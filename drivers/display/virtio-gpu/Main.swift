// SPDX-License-Identifier: BSD-3-Clause

// bin/virtio-gpu (D120, after todhchai's): the driver host for a virtio
// GPU (Virtual I/O Device 1.2 §5.7), its 2D part, serving the display
// class (`DisplayDeviceIPC.Display`, version 2):
//
// - outputs: GET_DISPLAY_INFO's scanouts, and GET_EDID's bytes;
// - attach: a 2D resource (B8G8R8X8) over the client's VMO, its pages
//   pinned through the BTI as the resource's backing;
// - show: SET_SCANOUT; flush: TRANSFER_TO_HOST_2D, then RESOURCE_FLUSH,
//   for each damaged rectangle;
// - outputsChanged: the device's VIRTIO_GPU_EVENT_DISPLAY, from its
//   configuration change interrupt, to every client.
//
// One request at a time on the control queue, each a request the device
// reads and a response it writes, in pinned memory; the dispatcher's
// thread is the only one that sends. The interrupt's thread acks each
// interrupt, harvests the queue's answers (finishing fences, Context3D.swift)
// and adds to a counter, which `send` waits on; a display event in the
// configuration wakes each client's server, which sends the event. The
// queue is under one lock: the dispatcher submits, both threads harvest.
// With virgl, blobs and context init offered (D121), it also serves the GPU
// class (`gpu`).

import DisplayDevice
import DriverHost
import GPUDevice
import IPC
import Node
import Sys
import Virtio
import VirtioGPU

/// An attached image: its resource, size, and the pinned VMO under it.
final class Image {
  let id: UInt32
  let width: UInt32
  let height: UInt32
  let vmo: Handle
  let pmt: UInt32
  init(id: UInt32, width: UInt32, height: UInt32, vmo: consuming Handle, pmt: UInt32) {
    self.id = id
    self.width = width
    self.height = height
    self.vmo = vmo
    self.pmt = pmt
  }
  deinit { try? DMA.unpin(pmt: pmt) }
}

/// What the interrupt's thread and the dispatcher's share.
final class Shared: @unchecked Sendable {
  let lock = Lock()
  /// Display events seen, and those each client was told of.
  var events = 0
  var clients: [(server: UInt64, told: Int)] = []
  var interrupts = 0
}

/// The device, as the dispatcher's thread drives it.
@safe final class GPUDevice: DisplayDeviceIPC.DisplayHandler, @unchecked Sendable {
  let queue: SplitQueue
  let pci: PCIDevice
  let notifyAt: Int
  let bti: Handle
  /// Raised by the interrupt's thread at each interrupt.
  let bell: UInt32
  /// Request area (device reads) and response area (device writes).
  let request: (address: UInt, bus: UInt64, size: Int)
  let response: (address: UInt, bus: UInt64, size: Int)
  let hasEDID: Bool
  var images: [Image] = []
  var nextID: UInt32 = 1
  var scanouts: [(rect: GPU.Rect, enabled: Bool)] = []
  /// What each scanout shows, as `show` and `present` set it.
  var showing = [UInt32](repeating: 0, count: GPU.maxScanouts)
  var failures = 0, flushes = 0
  /// The queue, `answered` and the fences, both threads' (see above).
  let lock = Lock()
  /// Whether the request in the request area has been answered.
  var answered = false
  // The 3D side (Context3D.swift).
  static let slotSize = 128, slotCount = 24
  /// Fence requests (at 0) and their answers (at 64), a slot each.
  let slab: (address: UInt, bus: UInt64)
  var fences = [FenceSlot?](repeating: nil, count: GPUDevice.slotCount)
  var nextFence: UInt64 = 1
  var has3D = false
  var capsets: [(id: UInt32, bytes: [UInt8])] = []
  /// The host-visible region, physically, and the BAR's resource it is in.
  var region: (base: UInt64, size: UInt64)?
  var barRaw: UInt32 = 0
  var windows: [(offset: UInt64, size: UInt64)] = []
  var watched: [WatchedWindow] = []
  var nextWatch: UInt64 = 1
  var nextContext: UInt32 = 1
  var contexts = 0, blobs = 0, submits = 0
  var dispatcher: IPCDispatcher?

