// SPDX-License-Identifier: BSD-3-Clause

// ChaCha20 and Poly1305 (N1a): ours, tier 0, from RFC 8439.
//
// ChaCha20's state is sixteen 32-bit words: four constants, the 256-bit
// key, then a 32-bit counter and a 96-bit nonce. Twenty rounds of
// quarter rounds, the input added back, give a 64-byte block of key
// stream. Adds, rotations and xors only: its time depends on nothing
// secret.
//
// Poly1305 evaluates the message, in 16-byte pieces with a 1 appended,
// as a polynomial at r (the key's first half, clamped) modulo 2^130 - 5,
// and adds s (its second half). Here in five 26-bit limbs with 64-bit
// products; the last reduction is by masks, not branches.

public enum ChaCha20 {
  /// "expand 32-byte k".
  static let sigma: InlineArray<4, UInt32> = [0x6170_7865, 0x3320_646E, 0x7962_2D32, 0x6B20_6574]

  @inline(__always) static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { x << n | x >> (32 - n) }

  @inline(__always) static func le32(_ b: borrowing Span<UInt8>, _ i: Int) -> UInt32 {
    UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
  }

  /// The 64-byte block for `key` (32 bytes) and state words 12-15
  /// (the counter and nonce, as the form in use lays them out).
  static func block(key: borrowing Span<UInt8>, _ w12: UInt32, _ w13: UInt32, _ w14: UInt32, _ w15: UInt32)
    -> InlineArray<64, UInt8>
  {
    var x = InlineArray<16, UInt32>(repeating: 0)
    for i in 0..<4 { x[i] = sigma[i] }
    for i in 0..<8 { x[4 + i] = le32(key, 4 * i) }
    x[12] = w12
    x[13] = w13
    x[14] = w14
    x[15] = w15
    var s = x
    @inline(__always) func quarter(_ a: Int, _ b: Int, _ c: Int, _ d: Int) {
      s[a] &+= s[b]; s[d] ^= s[a]; s[d] = rotl(s[d], 16)
      s[c] &+= s[d]; s[b] ^= s[c]; s[b] = rotl(s[b], 12)
      s[a] &+= s[b]; s[d] ^= s[a]; s[d] = rotl(s[d], 8)
      s[c] &+= s[d]; s[b] ^= s[c]; s[b] = rotl(s[b], 7)
    }
    for _ in 0..<10 {
      quarter(0, 4, 8, 12); quarter(1, 5, 9, 13); quarter(2, 6, 10, 14); quarter(3, 7, 11, 15)
      quarter(0, 5, 10, 15); quarter(1, 6, 11, 12); quarter(2, 7, 8, 13); quarter(3, 4, 9, 14)
    }
    var out = InlineArray<64, UInt8>(repeating: 0)
    for i in 0..<16 {
      let v = s[i] &+ x[i]
      for b in 0..<4 { out[4 * i + b] = UInt8(truncatingIfNeeded: v >> UInt32(8 * b)) }
    }
    return out
  }

  /// RFC 8439's block function: `nonce` 12 bytes.
  public static func block(key: [UInt8], counter: UInt32, nonce: [UInt8]) -> [UInt8] {
    precondition(key.count == 32 && nonce.count == 12)
    let n = nonce.span
    let b = block(key: key.span, counter, le32(n, 0), le32(n, 4), le32(n, 8))
    return (0..<64).map { b[$0] }
  }

  /// `data` xored with RFC 8439's key stream from block `counter` (key 32
  /// bytes, nonce 12).
  public static func xor(_ data: [UInt8], key: [UInt8], nonce: [UInt8], counter: UInt32) -> [UInt8] {
    precondition(key.count == 32 && nonce.count == 12)
    let n = nonce.span
    let (n0, n1, n2) = (le32(n, 0), le32(n, 4), le32(n, 8))
    return stream(data, key: key) { i in (counter &+ UInt32(truncatingIfNeeded: i), n0, n1, n2) }
  }

  static func stream(_ data: [UInt8], key: [UInt8],
                     words: (Int) -> (UInt32, UInt32, UInt32, UInt32)) -> [UInt8]
  {
    var out = data
    var i = 0, blockIndex = 0
    while i < data.count {
      let (a, b, c, d) = words(blockIndex)
      let ks = block(key: key.span, a, b, c, d)
      let n = min(64, data.count - i)
      for j in 0..<n { out[i + j] ^= ks[j] }
      i += n
      blockIndex += 1
    }
    return out
  }
}

/// Poly1305 (RFC 8439 §2.5), a one-time authenticator: a key is used for
/// one message only.
public struct Poly1305 {
  public static let tagSize = 16

  var r = InlineArray<5, UInt32>(repeating: 0)
  var h = InlineArray<5, UInt32>(repeating: 0)
  var pad = InlineArray<4, UInt32>(repeating: 0)
  var buffer = InlineArray<16, UInt8>(repeating: 0)
  var filled = 0

