// SPDX-License-Identifier: BSD-3-Clause

// Network byte order in byte arrays (N1b): reading and writing big-endian
// fields at offsets, and the Internet checksum (RFC 1071). Every protocol
// here reads a frame through these, bounds-checked; a frame too short for
// a field is refused by its parser before it reads it.

extension Array where Element == UInt8 {
  @inline(__always) func be16(_ at: Int) -> UInt16 { UInt16(self[at]) << 8 | UInt16(self[at + 1]) }

  @inline(__always) func be32(_ at: Int) -> UInt32 {
    UInt32(self[at]) << 24 | UInt32(self[at + 1]) << 16 | UInt32(self[at + 2]) << 8 | UInt32(self[at + 3])
  }

  @inline(__always) mutating func put16(_ v: UInt16, _ at: Int) {
    self[at] = UInt8(truncatingIfNeeded: v >> 8)
    self[at + 1] = UInt8(truncatingIfNeeded: v)
  }

  @inline(__always) mutating func put32(_ v: UInt32, _ at: Int) {
    self[at] = UInt8(truncatingIfNeeded: v >> 24)
    self[at + 1] = UInt8(truncatingIfNeeded: v >> 16)
    self[at + 2] = UInt8(truncatingIfNeeded: v >> 8)
    self[at + 3] = UInt8(truncatingIfNeeded: v)
  }
}

/// The Internet checksum (RFC 1071): the ones' complement sum of 16-bit
/// big-endian words, an odd last byte padded with zero.
public struct InternetChecksum {
  var sum: UInt64 = 0

  public init() {}

  /// Adds `count` bytes at `offset`. An odd count must come last.
  public mutating func add(_ b: [UInt8], _ offset: Int, _ count: Int) {
    var i = offset
    let end = offset + count
    while i + 1 < end {
      sum &+= UInt64(b[i]) << 8 | UInt64(b[i + 1])
      i += 2
    }
    if i < end { sum &+= UInt64(b[i]) << 8 }
  }

  public mutating func add16(_ v: UInt16) { sum &+= UInt64(v) }
  public mutating func add32(_ v: UInt32) { sum &+= UInt64(v >> 16) &+ UInt64(v & 0xFFFF) }

  /// The checksum to store: the complement of the folded sum.
  public var value: UInt16 {
    var s = sum
    while s >> 16 != 0 { s = (s & 0xFFFF) &+ (s >> 16) }
    return ~UInt16(truncatingIfNeeded: s)
  }

  /// The checksum of `count` bytes at `offset`; 0 over data that carries
  /// its own correct checksum.
  public static func of(_ b: [UInt8], _ offset: Int, _ count: Int) -> UInt16 {
    var c = InternetChecksum()
    c.add(b, offset, count)
    return c.value
  }
}
