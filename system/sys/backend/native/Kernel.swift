// SPDX-License-Identifier: BSD-3-Clause

// Sys's calls on the kernel: each one a system call through syscall.h
// (module CroiSyscall), its numbers, items and layouts the headers' (D45;
// todhchai's number table is gone). The calls that take arrays take them
// here; syscall.h's one-item helpers serve the rest. The floor
// (system/sys/floor) holds this process's handle and root VMAR, the
// vDSO's clock, each thread's port and block, and starts threads: Sys
// reaches it through its C interface (td_floor.h, td_native.h), so that the
// same source builds as tier 0's Embedded Swift and tier 1's full Swift.
//
// A channel write or call consumes its handles even when it fails (as
// Zircon), as Sys promises.

import CroiSyscall
import TDFloor
import TDNative

/// Throws the status a call returned, if it failed.
@inline(__always)
func check(_ result: Int64) throws(Status) {
  if result < 0 { throw Status(result: result) }
}

/// An address for the kernel to read or write through.
@inline(__always)
func address<T>(_ p: UnsafeMutablePointer<T>) -> UInt64 { unsafe UInt64(UInt(bitPattern: p)) }
@inline(__always)
func address(_ p: UnsafeRawPointer?) -> UInt64 { unsafe UInt64(UInt(bitPattern: p)) }

/// Calls `body` with a place for one out value, and returns it.
@inline(__always)
func out<T>(_ initial: T, _ body: (UInt64) -> Int64) throws(Status) -> T {
  var value = initial
  let r = unsafe withUnsafeMutablePointer(to: &value) { unsafe body(address($0)) }
  try check(r)
  return value
}

/// object_get_info for a fixed-size topic, into a `T`.
@inline(__always)
func getInfo<T>(_ h: UInt32, _ topic: UInt32, _ initial: T) throws(Status) -> T {
  try out(initial) { croi_syscall6(CROI_SYS_OBJECT_GET_INFO, UInt64(h), UInt64(topic), $0, UInt64(MemoryLayout<T>.size), 0, 0) }
}

/// A program's entry, natively: an ELF file in a VMO (bootfs), which the
/// caller keeps open while processes start from it.
public struct ProgramEntry: Sendable {
  /// The VMO, borrowed.
  public let image: UInt32
  public let offset: Int
  public let length: Int
  /// Its argv[0].
  public let name: String

  public init(image: UInt32, offset: Int, length: Int, name: String) {
    self.image = image
    self.offset = offset
    self.length = length
    self.name = name
  }
}

enum Kernel {
  static func close(_ h: UInt32) { _ = croi_handle_close(h) }

  /// handle_close's array (D33): 0s are skipped.
  static func close(all handles: UnsafeBufferPointer<UInt32>) {
    guard handles.count > 0 else { return }
    _ = unsafe croi_syscall(CROI_SYS_HANDLE_CLOSE, address(handles.baseAddress), UInt64(handles.count), 0, 0, 0)
  }

  /// handle_duplicate, one item: a duplicate, or with `consume` the
  /// handle replaced (gone either way).
  static func duplicate(_ h: UInt32, _ r: Rights, consume: Bool) throws(Status) -> UInt32 {
    try out(UInt32(0)) { p in
      unsafe croi_handle_duplicate(h, r.rawValue, UnsafeMutablePointer(bitPattern: UInt(p)),
                                   consume ? CROI_HANDLE_DUPLICATE_CONSUME : 0)
    }
  }

  static func info(_ h: UInt32) throws(Status) -> HandleInfo {
    let b = try getInfo(h, CROI_INFO_HANDLE_BASIC, croi_info_handle_basic_t())
    return HandleInfo(koid: b.koid, rights: Rights(rawValue: b.rights), type: b.type, relatedKoid: b.related_koid)
  }

  // MARK: Waits and ports

  /// Waits for one binding's event on the thread's port (the floor's
  /// td_wait_bind): its packet.
  static func wait(_ item: Binding, deadline: Int64) throws(Status) -> Packet {
    var item = item
    var packet = Packet()
    try check(Int64(unsafe td_wait_bind(&item, deadline, &packet)))
    return packet
  }

