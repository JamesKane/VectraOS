// SPDX-License-Identifier: BSD-3-Clause

// The block class over virtio-blk (D106; Virtual I/O Device 1.2 §5.2),
// after todhchai's backend (M3i), which did one request at a time: a Disk
// whose requests go through queue 0 several at once, each in a slot of
// memory the device reaches (a `DMAMemory`): its 16-byte header, its
// status byte, and a bounce region of `chunk` bytes its data is copied
// through. A request larger than a chunk takes several slots, and ends
// when the last of them does. A request that finds every slot taken waits,
// in order, for one to come free.
//
// Two threads drive it: the dispatcher's starts requests (`start`,
// `flush`), and the interrupt's ends them (`serviceInterrupt`): the used
// ring names each by its header's bus address, which is its slot's.
// One lock covers the queue and the slots; `done` is called after it
// drops.

import DriverHost
import Node
import Sd
import Sys
import Virtio

@safe public final class VirtioDisk<W: Window>: Disk, @unchecked Sendable {
  public let name: String
  public let sectors: UInt64
  public let sectorSize = Block.sectorSize
  public let readOnly: Bool
  public let features: UInt64
  /// Bytes a slot's bounce region holds: a ring entry's (D103).
  public static var chunk: Int { 131072 }
  static var slotHeader: Int { 32 }

  let device: Device<W>
  let notify: W
  let notifyAt: Int
  let queue: SplitQueue
  /// Kept: the rings and the slots live as long as it does.
  let memory: DMAMemory
  let lock = Lock()
  /// The slots' memory, here and as the device reaches it: each slot the
  /// header (16 bytes), the status (1) at 16, and the chunk at 32.
  let slotsAddress: UInt
  let slotsBus: UInt64
  let slotCount: Int
  var freeSlots: [Int]
  /// What each slot carries, while it is under way.
  var under: [Piece?]
  /// Requests that found no slot, in order.
  var waiting: [Piece] = []
  public private(set) var requests = 0
  public private(set) var failures = 0

  /// A request's part in one slot: what to do, where its data is, and the
  /// request it is a part of.
  struct Piece {
    var type: UInt32
    var sector: UInt64
    var data: SectorBuffer?
    var request: Request
  }

  /// A request: how many of its pieces are still under way, its first
  /// failure, and what to call at its end.
  final class Request: @unchecked Sendable {
    var left: Int
    var failure: NodeIPC.NodeError?
    let done: @Sendable (NodeIPC.NodeError?) -> Void
    init(_ left: Int, _ done: @escaping @Sendable (NodeIPC.NodeError?) -> Void) {
      self.left = left
      self.done = done
    }
  }

  /// Negotiates, sets up queue 0 (`queueSize` entries, at most the
  /// device's) and a slot for each request it can hold (three descriptors
  /// a request), and sets DRIVER_OK. `notify` is the notify capability's
  /// window; `multiplier` its notify_off_multiplier.
  public init(device: Device<W>, notify: W, multiplier: UInt32, memory: DMAMemory, queueSize: Int = 128,
              vector: UInt16 = Device<W>.noVector, name: String = "virtio-blk") throws(Status)
  {
    self.device = device
    self.notify = notify
    self.memory = memory
    self.name = name
    do throws(VirtioError) {
      features = try device.negotiate(Block.Feature.blockSize | Block.Feature.flush | Block.Feature.readOnly)
    } catch {
      throw .notSupported
    }
    readOnly = features & Block.Feature.readOnly != 0
    sectors = Block.geometry(device).sectors
    var size = min(queueSize, device.queueSize(0))
    while size & (size - 1) != 0 { size &= size - 1 }  // a power of two
    guard size >= 3 else { throw .notSupported }
    let layout = QueueLayout(size: size)
    let rings = try unsafe memory.allocate(bytes: layout.bytes)
    queue = unsafe SplitQueue(layout: layout, unsafe: rings.pointer, busAddress: rings.bus)
    slotCount = min(size / 3, 16)
    let stride = Self.slotHeader + Self.chunk
    let region = try unsafe memory.allocate(bytes: slotCount * stride)
    slotsAddress = unsafe UInt(bitPattern: region.pointer)
    slotsBus = unsafe region.bus
    freeSlots = (0..<slotCount).reversed().map { $0 }
    under = [Piece?](repeating: nil, count: slotCount)
    let offset: Int
    do throws(VirtioError) {
      offset = try device.enable(queue: 0, size: size, descriptors: queue.descriptorsAddress,
                                 driver: queue.availableAddress, device: queue.usedAddress, vector: vector)
    } catch {
      throw .notSupported
    }
    notifyAt = offset * Int(multiplier)
    device.set(status: device.status | DeviceStatus.driverOK)
  }

