// SPDX-License-Identifier: BSD-3-Clause

// Sys over the hosted kernel: each object kind, rights, bindings, and
// processes with their own handle tables (N0a), on V1's model (V2): the
// counter is the one event, and every wait a binding to a port.

import Glibc
import Sys
import Testing

/// The status `body` throws, or `.ok`.
func statusOf<R>(_ body: () throws(Status) -> R) -> Status {
  do throws(Status) {
    _ = try body()
    return .ok
  } catch {
    return error
  }
}

let second: Int64 = 1_000_000_000
func soon(_ ms: Int64 = 2000) -> Int64 { Clock.monotonic() + ms * 1_000_000 }

// MARK: The ABI (D45)

/// Status's and ResourceKind's cases are literals (an enum needs them):
/// the headers' values, and no others.
@Test func statusesAndKindsAreTheHeaders() {
  let statuses: [(Status, Int64)] = [
    (.ok, CROI_OK), (.internal, CROI_ERR_INTERNAL), (.notSupported, CROI_ERR_NOT_SUPPORTED),
    (.noResources, CROI_ERR_NO_RESOURCES), (.noMemory, CROI_ERR_NO_MEMORY), (.invalidArgs, CROI_ERR_INVALID_ARGS),
    (.badHandle, CROI_ERR_BAD_HANDLE), (.wrongType, CROI_ERR_WRONG_TYPE), (.outOfRange, CROI_ERR_OUT_OF_RANGE),
    (.bufferTooSmall, CROI_ERR_BUFFER_TOO_SMALL), (.badState, CROI_ERR_BAD_STATE), (.timedOut, CROI_ERR_TIMED_OUT),
    (.shouldWait, CROI_ERR_SHOULD_WAIT), (.canceled, CROI_ERR_CANCELED), (.peerClosed, CROI_ERR_PEER_CLOSED),
    (.notFound, CROI_ERR_NOT_FOUND), (.alreadyExists, CROI_ERR_ALREADY_EXISTS),
    (.alreadyBound, CROI_ERR_ALREADY_BOUND), (.unavailable, CROI_ERR_UNAVAILABLE),
    (.accessDenied, CROI_ERR_ACCESS_DENIED), (.io, CROI_ERR_IO), (.ioDataIntegrity, CROI_ERR_IO_DATA_INTEGRITY),
    (.fileBig, CROI_ERR_FILE_BIG), (.noSpace, CROI_ERR_NO_SPACE),
  ]
  for (status, value) in statuses { #expect(Int64(status.rawValue) == value, "\(status)") }
  #expect((-200...0).filter { Status(rawValue: Int32($0)) != nil }.count == statuses.count)
  let kinds: [(ResourceKind, UInt32)] = [
    (.mmio, CROI_RSRC_KIND_MMIO), (.irq, CROI_RSRC_KIND_IRQ), (.ioport, CROI_RSRC_KIND_IOPORT),
    (.root, CROI_RSRC_KIND_ROOT), (.smc, CROI_RSRC_KIND_SMC), (.system, CROI_RSRC_KIND_SYSTEM),
  ]
  for (kind, value) in kinds { #expect(kind.rawValue == value, "\(kind)") }
  #expect((0..<64).filter { ResourceKind(rawValue: UInt32($0)) != nil }.count == kinds.count)
}

// MARK: Handles and rights

@Test func duplicateAndReplaceNarrowRights() throws {
  let counter = try Counter.create()
  let reader = try counter.duplicate([.wait, .transfer])
  #expect(try reader.info().rights == [.wait, .transfer])
  #expect(statusOf { () throws(Status) in try Counter.add(reader, 1) } == .accessDenied)
  #expect(statusOf { () throws(Status) in try reader.duplicate() } == .accessDenied)
  #expect(statusOf { () throws(Status) in try counter.duplicate([.wait, .manageJob]) } == .invalidArgs)

  let narrowed = try counter.replace([.read, .write, .wait])
  try Counter.add(narrowed, 1)
  #expect(try reader.wait(for: Signals.positive, deadline: 0) & Signals.positive != 0)
}

@Test func rightsTravelWithTheHandle() throws {
  let ends = try Channel.create()
  let a = ends.a, b = ends.b
  let counter = try Counter.create()
  let waitOnly = try counter.duplicate([.wait, .transfer])
  try Channel.write(a, bytes: [0, 0, 0, 0], handles: [waitOnly.release()])
  let moved = Handle(raw: try Channel.read(b).handles[0])
  #expect(try moved.info().rights == [.wait, .transfer])

  // Without TRANSFER a handle can't move, and the write consumes it anyway.
  let fixed = try counter.duplicate([.wait])
  let raw = fixed.release()
  #expect(statusOf { () throws(Status) in try Channel.write(a, bytes: [], handles: [raw]) } == .accessDenied)
  #expect(statusOf { () throws(Status) in try Kernel_info(raw) } == .badHandle)
}

func Kernel_info(_ raw: UInt32) throws(Status) -> HandleInfo {
  try lending(raw) { (h: borrowing Handle) throws(Status) in try h.info() }
}

/// Lends a raw handle the caller still owns to `body` as a `Handle`.
func lending<R, E: Error>(_ raw: UInt32, _ body: (borrowing Handle) throws(E) -> R) throws(E) -> R {
  let h = Handle(raw: raw)
  do throws(E) {
    let r = try body(h)
    _ = h.release()
    return r
  } catch {
    _ = h.release()
    throw error
  }
}

@Test func infoGivesKoidsTypesAndPeers() throws {
  let ends = try Channel.create()
  let a = try ends.a.info(), b = try ends.b.info()
  #expect(a.type == ObjectType.channel && b.type == ObjectType.channel)
  #expect(a.relatedKoid == b.koid && b.relatedKoid == a.koid)
  #expect(a.rights == Rights.basic.subtracting(.duplicate).union([.read, .write, .signal]))
  let counter = try Counter.create().info()
  #expect(counter.type == ObjectType.counter && counter.relatedKoid == 0)
}

@Test func flowIDsAreCroisSplitmix() {
  // Reference values from an independent splitmix64 (ipc.h's croi_flow_id).
  #expect(flowID(channel: 1024, txid: 1) == 0x9d61_a03a_3cfc_0647)
  #expect(flowID(channel: 0, txid: 0) == 0)
  #expect(flowID(channel: UInt64.max, txid: UInt32.max) == 0xd940_3093_1f5c_bbca)
}

@Test func closingAnEndSignalsThePeer() throws {
  let ends = try Channel.create()
  var a: Handle? = ends.a
  let b = ends.b
  #expect(statusOf { () throws(Status) in try b.wait(for: Signals.peerClosed, deadline: 0) } == .timedOut)
  a = nil
  #expect(try b.wait(for: Signals.peerClosed, deadline: 0) & Signals.peerClosed != 0)
  #expect(statusOf { () throws(Status) in try Channel.read(b) } == .peerClosed)
}

// MARK: Channel calls

/// Serves `count` calls on `end` from another thread: each reply is the
/// request's bytes with every byte after the txid incremented.
func serve(_ end: consuming Handle, count: Int, delayMs: Int64 = 0) -> pthread_t {
  final class Box: @unchecked Sendable {
    let raw: UInt32
    let count: Int
    let delay: Int64
    init(_ raw: UInt32, _ count: Int, _ delay: Int64) {
      self.raw = raw
      self.count = count
      self.delay = delay
    }
  }
  let box = Unmanaged.passRetained(Box(end.release(), count, delayMs)).toOpaque()
  var thread = pthread_t()
  pthread_create(&thread, nil, { arg in
    let box = Unmanaged<Box>.fromOpaque(arg!).takeRetainedValue()
    let end = Handle(raw: box.raw)
    for _ in 0..<box.count {
      guard (try? end.wait(for: Signals.readable | Signals.peerClosed)) != nil,
            let m = try? Channel.read(end) else { break }
      if box.delay > 0 { sleep(until: Clock.monotonic() + box.delay * 1_000_000) }
      var reply = m.bytes
      for i in 4..<reply.count { reply[i] &+= 1 }
      try? Channel.write(end, bytes: reply, handles: m.handles)
    }
    return nil
  }, box)
  return thread
}

@Test func callGetsItsOwnReply() throws {
  let ends = try Channel.create()
  let client = ends.a
  let server = serve(ends.b, count: 3)
  for n in UInt8(1)...3 {
    let counter = try Counter.create()
    let reply = try Channel.call(client, bytes: [0, 0, 0, 0, n, n], handles: [counter.release()], deadline: soon())
    #expect(reply.bytes.count == 6)
    #expect(reply.bytes[4...] == [n + 1, n + 1])
    #expect(reply.bytes[3] & 0x80 != 0)  // the kernel's txids have the high bit
    #expect(reply.handles.count == 1)
    close(raw: reply.handles[0])
  }
  pthread_join(server, nil)
}

@Test func callsFromManyThreadsEachGetTheirReply() throws {
  let ends = try Channel.create()
  let raw = ends.a.release()
  let server = serve(ends.b, count: 64)
  final class Failures: @unchecked Sendable { var count = 0; var lock = pthread_mutex_t() }
  let failures = Failures()
  pthread_mutex_init(&failures.lock, nil)
  DispatchlessParallel.run(8) { worker in
    lending(raw) { (c: borrowing Handle) in
      for i in 0..<8 {
        let tag = UInt8(worker * 8 + i)
        let ok = (try? Channel.call(c, bytes: [0, 0, 0, 0, tag], deadline: soon()))?.bytes.last == tag &+ 1
        if !ok {
          pthread_mutex_lock(&failures.lock)
          failures.count += 1
          pthread_mutex_unlock(&failures.lock)
        }
      }
    }
  }
  #expect(failures.count == 0)
  close(raw: raw)
  pthread_join(server, nil)
}

@Test func callTimesOutAndALateReplyIsDropped() throws {
  let ends = try Channel.create()
  let client = ends.a
  let server = serve(ends.b, count: 2, delayMs: 50)
  #expect(statusOf { () throws(Status) in
    try Channel.call(client, bytes: [0, 0, 0, 0, 7], deadline: Clock.monotonic() + 5_000_000)
  } == .timedOut)
  // The first reply arrives after the call gave up: it lands on the
  // channel as an ordinary message, not in the next call.
  let reply = try Channel.call(client, bytes: [0, 0, 0, 0, 9], deadline: soon())
  #expect(reply.bytes.last == 10)
  pthread_join(server, nil)
  #expect(try Channel.read(client).bytes.last == 8)
}

