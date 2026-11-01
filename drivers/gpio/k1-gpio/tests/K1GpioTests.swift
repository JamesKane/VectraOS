// SPDX-License-Identifier: BSD-3-Clause

// The K1's GPIO controller as bin/k1-gpio drives it: its commands, and
// the writes each makes to its banks' registers.

import K1Gpio
import Testing

@Test func commandsNameAPinAndWhatItDoes() {
  #expect(GpioCommand("gpio 3 20 0 on") == GpioCommand(bank: 3, pin: 20, action: .on))
  #expect(GpioCommand("gpio 3 0 1 off") == GpioCommand(bank: 3, pin: 0, activeLow: true, action: .off))
  #expect(GpioCommand("gpio 2 16 0x0 input")?.action == .input)
  #expect(GpioCommand("gpio 3 20 on") == nil)
  #expect(GpioCommand("gpio 3 20 0 high") == nil)
  #expect(GpioCommand("pin 3 20 0 on") == nil)
  #expect(GpioCommand("gpio 3 20 1 on")?.description == "gpio 3 20 1 on")
}

@Test func anOutputsLevelIsSetBeforeItsDirection() throws {
  // GPIO 116, the Orange Pi RV2's PCIe slots' power: bank 3, at 0x100.
  let on = try GpioCommand(bank: 3, pin: 20, action: .on).writes()
  #expect(on.map(\.offset) == [0x118, 0x154] && on.allSatisfy { $0.value == 1 << 20 })
  // Active low: on is low, through the clear register.
  let low = try GpioCommand(bank: 1, pin: 0, activeLow: true, action: .on).writes()
  #expect(low.map(\.offset) == [0x4 + 0x24, 0x4 + 0x54] && low[0].value == 1)
  #expect(try GpioCommand(bank: 0, pin: 5, action: .input).writes().map(\.offset) == [0x60])
  #expect(throws: GpioError.noSuchPin) { try GpioCommand(bank: 4, pin: 0, action: .on).writes() }
  #expect(throws: GpioError.noSuchPin) { try GpioCommand(bank: 0, pin: 32, action: .on).writes() }
  // Every register written is within the extent the driver maps.
  for b in 0..<K1Gpios.banks {
    for w in try GpioCommand(bank: b, pin: 31, action: .off).writes() { #expect(w.offset + 4 <= K1Gpios.size) }
  }
}
