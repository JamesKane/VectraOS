// SPDX-License-Identifier: BSD-3-Clause

// The kernel's objects as V1 left them (docs/syscall-audit.md §4): no
// events, eventpairs, sockets, timers, clock objects or display timelines
// (counters and the port's deadline replace them, D23-D27), no VMO reads
// or writes (a mapping, D37), and every wait a binding to a port
// (object_bind, D20). Layouts are the headers' (D45).

import Synchronization

/// Channels: two ends, messages of bytes and handles.
public enum Channel {
  public static var maxBytes: Int { Int(CROI_CHANNEL_MAX_BYTES) }
  public static var maxHandles: Int { Int(CROI_CHANNEL_MAX_HANDLES) }

  public static func create() throws(Status) -> Ends {
    let (a, b) = try Kernel.channelCreate()
    return Ends(a: Handle(raw: a), b: Handle(raw: b))
  }

  /// A message read from a channel; its handles are now this process's.
  public struct Message: Sendable {
    public var bytes: [UInt8]
    public var handles: [UInt32]
    public init(bytes: [UInt8], handles: [UInt32]) {
      self.bytes = bytes
      self.handles = handles
    }
  }

  /// Writes a message, moving `handles` into it (they are consumed even on
  /// failure).
  public static func write(_ channel: borrowing Handle, bytes: [UInt8], handles: [UInt32] = []) throws(Status) {
    try Kernel.channelWrite(channel.raw, bytes, handles)
  }

  /// Reads the next message, or throws `shouldWait` if there is none.
  public static func read(_ channel: borrowing Handle) throws(Status) -> Message {
    try Kernel.channelRead(channel.raw)
  }

  /// An item's buffer address: `offset` bytes into `base`, or 0 for an
  /// empty buffer (whose base may be nil).
  static func itemAddress(_ base: UnsafeRawPointer?, _ offset: Int) -> UInt64 {
    guard let base = unsafe base else { return 0 }
    return unsafe UInt64(UInt(bitPattern: base + offset))
  }

  /// A message for `write(_:)`'s array, and how its write went.
  public struct Outgoing: Sendable {
    public var channel: UInt32
    public var bytes: [UInt8]
    public var handles: [UInt32]
    /// After the write: `.ok`, or why this one failed.
    public var status: Status = .ok

    public init(channel: UInt32, bytes: [UInt8], handles: [UInt32] = []) {
      self.channel = channel
      self.bytes = bytes
      self.handles = handles
    }
  }

  /// channel_write's array (D41): one message to each item's channel,
  /// CROI_CHANNEL_MAX_ITEMS to a call, going on past one that fails; each
  /// item's status set, and how many succeeded. A server replies to every
  /// request it read at once. Every item's handles are consumed, as
  /// `write`'s are, even when the call throws.
  @discardableResult
  public static func write(_ items: inout [Outgoing]) throws(Status) -> Int {
    var done = 0
    var start = 0
    while start < items.count {
      let end = Swift.min(start + Int(CROI_CHANNEL_MAX_ITEMS), items.count)
      do throws(Status) {
        done += try writeChunk(&items, start..<end)
      } catch {
        // Nothing of this chunk or the rest was taken: close their handles.
        for i in start..<items.count { for h in items[i].handles { Sys.close(raw: h) } }
        throw error
      }
      start = end
    }
    return done
  }

  /// One channel_write: the chunk's messages copied into one buffer each
  /// for bytes and handles, which the items point into for the call.
  static func writeChunk(_ items: inout [Outgoing], _ chunk: Range<Int>) throws(Status) -> Int {
    var bytes: [UInt8] = []
    var handles: [UInt32] = []
    for i in chunk {
      bytes.append(contentsOf: items[i].bytes)
      handles.append(contentsOf: items[i].handles)
    }
    var raw = [ChannelWriteItem](repeating: ChannelWriteItem(), count: chunk.count)
    let r = unsafe bytes.withUnsafeBytes { b in
      unsafe handles.withUnsafeBufferPointer { h in
        var byteOffset = 0, handleOffset = 0
        for (k, i) in chunk.enumerated() {
          let n = items[i].bytes.count, m = items[i].handles.count
          raw[k] = unsafe ChannelWriteItem(
            channel: items[i].channel, options: 0, bytes: itemAddress(b.baseAddress, byteOffset),
            handles: itemAddress(h.baseAddress, handleOffset * 4), num_bytes: UInt32(n),
            num_handles: UInt32(m), status: 0, reserved: 0)
          byteOffset += n
          handleOffset += m
        }
        return unsafe raw.withUnsafeMutableBufferPointer { rb in
          unsafe Result(catching: { () throws(Status) -> Int in try unsafe Kernel.channelWrite(rb) })
        }
      }
    }
    let done = try r.get()
    for (k, i) in chunk.enumerated() { items[i].status = Status(result: Int64(raw[k].status)) }
    return done
  }

  /// A read for `read(_:)`'s array: the channel, then its message or why
  /// there was none (`shouldWait`: nothing queued; `peerClosed`: nothing
  /// queued and the other end gone).
  public struct Incoming: Sendable {
    public var channel: UInt32
    public var message: Message?
    public var status: Status = .ok

    public init(channel: UInt32) { self.channel = channel }
  }

  /// How many bytes `read(_:)` gives each item at first: a message that
  /// doesn't fit is read again, at its size, in a second call.
  public static var readSlot: Int { 1024 }

  /// channel_read's array (D41): the next message from each item's
  /// channel, CROI_CHANNEL_MAX_ITEMS to a call, going on past one that has
  /// none; each item's message or status set, and how many were read. A
  /// server reads every channel its port reported at once. Messages
  /// larger than `readSlot` take a second call, which reads only those.
  @discardableResult
  public static func read(_ items: inout [Incoming]) throws(Status) -> Int {
    var done = 0
    var start = 0
    while start < items.count {
      let end = Swift.min(start + Int(CROI_CHANNEL_MAX_ITEMS), items.count)
      var pending = Array(start..<end)
      var room = [(bytes: Int, handles: Int)](repeating: (readSlot, maxHandles), count: pending.count)
      while !pending.isEmpty {
        let (read, short) = try readOnce(&items, pending, room)
        done += read
        pending = short.map { $0.index }
        room = short.map { $0.room }
      }
      start = end
    }
    return done
  }

