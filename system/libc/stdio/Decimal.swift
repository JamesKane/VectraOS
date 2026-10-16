// SPDX-License-Identifier: BSD-3-Clause

// A binary floating value's exact decimal digits (M6c; long double's in
// M6d), for printf's %f, %e and %g: the value is m × 2^e, a binary fraction
// that terminates, so its decimal expansion does too (a double's at most
// 1074 digits after the point and 309 before; a long double's 16494 and
// 4933).
// The integer part's digits come from dividing a big integer by 10^9; the
// fraction's from multiplying its numerator (over 2^k) by 10^9 and taking
// what rises above the point. What is left after the digits wanted decides
// the rounding exactly (C23 §7.23.6.1: correctly rounded in the current
// rounding mode, to nearest with ties to even). Runtime-free: fixed-size
// storage on the stack.

/// A non-negative integer of up to `capacity` × 32 bits, little-endian
/// limbs: each format's conversions pick a capacity that holds their
/// largest values (Strtod.swift, Format.swift), so a double's stay small.
struct Big<let capacity: Int> {
  var limbs = InlineArray<capacity, UInt32>(repeating: 0)
  var count = 0  // limbs in use; the top one nonzero, or count == 0

  init() {}

  init(_ v: UInt128) {
    var v = v
    while v != 0 {
      limbs[count] = UInt32(truncatingIfNeeded: v)
      v >>= 32
      count += 1
    }
  }

  var isZero: Bool { count == 0 }

  mutating func trim() { while count > 0 && limbs[count - 1] == 0 { count -= 1 } }

  /// self <<= n.
  mutating func shiftLeft(_ n: Int) {
    guard count > 0, n > 0 else { return }
    let words = n / 32, bits = n % 32
    var i = count - 1 + words + 1
    while i >= 0 {
      let src = i - words
      var v: UInt32 = 0
      if src >= 0 && src < count { v = bits == 0 ? limbs[src] : limbs[src] << UInt32(bits) }
      if bits != 0 && src - 1 >= 0 && src - 1 < count { v |= limbs[src - 1] >> UInt32(32 - bits) }
      if i < capacity { limbs[i] = v }
      i -= 1
    }
    count = min(capacity, count + words + 1)
    trim()
  }

  /// self = self × m + add; m and add small.
  mutating func multiply(_ m: UInt32, add: UInt32 = 0) {
    var carry = UInt64(add)
    for i in 0..<count {
      let p = UInt64(limbs[i]) * UInt64(m) + carry
      limbs[i] = UInt32(truncatingIfNeeded: p)
      carry = p >> 32
    }
    if carry != 0 && count < capacity {
      limbs[count] = UInt32(carry)
      count += 1
    }
  }

  /// self /= d, returning the remainder.
  mutating func divide(_ d: UInt32) -> UInt32 {
    var rem: UInt64 = 0
    var i = count - 1
    while i >= 0 {
      let cur = rem << 32 | UInt64(limbs[i])
      limbs[i] = UInt32(cur / UInt64(d))
      rem = cur % UInt64(d)
      i -= 1
    }
    trim()
    return UInt32(rem)
  }

  /// The bits of self at and above `k`, removed from self (self < 2^(k+32)).
  mutating func takeAbove(_ k: Int) -> UInt32 {
    let word = k / 32, bit = k % 32
    var v: UInt64 = 0
    if word < count { v = UInt64(limbs[word]) >> UInt64(bit) }
    if word + 1 < count { v |= UInt64(limbs[word + 1]) << UInt64(32 - bit) }
    if word + 2 < count && bit != 0 { v |= UInt64(limbs[word + 2]) << UInt64(64 - bit) }
    // Clear them.
    if word < count {
      limbs[word] &= bit == 0 ? 0 : (UInt32(1) << UInt32(bit)) &- 1
      var i = word + 1
      while i < count {
        limbs[i] = 0
        i += 1
      }
    }
    trim()
    return UInt32(truncatingIfNeeded: v)
  }

  /// Compares self with 2^k: -1, 0 or 1.
  func compare(powerOfTwo k: Int) -> Int {
    let word = k / 32, bit = k % 32
    if count - 1 > word { return 1 }
    if count - 1 < word { return -1 }
    let top = limbs[word], want = UInt32(1) << UInt32(bit)
    if top != want { return top > want ? 1 : -1 }
    var i = word - 1
    while i >= 0 {
      if limbs[i] != 0 { return 1 }
      i -= 1
    }
    return 0
  }
}

/// What follows the digits produced, as a fraction of their last place.
/// Constants, not an enum: an enum's derived Hashable brings the hasher's
/// seed (arc4random_buf) into programs that keep every function.
struct Tail: Equatable {
  let raw: UInt8
  static let zero = Tail(raw: 0), belowHalf = Tail(raw: 1), half = Tail(raw: 2), aboveHalf = Tail(raw: 3)
}

