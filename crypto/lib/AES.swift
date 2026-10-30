// SPDX-License-Identifier: BSD-3-Clause

// AES-256 (FIPS 197) and XTS (IEEE 1619, NIST SP 800-38E): ours, tier 0.
// Taisce's encrypted volumes are its user (D153), a 4 KiB block a data
// unit, its tweak the block number.
//
// The CPU's instructions do the work where it has them (crypto/accel,
// AES-NI on amd64, the Armv8 extension on arm64). Elsewhere, and to check
// them, this file's software does it in constant time: no table is
// indexed by a secret, since a table's cache lines leak the key. Four
// blocks go at once, their 64 bytes as 16 little-endian column words;
// SubBytes moves them into eight 64-bit bit-planes (an 8x8 bit transpose
// per 8 bytes) and computes all 64 S-boxes as one boolean circuit, Boyar
// and Peralta's ("A depth-16 circuit for the AES S-box", 2011), then moves
// them back. ShiftRows picks bytes from the column words by masks, and
// MixColumns doubles all four bytes of a word at once. The inverse S-box
// is the same circuit between two inverse affine maps.

import TDCryptoAccel

/// AES-256's key schedule: the 15 round keys.
public struct AES256: Sendable {
  /// The round keys as column words (FIPS 197's w[0..<60]), little-endian.
  let words: [UInt32]
  /// The same as bytes in the state's order, for the instructions.
  let encryption: [UInt8]
  /// The equivalent inverse cipher's round keys (FIPS 197 §5.3.5), as bytes.
  let decryption: [UInt8]

  /// The schedule of a 32-byte key.
  public init(key: [UInt8]) {
    precondition(key.count == 32, "an AES-256 key is 32 bytes")
    var w = [UInt32](repeating: 0, count: 60)
    for i in 0..<8 { w[i] = AESCore.word(key, 4 &* i) }
    var rcon: UInt32 = 1
    for i in 8..<60 {
      var t = w[i &- 1]
      if i % 8 == 0 {
        t = AESCore.subWord(t >> 8 | t << 24) ^ rcon
        rcon = AESCore.xtime(rcon)
      } else if i % 8 == 4 {
        t = AESCore.subWord(t)
      }
      w[i] = w[i &- 8] ^ t
    }
    words = w
    encryption = AESCore.bytes(w)
    var d = [UInt32](repeating: 0, count: 60)
    for r in 0..<15 {
      for c in 0..<4 {
        let k = w[4 &* (14 &- r) &+ c]
        d[4 &* r &+ c] = r == 0 || r == 14 ? k : AESCore.invMixColumn(k)
      }
    }
    decryption = AESCore.bytes(d)
  }

  /// `block` (16 bytes) encrypted, in software.
  public func encrypt(_ block: [UInt8]) -> [UInt8] {
    precondition(block.count == 16, "a block is 16 bytes")
    var s = AESCore.State(repeating: 0)
    for c in 0..<4 { s[c] = AESCore.word(block, 4 &* c) }
    AESCore.encrypt(&s, words)
    return AESCore.bytes(s, count: 4)
  }

  /// `block` (16 bytes) decrypted, in software.
  public func decrypt(_ block: [UInt8]) -> [UInt8] {
    precondition(block.count == 16, "a block is 16 bytes")
    var s = AESCore.State(repeating: 0)
    for c in 0..<4 { s[c] = AESCore.word(block, 4 &* c) }
    AESCore.decrypt(&s, words)
    return AESCore.bytes(s, count: 4)
  }
}

/// AES-256-XTS: a 64-byte key, the data key's half then the tweak key's.
public struct AESXTS: Sendable {
  let data: AES256
  let tweak: AES256

  public init(key: [UInt8]) {
    precondition(key.count == 64, "an AES-256-XTS key is 64 bytes")
    data = AES256(key: Array(key[0..<32]))
    tweak = AES256(key: Array(key[32..<64]))
  }

  /// Whether this CPU's instructions do the work.
  public static var hardware: Bool { td_aes_hardware() != 0 }

