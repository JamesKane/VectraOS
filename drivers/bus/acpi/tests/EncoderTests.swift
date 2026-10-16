// SPDX-License-Identifier: BSD-3-Clause

// The tests' AML encoder, against encodings worked out from ACPI 6.5 §20.2.

import Testing

@Test func packageLengthsCountTheirOwnBytes() {
  #expect(AML.pkgLength(0) == [0x01])
  #expect(AML.pkgLength(62) == [0x3F])  // 63 in one byte: the largest
  #expect(AML.pkgLength(63) == [0x41, 0x04])  // 65 = 0x41: lead 0x40 | 1, then 4
  #expect(AML.pkgLength(4093) == [0x4F, 0xFF])  // 4095: the largest in two
  #expect(AML.pkgLength(4094) == [0x81, 0x00, 0x01])  // 4097 = 0x1001: three bytes
  #expect(AML.pkgLength(0x0F_FFFC) == [0x8F, 0xFF, 0xFF])  // 2^20 - 1: the largest in three
  #expect(AML.pkgLength(0x0F_FFFD) == [0xC1, 0x00, 0x00, 0x01])  // 2^20 + 1: four
}

@Test func namesEncodeTheirPrefixesAndSegments() {
  #expect(AML.name("_SB") == Array("_SB_".utf8))
  #expect(AML.name("\\_SB.PCI0") == [0x5C, 0x2E] + Array("_SB_PCI0".utf8))
  #expect(AML.name("^^A.B.C") == [0x5E, 0x5E, 0x2F, 3] + Array("A___B___C___".utf8))
  #expect(AML.name("\\") == [0x5C, 0x00])
  #expect(AML.integer(0) == [0x00] && AML.integer(1) == [0x01] && AML.integer(.max) == [0xFF])
  #expect(AML.integer(0x1234) == [0x0B, 0x34, 0x12] && AML.integer(1 << 32) == [0x0E, 0, 0, 0, 0, 1, 0, 0, 0])
  // Name (_HID, EisaId ("PNP0A08")) as a compiler emits it: 0x080AD041.
  #expect(AML.nameObject("_HID", AML.integer(0x080A_D041)) == [0x08] + Array("_HID".utf8) + [0x0C, 0x41, 0xD0, 0x0A, 0x08])
}
