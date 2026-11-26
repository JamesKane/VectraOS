// SPDX-License-Identifier: BSD-3-Clause

// <math.h>'s pow: |x|^y = e^(y·ln|x|), with ln|x| and the product carried
// in double-double (to about 2^-70 of ln|x|), so that y·ln|x|'s error,
// which e^ turns into a relative one, stays a small part of an ulp. ln
// is 2 atanh s, s = (m - 1)/(m + 1), as log's reduction has it, its
// first three terms in double-double; e^ is exp's reduction and series
// with the reduced argument's low part kept. C23 Annex F's special cases
// (F.10.4.4). powf is pow rounded. Runtime-free.

/// ln x for a finite x > 0 as a double-double.
func logDD(_ x: Double) -> (Double, Double) {
  var v = x
  var k = 0
  if v.bitPattern >> 52 == 0 {  // subnormal: scale up first
    v *= 0x1p54
    k = -54
  }
  k += Int(v.bitPattern >> 52) - 1023
  var m = Double(bitPattern: v.bitPattern & ((1 << 52) - 1) | (1023 << 52))
  if m > 1.4142135623730951 {
    m *= 0.5
    k += 1
  }
  // s = (m - 1)/(m + 1), |s| <= 0.172; m - 1 is exact (Sterbenz).
  let (d, dLo) = twoSum(m, 1)
  let (s, sLo) = divideDD(m - 1, 0, d, dLo)
  // s², s³ and s⁵ in double-double.
  let (z, zLo0) = twoProduct(s, s)
  let zLo = zLo0 + 2 * s * sLo
  let (c, cLo0) = twoProduct(z, s)
  let cLo = cLo0 + (z * sLo + zLo * s)
  let (f, fLo0) = twoProduct(c, z)
  let fLo = fLo0 + (c * zLo + cLo * z)
  // 2 atanh s = 2s + 2s³/3 + 2s⁵/5 + s⁷·(2/7 + 2s²/9 + …); the rest under
  // 2^-17 of the whole, so a double's rounding there is under 2^-70.
  let (t3, t3Lo) = divideDD(2 * c, 2 * cLo, 3, 0)
  let (t5, t5Lo) = divideDD(2 * f, 2 * fLo, 5, 0)
  let rest = f * z * (2.0 / 7 + z * (2.0 / 9 + z * (2.0 / 11 + z * (2.0 / 13 + z * (2.0 / 15 + z * (2.0 / 17
    + z * (2.0 / 19 + z * (2.0 / 21 + z * (2.0 / 23 + z * (2.0 / 25 + z * (2.0 / 27)))))))))))
  // Smallest first, into 2s's double-double.
  let small = t5 + (rest + (t5Lo + t3Lo))
  let (a, aLo) = twoSum(2 * s, t3)
  let (l, lLo) = twoSum(a, aLo + (small + 2 * sLo))
  // k ln 2: k × ln2Hi exactly, k × ln2Lo by Dekker's product.
  let dk = Double(k)
  let (b, bLo) = twoProduct(dk, MathConstants.ln2Lo)
  let (h, hLo) = twoSum(dk * MathConstants.ln2Hi, l)
  return twoSum(h, hLo + (lLo + (b + bLo)))
}

/// e^(w + wLo), wLo below w's last place, for w within exp's range.
func expDD(_ w: Double, _ wLo: Double) -> Double {
  if w > 709.782712893384 { return .infinity }
  if w < -745.1332191019412 { return 0 }
  let k = nearestInt(w * MathConstants.invLn2)
  let a = w - Double(k) * MathConstants.ln2Hi
  let b = Double(k) * MathConstants.ln2Lo
  let r = a - b
  let rLo = ((a - r) - b) + wLo
  // e^r = 1 + r + r²·p as 1 + (t + tLo), then e^rLo ≈ 1 + rLo.
  let p = 1.0 / 2 + r * (1.0 / 6 + r * (1.0 / 24 + r * (1.0 / 120 + r * (1.0 / 720 + r * (1.0 / 5040
    + r * (1.0 / 40320 + r * (1.0 / 362880 + r * (1.0 / 3628800 + r * (1.0 / 39916800 + r * (1.0 / 479001600
    + r * (1.0 / 6227020800)))))))))))
  let (t, tLo) = twoSum(r, r * r * p)
  let e = 1 + t
  let eLo = ((1 - e) + t) + tLo
  return ldexp(e + (eLo + e * rLo), Int32(k))
}

/// y is an integer: 0 even, 1 odd, nil neither (y finite).
@inline(__always) func integerParity(_ y: Double) -> Int? {
  if trunc(y) != y { return nil }
  if abs(y) >= 0x1p53 { return 0 }
  return Int(y) & 1
}

public func pow(_ x: Double, _ y: Double) -> Double {
  // F.10.4.4, in its order.
  if y == 0 || x == 1 { return 1 }
  if x.isNaN || y.isNaN { return x + y }
  let ax = abs(x)
  if y.isInfinite {
    if ax == 1 { return 1 }
    return (ax < 1) == (y < 0) ? .infinity : 0
  }
  let parity = integerParity(y)
  let oddY = parity == 1
  let negativeX = x.sign == .minus
  if x == 0 {
    let v: Double = y < 0 ? .infinity : 0
    return oddY && negativeX ? -v : v
  }
  if x.isInfinite {
    let v: Double = y < 0 ? 0 : .infinity
    return oddY && negativeX ? -v : v
  }
  if negativeX && parity == nil { return .nan }
  if ax == 1 { return oddY ? -1 : 1 }  // x = -1 (ln 0 would meet a huge y)
  let (l, lLo) = logDD(ax)
  // y·ln|x|: settled before the product if far outside exp's range (and
  // then no Dekker product can overflow).
  let p = y * l
  var r: Double
  if p > 800 {
    r = .infinity
  } else if p < -800 {
    r = 0
  } else {
    let (w, e) = twoProduct(y, l)
    let wLo = e + y * lLo
    let (wh, wl) = twoSum(w, wLo)
    r = expDD(wh, wl)
  }
  return oddY && negativeX ? -r : r
}

public func powf(_ x: Float, _ y: Float) -> Float { Float(pow(Double(x), Double(y))) }