  /// One channel_read for `indices`, each with `room`: how many were read,
  /// and the items whose message needs more room (it stays queued).
  static func readOnce(_ items: inout [Incoming], _ indices: [Int], _ room: [(bytes: Int, handles: Int)])
    throws(Status) -> (Int, [(index: Int, room: (bytes: Int, handles: Int))])
  {
    let byteTotal = room.reduce(0) { $0 + $1.bytes }, handleTotal = room.reduce(0) { $0 + $1.handles }
    // Trivial values: uninitialized until the read fills them.
    var bytes = unsafe [UInt8](unsafeUninitializedCapacity: byteTotal) { _, k in k = byteTotal }
    var handles = unsafe [UInt32](unsafeUninitializedCapacity: handleTotal) { _, k in k = handleTotal }
    var raw = [ChannelReadItem](repeating: ChannelReadItem(), count: indices.count)
    let r = unsafe bytes.withUnsafeMutableBytes { b in
      unsafe handles.withUnsafeMutableBufferPointer { h in
        var byteOffset = 0, handleOffset = 0
        for (k, i) in indices.enumerated() {
          raw[k] = unsafe ChannelReadItem(
            channel: items[i].channel, options: 0, bytes: itemAddress(b.baseAddress, byteOffset),
            handles: itemAddress(h.baseAddress, handleOffset * 4), num_bytes: UInt32(room[k].bytes),
            num_handles: UInt32(room[k].handles), actual_bytes: 0, actual_handles: 0, status: 0, reserved: 0)
          byteOffset += room[k].bytes
          handleOffset += room[k].handles
        }
        return unsafe raw.withUnsafeMutableBufferPointer { rb in
          unsafe Result(catching: { () throws(Status) -> Int in try unsafe Kernel.channelRead(rb) })
        }
      }
    }
    let done = try r.get()
    var short: [(index: Int, room: (bytes: Int, handles: Int))] = []
    var byteOffset = 0, handleOffset = 0
    for (k, i) in indices.enumerated() {
      let status = Status(result: Int64(raw[k].status))
      items[i].status = status
      if status == .ok {
        let n = Int(raw[k].actual_bytes), m = Int(raw[k].actual_handles)
        items[i].message = Message(bytes: Array(bytes[byteOffset..<byteOffset + n]),
                                   handles: Array(handles[handleOffset..<handleOffset + m]))
      } else if status == .bufferTooSmall {
        short.append((i, (Int(raw[k].actual_bytes), Int(raw[k].actual_handles))))
      }
      byteOffset += room[k].bytes
      handleOffset += room[k].handles
    }
    return (done, short)
  }

  /// channel_call: writes the message (its first four bytes become the
  /// kernel's txid) and waits until `deadline` for the reply that echoes
  /// it, which comes to this caller alone.
  public static func call(_ channel: borrowing Handle, bytes: [UInt8], handles: [UInt32] = [],
                          deadline: Int64 = infiniteDeadline) throws(Status) -> Message
  {
    try Kernel.channelCall(channel.raw, bytes, handles, deadline)
  }
}

/// Ports: where packets queue, from users and from the objects bound to
/// them. A wait on a port nothing fills is the one sleep (D25).
public enum Port {
  public static func create() throws(Status) -> Handle { Handle(raw: try Kernel.portCreate(options: 0)) }

  /// A port interrupts may be bound to (CROI_PORT_BIND_TO_INTERRUPT).
  public static func create(bindToInterrupt: Bool) throws(Status) -> Handle {
    Handle(raw: try Kernel.portCreate(options: bindToInterrupt ? CROI_PORT_BIND_TO_INTERRUPT : 0))
  }

  /// object_bind: binds each item to `port`, in order, stopping at the
  /// first that fails; each item done has its status written back. How
  /// many were bound.
  @discardableResult
  public static func bind(_ port: borrowing Handle, _ items: inout [Binding]) throws(Status) -> Int {
    let r = unsafe items.withUnsafeMutableBufferPointer { b in
      unsafe Result(catching: { () throws(Status) -> Int in try unsafe Kernel.bind(port.raw, b) })
    }
    return try r.get()
  }

  /// object_bind, one item: its status thrown if it failed.
  public static func bind(_ port: borrowing Handle, _ item: Binding) throws(Status) {
    var one = [item]
    if try bind(port, &one) != 1 { throw Status(result: Int64(one[0].status)) }
  }

  /// Queues user packets, in order, stopping at the first that can't be
  /// (shouldWait: the port holds too many); how many went.
  @discardableResult
  public static func queue(_ port: borrowing Handle, _ packets: [Packet]) throws(Status) -> Int {
    let r = unsafe packets.withUnsafeBufferPointer { b in
      unsafe Result(catching: { () throws(Status) -> Int in try unsafe Kernel.portQueue(port.raw, b) })
    }
    return try r.get()
  }

  /// Queues one user packet.
  public static func queue(_ port: borrowing Handle, _ packet: Packet) throws(Status) {
    _ = try queue(port, [packet])
  }

  /// Up to `max` packets (at most CROI_PORT_MAX_PACKETS), waiting until
  /// `deadline` for the first (timedOut then).
  public static func wait(_ port: borrowing Handle, deadline: Int64 = infiniteDeadline, max: Int) throws(Status)
    -> [Packet]
  {
    var packets = [Packet](repeating: Packet(), count: Swift.max(1, Swift.min(max, Int(CROI_PORT_MAX_PACKETS))))
    let r = unsafe packets.withUnsafeMutableBufferPointer { b in
      unsafe Result(catching: { () throws(Status) -> Int in try unsafe Kernel.portWait(port.raw, deadline, b) })
    }
    packets.removeSubrange(try r.get()...)
    return packets
  }

  /// The next packet, waiting until `deadline` for one.
  public static func wait(_ port: borrowing Handle, deadline: Int64 = infiniteDeadline) throws(Status) -> Packet {
    try wait(port, deadline: deadline, max: 1)[0]
  }

  /// Undoes the bindings to the port with `key` made through `source`, and
  /// drops their queued packets; notFound if there were none.
  public static func cancel(_ port: borrowing Handle, source: borrowing Handle, key: UInt64) throws(Status) {
    try Kernel.portCancel(port.raw, source.raw, key)
  }

  /// Undoes every binding to the port with `key`, and drops every queued
  /// packet with it (users' too); notFound if there were none.
  public static func cancel(_ port: borrowing Handle, key: UInt64) throws(Status) {
    try Kernel.portCancel(port.raw, 0, key)
  }
}

/// Virtual memory objects: memory that handles share. V1 cut vmo_read and
/// vmo_write (D37): a VMO's bytes are reached through a mapping.
public enum VMO {
  /// How a VMO's mappings are cached (vmo_set_cache_policy).
  public enum CachePolicy: UInt32, Sendable {
    case cached = 0
    case uncached = 1
    case uncachedDevice = 2
    case writeCombining = 3
  }

  /// A new VMO of `size` bytes (rounded up to pages), zeroed.
  public static func create(size: Int) throws(Status) -> Handle { Handle(raw: try Kernel.vmoCreate(size)) }

  /// Its size (the VMO info topic).
  public static func size(_ vmo: borrowing Handle) throws(Status) -> Int { try Kernel.vmoSize(vmo.raw) }

  /// The bytes of its pages in memory (committed): hosted, all of it.
  public static func committedBytes(_ vmo: borrowing Handle) throws(Status) -> Int { try Kernel.vmoCommitted(vmo.raw) }

  /// vmo_create_child's options (vmo.h's CROI_VMO_CHILD_*).
  public enum ChildOptions {
    public static var slice: UInt32 { CROI_VMO_CHILD_SLICE }
    public static var snapshotAtLeastOnWrite: UInt32 { CROI_VMO_CHILD_SNAPSHOT_AT_LEAST_ON_WRITE }
    public static var noWrite: UInt32 { CROI_VMO_CHILD_NO_WRITE }
  }

  /// A VMO's signal: it has no children (CROI_VMO_ZERO_CHILDREN): none
  /// made, or the last one's last handle and mapping are gone.
  public static var zeroChildren: UInt32 { CROI_VMO_ZERO_CHILDREN }