@Test func callSeesThePeerClose() throws {
  let ends = try Channel.create()
  let client = ends.a
  let server = serve(ends.b, count: 0)  // closes its end at once
  pthread_join(server, nil)
  #expect(statusOf { () throws(Status) in try Channel.call(client, bytes: [0, 0, 0, 0], deadline: soon()) }
    == .peerClosed)
}

// MARK: Bindings and ports

/// A counter, positive (`value` above zero) and bound to `port`.
func positive(_ port: borrowing Handle, key: UInt64, persistent: Bool = false, edge: Bool = false) throws -> Handle {
  let c = try Counter.create()
  try c.bind(port: port, key: key, signals: Signals.positive, persistent: persistent, edge: edge)
  return c
}

/// channel_write and channel_read in arrays (D41): going on past an item
/// that fails (its handles consumed), a message larger than the read slot,
/// an empty channel, and more items than one call takes, in order.
@Test func channelsReadAndWriteInArrays() throws {
  let one = try Channel.create(), two = try Channel.create(), three = try Channel.create()
  let counter = try Counter.create()
  let lost = try counter.duplicate().release()
  let big = [UInt8](repeating: 9, count: Channel.readSlot + 1000)
  var out = [Channel.Outgoing(channel: one.a.raw, bytes: [1, 2, 3], handles: [try counter.duplicate().release()]),
             Channel.Outgoing(channel: two.a.raw, bytes: big),
             Channel.Outgoing(channel: 0x7FFF_FFF0, bytes: [4], handles: [lost])]
  #expect(try Channel.write(&out) == 2)
  #expect(out.map { $0.status } == [.ok, .ok, .badHandle])
  #expect(statusOf { () throws(Status) in try Handle(raw: lost).info() } == .badHandle)

  var reads = [Channel.Incoming(channel: one.b.raw), Channel.Incoming(channel: two.b.raw),
               Channel.Incoming(channel: three.b.raw)]
  #expect(try Channel.read(&reads) == 2)
  #expect(reads[0].message?.bytes == [1, 2, 3] && reads[0].message?.handles.count == 1)
  let moved = Handle(raw: reads[0].message!.handles[0])
  #expect(try moved.info().koid == counter.info().koid)
  #expect(reads[1].message?.bytes == big)
  #expect(reads[2].status == .shouldWait && reads[2].message == nil)

  let count = Int(CROI_CHANNEL_MAX_ITEMS) + 6
  var many = (0..<count).map { Channel.Outgoing(channel: three.a.raw, bytes: [UInt8($0)]) }
  #expect(try Channel.write(&many) == count)
  var back = (0..<count).map { _ in Channel.Incoming(channel: three.b.raw) }
  #expect(try Channel.read(&back) == count)
  #expect(back.map { $0.message?.bytes ?? [] } == (0..<count).map { [UInt8($0)] })

  let pair = try Channel.create()
  let writer = pair.a, reader = pair.b
  _ = consume writer
  var closed = [Channel.Incoming(channel: reader.raw)]
  _ = try Channel.read(&closed)
  #expect(closed[0].status == .peerClosed)
}

