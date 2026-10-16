// SPDX-License-Identifier: BSD-3-Clause

// bin/ipc-test: IPC over the kernel (V2), what IPCTests and IDLTests check
// hosted, natively: Echo's calls, errors, events and handles between a
// Swift client and a server on a thread of its own, composition (Loud),
// the C client (td_wire.h and idlc's test_ipc.h, idl_c_tests.c) against a
// Swift server, and the dispatcher serving several channels and a watched
// counter from one thread. userboot starts it (userboot.next=bin/ipc-test,
// the boot-ipc test); it exits 0 if every check passed.

import LibSys
import IPC
import Synchronization

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func check(_ condition: Bool, _ name: StaticString) {
  checks += 1
  if !condition {
    failures += 1
    print("ipc-test: FAILED: \(name)")
  }
}

/// M0's exit test, the C client (idl_c_tests.h): 0, or its failed check's line.
@_extern(c, "idl_c_echo_client") func idlCEchoClient(_ channel: UInt32) -> Int32

let millisecond: Int64 = 1_000_000
func soon(_ ms: Int64 = 2000) -> Int64 { Clock.monotonic() + ms * millisecond }

/// A String's bytes are `text`'s (String's `==` normalizes, which needs
/// Unicode tables only amd64's Embedded toolchain has).
func same(_ string: String, _ text: StaticString) -> Bool {
  unsafe Array(string.utf8) == Array(UnsafeBufferPointer(start: text.utf8Start, count: text.utf8CodeUnitCount))
}
func same(_ string: String?, _ text: StaticString) -> Bool { string.map { same($0, text) } ?? false }

/// How a server thread ended: 1 served until its client went, -1 failed.
final class Outcome: Sendable {
  let state = Atomic<Int>(0)
  func finish(_ ok: Bool) { state.store(ok ? 1 : -1, ordering: .releasing) }
  var ok: Bool { state.load(ordering: .acquiring) == 1 }
}

/// A handle an escaping closure can capture (Embedded Swift captures no
/// ~Copyable value with a deinit).
final class Held: Sendable {
  let handle: Handle
  init(_ handle: consuming Handle) { self.handle = handle }
}

/// A count an escaping closure can capture.
final class Tally: Sendable {
  let value = Atomic<Int64>(0)
}

/// A server on a thread of its own, and its outcome.
struct Served: ~Copyable {
  let thread: Handle
  let outcome: Outcome

  /// Whether the server ended well (its client must have closed).
  consuming func finished() -> Bool {
    let ended = (try? Thread.join(thread)) != nil
    return ended && outcome.ok
  }
}

/// Serves Echo on `raw` after sending one event, as Echo.swift's hosted
/// `startServer` does.
func startEcho(_ raw: UInt32) throws(Status) -> Served {
  let outcome = Outcome()
  let thread = try Thread.spawn {
    var server = TestIPC.EchoServer(channel: Handle(raw: raw), impl: EchoImpl())
    do throws(IPCError<Never>) {
      try server.sendTicked(7, label: "first")
      try server.serve()
      outcome.finish(true)
    } catch {
      outcome.finish(false)
    }
  }
  return Served(thread: thread, outcome: outcome)
}

/// Serves Loud on `raw` after one event of Echo's and one of its own.
func startLoud(_ raw: UInt32) throws(Status) -> Served {
  let outcome = Outcome()
  let thread = try Thread.spawn {
    var server = TestIPC.LoudServer(channel: Handle(raw: raw), impl: LoudImpl())
    do throws(IPCError<Never>) {
      try TestIPC.EchoEventSender.sendTicked(1, label: "composed", on: server.connection)
      try server.sendShouted("hey")
      try server.serve()
      outcome.finish(true)
    } catch {
      outcome.finish(false)
    }
  }
  return Served(thread: thread, outcome: outcome)
}

/// The transport status `body` threw, if it threw one.
func transportStatus<R: ~Copyable, E: IPCErrorCode>(_ body: () throws(IPCError<E>) -> R) -> Status? {
  do throws(IPCError<E>) {
    _ = try body()
    return nil
  } catch {
    if case .transport(let s) = error { return s }
    return nil
  }
}