  /// A child of `vmo` (`ChildOptions`): a slice of a physical VMO shares
  /// its pages and cache policy, and while any slice or its mapping lives
  /// the parent doesn't assert `zeroChildren`.
  public static func child(_ vmo: borrowing Handle, options: UInt32, offset: UInt64, size: Int) throws(Status) -> Handle {
    Handle(raw: try Kernel.vmoCreateChild(vmo.raw, options, offset, size))
  }

  /// A VMO over physical memory, `address` and `size` page-aligned, which
  /// an MMIO resource must cover. Its mappings are uncached device memory
  /// unless its cache policy is changed before the first.
  public static func physical(resource: borrowing Handle, address: UInt64, size: Int) throws(Status) -> Handle {
    Handle(raw: try Kernel.vmoCreatePhysical(resource.raw, address, size))
  }

  /// Sets how many of its bytes `vmo` holds (its content size): at most
  /// its size; the bytes past it read as zero.
  public static func setContentSize(_ vmo: borrowing Handle, _ size: UInt64) throws(Status) {
    try Kernel.setContentSize(vmo.raw, size)
  }

  /// `vmo` again, able to run (EXECUTE added to its rights): `vmex` is the
  /// VMEX system resource, or root. `vmo` is gone either way.
  public static func executable(_ vmo: consuming Handle, vmex: borrowing Handle) throws(Status) -> Handle {
    Handle(raw: try Kernel.vmoReplaceAsExecutable(vmo.release(), vmex.raw))
  }

  /// Sets how the VMO's mappings are cached; only while it has none.
  public static func setCachePolicy(_ vmo: borrowing Handle, _ policy: CachePolicy) throws(Status) {
    try Kernel.vmoSetCachePolicy(vmo.raw, policy)
  }

  /// Maps `length` bytes from `offset` (a page multiple) into this process.
  public static func map(_ vmo: borrowing Handle, offset: Int = 0, length: Int, writable: Bool = true) throws(Status)
    -> Mapping
  {
    unsafe Mapping(address: try Kernel.vmoMap(vmo.raw, offset, length, writable), length: length)
  }

  /// A resizable VMO's new size, in pages: pages past it go, and growth
  /// reads as zeros.
  public static func setSize(_ vmo: borrowing Handle, _ size: Int) throws(Status) { try Kernel.vmoSetSize(vmo.raw, size) }

  /// A child that sees the parent's pages as they are, changes included
  /// (CROI_VMO_CHILD_REFERENCE): a pager VMO's to hand to a reader.
  public static var referenceChild: UInt32 { CROI_VMO_CHILD_REFERENCE }

  /// Hints that the range's pages, a pager VMO's or those a child reads
  /// through to, aren't needed: under pressure their clean pages go
  /// first (CROI_VMO_OP_DONT_NEED). Other VMOs ignore it.
  public static func dontNeed(_ vmo: borrowing Handle, offset: UInt64, length: Int) throws(Status) {
    try Kernel.vmoDontNeed(vmo.raw, offset, UInt64(length))
  }

  /// Writes the range's cached lines back to memory, for a device that
  /// doesn't snoop the CPU's caches to read (CROI_VMO_OP_CACHE_CLEAN).
  public static func cacheClean(_ vmo: borrowing Handle, offset: UInt64, length: Int) throws(Status) {
    try Kernel.vmoCacheClean(vmo.raw, offset, UInt64(length))
  }

  /// Test boots only (the test call's eviction): evicts up to `pages`
  /// pages hinted with `dontNeed`, and returns how many went.
  public static func evictHinted(pages: Int) throws(Status) -> Int { try Kernel.evictHinted(pages) }
}

/// A pager (pager(2)): VMOs whose pages this process supplies when they
/// are needed, each need a request on a port. Hosted there is none
/// (`notSupported`): a hosted process takes no page faults.
public enum Pager {
  public static func create() throws(Status) -> Handle { Handle(raw: try Kernel.pagerCreate()) }

  /// A VMO of `size` bytes backed by `pager`, its requests on `port` with
  /// `key`, charged to this process's account.
  public static func vmo(_ pager: borrowing Handle, port: borrowing Handle, key: UInt64, size: Int,
                         resizable: Bool = true) throws(Status) -> Handle
  {
    let options = resizable ? UInt64(CROI_VMO_RESIZABLE) : 0
    return Handle(raw: try Kernel.pagerCreateVMO(pager.raw, options, port.raw, key, size))
  }

  /// Ends the pager's service of `vmo`: its clean pages go, its waiters
  /// fail, and a `complete` request comes once.
  public static func detach(_ pager: borrowing Handle, _ vmo: borrowing Handle) throws(Status) {
    try Kernel.pagerDetach(pager.raw, vmo.raw)
  }

  /// Moves `length` bytes of `aux`'s pages from `auxOffset` into `vmo` at
  /// `offset`, all page aligned, where it has none.
  public static func supply(_ pager: borrowing Handle, _ vmo: borrowing Handle, offset: UInt64, length: Int,
                            from aux: borrowing Handle, at auxOffset: UInt64 = 0) throws(Status)
  {
    try Kernel.pagerSupply(pager.raw, vmo.raw, offset, UInt64(length), aux.raw, auxOffset)
  }

  /// Fails the requests for the range with `status` (`io`,
  /// `ioDataIntegrity`, `badState`, `noSpace`).
  public static func fail(_ pager: borrowing Handle, _ vmo: borrowing Handle, offset: UInt64, length: Int,
                          _ status: Status) throws(Status)
  {
    try Kernel.pagerOp(pager.raw, UInt32(CROI_PAGER_OP_FAIL), vmo.raw, offset, UInt64(length),
                       UInt64(bitPattern: Int64(status.rawValue)))
  }

  /// The range's dirty pages await clean: written meanwhile, they are
  /// dirty again.
  public static func writebackBegin(_ pager: borrowing Handle, _ vmo: borrowing Handle, offset: UInt64, length: Int)
    throws(Status)
  {
    try Kernel.pagerOp(pager.raw, UInt32(CROI_PAGER_OP_WRITEBACK_BEGIN), vmo.raw, offset, UInt64(length), 0)
  }

  /// The range's pages still awaiting clean are clean.
  public static func writebackEnd(_ pager: borrowing Handle, _ vmo: borrowing Handle, offset: UInt64, length: Int)
    throws(Status)
  {
    try Kernel.pagerOp(pager.raw, UInt32(CROI_PAGER_OP_WRITEBACK_END), vmo.raw, offset, UInt64(length), 0)
  }

  /// The runs of pages in the range that aren't clean, in order.
  public static func dirtyRanges(_ pager: borrowing Handle, _ vmo: borrowing Handle, offset: UInt64 = 0,
                                 length: Int) throws(Status) -> [(offset: UInt64, length: Int)]
  {
    var buffer = [croi_vmo_dirty_range_t](repeating: croi_vmo_dirty_range_t(), count: 32)
    var out: [(offset: UInt64, length: Int)] = []
    var from = offset
    let end = offset + UInt64(length)
    while from < end {
      let (written, _) = try unsafe buffer.withUnsafeMutableBufferPointer { (b) throws(Status) in
        try unsafe Kernel.pagerDirtyRanges(pager.raw, vmo.raw, from, end - from, b)
      }
      for r in buffer[0..<written] { out.append((r.offset, Int(r.length))) }
      guard written == buffer.count, let last = out.last else { break }
      from = last.offset + UInt64(last.length)
    }
    return out
  }

