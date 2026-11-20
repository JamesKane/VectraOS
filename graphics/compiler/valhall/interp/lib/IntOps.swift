// SPDX-License-Identifier: BSD-3-Clause

// The integer, bitwise and shift instructions of valhall 11b.
//
// Lanes are carried as exact Int64 values (zero- or sign-extended by the
// variant's signedness) so that saturation clamps the exact result
// (11b §11b.1.5). Source selection is the widen and swizzle families of
// 11b §11b.1.2 and §11b.1.3.
//
// Choices where the spec is open: a half destination of a 32-bit scalar
// result writes the corresponding half of the result (§11b.1.4);
// `SEG_ADD`/`SEG_SUB` ignore `preserve_null` (the spec says leave it
// clear); `SEG_SUB` is `negResult` set; `IADDC`/`ISUBB` are not modelled
// (their semantics are open and nothing generates them).

/// The 4-bit swizzle of two 16-bit lanes of integer data (11b §11b.1.3): per result lane, the source
/// element, a half (`h`) or a byte (`b`).
private let swz16: [((Bool, Int), (Bool, Int))] = [
  ((false, 0), (false, 0)), ((false, 1), (false, 0)), ((false, 0), (false, 1)), ((false, 1), (false, 1)),
  ((true, 0), (true, 0)), ((true, 2), (true, 0)), ((true, 0), (true, 2)), ((true, 2), (true, 2)),
  ((true, 1), (true, 1)), ((true, 3), (true, 1)), ((true, 1), (true, 3)), ((true, 3), (true, 3)),
  ((true, 0), (true, 1)), ((true, 2), (true, 3)),
]

/// The 4-bit byte swizzle (11b §11b.1.3): the source byte of each result lane.
private let swz8: [[Int]] = [
  [0, 1, 2, 3], [3, 2, 1, 0], [0, 1, 0, 1], [2, 3, 2, 3], [0, 0, 0, 0], [1, 1, 1, 1], [2, 2, 2, 2],
  [3, 3, 3, 3], [2, 3, 0, 1], [1, 0, 3, 2], [0, 0, 1, 1], [2, 2, 3, 3],
]

func signExtend(_ v: UInt64, bits: Int) -> Int64 {
  guard bits < 64 else { return Int64(bitPattern: v) }
  let shift = UInt64(64 - bits)
  return Int64(bitPattern: v << shift) >> Int64(shift)
}

func laneMask(_ bits: Int) -> UInt64 { bits >= 64 ? ~0 : (1 << UInt64(bits)) - 1 }

/// An element of `raw` extended: `bits` wide at `shift`.
func element(_ raw: UInt64, shift: Int, bits: Int, signed: Bool) -> Int64 {
  let v = (raw >> UInt64(shift)) & laneMask(bits)
  return signed ? signExtend(v, bits: bits) : Int64(bitPattern: v)
}

extension Executor {
  /// The 32-bit widen (11b §11b.1.2): `none`, `h0`, `h1`, `b0` to `b3`, extended by signedness.
  func widen32(_ raw: UInt32, _ widen: UInt8, signed: Bool) throws -> Int64 {
    let r = UInt64(raw)
    switch widen {
    case 0: return element(r, shift: 0, bits: 32, signed: signed)
    case 2: return element(r, shift: 0, bits: 16, signed: signed)
    case 3: return element(r, shift: 16, bits: 16, signed: signed)
    case 4...7: return element(r, shift: 8 * Int(widen - 4), bits: 8, signed: signed)
    default: throw Fault.invalid("widen value \(widen) on a 32-bit source")
    }
  }