  /// object_bind: how many items were bound (each one's status written).
  static func bind(_ port: UInt32, _ items: UnsafeMutableBufferPointer<Binding>) throws(Status) -> Int {
    let r = unsafe croi_syscall(CROI_SYS_OBJECT_BIND, UInt64(port), address(items.baseAddress), UInt64(items.count), 0,
                                0)
    try check(r)
    return Int(r)
  }

  static func portCreate(options: UInt32) throws(Status) -> UInt32 {
    try out(UInt32(0)) { croi_syscall(CROI_SYS_PORT_CREATE, UInt64(options), $0, 0, 0, 0) }
  }

  static func portQueue(_ port: UInt32, _ packets: UnsafeBufferPointer<Packet>) throws(Status) -> Int {
    let r = unsafe croi_syscall(CROI_SYS_PORT_QUEUE, UInt64(port), address(packets.baseAddress),
                                UInt64(packets.count), 0, 0)
    try check(r)
    return Int(r)
  }

  static func portWait(_ port: UInt32, _ deadline: Int64, _ packets: UnsafeMutableBufferPointer<Packet>)
    throws(Status) -> Int
  {
    let r = unsafe croi_syscall(CROI_SYS_PORT_WAIT, UInt64(port), UInt64(bitPattern: deadline),
                                address(packets.baseAddress), UInt64(packets.count), 0)
    try check(r)
    return Int(r)
  }

  /// port_cancel: `source` 0 for every source.
  static func portCancel(_ port: UInt32, _ source: UInt32, _ key: UInt64) throws(Status) {
    try check(croi_syscall(CROI_SYS_PORT_CANCEL, UInt64(port), UInt64(source), key, 0, 0))
  }

  // MARK: Channels

  static func channelCreate() throws(Status) -> (UInt32, UInt32) {
    try out((UInt32(0), UInt32(0))) { p in croi_syscall(CROI_SYS_CHANNEL_CREATE, 0, p, p + 4, 0, 0) }
  }

  static func channelWrite(_ h: UInt32, _ bytes: [UInt8], _ handles: [UInt32]) throws(Status) {
    let r = unsafe bytes.withUnsafeBytes { b in
      unsafe handles.withUnsafeBufferPointer { hs in
        unsafe croi_channel_write(h, 0, b.baseAddress, UInt32(b.count), hs.baseAddress, UInt32(hs.count))
      }
    }
    try check(r)
  }

  /// channel_read, sized first: asked with no room, the kernel says how
  /// large the next message is and leaves it queued (BUFFER_TOO_SMALL), so
  /// the arrays are made to fit, uninitialized. Another reader may take it
  /// meanwhile; then the next one is sized.
  static func channelRead(_ h: UInt32) throws(Status) -> Channel.Message {
    while true {
      var count: UInt32 = 0, handleCount: UInt32 = 0
      let size = unsafe croi_channel_read(h, 0, nil, nil, 0, 0, &count, &handleCount)
      if size == 0 { return Channel.Message(bytes: [], handles: []) }  // an empty message, read
      guard size == CROI_ERR_BUFFER_TOO_SMALL else {
        try check(size)
        throw .internal
      }
      let n = Int(count), m = Int(handleCount)
      // Trivial values: uninitialized until the read fills them.
      var bytes = unsafe [UInt8](unsafeUninitializedCapacity: n) { _, k in k = n }
      var handles = unsafe [UInt32](unsafeUninitializedCapacity: m) { _, k in k = m }
      let r = unsafe bytes.withUnsafeMutableBytes { b in
        unsafe handles.withUnsafeMutableBufferPointer { hs in
          unsafe croi_channel_read(h, 0, b.baseAddress, hs.baseAddress, count, handleCount, nil, nil)
        }
      }
      if r == CROI_ERR_BUFFER_TOO_SMALL { continue }  // another reader took it: the next
      try check(r)
      return Channel.Message(bytes: bytes, handles: handles)
    }
  }