  var stride: Int { Self.slotHeader + Self.chunk }

  func slot(_ i: Int) -> UnsafeMutableRawPointer {
    unsafe UnsafeMutableRawPointer(bitPattern: slotsAddress + UInt(i * stride))!
  }

  // MARK: Disk

  public func start(_ op: SdOp, sector: UInt64, _ data: SectorBuffer,
                    done: @escaping @Sendable (NodeIPC.NodeError?) -> Void) {
    let count = UInt64(data.count / sectorSize)
    guard data.count % sectorSize == 0, sector <= sectors, count <= sectors - sector, count > 0 else {
      return done(data.count == 0 ? nil : .invalid)
    }
    if op == .write && readOnly { return done(.denied) }
    let pieces = (data.count + Self.chunk - 1) / Self.chunk
    let request = Request(pieces, done)
    var all: [Piece] = []
    for p in 0..<pieces {
      let at = p * Self.chunk
      let n = min(Self.chunk, data.count - at)
      let part = unsafe SectorBuffer(UnsafeMutableRawBufferPointer(rebasing: data.bytes[at..<(at + n)]))
      all.append(Piece(type: op == .read ? Block.read : Block.write, sector: sector + UInt64(at / sectorSize),
                       data: part, request: request))
    }
    lock.withLock { for piece in all { submitOrWait(piece) } }
  }

  /// FLUSH if the device keeps a write cache (§5.2.6.2): it makes durable
  /// the writes it has completed, which are the ones answered. Without
  /// one, writes are durable when done.
  public func flush(done: @escaping @Sendable (NodeIPC.NodeError?) -> Void) {
    guard features & Block.Feature.flush != 0 else { return done(nil) }
    let request = Request(1, done)
    lock.withLock { submitOrWait(Piece(type: Block.flush, sector: 0, data: nil, request: request)) }
  }

  /// Under the lock: `piece` into a free slot and onto the queue, or to
  /// wait for one.
  func submitOrWait(_ piece: Piece) {
    guard waiting.isEmpty, let i = freeSlots.popLast() else { return waiting.append(piece) }
    submit(piece, in: i)
  }

  func submit(_ piece: Piece, in i: Int) {
    let s = unsafe slot(i)
    let bus = slotsBus + UInt64(i * stride)
    let header = Block.header(type: piece.type, sector: piece.sector)
    unsafe header.withUnsafeBytes { unsafe s.copyMemory(from: $0.baseAddress!, byteCount: 16) }
    unsafe s.storeBytes(of: UInt8(0xFF), toByteOffset: 16, as: UInt8.self)
    var buffers = [Buffer(address: bus, length: 16, deviceWrites: false)]
    if let data = piece.data {
      if piece.type == Block.write {
        unsafe (s + Self.slotHeader).copyMemory(from: data.bytes.baseAddress!, byteCount: data.count)
      }
      buffers.append(Buffer(address: bus + UInt64(Self.slotHeader), length: UInt32(data.count),
                            deviceWrites: piece.type == Block.read))
    }
    buffers.append(Buffer(address: bus + 16, length: 1, deviceWrites: true))
    under[i] = piece
    guard queue.submit(buffers) != nil else {
      // Three descriptors a slot: the queue always has room for a slot's.
      under[i] = nil
      freeSlots.append(i)
      piece.request.failure = .io
      return
    }
    notify.write(notifyAt, width: 2, 0)
  }

  /// Ends the requests the device has finished: each one's data copied
  /// out of its slot if it read, its slot given to the next waiting, and
  /// its `done` called once its last piece is over.
  public func serviceInterrupt() {
    var ended: [Request] = []
    lock.withLock {
      for c in queue.completed() {
        let i = Int((c.address - slotsBus) / UInt64(stride))
        guard i >= 0, i < slotCount, let piece = under[i] else { continue }
        under[i] = nil
        let s = unsafe slot(i)
        let status = unsafe s.load(fromByteOffset: 16, as: UInt8.self)
        requests += 1
        if status != Block.ok {
          failures += 1
          if piece.request.failure == nil { piece.request.failure = status == 2 ? .unsupported : .io }
        } else if piece.type == Block.read, let data = piece.data {
          unsafe data.bytes.baseAddress!.copyMemory(from: s + Self.slotHeader, byteCount: data.count)
        }
        piece.request.left -= 1
        if piece.request.left == 0 { ended.append(piece.request) }
        if waiting.isEmpty {
          freeSlots.append(i)
        } else {
          submit(waiting.removeFirst(), in: i)
        }
      }
    }
    for r in ended { r.done(r.failure) }
  }
}