  /// The widen of a 64-bit-form source: also `w0` and `w1` (the words), extended to 64 bits.
  func widen64(_ raw: UInt64, _ widen: UInt8, signed: Bool) throws -> UInt64 {
    switch widen {
    case 0: return raw
    case 8: return UInt64(bitPattern: element(raw, shift: 0, bits: 32, signed: signed))
    case 9: return UInt64(bitPattern: element(raw, shift: 32, bits: 32, signed: signed))
    case 2: return UInt64(bitPattern: element(raw, shift: 0, bits: 16, signed: signed))
    case 3: return UInt64(bitPattern: element(raw, shift: 16, bits: 16, signed: signed))
    case 4...7: return UInt64(bitPattern: element(raw, shift: 8 * Int(widen - 4), bits: 8, signed: signed))
    default: throw Fault.invalid("widen value \(widen) on a 64-bit source")
    }
  }

  /// The lanes of a source after its widen or swizzle, for a data type of 32, 16 or 8-bit lanes.
  func intLanes(_ raw: UInt32, _ type: DataType, _ widen: UInt8) throws -> [Int64] {
    let signed = type.isSigned
    switch type {
    case .u32, .s32: return [try widen32(raw, widen, signed: signed)]
    case .v2u16, .v2s16:
      guard Int(widen) < swz16.count else { throw Fault.invalid("16-bit lane swizzle \(widen)") }
      let r = UInt64(raw)
      return [swz16[Int(widen)].0, swz16[Int(widen)].1].map { src in
        src.0 ? element(r, shift: 8 * src.1, bits: 8, signed: signed) : element(r, shift: 16 * src.1, bits: 16, signed: signed)
      }
    case .v4u8, .v4s8:
      guard Int(widen) < swz8.count else { throw Fault.invalid("byte swizzle \(widen)") }
      return swz8[Int(widen)].map { element(UInt64(raw), shift: 8 * $0, bits: 8, signed: signed) }
    default: throw Fault.invalid("lane type \(type)")
    }
  }

  func laneBits(_ type: DataType) -> Int {
    switch type {
    case .u32, .s32: 32
    case .v2u16, .v2s16: 16
    default: 8
    }
  }

  /// Packs exact lane results, wrapping or (with `sat`) clamping to the lane range.
  func packLanes(_ vals: [Int64], _ type: DataType, sat: Bool) -> UInt32 {
    let bits = laneBits(type)
    var out: UInt64 = 0
    for (i, v0) in vals.enumerated() {
      var v = v0
      if sat {
        let lo: Int64 = type.isSigned ? -(1 << Int64(bits - 1)) : 0
        let hi: Int64 = type.isSigned ? (1 << Int64(bits - 1)) - 1 : (1 << Int64(bits)) - 1
        v = max(lo, min(hi, v))
      }
      out |= (UInt64(bitPattern: v) & laneMask(bits)) << UInt64(bits * i)
    }
    return UInt32(truncatingIfNeeded: out)
  }

  func intCompare(_ cmp: UInt8, _ x: UInt32, _ y: UInt32, signed: Bool, bits: Int) -> Bool {
    let a = element(UInt64(x), shift: 0, bits: bits, signed: signed)
    let b = element(UInt64(y), shift: 0, bits: bits, signed: signed)
    return intOrder(cmp, a, b)
  }

  func intOrder(_ cmp: UInt8, _ a: Int64, _ b: Int64) -> Bool {
    switch cmp {
    case 0: a == b
    case 1: a > b
    case 2: a >= b
    case 3: a != b
    case 4: a < b
    default: a <= b
    }
  }

  // MARK: Dispatch

