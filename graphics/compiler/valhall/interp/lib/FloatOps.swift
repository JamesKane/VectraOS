// SPDX-License-Identifier: BSD-3-Clause

// The float instructions of valhall 11a: FADD, FMA and their kin, min and
// max, compare and select, flush, round, scale.
//
// Choices where the spec is open (each is marked "open" in 11a):
//   - a narrowing destination (`h0`, `h1`) rounds once, from the exact result to binary16; `h01` writes
//     both halves; `h0`/`h1` of a `v2f16` op write the corresponding lane (11a §11a.2.6);
//   - clamping a zero keeps its sign unless the value is below the bound (§11a.2.4);
//   - `FMIN` of -0 and +0 gives -0, `FMAX` gives +0 (§11a.6);
//   - `FMA_RSCALE` rounds the scaled value once; mode `left` takes S0 as the product term (§11a.5);
//   - `LDEXP`'s infinity mode is ignored, a `v2f16` exponent is the lane's own 16-bit integer (§11a.12);
//   - flush-to-zero (the program descriptor's mode) flushes subnormal inputs and results of every
//     float instruction here but `FLUSH`, `FROUND` and the conversions.

extension Executor {
  // MARK: Operands

  func fbit(_ ins: Instr, _ field: UInt8, _ i: Int) -> Bool { field & (1 << UInt8(i)) != 0 }

  /// One 32-bit float source after widen (0 none, 1 `h0`, 2 `h1`), flush, `abs`, then `neg`.
  func fsrc(_ raw: UInt32, widen: UInt8, neg: Bool, abs: Bool, flush: Bool) -> UInt32 {
    var b: UInt32
    switch widen {
    case 1: b = FPFormat.f32.encode(FPFormat.f16.decode(raw & 0xFFFF), .nearestEven)
    case 2: b = FPFormat.f32.encode(FPFormat.f16.decode(raw >> 16), .nearestEven)
    default: b = raw
    }
    if flush { b = FPFormat.f32.flushed(b) }
    if abs { b &= 0x7FFF_FFFF }
    if neg { b ^= 0x8000_0000 }
    return b
  }

  /// The two half lanes of a `v2f16` source after swizzle (0 `h00`, 1 `h10`, 2 `h01`, 3 `h11`), flush, `abs`, `neg`.
  func hsrc(_ raw: UInt32, swz: UInt8, neg: Bool, abs: Bool, flush: Bool) -> (UInt32, UInt32) {
    let lo = raw & 0xFFFF
    let hi = raw >> 16
    var (a, b): (UInt32, UInt32)
    switch swz & 3 {
    case 0: (a, b) = (lo, lo)
    case 1: (a, b) = (hi, lo)
    case 2: (a, b) = (lo, hi)
    default: (a, b) = (hi, hi)
    }
    for i in 0..<2 {
      var v = i == 0 ? a : b
      if flush { v = FPFormat.f16.flushed(v) }
      if abs { v &= 0x7FFF }
      if neg { v ^= 0x8000 }
      if i == 0 { a = v } else { b = v }
    }
    return (a, b)
  }

  func f32Operand(_ w: Warp, _ lane: Int, _ ins: Instr, _ i: Int, flush: Bool? = nil) throws -> UInt32 {
    let byte = [ins.s0, ins.s1, ins.s2, ins.s3][i]
    let widen = [ins.widen0, ins.widen1, ins.widen2, 0][i]
    return fsrc(
      try src32(w, lane, ins, byte), widen: widen, neg: fbit(ins, ins.neg, i), abs: fbit(ins, ins.abs, i),
      flush: flush ?? cfg.flushDenormals)
  }

  func h2Operand(_ w: Warp, _ lane: Int, _ ins: Instr, _ i: Int, flush: Bool? = nil) throws -> (UInt32, UInt32) {
    let byte = [ins.s0, ins.s1, ins.s2, ins.s3][i]
    let widen = [ins.widen0, ins.widen1, ins.widen2, 0][i]
    return hsrc(
      try src32(w, lane, ins, byte), swz: widen, neg: fbit(ins, ins.neg, i), abs: fbit(ins, ins.abs, i),
      flush: flush ?? halfFlush)
  }

