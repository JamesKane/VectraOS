// SPDX-License-Identifier: BSD-3-Clause

// What bin/sdhci computes without a controller: its commands' register
// values, the transfer mode, the card clock's divider, the ADMA2 table,
// and what it reads from a card's CSD and CID.

import SdHostController
import Testing

@Test func commandsCarryTheirResponsesChecks() {
  #expect(Sdhci.command(0, .none) == 0x0000)
  #expect(Sdhci.command(2, .long) == 0x0209)  // 136 bits, CRC
  #expect(Sdhci.command(8, .short) == 0x081A)  // 48 bits, CRC and index
  #expect(Sdhci.command(7, .busy) == 0x071B)
  #expect(Sdhci.command(41, .ocr) == 0x2902)  // neither check
  #expect(Sdhci.command(18, .short, data: true) == 0x123A)
}

@Test func moreThanOneBlockIsEndedByTheControllersCMD12() {
  #expect(Sdhci.transferMode(read: true, blocks: 1) == 0x13)  // DMA, count, read
  #expect(Sdhci.transferMode(read: true, blocks: 8) == 0x37)
  #expect(Sdhci.transferMode(read: false, blocks: 8) == 0x27)
}

@Test func theCardClockIsTheFastestAtMostTheTarget() {
  // Version 3 divides by 2N: 204.8 MHz to 400 kHz is N 256, to 25 MHz N 5
  // (20.48 MHz), to 50 MHz N 3 (34.1 MHz).
  #expect(Sdhci.divider(base: 204_800_000, target: 400_000, version: 2) == (0x0040, 400_000))
  #expect(Sdhci.divider(base: 204_800_000, target: 25_000_000, version: 2) == (0x0500, 20_480_000))
  #expect(Sdhci.divider(base: 204_800_000, target: 50_000_000, version: 2).hz == 34_133_333)
  // Version 2, by powers of two: QEMU's 52 MHz to 400 kHz is 256, to 25
  // MHz 4 (13 MHz).
  #expect(Sdhci.divider(base: 52_000_000, target: 400_000, version: 1) == (0x8000, 203_125))
  #expect(Sdhci.divider(base: 52_000_000, target: 25_000_000, version: 1) == (0x0200, 13_000_000))
  // A target at or above the base is the base itself.
  #expect(Sdhci.divider(base: 50_000_000, target: 50_000_000, version: 2) == (0, 50_000_000))
  // The capabilities' base clock: QEMU's default capabilities say 52 MHz.
  #expect(Sdhci.baseClock(0x0578_34B4, version: 1) == 52_000_000)
}

@Test func anADMA2TableCoversTheBufferInPieces() {
  let table = Sdhci.adma2(bus: 0x8000_0000, bytes: 0x18000)
  #expect(table.count == 3)
  #expect(table[0] == 0x8000_0000_8000_0021)  // valid, transfer, 32 KiB
  #expect(table[1] == 0x8000_8000_8000_0021)
  #expect(table[2] == 0x8001_0000_8000_0023)  // the end
  #expect(Sdhci.adma2(bus: 0x1000, bytes: 512) == [0x0000_1000_0200_0023])
}

/// An R2's four words as the controller keeps them: response bits 127:8
/// (the CSD's or CID's) shifted down 8.
func r2(_ bits: [(Int, Int, UInt64)]) -> [UInt32] {
  var words = [UInt32](repeating: 0, count: 4)
  for (high, low, value) in bits {
    for b in low...high where value >> UInt64(b - low) & 1 != 0 {
      words[(b - 8) / 32] |= 1 << UInt32((b - 8) % 32)
    }
  }
  return words
}

@Test func aCSDGivesTheCardsSectors() throws {
  // A high capacity card's: C_SIZE 15159 is 15160 x 512 KiB, a 7.4 GiB
  // card.
  let high = try #require(CSD(r2([(127, 126, 1), (69, 48, 15159)])))
  #expect(high.structure == 1 && high.sectors == 15160 * 1024)
  // A standard one's: C_SIZE 4095, C_SIZE_MULT 7, READ_BL_LEN 9 is
  // 4096 x 512 x 512 bytes, 1 GiB.
  let standard = try #require(CSD(r2([(73, 62, 4095), (49, 47, 7), (83, 80, 9)])))
  #expect(standard.structure == 0 && standard.sectors == 2 * 1024 * 1024)
  #expect(CSD(r2([(127, 126, 2)])) == nil)
  #expect(CSD([0, 0]) == nil)
}

@Test func aCIDGivesItsProductName() {
  var bits: [(Int, Int, UInt64)] = []
  for (i, c) in "SD64G".utf8.enumerated() { bits.append((103 - 8 * i, 96 - 8 * i, UInt64(c))) }
  #expect(Sdhci.productName(r2(bits)) == "SD64G")
  #expect(Sdhci.productName([1]) == "")
}
