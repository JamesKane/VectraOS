// SPDX-License-Identifier: BSD-3-Clause

// Our <string.h> against the host's glibc (the F track's differential
// harness, roadmap M0): the same random cases through both, on identical
// buffers, comparing results and every byte of the buffers afterwards, so a
// write outside the intended range shows too. Seeded, so a failure repeats.

import Glibc
import LibC
import Testing

/// SplitMix64 (Steele, Lea and Flood, 2014): small, fast, and good enough
/// to drive test cases.
struct Random {
  var state: UInt64
  mutating func next() -> UInt64 {
    state &+= 0x9e37_79b9_7f4a_7c15
    var z = state
    z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
    z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
    return z ^ (z >> 31)
  }
  mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
  /// A byte that is never NUL.
  mutating func nonzero() -> UInt8 { UInt8(1 + below(255)) }
  /// A c argument: usually a byte, sometimes with high bits or negative,
  /// which the functions must truncate to unsigned char.
  mutating func cArgument(_ byte: UInt8) -> Int32 {
    switch below(4) {
    case 0: Int32(byte) | 0x100
    case 1: Int32(Int8(bitPattern: byte))
    default: Int32(byte)
    }
  }
}

let cases = 5000
let size = 600

/// Two identical copies of a random buffer: one for glibc, one for us.
func twin(_ r: inout Random, nulFree: Bool = false) -> ([UInt8], [UInt8]) {
  let b = (0..<size).map { _ in nulFree ? r.nonzero() : UInt8(truncatingIfNeeded: r.next()) }
  return (b, b)
}

/// The sign of a comparison result: C promises only that.
func sign(_ x: Int32) -> Int32 { x < 0 ? -1 : x > 0 ? 1 : 0 }

@Test func memcpyMatchesGlibc() {
  var r = Random(state: 1)
  for i in 0..<cases {
    let n = r.below(257), d = r.below(size - 256), s = r.below(size - 256)
    var (host, ours) = twin(&r)
    let src = (0..<size).map { _ in UInt8(truncatingIfNeeded: r.next()) }
    let hr = host.withUnsafeMutableBytes { h in src.withUnsafeBytes { Glibc.memcpy(h.baseAddress! + d, $0.baseAddress! + s, n)! - h.baseAddress! } }
    let or = ours.withUnsafeMutableBytes { o in src.withUnsafeBytes { LibC.memcpy(o.baseAddress! + d, $0.baseAddress! + s, UInt(n)) - o.baseAddress! } }
    #expect(host == ours && hr == or, "case \(i): n \(n) dest +\(d) src +\(s)")
    if host != ours { return }
  }
}

@Test func memmoveMatchesGlibcWhenOverlapping() {
  var r = Random(state: 2)
  for i in 0..<cases {
    let n = r.below(257), d = r.below(size - 256), s = max(0, min(size - 256 - 1, d + r.below(65) - 32))
    var (host, ours) = twin(&r)
    _ = host.withUnsafeMutableBytes { Glibc.memmove($0.baseAddress! + d, $0.baseAddress! + s, n) }
    _ = ours.withUnsafeMutableBytes { LibC.memmove($0.baseAddress! + d, $0.baseAddress! + s, UInt(n)) }
    #expect(host == ours, "case \(i): n \(n) dest +\(d) src +\(s)")
    if host != ours { return }
  }
}

@Test func memsetMatchesGlibc() {
  var r = Random(state: 3)
  for i in 0..<cases {
    let n = r.below(257), d = r.below(size - 256), c = r.cArgument(UInt8(truncatingIfNeeded: r.next()))
    var (host, ours) = twin(&r)
    _ = host.withUnsafeMutableBytes { Glibc.memset($0.baseAddress! + d, c, n) }
    _ = ours.withUnsafeMutableBytes { LibC.memset($0.baseAddress! + d, c, UInt(n)) }
    #expect(host == ours, "case \(i): n \(n) +\(d) c \(c)")
    if host != ours { return }
  }
}

@Test func memcmpAndBcmpMatchGlibc() {
  var r = Random(state: 4)
  for i in 0..<cases {
    let n = r.below(130)
    // One byte longer than compared, so a zero-length array never has no address.
    let a = (0...n).map { _ in UInt8(truncatingIfNeeded: r.next()) }
    var b = a
    if n > 0 && r.below(4) != 0 { b[r.below(n)] = UInt8(truncatingIfNeeded: r.next()) }
    b[n] = ~a[n]  // past the end: must not be looked at
    let host = a.withUnsafeBytes { x in b.withUnsafeBytes { Glibc.memcmp(x.baseAddress!, $0.baseAddress!, n) } }
    let ours = a.withUnsafeBytes { x in b.withUnsafeBytes { LibC.memcmp(x.baseAddress!, $0.baseAddress!, UInt(n)) } }
    let bc = a.withUnsafeBytes { x in b.withUnsafeBytes { LibC.bcmp(x.baseAddress!, $0.baseAddress!, UInt(n)) } }
    #expect(sign(host) == sign(ours) && (host == 0) == (bc == 0), "case \(i): n \(n)")
  }
}

@Test func memchrMatchesGlibc() {
  var r = Random(state: 5)
  for i in 0..<cases {
    let n = r.below(200)
    let buffer = (0..<max(n, 1)).map { _ in UInt8(r.below(8)) }  // small alphabet: hits and misses
    let c = r.cArgument(UInt8(r.below(9)))
    let host = buffer.withUnsafeBytes { b in Glibc.memchr(b.baseAddress!, c, n).map { UnsafeRawPointer($0) - b.baseAddress! } }
    let ours = buffer.withUnsafeBytes { b in LibC.memchr(b.baseAddress!, c, UInt(n)).map { $0 - b.baseAddress! } }
    #expect(host == ours, "case \(i): n \(n) c \(c)")
  }
}

