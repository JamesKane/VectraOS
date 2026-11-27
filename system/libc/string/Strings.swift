// SPDX-License-Identifier: BSD-3-Clause

// <string.h>, the string functions: written from ISO/IEC 9899:2024 (C23)
// §7.26.2 to §7.26.6, and POSIX.1-2008 for strnlen. Strings are
// NUL-terminated arrays of char; comparisons are as unsigned char.

typealias Str = UnsafePointer<CChar>
typealias MutableStr = UnsafeMutablePointer<CChar>

@inline(__always) func byte(_ s: Str, _ i: Int) -> UInt8 { UInt8(bitPattern: unsafe s[i]) }

/// The number of chars before the terminating NUL (§7.26.6.4).
public func strlen(_ s: UnsafePointer<CChar>) -> UInt {
  var n = 0
  while unsafe s[n] != 0 { n += 1 }
  return UInt(n)
}

/// strlen, but looking at no more than maxlen chars (POSIX.1-2008).
public func strnlen(_ s: UnsafePointer<CChar>, _ maxlen: UInt) -> UInt {
  var n: UInt = 0
  while n < maxlen, unsafe s[Int(n)] != 0 { n += 1 }
  return n
}

/// Compares two strings as unsigned char (§7.26.4.2).
public func strcmp(_ s1: UnsafePointer<CChar>, _ s2: UnsafePointer<CChar>) -> Int32 {
  var i = 0
  while true {
    let a = unsafe byte(s1, i), b = unsafe byte(s2, i)
    if a != b || a == 0 { return Int32(a) - Int32(b) }
    i += 1
  }
}

/// strcmp of at most n chars (§7.26.4.5).
public func strncmp(_ s1: UnsafePointer<CChar>, _ s2: UnsafePointer<CChar>, _ n: UInt) -> Int32 {
  var i: UInt = 0
  while i < n {
    let a = unsafe byte(s1, Int(i)), b = unsafe byte(s2, Int(i))
    if a != b || a == 0 { return Int32(a) - Int32(b) }
    i += 1
  }
  return 0
}

/// A byte in the C locale's lower case.
@inline(__always) func lower(_ c: UInt8) -> UInt8 { c >= 0x41 && c <= 0x5A ? c | 0x20 : c }

/// strcmp with the C locale's letters folded to lower case (POSIX's
/// <strings.h>, M6g: FoundationEssentials compares so).
public func strcasecmp(_ s1: UnsafePointer<CChar>, _ s2: UnsafePointer<CChar>) -> Int32 {
  var i = 0
  while true {
    let a = lower(unsafe byte(s1, i)), b = lower(unsafe byte(s2, i))
    if a != b || a == 0 { return Int32(a) - Int32(b) }
    i += 1
  }
}

/// strcasecmp of at most n chars (POSIX's <strings.h>).
public func strncasecmp(_ s1: UnsafePointer<CChar>, _ s2: UnsafePointer<CChar>, _ n: UInt) -> Int32 {
  var i: UInt = 0
  while i < n {
    let a = lower(unsafe byte(s1, Int(i))), b = lower(unsafe byte(s2, Int(i)))
    if a != b || a == 0 { return Int32(a) - Int32(b) }
    i += 1
  }
  return 0
}

/// The first (char)c in s, which may be the terminating NUL, or nil (§7.26.5.3).
public func strchr(_ s: UnsafePointer<CChar>, _ c: Int32) -> UnsafePointer<CChar>? {
  let target = UInt8(truncatingIfNeeded: c)
  var i = 0
  while true {
    let b = unsafe byte(s, i)
    if b == target { return unsafe s + i }
    if b == 0 { return nil }
    i += 1
  }
}

/// The last (char)c in s, which may be the terminating NUL, or nil (§7.26.5.6).
public func strrchr(_ s: UnsafePointer<CChar>, _ c: Int32) -> UnsafePointer<CChar>? {
  let target = UInt8(truncatingIfNeeded: c)
  var found: UnsafePointer<CChar>? = nil
  var i = 0
  while true {
    let b = unsafe byte(s, i)
    if b == target { unsafe found = s + i }
    if b == 0 { return unsafe found }
    i += 1
  }
}

