// SPDX-License-Identifier: BSD-3-Clause

// The block class over an NVMe controller (NVM Express Base 1.4): its
// first active namespace as a Disk. The controller is taken from firmware
// disabled (§7.6.1: CC.EN off, CSTS.RDY waited for), given its admin
// queues and enabled, identified with its namespace, and given one I/O
// queue pair whose completions raise its interrupt, vector 0. Admin
// commands are polled; I/O commands go through slots of memory the
// controller reaches (a `DMAMemory`), each a bounce region of `chunk`
// bytes (128 KiB, or less if the controller's MDTS says so) and a page
// for its PRP list, as virtio-blk's backend has them. A command's id is
// its slot. A request larger than a chunk takes several slots and ends
// when the last does; one that finds no slot free waits, in order.
//
// Two threads drive it: the dispatcher's starts requests (`start`,
// `flush`), the interrupt's ends them (`serviceInterrupt`). One lock
// covers the I/O queues and the slots; `done` is called after it drops.

import CroiMMIO
import DriverHost
import Node
import Sd
import Sys

enum Nvme {
  static let pageSize = 4096
  static let slotBytes = 131072
  static let slotCount = 16
  static let queueSize = 64

  enum Reg {
    static let cap = 0x00, intMaskSet = 0x0C, intMaskClear = 0x10, cc = 0x14, csts = 0x1C
    static let aqa = 0x24, asq = 0x28, acq = 0x30
  }

  enum Opcode {
    static let flush: UInt8 = 0x00, write: UInt8 = 0x01, read: UInt8 = 0x02
    static let createSQ: UInt8 = 0x01, createCQ: UInt8 = 0x05, identify: UInt8 = 0x06, setFeatures: UInt8 = 0x09
  }

  /// A submission queue and its completion queue: their memory here and
  /// as the controller reaches it, the tail written next, the head read
  /// next and the phase a new completion has.
  struct Queues {
    let id: Int
    let entries: Int
    let submissions: UInt, submissionsBus: UInt64
    let completions: UInt, completionsBus: UInt64
    var tail = 0, head = 0
    var phase: UInt32 = 1

    init(id: Int, entries: Int, memory: DMAMemory) throws(Status) {
      let sq = try unsafe memory.allocate(bytes: entries * 64)
      let cq = try unsafe memory.allocate(bytes: entries * 16)
      self.id = id
      self.entries = entries
      submissions = unsafe UInt(bitPattern: sq.pointer)
      submissionsBus = unsafe sq.bus
      completions = unsafe UInt(bitPattern: cq.pointer)
      completionsBus = unsafe cq.bus
    }

    func doorbell(_ stride: Int, completion: Bool) -> Int { 0x1000 + (2 * id + (completion ? 1 : 0)) * stride }

    /// Writes a 64-byte command at the tail and rings the doorbell.
    mutating func submit(_ regs: borrowing Registers, stride: Int, opcode: UInt8, id cid: UInt16, nsid: UInt32 = 0,
                         prp1: UInt64 = 0, prp2: UInt64 = 0, cdw10: UInt32 = 0, cdw11: UInt32 = 0,
                         cdw12: UInt32 = 0) {
      let at = unsafe UnsafeMutableRawPointer(bitPattern: submissions + UInt(tail * 64))!
      unsafe at.initializeMemory(as: UInt8.self, repeating: 0, count: 64)
      unsafe at.storeBytes(of: UInt32(opcode) | UInt32(cid) << 16, toByteOffset: 0, as: UInt32.self)
      unsafe at.storeBytes(of: nsid, toByteOffset: 4, as: UInt32.self)
      unsafe at.storeBytes(of: prp1, toByteOffset: 24, as: UInt64.self)
      unsafe at.storeBytes(of: prp2, toByteOffset: 32, as: UInt64.self)
      unsafe at.storeBytes(of: cdw10, toByteOffset: 40, as: UInt32.self)
      unsafe at.storeBytes(of: cdw11, toByteOffset: 44, as: UInt32.self)
      unsafe at.storeBytes(of: cdw12, toByteOffset: 48, as: UInt32.self)
      tail = (tail + 1) % entries
      croi_dma_barrier()  // the command before the doorbell that covers it
      regs.store32(doorbell(stride, completion: false), UInt32(tail))
    }

