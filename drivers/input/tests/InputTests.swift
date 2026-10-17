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
