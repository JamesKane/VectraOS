// SPDX-License-Identifier: BSD-3-Clause

// bin/linlon (linlon(3)): a Linlon-D6 display engine's driver host (the
// CIX Sky1's CIXH5010, five of them), serving the display class
// (`DisplayDeviceIPC.Display`) by flipping only: the engine firmware
// left scanning out keeps its mode, its link and its transmitter, and
// only its layer's buffer changes (lib/Linlon.swift).
//
// - Before any engine register is read, its power resource must be on
//   (/dev/acpi/power, its _STA as devmgr reads it): an engine firmware
//   didn't light is left alone, with no outputs.
// - The probe: CORE_ID a part with the D71's registers, the GCU in an active mode, the live
//   pipeline's enabled layer, its buffer and format, the timing
//   controller's mode, and the refresh, measured over the output unit's
//   once-a-frame interrupt.
// - attach maps a client's image; show and flush copy its damage into
//   one of two buffers of the driver's own (contiguous, write-combining:
//   the engine doesn't snoop, and no IOMMU translates its reads yet),
//   point the layer at it, set the GCU's configuration-valid bit and
//   wait for the latch at the next frame, so a flush returns once its
//   frame is the one being scanned out. show of 0 puts firmware's buffer
//   back.
//
// Its tree: `status`, and `display`.

import CroiMMIO
import DisplayDevice
import DriverHost
import IPC
import Node
import Sys

struct ProbeStop: Error {
  let text: String
}

func readText(_ ns: Namespace, _ path: String) -> String? {
  guard var f = try? ns.open(path) else { return nil }
  return try? f.readText()
}

func hexText(_ v: UInt64, digits: Int = 8) -> String {
  let d = Array("0123456789abcdef".utf8)
  var out: [UInt8] = Array("0x".utf8)
  for i in stride(from: digits - 1, through: 0, by: -1) { out.append(d[Int(v >> UInt64(4 * i) & 0xF)]) }
  return String(decoding: out, as: UTF8.self)
}

/// An attached image: the client's VMO, mapped to be read.
final class Image {
  let id: UInt32
  let width: UInt32
  let height: UInt32
  let mapping: Mapping
  init(id: UInt32, width: UInt32, height: UInt32, mapping: consuming Mapping) {
    self.id = id
    self.width = width
    self.height = height
    self.mapping = mapping
  }
}

/// What firmware left in the layer, put back by show of 0.
struct Saved {
  var low: UInt32, high: UInt32, stride: UInt32, format: UInt32
}

/// The live engine, as the dispatcher's thread drives it.
@safe final class Engine: DisplayDeviceIPC.DisplayHandler, @unchecked Sendable {
  let regs: Registers
  let irq: InterruptPort
  let pipeline: Int
  let layer: Int
  let width: UInt32, height: UInt32
  let refresh: UInt32
  let saved: Saved
  let memory: PinnedMemory
  var buffers: Buffers
  /// The two scan-out buffers, once an image is first shown.
  var scanout: [(address: UInt, bus: UInt64)] = []
  let stride: Int
  var images: [Image] = []
  var nextID: UInt32 = 1
  var shown: UInt32 = 0
  var flips = 0, latched = 0, missedInterrupts = 0, timeouts = 0

  init(regs: consuming Registers, irq: consuming InterruptPort, pipeline: Int, layer: Int, width: UInt32,
       height: UInt32, refresh: UInt32, saved: Saved, memory: PinnedMemory)
  {
    self.regs = regs
    self.irq = irq
    self.pipeline = pipeline
    self.layer = layer
    self.width = width
    self.height = height
    self.refresh = refresh
    self.saved = saved
    self.memory = memory
    buffers = Buffers(width: width, height: height)
    // Rows 64-byte aligned (the engine's reads are 16-byte bursts at least).
    stride = (Int(width) * 4 + 63) & ~63
  }

  var configValid: Int { pipeline == 0 ? D71.configValid0 : D71.configValid1 }
  var cval: UInt32 { pipeline == 0 ? D71.cval0 : D71.cval1 }