    /// The next completion, if the controller has posted it: its command
    /// id and status (0: success). The head's doorbell is the caller's.
    mutating func complete() -> (id: UInt16, status: UInt16)? {
      let at = unsafe UnsafeRawPointer(bitPattern: completions + UInt(head * 16))!
      let dw3 = unsafe at.load(fromByteOffset: 12, as: UInt32.self)
      guard (dw3 >> 16) & 1 == phase else { return nil }
      croi_dma_barrier()  // the entry after the phase that says it is new
      head += 1
      if head == entries {
        head = 0
        phase ^= 1
      }
      return (UInt16(truncatingIfNeeded: dw3), UInt16(truncatingIfNeeded: dw3 >> 17) & 0x7FFF)
    }
  }

  static func wait(_ nanoseconds: Int64, _ done: () -> Bool) -> Bool {
    let until = Clock.monotonic() + nanoseconds
    while !done() {
      guard Clock.monotonic() < until else { return false }
    }
    return true
  }

  /// What setting up found.
  struct Setup {
    var admin: Queues
    var io: Queues
    var stride: Int
    var model = "", serial = ""
    var namespace: UInt32 = 0
    var sectors: UInt64 = 0
    var sectorSize = 512
    var writeCache = false
    var chunk = slotBytes
  }

  /// An admin command, polled to its end (5 s at most).
  static func admin(_ regs: borrowing Registers, _ s: inout Setup, _ opcode: UInt8, nsid: UInt32 = 0,
                    prp: UInt64 = 0, cdw10: UInt32 = 0, cdw11: UInt32 = 0) throws(Status) {
    s.admin.submit(regs, stride: s.stride, opcode: opcode, id: 0, nsid: nsid, prp1: prp, cdw10: cdw10, cdw11: cdw11)
    var result: (id: UInt16, status: UInt16)?
    let answered = wait(5_000_000_000) {
      result = s.admin.complete()
      return result != nil
    }
    regs.store32(s.admin.doorbell(s.stride, completion: true), UInt32(s.admin.head))
    guard answered else { throw .timedOut }
    guard result?.status == 0 else { throw .io }
  }

  /// Takes the controller from firmware disabled, enables it on new admin
  /// queues, identifies it and its first active namespace (into
  /// `identify`, a page it reaches at `identifyBus`), and makes the I/O
  /// queue pair, its completions on vector 0.
  static func setUp(_ regs: borrowing Registers, memory: DMAMemory, identify: UnsafeRawPointer,
                    identifyBus: UInt64) throws(Status) -> Setup {
    let cap = regs.load64(Reg.cap)
    let timeout = Int64((cap >> 24) & 0xFF) * 500_000_000 + 500_000_000
    guard (cap >> 37) & 1 != 0 else { throw .notSupported }  // the NVM command set
    guard (cap >> 48) & 0xF == 0 else { throw .notSupported }  // 4 KiB pages allowed
    let entries = min(queueSize, Int(cap & 0xFFFF) + 1)

    // Disabled first: firmware's driver may have left it running.
    if regs.load32(Reg.cc) & 1 != 0 { regs.store32(Reg.cc, regs.load32(Reg.cc) & ~1) }
    guard wait(timeout, { regs.load32(Reg.csts) & 1 == 0 }) else { throw .timedOut }

    var s = Setup(admin: try Queues(id: 0, entries: entries, memory: memory),
                  io: try Queues(id: 1, entries: entries, memory: memory), stride: 4 << Int((cap >> 32) & 0xF))
    regs.store32(Reg.aqa, UInt32(entries - 1) << 16 | UInt32(entries - 1))
    regs.store64(Reg.asq, s.admin.submissionsBus)
    regs.store64(Reg.acq, s.admin.completionsBus)
    regs.store32(Reg.intMaskSet, 0xFFFF_FFFF)  // INTx masked while admin commands are polled
    // Enabled: the NVM command set, 4 KiB pages, round robin, 64-byte
    // submissions and 16-byte completions.
    regs.store32(Reg.cc, 6 << 16 | 4 << 20 | 1)
    guard wait(timeout, { regs.load32(Reg.csts) & 3 != 0 }), regs.load32(Reg.csts) & 2 == 0 else { throw .io }

    func byte(_ at: Int) -> UInt8 { unsafe identify.load(fromByteOffset: at, as: UInt8.self) }
    func text(_ at: Int, _ n: Int) -> String {
      var bytes = (0..<n).map { byte(at + $0) }
      while let last = bytes.last, last == 0x20 || last == 0 { bytes.removeLast() }
      return String(decoding: bytes, as: UTF8.self)
    }
    // Identify Controller: its model, serial, transfer limit and cache.
    try admin(regs, &s, Opcode.identify, prp: identifyBus, cdw10: 1)
    s.serial = text(4, 20)
    s.model = text(24, 40)
    if byte(77) != 0 { s.chunk = min(slotBytes, pageSize << Int(byte(77))) }
    s.writeCache = byte(525) & 1 != 0
    // The first active namespace (CNS 2), then its size and format.
    try admin(regs, &s, Opcode.identify, prp: identifyBus, cdw10: 2)
    s.namespace = unsafe identify.load(fromByteOffset: 0, as: UInt32.self)
    guard s.namespace != 0 else { throw .notFound }
    try admin(regs, &s, Opcode.identify, nsid: s.namespace, prp: identifyBus, cdw10: 0)
    s.sectors = unsafe identify.loadUnaligned(fromByteOffset: 0, as: UInt64.self)
    let lbads = byte(128 + 4 * Int(byte(26) & 0xF) + 2)
    guard lbads >= 9, lbads <= 12 else { throw .notSupported }
    s.sectorSize = 1 << Int(lbads)
    // One I/O queue pair, its completions interrupting on vector 0.
    try admin(regs, &s, Opcode.setFeatures, cdw10: 0x07, cdw11: 0)  // Number of Queues: one each
    try admin(regs, &s, Opcode.createCQ, prp: s.io.completionsBus, cdw10: UInt32(entries - 1) << 16 | 1, cdw11: 2 | 1)
    try admin(regs, &s, Opcode.createSQ, prp: s.io.submissionsBus, cdw10: UInt32(entries - 1) << 16 | 1,
              cdw11: 1 << 16 | 1)
    regs.store32(Reg.intMaskClear, 0xFFFF_FFFF)  // INTx unmasked
    return s
  }
}