  /// channel_call with croi_channel_call_args_t.
  static func channelCall(_ h: UInt32, _ bytes: [UInt8], _ handles: [UInt32], _ deadline: Int64) throws(Status)
    -> Channel.Message
  {
    // Room for the largest reply (the kernel drops one that doesn't fit),
    // from the heap's classes and not zeroed.
    let maxBytes = Channel.maxBytes, maxHandles = Channel.maxHandles
    var reply = unsafe [UInt8](unsafeUninitializedCapacity: maxBytes) { _, n in n = maxBytes }
    var replyHandles = unsafe [UInt32](unsafeUninitializedCapacity: maxHandles) { _, n in n = maxHandles }
    var actual = (UInt32(0), UInt32(0))
    let r = unsafe bytes.withUnsafeBytes { wb in
      unsafe handles.withUnsafeBufferPointer { wh in
        unsafe reply.withUnsafeMutableBytes { rb in
          unsafe replyHandles.withUnsafeMutableBufferPointer { rh in
            var args = unsafe croi_channel_call_args_t(
              wr_bytes: address(wb.baseAddress), wr_handles: address(wh.baseAddress),
              rd_bytes: address(rb.baseAddress), rd_handles: address(rh.baseAddress),
              wr_num_bytes: UInt32(wb.count), wr_num_handles: UInt32(wh.count),
              rd_num_bytes: UInt32(maxBytes), rd_num_handles: UInt32(maxHandles))
            return unsafe withUnsafeMutablePointer(to: &args) { a in
              unsafe withUnsafeMutablePointer(to: &actual) { act in
                unsafe croi_syscall6(CROI_SYS_CHANNEL_CALL, UInt64(h), 0, UInt64(bitPattern: deadline), address(a),
                                     address(act), address(act) + 4)
              }
            }
          }
        }
      }
    }
    try check(r)
    reply.removeLast(maxBytes - Int(actual.0))
    replyHandles.removeLast(maxHandles - Int(actual.1))
    return Channel.Message(bytes: reply, handles: replyHandles)
  }

  // MARK: VMOs

  static let pageSize = 4096

  /// `n` rounded up to a page: the kernel refuses sizes and lengths that
  /// aren't (Zircon rounds a VMO's size up), and Sys promises pages.
  static func pages(_ n: Int) -> Int { (n + pageSize - 1) & ~(pageSize - 1) }

  static func vmoCreate(_ size: Int) throws(Status) -> UInt32 {
    try out(UInt32(0)) { croi_syscall(CROI_SYS_VMO_CREATE, UInt64(pages(size)), 0, $0, 0, 0) }
  }

  static func vmoSize(_ h: UInt32) throws(Status) -> Int {
    Int(try out(UInt64(0)) { p in unsafe croi_vmo_size(h, UnsafeMutablePointer(bitPattern: UInt(p))) })
  }

  /// vmar_map, one item, on the root VMAR.
  static func vmoMap(_ h: UInt32, _ offset: Int, _ length: Int, _ writable: Bool) throws(Status)
    -> UnsafeMutableRawPointer
  {
    let perms = CROI_VM_PERM_READ | (writable ? CROI_VM_PERM_WRITE : 0)
    let mapped = try out(UInt64(0)) { p in
      unsafe croi_vmar_map(td_runtime_vmar_root, perms, 0, h, UInt64(offset), UInt64(pages(length)),
                           UnsafeMutablePointer(bitPattern: UInt(p)))
    }
    guard let p = unsafe UnsafeMutableRawPointer(bitPattern: UInt(mapped)) else { throw .internal }
    return unsafe p
  }

  static func vmoUnmap(_ address: UnsafeMutableRawPointer, _ length: Int) {
    _ = croi_vmar_unmap(td_runtime_vmar_root, UInt64(UInt(bitPattern: address)), UInt64(pages(length)))
  }

  static func vmoCreateChild(_ vmo: UInt32, _ options: UInt32, _ offset: UInt64, _ size: Int) throws(Status) -> UInt32 {
    try out(UInt32(0)) { croi_syscall(CROI_SYS_VMO_CREATE_CHILD, UInt64(vmo), UInt64(options), offset, UInt64(pages(size)), $0) }
  }

  static func vmoCreatePhysical(_ resource: UInt32, _ address: UInt64, _ size: Int) throws(Status) -> UInt32 {
    try out(UInt32(0)) { croi_syscall(CROI_SYS_VMO_CREATE_PHYSICAL, UInt64(resource), address, UInt64(pages(size)), $0, 0) }
  }

  static func vmoSetCachePolicy(_ h: UInt32, _ policy: VMO.CachePolicy) throws(Status) {
    try check(croi_syscall(CROI_SYS_VMO_SET_CACHE_POLICY, UInt64(h), UInt64(policy.rawValue), 0, 0, 0))
  }

  // MARK: Resources and I/O ports

