// SPDX-License-Identifier: BSD-3-Clause

// Base64 (RFC 4648 §4, with padding): SCRAM's salts, proofs and
// signatures. Decoding is strict: whole quanta, padding only at the end,
// no other characters.

enum Base64 {
  static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

  static func encode(_ bytes: [UInt8]) -> String {
    var out: [UInt8] = []
    var i = 0
    while i < bytes.count {
      let n = min(3, bytes.count - i)
      let v = UInt32(bytes[i]) << 16 | (n > 1 ? UInt32(bytes[i + 1]) << 8 : 0) | (n > 2 ? UInt32(bytes[i + 2]) : 0)
      for k in 0..<4 {
        out.append(k <= n ? alphabet[Int(v >> UInt32(18 - 6 * k) & 0x3F)] : UInt8(ascii: "="))
      }
      i += 3
    }
    return String(decoding: out, as: UTF8.self)
  }

  static func value(_ c: UInt8) -> UInt32? {
    switch c {
    case UInt8(ascii: "A")...UInt8(ascii: "Z"): UInt32(c - UInt8(ascii: "A"))
    case UInt8(ascii: "a")...UInt8(ascii: "z"): UInt32(c - UInt8(ascii: "a") + 26)
    case UInt8(ascii: "0")...UInt8(ascii: "9"): UInt32(c - UInt8(ascii: "0") + 52)
    case UInt8(ascii: "+"): 62
    case UInt8(ascii: "/"): 63
    default: nil
    }
  }

  /// The bytes, or nil if `text` isn't canonical base64.
  static func decode(_ text: some StringProtocol) -> [UInt8]? {
    let b = Array(text.utf8)
    guard b.count % 4 == 0 else { return nil }
    var out: [UInt8] = []
    var i = 0
    while i < b.count {
      let last = i + 4 == b.count
      let pad = last ? (b[i + 3] == UInt8(ascii: "=") ? (b[i + 2] == UInt8(ascii: "=") ? 2 : 1) : 0) : 0
      var v: UInt32 = 0
      for k in 0..<4 {
        if k >= 4 - pad {
          v <<= 6
          continue
        }
        guard let d = value(b[i + k]) else { return nil }
        v = v << 6 | d
      }
      out.append(UInt8(v >> 16))
      if pad < 2 { out.append(UInt8(truncatingIfNeeded: v >> 8)) }
      if pad < 1 { out.append(UInt8(truncatingIfNeeded: v)) }
      // Canonical: the padding's bits are zero.
      if pad == 2 && v & 0xFFFF != 0 || pad == 1 && v & 0xFF != 0 { return nil }
      i += 4
    }
    return out
  }
}
