// SPDX-License-Identifier: BSD-3-Clause

// bin/linlon (linlon(3)): a Linlon-D6 display engine's driver host (the
// CIX Sky1's CIXH5010, five of them), serving the display class
// (`DisplayDeviceIPC.Display`): the engine firmware left scanning out,
// its layer flipped between a client's images, and its mode set to
// another the monitor and the link carry (lib/Linlon.swift).
//
// - Before any engine register is read, its power resource must be on
//   (/dev/acpi/power, its _STA as devmgr reads it): an engine firmware
//   didn't light is left alone, with no outputs.
// - The probe: CORE_ID a part with the D71's registers, the GCU in an
//   active mode, the live pipeline's enabled layer, its buffer and
//   format, its data path (compositor, image processor) and the timing
//   controller's mode, and the refresh, measured over the output unit's
//   once-a-frame interrupt.
// - attach pins a client's image through the engine's BTI, one run of
//   device addresses the display SMMU translates (D146); present (and
//   show, and flush of the shown image) writes the damaged rows back from
//   the CPU's caches (the engine doesn't snoop), points the layer at the
//   image, sets the GCU's configuration-valid bit and waits for the latch
//   at the next frame, so it returns once its frame is the one being
//   scanned out. show of 0 puts firmware's buffer back.
// - The modes are the monitor's (its EDID, through the transmitter's
//   link) that the link and one pixel a clock carry. A mode set (D146,
//   linlon-dpu 08 §8.5): the transmitter's stream stopped; the pipeline
//   disabled in two latches; the GCU inactive; the pixel clock gated, set
//   and ungated through /dev/scmi; ip_reset pulsed (the reset controller
//   devmgr grants, `--bar=N:reset`); the GCU active again and the path
//   built anew, one layer into the compositor over black, the image
//   processor, the timing; then the stream started for the new timing,
//   the link trained at another rate where it must be.
//
// Its tree: `status`, `ctl` (`mode WxH[@HZ]`), and `display`.

import CroiMMIO
import DisplayDevice
import DriverHost
import IPC
import Node
import Sys

struct ProbeStop: Error {
  let text: String
}

func hexText(_ v: UInt64, digits: Int = 8) -> String {
  let d = Array("0123456789abcdef".utf8)
  var out: [UInt8] = Array("0x".utf8)
  for i in stride(from: digits - 1, through: 0, by: -1) { out.append(d[Int(v >> UInt64(4 * i) & 0xF)]) }
  return String(decoding: out, as: UTF8.self)
}

func textLines(_ text: String) -> [[UInt8]] { text.utf8.split(separator: 0x0A).map { Array($0) } }

func words(_ line: [UInt8]) -> [[UInt8]] { line.split(separator: 0x20).map { Array($0) } }

func number(_ w: [UInt8]) -> UInt32? { UInt32(String(decoding: w, as: UTF8.self)) }

/// Writes `line` to `path`, which must take it.
func command(_ ns: Namespace, _ path: String, _ line: String) -> Bool {
  guard var f = try? ns.open(path) else { return false }
  let bytes = Array((line + "\n").utf8)
  return (try? f.write(offset: 0, bytes)) == UInt32(bytes.count)
}

/// The syncs' polarity as the timing controller drives them: inverted,
/// as firmware and the vendor's driver drive them (the transmitter tells
/// the sink the mode's own).
let invertSyncs = true

/// An attached image: the client's VMO, pinned for the engine to read as
/// one run of device addresses (the display SMMU translates them, D146).
final class Image {
  let id: UInt32
  let width: UInt32
  let height: UInt32
  let vmo: Handle
  let pmt: UInt32
  let bus: UInt64
  init(id: UInt32, width: UInt32, height: UInt32, vmo: consuming Handle, pmt: UInt32, bus: UInt64) {
    self.id = id
    self.width = width
    self.height = height
    self.vmo = vmo
    self.pmt = pmt
    self.bus = bus
  }
  deinit { try? DMA.unpin(pmt: pmt) }
}

/// What firmware left in the layer, put back by show of 0.
struct Saved {
  var low: UInt32, high: UInt32, stride: UInt32, format: UInt32
  var width: UInt32, height: UInt32
}

/// The live pipeline's blocks, by offset in the engine's window.
struct Blocks {
  var pipeline: Int
  /// The layer firmware showed, and all the pipeline's.
  var layer: Int
  var layers: [Int]
  var compositor: Int?, processor: Int?, timing: Int, outputUnit: Int
  /// Scalers, splitter and merger: off once a mode is set.
  var others: [Int]
  /// The timing controller's programmed and prefetch lines, firmware's.
  var lines: (prog: UInt32, prefetch: UInt32) = (4, 5)
}

