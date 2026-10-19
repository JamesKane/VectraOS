// SPDX-License-Identifier: BSD-3-Clause

// The mouse service's state (D83), against 9front's devmouse.c: the
// message's form, motion kept inside the screen, the button queue,
// writers' own buttons, the wheel's notches, scaling, acceleration and
// mousectl's messages.

import Mouse
import Testing

func text(_ b: [UInt8]?) -> String { b.map { String(decoding: $0, as: UTF8.self) } ?? "nil" }

/// The four numbers of a message.
func fields(_ b: [UInt8]?) -> [Int] {
  guard let b, b.first == UInt8(ascii: "m") else { return [] }
  return String(decoding: b.dropFirst(), as: UTF8.self).split(separator: " ").compactMap { Int($0) }
}

@Test func messagesAreDevmouses() {
  let mouse = Mouse(width: 800, height: 600)
  let r = mouse.open()
  #expect(mouse.read(r) == nil)  // nothing has changed
  let w = MouseWriter()
  #expect(mouse.mousein(Array("m 10 -5 0 1234".utf8), from: w, msec: 9))
  let m = mouse.read(r)
  #expect(m?.count == 49)
  #expect(text(m) == "m        410         295           0        1234 ")
  #expect(mouse.read(r) == nil)
  // nusb/kb's form, the first number touching the m.
  #expect(mouse.mousein(Array("m          1           1           0".utf8), from: w, msec: 10))
  #expect(fields(mouse.read(r)) == [411, 296, 0, 10])
  #expect(!mouse.mousein(Array("x 1 2 0".utf8), from: w, msec: 0))
  #expect(!mouse.mousein(Array("m 1 2".utf8), from: w, msec: 0))
  #expect(text(mouse.current()) == text(mouse.message(mouse.state)))
}

@Test func thePointerStaysOnTheScreen() {
  let mouse = Mouse(width: 800, height: 600)
  let w = MouseWriter()
  _ = mouse.mousein(Array("m -5000 -5000 0".utf8), from: w, msec: 1)
  #expect(mouse.state.x == 0 && mouse.state.y == 0)
  _ = mouse.mousein(Array("A 5000 5000 0".utf8), from: w, msec: 1)
  #expect(mouse.state.x == 799 && mouse.state.y == 599)
  // Scaled: 0 to 2^31 across it.
  _ = mouse.mousein(Array("a 1073741824 536870912 0".utf8), from: w, msec: 1)
  #expect(mouse.state.x == 400 && mouse.state.y == 150)
  #expect(mouse.move(Array("m 12 34".utf8), msec: 2))
  #expect(mouse.state.x == 12 && mouse.state.y == 34)
  #expect(!mouse.move(Array("m 12".utf8), msec: 2))
}

@Test func buttonChangesAreQueued() {
  let mouse = Mouse(width: 100, height: 100)
  let r = mouse.open()
  let w = MouseWriter()
  // A click and a move, all before a read: the press and the release each
  // read, then the state after.
  _ = mouse.mousein(Array("m 0 0 1\nm 0 0 0\nm 5 5 0\n".utf8), from: w, msec: 1)
  #expect(fields(mouse.read(r))[2] == 1)
  #expect(fields(mouse.read(r))[2] == 0)
  #expect(fields(mouse.read(r)) == [55, 55, 0, 1])
  #expect(mouse.read(r) == nil)
  // At most 16 queued.
  for i in 0..<40 { _ = mouse.mousein(Array("m 0 0 \(i & 1)".utf8), from: w, msec: 1) }
  var n = 0
  while mouse.read(r) != nil { n += 1 }
  #expect(n == 17)  // the 16, then the state
  // Each reader its own.
  let s = mouse.open()
  _ = mouse.mousein(Array("m 0 0 4".utf8), from: w, msec: 1)
  #expect(fields(mouse.read(r))[2] == 4 && fields(mouse.read(s))[2] == 4)
}

@Test func writersHoldTheirOwnButtons() {
  let mouse = Mouse(width: 100, height: 100)
  let a = MouseWriter(), b = MouseWriter()
  _ = mouse.mousein(Array("m 0 0 1".utf8), from: a, msec: 1)
  _ = mouse.mousein(Array("m 0 0 4".utf8), from: b, msec: 1)
  #expect(mouse.state.buttons == 5)
  _ = mouse.mousein(Array("m 1 0 0".utf8), from: a, msec: 1)
  #expect(mouse.state.buttons == 4)
  mouse.closed(b, msec: 2)
  #expect(mouse.state.buttons == 0)
}

@Test func theWheelIsMomentary() {
  let mouse = Mouse(width: 100, height: 100)
  let r = mouse.open()
  let w = MouseWriter()
  _ = mouse.mousein(Array("m 0 0 8\nm 0 0 8\n".utf8), from: w, msec: 1)
  // Two notches: pressed, released, pressed, released.
  #expect((0..<4).map { _ in fields(mouse.read(r))[2] } == [8, 0, 8, 0])
  #expect(mouse.state.buttons == 0)
  #expect(mouse.control(Array("scrollswap".utf8)))
  _ = mouse.mousein(Array("m 0 0 9".utf8), from: w, msec: 1)
  #expect(fields(mouse.read(r))[2] == 1)
  #expect(fields(mouse.read(r))[2] == 17)  // the left held, the wheel swapped
}

@Test func mousectl() {
  let mouse = Mouse(width: 1000, height: 1000)
  let w = MouseWriter()
  #expect(mouse.control(Array("swap".utf8)))
  _ = mouse.mousein(Array("m 0 0 1".utf8), from: w, msec: 1)
  #expect(fields(mouse.current())[2] == 4)
  #expect(mouse.control(Array("swap".utf8)))
  #expect(fields(mouse.current())[2] == 1)
  #expect(mouse.control(Array("buttonmap 213".utf8)))
  _ = mouse.mousein(Array("m 0 0 2".utf8), from: w, msec: 1)
  #expect(fields(mouse.current())[2] == 1)
  #expect(!mouse.control(Array("buttonmap 113".utf8)))
  #expect(!mouse.control(Array("buttonmap 12".utf8)))
  #expect(mouse.control(Array("buttonmap".utf8)))
  #expect(fields(mouse.current())[2] == 2)
  // devmouse's scale: 4 and 5 stepped, 6 on multiplied.
  _ = mouse.mousein(Array("A 500 500 0".utf8), from: w, msec: 1)
  #expect(mouse.control(Array("accelerated 4\n".utf8)))
  _ = mouse.mousein(Array("m 3 4 0".utf8), from: w, msec: 1)
  #expect(mouse.state.x == 503 && mouse.state.y == 507)
  _ = mouse.mousein(Array("m 5 -10 0".utf8), from: w, msec: 1)
  #expect(mouse.state.x == 514 && mouse.state.y == 467)
  #expect(mouse.control(Array("linear".utf8)))
  _ = mouse.mousein(Array("m 10 0 0".utf8), from: w, msec: 1)
  #expect(mouse.state.x == 524)
  #expect(mouse.control(Array("reset".utf8)))
  #expect(!mouse.control(Array("blank".utf8)))
  #expect(!mouse.control([]))
}
