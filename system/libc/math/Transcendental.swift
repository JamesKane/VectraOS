// SPDX-License-Identifier: BSD-3-Clause

// <math.h>'s exponentials, logarithms, sine and cosine (M6c), from the
// published methods: argument reduction (Cody and Waite's, with
// mathgen's splits of ln 2 and π/2; Payne and Hanek's for large
// arguments, over 2/π's bits) and series on the reduced argument, their
// coefficients 1/n! and 2/(2k+1) as the compiler rounds them exactly
// (n! is exact in a double this far). Within a unit in the last place of
// the true value: the tests measure it against glibc. The float versions
// are the double ones rounded. Runtime-free.

// MARK: exp, exp2

/// e^r for |r| <= ln2/2, by the series to r^13: 1 + (r + r²(1/2 + r(1/6 + …))).
@inline(__always) func expKernel(_ r: Double) -> Double {
  let p = 1.0 / 2 + r * (1.0 / 6 + r * (1.0 / 24 + r * (1.0 / 120 + r * (1.0 / 720 + r * (1.0 / 5040
    + r * (1.0 / 40320 + r * (1.0 / 362880 + r * (1.0 / 3628800 + r * (1.0 / 39916800 + r * (1.0 / 479001600
    + r * (1.0 / 6227020800)))))))))))
  return 1 + (r + r * r * p)
}

/// The nearest integer to t (|t| < 2^52), as an Int: t + 0.5 truncated, by sign.
@inline(__always) func nearestInt(_ t: Double) -> Int { t < 0 ? Int(t - 0.5) : Int(t + 0.5) }

public func exp(_ x: Double) -> Double {
  if x.isNaN { return x }
  if x > 709.782712893384 { return .infinity }
  if x < -745.1332191019412 { return 0 }
  if abs(x) < 0x1p-54 { return 1 + x }
  let k = nearestInt(x * MathConstants.invLn2)
  // r + rLo = x - k ln 2: x - k·ln2Hi is exact; k·ln2Lo's rounding goes to rLo.
  let a = x - Double(k) * MathConstants.ln2Hi
  let b = Double(k) * MathConstants.ln2Lo
  let r = a - b
  let rLo = (a - r) - b
  let e = expKernel(r)
  return ldexp(e + e * rLo, Int32(k))
}

public func exp2(_ x: Double) -> Double {
  if x.isNaN { return x }
  if x >= 1024 { return .infinity }
  if x < -1075 { return 0 }
  let k = nearestInt(x)
  let f = x - Double(k)  // exact, |f| <= 1/2
  // r + rLo = f × ln 2, the product exact (Dekker) and ln 2's own error
  // (ln2Hi + ln2Lo - ln2, the double) added.
  let (r, p) = twoProduct(f, MathConstants.ln2)
  let rLo = p + f * ((MathConstants.ln2Hi - MathConstants.ln2) + MathConstants.ln2Lo)
  let e = expKernel(r)
  return ldexp(e + e * rLo, Int32(k))
}

public func expf(_ x: Float) -> Float { Float(exp(Double(x))) }
public func exp2f(_ x: Float) -> Float { Float(exp2(Double(x))) }

// MARK: log, log2, log10

/// x = 2^k × (1 + f) with 1 + f in [√2/2, √2): k, f, and log(1 + f) - f's
/// correction, so that log(1 + f) = f - correction.
@inline(__always) func logReduce(_ x: Double) -> (k: Int, f: Double, correction: Double) {
  var v = x
  var k = 0
  if v.bitPattern >> 52 == 0 {  // subnormal: scale up first
    v *= 0x1p54
    k = -54
  }
  k += Int(v.bitPattern >> 52) - 1023
  // The significand in [1, 2), then into [√2/2, √2).
  var m = Double(bitPattern: v.bitPattern & ((1 << 52) - 1) | (1023 << 52))
  if m > 1.4142135623730951 {
    m *= 0.5
    k += 1
  }
  let f = m - 1  // exact (Sterbenz)
  let s = f / (2 + f)
  let z = s * s
  // R = 2z/3 + 2z²/5 + …: log(1+f) = 2 atanh(s) = 2s + s·R.
  let R = z * (2.0 / 3 + z * (2.0 / 5 + z * (2.0 / 7 + z * (2.0 / 9 + z * (2.0 / 11 + z * (2.0 / 13 + z * (2.0 / 15
    + z * (2.0 / 17 + z * (2.0 / 19 + z * (2.0 / 21 + z * (2.0 / 23 + z * (2.0 / 25))))))))))))
  let hfsq = 0.5 * f * f
  // log(1+f) = f - (hfsq - s·(hfsq + R)), since 2s + s·f = f.
  return (k, f, hfsq - s * (hfsq + R))
}

/// The special cases logarithms share: nil if x is an ordinary positive number.
@inline(__always) func logSpecial(_ x: Double) -> Double? {
  if x.isNaN { return x }
  if x < 0 { return .nan }
  if x == 0 { return -.infinity }
  if x.isInfinite { return x }
  return nil
}

