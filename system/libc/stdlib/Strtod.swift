// SPDX-License-Identifier: BSD-3-Clause

// strtod, strtof (C23 §7.24.1.5, M6c) and strtold (M6d): the subject
// sequence (white space, a sign, then a decimal or hexadecimal floating
// constant, INF, INFINITY, NAN or NAN(chars)), converted correctly rounded:
// to nearest, ties to even, once (strtof isn't strtod's result rounded
// again). A decimal is D × 10^E with D's first significant digits kept (768
// for a double, 11600 for a long double) and the rest folded into a sticky
// bit (no halfway point between two values needs more), then:
//   - small exact cases (double's: D < 2^53, |E| <= 22) by one IEEE operation,
//   - E >= 0: the big integer D × 10^E, its top bits rounded,
//   - E < 0: the quotient of D × 2^k by 10^-E, 128 bits of it and whether a
//     remainder is left, rounded.
// Runtime-free: Big's fixed storage on the stack. No locale: "." is the
// point. A range error saturates (to infinity, or zero or a subnormal) and
// sets errno to ERANGE: on overflow, and on underflow when the result is
// subnormal or zero and inexact (as glibc does; C23 leaves underflow's
// errno to the implementation).

extension Big {
  /// The number of significant bits.
  var bitLength: Int {
    guard count > 0 else { return 0 }
    return (count - 1) * 32 + (32 - limbs[count - 1].leadingZeroBitCount)
  }

  /// -1, 0 or 1 as self is below, equal to or above `other`.
  func compare(_ other: Big) -> Int {
    if count != other.count { return count < other.count ? -1 : 1 }
    var i = count - 1
    while i >= 0 {
      if limbs[i] != other.limbs[i] { return limbs[i] < other.limbs[i] ? -1 : 1 }
      i -= 1
    }
    return 0
  }

  /// self -= other (other <= self).
  mutating func subtract(_ other: Big) {
    var borrow: Int64 = 0
    for i in 0..<count {
      var d = Int64(limbs[i]) - (i < other.count ? Int64(other.limbs[i]) : 0) - borrow
      borrow = 0
      if d < 0 {
        d += 1 << 32
        borrow = 1
      }
      limbs[i] = UInt32(d)
    }
    trim()
  }

  /// self × 10^n.
  mutating func multiplyByPowerOfTen(_ n: Int) {
    var left = n
    while left >= 9 {
      multiply(1_000_000_000)
      left -= 9
    }
    var p: UInt32 = 1
    for _ in 0..<left { p *= 10 }
    if p > 1 { multiply(p) }
  }

  /// self >>= 1.
  mutating func shiftRightOne() {
    guard count > 0 else { return }
    for i in 0..<count {
      limbs[i] = limbs[i] >> 1 | (i + 1 < count ? limbs[i + 1] << 31 : 0)
    }
    trim()
  }

  /// The top 128 bits (self's highest bit at bit 127 when bitLength >= 128,
  /// else self itself) and whether any bit below them is set.
  func top128() -> (bits: UInt128, sticky: Bool) {
    let n = bitLength
    if n <= 128 {
      var v: UInt128 = 0
      for i in stride(from: count - 1, through: 0, by: -1) { v = v << 32 | UInt128(limbs[i]) }
      return (v, false)
    }
    let shift = n - 128
    var v: UInt128 = 0
    for b in 0..<128 {
      let bit = shift + b
      if limbs[bit / 32] >> UInt32(bit % 32) & 1 == 1 { v |= UInt128(1) << UInt128(b) }
    }
    var sticky = false
    for bit in 0..<shift where limbs[bit / 32] >> UInt32(bit % 32) & 1 == 1 {
      sticky = true
      break
    }
    return (v, sticky)
  }
}

/// An IEEE binary format's shape, and its encoding: the significand's bits
/// (the leading one implicit, but stored in x87's extended format), the
/// biased exponent above them, the sign above that.
struct BinaryFormat {
  let mantissaBits: Int  // p, the leading bit included: 24, 53, 64 (x87's), 113
  let exponentBits: Int  // 8, 11, 15, 15
  let explicitLeadingBit: Bool  // x87's
  /// Bounds on n + E (D's n digits × 10^E) past which a number is infinite
  /// or zero, with room to spare: the conversion decides near them.
  let largestDecimal: Int
  let smallestDecimal: Int

  var maxExponent: Int { (1 << (exponentBits - 1)) - 1 }
  var minExponent: Int { 1 - maxExponent }  // the smallest normal's
  var exponentShift: Int { explicitLeadingBit ? mantissaBits : mantissaBits - 1 }
  var signBit: UInt128 { UInt128(1) << UInt128(exponentShift + exponentBits) }
  var infinity: UInt128 {
    UInt128(2 * maxExponent + 1) << UInt128(exponentShift)
      | (explicitLeadingBit ? UInt128(1) << UInt128(mantissaBits - 1) : 0)
  }
  var quietNaN: UInt128 { infinity | UInt128(1) << UInt128(mantissaBits - 2) }
}

