// SPDX-License-Identifier: BSD-3-Clause

// Conversions (valhall 11c §11c.3 to §11c.6) and the special functions
// (§11c.7 to §11c.12) that are one instruction.
//
// PRECISION. Where the spec gives an error bound for a special function
// (`FRCP` below one unit in the last place, `FRSQ` at most one) or only
// calls it approximate, the interpreter returns the IEEE-correct result,
// computed in Double and rounded once; the hardware may differ from it by
// the bound. A test that compares a shader's output with the CPU's must
// allow `Tolerance`. For the half-precision `FLOG`, `FEXP` and `FPOW` the
// spec gives no bound; `Tolerance.f16Ulps` is a guess to be replaced by
// what the board shows.
//
// Not modelled (no semantics in the spec): `FPCLASS`, `FRCBRT_*`,
// `FSINCOS_OFFSET`, `FLOG_TABLE`, `FATAN_*`, `FPOW_SC_*`, `FRCP_APPROX`,
// `FRSQ_APPROX`, the arch 10 only forms.

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// How far the hardware's special functions may stray from the interpreter's exact results, in units
/// in the last place of the result's format (11c §11c.8.1, §11c.13.13).
public enum Tolerance {
  public static let frcpUlps = 1
  public static let frsqUlps = 2
  /// The sequences built on `FLOGD`, `FEXP`, the table lookups (11c §11c.13.13), as a count of ulps.
  public static let sequenceUlps = 4
  public static let f16Ulps = 2
}

extension Executor {
  func execConvert(_ w: Warp, _ lane: Int, _ ins: Instr) throws {
    let raw = try src32(w, lane, ins, ins.s0)
    switch ins.op {
    case .s8ToS32, .u8ToU32:
      let v = element(UInt64(raw), shift: 8 * Int(ins.widen0 & 3), bits: 8, signed: ins.op == .s8ToS32)
      try writeDst(w, lane, ins, UInt32(truncatingIfNeeded: v))
    case .s16ToS32, .u16ToU32:
      let v = element(UInt64(raw), shift: 16 * Int(ins.widen0 & 1), bits: 16, signed: ins.op == .s16ToS32)
      try writeDst(w, lane, ins, UInt32(truncatingIfNeeded: v))
    case .v2s8ToV2s16, .v2u8ToV2u16:
      // The field is (byte for lane 0) + 4 x (byte for lane 1) (11c §11c.3.2).
      let signed = ins.op == .v2s8ToV2s16
      let b0 = Int(ins.widen0 & 3)
      let b1 = Int((ins.widen0 >> 2) & 3)
      let l0 = element(UInt64(raw), shift: 8 * b0, bits: 8, signed: signed)
      let l1 = element(UInt64(raw), shift: 8 * b1, bits: 8, signed: signed)
      try writeDst(w, lane, ins, UInt32(truncatingIfNeeded: l0 & 0xFFFF) | UInt32(truncatingIfNeeded: l1 & 0xFFFF) << 16)
    case .s32ToF32, .u32ToF32:
      let v = try widen32(raw, ins.widen0, signed: ins.op == .s32ToF32)
      let r = FPFormat.f32.encode(Double(v), Round(rawValue: ins.round) ?? .nearestEven)
      try writeDst(w, lane, ins, r)
    case .f32ToS32, .f32ToU32:
      let a = fsrc(raw, widen: ins.widen0, neg: fbit(ins, ins.neg, 0), abs: fbit(ins, ins.abs, 0), flush: false)
      try writeDst(w, lane, ins, floatToInt(a, signed: ins.op == .f32ToS32, Round(rawValue: ins.round) ?? .nearestEven))
    case .f16ToF32:
      let h = (raw >> (16 * UInt32(ins.widen0 & 1))) & 0xFFFF
      var v = FPFormat.f32.encode(FPFormat.f16.decode(h), .nearestEven)
      if fbit(ins, ins.abs, 0) { v &= 0x7FFF_FFFF }
      if fbit(ins, ins.neg, 0) { v ^= 0x8000_0000 }
      try writeDst(w, lane, ins, v)
    default: throw Fault.invalid("\(ins.op) is not a conversion")
    }
  }

  /// Float to integer: rounded under `mode`, saturating, NaN to zero (11c §11c.5.1).
  func floatToInt(_ bits: UInt32, signed: Bool, _ mode: Round) -> UInt32 {
    let f = FPFormat.f32
    if f.isNaN(bits) { return 0 }
    let r = roundToIntegral(f.decode(bits), mode)
    if signed {
      if r >= 2147483648 { return UInt32(Int32.max) }
      if r <= -2147483648 { return UInt32(bitPattern: Int32.min) }
      return UInt32(bitPattern: Int32(r))
    }
    if r >= 4294967296 { return UInt32.max }
    if r <= 0 { return 0 }
    return UInt32(r)
  }

  // MARK: Special functions

  /// Table of sin(i pi / 32) as binary32, with the four signed zeros of 11c §11c.11.1.
  func sinCosTable(_ i: Int, isCos: Bool) -> UInt32 {
    if !isCos && i == 0 { return 0x8000_0000 }
    if !isCos && i == 32 { return 0 }
    if isCos && i == 16 { return 0 }
    if isCos && i == 48 { return 0x8000_0000 }
    let a = Double(i) * Double.pi / 32
    return FPFormat.f32.encode(isCos ? cos(a) : sin(a), .nearestEven)
  }