public func log(_ x: Double) -> Double {
  if let s = logSpecial(x) { return s }
  let (k, f, c) = logReduce(x)
  let dk = Double(k)
  return dk * MathConstants.ln2Hi + (f - (c - dk * MathConstants.ln2Lo))
}

public func log2(_ x: Double) -> Double {
  if let s = logSpecial(x) { return s }
  let (k, f, c) = logReduce(x)
  // k + log(1+f)/ln 2, the small part scaled with 1/ln 2 in two pieces.
  let l = f - c
  let hi = Double(bitPattern: l.bitPattern & ~0xFFFF_FFFF)  // l's top bits: hi × invLn2Hi is exact
  let lo = (f - hi) - c
  let invHi = Double(bitPattern: MathConstants.invLn2.bitPattern & ~0xFFFF_FFFF)
  let invLo = MathConstants.invLn2 - invHi
  return Double(k) + (hi * invHi + (lo * MathConstants.invLn2 + hi * invLo))
}

public func log10(_ x: Double) -> Double {
  if let s = logSpecial(x) { return s }
  let (k, f, c) = logReduce(x)
  let dk = Double(k)
  let l = f - c
  let hi = Double(bitPattern: l.bitPattern & ~0xFFFF_FFFF)
  let lo = (f - hi) - c
  let eHi = Double(bitPattern: MathConstants.log10e.bitPattern & ~0xFFFF_FFFF)
  let eLo = MathConstants.log10e - eHi
  return dk * MathConstants.log10Of2Hi + (hi * eHi + (lo * MathConstants.log10e + hi * eLo + dk * MathConstants.log10Of2Lo))
}

public func logf(_ x: Float) -> Float { Float(log(Double(x))) }
public func log2f(_ x: Float) -> Float { Float(log2(Double(x))) }
public func log10f(_ x: Float) -> Float { Float(log10(Double(x))) }

// MARK: sin, cos

/// sin(r + rLo) for |r| <= π/4, rLo below r's last place.
@inline(__always) func sinKernel(_ r: Double, _ rLo: Double) -> Double {
  let z = r * r
  let p = -1.0 / 6 + z * (1.0 / 120 + z * (-1.0 / 5040 + z * (1.0 / 362880 + z * (-1.0 / 39916800
    + z * (1.0 / 6227020800 + z * (-1.0 / 1307674368000 + z * (1.0 / 355687428096000
    + z * (-1.0 / 121645100408832000 + z * (1.0 / 51090942171709440000)))))))))
  return r + (rLo + r * z * p)
}

/// cos(r + rLo) for |r| <= π/4.
@inline(__always) func cosKernel(_ r: Double, _ rLo: Double) -> Double {
  let z = r * r
  let p = 1.0 / 24 + z * (-1.0 / 720 + z * (1.0 / 40320 + z * (-1.0 / 3628800 + z * (1.0 / 479001600
    + z * (-1.0 / 87178291200 + z * (1.0 / 20922789888000 + z * (-1.0 / 6402373705728000
    + z * (1.0 / 2432902008176640000))))))))
  let hz = 0.5 * z
  let w = 1 - hz
  // 1 - hz loses hz's low bits: put them back, then the rest of the series.
  return w + (((1 - w) - hz) + (z * z * p - r * rLo))
}

/// x mod π/2: the quadrant (mod 4) and the remainder as r + rLo, |r| <= π/4.
func reduceHalfPi(_ x: Double) -> (n: Int, r: Double, rLo: Double) {
  let ax = abs(x)
  if ax < 0x1p19 {
    // Cody and Waite: n × the parts of π/2 are exact for n < 2^20.
    let n = nearestInt(x * MathConstants.twoOverPiDouble)
    let dn = Double(n)
    let a = x - dn * MathConstants.halfPi1
    let w = dn * MathConstants.halfPi2
    let r1 = a - w
    let lo1 = (a - r1) - w
    let w3 = dn * MathConstants.halfPi3
    let r = r1 - w3
    let rLo = ((r1 - r) - w3) + lo1
    return (n, r, rLo)
  }
  return payneHanek(x)
}

/// 2/π's bits from `start` (1 is the first after the point), 64 of them.
@inline(__always) func twoOverPiWord(_ start: Int) -> UInt64 {
  var w: UInt64 = 0
  let text = MathConstants.twoOverPiBits
  for b in 0..<64 {
    let i = start + b - 1  // 0-based bit index
    let nibble = i / 4
    var v: UInt64 = 0
    if nibble < text.utf8CodeUnitCount {
      let c = unsafe text.utf8Start[nibble]
      let d = c >= 0x61 ? UInt64(c - 0x61 + 10) : UInt64(c - 0x30)
      v = (d >> UInt64(3 - i % 4)) & 1
    }
    w = w << 1 | v
  }
  return w
}

