// SPDX-License-Identifier: BSD-3-Clause

// The Sky1's Cadence GPIO controller as bin/cdns-gpio drives it: its
// commands, the writes each makes, and what an interrupt is.

import CdnsGpio
import DriverHost
import Testing

@Test func commandsNameAPinAndWhatItDoes() {
  #expect(GpioCommand("gpio 7 0 on") == GpioCommand(pin: 7, action: .on))
  #expect(GpioCommand("gpio 6 1 off") == GpioCommand(pin: 6, activeLow: true, action: .off))
  #expect(GpioCommand("gpio 0x1f 0x0 input")?.pin == 31)
  #expect(GpioCommand("gpio 6 0 watch rising") == GpioCommand(pin: 6, action: .watch, trigger: .rising))
  #expect(GpioCommand("gpio 10 1 watch low")?.description == "gpio 10 1 watch low")
  #expect(GpioCommand("gpio 10 1 watch")?.trigger == .both)
  // A trigger only a watch takes, and only a known one.
  #expect(GpioCommand("gpio 1 0 on rising") == nil)
  #expect(GpioCommand("gpio 1 0 watch sideways") == nil)
  #expect(GpioCommand("gpio 1 on") == nil)
  #expect(GpioCommand("pin 1 0 on") == nil)
}

@Test func controllersHaveTheirOwnLineCounts() {
  #expect(CdnsGpios.lines(base: 0x0412_0000) == 32)
  #expect(CdnsGpios.lines(base: 0x0415_0000) == 17)
  #expect(CdnsGpios.lines(base: 0x1600_4000) == 32)
  #expect(CdnsGpios.lines(base: 0x1600_5000) == 10)
  #expect(CdnsGpios.lines(base: 0x1600_6000) == 10)
  #expect(CdnsGpios.all(17) == 0x1_FFFF && CdnsGpios.all(32) == 0xFFFF_FFFF && CdnsGpios.all(10) == 0x3FF)
}

@Test func anOutputsLevelIsSetBeforeItsDirection() throws {
  let now = LineRegisters(bypass: 0x81, direction: 0xFFFF_FFFF, outputEnable: 0, outputValue: 0x4)
  let on = try GpioCommand(pin: 7, action: .on).writes(lines: 32, now: now)
  #expect(on.map(\.offset) == [0x0C, 0x08, 0x00, 0x04])
  // Only its own bit changes: the others stay as firmware left them.
  #expect(on[0].value == 0x84 && on[1].value == 0x80 && on[2].value == 0x01 && on[3].value == 0xFFFF_FF7F)
  // Active low: on is low.
  let low = try GpioCommand(pin: 2, activeLow: true, action: .on).writes(lines: 32, now: now)
  #expect(low[0].value == 0x0)
  let off = try GpioCommand(pin: 2, action: .off).writes(lines: 32, now: now)
  #expect(off[0].value == 0x0)
  let input = try GpioCommand(pin: 7, action: .input).writes(lines: 32, now: now)
  #expect(input.map(\.offset) == [0x00, 0x04] && input[0].value == 0x01)
}

@Test func aPinTheControllerLacksIsRefused() {
  #expect(throws: GpioError.noSuchPin) { try GpioCommand(pin: 10, action: .on).writes(lines: 10, now: LineRegisters()) }
  #expect(throws: GpioError.noSuchPin) { try GpioCommand(pin: 32, action: .input).writes(lines: 32, now: LineRegisters()) }
  #expect(throws: GpioError.noSuchPin) { try GpioCommand(pin: -1, action: .input).writes(lines: 32, now: LineRegisters()) }
  #expect((try? GpioCommand(pin: 9, action: .watch).writes(lines: 10, now: LineRegisters())) != nil)
}

@Test func eachTriggerProgramsAllThreeRegisters() throws {
  let expected: [(Trigger, Bool, Bool, Bool)] = [
    (.high, true, true, false), (.low, true, false, false), (.rising, false, true, false),
    (.falling, false, false, false), (.both, false, false, true),
  ]
  for (t, type, value, any) in expected {
    // Every register set, as after another trigger: all three change.
    let now = LineRegisters(type: 0xFFFF_FFFF, value: 0xFFFF_FFFF, anyEdge: 0xFFFF_FFFF)
    let w = try GpioCommand(pin: 3, action: .watch, trigger: t).writes(lines: 32, now: now)
    func bit(_ offset: Int) -> Bool { w.first(where: { $0.offset == offset })!.value & 8 != 0 }
    #expect(bit(CdnsRegister.type) == type && bit(CdnsRegister.value) == value && bit(CdnsRegister.anyEdge) == any)
  }
}