@Test func bindOnceQueuesOnePacket() throws {
  let port = try Port.create()
  let c = try positive(port, key: 42)
  #expect(statusOf { () throws(Status) in try Port.wait(port, deadline: 0) } == .timedOut)
  try Counter.add(c, 1)
  let packet = try Port.wait(port, deadline: 0)
  #expect(packet.key == 42 && packet.type == CROI_PKT_TYPE_SIGNAL)
  #expect(packet.trigger == Signals.positive && packet.observed == Signals.positive)
  // Once: it doesn't fire again.
  try Counter.add(c, -1)
  try Counter.add(c, 1)
  #expect(statusOf { () throws(Status) in try Port.wait(port, deadline: 0) } == .timedOut)
}

@Test func levelBindingFiresAtOnceAndEdgeWaitsForAChange() throws {
  let port = try Port.create()
  let c = try Counter.create()
  try Counter.add(c, 1)
  try c.bind(port: port, key: 1, signals: Signals.positive)
  try c.bind(port: port, key: 2, signals: Signals.positive, edge: true)
  #expect(try Port.wait(port, deadline: 0).key == 1)
  #expect(statusOf { () throws(Status) in try Port.wait(port, deadline: 0) } == .timedOut)
  try Counter.add(c, -1)
  try Counter.add(c, 1)
  #expect(try Port.wait(port, deadline: 0).key == 2)
}

