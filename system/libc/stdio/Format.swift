// SPDX-License-Identifier: BSD-3-Clause

// printf's formatting (M6c), from C23 §7.23.6.1: conversions d i u o x X c
// s p % and f F e E g G a A; flags - + space # 0; a width and a precision,
// either of them `*`; lengths hh h l ll j z t L (a long double: x87's
// format on amd64, binary128's elsewhere, M6d). Runtime-free: arguments
// come from a source (C's
// va_list natively, through the shim in native/stdio.c; an array in the
// hosted tests) and bytes go to a sink, both generic, so nothing allocates.

/// Where printf's arguments come from, in order.
protocol FormatArguments {
  /// The next integer argument of `size` bytes (1, 2, 4 or 8), its bits.
  mutating func integer(_ size: Int) -> UInt64
  mutating func double() -> Double
  /// The next long double, decoded (FloatValue's initializers).
  mutating func longDouble() -> FloatValue
  mutating func pointer() -> UInt
  /// The next `%s`'s string, or nil for a null pointer.
  mutating func string() -> UnsafePointer<UInt8>?
}

/// Where formatted bytes go.
protocol FormatSink {
  mutating func put(_ byte: UInt8)
}

/// The formatter: walks `format`, writes to `sink`; the number of bytes
/// the output has (written or not, as snprintf counts), or -1 for a
/// conversion C leaves undefined (an unknown one).
func format<A: FormatArguments, S: FormatSink>(_ format: UnsafePointer<UInt8>, _ args: inout A, _ sink: inout S)
  -> Int
{
  var count = 0
  var i = 0
  func emit(_ b: UInt8, _ sink: inout S, _ count: inout Int) {
    sink.put(b)
    count += 1
  }
  while unsafe format[i] != 0 {
    let c = unsafe format[i]
    i += 1
    if c != 0x25 {  // %
      emit(c, &sink, &count)
      continue
    }
    // Flags.
    var spec = Spec()
    while true {
      switch unsafe format[i] {
      case 0x2D: spec.left = true
      case 0x2B: spec.plus = true
      case 0x20: spec.space = true
      case 0x23: spec.alternate = true
      case 0x30: spec.zero = true
      default: break
      }
      if unsafe format[i] == 0x2D || format[i] == 0x2B || format[i] == 0x20 || format[i] == 0x23 || format[i] == 0x30 {
        i += 1
      } else {
        break
      }
    }
    // Width.
    if unsafe format[i] == 0x2A {
      let w = Int32(truncatingIfNeeded: args.integer(4))
      if w < 0 {
        spec.left = true
        spec.width = Int(-Int64(w))
      } else {
        spec.width = Int(w)
      }
      i += 1
    } else {
      while unsafe format[i] >= 0x30 && format[i] <= 0x39 {
        spec.width = spec.width * 10 + Int(unsafe format[i] - 0x30)
        i += 1
      }
    }
    // Precision.
    if unsafe format[i] == 0x2E {
      i += 1
      if unsafe format[i] == 0x2A {
        let p = Int32(truncatingIfNeeded: args.integer(4))
        spec.precision = p < 0 ? -1 : Int(p)
        i += 1
      } else {
        var p = 0
        while unsafe format[i] >= 0x30 && format[i] <= 0x39 {
          p = p * 10 + Int(unsafe format[i] - 0x30)
          i += 1
        }
        spec.precision = p
      }
    }
    // Length.
    var size = 4
    var long = false  // L
    switch unsafe format[i] {
    case 0x68:  // h, hh
      i += 1
      size = 2
      if unsafe format[i] == 0x68 {
        i += 1
        size = 1
      }
    case 0x6C:  // l, ll
      i += 1
      size = 8
      if unsafe format[i] == 0x6C { i += 1 }
    case 0x6A, 0x7A, 0x74:  // j z t
      i += 1
      size = 8
    case 0x4C:  // L
      i += 1
      long = true
    default: break
    }
    let conversion = unsafe format[i]
    if conversion == 0 { break }
    i += 1
    switch conversion {
    case 0x25: emit(0x25, &sink, &count)
    case 0x64, 0x69:  // d i
      let bits = args.integer(size)
      let shift = UInt64(64 - size * 8)
      let v = Int64(bitPattern: bits << shift) >> Int64(shift)
      integer(v < 0 ? UInt64(0) &- UInt64(bitPattern: v) : UInt64(v), negative: v < 0, signed: true, base: 10,
              upper: false, spec, &sink, &count)
    case 0x75, 0x6F, 0x78, 0x58:  // u o x X
      var v = args.integer(size)
      if size < 8 { v &= (UInt64(1) << UInt64(size * 8)) - 1 }
      integer(v, negative: false, signed: false, base: conversion == 0x75 ? 10 : conversion == 0x6F ? 8 : 16,
              upper: conversion == 0x58, spec, &sink, &count)
    case 0x70:  // p: as glibc, %#x with the sign flags and the precision
      var s = spec
      s.alternate = true
      let v = args.pointer()
      if v == 0 {
        literal("(nil)", spec, &sink, &count)
      } else {
        integer(UInt64(v), negative: false, signed: true, base: 16, upper: false, s, &sink, &count)
      }
    case 0x63:  // c
      let b = UInt8(truncatingIfNeeded: args.integer(4))
      pad(spec.width - 1, left: false, spec, &sink, &count)
      emit(b, &sink, &count)
      pad(spec.width - 1, left: true, spec, &sink, &count)
    case 0x73:  // s
      guard let s = unsafe args.string() else {
        // glibc prints "(null)" when it fits the precision.
        if spec.precision < 0 || spec.precision >= 6 { literal("(null)", spec, &sink, &count) } else {
          pad(spec.width, left: false, spec, &sink, &count)
          pad(spec.width, left: true, spec, &sink, &count)
        }
        continue
      }
      var n = 0
      while unsafe (spec.precision < 0 || n < spec.precision) && s[n] != 0 { n += 1 }
      pad(spec.width - n, left: false, spec, &sink, &count)
      for j in 0..<n { emit(unsafe s[j], &sink, &count) }
      pad(spec.width - n, left: true, spec, &sink, &count)
    case 0x66, 0x46, 0x65, 0x45, 0x67, 0x47, 0x61, 0x41:  // f F e E g G a A
      floating(long ? args.longDouble() : FloatValue(args.double()), conversion, spec, &sink, &count)
    default:
      return -1
    }
  }
  return count
}

