// SPDX-License-Identifier: BSD-3-Clause

// The GLSL.std.450 trigonometric and hyperbolic functions the IR has no operation for (Tan, Asin, Acos, Atan, Sinh, Cosh, Tanh,
// Asinh, Acosh, Atanh, Atan2), written out in the IR's own operations. The sequences follow valhall 11c.13.12 where it gives one
// (arctangent, two-argument arctangent, arcsine, arccosine), and the usual identities over the exponential and logarithm
// sequences of 11c.13.6 and 11c.13.7 for the rest, with a series near zero where the identity cancels. Everything is computed in
// binary32 (a binary16 operand is widened and the result rounded once).
//
// What each one measures against the correctly rounded result is in valhallbackend(2); the sweeps are in ValhallAluTests.

extension Lowerer {
  // MARK: small pieces

  private mutating func mfma(_ t: IRType, _ a: ValueID, _ b: ValueID, _ c: ValueID) -> ValueID { emit(.fma, t, [a, b, c]) }

  /// Horner's rule with fused multiply-adds: `c[0] + x * (c[1] + x * ...)` for coefficients lowest degree first.
  private mutating func horner(_ t: IRType, _ x: ValueID, _ c: [Double]) -> ValueID {
    var p = fc(t, c[c.count - 1])
    var k = c.count - 2
    while k >= 0 {
      p = mfma(t, p, x, fc(t, c[k]))
      k -= 1
    }
    return p
  }

  private mutating func copysignf(_ t: IRType, _ mag: ValueID, _ sign: ValueID) -> ValueID {
    let it = t.with(.i32)
    let m = emit(.and, it, [emit(.bitcast, it, [mag]), f.splat(it, 0x7FFF_FFFF)])
    let s = emit(.and, it, [emit(.bitcast, it, [sign]), f.splat(it, 0x8000_0000)])
    return emit(.bitcast, t, [emit(.or, it, [m, s])])
  }

  private mutating func cmpf(_ t: IRType, _ a: ValueID, _ b: ValueID, _ pred: Int) -> ValueID {
    emit(.fcmp, t.with(.bool), [a, b], imm: pred)
  }

  private mutating func sel(_ t: IRType, _ c: ValueID, _ a: ValueID, _ b: ValueID) -> ValueID { emit(.select, t, [c, a, b]) }

  private mutating func expf(_ t: IRType, _ x: ValueID) -> ValueID {
    emit(.fexp2, t, [emit(.fmul, t, [x, fc(t, 1.4426950408889634)])])
  }

  private mutating func logf(_ t: IRType, _ x: ValueID) -> ValueID {
    emit(.fmul, t, [emit(.flog2, t, [x]), fc(t, 0.6931471805599453)])
  }

  /// A NaN operand gives itself back through a select that a min or max may have lost.
  private mutating func keepNaN(_ t: IRType, _ x: ValueID, _ r: ValueID) -> ValueID {
    sel(t, cmpf(t, x, x, FCmpPred.ord), r, x)
  }

  /// The arctangent of any `t` (11c.13.12): `u = t` or `1/t`, the polynomial on `u*u`, the bias, the sign of `t`.
  private mutating func atanf(_ t: IRType, _ x: ValueID) -> ValueID {
    let ax = emit(.fabs, t, [x])
    let big = cmpf(t, ax, fc(t, 1), FCmpPred.ogt)
    let r = emit(.fdiv, t, [fc(t, 1), x])
    let u = sel(t, big, r, x)
    let w = emit(.fmul, t, [u, u])
    let p = horner(
      t, w,
      [
        0.9999793128310355, -0.3326756418091246, 0.1938924977115610, -0.1173503194786851, 0.0536813784310406,
        -0.0121323213173444,
      ])
    let au = emit(.fabs, t, [u])
    let bias = sel(t, big, fc(t, -1.5707963267948966), fc(t, 0))
    let sum = mfma(t, au, p, bias)
    return copysignf(t, emit(.fabs, t, [sum]), x)
  }

