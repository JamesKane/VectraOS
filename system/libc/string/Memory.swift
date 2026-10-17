// SPDX-License-Identifier: BSD-3-Clause

// <string.h>, the memory functions: written from ISO/IEC 9899:2024 (C23)
// §7.26.2 to §7.26.6, and POSIX.1-2001 for bcmp. memcpy, memmove and
// memset go a word at a time (ring.per_1000_slots asked: every ring slot
// is a memcpy, and a byte at a time cost it 4x, 2026-10-16), the rest a
// byte at a time. A word is stored where the destination is aligned, and
// loaded wherever the source falls on amd64 and arm64, whose loads don't
// care; on rv64 only where it is aligned too, since a misaligned load
// there may trap to the firmware.
//
// These are Swift functions in the LibC module. Exporting them under their
// C names (@c) comes with the native target, built so the optimizer can't
// turn these loops back into calls to themselves.

/// Whether words may be copied between `a` and `b` once `a` is aligned:
/// always on amd64 and arm64, and on rv64 when `b` is then aligned too.
@inline(__always) func wordsFit(_ a: UnsafeRawPointer, _ b: UnsafeRawPointer) -> Bool {
  #if arch(riscv64)
    return (UInt(bitPattern: Int(bitPattern: a)) ^ UInt(bitPattern: Int(bitPattern: b))) & 7 == 0
  #else
    return true
  #endif
}

/// Bytes from `p` to the next 8-byte boundary.
@inline(__always) func toAlignment(_ p: UnsafeRawPointer) -> UInt {
  (8 &- UInt(bitPattern: Int(bitPattern: p))) & 7
}

/// A word from `p + offset`, aligned or not where wordsFit said so.
@inline(__always) func word(_ p: UnsafeRawPointer, _ offset: UInt) -> UInt64 {
  #if arch(riscv64)
    unsafe p.load(fromByteOffset: Int(offset), as: UInt64.self)
  #else
    unsafe p.loadUnaligned(fromByteOffset: Int(offset), as: UInt64.self)
  #endif
}

@inline(__always) func copyByte(_ d: UnsafeMutableRawPointer, _ s: UnsafeRawPointer, _ i: UInt) {
  unsafe d.storeBytes(of: s.load(fromByteOffset: Int(i), as: UInt8.self), toByteOffset: Int(i), as: UInt8.self)
}

/// Copies n bytes from src to dest, which must not overlap (§7.26.2.1).
public func memcpy(_ dest: UnsafeMutableRawPointer, _ src: UnsafeRawPointer, _ n: UInt) -> UnsafeMutableRawPointer {
  unsafe copyForward(dest, src, n)
  return unsafe dest
}

/// Front to back, a word at a time once dest is aligned: safe for memmove
/// when dest is below src, as each word is loaded before it's stored and
/// lands below what's still to load.
func copyForward(_ dest: UnsafeMutableRawPointer, _ src: UnsafeRawPointer, _ n: UInt) {
  var i: UInt = 0
  if n >= 16, unsafe wordsFit(dest, src) {
    let head = unsafe toAlignment(dest)
    while i < head {
      unsafe copyByte(dest, src, i)
      i += 1
    }
    while n - i >= 32 {
      let a = unsafe word(src, i), b = unsafe word(src, i + 8), c = unsafe word(src, i + 16), e = unsafe word(src, i + 24)
      unsafe dest.storeBytes(of: a, toByteOffset: Int(i), as: UInt64.self)
      unsafe dest.storeBytes(of: b, toByteOffset: Int(i + 8), as: UInt64.self)
      unsafe dest.storeBytes(of: c, toByteOffset: Int(i + 16), as: UInt64.self)
      unsafe dest.storeBytes(of: e, toByteOffset: Int(i + 24), as: UInt64.self)
      i += 32
    }
    while n - i >= 8 {
      unsafe dest.storeBytes(of: word(src, i), toByteOffset: Int(i), as: UInt64.self)
      i += 8
    }
  }
  while i < n {
    unsafe copyByte(dest, src, i)
    i += 1
  }
}

/// Copies n bytes from src to dest, which may overlap (§7.26.2.3): front
/// to back when dest is below src, back to front (a word at a time once
/// dest's end is aligned) when above.
public func memmove(_ dest: UnsafeMutableRawPointer, _ src: UnsafeRawPointer, _ n: UInt) -> UnsafeMutableRawPointer {
  if unsafe UnsafeRawPointer(dest) < src {
    unsafe copyForward(dest, src, n)
    return unsafe dest
  }
  var i = n
  if n >= 16, unsafe wordsFit(dest, src) {
    let tail = UInt(bitPattern: Int(bitPattern: unsafe dest + Int(n))) & 7
    while i > n - tail {
      i -= 1
      unsafe copyByte(dest, src, i)
    }
    while i >= 8 {
      i -= 8
      unsafe dest.storeBytes(of: word(src, i), toByteOffset: Int(i), as: UInt64.self)
    }
  }
  while i > 0 {
    i -= 1
    unsafe copyByte(dest, src, i)
  }
  return unsafe dest
}

/// Sets n bytes of s to (unsigned char)c (§7.26.6.1), a word at a time
/// once s is aligned.
public func memset(_ s: UnsafeMutableRawPointer, _ c: Int32, _ n: UInt) -> UnsafeMutableRawPointer {
  let byte = UInt8(truncatingIfNeeded: c)
  var i: UInt = 0
  if n >= 16 {
    let head = unsafe toAlignment(s)
    while i < head {
      unsafe s.storeBytes(of: byte, toByteOffset: Int(i), as: UInt8.self)
      i += 1
    }
    let fill = UInt64(byte) &* 0x0101_0101_0101_0101
    while n - i >= 8 {
      unsafe s.storeBytes(of: fill, toByteOffset: Int(i), as: UInt64.self)
      i += 8
    }
  }
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
