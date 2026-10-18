// SPDX-License-Identifier: BSD-3-Clause

// virtio's transport and split queues against a model of a virtio-blk
// device (M3i): its common configuration as the spec describes it, and
// requests served from the rings in memory (bus addresses are this
// process's addresses here).

import DriverHost
import Node
import Sd
import Sys
import Testing
import Virtio
import VirtioBlk

/// Registers as a dictionary of bytes, with hooks for side effects.
final class ModelWindow: Window {
  var bytes = [UInt8](repeating: 0, count: 64)
  var onWrite: (Int, Int, UInt64) -> Void = { _, _, _ in }
  var onRead: (Int, Int) -> UInt64? = { _, _ in nil }
  func read(_ offset: Int, width: Int) -> UInt64 {
    if let v = onRead(offset, width) { return v }
    return (0..<width).reduce(0) { $0 | UInt64(bytes[offset + $1]) << (8 * UInt64($1)) }
  }
  func write(_ offset: Int, width: Int, _ value: UInt64) {
    for i in 0..<width { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * UInt64(i))) }
    onWrite(offset, width, value)
  }
}

/// A virtio-blk device over `disk`, offering `offer` and refusing
/// FEATURES_OK if the driver accepts anything in `refuse`.
final class ModelBlock {
  let common = ModelWindow(), config = ModelWindow()
  var disk: [UInt8]
  let offer: UInt64
  var refuse: UInt64 = 0
  var driverFeatures: UInt64 = 0
  var queue = (size: 0, desc: UInt64(0), driver: UInt64(0), device: UInt64(0), enabled: false)
  var lastAvailable: UInt16 = 0
  var maxSize = 8

  init(sectors: Int, offer: UInt64) {
    disk = [UInt8](repeating: 0, count: sectors * 512)
    self.offer = offer
    config.write(0, width: 4, UInt64(sectors))
    config.write(20, width: 4, 4096)
    common.write(0x12, width: 2, 1)  // one queue
    common.onRead = { [unowned self] offset, width in
      switch offset {
      case 0x04: return (offer >> (32 * (common.read(0x00, width: 4) & 1))) & 0xFFFF_FFFF
      case 0x18 where width == 2 && !queue.enabled: return UInt64(maxSize)
      default: return nil
      }
    }
    common.onWrite = { [unowned self] offset, _, value in
      switch offset {
      case 0x0C:
        let half = common.read(0x08, width: 4) & 1
        driverFeatures = driverFeatures & ~(0xFFFF_FFFF << (32 * half)) | value << (32 * half)
      case 0x14:
        if value == 0 { queue.enabled = false }
        if value & 8 != 0 && driverFeatures & refuse != 0 { common.bytes[0x14] &= ~8 }
      case 0x18: queue.size = Int(value)
      case 0x20: queue.desc = value
      case 0x28: queue.driver = value
      case 0x30: queue.device = value
      case 0x1C: queue.enabled = value == 1
      default: break
      }
    }
  }

  func at(_ address: UInt64) -> UnsafeMutableRawPointer { UnsafeMutableRawPointer(bitPattern: UInt(address))! }

  /// Serves every request made available since the last call.
  func process() {
    let avail = at(queue.driver)
    let index = avail.load(fromByteOffset: 2, as: UInt16.self)
    while lastAvailable != index {
      let head = avail.load(fromByteOffset: 4 + 2 * (Int(lastAvailable) % queue.size), as: UInt16.self)
      var chain: [(address: UInt64, length: UInt32, write: Bool)] = []
      var d = head
      while true {
        let desc = at(queue.desc + 16 * UInt64(d))
        let flags = desc.load(fromByteOffset: 12, as: UInt16.self)
        chain.append((desc.load(as: UInt64.self), desc.load(fromByteOffset: 8, as: UInt32.self), flags & 2 != 0))
        guard flags & 1 != 0 else { break }
        d = desc.load(fromByteOffset: 14, as: UInt16.self)
      }
      let header = at(chain[0].address)
      let type = header.load(as: UInt32.self), sector = Int(header.load(fromByteOffset: 8, as: UInt64.self))
      var written: UInt32 = 0, status: UInt8 = 0
      var offset = sector * 512
      for b in chain.dropFirst().dropLast() {
        let p = at(b.address)
        for i in 0..<Int(b.length) {
          guard offset + i < disk.count else { status = 1; break }
          if type == Block.read { p.storeBytes(of: disk[offset + i], toByteOffset: i, as: UInt8.self) }
          else { disk[offset + i] = p.load(fromByteOffset: i, as: UInt8.self) }
        }
        offset += Int(b.length)
        if type == Block.read { written += b.length }
      }
      at(chain.last!.address).storeBytes(of: status, as: UInt8.self)
      written += 1
      let used = at(queue.device)
      let usedIndex = used.load(fromByteOffset: 2, as: UInt16.self)
      let entry = 4 + 8 * (Int(usedIndex) % queue.size)
      used.storeBytes(of: UInt32(head), toByteOffset: entry, as: UInt32.self)
      used.storeBytes(of: written, toByteOffset: entry + 4, as: UInt32.self)
      used.storeBytes(of: usedIndex &+ 1, toByteOffset: 2, as: UInt16.self)
      lastAvailable &+= 1
    }
  }
}