  init(queue: SplitQueue, pci: PCIDevice, notifyAt: Int, bti: consuming Handle, bell: UInt32,
       request: (UInt, UInt64, Int), response: (UInt, UInt64, Int), slab: (UInt, UInt64), hasEDID: Bool)
  {
    self.queue = queue
    self.pci = pci
    self.notifyAt = notifyAt
    self.bti = bti
    self.bell = bell
    self.request = request
    self.response = response
    self.slab = slab
    self.hasEDID = hasEDID
  }

  /// The device's answers: the request area's, and fences'. Any thread.
  func harvest() {
    lock.withLock {
      for c in queue.completed() {
        if c.address == request.bus {
          answered = true
        } else if c.address >= slab.bus, c.address < slab.bus + UInt64(Self.slotCount * Self.slotSize) {
          completeFence(Int((c.address - slab.bus) / UInt64(Self.slotSize)))
        }
      }
    }
  }

  /// Harvests, waits for the next interrupt (at most 1 ms: a lost one
  /// costs a poll), harvests again; false past `deadline`.
  func waitForInterrupt(deadline: Int64) -> Bool {
    harvest()
    let b = Handle(raw: bell)  // borrowed
    let rung = (try? Counter.read(b)) ?? 0
    _ = try? Counter.wait(b, until: rung + 1, deadline: min(deadline, Clock.monotonic() + 1_000_000))
    _ = b.release()
    harvest()
    return Clock.monotonic() < deadline
  }

  /// Puts `buffers` on the control queue and tells the device.
  func submit(_ buffers: [Buffer]) -> Bool {
    let ok = lock.withLock { queue.submit(buffers) != nil }
    if ok { pci.notify(queue: GPU.controlQueue, offset: notifyAt) }
    return ok
  }

