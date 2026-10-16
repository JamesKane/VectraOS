// SPDX-License-Identifier: BSD-3-Clause

// Building ACPI tables and AML for tests: our own encoder, so the
// synthetic tests need no compiler and no third-party tables.

import TDACPI

func le(_ v: UInt64, _ bytes: Int) -> [UInt8] { (0..<bytes).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) } }

/// A table: the header (signature, revision, OEM fields) then `body`, with
/// the length and checksum filled in.
func table(_ signature: String, revision: UInt8 = 2, _ body: [UInt8]) -> [UInt8] {
  var t = Array(signature.utf8) + le(UInt64(36 + body.count), 4) + [revision, 0]
  t += Array("TDHCAI".utf8) + Array("TESTTBL ".utf8) + le(1, 4) + Array("TDAC".utf8) + le(1, 4)
  t += body
  t[9] = 0 &- t.reduce(0, &+)
  return t
}

/// An RSDP (revision 2) pointing at an RSDT and an XSDT.
func rsdp(rsdt: UInt32, xsdt: UInt64) -> [UInt8] {
  var r = Array("RSD PTR ".utf8) + [0] + Array("TDHCAI".utf8) + [2] + le(UInt64(rsdt), 4)
  r += le(36, 4) + le(xsdt, 8) + [0, 0, 0, 0]
  r[8] = 0 &- r[0..<20].reduce(0, &+)
  r[32] = 0 &- r.reduce(0, &+)
  return r
}