/// A register window that may be missing.
final class Window: @unchecked Sendable {
  let regs: Registers
  init(_ regs: consuming Registers) { self.regs = regs }
  func load(_ o: Int) -> UInt32 { regs.load32(o) }
  func store(_ o: Int, _ v: UInt32) { regs.store32(o, v) }
}

/// The engine's own channel to its transmitter's link, for calls (the
/// follower's thread has its own, for events).
final class LinkControl: @unchecked Sendable {
  var client: DisplayLinkIPC.LinkClient
  init(raw: UInt32) { client = DisplayLinkIPC.LinkClient(channel: Handle(raw: raw)) }
  func capacity() -> UInt32 { (try? client.capacity()) ?? 0 }
  func stop() { try? client.stop() }
  /// Nil if it started, else why not.
  func start(_ t: DisplayLinkIPC.Timing) -> String? {
    do throws(IPCError<DisplayLinkIPC.LinkError>) {
      try client.start(timing: t)
      return nil
    } catch {
      switch error {
      case .remote(.noSink): return "no monitor"
      case .remote(.tooFast): return "no link carries it"
      case .remote(.invalid): return "the transmitter refused the timing"
      case .remote(.trainingFailed): return "no link trained"
      case .transport, .wire: return "the link didn't answer"
      }
    }
  }
}

/// How a mode set reaches what isn't the engine's: the pixel clock
/// (SCMI), the reset controller, and the link.
struct ModeSetting {
  var ns: Namespace
  var pixelClock: UInt32
  var reset: Window
  var resetRegister: Int, resetBit: UInt32
}

/// The live engine, as the dispatcher's thread drives it.
@safe final class Engine: DisplayDeviceIPC.DisplayHandler, @unchecked Sendable {
  let regs: Registers
  let irq: InterruptPort
  let blocks: Blocks
  var width: UInt32, height: UInt32
  var refresh: UInt32
  let saved: Saved
  let bti: Handle
  let link = LinkState()
  var control: LinkControl?
  var setting: ModeSetting?
  /// The mode set, once one is: the path is then the engine's own, and an
  /// image of any size is shown from the top left.
  var mode: ModeTiming?
  var modeSets = 0, lastModeSet = ""
  var images: [Image] = []
  var nextID: UInt32 = 1
  var shown: UInt32 = 0
  var flips = 0, latched = 0, missedInterrupts = 0, timeouts = 0, refused = 0

  init(regs: consuming Registers, irq: consuming InterruptPort, blocks: Blocks, width: UInt32, height: UInt32,
       refresh: UInt32, saved: Saved, bti: consuming Handle)
  {
    self.regs = regs
    self.irq = irq
    self.blocks = blocks
    self.width = width
    self.height = height
    self.refresh = refresh
    self.saved = saved
    self.bti = bti
  }

  var pipeline: Int { blocks.pipeline }
  var layer: Int { blocks.layer }
  var configValid: Int { pipeline == 0 ? D71.configValid0 : D71.configValid1 }
  var cval: UInt32 { pipeline == 0 ? D71.cval0 : D71.cval1 }

  /// Sets the configuration valid and waits for the latch: the GCU's
  /// interrupt, or its raw status at the deadline (100 ms, six frames at
  /// 60 Hz). Whether it latched.
  @discardableResult func commit() -> Bool {
    regs.store32(configValid, 1)
    let deadline = Clock.monotonic() + 100_000_000
    while true {
      let fired = (try? irq.wait(deadline: deadline)) != nil
      let raw = regs.load32(D71.irqRawStatus)
      if raw != 0 { regs.store32(D71.irqClear, raw) }
      if fired { try? irq.ack() }
      if raw & cval != 0 {
        if !fired { missedInterrupts += 1 }
        return true
      }
      // At the deadline, however often other units' interrupts fire.
      if !fired || Clock.monotonic() >= deadline { return false }
    }
  }

  /// Points the layer at `low`/`high` and latches it, the layer (and,
  /// once the path is the engine's, the compositor's input) the image's
  /// size up to the mode's.
  func latch(low: UInt32, high: UInt32, stride: UInt32, format: UInt32, width w: UInt32, height h: UInt32) {
    regs.store32(layer + D71.p0Low, low)
    regs.store32(layer + D71.p0High, high)
    regs.store32(layer + D71.p0Stride, stride)
    regs.store32(layer + D71.layerFormat, format)
    if mode != nil, let cu = blocks.compositor {
      let size = hvSize(min(w, width), min(h, height))
      regs.store32(layer + D71.layerInSize, size)
      regs.store32(cu + D71.cuInputSize(0), size)
    }
    flips += 1
    if commit() { latched += 1 } else { timeouts += 1 }
  }