  /// The sine of x and the cosine, for the hyperbolic functions' sake: `sinh(x)` of any x.
  private mutating func sinhf(_ t: IRType, _ x: ValueID) -> ValueID {
    let ax = emit(.fabs, t, [x])
    let small = cmpf(t, ax, fc(t, 1), FCmpPred.olt)
    let x2 = emit(.fmul, t, [x, x])
    let poly = emit(.fmul, t, [x, horner(t, x2, [1, 1.0 / 6, 1.0 / 120, 1.0 / 5040, 1.0 / 362880, 1.0 / 39916800])])
    // e = e^|x| / 2; sinh = e - 1/(4e).
    let e = emit(.fexp2, t, [mfma(t, ax, fc(t, 1.4426950408889634), fc(t, -1))])
    let q = emit(.fdiv, t, [fc(t, 0.25), e])
    let large = copysignf(t, emit(.fsub, t, [e, q]), x)
    return keepNaN(t, x, sel(t, small, poly, large))
  }

  private mutating func coshf(_ t: IRType, _ x: ValueID) -> ValueID {
    let ax = emit(.fabs, t, [x])
    let e = emit(.fexp2, t, [mfma(t, ax, fc(t, 1.4426950408889634), fc(t, -1))])
    let q = emit(.fdiv, t, [fc(t, 0.25), e])
    return keepNaN(t, x, emit(.fadd, t, [e, q]))
  }

  /// `exp(x)`: exp2 of the product x * log2(e), whose rounding error (|y| half units of the last place of y, grown by the
  /// exponential) is carried through: the product's low part and the constant's, both exact with fused multiply-adds, scale
  /// the result. Within about a unit in the last place of the exp2 sequence instead of 0.35 |y| more.
  mutating func lowerExpAccurate(_ r: IRType, _ x0: ValueID) -> ValueID {
    let half = r.scalarKind == .f16
    let t = half ? r.with(.f32) : r
    let x = half ? emit(.fpext, t, [x0]) : x0
    let l = Double(Float(1.4426950408889634))
    let hi = emit(.fmul, t, [x, fc(t, l)])
    let lo = mfma(t, x, fc(t, l), emit(.fneg, t, [hi]))
    let c = mfma(t, x, fc(t, 1.4426950408889634 - l), lo)
    let e = emit(.fexp2, t, [hi])
    let corrected = mfma(t, e, emit(.fmul, t, [c, fc(t, 0.6931471805599453)]), e)
    let inRange = cmpf(t, emit(.fabs, t, [hi]), fc(t, 127), FCmpPred.olt)
    let res = sel(t, inRange, corrected, e)
    return half ? emit(.fptrunc, r, [res]) : res
  }

  /// `pow(x, y)` as exp2(y log2 x) (the definition Vulkan gives), with the product's rounding carried through like `exp`'s.
  mutating func lowerPowAccurate(_ r: IRType, _ x0: ValueID, _ y0: ValueID) -> ValueID {
    // A constant whole exponent from 1 to 128 is products, by squaring (pow(x, 2.0) is x * x, glmark2's pow(x, 100.0)
    // eight products): within pow's bounds wherever exp2(y log2 x) is defined (x > 0), and closer to x^y.
    if r.scalarKind == .f32, let lanes = constantLanes(f, y0), let b = lanes.first, lanes.allSatisfy({ $0 == b }) {
      let y = Float(bitPattern: UInt32(truncatingIfNeeded: b))
      if y >= 1, y <= 128, y == y.rounded(.towardZero) {
        var n = Int(y)
        var power = x0
        var result: ValueID = -1
        while n > 0 {
          if n & 1 == 1 { result = result < 0 ? power : emit(.fmul, r, [result, power]) }
          n >>= 1
          if n > 0 { power = emit(.fmul, r, [power, power]) }
        }
        return result
      }
    }
    let half = r.scalarKind == .f16
    let t = half ? r.with(.f32) : r
    let x = half ? emit(.fpext, t, [x0]) : x0
    let y = half ? emit(.fpext, t, [y0]) : y0
    let l = emit(.flog2, t, [x])
    let hi = emit(.fmul, t, [y, l])
    let lo = mfma(t, y, l, emit(.fneg, t, [hi]))
    let e = emit(.fexp2, t, [hi])
    let corrected = mfma(t, e, emit(.fmul, t, [lo, fc(t, 0.6931471805599453)]), e)
    let inRange = cmpf(t, emit(.fabs, t, [hi]), fc(t, 127), FCmpPred.olt)
    let res = sel(t, inRange, corrected, e)
    return half ? emit(.fptrunc, r, [res]) : res
  }

