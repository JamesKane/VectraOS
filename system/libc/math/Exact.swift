// SPDX-License-Identifier: BSD-3-Clause

// <math.h>'s exact functions (M6c), from C23 §7.12 and IEEE 754-2019: the
// ones with one right answer. Rounding to integers (floor, ceil, trunc,
// round, rint and nearbyint in the default rounding mode, to nearest with
// ties to even), fmod and remainder (exact by definition), fma (rounded
// once), sqrt (the hardware's, correctly rounded), and the small ones:
// fabs, copysign, frexp, ldexp, modf. On bit patterns and integers only:
// Swift's rounding methods lower to these very functions where the target
// has no instruction for them. Generic over BinaryFloatingPoint's two
// formats, Double and Float.

/// A format's layout, for the bit-level work.
protocol IEEEFormat: BinaryFloatingPoint where RawSignificand: FixedWidthInteger, RawExponent: FixedWidthInteger {
  associatedtype Bits: FixedWidthInteger & UnsignedInteger
  static var fractionBits: Int { get }
  static var exponentBias: Int { get }
  var bits: Bits { get }
  init(bits: Bits)
}

extension Double: IEEEFormat {
  static var fractionBits: Int { 52 }
  static var exponentBias: Int { 1023 }
  var bits: UInt64 { bitPattern }
  init(bits: UInt64) { self.init(bitPattern: bits) }
}

extension Float: IEEEFormat {
  static var fractionBits: Int { 23 }
  static var exponentBias: Int { 127 }
  var bits: UInt32 { bitPattern }
  init(bits: UInt32) { self.init(bitPattern: bits) }
}

/// x rounded to an integer by `mode`: 0 toward zero, 1 down, 2 up, 3 to
/// nearest with ties away from zero, 4 to nearest with ties to even.
@inline(__always) func roundToIntegral<F: IEEEFormat>(_ x: F, _ mode: Int) -> F {
  let bits = x.bits
  let exponent = Int(truncatingIfNeeded: (bits >> F.Bits(F.fractionBits)) & F.Bits((1 << F.exponentBitCount) - 1))
    - F.exponentBias
  if exponent >= F.fractionBits { return x }  // already an integer (or inf, nan)
  let negative = bits >> F.Bits(F.Bits.bitWidth - 1) != 0
  let signBit = negative ? F.Bits(1) << F.Bits(F.Bits.bitWidth - 1) : 0
  if exponent < 0 {
    // |x| < 1: 0, or ±1 if it rounds away.
    let magnitude = bits & ~signBit
    if magnitude == 0 { return x }
    let one = F.Bits(F.exponentBias) << F.Bits(F.fractionBits)
    let up: Bool
    switch mode {
    case 1: up = negative
    case 2: up = !negative
    case 3: up = exponent == -1  // |x| >= 0.5
    case 4: up = exponent == -1 && magnitude != (F.Bits(F.exponentBias - 1) << F.Bits(F.fractionBits))  // > 0.5
    default: up = false
    }
    return F(bits: signBit | (up ? one : 0))
  }
  // Clear the fraction bits below the point; maybe add one unit.
  let below = F.fractionBits - exponent
  let mask = (F.Bits(1) << F.Bits(below)) &- 1
  let rest = bits & mask
  if rest == 0 { return x }
  var r = bits & ~mask
  let unit = F.Bits(1) << F.Bits(below)
  let half = unit >> 1
  let up: Bool
  switch mode {
  case 1: up = negative
  case 2: up = !negative
  case 3: up = rest >= half
  case 4: up = rest > half || (rest == half && r & unit != 0)
  default: up = false
  }
  if up { r &+= unit }  // a carry into the exponent is right: 1.11…1 → 10.0
  return F(bits: r)
}