  /// The image on the layer, from the next frame.
  func latch(_ img: Image) {
    latch(low: UInt32(truncatingIfNeeded: img.bus), high: UInt32(truncatingIfNeeded: img.bus >> 32),
          stride: img.width * 4, format: D71.xrgb8888, width: img.width, height: img.height)
  }

  /// The rows `damage` touches (none: all) written back from the CPU's
  /// caches: the engine doesn't snoop them.
  func clean(_ img: Image, _ damage: [DisplayDeviceIPC.Area]) {
    var top = img.height, bottom: UInt32 = 0
    for a in damage where a.width > 0 && a.height > 0 && a.y < img.height {
      top = min(top, a.y)
      bottom = max(bottom, min(img.height, a.y + a.height))
    }
    if damage.isEmpty { (top, bottom) = (0, img.height) }
    guard top < bottom else { return }
    let row = UInt64(img.width) * 4
    try? VMO.cacheClean(img.vmo, offset: UInt64(top) * row, length: Int(UInt64(bottom - top) * row))
    croi_dma_barrier()  // the pixels before the pointer that shows them
  }

  /// The monitor's modes the engine and the link carry: one pixel a clock
  /// (up to 600 MHz), the timing controller's fields, and the link's
  /// capacity at 24 bits a pixel.
  func modeTimings() -> [ModeTiming] {
    let edid = link.lock.withLock { link.edid }
    let capacity = control?.capacity() ?? 0
    return EDID.modes(edid).filter { m in
      m.clock <= 600_000 && (control == nil || m.clock <= capacity)
        && Timing.registers(hActive: m.hActive, hSyncStart: m.hSyncStart, hSyncEnd: m.hSyncEnd, hTotal: m.hTotal,
                            vActive: m.vActive, vSyncStart: m.vSyncStart, vSyncEnd: m.vSyncEnd, vTotal: m.vTotal,
                            hPositive: true, vPositive: true) != nil
    }
  }