  var ftz: Bool { cfg.flushDenormals }
  /// Whether binary16 subnormals are flushed: with the program's flush mode 2 only (04 section 4.2.4.1: kept in modes 0 and 1).
  var halfFlush: Bool { cfg.flushHalves ?? cfg.flushDenormals }

  /// Final steps of a float result in `fmt`: flush, then clamp.
  func finish(_ b: UInt32, _ fmt: FPFormat, _ ins: Instr) -> UInt32 {
    var v = b
    if fmt.width == 16 ? halfFlush : ftz { v = fmt.flushed(v) }
    return fpClamp(v, fmt, ins.clamp)
  }

  /// Writes a binary32-source op's result: whole binary32, or narrowed to binary16 by the destination width.
  var narrowing: (Instr) -> Bool { { $0.dstWidth != 3 } }

  func roundMode(_ ins: Instr) -> Round { Round(rawValue: ins.round) ?? .nearestEven }

  // MARK: Compare

  func fpCompare(_ cmp: UInt8, _ a: UInt32, _ b: UInt32, _ fmt: FPFormat) -> Bool {
    let x = fmt.decode(a)
    let y = fmt.decode(b)
    switch cmp {
    case 0: return x == y
    case 1: return x > y
    case 2: return x >= y
    case 3: return x != y
    case 4: return x < y
    case 5: return x <= y
    case 6: return x < y || x > y
    default:
      // IEEE-754 total order: negative values order by descending magnitude (all NaNs at the ends).
      func key(_ v: UInt32) -> UInt32 { fmt.isNegative(v) ? ~v & (fmt.signBit | (fmt.signBit - 1)) : v | fmt.signBit }
      return key(a) <= key(b)
    }
  }

  /// The condition of `DISCARD` on raw 32-bit sources (13 §13.6.3).
  func fcmpTest(_ ins: Instr, a: UInt32, b: UInt32) -> Bool {
    let x = fsrc(a, widen: ins.widen0, neg: fbit(ins, ins.neg, 0), abs: fbit(ins, ins.abs, 0), flush: false)
    let y = fsrc(b, widen: ins.widen1, neg: fbit(ins, ins.neg, 1), abs: fbit(ins, ins.abs, 1), flush: false)
    return fpCompare(ins.cmp, x, y, .f32)
  }

  /// The value a compare writes for a true lane: integer 1, float 1.0 or all ones, in a lane of
  /// `bits` bits (11b §11b.1.6).
  func compareValue(_ type: UInt8, bits: Int) -> UInt32 {
    switch type {
    case 1: return bits == 16 ? 0x3C00 : bits == 8 ? 0x01 : 0x3F80_0000
    case 2: return bits == 32 ? 0xFFFF_FFFF : (1 << UInt32(bits)) - 1
    default: return 1
    }
  }

  // MARK: Dispatch of the float instructions

  func execFloat(_ w: Warp, _ lane: Int, _ ins: Instr) throws {
    switch ins.op {
    case .fadd, .faddLscale: try fAdd(w, lane, ins)
    case .faddImm: try fAddImm(w, lane, ins)
    case .fma: try fFma(w, lane, ins)
    case .fmaRscale: try fFmaRscale(w, lane, ins)
    case .fmin, .fmax: try fMinMax(w, lane, ins)
    case .fcmp: try fCmp(w, lane, ins)
    case .csel: try cSel(w, lane, ins)
    case .flush: try fFlush(w, lane, ins)
    case .fround: try fRound(w, lane, ins)
    case .ldexp: try fLdexp(w, lane, ins)
    default: throw Fault.invalid("\(ins.op) is not a float instruction")
    }
  }