public func floor(_ x: Double) -> Double { roundToIntegral(x, 1) }
public func floorf(_ x: Float) -> Float { roundToIntegral(x, 1) }
public func ceil(_ x: Double) -> Double { roundToIntegral(x, 2) }
public func ceilf(_ x: Float) -> Float { roundToIntegral(x, 2) }
public func trunc(_ x: Double) -> Double { roundToIntegral(x, 0) }
public func truncf(_ x: Float) -> Float { roundToIntegral(x, 0) }
public func round(_ x: Double) -> Double { roundToIntegral(x, 3) }
public func roundf(_ x: Float) -> Float { roundToIntegral(x, 3) }
public func roundeven(_ x: Double) -> Double { roundToIntegral(x, 4) }
public func roundevenf(_ x: Float) -> Float { roundToIntegral(x, 4) }
/// rint and nearbyint: the current rounding mode, which is always to
/// nearest, ties to even (no fenv here: the mode never changes).
public func rint(_ x: Double) -> Double { roundToIntegral(x, 4) }
public func rintf(_ x: Float) -> Float { roundToIntegral(x, 4) }
public func nearbyint(_ x: Double) -> Double { roundToIntegral(x, 4) }
public func nearbyintf(_ x: Float) -> Float { roundToIntegral(x, 4) }

public func fabs(_ x: Double) -> Double { Double(bitPattern: x.bitPattern & ~(1 << 63)) }
public func fabsf(_ x: Float) -> Float { Float(bitPattern: x.bitPattern & ~(1 << 31)) }
public func copysign(_ x: Double, _ y: Double) -> Double {
  Double(bitPattern: x.bitPattern & ~(1 << 63) | y.bitPattern & (1 << 63))
}
public func copysignf(_ x: Float, _ y: Float) -> Float {
  Float(bitPattern: x.bitPattern & ~(1 << 31) | y.bitPattern & (1 << 31))
}

public func sqrt(_ x: Double) -> Double { x.squareRoot() }  // the instruction: correctly rounded
public func sqrtf(_ x: Float) -> Float { x.squareRoot() }

/// x's significand in [0.5, 1) and its exponent (C's frexp).
public func frexp(_ x: Double, _ e: UnsafeMutablePointer<Int32>) -> Double {
  guard x.isFinite && x != 0 else {
    unsafe e.pointee = 0
    return x
  }
  var v = x
  var shift: Int32 = 0
  if v.bitPattern & 0x7FF0_0000_0000_0000 == 0 {  // subnormal: scale up first
    v = v * Double(bitPattern: 0x4350_0000_0000_0000)  // 2^54
    shift = -54
  }
  let field = Int32((v.bitPattern >> 52) & 0x7FF)
  unsafe e.pointee = field - 1022 + shift
  return Double(bitPattern: v.bitPattern & ~(UInt64(0x7FF) << 52) | UInt64(1022) << 52)
}

/// x × 2^n, rounded once (C's ldexp and scalbn).
public func ldexp(_ x: Double, _ n: Int32) -> Double {
  guard x.isFinite && x != 0 else { return x }
  var v = x
  var k = Int(n)
  // Scale in steps that can't overflow or round early: 2^1023 and 2^-969
  // (2^-1022 × 2^53, so a step down keeps the significand whole).
  while k > 1023 {
    v *= Double(bitPattern: 0x7FE0_0000_0000_0000)
    k -= 1023
    if !v.isFinite { return v }
  }
  while k < -1022 {
    v *= Double(bitPattern: 0x0360_0000_0000_0000)  // 2^-969
    k += 969
    if v == 0 { return v }
  }
  return v * Double(bitPattern: UInt64(k + 1023) << 52)
}

/// x's integer part in `i`, its fraction returned, both with x's sign.
public func modf(_ x: Double, _ i: UnsafeMutablePointer<Double>) -> Double {
  let t = trunc(x)
  unsafe i.pointee = t
  if x.isInfinite { return copysign(0, x) }
  return copysign(x - t, x)  // exact: x and t share the high bits
}