  /// resource_create: the parent and options share the first argument.
  static func resourceCreate(_ parent: UInt32, _ options: UInt32, _ base: UInt64, _ size: UInt64, _ name: String)
    throws(Status) -> UInt32
  {
    var bytes = Array(name.utf8.prefix(Int(CROI_MAX_NAME_LEN) - 1))
    return try out(UInt32(0)) { p in
      unsafe bytes.withUnsafeMutableBytes { n in
        unsafe croi_syscall6(CROI_SYS_RESOURCE_CREATE, UInt64(parent) | UInt64(options) << 32, base, size,
                             address(n.baseAddress), UInt64(n.count), p)
      }
    }
  }

  static func resourceInfo(_ h: UInt32) throws(Status) -> ResourceInfo {
    var r = try getInfo(h, CROI_INFO_RESOURCE, croi_info_resource_t())
    let name = unsafe withUnsafeBytes(of: &r.name) { b in
      unsafe String(decoding: b.prefix { $0 != 0 }, as: UTF8.self)
    }
    return ResourceInfo(kind: r.kind, flags: r.flags, base: r.base, size: r.size, name: name)
  }

  static func ioportsRequest(_ resource: UInt32, _ base: UInt16, _ count: UInt16) throws(Status) {
    try check(croi_syscall(CROI_SYS_IOPORTS_REQUEST, UInt64(resource), UInt64(base), UInt64(count), 0, 0))
  }

  static func ioportsRelease(_ resource: UInt32, _ base: UInt16, _ count: UInt16) throws(Status) {
    try check(croi_syscall(CROI_SYS_IOPORTS_RELEASE, UInt64(resource), UInt64(base), UInt64(count), 0, 0))
  }

  static func portIn(_ port: UInt16, _ width: Int) -> UInt32 {
    #if arch(x86_64)
      td_port_in(port, UInt32(width))
    #else
      UInt32.max >> (32 - 8 * width)  // no ports: what a missing device gives
    #endif
  }

  static func portOut(_ port: UInt16, _ width: Int, _ value: UInt32) {
    #if arch(x86_64)
      td_port_out(port, UInt32(width), value)
    #endif
  }

  // MARK: Interrupts

  static func interruptCreate(_ resource: UInt32, _ number: UInt32, _ options: UInt32) throws(Status) -> UInt32 {
    try out(UInt32(0)) { croi_syscall(CROI_SYS_INTERRUPT_CREATE, UInt64(resource), UInt64(number), UInt64(options), $0, 0) }
  }

  /// interrupt_ack's array (D40): how many were re-armed.
  static func interruptAck(_ items: UnsafeMutableBufferPointer<croi_interrupt_ack_item_t>) throws(Status) -> Int {
    let r = unsafe croi_syscall(CROI_SYS_INTERRUPT_ACK, address(items.baseAddress), UInt64(items.count), 0, 0, 0)
    try check(r)
    return Int(r)
  }

  static func interruptSetAffinity(_ h: UInt32, _ cpus: UInt64) throws(Status) {
    try check(croi_syscall(CROI_SYS_INTERRUPT_SET_AFFINITY, UInt64(h), cpus, 0, 0, 0))
  }

  static func msiAllocate(_ resource: UInt32, _ count: Int) throws(Status) -> UInt32 {
    try out(UInt32(0)) { croi_syscall(CROI_SYS_MSI_ALLOCATE, UInt64(resource), UInt64(count), $0, 0, 0) }
  }

  static func msiCreate(_ allocation: UInt32, _ options: UInt32, _ id: UInt32, _ vmo: UInt32, _ offset: Int)
    throws(Status) -> UInt32
  {
    try out(UInt32(0)) {
      croi_syscall6(CROI_SYS_MSI_CREATE, UInt64(allocation), UInt64(options), UInt64(id), UInt64(vmo), UInt64(offset), $0)
    }
  }

  static func msiInfo(_ allocation: UInt32) throws(Status) -> MSIInfo {
    let m = try getInfo(allocation, CROI_INFO_MSI, croi_info_msi_t())
    return MSIInfo(targetAddress: m.target_addr, targetData: m.target_data, baseIRQ: m.base_irq_id, count: m.num_irq,
                   interrupts: m.interrupt_count)
  }

  // MARK: Profiles

