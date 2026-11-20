// SPDX-License-Identifier: BSD-3-Clause

// What the ISA tests share.

/// A word as 16 hex digits.
func hex16(_ v: UInt64) -> String {
  let h = String(v, radix: 16, uppercase: true)
  return "0x" + String(repeating: "0", count: 16 - h.count) + h
}
