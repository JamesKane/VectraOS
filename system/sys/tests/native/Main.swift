// SPDX-License-Identifier: BSD-3-Clause

// bin/sys-test: Sys over the kernel (V2), what SysTests checks over the
// hosted kernel, natively: handles and rights, channels and calls, bindings
// and ports, waits on the thread's port, mappings, threads the floor starts
// (their stacks reclaimed), locks, futexes, counters, tasks and the CPRNG.
// userboot starts it (userboot.next=bin/sys-test, the boot-sys test); it
// exits 0 if every check passed.

import LibSys
import Sys
import TDFloor
import TDNative

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func check(_ condition: Bool, _ name: StaticString) {
  checks += 1
  if !condition {
    failures += 1
    print("sys-test: FAILED: \(name)")
  }
}

/// The status `body` throws, or `.ok`.
func statusOf<R>(_ body: () throws(Status) -> R) -> Status {
  do throws(Status) {
    _ = try body()
    return .ok
  } catch {
    return error
  }
}

let millisecond: Int64 = 1_000_000
func soon(_ ms: Int64 = 2000) -> Int64 { Clock.monotonic() + ms * millisecond }

/// A String's bytes are `text`'s (String's `==` normalizes, which needs
/// Unicode tables the program doesn't link).
func same(_ string: String, _ text: StaticString) -> Bool {
  unsafe Array(string.utf8) == Array(UnsafeBufferPointer(start: text.utf8Start, count: text.utf8CodeUnitCount))
}

@main
struct SysTest {
  static func main() {
    let args = Startup.current.args
    if args.count == 2 {
      if same(args[1], "stdio") { stdioChild() }
      if same(args[1], "hangup") { hangupChild() }
      if same(args[1], "descriptors") { descriptorsChild() }
      childMain()
    }
    do throws(Status) {
      try handles()
      try channels()
      try channelArrays()
      try bindings()
      try waits()
      try mappings()
      try threads()
      try futexes()
      try counters()
      try tasks()
      try random()
    } catch {
      print("sys-test: FAILED: a call threw \(error.rawValue)")
      failures += 1
    }
    print("sys-test: \(checks - failures) of \(checks) checks passed")
    Process.exit(code: failures == 0 ? 0 : 1)
  }

  static func handles() throws(Status) {
    let counter = try Counter.create()
    let reader = try counter.duplicate([.wait, .transfer])
    check(try reader.info().rights == [.wait, .transfer], "a duplicate has the rights asked for")
    check(statusOf { () throws(Status) in try Counter.add(reader, 1) } == .accessDenied, "and no others")
    check(statusOf { () throws(Status) in try reader.duplicate() } == .accessDenied, "duplicating needs DUPLICATE")
    let narrowed = try counter.replace([.read, .write, .wait])
    try Counter.add(narrowed, 1)
    check(try reader.wait(for: Signals.positive, deadline: 0) & Signals.positive != 0, "a replaced handle works")
    let info = try narrowed.info(), again = try reader.info()
    check(info.type == ObjectType.counter && info.koid == again.koid, "info: type and koid")
    let vmo = try VMO.create(size: 4096)
    try vmo.setName("sys-test")
    check(same(try vmo.name(), "sys-test"), "a name set is read back")
    close(raw: [try vmo.duplicate().release(), 0, try vmo.duplicate().release()])
    check(true, "handles closed in one call")
  }

  static func channels() throws(Status) {
    let ends = try Channel.create()
    let a = ends.a, b = ends.b
    check(statusOf { () throws(Status) in try Channel.read(b) } == .shouldWait, "an empty channel")
    let counter = try Counter.create()
    let big = [UInt8](repeating: 7, count: 10_000)
    try Channel.write(a, bytes: big, handles: [try counter.duplicate().release()])
    let m = try Channel.read(b)
    check(m.bytes == big && m.handles.count == 1, "a message's bytes and handles, sized first")
    let moved = Handle(raw: m.handles[0])
    let movedKoid = try moved.info().koid, koid = try counter.info().koid
    check(movedKoid == koid, "a handle moved is the same object")

    // A call, served by another thread: its reply is the request plus one.
    let raw = b.release()
    let server = try Thread.spawn {
      let end = Handle(raw: raw)
      if (try? end.wait(for: Signals.readable, deadline: soon())) != nil, let m = try? Channel.read(end) {
        var reply = m.bytes
        for i in 4..<reply.count { reply[i] &+= 1 }
        try? Channel.write(end, bytes: reply)
      }
    }
    let reply = try Channel.call(a, bytes: [0, 0, 0, 0, 41], deadline: soon())
    check(reply.bytes.count == 5 && reply.bytes[4] == 42, "a call gets its reply")
    try Thread.join(server)
    check(statusOf { () throws(Status) in try Channel.call(a, bytes: [0, 0, 0, 0], deadline: soon()) }
            == .peerClosed, "a call sees the peer gone")
  }