/// A conversion's flags, width and precision (-1: none given).
struct Spec {
  var left = false, plus = false, space = false, alternate = false, zero = false
  var width = 0
  var precision = -1
}

/// `n` spaces, on the side `left` says (`spec.left`'s side is the right).
func pad<S: FormatSink>(_ n: Int, left: Bool, _ spec: Spec, _ sink: inout S, _ count: inout Int) {
  guard n > 0, spec.left == left else { return }
  for _ in 0..<n {
    sink.put(0x20)
    count += 1
  }
}

func literal<S: FormatSink>(_ s: StaticString, _ spec: Spec, _ sink: inout S, _ count: inout Int) {
  let n = s.utf8CodeUnitCount
  pad(spec.width - n, left: false, spec, &sink, &count)
  for j in 0..<n {
    sink.put(unsafe s.utf8Start[j])
    count += 1
  }
  pad(spec.width - n, left: true, spec, &sink, &count)
}

/// The sign or the space a conversion leads with, if any.
func signByte(_ negative: Bool, _ spec: Spec) -> UInt8? {
  negative ? 0x2D : spec.plus ? 0x2B : spec.space ? 0x20 : nil
}

/// Writes a field: sign, prefix, zeros to the width (with `zeroPad`), the
/// body, and spaces on the side the flags say.
func field<S: FormatSink>(sign: UInt8?, prefix: StaticString?, zeros: Int, body: UnsafePointer<UInt8>, _ n: Int,
                          zeroPad: Bool, _ spec: Spec, _ sink: inout S, _ count: inout Int)
{
  let prefixCount = prefix?.utf8CodeUnitCount ?? 0
  var length = (sign == nil ? 0 : 1) + prefixCount + zeros + n
  var extraZeros = 0
  if zeroPad && !spec.left && spec.width > length {
    extraZeros = spec.width - length
    length = spec.width
  }
  pad(spec.width - length, left: false, spec, &sink, &count)
  if let sign {
    sink.put(sign)
    count += 1
  }
  if let prefix {
    for j in 0..<prefixCount {
      sink.put(unsafe prefix.utf8Start[j])
      count += 1
    }
  }
  for _ in 0..<(zeros + extraZeros) {
    sink.put(0x30)
    count += 1
  }
  for j in 0..<n {
    sink.put(unsafe body[j])
    count += 1
  }
  pad(spec.width - length, left: true, spec, &sink, &count)
}