  /// The mode `m` set (the sequence in the header). Nil if it runs, else why not.
  func apply(_ m: ModeTiming) -> String? {
    guard let setting, let control else { return "no pixel clock, reset or link to set a mode with" }
    guard let cu = blocks.compositor, let ips = blocks.processor else { return "no compositor or image processor" }
    guard let bs = Timing.registers(hActive: m.hActive, hSyncStart: m.hSyncStart, hSyncEnd: m.hSyncEnd,
                                    hTotal: m.hTotal, vActive: m.vActive, vSyncStart: m.vSyncStart,
                                    vSyncEnd: m.vSyncEnd, vTotal: m.vTotal, hPositive: m.hPositive != invertSyncs,
                                    vPositive: m.vPositive != invertSyncs)
    else { return "the timing controller can't hold it" }
    modeSets += 1
    var steps: [String] = []
    control.stop()

    // Two latches (03 §3.6): the layers, the compositor's inputs and the
    // rest of the path off, then the image processor and the timing.
    for l in blocks.layers { regs.store32(l + D71.control, regs.load32(l + D71.control) & ~D71.layerEnable) }
    for n in 0..<5 {
      regs.store32(cu + D71.inputID(n), 0)
      regs.store32(cu + D71.cuInputControl(n), D71.cuInputOff)
    }
    for b in blocks.others {
      regs.store32(b + D71.control, 0)
      regs.store32(b + D71.inputID(0), 0)
      regs.store32(b + D71.inputID(1), 0)
    }
    steps.append(commit() ? "path off" : "path off (no latch)")
    regs.store32(ips + D71.inputID(0), 0)
    regs.store32(ips + D71.inputID(1), 0)
    regs.store32(ips + D71.control, 0)
    regs.store32(blocks.timing + D71.control, regs.load32(blocks.timing + D71.control) & ~D71.bsEnable)
    steps.append(commit() ? "timing off" : "timing off (no latch)")
    setGCUMode(0)

    // The pixel clock, gated while it changes, read back once it has.
    let id = setting.pixelClock
    let ns = setting.ns
    var clock = m.clock
    if command(ns, "/dev/scmi/ctl", "clock \(id) off"), command(ns, "/dev/scmi/ctl", "clock \(id) rate \(m.clock * 1000)"),
      command(ns, "/dev/scmi/ctl", "clock \(id) on")
    {
      if let hz = rateSet(ns, id), hz > 0 { clock = hz / 1000 }
      steps.append("pixel clock \(clock) kHz")
    } else {
      _ = command(ns, "/dev/scmi/ctl", "clock \(id) on")
      steps.append("pixel clock not set")
    }

    // ip_reset pulsed: assert, 1 ms, release, 1 ms (08 §8.4).
    let r = setting.reset.load(setting.resetRegister)
    setting.reset.store(setting.resetRegister, r & ~setting.resetBit)
    sleep(until: Clock.monotonic() + 1_000_000)
    setting.reset.store(setting.resetRegister, r | setting.resetBit)
    sleep(until: Clock.monotonic() + 1_000_000)

    // The path anew (03 §3.8): the GCU active, the latch's interrupt,
    // each layer's alpha map, then layer, compositor, image processor,
    // timing.
    let active = setGCUMode(pipeline == 0 ? 3 : 4)
    regs.store32(D71.irqMask, regs.load32(D71.irqMask) | cval)
    for l in blocks.layers { regs.store32(l + D71.layerAlphaMap, D71.alphaMapValue) }
    let img = images.first { $0.id == shown }
    let w = min(img?.width ?? saved.width, m.hActive), h = min(img?.height ?? saved.height, m.vActive)
    if let img {
      regs.store32(layer + D71.p0Low, UInt32(truncatingIfNeeded: img.bus))
      regs.store32(layer + D71.p0High, UInt32(truncatingIfNeeded: img.bus >> 32))
      regs.store32(layer + D71.p0Stride, img.width * 4)
      regs.store32(layer + D71.layerFormat, D71.xrgb8888)
    } else {
      regs.store32(layer + D71.p0Low, saved.low)
      regs.store32(layer + D71.p0High, saved.high)
      regs.store32(layer + D71.p0Stride, saved.stride)
      regs.store32(layer + D71.layerFormat, saved.format)
    }
    regs.store32(layer + D71.layerInSize, hvSize(w, h))
    regs.store32(layer + D71.control, regs.load32(layer + D71.control) | D71.layerEnable)
    regs.store32(cu + D71.inputID(0), D71.asInput(regs.load32(layer + D71.blockInfo)))
    regs.store32(cu + D71.cuInputSize(0), hvSize(w, h))
    regs.store32(cu + D71.cuInputOffset(0), 0)
    regs.store32(cu + D71.cuInputControl(0), D71.cuInputOpaque)
    regs.store32(cu + D71.cuSize, hvSize(m.hActive, m.vActive))
    regs.store32(cu + D71.cuBackground, 0)
    regs.store32(ips + D71.inputID(0), D71.asInput(regs.load32(cu + D71.blockInfo)))
    regs.store32(ips + D71.inputID(1), 0)
    regs.store32(ips + D71.ipsSize, hvSize(m.hActive, m.vActive))
    regs.store32(ips + D71.ipsDepth, 8)
    regs.store32(ips + D71.control, 0)
    let t = blocks.timing
    regs.store32(t + D71.activeSize, bs.activeSize)
    regs.store32(t + D71.hIntervals, bs.hIntervals)
    regs.store32(t + D71.vIntervals, bs.vIntervals)
    regs.store32(t + D71.sync, bs.sync)
    regs.store32(t + D71.progLine, blocks.lines.prog)
    regs.store32(t + D71.prefetchLine, blocks.lines.prefetch)
    regs.store32(t + D71.control, D71.bsEnable | D71.bsVideoMode)
    steps.append((active ? "" : "gcu mode not taken, ") + (commit() ? "path on" : "path on (no latch)"))

    mode = m
    width = m.hActive
    height = m.vActive
    let total = UInt64(m.hTotal) * UInt64(m.vTotal)
    refresh = UInt32(truncatingIfNeeded: (UInt64(clock) * 1_000_000 + total / 2) / total)
    // The stream, for the clock the platform gave.
    let why = control.start(DisplayLinkIPC.Timing(
      clock: clock, hActive: m.hActive, hSyncStart: m.hSyncStart, hSyncEnd: m.hSyncEnd, hTotal: m.hTotal,
      vActive: m.vActive, vSyncStart: m.vSyncStart, vSyncEnd: m.vSyncEnd, vTotal: m.vTotal,
      flags: (m.hPositive ? 1 : 0) | (m.vPositive ? 2 : 0)))
    steps.append(why.map { "stream not started: " + $0 } ?? "stream started")
    lastModeSet = m.text + ": " + steps.joined(separator: ", ")
    print("linlon: mode " + lastModeSet)
    // Every client told the output changed.
    let servers = link.lock.withLock { () -> [UInt64] in
      link.changes += 1
      return link.clients.map { $0.server }
    }
    if let d = link.dispatcher { for s in servers { d.wake(s) } }
    return why
  }

