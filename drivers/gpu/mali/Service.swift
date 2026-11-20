// SPDX-License-Identifier: BSD-3-Clause

// The `csf` capset's server (D173 section 7, panthor 10 and 07 section
// 7.13): every context's VMs, buffers, binds, groups, syncs and
// submissions, over the scheduler (Scheduler.swift) and a backend. It is
// generic over `CSFBackend`, which is what the driver host's Device
// implements over the GPU's registers, page tables and memory and the
// host tests implement over a model: this file touches no register and
// no handle, and speaks no IPC (ServiceIPC.swift is the protocol's
// side). One service serves every client of the device: one scheduler,
// one pool of address spaces, one set of firmware slots; a client's
// tables (its handles) are its own.
//
// Time passes in `pump`, which the host calls on the job interrupt, on
// the tick (`nextWake`) and after every call that changes work: it takes
// the firmware's events, runs the scheduler, raises the counters of what
// finished and frees what ended. The tables are arrays, scanned: a
// client has at most a few hundred of anything, and tier 0 has no hashed
// collections.

#if canImport(Mali)
  import Mali
#endif

/// Why a call failed; the protocol's `GPUError`, case for case.
public enum CSFServiceError: Error, Equatable, Sendable {
  case invalid
  case notFound
  case unavailable
  case noMemory
  case lost
}

/// What the device and its firmware report.
public struct CSFDeviceInfo: Equatable, Sendable {
  public var gpuID: UInt32
  public var csfID: UInt32
  public var interfaceVersion: UInt32
  public var features: UInt64
  public var shaderPresent: UInt64
  public var tilerPresent: UInt64
  public var l2Present: UInt64
  public var asPresent: UInt32
  public var vaBits: Int
  public var groupSlots: Int
  public var queuesPerGroup: Int
  public var workRegisters: Int
  public var scoreboards: Int
  /// THREAD_MAX_THREADS, THREAD_MAX_WORKGROUP_SIZE, THREAD_MAX_BARRIER_SIZE and THREAD_FEATURES.
  public var threadMaxThreads: UInt32
  public var threadMaxWorkgroupSize: UInt32
  public var threadMaxBarrierSize: UInt32
  public var threadFeatures: UInt32
  public init(gpuID: UInt32, csfID: UInt32 = 0, interfaceVersion: UInt32 = 0, features: UInt64 = 0,
              shaderPresent: UInt64 = 0, tilerPresent: UInt64 = 0, l2Present: UInt64 = 0, asPresent: UInt32,
              vaBits: Int, groupSlots: Int, queuesPerGroup: Int, workRegisters: Int, scoreboards: Int,
              threadMaxThreads: UInt32 = 0, threadMaxWorkgroupSize: UInt32 = 0, threadMaxBarrierSize: UInt32 = 0,
              threadFeatures: UInt32 = 0) {
    self.gpuID = gpuID
    self.csfID = csfID
    self.interfaceVersion = interfaceVersion
    self.features = features
    self.shaderPresent = shaderPresent
    self.tilerPresent = tilerPresent
    self.l2Present = l2Present
    self.asPresent = asPresent
    self.vaBits = vaBits
    self.groupSlots = groupSlots
    self.queuesPerGroup = queuesPerGroup
    self.workRegisters = workRegisters
    self.scoreboards = scoreboards
    self.threadMaxThreads = threadMaxThreads
    self.threadMaxWorkgroupSize = threadMaxWorkgroupSize
    self.threadMaxBarrierSize = threadMaxBarrierSize
    self.threadFeatures = threadFeatures
  }
}

/// A bind's attributes (panthor 10 section 10.4.3: READONLY, NOEXEC,
/// UNCACHED), as the GPU's tables take them.
public struct CSFMapFlags: Equatable, Sendable {
  public var readOnly: Bool
  public var noExec: Bool
  public var uncached: Bool
  public init(readOnly: Bool = false, noExec: Bool = false, uncached: Bool = false) {
    self.readOnly = readOnly
    self.noExec = noExec
    self.uncached = uncached
  }
}

