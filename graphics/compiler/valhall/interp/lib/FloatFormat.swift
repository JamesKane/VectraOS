// SPDX-License-Identifier: BSD-3-Clause

// IEEE binary32 and binary16 arithmetic done exactly, for the float
// instructions of valhall 11a and 11c.
//
// Rounding modes (11a §11a.2.3) include directed ones that Swift's Float
// does not offer, and binary16 is not portable to every host. So results
// are computed on exact Doubles and rounded once, by integer arithmetic,
// into the destination format:
//   - a binary32 or binary16 product is exact in a Double (24 + 24 and
//     11 + 11 significand bits);
//   - a sum of two Doubles is made "round to odd" (the last significand bit
//     is forced on when the sum is inexact), which keeps every bit that
//     matters to a later rounding into a narrower format with any mode.
// NaN results are the canonical quiet NaN: the spec does not say what
// payload or sign a NaN carries (11a §11a.2.5), only that tests treat every
// NaN as equal.

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// Rounding mode of the 2-bit and 3-bit round fields (11a §11a.2.3; `nearestAway` is the 3-bit field's 4).
public enum Round: UInt8, Sendable {
  case nearestEven = 0, up = 1, down = 2, zero = 3, nearestAway = 4
}

/// A binary floating-point format by its field widths.
public struct FPFormat: Sendable {
  public let mant: Int
  public let expBits: Int
  public var bias: Int { (1 << (expBits - 1)) - 1 }
  public var width: Int { 1 + expBits + mant }
  public static let f32 = FPFormat(mant: 23, expBits: 8)
  public static let f16 = FPFormat(mant: 10, expBits: 5)

  var signBit: UInt32 { 1 << UInt32(width - 1) }
  var expMask: UInt32 { ((1 << UInt32(expBits)) - 1) << UInt32(mant) }
  var mantMask: UInt32 { (1 << UInt32(mant)) - 1 }
  var quietBit: UInt32 { 1 << UInt32(mant - 1) }
  public var qnan: UInt32 { expMask | quietBit }
  public var inf: UInt32 { expMask }
  public var maxFinite: UInt32 { expMask - 1 }
  public var one: UInt32 { UInt32(bias) << UInt32(mant) }

  public func isNaN(_ b: UInt32) -> Bool { (b & expMask) == expMask && (b & mantMask) != 0 }
  public func isInf(_ b: UInt32) -> Bool { (b & ~signBit) == expMask }
  public func isSubnormal(_ b: UInt32) -> Bool { (b & expMask) == 0 && (b & mantMask) != 0 }
  public func isZero(_ b: UInt32) -> Bool { (b & ~signBit) == 0 }
  public func isNegative(_ b: UInt32) -> Bool { (b & signBit) != 0 }

  /// The exact value of `b`.
  public func decode(_ b: UInt32) -> Double {
    let neg = (b & signBit) != 0
    let e = Int((b & expMask) >> UInt32(mant))
    let m = Double(b & mantMask)
    let maxE = (1 << expBits) - 1
    var v: Double
    if e == maxE {
      v = m == 0 ? .infinity : .nan
    } else if e == 0 {
      v = Double(sign: .plus, exponent: 1 - bias - mant, significand: m)
    } else {
      v = Double(sign: .plus, exponent: e - bias - mant, significand: m + Double(1 << mant))
    }
    return neg ? -v : v
  }

  /// `d` rounded into this format under `mode`; overflow gives infinity, or the largest finite value
  /// where the mode rounds toward zero for that sign.
  public func encode(_ d: Double, _ mode: Round) -> UInt32 {
    if d.isNaN { return qnan }
    let neg = d.sign == .minus
    let sgn: UInt32 = neg ? signBit : 0
    let m = abs(d)
    if m.isInfinite { return sgn | inf }
    if m == 0 { return sgn }
    let emin = 1 - bias
    let e = Int(m.exponent)
    let sub = e < emin
    let quantumExp = (sub ? emin : e) - mant
    let q = Double(sign: .plus, exponent: -quantumExp, significand: m)
    var n = UInt64(q.rounded(.towardZero))
    let frac = q - Double(n)
    if frac > 0 {
      let inc: Bool
      switch mode {
      case .nearestEven: inc = frac > 0.5 || (frac == 0.5 && n & 1 == 1)
      case .nearestAway: inc = frac >= 0.5
      case .up: inc = !neg
      case .down: inc = neg
      case .zero: inc = false
      }
      if inc { n += 1 }
    }
    var bits: UInt64
    if sub {
      bits = n
    } else {
      bits = (UInt64(e + bias) << UInt64(mant)) &+ (n &- UInt64(1) << UInt64(mant))
    }
    if bits >= UInt64(expMask) {
      let towardZero = mode == .zero || (mode == .up && neg) || (mode == .down && !neg)
      return sgn | (towardZero ? maxFinite : inf)
    }
    return sgn | UInt32(bits)
  }

