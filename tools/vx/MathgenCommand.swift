// SPDX-License-Identifier: BSD-3-Clause

// mathgen (M6c): the constants our libm needs, computed here rather than
// copied from anyone's: π by Machin's formula (π = 16 atan 1/5 - 4 atan
// 1/239), ln 2 = 2 atanh 1/3, ln 10 = 3 ln 2 + 2 atanh 1/9, each as a
// fixed-point integer of 1600 fraction bits, then 2/π by long division.
// From them, correctly rounded doubles and the splits argument reduction
// needs (Cody and Waite: a high part with trailing zeros, so k × high is
// exact, and the rest), and 2/π's first 1216 fraction bits for Payne and
// Hanek's reduction of large arguments. Writes
// system/libc/math/generated/Constants.swift:
//
//     .build/debug/vx mathgen system/libc/math/generated/Constants.swift
//
// A vx command (D11), lifted from todhchai's tools/mathgen.

import HostSystem

/// A non-negative big integer, little-endian 32-bit limbs.
private struct Big {
  var limbs: [UInt32]

  init(_ v: UInt64 = 0) { limbs = [UInt32(truncatingIfNeeded: v), UInt32(truncatingIfNeeded: v >> 32)]; trim() }
  init(powerOfTwo n: Int) {
    limbs = [UInt32](repeating: 0, count: n / 32 + 1)
    limbs[n / 32] = 1 << UInt32(n % 32)
  }

  mutating func trim() { while let last = limbs.last, last == 0 { limbs.removeLast() } }
  var isZero: Bool { limbs.isEmpty }
  var bitLength: Int { limbs.isEmpty ? 0 : (limbs.count - 1) * 32 + 32 - limbs.last!.leadingZeroBitCount }
  func bit(_ i: Int) -> Bool { i / 32 < limbs.count && limbs[i / 32] >> UInt32(i % 32) & 1 == 1 }

  static func + (a: Big, b: Big) -> Big {
    var r = Big()
    r.limbs = [UInt32](repeating: 0, count: max(a.limbs.count, b.limbs.count) + 1)
    var carry: UInt64 = 0
    for i in 0..<r.limbs.count {
      let s = UInt64(i < a.limbs.count ? a.limbs[i] : 0) + UInt64(i < b.limbs.count ? b.limbs[i] : 0) + carry
      r.limbs[i] = UInt32(truncatingIfNeeded: s)
      carry = s >> 32
    }
    r.trim()
    return r
  }

  /// a - b, b <= a.
  static func - (a: Big, b: Big) -> Big {
    var r = a
    var borrow: Int64 = 0
    for i in 0..<r.limbs.count {
      var d = Int64(r.limbs[i]) - Int64(i < b.limbs.count ? b.limbs[i] : 0) - borrow
      borrow = 0
      if d < 0 {
        d += 1 << 32
        borrow = 1
      }
      r.limbs[i] = UInt32(d)
    }
    r.trim()
    return r
  }

  static func * (a: Big, m: UInt32) -> Big {
    var r = Big()
    r.limbs = [UInt32](repeating: 0, count: a.limbs.count + 1)
    var carry: UInt64 = 0
    for i in 0..<a.limbs.count {
      let p = UInt64(a.limbs[i]) * UInt64(m) + carry
      r.limbs[i] = UInt32(truncatingIfNeeded: p)
      carry = p >> 32
    }
    r.limbs[a.limbs.count] = UInt32(carry)
    r.trim()
    return r
  }

  static func / (a: Big, d: UInt32) -> Big {
    var r = a
    var rem: UInt64 = 0
    for i in stride(from: r.limbs.count - 1, through: 0, by: -1) {
      let cur = rem << 32 | UInt64(r.limbs[i])
      r.limbs[i] = UInt32(cur / UInt64(d))
      rem = cur % UInt64(d)
    }
    r.trim()
    return r
  }

  func compare(_ b: Big) -> Int {
    if limbs.count != b.limbs.count { return limbs.count < b.limbs.count ? -1 : 1 }
    for i in stride(from: limbs.count - 1, through: 0, by: -1) where limbs[i] != b.limbs[i] {
      return limbs[i] < b.limbs[i] ? -1 : 1
    }
    return 0
  }

  func shifted(_ n: Int) -> Big {
    var r = Big()
    r.limbs = [UInt32](repeating: 0, count: limbs.count + n / 32 + 1)
    for i in 0..<bitLength where bit(i) { r.limbs[(i + n) / 32] |= 1 << UInt32((i + n) % 32) }
    r.trim()
    return r
  }

  /// floor(a / b), by long division a bit at a time.
  static func / (a: Big, b: Big) -> Big {
    var q = Big()
    q.limbs = [UInt32](repeating: 0, count: a.limbs.count + 1)
    var r = Big()
    for i in stride(from: a.bitLength - 1, through: 0, by: -1) {
      r = r.shifted(1)
      if a.bit(i) { r = r + Big(1) }
      if r.compare(b) >= 0 {
        r = r - b
        q.limbs[i / 32] |= 1 << UInt32(i % 32)
      }
    }
    q.trim()
    return q
  }
}

private let fraction = 1600
private let one = Big(powerOfTwo: fraction)