/// A queue's kernel memory in its group's VM: its ring, its sync object (16
/// bytes, in the group's array of them) and its profiling slots.
public struct CSFQueueMemory: Equatable, Sendable {
  public var ringVA: UInt64
  public var ringSize: Int
  public var syncVA: UInt64
  public var profilingVA: UInt64
}

/// A job as the service takes it: the protocol's `Job`.
public struct CSFJob: Equatable, Sendable {
  public var queue: UInt32
  public var stream: UInt64
  public var size: UInt32
  public var flush: UInt32
  public init(queue: UInt32, stream: UInt64, size: UInt32, flush: UInt32) {
    self.queue = queue
    self.stream = stream
    self.size = size
    self.flush = flush
  }
}

/// A sync as the service takes it: a counter's id and the value to wait
/// for or to raise it to.
public struct CSFSync: Equatable, Sendable {
  public var id: UInt32
  public var value: UInt64
  public init(id: UInt32, value: UInt64) {
    self.id = id
    self.value = value
  }
}

/// What the service needs of a device beyond the firmware's interface (the
/// scheduler's `FirmwareLink`, which the backend is, and which the
/// scheduler holds as `link`): memory, page tables, counters, the clock.
/// A VM, a group and a buffer are named as the scheduler and the service
/// name them: by the integer they were given.
public protocol CSFBackend: FirmwareLink {
  var device: CSFDeviceInfo { get }
  /// Nanoseconds since some start, monotonic.
  var nanoseconds: UInt64 { get }
  /// The size of a client's CPU address space, if the GPU's addresses are
  /// to line up with it by default (0: not).
  var userAddressSpace: UInt64 { get }

  /// Pinned write-combining memory of `size` bytes (the GPU page rounded;
  /// the backend may round to its own), zeroed. Its key, or nil.
  mutating func allocateBuffer(size: UInt64) -> Int?
  /// Free it. Its mappings are gone by then.
  mutating func freeBuffer(_ buffer: Int)

  /// A VM's page tables (an empty tree), for the scheduler's VM `vm`.
  mutating func createVM(_ vm: Int) -> Bool
  /// The VM's tables and every mapping of its (user and kernel) go.
  mutating func destroyVM(_ vm: Int)
  /// Map `size` bytes of the buffer from `offset` at `va`, replacing what
  /// was there, and flush: all multiples of the GPU page. False if the
  /// tables can't grow.
  mutating func map(vm: Int, buffer: Int, offset: UInt64, size: UInt64, va: UInt64, flags: CSFMapFlags) -> Bool
  /// Unmap a range (parts of it may be unmapped already) and flush.
  mutating func unmap(vm: Int, va: UInt64, size: UInt64)

  /// A group's kernel memory: the rings and sync objects at the addresses
  /// the service chose in the group's VM (its kernel region), mapped
  /// non-executable and uncached, zeroed, plus the firmware's own (suspend
  /// buffers, queue control areas). False if the memory isn't there.
  mutating func attachGroup(group: Int, vm: Int, queues: [CSFQueueMemory]) -> Bool
  /// After the scheduler forgot the group: all of it freed and unmapped.
  mutating func detachGroup(group: Int)

  /// A client's counter, by the raw handle value the service was given:
  /// its value now.
  func counterValue(_ counter: UInt32) -> UInt64
  /// Raise it to `value` (by adding the difference, if it is lower: counters
  /// only add, D25).
  mutating func raiseCounter(_ counter: UInt32, to value: UInt64)
  /// The service lets it go: close the handle.
  mutating func closeCounter(_ counter: UInt32)
}

public struct CSFService<Backend: CSFBackend> {
  // 10.4.1: 32 VMs a client; 10.6.1: 128 groups a client.
  public static var maxVMs: Int { 32 }
  public static var maxGroups: Int { 128 }
  public static var maxBuffers: Int { 4096 }
  public static var maxSyncs: Int { 1024 }
  public static var maxJobs: Int { 256 }
  /// A buffer's most bytes, and a context's all together.
  public static var maxBufferSize: UInt64 { 1 << 32 }
  public static var maxContextBytes: UInt64 { 4 << 30 }