  /// `log(x)`: log2 times ln 2, in binary32 for a binary16 operand.
  mutating func lowerLogAccurate(_ r: IRType, _ x0: ValueID) -> ValueID {
    let half = r.scalarKind == .f16
    let t = half ? r.with(.f32) : r
    let x = half ? emit(.fpext, t, [x0]) : x0
    let res = emit(.fmul, t, [emit(.flog2, t, [x]), fc(t, 0.6931471805599453)])
    return half ? emit(.fptrunc, r, [res]) : res
  }

  // MARK: the instructions

  mutating func lowerMathExt(_ n: Int, _ a: [ValueID], _ r: IRType, _ name: String, _ i: SPIRVInstruction) throws(CompileError) -> ValueID? {
    guard (15...25).contains(n) else { return nil }
    guard let k = r.scalarKind, k == .f32 || k == .f16 else { throw fail(i, "GLSL.std.450 \(name) needs binary16 or binary32 operands") }
    let want = n == 25 ? 2 : 1
    guard a.count == want else { throw fail(i, "GLSL.std.450 \(name) takes \(want) operands") }
    for (j, v) in a.enumerated() where f.type(v) != r { throw fail(i, "operand \(j) has type \(f.type(v).name), expected \(r.name)") }
    let t = r.with(.f32)
    let x = k == .f16 ? emit(.fpext, t, [a[0]]) : a[0]
    var res: ValueID
    switch n {
    case 15:  // Tan: sin / cos
      res = emit(.fdiv, t, [emit(.fsin, t, [x]), emit(.fcos, t, [x])])
    case 16, 17:  // Asin, Acos
      res = arcsine(t, x, cosine: n == 17)
    case 18:  // Atan
      res = atanf(t, x)
    case 19: res = sinhf(t, x)
    case 20: res = coshf(t, x)
    case 21:  // Tanh: sinh over cosh, with the argument clamped so neither overflows (tanh(10) is 1 in binary32)
      let ax = emit(.fabs, t, [x])
      let c = copysignf(t, emit(.fmin, t, [ax, fc(t, 10)]), x)
      res = keepNaN(t, x, emit(.fdiv, t, [sinhf(t, c), coshf(t, c)]))
    case 22: res = asinhf(t, x)
    case 23: res = acoshf(t, x)
    case 24: res = atanhf(t, x)
    default:  // 25: Atan2(y, x)
      let y = k == .f16 ? emit(.fpext, t, [a[0]]) : a[0]
      let xx = k == .f16 ? emit(.fpext, t, [a[1]]) : a[1]
      res = atan2f(t, y, xx)
    }
    if k == .f16 { res = emit(.fptrunc, r, [res]) }
    return res
  }

  private mutating func atan2f(_ t: IRType, _ y: ValueID, _ x: ValueID) -> ValueID {
    let zero = fc(t, 0)
    let ax = emit(.fabs, t, [x])
    let flip = cmpf(t, x, zero, FCmpPred.ole)
    var s = sel(t, flip, ax, y)
    var d = sel(t, flip, y, ax)
    // Keep the reciprocal from flushing when |d| is huge.
    let huge = cmpf(t, emit(.fabs, t, [d]), fc(t, 1e18), FCmpPred.oge)
    s = sel(t, huge, emit(.fmul, t, [s, fc(t, 0.25)]), s)
    d = sel(t, huge, emit(.fmul, t, [d, fc(t, 0.25)]), d)
    let rd = emit(.fdiv, t, [fc(t, 1), d])
    var q = emit(.fmul, t, [emit(.fabs, t, [s]), emit(.fabs, t, [rd])])
    let same = cmpf(t, ax, emit(.fabs, t, [y]), FCmpPred.oeq)
    q = sel(t, same, fc(t, 1), q)
    let at = atanf(t, q)
    let withFlip = sel(t, flip, emit(.fadd, t, [at, fc(t, 1.5707963267948966)]), at)
    let smaller = emit(.fmin, t, [y, rd])
    let negative = cmpf(t, smaller, zero, FCmpPred.olt)
    return sel(t, negative, emit(.fneg, t, [withFlip]), withFlip)
  }

