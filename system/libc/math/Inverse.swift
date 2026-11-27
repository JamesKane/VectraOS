// SPDX-License-Identifier: BSD-3-Clause

// <math.h>'s inverse trigonometric functions: atan, atan2, asin and acos,
// from the published method. The argument is reduced by atan's addition
// formula, atan v = atan c + atan((v - c) / (1 + c·v)), about c = 0, 1/2,
// 1, 2 or ∞ (atan c from mathgen, as double-doubles), so the reduced
// argument t is within ±1/4, then the Taylor series t - t³/3 + t⁵/5 - …,
// its coefficients 1/(2k+1) exact rationals. The quotients are carried in
// double-double, so only the last rounding costs a whole half ulp. atan2
// takes |y|/|x| in double-double; asin and acos are atan2 of x and
// √(1 - x²), that root in double-double too. C23 Annex F's special cases
// (F.10.1). The float versions are the double ones rounded. Runtime-free.

/// atan(v + vLo) for v >= 0 (vLo below v's last place), as a double-double.
func atanDD(_ v: Double, _ vLo: Double) -> (Double, Double) {
  if v > 0x1p60 { return (MathConstants.halfPi, MathConstants.halfPiLo) }
  // atan v = k + atan t, t = n / d.
  var k = 0.0, kLo = 0.0
  var t = v, tLo = vLo
  if v >= 4 {
    k = MathConstants.halfPi
    kLo = MathConstants.halfPiLo
    (t, tLo) = divideDD(-1, 0, v, vLo)
  } else if v >= 0.25 {
    // c and atan c; v - c is exact (Sterbenz) in each range.
    let c: Double
    if v < 0.75 {
      c = 0.5
      k = MathConstants.atanHalf
      kLo = MathConstants.atanHalfLo
    } else if v < 4.0 / 3 {
      c = 1
      k = 0.5 * MathConstants.halfPi
      kLo = 0.5 * MathConstants.halfPiLo
    } else {
      c = 2
      k = MathConstants.atanTwo
      kLo = MathConstants.atanTwoLo
    }
    let (d, dLo) = twoSum(1, c * v)
    (t, tLo) = divideDD(v - c, vLo, d, dLo + c * vLo)
  }
  // |t| <= 1/4: the series to t^29, under 2^-57 of t past it.
  let z = t * t
  let p = -1.0 / 3 + z * (1.0 / 5 + z * (-1.0 / 7 + z * (1.0 / 9 + z * (-1.0 / 11 + z * (1.0 / 13
    + z * (-1.0 / 15 + z * (1.0 / 17 + z * (-1.0 / 19 + z * (1.0 / 21 + z * (-1.0 / 23 + z * (1.0 / 25
    + z * (-1.0 / 27 + z * (1.0 / 29)))))))))))))
  // atan(t + tLo) = atan t + tLo / (1 + t²).
  let tail = t * z * p + tLo * (1 - z)
  let (hi, lo) = twoSum(k, t)
  return twoSum(hi, lo + (kLo + tail))
}

public func atan(_ x: Double) -> Double {
  if x.isNaN { return x }
  if abs(x) < 0x1p-27 { return x }  // x³/3 is below half an ulp of x
  let (hi, lo) = atanDD(abs(x), 0)
  let a = hi + lo
  return x < 0 ? -a : a
}

/// The biased exponent of |x|'s bits (0 for zero and subnormals).
@inline(__always) func biasedExponent(_ x: Double) -> Int { Int(x.bitPattern >> 52 & 0x7FF) }