  struct Binding {
    var va: UInt64
    var size: UInt64
    var buffer: UInt32
    var offset: UInt64
    var flags: CSFMapFlags
  }

  /// A VM, by the scheduler's id for it (never reused).
  struct VMRecord {
    var context: Int
    var layout: UserVMLayout
    var bindings: [Binding] = []
    var liveGroups = 0
    /// Its handle is gone: it goes when its last group does.
    var dying = false
    var gone = false
  }

  struct BufferRecord {
    var id: UInt32
    var key: Int
    var size: UInt64
    /// The binds that map it.
    var refs = 0
    var closed = false
  }

  struct GroupRecord {
    var sched: Int
    /// The scheduler's VM.
    var vm: Int
    var queues: [CSFQueueMemory]
    var syncBase: UInt64
    var syncSize: UInt64
  }

  struct Sync {
    var id: UInt32
    var counter: UInt32
  }

  struct Context {
    /// Handle h is slot h - 1: the scheduler's VM.
    var vms = [Int?](repeating: nil, count: CSFService.maxVMs)
    var groups = [GroupRecord?](repeating: nil, count: CSFService.maxGroups)
    var buffers: [BufferRecord] = []
    var nextBuffer: UInt32 = 1
    var bytes: UInt64 = 0
    var syncs: [Sync] = []
    var nextSync: UInt32 = 1
    var lost = false
  }

  struct Submission {
    var id: Int
    var context: Int
    var group: Int
    var jobs: [CSFJob]
    var waits: [CSFSync]
    var signals: [CSFSync]
    var issued = 0
    var remaining: Int
  }

  public var scheduler: GroupScheduler<Backend>
  /// The group priorities a context may have (bit p: priority p). A
  /// context holds no privilege here, so high and realtime wait for one.
  public var allowedPriorities: UInt32 = 0b0011
  var contexts: [Context?] = []
  var vms: [VMRecord] = []
  /// Groups their client let go of, until the scheduler has too.
  var zombies: [GroupRecord] = []
  /// Submissions with jobs still to go to rings, in order.
  var pending: [Submission] = []
  /// Submissions whose jobs are all on rings, awaiting their completions.
  var submitted: [Submission] = []
  /// Job tag to submission id, of the jobs on rings.
  var tags: [(tag: UInt64, submission: Int)] = []
  var nextTag: UInt64 = 1
  var nextSubmission = 1

  public init(backend: Backend) {
    let d = backend.device
    var config = SchedulerConfig(
      asPresent: d.asPresent, shape: JobSequenceShape(workRegisters: d.workRegisters, scoreboards: d.scoreboards))
    // The per-context limit is the service's.
    config.maxGroups = 4096
    scheduler = GroupScheduler(link: backend, config: config)
  }

  public var device: CSFDeviceInfo { scheduler.link.device }

  // MARK: Contexts

  public mutating func openContext() -> Int {
    for i in 0..<contexts.count where contexts[i] == nil {
      contexts[i] = Context()
      return i
    }
    contexts.append(Context())
    return contexts.count - 1
  }

  /// Everything of the context goes: its groups end, its VMs and buffers
  /// with them, its counters are closed.
  public mutating func closeContext(_ c: Int) {
    guard c >= 0, c < contexts.count, contexts[c] != nil else { return }
    pending.removeAll { $0.context == c }
    submitted.removeAll { $0.context == c }
    for h in 0..<Self.maxGroups where contexts[c]!.groups[h] != nil { try? destroyGroup(c, UInt32(h + 1)) }
    for h in 0..<Self.maxVMs where contexts[c]!.vms[h] != nil { try? destroyVM(c, UInt32(h + 1)) }
    for b in contexts[c]!.buffers { try? destroyBuffer(c, b.id) }
    for s in contexts[c]!.syncs { scheduler.link.closeCounter(s.counter) }
    contexts[c] = nil
    reap()
  }