  static func profileCreate(_ resource: UInt32, deadline: (Int64, Int64, Int64)) throws(Status) -> UInt32 {
    var profile = croi_profile_info_t()
    profile.flags = CROI_PROFILE_INFO_FLAG_DEADLINE
    profile.deadline_params = croi_sched_deadline_params_t(capacity: deadline.0, relative_deadline: deadline.1,
                                                           period: deadline.2)
    return try out(UInt32(0)) { p in
      unsafe withUnsafeMutablePointer(to: &profile) { i in
        unsafe croi_syscall(CROI_SYS_PROFILE_CREATE, UInt64(resource), 0, address(i), p, 0)
      }
    }
  }

  /// object_set_profile: 0, or admission's refusal (its reason word).
  static func setProfile(_ target: UInt32, _ profile: UInt32, _ options: UInt32) throws(Status) -> UInt32 {
    var refusal: UInt32 = 0
    let r = unsafe withUnsafeMutablePointer(to: &refusal) { p in
      unsafe croi_syscall(CROI_SYS_OBJECT_SET_PROFILE, UInt64(target), UInt64(profile), UInt64(options), address(p), 0)
    }
    if r == CROI_ERR_NO_RESOURCES { return refusal == 0 ? 0xFFFF_FFFF : refusal }
    try check(r)
    return 0
  }

  // MARK: Counters

  static func counterCreate() throws(Status) -> UInt32 {
    try out(UInt32(0)) { croi_syscall(CROI_SYS_COUNTER_CREATE, 0, $0, 0, 0, 0) }
  }

  /// counter_add's array (D40): how many adds succeeded.
  static func counterAdd(_ items: UnsafeMutableBufferPointer<CounterAdd>) throws(Status) -> Int {
    let r = unsafe croi_syscall(CROI_SYS_COUNTER_ADD, address(items.baseAddress), UInt64(items.count), 0, 0, 0)
    try check(r)
    return Int(r)
  }

  static func counterRead(_ h: UInt32) throws(Status) -> Int64 {
    try out(Int64(0)) { croi_syscall(CROI_SYS_COUNTER_READ, UInt64(h), $0, 0, 0, 0) }
  }

  // MARK: DMA

  /// iommu_create(STUB): its descriptor is one byte (zx_iommu_desc_stub_t).
  static func iommuCreateStub(_ resource: UInt32) throws(Status) -> UInt32 {
    var desc: UInt8 = 0
    return try out(UInt32(0)) { p in
      unsafe withUnsafeMutablePointer(to: &desc) { d in
        unsafe croi_syscall(CROI_SYS_IOMMU_CREATE, UInt64(resource), UInt64(CROI_IOMMU_TYPE_STUB), address(d), 1, p)
      }
    }
  }

  static func btiCreate(_ iommu: UInt32, _ id: UInt64) throws(Status) -> UInt32 {
    try out(UInt32(0)) { croi_syscall(CROI_SYS_BTI_CREATE, UInt64(iommu), 0, id, $0, 0) }
  }

  static func btiSetProperties(_ bti: UInt32, _ p: DMA.Properties) throws(Status) {
    var properties = croi_bti_properties_t(
      address_bits: p.addressBits, memory_type: p.coherent ? CROI_BTI_MEMORY_COHERENT : CROI_BTI_MEMORY_NONCOHERENT,
      window_base: p.windowBase, window_size: p.windowSize)
    let r = unsafe withUnsafeMutablePointer(to: &properties) {
      unsafe croi_syscall(CROI_SYS_BTI_SET_PROPERTIES, UInt64(bti), address($0), 0, 0, 0)
    }
    try check(r)
  }

  static func vmoCreateContiguous(_ bti: UInt32, _ size: Int, _ alignmentLog2: UInt32) throws(Status) -> UInt32 {
    try out(UInt32(0)) {
      croi_syscall(CROI_SYS_VMO_CREATE_CONTIGUOUS, UInt64(bti), UInt64(pages(size)), UInt64(alignmentLog2), $0, 0)
    }
  }

