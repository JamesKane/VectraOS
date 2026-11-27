// SPDX-License-Identifier: BSD-3-Clause

// scanf's conversions (C23 §7.23.6.2), from a string (sscanf's family):
// white space, ordinary characters and %%; conversions d i o u x X p,
// a e f g (and upper case), s c [ and n; assignment suppression (*), a
// width, and lengths hh h l ll j z t L. A number is the longest prefix of
// the input that is, or begins, the conversion's form (within the width),
// converted as strtol's and strtod's families convert it. Runtime-free:
// the pointers to store through come from a source (C's va_list
// natively, through native/stdio.c), generic, so nothing allocates.

/// Where scanf's pointers come from, in order.
protocol ScanArguments {
  mutating func pointer() -> UnsafeMutableRawPointer?
}

/// What scanf returns: the number of items assigned, or EOF (-1) if the
/// input ended before the first conversion.
func scan<A: ScanArguments>(_ input: UnsafePointer<UInt8>, _ format: UnsafePointer<UInt8>, _ args: inout A) -> Int32 {
  var at = 0  // input consumed
  var i = 0  // format read
  var assigned: Int32 = 0
  var converted = false  // any conversion done (EOF only before the first)
  @inline(__always) func isSpace(_ c: UInt8) -> Bool { c == 0x20 || (c >= 0x09 && c <= 0x0D) }
  func skipSpace(_ at: inout Int) { while unsafe isSpace(input[at]) { at += 1 } }
  while unsafe format[i] != 0 {
    let f = unsafe format[i]
    if isSpace(f) {
      while unsafe isSpace(format[i]) { i += 1 }
      skipSpace(&at)
      continue
    }
    if f != 0x25 {  // an ordinary character matches itself
      if unsafe input[at] == 0 { return converted ? assigned : -1 }
      guard unsafe input[at] == f else { return assigned }
      at += 1
      i += 1
      continue
    }
    i += 1
    if unsafe format[i] == 0x25 {  // %%
      skipSpace(&at)
      if unsafe input[at] == 0 { return converted ? assigned : -1 }
      guard unsafe input[at] == 0x25 else { return assigned }
      at += 1
      i += 1
      continue
    }
    var suppress = false
    if unsafe format[i] == 0x2A {
      suppress = true
      i += 1
    }
    var width = 0
    while unsafe format[i] >= 0x30 && format[i] <= 0x39 {
      width = width * 10 + Int(unsafe format[i] - 0x30)
      i += 1
    }
    // The length: the size stored, in bytes (0 the default's).
    var size = 0
    var long = false
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
      long = true
      if unsafe format[i] == 0x6C { i += 1 }
    case 0x6A, 0x7A, 0x74:  // j z t
      i += 1
      size = 8
    case 0x4C:  // L
      i += 1
      size = 16
    default: break
    }
    let conversion = unsafe format[i]
    if conversion == 0 { return assigned }
    i += 1
    if conversion != 0x63 && conversion != 0x5B && conversion != 0x6E { skipSpace(&at) }
    if conversion == 0x6E {  // n: the count so far, not an item
      if !suppress, let p = unsafe args.pointer() { unsafe storeInteger(p, UInt64(at), size == 0 ? 4 : size) }
      continue
    }
    if unsafe input[at] == 0 { return converted ? assigned : -1 }
    let limit = width == 0 ? Int.max : width
    switch conversion {
    case 0x64, 0x69, 0x6F, 0x75, 0x78, 0x58, 0x70:  // d i o u x X p
      let base: Int32 =
        conversion == 0x64 || conversion == 0x75 ? 10 : conversion == 0x69 ? 0 : conversion == 0x6F ? 8 : 16
      var text = InlineArray<80, CChar>(repeating: 0)
      let n = unsafe integerPrefix(input + at, limit, base, &text)
      guard n > 0 else { return assigned }
      at += n
      converted = true
      if suppress { continue }
      let value: UInt64 = withUnsafePointer(to: &text) { t in
        let s = unsafe UnsafeRawPointer(t).assumingMemoryBound(to: CChar.self)
        if conversion == 0x64 || conversion == 0x69 { return UInt64(bitPattern: unsafe strtoll(s, nil, base)) }
        return unsafe strtoull(s, nil, base)
      }
      guard let p = unsafe args.pointer() else { return assigned }
      unsafe storeInteger(p, value, conversion == 0x70 ? 8 : size == 0 ? 4 : size)
      assigned += 1
    case 0x61, 0x65, 0x66, 0x67, 0x41, 0x45, 0x46, 0x47:  // a e f g
      var text = InlineArray<512, CChar>(repeating: 0)
      let n = unsafe floatPrefix(input + at, limit, &text)
      guard n > 0 else { return assigned }
      at += n
      converted = true
      if suppress { continue }
      guard let p = unsafe args.pointer() else { return assigned }
      withUnsafePointer(to: &text) { t in
        let s = unsafe UnsafeRawPointer(t).assumingMemoryBound(to: CChar.self)
        if size == 16 {
          let bits = unsafe strtoldBits(s, nil)
          unsafe p.storeBytes(of: UInt64(truncatingIfNeeded: bits), as: UInt64.self)
          unsafe p.storeBytes(of: UInt64(truncatingIfNeeded: bits >> 64), toByteOffset: 8, as: UInt64.self)
        } else if long {
          unsafe p.storeBytes(of: strtod(s, nil), as: Double.self)
        } else {
          unsafe p.storeBytes(of: strtof(s, nil), as: Float.self)
        }
      }
      assigned += 1
    case 0x73:  // s: non-white-space, then a NUL
      let p = suppress ? nil : unsafe args.pointer()
      var n = 0
      while n < limit, unsafe input[at] != 0, unsafe !isSpace(input[at]) {
        if let p = unsafe p { unsafe p.storeBytes(of: input[at], toByteOffset: n, as: UInt8.self) }
        n += 1
        at += 1
      }
      converted = true
      if let p = unsafe p {
        unsafe p.storeBytes(of: 0, toByteOffset: n, as: UInt8.self)
        assigned += 1
      }
    case 0x63:  // c: the width's characters (1 by default), no NUL
      let count = width == 0 ? 1 : width
      let p = suppress ? nil : unsafe args.pointer()
      var n = 0
      while n < count, unsafe input[at] != 0 {
        if let p = unsafe p { unsafe p.storeBytes(of: input[at], toByteOffset: n, as: UInt8.self) }
        n += 1
        at += 1
      }
      if n < count { return assigned }  // the input ended inside the item
      converted = true
      if unsafe p != nil { assigned += 1 }
    case 0x5B:  // [: the scanset's characters, then a NUL
      var set = InlineArray<256, Bool>(repeating: false)
      var negate = false
      if unsafe format[i] == 0x5E {
        negate = true
        i += 1
      }
      // A ] first is in the set; a - between two characters is a range.
      var first = true
      while unsafe format[i] != 0 && (format[i] != 0x5D || first) {
        let c = unsafe format[i]
        if unsafe format[i + 1] == 0x2D && format[i + 2] != 0x5D && format[i + 2] != 0 {
          let high = unsafe format[i + 2]
          if c <= high { for b in Int(c)...Int(high) { set[b] = true } }
          i += 3
        } else {
          set[Int(c)] = true
          i += 1
        }
        first = false
      }
      if unsafe format[i] == 0x5D { i += 1 }
      let p = suppress ? nil : unsafe args.pointer()
      var n = 0
      while n < limit, unsafe input[at] != 0, set[Int(unsafe input[at])] != negate {
        if let p = unsafe p { unsafe p.storeBytes(of: input[at], toByteOffset: n, as: UInt8.self) }
        n += 1
        at += 1
      }
      guard n > 0 else { return assigned }
      converted = true
      if let p = unsafe p {
        unsafe p.storeBytes(of: 0, toByteOffset: n, as: UInt8.self)
        assigned += 1
      }
    default:
      return assigned
    }
  }
  return assigned
}

