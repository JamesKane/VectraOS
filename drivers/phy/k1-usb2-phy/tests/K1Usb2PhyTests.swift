// SPDX-License-Identifier: BSD-3-Clause

// The K1's USB 2 PHY as bin/k1-usb2-phy drives it: the writes that turn
// it on once its PLL locks.

import K1Usb2Phy
import Testing

@Test func theUSB2PHYsWritesAreTheVendors() {
  let u = K1Usb2Phy.setup
  #expect(u.map(\.register) == [0x04, 0x34, 0xa4, 0x10])
  // Whole words for the first two, whatever was there.
  #expect(u[0].apply(0xFFFF_FFFF) == 0x60ef && u[1].apply(0) == 0x1c)
  // The transmitter's current: its four select bits 0xc and the enable,
  // the rest kept.
  #expect(u[2].apply(0x0000_0A0B) == 0x0000_0A1C)
  #expect(u[3].apply(0x0000_0001) == 0x0000_0005)
  #expect(u.allSatisfy { $0.register + 4 <= K1Usb2Phy.size })
}