  /// For `key` (32 bytes: r, then s).
  public init(key: [UInt8]) {
    precondition(key.count == 32)
    let k = key.span
    // r clamped (§2.5.1), in 26-bit limbs.
    let t0 = ChaCha20.le32(k, 0), t1 = ChaCha20.le32(k, 4), t2 = ChaCha20.le32(k, 8), t3 = ChaCha20.le32(k, 12)
    r[0] = t0 & 0x3FF_FFFF
    r[1] = ((t0 >> 26) | (t1 << 6)) & 0x3FF_FF03
    r[2] = ((t1 >> 20) | (t2 << 12)) & 0x3FF_C0FF
    r[3] = ((t2 >> 14) | (t3 << 18)) & 0x3F0_3FFF
    r[4] = (t3 >> 8) & 0x00F_FFFF
    for i in 0..<4 { pad[i] = ChaCha20.le32(k, 16 + 4 * i) }
  }

  /// Adds `input` to the message.
  public mutating func update(_ input: [UInt8]) {
    var i = 0
    if filled > 0 {
      while filled < 16 && i < input.count {
        buffer[filled] = input[i]
        filled += 1
        i += 1
      }
      if filled < 16 { return }
      blocks(buffer, final: false)
      filled = 0
    }
    while input.count - i >= 16 {
      var b = InlineArray<16, UInt8>(repeating: 0)
      for k in 0..<16 { b[k] = input[i + k] }
      blocks(b, final: false)
      i += 16
    }
    while i < input.count {
      buffer[filled] = input[i]
      filled += 1
      i += 1
    }
  }

  /// One 16-byte piece: h = (h + piece with its high bit) * r mod 2^130 - 5.
  /// A short last piece is padded with 1 then zeros, without the bit
  /// above it (`final`).
  mutating func blocks(_ m: InlineArray<16, UInt8>, final: Bool) {
    func le(_ i: Int) -> UInt32 {
      UInt32(m[i]) | UInt32(m[i + 1]) << 8 | UInt32(m[i + 2]) << 16 | UInt32(m[i + 3]) << 24
    }
    let hibit: UInt32 = final ? 0 : 1 << 24
    let t0 = le(0), t1 = le(4), t2 = le(8), t3 = le(12)
    let h0 = UInt64(h[0] &+ (t0 & 0x3FF_FFFF))
    let h1 = UInt64(h[1] &+ (((t0 >> 26) | (t1 << 6)) & 0x3FF_FFFF))
    let h2 = UInt64(h[2] &+ (((t1 >> 20) | (t2 << 12)) & 0x3FF_FFFF))
    let h3 = UInt64(h[3] &+ (((t2 >> 14) | (t3 << 18)) & 0x3FF_FFFF))
    let h4 = UInt64(h[4] &+ ((t3 >> 8) | hibit))
    let r0 = UInt64(r[0]), r1 = UInt64(r[1]), r2 = UInt64(r[2]), r3 = UInt64(r[3]), r4 = UInt64(r[4])
    // 2^130 = 5 mod p: a limb past the top comes back times 5.
    let s1 = r1 &* 5, s2 = r2 &* 5, s3 = r3 &* 5, s4 = r4 &* 5
    let d0 = h0 &* r0 &+ h1 &* s4 &+ h2 &* s3 &+ h3 &* s2 &+ h4 &* s1
    var d1 = h0 &* r1 &+ h1 &* r0 &+ h2 &* s4 &+ h3 &* s3 &+ h4 &* s2
    var d2 = h0 &* r2 &+ h1 &* r1 &+ h2 &* r0 &+ h3 &* s4 &+ h4 &* s3
    var d3 = h0 &* r3 &+ h1 &* r2 &+ h2 &* r1 &+ h3 &* r0 &+ h4 &* s4
    var d4 = h0 &* r4 &+ h1 &* r3 &+ h2 &* r2 &+ h3 &* r1 &+ h4 &* r0
    // Carry back into 26-bit limbs.
    var c = d0 >> 26
    var n0 = d0 & 0x3FF_FFFF
    d1 &+= c; c = d1 >> 26; let n1 = d1 & 0x3FF_FFFF
    d2 &+= c; c = d2 >> 26; let n2 = d2 & 0x3FF_FFFF
    d3 &+= c; c = d3 >> 26; let n3 = d3 & 0x3FF_FFFF
    d4 &+= c; c = d4 >> 26; let n4 = d4 & 0x3FF_FFFF
    n0 &+= c &* 5
    let carry = n0 >> 26
    n0 &= 0x3FF_FFFF
    h[0] = UInt32(n0)
    h[1] = UInt32(n1 &+ carry)
    h[2] = UInt32(n2)
    h[3] = UInt32(n3)
    h[4] = UInt32(n4)
  }