/// d i u o x X p.
func integer<S: FormatSink>(_ v: UInt64, negative: Bool, signed: Bool, base: UInt64, upper: Bool, _ spec: Spec,
                            _ sink: inout S, _ count: inout Int)
{
  var digits = InlineArray<24, UInt8>(repeating: 0)
  var n = 0
  var x = v
  let alphabet: StaticString = upper ? "0123456789ABCDEF" : "0123456789abcdef"
  while x != 0 {
    digits[23 - n] = unsafe alphabet.utf8Start[Int(x % base)]
    x /= base
    n += 1
  }
  // A precision of 0 with a value of 0 has no digits (but # with o has one).
  let precision = spec.precision < 0 ? 1 : spec.precision
  var zeros = max(0, precision - n)
  var prefix: StaticString? = nil
  if spec.alternate && base == 8 && zeros == 0 && (n == 0 || digits[24 - n] != 0x30) { zeros = 1 }
  if spec.alternate && base == 16 && v != 0 { prefix = upper ? "0X" : "0x" }
  let sign = signed ? signByte(negative, spec) : nil
  withUnsafePointer(to: &digits) { p in
    let start = unsafe UnsafeRawPointer(p).assumingMemoryBound(to: UInt8.self) + (24 - n)
    unsafe field(sign: sign, prefix: prefix, zeros: zeros, body: start, n, zeroPad: spec.zero && spec.precision < 0,
                 spec, &sink, &count)
  }
}

/// A floating argument, decoded from its format: sign, class, and its
/// magnitude mantissa × 2^exponent, with the format's precision (p, the
/// leading bit included) and whether it stores the leading bit (x87's
/// extended format does), which %a's digits follow.
struct FloatValue {
  static let finite: UInt8 = 0, infinite: UInt8 = 1, nan: UInt8 = 2

  var negative: Bool
  var kind: UInt8
  var mantissa: UInt128
  var exponent: Int
  var precisionBits: Int
  var explicitLeadingBit: Bool

  init(_ d: Double) {
    let bits = d.bitPattern
    let field = Int(bits >> 52 & 0x7FF)
    let fraction = bits & ((1 << 52) - 1)
    negative = bits >> 63 == 1
    kind = field == 0x7FF ? (fraction == 0 ? FloatValue.infinite : FloatValue.nan) : FloatValue.finite
    mantissa = UInt128(field == 0 ? fraction : fraction | 1 << 52)
    exponent = (field == 0 ? 1 : field) - 1075
    precisionBits = 53
    explicitLeadingBit = false
  }

  /// x87's 80-bit extended format: the significand's 64 bits (its leading
  /// bit stored), then 15 bits of exponent and the sign.
  init(x87 low: UInt64, _ high: UInt16) {
    let field = Int(high & 0x7FFF)
    negative = high >> 15 == 1
    kind = field == 0x7FFF ? (low << 1 == 0 ? FloatValue.infinite : FloatValue.nan) : FloatValue.finite
    mantissa = UInt128(low)
    exponent = (field == 0 ? 1 : field) - 16383 - 63
    precisionBits = 64
    explicitLeadingBit = true
  }

