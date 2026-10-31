// SPDX-License-Identifier: BSD-3-Clause

// The hosted kernel: the kernel's object model (Zircon's semantics and
// values, studied, not copied) on Linux, in one process. Hosted processes
// are threads with handle tables of their own, so a process can use only
// the handles it was given; memory isn't isolated (docs/milestones/N0.md).
// `Sys` (system/sys/api) is the typed face services use; natively it calls
// the kernel instead, and nothing above it changes. It follows V1's model
// (V2): no events, eventpairs, sockets, timers or user signals; every wait
// is a binding to a port (object_bind), a counter's too.
//
// One lock guards everything, and one condition is broadcast on every
// change: simple, and enough for a development kernel.

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Synchronization
import SysABI

// MARK: Objects

/// An object_bind binding: packets to `port` when its event comes.
final class Bound {
  let object: KernelObject
  let port: PortObject
  let key: UInt64
  /// CROI_BIND_SIGNALS, _VALUE or _CHANGE.
  let kind: UInt32
  let trigger: UInt64
  let persistent: Bool
  let edge: Bool
  /// The handle it was made through: closing that handle cancels it.
  let process: ObjectIdentifier
  let handle: UInt32

  init(object: KernelObject, port: PortObject, key: UInt64, kind: UInt32, trigger: UInt64, persistent: Bool,
       edge: Bool, process: ObjectIdentifier, handle: UInt32) {
    self.object = object
    self.port = port
    self.key = key
    self.kind = kind
    self.trigger = trigger
    self.persistent = persistent
    self.edge = edge
    self.process = process
    self.handle = handle
  }
}

class KernelObject {
  let koid: UInt64
  let type: UInt32
  var signals: UInt32 = 0
  var refs = 0

  init(_ kernel: HostKernel, type: UInt32) {
    kernel.lastKoid += 1
    koid = kernel.lastKoid
    self.type = type
  }

  /// The koid of the object this one is paired with (a channel's peer),
  /// for object_get_info.
  var relatedKoid: UInt64 { 0 }

  /// Under the lock, when the last handle (or carrying message) goes.
  func lastReferenceGone(_ kernel: HostKernel) {}
}

/// A counter (Zircon's type 34): a value that only its holders change,
/// POSITIVE or NON_POSITIVE asserted by its sign, bound VALUE (a packet
/// once it reaches a value) or CHANGE (a packet at every add).
final class CounterObject: KernelObject {
  var value: Int64 = 0
}

class Peered: KernelObject {
  weak var peer: Peered?
  var peerKoid: UInt64 = 0
  override var relatedKoid: UInt64 { peerKoid }

  override func lastReferenceGone(_ kernel: HostKernel) {
    if let peer {
      kernel.update(peer, set: Signals.peerClosed)
      peer.peer = nil
    }
    peer = nil
  }
}

final class ChannelEnd: Peered {
  struct Message {
    var bytes: [UInt8]
    var handles: [(object: KernelObject, rights: Rights)]
  }

  var queue: [Message] = []
  /// Calls waiting on this end for their reply, by txid; nil until it comes.
  var calls: [UInt32: Message?] = [:]

  override func lastReferenceGone(_ kernel: HostKernel) {
    super.lastReferenceGone(kernel)
    let dropped = queue + calls.values.compactMap { $0 }
    queue = []
    calls = [:]
    for message in dropped {
      for carried in message.handles { kernel.release(carried.object) }
    }
  }
}

final class PortObject: KernelObject {
  /// Its packets, each with the binding that queued it (nil: a user's), so
  /// that a persistent binding's coalesce and a cancel finds its own.
  var packets: [(packet: Packet, from: Bound?)] = []
}

final class VMOObject: KernelObject {
  let base: UnsafeMutableRawPointer
  let size: Int

  init(_ kernel: HostKernel, size: Int) {
    self.size = size
    base = UnsafeMutableRawPointer.allocate(byteCount: max(size, 1), alignment: 4096)
    base.initializeMemory(as: UInt8.self, repeating: 0, count: max(size, 1))
    super.init(kernel, type: ObjectType.vmo)
  }

  deinit { base.deallocate() }
}


class TaskObject: KernelObject {
  var killed = false
}

final class JobObject: TaskObject {
  weak var parent: JobObject?
  var children: [JobObject] = []
  var processes: [ProcessObject] = []
}

final class ProcessObject: TaskObject {
  let name: String
  weak var job: JobObject?
  var table = HandleTable()
  /// Threads running, and whether one ever started.
  var running = 0
  var started = false
  var returnCode: Int64 = 0

  init(_ kernel: HostKernel, name: String, job: JobObject?) {
    self.name = name
    self.job = job
    super.init(kernel, type: ObjectType.process)
  }
}

final class ThreadObject: TaskObject {
  let process: ProcessObject
  var started = false

  init(_ kernel: HostKernel, process: ProcessObject) {
    self.process = process
    super.init(kernel, type: ObjectType.thread)
  }

  override func lastReferenceGone(_ kernel: HostKernel) { kernel.release(process) }
}

/// A process's handles. A handle is (generation << 20) | (index + 1), so 0
/// is never valid and a closed handle's number fails until reused.
struct HandleTable {
  struct Slot {
    var object: KernelObject?
    var rights: Rights = []
    var generation: UInt32 = 0
  }

  static let indexBits: UInt32 = 20
  static let indexMask: UInt32 = (1 << indexBits) - 1

  var slots: [Slot] = []
  var free: [Int] = []

  mutating func install(_ object: KernelObject, _ rights: Rights) throws(Status) -> UInt32 {
    let index: Int
    if let reused = free.popLast() {
      index = reused
    } else {
      guard slots.count < Int(Self.indexMask) else { throw .noResources }
      index = slots.count
      slots.append(Slot())
    }
    slots[index].object = object
    slots[index].rights = rights
    return (slots[index].generation << Self.indexBits) | UInt32(index + 1)
  }