  /// bti_pin, packed into six registers: bti | options << 32, vmo |
  /// addrs_count << 32, offset, size, addrs, pmt out.
  static func btiPin(_ bti: UInt32, _ vmo: UInt32, _ offset: Int, _ size: Int, _ options: UInt32, _ count: Int)
    throws(Status) -> (pmt: UInt32, addresses: [UInt64])
  {
    var addresses = [UInt64](repeating: 0, count: count)
    var pmt: UInt32 = 0
    let r = unsafe addresses.withUnsafeMutableBytes { a in
      unsafe withUnsafeMutablePointer(to: &pmt) { p in
        unsafe croi_syscall6(CROI_SYS_BTI_PIN, UInt64(bti) | UInt64(options) << 32, UInt64(vmo) | UInt64(count) << 32,
                             UInt64(offset), UInt64(pages(size)), address(a.baseAddress), address(p))
      }
    }
    try check(r)
    return (pmt, addresses)
  }

  static func pmtUnpin(_ pmt: UInt32) throws(Status) { try check(croi_syscall(CROI_SYS_PMT_UNPIN, UInt64(pmt), 0, 0, 0, 0)) }

  static func btiReleaseQuarantine(_ bti: UInt32) throws(Status) {
    try check(croi_syscall(CROI_SYS_BTI_RELEASE_QUARANTINE, UInt64(bti), 0, 0, 0, 0))
  }

  // MARK: The debuglog

  /// A log handle to write to (and ask CROI_INFO_DEBUGLOG of).
  static func debuglogCreate() throws(Status) -> UInt32 {
    try out(UInt32(0)) { croi_syscall(CROI_SYS_DEBUGLOG_CREATE, 0, 0, $0, 0, 0) }
  }

  /// Records written, and those the console dumper has finished with.
  static func debuglogProgress(_ log: UInt32) throws(Status) -> (written: UInt64, printed: UInt64) {
    let p = try getInfo(log, CROI_INFO_DEBUGLOG, croi_info_debuglog_t())
    return (p.written, p.printed)
  }

  // MARK: Futexes

  static func futexWait(_ word: UnsafeMutablePointer<UInt32>, current: UInt32, deadline: Int64) throws(Status) {
    // No owner: Sys's locks don't name one (Lock.swift).
    try check(Int64(unsafe td_futex_wait(word, current, deadline)))
  }

  static func futexWake(_ word: UnsafeMutablePointer<UInt32>, count: Int) {
    _ = unsafe td_futex_wake(word, UInt32(clamping: count))
  }

  // MARK: Tasks

  static func jobCreate(_ parent: UInt32) throws(Status) -> UInt32 {
    try out(UInt32(0)) { croi_syscall(CROI_SYS_JOB_CREATE, UInt64(parent), 0, $0, 0, 0) }
  }

  /// process_create gives the process and its root VMAR. The VMAR is the
  /// loader's, which comes with the launcher (V2's item 4); until then it
  /// is closed, and the process can't be started from Sys.
  static func processCreate(_ job: UInt32, _ name: String) throws(Status) -> UInt32 {
    var bytes = Array(name.utf8)
    let ends = try out((UInt32(0), UInt32(0))) { p in
      unsafe bytes.withUnsafeMutableBytes { n in
        unsafe croi_syscall6(CROI_SYS_PROCESS_CREATE, UInt64(job), address(n.baseAddress), UInt64(n.count), 0, p, p + 4)
      }
    }
    close(ends.1)
    return ends.0
  }

  static func threadCreate(_ process: UInt32) throws(Status) -> UInt32 {
    let name: StaticString = "thread"
    return try out(UInt32(0)) { p in
      unsafe croi_syscall(CROI_SYS_THREAD_CREATE, UInt64(process), address(name.utf8Start),
                          UInt64(name.utf8CodeUnitCount), 0, p)
    }
  }

  /// Not yet natively: the loader comes with the launcher (V2's item 4).
  /// Its handles are consumed, as they would be.
  static func processStart(_ process: UInt32, _ thread: UInt32, _ arg: UInt32, _ entry: ProgramEntry,
                           _ extra: [(info: UInt32, handle: UInt32)], _ environment: [String]) throws(Status) {
    close(arg)
    for e in extra { close(e.handle) }
    throw .notSupported
  }

  /// A thread's start: its body, kept alive by the thread until it runs.
  final class Start {
    let body: @Sendable () -> Void
    init(_ body: @escaping @Sendable () -> Void) { self.body = body }
  }