  func execInt(_ w: Warp, _ lane: Int, _ ins: Instr) throws {
    switch ins.op {
    case .iadd, .isub, .imul: try intArith(w, lane, ins)
    case .iaddImm, .andImm, .orImm, .xorImm: try intImm(w, lane, ins)
    case .idpadd: try idpadd(w, lane, ins)
    case .iabs: try iabs(w, lane, ins)
    case .icmp: try icmp(w, lane, ins)
    case .icmpMulti: try icmpMulti(w, lane, ins)
    case .mux: try mux(w, lane, ins)
    case .shift: try shiftLogic(w, lane, ins)
    case .mov: try writeDst(w, lane, ins, try src32(w, lane, ins, ins.s0))
    case .mkvecV2i16:
      let a = try src32(w, lane, ins, ins.s0)
      let b = try src32(w, lane, ins, ins.s1)
      let lo = (a >> (ins.widen0 == 0 ? 0 : 16)) & 0xFFFF
      let hi = (b >> (ins.widen1 == 0 ? 0 : 16)) & 0xFFFF
      try writeDst(w, lane, ins, lo | hi << 16)
    case .mkvecV2i8:
      let a = try src32(w, lane, ins, ins.s0)
      let b = try src32(w, lane, ins, ins.s1)
      let cd = try src32(w, lane, ins, ins.s2)
      let b0 = (a >> UInt32(8 * (ins.widen0 & 3))) & 0xFF
      let b1 = (b >> UInt32(8 * (ins.widen1 & 3))) & 0xFF
      try writeDst(w, lane, ins, b0 | b1 << 8 | (cd & 0xFFFF) << 16)
    case .clz: try clz(w, lane, ins)
    case .popcount: try writeDst(w, lane, ins, UInt32(try src32(w, lane, ins, ins.s0).nonzeroBitCount))
    case .bitrev:
      let v = try src32(w, lane, ins, ins.s0)
      var r: UInt32 = 0
      for i in 0..<32 where v & (1 << UInt32(i)) != 0 { r |= 1 << UInt32(31 - i) }
      try writeDst(w, lane, ins, r)
    case .shadd: try shadd(w, lane, ins)
    case .segAdd: try segAdd(w, lane, ins)
    default: throw Fault.invalid("\(ins.op) is not an integer instruction")
    }
  }

  func intArith(_ w: Warp, _ lane: Int, _ ins: Instr) throws {
    let t = ins.dataType
    if t == .u64 || t == .s64 {
      let a = try widen64(try src64(w, lane, ins, ins.s0), ins.widen0, signed: t.isSigned)
      let b = try widen64(try src64(w, lane, ins, ins.s1), ins.widen1, signed: t.isSigned)
      switch ins.op {
      case .iadd: return try writeDst64(w, lane, ins, a &+ b)
      case .isub: return try writeDst64(w, lane, ins, a &- b)
      default:
        // 32 x 32 to 64: both operands must be selected down to a 32-bit value (11b §11b.3.2).
        guard ins.widen0 != 0 && ins.widen1 != 0 && ins.widen0 != 9 && ins.widen1 != 9 else {
          throw Fault.invalid("IMUL.64 needs a widen on both sources (none and w1 are not allowed)")
        }
        return try writeDst64(w, lane, ins, a &* b)
      }
    }
    let a = try intLanes(try src32(w, lane, ins, ins.s0), t, ins.widen0)
    let b = try intLanes(try src32(w, lane, ins, ins.s1), t, ins.widen1)
    let bits = laneBits(t)
    var out: [Int64] = []
    for i in a.indices {
      switch ins.op {
      case .iadd: out.append(a[i] + b[i])
      case .isub: out.append(a[i] - b[i])
      default:
        if t.isSigned {
          out.append(a[i] * b[i])
        } else {
          let p = UInt64(a[i]) * UInt64(b[i])
          out.append(ins.saturate ? Int64(min(p, laneMask(bits))) : Int64(truncatingIfNeeded: p & laneMask(bits)))
        }
      }
    }
    try writeDst(w, lane, ins, packLanes(out, t, sat: ins.saturate))
  }

  func intImm(_ w: Warp, _ lane: Int, _ ins: Instr) throws {
    let a = try src32(w, lane, ins, ins.s0)
    switch ins.op {
    case .andImm: try writeDst(w, lane, ins, a & ins.imm)
    case .orImm: try writeDst(w, lane, ins, a | ins.imm)
    case .xorImm: try writeDst(w, lane, ins, a ^ ins.imm)
    default:
      if ins.dataType == .v2u16 || ins.dataType == .v2s16 {
        let lo = (a & 0xFFFF) &+ (ins.imm & 0xFFFF)
        let hi = (a >> 16) &+ (ins.imm >> 16)
        try writeDst(w, lane, ins, (lo & 0xFFFF) | hi << 16)
      } else {
        try writeDst(w, lane, ins, a &+ ins.imm)
      }
    }
  }