  /// The GCU's operating mode asked for and read back (03 §3.3: up to
  /// 100 polls, 1 ms apart).
  @discardableResult func setGCUMode(_ m: UInt32) -> Bool {
    regs.store32(D71.control, regs.load32(D71.control) & ~D71.modeMask | m)
    for _ in 0..<100 {
      if regs.load32(D71.control) & D71.modeMask == m { return true }
      sleep(until: Clock.monotonic() + 1_000_000)
    }
    return false
  }

  // DisplayDeviceIPC.Display

  /// The one output, enabled while the transmitter's link says a monitor
  /// is there (always, without a link).
  func outputs() -> [DisplayDeviceIPC.Output] {
    let connected = link.lock.withLock { link.connected }
    return [DisplayDeviceIPC.Output(id: 0, width: width, height: height, enabled: connected, refresh: refresh)]
  }

  /// The engine has no AUX of its own: the EDID is the transmitter's, as
  /// its link last said.
  func edid(output: UInt32) throws(DisplayDeviceIPC.DisplayError) -> [UInt8] {
    guard output == 0 else { throw .notFound }
    return link.lock.withLock { link.edid }
  }

  func modes(output: UInt32) throws(DisplayDeviceIPC.DisplayError) -> [DisplayDeviceIPC.Mode] {
    guard output == 0 else { throw .notFound }
    return modeTimings().map { DisplayDeviceIPC.Mode(width: $0.hActive, height: $0.vActive, refresh: $0.refresh, clock: $0.clock) }
  }

  func setMode(output: UInt32, mode: DisplayDeviceIPC.Mode) throws(DisplayDeviceIPC.DisplayError) {
    guard output == 0 else { throw .notFound }
    guard let m = modeTimings().first(where: {
      $0.hActive == mode.width && $0.vActive == mode.height && $0.refresh == mode.refresh && $0.clock == mode.clock
    }) else { throw .invalid }
    if apply(m) != nil { throw .unavailable }
  }

  /// Pinned through the BTI as one run: refused where no IOMMU
  /// translates the engine and the VMO isn't contiguous.
  func attach(vmo: consuming Handle, width: UInt32, height: UInt32) throws(DisplayDeviceIPC.DisplayError) -> UInt32 {
    guard width > 0, height > 0, width <= 8192, height <= 8192 else { throw .invalid }
    let bytes = (Int(width) * Int(height) * 4 + 4095) & ~4095
    guard let size = try? VMO.size(vmo), size >= bytes else { throw .invalid }
    // A page an address (`.contiguous` is for contiguous VMOs only): behind
    // the IOMMU they run on, one reservation; without one, rarely.
    let pages = bytes / 4096
    guard let pinned = try? DMA.pin(bti, vmo, offset: 0, size: bytes, options: [.read], count: pages) else {
      refused += 1
      throw .unavailable
    }
    for (i, a) in pinned.addresses.enumerated() where a != pinned.addresses[0] + UInt64(i) * 4096 {
      try? DMA.unpin(pmt: pinned.pmt)
      refused += 1
      throw .unavailable
    }
    let id = nextID
    nextID += 1
    images.append(Image(id: id, width: width, height: height, vmo: vmo, pmt: pinned.pmt, bus: pinned.addresses[0]))
    return id
  }

  /// Firmware's buffer back first where the image is shown, so the
  /// engine never reads pages unpinned.
  func detach(image: UInt32) {
    if shown == image { try? show(output: 0, image: 0) }
    images.removeAll { $0.id == image }
  }

  func show(output: UInt32, image: UInt32) throws(DisplayDeviceIPC.DisplayError) {
    guard output == 0 else { throw .notFound }
    if image == 0 {
      if shown != 0 {
        latch(low: saved.low, high: saved.high, stride: saved.stride, format: saved.format, width: saved.width,
              height: saved.height)
      }
      shown = 0
      return
    }
    try present(output: output, image: image, damage: [])
  }

  /// The shown image's damage written back: the engine reads it from the
  /// next frame. It tears where the client draws into the image shown;
  /// `present` of the other image doesn't.
  func flush(image: UInt32, damage: [DisplayDeviceIPC.Area]) throws(DisplayDeviceIPC.DisplayError) {
    guard let img = images.first(where: { $0.id == image }) else { throw .notFound }
    guard image == shown else { return }  // on no screen
    clean(img, damage)
    latch(img)
  }

