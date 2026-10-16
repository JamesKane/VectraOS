// SPDX-License-Identifier: BSD-3-Clause

// <string.h>, the memory functions: written from ISO/IEC 9899:2024 (C23)
// §7.26.2 to §7.26.6, and POSIX.1-2001 for bcmp. Byte at a time for now:
// correct first, then measured (principle 9); word-at-a-time versions come
// when a budget asks for them.
//
// These are Swift functions in the LibC module. Exporting them under their
// C names (@c) comes with the native target, built so the optimizer can't
// turn these loops back into calls to themselves.

/// Copies n bytes from src to dest, which must not overlap (§7.26.2.1).
public func memcpy(_ dest: UnsafeMutableRawPointer, _ src: UnsafeRawPointer, _ n: UInt) -> UnsafeMutableRawPointer {
  var i: UInt = 0
  while i < n {
    unsafe dest.storeBytes(of: src.load(fromByteOffset: Int(i), as: UInt8.self), toByteOffset: Int(i), as: UInt8.self)
    i += 1
  }
  return unsafe dest
}

/// Copies n bytes from src to dest, which may overlap (§7.26.2.3).
public func memmove(_ dest: UnsafeMutableRawPointer, _ src: UnsafeRawPointer, _ n: UInt) -> UnsafeMutableRawPointer {
  if unsafe UnsafeRawPointer(dest) < src {
    var i: UInt = 0
    while i < n {
      unsafe dest.storeBytes(of: src.load(fromByteOffset: Int(i), as: UInt8.self), toByteOffset: Int(i), as: UInt8.self)
      i += 1
    }
  } else {
    var i = n
    while i > 0 {
      i -= 1
      unsafe dest.storeBytes(of: src.load(fromByteOffset: Int(i), as: UInt8.self), toByteOffset: Int(i), as: UInt8.self)
    }
  }
  return unsafe dest
}

/// Sets n bytes of s to (unsigned char)c (§7.26.6.1).
public func memset(_ s: UnsafeMutableRawPointer, _ c: Int32, _ n: UInt) -> UnsafeMutableRawPointer {
  let byte = UInt8(truncatingIfNeeded: c)
  var i: UInt = 0
  while i < n {
    unsafe s.storeBytes(of: byte, toByteOffset: Int(i), as: UInt8.self)
    i += 1
  }
  return unsafe s
}

/// Compares n bytes as unsigned char: negative, zero or positive (§7.26.4.1).
public func memcmp(_ s1: UnsafeRawPointer, _ s2: UnsafeRawPointer, _ n: UInt) -> Int32 {
  var i: UInt = 0
  while i < n {
    let a = unsafe s1.load(fromByteOffset: Int(i), as: UInt8.self)
    let b = unsafe s2.load(fromByteOffset: Int(i), as: UInt8.self)
    if a != b { return Int32(a) - Int32(b) }
    i += 1
  }
  return 0
}

/// Zero if the n bytes are equal, nonzero otherwise (POSIX.1-2001).
public func bcmp(_ s1: UnsafeRawPointer, _ s2: UnsafeRawPointer, _ n: UInt) -> Int32 {
  unsafe memcmp(s1, s2, n)
}

/// The first of n bytes equal to (unsigned char)c, or nil (§7.26.5.2).
public func memchr(_ s: UnsafeRawPointer, _ c: Int32, _ n: UInt) -> UnsafeRawPointer? {
  let byte = UInt8(truncatingIfNeeded: c)
  var i: UInt = 0
  while i < n {
    if unsafe s.load(fromByteOffset: Int(i), as: UInt8.self) == byte { return unsafe s + Int(i) }
    i += 1
  }
  return nil
}
