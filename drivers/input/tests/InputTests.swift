// SPDX-License-Identifier: BSD-3-Clause

// virtio-input's evdev codes as HID usages (D83), spot-checked against the
// USB HID Usage Tables: every key a US keyboard has maps, to one usage each.

import InputDevice
import Testing

@Test func evdevCodesAreTheirUsages() {
  #expect(KeyboardUsage.of(evdev: 30) == 0x04)   // KEY_A: a
  #expect(KeyboardUsage.of(evdev: 44) == 0x1D)   // KEY_Z: z
  #expect(KeyboardUsage.of(evdev: 2) == 0x1E && KeyboardUsage.of(evdev: 11) == 0x27)  // 1, 0
  #expect(KeyboardUsage.of(evdev: 28) == 0x28 && KeyboardUsage.of(evdev: 14) == 0x2A)  // Enter, Backspace
  #expect(KeyboardUsage.of(evdev: 29) == 0xE0 && KeyboardUsage.of(evdev: 97) == 0xE4)  // the Ctrls
  #expect(KeyboardUsage.of(evdev: 42) == 0xE1 && KeyboardUsage.of(evdev: 54) == 0xE5)  // the Shifts
  #expect(KeyboardUsage.of(evdev: 100) == 0xE6 && KeyboardUsage.of(evdev: 125) == 0xE3)  // AltGr, Meta
  #expect(KeyboardUsage.of(evdev: 111) == 0x4C && KeyboardUsage.of(evdev: 103) == 0x52)  // Delete, Up
  #expect(KeyboardUsage.of(evdev: 59) == 0x3A && KeyboardUsage.of(evdev: 88) == 0x45)  // F1, F12
  #expect(KeyboardUsage.of(evdev: 300) == 0)
  // Each key its own usage.
  let used = (1..<128).map { KeyboardUsage.of(evdev: UInt16($0)) }.filter { $0 != 0 }
  for u in used { #expect(used.filter { $0 == u }.count == 1) }
  #expect(KeyboardUsage.record(0x04, down: true) == [0x04, 1])
}

// A pointer's evdev events, gathered to its SYN_REPORT, as mousein records.
@Test func pointerReportsAreMouseinRecords() {
  func text(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }
  var p = PointerReport()
  #expect(p.take(type: PointerReport.rel, code: 0, value: 3).isEmpty)
  #expect(p.take(type: PointerReport.rel, code: 1, value: -2).isEmpty)
  _ = p.take(type: PointerReport.rel, code: 0, value: 1)
  _ = p.take(type: PointerReport.key, code: 0x110, value: 1)  // BTN_LEFT
  #expect(text(p.take(type: PointerReport.syn, code: 0, value: 0)) == "m4 -2 1\n")
  #expect(p.take(type: PointerReport.syn, code: 0, value: 0).isEmpty)  // nothing new
  // The right button is 4, the middle 2; a held button's repeat is none.
  _ = p.take(type: PointerReport.key, code: 0x111, value: 1)
  _ = p.take(type: PointerReport.key, code: 0x112, value: 2)
  #expect(text(p.take(type: PointerReport.syn, code: 0, value: 0)) == "m0 0 5\n")
  // The wheel: a record each notch, up 8, down 16, right 64.
  _ = p.take(type: PointerReport.key, code: 0x110, value: 0)
  _ = p.take(type: PointerReport.key, code: 0x111, value: 0)
  _ = p.take(type: PointerReport.rel, code: 8, value: 2)
  #expect(text(p.take(type: PointerReport.syn, code: 0, value: 0)) == "m0 0 8\nm0 0 8\n")
  _ = p.take(type: PointerReport.rel, code: 8, value: -1)
  _ = p.take(type: PointerReport.rel, code: 6, value: 1)
  _ = p.take(type: PointerReport.rel, code: 0, value: 7)
  #expect(text(p.take(type: PointerReport.syn, code: 0, value: 0)) == "m7 0 0\nm0 0 16\nm0 0 64\n")
  #expect(!PointerReport.isButton(30) && PointerReport.isButton(0x112))

  // A tablet: its axes scaled from their ranges to 0 to 2^31.
  var t = PointerReport(rangeX: 0...32767, rangeY: 0...32767)
  _ = t.take(type: PointerReport.abs, code: 0, value: 16384)
  _ = t.take(type: PointerReport.abs, code: 1, value: 0)
  #expect(text(t.take(type: PointerReport.syn, code: 0, value: 0)) == "a1073741824 0 0\n")
  _ = t.take(type: PointerReport.abs, code: 1, value: 40000)  // past the range: its end
  _ = t.take(type: PointerReport.key, code: 0x110, value: 1)
  #expect(text(t.take(type: PointerReport.syn, code: 0, value: 0)) == "a1073741824 2147418112 1\n")
}

// A USB keyboard's boot reports as kbin's records: what changed since the
// last report, modifiers first, releases before presses.
@Test func bootKeyboardReportsAreChanges() {
  var k = BootKeyboard()
  #expect(k.take([0, 0, 0x04, 0, 0, 0, 0, 0]) == [0x04, 1])  // a
  #expect(k.take([0, 0, 0x04, 0, 0, 0, 0, 0]).isEmpty)  // still held
  #expect(k.take([0x02, 0, 0x04, 0x05, 0, 0, 0, 0]) == [0xE1, 1, 0x05, 1])  // LeftShift, b
  #expect(k.take([0x02, 0, 0x05, 0, 0, 0, 0, 0]) == [0x04, 0])
  #expect(k.take([0x02, 0, 1, 1, 1, 1, 1, 1]).isEmpty)  // rolled over: unknown, nothing
  #expect(k.take([0, 0, 0, 0, 0, 0, 0, 0]) == [0xE1, 0, 0x05, 0])
  #expect(k.take([0, 0]).isEmpty)  // short
}

// A USB mouse's boot reports as mousein's records: the right button is 4,
// the middle 2, the wheel a record each notch.
@Test func bootMouseReportsAreMouseinRecords() {
  func text(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }
  var m = HIDMouse()
  #expect(text(m.take([0x01, 5, 0xFE])) == "m5 -2 1\n")
  #expect(text(m.take([0x03, 0, 0])) == "m0 0 5\n")
  #expect(m.take([0x03, 0, 0]).isEmpty)
  #expect(text(m.take([0x04, 0, 0, 1])) == "m0 0 10\n")  // the wheel's record carries the buttons
  #expect(text(m.take([0, 0, 0, 0xFF])) == "m0 0 16\n")
}

// The Corsair 1b1c:1bac's mouse interface, as it describes itself: five
// buttons, 16-bit X and Y, a wheel byte, and five vendor bytes; it sends
// this even when asked for the boot protocol.
let corsairMouse: [UInt8] = [
  0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x09, 0x01, 0xA1, 0x00, 0x05, 0x09, 0x19, 0x01, 0x29, 0x05, 0x15, 0x00,
  0x25, 0x01, 0x95, 0x05, 0x75, 0x01, 0x81, 0x02, 0x95, 0x03, 0x75, 0x01, 0x81, 0x03, 0x75, 0x10, 0x95, 0x02,
  0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x16, 0x01, 0x80, 0x26, 0xFF, 0x7F, 0x81, 0x06, 0x75, 0x08, 0x95, 0x01,
  0x05, 0x01, 0x09, 0x38, 0x15, 0x81, 0x25, 0x7F, 0x81, 0x06, 0x06, 0x00, 0xFF, 0x09, 0xF1, 0x75, 0x08, 0x95,
  0x05, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x81, 0x00, 0xC0, 0xC0,
]

@Test func aMouseIsReadAsItsDescriptorLaysItOut() {
  let layout = MouseLayout.parse(corsairMouse)
  #expect(layout == MouseLayout(reportID: nil, buttons: [0, 1, 2],
                                x: .init(offset: 8, size: 16, signed: true), y: .init(offset: 24, size: 16, signed: true),
                                wheel: .init(offset: 40, size: 8, signed: true)))
  func text(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }
  var m = HIDMouse(layout: layout ?? .boot)
  // Down and left: dy +3 (0x0003), dx -2 (0xFFFE), which the boot
  // protocol's bytes read as dy -1 and a wheel notch.
  #expect(text(m.take([0, 0xFE, 0xFF, 0x03, 0x00, 0, 0, 0, 0, 0, 0])) == "m-2 3 0\n")
  #expect(text(m.take([0x02, 0, 0, 0, 0, 0xFF, 0, 0, 0, 0, 0])).hasSuffix("m0 0 20\n"))
}

@Test func aMouseWithReportIDsReadsOnlyItsReport() {
  // Report 2: three buttons and five bits of padding, then 8-bit X and Y.
  let d: [UInt8] = [
    0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x85, 0x02, 0x09, 0x01, 0xA1, 0x00, 0x05, 0x09, 0x19, 0x01, 0x29, 0x03,
    0x15, 0x00, 0x25, 0x01, 0x95, 0x03, 0x75, 0x01, 0x81, 0x02, 0x95, 0x01, 0x75, 0x05, 0x81, 0x03, 0x05, 0x01,
    0x09, 0x30, 0x09, 0x31, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x02, 0x81, 0x06, 0xC0, 0xC0,
  ]
  let layout = MouseLayout.parse(d)
  #expect(layout?.reportID == 2 && layout?.x == .init(offset: 8, size: 8, signed: true) && layout?.wheel == nil)
  var m = HIDMouse(layout: layout ?? .boot)
  #expect(m.take([1, 0, 5, 5]).isEmpty)  // another report's
  #expect(String(decoding: m.take([2, 0, 5, 0xFB]), as: UTF8.self) == "m5 -5 0\n")
  // A keyboard's descriptor has no pointer.
  #expect(MouseLayout.parse([0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0xC0]) == nil)
}