  func present(output: UInt32, image: UInt32, damage: [DisplayDeviceIPC.Area]) throws(DisplayDeviceIPC.DisplayError) {
    guard output == 0 else { throw .notFound }
    guard let img = images.first(where: { $0.id == image }) else { throw .notFound }
    // In firmware's path, whose scaler and compositor stay as they are,
    // the image is the output's size.
    guard mode != nil || (img.width == width && img.height == height) else { throw .invalid }
    clean(img, damage)
    latch(img)
    shown = image
  }
}

/// The rate SCMI's status says clock `id` was set to, in Hz.
func rateSet(_ ns: Namespace, _ id: UInt32) -> UInt32? {
  for l in textLines(ns.readText("/dev/scmi/status") ?? "") {
    let w = words(l)
    if w.count == 4, w[0] == Array("clock".utf8), number(w[1]) == id, w[2] == Array("rate".utf8) { return number(w[3]) }
  }
  return nil
}

/// The data path firmware left, as status lines.
func pathText(_ regs: borrowing Registers, _ b: Blocks) -> [String] {
  func h(_ v: UInt32) -> String { hexText(UInt64(v)) }
  var out: [String] = []
  let layers = b.layers.map { h(regs.load32($0 + D71.control)) }.joined(separator: " ")
  out.append("layers' control \(layers)")
  if let cu = b.compositor {
    let inputs = (0..<5).map { h(regs.load32(cu + D71.inputID($0))) }.joined(separator: " ")
    out.append("compositor: inputs \(inputs), size \(h(regs.load32(cu + D71.cuSize))), input 0 size "
      + "\(h(regs.load32(cu + D71.cuInputSize(0)))) offset \(h(regs.load32(cu + D71.cuInputOffset(0)))) control "
      + "\(h(regs.load32(cu + D71.cuInputControl(0)))), background \(h(regs.load32(cu + D71.cuBackground)))")
  }
  if let ips = b.processor {
    out.append("image processor: input \(h(regs.load32(ips + D71.inputID(0)))) \(h(regs.load32(ips + D71.inputID(1)))), "
      + "control \(h(regs.load32(ips + D71.control))), size \(h(regs.load32(ips + D71.ipsSize))), depth "
      + "\(regs.load32(ips + D71.ipsDepth))")
  }
  let others = b.others.map { h(regs.load32($0 + D71.control)) }.joined(separator: " ")
  out.append("scalers, splitter and merger control \(others)")
  let t = b.timing
  out.append("timing control \(h(regs.load32(t + D71.control))), sync \(h(regs.load32(t + D71.sync))), "
    + "lines \(regs.load32(t + D71.progLine)) \(regs.load32(t + D71.prefetchLine)); gcu control "
    + "\(h(regs.load32(D71.control))), irq mask \(h(regs.load32(D71.irqMask)))")
  return out
}

/// The probe: the lines it says, and the engine if it is the live one.
func probe(_ ns: Namespace, _ resources: inout DeviceResources) -> (lines: [String], engine: Engine?) {
  var lines: [String] = []
  do throws(ProbeStop) {
    // Firmware's power: an engine unpowered faults on its first read.
    let power = ns.readText("/dev/acpi/power") ?? ""
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
    var path = Blocks(pipeline: pipe, layer: layer.offset, layers: layout.layers.filter { $0.pipeline == pipe }.map { $0.offset },
                      compositor: layout.compositors[pipe], processor: layout.processors[pipe], timing: bs,
                      outputUnit: dou, others: layout.scalers[pipe] + layout.others[pipe])
    path.lines = (regs.load32(bs + D71.progLine), regs.load32(bs + D71.prefetchLine))
    let l = layer.offset
    let inSize = regs.load32(l + D71.layerInSize)
    let w = inSize & 0x1FFF, h = inSize >> 16 & 0x1FFF
    let saved = Saved(low: regs.load32(l + D71.p0Low), high: regs.load32(l + D71.p0High),
                      stride: regs.load32(l + D71.p0Stride), format: regs.load32(l + D71.layerFormat), width: w, height: h)
    lines.append("pipeline \(pipe), layer \(layer.index): \(w)x\(h) \(D71.formatName(saved.format)), stride "
      + "\(saved.stride), at \(hexText(UInt64(saved.high) << 32 | UInt64(saved.low), digits: 10))")
    let t = Timing(activeSize: regs.load32(bs + D71.activeSize), hIntervals: regs.load32(bs + D71.hIntervals),
                   vIntervals: regs.load32(bs + D71.vIntervals), sync: regs.load32(bs + D71.sync))
    lines.append("timing \(t.text)")
    lines += pathText(regs, path)
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
    let engine = Engine(regs: regs, irq: irq, blocks: path, width: w, height: h, refresh: hz == 0 ? 60_000 : hz,
                        saved: saved, bti: bti)
    lines.append("ready: output 0 \(w)x\(h)")
    return (lines, engine)
  } catch {
    lines.append(error.text)
    return (lines, nil)
  }
}