  func execSpecial(_ w: Warp, _ lane: Int, _ ins: Instr) throws {
    let f32 = FPFormat.f32
    let f16 = FPFormat.f16
    switch ins.op {
    case .frcp, .frsq:
      let rcp = ins.op == .frcp
      func eval(_ x: Double) -> Double {
        if x.isNaN { return .nan }
        if rcp { return 1 / x }
        if x == 0 { return x.sign == .minus ? -.infinity : .infinity }
        if x < 0 { return .nan }
        return 1 / x.squareRoot()
      }
      if ins.dataType == .f16 {
        let raw = try src32(w, lane, ins, ins.s0)
        let h = (raw >> (16 * UInt32(ins.widen0 & 1))) & 0xFFFF
        var v = h
        if fbit(ins, ins.abs, 0) { v &= 0x7FFF }
        if fbit(ins, ins.neg, 0) { v ^= 0x8000 }
        try writeHalf(w, lane, ins, UInt16(f16.encode(eval(f16.decode(v)), .nearestEven)))
      } else {
        // The f32 forms flush subnormal inputs and results (11c §11c.8.1).
        let a = try f32Operand(w, lane, ins, 0, flush: true)
        try writeDst(w, lane, ins, f32.flushed(f32.encode(eval(f32.decode(a)), .nearestEven)))
      }
    case .flogd:
      let a = f32.decode(try f32Operand(w, lane, ins, 0))
      var v: Double
      if a.isNaN || a < 0 { v = .nan } else if a == 0 || a.isInfinite { v = a == 0 ? .infinity : 0 } else {
        let m = reduced(a)
        v = m == 1 ? 1 / M_LN2 : log2(m) / (m - 1)
      }
      try writeDst(w, lane, ins, f32.encode(v, .nearestEven))
    case .flog:
      let raw = try src32(w, lane, ins, ins.s0)
      var h = (raw >> (16 * UInt32(ins.widen0 & 1))) & 0xFFFF
      if fbit(ins, ins.abs, 0) { h &= 0x7FFF }
      if fbit(ins, ins.neg, 0) { h ^= 0x8000 }
      try writeHalf(w, lane, ins, UInt16(f16.encode(log2(f16.decode(h)), .nearestEven)))
    case .fexp:
      if ins.dataType == .f16 {
        let raw = try src32(w, lane, ins, ins.s1)
        let h = (raw >> (16 * UInt32(ins.widen1 & 1))) & 0xFFFF
        try writeHalf(w, lane, ins, UInt16(f16.encode(exp2(f16.decode(h)), .nearestEven)))
      } else {
        let x = Int32(bitPattern: try src32(w, lane, ins, ins.s0))
        let s1 = try f32Operand(w, lane, ins, 1)
        if f32.isNaN(s1) { return try writeDst(w, lane, ins, f32.qnan) }
        try writeDst(w, lane, ins, f32.encode(exp2(Double(x) / 16777216), .nearestEven))
      }
    case .fpow:
      let a = try src32(w, lane, ins, ins.s0)
      let b = try src32(w, lane, ins, ins.s1)
      let x = f16.decode((a >> (16 * UInt32(ins.widen0 & 1))) & 0xFFFF)
      let y = f16.decode((b >> (16 * UInt32(ins.widen1 & 1))) & 0xFFFF)
      try writeHalf(w, lane, ins, UInt16(f16.encode(pow(x, y), .nearestEven)))
    case .frexpm, .frexpe:
      let a = try f32Operand(w, lane, ins, 0, flush: false)
      let (m, e) = frexp3(f32.decode(a), mode: ins.special)
      if ins.op == .frexpm {
        let src = f32.decode(a)
        try writeDst(w, lane, ins, src.isFinite && src != 0 ? f32.encode(m, .nearestEven) : a)
      } else {
        try writeDst(w, lane, ins, UInt32(bitPattern: ins.negResult ? -Int32(e) : Int32(e)))
      }
    case .fsinTable, .fcosTable:
      let b = try src32(w, lane, ins, ins.s0)
      if f32.isNaN(b) { return try writeDst(w, lane, ins, b) }
      if f32.isInf(b) { return try writeDst(w, lane, ins, f32.qnan) }
      let ok = b & 0x8000_0000 == 0 && (b >> 23) & 0xFF == 146
      try writeDst(w, lane, ins, ok ? sinCosTable(Int(b & 63), isCos: ins.op == .fcosTable) : 0x8000_0000)
    case .fexpTable:
      let b = try src32(w, lane, ins, ins.s0)
      try writeDst(w, lane, ins, f32.encode(exp2(Double(b & 15) / 16), .nearestEven))
    default: throw Fault.invalid("\(ins.op) is not a special function")
    }
  }

  /// `a` brought into [0.75, 1.5) by powers of two (the `log` split).
  func reduced(_ a: Double) -> Double { frexp3(a, mode: 2).0 }

  /// The fraction and exponent of `FREXPM`/`FREXPE` (11c §11c.7.1): `none` M in [0.5, 1), x = M 2^E;
  /// `sqrt` M in [0.25, 1), x = M 4^E'; `log` M in [0.75, 1.5), x = M 2^E. Zero, infinity and NaN give
  /// exponent 0 (the spec's inherited reading).
  func frexp3(_ x: Double, mode: UInt8) -> (Double, Int) {
    guard x.isFinite && x != 0 else { return (x, 0) }
    let ax = abs(x)
    var e = Int(ax.exponent) + 1  // ax = m * 2^e, m in [0.5, 1)
    var m = Double(sign: .plus, exponent: -e, significand: ax)
    if mode == 2 {
      if m < 0.75 { m *= 2; e -= 1 }
    } else if mode == 1 {
      let eh = (e + 1) >> 1  // floor((e + 1) / 2)
      m = Double(sign: .plus, exponent: e - 2 * eh, significand: m)
      e = eh
    }
    return (x < 0 ? -m : m, e)
  }
}