/// atan(1/n) or atanh(1/n) × 2^fraction: Σ ±1 / ((2k+1) n^(2k+1)).
private func series(_ n: UInt32, alternating: Bool) -> Big {
  var positive = Big(), negative = Big()
  var power = one / n  // 1 / n^(2k+1)
  var k: UInt32 = 0
  while !power.isZero {
    let term = power / (2 * k + 1)
    if alternating && k % 2 == 1 { negative = negative + term } else { positive = positive + term }
    power = power / (n * n)
    k += 1
  }
  return positive - negative
}

private let pi = series(5, alternating: true) * 16 - series(239, alternating: true) * 4
private let ln2 = series(3, alternating: false) * 2
private let ln10 = ln2 * 3 + series(9, alternating: false) * 2
/// 2/π × 2^(2 fraction) / (π × 2^fraction) = 2/π × 2^fraction.
private let twoOverPi = Big(powerOfTwo: 2 * fraction + 1) / pi

/// The double nearest value × 2^-fraction, keeping at most `bits`
/// significant bits (truncated, for a split's high part, or rounded).
private func double(_ v: Big, bits: Int = 53, round: Bool = true) -> Double {
  let length = v.bitLength
  guard length > 0 else { return 0 }
  var m: UInt64 = 0
  for i in 0..<bits { if v.bit(length - 1 - i) { m |= 1 << UInt64(bits - 1 - i) } }
  if round && v.bit(length - 1 - bits) {
    // Ties can't happen at these lengths for irrational constants.
    m += 1
  }
  return Double(sign: .plus, exponent: length - 1 - fraction - (bits - 1), significand: 1) * Double(m)
}

/// value - high, × 2^fraction, for a split's low part.
private func remainder(_ v: Big, minus high: Double) -> Big {
  // high = m × 2^e exactly: as a fixed-point integer.
  let e = high.exponent, m = UInt64(high.significandBitPattern | 1 << 52)
  var h = Big(m)
  h = h.shifted(fraction + Int(e) - 52)
  return v - h
}

private func hex(_ d: Double) -> String { "0x" + String(d.bitPattern, radix: 16, uppercase: true) }

/// Writes the constants to args[0] (default Constants.swift).
func mathgenCommand(_ args: [String]) -> Bool {
  var out = """
    // SPDX-License-Identifier: BSD-3-Clause

    // Generated by vx mathgen: constants for our libm (M6c), computed by
    // mathgen from series (π by Machin's formula, ln 2 and ln 10 from atanh),
    // not copied. Regenerate: .build/debug/vx mathgen system/libc/math/generated/Constants.swift

    enum MathConstants {

    """
  func emit(_ name: String, _ d: Double, _ what: String) {
    out += "  /// \(what) (\(d))\n  @inline(__always) static var \(name): Double { Double(bitPattern: \(hex(d))) }\n"
  }
  // Cody-Waite splits: highs with trailing zeros so k × high is exact.
  let ln2Hi = double(ln2, bits: 40, round: false)
  emit("ln2", double(ln2), "ln 2")
  emit("ln2Hi", ln2Hi, "ln 2's first 40 bits: k × ln2Hi is exact for |k| < 2^13")
  emit("ln2Lo", double(remainder(ln2, minus: ln2Hi)), "ln 2 - ln2Hi")
  emit("invLn2", double(one.shifted(fraction) / ln2), "1 / ln 2")
  emit("ln10", double(ln10), "ln 10")
  emit("log10e", double(one.shifted(fraction) / ln10), "log10 e = 1 / ln 10")
  let log10Of2 = ln2.shifted(fraction) / ln10
  let log10Of2Hi = double(log10Of2, bits: 40, round: false)
  emit("log10Of2Hi", log10Of2Hi, "log10 2's first 40 bits")
  emit("log10Of2Lo", double(remainder(log10Of2, minus: log10Of2Hi)), "log10 2 - log10Of2Hi")
  let halfPi = pi / 2
  let p1 = double(halfPi, bits: 33, round: false)
  let r1 = remainder(halfPi, minus: p1)
  let p2 = double(r1, bits: 33, round: false)
  emit("halfPi", double(halfPi), "π/2")
  emit("halfPi1", p1, "π/2's first 33 bits")
  emit("halfPi2", p2, "the next 33")
  emit("halfPi3", double(remainder(r1, minus: p2)), "the rest, rounded")
  emit("twoOverPiDouble", double(twoOverPi), "2/π")
  // 2/π's fraction bits (it is below 1: all of them fraction), 1216 of them,
  // most significant first, as hex digits.
  var bits = ""
  var nibble = 0, count = 0
  for i in 0..<1216 {
    let position = fraction - 1 - i
    nibble = nibble << 1 | (twoOverPi.bit(position) ? 1 : 0)
    count += 1
    if count == 4 {
      bits += String(nibble, radix: 16)
      nibble = 0
      count = 0
    }
  }
  out += """
      /// 2/π's first 1216 bits after the point, hex, most significant first
      /// (Payne-Hanek reduction of large arguments).
      static let twoOverPiBits: StaticString = "\(bits)"
    }

    """
  let path = args.first ?? "Constants.swift"
  guard (try? out.write(toFile: path, atomically: true, encoding: .utf8)) != nil else { return false }
  print("vx mathgen: wrote \(path)")
  return true
}