/// Stores `value`'s low `size` bytes (1, 2, 4 or 8).
func storeInteger(_ p: UnsafeMutableRawPointer, _ value: UInt64, _ size: Int) {
  switch size {
  case 1: unsafe p.storeBytes(of: UInt8(truncatingIfNeeded: value), as: UInt8.self)
  case 2: unsafe p.storeBytes(of: UInt16(truncatingIfNeeded: value), as: UInt16.self)
  case 4: unsafe p.storeBytes(of: UInt32(truncatingIfNeeded: value), as: UInt32.self)
  default: unsafe p.storeBytes(of: value, as: UInt64.self)
  }
}

@inline(__always) func digitIn(_ c: UInt8, _ base: Int32) -> Bool {
  let d: Int32 =
    c >= 0x30 && c <= 0x39 ? Int32(c - 0x30) : c >= 0x61 && c <= 0x7A ? Int32(c - 0x61 + 10)
    : c >= 0x41 && c <= 0x5A ? Int32(c - 0x41 + 10) : 99
  return d < base
}

/// The integer at `s` in `base` (0: by its prefix, as strtol's), at most
/// `limit` characters, copied to `text` with a NUL; how many it took (0:
/// no digit, a matching failure).
func integerPrefix<let N: Int>(_ s: UnsafePointer<UInt8>, _ limit: Int, _ base: Int32, _ text: inout InlineArray<N, CChar>)
  -> Int
{
  var n = 0
  var base = base
  var digits = 0
  func take(_ n: inout Int, _ text: inout InlineArray<N, CChar>) {
    if n < N - 1 { text[n] = CChar(bitPattern: unsafe s[n]) }
    n += 1
  }
  if n < limit && (unsafe s[n] == 0x2B || s[n] == 0x2D) { take(&n, &text) }
  if (base == 0 || base == 16) && n < limit && (unsafe s[n]) == 0x30 {
    take(&n, &text)
    digits = 1
    if n < limit && (unsafe s[n] == 0x78 || s[n] == 0x58) {
      // 0x: hex, if a hex digit follows within the width; else the 0 alone.
      if n + 1 < limit && digitIn(unsafe s[n + 1], 16) {
        take(&n, &text)
        base = 16
        digits = 0
      } else if base == 0 {
        base = 8
      }
    } else if base == 0 {
      base = 8
    }
  }
  if base == 0 { base = 10 }
  while n < limit && digitIn(unsafe s[n], base) {
    take(&n, &text)
    digits += 1
  }
  if digits == 0 { return 0 }
  text[min(n, N - 1)] = 0
  return n
}