  func fAdd(_ w: Warp, _ lane: Int, _ ins: Instr) throws {
    let mode = roundMode(ins)
    switch ins.dataType {
    case .f32:
      let a = try f32Operand(w, lane, ins, 0)
      var b = try f32Operand(w, lane, ins, 1)
      if ins.op == .faddLscale { b = rescale(b) }
      let fmt: FPFormat = narrowing(ins) ? .f16 : .f32
      let r = finish(fpAdd(FPFormat.f32.decode(a), FPFormat.f32.decode(b), fmt, mode), fmt, ins)
      if fmt.width == 16 { try writeHalf(w, lane, ins, UInt16(r)) } else { try writeDst(w, lane, ins, r) }
    case .v2f16:
      let (a0, a1) = try h2Operand(w, lane, ins, 0)
      let (b0, b1) = try h2Operand(w, lane, ins, 1)
      if ins.op == .faddLscale { throw Fault.invalid("FADD_LSCALE has no v2f16 form") }
      let f = FPFormat.f16
      let r0 = finish(fpAdd(f.decode(a0), f.decode(b0), f, mode), f, ins)
      let r1 = finish(fpAdd(f.decode(a1), f.decode(b1), f, mode), f, ins)
      try writeDst(w, lane, ins, r0 | r1 << 16)
    default: throw Fault.invalid("FADD with data type \(ins.dataType)")
    }
  }

  /// `FADD_LSCALE`'s rescale (11a §11a.3): the exponent is forced to the bias and a mantissa of 1.5 or
  /// more is halved, so |R| is in [0.75, 1.5); zero, subnormal, infinity and NaN pass through.
  func rescale(_ b: UInt32) -> UInt32 {
    let e = (b >> 23) & 0xFF
    guard e != 0 && e != 0xFF else { return b }
    let sign = b & 0x8000_0000
    let mant = b & 0x7F_FFFF
    let exp: UInt32 = mant >= 0x40_0000 ? 126 : 127
    return sign | exp << 23 | mant
  }

  func fAddImm(_ w: Warp, _ lane: Int, _ ins: Instr) throws {
    let raw = try src32(w, lane, ins, ins.s0)
    switch ins.dataType {
    case .f32:
      let a = fsrc(raw, widen: 0, neg: false, abs: false, flush: ftz)
      let r = fpAdd(FPFormat.f32.decode(a), FPFormat.f32.decode(ftz ? FPFormat.f32.flushed(ins.imm) : ins.imm), .f32, .nearestEven)
      try writeDst(w, lane, ins, ftz ? FPFormat.f32.flushed(r) : r)
    case .v2f16:
      let (a0, a1) = hsrc(raw, swz: 2, neg: false, abs: false, flush: halfFlush)
      let f = FPFormat.f16
      let r0 = fpAdd(f.decode(a0), f.decode(ins.imm & 0xFFFF), f, .nearestEven)
      let r1 = fpAdd(f.decode(a1), f.decode(ins.imm >> 16), f, .nearestEven)
      try writeDst(w, lane, ins, (ftz ? f.flushed(r0) : r0) | (ftz ? f.flushed(r1) : r1) << 16)
    default: throw Fault.invalid("FADD_IMM with data type \(ins.dataType)")
    }
  }

  func fFma(_ w: Warp, _ lane: Int, _ ins: Instr) throws {
    let mode = roundMode(ins)
    switch ins.dataType {
    case .f32:
      let a = try f32Operand(w, lane, ins, 0)
      let b = try f32Operand(w, lane, ins, 1)
      let c = try f32Operand(w, lane, ins, 2)
      let f = FPFormat.f32
      let fmt: FPFormat = narrowing(ins) ? .f16 : .f32
      let r = finish(fpFma(f.decode(a), f.decode(b), f.decode(c), fmt, mode), fmt, ins)
      if fmt.width == 16 { try writeHalf(w, lane, ins, UInt16(r)) } else { try writeDst(w, lane, ins, r) }
    case .v2f16:
      let (a0, a1) = try h2Operand(w, lane, ins, 0)
      let (b0, b1) = try h2Operand(w, lane, ins, 1)
      let (c0, c1) = try h2Operand(w, lane, ins, 2)
      let f = FPFormat.f16
      let r0 = finish(fpFma(f.decode(a0), f.decode(b0), f.decode(c0), f, mode), f, ins)
      let r1 = finish(fpFma(f.decode(a1), f.decode(b1), f.decode(c1), f, mode), f, ins)
      try writeDst(w, lane, ins, r0 | r1 << 16)
    default: throw Fault.invalid("FMA with data type \(ins.dataType)")
    }
  }