  /// channel_write and channel_read in arrays (D41): a message larger
  /// than the read slot, a failed item that still consumes its handle, an
  /// empty channel, and more items than one call takes, in order.
  static func channelArrays() throws(Status) {
    let one = try Channel.create(), two = try Channel.create(), three = try Channel.create()
    let counter = try Counter.create()
    let lost = try counter.duplicate().release()
    let big = [UInt8](repeating: 9, count: Channel.readSlot + 1000)
    var out = [Channel.Outgoing(channel: one.a.raw, bytes: [1, 2, 3], handles: [try counter.duplicate().release()]),
               Channel.Outgoing(channel: two.a.raw, bytes: big),
               Channel.Outgoing(channel: 0x7fff_fff0, bytes: [4], handles: [lost])]
    check(try Channel.write(&out) == 2, "a write array: two of three")
    check(out[0].status == .ok && out[1].status == .ok && out[2].status == .badHandle, "each item's status")
    check(statusOf { () throws(Status) in try Handle(raw: lost).info() } == .badHandle,
          "a failed item's handles are consumed")

    var reads = [Channel.Incoming(channel: one.b.raw), Channel.Incoming(channel: two.b.raw),
                 Channel.Incoming(channel: three.b.raw)]
    check(try Channel.read(&reads) == 2, "a read array: two of three")
    check(reads[0].message?.bytes == [1, 2, 3] && reads[0].message?.handles.count == 1, "a message and its handle")
    if let h = reads[0].message?.handles.first {
      let moved = Handle(raw: h)
      check((try moved.info().koid) == (try counter.info().koid), "the handle is the same object")
    }
    check(reads[1].message?.bytes == big, "a message larger than the slot, read again")
    check(reads[2].status == .shouldWait && reads[2].message == nil, "an empty channel's item")

    // More than CROI_CHANNEL_MAX_ITEMS, all to one channel: in order.
    let count = Int(CROI_CHANNEL_MAX_ITEMS) + 6
    var many = (0..<count).map { Channel.Outgoing(channel: three.a.raw, bytes: [UInt8($0)]) }
    check(try Channel.write(&many) == count, "a write array longer than one call")
    var back = (0..<count).map { _ in Channel.Incoming(channel: three.b.raw) }
    check(try Channel.read(&back) == count, "a read array longer than one call")
    check(back.indices.allSatisfy { back[$0].message?.bytes == [UInt8($0)] }, "in order")
    var drained = [Channel.Incoming(channel: three.b.raw)]
    _ = try Channel.read(&drained)
    check(drained[0].status == .shouldWait, "drained")

    let pair = try Channel.create()
    let writer = pair.a, reader = pair.b
    _ = consume writer
    var closed = [Channel.Incoming(channel: reader.raw)]
    _ = try Channel.read(&closed)
    check(closed[0].status == .peerClosed, "an empty channel whose peer is gone")
    _ = consume one
    _ = consume two
  }