/// Payne and Hanek: x × 2/π mod 4 from a 192-bit window of 2/π's bits, the
/// ones whose products with x aren't multiples of 4.
func payneHanek(_ x: Double) -> (n: Int, r: Double, rLo: Double) {
  let bits = x.bitPattern & ~(UInt64(1) << 63)
  let m = bits & ((1 << 52) - 1) | 1 << 52
  let e = Int(bits >> 52) - 1075  // x = m × 2^e
  let first = max(1, e - 1)
  let w0 = twoOverPiWord(first), w1 = twoOverPiWord(first + 64), w2 = twoOverPiWord(first + 128)
  // P = m × W, W = w0 w1 w2 (192 bits): 4 words, least significant first.
  let p2 = m.multipliedFullWidth(by: w2), p1 = m.multipliedFullWidth(by: w1), p0 = m.multipliedFullWidth(by: w0)
  let q0 = p2.low
  var q1 = p2.high, q2 = p1.high, q3 = p0.high
  var c: Bool
  (q1, c) = q1.addingReportingOverflow(p1.low)
  if c { (q2, c) = q2.addingReportingOverflow(1); if c { q3 &+= 1 } }
  (q2, c) = q2.addingReportingOverflow(p0.low)
  if c { q3 &+= 1 }
  // x × 2/π = P × 2^(e - first - 191): its integer part starts at bit s.
  let s = first + 191 - e
  // The integer part mod 4 and the 128 fraction bits below it.
  func bit(_ i: Int) -> UInt64 {
    guard i >= 0 else { return 0 }
    let word = i / 64, b = UInt64(i % 64)
    let v = word == 0 ? q0 : word == 1 ? q1 : word == 2 ? q2 : word == 3 ? q3 : 0
    return (v >> b) & 1
  }
  var n = Int(bit(s) | bit(s + 1) << 1)
  var fHi: UInt64 = 0, fLo: UInt64 = 0
  for i in 0..<64 { fHi = fHi << 1 | bit(s - 1 - i) }
  for i in 0..<64 { fLo = fLo << 1 | bit(s - 65 - i) }
  // Past one half: the next quadrant, and the fraction minus one (negative).
  var negative = false
  if fHi >> 63 == 1 {
    n += 1
    negative = true
    // 1 - f, as 128 bits.
    fLo = 0 &- fLo
    fHi = ~fHi &+ (fLo == 0 ? 1 : 0)
  }
  // The fraction as a double-double, times π/2 (in two parts).
  // (fHi's top 53 bits exactly, then the 11 below them and fLo.)
  let t = Double(fHi >> 11) * 0x1p-53
  let tLo = Double(fHi & 0x7FF) * 0x1p-64 + Double(fLo) * 0x1p-128
  let piHi = MathConstants.halfPi1 + MathConstants.halfPi2  // 66 bits rounded: the next part below covers it
  let piLo = (MathConstants.halfPi2 - (piHi - MathConstants.halfPi1)) + MathConstants.halfPi3
  // Products with Veltkamp splits, exactly.
  let (ph, pl) = twoProduct(t, piHi)
  let r = ph + (pl + (t * piLo + tLo * piHi))
  let rLo = (ph - r) + (pl + (t * piLo + tLo * piHi))
  let sign: Double = (x < 0) != negative ? -1 : 1
  let quadrant = x < 0 ? (4 - n % 4) % 4 : n % 4
  return (quadrant, sign * r, sign * rLo)
}

/// a × b = hi + lo exactly (Dekker, with Veltkamp's split: no fma).
@inline(__always) func twoProduct(_ a: Double, _ b: Double) -> (Double, Double) {
  let p = a * b
  let (ah, al) = split(a), (bh, bl) = split(b)
  let err = ((ah * bh - p) + ah * bl + al * bh) + al * bl
  return (p, err)
}

@inline(__always) func split(_ a: Double) -> (Double, Double) {
  let c = 134217729.0 * a  // 2^27 + 1
  let hi = c - (c - a)
  return (hi, a - hi)
}

public func sin(_ x: Double) -> Double {
  if !x.isFinite { return .nan }
  if abs(x) < 0x1p-26 { return x }
  let (n, r, rLo) = reduceHalfPi(x)
  switch n & 3 {
  case 0: return sinKernel(r, rLo)
  case 1: return cosKernel(r, rLo)
  case 2: return -sinKernel(r, rLo)
  default: return -cosKernel(r, rLo)
  }
}

public func cos(_ x: Double) -> Double {
  if !x.isFinite { return .nan }
  if abs(x) < 0x1p-27 { return 1 }
  let (n, r, rLo) = reduceHalfPi(x)
  switch n & 3 {
  case 0: return cosKernel(r, rLo)
  case 1: return -sinKernel(r, rLo)
  case 2: return -cosKernel(r, rLo)
  default: return sinKernel(r, rLo)
  }
}

public func sinf(_ x: Float) -> Float { Float(sin(Double(x))) }
public func cosf(_ x: Float) -> Float { Float(cos(Double(x))) }