/// A persistent binding: a packet when READABLE rises, not at messages to
/// a channel already readable (its reader drains); drained, the next
/// message brings another.
@Test func persistentBindingFiresAgainOnceDrained() throws {
  let port = try Port.create()
  let ends = try Channel.create()
  try ends.b.bind(port: port, key: 7, signals: Signals.readable, persistent: true)
  for n in UInt8(1)...3 { try Channel.write(ends.a, bytes: [n]) }
  let first = try Port.wait(port, deadline: 0)
  #expect(first.key == 7 && first.payload.1 == 1)
  #expect(statusOf { () throws(Status) in try Port.wait(port, deadline: 0) } == .timedOut)
  for _ in 0..<3 { _ = try Channel.read(ends.b) }
  while (try? Port.wait(port, deadline: 0)) != nil {}
  try Channel.write(ends.a, bytes: [4])
  #expect(try Port.wait(port, deadline: 0).key == 7)
}

@Test func userPacketsInArraysAndCancel() throws {
  let port = try Port.create()
  try Port.queue(port, Packet(key: 5, payload: (1, 2, 3, 4)))
  let p = try Port.wait(port, deadline: 0)
  #expect(p.key == 5 && p.type == CROI_PKT_TYPE_USER && p.payload.3 == 4)
  #expect(try Port.queue(port, [Packet(key: 1), Packet(key: 2), Packet(key: 3)]) == 3)
  #expect(try Port.wait(port, deadline: 0, max: 8).map { $0.key } == [1, 2, 3])

  let c = try positive(port, key: 6)
  try Port.cancel(port, source: c, key: 6)
  try Counter.add(c, 1)
  #expect(statusOf { () throws(Status) in try Port.wait(port, deadline: 0) } == .timedOut)
  // Nothing left to cancel, by source or by key alone.
  #expect(statusOf { () throws(Status) in try Port.cancel(port, source: c, key: 6) } == .notFound)
  #expect(statusOf { () throws(Status) in try Port.cancel(port, key: 6) } == .notFound)
  // Every source's, by key: a queued packet goes with its binding.
  let d = try positive(port, key: 8)
  try Counter.add(d, 1)
  try Port.cancel(port, key: 8)
  #expect(statusOf { () throws(Status) in try Port.wait(port, deadline: 0) } == .timedOut)
}