  /// IEEE's binary128: 112 bits of fraction, 15 of exponent, the sign.
  init(binary128 bits: UInt128) {
    let field = Int(bits >> 112 & 0x7FFF)
    let fraction = bits & ((UInt128(1) << 112) - 1)
    negative = bits >> 127 == 1
    kind = field == 0x7FFF ? (fraction == 0 ? FloatValue.infinite : FloatValue.nan) : FloatValue.finite
    mantissa = field == 0 ? fraction : fraction | UInt128(1) << 112
    exponent = (field == 0 ? 1 : field) - 16383 - 112
    precisionBits = 113
    explicitLeadingBit = false
  }

  /// The place of the leading bit (floor(log2) of the magnitude; 0 for zero).
  var binaryExponent: Int { mantissa == 0 ? 0 : exponent + 127 - mantissa.leadingZeroBitCount }
}

/// f F e E g G a A: a double's in small buffers; a long double's need room
/// for 4933 integer digits (and its Big, 16494 bits of fraction).
func floating<S: FormatSink>(_ value: FloatValue, _ conversion: UInt8, _ spec: Spec, _ sink: inout S,
                             _ count: inout Int)
{
  if value.precisionBits <= 53 {
    var out = InlineArray<1300, UInt8>(repeating: 0)
    floating(value, conversion, spec, &out, Digits<1200, 128>.self, &sink, &count)
  } else {
    var out = InlineArray<5500, UInt8>(repeating: 0)
    floating(value, conversion, spec, &out, Digits<5400, 560>.self, &sink, &count)
  }
}

func floating<S: FormatSink, let N: Int, let C: Int, let L: Int>(
  _ value: FloatValue, _ conversion: UInt8, _ spec: Spec, _ out: inout InlineArray<N, UInt8>,
  _ digits: Digits<C, L>.Type, _ sink: inout S, _ count: inout Int
) {
  let upper = conversion == 0x46 || conversion == 0x45 || conversion == 0x47 || conversion == 0x41
  let sign = signByte(value.negative, spec)
  if value.kind != FloatValue.finite {
    let text: StaticString =
      value.kind == FloatValue.nan ? (upper ? "NAN" : "nan") : (upper ? "INF" : "inf")
    unsafe field(sign: sign, prefix: nil, zeros: 0, body: text.utf8Start, text.utf8CodeUnitCount, zeroPad: false, spec,
                 &sink, &count)
    return
  }
  // The text, built in a buffer: digits, a point, an exponent.
  var n = 0
  var prefix: StaticString? = nil
  switch conversion {
  case 0x61, 0x41:  // a A
    hex(value, spec, upper, &out, &n)
    prefix = upper ? "0X" : "0x"
  case 0x66, 0x46:  // f F
    let p = spec.precision < 0 ? 6 : spec.precision
    var d = Digits<C, L>(mantissa: value.mantissa, exponent: value.exponent, fractionDigits: p)
    d.round(keeping: d.point + p)
    fixed(d, p, spec.alternate, &out, &n)
  case 0x65, 0x45:  // e E
    let p = spec.precision < 0 ? 6 : spec.precision
    var (d, e) = significant(value, p + 1, digits)
    exponential(&d, &e, p, spec.alternate, upper, &out, &n)
  default:  // g G
    var p = spec.precision < 0 ? 6 : spec.precision
    if p == 0 { p = 1 }
    var (d, e) = significant(value, p, digits)
    if p > e && e >= -4 {
      // %f with p - 1 - e digits after the point.
      var f = Digits<C, L>(mantissa: value.mantissa, exponent: value.exponent, fractionDigits: p - 1 - e)
      f.round(keeping: f.point + p - 1 - e)
      fixed(f, p - 1 - e, spec.alternate, &out, &n)
    } else {
      exponential(&d, &e, p - 1, spec.alternate, upper, &out, &n)
    }
    if !spec.alternate { stripZeros(&out, &n) }
  }
  withUnsafePointer(to: &out) { p in
    unsafe field(sign: sign, prefix: prefix, zeros: 0, body: UnsafeRawPointer(p).assumingMemoryBound(to: UInt8.self),
                 n, zeroPad: spec.zero, spec, &sink, &count)
  }
}