/// The value bits × 2^lsbExponent (plus a sticky bit, set if anything below
/// them is nonzero), rounded to nearest, ties to even, once, in `format`:
/// the encoding's bits, sign apart. Too large is infinity, too small zero.
func assemble(_ bits: UInt128, sticky: Bool, lsbExponent: Int, _ format: BinaryFormat) -> UInt128 {
  var inexact = false
  return assemble(bits, sticky: sticky, lsbExponent: lsbExponent, format, inexact: &inexact)
}

/// The same, saying whether the result is inexact.
func assemble(_ bits: UInt128, sticky: Bool, lsbExponent: Int, _ format: BinaryFormat, inexact: inout Bool)
  -> UInt128
{
  inexact = sticky
  guard bits != 0 else { return 0 }
  let p = format.mantissaBits
  let leading = lsbExponent + (128 - bits.leadingZeroBitCount) - 1
  // The place of the result's lowest bit: p - 1 below the leading one, but
  // no lower than the smallest subnormal's.
  var target = max(leading - (p - 1), format.minExponent - (p - 1))
  let drop = target - lsbExponent
  var m: UInt128
  if drop <= 0 {
    m = bits << UInt128(-drop)  // exact (it fits: at most p bits)
  } else if drop > 128 {
    inexact = true
    return 0  // below half the smallest subnormal
  } else {
    m = drop == 128 ? 0 : bits >> UInt128(drop)
    let rest = drop == 128 ? bits : bits & ((UInt128(1) << UInt128(drop)) &- 1)
    if rest != 0 { inexact = true }
    let half = UInt128(1) << UInt128(drop - 1)
    if rest > half || (rest == half && (sticky || m & 1 == 1)) {
      m += 1
      if m >> UInt128(p) != 0 {  // a carry into a new bit
        m >>= 1
        target += 1
      }
    }
  }
  if m == 0 { return 0 }
  if m >> UInt128(p - 1) == 0 { return m }  // subnormal: biased exponent 0
  let exponent = target + p - 1
  if exponent > format.maxExponent {
    inexact = true
    return format.infinity
  }
  let stored = format.explicitLeadingBit ? m : m & ((UInt128(1) << UInt128(p - 1)) - 1)
  return UInt128(exponent + format.maxExponent) << UInt128(format.exponentShift) | stored
}