  static func bindings() throws(Status) {
    let port = try Port.create()
    let c = try Counter.create()
    try c.bind(port: port, key: 42, signals: Signals.positive)
    check(statusOf { () throws(Status) in try Port.wait(port, deadline: 0) } == .timedOut, "nothing yet")
    try Counter.add(c, 1)
    let p = try Port.wait(port, deadline: 0)
    check(p.key == 42 && p.type == CROI_PKT_TYPE_SIGNAL && p.trigger == Signals.positive, "a ONCE binding's packet")
    try Counter.add(c, -1)
    try Counter.add(c, 1)
    check(statusOf { () throws(Status) in try Port.wait(port, deadline: 0) } == .timedOut, "only once")

    let ends = try Channel.create()
    try ends.b.bind(port: port, key: 7, signals: Signals.readable, persistent: true)
    // READABLE rises at the first message, not at the others (its reader
    // drains): one packet; drained, the next message brings another.
    for n in UInt8(1)...3 { try Channel.write(ends.a, bytes: [n]) }
    let first = try Port.wait(port, deadline: 0)
    check(first.key == 7 && first.payload.1 == 1, "a persistent binding's packet")
    check(statusOf { () throws(Status) in try Port.wait(port, deadline: 0) } == .timedOut, "once for the messages")
    for _ in 0..<3 { _ = try Channel.read(ends.b) }
    check(statusOf { () throws(Status) in try Port.wait(port, deadline: 0) } == .timedOut, "none at the reads")
    try Channel.write(ends.a, bytes: [4])
    check(try Port.wait(port, deadline: 0).key == 7, "and again once drained")
    try Port.cancel(port, source: ends.b, key: 7)
    check(statusOf { () throws(Status) in try Port.cancel(port, source: ends.b, key: 7) } == .notFound,
          "cancelled by source")

    var items = [Binding.signals(c.raw, Signals.nonPositive, key: 1), Binding.value(c.raw, 3, key: 2),
                 Binding.signals(0x7FFF_FFF0, Signals.positive, key: 3), Binding.signals(c.raw, 0, key: 4)]
    check(try Port.bind(port, &items) == 2, "an array binds up to the first failure")
    check(items[2].status == Status.badHandle.rawValue, "whose status is written back")
    try Counter.add(c, 2)
    check(try Port.wait(port, deadline: 0).key == 2, "a VALUE binding's packet")
    try Port.cancel(port, key: 1)
    check(statusOf { () throws(Status) in try Port.cancel(port, key: 1) } == .notFound, "cancelled by key")

    check(try Port.queue(port, [Packet(key: 10), Packet(key: 11), Packet(key: 12)]) == 3, "packets queued at once")
    let three = try Port.wait(port, deadline: 0, max: 8)
    check(three.count == 3 && three[0].key == 10 && three[2].key == 12, "and taken at once")
  }

  static func waits() throws(Status) {
    let c = try Counter.create()
    let start = Clock.monotonic()
    check(statusOf { () throws(Status) in try c.wait(for: Signals.positive, deadline: start + 2 * millisecond) }
            == .timedOut, "a wait times out")
    check(Clock.monotonic() >= start + 2 * millisecond, "at its deadline")
    let raw = c.raw
    let adder = try Thread.spawn {
      let borrowed = Handle(raw: raw)
      sleep(until: Clock.monotonic() + 2 * millisecond)
      try? Counter.add(borrowed, 5)
      _ = borrowed.release()
    }
    check(try c.wait(for: Signals.positive, deadline: soon()) & Signals.positive != 0, "a wait sees the event")
    try Counter.wait(c, until: 5, deadline: soon())
    check(true, "a counter's wait for a value")
    try Thread.join(adder)
    let before = Clock.monotonic()
    sleep(until: before + 2 * millisecond)
    check(Clock.monotonic() >= before + 2 * millisecond, "a sleep reaches its deadline")
  }