/// The floating-point number at `s` (strtod's forms: decimal, hex, inf,
/// infinity, nan and nan(chars)), at most `limit` characters, copied to
/// `text` with a NUL; how many it took (0: none, a matching failure).
func floatPrefix<let N: Int>(_ s: UnsafePointer<UInt8>, _ limit: Int, _ text: inout InlineArray<N, CChar>) -> Int {
  var n = 0
  func at(_ k: Int) -> UInt8 { k < limit ? unsafe s[k] : 0 }
  func lower(_ c: UInt8) -> UInt8 { c >= 0x41 && c <= 0x5A ? c | 0x20 : c }
  func word(_ from: Int, _ w: StaticString) -> Bool {
    for k in 0..<w.utf8CodeUnitCount where lower(at(from + k)) != (unsafe w.utf8Start[k]) { return false }
    return true
  }
  if at(n) == 0x2B || at(n) == 0x2D { n += 1 }
  if word(n, "infinity") {
    n += 8
  } else if word(n, "inf") {
    n += 3
  } else if word(n, "nan") {
    n += 3
    if at(n) == 0x28 {
      var k = n + 1
      while digitIn(at(k), 36) || at(k) == 0x5F { k += 1 }
      if at(k) == 0x29 { n = k + 1 }
    }
  } else {
    var hex = false
    if at(n) == 0x30 && lower(at(n + 1)) == 0x78 && (digitIn(at(n + 2), 16) || (at(n + 2) == 0x2E && digitIn(at(n + 3), 16))) {
      hex = true
      n += 2
    }
    let base: Int32 = hex ? 16 : 10
    var digits = 0
    while digitIn(at(n), base) {
      n += 1
      digits += 1
    }
    if at(n) == 0x2E {
      n += 1
      while digitIn(at(n), base) {
        n += 1
        digits += 1
      }
    }
    if digits == 0 { return 0 }
    // An exponent, if it has digits.
    if lower(at(n)) == (hex ? 0x70 : 0x65) {
      var k = n + 1
      if at(k) == 0x2B || at(k) == 0x2D { k += 1 }
      if digitIn(at(k), 10) {
        while digitIn(at(k), 10) { k += 1 }
        n = k
      }
    }
  }
  if n == 0 || (n == 1 && (unsafe s[0] == 0x2B || s[0] == 0x2D)) { return 0 }
  for k in 0..<min(n, N - 1) { text[k] = CChar(bitPattern: unsafe s[k]) }
  text[min(n, N - 1)] = 0
  return n
}