  /// A page request (a CROI_PKT_TYPE_PAGE_REQUEST packet): its VMO's key,
  /// command and range.
  public struct Request: Sendable {
    public enum Command: Sendable { case read, dirty, complete, other }
    public let key: UInt64
    public let command: Command
    public let offset: UInt64
    public let length: Int

    /// The request a packet is; nil for any other packet.
    public init?(_ packet: Packet) {
      guard packet.type == UInt32(CROI_PKT_TYPE_PAGE_REQUEST) else { return nil }
      key = packet.key
      command = switch UInt32(truncatingIfNeeded: packet.payload.0 & 0xFFFF) {
      case UInt32(CROI_PAGER_VMO_READ): .read
      case UInt32(CROI_PAGER_VMO_DIRTY): .dirty
      case UInt32(CROI_PAGER_VMO_COMPLETE): .complete
      default: .other
      }
      offset = packet.payload.1
      length = Int(packet.payload.2)
    }
  }
}

/// A VMO's range mapped into this process; unmapped when dropped. The
/// mapping keeps the VMO alive.
@safe public struct Mapping: ~Copyable {
  public let address: UnsafeMutableRawPointer
  public let length: Int

  init(address: UnsafeMutableRawPointer, length: Int) {
    unsafe self.address = address
    self.length = length
  }

  deinit { unsafe Kernel.vmoUnmap(address, length) }

  public func load<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
    precondition(offset >= 0 && offset + MemoryLayout<T>.size <= length)
    return unsafe address.loadUnaligned(fromByteOffset: offset, as: T.self)
  }

  public func store<T: FixedWidthInteger>(_ value: T, at offset: Int) {
    precondition(offset >= 0 && offset + MemoryLayout<T>.size <= length)
    unsafe address.storeBytes(of: value, toByteOffset: offset, as: T.self)
  }

  /// `count` bytes from `offset`, copied out (what vmo_read gave).
  public func read(at offset: Int, count: Int) -> [UInt8] {
    precondition(offset >= 0 && count >= 0 && offset + count <= length)
    return unsafe [UInt8](UnsafeRawBufferPointer(start: address + offset, count: count))
  }

  /// `bytes` copied in at `offset` (what vmo_write did).
  public func write(_ bytes: [UInt8], at offset: Int) {
    precondition(offset >= 0 && offset + bytes.count <= length)
    unsafe bytes.withUnsafeBytes { b in unsafe (address + offset).copyMemory(from: b.baseAddress!, byteCount: b.count) }
  }
}

/// Resources: the right to a range of hardware, MMIO addresses, interrupts
/// or I/O ports. A child lies inside its parent; the launcher grants its
/// ranged roots by manifest (`resource mmio`).
public enum Resource {
  /// A resource for `base` and `size` of `kind`, inside `parent`'s range.
  /// `exclusive`: no other may overlap it (only from a ranged root).
  public static func create(parent: borrowing Handle, kind: ResourceKind, base: UInt64, size: UInt64,
                            name: String, exclusive: Bool = false) throws(Status) -> Handle
  {
    Handle(raw: try Kernel.resourceCreate(parent.raw, kind.rawValue | (exclusive ? CROI_RSRC_FLAG_EXCLUSIVE : 0), base,
                                          size, name))
  }

  /// What a resource grants (object_get_info, RESOURCE).
  public static func info(_ resource: borrowing Handle) throws(Status) -> ResourceInfo {
    try Kernel.resourceInfo(resource.raw)
  }

  /// An SMCCC call to firmware (smc_call, arm64 only): `function` with
  /// x1-x6 `args`, through an SMC resource whose function-ID range covers
  /// it. x0-x3 of the result. NOT_SUPPORTED elsewhere.
  public static func smc(_ resource: borrowing Handle, function: UInt32,
                         _ args: (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0, 0, 0))
    throws(Status) -> (UInt64, UInt64, UInt64, UInt64)
  {
    try Kernel.smcCall(resource.raw, function, args)
  }
}

/// Where the RAM the kernel manages is (M6l: About this system), from
/// object_get_info(KMEM_STATS) through the INFO system resource (as
/// CPUStats): a snapshot of the PMM's pages and the kernel heap.
public struct KMemStats: Equatable, Sendable {
  public var total: UInt64
  public var free: UInt64
  public var wired: UInt64
  public var heap: UInt64
  public var heapFree: UInt64
  public var vmo: UInt64
  public var mmu: UInt64
  public var ipc: UInt64
  public var other: UInt64

  public init(total: UInt64, free: UInt64, wired: UInt64, heap: UInt64, heapFree: UInt64, vmo: UInt64, mmu: UInt64,
              ipc: UInt64, other: UInt64)
  {
    self.total = total
    self.free = free
    self.wired = wired
    self.heap = heap
    self.heapFree = heapFree
    self.vmo = vmo
    self.mmu = mmu
    self.ipc = ipc
    self.other = other
  }

  /// In use: everything but what's free.
  public var used: UInt64 { total > free ? total - free : 0 }

  public static func read(_ resource: borrowing Handle) throws(Status) -> KMemStats { try Kernel.kmemStats(resource.raw) }

  /// The RAM the kernel manages, in bytes (KMEM_STATS' `total`), from the
  /// vDSO's topology page: no resource needed, for sizing a cache as a
  /// share of it. 0 if unknown.
  public static var physical: UInt64 { Kernel.memoryBytes() }
}

/// The machine's power (system_powerctl), under the power system resource
/// (M6l: Deskbar's Restart). Shutting down is userboot's: the launcher
/// ends, and userboot powers off.
public enum Power {
  /// Restarts the machine: never returns if it can.
  public static func reboot(_ resource: borrowing Handle) throws(Status) {
    try Kernel.powerctl(resource.raw, CROI_SYSTEM_POWERCTL_REBOOT)
  }

  /// Turns the machine off: never returns if it can. amd64 needs ACPI's
  /// \_S5 sleep types (`sleepTypes`, from an AML interpreter); arm64 and
  /// rv64 ask the firmware (PSCI, SBI) and need none.
  public static func poweroff(_ resource: borrowing Handle, sleepTypes: (UInt8, UInt8)?) throws(Status) {
    #if arch(x86_64)
      guard let (a, b) = sleepTypes else { throw .notSupported }
      try Kernel.powerctlS5(resource.raw, a, b)
    #else
      try Kernel.powerctl(resource.raw, CROI_SYSTEM_POWERCTL_SHUTDOWN)
    #endif
  }

  /// Warm boot (D101): the kernel hands off to the kernel ELF and bootfs
  /// in `kernel` and `bootfs`, each as long as its content size, with the
  /// command line in `cmdline`. Never returns if it can; a bad ELF or too
  /// little memory for the copies is refused with nothing stopped. amd64
  /// and arm64 (notSupported on rv64).
  public static func warmboot(_ resource: borrowing Handle, kernel: borrowing Handle, bootfs: borrowing Handle,
                              cmdline: borrowing Handle) throws(Status) {
    try Kernel.powerctlWarmboot(resource.raw, kernel.raw, bootfs.raw, cmdline.raw)
  }

  /// Warm boot with this boot's command line.
  public static func warmboot(_ resource: borrowing Handle, kernel: borrowing Handle, bootfs: borrowing Handle)
    throws(Status)
  {
    try Kernel.powerctlWarmboot(resource.raw, kernel.raw, bootfs.raw, 0)
  }

