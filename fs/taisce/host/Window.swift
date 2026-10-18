// SPDX-License-Identifier: BSD-3-Clause

// A part of another device, as a device of its own: a disk image's
// partition, for vx disk's mkfs and vx fsck (D105). Its blocks are the
// base's from `first`, `blockCount` of them.

import Taisce

public struct WindowDevice<Base: BlockDevice>: BlockDevice {
  public var base: Base
  public let first: UInt64
  public let blockCount: UInt64
  public var blockSize: Int { base.blockSize }

  public init(_ base: Base, first: UInt64, count: UInt64) throws(TaisceError) {
    guard first <= base.blockCount, count <= base.blockCount - first else { throw .outOfRange }
    self.base = base
    self.first = first
    blockCount = count
  }

  public mutating func read(_ block: UInt64, count: Int) throws(TaisceError) -> [UInt8] {
    guard count >= 0, block <= blockCount, UInt64(count) <= blockCount - block else { throw .outOfRange }
    return try base.read(first + block, count: count)
  }

  public mutating func write(_ block: UInt64, _ bytes: [UInt8]) throws(TaisceError) {
    guard bytes.count % blockSize == 0, block <= blockCount, UInt64(bytes.count / blockSize) <= blockCount - block else {
      throw .outOfRange
    }
    try base.write(first + block, bytes)
  }

  public mutating func flush() throws(TaisceError) { try base.flush() }
}
