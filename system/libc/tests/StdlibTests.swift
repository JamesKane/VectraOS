// SPDX-License-Identifier: BSD-3-Clause

// Our <stdlib.h> conversions, getenv, searching and sorting against the
// host's glibc (the F track's differential harness), errno included. The
// conversions are C23's, so their 0b prefix is compared with glibc's C23
// entry points (__isoc23_strtol and its kin).

import Glibc
import LibC
import Testing

typealias StrtolFunction = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, Int32) -> Int

/// glibc's C23 strtol (since 2.38), found at run time.
let isoc23Strtol: StrtolFunction? = {
  guard let symbol = dlsym(nil, "__isoc23_strtol") else { return nil }  // RTLD_DEFAULT, on glibc
  return unsafeBitCast(symbol, to: StrtolFunction.self)
}()

/// A string made to probe the subject sequence: white space, signs,
/// prefixes, digits of several bases, junk, and sometimes a huge number.
func numberLike(_ r: inout Random) -> [CChar] {
  let pieces = [" ", "\t", "\n", "\u{0B}", "+", "-", "0", "0x", "0X", "0b", "0B", "1", "7", "9", "a", "f", "F", "z",
                "Z", "g", "19", "123456789", "999999999999999999999", "9223372036854775807", "9223372036854775808",
                "-", "x", ".", "_"]
  var s = ""
  for _ in 0..<(1 + r.below(6)) { s += pieces[r.below(pieces.count)] }
  return Array(s.utf8CString)
}

typealias StrtoulFunction = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, Int32) -> UInt

/// One of glibc's C23 conversions, by name.
func isoc23<F>(_ name: String, as: F.Type) -> F? {
  guard let symbol = dlsym(nil, name) else { return nil }
  return unsafeBitCast(symbol, to: F.self)
}

@Test func strtolMatchesGlibc() throws {
  let theirs = try #require(isoc23Strtol, "glibc has __isoc23_strtol")
  var r = Random(state: 7)
  let bases: [Int32] = [0, 2, 8, 10, 16, 36] + (2...36).map { Int32($0) }
  for i in 0..<cases {
    let s = numberLike(&r), base = bases[r.below(bases.count)]
    s.withUnsafeBufferPointer { p in
      let start = p.baseAddress!
      var hostEnd: UnsafeMutablePointer<CChar>?, ourEnd: UnsafeMutablePointer<CChar>?
      errno = 0
      let h = theirs(start, &hostEnd, base)
      let hostErrno = errno
      errno = 0
      let o = LibC.strtol(start, &ourEnd, base)
      let text = String(cString: start)
      #expect(hostErrno == errno, "case \(i): strtol(\"\(text)\", \(base)): errno \(hostErrno), ours \(errno)")
      #expect(h == o && hostEnd == ourEnd, "case \(i): strtol(\"\(text)\", \(base)): glibc \(h) ends +\(hostEnd! - UnsafeMutablePointer(mutating: start)), ours \(o) ends +\(ourEnd! - UnsafeMutablePointer(mutating: start))")
    }
  }
}

@Test func atolAndAtoiMatchGlibc() {
  var r = Random(state: 8)
  for i in 0..<cases {
    let s = numberLike(&r)
    s.withUnsafeBufferPointer { p in
      let start = p.baseAddress!
      // Out of range is undefined for atol: compare where glibc's strtol is in range.
      var end: UnsafeMutablePointer<CChar>?
      let v = Glibc.strtol(start, &end, 10)
      guard v != Int.max && v != Int.min else { return }
      #expect(Glibc.atol(start) == LibC.atol(start), "case \(i): atol(\"\(String(cString: start))\")")
      if v >= Int(Int32.min) && v <= Int(Int32.max) {
        #expect(Glibc.atoi(start) == LibC.atoi(start), "case \(i): atoi(\"\(String(cString: start))\")")
      }
    }
  }
}

@Test func strtolRejectsABadBase() {
  "12".withCString { s in
    var end: UnsafeMutablePointer<CChar>?
    #expect(LibC.strtol(s, &end, 1) == 0 && end == UnsafeMutablePointer(mutating: s))
    #expect(LibC.strtol(s, &end, 37) == 0 && end == UnsafeMutablePointer(mutating: s))
  }
}

@Test func getenvMatchesGlibcOnItsEnvironment() {
  setenv("TD_LIBC_TEST", "value=with=equals", 1)
  setenv("TD_LIBC_TEST_EMPTY", "", 1)
  defer {
    unsetenv("TD_LIBC_TEST")
    unsetenv("TD_LIBC_TEST_EMPTY")
  }
  var names = ["TD_LIBC_TEST", "TD_LIBC_TEST_EMPTY", "TD_LIBC_TES", "TD_LIBC_TEST_", "", "PATH", "HOME", "NOPE"]
  var e = 0
  while let entry = environ[e], e < 200 {
    let text = String(cString: entry)
    if let eq = text.firstIndex(of: "=") { names.append(String(text[..<eq])) }
    e += 1
  }
  for name in names {
    name.withCString { n in
      let h = Glibc.getenv(n).map { String(cString: $0) }
      let o = LibC.getenv(n, in: UnsafePointer(environ)).map { String(cString: $0) }
      #expect(h == o, "getenv(\"\(name)\")")
    }
  }
}