@Test func findsCapabilities() {
  // Two vendor capabilities at 0x40 and 0x54, an MSI-X one between.
  var space = [UInt8](repeating: 0, count: 256)
  func cap(_ at: Int, _ kind: UInt8, bar: UInt8, offset: UInt32, length: UInt32, mult: UInt32? = nil) {
    space[at] = 0x09
    space[at + 2] = mult == nil ? 16 : 20
    space[at + 3] = kind
    space[at + 4] = bar
    for i in 0..<4 {
      space[at + 8 + i] = UInt8(truncatingIfNeeded: offset >> (8 * UInt32(i)))
      space[at + 12 + i] = UInt8(truncatingIfNeeded: length >> (8 * UInt32(i)))
      if let mult { space[at + 16 + i] = UInt8(truncatingIfNeeded: mult >> (8 * UInt32(i))) }
    }
  }
  cap(0x40, 1, bar: 4, offset: 0, length: 0x38)
  space[0x50] = 0x11
  cap(0x54, 2, bar: 4, offset: 0x3000, length: 0x1000, mult: 4)
  cap(0x6C, 1, bar: 2, offset: 0, length: 0x38)  // a second common: ignored
  let caps = Capability.find(at: [0x40, 0x50, 0x54, 0x6C]) { space[$0] }
  #expect(caps == [Capability(kind: .common, bar: 4, offset: 0, length: 0x38),
                   Capability(kind: .notify, bar: 4, offset: 0x3000, length: 0x1000, multiplier: 4)])
}

@Test func findsSharedMemoryRegions() {
  // virtio-gpu's host-visible region: type 8, id 1, BAR 4, a 64-bit offset
  // and length (QEMU puts 1 GiB at 4 GiB into the BAR here, as a model).
  var space = [UInt8](repeating: 0, count: 256)
  func put32(_ o: Int, _ v: UInt32) { for i in 0..<4 { space[o + i] = UInt8(truncatingIfNeeded: v >> (8 * i)) } }
  space[0x40] = 0x09; space[0x42] = 24; space[0x43] = 8; space[0x44] = 4; space[0x45] = 1
  put32(0x48, 0); put32(0x4C, 0x4000_0000); put32(0x50, 1); put32(0x54, 0)
  space[0x58] = 0x09; space[0x5A] = 16; space[0x5B] = 1; space[0x5C] = 0  // a common capability: not a region
  let regions = SharedMemoryRegion.find(at: [0x40, 0x58]) { space[$0] }
  #expect(regions == [SharedMemoryRegion(id: 1, bar: 4, offset: 1 << 32, length: 1 << 30)])
}

@Test func negotiatesFeatures() throws {
  let model = ModelBlock(sectors: 64, offer: Feature.version1 | Block.Feature.blockSize | Block.Feature.flush | 1 << 3)
  let device = Device(common: model.common, device: model.config)
  let features = try device.negotiate(Block.Feature.blockSize | Block.Feature.readOnly)
  #expect(features == Feature.version1 | Block.Feature.blockSize)
  #expect(model.driverFeatures == features)
  #expect(device.status == DeviceStatus.acknowledge | DeviceStatus.driver | DeviceStatus.featuresOK)
  let g = Block.geometry(device)
  #expect(g.sectors == 64 && g.blockSize == 4096)

  let legacy = ModelBlock(sectors: 8, offer: Block.Feature.flush)
  #expect(throws: VirtioError.notModern) { try Device(common: legacy.common, device: legacy.config).negotiate(0) }
  let picky = ModelBlock(sectors: 8, offer: Feature.version1 | Block.Feature.flush)
  picky.refuse = Block.Feature.flush
  let d = Device(common: picky.common, device: picky.config)
  #expect(throws: VirtioError.featuresRefused) { try d.negotiate(Block.Feature.flush) }
  #expect(d.status & DeviceStatus.failed != 0)
}