/// The conversion, with room for `digitCapacity` significant digits (no
/// halfway point between two values of the format needs more) over
/// Big<limbs>, which must hold D × 2^k beside 10^-E × 2^128.
enum FloatingParser<let digitCapacity: Int, let limbs: Int> {
  /// The value of the subject sequence at `s`, in `format`: the encoding's
  /// bits with the sign, and where the sequence ended (0 if there was none).
  static func parse(_ s: UnsafePointer<CChar>, _ format: BinaryFormat) -> (bits: UInt128, end: Int) {
    var i = 0
    while unsafe isSpace(byte(s, i)) { i += 1 }
    var negative = false
    if unsafe byte(s, i) == 0x2B || byte(s, i) == 0x2D {
      negative = unsafe byte(s, i) == 0x2D
      i += 1
    }
    let signBit = negative ? format.signBit : 0
    // INF, INFINITY, NAN, NAN(chars), any case.
    if unsafe matches(s, i, "inf") {
      let end = unsafe matches(s, i, "infinity") ? i + 8 : i + 3
      return (signBit | format.infinity, end)
    }
    if unsafe matches(s, i, "nan") {
      var end = i + 3
      if unsafe byte(s, end) == 0x28 {
        var j = end + 1
        while unsafe isAlphanumeric(byte(s, j)) || byte(s, j) == 0x5F { j += 1 }
        if unsafe byte(s, j) == 0x29 { end = j + 1 }
      }
      return (signBit | format.quietNaN, end)
    }
    // Hexadecimal: 0x, hex digits with a point, and an optional p exponent.
    if unsafe byte(s, i) == 0x30 && (byte(s, i + 1) | 0x20) == 0x78
      && (hexValue(byte(s, i + 2)) < 16 || (byte(s, i + 2) == 0x2E && hexValue(byte(s, i + 3)) < 16))
    {
      var j = i + 2
      var bits: UInt128 = 0, sticky = false, exponent = 0, any = false
      var seenPoint = false
      while true {
        let c = unsafe byte(s, j)
        if c == 0x2E && !seenPoint {
          seenPoint = true
          j += 1
          continue
        }
        let v = hexValue(c)
        guard v < 16 else { break }
        any = true
        if bits >> 124 == 0 {
          bits = bits << 4 | UInt128(v)
          if seenPoint { exponent -= 4 }
        } else {
          if v != 0 { sticky = true }
          if !seenPoint { exponent += 4 }
        }
        j += 1
      }
      guard any else { return (0, 0) }
      if unsafe (byte(s, j) | 0x20) == 0x70, let (e, end) = unsafe exponentPart(s, j + 1) {
        exponent += e
        j = end
      }
      return (signBit | ranged(bits, sticky: sticky, lsbExponent: exponent, format), j)
    }
    // Decimal: digits with a point, and an optional e exponent.
    var digits = InlineArray<digitCapacity, UInt8>(repeating: 0)
    var n = 0, truncated = false, decimalExponent = 0, any = false, seenPoint = false
    var j = i
    while true {
      let c = unsafe byte(s, j)
      if c == 0x2E && !seenPoint {
        seenPoint = true
        j += 1
        continue
      }
      guard c >= 0x30 && c <= 0x39 else { break }
      any = true
      if n == 0 && c == 0x30 {
        if seenPoint { decimalExponent -= 1 }  // a leading zero after the point
      } else if n < digitCapacity {
        digits[n] = c - 0x30
        n += 1
        if seenPoint { decimalExponent -= 1 }
      } else {
        if c != 0x30 { truncated = true }
        if !seenPoint { decimalExponent += 1 }
      }
      j += 1
    }
    guard any else { return (0, 0) }
    if unsafe (byte(s, j) | 0x20) == 0x65, let (e, end) = unsafe exponentPart(s, j + 1) {
      decimalExponent = decimalExponent + e
      j = end
    }
    if n == 0 { return (signBit, j) }  // zero
    // Out of any range: past the largest or below the smallest.
    if decimalExponent + n > format.largestDecimal {
      Errno.set(Errno.range)
      return (signBit | format.infinity, j)
    }
    if decimalExponent + n < format.smallestDecimal {
      Errno.set(Errno.range)
      return (signBit, j)
    }
    // Small and exact: one IEEE operation (double's format only).
    if format.mantissaBits == 53 && n <= 15 && !truncated && decimalExponent >= -22 && decimalExponent <= 22 {
      var d: Double = 0
      for k in 0..<n { d = d * 10 + Double(digits[k]) }
      var p: Double = 1
      for _ in 0..<(decimalExponent < 0 ? -decimalExponent : decimalExponent) { p *= 10 }
      let v = decimalExponent < 0 ? d / p : d * p
      return (signBit | UInt128(v.bitPattern), j)
    }
    var big = Big<limbs>()
    for k in 0..<n { big.multiply(10, add: UInt32(digits[k])) }
    if decimalExponent >= 0 {
      big.multiplyByPowerOfTen(decimalExponent)
      let (bits, sticky) = big.top128()
      let lsb = big.bitLength - (128 - bits.leadingZeroBitCount)
      return (signBit | ranged(bits, sticky: sticky || truncated, lsbExponent: lsb, format), j)
    }
    // D / 10^-E: shift D left by k so the quotient has 128 bits, divide.
    var divisor = Big<limbs>(1)
    divisor.multiplyByPowerOfTen(-decimalExponent)
    // D × 2^k / divisor has 128 or 129 bits: D shifted up, or (k < 0) the
    // divisor.
    let k = 128 + divisor.bitLength - big.bitLength
    if k > 0 { big.shiftLeft(k) } else if k < 0 { divisor.shiftLeft(-k) }
    // Long division, a quotient bit at a time from bit 128 down, the
    // divisor shifted down in place.
    divisor.shiftLeft(128)
    var top = false  // bit 128, if the quotient has it
    if big.compare(divisor) >= 0 {
      big.subtract(divisor)
      top = true
    }
    var quotient: UInt128 = 0
    var b = 127
    while b >= 0 {
      divisor.shiftRightOne()
      if big.compare(divisor) >= 0 {
        big.subtract(divisor)
        quotient |= UInt128(1) << UInt128(b)
      }
      b -= 1
    }
    var sticky = !big.isZero || truncated
    var lsbExponent = -k
    if top {
      // 129 bits: keep the top 128, the lowest one into the sticky bit.
      if quotient & 1 == 1 { sticky = true }
      quotient = quotient >> 1 | UInt128(1) << 127
      lsbExponent += 1
    }
    return (signBit | ranged(quotient, sticky: sticky, lsbExponent: lsbExponent, format), j)
  }

  /// assemble's result, with errno set to ERANGE when it overflowed, or
  /// underflowed: inexact, and subnormal or zero.
  static func ranged(_ bits: UInt128, sticky: Bool, lsbExponent: Int, _ format: BinaryFormat) -> UInt128 {
    var inexact = false
    let v = assemble(bits, sticky: sticky, lsbExponent: lsbExponent, format, inexact: &inexact)
    let field = v >> UInt128(format.exponentShift)
    if v == format.infinity || (inexact && field == 0) { Errno.set(Errno.range) }
    return v
  }
}