/// Appends s2 to the end of s1, which must have room (§7.26.3.1).
public func strcat(_ s1: UnsafeMutablePointer<CChar>, _ s2: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar> {
  var end = Int(unsafe strlen(s1))
  var i = 0
  repeat {
    unsafe s1[end] = s2[i]
    end += 1
    i += 1
  } while unsafe s2[i - 1] != 0
  return unsafe s1
}

/// Copies at most n chars of s2 to s1, padding with NULs to n; s1 is not
/// terminated if s2 is n chars or longer (§7.26.2.5).
public func strncpy(_ s1: UnsafeMutablePointer<CChar>, _ s2: UnsafePointer<CChar>, _ n: UInt) -> UnsafeMutablePointer<CChar> {
  var i: UInt = 0
  while i < n, unsafe s2[Int(i)] != 0 {
    unsafe s1[Int(i)] = s2[Int(i)]
    i += 1
  }
  while i < n {
    unsafe s1[Int(i)] = 0
    i += 1
  }
  return unsafe s1
}

@_extern(c, "malloc") func cMalloc(_ size: Int) -> UnsafeMutableRawPointer?

/// A copy of s on the heap, or nil (errno ENOMEM, the heap's) when there's
/// no room (C23 §7.26.2.6). Its body stays here (@export(interface)):
/// Embedded clients have their own malloc declaration.
@export(interface)
public func strdup(_ s: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
  unsafe strndup(s, UInt.max)
}

/// A copy of at most n chars of s on the heap, always terminated, or nil
/// (C23 §7.26.2.7).
@export(interface)
public func strndup(_ s: UnsafePointer<CChar>, _ n: UInt) -> UnsafeMutablePointer<CChar>? {
  let length = Int(unsafe strnlen(s, n))
  guard let p = unsafe cMalloc(length + 1)?.assumingMemoryBound(to: CChar.self) else { return nil }
  for i in 0..<length { unsafe p[i] = s[i] }
  unsafe p[length] = 0
  return unsafe p
}

/// The string transformed for comparison by strcmp, as strcoll compares
/// (§7.26.4.5): in the C locale, the string itself. Copies it, its NUL
/// too, when that fits in n chars; returns its length either way.
public func strxfrm(_ d: UnsafeMutablePointer<CChar>?, _ s: UnsafePointer<CChar>, _ n: UInt) -> UInt {
  let length = unsafe strlen(s)
  if length < n, let d = unsafe d {
    for i in 0...Int(length) { unsafe d[i] = s[i] }
  }
  return length
}

/// Copies s, its NUL too, to d (§7.26.2.3).
public func strcpy(_ d: UnsafeMutablePointer<CChar>, _ s: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar> {
  var i = 0
  repeat {
    unsafe d[i] = s[i]
    i += 1
  } while unsafe s[i - 1] != 0
  return unsafe d
}

/// Appends at most n chars of s, then a NUL, to d (§7.26.3.2).
public func strncat(_ d: UnsafeMutablePointer<CChar>, _ s: UnsafePointer<CChar>, _ n: UInt) -> UnsafeMutablePointer<CChar> {
  let start = Int(unsafe strlen(d))
  var i = 0
  while UInt(i) < n, unsafe s[i] != 0 {
    unsafe d[start + i] = s[i]
    i += 1
  }
  unsafe d[start + i] = 0
  return unsafe d
}

/// Whether byte b is in the NUL-terminated set.
@inline(__always) func inSet(_ b: UInt8, _ set: UnsafePointer<CChar>) -> Bool {
  var k = 0
  while true {
    let c = unsafe byte(set, k)
    if c == 0 { return false }
    if c == b { return true }
    k += 1
  }
}

/// The length of s's start made of set's chars (§7.26.5.7).
public func strspn(_ s: UnsafePointer<CChar>, _ set: UnsafePointer<CChar>) -> UInt {
  var i = 0
  while unsafe byte(s, i) != 0 && inSet(byte(s, i), set) { i += 1 }
  return UInt(i)
}

/// The length of s's start made of chars not in set (§7.26.5.4).
public func strcspn(_ s: UnsafePointer<CChar>, _ set: UnsafePointer<CChar>) -> UInt {
  var i = 0
  while unsafe byte(s, i) != 0 && !inSet(byte(s, i), set) { i += 1 }
  return UInt(i)
}

/// The first char of s in set, or nil (§7.26.5.5).
public func strpbrk(_ s: UnsafePointer<CChar>, _ set: UnsafePointer<CChar>) -> UnsafePointer<CChar>? {
  let n = Int(unsafe strcspn(s, set))
  return unsafe s[n] == 0 ? nil : s + n
}

/// The first place needle occurs in haystack, or nil; haystack itself for
/// an empty needle (§7.26.5.8).
public func strstr(_ haystack: UnsafePointer<CChar>, _ needle: UnsafePointer<CChar>) -> UnsafePointer<CChar>? {
  let m = Int(unsafe strlen(needle))
  var i = 0
  while true {
    var k = 0
    while unsafe k < m && haystack[i + k] == needle[k] { k += 1 }
    if k == m { return unsafe haystack + i }
    if unsafe haystack[i] == 0 { return nil }
    i += 1
  }
}

/// The next token of s (or of the string strtok_r left off in, when s is
/// nil), delimited by sep's chars (POSIX's strtok_r; §7.26.5.9 for strtok).
public func strtok_r(_ s: UnsafeMutablePointer<CChar>?, _ sep: UnsafePointer<CChar>,
                     _ state: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> UnsafeMutablePointer<CChar>?
{
  guard var p = unsafe s ?? state.pointee else { return nil }
  unsafe p += Int(strspn(p, sep))
  if unsafe p[0] == 0 {
    unsafe state.pointee = nil
    return nil
  }
  let n = Int(unsafe strcspn(p, sep))
  if unsafe p[n] == 0 {
    unsafe state.pointee = nil
  } else {
    unsafe p[n] = 0
    unsafe state.pointee = p + n + 1
  }
  return unsafe p
}
