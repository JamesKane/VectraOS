// SPDX-License-Identifier: BSD-3-Clause

// The Sky1's reset controllers as bin/sky1-reset drives them: ctl's
// commands, the line each RSTL index names, and the one bit a change
// touches.

import DriverHost
import Sky1Reset
import Testing

@Test func ctlLinesBecomeCommands() {
  #expect(Command("reset 9 assert") == .assert(9))
  #expect(Command("reset 9 deassert") == .deassert(9))
  #expect(Command("reset 0x17 deassert") == .deassert(23))
  #expect(Command("reset 9 pulse 20") == .pulse(9, microseconds: 20))
  #expect(Command("reset 9 pulse 100000") == .pulse(9, microseconds: 100_000))
  #expect(Command("reset 9 pulse 100001") == nil)
  #expect(Command("reset 9 pulse") == nil)
  #expect(Command("reset 9") == nil)
  #expect(Command("reset 9 on") == nil)
  #expect(Command("reset x assert") == nil)
  #expect(Command("reset -1 assert") == nil)
  #expect(Command("clock 9 assert") == nil)
  #expect(Command("reset 9 assert now") == nil)
  #expect(Command("reset 9 pulse 20")?.description == "reset 9 pulse 20")
  #expect(Command("reset 9 deassert")?.description == "reset 9 deassert")
}

@Test func theControllersAreFoundByTheirBase() {
  #expect(Controller(base: 0x1600_0000) == .s5)
  #expect(Controller(base: 0x0416_0000) == .fch)
  #expect(Controller(base: 0x0416_0100) == nil)
  #expect(Controller.s5.hid == "CIXHA020" && Controller.fch.hid == "CIXHA021")
}

@Test func theS5IndicesAreTheSpecsMap() {
  let s5 = Controller.s5
  // Annex A, its first and last line of each word.
  #expect(s5.line(0) == Line(register: 0x304, bit: 1))
  #expect(s5.line(1) == Line(register: 0x308, bit: 1))
  #expect(s5.line(2) == Line(register: 0x30C, bit: 1))
  #expect(s5.line(3) == Line(register: 0x400, bit: 1 << 0))  // DDRC
  #expect(s5.line(9) == Line(register: 0x400, bit: 1 << 6))  // GPU
  #expect(s5.line(19) == Line(register: 0x400, bit: 1 << 16))  // DPU_RESET0
  #expect(s5.line(23) == Line(register: 0x400, bit: 1 << 20))  // DPU_RESET4
  #expect(s5.line(29) == Line(register: 0x400, bit: 1 << 26))  // DP_PHY
  #expect(s5.line(30) == Line(register: 0x404, bit: 1 << 0))
  #expect(s5.line(44) == Line(register: 0x404, bit: 1 << 14))  // GMAC0
  #expect(s5.line(50) == Line(register: 0x404, bit: 1 << 20))
  #expect(s5.line(51) == Line(register: 0x408, bit: 1 << 0))
  #expect(s5.line(70) == Line(register: 0x408, bit: 1 << 19))
  #expect(s5.line(71) == Line(register: 0x40C, bit: 1 << 0))
  #expect(s5.line(90) == Line(register: 0x40C, bit: 1 << 19))
  #expect(s5.line(91) == Line(register: 0x800, bit: 1 << 0))
  #expect(s5.line(122) == Line(register: 0x800, bit: 1 << 31))
  #expect(s5.line(123) == Line(register: 0x804, bit: 1 << 0))
  #expect(s5.line(142) == Line(register: 0x804, bit: 1 << 19))
  #expect(s5.line(143) == nil)
  #expect(s5.line(UInt32.max) == nil)
}

@Test func theFCHIndicesAreTheSpecsTable() {
  let f = Controller.fch
  #expect(f.line(0) == Line(register: 0x008, bit: 1 << 0))
  #expect(f.line(7) == Line(register: 0x008, bit: 1 << 7))
  #expect(f.line(8) == Line(register: 0x008, bit: 1 << 20))
  #expect(f.line(9) == Line(register: 0x00C, bit: 1 << 0))
  #expect(f.line(11) == Line(register: 0x00C, bit: 1 << 2))
  #expect(f.line(12) == Line(register: 0x00C, bit: 1 << 4))
  #expect(f.line(15) == Line(register: 0x00C, bit: 1 << 7))
  #expect(f.line(16) == Line(register: 0x00C, bit: 1 << 8))
  #expect(f.line(17) == Line(register: 0x00C, bit: 1 << 9))
  #expect(f.line(18) == Line(register: 0x00C, bit: 1 << 12))  // I2C0 APB
  #expect(f.line(25) == Line(register: 0x00C, bit: 1 << 19))
  #expect(f.line(26) == Line(register: 0x00C, bit: 1 << 21))  // GPIO APB
  #expect(f.line(27) == Line(register: 0x010, bit: 1 << 0))
  #expect(f.line(28) == Line(register: 0x010, bit: 1 << 1))
  #expect(f.line(29) == nil)
}

@Test func everyLineIsOneBitAndNoTwoShareOne() {
  for c in [Controller.s5, .fch] {
    var seen: [(Int, UInt32)] = []
    for i in 0..<UInt32(c.count) {
      let l = c.line(i)!
      #expect(l.bit.nonzeroBitCount == 1)
      #expect(l.register + 4 <= c.size)
      #expect(!seen.contains { $0.0 == l.register && $0.1 == l.bit })
      seen.append((l.register, l.bit))
    }
  }
}

@Test func aChangeTouchesOneBitAndIsActiveLow() {
  let gpu = Controller.s5.line(9)!
  let word: UInt32 = 0x1234_5678 | gpu.bit
  // Released reads 1; asserted clears that bit alone.
  #expect(!isAsserted(word, gpu))
  let held = changed(word, gpu, asserted: true)
  #expect(held == word & ~(1 << 6))
  #expect(isAsserted(held, gpu))
  #expect(changed(held, gpu, asserted: false) == word)
  // Asserting a held line, or releasing a released one, changes nothing.
  #expect(changed(held, gpu, asserted: true) == held)
  #expect(changed(word, gpu, asserted: false) == word)
  // Every other bit survives, whatever they are.
  for w in [UInt32(0), 0xFFFF_FFFF, 0xA5A5_A5A5] {
    #expect(changed(w, gpu, asserted: true) | gpu.bit == w | gpu.bit)
    #expect(changed(w, gpu, asserted: false) & ~gpu.bit == w & ~gpu.bit)
  }
}

@Test func aConsumersLinkNamesTheCommandsItsProviderTakes() throws {
  // Its /dev/acpi/links as devmgr gives them: the GPU's RSTL.
  let links = ProvidedLink.parse("""
    reset gpu_reset sky1-reset-CIXHA020 9
    reset gpu_rcsu_reset sky1-reset-CIXHA020 119
    clock gpu_clk_core - 31
    """)
  let gpu = try #require(links.first { $0.isKind("reset") && $0.name == "gpu_reset" })
  #expect(gpu.provider == "sky1-reset-CIXHA020")
  #expect(gpu.pulsing(microseconds: 20) == "reset 9 pulse 20")
  #expect(gpu.enabling == "reset 9 deassert")
  #expect(Command(gpu.pulsing(microseconds: 20)!) == .pulse(9, microseconds: 20))
  #expect(Command(gpu.enabling!) == .deassert(9))
  #expect(links[2].pulsing(microseconds: 20) == nil)
}