  /// Subnormals become a zero of the same sign.
  public func flushed(_ b: UInt32) -> UInt32 { isSubnormal(b) ? b & signBit : b }

  public func negated(_ b: UInt32) -> UInt32 { b ^ signBit }
  public func absolute(_ b: UInt32) -> UInt32 { b & ~signBit }
}

/// The sum of two finite Doubles, "round to odd".
func sumOdd(_ a: Double, _ b: Double) -> Double {
  let s = a + b
  guard s.isFinite else { return s }
  let bb = s - a
  let err = (a - (s - bb)) + (b - bb)
  if err == 0 { return s }
  if s.significandBitPattern & 1 == 0 { return err > 0 ? s.nextUp : s.nextDown }
  return s
}

/// `a + b` for operands already decoded from `fmt` (so exact in a Double), rounded once.
func fpAdd(_ a: Double, _ b: Double, _ fmt: FPFormat, _ mode: Round) -> UInt32 {
  guard a.isFinite && b.isFinite else { return fmt.encode(a + b, mode) }
  let s = sumOdd(a, b)
  if s == 0 { return zeroSum(a, b, fmt, mode) }
  return fmt.encode(s, mode)
}

/// `a * b + c`, one rounding (11a §11a.4). `a * b` is exact in a Double for either format.
func fpFma(_ a: Double, _ b: Double, _ c: Double, _ fmt: FPFormat, _ mode: Round) -> UInt32 {
  let p = a * b
  guard p.isFinite && c.isFinite && !a.isNaN && !b.isNaN else { return fmt.encode(p + c, mode) }
  let s = sumOdd(p, c)
  if s == 0 { return zeroSum(p, c, fmt, mode) }
  return fmt.encode(s, mode)
}

/// The sign of an exactly zero sum: that of both addends when they agree, else positive
/// (negative under round-down), 11a §11a.2.5.
private func zeroSum(_ a: Double, _ b: Double, _ fmt: FPFormat, _ mode: Round) -> UInt32 {
  let neg: Bool = a.sign == b.sign ? a.sign == .minus : mode == .down
  return neg ? fmt.signBit : 0
}

/// Clamp (11a §11a.2.4) applied to a result of `fmt`: NaN becomes the lower bound; zero keeps its sign
/// when it is not below the bound (the spec leaves the sign of a clamped zero open).
func fpClamp(_ b: UInt32, _ fmt: FPFormat, _ clamp: UInt8) -> UInt32 {
  if clamp == 0 { return b }
  let (lo, hi): (Double, Double) =
    switch clamp {
    case 1: (0, .infinity)
    case 2: (-1, 1)
    default: (0, 1)
    }
  let loBits = fmt.encode(lo, .nearestEven)
  if fmt.isNaN(b) { return loBits }
  let v = fmt.decode(b)
  if v < lo { return loBits }
  if v > hi { return fmt.encode(hi, .nearestEven) }
  return b
}

/// Integer result of rounding `x` under `mode` (for float to integer conversion, FROUND).
func roundToIntegral(_ x: Double, _ mode: Round) -> Double {
  switch mode {
  case .nearestEven: return x.rounded(.toNearestOrEven)
  case .nearestAway: return x.rounded(.toNearestOrAwayFromZero)
  case .up: return x.rounded(.up)
  case .down: return x.rounded(.down)
  case .zero: return x.rounded(.towardZero)
  }
}