  func index(_ handle: UInt32) -> Int? {
    let i = Int(handle & Self.indexMask) - 1
    guard i >= 0, i < slots.count, slots[i].object != nil, slots[i].generation == handle >> Self.indexBits else {
      return nil
    }
    return i
  }

  mutating func remove(_ i: Int) -> (KernelObject, Rights) {
    let taken = (slots[i].object!, slots[i].rights)
    slots[i].object = nil
    slots[i].generation = (slots[i].generation + 1) & (UInt32.max >> Self.indexBits)
    free.append(i)
    return taken
  }
}

// MARK: The kernel

public final class HostKernel: @unchecked Sendable {
  public static let shared = HostKernel()

  var lastKoid: UInt64 = 1023
  let lock = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
  let changed = UnsafeMutablePointer<pthread_cond_t>.allocate(capacity: 1)
  /// The calling thread's process.
  var currentKey = pthread_key_t()
  /// Each thread's one word for Sys.ThreadSlot.
  public var slotKey = pthread_key_t()
  /// The process a thread belongs to when the kernel didn't start it (the
  /// host's own threads: tests, tools, the hosted boot's first thread).
  var hostProcess: ProcessObject!
  var rootJob: JobObject!
  /// Every object_bind binding, in the order made.
  var bindings: [Bound] = []
  var futexWaiters: [FutexWaiter] = []
  var lastTxid: UInt32 = 0
  /// Ends a started thread's accounting when it exits, however it does
  /// (pthread_exit in a kernel call doesn't unwind Swift frames). Its
  /// destructor may run after the Swift runtime's thread-local state is
  /// gone, so this module is built without dynamic exclusivity checks,
  /// which use it (Package.swift; they crashed it now and then, M6k k4c).
  var endKey = pthread_key_t()

  init() {
    pthread_mutex_init(lock, nil)
    var attr = pthread_condattr_t()
    pthread_condattr_init(&attr)
    #if !canImport(Darwin)  // Darwin waits relative to now instead (awaitChange)
    pthread_condattr_setclock(&attr, CLOCK_MONOTONIC)
    #endif
    pthread_cond_init(changed, &attr)
    pthread_condattr_destroy(&attr)
    pthread_key_create(&currentKey, nil)
    pthread_key_create(&slotKey, nil)
    pthread_key_create(&endKey) { arg in
      let s = Unmanaged<HostKernel.Start>.fromOpaque((arg as UnsafeMutableRawPointer?)!).takeRetainedValue()
      s.kernel.threadEnded(s.thread)
    }
    rootJob = JobObject(self, type: ObjectType.job)
    rootJob.refs = 1  // the kernel's own reference
    hostProcess = ProcessObject(self, name: "host", job: rootJob)
    hostProcess.refs = 1
    hostProcess.started = true
    rootJob.processes.append(hostProcess)
  }