@safe public final class NvmeDisk: Disk, @unchecked Sendable {
  public let name = "nvme"
  public let sectors: UInt64
  public let sectorSize: Int
  public let readOnly = false
  public let model: String
  public let serial: String
  public let namespace: UInt32
  /// The controller keeps a volatile write cache, which a flush empties.
  public let writeCache: Bool
  public let chunk: Int
  public private(set) var requests = 0
  public private(set) var failures = 0

  let regs: Registers
  let stride: Int
  /// Kept: the queues and slots live as long as it does.
  let memory: DMAMemory
  let lock = Lock()
  var io: Nvme.Queues
  let slotsAddress: UInt, slotsBus: UInt64
  let listsAddress: UInt, listsBus: UInt64
  var freeSlots: [Int]
  var under: [Piece?]
  var waiting: [Piece] = []

  struct Piece {
    var opcode: UInt8
    var sector: UInt64
    var data: SectorBuffer?
    var request: Request
  }

  final class Request: @unchecked Sendable {
    var left: Int
    var failure: NodeIPC.NodeError?
    let done: @Sendable (NodeIPC.NodeError?) -> Void
    init(_ left: Int, _ done: @escaping @Sendable (NodeIPC.NodeError?) -> Void) {
      self.left = left
      self.done = done
    }
  }

  /// Takes the controller over BAR 0's registers (Nvme.setUp).
  public init(_ regs: consuming Registers, memory: DMAMemory) throws(Status) {
    let slots = try unsafe memory.allocate(bytes: Nvme.slotCount * Nvme.slotBytes)
    // A PRP list page a slot, and one more for Identify's data.
    let lists = try unsafe memory.allocate(bytes: (Nvme.slotCount + 1) * Nvme.pageSize)
    let identifyAt = Nvme.slotCount * Nvme.pageSize
    let s = try unsafe Nvme.setUp(regs, memory: memory,
                           identify: unsafe UnsafeRawPointer(lists.pointer + identifyAt),
                           identifyBus: unsafe lists.bus + UInt64(identifyAt))
    slotsAddress = unsafe UInt(bitPattern: slots.pointer)
    slotsBus = unsafe slots.bus
    listsAddress = unsafe UInt(bitPattern: lists.pointer)
    listsBus = unsafe lists.bus
    io = s.io
    stride = s.stride
    model = s.model
    serial = s.serial
    namespace = s.namespace
    sectors = s.sectors
    sectorSize = s.sectorSize
    writeCache = s.writeCache
    chunk = s.chunk
    freeSlots = (0..<Nvme.slotCount).reversed().map { $0 }
    under = [Piece?](repeating: nil, count: Nvme.slotCount)
    self.memory = memory
    self.regs = regs
  }

  func slot(_ i: Int) -> UnsafeMutableRawPointer {
    unsafe UnsafeMutableRawPointer(bitPattern: slotsAddress + UInt(i * Nvme.slotBytes))!
  }

