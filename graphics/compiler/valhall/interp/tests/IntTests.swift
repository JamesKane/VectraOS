// SPDX-License-Identifier: BSD-3-Clause

// Integer, bitwise and shift instructions (valhall 11b), against values
// computed independently in Swift.

import Testing

import ValhallInterp

private let corpus: [UInt32] = {
  var v: [UInt32] = [0, 1, 2, 0x7F, 0x80, 0xFF, 0x7FFF, 0x8000, 0xFFFF, 0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFF, 0x1234_5678, 0xDEAD_BEEF]
  var g = Lcg(s: 99)
  while v.count < 300 { v.append(g.next()) }
  return v
}()

private func perm(_ k: Int) -> [UInt32] { corpus.indices.map { corpus[($0 * k + 5) % corpus.count] } }

/// Runs a 64-bit instruction: r0:r1 and r2:r3 in, r8:r9 out.
func run64(_ ins: Instr, _ a: [UInt64], _ b: [UInt64]) throws -> [UInt64] {
  var out: [UInt64] = []
  var i = 0
  while i < a.count {
    let n = min(16, a.count - i)
    func part(_ v: [UInt64], _ half: Int) -> [UInt32] {
      (0..<16).map { UInt32(truncatingIfNeeded: v[min(i + $0, v.count - 1)] >> UInt64(32 * half)) }
    }
    let o = try run([ins], inputs: [0: part(a, 0), 1: part(a, 1), 2: part(b, 0), 3: part(b, 1)])
    out += (0..<n).map { UInt64(o[8, $0]) | UInt64(o[9, $0]) << 32 }
    i += 16
  }
  return out
}

private func lanes16(_ x: UInt32) -> [Int32] { [Int32(Int16(truncatingIfNeeded: x)), Int32(Int16(truncatingIfNeeded: x >> 16))] }
private func ulanes16(_ x: UInt32) -> [Int32] { [Int32(x & 0xFFFF), Int32(x >> 16)] }
private func clamp(_ v: Int64, _ lo: Int64, _ hi: Int64) -> Int64 { max(lo, min(hi, v)) }