public func atan2(_ y: Double, _ x: Double) -> Double {
  if x.isNaN || y.isNaN { return x + y }
  let negativeY = y.sign == .minus, negativeX = x.sign == .minus
  let pi = 2 * MathConstants.halfPi, piLo = 2 * MathConstants.halfPiLo
  @inline(__always) func signed(_ v: Double) -> Double { negativeY ? -v : v }
  // Zeros and infinities (F.10.1.4).
  if y == 0 { return signed(negativeX ? pi : 0) }
  if x == 0 { return signed(MathConstants.halfPi) }
  if x.isInfinite {
    if y.isInfinite {
      if !negativeX { return signed(0.5 * MathConstants.halfPi) }
      let (h, l) = twoSum(MathConstants.halfPi, 0.5 * MathConstants.halfPi)
      return signed(h + (l + 1.5 * MathConstants.halfPiLo))
    }
    return signed(negativeX ? pi : 0)
  }
  if y.isInfinite { return signed(MathConstants.halfPi) }
  var ay = abs(y), ax = abs(x)
  let ey = biasedExponent(ay), ex = biasedExponent(ax)
  // atan(|y|/|x|), or π - it for negative x.
  var a: Double, aLo: Double
  if ey - ex > 60 {
    (a, aLo) = (MathConstants.halfPi, MathConstants.halfPiLo)
  } else if ex - ey > 60 {
    // |y|/|x| < 2^-59: atan is the quotient itself (it may underflow).
    if !negativeX { return signed(ay / ax) }
    (a, aLo) = (ay / ax, 0)
  } else {
    // Scale both into the range where Dekker's products are exact.
    if max(ey, ex) > 1023 + 900 {
      ay *= 0x1p-600
      ax *= 0x1p-600
    } else if min(ey, ex) < 1023 - 900 {
      ay *= 0x1p600
      ax *= 0x1p600
    }
    let (q, qLo) = divideDD(ay, 0, ax, 0)
    (a, aLo) = atanDD(q, qLo)
  }
  if negativeX {
    let (h, l) = twoSum(pi, -a)
    return signed(h + (l + (piLo - aLo)))
  }
  return signed(a + aLo)
}

/// √(1 - x²) for |x| < 1 as a double-double: 1 - x² exactly (Dekker's
/// square and a two-sum), its root, and the root's remainder halved.
@inline(__always) func cosineOfArcsine(_ x: Double) -> (Double, Double) {
  let (p, pLo) = twoProduct(x, x)
  let (s, e) = twoSum(1, -p)
  let w = s + (e - pLo)
  let wLo = (s - w) + (e - pLo)
  let r = w.squareRoot()
  let (rr, rrLo) = twoProduct(r, r)
  return (r, (((w - rr) - rrLo) + wLo) / (2 * r))
}

public func asin(_ x: Double) -> Double {
  if x.isNaN { return x }
  let ax = abs(x)
  if ax > 1 { return .nan }
  if ax < 0x1p-27 { return x }  // x³/6 is below half an ulp of x
  if ax == 1 { return x < 0 ? -MathConstants.halfPi : MathConstants.halfPi }
  // asin x = atan(x / √(1 - x²)).
  let (c, cLo) = cosineOfArcsine(ax)
  let (q, qLo) = divideDD(ax, 0, c, cLo)
  let (hi, lo) = atanDD(q, qLo)
  let a = hi + lo
  return x < 0 ? -a : a
}

public func acos(_ x: Double) -> Double {
  if x.isNaN { return x }
  let ax = abs(x)
  if ax > 1 { return .nan }
  if x == 1 { return 0 }
  if x == -1 { return 2 * MathConstants.halfPi }
  if ax < 0x1p-60 { return MathConstants.halfPi }  // π/2 - x rounds to π/2
  // acos x = atan(√(1 - x²) / x), or π - it for negative x.
  let (c, cLo) = cosineOfArcsine(ax)
  let (q, qLo) = divideDD(c, cLo, ax, 0)
  let (a, aLo) = atanDD(q, qLo)
  if x < 0 {
    let (h, l) = twoSum(2 * MathConstants.halfPi, -a)
    return h + (l + (2 * MathConstants.halfPiLo - aLo))
  }
  return a + aLo
}

public func atanf(_ x: Float) -> Float { Float(atan(Double(x))) }
public func atan2f(_ y: Float, _ x: Float) -> Float { Float(atan2(Double(y), Double(x))) }
public func asinf(_ x: Float) -> Float { Float(asin(Double(x))) }
public func acosf(_ x: Float) -> Float { Float(acos(Double(x))) }