@Test func closingTheBoundHandleCancelsItsBinding() throws {
  let port = try Port.create()
  let c = try Counter.create()
  var bound: Handle? = try c.duplicate()
  try bound!.bind(port: port, key: 3, signals: Signals.positive)
  bound = nil
  try Counter.add(c, 1)
  #expect(statusOf { () throws(Status) in try Port.wait(port, deadline: 0) } == .timedOut)
}

/// object_bind's array: in order, stopping at the first that fails, each
/// one's status written back.
@Test func bindTakesArrays() throws {
  let port = try Port.create()
  let a = try Counter.create(), b = try Counter.create()
  var items = [Binding.signals(a.raw, Signals.positive, key: 1), Binding.value(b.raw, 2, key: 2),
               Binding.signals(0x7FFF_FFF0, Signals.positive, key: 3), Binding.signals(b.raw, Signals.positive, key: 4)]
  #expect(try Port.bind(port, &items) == 2)
  #expect(items.map { $0.status } == [0, 0, Status.badHandle.rawValue, 0])
  try Counter.add(b, 2)
  #expect(try Port.wait(port, deadline: 0).key == 2)
}

@Test func portWakesAWaitingThread() throws {
  let port = try Port.create()
  let channel = try Channel.create()
  try channel.b.bind(port: port, key: 9, signals: Signals.readable)
  let raw = channel.a.release()  // channels can't be duplicated
  var t = pthread_t()
  pthread_create(&t, nil, { arg in
    let a = Handle(raw: UInt32(UInt(bitPattern: arg)))
    sleep(until: Clock.monotonic() + 10_000_000)
    try? Channel.write(a, bytes: [1])
    return nil
  }, UnsafeMutableRawPointer(bitPattern: UInt(raw)))
  let packet = try Port.wait(port, deadline: soon())
  #expect(packet.key == 9 && packet.trigger == Signals.readable)
  pthread_join(t, nil)
}

/// A wait is a ONCE binding on the thread's own port: it times out at its
/// deadline, leaving no binding behind, and sees the event when it comes.
@Test func waitsTimeOutAndSeeTheirEvent() throws {
  let c = try Counter.create()
  let start = Clock.monotonic()
  #expect(statusOf { () throws(Status) in try c.wait(for: Signals.positive, deadline: start + 5_000_000) } == .timedOut)
  #expect(Clock.monotonic() - start >= 5_000_000)
  let raw = c.raw
  let adder = try Thread.spawn {
    let borrowed = Handle(raw: raw)
    sleep(until: Clock.monotonic() + 5_000_000)
    try? Counter.add(borrowed, 1)
    _ = borrowed.release()
  }
  #expect(try c.wait(for: Signals.positive, deadline: soon()) & Signals.positive != 0)
  try Thread.join(adder)
}

@Test func sleepReachesItsDeadline() {
  let start = Clock.monotonic()
  sleep(until: start + 20_000_000)
  #expect(Clock.monotonic() - start >= 20_000_000)
}

// MARK: VMOs

@Test func vmoMapsAndRights() throws {
  let vmo = try VMO.create(size: 5000)
  #expect(try VMO.size(vmo) == 8192)
  let shared = try vmo.duplicate()
  do {
    let a = try VMO.map(vmo, length: 8192)
    let b = try VMO.map(shared, offset: 4096, length: 4096)
    a.write([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], at: 4090)
    #expect(a.read(at: 4090, count: 10) == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
    a.store(UInt64(0x1122_3344_5566_7788), at: 4096 + 16)
    #expect(b.load(UInt64.self, at: 16) == 0x1122_3344_5566_7788)
    #expect(b.load(UInt8.self, at: 0) == 7)
  }

  let readOnly = try vmo.duplicate([.read, .map])
  #expect(statusOf { () throws(Status) in try VMO.map(readOnly, length: 4096, writable: true) } == .accessDenied)
  #expect(statusOf { () throws(Status) in try VMO.map(readOnly, length: 4096, writable: false) } == .ok)
  #expect(statusOf { () throws(Status) in try VMO.map(vmo, offset: 100, length: 4096) } == .outOfRange)
}

