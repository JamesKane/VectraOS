// SPDX-License-Identifier: BSD-3-Clause

// <stdlib.h>, numeric conversion, the environment, searching and sorting
// and integer arithmetic: written from ISO/IEC 9899:2024 (C23) §7.24.1.2
// (atoi, atol, atoll), §7.24.1.7 (strtol, strtoll, strtoul, strtoull: the
// subject sequence, bases 0 and 2 to 36), §7.24.4.6 (getenv), §7.24.5
// (bsearch, qsort), §7.24.6.1 (abs) and §7.8.2 (<inttypes.h>'s). No
// locale: the "C" locale's white space and digits only. A range error
// saturates the result and sets errno to ERANGE; a bad base sets EINVAL.

/// White space in the "C" locale (§7.4.1.10): space, \t \n \v \f \r.
@inline(__always) func isSpace(_ c: UInt8) -> Bool { c == 0x20 || (c >= 0x09 && c <= 0x0D) }

/// A digit's value in bases up to 36, or 99.
@inline(__always) func digitValue(_ c: UInt8) -> Int {
  switch c {
  case 0x30...0x39: Int(c - 0x30)
  case 0x41...0x5A: Int(c - 0x41) + 10
  case 0x61...0x7A: Int(c - 0x61) + 10
  default: 99
  }
}

/// Whether `s` at `i` holds "0" and `letter` (either case) before a digit of
/// `prefixBase`. (A function, not a closure over `i`: a captured variable
/// is boxed, which the libc, built -no-allocations, can't do.)
func hasPrefix(_ s: UnsafePointer<CChar>, _ i: Int, _ letter: UInt8, _ prefixBase: Int) -> Bool {
  unsafe byte(s, i) == 0x30 && (byte(s, i + 1) | 0x20) == letter && digitValue(byte(s, i + 2)) < prefixBase
}

/// The subject sequence of an integer conversion (§7.24.1.7): its sign, its
/// magnitude (saturated past `limit`), whether any digits were seen, and
/// where it ended.
func parseInteger(_ s: UnsafePointer<CChar>, base given: Int32, limit: UInt64)
  -> (negative: Bool, magnitude: UInt64, overflow: Bool, end: Int)?
{
  var i = 0
  while unsafe isSpace(byte(s, i)) { i += 1 }
  var negative = false
  if unsafe byte(s, i) == 0x2B || byte(s, i) == 0x2D {
    negative = unsafe byte(s, i) == 0x2D
    i += 1
  }
  var base = Int(given)
  guard base == 0 || (base >= 2 && base <= 36) else {
    Errno.set(Errno.invalid)
    return nil
  }
  // 0x or 0X before hex digits, 0b or 0B before binary ones (C23).
  if unsafe (base == 0 || base == 16) && hasPrefix(s, i, 0x78, 16) {
    base = 16
    i += 2
  } else if unsafe (base == 0 || base == 2) && hasPrefix(s, i, 0x62, 2) {
    base = 2
    i += 2
  } else if base == 0 {
    base = unsafe byte(s, i) == 0x30 ? 8 : 10
  }
  let start = i
  var magnitude: UInt64 = 0
  var overflow = false
  while true {
    let d = unsafe digitValue(byte(s, i))
    guard d < base else { break }
    let (m, o1) = magnitude.multipliedReportingOverflow(by: UInt64(base))
    let (a, o2) = m.addingReportingOverflow(UInt64(d))
    if o1 || o2 || a > limit { overflow = true } else { magnitude = a }
    i += 1
  }
  guard i > start else { return nil }
  return (negative, magnitude, overflow, i)
}

/// Converts the start of `nptr` to a long (§7.24.1.7); `endptr`, if given,
/// gets where the conversion stopped (`nptr` itself if nothing converted).
public func strtol(_ nptr: UnsafePointer<CChar>, _ endptr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
                   _ base: Int32) -> Int
{
  guard let p = unsafe parseInteger(nptr, base: base, limit: UInt64(Int.max) + 1) else {
    unsafe endptr?.pointee = UnsafeMutablePointer(mutating: nptr)
    return 0
  }
  unsafe endptr?.pointee = UnsafeMutablePointer(mutating: nptr + p.end)
  if p.negative {
    if p.overflow { Errno.set(Errno.range) }
    return p.overflow ? Int.min : (p.magnitude == UInt64(Int.max) + 1 ? Int.min : -Int(p.magnitude))
  }
  if p.overflow || p.magnitude > UInt64(Int.max) {
    Errno.set(Errno.range)
    return Int.max
  }
  return Int(p.magnitude)
}

/// strtol's long long, the same width on LP64.
public func strtoll(_ nptr: UnsafePointer<CChar>, _ endptr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
                    _ base: Int32) -> Int64
{ Int64(unsafe strtol(nptr, endptr, base)) }