/// x - n × y for the n that is x / y rounded toward zero (fmod) or to nearest,
/// ties to even (remainder): exact, by long division on the significands.
@inline(__always) func remainderCore(_ x: Double, _ y: Double, nearest: Bool) -> Double {
  if x.isNaN || y.isNaN || x.isInfinite || y == 0 { return .nan }
  if y.isInfinite { return x }
  if x == 0 { return x }
  // Each as m × 2^e with m an integer (53 bits at most).
  func split(_ v: Double) -> (UInt64, Int) {
    let b = v.bitPattern & ~(UInt64(1) << 63)
    let field = Int(b >> 52)
    let f = b & ((1 << 52) - 1)
    return field == 0 ? (f, -1074) : (f | 1 << 52, field - 1075)
  }
  var (mx, ex) = split(x)
  let (my, ey) = split(y)
  // r = mx × 2^ex mod my × 2^ey, a bit of the quotient at a time.
  var q: UInt64 = 0  // the quotient's low bits (its parity is what nearest needs)
  if ex >= ey {
    var r = mx % my
    q = mx / my
    var e = ex
    while e > ey {
      // r < my < 2^53: shifting by up to 10 bits at a time stays in 64 bits.
      let step = min(e - ey, 10)
      r <<= UInt64(step)
      q = (q << UInt64(step)) &+ r / my
      r %= my
      e -= step
    }
    mx = r
    ex = ey
  }
  // (ex < ey: |x| < |y|, the quotient 0, r = |x|.)
  // r = mx × 2^ex: |x| mod |y| (0 <= r < |y|), exactly; q's parity kept.
  var r = Double(sign: .plus, exponent: ex, significand: 1) * Double(mx)
  if nearest {
    // To nearest: past half of |y|, or at half with q odd, take |y| off.
    let ay = Swift.abs(y)
    let twice = r + r
    if twice > ay || (twice == ay && q & 1 == 1) { r -= ay }
  }
  return x.sign == .minus ? -r : r
}

public func fmod(_ x: Double, _ y: Double) -> Double { remainderCore(x, y, nearest: false) }
public func remainder(_ x: Double, _ y: Double) -> Double { remainderCore(x, y, nearest: true) }
public func fmodf(_ x: Float, _ y: Float) -> Float { Float(remainderCore(Double(x), Double(y), nearest: false)) }
public func remainderf(_ x: Float, _ y: Float) -> Float { Float(remainderCore(Double(x), Double(y), nearest: true)) }

/// x × y + z rounded once (C's fma): the product exactly in 128 bits, the
/// sum exactly beside it, rounded by assemble's rule (Strtod.swift).
public func fma(_ x: Double, _ y: Double, _ z: Double) -> Double {
  // NaN, infinity and an exact zero product follow from IEEE's own rules;
  // a finite product (exact, so never infinite) with an infinite z is z.
  if x.isFinite && y.isFinite && z.isInfinite { return z }
  if !x.isFinite || !y.isFinite || !z.isFinite || x == 0 || y == 0 { return x * y + z }
  let (bits, negative) = exactSum(x, y, z, doubleFormat)
  return Double(bitPattern: bits | (negative ? 1 << 63 : 0))
}

/// fmaf: the same exact sum, rounded once to float (not to double first).
public func fmaf(_ x: Float, _ y: Float, _ z: Float) -> Float {
  if x.isFinite && y.isFinite && z.isInfinite { return z }
  if !x.isFinite || !y.isFinite || !z.isFinite || x == 0 || y == 0 { return x * y + z }
  let (bits, negative) = exactSum(Double(x), Double(y), Double(z), floatFormat)
  return Float(bitPattern: UInt32(truncatingIfNeeded: bits) | (negative ? 1 << 31 : 0))
}