  func idpadd(_ w: Warp, _ lane: Int, _ ins: Instr) throws {
    let signed = ins.dataType == .v4s8
    let a = try intLanes(try src32(w, lane, ins, ins.s0), ins.dataType, 0)
    let b = try intLanes(try src32(w, lane, ins, ins.s1), ins.dataType, 0)
    let c = try src32(w, lane, ins, ins.s2)
    let sum = zip(a, b).reduce(Int64(0)) { $0 + $1.0 * $1.1 }
    var r = (signed ? Int64(Int32(bitPattern: c)) : Int64(c)) + sum
    if ins.saturate {
      r = signed ? max(Int64(Int32.min), min(Int64(Int32.max), r)) : max(0, min(Int64(UInt32.max), r))
    }
    try writeDst(w, lane, ins, UInt32(truncatingIfNeeded: r))
  }

  func iabs(_ w: Warp, _ lane: Int, _ ins: Instr) throws {
    let v = try intLanes(try src32(w, lane, ins, ins.s0), ins.dataType, ins.widen0)
    // The most negative lane maps to itself: wrapping the exact absolute value does that.
    try writeDst(w, lane, ins, packLanes(v.map { $0 < 0 ? -$0 : $0 }, ins.dataType, sat: false))
  }

  func icmp(_ w: Warp, _ lane: Int, _ ins: Instr) throws {
    guard ins.resultType <= 2 else { throw Fault.invalid("ICMP result type c") }
    let t = ins.dataType
    let a = try intLanes(try src32(w, lane, ins, ins.s0), t, ins.widen0)
    let b = try intLanes(try src32(w, lane, ins, ins.s1), t, ins.widen1)
    let c = try src32(w, lane, ins, ins.s2)
    let bits = laneBits(t)
    var out: UInt32 = 0
    for i in a.indices {
      let cv = (c >> UInt32(bits * i)) & UInt32(truncatingIfNeeded: laneMask(bits))
      let r = intOrder(ins.cmp, a[i], b[i])
      let k = ins.combine == 1 ? r && cv != 0 : r || cv != 0
      if k { out |= compareValue(ins.resultType, bits: bits) << UInt32(bits * i) }
    }
    try writeDst(w, lane, ins, out)
  }

  func icmpMulti(_ w: Warp, _ lane: Int, _ ins: Instr) throws {
    let signed = ins.dataType.isSigned
    let a = try widen32(try src32(w, lane, ins, ins.s0), ins.widen0, signed: signed)
    let b = try widen32(try src32(w, lane, ins, ins.s1), ins.widen1, signed: signed)
    let c = Int64(Int32(bitPattern: try src32(w, lane, ins, ins.s2)))
    var o: Int64 = a < b ? -1 : a > b ? 1 : 0
    if o == 0 { o = c < 0 ? -1 : c > 0 ? 1 : 0 }
    if ins.resultType == 3 {
      guard !signed else { throw Fault.invalid("ICMP_MULTI result type c is unsigned only") }
      return try writeDst(w, lane, ins, UInt32(truncatingIfNeeded: o))
    }
    let r = intOrder(ins.cmp, o, 0)
    try writeDst(w, lane, ins, r ? compareValue(ins.resultType, bits: 32) : 0)
  }

