// SPDX-License-Identifier: BSD-3-Clause

// <string.h>, the memory functions: written from ISO/IEC 9899:2024 (C23)
// §7.26.2 to §7.26.6, and POSIX.1-2001 for bcmp. memcpy, memmove and
// memset are shaped for ring.per_1000_slots, whose every slot is a 64-byte
// memcpy: on amd64 and arm64, whose loads don't care where they fall, up
// to 128 bytes are two loads that may overlap and two stores, the loads
// first, and a longer run a vector at each end with aligned vectors
// between (6.4 to 5.3 µs per 1000 slots under KVM on a Zen 5, 2026-10-24,
// against a word at a time). On rv64, where a misaligned load may trap to the
// firmware, they go a word at a time where source and destination are
// alike aligned, else a byte at a time. The rest go a byte at a time.
//
// These are Swift functions in the LibC module. Exporting them under their
// C names (@c) comes with the native target, built so the optimizer can't
// turn these loops back into calls to themselves.

/// Copies n bytes from src to dest, which must not overlap (§7.26.2.1).
public func memcpy(_ dest: UnsafeMutableRawPointer, _ src: UnsafeRawPointer, _ n: UInt) -> UnsafeMutableRawPointer {
  unsafe copyForward(dest, src, n)
  return unsafe dest
}

#if !arch(riscv64)

/// A `T` from `p + offset`, wherever it falls.
@inline(__always) func load<T: BitwiseCopyable>(_ p: UnsafeRawPointer, _ offset: UInt, _: T.Type) -> T {
  unsafe p.loadUnaligned(fromByteOffset: Int(bitPattern: offset), as: T.self)
}

@inline(__always) func store<T: BitwiseCopyable>(_ p: UnsafeMutableRawPointer, _ offset: UInt, _ value: T) {
  unsafe p.storeBytes(of: value, toByteOffset: Int(bitPattern: offset), as: T.self)
}

/// n bytes, between one and two `T`s: both loaded, overlapping, then stored.
@inline(__always) func copyPair<T: BitwiseCopyable>(_ d: UnsafeMutableRawPointer, _ s: UnsafeRawPointer, _ n: UInt, _: T.Type) {
  let end = n &- UInt(MemoryLayout<T>.size)
  let a = unsafe load(s, 0, T.self), b = unsafe load(s, end, T.self)
  unsafe store(d, 0, a)
  unsafe store(d, end, b)
}

/// Up to 128 bytes, everything loaded before anything is stored: a move.
@inline(__always) func copyShort(_ d: UnsafeMutableRawPointer, _ s: UnsafeRawPointer, _ n: UInt) {
  if n > 64 {
    unsafe copyPair(d, s, n, SIMD64<UInt8>.self)
  } else if n > 32 {
    unsafe copyPair(d, s, n, SIMD32<UInt8>.self)
  } else if n > 16 {
    unsafe copyPair(d, s, n, SIMD16<UInt8>.self)
  } else if n >= 8 {
    unsafe copyPair(d, s, n, UInt64.self)
  } else if n >= 4 {
    unsafe copyPair(d, s, n, UInt32.self)
  } else if n >= 2 {
    unsafe copyPair(d, s, n, UInt16.self)
  } else if n == 1 {
    unsafe store(d, 0, load(s, 0, UInt8.self))
  }
}

/// More than 128 bytes, front to back: the ends loaded first and stored
/// last, aligned vectors between. Safe for memmove when dest is below src,
/// as each vector lands below what's still to load.
@inline(never) func copyLongForward(_ d: UnsafeMutableRawPointer, _ s: UnsafeRawPointer, _ n: UInt) {
  let head = unsafe load(s, 0, SIMD64<UInt8>.self), tail = unsafe load(s, n &- 64, SIMD64<UInt8>.self)
  var i = 64 &- (UInt(bitPattern: Int(bitPattern: d)) & 63)
  while n &- i > 64 {
    unsafe store(d, i, load(s, i, SIMD64<UInt8>.self))
    i &+= 64
  }
  unsafe store(d, 0, head)
  unsafe store(d, n &- 64, tail)
}