@Test func blockRequestsGoThroughTheRing() throws {
  let model = ModelBlock(sectors: 64, offer: Feature.version1)
  let device = Device(common: model.common, device: model.config)
  _ = try device.negotiate(0)
  let layout = QueueLayout(size: 8)
  #expect(layout.available == 128 && layout.used == 148 && layout.bytes == 148 + 4 + 64)
  let rings = UnsafeMutableRawPointer.allocate(byteCount: layout.bytes, alignment: 4096)
  rings.initializeMemory(as: UInt8.self, repeating: 0, count: layout.bytes)
  defer { rings.deallocate() }
  let bus = UInt64(UInt(bitPattern: rings))
  let queue = SplitQueue(layout: layout, unsafe: rings, busAddress: bus)
  #expect(throws: VirtioError.noSuchQueue(0)) {
    try device.enable(queue: 0, size: 16, descriptors: 0, driver: 0, device: 0)
  }
  _ = try device.enable(queue: 0, size: 8, descriptors: queue.descriptorsAddress, driver: queue.availableAddress,
                        device: queue.usedAddress)
  #expect(model.queue.enabled && model.queue.size == 8)

  // Requests' memory: a header, 512 bytes of data and a status byte each.
  let memory = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 16)
  defer { memory.deallocate() }
  func address(_ p: UnsafeMutableRawPointer) -> UInt64 { UInt64(UInt(bitPattern: p)) }
  func request(_ type: UInt32, sector: UInt64, fill: UInt8?) -> UInt16? {
    memory.copyMemory(from: Block.header(type: type, sector: sector), byteCount: 16)
    if let fill { (memory + 16).initializeMemory(as: UInt8.self, repeating: fill, count: 512) }
    return queue.submit([
      Buffer(address: address(memory), length: 16, deviceWrites: false),
      Buffer(address: address(memory + 16), length: 512, deviceWrites: type == Block.read),
      Buffer(address: address(memory + 528), length: 1, deviceWrites: true),
    ])
  }
  // More requests than the ring's size, one at a time: indices wrap.
  for i in 0..<20 {
    let id = request(Block.write, sector: UInt64(i % 64), fill: UInt8(i))
    #expect(id != nil && queue.freeDescriptors == 5)
    model.process()
    let done = queue.completed()
    #expect(done.count == 1 && done[0].id == id && done[0].written == 1)
    #expect(memory.load(fromByteOffset: 528, as: UInt8.self) == Block.ok)
    #expect(queue.freeDescriptors == 8)
  }
  #expect(model.disk[19 * 512] == 19 && model.disk[19 * 512 + 511] == 19)
  _ = request(Block.read, sector: 7, fill: 0xEE)
  model.process()
  #expect(queue.completed().first?.written == 513)
  #expect((0..<512).allSatisfy { memory.load(fromByteOffset: 16 + $0, as: UInt8.self) == 7 })
  // Past the end: an I/O error.
  _ = request(Block.read, sector: 64, fill: nil)
  model.process()
  _ = queue.completed()
  #expect(memory.load(fromByteOffset: 528, as: UInt8.self) == 1)
  // Too many at once: refused until some complete.
  #expect(request(Block.write, sector: 0, fill: 1) != nil && request(Block.write, sector: 1, fill: 1) != nil)
  #expect(request(Block.write, sector: 2, fill: 1) == nil)
}

/// virtio-input's configuration answers what its select and subsel ask.
@Test func inputConfigurationIsQueried() throws {
  let common = ModelWindow(), config = ModelWindow()
  config.bytes = [UInt8](repeating: 0, count: 136)
  let name = Array("QEMU Virtio Keyboard".utf8)
  config.onWrite = { offset, _, _ in
    guard offset <= 1 else { return }
    let select = config.bytes[0], subsel = config.bytes[1]
    var data: [UInt8] = []
    switch select {
    case Input.idName: data = name
    case Input.idDevids: data = [0x06, 0, 0x27, 0x06, 0x01, 0, 0x01, 0]  // BUS_VIRTUAL, 0x0627, 1, 1
    case Input.eventBits where subsel == 1 || subsel == 0x11 || subsel == 0x14: data = [0xFF]
    default: data = []
    }
    config.bytes[2] = UInt8(data.count)
    for (i, b) in data.enumerated() { config.bytes[8 + i] = b }
  }
  common.onRead = { offset, _ in offset == 0x04 ? (common.bytes[0] == 1 ? 1 : 0) : nil }
  let d = Device(common: common, device: config)
  _ = try d.negotiate(0)
  let id = Input.identity(d)
  #expect(id == Input.Identity(name: "QEMU Virtio Keyboard", bus: 6, vendor: 0x0627, product: 1, version: 1,
                               eventTypes: [0x01, 0x11, 0x14]))
}