/// Converts the start of `nptr` to an unsigned long (§7.24.1.7): a minus
/// sign negates the value in the unsigned type.
public func strtoul(_ nptr: UnsafePointer<CChar>, _ endptr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
                    _ base: Int32) -> UInt
{
  guard let p = unsafe parseInteger(nptr, base: base, limit: UInt64.max) else {
    unsafe endptr?.pointee = UnsafeMutablePointer(mutating: nptr)
    return 0
  }
  unsafe endptr?.pointee = UnsafeMutablePointer(mutating: nptr + p.end)
  if p.overflow {
    Errno.set(Errno.range)
    return UInt.max
  }
  return p.negative ? 0 &- UInt(p.magnitude) : UInt(p.magnitude)
}

/// strtoul's unsigned long long, the same width on LP64.
public func strtoull(_ nptr: UnsafePointer<CChar>, _ endptr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
                     _ base: Int32) -> UInt64
{ UInt64(unsafe strtoul(nptr, endptr, base)) }

/// strtol(nptr, NULL, 10) (§7.24.1.2); what an out-of-range value gives is
/// undefined there, and here it saturates.
public func atol(_ nptr: UnsafePointer<CChar>) -> Int { unsafe strtol(nptr, nil, 10) }

/// atol as an int (§7.24.1.2): the long, truncated.
public func atoi(_ nptr: UnsafePointer<CChar>) -> Int32 { Int32(truncatingIfNeeded: unsafe atol(nptr)) }

/// atol as a long long (§7.24.1.2).
public func atoll(_ nptr: UnsafePointer<CChar>) -> Int64 { Int64(unsafe atol(nptr)) }

/// |j| (§7.24.6.1); the most negative value's is undefined, here itself.
public func labs(_ j: Int) -> Int { j < 0 ? 0 &- j : j }

/// A comparison function, as C's qsort and bsearch take it.
public typealias Compare = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?) -> Int32

/// The element of `base`'s `n` (each `size` bytes, sorted by `compare`)
/// equal to `key`, or nil (§7.24.5.1): a binary search.
public func bsearch(_ key: UnsafeRawPointer?, _ base: UnsafeRawPointer?, _ n: Int, _ size: Int, _ compare: Compare)
  -> UnsafeRawPointer?
{
  guard let base = unsafe base else { return nil }
  var low = 0, high = n
  while low < high {
    let mid = low + (high - low) / 2
    let element = unsafe base + mid * size
    let c = unsafe compare(key, element)
    if c == 0 { return unsafe element }
    if c < 0 { high = mid } else { low = mid + 1 }
  }
  return nil
}

/// Sorts `base`'s `n` elements of `size` bytes by `compare` (§7.24.5.2), in
/// place with no allocation: a heapsort, so O(n log n) at worst. Not
/// stable (C doesn't ask it to be).
public func qsort(_ base: UnsafeMutableRawPointer?, _ n: Int, _ size: Int, _ compare: Compare) {
  guard let base = unsafe base, n > 1, size > 0 else { return }
  // Build a max-heap, then move its top to the end, n - 1 times.
  var start = n / 2
  while start > 0 {
    start -= 1
    unsafe siftDown(base, start, n, size, compare)
  }
  var end = n - 1
  while end > 0 {
    unsafe swapElements(base, 0, end, size)
    unsafe siftDown(base, 0, end, size, compare)
    end -= 1
  }
}

/// Restores the heap below `root`, within the first `count` elements.
func siftDown(_ base: UnsafeMutableRawPointer, _ root: Int, _ count: Int, _ size: Int, _ compare: Compare) {
  var parent = root
  while true {
    var largest = parent
    let left = 2 * parent + 1, right = left + 1
    if unsafe left < count && compare(base + left * size, base + largest * size) > 0 { largest = left }
    if unsafe right < count && compare(base + right * size, base + largest * size) > 0 { largest = right }
    if largest == parent { return }
    unsafe swapElements(base, parent, largest, size)
    parent = largest
  }
}

/// Swaps two elements, a byte at a time (they're of any size and alignment).
func swapElements(_ base: UnsafeMutableRawPointer, _ i: Int, _ j: Int, _ size: Int) {
  let a = unsafe base + i * size, b = unsafe base + j * size
  for k in 0..<size {
    let t = unsafe a.load(fromByteOffset: k, as: UInt8.self)
    unsafe a.storeBytes(of: b.load(fromByteOffset: k, as: UInt8.self), toByteOffset: k, as: UInt8.self)
    unsafe b.storeBytes(of: t, toByteOffset: k, as: UInt8.self)
  }
}

/// The value of `name` in `environment` (`NAME=value` strings, ending with
/// a null pointer; §7.24.4.6), or nil.
public func getenv(_ name: UnsafePointer<CChar>, in environment: UnsafePointer<UnsafeMutablePointer<CChar>?>?)
  -> UnsafeMutablePointer<CChar>?
{
  guard let environment = unsafe environment else { return nil }
  var e = 0
  while let entry = unsafe environment[e] {
    var i = 0
    while unsafe byte(name, i) != 0 && byte(name, i) != 0x3D && byte(name, i) == UInt8(bitPattern: entry[i]) { i += 1 }
    if unsafe byte(name, i) == 0 && UInt8(bitPattern: entry[i]) == 0x3D { return unsafe entry + i + 1 }
    e += 1
  }
  return nil
}