  /// Starts `thread` through the floor (td_thread_start: its own stack,
  /// block and TLS, the stack unmapped as it ends), running `body`.
  static func threadStart(_ thread: UInt32, _ body: @escaping @Sendable () -> Void) throws(Status) {
    let arg = unsafe UInt(bitPattern: Unmanaged.passRetained(Start(body)).toOpaque())
    let entry: @convention(c) (UInt) -> Void = { arg in
      let start = unsafe Unmanaged<Start>.fromOpaque(UnsafeRawPointer(bitPattern: arg)!).takeRetainedValue()
      start.body()
    }
    let r = td_thread_start(thread, entry, arg)
    if r != 0 {
      unsafe Unmanaged<Start>.fromOpaque(UnsafeRawPointer(bitPattern: arg)!).release()
      throw Status(result: Int64(r))
    }
  }

  static func kill(_ h: UInt32) throws(Status) { try check(croi_syscall(CROI_SYS_TASK_KILL, UInt64(h), 0, 0, 0, 0)) }

  static func exit(_ code: Int64) -> Never { td_exit(code) }

  static func processInfo(_ h: UInt32) throws(Status) -> ProcessInfo {
    let p = try getInfo(h, CROI_INFO_PROCESS, croi_info_process_t())
    return ProcessInfo(returnCode: p.return_code, started: p.flags & CROI_INFO_PROCESS_FLAG_STARTED != 0,
                       exited: p.flags & CROI_INFO_PROCESS_FLAG_EXITED != 0)
  }

  static func taskStats(_ h: UInt32) throws(Status) -> TaskStats {
    let s = try getInfo(h, CROI_INFO_TASK_STATS, croi_info_task_stats_t())
    return TaskStats(mapped: s.mem_mapped_bytes, privateBytes: s.mem_private_bytes, shared: s.mem_shared_bytes,
                     scaledShared: s.mem_scaled_shared_bytes)
  }

  /// object_get_child: (handle, koid, rights, out).
  static func child(_ h: UInt32, _ koid: UInt64, _ rights: UInt32) throws(Status) -> UInt32 {
    try out(UInt32(0)) { croi_syscall(CROI_SYS_OBJECT_GET_CHILD, UInt64(h), koid, UInt64(rights), $0, 0) }
  }

  /// object_get_property(NAME): 32 bytes, NUL-padded.
  static func name(_ h: UInt32) throws(Status) -> String {
    var r = try out(InlineArray<32, UInt8>(repeating: 0)) {
      croi_syscall(CROI_SYS_OBJECT_GET_PROPERTY, UInt64(h), UInt64(CROI_PROP_NAME), $0, 32, 0)
    }
    return unsafe withUnsafeBytes(of: &r) { b in unsafe String(decoding: b.prefix { $0 != 0 }, as: UTF8.self) }
  }

  /// object_set_property(NAME): up to 31 bytes and a NUL.
  static func setName(_ h: UInt32, _ name: String) throws(Status) {
    var bytes = Array(name.utf8.prefix(31))
    bytes.append(0)
    let r = unsafe bytes.withUnsafeBytes { b in
      unsafe croi_syscall(CROI_SYS_OBJECT_SET_PROPERTY, UInt64(h), UInt64(CROI_PROP_NAME), address(b.baseAddress),
                          UInt64(b.count), 0)
    }
    try check(r)
  }

  static func threadState(_ h: UInt32) throws(Status) -> UInt32 {
    try getInfo(h, CROI_INFO_THREAD, croi_info_thread_t()).state
  }

  static func taskRuntime(_ h: UInt32) throws(Status) -> TaskRuntime {
    let r = try getInfo(h, CROI_INFO_TASK_RUNTIME, croi_info_task_runtime_t())
    return TaskRuntime(cpuTime: r.cpu_time, queueTime: r.queue_time, pageFaultTime: r.page_fault_time,
                       lockContentionTime: r.lock_contention_time)
  }

  /// A list topic's records of `T`: read again larger while more are
  /// available.
  static func records<T>(_ h: UInt32, _ topic: UInt32, _ zero: T) throws(Status) -> [T] {
    var room = 64
    while true {
      var items = [T](repeating: zero, count: room)
      var counts: (actual: UInt64, avail: UInt64) = (0, 0)
      let r = unsafe items.withUnsafeMutableBytes { b in
        unsafe withUnsafeMutablePointer(to: &counts) { c in
          unsafe croi_syscall6(CROI_SYS_OBJECT_GET_INFO, UInt64(h), UInt64(topic), address(b.baseAddress),
                               UInt64(b.count), address(c), address(c) + 8)
        }
      }
      try check(r)
      if counts.avail <= counts.actual || room >= 1 << 16 {
        items.removeSubrange(Int(counts.actual)...)
        return items
      }
      room = Int(counts.avail) + 16
    }
  }