  /// The 16-byte tag.
  public func finalize() -> [UInt8] {
    var m = self
    if m.filled > 0 {
      var b = InlineArray<16, UInt8>(repeating: 0)
      for k in 0..<m.filled { b[k] = m.buffer[k] }
      b[m.filled] = 1
      m.blocks(b, final: true)
    }
    // Fully carried.
    var h0 = m.h[0], h1 = m.h[1], h2 = m.h[2], h3 = m.h[3], h4 = m.h[4]
    var c = h1 >> 26; h1 &= 0x3FF_FFFF
    h2 &+= c; c = h2 >> 26; h2 &= 0x3FF_FFFF
    h3 &+= c; c = h3 >> 26; h3 &= 0x3FF_FFFF
    h4 &+= c; c = h4 >> 26; h4 &= 0x3FF_FFFF
    h0 &+= c &* 5; c = h0 >> 26; h0 &= 0x3FF_FFFF
    h1 &+= c
    // g = h + 5 - 2^130: h if g is negative, else g. By a mask, not a branch.
    var g0 = h0 &+ 5; c = g0 >> 26; g0 &= 0x3FF_FFFF
    var g1 = h1 &+ c; c = g1 >> 26; g1 &= 0x3FF_FFFF
    var g2 = h2 &+ c; c = g2 >> 26; g2 &= 0x3FF_FFFF
    var g3 = h3 &+ c; c = g3 >> 26; g3 &= 0x3FF_FFFF
    let g4 = h4 &+ c &- (1 << 26)
    let useG = (g4 >> 31) &- 1  // all ones if g4 didn't go negative
    let useH = ~useG
    h0 = (h0 & useH) | (g0 & useG)
    h1 = (h1 & useH) | (g1 & useG)
    h2 = (h2 & useH) | (g2 & useG)
    h3 = (h3 & useH) | (g3 & useG)
    h4 = (h4 & useH) | (g4 & useG)
    // Back to four 32-bit words, plus s, mod 2^128.
    let w0 = h0 | h1 << 26
    let w1 = h1 >> 6 | h2 << 20
    let w2 = h2 >> 12 | h3 << 14
    let w3 = h3 >> 18 | h4 << 8
    var f = UInt64(w0) &+ UInt64(m.pad[0])
    var out = [UInt8](repeating: 0, count: 16)
    func put(_ v: UInt64, _ at: Int) { for b in 0..<4 { out[at + b] = UInt8(truncatingIfNeeded: v >> UInt64(8 * b)) } }
    put(f, 0)
    f = UInt64(w1) &+ UInt64(m.pad[1]) &+ (f >> 32); put(f, 4)
    f = UInt64(w2) &+ UInt64(m.pad[2]) &+ (f >> 32); put(f, 8)
    f = UInt64(w3) &+ UInt64(m.pad[3]) &+ (f >> 32); put(f, 12)
    return out
  }

  /// The tag of `message` under `key`.
  public static func authenticate(_ message: [UInt8], key: [UInt8]) -> [UInt8] {
    var p = Poly1305(key: key)
    p.update(message)
    return p.finalize()
  }
}

/// ChaCha20-Poly1305, RFC 8439 §2.8's AEAD: a 32-byte key, a 12-byte
/// nonce never reused under it.
public enum ChaCha20Poly1305 {
  /// Poly1305's input: the AAD, padded to 16; the ciphertext, padded; the
  /// two lengths, 64-bit little-endian.
  static func tag(_ aad: [UInt8], _ ciphertext: [UInt8], key: [UInt8], nonce: [UInt8]) -> [UInt8] {
    let otk = Array(ChaCha20.block(key: key, counter: 0, nonce: nonce).prefix(32))
    var p = Poly1305(key: otk)
    func padded(_ b: [UInt8]) {
      p.update(b)
      if b.count % 16 != 0 { p.update([UInt8](repeating: 0, count: 16 - b.count % 16)) }
    }
    padded(aad)
    padded(ciphertext)
    var lengths = [UInt8](repeating: 0, count: 16)
    for i in 0..<8 {
      lengths[i] = UInt8(truncatingIfNeeded: UInt64(aad.count) >> UInt64(8 * i))
      lengths[8 + i] = UInt8(truncatingIfNeeded: UInt64(ciphertext.count) >> UInt64(8 * i))
    }
    p.update(lengths)
    return p.finalize()
  }

  /// The ciphertext, then the 16-byte tag.
  public static func seal(_ plaintext: [UInt8], key: [UInt8], nonce: [UInt8], aad: [UInt8] = []) -> [UInt8] {
    let ciphertext = ChaCha20.xor(plaintext, key: key, nonce: nonce, counter: 1)
    return ciphertext + tag(aad, ciphertext, key: key, nonce: nonce)
  }

  /// The plaintext, or nil if the tag (the last 16 bytes) is wrong.
  public static func open(_ sealed: [UInt8], key: [UInt8], nonce: [UInt8], aad: [UInt8] = []) -> [UInt8]? {
    guard sealed.count >= 16 else { return nil }
    let ciphertext = Array(sealed.dropLast(16))
    guard constantTimeEqual(tag(aad, ciphertext, key: key, nonce: nonce), Array(sealed.suffix(16))) else { return nil }
    return ChaCha20.xor(ciphertext, key: key, nonce: nonce, counter: 1)
  }
}