  // MARK: Disk

  public func start(_ op: SdOp, sector: UInt64, _ data: SectorBuffer,
                    done: @escaping @Sendable (NodeIPC.NodeError?) -> Void) {
    let count = UInt64(data.count / sectorSize)
    guard data.count % sectorSize == 0, sector <= sectors, count <= sectors - sector, count > 0 else {
      return done(data.count == 0 ? nil : .invalid)
    }
    let pieces = (data.count + chunk - 1) / chunk
    let request = Request(pieces, done)
    var all: [Piece] = []
    for p in 0..<pieces {
      let at = p * chunk
      let n = min(chunk, data.count - at)
      let part = unsafe SectorBuffer(UnsafeMutableRawBufferPointer(rebasing: data.bytes[at..<(at + n)]))
      all.append(Piece(opcode: op == .read ? Nvme.Opcode.read : Nvme.Opcode.write,
                       sector: sector + UInt64(at / sectorSize), data: part, request: request))
    }
    lock.withLock { for piece in all { submitOrWait(piece) } }
  }

  /// FLUSH where the controller keeps a volatile write cache; without one,
  /// a write is durable when done.
  public func flush(done: @escaping @Sendable (NodeIPC.NodeError?) -> Void) {
    guard writeCache else { return done(nil) }
    let request = Request(1, done)
    lock.withLock { submitOrWait(Piece(opcode: Nvme.Opcode.flush, sector: 0, data: nil, request: request)) }
  }

  func submitOrWait(_ piece: Piece) {
    guard waiting.isEmpty, let i = freeSlots.popLast() else { return waiting.append(piece) }
    send(piece, in: i)
  }

  /// Under the lock: the piece's data into slot `i` (a write), its PRPs
  /// (the slot's first page, then its second or a list of the rest), and
  /// the command, whose id is the slot.
  func send(_ piece: Piece, in i: Int) {
    let bus = slotsBus + UInt64(i * Nvme.slotBytes)
    var prp1: UInt64 = 0, prp2: UInt64 = 0, cdw10: UInt32 = 0, cdw11: UInt32 = 0, cdw12: UInt32 = 0
    if let data = piece.data {
      if piece.opcode == Nvme.Opcode.write {
        unsafe slot(i).copyMemory(from: data.bytes.baseAddress!, byteCount: data.count)
      }
      let pages = (data.count + Nvme.pageSize - 1) / Nvme.pageSize
      prp1 = bus
      if pages == 2 {
        prp2 = bus + UInt64(Nvme.pageSize)
      } else if pages > 2 {
        let list = unsafe UnsafeMutablePointer<UInt64>(bitPattern: listsAddress + UInt(i * Nvme.pageSize))!
        for p in 1..<pages { unsafe list[p - 1] = bus + UInt64(p * Nvme.pageSize) }
        prp2 = listsBus + UInt64(i * Nvme.pageSize)
      }
      cdw10 = UInt32(truncatingIfNeeded: piece.sector)
      cdw11 = UInt32(truncatingIfNeeded: piece.sector >> 32)
      cdw12 = UInt32(data.count / sectorSize - 1)
    }
    under[i] = piece
    io.submit(regs, stride: stride, opcode: piece.opcode, id: UInt16(i), nsid: namespace, prp1: prp1, prp2: prp2,
              cdw10: cdw10, cdw11: cdw11, cdw12: cdw12)
  }

  /// Ends the commands the controller has completed: a read's data copied
  /// out, its slot given to the next waiting, `done` once a request's
  /// last piece is over.
  public func serviceInterrupt() {
    var ended: [Request] = []
    lock.withLock {
      var any = false
      while let c = io.complete() {
        any = true
        let i = Int(c.id)
        guard i < Nvme.slotCount, let piece = under[i] else { continue }
        under[i] = nil
        requests += 1
        if c.status != 0 {
          failures += 1
          if piece.request.failure == nil { piece.request.failure = .io }
        } else if piece.opcode == Nvme.Opcode.read, let data = piece.data {
          unsafe data.bytes.baseAddress!.copyMemory(from: slot(i), byteCount: data.count)
        }
        piece.request.left -= 1
        if piece.request.left == 0 { ended.append(piece.request) }
        if waiting.isEmpty { freeSlots.append(i) } else { send(waiting.removeFirst(), in: i) }
      }
      if any { regs.store32(io.doorbell(stride, completion: true), UInt32(io.head)) }
    }
    for r in ended { r.done(r.failure) }
  }
}