  func context(_ c: Int) throws(CSFServiceError) -> Context {
    guard c >= 0, c < contexts.count, let x = contexts[c] else { throw .invalid }
    return x
  }

  /// Whether the context's work can no longer run (a group of it ended, or
  /// the device is lost).
  public func isLost(_ c: Int) -> Bool {
    scheduler.deviceLost || (c >= 0 && c < contexts.count && contexts[c]?.lost == true)
  }

  // MARK: VMs

  /// 10.4.1. The handle, and where the client's addresses end.
  public mutating func createVM(_ c: Int, userRange: UInt64) throws(CSFServiceError) -> (id: UInt32, userRange: UInt64) {
    _ = try context(c)
    if scheduler.deviceLost { throw .lost }
    guard let slot = contexts[c]!.vms.firstIndex(where: { $0 == nil }) else { throw .unavailable }
    let layout: UserVMLayout
    do {
      layout = try UserVMLayout(
        vaBits: scheduler.link.device.vaBits, userSize: userRange, cpuSpace: scheduler.link.userAddressSpace)
    } catch { throw .invalid }
    let vm = scheduler.createVM()
    guard scheduler.link.createVM(vm) else {
      try? scheduler.destroyVM(vm)
      throw .noMemory
    }
    while vms.count <= vm { vms.append(VMRecord(context: -1, layout: layout, gone: true)) }
    vms[vm] = VMRecord(context: c, layout: layout)
    contexts[c]!.vms[slot] = vm
    return (UInt32(slot + 1), layout.kernelStart)
  }

  /// 10.4.2: the handle goes now; its mappings too, so work still on it
  /// faults; the VM itself when its groups are gone.
  public mutating func destroyVM(_ c: Int, _ handle: UInt32) throws(CSFServiceError) {
    let vm = try vmID(c, handle)
    contexts[c]!.vms[Int(handle) - 1] = nil
    dropBindings(vm: vm, lo: 0, hi: UInt64.max)
    vms[vm].dying = true
    reap()
  }

  func vmID(_ c: Int, _ handle: UInt32) throws(CSFServiceError) -> Int {
    let x = try context(c)
    guard handle >= 1, Int(handle) <= Self.maxVMs, let vm = x.vms[Int(handle) - 1] else { throw .invalid }
    return vm
  }

  // MARK: Buffers

  func bufferIndex(_ c: Int, _ id: UInt32) -> Int? { contexts[c]!.buffers.firstIndex { $0.id == id } }

  /// BO_CREATE: `flags` is 0. The size comes back rounded to the GPU page;
  /// `key` is the backend's, for the host to make the VMO from.
  public mutating func createBuffer(_ c: Int, size: UInt64, flags: UInt32) throws(CSFServiceError)
    -> (id: UInt32, key: Int, size: UInt64)
  {
    _ = try context(c)
    guard flags == 0, size > 0, size <= Self.maxBufferSize, let rounded = VARegion.rounded(size) else { throw .invalid }
    if contexts[c]!.buffers.count >= Self.maxBuffers || contexts[c]!.bytes + rounded > Self.maxContextBytes {
      throw .unavailable
    }
    guard let key = scheduler.link.allocateBuffer(size: rounded) else { throw .noMemory }
    var id = contexts[c]!.nextBuffer
    while bufferIndex(c, id) != nil { id = id &+ 1 == 0 ? 1 : id &+ 1 }
    contexts[c]!.nextBuffer = id &+ 1 == 0 ? 1 : id &+ 1
    contexts[c]!.buffers.append(BufferRecord(id: id, key: key, size: rounded))
    contexts[c]!.bytes += rounded
    return (id, key, rounded)
  }

  /// The handle goes now; the memory when nothing maps it.
  public mutating func destroyBuffer(_ c: Int, _ id: UInt32) throws(CSFServiceError) {
    _ = try context(c)
    guard let i = bufferIndex(c, id), !contexts[c]!.buffers[i].closed else { throw .notFound }
    contexts[c]!.buffers[i].closed = true
    releaseBufferIfDone(c, id)
  }