  /// Arcsine and arccosine (11c.13.12): the Abramowitz and Stegun polynomial for pi/2 - sqrt(1 - |x|) p, and for a small |x|
  /// the arcsine's series.
  private mutating func arcsine(_ t: IRType, _ x: ValueID, cosine: Bool) -> ValueID {
    let ax = emit(.fabs, t, [x])
    let p = horner(t, ax, [1.5707288, -0.2121144, 0.0742610, -0.0187293])
    let root = emit(.fsqrt, t, [emit(.fsub, t, [fc(t, 1), ax])])
    let mag = emit(.fsub, t, [fc(t, 1.5707963267948966), emit(.fmul, t, [root, p])])
    let a = copysignf(t, mag, x)
    if cosine { return emit(.fsub, t, [fc(t, 1.5707963267948966), a]) }
    let x2 = emit(.fmul, t, [x, x])
    let series = emit(.fmul, t, [x, mfma(t, x2, fc(t, 1.0 / 6), fc(t, 1))])
    let small = cmpf(t, ax, fc(t, 0.21502245), FCmpPred.olt)
    return sel(t, small, series, a)
  }

  private mutating func asinhf(_ t: IRType, _ x: ValueID) -> ValueID {
    let ax = emit(.fabs, t, [x])
    let x2 = emit(.fmul, t, [x, x])
    let series = emit(
      .fmul, t,
      [
        x,
        horner(
          t, x2,
          [1, -1.0 / 6, 3.0 / 40, -5.0 / 112, 35.0 / 1152, -63.0 / 2816, 231.0 / 13312]),
      ])
    let root = emit(.fsqrt, t, [mfma(t, ax, ax, fc(t, 1))])
    let general = logf(t, emit(.fadd, t, [ax, root]))
    // Beyond 4096, log(2|x|).
    let huge = emit(.fadd, t, [logf(t, ax), fc(t, 0.6931471805599453)])
    let big = cmpf(t, ax, fc(t, 4096), FCmpPred.ogt)
    let mag = sel(t, big, huge, general)
    let small = cmpf(t, ax, fc(t, 0.25), FCmpPred.olt)
    return keepNaN(t, x, sel(t, small, series, copysignf(t, mag, x)))
  }

  private mutating func acoshf(_ t: IRType, _ x: ValueID) -> ValueID {
    // Near 1, sqrt(2z) times a series in z = x - 1 (the logarithm's absolute error would swamp the result).
    let z = emit(.fsub, t, [x, fc(t, 1)])
    let two = emit(.fmul, t, [z, fc(t, 2)])
    let series = emit(
      .fmul, t,
      [
        emit(.fsqrt, t, [two]),
        horner(t, z, [1, -1.0 / 12, 3.0 / 160, -5.0 / 896, 35.0 / 18432, -63.0 / 90112, 231.0 / 851968, -143.0 / 1310720]),
      ])
    let root = emit(.fsqrt, t, [emit(.fmul, t, [z, emit(.fadd, t, [x, fc(t, 1)])])])
    let general = logf(t, emit(.fadd, t, [x, root]))
    let huge = emit(.fadd, t, [logf(t, x), fc(t, 0.6931471805599453)])
    let big = cmpf(t, x, fc(t, 4096), FCmpPred.ogt)
    let wide = sel(t, big, huge, general)
    let small = cmpf(t, x, fc(t, 1.25), FCmpPred.olt)
    return sel(t, small, series, wide)
  }

  private mutating func atanhf(_ t: IRType, _ x: ValueID) -> ValueID {
    let ax = emit(.fabs, t, [x])
    let x2 = emit(.fmul, t, [x, x])
    let series = emit(
      .fmul, t, [x, horner(t, x2, [1, 1.0 / 3, 1.0 / 5, 1.0 / 7, 1.0 / 9, 1.0 / 11, 1.0 / 13, 1.0 / 15])])
    let ratio = emit(.fdiv, t, [emit(.fadd, t, [fc(t, 1), x]), emit(.fsub, t, [fc(t, 1), x])])
    let general = emit(.fmul, t, [logf(t, ratio), fc(t, 0.5)])
    let small = cmpf(t, ax, fc(t, 0.25), FCmpPred.olt)
    return sel(t, small, series, general)
  }
}