  static func mappings() throws(Status) {
    let vmo = try VMO.create(size: 5000)
    check(try VMO.size(vmo) == 8192, "a VMO's size, in pages")
    let shared = try vmo.duplicate()
    do {
      let a = try VMO.map(vmo, length: 8192)
      let b = try VMO.map(shared, offset: 4096, length: 4096)
      a.write([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], at: 4090)
      check(a.read(at: 4090, count: 10) == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10], "a mapping's bytes")
      check(b.load(UInt8.self, at: 0) == 7, "seen through another")
    }
    let readOnly = try vmo.duplicate([.read, .map])
    check(statusOf { () throws(Status) in try VMO.map(readOnly, length: 4096, writable: true) } == .accessDenied,
          "no writable mapping without WRITE")
  }

  final class Box: @unchecked Sendable {
    var count = 0
    var inside = 0
    var worst = 0
  }

  static func threads() throws(Status) {
    let process = try Process.current()
    let box = Box(), lock = Lock()
    var running: [UInt32] = []
    for _ in 0..<4 {
      running.append(try Thread.spawn {
        for _ in 0..<500 {
          lock.lock()
          box.inside += 1
          box.worst = max(box.worst, box.inside)
          box.count += 1
          box.inside -= 1
          lock.unlock()
        }
      }.release())
    }
    for raw in running { try Thread.join(Handle(raw: raw)) }
    check(box.count == 2000 && box.worst == 1, "a lock excludes")

    // Threads unmap their own stacks: many come and go, and the mapping
    // stays as it was.
    let mapped = try Process.stats(process).mapped
    for _ in 0..<32 {
      let t = try Thread.spawn { box.count += 1 }
      try Thread.join(t)
    }
    let exited = try Thread.spawn {
      box.count += 1
      Thread.exit()
    }
    try Thread.join(exited)
    check(try Process.stats(process).mapped == mapped, "threads' stacks are reclaimed")

    let blocked = try Thread.spawn { sleep(until: Clock.monotonic() + 200 * millisecond) }
    sleep(until: Clock.monotonic() + 20 * millisecond)
    check(same(try Thread.state(blocked).text, "blocked: port"), "a sleeping thread waits on its port")
    try Thread.join(blocked)
  }

  static func futexes() throws(Status) {
    let word = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
    defer { unsafe word.deallocate() }
    unsafe word.pointee = 0
    check(statusOf { () throws(Status) in try unsafe Futex.wait(word, current: 2) } == .badState,
          "a futex wait checks the word")
    let start = Clock.monotonic()
    check(statusOf { () throws(Status) in try unsafe Futex.wait(word, current: 0, deadline: start + 2 * millisecond) }
            == .timedOut, "and times out")
    let address = unsafe UInt(bitPattern: word)
    let waker = try Thread.spawn {
      sleep(until: Clock.monotonic() + 2 * millisecond)
      unsafe Futex.wake(UnsafeMutablePointer<UInt32>(bitPattern: address)!, count: 1)
    }
    check(statusOf { () throws(Status) in try unsafe Futex.wait(word, current: 0, deadline: soon()) } == .ok,
          "or is woken")
    try Thread.join(waker)
  }

  static func counters() throws(Status) {
    let c = try Counter.create(), d = try Counter.create()
    var items = [CounterAdd(counter: c.raw, status: 0, amount: 1), CounterAdd(counter: 0x7FFF_FFF0, status: 0, amount: 1),
                 CounterAdd(counter: d.raw, status: 0, amount: Int64.max), CounterAdd(counter: d.raw, status: 0, amount: 1)]
    check(try Counter.add(&items) == 2, "adds go on past a failure")
    check(items[1].status == Status.badHandle.rawValue && items[3].status == Status.outOfRange.rawValue,
          "each one's status")
    let cValue = try Counter.read(c), dValue = try Counter.read(d)
    check(cValue == 1 && dValue == Int64.max, "and the values")
    let port = try Port.create()
    try Port.bind(port, Binding.changes(c.raw, key: 4))
    try Counter.add(c, 1)
    try Counter.add(c, 1)
    let p = try Port.wait(port, deadline: 0)
    check(p.type == Counter.changePacketType && p.payload.1 == 3 && p.payload.2 == 2, "a doorbell coalesces")
  }

  static func tasks() throws(Status) {
    let me = try Process.current().info()
    check(me.type == ObjectType.process, "the current process")
    guard let raw = StartupHandles.take(HandleType.info(HandleType.jobDefault)) else {
      return check(false, "a default job")
    }
    let root = Handle(raw: raw)
    let job = try Job.create(parent: root)
    let process = try Process.create(job: job, name: "child")
    check(same(try process.name(), "child"), "a process made, named")
    let processes = try Job.processes(job), child = try process.info().koid
    check(processes == [child], "the job's processes")
    try startChild(job)
    try kill(job)
    check(try job.wait(for: Signals.terminated, deadline: soon()) & Signals.terminated != 0, "a job killed")
  }

  /// Starts bin/sys-test from bootfs again, as a child given arguments,
  /// an environment, a name and a channel: what it reports of its Startup,
  /// and its exit code.
  static func startChild(_ job: borrowing Handle) throws(Status) {
    guard let raw = StartupHandles.take(HandleType.info(HandleType.vmoBootfs)) else {
      return check(false, "bootfs, to start a child from")
    }
    let bootfs = Handle(raw: raw)
    let programs = try ProgramEntry.bootfs(bootfs)
    guard let me = programs.first(where: { same($0.name, "bin/sys-test") }) else {
      return check(false, "bin/sys-test in bootfs")
    }
    check(programs.contains { same($0.name, "bin/ipc-test") }, "bootfs's files listed")
    let process = try Process.create(job: job, name: "sys-test-child")
    let ends = try Channel.create()
    let startup = Startup(args: ["sys-test", "child"], environment: ["SYS_TEST=child"], names: ["/svc"])
    startup.add(ends.b, info: HandleType.info(HandleType.user0))
    let thread = try Process.start(process, entry: me, startup)
    _ = try process.wait(for: Signals.terminated, deadline: soon(5000))
    check(try Process.info(process).returnCode == 7, "a child loaded from bootfs ran and exited with its code")
    let report = try? Channel.read(ends.a)
    check(report?.bytes == [1, 1, 1, 1], "it was given its arguments, environment, names and handles")
    check(statusOf { () throws(Status) in try Process.start(process, entry: me, Startup()) } == .badState,
          "a process starts once")
    try stdio(job, me)
    _ = consume thread
    _ = consume bootfs
  }

  /// The child's part: reports what its Startup holds, and exits with 7.
  static func childMain() -> Never {
    let startup = Startup.current
    let args = startup.args
    let argsOK: UInt8 = args.count == 2 && same(args[1], "child") ? 1 : 0
    let envOK: UInt8 = startup.value("SYS_TEST").map { same($0, "child") } ?? false ? 1 : 0
    let namesOK: UInt8 = startup.names.count == 1 && same(startup.names[0], "/svc") ? 1 : 0
    guard let report = startup.take(HandleType.info(HandleType.user0)) else { Process.exit(code: 1) }
    let handlesOK: UInt8 = startup.infos.isEmpty ? 1 : 0  // the floor took its own
    try? Channel.write(report, bytes: [argsOK, envOK, namesOK, handlesOK])
    Process.exit(code: 7)
  }

  /// The child's stdio on rings (D46): what it reads from its stdin comes
  /// back on its stdout after a line saying how much, then the end; a
  /// child whose parent closes its stdio sees its stdin end.
  static func stdio(_ job: borrowing Handle, _ me: ProgramEntry) throws(Status) {
    var pattern = [UInt8](repeating: 0, count: 20_000)
    for i in pattern.indices { pattern[i] = UInt8(truncatingIfNeeded: i &* 7 &+ i >> 8) }
    let process = try Process.create(job: job, name: "sys-test-stdio")
    let startup = Startup(args: ["sys-test", "stdio"])
    let stdio = try ChildStdio(for: startup)
    let thread = try Process.start(process, entry: me, startup)
    try stdio.write(pattern, deadline: soon(5000))
    try stdio.closeInput(deadline: soon(5000))
    let out = try stdio.readAll(deadline: soon(5000))
    _ = try process.wait(for: Signals.terminated, deadline: soon(5000))
    var expected = Array("got 20000 bytes\n".utf8)
    expected += pattern
    check(out == expected, "a child's stdin and stdout on rings, ended")
    check(try Process.info(process).returnCode == 5, "and it ran to its end")
    _ = consume thread

    let hung = try Process.create(job: job, name: "sys-test-hangup")
    let other = Startup(args: ["sys-test", "hangup"])
    var dropped: ChildStdio? = try ChildStdio(for: other)
    let thread2 = try Process.start(hung, entry: me, other)
    dropped = nil  // its parent's side gone: the child's stdin ends
    _ = try hung.wait(for: Signals.terminated, deadline: soon(5000))
    check(try Process.info(hung).returnCode == 6 && dropped == nil, "a child sees its parent go as its stdin's end")
    _ = consume thread2

    // A ring per descriptor: stderr on fd 2's, and fds 3 (written) and 4
    // (read) beside stdin and stdout.
    let many = try Process.create(job: job, name: "sys-test-descriptors")
    let third = Startup(args: ["sys-test", "descriptors"])
    let fds = try ChildStdio(for: third, descriptors: [(0, true), (1, false), (2, false), (3, false), (4, true)])
    let thread3 = try Process.start(many, entry: me, third)
    try fds.stream(4)!.write(Array("four".utf8), deadline: soon(5000))
    try fds.stream(4)!.closeInput(deadline: soon(5000))
    try fds.closeInput(deadline: soon(5000))
    let three = try fds.stream(3)!.readAll(deadline: soon(5000))
    let err = try fds.stream(2)!.readAll(deadline: soon(5000))
    let printed = try fds.readAll(deadline: soon(5000))
    _ = try many.wait(for: Signals.terminated, deadline: soon(5000))
    check(printed == Array("out\n".utf8) && err == Array("err\n".utf8), "stderr on a ring of its own")
    check(three == Array("three four".utf8), "a child's fds 3 and 4 on rings, each ended")
    check(try Process.info(many).returnCode == 8, "and that child ran to its end")
    _ = consume thread3

    // A descriptor's child side handed over and attached in Swift (a
    // pty's terminal end), each way.
    var reader: AttachedStream? = nil, writer: AttachedStream? = nil
    let to = try ChildStream(childReads: true) { (p: consuming StreamParts) in reader = try? AttachedStream(p) }
    let from = try ChildStream(childReads: false) { (p: consuming StreamParts) in writer = try? AttachedStream(p) }
    try to.write(Array("keys".utf8), deadline: soon(5000))
    try to.closeInput(deadline: soon(5000))
    let keys = try reader?.read(deadline: soon(5000)) ?? []
    let keysEnd = try reader?.read(deadline: soon(5000))
    try writer?.write(Array("shown".utf8), deadline: soon(5000))
    try writer?.end(deadline: soon(5000))
    let shown = try from.readAll(deadline: soon(5000))
    check(keys == Array("keys".utf8) && keysEnd == [] && shown == Array("shown".utf8),
          "a descriptor's parts attached in Swift, each way, ended")
  }

  /// A descriptors child: stdout, stderr, and fd 3 saying what fd 4 held.
  static func descriptorsChild() -> Never {
    print("out")
    let err = Array("err\n".utf8)
    unsafe err.withUnsafeBytes { unsafe td_stderr_write($0.baseAddress!, $0.count) }
    var reads = false
    guard unsafe td_stdio_has(4, &reads), reads, unsafe td_stdio_has(3, &reads), !reads else { Process.exit(code: 1) }
    var four: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 100)
    while true {
      let n = unsafe buffer.withUnsafeMutableBytes { unsafe td_stdio_read_fd(4, $0.baseAddress!, UInt64($0.count)) }
      if n <= 0 { break }
      four += buffer[..<Int(n)]
    }
    let three = Array("three ".utf8) + four
    _ = unsafe three.withUnsafeBytes { unsafe td_stdio_write_fd(3, $0.baseAddress!, UInt64($0.count)) }
    Process.exit(code: 8)
  }

  /// A stdio child: echoes its stdin after saying how much there was.
  static func stdioChild() -> Never {
    let all = readStdin()
    print("got \(all.count) bytes")
    unsafe all.withUnsafeBytes { unsafe td_stdout_write($0.baseAddress!, $0.count) }
    Process.exit(code: 5)
  }

  /// A stdio child whose parent goes: reads stdin to its end, exits 6.
  static func hangupChild() -> Never {
    _ = readStdin()
    Process.exit(code: 6)
  }

  static func readStdin() -> [UInt8] {
    var all: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 1000)
    while true {
      let n = unsafe buffer.withUnsafeMutableBytes { unsafe td_stdin_read($0.baseAddress!, $0.count) }
      if n <= 0 { return all }
      all += buffer[..<n]
    }
  }

  static func random() throws(Status) {
    let a = try CPRNG.draw(count: 1000), b = try CPRNG.draw(count: 1000)
    check(a.count == 1000 && a != b, "the CPRNG fills what is asked for")
  }
}
