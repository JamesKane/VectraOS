// SPDX-License-Identifier: BSD-3-Clause

import TDUnicode

/// A typed attribute (filesystem.md §6). Strings are UTF-8 in NFC.
public enum AttributeValue: Equatable, Sendable {
  case string([UInt8])
  case int64(Int64)
  case uint64(UInt64)
  case double(Double)
  /// Nanoseconds since 1970, UTC.
  case time(Int64)
  case bool(Bool)
  case bytes([UInt8])
  /// Another node, by inode number.
  case ref(UInt64)
  /// A MIME type, such as "text/x-email".
  case type([UInt8])

  public var kind: AttributeKind {
    switch self {
    case .string: .string
    case .int64: .int64
    case .uint64: .uint64
    case .double: .double
    case .time: .time
    case .bool: .bool
    case .bytes: .bytes
    case .ref: .ref
    case .type: .type
    }
  }

  /// Its bytes on disk: the payload alone (the kind is stored beside it).
  func payload() -> [UInt8] {
    var b = [UInt8](repeating: 0, count: 8)
    switch self {
    case .string(let s), .bytes(let s), .type(let s): return s
    case .int64(let v), .time(let v): b.put(v, at: 0)
    case .uint64(let v), .ref(let v): b.put(v, at: 0)
    case .double(let v): b.put(v.bitPattern, at: 0)
    case .bool(let v): return [v ? 1 : 0]
    }
    return b
  }

  static func decode(_ kind: AttributeKind, _ p: [UInt8]) throws(TaisceError) -> AttributeValue {
    switch kind {
    case .string: return .string(p)
    case .bytes: return .bytes(p)
    case .type: return .type(p)
    case .bool:
      guard p.count == 1 else { throw .corrupt(.attribute) }
      return .bool(p[0] != 0)
    default:
      guard p.count == 8 else { throw .corrupt(.attribute) }
      switch kind {
      case .int64: return .int64(p.get(Int64.self, at: 0))
      case .time: return .time(p.get(Int64.self, at: 0))
      case .uint64: return .uint64(p.get(UInt64.self, at: 0))
      case .ref: return .ref(p.get(UInt64.self, at: 0))
      default: return .double(Double(bitPattern: p.get(UInt64.self, at: 0)))
      }
    }
  }
}

public enum AttributeKind: UInt8, Sendable {
  case string = 1, int64, uint64, double, time, bool, bytes, ref, type
}

/// How an index compares strings.
public enum Collation: UInt8, Sendable {
  /// Byte for byte, after NFC.
  case exact = 0
  /// Canonical caseless matching (Unicode D145): "Café" finds "CAFÉ".
  case caseFolded = 1
}

/// A declared index (filesystem.md §6).
public struct IndexInfo: Equatable, Sendable {
  public var name: [UInt8]
  public var kind: AttributeKind
  public var collation: Collation
  /// Still filling in what existed before it was declared.
  public var building: Bool
  /// The tree holding it.
  var tree: UInt64
  /// The back-fill's next inode.
  var cursor: UInt64

  func encode() -> [UInt8] {
    var b = [UInt8](repeating: 0, count: 24)
    b[0] = kind.rawValue
    b[1] = collation.rawValue
    b[2] = building ? 1 : 0
    b.put(tree, at: 8)
    b.put(cursor, at: 16)
    return b
  }

  static func decode(_ name: [UInt8], _ b: [UInt8]) throws(TaisceError) -> IndexInfo {
    guard b.count == 24, let kind = AttributeKind(rawValue: b[0]), let collation = Collation(rawValue: b[1]) else {
      throw .corrupt(.index)
    }
    return IndexInfo(name: name, kind: kind, collation: collation, building: b[2] != 0, tree: b.get(UInt64.self, at: 8),
                     cursor: b.get(UInt64.self, at: 16))
  }

  /// Whether this index takes values of `kind` (MIME types count as strings).
  func accepts(_ v: AttributeValue) -> Bool {
    v.kind == kind || (kind == .string && v.kind == .type) || (kind == .type && v.kind == .string)
  }

  /// The value's part of an index key, in an encoding whose byte order is
  /// the value's order.
  func key(_ v: AttributeValue) -> [UInt8] { IndexKey.encode(v, collation) }
}

/// Order-preserving encodings for index keys.
public enum IndexKey {
  /// Longer strings are cut in the key; a query re-reads the attribute.
  static let maxString = 512

  public static func encode(_ v: AttributeValue, _ collation: Collation) -> [UInt8] {
    func be(_ x: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: x >> (56 - 8 * $0)) } }
    switch v {
    case .int64(let x), .time(let x): return be(UInt64(bitPattern: x) ^ (1 << 63))
    case .uint64(let x), .ref(let x): return be(x)
    case .double(let d):
      // IEEE total order: flip every bit of negatives, the sign bit of the rest.
      let bits = d.bitPattern
      return be(bits & (1 << 63) != 0 ? ~bits : bits ^ (1 << 63))
    case .bool(let b): return [b ? 1 : 0]
    case .string(let s), .type(let s):
      let text = collation == .caseFolded ? (Text.caselessKey(s) ?? s) : s
      return escaped(Array(text.prefix(maxString)))
    case .bytes(let s): return escaped(Array(s.prefix(maxString)))
    }
  }

  /// Bytes that sort as the original and end unambiguously: 0x00 becomes
  /// 0x00 0xFF, and 0x00 0x00 ends the string.
  static func escaped(_ s: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(s.count + 2)
    for b in s {
      out.append(b)
      if b == 0 { out.append(0xFF) }
    }
    return out + [0, 0]
  }
}

/// Why a node appears in the change journal; several can be set.
public struct ChangeReason: OptionSet, Equatable, Sendable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }
  public static let created = ChangeReason(rawValue: 1 << 0)
  public static let removed = ChangeReason(rawValue: 1 << 1)
  public static let renamed = ChangeReason(rawValue: 1 << 2)
  public static let linked = ChangeReason(rawValue: 1 << 3)
  public static let unlinked = ChangeReason(rawValue: 1 << 4)
  public static let data = ChangeReason(rawValue: 1 << 5)
  public static let attribute = ChangeReason(rawValue: 1 << 6)
  public static let metadata = ChangeReason(rawValue: 1 << 7)
}

/// One record of the persistent change journal (filesystem.md §3): the
/// backbone of node monitoring, live-query catch-up, the indexer, backup
/// and sync. A consumer keeps the last `seq` it saw and resumes after it.
public struct JournalEntry: Equatable, Sendable {
  public var seq: UInt64
  public var txg: UInt64
  public var ino: UInt64
  public var parent: UInt64
  public var reasons: ChangeReason
  /// The attribute, for `.attribute`; the new name, for names.
  public var name: [UInt8]

  func encode() -> [UInt8] {
    var b = [UInt8](repeating: 0, count: 28)
    b.put(txg, at: 0)
    b.put(ino, at: 8)
    b.put(parent, at: 16)
    b.put(reasons.rawValue, at: 24)
    return b + name
  }

  static func decode(_ seq: UInt64, _ b: [UInt8]) throws(TaisceError) -> JournalEntry {
    guard b.count >= 28 else { throw .corrupt(.journal) }
    return JournalEntry(seq: seq, txg: b.get(UInt64.self, at: 0), ino: b.get(UInt64.self, at: 8),
                        parent: b.get(UInt64.self, at: 16), reasons: ChangeReason(rawValue: b.get(UInt32.self, at: 24)),
                        name: Array(b[28...]))
  }
}