/// Appends `b` to `out` while it has room.
func put<let N: Int>(_ b: UInt8, _ out: inout InlineArray<N, UInt8>, _ n: inout Int) {
  if n < N {
    out[n] = b
    n += 1
  }
}

/// `digits` significant digits of `value` and its decimal exponent (the
/// first digit's place), rounded.
func significant<let C: Int, let L: Int>(_ value: FloatValue, _ digits: Int, _: Digits<C, L>.Type)
  -> (Digits<C, L>, Int)
{
  // Enough fraction digits to reach `digits` significant ones past the
  // leading zeros: the first digit's place estimated from the binary
  // exponent (log10 2 a bit), with two to spare for the estimate.
  // (Integer arithmetic, floor division: tier 0 has no libm.)
  let scaled = value.binaryExponent * 30103
  let place = scaled >= 0 ? scaled / 100_000 : -((-scaled + 99_999) / 100_000)
  var d = Digits<C, L>(mantissa: value.mantissa, exponent: value.exponent,
                       fractionDigits: min(C, max(0, digits - place) + 2))
  // Skip leading zeros: the first nonzero digit's place.
  var first = 0
  while first < d.count && d.buffer[first] == 0x30 { first += 1 }
  if first == d.count {  // zero
    var z = Digits<C, L>(mantissa: 0, exponent: 0, fractionDigits: 0)
    z.count = 0
    for _ in 0..<max(1, digits) { z.append(0x30) }
    z.point = 1
    return (z, 0)
  }
  var e = d.point - first - 1
  // Move the significant digits to the front.
  if first > 0 {
    for j in first..<d.count { d.buffer[j - first] = d.buffer[j] }
    d.count -= first
    d.point -= first
  }
  d.round(keeping: digits)
  if d.count > digits {  // a carry made one more digit: 10…0
    d.count = digits
    e += 1
  }
  while d.count < digits { d.append(0x30) }
  return (d, e)
}

/// d.ddd with `p` digits after the point, then e±XX.
func exponential<let N: Int, let C: Int, let L: Int>(_ d: inout Digits<C, L>, _ e: inout Int, _ p: Int,
                                                     _ alternate: Bool, _ upper: Bool,
                                                     _ out: inout InlineArray<N, UInt8>, _ n: inout Int)
{
  put(d.buffer[0], &out, &n)
  if p > 0 || alternate { put(0x2E, &out, &n) }
  for j in 0..<p { put(j + 1 < d.count ? d.buffer[j + 1] : 0x30, &out, &n) }
  put(upper ? 0x45 : 0x65, &out, &n)
  put(e < 0 ? 0x2D : 0x2B, &out, &n)
  exponentDigits(e < 0 ? -e : e, minimum: 2, &out, &n)
}

/// A non-negative exponent's digits, at least `minimum` of them.
func exponentDigits<let N: Int>(_ a: Int, minimum: Int, _ out: inout InlineArray<N, UInt8>, _ n: inout Int) {
  var a = a
  var tmp = InlineArray<6, UInt8>(repeating: 0)
  var k = 0
  repeat {
    tmp[k] = 0x30 + UInt8(a % 10)
    a /= 10
    k += 1
  } while a > 0 || k < minimum
  while k > 0 {
    k -= 1
    put(tmp[k], &out, &n)
  }
}

/// The integer digits, then `p` after the point.
func fixed<let N: Int, let C: Int, let L: Int>(_ d: Digits<C, L>, _ p: Int, _ alternate: Bool,
                                               _ out: inout InlineArray<N, UInt8>, _ n: inout Int)
{
  for j in 0..<d.point { put(d.buffer[j], &out, &n) }
  if p > 0 || alternate { put(0x2E, &out, &n) }
  for j in 0..<p { put(d.point + j < d.count ? d.buffer[d.point + j] : 0x30, &out, &n) }
}