@Test func iaddIsubThirtyTwoBit() throws {
  let a = perm(1)
  let b = perm(7)
  for (op, f) in [(Opcode.iadd, { (x: UInt32, y: UInt32) in x &+ y }), (.isub, { $0 &- $1 })] {
    for t in [DataType.u32, .s32] {
      let got = try runLanes(I(op, t, d: 8, r(0), r(1)), a, b)
      for i in a.indices { #expect(got[i] == f(a[i], b[i])) }
    }
  }
}

@Test func saturation32() throws {
  let a = perm(1)
  let b = perm(3)
  let su = try runLanes(I(.iadd, .u32, d: 8, r(0), r(1)).with(\.saturate, true), a, b)
  let ss = try runLanes(I(.iadd, .s32, d: 8, r(0), r(1)).with(\.saturate, true), a, b)
  let du = try runLanes(I(.isub, .u32, d: 8, r(0), r(1)).with(\.saturate, true), a, b)
  let ds = try runLanes(I(.isub, .s32, d: 8, r(0), r(1)).with(\.saturate, true), a, b)
  for i in a.indices {
    let (x, y) = (Int64(a[i]), Int64(b[i]))
    let (sx, sy) = (Int64(Int32(bitPattern: a[i])), Int64(Int32(bitPattern: b[i])))
    #expect(su[i] == UInt32(clamp(x + y, 0, 0xFFFF_FFFF)))
    #expect(du[i] == UInt32(clamp(x - y, 0, 0xFFFF_FFFF)))
    #expect(ss[i] == UInt32(bitPattern: Int32(clamp(sx + sy, Int64(Int32.min), Int64(Int32.max)))))
    #expect(ds[i] == UInt32(bitPattern: Int32(clamp(sx - sy, Int64(Int32.min), Int64(Int32.max)))))
  }
}

@Test func twoLaneSixteenBitWithSwizzles() throws {
  let a = perm(1)
  let b = perm(9)
  // Identity, saturating signed, and the swizzles h10 (swap), h11, and the byte forms b00 and b13.
  let u = try runLanes(I(.iadd, .v2u16, d: 8, r(0), r(1)), a, b)
  let s = try runLanes(I(.iadd, .v2s16, d: 8, r(0), r(1)).with(\.saturate, true), a, b)
  let sw = try runLanes(I(.isub, .v2u16, d: 8, r(0), r(1)).with(\.widen0, 1).with(\.widen1, 3), a, b)
  for i in a.indices {
    let (x, y) = (ulanes16(a[i]), ulanes16(b[i]))
    #expect(u[i] == UInt32((x[0] + y[0]) & 0xFFFF) | UInt32((x[1] + y[1]) & 0xFFFF) << 16)
    let (sx, sy) = (lanes16(a[i]), lanes16(b[i]))
    func sat(_ v: Int32) -> UInt32 { UInt32(UInt16(bitPattern: Int16(max(-32768, min(32767, v))))) }
    #expect(s[i] == sat(sx[0] + sy[0]) | sat(sx[1] + sy[1]) << 16)
    // swizzle h10 on S0, h11 on S1: lane 0 = hi(a) - hi(b), lane 1 = lo(a) - hi(b)
    #expect(sw[i] == UInt32((x[1] - y[1]) & 0xFFFF) | UInt32((x[0] - y[1]) & 0xFFFF) << 16)
  }
  // b13 (value 10): lane 0 = byte 1, lane 1 = byte 3, zero-extended for the unsigned variant.
  let bb = try runLanes(I(.iadd, .v2u16, d: 8, r(0), .zero).with(\.widen0, 10), [0xAABB_CCDD])
  #expect(bb == [0x00AA_00CC])
  let bs = try runLanes(I(.iadd, .v2s16, d: 8, r(0), .zero).with(\.widen0, 10), [0xAABB_CCDD])
  #expect(bs == [0xFFAA_FFCC])  // sign-extended bytes
}

@Test func widenOfThirtyTwoBitSources() throws {
  let x: UInt32 = 0x8182_83F4
  func add(_ w0: UInt8, _ w1: UInt8, _ t: DataType) throws -> UInt32 {
    try runLanes(I(.iadd, t, d: 8, r(0), r(1)).with(\.widen0, w0).with(\.widen1, w1), [x], [x])[0]
  }
  // u32: b3 + h1 = 0x81 + 0x8182; s32: sign extended.
  #expect(try add(7, 3, .u32) == 0x81 + 0x8182)
  #expect(try add(7, 3, .s32) == UInt32(bitPattern: Int32(Int8(bitPattern: 0x81)) + Int32(Int16(bitPattern: 0x8182))))
  #expect(try add(2, 6, .u32) == 0x83F4 + 0x82)
}

@Test func sixtyFourBitAddSubMulAndWidens() throws {
  let a: [UInt64] = [0, 0xFFFF_FFFF, 0x1_0000_0000, 0xFFFF_FFFF_FFFF_FFFF, 0x1234_5678_9ABC_DEF0, 3]
  let b: [UInt64] = [0, 1, 0xFFFF_FFFF, 1, 0xFEDC_BA98_7654_3210, 0x8000_0000_0000_0000]
  #expect(try run64(I(.iadd, .u64, d: 8, r(0), r(2)), a, b) == zip(a, b).map { $0 &+ $1 })
  #expect(try run64(I(.isub, .s64, d: 8, r(0), r(2)), a, b) == zip(a, b).map { $0 &- $1 })
  // w0 of the second source, zero or sign extended: the address arithmetic of 11b §11b.3.5.
  let w0u = try run64(I(.iadd, .u64, d: 8, r(0), r(2)).with(\.widen1, 8), a, b)
  let w0s = try run64(I(.iadd, .s64, d: 8, r(0), r(2)).with(\.widen1, 8), a, b)
  let w1u = try run64(I(.iadd, .u64, d: 8, r(0), r(2)).with(\.widen1, 9), a, b)
  for i in a.indices {
    #expect(w0u[i] == a[i] &+ (b[i] & 0xFFFF_FFFF))
    #expect(w0s[i] == a[i] &+ UInt64(bitPattern: Int64(Int32(truncatingIfNeeded: b[i]))))
    #expect(w1u[i] == a[i] &+ (b[i] >> 32))
  }
  // 32 x 32 to 64.
  let mu = try run64(I(.imul, .u64, d: 8, r(0), r(2)).with(\.widen0, 8).with(\.widen1, 8), a, b)
  let ms = try run64(I(.imul, .s64, d: 8, r(0), r(2)).with(\.widen0, 8).with(\.widen1, 8), a, b)
  for i in a.indices {
    #expect(mu[i] == (a[i] & 0xFFFF_FFFF) &* (b[i] & 0xFFFF_FFFF))
    #expect(ms[i] == UInt64(bitPattern: Int64(Int32(truncatingIfNeeded: a[i])) &* Int64(Int32(truncatingIfNeeded: b[i]))))
  }
  #expect(throws: InterpError.self) { _ = try run64(I(.imul, .u64, d: 8, r(0), r(2)), a, b) }  // no widen: not allowed
  // SHADD: A + (B.w0 << 2); SEG_ADD and SEG_SUB.
  let sh = try run64(I(.shadd, .u64, d: 8, r(0), r(2)).with(\.widen1, 8).with(\.shiftAmount, 2), a, b)
  for i in a.indices { #expect(sh[i] == a[i] &+ ((b[i] & 0xFFFF_FFFF) << 2)) }
  let sa = try run64(I(.segAdd, .u64, d: 8, r(0), r(2)).with(\.widen1, 8), a, b)
  let ss = try run64(I(.segAdd, .u64, d: 8, r(0), r(2)).with(\.widen1, 8).with(\.negResult, true), a, b)
  for i in a.indices {
    #expect(sa[i] == a[i] &+ (b[i] & 0xFFFF_FFFF))
    #expect(ss[i] == a[i] &- (b[i] & 0xFFFF_FFFF))
  }
}

@Test func multiply() throws {
  let a = perm(1)
  let b = perm(11)
  let m = try runLanes(I(.imul, .u32, d: 8, r(0), r(1)), a, b)
  let sat = try runLanes(I(.imul, .u32, d: 8, r(0), r(1)).with(\.saturate, true), a, b)
  let ssat = try runLanes(I(.imul, .s32, d: 8, r(0), r(1)).with(\.saturate, true), a, b)
  for i in a.indices {
    #expect(m[i] == a[i] &* b[i])
    #expect(sat[i] == UInt32(min(UInt64(a[i]) * UInt64(b[i]), 0xFFFF_FFFF)))
    let p = Int64(Int32(bitPattern: a[i])) * Int64(Int32(bitPattern: b[i]))
    #expect(ssat[i] == UInt32(bitPattern: Int32(clamp(p, Int64(Int32.min), Int64(Int32.max)))))
  }
  // Byte lanes: low 8 bits of each product; saturating signed.
  let v4 = try runLanes(I(.imul, .v4u8, d: 8, r(0), r(1)), a, b)
  let v4s = try runLanes(I(.imul, .v4s8, d: 8, r(0), r(1)).with(\.saturate, true), a, b)
  for i in a.indices {
    var w: UInt32 = 0
    var ws: UInt32 = 0
    for k in 0..<4 {
      let x = UInt32(a[i] >> UInt32(8 * k)) & 0xFF
      let y = UInt32(b[i] >> UInt32(8 * k)) & 0xFF
      w |= ((x &* y) & 0xFF) << UInt32(8 * k)
      let p = Int32(Int8(bitPattern: UInt8(x))) * Int32(Int8(bitPattern: UInt8(y)))
      ws |= UInt32(UInt8(bitPattern: Int8(max(-128, min(127, p))))) << UInt32(8 * k)
    }
    #expect(v4[i] == w && v4s[i] == ws)
  }
}

@Test func immediatesAndMoves() throws {
  #expect(try runLanes(I(.iaddImm, d: 8, r(0)).with(\.imm, 5), [10, 0xFFFF_FFFF]) == [15, 4])
  // MOV_IMM is IADD_IMM of the zero constant.
  #expect(try runLanes(I(.iaddImm, d: 8, .zero).with(\.imm, 0x1234_5678), [0]) == [0x1234_5678])
  let v2 = I(.iaddImm, .v2u16, d: 8, r(0)).with(\.imm, 0x0001_FFFF)
  #expect(try runLanes(v2, [0x0005_0001]) == [0x0006_0000])
  #expect(try runLanes(I(.andImm, d: 8, r(0)).with(\.imm, 0xFF), [0x1234_5678]) == [0x78])
  #expect(try runLanes(I(.orImm, d: 8, r(0)).with(\.imm, 0xF0), [0x0F]) == [0xFF])
  #expect(try runLanes(I(.xorImm, d: 8, r(0)).with(\.imm, 0xFF), [0x0F]) == [0xF0])
  // A destination half merges: r8 keeps its other half.
  let o = try run([I(.iaddImm, d: 8, .zero).with(\.imm, 0xAAAA_BBBB), I(.mov, d: 8, r(0)).w(1)], inputs: [0: [0x1111_2222]])
  #expect(o[8, 0] == 0xAAAA_2222)
  let o2 = try run([I(.iaddImm, d: 8, .zero).with(\.imm, 0xAAAA_BBBB), I(.mov, d: 8, r(0)).w(2)], inputs: [0: [0x1111_2222]])
  #expect(o2[8, 0] == 0x1111_BBBB)
  // MOV reads FAU words, special entries and constants.
  #expect(try run([I(.mov, d: 8, .u(1, 1))], fau: [0, 0, 7, 9])[8, 0] == 9)
  #expect(try run([I(.mov, d: 8, .u(37, 0))], fau: (0..<80).map { $0 == 74 ? 42 : 3 })[8, 0] == 42)
  #expect(try run([I(.mov, d: 8, .laneId)]).all(8) == (0..<16).map { UInt32($0) })
  #expect(try run([I(.mov, d: 8, .k(16))])[8, 3] == 0x3F80_0000)
}

@Test func compareFamily() throws {
  let a = perm(1)
  let b = perm(13)
  for (cmp, f) in [
    (UInt8(0), { (x: Int64, y: Int64) in x == y }), (1, { $0 > $1 }), (2, { $0 >= $1 }), (3, { $0 != $1 }), (4, { $0 < $1 }), (5, { $0 <= $1 }),
  ] {
    let u = try runLanes(I(.icmp, .u32, d: 8, r(0), r(1), .zero).with(\.cmp, cmp), a, b)
    let s = try runLanes(I(.icmp, .s32, d: 8, r(0), r(1), .zero).with(\.cmp, cmp).with(\.resultType, 2), a, b)
    let v = try runLanes(I(.icmp, .v2s16, d: 8, r(0), r(1), .zero).with(\.cmp, cmp).with(\.resultType, 2), a, b)
    for i in a.indices {
      #expect(u[i] == (f(Int64(a[i]), Int64(b[i])) ? 1 : 0))
      #expect(s[i] == (f(Int64(Int32(bitPattern: a[i])), Int64(Int32(bitPattern: b[i]))) ? ~0 : 0))
      let (x, y) = (lanes16(a[i]), lanes16(b[i]))
      #expect(v[i] == (f(Int64(x[0]), Int64(y[0])) ? 0xFFFF : 0) | (f(Int64(x[1]), Int64(y[1])) ? 0xFFFF_0000 : 0))
    }
  }
  // Combine: OR with a nonzero C is true, AND with a zero C is false; f1 gives 1.0.
  #expect(try runLanes(I(.icmp, .u32, d: 8, r(0), r(1), r(2)).with(\.cmp, 0), [1], [2], [7]) == [1])
  #expect(try runLanes(I(.icmp, .u32, d: 8, r(0), r(1), r(2)).with(\.cmp, 0).with(\.combine, 1), [1], [1], [0]) == [0])
  #expect(try runLanes(I(.icmp, .u32, d: 8, r(0), r(1), .zero).with(\.cmp, 0).with(\.resultType, 1), [1], [1]) == [0x3F80_0000])
}

@Test func icmpMultiBuilds64BitComparison() throws {
  let a: [UInt64] = [0, 5, 5, 0xFFFF_FFFF_FFFF_FFFF, 0x1_0000_0000, 0x8000_0000_0000_0000, 7, 0xFFFF_FFFF]
  let b: [UInt64] = [0, 5, 6, 0, 0xFFFF_FFFF, 1, 7, 0x1_0000_0000]
  for t in [DataType.u32, .s32] {
    for (cmp, f) in [(UInt8(1), { (x: Int, y: Int) in x > y }), (4, { $0 < $1 }), (0, { $0 == $1 }), (5, { $0 <= $1 })] {
      // Low words: unsigned, result type c; high words: with that as S2.
      let lo = I(.icmpMulti, .u32, d: 8, r(0), r(2), .zero).with(\.resultType, 3)
      let hi = I(.icmpMulti, t, d: 9, r(1), r(3), r(8)).with(\.cmp, cmp).with(\.resultType, 2)
      var got: [UInt32] = []
      for k in 0..<a.count {
        let o = try run(
          [lo, hi],
          inputs: [0: [UInt32(truncatingIfNeeded: a[k])], 1: [UInt32(a[k] >> 32)], 2: [UInt32(truncatingIfNeeded: b[k])], 3: [UInt32(b[k] >> 32)]])
        got.append(o[9, 0])
      }
      for k in a.indices {
        let ord: Int
        if t == .u32 { ord = a[k] < b[k] ? -1 : a[k] > b[k] ? 1 : 0 } else {
          let (x, y) = (Int64(bitPattern: a[k]), Int64(bitPattern: b[k]))
          ord = x < y ? -1 : x > y ? 1 : 0
        }
        #expect(got[k] == (f(ord, 0) ? ~0 : 0), "\(t) cmp \(cmp) k=\(k)")
      }
    }
  }
}

@Test func muxModes() throws {
  let a: UInt32 = 0xAAAA_AAAA
  let b: UInt32 = 0x5555_5555
  func mux(_ cond: UInt8, _ m: UInt32) throws -> UInt32 { try runLanes(I(.mux, .u32, d: 8, r(0), r(1), r(2)).with(\.special, cond), [a], [b], [m])[0] }
  #expect(try mux(0, 0x8000_0000) == a && mux(0, 0x7FFF_FFFF) == b)  // neg: msb
  #expect(try mux(1, 0) == a && mux(1, 4) == b)  // int_zero
  #expect(try mux(2, 0x8000_0000) == a && mux(2, 0x3F80_0000) == b && mux(2, 0) == a)  // fp_zero: -0 and +0
  #expect(try mux(3, 0xFFFF_0000) == 0xAAAA_5555)  // bit
  let v2 = I(.mux, .v2u16, d: 8, r(0), r(1), r(2)).with(\.special, 1)
  #expect(try runLanes(v2, [0x1111_2222], [0x3333_4444], [0x0000_0001]) == [0x1111_4444])
  let v4 = I(.mux, .v4u8, d: 8, r(0), r(1), r(2)).with(\.special, 3)
  #expect(try runLanes(v4, [0xFFFF_FFFF], [0], [0xFF00_FF00]) == [0xFF00_FF00])
}

private func rotl(_ x: UInt64, _ n: Int, _ w: Int) -> UInt64 {
  let m: UInt64 = w == 64 ? ~0 : (1 << UInt64(w)) - 1
  let n = n % w
  return n == 0 ? x & m : ((x << UInt64(n)) | ((x & m) >> UInt64(w - n))) & m
}

@Test func shiftFamilyThirtyTwoBit() throws {
  let x = perm(1)
  let n = perm(5)
  let s2 = perm(9)
  for shiftOp in UInt8(0)...4 {
    for combine in UInt8(0)...2 {
      for flags in 0..<4 {
        var ins = I(.shift, .u32, d: 8, r(0), r(1), r(2)).with(\.shiftOp, shiftOp).with(\.combine, combine)
        ins.notSrc2 = flags & 1 != 0
        ins.notResult = flags & 2 != 0
        let got = try runLanes(ins, x, n, s2)
        for i in x.indices {
          let k = Int(n[i] & 31)
          let t: UInt32
          switch shiftOp {
          case 0: t = x[i] >> UInt32(k)
          case 1: t = x[i] << UInt32(k)
          case 2: t = UInt32(rotl(UInt64(x[i]), 32 - k, 32))
          case 3: t = UInt32(rotl(UInt64(x[i]), k, 32))
          default: t = UInt32(bitPattern: Int32(bitPattern: x[i]) >> Int32(k))
          }
          let u = flags & 1 != 0 ? ~s2[i] : s2[i]
          var rr = combine == 0 ? t & u : combine == 1 ? t | u : t ^ u
          if flags & 2 != 0 { rr = ~rr }
          #expect(got[i] == rr, "op \(shiftOp) combine \(combine) flags \(flags) x=\(x[i]) n=\(k)")
        }
      }
    }
  }
}

@Test func shiftAmountLaneAndAliases() throws {
  // The amount is one byte of S1, chosen by the lane field; only its low 5 bits count (0x21 shifts by 1).
  let i = I(.shift, .u32, d: 8, r(0), r(1), .zero).with(\.shiftOp, 1).with(\.combine, 1).with(\.widen1, 5)
  #expect(try runLanes(i, [1], [0x0000_2100 | 0xFF]) == [2])  // byte 1 = 0x21
  // AND, OR, XOR aliases: S0 op S2; NOT: XOR of S0 with all ones.
  let andi = I(.shift, .u32, d: 8, r(0), .zero, r(2)).with(\.shiftOp, 1).with(\.combine, 0)
  #expect(try runLanes(andi, [0xF0F0], [0], [0xFF00]) == [0xF000])
  let noti = I(.shift, .u32, d: 8, r(0), .zero, .ones).with(\.shiftOp, 1).with(\.combine, 2)
  #expect(try runLanes(noti, [0x0F0F_0F0F]) == [0xF0F0_F0F0])
  // Byte swap: OR.v4i8 with the byte swizzle b3210 (value 1) of S0.
  let bswap = I(.shift, .v4u8, d: 8, r(0), .zero, .zero).with(\.shiftOp, 1).with(\.combine, 1).with(\.widen0, 1)
  #expect(try runLanes(bswap, [0x1122_3344]) == [0x4433_2211])
  // A widen of S0 zero-extends: b2 of 0x00AB0000 is 0xAB.
  let wid = I(.shift, .u32, d: 8, r(0), .zero, .zero).with(\.shiftOp, 1).with(\.combine, 1).with(\.widen0, 6)
  #expect(try runLanes(wid, [0x00AB_0000]) == [0xAB])
}

@Test func shiftFamilySixteenAndEightAndSixtyFourBit() throws {
  let x = perm(1)
  let n = perm(3)
  let s2 = perm(7)
  for shiftOp in UInt8(0)...4 {
    // v2i16: the default lane field b02 takes the amount of lane 0 from byte 0 and of lane 1 from byte 2.
    let v2 = try runLanes(I(.shift, .v2u16, d: 8, r(0), r(1), r(2)).with(\.shiftOp, shiftOp).with(\.combine, 2), x, n, s2)
    let v4 = try runLanes(I(.shift, .v4u8, d: 8, r(0), r(1), r(2)).with(\.shiftOp, shiftOp).with(\.combine, 1), x, n, s2)
    func lane(_ v: UInt64, _ k: Int, _ w: Int) -> UInt64 {
      let m: UInt64 = w == 64 ? ~0 : (1 << UInt64(w)) - 1
      let k = k & (w - 1)
      switch shiftOp {
      case 0: return (v & m) >> UInt64(k)
      case 1: return ((v & m) << UInt64(k)) & m
      case 2: return rotl(v, w - k, w)
      case 3: return rotl(v, k, w)
      default:
        let sv = Int64(bitPattern: v << UInt64(64 - w)) >> Int64(64 - w)
        return UInt64(bitPattern: sv >> Int64(k)) & m
      }
    }
    for i in x.indices {
      var e2: UInt32 = 0
      for l in 0..<2 {
        let amt = Int(n[i] >> UInt32(16 * l)) & 0xFF
        e2 |= UInt32(lane(UInt64((x[i] >> UInt32(16 * l)) & 0xFFFF), amt, 16) ^ UInt64((s2[i] >> UInt32(16 * l)) & 0xFFFF)) << UInt32(16 * l)
      }
      #expect(v2[i] == e2, "v2 op \(shiftOp)")
      var e4: UInt32 = 0
      for l in 0..<4 {
        let amt = Int(n[i] >> UInt32(8 * l)) & 0xFF
        e4 |= UInt32(lane(UInt64((x[i] >> UInt32(8 * l)) & 0xFF), amt, 8) | UInt64((s2[i] >> UInt32(8 * l)) & 0xFF)) << UInt32(8 * l)
      }
      #expect(v4[i] == e4, "v4 op \(shiftOp)")
    }
    let a64: [UInt64] = x.indices.map { UInt64(x[$0]) << 32 | UInt64(perm(2)[$0]) }
    let n64: [UInt64] = n.map { UInt64($0) }
    let s64: [UInt64] = s2.indices.map { UInt64(s2[$0]) << 32 | UInt64(perm(4)[$0]) }
    var ins = I(.shift, .u64, d: 8, r(0), r(2), r(4)).with(\.shiftOp, shiftOp).with(\.combine, 0)
    ins.notSrc2 = true
    var got: [UInt64] = []
    for i in 0..<a64.count {
      let o = try run(
        [ins],
        inputs: [
          0: [UInt32(truncatingIfNeeded: a64[i])], 1: [UInt32(a64[i] >> 32)], 2: [UInt32(truncatingIfNeeded: n64[i])], 3: [0],
          4: [UInt32(truncatingIfNeeded: s64[i])], 5: [UInt32(s64[i] >> 32)],
        ])
      got.append(UInt64(o[8, 0]) | UInt64(o[9, 0]) << 32)
    }
    for i in a64.indices {
      #expect(got[i] == lane(a64[i], Int(n64[i] & 0xFF), 64) & ~s64[i], "i64 op \(shiftOp)")
    }
  }
}

@Test func bitCountingAndReversal() throws {
  let x = corpus
  let clz = try runLanes(I(.clz, .u32, d: 8, r(0)), x)
  let clzm = try runLanes(I(.clz, .u32, d: 8, r(0)).with(\.mask, true), x)
  let pc = try runLanes(I(.popcount, d: 8, r(0)), x)
  let br = try runLanes(I(.bitrev, d: 8, r(0)), x)
  let c16 = try runLanes(I(.clz, .v2u16, d: 8, r(0)), x)
  let c8 = try runLanes(I(.clz, .v4u8, d: 8, r(0)), x)
  for i in x.indices {
    #expect(clz[i] == UInt32(x[i].leadingZeroBitCount))
    #expect(clzm[i] == (x[i] == 0 ? 0xFFFF_FFFF : UInt32(x[i].leadingZeroBitCount)))
    #expect(pc[i] == UInt32(x[i].nonzeroBitCount))
    var rev: UInt32 = 0
    for b in 0..<32 where x[i] >> UInt32(b) & 1 == 1 { rev |= 1 << UInt32(31 - b) }
    #expect(br[i] == rev)
    #expect(c16[i] == UInt32(UInt16(truncatingIfNeeded: x[i]).leadingZeroBitCount) | UInt32(UInt16(truncatingIfNeeded: x[i] >> 16).leadingZeroBitCount) << 16)
    var e: UInt32 = 0
    for k in 0..<4 { e |= UInt32(UInt8(truncatingIfNeeded: x[i] >> UInt32(8 * k)).leadingZeroBitCount) << UInt32(8 * k) }
    #expect(c8[i] == e)
  }
}

@Test func absoluteValueDotProductAndVectorBuild() throws {
  let x = corpus
  let abs32 = try runLanes(I(.iabs, .s32, d: 8, r(0)), x)
  let abs16 = try runLanes(I(.iabs, .v2s16, d: 8, r(0)), x)
  for i in x.indices {
    #expect(abs32[i] == UInt32(bitPattern: Int32(bitPattern: x[i]) == .min ? .min : Swift.abs(Int32(bitPattern: x[i]))))
    let l = lanes16(x[i])
    func a16(_ v: Int32) -> UInt32 { UInt32(UInt16(truncatingIfNeeded: v < 0 ? -v : v)) }
    #expect(abs16[i] == a16(l[0]) | a16(l[1]) << 16)
  }
  // IABS with a byte widen: b2 sign-extended.
  #expect(try runLanes(I(.iabs, .s32, d: 8, r(0)).with(\.widen0, 6), [0x0080_0000]) == [128])
  let a = perm(1)
  let b = perm(3)
  let c = perm(5)
  let ds = try runLanes(I(.idpadd, .v4s8, d: 8, r(0), r(1), r(2)), a, b, c)
  let du = try runLanes(I(.idpadd, .v4u8, d: 8, r(0), r(1), r(2)).with(\.saturate, true), a, b, c)
  for i in a.indices {
    var ss: Int64 = Int64(Int32(bitPattern: c[i]))
    var su: Int64 = Int64(c[i])
    for k in 0..<4 {
      let p = UInt8(truncatingIfNeeded: a[i] >> UInt32(8 * k))
      let q = UInt8(truncatingIfNeeded: b[i] >> UInt32(8 * k))
      ss += Int64(Int8(bitPattern: p)) * Int64(Int8(bitPattern: q))
      su += Int64(p) * Int64(q)
    }
    #expect(ds[i] == UInt32(truncatingIfNeeded: ss))
    #expect(du[i] == UInt32(clamp(su, 0, 0xFFFF_FFFF)))
  }
  let mk = I(.mkvecV2i16, d: 8, r(0), r(1)).with(\.widen0, 1)  // A.h1 | B.h0 << 16
  #expect(try runLanes(mk, [0xAAAA_1111], [0x2222_BBBB]) == [0xBBBB_AAAA])
  let mk8 = I(.mkvecV2i8, d: 8, r(0), r(1), r(2)).with(\.widen0, 3).with(\.widen1, 1)
  #expect(try runLanes(mk8, [0x8000_0000], [0x0000_7F00], [0xDEAD_BEEF]) == [0xBEEF_7F80])
}