  /// The system resource's base that grants power control.
  public static var systemBase: UInt64 { UInt64(CROI_RSRC_SYSTEM_POWER_BASE) }
}

/// A CPU's counts since boot (croi_info_cpu_stats_t, the fields the kernel
/// fills). On an idle machine every interrupt a CPU takes is a wakeup.
public struct CPUStats: Equatable, Sendable {
  public var cpu: UInt32
  public var online: Bool
  /// Nanoseconds idle.
  public var idleTime: Int64
  public var contextSwitches: UInt64
  /// Device and other interrupts, timer interrupts, timer callbacks run.
  public var interrupts: UInt64
  public var timerInterrupts: UInt64
  public var timers: UInt64
  public var syscalls: UInt64
  public var rescheduleIPIs: UInt64
  public var genericIPIs: UInt64

  /// The system resource's base that grants reading them (the INFO resource).
  public static var systemBase: UInt64 { UInt64(CROI_RSRC_SYSTEM_INFO_BASE) }

  /// Every CPU's (up to `max`), through the INFO system resource.
  public static func read(_ resource: borrowing Handle, max: Int = 64) throws(Status) -> [CPUStats] {
    try Kernel.cpuStats(resource.raw, max: max)
  }

  /// The wakeups it counts: every interrupt the CPU took.
  public var wakeups: UInt64 { interrupts + timerInterrupts + rescheduleIPIs + genericIPIs }
}

/// An MSI allocation (croi_info_msi_t): interrupt id n writes
/// `targetData + n` to `targetAddress`.
public struct MSIInfo: Equatable, Sendable {
  public var targetAddress: UInt64
  public var targetData: UInt32
  public var baseIRQ: UInt32
  public var count: UInt32
  /// Ids with an interrupt object.
  public var interrupts: UInt32
}

public struct ResourceInfo: Equatable, Sendable {
  public var kind: UInt32
  public var flags: UInt32
  public var base: UInt64
  /// 0 for a kind's ranged root.
  public var size: UInt64
  public var name: String

  public init(kind: UInt32, flags: UInt32, base: UInt64, size: UInt64, name: String) {
    self.kind = kind
    self.flags = flags
    self.base = base
    self.size = size
    self.name = name
  }
}

/// I/O ports (amd64): a process may use the ports it has requested with
/// an IOPORT resource that covers them; any other faults.
public enum IOPorts {
  public static func request(_ resource: borrowing Handle, base: UInt16, count: UInt16) throws(Status) {
    try Kernel.ioportsRequest(resource.raw, base, count)
  }

  public static func release(_ resource: borrowing Handle, base: UInt16, count: UInt16) throws(Status) {
    try Kernel.ioportsRelease(resource.raw, base, count)
  }

  /// `in` and `out` of 1, 2 or 4 bytes (`width`).
  public static func read(_ port: UInt16, width: Int) -> UInt32 { Kernel.portIn(port, width) }
  public static func write(_ port: UInt16, width: Int, _ value: UInt32) { Kernel.portOut(port, width, value) }
}

/// The kernel's log, a ring every process's stdout writes to (D38: readers
/// map it; the console's, V2's item 8).
public enum Debuglog {
  /// Waits until the console has printed every record written so far, or
  /// `deadline`: power-off waits only 100 ms for it, and the console
  /// carries the debuglog far slower than a process can fill it. False if
  /// it hadn't caught up (or there's no console to ask).
  @discardableResult
  public static func waitForConsole(deadline: Int64) -> Bool {
    guard let raw = try? Kernel.debuglogCreate() else { return false }
    let log = Handle(raw: raw)
    guard let target = try? Kernel.debuglogProgress(log.raw).written else { return false }
    while let p = try? Kernel.debuglogProgress(log.raw), p.printed < target {
      guard Clock.monotonic() < deadline else { return false }
      Kernel.sleep(Clock.monotonic() + 10_000_000)
    }
    return true
  }
}

/// Interrupt objects: a device's interrupt, by its number (amd64 and rv64
/// a GSI, arm64 an INTID) under an IRQ resource covering it. A bound port
/// is the one way to wait for one (V1 cut interrupt_wait and virtual
/// interrupts, D29): its packets come until `ack` re-arms it, and a level
/// interrupt is masked from when it fires until then.
public enum Interrupt {
  /// How the line signals (interrupt_create's mode).
  public enum Mode: UInt32, Sendable {
    /// What firmware says (amd64: MADT overrides, else ISA edge-high, PCI level-low).
    case `default` = 0
    case edgeLow = 2
    case edgeHigh = 4
    case levelLow = 6
    case levelHigh = 8
  }

  /// A port packet's type for an interrupt: payload.0 is its timestamp.
  public static var packetType: UInt32 { CROI_PKT_TYPE_INTERRUPT }

  public static func create(resource: borrowing Handle, number: UInt32, mode: Mode = .default) throws(Status) -> Handle {
    Handle(raw: try Kernel.interruptCreate(resource.raw, number, mode.rawValue))
  }

  /// Packets to `port` with `key`, one an interrupt (object_bind INTERRUPT).
  public static func bind(_ interrupt: borrowing Handle, port: borrowing Handle, key: UInt64) throws(Status) {
    try Port.bind(port, Binding.interrupt(interrupt.raw, key: key))
  }

  /// Re-arms interrupts (interrupt_ack's array, D40): an IRQ thread acks
  /// every vector it handled at once. Each one's status; how many succeeded.
  @discardableResult
  public static func ack(_ interrupts: [UInt32], statuses: inout [Status]) throws(Status) -> Int {
    var items = interrupts.map { croi_interrupt_ack_item_t(interrupt: $0, status: 0) }
    let r = unsafe items.withUnsafeMutableBufferPointer { b in
      unsafe Result(catching: { () throws(Status) -> Int in try unsafe Kernel.interruptAck(b) })
    }
    statuses = items.map { Status(result: Int64($0.status)) }
    return try r.get()
  }

  /// Re-arms one interrupt.
  public static func ack(_ interrupt: borrowing Handle) throws(Status) {
    var statuses: [Status] = []
    if try ack([interrupt.raw], statuses: &statuses) != 1 { throw statuses[0] }
  }

  /// The system resource's base that grants MSI allocations.
  public static var msiSystemBase: UInt64 { UInt64(CROI_RSRC_SYSTEM_MSI_BASE) }

  /// `count` contiguous MSI vectors (a power of two, up to 32; amd64 only
  /// so far): an allocation to make interrupts from.
  public static func msiAllocate(resource: borrowing Handle, count: Int) throws(Status) -> Handle {
    Handle(raw: try Kernel.msiAllocate(resource.raw, count))
  }

  /// Interrupt `id` of an MSI allocation. With `msix`, `vmo` holds the
  /// device's MSI-X table at `offset` (physical, uncached) and the kernel
  /// programs and masks entry `id`; without, `vmo` is the function's
  /// configuration space with the MSI capability at `offset`.
  public static func msi(allocation: borrowing Handle, id: UInt32, vmo: borrowing Handle, offset: Int, msix: Bool)
    throws(Status) -> Handle
  {
    Handle(raw: try Kernel.msiCreate(allocation.raw, msix ? CROI_MSI_MODE_MSI_X : 0, id, vmo.raw, offset))
  }