  /// Points the layer at `low`/`high`, sets the configuration valid and
  /// waits for the latch: the GCU's interrupt, or its raw status at the
  /// deadline (100 ms, six frames at 60 Hz).
  func latch(low: UInt32, high: UInt32, stride: UInt32, format: UInt32) {
    regs.store32(layer + D71.p0Low, low)
    regs.store32(layer + D71.p0High, high)
    regs.store32(layer + D71.p0Stride, stride)
    regs.store32(layer + D71.layerFormat, format)
    regs.store32(configValid, 1)
    flips += 1
    let deadline = Clock.monotonic() + 100_000_000
    while true {
      let fired = (try? irq.wait(deadline: deadline)) != nil
      let raw = regs.load32(D71.irqRawStatus)
      if raw != 0 { regs.store32(D71.irqClear, raw) }
      if fired { try? irq.ack() }
      if raw & cval != 0 {
        latched += 1
        if !fired { missedInterrupts += 1 }
        return
      }
      // At the deadline, however often other units' interrupts fire.
      if !fired || Clock.monotonic() >= deadline {
        timeouts += 1
        return
      }
    }
  }

  // DisplayDeviceIPC.Display

  func outputs() -> [DisplayDeviceIPC.Output] {
    [DisplayDeviceIPC.Output(id: 0, width: width, height: height, enabled: true, refresh: refresh)]
  }

  /// The PS185 gives no EDID, and the engine has no AUX of its own.
  func edid(output: UInt32) throws(DisplayDeviceIPC.DisplayError) -> [UInt8] {
    guard output == 0 else { throw .notFound }
    return []
  }

  func attach(vmo: consuming Handle, width: UInt32, height: UInt32) throws(DisplayDeviceIPC.DisplayError) -> UInt32 {
    guard width > 0, height > 0, width <= 8192, height <= 8192 else { throw .invalid }
    let bytes = (Int(width) * Int(height) * 4 + 4095) & ~4095
    guard let size = try? VMO.size(vmo), size >= bytes, let mapping = try? VMO.map(vmo, length: bytes, writable: false)
    else { throw .invalid }
    let id = nextID
    nextID += 1
    images.append(Image(id: id, width: width, height: height, mapping: mapping))
    return id
  }

  func detach(image: UInt32) {
    if shown == image { try? show(output: 0, image: 0) }
    images.removeAll { $0.id == image }
  }

  func show(output: UInt32, image: UInt32) throws(DisplayDeviceIPC.DisplayError) {
    guard output == 0 else { throw .notFound }
    if image == 0 {
      if shown != 0 { latch(low: saved.low, high: saved.high, stride: saved.stride, format: saved.format) }
      shown = 0
      return
    }
    guard let img = images.first(where: { $0.id == image }) else { throw .notFound }
    // No scaler in use: the image is the output's size.
    guard img.width == width, img.height == height else { throw .invalid }
    if scanout.isEmpty {
      for _ in 0..<2 {
        guard let b = try? unsafe memory.allocate(bytes: stride * Int(height)) else {
          scanout = []
          throw .unavailable
        }
        scanout.append(unsafe (UInt(bitPattern: b.pointer), b.bus))
      }
    }
    shown = image
    buffers.invalidate()
    try flush(image: image, damage: [])
  }

  func flush(image: UInt32, damage: [DisplayDeviceIPC.Area]) throws(DisplayDeviceIPC.DisplayError) {
    guard let img = images.first(where: { $0.id == image }) else { throw .notFound }
    guard image == shown else { return }  // on no screen
    var d = Rect(x: 0, y: 0, width: 0, height: 0)
    for a in damage { d = d.union(Rect(x: a.x, y: a.y, width: a.width, height: a.height)) }
    if damage.isEmpty { d = Rect(x: 0, y: 0, width: width, height: height) }
    let back = buffers.back
    let copy = buffers.flush(d)
    if !copy.isEmpty {
      let src = unsafe img.mapping.address, dst = unsafe UnsafeMutableRawPointer(bitPattern: scanout[back].address)!
      let rowBytes = Int(copy.width) * 4
      for y in Int(copy.y)..<Int(copy.y + copy.height) {
        unsafe (dst + y * stride + Int(copy.x) * 4).copyMemory(from: src + (y * Int(width) + Int(copy.x)) * 4,
                                                               byteCount: rowBytes)
      }
    }
    croi_dma_barrier()  // the pixels before the pointer that shows them
    let bus = scanout[back].bus
    latch(low: UInt32(truncatingIfNeeded: bus), high: UInt32(truncatingIfNeeded: bus >> 32), stride: UInt32(stride),
          format: D71.xrgb8888)
    buffers.flipped()
  }
}