  /// A list topic of koids (JOB_CHILDREN, JOB_PROCESSES, PROCESS_THREADS).
  static func koids(_ h: UInt32, _ topic: UInt32) throws(Status) -> [UInt64] { try records(h, topic, UInt64(0)) }

  static func handleTable(_ h: UInt32) throws(Status) -> [HandleEntry] {
    try records(h, CROI_INFO_HANDLE_TABLE, croi_info_handle_extended_t()).map { e in
      HandleEntry(type: e.type, value: e.handle_value, rights: e.rights, koid: e.koid, relatedKoid: e.related_koid)
    }
  }

  /// object_get_info(CPU_STATS): one record a CPU, as many as fit; the
  /// call returns how many it wrote.
  static func cpuStats(_ resource: UInt32, max: Int) throws(Status) -> [CPUStats] {
    var stats = [croi_info_cpu_stats_t](repeating: croi_info_cpu_stats_t(), count: max)
    let n = unsafe stats.withUnsafeMutableBytes { b in
      unsafe croi_syscall6(CROI_SYS_OBJECT_GET_INFO, UInt64(resource), UInt64(CROI_INFO_CPU_STATS),
                           address(b.baseAddress), UInt64(b.count), 0, 0)
    }
    try check(n)
    return stats[0..<Int(n)].map { s in
      CPUStats(cpu: s.cpu_number, online: s.flags & CROI_INFO_CPU_STATS_FLAG_ONLINE != 0, idleTime: s.idle_time,
               contextSwitches: s.context_switches, interrupts: s.ints, timerInterrupts: s.timer_ints,
               timers: s.timers, syscalls: s.syscalls, rescheduleIPIs: s.reschedule_ipis, genericIPIs: s.generic_ipis)
    }
  }

  static func kmemStats(_ resource: UInt32) throws(Status) -> KMemStats {
    let k = try getInfo(resource, CROI_INFO_KMEM_STATS_V1, croi_info_kmem_stats_v1_t())
    return KMemStats(total: k.total_bytes, free: k.free_bytes, wired: k.wired_bytes, heap: k.total_heap_bytes,
                     heapFree: k.free_heap_bytes, vmo: k.vmo_bytes, mmu: k.mmu_overhead_bytes, ipc: k.ipc_bytes,
                     other: k.other_bytes)
  }

  static func powerctl(_ resource: UInt32, _ command: UInt32) throws(Status) {
    var arg = croi_system_powerctl_arg_t()
    let r = unsafe withUnsafeMutablePointer(to: &arg) { a in
      unsafe croi_syscall(CROI_SYS_SYSTEM_POWERCTL, UInt64(resource), UInt64(command), address(a), 0, 0)
    }
    try check(r)
  }

  static func processSelf() throws(Status) -> UInt32 {
    try duplicate(td_runtime_process_self, .sameRights, consume: false)
  }

  static func now() -> Int64 { td_monotonic() }

  /// UTC, once the time service's page comes (D48); the monotonic clock
  /// until then.
  static func realtime() -> Int64 { td_utc_now() }

  static func threadExit() -> Never { td_thread_exit() }

  /// The thread block's slot at 16 (Sys.ThreadSlot's word).
  static func threadSlot() -> UInt { unsafe UInt(td_thread_block()!.load(fromByteOffset: 16, as: UInt64.self)) }
  static func setThreadSlot(_ v: UInt) { unsafe td_thread_block()!.storeBytes(of: UInt64(v), toByteOffset: 16, as: UInt64.self) }

  /// A wait on the thread's port until `deadline` (td_sleep).
  static func sleep(_ deadline: Int64) { td_sleep(deadline) }

  static func random(_ buffer: UnsafeMutableRawBufferPointer) throws(Status) {
    var at = 0
    while at < buffer.count {
      let n = min(Int(CROI_CPRNG_MAX_LEN), buffer.count - at)
      try check(unsafe croi_syscall(CROI_SYS_CPRNG_DRAW, address(buffer.baseAddress! + at), UInt64(n), 0, 0, 0))
      at += n
    }
  }
}