  /// What a device must write to raise an MSI allocation's interrupts: a
  /// plain MSI capability's driver programs it from this.
  public static func msiInfo(_ allocation: borrowing Handle) throws(Status) -> MSIInfo {
    try Kernel.msiInfo(allocation.raw)
  }

  /// Routes it to a CPU of `cpus` (bit n, CPU n).
  public static func setAffinity(_ interrupt: borrowing Handle, cpus: UInt64) throws(Status) {
    try Kernel.interruptSetAffinity(interrupt.raw, cpus)
  }
}

/// DMA: an IOMMU, a bus transaction initiator (BTI) per device under it,
/// and memory pinned through the BTI for the device to reach, its pages
/// held until unpinned. Through the stub IOMMU, device addresses are
/// physical ones.
public enum DMA {
  /// The bti_pin options (dma.h's CROI_BTI_*).
  public struct Pin: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static var read: Pin { Pin(rawValue: CROI_BTI_PERM_READ) }
    public static var write: Pin { Pin(rawValue: CROI_BTI_PERM_WRITE) }
    public static var execute: Pin { Pin(rawValue: CROI_BTI_PERM_EXECUTE) }
    public static var compress: Pin { Pin(rawValue: CROI_BTI_COMPRESS) }
    public static var contiguous: Pin { Pin(rawValue: CROI_BTI_CONTIGUOUS) }
  }

  /// A BTI's DMA properties (bti_set_properties): addresses below
  /// 2^addressBits, inside [windowBase, windowBase + windowSize) if the
  /// size isn't 0, and the memory's coherency. Only ever narrowed.
  public struct Properties: Equatable, Sendable {
    public var addressBits: UInt32
    public var coherent: Bool
    public var windowBase: UInt64
    public var windowSize: UInt64
    public init(addressBits: UInt32 = 64, coherent: Bool = true, windowBase: UInt64 = 0, windowSize: UInt64 = 0) {
      self.addressBits = addressBits
      self.coherent = coherent
      self.windowBase = windowBase
      self.windowSize = windowSize
    }
  }

  /// The system resource's base that grants making an IOMMU.
  public static var iommuSystemBase: UInt64 { UInt64(CROI_RSRC_SYSTEM_IOMMU_BASE) }

  /// iommu_create's types (dma.h): which kind of unit a descriptor names.
  public enum IOMMUType: UInt32, Sendable {
    case stub = 0
    /// VT-d: croi_iommu_desc_intel_t, its scopes and reserved memory.
    case intel = 1
    /// SMMUv3 (and v1/v2): the register base alone.
    case armSMMU = 2
    /// AMD-Vi: croi_iommu_desc_amd_t and its unity ranges.
    case amd = 0x10000
    /// The RISC-V IOMMU: the register base alone.
    case riscv = 0x10001
  }

  /// The unit `descriptor` names, the bytes dma.h lays out for `type`: the
  /// kernel checks it against firmware's tables and turns translation on.
  /// A device it covers is claimed by `bti`; what it doesn't cover,
  /// OUT_OF_RANGE.
  public static func iommu(resource: borrowing Handle, type: IOMMUType, descriptor: [UInt8]) throws(Status) -> Handle {
    Handle(raw: try Kernel.iommuCreate(resource.raw, type.rawValue, descriptor))
  }

  /// The stub IOMMU: no translation. Its BTIs are a trust decision that
  /// the kernel logs.
  public static func stubIOMMU(resource: borrowing Handle) throws(Status) -> Handle {
    try iommu(resource: resource, type: .stub, descriptor: [0])
  }

  /// A BTI for the device with `id` (a PCI device's bus, device and
  /// function, by convention).
  public static func bti(iommu: borrowing Handle, id: UInt64) throws(Status) -> Handle {
    Handle(raw: try Kernel.btiCreate(iommu.raw, id))
  }

  public static func setProperties(_ bti: borrowing Handle, _ p: Properties) throws(Status) {
    try Kernel.btiSetProperties(bti.raw, p)
  }

  /// A VMO of `size` bytes contiguous in device address space, inside the
  /// BTI's properties.
  public static func contiguousVMO(bti: borrowing Handle, size: Int, alignmentLog2: UInt32 = 0) throws(Status) -> Handle {
    Handle(raw: try Kernel.vmoCreateContiguous(bti.raw, size, alignmentLog2))
  }

  /// Pins `size` bytes of the VMO from `offset` (page aligned); the PMT
  /// that holds them, and their device addresses (`count` of them: one
  /// with `.contiguous`, else one a page). Unpin with `unpin`: a PMT
  /// closed while pinned is quarantined.
  public static func pin(_ bti: borrowing Handle, _ vmo: borrowing Handle, offset: Int, size: Int, options: Pin,
                         count: Int) throws(Status) -> (pmt: UInt32, addresses: [UInt64])
  {
    try Kernel.btiPin(bti.raw, vmo.raw, offset, size, options.rawValue, count)
  }

  /// Unpins; the PMT is consumed.
  public static func unpin(pmt: UInt32) throws(Status) { try Kernel.pmtUnpin(pmt) }

  public static func releaseQuarantine(_ bti: borrowing Handle) throws(Status) {
    try Kernel.btiReleaseQuarantine(bti.raw)
  }
}

/// Scheduling profiles: a priority, or a deadline (capacity of CPU time
/// in each period, due by the relative deadline), applied to a thread. A
/// deadline profile passes admission or is refused with a reason. Making
/// one needs the profile system resource.
public enum Profile {
  /// The system resource's base that grants profiles.
  public static var systemBase: UInt64 { UInt64(CROI_RSRC_SYSTEM_PROFILE_BASE) }

  /// A deadline profile: `capacity` ns in every `period` ns, done within
  /// `deadline` ns of the period's start (50 µs <= capacity <= deadline <= period).
  public static func deadline(resource: borrowing Handle, capacity: Int64, deadline: Int64, period: Int64) throws(Status)
    -> Handle
  {
    Handle(raw: try Kernel.profileCreate(resource.raw, deadline: (capacity, deadline, period)))
  }

  /// Applies `profile` to `thread`: 0, or the reason word admission
  /// refused a deadline profile with (CROI_ADMISSION_*).
  public static func apply(_ profile: borrowing Handle, to thread: borrowing Handle) throws(Status) -> UInt32 {
    try Kernel.setProfile(thread.raw, profile.raw, 0)
  }

  /// Makes an interrupt or counter lend `profile`'s deadline to each
  /// thread it wakes, until that thread next blocks.
  public static func lend(_ profile: borrowing Handle, from object: borrowing Handle) throws(Status) {
    _ = try Kernel.setProfile(object.raw, profile.raw, 0)
  }
}

/// Counters: a signed 64-bit value its holders add to, POSITIVE or
/// NON_POSITIVE by its sign, and waited on at a value (a fence) or at
/// every add (a doorbell). V1's one event (D23): the desktop's acquire
/// fences and release values, and every ring's kick.
public enum Counter {
  /// A port packet's type for a counter reaching a value: payload.0 the
  /// value waited for, .1 the value reached, .2 the time.
  public static var packetType: UInt32 { CROI_PKT_TYPE_COUNTER }
  /// A port packet's type for an add (`Binding.changes`): payload.1 the
  /// value, .2 the adds coalesced, .3 the time.
  public static var changePacketType: UInt32 { CROI_PKT_TYPE_COUNTER_CHANGE }

