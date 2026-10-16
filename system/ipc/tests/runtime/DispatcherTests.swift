// SPDX-License-Identifier: BSD-3-Clause

// The dispatcher over SysHost (natively: bin/ipc-test): channels bound
// once, PERSISTENT, read and answered in arrays, from one thread.

@testable import Echo
@testable import IPC
import Synchronization
import Testing

/// Waits until `done`, or two seconds; whether it was done.
func eventually(_ done: () -> Bool) -> Bool {
  let deadline = Clock.monotonic() + 2_000_000_000
  while !done() {
    if Clock.monotonic() > deadline { return false }
    sleep(until: Clock.monotonic() + 1_000_000)
  }
  return true
}

final class Seen: Sendable {
  let value = Atomic<Int64>(0)
}

@Test func aDispatcherServesChannelsAndWatchesFromOneThread() throws {
  let d = try IPCDispatcher()
  var clients: [UInt32] = []
  var ids: [UInt64] = []
  for _ in 0..<3 {
    let ends = try Channel.create()
    ids.append(try d.add(TestIPC.EchoServer(channel: ends.b, impl: EchoImpl())) {
      (s: inout TestIPC.EchoServer<EchoImpl>) throws(IPCError<Never>) in try s.sendTicked(9, label: "woken")
    })
    clients.append(ends.a.release())
  }
  let counter = try Counter.create()
  let seen = Seen()
  let mine = try counter.duplicate().release()
  let watch = try d.watch(try counter.duplicate(), signals: Signals.positive) { _ in
    let held = Handle(raw: mine)
    if let n = try? Counter.read(held), n > 0 {
      try? Counter.add(held, -n)
      seen.value.add(n, ordering: .relaxed)
    }
    _ = held.release()
    return true
  }
  #expect(d.count == 4)
  let thread = try Thread.spawn { try? d.run() }

  var a = TestIPC.EchoClient(channel: Handle(raw: clients[0]))
  var b = TestIPC.EchoClient(channel: Handle(raw: clients[1]))
  var c = TestIPC.EchoClient(channel: Handle(raw: clients[2]))
  #expect(try a.say("x", times: 2) == "xx" && b.say("y", times: 1) == "y" && c.say("z", times: 3) == "zzz")

  d.wake(ids[1])
  guard case .ticked(let n, let label) = try b.nextEvent(deadline: Clock.monotonic() + 2_000_000_000) else {
    Issue.record("expected the woken event")
    return
  }
  #expect(n == 9 && label == "woken")

  // Forty one-way requests under one coalesced packet, drained.
  for n in UInt64(1)...40 { try c.note(n, loud: false) }
  #expect(try c.noted() == 820)

  try Counter.add(counter, 3)
  #expect(eventually { seen.value.load(ordering: .relaxed) == 3 })
  try Counter.add(counter, 4)
  #expect(eventually { seen.value.load(ordering: .relaxed) == 7 })

  _ = consume a
  #expect(eventually { d.count == 3 })
  d.unwatch(watch)
  #expect(eventually { d.count == 2 })
  try Counter.add(counter, 5)
  sleep(until: Clock.monotonic() + 20_000_000)
  #expect(seen.value.load(ordering: .relaxed) == 7)

  d.stop()
  try Thread.join(thread)
  d.removeAll()
  #expect(d.count == 0)
  var status: Status?
  do throws(IPCError<Never>) {
    _ = try b.noted()
  } catch {
    if case .transport(let s) = error { status = s }
  }
  #expect(status == .peerClosed)
  _ = consume c
  Sys.close(raw: mine)
}