@main
struct IPCTest {
  static func main() {
    do throws(Status) {
      try echo()
      try structs()
      try composition()
      try cClient()
      try dispatcher()
    } catch {
      print("ipc-test: FAILED: a call threw \(error.rawValue)")
      failures += 1
    }
    print("ipc-test: \(checks - failures) of \(checks) checks passed")
    Process.exit(code: failures == 0 ? 0 : 1)
  }

  /// Calls, an error reply, one-way requests, an event queued behind a
  /// reply, a handle there and back, and an unknown method.
  static func echo() throws(Status) {
    let ends = try Channel.create()
    let server = try startEcho(ends.b.release())
    var client = TestIPC.EchoClient(channel: ends.a)

    check(same(try? client.say("hi", times: 3), "hihihi"), "echo: say")
    var remote: EchoError?
    do throws(IPCError<EchoError>) {
      _ = try client.say("long", times: 100)
    } catch {
      if case .remote(let e) = error { remote = e }
    }
    check(remote == .tooLong, "echo: the method's own error")
    check((try? client.note(5, loud: false)) != nil && (try? client.note(5, loud: true)) != nil, "echo: one-way")
    check((try? client.noted()) == 15, "echo: one-way requests were served in order")

    // The event was sent before the first reply, and stayed queued.
    if case .ticked(let n, let label)? = try? client.nextEvent(deadline: soon()) {
      check(n == 7 && same(label, "first"), "echo: the event")
    } else {
      check(false, "echo: the event")
    }

    // The handle goes and comes back: the same counter, as its value shows.
    let sent = try Counter.create()
    try Counter.add(sent, 7)
    if let back = try? client.swap(sent) {
      check((try? Counter.read(back)) == 7, "echo: a handle there and back")
    } else {
      check(false, "echo: a handle there and back")
    }

    let unknown = try? IPCCodec.encode(MessageHeader(txid: 0, kind: .request, ordinal: 0x1234), inlineSize: 0,
                                       Never.self)
    if let unknown {
      let status = transportStatus { () throws(IPCError<Never>) in
        try client.connection.call(unknown, Never.self, trace: TestIPC._trace_Echo_say)
      }
      check(status == .notSupported, "echo: an unknown method")
    }

    _ = consume client
    check(server.finished(), "echo: the server ends when its client goes")
  }

  /// Structs, enums, optionals, vectors, and structs that carry handles.
  static func structs() throws(Status) {
    let ends = try Channel.create()
    let server = try startEcho(ends.b.release())
    var client = TestIPC.EchoClient(channel: ends.a)
    _ = try? client.nextEvent(deadline: soon())

    let sample = TestIPC.Shaped(
      shape: .triangle, at: TestIPC.Point(x: -3, y: 4), label: "tri", tags: ["a", "", "ccc"],
      path: [TestIPC.Point(x: 1, y: 2), TestIPC.Point(x: Int32.min, y: Int32.max)], weight: 513,
      data: [0, 255, 7], flag: true)
    if let s = try? client.reflect(sample) {
      check(s.shape == .triangle && s.at == sample.at && same(s.label, "tri") && s.tags.count == 3
              && same(s.tags[2], "ccc") && s.tags[1].utf8.isEmpty && s.path == sample.path && s.weight == 513
              && s.data == [0, 255, 7] && s.flag, "structs: reflect")
    } else {
      check(false, "structs: reflect")
    }

    let many = try? client.many([sample], nested: [[1, 2, 3], [], [10]], maybe: [TestIPC.Point(x: 9, y: 9)])
    check(many?.count == 5 && many?[1].weight == 6 && many?[2].weight == 0 && many?[3].weight == 10
            && many?[4].path == [TestIPC.Point(x: 9, y: 9)] && same(many?[4].label, "maybe"), "structs: many")
    check((try? client.many([], nested: [], maybe: nil))?.isEmpty == true, "structs: many, empty")

    let present = try Counter.create()
    do throws(IPCError<Never>) {
      let returned = try client.optionals("t", bytes: [], point: TestIPC.Point(x: 1, y: 1), handle: present)
      let came = returned != nil
      check(came, "structs: an optional handle comes back")
      let none = try client.optionals(nil, bytes: [1], point: nil, handle: nil)
      let absent = none == nil
      check(absent, "structs: absent optionals")
    } catch {
      check(false, "structs: optionals")
    }

    // A struct with two handles: they come back swapped.
    let a = try Counter.create(), b = try Counter.create()
    let aKoid = try a.info().koid, bKoid = try b.info().koid
    if let carried = try? client.carry(TestIPC.Carried(name: "box", handle: a, spare: b, inner: sample)) {
      let handleKoid = try carried.handle.info().koid, spareKoid = try carried.spare?.info().koid
      check(same(carried.name, "box!") && carried.inner?.weight == 513 && handleKoid == bKoid && spareKoid == aKoid, "structs: carry swaps the handles")
    } else {
      check(false, "structs: carry swaps the handles")
    }

    _ = consume client
    check(server.finished(), "structs: the server ends")
  }