  /// `bytes` encrypted in place, as data units of `unitSize` bytes (a
  /// multiple of 16) numbered from `firstUnit`. `software` makes the
  /// software do it, whatever the CPU has.
  public func encrypt(_ bytes: inout [UInt8], firstUnit: UInt64, unitSize: Int = 4096, software: Bool = false) {
    unsafe bytes.withUnsafeMutableBytes { b in
      unsafe run(b, firstUnit: firstUnit, unitSize: unitSize, decrypt: false, software: software)
    }
  }

  /// `bytes` decrypted in place, likewise.
  public func decrypt(_ bytes: inout [UInt8], firstUnit: UInt64, unitSize: Int = 4096, software: Bool = false) {
    unsafe bytes.withUnsafeMutableBytes { b in
      unsafe run(b, firstUnit: firstUnit, unitSize: unitSize, decrypt: true, software: software)
    }
  }

  /// The same over bytes in memory, where they are.
  public func encrypt(_ bytes: UnsafeMutableRawBufferPointer, firstUnit: UInt64, unitSize: Int = 4096,
                      software: Bool = false) {
    unsafe run(bytes, firstUnit: firstUnit, unitSize: unitSize, decrypt: false, software: software)
  }

  public func decrypt(_ bytes: UnsafeMutableRawBufferPointer, firstUnit: UInt64, unitSize: Int = 4096,
                      software: Bool = false) {
    unsafe run(bytes, firstUnit: firstUnit, unitSize: unitSize, decrypt: true, software: software)
  }

  func run(_ b: UnsafeMutableRawBufferPointer, firstUnit: UInt64, unitSize: Int, decrypt: Bool, software: Bool) {
    precondition(unitSize > 0 && unitSize % 16 == 0 && b.count % unitSize == 0, "whole data units of whole blocks")
    guard let base = b.baseAddress else { return }
    let units = b.count / unitSize, blocks = unitSize / 16
    if !software, Self.hardware {
      unsafe (decrypt ? data.decryption : data.encryption).withUnsafeBufferPointer { k in
        unsafe tweak.encryption.withUnsafeBufferPointer { t in
          for u in 0..<units {
            let p = unsafe (base + u &* unitSize).assumingMemoryBound(to: UInt8.self)
            if decrypt {
              unsafe td_aes_xts_decrypt(k.baseAddress!, t.baseAddress!, firstUnit &+ UInt64(u), p, blocks)
            } else {
              unsafe td_aes_xts_encrypt(k.baseAddress!, t.baseAddress!, firstUnit &+ UInt64(u), p, blocks)
            }
          }
        }
      }
      return
    }
    for u in 0..<units {
      unsafe unit(base + u &* unitSize, blocks: blocks, number: firstUnit &+ UInt64(u), decrypt: decrypt)
    }
  }

  /// One data unit in software, four blocks at a time.
  func unit(_ p: UnsafeMutableRawPointer, blocks: Int, number: UInt64, decrypt: Bool) {
    var s = AESCore.State(repeating: 0)
    s[0] = UInt32(truncatingIfNeeded: number)
    s[1] = UInt32(truncatingIfNeeded: number >> 32)
    AESCore.encrypt(&s, tweak.words)
    var t = (lo: UInt64(s[0]) | UInt64(s[1]) << 32, hi: UInt64(s[2]) | UInt64(s[3]) << 32)
    var at = 0
    while at < blocks {
      let n = Swift.min(4, blocks &- at)
      var tweaks = InlineArray<4, (lo: UInt64, hi: UInt64)>(repeating: (0, 0))
      for k in 0..<n {
        tweaks[k] = t
        let carry = t.hi >> 63
        t.hi = t.hi << 1 | t.lo >> 63
        t.lo = t.lo << 1 ^ (0x87 & (0 &- carry))
      }
      for k in 0..<4 {
        let q = unsafe p + (at &+ k) &* 16
        for c in 0..<4 {
          let tw = c < 2 ? tweaks[k].lo >> (32 &* UInt64(c)) : tweaks[k].hi >> (32 &* UInt64(c &- 2))
          s[4 &* k &+ c] = k < n ? unsafe UInt32(littleEndian: q.loadUnaligned(fromByteOffset: 4 &* c, as: UInt32.self))
            ^ UInt32(truncatingIfNeeded: tw) : 0
        }
      }
      if decrypt { AESCore.decrypt(&s, data.words) } else { AESCore.encrypt(&s, data.words) }
      for k in 0..<n {
        let q = unsafe p + (at &+ k) &* 16
        for c in 0..<4 {
          let tw = c < 2 ? tweaks[k].lo >> (32 &* UInt64(c)) : tweaks[k].hi >> (32 &* UInt64(c &- 2))
          unsafe q.storeBytes(of: (s[4 &* k &+ c] ^ UInt32(truncatingIfNeeded: tw)).littleEndian,
                              toByteOffset: 4 &* c, as: UInt32.self)
        }
      }
      at &+= n
    }
  }
}

