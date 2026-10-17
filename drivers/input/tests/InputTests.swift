// SPDX-License-Identifier: BSD-3-Clause

// The input class (V2 item 7d) over SysHost: events on a reader's ring,
// what doesn't fit dropped and counted, a sleeping reader woken through
// its doorbell, a ring that isn't one refused; and `Device` over a
// channel, its `open` handing the driver the reader's ring.

import IPC
import InputDevice
import Sys
import Testing

func key(_ code: UInt16, _ value: Int32, at time: Int64 = 1) -> [InputEvent] {
  [InputEvent(time: time, type: 1, code: code, value: value), InputEvent(time: time, type: 0, code: 0, value: 0)]
}

@Test func eventsGoThroughTheReadersRing() throws {
  var reader = try InputReader(slots: 8)
  let writer = try #require(InputWriter(try reader.events()))
  #expect(writer.post(key(30, 1) + key(30, 0, at: 2)))
  let read = try reader.read(deadline: Clock.monotonic())
  #expect(read == key(30, 1) + key(30, 0, at: 2))
  #expect(read[1].endsBatch && !read[0].endsBatch)
  // Nothing more: the wait ends at its deadline, empty.
  #expect(try reader.read(deadline: Clock.monotonic() + 1_000_000).isEmpty)
  // A full ring drops what doesn't fit, and counts it.
  #expect(writer.post((0..<5).flatMap { key(UInt16(16 + $0), 1, at: Int64($0)) }))
  #expect(writer.dropped == 2)
  #expect(try reader.read().count == 8)
}

@Test func aSleepingReaderIsWoken() throws {
  var reader = try InputReader(slots: 4)
  let writer = try #require(InputWriter(try reader.events()))
  let posted = try Thread.spawn {
    sleep(until: Clock.monotonic() + 20_000_000)
    writer.post(key(2, 1))
  }
  #expect(try reader.read(deadline: Clock.monotonic() + 2_000_000_000) == key(2, 1))
  _ = consume posted
}

@Test func aRingThatIsntOneIsRefused() throws {
  // More slots than its VMO holds, then a VMO holding no ring.
  let reader = try InputReader(slots: 4)
  var events = try reader.events()
  events.slots = 1 << 16
  #expect(InputWriter(events) == nil)
  let blank = InputDeviceIPC.Events(memory: try VMO.create(size: 4096), readerBell: try Counter.create(), slots: 4)
  #expect(InputWriter(blank) == nil)
}

/// A device that keeps the ring its reader opens.
final class Opened: @unchecked Sendable { var writer: InputWriter? }

struct Keyboard: InputDeviceIPC.DeviceHandler {
  let opened: Opened
  func info() -> InputDeviceIPC.DeviceInfo { InputDeviceIPC.DeviceInfo(name: "kbd", kind: 1, vendor: 1, product: 2) }
  func open(_ events: consuming InputDeviceIPC.Events) throws(InputDeviceIPC.InputError) {
    guard let w = InputWriter(events) else { throw .invalid }
    opened.writer = w
  }
}

@Test func theDeviceProtocolOpensTheRing() throws {
  let d = try IPCDispatcher()
  let ends = try Channel.create()
  let opened = Opened()
  try d.add(InputDeviceIPC.DeviceServer(channel: ends.b, impl: Keyboard(opened: opened)))
  let thread = try Thread.spawn { try? d.run() }
  var client = InputDeviceIPC.DeviceClient(channel: ends.a)
  #expect(try client.info() == InputDeviceIPC.DeviceInfo(name: "kbd", kind: 1, vendor: 1, product: 2))
  var reader = try InputReader(slots: 16)
  try client.open(try reader.events())
  #expect(opened.writer?.post(key(30, 1)) == true)
  #expect(try reader.read(deadline: Clock.monotonic() + 2_000_000_000) == key(30, 1))
  var bad = try reader.events()
  bad.slots = 3
  var refused = false
  do throws(IPCError<InputDeviceIPC.InputError>) { try client.open(bad) } catch {
    if case .remote(.invalid) = error { refused = true }
  }
  #expect(refused)
  d.stop()
  _ = consume thread
}
