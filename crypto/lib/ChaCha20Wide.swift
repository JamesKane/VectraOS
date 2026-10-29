// SPDX-License-Identifier: BSD-3-Clause

// ChaCha20 four blocks at a time: each lane of a SIMD4<UInt32> is one
// block's state, so one pass of the rounds gives 256 bytes of key stream,
// as BLAKE3Wide.swift compresses four chunks. SIMD4 is NEON on arm64 and
// SSE on amd64, both in the baselines; rv64's baseline has no vectors, and
// runs the lanes one by one. The key stream is the scalar block's
// (ChaCha20.swift), which makes what isn't 256 whole bytes.

extension ChaCha20 {
  typealias Lanes = SIMD4<UInt32>

  // Rotations as two shifts added (their bits are disjoint), as BLAKE3's:
  // amd64's baseline has no vector rotate.
  @inline(__always) static func rotl16(_ x: Lanes) -> Lanes { (x &<< 16) &+ (x &>> 16) }
  @inline(__always) static func rotl12(_ x: Lanes) -> Lanes { (x &<< 12) &+ (x &>> 20) }
  @inline(__always) static func rotl8(_ x: Lanes) -> Lanes { (x &<< 8) &+ (x &>> 24) }
  @inline(__always) static func rotl7(_ x: Lanes) -> Lanes { (x &<< 7) &+ (x &>> 25) }

  /// Four blocks' states, a lane each: stored properties, so the rounds
  /// reach them without captures.
  struct Blocks {
    var s0, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11, s12, s13, s14, s15: Lanes

    @inline(__always) static func quarter(_ a: inout Lanes, _ b: inout Lanes, _ c: inout Lanes, _ d: inout Lanes) {
      a = a &+ b; d = rotl16(d ^ a)
      c = c &+ d; b = rotl12(b ^ c)
      a = a &+ b; d = rotl8(d ^ a)
      c = c &+ d; b = rotl7(b ^ c)
    }

    /// A column round, then a diagonal one.
    @inline(__always) mutating func doubleRound() {
      Self.quarter(&s0, &s4, &s8, &s12)
      Self.quarter(&s1, &s5, &s9, &s13)
      Self.quarter(&s2, &s6, &s10, &s14)
      Self.quarter(&s3, &s7, &s11, &s15)
      Self.quarter(&s0, &s5, &s10, &s15)
      Self.quarter(&s1, &s6, &s11, &s12)
      Self.quarter(&s2, &s7, &s8, &s13)
      Self.quarter(&s3, &s4, &s9, &s14)
    }
  }

  /// The 256 bytes at `p + at` xored, in place, with blocks `counter` to
  /// `counter + 3`'s key stream, for `key`'s eight words and the nonce's
  /// three.
  @inline(__always)
  static func xorFour(_ p: UnsafeMutableRawPointer, _ at: Int, key k: borrowing InlineArray<8, UInt32>,
                      counter: UInt32, _ n0: UInt32, _ n1: UInt32, _ n2: UInt32) {
    let x = Blocks(
      s0: Lanes(repeating: sigma[0]), s1: Lanes(repeating: sigma[1]), s2: Lanes(repeating: sigma[2]),
      s3: Lanes(repeating: sigma[3]), s4: Lanes(repeating: k[0]), s5: Lanes(repeating: k[1]),
      s6: Lanes(repeating: k[2]), s7: Lanes(repeating: k[3]), s8: Lanes(repeating: k[4]),
      s9: Lanes(repeating: k[5]), s10: Lanes(repeating: k[6]), s11: Lanes(repeating: k[7]),
      s12: Lanes(counter, counter &+ 1, counter &+ 2, counter &+ 3),
      s13: Lanes(repeating: n0), s14: Lanes(repeating: n1), s15: Lanes(repeating: n2))
    var s = x
    for _ in 0..<10 { s.doubleRound() }
    let w0 = s.s0 &+ x.s0, w1 = s.s1 &+ x.s1, w2 = s.s2 &+ x.s2, w3 = s.s3 &+ x.s3
    let w4 = s.s4 &+ x.s4, w5 = s.s5 &+ x.s5, w6 = s.s6 &+ x.s6, w7 = s.s7 &+ x.s7
    let w8 = s.s8 &+ x.s8, w9 = s.s9 &+ x.s9, w10 = s.s10 &+ x.s10, w11 = s.s11 &+ x.s11
    let w12 = s.s12 &+ x.s12, w13 = s.s13 &+ x.s13, w14 = s.s14 &+ x.s14, w15 = s.s15 &+ x.s15
    // Block j is lane j of each word: transposed sixteen bytes at a time
    // (little-endian, as every target is).
    @inline(__always) func put(_ j: Int, _ q: Int, _ v: Lanes) {
      let o = at &+ 64 &* j &+ 16 &* q
      unsafe p.storeBytes(of: unsafe p.loadUnaligned(fromByteOffset: o, as: Lanes.self) ^ v, toByteOffset: o, as: Lanes.self)
    }
    for j in 0..<4 {
      put(j, 0, Lanes(w0[j], w1[j], w2[j], w3[j]))
      put(j, 1, Lanes(w4[j], w5[j], w6[j], w7[j]))
      put(j, 2, Lanes(w8[j], w9[j], w10[j], w11[j]))
      put(j, 3, Lanes(w12[j], w13[j], w14[j], w15[j]))
    }
  }
}
