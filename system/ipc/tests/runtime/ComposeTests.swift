// SPDX-License-Identifier: BSD-3-Clause

// Composition (FIDL's `compose`): Loud composes Echo, so Echo's methods are
// Loud's, with Echo's ordinals. In one library the client has them all;
// its events include Echo's, and an Echo client works on a Loud channel,
// though Loud's own events are nothing it knows. (A protocol of another
// library is lent the connection instead: tests/fs.)

@testable import Echo
import IPC
import Testing

@Test func aComposedProtocolServesItsPartsMethods() async throws {
  let ends = try Channel.create()
  let server = startLoudServer(ends.b.release())
  do {
    var loud = TestIPC.LoudClient(channel: ends.a)
    // Events: Echo's, wrapped, then Loud's own.
    guard case .echo(.ticked(let n, let label)) = try loud.nextEvent() else {
      Issue.record("expected Echo's event")
      return
    }
    #expect(n == 1 && label == "composed")
    guard case .shouted(let text) = try loud.nextEvent() else {
      Issue.record("expected Loud's event")
      return
    }
    #expect(text == "hey")

    #expect(try loud.shout("quiet") == "QUIET")
    // Echo's methods, on Loud's client.
    #expect(try loud.say("ab", times: 2) == "abab")
    try loud.note(5, loud: false)
    #expect(try loud.noted() == 5)

    // The same channel as an Echo channel: Echo's calls work, and Loud's
    // event is one an Echo client can't read (no "is a").
    var echo = TestIPC.EchoClient(connection: loud.takeConnection())
    #expect(try echo.say("x", times: 3) == "xxx")
  }
  #expect(await server.value == nil)
}

@Test func anEchoClientCantReadLoudsOwnEvents() async throws {
  let ends = try Channel.create()
  let server = startLoudServer(ends.b.release())
  do {
    var echo = TestIPC.EchoClient(channel: ends.a)
    guard case .ticked = try echo.nextEvent() else {
      Issue.record("expected Echo's event")
      return
    }
    #expect(failure { () throws(IPCError<Never>) in try echo.nextEvent() } == "wire(IPCWire.WireError.unexpectedMessage)")
  }
  #expect(await server.value == nil)
}

@Test func anEchoServerRefusesLoudsOwnMethods() async throws {
  let ends = try Channel.create()
  let server = startServer(ends.b.release())
  do {
    var loud = TestIPC.LoudClient(connection: TestIPC.EchoClient(channel: ends.a).takeConnection())
    #expect(failure { () throws(IPCError<Never>) in try loud.shout("no") } == "transport(SysABI.Status.notSupported)")
    #expect(try loud.say("y", times: 1) == "y")
  }
  #expect(await server.value == nil)
}

/// What a call threw, described; nil if it didn't.
func failure<R: ~Copyable>(_ body: () throws(IPCError<Never>) -> R) -> String? {
  do throws(IPCError<Never>) {
    _ = try body()
    return nil
  } catch {
    return "\(error)"
  }
}
