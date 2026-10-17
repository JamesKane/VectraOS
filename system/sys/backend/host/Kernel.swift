// SPDX-License-Identifier: BSD-3-Clause

// Sys's calls on the hosted kernel (SysHost), for SwiftPM builds; the
// native build's are system/sys/backend/native. The same interface: the
// calls that take arrays take buffers of the headers' items.

import Glibc
import SysHost

/// A program's entry, hosted: a Swift function given its Startup.
public struct ProgramEntry: Sendable {
  let body: @Sendable (Startup) -> Void
  public init(_ body: @escaping @Sendable (Startup) -> Void) { self.body = body }
}

enum Kernel {
  static var k: HostKernel { HostKernel.shared }

  static func close(_ h: UInt32) { try? k.close(h) }
  static func close(all handles: UnsafeBufferPointer<UInt32>) {
    for unsafe h in unsafe handles where h != 0 { close(h) }
  }
  static func duplicate(_ h: UInt32, _ r: Rights, consume: Bool) throws(Status) -> UInt32 {
    consume ? try k.replace(h, rights: r) : try k.duplicate(h, rights: r)
  }
  static func info(_ h: UInt32) throws(Status) -> HandleInfo {
    let i = try k.info(h)
    return HandleInfo(koid: i.koid, rights: i.rights, type: i.type, relatedKoid: i.relatedKoid)
  }

  static func wait(_ item: Binding, deadline: Int64) throws(Status) -> Packet { try k.wait(item, deadline: deadline) }
  static func bind(_ port: UInt32, _ items: UnsafeMutableBufferPointer<Binding>) throws(Status) -> Int {
    try unsafe k.bind(port, items)
  }
  static func portCreate(options: UInt32) throws(Status) -> UInt32 { try k.portCreate(options: options) }
  static func portQueue(_ p: UInt32, _ packets: UnsafeBufferPointer<Packet>) throws(Status) -> Int {
    try unsafe k.portQueue(p, packets)
  }
  static func portWait(_ p: UInt32, _ deadline: Int64, _ packets: UnsafeMutableBufferPointer<Packet>) throws(Status)
    -> Int
  {
    try unsafe k.portWait(p, deadline: deadline, packets)
  }
  static func portCancel(_ p: UInt32, _ source: UInt32, _ key: UInt64) throws(Status) {
    try k.portCancel(p, source: source, key: key)
  }

  static func channelCreate() throws(Status) -> (UInt32, UInt32) { try k.channelCreate() }
  static func channelWrite(_ h: UInt32, _ bytes: [UInt8], _ handles: [UInt32]) throws(Status) {
    try k.channelWrite(h, bytes: bytes, handles: handles)
  }
  static func channelRead(_ h: UInt32) throws(Status) -> Channel.Message {
    var bytes = [UInt8](repeating: 0, count: Channel.maxBytes)
    var handles = [UInt32](repeating: 0, count: Channel.maxHandles)
    do {
      // Untyped closures: a `throws(E)` closure passed to these `rethrows`
      // methods miscompiles in Swift 6.4 (CLAUDE.md, "Toolchain pitfalls").
      let got = try unsafe bytes.withUnsafeMutableBytes { b in
        try unsafe handles.withUnsafeMutableBufferPointer { hb in
          try unsafe k.channelRead(h, bytes: b, handles: hb)
        }
      }
      return Channel.Message(bytes: Array(bytes[..<got.byteCount]), handles: Array(handles[..<got.handleCount]))
    } catch {
      throw (error as? HostKernel.ReadError)?.status ?? .invalidArgs
    }
  }
  static func channelWrite(_ items: UnsafeMutableBufferPointer<ChannelWriteItem>) throws(Status) -> Int {
    try unsafe k.channelWrite(items: items)
  }
  static func channelRead(_ items: UnsafeMutableBufferPointer<ChannelReadItem>) throws(Status) -> Int {
    try unsafe k.channelRead(items: items)
  }
  static func channelCall(_ h: UInt32, _ bytes: [UInt8], _ handles: [UInt32], _ deadline: Int64) throws(Status)
    -> Channel.Message
  {
    let m = try k.channelCall(h, bytes: bytes, handles: handles, deadline: deadline)
    return Channel.Message(bytes: m.bytes, handles: m.handles)
  }

  static func vmoCreate(_ size: Int) throws(Status) -> UInt32 { try k.vmoCreate(size: size) }
  static func vmoSize(_ h: UInt32) throws(Status) -> Int { try k.vmoSize(h) }
  static func vmoMap(_ h: UInt32, _ offset: Int, _ length: Int, _ writable: Bool) throws(Status) -> UnsafeMutableRawPointer {
    try unsafe k.vmoMap(h, offset: offset, length: length, writable: writable)
  }
  static func vmoUnmap(_ address: UnsafeMutableRawPointer, _ length: Int) { try? unsafe k.vmoUnmap(address) }

