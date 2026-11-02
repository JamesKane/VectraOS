// SPDX-License-Identifier: BSD-3-Clause

// The K1's thermal sensor as bin/k1-tsensor drives it: the enable
// sequence's words, where each reading is, and what a reading means.

import K1Tsensor
import Testing

@Test func theEnableSequenceSetsItsBitsAndKeepsTheRest() {
  // The trim and software control fields cleared, power, temperature
  // mode, output select and automatic mode set; other bits kept.
  #expect(Tsensor.powered(0) == 0x0080_0089)
  #expect(Tsensor.powered(0x003C_0F00 | 1 << 30) == 0x0080_0089 | 1 << 30)
  #expect(Tsensor.modulatorAt24MHz(0xFFFF_FFFF) == 0xFFFF_3FFF)
  #expect(Tsensor.timing(0xAB12_3456) == 0xAB30_00FF)
  #expect(Tsensor.allEnabled(0x100) == 0x11F)
}

@Test func eachSensorsReadingIsHalfADataWord() {
  #expect([0, 1, 2, 3, 4].map { Tsensor.data($0).offset } == [0x20, 0x20, 0x24, 0x24, 0x28])
  #expect([0, 1, 2, 3, 4].map { Tsensor.data($0).shift } == [0, 16, 0, 16, 0])
  // Sensor 3 at 45 C (raw 323) and sensor 2 at 40 C (318), in one word.
  let word = UInt32(323) << 16 | 318
  #expect(Tsensor.celsius(3, word: word) == 45 && Tsensor.celsius(2, word: word) == 40)
}

@Test func aReadingNoDieCouldGiveIsNotReady() {
  #expect(Tsensor.celsius(raw: 278) == 0 && Tsensor.celsius(raw: 393) == 115)
  #expect(Tsensor.celsius(raw: 0) == nil && Tsensor.celsius(raw: 0xFFFF) == nil)
  #expect(Tsensor.celsius(raw: 238) == -40 && Tsensor.celsius(raw: 237) == nil)
  #expect(Tsensor.text([41, nil, 40, 45, 44]) == "0 41 soc\n1 - package\n2 40 gpu\n3 45 cluster0\n4 44 cluster1\n")
}