/// More than 128 bytes, back to front, for memmove when dest is above src.
@inline(never) func copyLongBackward(_ d: UnsafeMutableRawPointer, _ s: UnsafeRawPointer, _ n: UInt) {
  let head = unsafe load(s, 0, SIMD64<UInt8>.self), tail = unsafe load(s, n &- 64, SIMD64<UInt8>.self)
  var i = n &- (UInt(bitPattern: Int(bitPattern: unsafe d + Int(bitPattern: n))) & 63)
  while i > 64 {
    i &-= 64
    unsafe store(d, i, load(s, i, SIMD64<UInt8>.self))
  }
  unsafe store(d, n &- 64, tail)
  unsafe store(d, 0, head)
}

func copyForward(_ dest: UnsafeMutableRawPointer, _ src: UnsafeRawPointer, _ n: UInt) {
  if n <= 128 { unsafe copyShort(dest, src, n) } else { unsafe copyLongForward(dest, src, n) }
}

/// Copies n bytes from src to dest, which may overlap (§7.26.2.3): front
/// to back unless dest lies within the source, back to front when it does.
public func memmove(_ dest: UnsafeMutableRawPointer, _ src: UnsafeRawPointer, _ n: UInt) -> UnsafeMutableRawPointer {
  if n <= 128 {
    unsafe copyShort(dest, src, n)
  } else if UInt(bitPattern: Int(bitPattern: dest)) &- UInt(bitPattern: Int(bitPattern: src)) >= n {
    unsafe copyLongForward(dest, src, n)
  } else {
    unsafe copyLongBackward(dest, src, n)
  }
  return unsafe dest
}

/// `value` at both ends of n bytes, between one and two `T`s.
@inline(__always) func setPair<T: BitwiseCopyable>(_ s: UnsafeMutableRawPointer, _ n: UInt, _ value: T) {
  unsafe store(s, 0, value)
  unsafe store(s, n &- UInt(MemoryLayout<T>.size), value)
}

/// Sets n bytes of s to (unsigned char)c (§7.26.6.1).
public func memset(_ s: UnsafeMutableRawPointer, _ c: Int32, _ n: UInt) -> UnsafeMutableRawPointer {
  let byte = UInt8(truncatingIfNeeded: c)
  let word = UInt64(byte) &* 0x0101_0101_0101_0101
  if n > 64 {
    let fill = SIMD64<UInt8>(repeating: byte)
    unsafe setPair(s, n, fill)
    var i = 64 &- (UInt(bitPattern: Int(bitPattern: s)) & 63)
    while i &+ 64 < n {
      unsafe store(s, i, fill)
      i &+= 64
    }
  } else if n > 32 {
    unsafe setPair(s, n, SIMD32<UInt8>(repeating: byte))
  } else if n > 16 {
    unsafe setPair(s, n, SIMD16<UInt8>(repeating: byte))
  } else if n >= 8 {
    unsafe setPair(s, n, word)
  } else if n >= 4 {
    unsafe setPair(s, n, UInt32(truncatingIfNeeded: word))
  } else if n >= 2 {
    unsafe setPair(s, n, UInt16(truncatingIfNeeded: word))
  } else if n == 1 {
    unsafe store(s, 0, byte)
  }
  return unsafe s
}

#else

/// Whether words may be copied between `a` and `b` once `a` is aligned:
/// when `b` is then aligned too.
@inline(__always) func wordsFit(_ a: UnsafeRawPointer, _ b: UnsafeRawPointer) -> Bool {
  (UInt(bitPattern: Int(bitPattern: a)) ^ UInt(bitPattern: Int(bitPattern: b))) & 7 == 0
}

/// Bytes from `p` to the next 8-byte boundary.
@inline(__always) func toAlignment(_ p: UnsafeRawPointer) -> UInt {
  (8 &- UInt(bitPattern: Int(bitPattern: p))) & 7
}

/// An aligned word from `p + offset`.
@inline(__always) func word(_ p: UnsafeRawPointer, _ offset: UInt) -> UInt64 {
  unsafe p.load(fromByteOffset: Int(offset), as: UInt64.self)
}

@inline(__always) func copyByte(_ d: UnsafeMutableRawPointer, _ s: UnsafeRawPointer, _ i: UInt) {
  unsafe d.storeBytes(of: s.load(fromByteOffset: Int(i), as: UInt8.self), toByteOffset: Int(i), as: UInt8.self)
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

#endif

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