  mutating func releaseBufferIfDone(_ c: Int, _ id: UInt32) {
    guard let i = bufferIndex(c, id) else { return }
    let b = contexts[c]!.buffers[i]
    guard b.closed, b.refs == 0 else { return }
    scheduler.link.freeBuffer(b.key)
    contexts[c]!.bytes -= b.size
    contexts[c]!.buffers.remove(at: i)
  }

  // MARK: Binds

  /// 10.4.3's synchronous MAP: page multiples, inside the user range, the
  /// buffer holds the range; it replaces what overlaps, splitting.
  public mutating func bind(
    _ c: Int, vm handle: UInt32, buffer id: UInt32, offset: UInt64, size: UInt64, address: UInt64, flags: UInt32
  ) throws(CSFServiceError) {
    let vm = try vmID(c, handle)
    if scheduler.deviceLost { throw .lost }
    guard flags & ~0b111 == 0 else { throw .invalid }
    do { try vms[vm].layout.validateBind(va: address, size: size) } catch { throw .invalid }
    guard offset & (gpuPageSize - 1) == 0 else { throw .invalid }
    guard let i = bufferIndex(c, id), !contexts[c]!.buffers[i].closed else { throw .invalid }
    let b = contexts[c]!.buffers[i]
    guard offset <= b.size, size <= b.size - offset else { throw .invalid }
    let f = CSFMapFlags(readOnly: flags & 1 != 0, noExec: flags & 2 != 0, uncached: flags & 4 != 0)
    dropBindings(vm: vm, lo: address, hi: address + size)
    guard scheduler.link.map(vm: vm, buffer: b.key, offset: offset, size: size, va: address, flags: f) else {
      throw .noMemory
    }
    vms[vm].bindings.append(Binding(va: address, size: size, buffer: id, offset: offset, flags: f))
    vms[vm].bindings.sort { $0.va < $1.va }
    contexts[c]!.buffers[bufferIndex(c, id)!].refs += 1
  }

  /// 10.4.3's UNMAP: whatever is mapped in the range goes.
  public mutating func unbind(_ c: Int, vm handle: UInt32, address: UInt64, size: UInt64) throws(CSFServiceError) {
    let vm = try vmID(c, handle)
    do { try vms[vm].layout.validateBind(va: address, size: size) } catch { throw .invalid }
    dropBindings(vm: vm, lo: address, hi: address + size)
  }

  /// Unmap [lo, hi) of the VM's user mappings: a mapping it overlaps is
  /// cut, and a buffer nothing maps and its handle let go of is freed.
  mutating func dropBindings(vm: Int, lo: UInt64, hi: UInt64) {
    let c = vms[vm].context
    var kept: [Binding] = []
    var released: [UInt32] = []
    var added: [UInt32] = []
    for b in vms[vm].bindings {
      let end = b.va + b.size
      if end <= lo || b.va >= hi {
        kept.append(b)
        continue
      }
      let cutLo = max(b.va, lo)
      let cutHi = min(end, hi)
      scheduler.link.unmap(vm: vm, va: cutLo, size: cutHi - cutLo)
      var pieces = 0
      if b.va < cutLo {
        var left = b
        left.size = cutLo - b.va
        kept.append(left)
        pieces += 1
      }
      if cutHi < end {
        var right = b
        right.va = cutHi
        right.size = end - cutHi
        right.offset = b.offset + (cutHi - b.va)
        kept.append(right)
        pieces += 1
      }
      if pieces == 0 { released.append(b.buffer) }
      if pieces == 2 { added.append(b.buffer) }
    }
    kept.sort { $0.va < $1.va }
    vms[vm].bindings = kept
    guard c >= 0, c < contexts.count, contexts[c] != nil else { return }
    for id in added {
      if let i = bufferIndex(c, id) { contexts[c]!.buffers[i].refs += 1 }
    }
    for id in released {
      if let i = bufferIndex(c, id) { contexts[c]!.buffers[i].refs -= 1 }
      releaseBufferIfDone(c, id)
    }
  }

  // MARK: Groups