  /// Nanoseconds on the monotonic clock, the time base of every deadline.
  public static func now() -> Int64 {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec)
  }

  public static let infinite = Int64.max

  // MARK: Locking, the caller's process, kills

  /// The calling thread, if the kernel started it.
  var currentThread: ThreadObject? {
    guard let t = pthread_getspecific(currentKey) else { return nil }
    return Unmanaged<ThreadObject>.fromOpaque(t).takeUnretainedValue()
  }

  var current: ProcessObject { currentThread?.process ?? hostProcess }

  /// Runs `body` under the lock. A thread whose process was killed never
  /// returns from a kernel call: it exits here, as croi's do.
  func locked<R>(_ body: () throws(Status) -> R) throws(Status) -> R {
    pthread_mutex_lock(lock)
    exitIfKilled()
    defer { pthread_mutex_unlock(lock) }
    return try body()
  }

  /// Under the lock: ends the calling thread if it or its process was killed.
  func exitIfKilled() {
    guard let t = currentThread, t.killed || t.process.killed else { return }
    pthread_mutex_unlock(lock)
    pthread_exit(nil)
  }

  /// Waits for any change, until `deadline`; false if it passed.
  func awaitChange(until deadline: Int64) -> Bool {
    if deadline == Self.infinite {
      pthread_cond_wait(changed, lock)
    } else {
      if Self.now() >= deadline { return false }
      #if canImport(Darwin)
      // Darwin's condition variables have no clock attribute.
      let wait = deadline - Self.now()
      var ts = timespec(tv_sec: Int(wait / 1_000_000_000), tv_nsec: Int(wait % 1_000_000_000))
      pthread_cond_timedwait_relative_np(changed, lock, &ts)
      #else
      var ts = timespec(tv_sec: Int(deadline / 1_000_000_000), tv_nsec: Int(deadline % 1_000_000_000))
      pthread_cond_timedwait(changed, lock, &ts)
      #endif
    }
    exitIfKilled()
    return true
  }

  // MARK: Handles (under the lock)

  func install(_ object: KernelObject, _ rights: Rights, in process: ProcessObject? = nil) throws(Status) -> UInt32 {
    try (process ?? current).table.install(object, rights)
  }

  func lookup(_ handle: UInt32, _ needed: Rights) throws(Status) -> KernelObject {
    let p = current
    guard let i = p.table.index(handle) else { throw .badHandle }
    guard p.table.slots[i].rights.isSuperset(of: needed) else { throw .accessDenied }
    return p.table.slots[i].object!
  }

  /// Zircon's order of errors, as croi's: bad handle, wrong type, access denied.
  func lookup<T: KernelObject>(_ handle: UInt32, _ needed: Rights, as: T.Type) throws(Status) -> T {
    guard let o = try lookup(handle, []) as? T else { throw .wrongType }
    _ = try lookup(handle, needed)
    return o
  }

  /// Drops a reference; at the last, the object goes, and with it the
  /// bindings it was a source or port of.
  func release(_ object: KernelObject) {
    object.refs -= 1
    guard object.refs == 0 else { return }
    bindings.removeAll { $0.object === object || $0.port === object }
    object.lastReferenceGone(self)
  }

  /// Takes a handle out of the caller's table: the bindings made through
  /// it are cancelled, and the caller now holds its reference.
  func take(_ handle: UInt32) throws(Status) -> (KernelObject, Rights) {
    let p = current
    guard let i = p.table.index(handle) else { throw .badHandle }
    let taken = p.table.remove(i)
    let id = ObjectIdentifier(p)
    bindings.removeAll { $0.process == id && $0.handle == handle }
    pthread_cond_broadcast(changed)
    return taken
  }

  /// Under the lock: `packet` from binding `b` onto its port. A persistent
  /// binding's packet still queued takes it instead, counting it (a signal's
  /// payload[1], a change's payload[2]); a ONCE binding is done.
  func deliver(_ packet: Packet, from b: Bound) {
    if b.persistent, let i = b.port.packets.firstIndex(where: { $0.from === b }) {
      var queued = b.port.packets[i].packet
      if b.kind == CROI_BIND_CHANGE {
        queued.payload.1 = packet.payload.1
        queued.payload.2 += 1
        queued.payload.3 = packet.payload.3
      } else {
        queued.payload.0 = packet.payload.0
        queued.payload.1 += 1
        queued.payload.2 = packet.payload.2
      }
      b.port.packets[i].packet = queued
    } else {
      b.port.packets.append((packet, b))
    }
    if !b.persistent { bindings.removeAll { $0 === b } }
    pthread_cond_broadcast(changed)
  }

  /// A SIGNALS binding's packet: the signals that triggered it and those
  /// observed, a count of 1 and the time.
  func signalPacket(_ b: Bound, _ o: KernelObject) -> Packet {
    let met = o.signals & UInt32(truncatingIfNeeded: b.trigger)
    return Packet(key: b.key, type: CROI_PKT_TYPE_SIGNAL, status: 0,
                  payload: (UInt64(met) | UInt64(o.signals) << 32, 1, UInt64(Self.now()), 0))
  }

  /// Sets and clears an object's signals; wakes waiters and fires the
  /// SIGNALS bindings met. A level ONCE binding fires while one of its
  /// signals is asserted; an edge or persistent one when one rises, as the
  /// kernel's do (a message to a channel already READABLE fires nothing:
  /// its reader drains until shouldWait).
  func update(_ o: KernelObject, set: UInt32 = 0, clear: UInt32 = 0) {
    let before = o.signals
    o.signals = (o.signals & ~clear) | set
    guard o.signals != before else { return }
    for b in bindings where b.object === o && b.kind == CROI_BIND_SIGNALS {
      let wanted = UInt32(truncatingIfNeeded: b.trigger)
      let held = o.signals & wanted, rose = held & ~before
      let fires = b.edge || b.persistent ? rose != 0 : held != 0
      if fires { deliver(signalPacket(b, o), from: b) }
    }
    pthread_cond_broadcast(changed)
  }

  // MARK: Handle calls

  public func close(_ handle: UInt32) throws(Status) {
    try locked { () throws(Status) in
      let (object, _) = try take(handle)
      release(object)
    }
  }

  /// How many of the calling process's handles name threads that have
  /// ended: what tests look at to find a server that keeps its threads'.
  public func endedThreadHandles() -> Int {
    (try? locked { () throws(Status) -> Int in
      current.table.slots.reduce(0) { n, s in
        guard let t = s.object as? ThreadObject, t.signals & Signals.terminated != 0 else { return n }
        return n + 1
      }
    }) ?? 0
  }

  public func duplicate(_ handle: UInt32, rights: Rights) throws(Status) -> UInt32 {
    try locked { () throws(Status) in
      let p = current
      guard let i = p.table.index(handle) else { throw .badHandle }
      let have = p.table.slots[i].rights
      guard have.contains(.duplicate) else { throw .accessDenied }
      let object = p.table.slots[i].object!
      let r = rights == .sameRights ? have : rights
      guard have.isSuperset(of: r) else { throw .invalidArgs }
      object.refs += 1
      return try install(object, r)
    }
  }

  public func replace(_ handle: UInt32, rights: Rights) throws(Status) -> UInt32 {
    try locked { () throws(Status) in
      let p = current
      guard let i = p.table.index(handle) else { throw .badHandle }
      let have = p.table.slots[i].rights
      let r = rights == .sameRights ? have : rights
      let (object, _) = try take(handle)
      guard have.isSuperset(of: r) else {
        release(object)
        throw .invalidArgs
      }
      return try install(object, r)
    }
  }

  public struct HandleInfo: Equatable, Sendable {
    public var koid: UInt64
    public var rights: Rights
    public var type: UInt32
    public var relatedKoid: UInt64
  }

  /// object_get_info, topic HANDLE_BASIC.
  public func info(_ handle: UInt32) throws(Status) -> HandleInfo {
    try locked { () throws(Status) in
      let p = current
      guard let i = p.table.index(handle) else { throw .badHandle }
      let o = p.table.slots[i].object!
      return HandleInfo(koid: o.koid, rights: p.table.slots[i].rights, type: o.type, relatedKoid: o.relatedKoid)
    }
  }

  // MARK: Bindings and waits

  /// Under the lock: binds one item to port `p` (object_bind): the event
  /// at once if it has already come (a level SIGNALS binding with one
  /// asserted, a VALUE binding reached), else when it does. The item's
  /// status.
  func bind(_ item: Binding, to p: PortObject) -> Status {
    let kind = item.options & CROI_BIND_KIND_MASK
    let persistent = item.options & CROI_BIND_PERSISTENT != 0
    let edge = item.options & CROI_BIND_EDGE != 0
    guard item.options & ~(CROI_BIND_KIND_MASK | CROI_BIND_PERSISTENT | CROI_BIND_EDGE | CROI_BIND_TIMESTAMP) == 0,
          item.reserved == 0 else { return .invalidArgs }
    let o: KernelObject
    do throws(Status) {
      switch kind {
      case CROI_BIND_SIGNALS: o = try lookup(item.handle, .wait)
      case CROI_BIND_VALUE, CROI_BIND_CHANGE: o = try lookup(item.handle, [.wait, .read], as: CounterObject.self)
      default: return .notSupported  // no interrupts, deadline profiles or accounts hosted
      }
    } catch {
      return error
    }
    switch kind {
    case CROI_BIND_VALUE: guard !persistent, !edge else { return .invalidArgs }
    case CROI_BIND_CHANGE: guard persistent, !edge, item.trigger == 0 else { return .invalidArgs }
    default: break
    }
    let b = Bound(object: o, port: p, key: item.key, kind: kind, trigger: item.trigger, persistent: persistent,
                  edge: edge, process: ObjectIdentifier(current), handle: item.handle)
    bindings.append(b)
    if kind == CROI_BIND_SIGNALS, !edge, o.signals & UInt32(truncatingIfNeeded: item.trigger) != 0 {
      deliver(signalPacket(b, o), from: b)
    } else if kind == CROI_BIND_VALUE, let c = o as? CounterObject {
      reached(c)
    }
    return .ok
  }

  /// object_bind: binds each item to `port`, in order, stopping at the
  /// first that fails; each item done has its status written back. How
  /// many were bound.
  public func bind(_ port: UInt32, _ items: UnsafeMutableBufferPointer<Binding>) throws(Status) -> Int {
    try locked { () throws(Status) in
      guard items.count <= Int(CROI_BIND_MAX_ITEMS) else { throw .invalidArgs }
      let p = try lookup(port, .write, as: PortObject.self)
      for i in items.indices {
        let status = bind(items[i], to: p)
        items[i].status = status.rawValue
        if status != .ok { return i }
      }
      return items.count
    }
  }

  /// Waits for one binding's event until `deadline`: a ONCE binding to a
  /// port of the thread's own (as the floor's td_wait_bind), cancelled if
  /// the deadline passes first. Its packet.
  public func wait(_ item: Binding, deadline: Int64) throws(Status) -> Packet {
    try locked { () throws(Status) in
      let port = PortObject(self, type: ObjectType.port)
      var once = item
      once.options &= ~CROI_BIND_PERSISTENT
      let status = bind(once, to: port)
      guard status == .ok else { throw status }
      while port.packets.isEmpty {
        if !awaitChange(until: deadline) {
          bindings.removeAll { $0.port === port }
          throw .timedOut
        }
      }
      let packet = port.packets[0].packet
      guard packet.status == 0 else { throw Status(result: Int64(packet.status)) }
      return packet
    }
  }

  // MARK: Counters

  public func counterCreate() throws(Status) -> UInt32 {
    try locked { () throws(Status) in
      let c = CounterObject(self, type: ObjectType.counter)
      c.refs = 1
      c.signals = Signals.nonPositive
      return try install(c, .counterDefault)
    }
  }

  /// Under the lock: the VALUE bindings `c` has reached fire.
  func reached(_ c: CounterObject) {
    for b in bindings where b.object === c && b.kind == CROI_BIND_VALUE && c.value >= Int64(bitPattern: b.trigger) {
      deliver(Packet(key: b.key, type: CROI_PKT_TYPE_COUNTER, status: 0,
                     payload: (b.trigger, UInt64(bitPattern: c.value), UInt64(Self.now()), 0)), from: b)
    }
  }

  /// counter_add's array: each item's amount added to its counter, going on
  /// past one that fails (outOfRange, unchanged, on overflow); each item's
  /// status written back, and how many succeeded.
  public func counterAdd(_ items: UnsafeMutableBufferPointer<croi_counter_add_item_t>) throws(Status) -> Int {
    try locked { () throws(Status) in
      guard items.count <= Int(CROI_COUNTER_ADD_MAX_ITEMS) else { throw .invalidArgs }
      var done = 0
      for i in items.indices {
        do throws(Status) {
          let c = try lookup(items[i].counter, [.read, .write], as: CounterObject.self)
          let (sum, overflow) = c.value.addingReportingOverflow(items[i].amount)
          guard !overflow else { throw .outOfRange }
          c.value = sum
          for b in bindings where b.object === c && b.kind == CROI_BIND_CHANGE {
            deliver(Packet(key: b.key, type: CROI_PKT_TYPE_COUNTER_CHANGE, status: 0,
                           payload: (0, UInt64(bitPattern: sum), 1, UInt64(Self.now()))), from: b)
          }
          reached(c)
          update(c, set: sum > 0 ? Signals.positive : Signals.nonPositive,
                 clear: sum > 0 ? Signals.nonPositive : Signals.positive)
          items[i].status = 0
          done += 1
        } catch {
          items[i].status = error.rawValue
        }
      }
      return done
    }
  }

  public func counterRead(_ h: UInt32) throws(Status) -> Int64 {
    try locked { () throws(Status) in try lookup(h, .read, as: CounterObject.self).value }
  }

  func pair<T: Peered>(_ make: () -> T, _ rights: Rights) throws(Status) -> (UInt32, UInt32) {
    let a = make(), b = make()
    a.peer = b
    b.peer = a
    a.peerKoid = b.koid
    b.peerKoid = a.koid
    a.refs = 1
    b.refs = 1
    return (try install(a, rights), try install(b, rights))
  }

  // MARK: Channels

  public func channelCreate() throws(Status) -> (UInt32, UInt32) {
    try locked { () throws(Status) in
      let ends = try pair({ ChannelEnd(self, type: ObjectType.channel) }, .channelDefault)
      for h in [ends.0, ends.1] { update(try lookup(h, []), set: Signals.writable) }
      return ends
    }
  }

  /// Under the lock: takes `handles` out of the caller's table for a
  /// message on `end`. On any failure every one of them is closed, as in
  /// Zircon: a write consumes its handles whatever happens.
  func carry(_ handles: [UInt32], on end: ChannelEnd?, _ failure: inout Status?) -> [(object: KernelObject, rights: Rights)] {
    var carried: [(object: KernelObject, rights: Rights)] = []
    for h in handles {
      guard let (object, rights) = try? take(h) else {
        failure = failure ?? .badHandle
        continue
      }
      if !rights.contains(.transfer) { failure = failure ?? .accessDenied }
      if let end, object === end || object === end.peer { failure = failure ?? .notSupported }
      carried.append((object, rights))
    }
    return carried
  }

  /// Under the lock: delivers a message to `end`'s peer, or to the call
  /// waiting for it there.
  func deliver(_ message: ChannelEnd.Message, from end: ChannelEnd) {
    let peer = end.peer as! ChannelEnd
    if message.bytes.count >= 4 {
      let txid = UInt32(message.bytes[0]) | UInt32(message.bytes[1]) << 8 | UInt32(message.bytes[2]) << 16
        | UInt32(message.bytes[3]) << 24
      if let waiting = peer.calls[txid], waiting == nil {
        peer.calls[txid] = message
        pthread_cond_broadcast(changed)
        return
      }
    }
    peer.queue.append(message)
    update(peer, set: Signals.readable)
  }

  public func channelWrite(_ handle: UInt32, bytes: [UInt8], handles: [UInt32]) throws(Status) {
    try locked { () throws(Status) in
      var failure: Status? = nil
      var end: ChannelEnd? = nil
      do throws(Status) {
        end = try lookup(handle, .write, as: ChannelEnd.self)
      } catch {
        failure = error
      }
      let carried = carry(handles, on: end, &failure)
      if bytes.count > 65_536 || handles.count > 64 { failure = failure ?? .outOfRange }
      if failure == nil, end?.peer == nil { failure = .peerClosed }
      if let failure {
        for c in carried { release(c.object) }
        throw failure
      }
      deliver(.init(bytes: bytes, handles: carried), from: end!)
    }
  }

  /// A message's sizes.
  public struct ReadResult: Equatable, Sendable {
    public var byteCount: Int
    public var handleCount: Int
  }

  /// A failed read; `needed` is set when the status is `bufferTooSmall`.
  public struct ReadError: Error {
    public var status: Status
    public var needed: ReadResult
  }

  /// Reads the next message into the buffers, installing its handles. If the
  /// buffers are too small, the message stays queued and the error says
  /// what it needs.
  public func channelRead(_ handle: UInt32, bytes: UnsafeMutableRawBufferPointer,
                          handles: UnsafeMutableBufferPointer<UInt32>) throws(ReadError) -> ReadResult
  {
    pthread_mutex_lock(lock)
    exitIfKilled()
    defer { pthread_mutex_unlock(lock) }
    func fail(_ s: Status, _ needed: ReadResult = ReadResult(byteCount: 0, handleCount: 0)) -> ReadError {
      ReadError(status: s, needed: needed)
    }
    let end: ChannelEnd
    do {
      end = try lookup(handle, .read, as: ChannelEnd.self)
    } catch {
      throw fail(error)
    }
    guard let message = end.queue.first else { throw fail(end.peer == nil ? .peerClosed : .shouldWait) }
    let needed = ReadResult(byteCount: message.bytes.count, handleCount: message.handles.count)
    guard message.bytes.count <= bytes.count, message.handles.count <= handles.count else {
      throw fail(.bufferTooSmall, needed)
    }
    var installed: [UInt32] = []
    for carried in message.handles {
      do {
        installed.append(try install(carried.object, carried.rights))
      } catch {
        for h in installed { _ = current.table.remove(current.table.index(h)!) }
        throw fail(error)
      }
    }
    end.queue.removeFirst()
    if end.queue.isEmpty { update(end, clear: Signals.readable) }
    message.bytes.withUnsafeBytes { bytes.copyMemory(from: $0) }
    for (i, h) in installed.enumerated() { handles[i] = h }
    return needed
  }

  /// channel_write's array (D41): one message to each item's channel,
  /// going on past one that fails, each item's status written back; how
  /// many succeeded. Every item's handles are consumed.
  public func channelWrite(items: UnsafeMutableBufferPointer<croi_channel_write_item_t>) throws(Status) -> Int {
    guard items.count > 0, items.count <= Int(CROI_CHANNEL_MAX_ITEMS) else { throw .invalidArgs }
    var done = 0
    for i in items.indices {
      let item = items[i]
      let bytes = item.num_bytes == 0 ? [] : Array(UnsafeRawBufferPointer(
        start: UnsafeRawPointer(bitPattern: UInt(item.bytes)), count: Int(item.num_bytes)))
      let handles = item.num_handles == 0 ? [] : Array(UnsafeBufferPointer(
        start: UnsafePointer<UInt32>(bitPattern: UInt(item.handles)), count: Int(item.num_handles)))
      do throws(Status) {
        try channelWrite(item.channel, bytes: bytes, handles: handles)
        items[i].status = 0
        done += 1
      } catch {
        items[i].status = error.rawValue
      }
    }
    return done
  }

  /// channel_read's array (D41): one message from each item's channel into
  /// its buffers, going on past one that fails (`shouldWait`, or
  /// `bufferTooSmall` with the sizes it needs), each item's status and
  /// sizes written back; how many succeeded.
  public func channelRead(items: UnsafeMutableBufferPointer<croi_channel_read_item_t>) throws(Status) -> Int {
    guard items.count > 0, items.count <= Int(CROI_CHANNEL_MAX_ITEMS) else { throw .invalidArgs }
    var done = 0
    for i in items.indices {
      let item = items[i]
      let bytes = UnsafeMutableRawBufferPointer(
        start: UnsafeMutableRawPointer(bitPattern: UInt(item.bytes)), count: Int(item.num_bytes))
      let handles = UnsafeMutableBufferPointer(
        start: UnsafeMutablePointer<UInt32>(bitPattern: UInt(item.handles)), count: Int(item.num_handles))
      do throws(ReadError) {
        let got = try channelRead(item.channel, bytes: bytes, handles: handles)
        items[i].actual_bytes = UInt32(got.byteCount)
        items[i].actual_handles = UInt32(got.handleCount)
        items[i].status = 0
        done += 1
      } catch {
        items[i].actual_bytes = UInt32(error.needed.byteCount)
        items[i].actual_handles = UInt32(error.needed.handleCount)
        items[i].status = error.status.rawValue
      }
    }
    return done
  }

  /// A message read whole: its bytes, and its handles now the caller's.
  public struct Message: Sendable {
    public var bytes: [UInt8]
    public var handles: [UInt32]
  }

  /// channel_call: writes `bytes` (whose first four bytes the kernel sets
  /// to a txid of its own, high bit set) and waits for the reply that
  /// echoes it, which comes straight to this caller, never to a read.
  public func channelCall(_ handle: UInt32, bytes: [UInt8], handles: [UInt32], deadline: Int64) throws(Status)
    -> Message
  {
    try locked { () throws(Status) in
      var failure: Status? = nil
      var found: ChannelEnd? = nil
      do throws(Status) {
        found = try lookup(handle, [.read, .write], as: ChannelEnd.self)
      } catch {
        failure = error
      }
      let carried = carry(handles, on: found, &failure)
      if bytes.count < 4 || bytes.count > 65_536 || handles.count > 64 { failure = failure ?? .invalidArgs }
      if failure == nil, found?.peer == nil { failure = .peerClosed }
      if let failure {
        for c in carried { release(c.object) }
        throw failure
      }
      let end = found!
      repeat { lastTxid = (lastTxid &+ 1) & 0x7FFF_FFFF } while end.calls[lastTxid | 0x8000_0000] != nil
      let txid = lastTxid | 0x8000_0000
      var message = bytes
      for i in 0..<4 { message[i] = UInt8(truncatingIfNeeded: txid >> (8 * UInt32(i))) }
      end.calls[txid] = .some(nil)
      deliver(.init(bytes: message, handles: carried), from: end)
      while true {
        if case .some(.some(let reply)) = end.calls[txid] {
          end.calls[txid] = nil
          var installed: [UInt32] = []
          for c in reply.handles { installed.append(try install(c.object, c.rights)) }
          return Message(bytes: reply.bytes, handles: installed)
        }
        if end.peer == nil {
          end.calls[txid] = nil
          throw .peerClosed
        }
        if !awaitChange(until: deadline) {
          end.calls[txid] = nil
          throw .timedOut
        }
      }
    }
  }

  // MARK: Ports

  /// How many packets a port holds before port_queue says shouldWait.
  static let portCapacity = 4096

  /// port_create: no options hosted (no interrupts to bind, no rings).
  public func portCreate(options: UInt32) throws(Status) -> UInt32 {
    try locked { () throws(Status) in
      guard options == 0 else { throw .notSupported }
      let p = PortObject(self, type: ObjectType.port)
      p.refs = 1
      return try install(p, .portDefault)
    }
  }

  /// port_queue: user packets, in order, stopping at the first the port
  /// has no room for; how many went, or shouldWait if none did.
  public func portQueue(_ port: UInt32, _ packets: UnsafeBufferPointer<Packet>) throws(Status) -> Int {
    try locked { () throws(Status) in
      guard packets.count > 0, packets.count <= Int(CROI_PORT_MAX_PACKETS) else { throw .invalidArgs }
      let p = try lookup(port, .write, as: PortObject.self)
      var done = 0
      for packet in packets where p.packets.count < Self.portCapacity {
        var user = packet
        user.type = CROI_PKT_TYPE_USER
        p.packets.append((user, nil))
        done += 1
      }
      guard done > 0 else { throw .shouldWait }
      pthread_cond_broadcast(changed)
      return done
    }
  }

  /// port_wait: up to `packets.count`, waiting until `deadline` while the
  /// port is empty; how many.
  public func portWait(_ port: UInt32, deadline: Int64, _ packets: UnsafeMutableBufferPointer<Packet>) throws(Status)
    -> Int
  {
    try locked { () throws(Status) in
      guard packets.count > 0, packets.count <= Int(CROI_PORT_MAX_PACKETS) else { throw .invalidArgs }
      let p = try lookup(port, .read, as: PortObject.self)
      while p.packets.isEmpty {
        guard current.table.index(port) != nil else { throw .canceled }
        if !awaitChange(until: deadline) { throw .timedOut }
      }
      let n = min(packets.count, p.packets.count)
      for i in 0..<n { packets[i] = p.packets[i].packet }
      p.packets.removeFirst(n)
      return n
    }
  }

  /// port_cancel, as the kernel's: undoes the bindings to the port with
  /// `key` made through handle `source`, and drops their queued packets;
  /// with source 0, every binding and queued packet with `key` (user
  /// packets too). Either way, notFound if there were none.
  public func portCancel(_ port: UInt32, source: UInt32, key: UInt64) throws(Status) {
    try locked { () throws(Status) in
      let p = try lookup(port, .write, as: PortObject.self)
      let id = ObjectIdentifier(current)
      if source != 0 { _ = try lookup(source, .wait) }
      func matches(_ b: Bound) -> Bool {
        b.port === p && b.key == key && (source == 0 || (b.process == id && b.handle == source))
      }
      let before = bindings.count, queued = p.packets.count
      bindings.removeAll(where: matches)
      p.packets.removeAll { q in q.from.map(matches) ?? (source == 0 && q.packet.key == key) }
      guard bindings.count < before || p.packets.count < queued else { throw .notFound }
    }
  }

  // MARK: VMOs

  public func vmoCreate(size: Int) throws(Status) -> UInt32 {
    try locked { () throws(Status) in
      guard size >= 0, size <= 1 << 34 else { throw .outOfRange }
      let v = VMOObject(self, size: (size + 4095) & ~4095)
      v.refs = 1
      return try install(v, .vmoDefault)
    }
  }

  public func vmoSize(_ handle: UInt32) throws(Status) -> Int {
    try locked { () throws(Status) in try lookup(handle, [], as: VMOObject.self).size }
  }

  /// Maps a VMO's range; the mapping keeps the VMO alive until `unmap`.
  /// Hosted, every process shares one address space, so a mapping is
  /// the VMO's own memory.
  public func vmoMap(_ handle: UInt32, offset: Int, length: Int, writable: Bool) throws(Status) -> UnsafeMutableRawPointer {
    try locked { () throws(Status) in
      let v = try lookup(handle, writable ? [.map, .read, .write] : [.map, .read], as: VMOObject.self)
      guard offset >= 0, length > 0, offset % 4096 == 0, offset <= v.size, length <= v.size - offset else {
        throw .outOfRange
      }
      v.refs += 1
      mappings.append((v.base + offset, v))
      return v.base + offset
    }
  }

  var mappings: [(address: UnsafeMutableRawPointer, vmo: VMOObject)] = []

  public func vmoUnmap(_ address: UnsafeMutableRawPointer) throws(Status) {
    try locked { () throws(Status) in
      guard let i = mappings.firstIndex(where: { $0.address == address }) else { throw .notFound }
      let v = mappings.remove(at: i).vmo
      release(v)
    }
  }

  // MARK: Jobs, processes, threads

  /// A handle to the root job, for the hosted boot (natively userboot
  /// passes it to the launcher).
  public func rootJobHandle() throws(Status) -> UInt32 {
    try locked { () throws(Status) in
      rootJob.refs += 1
      return try install(rootJob, .jobDefault)
    }
  }

  public func jobCreate(parent: UInt32) throws(Status) -> UInt32 {
    try locked { () throws(Status) in
      let parent = try lookup(parent, .manageJob, as: JobObject.self)
      guard !parent.killed else { throw .badState }
      let j = JobObject(self, type: ObjectType.job)
      j.parent = parent
      j.refs = 1
      parent.children.append(j)
      return try install(j, .jobDefault)
    }
  }

  public func processCreate(job: UInt32, name: String) throws(Status) -> UInt32 {
    try locked { () throws(Status) in
      let job = try lookup(job, .manageProcess, as: JobObject.self)
      guard !job.killed else { throw .badState }
      let p = ProcessObject(self, name: name, job: job)
      p.refs = 1
      job.processes.append(p)
      return try install(p, .processDefault)
    }
  }

  public func threadCreate(process: UInt32) throws(Status) -> UInt32 {
    try locked { () throws(Status) in
      let p = try lookup(process, .manageThread, as: ProcessObject.self)
      guard !p.killed else { throw .badState }
      let t = ThreadObject(self, process: p)
      t.refs = 1
      p.refs += 1  // a thread keeps its process
      return try install(t, .threadDefault)
    }
  }

  final class Start {
    let kernel: HostKernel
    let thread: ThreadObject
    let body: ([UInt32]) -> Void
    let args: [UInt32]
    init(_ kernel: HostKernel, _ thread: ThreadObject, _ body: @escaping ([UInt32]) -> Void, _ args: [UInt32]) {
      self.kernel = kernel
      self.thread = thread
      self.body = body
      self.args = args
    }
  }

  /// Starts a thread running `body` in its process. `args`, handles of the
  /// caller's, move into that process first (process_start's bootstrap
  /// message: all of them, or none if one is bad, the rest closed), and
  /// `body` gets their numbers there.
  public func threadStart(_ thread: UInt32, args: [UInt32] = [], _ body: @escaping ([UInt32]) -> Void) throws(Status) {
    try locked { () throws(Status) in
      let t = try lookup(thread, .write, as: ThreadObject.self)
      guard !t.started, !t.process.killed else { throw .badState }
      var taken: [(KernelObject, Rights)] = []
      var bad: Status?
      for a in args {
        do throws(Status) { taken.append(try take(a)) } catch { bad = bad ?? error }
      }
      if let bad {
        for (o, _) in taken { release(o) }
        throw bad
      }
      var argsInProcess: [UInt32] = []
      for (o, r) in taken { argsInProcess.append(try install(o, r, in: t.process)) }
      t.started = true
      t.process.started = true
      t.process.running += 1
      t.refs += 1  // the running thread's own reference
      update(t, set: Signals.threadRunning)
      let start = Unmanaged.passRetained(Start(self, t, body, argsInProcess)).toOpaque()
      #if canImport(Darwin)
      var pt: pthread_t?  // a pointer on Darwin
      #else
      var pt = pthread_t()
      #endif
      guard pthread_create(&pt, nil, { arg in
        let s = Unmanaged<Start>.fromOpaque((arg as UnsafeMutableRawPointer?)!).takeRetainedValue()
        pthread_setspecific(s.kernel.currentKey, Unmanaged.passUnretained(s.thread).toOpaque())
        // The end key's destructor accounts for the thread's end, whether
        // the body returns or the thread exits in a kernel call.
        pthread_setspecific(s.kernel.endKey, Unmanaged.passRetained(s).toOpaque())
        s.body(s.args)
        return nil
      }, start) == 0 else { throw .noResources }
      #if canImport(Darwin)
      pthread_detach(pt!)
      #else
      pthread_detach(pt)
      #endif
    }
  }

  /// A thread finished: its process ends when its last thread does.
  func threadEnded(_ t: ThreadObject) {
    pthread_mutex_lock(lock)
    defer { pthread_mutex_unlock(lock) }
    finish(t)
  }

  /// Under the lock.
  func finish(_ t: ThreadObject) {
    guard t.signals & Signals.terminated == 0 else { return }
    t.killed = true
    update(t, set: Signals.terminated, clear: Signals.threadRunning)
    t.process.running -= 1
    // The host's process is the Linux process: threads the kernel started
    // in it (Thread.spawn from a test or tool) don't end it.
    if t.process.running == 0 && t.process !== hostProcess { terminate(t.process, code: t.process.returnCode) }
    release(t)  // the running thread's own reference
  }

  /// Under the lock: a process ends. Its handles close, its threads exit
  /// at their next kernel call, and it signals TERMINATED.
  func terminate(_ p: ProcessObject, code: Int64) {
    guard p.signals & Signals.terminated == 0 else { return }
    p.killed = true
    p.returnCode = code
    var held: [KernelObject] = []
    for i in p.table.slots.indices where p.table.slots[i].object != nil { held.append(p.table.remove(i).0) }
    for o in held { release(o) }
    update(p, set: Signals.terminated)
    if let job = p.job { job.processes.removeAll { $0 === p } }
  }

  func kill(_ job: JobObject) {
    job.killed = true
    for p in job.processes { terminate(p, code: -1024) }
    for c in job.children { kill(c) }
    update(job, set: Signals.terminated)
  }

  /// task_kill: a job (and all under it), a process, or a thread.
  public func kill(_ task: UInt32) throws(Status) {
    try locked { () throws(Status) in
      let o = try lookup(task, [])
      guard o is TaskObject else { throw .wrongType }
      _ = try lookup(task, .destroy)
      switch o {
      case let j as JobObject: kill(j)
      case let p as ProcessObject: terminate(p, code: -1024)
      case let t as ThreadObject:
        // It exits at its next kernel call, or now if it is waiting in one.
        t.killed = true
        pthread_cond_broadcast(changed)
      default: throw .wrongType
      }
    }
  }

  /// A handle to the calling process (natively, processargs' PROC_SELF).
  public func processSelf() throws(Status) -> UInt32 {
    try locked { () throws(Status) in
      let p = current
      p.refs += 1
      return try install(p, .processDefault)
    }
  }

  // MARK: Futexes

  /// A thread waiting on a futex word, until a wake marks it.
  final class FutexWaiter {
    let address: UInt
    let thread: ThreadObject?
    var woken = false
    init(address: UInt, thread: ThreadObject?) {
      self.address = address
      self.thread = thread
    }
  }

  /// futex_wait: sleeps while the word at `address` holds `current`, until
  /// a wake or `deadline`. `badState` if the word had already changed. The
  /// word is read under the kernel's lock, which a wake takes too, so no
  /// wake falls between the check and the sleep.
  public func futexWait(_ address: UnsafeMutablePointer<UInt32>, current value: UInt32, deadline: Int64) throws(Status) {
    try locked { () throws(Status) in
      let word = unsafe UnsafeRawPointer(address).assumingMemoryBound(to: Atomic<UInt32>.self)
      guard unsafe word.pointee.load(ordering: .sequentiallyConsistent) == value else { throw .badState }
      let waiter = FutexWaiter(address: UInt(bitPattern: address), thread: currentThread)
      futexWaiters.append(waiter)
      defer { futexWaiters.removeAll { $0 === waiter } }
      while !waiter.woken {
        if !awaitChange(until: deadline) { throw .timedOut }
      }
    }
  }

  /// futex_wake: wakes up to `count` threads waiting on `address`. A
  /// waiter whose thread was killed takes no wake.
  public func futexWake(_ address: UnsafeMutablePointer<UInt32>, count: Int) {
    try? locked { () throws(Status) in
      let a = UInt(bitPattern: address)
      var woken = 0
      for w in futexWaiters where woken < count && !w.woken && w.address == a {
        if let t = w.thread, t.killed || t.process.killed { continue }
        w.woken = true
        woken += 1
      }
      if woken > 0 { pthread_cond_broadcast(changed) }
    }
  }

  /// process_exit: the calling process ends with `code`; never returns.
  /// The host's own threads have no hosted process to end: the Linux
  /// process exits.
  public func exit(code: Int64) -> Never {
    pthread_mutex_lock(lock)
    let p = current
    guard p !== hostProcess else {
      pthread_mutex_unlock(lock)
      hostExit(Int32(truncatingIfNeeded: code))
    }
    terminate(p, code: code)
    pthread_mutex_unlock(lock)
    pthread_exit(nil)
  }

  public struct ProcessInfo: Equatable, Sendable {
    public var returnCode: Int64
    public var started: Bool
    public var exited: Bool
  }

  public func processInfo(_ process: UInt32) throws(Status) -> ProcessInfo {
    try locked { () throws(Status) in
      let p = try lookup(process, .inspect, as: ProcessObject.self)
      return ProcessInfo(returnCode: p.returnCode, started: p.started, exited: p.signals & Signals.terminated != 0)
    }
  }

  /// Sleeps until `deadline` (nanosleep).
  public func sleep(until deadline: Int64) {
    pthread_mutex_lock(lock)
    exitIfKilled()
    while HostKernel.now() < deadline { _ = awaitChange(until: deadline) }
    pthread_mutex_unlock(lock)
  }
}

/// The rights each object's first handle has: the kernel's defaults
/// (Zircon's, less what V1 cut).
extension Rights {
  static var channelDefault: Rights { Rights.basic.subtracting(.duplicate).union([.read, .write, .signal]) }
  static var portDefault: Rights { Rights.basic.subtracting(.wait).union([.read, .write]) }
  static var vmoDefault: Rights { Rights.basic.union([.read, .write, .map, .getProperty, .setProperty, .signal]) }
  static var counterDefault: Rights { Rights.basic.union([.read, .write, .signal]) }
  static var jobDefault: Rights {
    Rights.basic.union([.read, .write, .getProperty, .setProperty, .getPolicy, .setPolicy, .enumerate, .destroy,
                        .signal, .manageJob, .manageProcess, .manageThread])
  }
  static var processDefault: Rights {
    Rights.basic.union([.read, .write, .getProperty, .setProperty, .enumerate, .destroy, .signal, .manageProcess,
                        .manageThread])
  }
  static var threadDefault: Rights {
    Rights.basic.union([.read, .write, .getProperty, .setProperty, .destroy, .signal, .manageThread])
  }
}

/// The C library's exit, which HostKernel's own `exit(code:)` hides.
private func hostExit(_ code: Int32) -> Never { exit(code) }