@Test func aMappingKeepsTheVMO() throws {
  var vmo: Handle? = try VMO.create(size: 4096)
  let mapping = try VMO.map(vmo!, length: 4096)
  vmo = nil
  mapping.store(UInt32(77), at: 0)
  #expect(mapping.load(UInt32.self, at: 0) == 77)
}

// MARK: Jobs, processes, threads

/// What a hosted process reports back: a channel its entry writes to.
struct Spawned: ~Copyable {
  var process: Handle
  var report: Handle
}

func spawn(_ job: borrowing Handle, _ name: String, _ entry: ProgramEntry) throws -> Spawned {
  let process = try Process.create(job: job, name: name)
  let ends = try Channel.create()
  let report = ends.a
  _ = try Process.start(process, entry: entry, arg: ends.b)
  return Spawned(process: process, report: report)
}

@Test func aProcessHasItsOwnHandleTable() throws {
  let root = try Job.root()
  let job = try Job.create(parent: root)
  let mine = try Counter.create()
  let mineRaw = mine.raw
  let spawned = try spawn(job, "isolated", ProgramEntry { startup in
    // The host's handle number means nothing here.
    let foreign = Handle(raw: mineRaw)
    let status = statusOf { () throws(Status) in try foreign.info() }
    _ = foreign.release()
    // Its own handles work.
    let counter = try? Counter.create()
    let ok: UInt8 = (try? counter?.info()) != nil ? 1 : 0
    try? Channel.write(startup, bytes: [UInt8(truncatingIfNeeded: -status.rawValue), ok])
    Process.exit(code: 3)
  })
  let process = spawned.process
  let report = spawned.report
  _ = try report.wait(for: Signals.readable, deadline: soon())
  #expect(try Channel.read(report).bytes == [UInt8(-Status.badHandle.rawValue), 1])
  _ = try process.wait(for: Signals.terminated, deadline: soon())
  let info = try Process.info(process)
  #expect(info.exited && info.started && info.returnCode == 3)
  // Its handles closed when it ended, the startup channel's end among them.
  #expect(try report.wait(for: Signals.peerClosed, deadline: soon()) & Signals.peerClosed != 0)
}

@Test func aProcessEndsWithItsLastThread() throws {
  let root = try Job.root()
  let job = try Job.create(parent: root)
  let spawned = try spawn(job, "threads", ProgramEntry { startup in
    let ends = try! Channel.create()
    let raw = ends.a.release()
    var keep: Handle? = ends.b
    try? Channel.write(startup, bytes: [1], handles: [raw])
    _ = try? keep!.wait(for: Signals.readable, deadline: soon())
    keep = nil
  })
  let process = spawned.process
  let report = spawned.report
  _ = try report.wait(for: Signals.readable, deadline: soon())
  let m = try Channel.read(report)
  let go = Handle(raw: m.handles[0])
  // Still running: its thread waits for us.
  #expect(statusOf { () throws(Status) in try process.wait(for: Signals.terminated, deadline: 0) } == .timedOut)
  try Channel.write(go, bytes: [2])
  _ = try process.wait(for: Signals.terminated, deadline: soon())
  #expect(try Process.info(process).returnCode == 0)
}

/// A process that reports in, then blocks until killed.
let sleeper = ProgramEntry { startup in
  try? Channel.write(startup, bytes: [1])
  let counter = try? Counter.create()
  _ = try? counter?.wait(for: Signals.positive)
  try? Channel.write(startup, bytes: [2])
}

@Test func killingAJobEndsItsProcessesEvenWhileTheyWait() throws {
  let root = try Job.root()
  let job = try Job.create(parent: root)
  let child = try Job.create(parent: job)
  let a = try spawn(job, "sleeper-a", sleeper)
  let b = try spawn(child, "sleeper-b", sleeper)
  _ = try a.report.wait(for: Signals.readable, deadline: soon())
  _ = try b.report.wait(for: Signals.readable, deadline: soon())
  try kill(job)
  for s in [a.process.raw, b.process.raw] {
    try lending(s) { (p: borrowing Handle) throws(Status) in
      _ = try p.wait(for: Signals.terminated, deadline: soon())
      #expect(try Process.info(p).returnCode == -1024)
    }
  }
  #expect(try job.wait(for: Signals.terminated, deadline: 0) & Signals.terminated != 0)
  #expect(try child.wait(for: Signals.terminated, deadline: 0) & Signals.terminated != 0)
  for r in [a.report.raw, b.report.raw] {
    try lending(r) { (report: borrowing Handle) throws(Status) in
      _ = try Channel.read(report)  // the first message only
      #expect(statusOf { () throws(Status) in try Channel.read(report) } == .peerClosed)
    }
  }
  #expect(statusOf { () throws(Status) in try Process.create(job: job, name: "late") } == .badState)
}