  /// Give back kernel-region ranges of a VM.
  mutating func releaseKernel(vm: Int, _ ranges: [(UInt64, UInt64)]) {
    for r in ranges { _ = vms[vm].layout.kernel.release(at: r.0, size: r.1) }
  }

  /// 10.6.1's checks, in its order; the group's kernel memory (rings, sync
  /// objects) is addresses of the VM's kernel region.
  public mutating func createGroup(_ c: Int, vm handle: UInt32, queues: [(ringSize: UInt32, priority: UInt32)],
                                   priority: UInt32) throws(CSFServiceError) -> UInt32 {
    _ = try context(c)
    reap()
    if scheduler.deviceLost || contexts[c]!.lost { throw .lost }
    let d = scheduler.link.device
    if queues.count < 1 || queues.count > 32 { throw .invalid }
    if priority > 3 { throw .invalid }
    if allowedPriorities >> priority & 1 == 0 { throw .invalid }
    if queues.count > min(32, d.queuesPerGroup) { throw .invalid }
    let vm = try vmID(c, handle)
    for q in queues {
      let r = q.ringSize
      if r < 4096 || r > 65536 || r & (r - 1) != 0 || q.priority > 15 { throw .invalid }
    }
    guard let slot = contexts[c]!.groups.firstIndex(where: { $0 == nil }) else { throw .unavailable }

    // The kernel memory's addresses, from the VM's kernel region.
    let syncSize = UInt64(queues.count) * 16
    guard let syncBase = vms[vm].layout.kernel.allocate(size: syncSize) else { throw .noMemory }
    var memory: [CSFQueueMemory] = []
    var specs: [QueueSpec] = []
    var taken: [(UInt64, UInt64)] = [(syncBase, syncSize)]
    for i in 0..<queues.count {
      let q = queues[i]
      guard let ring = vms[vm].layout.kernel.allocate(size: UInt64(q.ringSize)) else {
        releaseKernel(vm: vm, taken)
        throw .noMemory
      }
      taken.append((ring, UInt64(q.ringSize)))
      let sync = syncBase + UInt64(i) * 16
      memory.append(CSFQueueMemory(ringVA: ring, ringSize: Int(q.ringSize), syncVA: sync, profilingVA: 0))
      specs.append(QueueSpec(ringSize: Int(q.ringSize), priority: Int(q.priority), syncVA: sync))
    }
    let g: Int
    do { g = try scheduler.createGroup(vm: vm, priority: Int(priority), queues: specs) } catch {
      releaseKernel(vm: vm, taken)
      throw error == .tooManyGroups ? .unavailable : .invalid
    }
    guard scheduler.link.attachGroup(group: g, vm: vm, queues: memory) else {
      try? scheduler.destroyGroup(g)
      releaseKernel(vm: vm, taken)
      throw .noMemory
    }
    contexts[c]!.groups[slot] = GroupRecord(sched: g, vm: vm, queues: memory, syncBase: syncBase, syncSize: syncSize)
    vms[vm].liveGroups += 1
    return UInt32(slot + 1)
  }

  func groupRecord(_ c: Int, _ handle: UInt32) throws(CSFServiceError) -> GroupRecord {
    let x = try context(c)
    guard handle >= 1, Int(handle) <= Self.maxGroups, let g = x.groups[Int(handle) - 1] else { throw .invalid }
    return g
  }

  /// 10.6.2: the handle goes now, and its jobs not yet on a ring; a
  /// resident group leaves at the next pass.
  public mutating func destroyGroup(_ c: Int, _ handle: UInt32) throws(CSFServiceError) {
    let g = try groupRecord(c, handle)
    contexts[c]!.groups[Int(handle) - 1] = nil
    pending.removeAll { $0.context == c && $0.group == Int(handle) }
    submitted.removeAll { $0.context == c && $0.group == Int(handle) }
    try? scheduler.destroyGroup(g.sched)
    zombies.append(g)
    pump()
  }