@Test func aWatchMasksItsLineWhileItsTriggerChangesAndUnmasksLast() throws {
  let w = try GpioCommand(pin: 6, action: .watch, trigger: .rising).writes(lines: 32, now: LineRegisters(bypass: 0x40))
  #expect(w.first! == (CdnsRegister.disable, 0x40))
  // Cleared of an old interrupt before it is unmasked.
  #expect(w.suffix(2).map(\.offset) == [CdnsRegister.status, CdnsRegister.enable])
  #expect(w.suffix(2).allSatisfy { $0.value == 0x40 })
  // An input, and handed to GPIO from any bypass.
  #expect(w.first(where: { $0.offset == CdnsRegister.direction })!.value & 0x40 != 0)
  #expect(w.first(where: { $0.offset == CdnsRegister.bypass })!.value == 0)
  // No register past the extent.
  #expect(w.allSatisfy { $0.offset + 4 <= CdnsGpios.size })
}

@Test func atStartNoLineIsLetThroughAndNonePending() {
  let w = Watches.reset(lines: 17, pending: 0x5)
  #expect(w.map(\.offset) == [CdnsRegister.disable, CdnsRegister.status])
  #expect(w[0].value == 0x1_FFFF && w[1].value == 0x5)
}

@Test func anEdgeIsCountedAndClearedOnce() throws {
  var w = Watches()
  #expect(w.text(level: 0) == "none\n")
  // The Orange Pi 6 Plus's EC: S5 GPIO 0 line 6, rising edge.
  w.watch(GpioCommand(pin: 6, action: .watch, trigger: .rising))
  w.watch(GpioCommand(pin: 10, activeLow: true, action: .watch, trigger: .low))
  #expect(w.text(level: 0) == "gpio 6 0 inactive edges 0\ngpio 10 1 active edges 0\n")
  #expect(w.text(level: 1 << 10) == "gpio 6 0 inactive edges 0\ngpio 10 1 inactive edges 0\n")

  let (edge, changed) = w.take(status: 1 << 6, mask: 1 << 10)
  #expect(changed && w.lines[0].edges == 1 && w.lines[1].edges == 0)
  #expect(edge.count == 1 && edge[0] == (CdnsRegister.status, 1 << 6))
  // A masked line's status bit is no interrupt.
  let (none, quiet) = w.take(status: 1 << 10, mask: 1 << 10)
  #expect(!quiet && none.isEmpty)
  // An unwatched line's bit is cleared, and changes nothing watched.
  let (stray, q2) = w.take(status: 1 << 3, mask: 0)
  #expect(!q2 && stray.count == 1 && stray[0].value == 1 << 3)
}

@Test func aLevelLineIsMaskedOnceItHasFiredUntilWatchedAgain() throws {
  var w = Watches()
  w.watch(GpioCommand(pin: 10, activeLow: true, action: .watch, trigger: .low))
  let (writes, changed) = w.take(status: 1 << 10, mask: 0)
  // Masked before it is cleared, so its still-low input doesn't raise it again.
  #expect(changed && writes.map(\.offset) == [CdnsRegister.disable, CdnsRegister.status])
  #expect(w.lines[0].masked && w.lines[0].edges == 1)
  w.watch(GpioCommand(pin: 10, activeLow: true, action: .watch, trigger: .low))
  #expect(!w.lines[0].masked && w.lines.count == 1 && w.lines[0].edges == 1)
  // Two lines at once, from one read of the status.
  w.watch(GpioCommand(pin: 6, action: .watch, trigger: .rising))
  let (both, _) = w.take(status: (1 << 6) | (1 << 10), mask: 0)
  #expect(both.map(\.value) == [1 << 10, (1 << 6) | (1 << 10)])
  #expect(w.lines[0].edges == 2 && w.lines[1].edges == 1)
}

@Test func aConsumerFindsItsLineInEvents() throws {
  var w = Watches()
  w.watch(GpioCommand(pin: 6, action: .watch, trigger: .rising))
  w.watch(GpioCommand(pin: 10, activeLow: true, action: .watch, trigger: .low))
  _ = w.take(status: 1 << 10, mask: 0)
  let text = w.text(level: 1 << 6)
  #expect(WatchedGpio.find(text, cells: [6, 0]) == WatchedGpio(active: true, edges: 0))
  #expect(WatchedGpio.find(text, cells: [10, 1]) == WatchedGpio(active: true, edges: 1))
  #expect(WatchedGpio.find(text, cells: [10, 0]) == nil)
  #expect(WatchedGpio.find("none\n", cells: [6, 0]) == nil)
}

@Test func statusNamesAPinsDirectionLevelAndWatch() {
  let w = Watches.Line(pin: 6, activeLow: false, trigger: .rising, edges: 3)
  #expect(pinStatus(pin: 6, direction: 0x40, level: 0x40, bypass: 0, mask: 0, watch: w) == "pin 6 input level 1 watched rising edges 3")
  #expect(pinStatus(pin: 6, direction: 0, level: 0, bypass: 0x40, mask: 0x40, watch: nil) == "pin 6 output level 0 bypassed")
  #expect(pinStatus(pin: 6, direction: 0x40, level: 0, bypass: 0, mask: 0x40, watch: w).hasSuffix("edges 3 masked"))
}
