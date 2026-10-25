// SPDX-License-Identifier: BSD-3-Clause

// A font's bytes, read big-endian (OpenType's data types, OpenType 1.9
// "Data types") with every read bounds-checked: a malformed font throws,
// never traps.

/// Why a font couldn't be read.
public enum FontError: Error, Equatable, Sendable {
  /// Not an OpenType font (or a collection, which isn't read yet).
  case notAFont
  /// A table the font needs is missing.
  case missingTable(String)
  /// A table's bytes don't hold what it says.
  case malformed(String)
  /// The glyph index is past the font's glyphs.
  case noGlyph(Int)
  /// What the font is made of is a stub here (text/README.md): CFF2, seac.
  case unsupported(String)
}

/// A window on a font's bytes.
public struct Bytes: Sendable {
  let data: [UInt8]
  let start: Int
  public let count: Int

  public init(_ data: [UInt8]) {
    self.data = data
    start = 0
    count = data.count
  }

  init(_ data: [UInt8], start: Int, count: Int) {
    self.data = data
    self.start = start
    self.count = count
  }

  /// The `count` bytes at `offset`, or malformed(`what`).
  public func slice(_ offset: Int, _ count: Int, _ what: String) throws(FontError) -> Bytes {
    guard offset >= 0, count >= 0, offset <= self.count, count <= self.count - offset else { throw .malformed(what) }
    return Bytes(data, start: start + offset, count: count)
  }

  /// The bytes from `offset` to the end.
  public func from(_ offset: Int, _ what: String) throws(FontError) -> Bytes {
    try slice(offset, count - max(0, min(offset, count)), what)
  }

  public func u8(_ at: Int) throws(FontError) -> UInt8 {
    guard at >= 0, at < count else { throw .malformed("a read past the end") }
    return data[start + at]
  }

  public func u16(_ at: Int) throws(FontError) -> UInt16 {
    guard at >= 0, at + 2 <= count else { throw .malformed("a read past the end") }
    return UInt16(data[start + at]) << 8 | UInt16(data[start + at + 1])
  }

  public func i16(_ at: Int) throws(FontError) -> Int16 { Int16(bitPattern: try u16(at)) }

  public func u32(_ at: Int) throws(FontError) -> UInt32 {
    UInt32(try u16(at)) << 16 | UInt32(try u16(at + 2))
  }

  public func i32(_ at: Int) throws(FontError) -> Int32 { Int32(bitPattern: try u32(at)) }

  /// An unsigned integer of `size` bytes (1 to 4), as CFF's offsets are.
  public func uint(_ at: Int, size: Int) throws(FontError) -> UInt32 {
    var v: UInt32 = 0
    for i in 0..<size { v = v << 8 | UInt32(try u8(at + i)) }
    return v
  }

  /// A four-letter tag.
  public func tag(_ at: Int) throws(FontError) -> String {
    let v = try u32(at)
    let bytes = (0..<4).map { UInt8(truncatingIfNeeded: v >> (24 - 8 * UInt32($0))) }
    return String(decoding: bytes, as: UTF8.self)
  }
}
