// SPDX-License-Identifier: BSD-3-Clause

// Names compared as bytes. The instruction tables and the validator keep mnemonics, variants and field
// names as Strings. String's own `==`, `hasPrefix` and `split` (by Character) normalise and break at
// graphemes, which needs Unicode data tables that a device program built with Embedded Swift does not
// link (a tier 0 program has none; the tree compares bytes instead). Every name here is ASCII, so bytes
// are what the comparison means.

/// A name that compares by its UTF-8 bytes: `switch name.sym { case "IADD", "ISUB": ... }`.
public struct ByteName: Equatable, ExpressibleByStringLiteral, Sendable {
  public var text: String

  public init(_ text: String) { self.text = text }
  public init(stringLiteral value: String) { text = value }

  public static func == (a: ByteName, b: ByteName) -> Bool { a.text.utf8.elementsEqual(b.text.utf8) }
}

extension String {
  /// This string as a name that compares by bytes.
  public var sym: ByteName { ByteName(self) }

  /// Whether the string's bytes start with `prefix`'s.
  public func startsWithBytes(_ prefix: String) -> Bool { utf8.starts(with: prefix.utf8) }

  /// Whether the string's bytes end with `suffix`'s.
  public func endsWithBytes(_ suffix: String) -> Bool {
    let n = utf8.count
    let m = suffix.utf8.count
    guard m <= n else { return false }
    return utf8.dropFirst(n - m).elementsEqual(suffix.utf8)
  }

  /// Whether the two strings have the same bytes.
  public func sameBytes(_ other: String) -> Bool { utf8.elementsEqual(other.utf8) }

  /// The pieces between `separator` bytes (ASCII); empty ones kept or not.
  public func splitBytes(_ separator: UInt8, omittingEmpty: Bool = true) -> [String] {
    var out: [String] = []
    var current: [UInt8] = []
    for b in utf8 {
      if b == separator {
        if !omittingEmpty || !current.isEmpty { out.append(String(decoding: current, as: UTF8.self)) }
        current.removeAll(keepingCapacity: true)
      } else {
        current.append(b)
      }
    }
    if !omittingEmpty || !current.isEmpty { out.append(String(decoding: current, as: UTF8.self)) }
    return out
  }

  /// The string without its first `n` bytes (ASCII).
  public func droppingBytes(_ n: Int) -> String { String(decoding: Array(utf8.dropFirst(n)), as: UTF8.self) }

  /// The string without its last `n` bytes (ASCII).
  public func droppingLastBytes(_ n: Int) -> String { String(decoding: Array(utf8.dropLast(n)), as: UTF8.self) }

  /// The byte offset of the first `byte`, or nil.
  public func firstByte(_ byte: UInt8) -> Int? {
    var i = 0
    for b in utf8 {
      if b == byte { return i }
      i += 1
    }
    return nil
  }

  /// The bytes from `start` up to (not including) `end`, as a String.
  public func bytes(_ start: Int, _ end: Int) -> String {
    String(decoding: Array(utf8.dropFirst(start).prefix(end - start)), as: UTF8.self)
  }
}