/// What a mode set needs besides the engine: the pipeline's pixel clock
/// (CLKT's `pipeline@<n>`), and its ip_reset (RSTL's, in the reset
/// controller devmgr grants). Nil, and why, where one is missing.
func modeSetting(_ ns: Namespace, _ resources: borrowing DeviceResources, roles: [(index: Int, role: String)],
                 pipeline: Int) -> (ModeSetting?, String)
{
  let name = Array("pipeline@\(pipeline)".utf8)
  var clock: UInt32?
  for l in textLines(ns.readText("/dev/acpi/clocks") ?? "") {
    let w = words(l)
    if w.count == 2, w[1] == name { clock = number(w[0]) }
  }
  guard let clock else { return (nil, "no pixel clock for pipeline \(pipeline) in its CLKT: no mode set") }
  var line: (register: Int, bit: UInt32)?
  for l in textLines(ns.readText("/dev/acpi/resets") ?? "") {
    let w = words(l)
    if w.count == 3, w[2] == Array("ip_reset".utf8), let index = number(w[1]) { line = ipReset(index: index) }
  }
  guard let line, let b = roles.first(where: { $0.role.utf8.elementsEqual("reset".utf8) })?.index,
    let rst = try? resources.map(bar: b)
  else { return (nil, "no ip_reset in its RSTL's reset controller: no mode set") }
  return (ModeSetting(ns: ns, pixelClock: clock, reset: Window(rst), resetRegister: line.register, resetBit: line.bit),
          "modes set through pixel clock \(clock) and ip_reset bit \(line.bit.trailingZeroBitCount)")
}

