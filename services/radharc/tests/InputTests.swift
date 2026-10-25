// SPDX-License-Identifier: BSD-3-Clause

// A window's input: the ring carries events in order, says when to ring,
// and drops what doesn't fit; /dev/kbd's and /dev/mouse's messages become
// key, pointer, button and wheel events.

import Kbdfs
import Radharc
import TDUnicode
import Testing

@Test func theRingCarriesEventsAndSaysWhenToRing() {
  let bytes = UnsafeMutableRawPointer.allocate(byteCount: WindowInput.size, alignment: 64)
  defer { bytes.deallocate() }
  bytes.initializeMemory(as: UInt8.self, repeating: 0, count: WindowInput.size)
  #expect(unsafe WindowInput.create(bytes))
  var producer = unsafe InputProducer(attaching: bytes)!
  var consumer = unsafe InputConsumer(attaching: bytes, size: WindowInput.size)!
  var popped = consumer.pop()
  #expect(popped == nil)
  let maySleep = consumer.prepareSleep()
  #expect(maySleep)  // empty: it may sleep
  let e = InputEvent(kind: .keyDown, code: 4, modifiers: 1, character: 0x61, time: 7)
  var ring = producer.push(e)
  #expect(ring)  // it sleeps: ring
  consumer.endSleep()
  ring = producer.push(InputEvent(kind: .keyUp, code: 4))
  #expect(!ring)  // awake: don't
  popped = consumer.pop()
  #expect(popped == e)
  popped = consumer.pop()
  #expect(popped?.kind == .keyUp)
  popped = consumer.pop()
  #expect(popped == nil)
  for _ in 0..<WindowInput.slots + 3 { _ = producer.push(e) }
  let dropped = producer.dropped
  #expect(dropped == 3)
}

@Test func keysComeFromWhatIsHeld() {
  var k = KeyboardDecoder()
  // Shift down, a down (the `c` typed is skipped), a up, Shift up.
  let shift = UTF8Text.encode(KeyRune.shift)
  var bytes: [UInt8] = [UInt8(ascii: "k")] + shift + [0]
  bytes += [UInt8(ascii: "k")] + shift + [UInt8(ascii: "a"), 0, UInt8(ascii: "c"), UInt8(ascii: "A"), 0]
  bytes += [UInt8(ascii: "K")] + shift + [0, UInt8(ascii: "K"), 0]
  let events = k.decode(bytes, time: 5)
  #expect(events.map(\.kind) == [.keyDown, .keyDown, .keyUp, .keyUp])
  #expect(events.map(\.code) == [0xE1, 0x04, 0x04, 0xE1])
  #expect(events[1].character == 0x61 && events[1].modifiers == InputEvent.Modifier.shift)
  #expect(events[0].character == 0 && events[3].modifiers == 0)
  #expect(k.held.isEmpty)
  // An arrow is the main block's, not the keypad's.
  #expect(k.usage(of: KeyRune.up) == 0x52)
}

@Test func thePointerButtonsAndWheelComeFromMessages() {
  func message(_ x: Int, _ y: Int, _ b: Int, _ ms: Int) -> [UInt8] {
    func field(_ v: Int) -> [UInt8] {
      let digits = Array(String(v).utf8)
      return [UInt8](repeating: 0x20, count: 11 - digits.count) + digits + [0x20]
    }
    return [UInt8(ascii: "m")] + field(x) + field(y) + field(b) + field(ms)
  }
  #expect(message(1, 2, 3, 4).count == 49)
  var m = MouseDecoder()
  var e = m.decode(message(40, 30, 0, 10))
  #expect(e == [InputEvent(kind: .pointerAbsolute, x: 40, y: 30, time: 10_000_000)])
  e = m.decode(message(40, 30, 4, 11))  // the right button: 2
  #expect(e.map(\.kind) == [.buttonDown] && e[0].code == 2 && e[0].x == 40)
  e = m.decode(message(41, 30, 4 | 8, 12))  // moved, and a notch up
  #expect(e.map(\.kind) == [.pointerAbsolute, .wheel] && e[1].y == 1)
  e = m.decode(message(41, 30, 0, 13))  // the notch's release is nothing
  #expect(e.map(\.kind) == [.buttonUp] && e[0].code == 2)
  #expect(m.decode(Array("not a message".utf8)).isEmpty)
}
