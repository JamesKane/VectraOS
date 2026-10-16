// SPDX-License-Identifier: BSD-3-Clause

@testable import Echo
import IPC
import Testing

typealias Point = TestIPC.Point
typealias Shaped = TestIPC.Shaped

/// A server, and its c.client.
struct Connected: ~Copyable {
  var client: TestIPC.EchoClient
  let server: Task<IPCError<Never>?, Never>
}

/// A client of a fresh server, which has sent its first event.
func connect() throws -> Connected {
  let ends = try Channel.create()
  let server = startServer(ends.b.release())
  return Connected(client: TestIPC.EchoClient(channel: ends.a), server: server)
}

/// Closes the client, which ends the server's loop; whether it ended well.
func finish(_ c: consuming Connected) async -> Bool {
  let server = c.server
  _ = consume c
  return await server.value == nil
}

let sample = Shaped(
  shape: .triangle, at: Point(x: -3, y: 4), label: "tri", tags: ["a", "", "ccc"],
  path: [Point(x: 1, y: 2), Point(x: Int32.min, y: Int32.max)], weight: 513, data: [0, 255, 7], flag: true)

@Test func callsRepliesErrorsEventsAndHandles() async throws {
  var c = try connect()

  let said = try c.client.say("hi", times: 3)
  #expect(said == "hihihi")

  var remote: EchoError?
  do throws(IPCError<EchoError>) {
    _ = try c.client.say("long", times: 100)
  } catch {
    if case .remote(let e) = error { remote = e }
  }
  #expect(remote == .tooLong)

  try c.client.note(5, loud: false)
  try c.client.note(5, loud: true)
  let noted = try c.client.noted()
  #expect(noted == 15)

  // The event was sent before the first reply, and stayed queued.
  let event = try c.client.nextEvent()
  guard case .ticked(let n, let label) = event else { Issue.record("wrong event"); return }
  #expect(n == 7 && label == "first")

  // The handle goes and comes back: the same counter, as its value shows
  // (V1 has no events, D23).
  let sent = try Counter.create()
  try Counter.add(sent, 7)
  let back = try c.client.swap(sent)
  #expect(try Counter.read(back) == 7)

  #expect(await finish(c))
}

@Test func structsEnumsOptionalsAndVectorsRoundTrip() async throws {
  var c = try connect()
  #expect(try c.client.reflect(sample) == sample)
  let sparse = Shaped(shape: .circle, at: Point(x: 0, y: 0), label: nil, tags: [], path: [], weight: nil,
                      data: [], flag: false)
  #expect(try c.client.reflect(sparse) == sparse)

  let many = try c.client.many([sample, sparse], nested: [[1, 2, 3], [], [10]], maybe: [Point(x: 9, y: 9)])
  #expect(many.count == 6)
  #expect(Array(many[0..<2]) == [sample, sparse])
  #expect(many[2...4].map(\.weight) == [6, 0, 10])
  #expect(many[5].path == [Point(x: 9, y: 9)] && many[5].label == "maybe")
  #expect(try c.client.many([], nested: [], maybe: nil).isEmpty)
  #expect(await finish(c))
}

@Test func optionalsAndStructsCarryHandles() async throws {
  var c = try connect()

  let present = try Counter.create()
  let returned = try c.client.optionals("t", bytes: [], point: Point(x: 1, y: 1), handle: present)
  let came = returned != nil
  #expect(came)
  let none = try c.client.optionals(nil, bytes: [1], point: nil, handle: nil)
  let absent = none == nil
  #expect(absent)

  // A struct with two handles: they come back swapped.
  let a = try Counter.create(), b = try Counter.create()
  let aKoid = try a.info().koid, bKoid = try b.info().koid
  let carried = try c.client.carry(TestIPC.Carried(name: "box", handle: a, spare: b, inner: sample))
  #expect(carried.name == "box!" && carried.inner == sample)
  #expect(try carried.handle.info().koid == bKoid)
  let spareKoid = try carried.spare?.info().koid
  #expect(spareKoid == aKoid)
  _ = consume carried
  #expect(await finish(c))
}

@Test func aLateReplyIsDroppedAndTheNextCallWorks() async throws {
  // A server that answers its first call late.
  let ends = try Channel.create()
  let raw = ends.b.release()
  let server = Task.detached {
    let end = Handle(raw: raw)
    _ = try? end.wait(for: Signals.readable)
    guard let first = try? Channel.read(end) else { return }
    sleep(until: Clock.monotonic() + 50_000_000)
    var reply = first.bytes
    reply[4] = MessageKind.reply.rawValue
    try? Channel.write(end, bytes: reply)
    var server = TestIPC.EchoServer(channel: end, impl: EchoImpl())
    try? server.serve()
  }
  var client = TestIPC.EchoClient(channel: ends.a)
  client.connection.timeout = 5_000_000
  var status: Status?
  do throws(IPCError<Never>) {
    _ = try client.noted()
  } catch {
    if case .transport(let s) = error { status = s }
  }
  #expect(status == .timedOut)
  client.connection.timeout = nil
  #expect(try client.noted() == 0)
  _ = consume client
  await server.value
}

@Test func unknownMethodsGetNotSupported() async throws {
  var c = try connect()
  let request = try IPCCodec.encode(
    MessageHeader(txid: 0, kind: .request, ordinal: 0x1234), inlineSize: 0, Never.self)
  var status: Status?
  do throws(IPCError<Never>) {
    _ = try c.client.connection.call(request, Never.self, trace: TestIPC._trace_Echo_say)
  } catch {
    if case .transport(let s) = error { status = s }
  }
  #expect(status == .notSupported)
  _ = await finish(c)
}

@Test func ordinalsAreTheWireFormatsHash() {
  // The macro computes ordinals with IPCWire.methodOrdinal; recompute one.
  let name = Array("todhchai.test.Echo.say".utf8)
  #expect(methodOrdinal(name.span) == 0x1458_fe16_9955_bc11)
}

@Test func unionsRoundTripInStructsVectorsAndOptionals() async throws {
  var c = try connect()
  let drawing = TestIPC.Drawing(
    name: "d", first: .move(Point(x: 1, y: 2)),
    rest: [.label(text: "hi", at: Point(x: 3, y: 4), size: 12), .path([Point(x: 5, y: 6)], closed: false),
           .style(.circle), .shaped(sample), .clear])
  #expect(try c.client.draw(drawing, last: .clear) == [drawing.first] + drawing.rest + [.clear])
  #expect(try c.client.draw(TestIPC.Drawing(name: "", first: .clear, rest: []), last: nil) == [.clear])
  #expect(await finish(c))
}