/// %g's trailing zeros (and a point left bare) removed, before an exponent.
func stripZeros<let N: Int>(_ out: inout InlineArray<N, UInt8>, _ n: inout Int) {
  var point = -1, exponent = n
  for j in 0..<n {
    if out[j] == 0x2E { point = j }
    if out[j] == 0x65 || out[j] == 0x45 {
      exponent = j
      break
    }
  }
  guard point >= 0 else { return }
  var end = exponent
  while end > point + 1 && out[end - 1] == 0x30 { end -= 1 }
  if end == point + 1 { end = point }
  let removed = exponent - end
  guard removed > 0 else { return }
  for j in exponent..<n { out[j - removed] = out[j] }
  n -= removed
}

/// %a: h.hhhp±d, rounded to the precision, ties to even. The leading digit
/// is the format's leading bit (1, or 0 for zero and subnormals, whose
/// exponent is the smallest normal's) where the format leaves it implicit,
/// and its first four bits in x87's, which stores it (as glibc prints
/// them: 1.0L is 0x8p-3).
func hex<let N: Int>(_ value: FloatValue, _ spec: Spec, _ upper: Bool, _ out: inout InlineArray<N, UInt8>,
                     _ n: inout Int)
{
  let leadBits = value.explicitLeadingBit ? 4 : 1
  let fractionBits = value.precisionBits - leadBits
  let nibbles = (fractionBits + 3) / 4
  // The fraction, left-aligned to whole nibbles.
  var mantissa = (value.mantissa & ((UInt128(1) << UInt128(fractionBits)) - 1)) << UInt128(4 * nibbles - fractionBits)
  var lead = value.mantissa >> UInt128(fractionBits)
  let e = value.mantissa == 0 ? 0 : value.exponent + fractionBits
  var digits = nibbles
  if spec.precision >= 0 && spec.precision < nibbles {
    digits = spec.precision
    let drop = UInt128(4 * (nibbles - digits))
    let rest = mantissa & ((1 << drop) - 1)
    mantissa >>= drop
    let half: UInt128 = 1 << (drop - 1)
    // A tie goes to the even last digit: the leading one when none is kept.
    let odd = digits == 0 ? lead & 1 == 1 : mantissa & 1 == 1
    if rest > half || (rest == half && odd) {
      mantissa += 1
      if mantissa >> UInt128(4 * digits) != 0 {
        mantissa &= (UInt128(1) << UInt128(4 * digits)) &- 1
        lead += 1
      }
    }
  } else if spec.precision < 0 {
    // Shortest exact: trailing zero nibbles dropped.
    while digits > 0 && mantissa & 0xF == 0 {
      mantissa >>= 4
      digits -= 1
    }
  }
  let alphabet: StaticString = upper ? "0123456789ABCDEF" : "0123456789abcdef"
  // A leading digit past f (x87's rounded up from 0xf): its carry moves
  // into the exponent's next nibble, as 0x1.0p+(e+4).
  var exponent = e
  if lead > 0xF {
    lead >>= 4
    exponent += 4
  }
  put(unsafe alphabet.utf8Start[Int(lead)], &out, &n)
  if digits > 0 || spec.alternate { put(0x2E, &out, &n) }
  var j = digits - 1
  while j >= 0 {
    put(unsafe alphabet.utf8Start[Int((mantissa >> UInt128(4 * j)) & 0xF)], &out, &n)
    j -= 1
  }
  for _ in 0..<max(0, spec.precision - digits) where spec.precision > nibbles { put(0x30, &out, &n) }
  put(upper ? 0x50 : 0x70, &out, &n)
  put(exponent < 0 ? 0x2D : 0x2B, &out, &n)
  exponentDigits(exponent < 0 ? -exponent : exponent, minimum: 1, &out, &n)
}