  // Resources, physical memory, interrupts and DMA: none hosted.
  static func vmoCreatePhysical(_ resource: UInt32, _ address: UInt64, _ size: Int) throws(Status) -> UInt32 {
    throw .notSupported
  }
  static func vmoCreateChild(_ vmo: UInt32, _ options: UInt32, _ offset: UInt64, _ size: Int) throws(Status) -> UInt32 {
    throw .notSupported
  }
  static func vmoSetCachePolicy(_ h: UInt32, _ policy: VMO.CachePolicy) throws(Status) { throw .notSupported }
  static func resourceCreate(_ parent: UInt32, _ options: UInt32, _ base: UInt64, _ size: UInt64, _ name: String)
    throws(Status) -> UInt32
  { throw .notSupported }
  static func resourceInfo(_ h: UInt32) throws(Status) -> ResourceInfo { throw .notSupported }
  static func ioportsRequest(_ resource: UInt32, _ base: UInt16, _ count: UInt16) throws(Status) { throw .notSupported }
  static func ioportsRelease(_ resource: UInt32, _ base: UInt16, _ count: UInt16) throws(Status) { throw .notSupported }
  /// No ports: reads see what a missing device gives, all ones.
  static func portIn(_ port: UInt16, _ width: Int) -> UInt32 { UInt32.max >> (32 - 8 * width) }
  static func portOut(_ port: UInt16, _ width: Int, _ value: UInt32) {}

  static func debuglogCreate() throws(Status) -> UInt32 { throw .notSupported }
  static func debuglogProgress(_ log: UInt32) throws(Status) -> (written: UInt64, printed: UInt64) { throw .notSupported }
  static func interruptCreate(_ resource: UInt32, _ number: UInt32, _ options: UInt32) throws(Status) -> UInt32 {
    throw .notSupported
  }
  static func interruptAck(_ items: UnsafeMutableBufferPointer<croi_interrupt_ack_item_t>) throws(Status) -> Int {
    throw .notSupported
  }
  static func interruptSetAffinity(_ h: UInt32, _ cpus: UInt64) throws(Status) { throw .notSupported }
  static func iommuCreate(_ resource: UInt32, _ type: UInt32, _ descriptor: [UInt8]) throws(Status) -> UInt32 {
    throw .notSupported
  }
  static func btiCreate(_ iommu: UInt32, _ id: UInt64) throws(Status) -> UInt32 { throw .notSupported }
  static func btiSetProperties(_ bti: UInt32, _ p: DMA.Properties) throws(Status) { throw .notSupported }
  static func vmoCreateContiguous(_ bti: UInt32, _ size: Int, _ alignmentLog2: UInt32) throws(Status) -> UInt32 {
    throw .notSupported
  }
  static func btiPin(_ bti: UInt32, _ vmo: UInt32, _ offset: Int, _ size: Int, _ options: UInt32, _ count: Int)
    throws(Status) -> (pmt: UInt32, addresses: [UInt64])
  { throw .notSupported }
  static func pmtUnpin(_ pmt: UInt32) throws(Status) { throw .notSupported }
  static func btiReleaseQuarantine(_ bti: UInt32) throws(Status) { throw .notSupported }
  static func taskStats(_ h: UInt32) throws(Status) -> TaskStats { throw .notSupported }
  static func taskRuntime(_ h: UInt32) throws(Status) -> TaskRuntime { throw .notSupported }
  static func child(_ h: UInt32, _ koid: UInt64, _ rights: UInt32) throws(Status) -> UInt32 { throw .notSupported }
  static func name(_ h: UInt32) throws(Status) -> String { throw .notSupported }
  static func setName(_ h: UInt32, _ name: String) throws(Status) { throw .notSupported }
  static func threadState(_ h: UInt32) throws(Status) -> UInt32 { throw .notSupported }
  static func koids(_ h: UInt32, _ topic: UInt32) throws(Status) -> [UInt64] { throw .notSupported }
  static func handleTable(_ h: UInt32) throws(Status) -> [HandleEntry] { throw .notSupported }
  static func msiAllocate(_ resource: UInt32, _ count: Int) throws(Status) -> UInt32 { throw .notSupported }
  static func msiCreate(_ allocation: UInt32, _ options: UInt32, _ id: UInt32, _ vmo: UInt32, _ offset: Int) throws(Status)
    -> UInt32
  { throw .notSupported }
  static func msiInfo(_ allocation: UInt32) throws(Status) -> MSIInfo { throw .notSupported }
  static func cpuStats(_ resource: UInt32, max: Int) throws(Status) -> [CPUStats] { throw .notSupported }
  static func kmemStats(_ resource: UInt32) throws(Status) -> KMemStats { throw .notSupported }
  static func powerctl(_ resource: UInt32, _ command: UInt32) throws(Status) { throw .notSupported }
  static func profileCreate(_ resource: UInt32, deadline: (Int64, Int64, Int64)) throws(Status) -> UInt32 {
    throw .notSupported
  }
  static func setProfile(_ target: UInt32, _ profile: UInt32, _ options: UInt32) throws(Status) -> UInt32 {
    throw .notSupported
  }