  /// Loud composes Echo: Echo's methods and events on Loud's client, and
  /// an Echo client on a Loud channel.
  static func composition() throws(Status) {
    let ends = try Channel.create()
    let server = try startLoud(ends.b.release())
    var loud = TestIPC.LoudClient(channel: ends.a)
    if case .echo(.ticked(let n, let label))? = try? loud.nextEvent(deadline: soon()) {
      check(n == 1 && same(label, "composed"), "compose: Echo's event, wrapped")
    } else {
      check(false, "compose: Echo's event, wrapped")
    }
    if case .shouted(let text)? = try? loud.nextEvent(deadline: soon()) {
      check(same(text, "hey"), "compose: Loud's own event")
    } else {
      check(false, "compose: Loud's own event")
    }
    check(same(try? loud.shout("quiet"), "QUIET"), "compose: Loud's method")
    check(same(try? loud.say("ab", times: 2), "abab"), "compose: Echo's method on Loud's client")
    var echo = TestIPC.EchoClient(connection: loud.takeConnection())
    check(same(try? echo.say("x", times: 3), "xxx"), "compose: an Echo client on a Loud channel")
    _ = consume echo
    check(server.finished(), "compose: the server ends")

    // An Echo server refuses Loud's own methods.
    let other = try Channel.create()
    let echoServer = try startEcho(other.b.release())
    var refused = TestIPC.LoudClient(connection: TestIPC.EchoClient(channel: other.a).takeConnection())
    check(transportStatus { () throws(IPCError<Never>) in try refused.shout("no") } == .notSupported,
          "compose: an Echo server refuses Loud's methods")
    check(same(try? refused.say("y", times: 1), "y"), "compose: and serves Echo's")
    _ = consume refused
    check(echoServer.finished(), "compose: the Echo server ends")
  }

  /// The C client, over td_wire_call (one channel_call each), against the
  /// Swift server.
  static func cClient() throws(Status) {
    let ends = try Channel.create()
    let server = try startEcho(ends.b.release())
    let line = idlCEchoClient(ends.a.release())
    if line != 0 { print("ipc-test: the C client failed at idl_c_tests.c:\(line)") }
    check(line == 0, "c: the C client's calls")
    check(server.finished(), "c: the server ends when the C client closes")
  }


  /// An Echo server added to `d`, and its client.
  struct Dispatched: ~Copyable {
    let id: UInt64
    var client: TestIPC.EchoClient
  }

  static func dispatched(_ d: IPCDispatcher) throws(Status) -> Dispatched {
    let ends = try Channel.create()
    let id = try d.add(TestIPC.EchoServer(channel: ends.b, impl: EchoImpl())) {
      (s: inout TestIPC.EchoServer<EchoImpl>) throws(IPCError<Never>) in try s.sendTicked(9, label: "woken")
    }
    return Dispatched(id: id, client: TestIPC.EchoClient(channel: ends.a))
  }

  /// Whether `client`'s say comes back `times` long.
  static func says(_ client: inout TestIPC.EchoClient, _ times: Int) -> Bool {
    (try? client.say("d", times: UInt32(times)))?.utf8.count == times
  }

  /// Waits until `done`, or two seconds; whether it was done.
  static func eventually(_ done: () -> Bool) -> Bool {
    let deadline = soon()
    while !done() {
      if Clock.monotonic() > deadline { return false }
      sleep(until: soon(1))
    }
    return true
  }