/// A value's decimal digits (its magnitude, m × 2^e): the integer part's,
/// then up to `fractionDigits` of the fraction's, and what follows them.
/// `capacity` digits at most, over Big<limbs> (which also bounds the integer
/// part's 9-digit chunks: 10^9 < 2^32, and 32 × log10(2) / 9 < 1.08, so
/// limbs sized with 8% to spare hold them).
struct Digits<let capacity: Int, let limbs: Int> {
  /// ASCII digits, most significant first; `point` of them before the point.
  var buffer = InlineArray<capacity, UInt8>(repeating: 0)
  var count = 0
  var point = 0
  var tail = Tail.zero

  /// mantissa × 2^exponent's digits: `fractionDigits` past the point, at
  /// most what fits.
  init(mantissa: UInt128, exponent: Int, fractionDigits: Int) {
    // The integer part.
    var integer = Big<limbs>()
    var fraction = Big<limbs>()
    var k = 0  // fraction = numerator / 2^k
    if exponent >= 0 {
      integer = Big(mantissa)
      integer.shiftLeft(exponent)
    } else if exponent > -128 {
      integer = Big(mantissa >> UInt128(-exponent))
      fraction = Big(mantissa & ((UInt128(1) << UInt128(-exponent)) - 1))
      k = -exponent
    } else {
      fraction = Big(mantissa)
      k = -exponent
    }
    // Integer digits, by 10^9 at a time, least significant first.
    var chunks = InlineArray<limbs, UInt32>(repeating: 0)
    var chunkCount = 0
    while !integer.isZero {
      chunks[chunkCount] = integer.divide(1_000_000_000)
      chunkCount += 1
    }
    if chunkCount == 0 {
      append(0x30)
    } else {
      var c = chunkCount - 1
      var leading = true
      while c >= 0 {
        var chunk = chunks[c]
        var d = InlineArray<9, UInt8>(repeating: 0)
        for j in 0..<9 {
          d[8 - j] = UInt8(chunk % 10)
          chunk /= 10
        }
        for j in 0..<9 where !(leading && d[j] == 0 && !(c == 0 && j == 8)) {
          leading = false
          append(0x30 + d[j])
        }
        c -= 1
      }
    }
    point = count
    // Fraction digits, by 10^9 at a time.
    var wanted = min(fractionDigits, capacity - count)
    while wanted > 0 && !fraction.isZero {
      fraction.multiply(1_000_000_000)
      var chunk = fraction.takeAbove(k)
      var d = InlineArray<9, UInt8>(repeating: 0)
      for j in 0..<9 {
        d[8 - j] = UInt8(chunk % 10)
        chunk /= 10
      }
      let take = min(9, wanted)
      for j in 0..<take { append(0x30 + d[j]) }
      wanted -= take
      if take < 9 {
        // What follows inside this chunk, then the rest of the fraction.
        let next = d[take]
        var restNonzero = !fraction.isZero
        for j in (take + 1)..<9 where d[j] != 0 { restNonzero = true }
        tail = next > 5 ? .aboveHalf : next < 5 ? (next == 0 && !restNonzero ? .zero : .belowHalf)
          : (restNonzero ? .aboveHalf : .half)
        return
      }
    }
    // Digits ran out at a chunk boundary: the rest is fraction / 2^k.
    if fraction.isZero {
      tail = .zero
    } else {
      let c = fraction.compare(powerOfTwo: k - 1)
      tail = c > 0 ? .aboveHalf : c == 0 ? .half : .belowHalf
    }
    // Requested digits past the exact ones are zeros.
    while wanted > 0 {
      append(0x30)
      wanted -= 1
    }
  }

  mutating func append(_ b: UInt8) {
    if count < capacity {
      buffer[count] = b
      count += 1
    }
  }

  /// Keeps the first `keep` digits, rounded to nearest, ties to even, by the
  /// digits dropped and the tail. A carry out of the first digit prepends a
  /// 1 (and moves the point). `keep` may be 0: then only a carry remains.
  mutating func round(keeping keep: Int) {
    guard keep <= count else { return }
    // How the dropped part compares with half of the last kept place: the
    // tail itself when nothing generated is dropped.
    var dropped = tail
    if keep < count {
      let first = buffer[keep]
      var restNonzero = tail != .zero
      var i = keep + 1
      while i < count {
        if buffer[i] != 0x30 { restNonzero = true }
        i += 1
      }
      if first > 0x35 { dropped = .aboveHalf }
      else if first < 0x35 { dropped = first == 0x30 && !restNonzero ? .zero : .belowHalf }
      else { dropped = restNonzero ? .aboveHalf : .half }
    }
    count = keep
    tail = dropped == .zero ? .zero : .belowHalf  // the kept digits no longer say
    let lastOdd = keep > 0 && (buffer[keep - 1] - 0x30) % 2 == 1
    guard dropped == .aboveHalf || (dropped == .half && lastOdd) else { return }
    // Add one in the last kept place.
    var j = keep - 1
    while j >= 0 {
      if buffer[j] == 0x39 {
        buffer[j] = 0x30
        j -= 1
      } else {
        buffer[j] += 1
        return
      }
    }
    // A carry out: 1 then the zeros.
    var k = count
    while k > 0 {
      buffer[k] = buffer[k - 1]
      k -= 1
    }
    buffer[0] = 0x31
    count += 1
    point += 1
  }
}