  /// 10.6.4: bit 0 timed out, bit 1 a fatal fault, bit 2 innocent.
  public func groupState(_ c: Int, _ handle: UInt32) throws(CSFServiceError)
    -> (state: UInt32, fatalQueues: UInt32, resident: Bool)
  {
    let g = try groupRecord(c, handle)
    guard let i = scheduler.info(g.sched) else { throw .invalid }
    var s: UInt32 = 0
    if i.timedOut { s |= 1 }
    if i.fatalQueues != 0 { s |= 2 }
    if i.innocent { s |= 4 }
    return (s, i.fatalQueues, i.csg != nil)
  }

  // MARK: Syncs

  public mutating func addSync(_ c: Int, counter: UInt32) throws(CSFServiceError) -> UInt32 {
    _ = try context(c)
    if contexts[c]!.syncs.count >= Self.maxSyncs { throw .unavailable }
    var id = contexts[c]!.nextSync
    while contexts[c]!.syncs.contains(where: { $0.id == id }) { id = id &+ 1 == 0 ? 1 : id &+ 1 }
    contexts[c]!.nextSync = id &+ 1 == 0 ? 1 : id &+ 1
    contexts[c]!.syncs.append(Sync(id: id, counter: counter))
    return id
  }

  public mutating func removeSync(_ c: Int, _ id: UInt32) {
    guard c >= 0, c < contexts.count, contexts[c] != nil,
      let i = contexts[c]!.syncs.firstIndex(where: { $0.id == id })
    else { return }
    scheduler.link.closeCounter(contexts[c]!.syncs.remove(at: i).counter)
  }

  func counter(_ c: Int, _ id: UInt32) -> UInt32? {
    guard c >= 0, c < contexts.count, let x = contexts[c] else { return nil }
    for s in x.syncs where s.id == id { return s.counter }
    return nil
  }

  // MARK: Submission

  /// 10.6.3's checks. The jobs go to their queues in order once every wait
  /// has reached its value (a context's jobs on a group keep their order);
  /// each signal rises when the last job is done.
  public mutating func submit(_ c: Int, group handle: UInt32, jobs: [CSFJob], waits: [CSFSync], signals: [CSFSync])
    throws(CSFServiceError)
  {
    let g = try groupRecord(c, handle)
    if scheduler.deviceLost { throw .lost }
    markLost()
    guard let info = scheduler.info(g.sched) else { throw .invalid }
    if contexts[c]!.lost || !info.runnable { throw .lost }
    if jobs.count > Self.maxJobs { throw .invalid }
    for j in jobs {
      if Int(j.queue) >= g.queues.count { throw .invalid }
      if (j.stream == 0) != (j.size == 0) { throw .invalid }
      if j.stream & 63 != 0 || j.size & 7 != 0 || j.flush >> 24 & 0x7F != 0 { throw .invalid }
    }
    for s in waits where counter(c, s.id) == nil { throw .notFound }
    for s in signals where counter(c, s.id) == nil { throw .notFound }
    let id = nextSubmission
    nextSubmission += 1
    pending.append(Submission(id: id, context: c, group: Int(handle), jobs: jobs, waits: waits, signals: signals,
                              remaining: jobs.count))
    pump()
  }

  // MARK: Time

  /// When the host should call `pump` next if nothing else wakes it (nil:
  /// nothing is waiting on the clock).
  public var nextWake: UInt64? {
    var t = scheduler.nextTick
    if !pending.isEmpty {
      let poll = scheduler.link.nanoseconds &+ 1_000_000
      t = t.map { min($0, poll) } ?? poll
    }
    return t
  }

  /// Run what is due: the firmware's events and the scheduler's tick and
  /// timers, the submissions whose waits are met, the counters of what
  /// finished; then free what ended.
  public mutating func pump() {
    var rounds = 0
    while rounds < 8 {
      rounds += 1
      scheduler.run(now: scheduler.link.nanoseconds)
      let done = scheduler.drainCompletions()
      for c in done { complete(c) }
      let moved = issuePending()
      reap()
      if done.isEmpty && !moved { break }
    }
    markLost()
  }

