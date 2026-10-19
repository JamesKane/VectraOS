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
