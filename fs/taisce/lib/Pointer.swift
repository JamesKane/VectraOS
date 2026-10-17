// SPDX-License-Identifier: BSD-3-Clause

import TDCrypto

/// A block's BLAKE3 hash, its first 128 bits (S1 decision 1).
public struct Checksum: Equatable, Hashable, Sendable {
  public var a: UInt64
  public var b: UInt64

  public static let zero = Checksum(a: 0, b: 0)

  public init(a: UInt64, b: UInt64) {
    self.a = a
    self.b = b
  }

  /// The checksum of `bytes`.
  public init(of bytes: [UInt8]) {
    let h = BLAKE3.hash(bytes, count: 16)
    a = h.get(UInt64.self, at: 0)
    b = h.get(UInt64.self, at: 8)
  }
}

/// A pointer to a B+tree node (filesystem.md §3, S1 decision 3): where it
/// is, the checksum its bytes must have, and the transaction group that
/// wrote it. Physical: there's no object map.
///
/// Inside a transaction group, a node that has changed has a pointer with
/// no checksum yet (`fresh`); committing writes it and fills one in.
public struct NodePointer: Equatable, Sendable {
  public var block: UInt64
  public var checksum: Checksum
  public var birth: UInt64

  public init(block: UInt64, checksum: Checksum, birth: UInt64) {
    self.block = block
    self.checksum = checksum
    self.birth = birth
  }

  /// No node: an empty tree.
  public static let null = NodePointer(block: 0, checksum: .zero, birth: 0)

  /// A node changed in this group, not yet written.
  static func fresh(_ block: UInt64) -> NodePointer { NodePointer(block: block, checksum: .zero, birth: 0) }

  public var isNull: Bool { block == 0 }

  static let size = 32

  func put(into b: inout [UInt8], at offset: Int) {
    b.put(block, at: offset)
    b.put(checksum.a, at: offset + 8)
    b.put(checksum.b, at: offset + 16)
    b.put(birth, at: offset + 24)
  }

  static func get(_ b: [UInt8], at offset: Int) -> NodePointer {
    NodePointer(block: b.get(UInt64.self, at: offset),
                checksum: Checksum(a: b.get(UInt64.self, at: offset + 8), b: b.get(UInt64.self, at: offset + 16)),
                birth: b.get(UInt64.self, at: offset + 24))
  }

  func encode() -> [UInt8] {
    var b = [UInt8](repeating: 0, count: Self.size)
    put(into: &b, at: 0)
    return b
  }
}