@Test func unsignedAndLongLongConversionsMatchGlibc() throws {
  let strtoul = try #require(isoc23("__isoc23_strtoul", as: StrtoulFunction.self))
  let strtoll = try #require(isoc23("__isoc23_strtoll", as: StrtolFunction.self))
  var r = Random(state: 9)
  let bases: [Int32] = [0, 2, 8, 10, 16, 36, 1, 37] + (2...36).map { Int32($0) }
  for i in 0..<cases {
    let s = numberLike(&r), base = bases[r.below(bases.count)]
    s.withUnsafeBufferPointer { p in
      let start = p.baseAddress!
      let text = String(cString: start)
      var hostEnd: UnsafeMutablePointer<CChar>?, ourEnd: UnsafeMutablePointer<CChar>?
      errno = 0
      let h = strtoul(start, &hostEnd, base)
      let hostErrno = errno
      errno = 0
      let o = LibC.strtoul(start, &ourEnd, base)
      // A bad base leaves glibc's endptr alone, and sets ours to nptr.
      let valid = base == 0 || (2...36).contains(base)
      #expect(h == o && (hostEnd == ourEnd || !valid) && hostErrno == errno,
              "case \(i): strtoul(\"\(text)\", \(base)): glibc \(h) errno \(hostErrno), ours \(o) errno \(errno)")
      errno = 0
      let hl = strtoll(start, &hostEnd, base)
      let hostErrnoL = errno
      errno = 0
      let ol = LibC.strtoll(start, &ourEnd, base)
      #expect(hl == Int(ol) && (hostEnd == ourEnd || !valid) && hostErrnoL == errno, "case \(i): strtoll(\"\(text)\", \(base))")
      #expect(UInt64(h) == LibC.strtoull(start, nil, base), "case \(i): strtoull(\"\(text)\", \(base))")
      if hl != Int.max && hl != Int.min && base == 10 {
        #expect(Glibc.atoll(start) == LibC.atoll(start), "case \(i): atoll(\"\(text)\")")
      }
    }
  }
}

@Test func labsMatchesGlibc() {
  var r = Random(state: 10)
  for _ in 0..<cases {
    let v = Int(bitPattern: UInt(r.next()) >> UInt(r.below(64)))
    let j = r.below(2) == 0 ? v : 0 &- v
    if j != Int.min { #expect(Glibc.labs(j) == LibC.labs(j), "labs(\(j))") }
  }
}

/// Elements compared on all their bytes, so that any correct sort gives
/// the same order: a key in the first two, the rest a tiebreak.
func compareElements(_ a: UnsafeRawPointer?, _ b: UnsafeRawPointer?) -> Int32 {
  memcmp(a!, b!, sortSize)
}
nonisolated(unsafe) var sortSize = 0

@Test func qsortAndBsearchMatchGlibc() {
  var r = Random(state: 11)
  for i in 0..<500 {
    let size = 1 + r.below(24), n = 1 + r.below(300)
    sortSize = size
    // Few distinct values in the first byte: many near-ties.
    var host = (0..<(n * size)).map { k in k % size == 0 ? UInt8(r.below(4)) : UInt8(truncatingIfNeeded: r.next()) }
    var ours = host
    host.withUnsafeMutableBytes { Glibc.qsort($0.baseAddress!, n, size, compareElements) }
    ours.withUnsafeMutableBytes { LibC.qsort($0.baseAddress, n, size, compareElements) }
    #expect(host == ours, "case \(i): qsort of \(n) × \(size)")
    // Each element, and some that aren't there, searched for.
    for _ in 0..<20 {
      var key = (0..<size).map { _ in UInt8(truncatingIfNeeded: r.next()) }
      if r.below(2) == 0 {
        let k = r.below(n)
        key = Array(host[(k * size)..<((k + 1) * size)])
      }
      host.withUnsafeBytes { h in
        key.withUnsafeBytes { kp in
          let found = Glibc.bsearch(kp.baseAddress!, h.baseAddress!, n, size, compareElements)
          let ourFound = LibC.bsearch(kp.baseAddress, h.baseAddress, n, size, compareElements)
          // Equal elements may be found at different places: compare what was found.
          #expect((found == nil) == (ourFound == nil), "case \(i): bsearch")
          if let found, let ourFound { #expect(memcmp(found, ourFound, size) == 0, "case \(i): bsearch's element") }
        }
      }
    }
  }
}