/// The probe: the lines it says, and the engine if it is the live one.
func probe(_ ns: Namespace, _ resources: inout DeviceResources, coherent: Bool) -> (lines: [String], engine: Engine?) {
  var lines: [String] = []
  do throws(ProbeStop) {
    // Firmware's power: an engine unpowered faults on its first read.
    let power = readText(ns, "/dev/acpi/power") ?? ""
    guard power.utf8.starts(with: "on".utf8) else {
      throw ProbeStop(text: "off: its power resource is off, so firmware didn't light it; no register is read")
    }
    lines.append("powered by firmware")
    guard let regs = try? resources.map(bar: 0), regs.size >= D71.windowSize else {
      throw ProbeStop(text: "FAILED: no registers")
    }
    let core = regs.load32(D71.coreID), arch = regs.load32(D71.archID), info = regs.load32(D71.coreInfo)
    guard let product = D71.productName(coreID: core) else {
      throw ProbeStop(text: "FAILED: CORE_ID \(hexText(UInt64(core))): no part with the D71's registers")
    }
    let blocks = Int(info & 0xFF), pipelines = Int(info >> 8 & 7)
    lines.append("\(product) r\(core >> 12 & 0xF)p\(core >> 4 & 0xFF), ARCH_ID \(hexText(UInt64(arch))), "
      + "\(pipelines) pipelines, \(blocks) blocks")
    let gcu = regs.load32(D71.status)
    lines.append("GCU: \(D71.modeName(gcu)) (status \(hexText(UInt64(gcu))))")
    guard let pipe = D71.livePipeline(gcuStatus: gcu), pipe < pipelines else {
      throw ProbeStop(text: "idle: firmware left it not scanning out")
    }
    let layout = Layout.scan(blocks: blocks) { regs.load32($0) }
    guard let layer = layout.layers.first(where: {
      $0.pipeline == pipe && regs.load32($0.offset + D71.control) & D71.layerEnable != 0
    }) else {
      throw ProbeStop(text: "FAILED: pipeline \(pipe) has no enabled layer")
    }
    guard let bs = layout.timing[pipe], let dou = layout.outputUnits[pipe] else {
      throw ProbeStop(text: "FAILED: pipeline \(pipe) has no output unit or timing controller")
    }
    let l = layer.offset
    let saved = Saved(low: regs.load32(l + D71.p0Low), high: regs.load32(l + D71.p0High),
                      stride: regs.load32(l + D71.p0Stride), format: regs.load32(l + D71.layerFormat))
    let inSize = regs.load32(l + D71.layerInSize)
    let w = inSize & 0x1FFF, h = inSize >> 16 & 0x1FFF
    lines.append("pipeline \(pipe), layer \(layer.index): \(w)x\(h) \(D71.formatName(saved.format)), stride "
      + "\(saved.stride), at \(hexText(UInt64(saved.high) << 32 | UInt64(saved.low), digits: 10))")
    let t = Timing(activeSize: regs.load32(bs + D71.activeSize), hIntervals: regs.load32(bs + D71.hIntervals),
                   vIntervals: regs.load32(bs + D71.vIntervals), sync: regs.load32(bs + D71.sync))
    lines.append("timing \(t.text)")
    guard w > 0, h > 0 else { throw ProbeStop(text: "FAILED: the layer is \(w)x\(h)") }
    // Where firmware scales the layer to the mode, the scaler stays as it is.
    if w != t.width || h != t.height { lines.append("the layer is scaled to the mode") }

    // The interrupt, and the refresh measured over the output unit's
    // once-a-frame interrupt (then masked again: an idle desk takes none).
    guard let handle = try? resources.interrupt(), let irq = try? InterruptPort(handle) else {
      throw ProbeStop(text: "FAILED: no interrupt")
    }
    let douMask = regs.load32(dou + D71.irqMask)
    regs.store32(dou + D71.irqClear, regs.load32(dou + D71.irqRawStatus))
    regs.store32(dou + D71.irqMask, douMask | D71.douPL0)
    var frames: [Int64] = []
    let until = Clock.monotonic() + 500_000_000
    while frames.count < 31, Clock.monotonic() < until, let at = try? irq.wait(deadline: until) {
      let raw = regs.load32(dou + D71.irqRawStatus)
      regs.store32(dou + D71.irqClear, raw)
      // The GCU's own, if any is pending from firmware, cleared too.
      let gcuRaw = regs.load32(D71.irqRawStatus)
      if gcuRaw != 0 { regs.store32(D71.irqClear, gcuRaw) }
      try? irq.ack()
      if raw & D71.douPL0 != 0 { frames.append(at) }
    }
    regs.store32(dou + D71.irqMask, douMask)
    let hz = frames.count >= 2 ? refresh(frames: frames.count - 1, nanoseconds: frames[frames.count - 1] - frames[0]) : 0
    lines.append(frames.count >= 2
      ? "refresh \(hz / 1000).\(hz % 1000 / 100) Hz over \(frames.count - 1) frames"
      : "no frame interrupt in 500 ms (\(frames.count) seen): refresh unknown")
    // The latch's interrupt, for flips.
    let pipeCval = pipe == 0 ? D71.cval0 : D71.cval1
    regs.store32(D71.irqMask, regs.load32(D71.irqMask) | pipeCval)
    guard let bti = resources.takeBTI() else { throw ProbeStop(text: "FAILED: no BTI") }
    let memory = PinnedMemory(bti: bti, coherent: coherent)
    let engine = Engine(regs: regs, irq: irq, pipeline: pipe, layer: l, width: w, height: h,
                        refresh: hz == 0 ? 60_000 : hz, saved: saved, memory: memory)
    lines.append("ready: output 0 \(w)x\(h)")
    return (lines, engine)
  } catch {
    lines.append(error.text)
    return (lines, nil)
  }
}