@main struct LinlonDriver {
  static func main() {
    let start = Startup.current
    var resources = DeviceResources(take: { start.take($0)?.release() })
    // `--bar=INDEX:ROLE`: which BAR each linked range is.
    var roles: [(index: Int, role: String)] = []
    for a in start.args where a.utf8.starts(with: "--bar=".utf8) {
      let rest = Array(a.utf8.dropFirst(6))
      guard let colon = rest.firstIndex(of: 0x3A), let i = Int(String(decoding: rest[..<colon], as: UTF8.self)) else { continue }
      roles.append((i, String(decoding: rest[(colon + 1)...], as: UTF8.self)))
    }
    var probed: (lines: [String], engine: Engine?) = (["FAILED: no namespace"], nil)
    let ns = try? Namespace(start)
    if let ns { probed = probe(ns, &resources) }
    var lines = probed.lines
    let engine = probed.engine
    // The transmitter's link, where devmgr gave one (/dev/link, D146): a
    // channel to follow it, and one to call it.
    var linkChannel: UInt32 = 0
    if let engine, let ns, let ch = try? ns.connect("/dev/link/link") {
      linkChannel = ch.release()
      if let ctl = try? ns.connect("/dev/link/link") { engine.control = LinkControl(raw: ctl.release()) }
      lines.append("following the transmitter's link")
    }
    if let engine, let ns {
      let (setting, line) = modeSetting(ns, resources, roles: roles, pipeline: engine.pipeline)
      engine.setting = setting
      lines.append(line)
    }
    print("linlon: " + lines.joined(separator: "; "))

    do throws(Status) {
      let dispatcher = try IPCDispatcher()
      if let engine, linkChannel != 0 {
        let raw = linkChannel
        _ = try? Thread.spawn { follow(raw, engine.link, dispatcher) }.release()
      }
      engine?.link.dispatcher = dispatcher
      let tree = NodeTree(dispatcher: dispatcher)
      let status = lines.map { $0 + "\n" }.joined()
      tree.text("status", read: {
        guard let e = engine else { return status }
        let link = e.link.lock.withLock { () -> String in
          guard e.link.followed else { return "" }
          let monitor = e.link.edid.isEmpty ? "no edid" : (EDID(e.link.edid).map { $0.text } ?? "edid not valid")
          return "link: " + (e.link.connected ? "connected, " + monitor : "no monitor") + ", changes \(e.link.changes)\n"
        }
        let modes = e.modeTimings()
        return status + "images \(e.images.count), refused \(e.refused), showing \(e.shown == 0 ? "firmware's buffer" : "image \(e.shown)")\n"
          + "flips \(e.flips), latched \(e.latched), missed interrupts \(e.missedInterrupts), timeouts \(e.timeouts)\n"
          + link + "modes \(modes.count): " + modes.map { $0.text }.joined(separator: ", ") + "\n"
          + (e.modeSets > 0 ? "mode sets \(e.modeSets): \(e.lastModeSet)\n" : "")
      })
      // `mode WxH[@HZ]`: the first of the modes with that size (and refresh).
      tree.text("ctl", read: { "" }, write: { (text: String) throws(NodeError) in
        guard let e = engine else { throw .io }
        for l in textLines(text) {
          let w = words(l)
          guard w.count == 2, w[0] == Array("mode".utf8) else { throw .invalid }
          let spec = w[1].split(separator: 0x40, omittingEmptySubsequences: false).map { Array($0) }
          let size = spec[0].split(separator: 0x78).map { Array($0) }
          guard size.count == 2, let width = number(size[0]), let height = number(size[1]) else { throw .invalid }
          let hz = spec.count == 2 ? number(spec[1]) : nil
          guard let m = e.modeTimings().first(where: {
            $0.hActive == width && $0.vActive == height && (hz == nil || ($0.refresh + 500) / 1000 == hz)
          }) else { throw .invalid }
          if e.apply(m) != nil { throw .io }
        }
      })
      // The display class: no outputs where the engine isn't live. Each
      // client is told of the link's changes by its server's thread.
      tree.service("display") { (channel: consuming Handle) throws(Status) in
        if let engine {
          let link = engine.link
          let c = DisplayClient()
          let told = link.lock.withLock { link.changes }
          c.id = try dispatcher.add(DisplayDeviceIPC.DisplayServer(channel: channel, impl: engine)) {
            (s: inout DisplayDeviceIPC.DisplayServer<Engine>) throws(IPCError<Never>) in
            let tell = link.lock.withLock { () -> Bool in
              guard let i = link.clients.firstIndex(where: { $0.server == c.id }), link.clients[i].told != link.changes
              else { return false }
              link.clients[i].told = link.changes
              return true
            }
            if tell { try DisplayDeviceIPC.DisplayEventSender.sendOutputsChanged(on: s.connection) }
          }
          link.lock.withLock { link.clients.append((c.id, told)) }
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
  func modes(output: UInt32) throws(DisplayDeviceIPC.DisplayError) -> [DisplayDeviceIPC.Mode] { throw .notFound }
  func setMode(output: UInt32, mode: DisplayDeviceIPC.Mode) throws(DisplayDeviceIPC.DisplayError) { throw .notFound }
  func attach(vmo: consuming Handle, width: UInt32, height: UInt32) throws(DisplayDeviceIPC.DisplayError) -> UInt32 {
    throw .unavailable
  }
  func detach(image: UInt32) {}
  func show(output: UInt32, image: UInt32) throws(DisplayDeviceIPC.DisplayError) { throw .notFound }
  func flush(image: UInt32, damage: [DisplayDeviceIPC.Area]) throws(DisplayDeviceIPC.DisplayError) { throw .notFound }
  func present(output: UInt32, image: UInt32, damage: [DisplayDeviceIPC.Area]) throws(DisplayDeviceIPC.DisplayError) {
    throw .notFound
  }
}

/// What the engine's transmitter says of its monitor (D146), as the
/// thread following its link hears it.
final class LinkState: @unchecked Sendable {
  let lock = Lock()
  /// Whether a link is followed; without one, the output is taken to be
  /// connected, with no EDID.
  var followed = false
  var connected = true
  var edid: [UInt8] = []
  /// The changes clients are told of: the link's, and modes set.
  var changes = 0
  /// The display class's clients: each one's server, and the changes it
  /// was told of.
  var clients: [(server: UInt64, told: Int)] = []
  var dispatcher: IPCDispatcher?
}

/// A display client's server id, once added.
final class DisplayClient: @unchecked Sendable {
  var id: UInt64 = 0
}

/// Follows the transmitter's link on channel `raw`: the sink and its EDID
/// at once and at each change, and the display's clients told of it.
func follow(_ raw: UInt32, _ link: LinkState, _ dispatcher: IPCDispatcher) {
  var client = DisplayLinkIPC.LinkClient(channel: Handle(raw: raw))
  var first = true
  while true {
    if !first {
      guard let e = try? client.nextEvent() else { return }
      guard case .sinkChanged = e else { continue }
    }
    let sink = try? client.sink()
    let edid = (try? client.edid()) ?? []
    let servers = link.lock.withLock { () -> [UInt64] in
      link.followed = true
      link.connected = sink?.connected ?? true
      link.edid = edid
      if !first { link.changes += 1 }
      return link.clients.map { $0.server }
    }
    if !first {
      print("linlon: the link changed: " + (sink?.connected == false ? "no monitor" : "a monitor"))
      for s in servers { dispatcher.wake(s) }
    }
    first = false
  }
}