  func fFmaRscale(_ w: Warp, _ lane: Int, _ ins: Instr) throws {
    if ins.special == 3 { throw Fault.invalid("FMA_RSCALE n_add is not to be used (11a §11a.5)") }
    let f = FPFormat.f32
    let a = f.decode(try f32Operand(w, lane, ins, 0))
    let b = f.decode(try f32Operand(w, lane, ins, 1))
    let c = f.decode(try f32Operand(w, lane, ins, 2))
    let n = Int32(bitPattern: try src32(w, lane, ins, ins.s3))
    var p = a * b
    if (a == 0 || b == 0) && !a.isNaN && !b.isNaN {
      if ins.special == 1 { p = 0 }
      if ins.special == 2 { p = a }
    }
    let mode: Round = ins.round & 1 == 1 ? .zero : .nearestEven
    let scale = Int(max(-600, min(600, n)))
    var r: UInt32
    if !p.isFinite || !c.isFinite {
      r = f.encode(Double(sign: .plus, exponent: scale, significand: p + c), mode)
    } else {
      let s = sumOdd(p, c)
      if s == 0 {
        r = fpAdd(p, c, f, mode)
      } else {
        r = f.encode(Double(sign: .plus, exponent: scale, significand: s), mode)
      }
    }
    try writeDst(w, lane, ins, finish(r, f, ins))
  }

  func fMinMax(_ w: Warp, _ lane: Int, _ ins: Instr) throws {
    func pick(_ a: UInt32, _ b: UInt32, _ fmt: FPFormat) -> UInt32 {
      let an = fmt.isNaN(a)
      let bn = fmt.isNaN(b)
      if an || bn {
        if ins.sem == 1 || (an && bn) { return fmt.qnan }
        return an ? b : a
      }
      let x = fmt.decode(a)
      let y = fmt.decode(b)
      let wantMin = ins.op == .fmin
      if x == y {
        // The two zeros: -0 is the smaller (open, 11a §11a.6).
        if fmt.isZero(a) && fmt.isZero(b) { return wantMin ? (a | b) & fmt.signBit : a & b & fmt.signBit }
        return a
      }
      return (x < y) == wantMin ? a : b
    }
    switch ins.dataType {
    case .f32:
      let a = try f32Operand(w, lane, ins, 0)
      let b = try f32Operand(w, lane, ins, 1)
      try writeDst(w, lane, ins, finish(pick(a, b, .f32), .f32, ins))
    case .v2f16:
      let (a0, a1) = try h2Operand(w, lane, ins, 0)
      let (b0, b1) = try h2Operand(w, lane, ins, 1)
      let r0 = finish(pick(a0, b0, .f16), .f16, ins)
      let r1 = finish(pick(a1, b1, .f16), .f16, ins)
      try writeDst(w, lane, ins, r0 | r1 << 16)
    default: throw Fault.invalid("FMIN/FMAX with data type \(ins.dataType)")
    }
  }

  func fCmp(_ w: Warp, _ lane: Int, _ ins: Instr) throws {
    guard ins.resultType <= 2 else { throw Fault.invalid("FCMP result type c") }
    let raw2 = try src32(w, lane, ins, ins.s2)
    func combine(_ c: Bool, _ v: UInt32) -> Bool { ins.combine == 1 ? c && v != 0 : c || v != 0 }
    switch ins.dataType {
    case .f32:
      let a = try f32Operand(w, lane, ins, 0)
      let b = try f32Operand(w, lane, ins, 1)
      let k = combine(fpCompare(ins.cmp, a, b, .f32), raw2)
      try writeDst(w, lane, ins, k ? compareValue(ins.resultType, bits: 32) : 0)
    case .v2f16:
      let (a0, a1) = try h2Operand(w, lane, ins, 0)
      let (b0, b1) = try h2Operand(w, lane, ins, 1)
      let k0 = combine(fpCompare(ins.cmp, a0, b0, .f16), raw2 & 0xFFFF)
      let k1 = combine(fpCompare(ins.cmp, a1, b1, .f16), raw2 >> 16)
      let t = compareValue(ins.resultType, bits: 16)
      try writeDst(w, lane, ins, (k0 ? t : 0) | (k1 ? t : 0) << 16)
    default: throw Fault.invalid("FCMP with data type \(ins.dataType)")
    }
  }