  func mux(_ w: Warp, _ lane: Int, _ ins: Instr) throws {
    let a = try src32(w, lane, ins, ins.s0)
    let b = try src32(w, lane, ins, ins.s1)
    let m = try src32(w, lane, ins, ins.s2)
    func pick(_ x: UInt32, _ y: UInt32, _ mm: UInt32, bits: Int) -> UInt32 {
      let msb = (mm >> UInt32(bits - 1)) & 1 != 0
      let zero = mm & UInt32(truncatingIfNeeded: laneMask(bits)) == 0
      switch ins.special {
      case 0: return msb ? x : y
      case 1: return zero ? x : y
      case 2: return FPFormat.f32.decode(mm) == 0 ? x : y
      default: return (x & mm) | (y & ~mm)
      }
    }
    switch ins.dataType {
    case .u32, .s32:
      try writeDst(w, lane, ins, pick(a, b, m, bits: 32))
    case .v2u16, .v2s16:
      let la = try intLanes(a, .v2u16, ins.widen0)
      let lb = try intLanes(b, .v2u16, ins.widen1)
      let lm = try intLanes(m, .v2u16, ins.widen2)
      var out: UInt32 = 0
      for i in 0..<2 { out |= (pick(UInt32(la[i]), UInt32(lb[i]), UInt32(lm[i]), bits: 16) & 0xFFFF) << UInt32(16 * i) }
      try writeDst(w, lane, ins, out)
    case .v4u8, .v4s8:
      if ins.special == 2 { throw Fault.invalid("MUX.v4i8 has no fp_zero") }
      var out: UInt32 = 0
      for i in 0..<4 {
        let sh = UInt32(8 * i)
        out |= (pick((a >> sh) & 0xFF, (b >> sh) & 0xFF, (m >> sh) & 0xFF, bits: 8) & 0xFF) << sh
      }
      try writeDst(w, lane, ins, out)
    default: throw Fault.invalid("MUX with data type \(ins.dataType)")
    }
  }

  func clz(_ w: Warp, _ lane: Int, _ ins: Instr) throws {
    let raw = try src32(w, lane, ins, ins.s0)
    func one(_ v: UInt64, _ bits: Int) -> UInt64 {
      if v == 0 { return ins.mask ? laneMask(bits) : UInt64(bits) }
      return UInt64(v.leadingZeroBitCount - (64 - bits))
    }
    switch ins.dataType {
    case .u32: try writeDst(w, lane, ins, UInt32(one(UInt64(raw), 32)))
    case .v2u16:
      let l = try intLanes(raw, .v2u16, ins.widen0)
      try writeDst(w, lane, ins, UInt32(one(UInt64(l[0]), 16) | one(UInt64(l[1]), 16) << 16))
    case .v4u8:
      var out: UInt32 = 0
      for i in 0..<4 { out |= UInt32(one(UInt64((raw >> UInt32(8 * i)) & 0xFF), 8)) << UInt32(8 * i) }
      try writeDst(w, lane, ins, out)
    default: throw Fault.invalid("CLZ with data type \(ins.dataType)")
    }
  }

  func shadd(_ w: Warp, _ lane: Int, _ ins: Instr) throws {
    let a = try src64(w, lane, ins, ins.s0)
    let b = try widen64(try src64(w, lane, ins, ins.s1), ins.widen1, signed: ins.dataType.isSigned)
    try writeDst64(w, lane, ins, a &+ (b << UInt64(ins.shiftAmount & 7)))
  }

  func segAdd(_ w: Warp, _ lane: Int, _ ins: Instr) throws {
    let a = try src64(w, lane, ins, ins.s0)
    let b = try widen64(try src64(w, lane, ins, ins.s1), ins.widen1, signed: false)
    try writeDst64(w, lane, ins, ins.negResult ? a &- b : a &+ b)
  }

  // MARK: Shift and logic (11b §11b.5)