@main struct LinlonDriver {
  static func main() {
    let start = Startup.current
    var resources = DeviceResources(take: { start.take($0)?.release() })
    let coherent = !start.args.contains { $0.utf8.elementsEqual("--noncoherent".utf8) }
    var probed: (lines: [String], engine: Engine?) = (["FAILED: no namespace"], nil)
    if let ns = try? Namespace(start) { probed = probe(ns, &resources, coherent: coherent) }
    let lines = probed.lines, engine = probed.engine
    print("linlon: " + lines.joined(separator: "; "))

    do throws(Status) {
      let dispatcher = try IPCDispatcher()
      let tree = NodeTree(dispatcher: dispatcher)
      let status = lines.map { $0 + "\n" }.joined()
      tree.text("status", read: {
        guard let e = engine else { return status }
        return status + "images \(e.images.count), showing \(e.shown == 0 ? "firmware's buffer" : "image \(e.shown)")\n"
          + "flips \(e.flips), latched \(e.latched), missed interrupts \(e.missedInterrupts), timeouts \(e.timeouts)\n"
      })
      // The display class: no outputs where the engine isn't live.
      tree.service("display") { (channel: consuming Handle) throws(Status) in
        if let engine {
          _ = try dispatcher.add(DisplayDeviceIPC.DisplayServer(channel: channel, impl: engine))
        } else {
          _ = try dispatcher.add(DisplayDeviceIPC.DisplayServer(channel: channel, impl: Unlit()))
        }
      }
      guard let export = start.export() else { Process.exit(code: 2) }
      try tree.serve(export)
      try dispatcher.run()
    } catch {
      Process.exit(code: 1)
    }
    _ = consume resources
  }
}

/// An engine firmware didn't light: no outputs.
final class Unlit: DisplayDeviceIPC.DisplayHandler, @unchecked Sendable {
  func outputs() -> [DisplayDeviceIPC.Output] { [] }
  func edid(output: UInt32) throws(DisplayDeviceIPC.DisplayError) -> [UInt8] { throw .notFound }
  func attach(vmo: consuming Handle, width: UInt32, height: UInt32) throws(DisplayDeviceIPC.DisplayError) -> UInt32 {
    throw .unavailable
  }
  func detach(image: UInt32) {}
  func show(output: UInt32, image: UInt32) throws(DisplayDeviceIPC.DisplayError) { throw .notFound }
  func flush(image: UInt32, damage: [DisplayDeviceIPC.Area]) throws(DisplayDeviceIPC.DisplayError) { throw .notFound }
}