@Test func aThreadCanBeKilledAlone() throws {
  let root = try Job.root()
  let job = try Job.create(parent: root)
  let spawned = try spawn(job, "two", ProgramEntry { startup in
    try? Channel.write(startup, bytes: [1])
    // Lives until the host says so.
    _ = try? startup.wait(for: Signals.readable)
  })
  let process = spawned.process
  let report = spawned.report
  _ = try report.wait(for: Signals.readable, deadline: soon())
  _ = try Channel.read(report)
  // A second thread in that process, blocked in a wait forever.
  let thread = try Thread.create(process: process)
  try Thread.start(thread) {
    let counter = try? Counter.create()
    _ = try? counter?.wait(for: Signals.positive)
  }
  _ = try thread.wait(for: Signals.threadRunning, deadline: soon())
  try kill(thread)
  _ = try thread.wait(for: Signals.terminated, deadline: soon())
  // The process goes on with its first thread.
  #expect(statusOf { () throws(Status) in try process.wait(for: Signals.terminated, deadline: 0) } == .timedOut)
  try Channel.write(report, bytes: [2])
  _ = try process.wait(for: Signals.terminated, deadline: soon())
}

@Test func jobsNeedTheirRights() throws {
  let root = try Job.root()
  let job = try Job.create(parent: root)
  let weak = try job.duplicate([.wait, .inspect])
  #expect(statusOf { () throws(Status) in try Process.create(job: weak, name: "x") } == .accessDenied)
  #expect(statusOf { () throws(Status) in try Job.create(parent: weak) } == .accessDenied)
  #expect(statusOf { () throws(Status) in try kill(weak) } == .accessDenied)
  let counter = try Counter.create()
  #expect(statusOf { () throws(Status) in try Process.create(job: counter, name: "x") } == .wrongType)
}

/// Runs `body(i)` on `count` threads and joins them.
enum DispatchlessParallel {
  final class Work: @unchecked Sendable {
    let body: @Sendable (Int) -> Void
    let index: Int
    init(_ body: @escaping @Sendable (Int) -> Void, _ index: Int) {
      self.body = body
      self.index = index
    }
  }

  static func run(_ count: Int, _ body: @escaping @Sendable (Int) -> Void) {
    var threads: [pthread_t] = []
    for i in 0..<count {
      var t = pthread_t()
      pthread_create(&t, nil, { arg in
        let w = Unmanaged<Work>.fromOpaque(arg!).takeRetainedValue()
        w.body(w.index)
        return nil
      }, Unmanaged.passRetained(Work(body, i)).toOpaque())
      threads.append(t)
    }
    for t in threads { pthread_join(t, nil) }
  }
}

// MARK: Locks, threads in this process, futexes (M3b)

@Test func processCurrentIsTheCallersProcess() throws {
  let me = try Process.current()
  let again = try Process.current()
  let a = try me.info(), b = try again.info()
  #expect(a.koid == b.koid && a.type == ObjectType.process)
}

@Test func spawnedThreadsRunAndJoin() throws {
  final class Box: @unchecked Sendable { var ran = 0 }
  let box = Box()
  let lock = Lock()
  var threads: [UInt32] = []
  for _ in 0..<4 {
    let t = try Thread.spawn {
      for _ in 0..<1000 { lock.withLock { box.ran += 1 } }
    }
    threads.append(t.release())
  }
  for raw in threads {
    let t = Handle(raw: raw)
    try Thread.join(t)
  }
  #expect(box.ran == 4000)
}

@Test func lockExcludesUnderContention() throws {
  final class Box: @unchecked Sendable { var inside = 0; var worst = 0; var total = 0 }
  let box = Box()
  let lock = Lock()
  var threads: [UInt32] = []
  for _ in 0..<8 {
    threads.append(try Thread.spawn {
      for _ in 0..<2000 {
        lock.lock()
        box.inside += 1
        box.worst = max(box.worst, box.inside)
        box.total += 1
        sched_yield()
        box.inside -= 1
        lock.unlock()
      }
    }.release())
  }
  for raw in threads { try Thread.join(Handle(raw: raw)) }
  #expect(box.total == 16000)
  #expect(box.worst == 1)
}

