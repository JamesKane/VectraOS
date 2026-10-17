// SPDX-License-Identifier: BSD-3-Clause

import TDUnicode

/// What a node is.
public enum NodeType: UInt8, Sendable {
  case file = 1
  case directory = 2
  case symlink = 3
}

/// A node's fixed fields (filesystem.md §3, INODE): 96 bytes on disk.
public struct Inode: Equatable, Sendable {
  public var type: NodeType
  public var mode: UInt32  // permission bits, 0o7777
  public var uid: UInt32 = 0
  public var gid: UInt32 = 0
  public var links: UInt32
  public var flags: UInt32 = 0
  public var size: UInt64 = 0
  public var atime: UInt64
  public var mtime: UInt64
  public var ctime: UInt64
  public var btime: UInt64
  /// A directory's parent (the root is its own).
  public var parent: UInt64
  /// Bumped by every change, for caches and the journal.
  public var version: UInt64 = 1

  public init(type: NodeType, mode: UInt32, parent: UInt64, now: UInt64) {
    self.type = type
    self.mode = mode & 0o7777
    links = type == .directory ? 2 : 1
    atime = now
    mtime = now
    ctime = now
    btime = now
    self.parent = parent
  }

  static let bytes = 96

  func encode() -> [UInt8] {
    var b = [UInt8](repeating: 0, count: Self.bytes)
    b.put(type.rawValue, at: 0)
    b.put(mode, at: 4)
    b.put(uid, at: 8)
    b.put(gid, at: 12)
    b.put(links, at: 16)
    b.put(flags, at: 20)
    b.put(size, at: 24)
    b.put(atime, at: 32)
    b.put(mtime, at: 40)
    b.put(ctime, at: 48)
    b.put(btime, at: 56)
    b.put(parent, at: 64)
    b.put(version, at: 72)
    return b
  }

  static func decode(_ b: [UInt8]) throws(TaisceError) -> Inode {
    guard b.count >= bytes, let type = NodeType(rawValue: b[0]) else { throw .corrupt(.inode) }
    var n = Inode(type: type, mode: b.get(UInt32.self, at: 4), parent: b.get(UInt64.self, at: 64), now: 0)
    n.uid = b.get(UInt32.self, at: 8)
    n.gid = b.get(UInt32.self, at: 12)
    n.links = b.get(UInt32.self, at: 16)
    n.flags = b.get(UInt32.self, at: 20)
    n.size = b.get(UInt64.self, at: 24)
    n.atime = b.get(UInt64.self, at: 32)
    n.mtime = b.get(UInt64.self, at: 40)
    n.ctime = b.get(UInt64.self, at: 48)
    n.btime = b.get(UInt64.self, at: 56)
    n.version = b.get(UInt64.self, at: 72)
    return n
  }

  // Offsets for blind deltas.
  static let sizeOffset = 24
  static let mtimeOffset = 40
  static let ctimeOffset = 48
  static let versionOffset = 72
}

/// Keys in the file system tree: `(ino, kind, sub_key)`, big-endian so
/// byte order is numeric order and a node's keys are together.
enum FSKey {
  /// The file system's own tree: inodes, entries, extents, attributes.
  static let tree: UInt64 = 1
  static let rootDirectory: UInt64 = 1
  static let overflowFlag: UInt8 = 0x80

  /// A valid attribute name, normalized: UTF-8 in NFC, a namespace before a
  /// colon ("user:rating", "Audio:Artist"), no NUL, at most 255 bytes.
  static func attributeName(_ name: [UInt8]) throws(TaisceError) -> [UInt8] {
    guard let n = Text.normalized(name), n.count <= 255, !n.contains(0) else { throw .invalid }
    guard let colon = n.firstIndex(of: 0x3A), colon > 0, colon < n.count - 1 else { throw .invalid }
    return n
  }

  static func chunkKey(_ ino: UInt64, _ name: [UInt8], _ index: UInt32) -> [UInt8] {
    FSKey.make(ino, FSKey.attributeChunk, name + [0] + (0..<4).map { UInt8(truncatingIfNeeded: index >> (24 - 8 * $0)) })
  }

  static let inode: UInt8 = 0
  static let dirent: UInt8 = 1
  static let attribute: UInt8 = 2  // S0f
  static let extent: UInt8 = 3
  static let symlink: UInt8 = 4
  static let attributeChunk: UInt8 = 5
  /// (ino, NAME, dir + name): each of a node's names, from the node's side.
  static let name: UInt8 = 6

  static func make(_ ino: UInt64, _ kind: UInt8, _ sub: [UInt8] = []) -> [UInt8] {
    var k = [UInt8](repeating: 0, count: 9)
    for i in 0..<8 { k[i] = UInt8(truncatingIfNeeded: ino >> (56 - 8 * i)) }
    k[8] = kind
    return k + sub
  }

  static func u64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> (56 - 8 * $0)) } }

  static func readU64(_ k: [UInt8], at offset: Int) -> UInt64 {
    var v: UInt64 = 0
    for i in 0..<8 { v = v << 8 | UInt64(k[offset + i]) }
    return v
  }
}

/// A directory entry.
public struct DirectoryEntry: Equatable, Sendable {
  public var name: [UInt8]
  public var ino: UInt64
  public var type: NodeType
}

/// The entries whose names share a hash, as one value: a count, then
/// (ino u64, type u8, name length u16, name) each. Almost always one.
enum Bucket {
  static func decode(_ b: [UInt8]) throws(TaisceError) -> [DirectoryEntry] {
    guard b.count >= 2 else { throw .corrupt(.directory) }
    var out: [DirectoryEntry] = []
    var at = 2
    for _ in 0..<Int(b.get(UInt16.self, at: 0)) {
      guard at + 11 <= b.count, let type = NodeType(rawValue: b[at + 8]) else { throw .corrupt(.directory) }
      let n = Int(b.get(UInt16.self, at: at + 9))
      guard at + 11 + n <= b.count else { throw .corrupt(.directory) }
      out.append(DirectoryEntry(name: b.get(bytes: n, at: at + 11), ino: b.get(UInt64.self, at: at), type: type))
      at += 11 + n
    }
    return out
  }

  static func encode(_ entries: [DirectoryEntry]) -> [UInt8] {
    var b = [UInt8](repeating: 0, count: 2 + entries.reduce(0) { $0 + 11 + $1.name.count })
    b.put(UInt16(entries.count), at: 0)
    var at = 2
    for e in entries {
      b.put(e.ino, at: at)
      b.put(e.type.rawValue, at: at + 8)
      b.put(UInt16(e.name.count), at: at + 9)
      b.put(bytes: e.name, at: at + 11)
      at += 11 + e.name.count
    }
    return b
  }

  /// FNV-1a, 64-bit: where a name's bucket is.
  static func hash(_ name: [UInt8]) -> UInt64 {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for b in name {
      h ^= UInt64(b)
      h = h &* 0x0000_0100_0000_01B3
    }
    return h
  }
}