  static func counterCreate() throws(Status) -> UInt32 { try k.counterCreate() }
  static func counterAdd(_ items: UnsafeMutableBufferPointer<CounterAdd>) throws(Status) -> Int {
    try unsafe k.counterAdd(items)
  }
  static func counterRead(_ h: UInt32) throws(Status) -> Int64 { try k.counterRead(h) }

  static func processSelf() throws(Status) -> UInt32 { try k.processSelf() }
  /// The host thread's exit: the kernel's end key accounts for it.
  static func threadExit() -> Never { pthread_exit(nil) }
  /// A host thread key: any host thread's, the kernel's or not.
  static func threadSlot() -> UInt { unsafe UInt(bitPattern: pthread_getspecific(k.slotKey)) }
  static func setThreadSlot(_ v: UInt) { unsafe pthread_setspecific(k.slotKey, UnsafeRawPointer(bitPattern: v)) }
  static func realtime() -> Int64 {
    var ts = timespec()
    unsafe clock_gettime(CLOCK_REALTIME, &ts)
    return Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec)
  }
  static func futexWait(_ address: UnsafeMutablePointer<UInt32>, current: UInt32, deadline: Int64) throws(Status) {
    try unsafe k.futexWait(address, current: current, deadline: deadline)
  }
  static func futexWake(_ address: UnsafeMutablePointer<UInt32>, count: Int) { unsafe k.futexWake(address, count: count) }

  static func jobCreate(_ parent: UInt32) throws(Status) -> UInt32 { try k.jobCreate(parent: parent) }
  static func processCreate(_ job: UInt32, _ name: String) throws(Status) -> UInt32 { try k.processCreate(job: job, name: name) }
  static func threadCreate(_ process: UInt32) throws(Status) -> UInt32 { try k.threadCreate(process: process) }
  /// The handles move into the process, and its entry gets a Startup of
  /// their numbers there.
  static func processStart(_ process: UInt32, _ thread: UInt32, _ entry: ProgramEntry, _ startup: Startup,
                           _ handles: [(info: UInt32, handle: UInt32)]) throws(Status) {
    let (args, names) = (startup.args, startup.names)
    let infos = handles.map { $0.info }
    try k.threadStart(thread, args: handles.map { $0.handle }) { raws in
      let given = Startup(args: args, names: names)
      for (info, raw) in zip(infos, raws) { given.add(raw: raw, info: info) }
      entry.body(given)
    }
  }

  /// Hosted, the host process's: nothing.
  static let currentStartup = Startup()
  static func startupTake(_ info: UInt32) -> UInt32? { nil }
  static func startupInfos() -> [UInt32] { [] }
  static func threadStart(_ thread: UInt32, _ body: @escaping @Sendable () -> Void) throws(Status) {
    try k.threadStart(thread) { _ in body() }
  }
  static func kill(_ h: UInt32) throws(Status) { try k.kill(h) }
  static func exit(_ code: Int64) -> Never { k.exit(code: code) }
  static func processInfo(_ h: UInt32) throws(Status) -> ProcessInfo {
    let i = try k.processInfo(h)
    return ProcessInfo(returnCode: i.returnCode, started: i.started, exited: i.exited)
  }

  static func now() -> Int64 { HostKernel.now() }
  static func sleep(_ deadline: Int64) { k.sleep(until: deadline) }

  static func random(_ buffer: UnsafeMutableRawBufferPointer) throws(Status) {
    var at = 0
    while at < buffer.count {
      let n = min(256, buffer.count - at)
      guard unsafe getentropy(buffer.baseAddress! + at, n) == 0 else { throw .internal }
      at += n
    }
  }
}

extension Job {
  /// The root job, for the hosted boot (natively, userboot passes it to
  /// the launcher).
  public static func root() throws(Status) -> Handle { Handle(raw: try HostKernel.shared.rootJobHandle()) }
}
