// SPDX-License-Identifier: BSD-3-Clause

// Little-endian fields in byte arrays: the formats here (ELF, PE, bootfs)
// are all little-endian, and are read and written field by field, never
// through struct layout.

/// A format error: what was wrong with the input, for the tool to report.
public struct FormatError: Error, Equatable, CustomStringConvertible {
  public var description: String
  public init(_ description: String) { self.description = description }
}

extension Array where Element == UInt8 {
  func u16(_ at: Int) -> UInt16 { UInt16(self[at]) | UInt16(self[at + 1]) << 8 }
  func u32(_ at: Int) -> UInt32 { UInt32(u16(at)) | UInt32(u16(at + 2)) << 16 }
  func u64(_ at: Int) -> UInt64 { UInt64(u32(at)) | UInt64(u32(at + 4)) << 32 }

  /// Bounds-checked reads, for input that might be truncated.
  func checked(_ at: Int, _ size: Int) throws(FormatError) {
    guard at >= 0, size >= 0, at <= count - size else { throw FormatError("truncated at offset \(at)") }
  }

  mutating func put16(_ at: Int, _ v: UInt16) {
    self[at] = UInt8(truncatingIfNeeded: v)
    self[at + 1] = UInt8(truncatingIfNeeded: v >> 8)
  }
  mutating func put32(_ at: Int, _ v: UInt32) {
    put16(at, UInt16(truncatingIfNeeded: v))
    put16(at + 2, UInt16(truncatingIfNeeded: v >> 16))
  }
  mutating func put64(_ at: Int, _ v: UInt64) {
    put32(at, UInt32(truncatingIfNeeded: v))
    put32(at + 4, UInt32(truncatingIfNeeded: v >> 32))
  }

  mutating func append16(_ v: UInt16) { append(contentsOf: [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)]) }
  mutating func append32(_ v: UInt32) {
    append16(UInt16(truncatingIfNeeded: v))
    append16(UInt16(truncatingIfNeeded: v >> 16))
  }
}

func align(_ value: Int, _ to: Int) -> Int { (value + to - 1) & ~(to - 1) }