  public static func create() throws(Status) -> Handle { Handle(raw: try Kernel.counterCreate()) }

  /// counter_add's array (D40): each item's amount added to its counter,
  /// going on past one that fails; each item's status written back, and
  /// how many succeeded. A service rings every client's doorbell at once.
  @discardableResult
  public static func add(_ items: inout [CounterAdd]) throws(Status) -> Int {
    let r = unsafe items.withUnsafeMutableBufferPointer { b in
      unsafe Result(catching: { () throws(Status) -> Int in try unsafe Kernel.counterAdd(b) })
    }
    return try r.get()
  }

  /// Adds to one counter (outOfRange, unchanged, on overflow).
  public static func add(_ counter: borrowing Handle, _ amount: Int64) throws(Status) {
    var items = [CounterAdd(counter: counter.raw, status: 0, amount: amount)]
    if try add(&items) != 1 { throw Status(result: Int64(items[0].status)) }
  }

  public static func read(_ counter: borrowing Handle) throws(Status) -> Int64 { try Kernel.counterRead(counter.raw) }

  /// Waits until the value is at least `value` (`timedOut` at the
  /// deadline): a VALUE binding on the thread's port (counter_wait went in
  /// V1, D25).
  public static func wait(_ counter: borrowing Handle, until value: Int64, deadline: Int64 = infiniteDeadline)
    throws(Status)
  {
    _ = try Kernel.wait(Binding.value(counter.raw, value, key: 0), deadline: deadline)
  }
}

/// The kernel's CPRNG (cprng_draw; getentropy hosted): keys, nonces, TCP's
/// initial sequence secret.
public enum CPRNG {
  public static func draw(count: Int) throws(Status) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    // Not a typed-throws closure to withUnsafeMutableBytes (CLAUDE.md's pitfall).
    let status = bytes.withUnsafeMutableBytes { b -> Status? in
      do throws(Status) { try unsafe Kernel.random(b) } catch { return error }
      return nil
    }
    if let status { throw status }
    return bytes
  }
}

/// Jobs: the tree processes live in; killing one kills all under it.
public enum Job {
  public static func create(parent: borrowing Handle) throws(Status) -> Handle {
    Handle(raw: try Kernel.jobCreate(parent.raw))
  }

  /// Its child jobs' koids (M6j, the Inspector; ENUMERATE).
  public static func children(_ job: borrowing Handle) throws(Status) -> [UInt64] {
    try Kernel.koids(job.raw, CROI_INFO_JOB_CHILDREN)
  }

  /// Its processes' koids (ENUMERATE).
  public static func processes(_ job: borrowing Handle) throws(Status) -> [UInt64] {
    try Kernel.koids(job.raw, CROI_INFO_JOB_PROCESSES)
  }

  /// A job debugger channel (INSPECT, ENUMERATE, DUPLICATE, TRANSFER,
  /// MANAGE_THREAD): a message for each process starting under the job,
  /// held at its start until the message's exception is closed.
  public static func debugChannel(_ job: borrowing Handle) throws(Status) -> Handle {
    Handle(raw: try Kernel.debugChannel(job.raw))
  }
}

/// Exceptions, each a message's one handle on an exception channel:
/// closing it lets the thread go on.
public enum Exception {
  /// The process the exception is in.
  public static func process(_ exception: borrowing Handle) throws(Status) -> Handle {
    Handle(raw: try Kernel.exceptionProcess(exception.raw))
  }
}

/// A process's memory (croi_info_task_stats_t): bytes mapped, committed in
/// VMOs only it maps, committed in VMOs others map too, and its share of
/// those (each shared range divided by the processes mapping it). Device
/// memory counts nothing.
public struct TaskStats: Equatable, Sendable {
  public var mapped: UInt64
  public var privateBytes: UInt64
  public var shared: UInt64
  public var scaledShared: UInt64

  public init(mapped: UInt64, privateBytes: UInt64, shared: UInt64, scaledShared: UInt64) {
    self.mapped = mapped
    self.privateBytes = privateBytes
    self.shared = shared
    self.scaledShared = scaledShared
  }

  /// What the process holds without counting a shared page twice.
  public var resident: UInt64 { privateBytes + scaledShared }
}

/// A thread's state, and a blocked thread's wait (task.h's
/// CROI_THREAD_STATE_*).
public struct ThreadState: Equatable, Sendable {
  public var rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }

  /// As the Inspector shows it: "running", "blocked: port"...
  public var text: String {
    switch rawValue {
    case CROI_THREAD_STATE_NEW: "new"
    case CROI_THREAD_STATE_RUNNING: "running"
    case CROI_THREAD_STATE_SUSPENDED: "suspended"
    case CROI_THREAD_STATE_BLOCKED_EXCEPTION: "blocked: exception"
    case CROI_THREAD_STATE_BLOCKED_FUTEX: "blocked: futex"
    case CROI_THREAD_STATE_BLOCKED_PORT: "blocked: port"
    case CROI_THREAD_STATE_BLOCKED_CHANNEL: "blocked: channel"
    case CROI_THREAD_STATE_BLOCKED_PAGER: "blocked: pager"
    case CROI_THREAD_STATE_DYING: "dying"
    case CROI_THREAD_STATE_DEAD: "dead"
    default: rawValue & 0xFF == CROI_THREAD_STATE_BLOCKED ? "blocked" : "unknown"
    }
  }
}

/// One of a process's mappings (croi_info_maps_t's): its VMO's name, where
/// it is, its permissions (CROI_VM_PERM_*), and where in its VMO it starts.
public struct ProcessMapping: Equatable, Sendable {
  public var name: String
  public var base: UInt64
  public var size: UInt64
  public var flags: UInt32
  public var vmoKoid: UInt64
  public var vmoOffset: UInt64
  public init(name: String, base: UInt64, size: UInt64, flags: UInt32, vmoKoid: UInt64, vmoOffset: UInt64) {
    (self.name, self.base, self.size, self.flags, self.vmoKoid, self.vmoOffset) = (name, base, size, flags, vmoKoid, vmoOffset)
  }

  /// Whether it may run.
  public var executable: Bool { flags & UInt32(CROI_VM_PERM_EXECUTE) != 0 }
}

/// A task's time (croi_info_task_runtime_t): on a CPU, ready and waiting
/// for one, in page faults, in lock contention (ns).
public struct TaskRuntime: Equatable, Sendable {
  public var cpuTime: Int64
  public var queueTime: Int64
  public var pageFaultTime: Int64
  public var lockContentionTime: Int64
  public init(cpuTime: Int64, queueTime: Int64, pageFaultTime: Int64, lockContentionTime: Int64) {
    self.cpuTime = cpuTime
    self.queueTime = queueTime
    self.pageFaultTime = pageFaultTime
    self.lockContentionTime = lockContentionTime
  }
}

/// A handle in a process's table (croi_info_handle_extended_t): its
/// object's type (ObjectType's value) and koid, its value and rights, and
/// for a channel its peer's koid.
public struct HandleEntry: Equatable, Sendable {
  public var type: UInt32
  public var value: UInt32
  public var rights: UInt32
  public var koid: UInt64
  public var relatedKoid: UInt64
  public init(type: UInt32, value: UInt32, rights: UInt32, koid: UInt64, relatedKoid: UInt64) {
    self.type = type
    self.value = value
    self.rights = rights
    self.koid = koid
    self.relatedKoid = relatedKoid
  }
}

