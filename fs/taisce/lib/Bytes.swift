// SPDX-License-Identifier: BSD-3-Clause

// Little-endian fields in byte arrays: every on-disk structure is written
// and read through these, so layouts never depend on the host's.

extension Array where Element == UInt8 {
  @inline(__always)
  mutating func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
    for i in 0..<MemoryLayout<T>.size { self[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
  }

  @inline(__always)
  func get<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
    var v: T = 0
    for i in 0..<MemoryLayout<T>.size { v |= T(self[offset + i]) << (8 * i) }
    return v
  }

  mutating func put(bytes: [UInt8], at offset: Int) {
    for (i, b) in bytes.enumerated() { self[offset + i] = b }
  }

  func get(bytes count: Int, at offset: Int) -> [UInt8] { Array(self[offset..<(offset + count)]) }

  /// Whether this key sorts before `other`, byte by byte (a prefix first):
  /// `lexicographicallyPrecedes`, without its generic iterators, which
  /// were a twentieth of the file service's time looking keys up.
  @inline(__always)
  func precedes(_ other: [UInt8]) -> Bool {
    let n = Swift.min(count, other.count)
    return unsafe withUnsafeBufferPointer { a in
      unsafe other.withUnsafeBufferPointer { b in
        var i = 0
        while i < n {
          let x = unsafe a[i], y = unsafe b[i]
          if x != y { return x < y }
          i += 1
        }
        return a.count < b.count
      }
    }
  }
}

extension Span where Element == UInt8 {
  /// A little-endian field, as `Array.get` reads one: a value read in
  /// place from a node's page.
  @inline(__always)
  func get<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
    var v: T = 0
    for i in 0..<MemoryLayout<T>.size { v |= T(self[offset + i]) << (8 * i) }
    return v
  }

  /// Whether bytes `range` are `other`'s.
  func equals(_ range: Range<Int>, _ other: [UInt8]) -> Bool {
    guard range.count == other.count else { return false }
    for i in 0..<other.count where self[range.lowerBound + i] != other[i] { return false }
    return true
  }
}