@Test func networkConfigurationByFeature() throws {
  let common = ModelWindow(), config = ModelWindow()
  for (i, b) in [0x52, 0x54, 0x00, 0x12, 0x34, 0x56].enumerated() { config.bytes[i] = UInt8(b) }
  config.write(6, width: 2, 1)
  config.write(10, width: 2, 1500)
  common.onRead = { offset, _ in
    offset == 0x04 ? (common.bytes[0] == 1 ? 1 : Network.Feature.mac | Network.Feature.status) : nil
  }
  let d = Device(common: common, device: config)
  _ = try d.negotiate(Network.Feature.mac | Network.Feature.status | Network.Feature.mtu)
  let c = Network.config(d)
  #expect(c == Network.Config(mac: [0x52, 0x54, 0, 0x12, 0x34, 0x56], status: 1, mtu: nil, queuePairs: 1))
  #expect(Network.text(c.mac!) == "52:54:00:12:34:56")
}

/// Memory the model device reads where this process does: bus addresses
/// are addresses.
final class HostMemory: DMAMemory {
  var regions: [UnsafeMutableRawPointer] = []
  func allocate(bytes: Int) throws(Status) -> (pointer: UnsafeMutableRawPointer, bus: UInt64) {
    let p = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 4096)
    p.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
    regions.append(p)
    return (p, UInt64(UInt(bitPattern: p)))
  }
  deinit { for p in regions { p.deallocate() } }
}

/// A request to `disk`, run to its end: the device serves at each
/// notify, and the interrupt's work is done after.
func run(_ disk: VirtioDisk<ModelWindow>, _ op: SdOp, sector: UInt64, _ bytes: inout [UInt8]) -> NodeError?? {
  let result = Locked<NodeError??>(nil)
  bytes.withUnsafeMutableBytes { b in
    disk.start(op, sector: sector, unsafe SectorBuffer(b)) { e in result.withLock { $0 = .some(e) } }
    for _ in 0..<10 where result.withLock({ $0 }) == nil { disk.serviceInterrupt() }
  }
  return result.withLock { $0 }
}

/// The block class's disk over virtio-blk (D106): requests larger than a
/// slot split, more than the slots at once wait their turn, reads come
/// back, a flush ends, and a read-only device refuses writes.
@Test func aVirtioDiskSplitsAndQueuesItsRequests() throws {
  let model = ModelBlock(sectors: 2048, offer: Feature.version1 | Block.Feature.flush)
  let notify = ModelWindow()
  notify.onWrite = { _, _, _ in model.process() }
  let memory = HostMemory()
  let disk = try VirtioDisk(device: Device(common: model.common, device: model.config), notify: notify,
                            multiplier: 0, memory: memory)
  #expect(disk.sectors == 2048 && !disk.readOnly)
  // 300 KiB: three slots' worth, with two slots (a queue of 8).
  var bytes = (0..<(300 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 10) }
  let wrote = run(disk, .write, sector: 8, &bytes)
  #expect(wrote == .some(nil))
  #expect(Array(model.disk[(8 * 512)..<(8 * 512 + bytes.count)]) == bytes)
  var back = [UInt8](repeating: 0, count: bytes.count)
  #expect(run(disk, .read, sector: 8, &back) == .some(nil))
  #expect(back == bytes)
  #expect(disk.requests == 6)
  let flushed = Locked<NodeError??>(nil)
  disk.flush { e in flushed.withLock { $0 = .some(e) } }
  disk.serviceInterrupt()
  #expect(flushed.withLock { $0 } == .some(nil))
  // Past the end, and not whole sectors.
  var tail = [UInt8](repeating: 0, count: 1024)
  #expect(run(disk, .read, sector: 2047, &tail) == .some(.invalid))
  var odd = [UInt8](repeating: 0, count: 100)
  #expect(run(disk, .write, sector: 0, &odd) == .some(.invalid))

  let readOnly = ModelBlock(sectors: 64, offer: Feature.version1 | Block.Feature.readOnly)
  let roNotify = ModelWindow()
  roNotify.onWrite = { _, _, _ in readOnly.process() }
  let ro = try VirtioDisk(device: Device(common: readOnly.common, device: readOnly.config), notify: roNotify,
                          multiplier: 0, memory: memory)
  #expect(ro.readOnly)
  var one = [UInt8](repeating: 1, count: 512)
  #expect(run(ro, .write, sector: 0, &one) == .some(.denied))
}