  /// Pending submissions that can go. True if any job went to a ring or
  /// any submission was done.
  mutating func issuePending() -> Bool {
    var any = false
    var i = 0
    // A group with an earlier submission still waiting is waited for.
    var blocked: [(Int, Int)] = []
    while i < pending.count {
      let s = pending[i]
      if blocked.contains(where: { $0 == (s.context, s.group) }) {
        i += 1
        continue
      }
      guard let g = try? groupRecord(s.context, UInt32(s.group)) else {
        pending.remove(at: i)
        continue
      }
      var ready = true
      for w in s.waits {
        // A sync removed meanwhile is no longer waited for.
        if let raw = counter(s.context, w.id), scheduler.link.counterValue(raw) < w.value { ready = false }
      }
      if !ready {
        blocked.append((s.context, s.group))
        i += 1
        continue
      }
      var failed = false
      while pending[i].issued < pending[i].jobs.count {
        let j = pending[i].jobs[pending[i].issued]
        let tag = nextTag
        do {
          _ = try scheduler.submit(group: g.sched, queue: Int(j.queue), streamVA: j.stream, streamSize: j.size,
                                   flushID: j.flush, tag: tag, now: scheduler.link.nanoseconds)
        } catch {
          if error == .ringFull {
            blocked.append((s.context, s.group))
          } else {
            failed = true
          }
          break
        }
        nextTag += 1
        tags.append((tag, pending[i].id))
        pending[i].issued += 1
        any = true
      }
      if failed {
        // The group ended under it: the jobs on rings finish with the
        // group, and the rest never go.
        let rest = pending[i].jobs.count - pending[i].issued
        pending[i].remaining -= rest
        pending[i].jobs.removeLast(rest)
      }
      if pending[i].issued == pending[i].jobs.count {
        let done = pending.remove(at: i)
        if done.remaining == 0 {
          raise(done.context, done.signals)
          any = true
        } else {
          submitted.append(done)
        }
        continue
      }
      i += 1
    }
    return any
  }

  mutating func complete(_ c: Completion) {
    guard let t = tags.firstIndex(where: { $0.tag == c.job.tag }) else { return }
    let sid = tags.remove(at: t).submission
    if let i = submitted.firstIndex(where: { $0.id == sid }) {
      submitted[i].remaining -= 1
      if submitted[i].remaining == 0 {
        let s = submitted.remove(at: i)
        raise(s.context, s.signals)
      }
    } else if let i = pending.firstIndex(where: { $0.id == sid }) {
      pending[i].remaining -= 1
    }
  }

  mutating func raise(_ c: Int, _ signals: [CSFSync]) {
    for s in signals {
      if let raw = counter(c, s.id) { scheduler.link.raiseCounter(raw, to: s.value) }
    }
  }

  /// A context with a group that can no longer run is lost.
  mutating func markLost() {
    for c in 0..<contexts.count where contexts[c] != nil && !contexts[c]!.lost {
      for h in 0..<Self.maxGroups {
        guard let g = contexts[c]!.groups[h], let i = scheduler.info(g.sched) else { continue }
        if !i.runnable {
          contexts[c]!.lost = true
          break
        }
      }
    }
  }

  /// Free the groups the scheduler has forgotten, and the VMs that waited
  /// for them.
  mutating func reap() {
    var i = 0
    while i < zombies.count {
      let g = zombies[i]
      if scheduler.info(g.sched) != nil {
        i += 1
        continue
      }
      zombies.remove(at: i)
      scheduler.link.detachGroup(group: g.sched)
      var ranges: [(UInt64, UInt64)] = [(g.syncBase, g.syncSize)]
      for q in g.queues { ranges.append((q.ringVA, UInt64(q.ringSize))) }
      releaseKernel(vm: g.vm, ranges)
      vms[g.vm].liveGroups -= 1
    }
    for vm in 0..<vms.count where vms[vm].dying && !vms[vm].gone && vms[vm].liveGroups == 0 {
      if (try? scheduler.destroyVM(vm)) != nil {
        scheduler.link.destroyVM(vm)
        vms[vm].gone = true
      }
    }
  }
}
