// SPDX-License-Identifier: BSD-3-Clause

/// A B+tree node (filesystem.md §3): 16 KiB, decoded whole. Leaves hold
/// keys and values; an internal node holds `keys.count + 1` children, where
/// every key in `children[i + 1]` is at least `keys[i]` and every key in
/// `children[i]` is below it.
///
/// On disk: a 48-byte header (magic, level, count, then an internal node's
/// first child pointer), and cells packed after it. A leaf cell is key
/// length (u16), value length (u16), key, value; an internal cell is key
/// length, key, and the pointer to the child on its right (32 bytes: block,
/// BLAKE3-128, birth txg).
public struct Node: Equatable, Sendable {
  public var level: UInt16  // 0: a leaf
  public var keys: [[UInt8]] = []
  public var values: [[UInt8]] = []  // leaves
  public var children: [NodePointer] = []  // internal nodes

  public static let bytes = Layout.blockSize * Layout.nodeBlocks
  static let magic: UInt32 = 0x646F_4E54  // "TNod"
  static let headerSize = 48

  public init(level: UInt16) { self.level = level }

  public var isLeaf: Bool { level == 0 }

  /// The encoded size of a leaf cell, or an internal cell.
  static func leafCell(_ key: [UInt8], _ value: [UInt8]) -> Int { 4 + key.count + value.count }
  static func internalCell(_ key: [UInt8]) -> Int { 2 + key.count + NodePointer.size }

  public var size: Int {
    var n = Self.headerSize
    if isLeaf {
      for i in keys.indices { n += Self.leafCell(keys[i], values[i]) }
    } else {
      for k in keys { n += Self.internalCell(k) }
    }
    return n
  }

  public func encode() -> [UInt8] {
    var b = [UInt8](repeating: 0, count: Self.bytes)
    b.put(Self.magic, at: 0)
    b.put(level, at: 4)
    b.put(UInt16(keys.count), at: 6)
    if !isLeaf { children[0].put(into: &b, at: 8) }
    var at = Self.headerSize
    for i in keys.indices {
      b.put(UInt16(keys[i].count), at: at)
      if isLeaf {
        b.put(UInt16(values[i].count), at: at + 2)
        b.put(bytes: keys[i], at: at + 4)
        b.put(bytes: values[i], at: at + 4 + keys[i].count)
        at += Self.leafCell(keys[i], values[i])
      } else {
        b.put(bytes: keys[i], at: at + 2)
        children[i + 1].put(into: &b, at: at + 2 + keys[i].count)
        at += Self.internalCell(keys[i])
      }
    }
    return b
  }

  public static func decode(_ b: [UInt8]) throws(TaisceError) -> Node {
    guard b.count == bytes, b.get(UInt32.self, at: 0) == magic else { throw .corrupt(.node) }
    var n = Node(level: b.get(UInt16.self, at: 4))
    let count = Int(b.get(UInt16.self, at: 6))
    if !n.isLeaf { n.children.append(NodePointer.get(b, at: 8)) }
    var at = headerSize
    for _ in 0..<count {
      guard at + 4 <= bytes else { throw .corrupt(.node) }
      let klen = Int(b.get(UInt16.self, at: at))
      if n.isLeaf {
        let vlen = Int(b.get(UInt16.self, at: at + 2))
        guard at + 4 + klen + vlen <= bytes else { throw .corrupt(.node) }
        n.keys.append(b.get(bytes: klen, at: at + 4))
        n.values.append(b.get(bytes: vlen, at: at + 4 + klen))
        at += 4 + klen + vlen
      } else {
        guard at + 2 + klen + NodePointer.size <= bytes else { throw .corrupt(.node) }
        n.keys.append(b.get(bytes: klen, at: at + 2))
        n.children.append(NodePointer.get(b, at: at + 2 + klen))
        at += 2 + klen + NodePointer.size
      }
    }
    return n
  }

  /// The first index whose key is at least `key` (binary search).
  func lowerBound(_ key: [UInt8]) -> Int {
    var lo = 0, hi = keys.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if keys[mid].lexicographicallyPrecedes(key) { lo = mid + 1 } else { hi = mid }
    }
    return lo
  }

  /// The child of an internal node that covers `key`.
  func childIndex(_ key: [UInt8]) -> Int {
    var lo = 0, hi = keys.count  // the number of keys ≤ key
    while lo < hi {
      let mid = (lo + hi) / 2
      if key.lexicographicallyPrecedes(keys[mid]) { hi = mid } else { lo = mid + 1 }
    }
    return lo
  }
}
