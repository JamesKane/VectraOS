// SPDX-License-Identifier: BSD-3-Clause

/// What the writer's FileSystem keeps of the names and inodes it has read
/// (D143), as Fxfs keeps its dirent cache: a name's node by (directory,
/// name), and a node's inode, decoded. Each table is direct-mapped: a new
/// entry takes its slot from whatever held it. Every batch drops the
/// entries whose keys it changes (`dropping`), before it lands.
struct MetadataCache {
  struct Name {
    var dir: UInt64
    /// The name's bucket hash (`Bucket.hash`), its directory entry's key.
    var hash: UInt64
    var name: [UInt8]
    var ino: UInt64
  }

  struct Cached {
    var ino: UInt64
    var inode: Inode
  }

  static var slots: Int { 4096 }
  var names = [Name?](repeating: nil, count: MetadataCache.slots)
  var inodes = [Cached?](repeating: nil, count: MetadataCache.slots)

  /// A slot for a directory and a name hash, or for a node (hash 0).
  static func slot(_ a: UInt64, _ b: UInt64) -> Int {
    Int(truncatingIfNeeded: (((a &* 0x9E37_79B9_7F4A_7C15) ^ b) &* 0x9E37_79B9_7F4A_7C15) >> 52) & (slots - 1)
  }

  func inode(_ ino: UInt64) -> Inode? {
    guard let c = inodes[Self.slot(ino, 0)], c.ino == ino else { return nil }
    return c.inode
  }

  mutating func keep(_ ino: UInt64, _ inode: Inode) { inodes[Self.slot(ino, 0)] = Cached(ino: ino, inode: inode) }

  func lookup(_ dir: UInt64, _ hash: UInt64, _ name: [UInt8]) -> UInt64? {
    guard let n = names[Self.slot(dir, hash)], n.dir == dir, n.hash == hash, n.name == name else { return nil }
    return n.ino
  }

  mutating func keep(_ dir: UInt64, _ hash: UInt64, _ name: [UInt8], _ ino: UInt64) {
    names[Self.slot(dir, hash)] = Name(dir: dir, hash: hash, name: name, ino: ino)
  }

  /// Drops what a change to the file tree's `key` may have made stale: an
  /// inode key's node, a directory entry key's (directory, hash) slot.
  mutating func dropping(_ key: [UInt8]) {
    guard key.count >= 9 else { return }
    let ino = FSKey.readU64(key, at: 0)
    switch key[8] {
    case FSKey.inode:
      let s = Self.slot(ino, 0)
      if inodes[s]?.ino == ino { inodes[s] = nil }
    case FSKey.dirent where key.count == 17:
      let hash = FSKey.readU64(key, at: 9)
      let s = Self.slot(ino, hash)
      if let n = names[s], n.dir == ino, n.hash == hash { names[s] = nil }
    default:
      break
    }
  }
}