/// An exponent's digits after e or p: its value (saturated) and its end, or
/// nil if no digit follows (then the e or p isn't part of the number).
func exponentPart(_ s: UnsafePointer<CChar>, _ start: Int) -> (Int, Int)? {
  var i = start
  var negative = false
  if unsafe byte(s, i) == 0x2B || byte(s, i) == 0x2D {
    negative = unsafe byte(s, i) == 0x2D
    i += 1
  }
  guard unsafe byte(s, i) >= 0x30 && byte(s, i) <= 0x39 else { return nil }
  var v = 0
  while unsafe byte(s, i) >= 0x30 && byte(s, i) <= 0x39 {
    if v < 100_000 { v = v * 10 + Int(unsafe byte(s, i) - 0x30) }
    i += 1
  }
  return (negative ? -v : v, i)
}

func hexValue(_ c: UInt8) -> Int {
  switch c {
  case 0x30...0x39: Int(c - 0x30)
  case 0x41...0x46: Int(c - 0x41) + 10
  case 0x61...0x66: Int(c - 0x61) + 10
  default: 99
  }
}

func isAlphanumeric(_ c: UInt8) -> Bool { (c >= 0x30 && c <= 0x39) || (c | 0x20 >= 0x61 && c | 0x20 <= 0x7A) }

/// Whether `s` at `i` holds `word` (lowercase ASCII), in any case.
func matches(_ s: UnsafePointer<CChar>, _ i: Int, _ word: StaticString) -> Bool {
  for k in 0..<word.utf8CodeUnitCount where unsafe byte(s, i + k) | 0x20 != word.utf8Start[k] { return false }
  return true
}

// Double's and float's: 768 digits (a double's halfway points have up to
// 767 significant digits) over 128 limbs (10^(330 + 768) × 2^128 fits).
let doubleFormat = BinaryFormat(mantissaBits: 53, exponentBits: 11, explicitLeadingBit: false, largestDecimal: 310,
                                smallestDecimal: -330)
let floatFormat = BinaryFormat(mantissaBits: 24, exponentBits: 8, explicitLeadingBit: false, largestDecimal: 310,
                               smallestDecimal: -330)
typealias DoubleParser = FloatingParser<768, 128>

// Long double's (M6d): x87's 80-bit extended format on amd64, IEEE's
// binary128 on arm64 and rv64. 11600 digits (binary128's halfway points
// have up to 11564 significant digits, x87's 11516) over 1760 limbs
// (10^(4970 + 11600) × 2^128 fits).
let x87Format = BinaryFormat(mantissaBits: 64, exponentBits: 15, explicitLeadingBit: true, largestDecimal: 4940,
                             smallestDecimal: -4970)
let binary128Format = BinaryFormat(mantissaBits: 113, exponentBits: 15, explicitLeadingBit: false,
                                   largestDecimal: 4940, smallestDecimal: -4970)
typealias LongDoubleParser = FloatingParser<11600, 1760>

#if arch(x86_64)
let longDoubleFormat = x87Format
#else
let longDoubleFormat = binary128Format
#endif

public func strtod(_ s: UnsafePointer<CChar>, _ end: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Double {
  let (bits, e) = unsafe DoubleParser.parse(s, doubleFormat)
  if let end = unsafe end { unsafe end.pointee = UnsafeMutablePointer(mutating: s + e) }
  return Double(bitPattern: UInt64(truncatingIfNeeded: bits))
}

public func strtof(_ s: UnsafePointer<CChar>, _ end: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Float {
  let (bits, e) = unsafe DoubleParser.parse(s, floatFormat)
  if let end = unsafe end { unsafe end.pointee = UnsafeMutablePointer(mutating: s + e) }
  return Float(bitPattern: UInt32(truncatingIfNeeded: bits))
}

/// strtold's value as its encoding's bits (C's strtold, native/stdlib.c,
/// puts them in a long double: Swift has no binary128 type).
public func strtoldBits(_ s: UnsafePointer<CChar>, _ end: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?)
  -> UInt128
{ unsafe strtoldBits(s, end, longDoubleFormat) }

/// The same in either long double format (the tests take both).
func strtoldBits(_ s: UnsafePointer<CChar>, _ end: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
                 _ format: BinaryFormat) -> UInt128
{
  let (bits, e) = unsafe LongDoubleParser.parse(s, format)
  if let end = unsafe end { unsafe end.pointee = UnsafeMutablePointer(mutating: s + e) }
  return bits
}

public func atof(_ s: UnsafePointer<CChar>) -> Double { unsafe strtod(s, nil) }