/// (mx × my) × 2^(ex+ey) + mz × 2^ez, exactly, rounded once in `format`: its
/// encoding's bits, and the sign.
func exactSum(_ x: Double, _ y: Double, _ z: Double, _ format: BinaryFormat) -> (UInt64, Bool) {
  func split(_ v: Double) -> (UInt64, Int) {
    let b = v.bitPattern & ~(UInt64(1) << 63)
    let field = Int(b >> 52)
    let f = b & ((1 << 52) - 1)
    return field == 0 ? (f, -1074) : (f | 1 << 52, field - 1075)
  }
  let (mx, ex) = split(x), (my, ey) = split(y), (mz, ez) = split(z)
  let productNegative = (x.sign == .minus) != (y.sign == .minus)
  // The product: up to 106 bits.
  let p = mx.multipliedFullWidth(by: my)
  var pHigh = p.high, pLow = p.low
  var pExp = ex + ey
  var zHigh: UInt64 = 0, zLow = mz
  var zExp = ez
  if z == 0 {
    zLow = 0
    zExp = pExp
  }
  // Align both to the smaller exponent, keeping what falls far below as a
  // sticky bit (anything shifted past 192 bits can only break a tie).
  var sticky = false
  func shiftLeft(_ h: inout UInt64, _ l: inout UInt64, _ n: Int) {
    guard n > 0 else { return }
    if n >= 128 {
      h = 0
      l = 0
    } else if n >= 64 {
      h = l << UInt64(n - 64)
      l = 0
    } else {
      h = h << UInt64(n) | l >> UInt64(64 - n)
      l <<= UInt64(n)
    }
  }
  func shiftRight(_ h: inout UInt64, _ l: inout UInt64, _ n: Int, _ sticky: inout Bool) {
    guard n > 0 else { return }
    if n >= 128 {
      if h != 0 || l != 0 { sticky = true }
      h = 0
      l = 0
    } else if n >= 64 {
      if l != 0 || h & ((UInt64(1) << UInt64(n - 64)) &- 1) != 0 { sticky = true }
      l = h >> UInt64(n - 64)
      h = 0
    } else {
      if l & ((UInt64(1) << UInt64(n)) &- 1) != 0 { sticky = true }
      l = l >> UInt64(n) | h << UInt64(64 - n)
      h >>= UInt64(n)
    }
  }
  // Bring the one with the larger exponent down to the other's, shifting it
  // left while there is room (128 bits hold 106 + 21), else the smaller right.
  if pExp > zExp {
    let room = min(pExp - zExp, 128 - 106 - 1)  // a bit spare: the sum can carry
    shiftLeft(&pHigh, &pLow, room)
    pExp -= room
    if pExp > zExp { shiftRight(&zHigh, &zLow, pExp - zExp, &sticky) }
    zExp = pExp
  } else if zExp > pExp {
    let room = min(zExp - pExp, 128 - 53 - 2)
    shiftLeft(&zHigh, &zLow, room)
    zExp -= room
    if zExp > pExp { shiftRight(&pHigh, &pLow, zExp - pExp, &sticky) }
    pExp = zExp
  }
  let zNegative = z.sign == .minus
  // Add or subtract the magnitudes.
  var h: UInt64, l: UInt64
  var negative: Bool
  if productNegative == zNegative {
    let (sl, c) = pLow.addingReportingOverflow(zLow)
    l = sl
    h = pHigh &+ zHigh &+ (c ? 1 : 0)
    negative = productNegative
  } else {
    // The larger minus the smaller (a sticky bit belongs to the smaller).
    let pGreater = pHigh > zHigh || (pHigh == zHigh && pLow >= zLow)
    let (ah, al, bh, bl) = pGreater ? (pHigh, pLow, zHigh, zLow) : (zHigh, zLow, pHigh, pLow)
    let (dl, b) = al.subtractingReportingOverflow(bl)
    l = dl
    h = ah &- bh &- (b ? 1 : 0)
    if sticky {
      // The smaller had bits below: the difference is just under this, so
      // take one off and keep the sticky bit.
      let (dl2, b2) = l.subtractingReportingOverflow(1)
      l = dl2
      if b2 { h &-= 1 }
    }
    negative = pGreater ? productNegative : zNegative
  }
  if h == 0 && l == 0 && !sticky {
    // An exact zero: +0, but -0 if both were negative (round to nearest).
    return (0, productNegative && zNegative)
  }
  // Top 64 bits and a sticky bit, then assemble's rounding.
  var top: UInt64, lsb: Int
  if h != 0 {
    let lz = h.leadingZeroBitCount
    top = lz == 0 ? h : h << UInt64(lz) | l >> UInt64(64 - lz)
    let lostBits = lz == 0 ? l : l << UInt64(lz)
    if lostBits != 0 { sticky = true }
    lsb = pExp + 64 - lz
  } else {
    top = l
    lsb = pExp
  }
  return (UInt64(truncatingIfNeeded: assemble(UInt128(top), sticky: sticky, lsbExponent: lsb, format)), negative)
}