/// A NUL-terminated string of `length` non-NUL chars, from a small
/// alphabet (so comparisons often tie) with high bytes mixed in (so
/// signedness matters).
func string(_ r: inout Random, length: Int) -> [CChar] {
  (0..<length).map { _ in CChar(bitPattern: r.below(3) == 0 ? UInt8(0x80 + r.below(3)) : UInt8(0x61 + r.below(3))) } + [0]
}

@Test func strlenAndStrnlenMatchGlibc() {
  var r = Random(state: 6)
  for i in 0..<cases {
    let s = string(&r, length: r.below(300)), maxlen = r.below(320)
    #expect(Glibc.strlen(s) == Int(LibC.strlen(s)), "case \(i)")
    #expect(Glibc.strnlen(s, maxlen) == Int(LibC.strnlen(s, UInt(maxlen))), "case \(i): maxlen \(maxlen)")
  }
}

@Test func strcmpAndStrncmpMatchGlibc() {
  var r = Random(state: 7)
  for i in 0..<cases {
    let a = string(&r, length: r.below(12))
    var b = r.below(3) == 0 ? a : string(&r, length: r.below(12))
    if r.below(3) == 0 { b = Array(a.prefix(r.below(a.count))) + [0] }
    let n = r.below(16)
    #expect(sign(Glibc.strcmp(a, b)) == sign(LibC.strcmp(a, b)), "case \(i)")
    #expect(sign(Glibc.strncmp(a, b, n)) == sign(LibC.strncmp(a, b, UInt(n))), "case \(i): n \(n)")
  }
}

@Test func strcasecmpAndStrncasecmpMatchGlibc() {
  var r = Random(state: 70)
  // Letters in both cases, so folding is what's compared.
  let letters = Array("aAbBzZ@[`{_09".utf8).map { CChar(bitPattern: $0) }
  func word(_ n: Int) -> [CChar] { (0..<n).map { _ in letters[r.below(letters.count)] } + [0] }
  for i in 0..<cases {
    let a = word(r.below(10))
    // Or a with some of its letters' cases flipped.
    func flipped(_ c: CChar) -> CChar {
      let u = UInt8(bitPattern: c)
      let letter = (u | 0x20) >= 0x61 && (u | 0x20) <= 0x7A
      return letter && r.below(2) == 0 ? CChar(bitPattern: u ^ 0x20) : c
    }
    var b = r.below(3) == 0 ? word(r.below(10)) : a.map(flipped)
    if r.below(4) == 0 { b = Array(b.dropLast().prefix(r.below(b.count))) + [0] }
    let n = r.below(12)
    #expect(sign(Glibc.strcasecmp(a, b)) == sign(LibC.strcasecmp(a, b)), "case \(i)")
    #expect(sign(Glibc.strncasecmp(a, b, n)) == sign(LibC.strncasecmp(a, b, UInt(n))), "case \(i): n \(n)")
  }
}

@Test func strchrAndStrrchrMatchGlibc() {
  var r = Random(state: 8)
  for i in 0..<cases {
    let s = string(&r, length: r.below(40))
    let c = r.below(6) == 0 ? r.cArgument(0) : r.cArgument(UInt8(bitPattern: string(&r, length: 1)[0]))
    s.withUnsafeBufferPointer { p in
      let base = p.baseAddress!
      let hostFirst = Glibc.strchr(base, c).map { UnsafePointer($0) - base }
      let hostLast = Glibc.strrchr(base, c).map { UnsafePointer($0) - base }
      #expect(hostFirst == LibC.strchr(base, c).map { $0 - base }, "case \(i): c \(c)")
      #expect(hostLast == LibC.strrchr(base, c).map { $0 - base }, "case \(i): c \(c)")
    }
  }
}

@Test func strcatMatchesGlibc() {
  var r = Random(state: 9)
  for i in 0..<cases {
    let first = string(&r, length: r.below(100)), second = string(&r, length: r.below(100))
    var host = [CChar](repeating: 0x55, count: 256), ours = host
    host.replaceSubrange(0..<first.count, with: first)
    ours.replaceSubrange(0..<first.count, with: first)
    _ = Glibc.strcat(&host, second)
    _ = LibC.strcat(&ours, second)
    #expect(host == ours, "case \(i)")
  }
}

@Test func strncpyMatchesGlibc() {
  var r = Random(state: 10)
  for i in 0..<cases {
    let s = string(&r, length: r.below(60)), n = r.below(80)
    var host = [CChar](repeating: 0x55, count: 128), ours = host
    _ = Glibc.strncpy(&host, s, n)
    _ = LibC.strncpy(&ours, s, UInt(n))
    #expect(host == ours, "case \(i): n \(n) length \(s.count - 1)")
  }
}

@Test func strdupAndStrndupMatchGlibc() {
  var r = Random(state: 31)
  for i in 0..<cases {
    let (b, _) = twin(&r, nulFree: true)
    var s = Array(b.prefix(r.below(40)).map { CChar(bitPattern: $0) })
    s.append(0)
    let n = UInt(r.below(50))
    s.withUnsafeBufferPointer { p in
      let host = Glibc.strndup(p.baseAddress!, Int(n)), ours = LibC.strndup(p.baseAddress!, n)
      #expect(String(cString: host!) == String(cString: ours!), "case \(i): strndup(\(n))")
      free(host)
      free(ours)
      let hd = Glibc.strdup(p.baseAddress!), od = LibC.strdup(p.baseAddress!)
      #expect(String(cString: hd!) == String(cString: od!), "case \(i): strdup")
      free(hd)
      free(od)
    }
  }
}