/// The software cipher's rounds over four blocks.
enum AESCore {
  /// Four blocks: block k's column c is word 4k + c, byte r of it row r.
  typealias State = InlineArray<16, UInt32>
  typealias Planes = InlineArray<8, UInt64>

  static func word(_ b: [UInt8], _ at: Int) -> UInt32 {
    UInt32(b[at]) | UInt32(b[at &+ 1]) << 8 | UInt32(b[at &+ 2]) << 16 | UInt32(b[at &+ 3]) << 24
  }

  static func bytes(_ w: [UInt32]) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(w.count &* 4)
    for x in w { for k in 0..<4 { out.append(UInt8(truncatingIfNeeded: x >> (8 &* UInt32(k)))) } }
    return out
  }

  static func bytes(_ s: State, count: Int) -> [UInt8] {
    var out: [UInt8] = []
    for i in 0..<count { for k in 0..<4 { out.append(UInt8(truncatingIfNeeded: s[i] >> (8 &* UInt32(k)))) } }
    return out
  }

  /// Each byte of `w` times x in GF(2^8).
  @inline(__always) static func xtime(_ w: UInt32) -> UInt32 {
    ((w & 0x7F7F_7F7F) << 1) ^ (((w >> 7) & 0x0101_0101) &* 0x1B)
  }

  /// Byte r of the result is byte r + k of `w` (mod 4).
  @inline(__always) static func rot(_ w: UInt32, _ k: UInt32) -> UInt32 { w >> (8 &* k) | w << (32 &- 8 &* k) }

  @inline(__always) static func mixColumn(_ w: UInt32) -> UInt32 {
    let r1 = rot(w, 1)
    return xtime(w ^ r1) ^ r1 ^ rot(w, 2) ^ rot(w, 3)
  }

  /// InvMixColumns as MixColumns after a multiply by {04}x^2 + {05} (FIPS
  /// 197's matrix factors so).
  @inline(__always) static func invMixColumn(_ w: UInt32) -> UInt32 {
    let t = xtime(xtime(w ^ rot(w, 2)))
    return mixColumn(w ^ t)
  }

  static func subWord(_ w: UInt32) -> UInt32 {
    var s = State(repeating: 0)
    s[0] = w
    subBytes(&s, inverse: false)
    return s[0]
  }

  /// An 8x8 bit matrix transposed: bit c of byte r to bit r of byte c.
  @inline(__always) static func transpose(_ x: UInt64) -> UInt64 {
    var x = x
    var t = (x ^ (x >> 7)) & 0x00AA_00AA_00AA_00AA
    x = x ^ t ^ (t << 7)
    t = (x ^ (x >> 14)) & 0x0000_CCCC_0000_CCCC
    x = x ^ t ^ (t << 14)
    t = (x ^ (x >> 28)) & 0x0000_0000_F0F0_F0F0
    return x ^ t ^ (t << 28)
  }

  /// SubBytes (or its inverse) of every byte of the state.
  static func subBytes(_ s: inout State, inverse: Bool) {
    var p = Planes(repeating: 0)
    for k in 0..<8 {
      let x = transpose(UInt64(s[2 &* k]) | UInt64(s[2 &* k &+ 1]) << 32)
      for b in 0..<8 { p[b] |= (x >> (8 &* UInt64(b)) & 0xFF) << (8 &* UInt64(k)) }
    }
    if inverse {
      inverseAffine(&p)
      sbox(&p)
      inverseAffine(&p)
    } else {
      sbox(&p)
    }
    for k in 0..<8 {
      var x: UInt64 = 0
      for b in 0..<8 { x |= (p[b] >> (8 &* UInt64(k)) & 0xFF) << (8 &* UInt64(b)) }
      x = transpose(x)
      s[2 &* k] = UInt32(truncatingIfNeeded: x)
      s[2 &* k &+ 1] = UInt32(truncatingIfNeeded: x >> 32)
    }
  }

  /// The S-box's affine map undone (FIPS 197 §5.3.2): bit i of the result
  /// is bits i + 2, i + 5 and i + 7, plus {05}. Between two of them the
  /// S-box is the inverse S-box.
  static func inverseAffine(_ p: inout Planes) {
    var q = Planes(repeating: 0)
    for i in 0..<8 { q[i] = p[(i &+ 2) & 7] ^ p[(i &+ 5) & 7] ^ p[(i &+ 7) & 7] }
    q[0] = ~q[0]
    q[2] = ~q[2]
    p = q
  }

  /// The S-box of 64 bytes at once, plane b holding their bits b: Boyar and
  /// Peralta's circuit, its inputs x0 (the high bit) to x7.
  static func sbox(_ q: inout Planes) {
    let x0 = q[7], x1 = q[6], x2 = q[5], x3 = q[4], x4 = q[3], x5 = q[2], x6 = q[1], x7 = q[0]
    // The top linear map.
    let y14 = x3 ^ x5, y13 = x0 ^ x6, y9 = x0 ^ x3, y8 = x0 ^ x5
    let t0 = x1 ^ x2
    let y1 = t0 ^ x7
    let y4 = y1 ^ x3, y12 = y13 ^ y14, y2 = y1 ^ x0, y5 = y1 ^ x6
    let y3 = y5 ^ y8
    let t1 = x4 ^ y12
    let y15 = t1 ^ x5, y20 = t1 ^ x1
    let y6 = y15 ^ x7, y10 = y15 ^ t0, y11 = y20 ^ y9
    let y7 = x7 ^ y11, y17 = y10 ^ y11, y19 = y10 ^ y8, y16 = t0 ^ y11
    let y21 = y13 ^ y16, y18 = x0 ^ y16
    // The non-linear middle: inversion in GF(2^4)^2.
    let t2 = y12 & y15, t3 = y3 & y6
    let t4 = t3 ^ t2
    let t5 = y4 & x7
    let t6 = t5 ^ t2
    let t7 = y13 & y16, t8 = y5 & y1
    let t9 = t8 ^ t7
    let t10 = y2 & y7
    let t11 = t10 ^ t7
    let t12 = y9 & y11, t13 = y14 & y17
    let t14 = t13 ^ t12
    let t15 = y8 & y10
    let t16 = t15 ^ t12
    let t17 = t4 ^ t14, t18 = t6 ^ t16, t19 = t9 ^ t14, t20 = t11 ^ t16
    let t21 = t17 ^ y20, t22 = t18 ^ y19, t23 = t19 ^ y21, t24 = t20 ^ y18
    let t25 = t21 ^ t22, t26 = t21 & t23
    let t27 = t24 ^ t26
    let t28 = t25 & t27
    let t29 = t28 ^ t22
    let t30 = t23 ^ t24, t31 = t22 ^ t26
    let t32 = t31 & t30
    let t33 = t32 ^ t24
    let t34 = t23 ^ t33, t35 = t27 ^ t33
    let t36 = t24 & t35
    let t37 = t36 ^ t34, t38 = t27 ^ t36
    let t39 = t29 & t38
    let t40 = t25 ^ t39
    let t41 = t40 ^ t37, t42 = t29 ^ t33, t43 = t29 ^ t40, t44 = t33 ^ t37
    let t45 = t42 ^ t41
    let z0 = t44 & y15, z1 = t37 & y6, z2 = t33 & x7, z3 = t43 & y16, z4 = t40 & y1, z5 = t29 & y7
    let z6 = t42 & y11, z7 = t45 & y17, z8 = t41 & y10, z9 = t44 & y12, z10 = t37 & y3, z11 = t33 & y4
    let z12 = t43 & y13, z13 = t40 & y5, z14 = t29 & y2, z15 = t42 & y9, z16 = t45 & y14, z17 = t41 & y8
    // The bottom linear map.
    let t46 = z15 ^ z16, t47 = z10 ^ z11, t48 = z5 ^ z13, t49 = z9 ^ z10, t50 = z2 ^ z12, t51 = z2 ^ z5
    let t52 = z7 ^ z8, t53 = z0 ^ z3, t54 = z6 ^ z7, t55 = z16 ^ z17
    let t56 = z12 ^ t48, t57 = t50 ^ t53, t58 = z4 ^ t46, t59 = z3 ^ t54
    let t60 = t46 ^ t57, t61 = z14 ^ t57, t62 = t52 ^ t58, t63 = t49 ^ t58, t64 = z4 ^ t59
    let t65 = t61 ^ t62, t66 = z1 ^ t63
    let s0 = t59 ^ t63, s6 = t56 ^ ~t62, s7 = t48 ^ ~t60
    let t67 = t64 ^ t65
    let s3 = t53 ^ t66, s4 = t51 ^ t66, s5 = t47 ^ t65
    let s1 = t64 ^ ~s3, s2 = t55 ^ ~t67
    q[7] = s0
    q[6] = s1
    q[5] = s2
    q[4] = s3
    q[3] = s4
    q[2] = s5
    q[1] = s6
    q[0] = s7
  }

  @inline(__always) static func addRoundKey(_ s: inout State, _ w: [UInt32], _ round: Int) {
    for k in 0..<4 { for c in 0..<4 { s[4 &* k &+ c] ^= w[4 &* round &+ c] } }
  }

  static func shiftRows(_ s: inout State, inverse: Bool) {
    for k in 0..<4 {
      let c0 = s[4 &* k], c1 = s[4 &* k &+ 1], c2 = s[4 &* k &+ 2], c3 = s[4 &* k &+ 3]
      @inline(__always) func pick(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> UInt32 {
        a & 0xFF | b & 0xFF00 | c & 0xFF_0000 | d & 0xFF00_0000
      }
      if inverse {
        s[4 &* k] = pick(c0, c3, c2, c1)
        s[4 &* k &+ 1] = pick(c1, c0, c3, c2)
        s[4 &* k &+ 2] = pick(c2, c1, c0, c3)
        s[4 &* k &+ 3] = pick(c3, c2, c1, c0)
      } else {
        s[4 &* k] = pick(c0, c1, c2, c3)
        s[4 &* k &+ 1] = pick(c1, c2, c3, c0)
        s[4 &* k &+ 2] = pick(c2, c3, c0, c1)
        s[4 &* k &+ 3] = pick(c3, c0, c1, c2)
      }
    }
  }

  static func encrypt(_ s: inout State, _ w: [UInt32]) {
    addRoundKey(&s, w, 0)
    for round in 1..<14 {
      subBytes(&s, inverse: false)
      shiftRows(&s, inverse: false)
      for i in 0..<16 { s[i] = mixColumn(s[i]) }
      addRoundKey(&s, w, round)
    }
    subBytes(&s, inverse: false)
    shiftRows(&s, inverse: false)
    addRoundKey(&s, w, 14)
  }

  /// The inverse cipher (FIPS 197 §5.3), with the encryption's round keys.
  static func decrypt(_ s: inout State, _ w: [UInt32]) {
    addRoundKey(&s, w, 14)
    for round in stride(from: 13, through: 1, by: -1) {
      shiftRows(&s, inverse: true)
      subBytes(&s, inverse: true)
      addRoundKey(&s, w, round)
      for i in 0..<16 { s[i] = invMixColumn(s[i]) }
    }
    shiftRows(&s, inverse: true)
    subBytes(&s, inverse: true)
    addRoundKey(&s, w, 0)
  }
}