  /// One dispatcher thread serves three channels and watches a counter;
  /// `wake` runs a server's wake on that thread; a client that goes takes
  /// its server with it.
  static func dispatcher() throws(Status) {
    let d = try IPCDispatcher()
    var a = try dispatched(d), b = try dispatched(d), c = try dispatched(d)

    let counter = try Counter.create()
    let seen = Tally()
    let mine = Held(try counter.duplicate())
    let watchID = try d.watch(try counter.duplicate(), signals: Signals.positive) { (_: UInt32) -> Bool in
      // Take what was added, so the counter is no longer positive.
      if let n = try? Counter.read(mine.handle), n > 0 {
        try? Counter.add(mine.handle, -n)
        seen.value.add(n, ordering: .relaxed)
      }
      return true
    }
    check(d.count == 4, "dispatcher: three servers and a watch")
    let outcome = Outcome()
    let thread = try Thread.spawn {
      outcome.finish((try? d.run()) != nil)
    }

    var calls = 0
    for times in 1...4 {
      if says(&a.client, times) { calls += 1 }
      if says(&b.client, times) { calls += 1 }
      if says(&c.client, times) { calls += 1 }
    }
    check(calls == 12, "dispatcher: calls on three channels")

    d.wake(b.id)
    if case .ticked(let n, _)? = try? b.client.nextEvent(deadline: soon()) {
      check(n == 9, "dispatcher: a wake runs on the dispatcher's thread")
    } else {
      check(false, "dispatcher: a wake runs on the dispatcher's thread")
    }

    // The binding is PERSISTENT: each rise is a packet, with no re-arming.
    try Counter.add(counter, 3)
    check(eventually { seen.value.load(ordering: .relaxed) == 3 }, "dispatcher: a watched counter")
    try Counter.add(counter, 4)
    check(eventually { seen.value.load(ordering: .relaxed) == 7 }, "dispatcher: watched again")

    // Requests queued faster than they are served: one packet, coalesced,
    // and the dispatcher reads until the channel would block.
    var sent = true
    for n in 1...40 as ClosedRange<UInt64> where (try? c.client.note(n, loud: false)) == nil { sent = false }
    check(sent && (try? c.client.noted()) == 820, "dispatcher: forty one-way requests, drained")

    // More servers than one wakeup takes packets for: a one-way request
    // to each, as fast as they go, then a call to each.
    var many: [UInt32] = []
    for _ in 0..<(Int(CROI_CHANNEL_MAX_ITEMS) + 6) {
      let ends = try Channel.create()
      try d.add(TestIPC.EchoServer(channel: ends.b, impl: EchoImpl()))
      many.append(ends.a.release())
    }
    for (i, raw) in many.enumerated() {
      var client = TestIPC.EchoClient(channel: Handle(raw: raw))
      try? client.note(UInt64(i), loud: true)
      _ = client.takeConnection().takeChannel().release()
    }
    var replied = 0
    for (i, raw) in many.enumerated() {
      var client = TestIPC.EchoClient(channel: Handle(raw: raw))
      if (try? client.noted()) == UInt64(2 * i) { replied += 1 }
    }
    check(replied == many.count, "dispatcher: seventy servers, each answers")
    check(eventually { d.count == 4 }, "dispatcher: their servers go with their clients")

    // A client that goes takes its server with it; the others stay.
    _ = consume a
    check(eventually { d.count == 3 }, "dispatcher: a closed channel's server is dropped")
    check((try? c.client.noted()) == 820, "dispatcher: the others still serve")

    // An unwatched counter calls its handler no more.
    d.unwatch(watchID)
    check(eventually { d.count == 2 }, "dispatcher: unwatch drops the watch")
    try Counter.add(counter, 5)
    sleep(until: soon(20))
    check(seen.value.load(ordering: .relaxed) == 7, "dispatcher: and its handler")

    d.stop()
    let joined = (try? Thread.join(thread)) != nil
    check(joined && outcome.ok, "dispatcher: stop ends run")
    d.removeAll()
    check(d.count == 0, "dispatcher: removeAll drops the rest")
    // Their servers are gone, so their clients see the channel close.
    check(transportStatus { () throws(IPCError<Never>) in try b.client.noted() } == .peerClosed,
          "dispatcher: removeAll closes the channels")
    _ = consume c
  }
}