  /// One request and its response (`size` bytes of it).
  func send(_ bytes: [UInt8], response size: Int) throws(Status) -> [UInt8] {
    guard bytes.count <= request.size, size <= response.size else { throw .outOfRange }
    lock.withLock { answered = false }
    let base = unsafe UnsafeMutableRawPointer(bitPattern: request.address)!
    bytes.withUnsafeBytes { unsafe base.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
    guard submit([Buffer(address: request.bus, length: UInt32(bytes.count), deviceWrites: false),
                  Buffer(address: response.bus, length: UInt32(size), deviceWrites: true)])
    else { throw .noResources }
    let deadline = Clock.monotonic() + 1_000_000_000
    while !lock.withLock({ answered }) && waitForInterrupt(deadline: deadline) {}
    guard lock.withLock({ answered }) else { throw .timedOut }
    let out = unsafe UnsafeRawPointer(bitPattern: response.address)!
    return (0..<size).map { unsafe out.load(fromByteOffset: $0, as: UInt8.self) }
  }

  /// A request answered OK_NODATA.
  func command(_ bytes: [UInt8]) throws(DisplayDeviceIPC.DisplayError) {
    guard let r = try? send(bytes, response: GPU.headerSize), GPU.responseType(r) == GPU.Response.okNoData else {
      failures += 1
      throw .unavailable
    }
  }

  func readScanouts() {
    if let r = try? send(GPU.getDisplayInfo(), response: GPU.displayInfoSize), let modes = GPU.displayInfo(r) {
      scanouts = modes
    }
  }

  // DisplayDeviceIPC.Display

  func outputs() -> [DisplayDeviceIPC.Output] {
    readScanouts()
    return scanouts.enumerated().filter { $0.element.enabled || $0.offset == 0 }.map { (i, s) in
      // virtio-gpu says no refresh: QEMU's is 60 Hz.
      DisplayDeviceIPC.Output(id: UInt32(i), width: s.rect.width, height: s.rect.height, enabled: s.enabled,
                              refresh: 60_000)
    }
  }

  /// The one mode the host gives a scanout, its size now: the host's
  /// window decides it, not the guest.
  func modes(output: UInt32) throws(DisplayDeviceIPC.DisplayError) -> [DisplayDeviceIPC.Mode] {
    guard let o = outputs().first(where: { $0.id == output }) else { throw .notFound }
    return [DisplayDeviceIPC.Mode(width: o.width, height: o.height, refresh: o.refresh, clock: 0)]
  }

  func setMode(output: UInt32, mode: DisplayDeviceIPC.Mode) throws(DisplayDeviceIPC.DisplayError) {
    guard try modes(output: output).contains(mode) else { throw .invalid }
  }

  func edid(output: UInt32) throws(DisplayDeviceIPC.DisplayError) -> [UInt8] {
    guard hasEDID else { return [] }
    guard let r = try? send(GPU.getEDID(scanout: output), response: GPU.edidSize), let e = GPU.edid(r) else {
      throw .notFound
    }
    return e
  }

  func attach(vmo: consuming Handle, width: UInt32, height: UInt32) throws(DisplayDeviceIPC.DisplayError) -> UInt32 {
    guard width > 0, height > 0, width <= 16384, height <= 16384 else { throw .invalid }
    let bytes = (Int(width) * Int(height) * 4 + 4095) & ~4095
    guard let size = try? VMO.size(vmo), size >= bytes else { throw .invalid }
    let pinned: (pmt: UInt32, addresses: [UInt64])
    do throws(Status) {
      pinned = try DMA.pin(bti, vmo, offset: 0, size: bytes, options: [.read], count: bytes / 4096)
    } catch {
      throw .unavailable
    }
    let id = nextID
    nextID += 1
    do throws(DisplayDeviceIPC.DisplayError) {
      try command(GPU.createResource(id: id, width: width, height: height))
      try command(GPU.attachBacking(resource: id, pages: pinned.addresses, page: 4096))
    } catch {
      try? DMA.unpin(pmt: pinned.pmt)
      throw error
    }
    images.append(Image(id: id, width: width, height: height, vmo: vmo, pmt: pinned.pmt))
    return id
  }

  func detach(image: UInt32) {
    guard let i = images.firstIndex(where: { $0.id == image }) else { return }
    try? command(GPU.detachBacking(resource: image))
    try? command(GPU.unref(id: image))
    for o in showing.indices where showing[o] == image { showing[o] = 0 }
    images.remove(at: i)  // unpins
  }

  func show(output: UInt32, image: UInt32) throws(DisplayDeviceIPC.DisplayError) {
    guard Int(output) < GPU.maxScanouts else { throw .notFound }
    if image == 0 {
      try command(GPU.setScanout(output, resource: 0, GPU.Rect(x: 0, y: 0, width: 0, height: 0)))
      showing[Int(output)] = 0
      return
    }
    guard let img = images.first(where: { $0.id == image }) else { throw .notFound }
    try command(GPU.setScanout(output, resource: image, GPU.Rect(x: 0, y: 0, width: img.width, height: img.height)))
    showing[Int(output)] = image
  }

  func flush(image: UInt32, damage: [DisplayDeviceIPC.Area]) throws(DisplayDeviceIPC.DisplayError) {
    guard let img = images.first(where: { $0.id == image }) else { throw .notFound }
    for r in clipped(img, damage) {
      try command(GPU.transferToHost(resource: image, r, stride: img.width * 4))
      try command(GPU.flush(resource: image, r))
    }
    flushes += 1
  }

  /// The damage to the host, then the image on the scanout if it wasn't
  /// there, which the host then shows whole.
  func present(output: UInt32, image: UInt32, damage: [DisplayDeviceIPC.Area]) throws(DisplayDeviceIPC.DisplayError) {
    guard Int(output) < GPU.maxScanouts else { throw .notFound }
    guard let img = images.first(where: { $0.id == image }) else { throw .notFound }
    if showing[Int(output)] == image { return try flush(image: image, damage: damage) }
    for r in clipped(img, damage) { try command(GPU.transferToHost(resource: image, r, stride: img.width * 4)) }
    let whole = GPU.Rect(x: 0, y: 0, width: img.width, height: img.height)
    try command(GPU.setScanout(output, resource: image, whole))
    showing[Int(output)] = image
    try command(GPU.flush(resource: image, whole))
    flushes += 1
  }

  /// `damage` clipped to the image (none: the whole image).
  func clipped(_ img: Image, _ damage: [DisplayDeviceIPC.Area]) -> [GPU.Rect] {
    let whole = DisplayDeviceIPC.Area(x: 0, y: 0, width: img.width, height: img.height)
    var out: [GPU.Rect] = []
    for d in damage.isEmpty ? [whole] : damage {
      guard d.x < img.width, d.y < img.height else { continue }
      let r = GPU.Rect(x: d.x, y: d.y, width: min(d.width, img.width - d.x), height: min(d.height, img.height - d.y))
      if r.width > 0, r.height > 0 { out.append(r) }
    }
    return out
  }
}

/// A client of `display`: its server's id, once added.
final class Client: @unchecked Sendable {
  var id: UInt64 = 0
}

@main struct VirtioGPUDriver {
  static func main() {
    let start = Startup.current
    var resources = DeviceResources(take: { start.take($0)?.release() })
    var lines: [String] = []
    let shared = Shared()
    var gpu: GPUDevice?
    // The rings and buffers live as long as the device uses them.
    var memory: PinnedMemory?
    do throws(Status) {
      guard let bti = resources.takeBTI() else { throw Status.notFound }
      let pci = try PCIDevice(resources)
      let irq = try pci.interrupt(resources)
      lines.append("interrupt \(irq.msix ? "MSI-X" : "INTx")")
      let device = pci.device
      let features: UInt64
      // 3D needs virgl, blobs and context init together (D121).
      let threeD = GPU.Feature.virgl | GPU.Feature.resourceBlob | GPU.Feature3D.contextInit
      do throws(VirtioError) { features = try device.negotiate(GPU.Feature.edid | threeD) } catch {
        throw Status.notSupported
      }
      guard features & Feature.accessPlatform != 0 else {
        lines.append("the device bypasses the IOMMU (no ACCESS_PLATFORM)")
        throw Status.notSupported
      }
      // Display events come on the configuration's vector: the queue's.
      if irq.msix { device.setConfigVector(0) }
      let config = GPU.config(device)
      guard pci.notify != nil, let isr = pci.isr else { throw Status.notSupported }
      let pinned = PinnedMemory(bti: try bti.duplicate())
      memory = pinned
      let size = device.queueSize(most: 64, [GPU.controlQueue])
      let (q, at) = try device.makeQueue(GPU.controlQueue, size: size, memory: pinned, vector: irq.vector)
      // Requests up to 256 KiB (a 4K screen's backing list), responses 4 KiB.
      let req = try unsafe pinned.allocate(bytes: 256 * 1024), resp = try unsafe pinned.allocate(bytes: 4096)
      let slab = try unsafe pinned.allocate(bytes: GPUDevice.slotCount * GPUDevice.slotSize)
      device.set(status: device.status | DeviceStatus.driverOK)
      let bellRaw = try Counter.create().release()
      // The interrupt's own thread: each interrupt acked and counted, and a
      // display event told to every client.
      let port = try Port.create(bindToInterrupt: true)
      try Interrupt.bind(irq.handle, port: port, key: 1)
      let portRaw = port.release(), irqRaw = irq.handle.raw, msix = irq.msix
      let g = unsafe GPUDevice(queue: q, pci: pci, notifyAt: at, bti: bti, bell: bellRaw,
                               request: (UInt(bitPattern: req.pointer), req.bus, 256 * 1024),
                               response: (UInt(bitPattern: resp.pointer), resp.bus, 4096),
                               slab: (UInt(bitPattern: slab.pointer), slab.bus),
                               hasEDID: features & GPU.Feature.edid != 0)
      gpu = g
      _ = try Thread.spawn {
        let p = Handle(raw: portRaw), i = Handle(raw: irqRaw), b = Handle(raw: bellRaw)
        while true {
          // While fences are in flight, a harvest every 5 ms too: with
          // nothing else on the device, a fence's answer was seen to wait
          // for the next interrupt (a Venus ring's teardown ran out its 10 s).
          let pending = g.lock.withLock { g.fences.contains { $0 != nil } }
          _ = try? Port.wait(p, deadline: pending ? Clock.monotonic() + 5_000_000 : infiniteDeadline)
          if !msix { _ = isr.read(0, width: 1) }  // lowers INTx
          try? Interrupt.ack(i)
          // A display event: cleared, and told.
          if UInt32(truncatingIfNeeded: device.config(0, width: 4)) & GPU.displayEvent != 0 {
            device.setConfig(4, width: 4, UInt64(GPU.displayEvent))
            let servers = shared.lock.withLock { () -> [UInt64] in
              shared.events += 1
              return shared.clients.map { $0.server }
            }
            if let d = GPUHost.dispatcher { for s in servers { d.wake(s) } }
          }
          shared.lock.withLock { shared.interrupts += 1 }
          // Answers in: fences finished, and `send` woken.
          g.harvest()
          try? Counter.add(b, 1)
        }
      }.release()
      g.readScanouts()
      let enabled = g.scanouts.filter { $0.enabled }.map { "\($0.rect.width)x\($0.rect.height)" }
      lines.append("scanouts \(config.scanouts)\(g.hasEDID ? ", edid" : ""); enabled: "
        + (enabled.isEmpty ? "none" : enabled.joined(separator: " ")))
      // 3D: the capsets, and the host-visible region blobs are mapped into.
      if features & threeD == threeD, let shm = pci.sharedMemory.first(where: { $0.id == GPU.hostVisibleRegion }) {
        let info = try resources.bar(Int(shm.bar))
        g.barRaw = try resources.borrowedBAR(Int(shm.bar)) { (h: borrowing Handle) throws(Status) in try h.duplicate() }.release()
        g.region = (info.base + shm.offset, shm.length)
        g.windows = [(0, shm.length)]
        for i in 0..<config.capsets {
          guard let r = try? g.send(GPU.getCapsetInfo(index: i), response: GPU.capsetInfoSize), let c = GPU.capsetInfo(r),
            Int(c.maxSize) + GPU.headerSize <= 4096,
            let data = try? g.send(GPU.getCapset(id: c.id, version: c.maxVersion), response: GPU.headerSize + Int(c.maxSize)),
            let bytes = GPU.capset(data, size: Int(c.maxSize))
          else { continue }
          g.capsets.append((c.id, bytes))
        }
        g.has3D = !g.capsets.isEmpty
        lines.append("3D: capsets \(g.capsets.map { "\($0.id)" }.joined(separator: " ")), host-visible "
          + "\(shm.length >> 20) MiB at BAR \(shm.bar)")
      }
    } catch {
      lines.append("FAILED: status \(error.rawValue)")
    }
    print("virtio-gpu: " + lines.joined(separator: "; "))

    do throws(Status) {
      let dispatcher = try IPCDispatcher()
      GPUHost.dispatcher = dispatcher
      let tree = NodeTree(dispatcher: dispatcher)
      let status = lines.joined(separator: "\n") + "\n"
      tree.text("status", read: {
        let (events, interrupts) = shared.lock.withLock { (shared.events, shared.interrupts) }
        return status + "images \(gpu?.images.count ?? 0) flushes \(gpu?.flushes ?? 0) failures \(gpu?.failures ?? 0)\n"
          + "display events \(events) interrupts \(interrupts)\n"
          + (gpu?.has3D == true ? "contexts \(gpu?.contexts ?? 0) blobs \(gpu?.blobs ?? 0) submits \(gpu?.submits ?? 0)\n" : "")
      })
      if let gpu {
        gpu.dispatcher = dispatcher
        // The GPU class (D121), beside the display's.
        if gpu.has3D {
          tree.service("gpu") { (channel: consuming Handle) throws(Status) in
            try dispatcher.add(GPUDeviceIPC.DeviceServer(channel: channel, impl: GPUDeviceSession(gpu: gpu)))
          }
        }
        tree.service("display") { (channel: consuming Handle) throws(Status) in
          let c = Client()
          let told = shared.lock.withLock { shared.events }
          c.id = try dispatcher.add(DisplayDeviceIPC.DisplayServer(channel: channel, impl: gpu)) {
            (s: inout DisplayDeviceIPC.DisplayServer<GPUDevice>) throws(IPCError<Never>) in
            let tell = shared.lock.withLock { () -> Bool in
              guard let i = shared.clients.firstIndex(where: { $0.server == c.id }), shared.clients[i].told != shared.events
              else { return false }
              shared.clients[i].told = shared.events
              return true
            }
            if tell { try DisplayDeviceIPC.DisplayEventSender.sendOutputsChanged(on: s.connection) }
          }
          shared.lock.withLock { shared.clients.append((c.id, told)) }
        }
      }
      guard let export = start.export() else { Process.exit(code: 2) }
      try tree.serve(export)
      try dispatcher.run()
    } catch {
      Process.exit(code: 1)
    }
    _ = consume resources
    withExtendedLifetime(memory) {}
  }
}

/// What the interrupt's thread reaches once the dispatcher is made.
enum GPUHost {
  nonisolated(unsafe) static var dispatcher: IPCDispatcher?
}
