// SPDX-License-Identifier: BSD-3-Clause

// The K1's GPIO controller as bin/k1-gpio drives it: its commands, and
// the writes each makes to its banks' registers.

import DriverHost
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

@Test func atStartNoLinesEdgesAreEnabledOrLetThrough() {
  let reset = Watches.reset
  for b in 0..<K1Gpios.banks {
    let base = K1Gpios.bank(b)
    #expect(reset.contains { $0.offset == base + 0x9C && $0.value == 0 })
    #expect(reset.contains { $0.offset == base + 0x30 && $0.value == 0 })
    #expect(reset.contains { $0.offset == base + 0x3C && $0.value == 0 })
    #expect(reset.contains { $0.offset == base + 0x48 && $0.value == 0xFFFF_FFFF })
  }
  #expect(reset.allSatisfy { $0.offset + 4 <= K1Gpios.size })
}

@Test func aWatchedLinesEdgesAreCountedAndCleared() throws {
  // GPIO 80, the Orange Pi RV2's card detect: bank 2, pin 16, active low.
  var w = Watches()
  #expect(w.text(levels: [0, 0, 0, 0]) == "none\n")
  let c = try #require(GpioCommand("gpio 2 16 1 watch"))
  #expect(c.description == "gpio 2 16 1 watch")
  let writes = try w.watch(c)
  // Both edges on (GSRER, GSFER), an old edge cleared, then the mask.
  #expect(writes.map(\.offset) == [0x8 + 0x6C, 0x8 + 0x84, 0x8 + 0x48, 0x8 + 0x9C])
  #expect(writes.allSatisfy { $0.value == 1 << 16 })
  // Low is active: a card in.
  #expect(w.text(levels: [0, 0, 0, 0]) == "gpio 2 16 1 active edges 0\n")
  #expect(w.text(levels: [0, 0, 1 << 16, 0]) == "gpio 2 16 1 inactive edges 0\n")

  // A second line in the same bank keeps the first's mask bit.
  let more = try w.watch(GpioCommand(bank: 2, pin: 3, action: .watch))
  #expect(more.last! == (0x8 + 0x9C, (1 << 16) | (1 << 3)))
  #expect(w.lines.count == 2)
  // Watched again: still one line, its flags the new ones.
  _ = try w.watch(GpioCommand(bank: 2, pin: 3, activeLow: true, action: .watch))
  #expect(w.lines.count == 2 && w.lines[1].activeLow)

  // Every edge seen is cleared, a watched line's counted.
  let (clear, changed) = w.take([0x1, 0, 1 << 16, 0])
  #expect(clear.map(\.offset) == [0x48, 0x8 + 0x48] && clear.map(\.value) == [0x1, 1 << 16])
  #expect(changed && w.lines[0].edges == 1 && w.lines[1].edges == 0)
  // An unwatched line's edge changes nothing watched.
  let (_, quiet) = w.take([0, 0x2, 0, 0])
  #expect(!quiet)
  #expect(w.take([0, 0, 0, 0]).writes.isEmpty)

  #expect(throws: GpioError.noSuchPin) { try w.watch(GpioCommand(bank: 4, pin: 0, action: .watch)) }
}

@Test func aConsumerFindsItsLineInEvents() throws {
  var w = Watches()
  _ = try w.watch(GpioCommand(bank: 2, pin: 16, activeLow: true, action: .watch))
  _ = try w.watch(GpioCommand(bank: 3, pin: 0, action: .watch))
  _ = w.take([0, 0, 1 << 16, 0])
  let text = w.text(levels: [0, 0, 1 << 16, 1])
  #expect(WatchedGpio.find(text, cells: [2, 16, 1]) == WatchedGpio(active: false, edges: 1))
  #expect(WatchedGpio.find(text, cells: [3, 0, 0]) == WatchedGpio(active: true, edges: 0))
  // Its own specifier only: other flags, another pin, nothing watched.
  #expect(WatchedGpio.find(text, cells: [2, 16, 0]) == nil)
  #expect(WatchedGpio.find(text, cells: [2, 17, 1]) == nil)
  #expect(WatchedGpio.find("none\n", cells: [2, 16, 1]) == nil)
  #expect(WatchedGpio.find(text, cells: []) == nil)
}