  func cSel(_ w: Warp, _ lane: Int, _ ins: Instr) throws {
    let a = try src32(w, lane, ins, ins.s0)
    let b = try src32(w, lane, ins, ins.s1)
    let t = try src32(w, lane, ins, ins.s2)
    let f = try src32(w, lane, ins, ins.s3)
    func test(_ x: UInt32, _ y: UInt32) -> Bool {
      switch ins.dataType {
      case .f32: return fpCompare(ins.cmp, x, y, .f32)
      case .v2f16: return fpCompare(ins.cmp, x, y, .f16)
      default: return intCompare(ins.cmp, x, y, signed: ins.dataType.isSigned, bits: ins.dataType == .u32 || ins.dataType == .s32 ? 32 : 16)
      }
    }
    switch ins.dataType {
    case .f32, .u32, .s32:
      try writeDst(w, lane, ins, test(a, b) ? t : f)
    case .v2f16, .v2u16, .v2s16:
      let lo = test(a & 0xFFFF, b & 0xFFFF) ? t & 0xFFFF : f & 0xFFFF
      let hi = test(a >> 16, b >> 16) ? t & 0xFFFF_0000 : f & 0xFFFF_0000
      try writeDst(w, lane, ins, lo | hi)
    default: throw Fault.invalid("CSEL with data type \(ins.dataType)")
    }
  }

  func fFlush(_ w: Warp, _ lane: Int, _ ins: Instr) throws {
    func one(_ b: UInt32, _ fmt: FPFormat) -> UInt32 {
      if fmt.isNaN(b) {
        if ins.nanMode == 1 { return 0 }
        if ins.nanMode == 2 { return b | fmt.quietBit }
        return b
      }
      if ins.ftz && fmt.isSubnormal(b) { return b & fmt.signBit }
      if ins.flushInf && fmt.isInf(b) { return (b & fmt.signBit) | fmt.maxFinite }
      return b
    }
    switch ins.dataType {
    case .f32:
      let a = try f32Operand(w, lane, ins, 0, flush: false)
      try writeDst(w, lane, ins, one(a, .f32))
    case .v2f16:
      let (a0, a1) = try h2Operand(w, lane, ins, 0, flush: false)
      try writeDst(w, lane, ins, one(a0, .f16) | one(a1, .f16) << 16)
    default: throw Fault.invalid("FLUSH with data type \(ins.dataType)")
    }
  }

  func fRound(_ w: Warp, _ lane: Int, _ ins: Instr) throws {
    guard ins.dataType == .f32 else { throw Fault.invalid("FROUND is f32 only on arch 11 and later") }
    let a = try f32Operand(w, lane, ins, 0, flush: false)
    let f = FPFormat.f32
    guard !f.isNaN(a) && !f.isInf(a) else { return try writeDst(w, lane, ins, a) }
    let mode = Round(rawValue: ins.round) ?? .nearestEven
    try writeDst(w, lane, ins, f.encode(roundToIntegral(f.decode(a), mode), .nearestEven))
  }

  func fLdexp(_ w: Warp, _ lane: Int, _ ins: Instr) throws {
    let mode = roundMode(ins)
    let e = try src32(w, lane, ins, ins.s1)
    func scaled(_ d: Double, _ n: Int, _ fmt: FPFormat) -> UInt32 {
      guard d.isFinite && d != 0 else { return fmt.encode(d, .nearestEven) }
      return fmt.encode(Double(sign: .plus, exponent: max(-1000, min(1000, n)), significand: d), mode)
    }
    switch ins.dataType {
    case .f32:
      let a = try f32Operand(w, lane, ins, 0)
      try writeDst(w, lane, ins, finish(scaled(FPFormat.f32.decode(a), Int(Int32(bitPattern: e)), .f32), .f32, ins))
    case .v2f16:
      let (a0, a1) = try h2Operand(w, lane, ins, 0)
      let n0 = Int(Int16(truncatingIfNeeded: e))
      let n1 = Int(Int16(truncatingIfNeeded: e >> 16))
      let r0 = finish(scaled(FPFormat.f16.decode(a0), n0, .f16), .f16, ins)
      let r1 = finish(scaled(FPFormat.f16.decode(a1), n1, .f16), .f16, ins)
      try writeDst(w, lane, ins, r0 | r1 << 16)
    default: throw Fault.invalid("LDEXP with data type \(ins.dataType)")
    }
  }
}