  func shiftLogic(_ w: Warp, _ lane: Int, _ ins: Instr) throws {
    let t = ins.dataType
    if t == .u64 || t == .s64 {
      let x = try widen64(try src64(w, lane, ins, ins.s0), ins.widen0, signed: false)
      let amountSrc = try src64(w, lane, ins, ins.s1)
      let s2 = try src64(w, lane, ins, ins.s2)
      let n = Int((amountSrc >> UInt64(8 * (Int(ins.widen1) - 4))) & 0xFF)
      try writeDst64(w, lane, ins, shiftLane(x, n, width: 64, ins, s2))
      return
    }
    let raw0 = try src32(w, lane, ins, ins.s0)
    let raw1 = try src32(w, lane, ins, ins.s1)
    let raw2 = try src32(w, lane, ins, ins.s2)
    switch t {
    case .u32, .s32:
      let x = UInt64(bitPattern: try widen32(raw0, ins.widen0, signed: false))
      guard (4...7).contains(ins.widen1) else { throw Fault.invalid("shift amount lane \(ins.widen1)") }
      let n = Int((raw1 >> UInt32(8 * (ins.widen1 - 4))) & 0xFF)
      try writeDst(w, lane, ins, UInt32(truncatingIfNeeded: shiftLane(x, n, width: 32, ins, UInt64(raw2))))
    case .v2u16, .v2s16:
      let x = try intLanes(raw0, .v2u16, ins.widen0)
      let bytes: [Int]
      switch ins.widen1 {
      case 0: bytes = [0, 2]
      case 4...7: bytes = [Int(ins.widen1 - 4), Int(ins.widen1 - 4)]
      case 10: bytes = [0, 1]
      case 11: bytes = [2, 3]
      default: throw Fault.invalid("v2i16 shift amount lane \(ins.widen1)")
      }
      var out: UInt32 = 0
      for i in 0..<2 {
        let n = Int((raw1 >> UInt32(8 * bytes[i])) & 0xFF)
        let s2 = UInt64((raw2 >> UInt32(16 * i)) & 0xFFFF)
        out |= UInt32(truncatingIfNeeded: shiftLane(UInt64(x[i]), n, width: 16, ins, s2)) << UInt32(16 * i)
      }
      try writeDst(w, lane, ins, out)
    case .v4u8, .v4s8:
      let x = try intLanes(raw0, .v4u8, ins.widen0)
      guard Int(ins.widen1) < swz8.count else { throw Fault.invalid("byte swizzle \(ins.widen1)") }
      var out: UInt32 = 0
      for i in 0..<4 {
        let n = Int((raw1 >> UInt32(8 * swz8[Int(ins.widen1)][i])) & 0xFF)
        let s2 = UInt64((raw2 >> UInt32(8 * i)) & 0xFF)
        out |= UInt32(truncatingIfNeeded: shiftLane(UInt64(x[i]), n, width: 8, ins, s2)) << UInt32(8 * i)
      }
      try writeDst(w, lane, ins, out)
    default: throw Fault.invalid("shift with data type \(t)")
    }
  }

  /// One lane of the shift-and-logic family: `X` shifted or rotated by `n` (modulo the lane width),
  /// combined with `S2` (complemented if asked), the result complemented if asked.
  func shiftLane(_ x: UInt64, _ n0: Int, width: Int, _ ins: Instr, _ s2: UInt64) -> UInt64 {
    let m = laneMask(width)
    let n = UInt64(n0 & (width - 1))
    let v = x & m
    let wd = UInt64(width)
    var t: UInt64
    switch ins.shiftOp {
    case 0: t = v >> n
    case 1: t = (v << n) & m
    case 2: t = n == 0 ? v : ((v >> n) | (v << (wd - n))) & m
    case 3: t = n == 0 ? v : ((v << n) | (v >> (wd - n))) & m
    default: t = UInt64(bitPattern: signExtend(v, bits: width) >> Int64(n)) & m
    }
    var u = s2 & m
    if ins.notSrc2 { u = ~u & m }
    var r: UInt64
    switch ins.combine {
    case 0: r = t & u
    case 1: r = t | u
    default: r = t ^ u
    }
    if ins.notResult { r = ~r & m }
    return r
  }
}
