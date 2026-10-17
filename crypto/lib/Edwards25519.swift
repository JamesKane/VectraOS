// SPDX-License-Identifier: BSD-3-Clause

// The twisted Edwards curve -x^2 + y^2 = 1 + d x^2 y^2 over Field25519
// (RFC 8032 §5.1), Ed25519's group (N1a). Ours, tier 0.
//
// Points are extended coordinates (X:Y:Z:T, x = X/Z, y = Y/Z, xy = T/Z;
// Hisil, Wong, Carter and Dawson, "Twisted Edwards Curves Revisited",
// 2008, §3.1 with a = -1), whose addition is complete: the same formula
// for every pair, the identity and doubling included. The constants (d,
// sqrt(-1), the base point) are computed from their definitions.
//
// A scalar multiple takes 4-bit windows from the top, four doublings and
// one addition each, the window's multiple read from a table of 16 by
// masks over every entry: the same work and memory accesses for every
// scalar.

struct EdwardsPoint {
  var x, y, z, t: Field25519

  init(x: Field25519, y: Field25519, z: Field25519, t: Field25519) {
    self.x = x
    self.y = y
    self.z = z
    self.t = t
  }

  static let identity = EdwardsPoint(x: .zero, y: .one, z: .one, t: .zero)

  /// d = -121665 / 121666.
  static let d = -(Field25519(121_665, 0, 0, 0, 0) * Field25519(121_666, 0, 0, 0, 0).inverse)
  static let d2 = d + d

  /// sqrt(-1) = 2^((p - 1) / 4), and (p - 1) / 4 = 2 (2^252 - 3) + 1.
  static let sqrtMinusOne: Field25519 = {
    let two = Field25519(2, 0, 0, 0, 0)
    return two.powP58.squared * two
  }()

  /// B: y = 4/5, x even (RFC 8032 §5.1).
  static let base: EdwardsPoint = {
    let y = Field25519(4, 0, 0, 0, 0) * Field25519(5, 0, 0, 0, 0).inverse
    return EdwardsPoint(bytes: y.bytes)!
  }()

  /// Decodes 32 bytes (RFC 8032 §5.1.3), or nil if they aren't a point:
  /// y not below p, x^2 with no root, or x = 0 with its sign bit set.
  /// Public values only (the checks exit early).
  init?(bytes b: [UInt8]) {
    precondition(b.count == 32)
    let y = Field25519(bytes: b.span)
    var canonical = b
    canonical[31] &= 0x7F
    guard y.bytes == canonical else { return nil }
    let sign = b[31] >> 7
    let yy = y.squared
    let u = yy - .one, v = EdwardsPoint.d * yy + .one
    let v3 = v.squared * v
    var x = u * v3 * (u * v3.squared * v).powP58  // u v^3 (u v^7)^((p-5)/8)
    let vxx = v * x.squared
    if !vxx.equals(u) {
      guard vxx.equals(-u) else { return nil }
      x = x * EdwardsPoint.sqrtMinusOne
    }
    if x.isZero && sign == 1 { return nil }
    if (x.isNegative ? 1 : 0) != sign { x = -x }
    self.init(x: x, y: y, z: .one, t: x * y)
  }

  /// The 32-byte encoding: y, with x's sign in the top bit.
  var bytes: [UInt8] {
    let zi = z.inverse
    var out = (y * zi).bytes
    out[31] |= ((x * zi).bytes[0] & 1) << 7
    return out
  }

  static func + (p: EdwardsPoint, q: EdwardsPoint) -> EdwardsPoint {
    let a = (p.y - p.x) * (q.y - q.x)
    let b = (p.y + p.x) * (q.y + q.x)
    let c = p.t * d2 * q.t
    let zz = p.z * q.z
    let dd = zz + zz
    let e = b - a, f = dd - c, g = dd + c, h = b + a
    return EdwardsPoint(x: e * f, y: g * h, z: f * g, t: e * h)
  }

  /// 2P, by the doubling formula (a = -1), cheaper than P + P.
  var doubled: EdwardsPoint {
    let a = x.squared, b = y.squared
    let zz = z.squared
    let c = zz + zz
    let h = a + b
    let e = h - (x + y).squared
    let g = a - b
    let f = c + g
    return EdwardsPoint(x: e * f, y: g * h, z: f * g, t: e * h)
  }

  static prefix func - (p: EdwardsPoint) -> EdwardsPoint { EdwardsPoint(x: -p.x, y: p.y, z: p.z, t: -p.t) }

  /// `scalar` (32 little-endian bytes, any value) times this point.
  func times(_ scalar: [UInt8]) -> EdwardsPoint {
    precondition(scalar.count == 32)
    var table = InlineArray<16, EdwardsPoint>(repeating: .identity)
    for i in 1..<16 { table[i] = table[i - 1] + self }
    var r = EdwardsPoint.identity
    for w in stride(from: 63, through: 0, by: -1) {
      r = r.doubled.doubled.doubled.doubled
      let nibble = UInt64(scalar[w >> 1] >> UInt8(4 * (w & 1))) & 15
      var m = EdwardsPoint.identity
      for i in 0..<16 {
        // All ones where i is the nibble: (i ^ nibble) - 1 borrows only at 0.
        let mask = 0 &- ((UInt64(i) ^ nibble) &- 1) >> 63
        m.select(table[i], mask)
      }
      r = r + m
    }
    return r
  }

  /// Takes `other`'s coordinates where `mask` is all ones.
  mutating func select(_ other: EdwardsPoint, _ mask: UInt64) {
    for i in 0..<5 {
      x.l[i] ^= mask & (x.l[i] ^ other.x.l[i])
      y.l[i] ^= mask & (y.l[i] ^ other.y.l[i])
      z.l[i] ^= mask & (z.l[i] ^ other.z.l[i])
      t.l[i] ^= mask & (t.l[i] ^ other.t.l[i])
    }
  }
}