public struct ProcessInfo: Equatable, Sendable {
  public var returnCode: Int64
  public var started: Bool
  public var exited: Bool
  public init(returnCode: Int64, started: Bool, exited: Bool) {
    self.returnCode = returnCode
    self.started = started
    self.exited = exited
  }
}

/// Notes (D87): Plan 9's, text posted to a process (`interrupt`, `hangup`,
/// `kill`). A process that hasn't asked for its notes dies of the first,
/// with it as its exit string; one that has gets each in its handler.
public enum Note {
  /// The longest note, in bytes (Plan 9's ERRMAX, less its NUL).
  public static var max: Int { 127 }

  /// Posts `text` to `process`, which needs the handle's NOTE right (the
  /// proc service's, D79). `shouldWait` if five wait already, `badState`
  /// if it isn't running.
  public static func post(_ text: String, to process: borrowing Handle) throws(Status) {
    try Kernel.postNote(process.raw, text)
  }

  /// The note `process` died of, once it has ended; nil if it ended
  /// otherwise.
  public static func diedOf(_ process: borrowing Handle) -> String? { try? Kernel.note(process.raw) }

  /// From now on this process takes its notes: each, oldest first, given
  /// to `handler` on a thread of its own. When the handler returns false,
  /// the process ends with the note as its exit string, as with no
  /// handler (Plan 9's NDFLT). Once a process.
  public static func notify(_ handler: @escaping @Sendable (String) -> Bool) throws(Status) {
    let me = try Process.current().release()  // the thread's, for good
    try Kernel.setNotify(me, true)
    _ = try Thread.spawn {
      while true {
        let process = Handle(raw: me)
        _ = try? process.wait(for: Signals.note)
        _ = process.release()
        while let note = try? Kernel.note(me) {
          if !handler(note) { Kernel.exits(note) }
        }
      }
    }.release()
  }
}

/// Processes: a handle table and threads. Natively an address space too.
public enum Process {
  public static func create(job: borrowing Handle, name: String) throws(Status) -> Handle {
    Handle(raw: try Kernel.processCreate(job.raw, name))
  }

  /// Starts the process: its first thread runs `entry`, given `startup`,
  /// whose handles move into the process (started or not). The thread's
  /// handle. Natively, `entry` is an ELF image the process is loaded from
  /// (Program, user/lib/loader), and `startup` its processargs message,
  /// with the process's own handles, its root VMAR and a debuglog for its
  /// stdout added, and its name as argv[0] if `startup` has no arguments;
  /// hosted, a Swift function given `startup`.
  public static func start(_ process: borrowing Handle, entry: ProgramEntry, _ startup: Startup) throws(Status)
    -> Handle
  {
    let handles = startup.takeAll()
    let thread: Handle
    do throws(Status) {
      thread = Handle(raw: try Kernel.threadCreate(process.raw))
    } catch {
      close(raw: handles.map { $0.handle })
      throw error
    }
    try Kernel.processStart(process.raw, thread.raw, entry, startup, handles)
    return thread
  }

  /// The calling process ends with `code`.
  public static func exit(code: Int64) -> Never { Kernel.exit(code) }

  /// The calling process ends with `message` as its exit string (D72):
  /// code 0 for none, else 1.
  public static func exits(_ message: String) -> Never { Kernel.exits(message) }

  /// The calling process says why it can't go on, after its name, and
  /// ends with that as its exit string.
  public static func fail(_ why: String) -> Never {
    // Bytes, not Characters: tier 0 has no grapheme tables.
    let path = Array((Startup.current.args.first ?? "?").utf8)
    let name = path[(path.lastIndex(of: UInt8(ascii: "/")).map { $0 + 1 } ?? 0)...]
    print(String(decoding: name, as: UTF8.self) + ": " + why)
    exits(why)
  }

  /// A handle to the calling process.
  public static func current() throws(Status) -> Handle { Handle(raw: try Kernel.processSelf()) }

  public static func info(_ process: borrowing Handle) throws(Status) -> ProcessInfo { try Kernel.processInfo(process.raw) }

  /// Its memory; `badState` once it has ended.
  public static func stats(_ process: borrowing Handle) throws(Status) -> TaskStats { try Kernel.taskStats(process.raw) }

  /// Its threads' time on and waiting for a CPU (M6j, the Inspector).
  public static func runtime(_ process: borrowing Handle) throws(Status) -> TaskRuntime {
    try Kernel.taskRuntime(process.raw)
  }

  /// Its threads' koids (ENUMERATE).
  public static func threads(_ process: borrowing Handle) throws(Status) -> [UInt64] {
    try Kernel.koids(process.raw, CROI_INFO_PROCESS_THREADS)
  }

  /// Its mappings, by address (INSPECT).
  public static func mappings(_ process: borrowing Handle) throws(Status) -> [ProcessMapping] {
    try Kernel.processMappings(process.raw)
  }

  /// Its handle table (INSPECT, MANAGE_PROCESS, MANAGE_THREAD): each
  /// handle's object, and a channel's peer.
  public static func handles(_ process: borrowing Handle) throws(Status) -> [HandleEntry] {
    try Kernel.handleTable(process.raw)
  }
}

/// Threads: more threads in a process (a process's first comes with
/// Process.start).
public enum Thread {
  public static func create(process: borrowing Handle) throws(Status) -> Handle {
    Handle(raw: try Kernel.threadCreate(process.raw))
  }

  /// What a thread is doing (croi_info_thread_t's state: the low byte the
  /// state, the high one what a blocked thread waits on).
  public static func state(_ thread: borrowing Handle) throws(Status) -> ThreadState {
    ThreadState(rawValue: try Kernel.threadState(thread.raw))
  }

  /// Its time on and waiting for a CPU.
  public static func runtime(_ thread: borrowing Handle) throws(Status) -> TaskRuntime {
    try Kernel.taskRuntime(thread.raw)
  }

  /// The id the kernel's trace records name it by (INSPECT): its process's
  /// task number, shifted left 12, or its index in the process.
  public static func traceID(_ thread: borrowing Handle) throws(Status) -> UInt32 {
    try Kernel.threadTraceID(thread.raw)
  }

  /// Starts `thread` running `body`; the thread exits when it returns.
  /// Natively the floor gives it a stack of its own (td_thread_start),
  /// which it unmaps as it ends.
  public static func start(_ thread: borrowing Handle, _ body: @escaping @Sendable () -> Void) throws(Status) {
    try Kernel.threadStart(thread.raw, body)
  }

  /// A new thread in the calling process, running `body`. Its handle:
  /// `join` it, or drop it to let the thread run on alone.
  public static func spawn(_ body: @escaping @Sendable () -> Void) throws(Status) -> Handle {
    let process = try Process.current()
    let thread = try create(process: process)
    try start(thread, body)
    return thread
  }

  /// Ends the calling thread now (pthread_exit's, M5k). What it was
  /// running doesn't return; its stack is reclaimed as a thread's that
  /// returned.
  public static func exit() -> Never { Kernel.threadExit() }

  /// Waits until `thread` has ended.
  public static func join(_ thread: borrowing Handle) throws(Status) {
    _ = try thread.wait(for: Signals.terminated)
  }
}

/// task_kill: a job (with all under it), a process or a thread.
public func kill(_ task: borrowing Handle) throws(Status) { try Kernel.kill(task.raw) }