@Test func futexWaitChecksTheWordTimesOutAndWakes() throws {
  let word = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
  defer { word.deallocate() }
  word.pointee = 0
  // A wait for a value the word doesn't hold refuses at once.
  #expect(statusOf { () throws(Status) in try Futex.wait(word, current: 2) } == .badState)
  // One for the value it holds sleeps until its deadline...
  let start = Clock.monotonic()
  #expect(statusOf { () throws(Status) in try Futex.wait(word, current: 0, deadline: start + 20_000_000) } == .timedOut)
  #expect(Clock.monotonic() - start >= 20_000_000)
  // ...or until a wake.
  let address = UInt(bitPattern: word)
  let waker = try Thread.spawn {
    usleep(20_000)
    Futex.wake(UnsafeMutablePointer<UInt32>(bitPattern: address)!, count: 1)
  }
  #expect(statusOf { () throws(Status) in try Futex.wait(word, current: 0, deadline: Clock.monotonic() + 5 * second) } == .ok)
  try Thread.join(waker)
}

/// Counters: add (one, or an array going on past a failure), read, the
/// sign's signals, a wait until a value (a VALUE binding on the thread's
/// port), and the port packet when it's reached.
@Test func countersReachTheirValues() throws {
  let c = try Counter.create()
  #expect(try Counter.read(c) == 0)
  #expect(try c.wait(for: Signals.nonPositive, deadline: 0) & Signals.nonPositive != 0)
  try Counter.add(c, 3)
  #expect(try Counter.read(c) == 3)
  #expect(try c.wait(for: Signals.positive, deadline: 0) & Signals.positive != 0)
  #expect(throws: Status.timedOut) { try Counter.wait(c, until: 4, deadline: Clock.monotonic() + 1_000_000) }
  let port = try Port.create()
  try Port.bind(port, Binding.value(c.raw, 10, key: 9))
  #expect(throws: (any Error).self) { _ = try Port.wait(port, deadline: 0) }
  let raw = c.raw
  let adder = try Thread.spawn {
    let borrowed = Handle(raw: raw)
    sleep(until: Clock.monotonic() + 5_000_000)
    try? Counter.add(borrowed, 7)
    _ = borrowed.release()
  }
  try Counter.wait(c, until: 10, deadline: Clock.monotonic() + 2_000_000_000)
  let p = try Port.wait(port, deadline: Clock.monotonic() + 1_000_000_000)
  #expect(p.key == 9 && p.type == Counter.packetType && p.payload.0 == 10 && p.payload.1 == 10)
  try Thread.join(adder)

  let d = try Counter.create()
  var items = [CounterAdd(counter: c.raw, status: 0, amount: 1), CounterAdd(counter: 0x7FFF_FFF0, status: 0, amount: 1),
               CounterAdd(counter: d.raw, status: 0, amount: Int64.max), CounterAdd(counter: d.raw, status: 0, amount: 1)]
  #expect(try Counter.add(&items) == 2)
  #expect(items.map { $0.status } == [0, Status.badHandle.rawValue, 0, Status.outOfRange.rawValue])
  #expect(try Counter.read(c) == 11 && Counter.read(d) == Int64.max)
}

/// A counter bound for its changes: a packet at every add, coalesced while
/// unread (the doorbell).
@Test func counterChangesRingTheDoorbell() throws {
  let port = try Port.create()
  let c = try Counter.create()
  try Port.bind(port, Binding.changes(c.raw, key: 4))
  try Counter.add(c, 1)
  try Counter.add(c, 1)
  let p = try Port.wait(port, deadline: 0)
  #expect(p.type == Counter.changePacketType && p.payload.1 == 2 && p.payload.2 == 2)
  try Counter.add(c, 5)
  #expect(try Port.wait(port, deadline: 0).payload.1 == 7)
}

@Test func theCPRNGFillsWhatIsAskedFor() throws {
  // Past cprng_draw's 256 bytes a call, and two draws differ.
  let a = try CPRNG.draw(count: 1000), b = try CPRNG.draw(count: 1000)
  #expect(a.count == 1000 && a != b && a.contains { $0 != 0 })
  #expect(try CPRNG.draw(count: 0).isEmpty)
}
