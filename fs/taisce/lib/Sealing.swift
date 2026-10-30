// SPDX-License-Identifier: BSD-3-Clause

// An encrypted volume (S2, D153 §3): every block but the superblock rings
// AES-256-XTS, a 4 KiB block a data unit and its number the tweak, and
// every checksum keyed BLAKE3 of the plaintext, so the tree of checksums
// authenticates what XTS alone would let be changed unseen. Both keys come
// from the volume key, random at format, which the superblock's keybag
// holds wrapped. The device does the cipher; Taisce above it asks the
// device for the checksums' key and is otherwise unchanged.

import TDCrypto

/// A volume's key: 32 random bytes, made at format and never changed.
public struct VolumeKey: Equatable, Sendable {
  public let bytes: [UInt8]

  public init(_ bytes: [UInt8]) {
    precondition(bytes.count == 32, "a volume key is 32 bytes")
    self.bytes = bytes
  }
}

/// What a volume key opens: the blocks' cipher and the checksums' key,
/// each derived for its own use (BLAKE3's derive_key).
public struct Sealing: Sendable {
  public let cipher: AESXTS
  public let checksumKey: BLAKE3Key

  public init(_ key: VolumeKey) {
    var c = BLAKE3(deriveKeyContext: Array("Taisce 2026-10-30 block cipher, AES-256-XTS".utf8))
    c.update(key.bytes)
    cipher = AESXTS(key: c.finalize(count: 64))
    var k = BLAKE3(deriveKeyContext: Array("Taisce 2026-10-30 block checksums, keyed BLAKE3".utf8))
    k.update(key.bytes)
    checksumKey = BLAKE3Key(k.finalize(count: 32))
  }
}

/// A device whose blocks are encrypted, once a sealing is given: the
/// superblock rings at either end stay plain, since they hold the keybag
/// that unlocks the rest. Without one, it is its base.
public struct SealedDevice<Base: BlockDevice>: BlockDevice {
  public var base: Base
  public var sealing: Sealing?

  public init(_ base: consuming Base, sealing: Sealing? = nil) {
    self.base = base
    self.sealing = sealing
  }

  public var blockSize: Int { base.blockSize }
  public var blockCount: UInt64 { base.blockCount }
  public var checksumKey: BLAKE3Key? { sealing?.checksumKey }

  /// The blocks from `block` to `block + count` that are encrypted: all
  /// but the rings' (Layout.ringSlots at each end).
  func sealed(_ block: UInt64, count: Int) -> Range<UInt64> {
    let low = Swift.max(block, UInt64(Layout.ringSlots))
    let high = Swift.min(block + UInt64(count), blockCount >= Layout.ringSlots ? blockCount - Layout.ringSlots : 0)
    return low < high ? low..<high : low..<low
  }

  func decrypt(_ bytes: inout [UInt8], from block: UInt64) {
    guard let sealing else { return }
    let r = sealed(block, count: bytes.count / blockSize)
    guard !r.isEmpty else { return }
    let start = Int(r.lowerBound - block) * blockSize, end = Int(r.upperBound - block) * blockSize
    unsafe bytes.withUnsafeMutableBytes { b in
      unsafe sealing.cipher.decrypt(UnsafeMutableRawBufferPointer(rebasing: b[start..<end]), firstUnit: r.lowerBound,
                                    unitSize: blockSize)
    }
  }

  public mutating func read(_ block: UInt64, count: Int) throws(TaisceError) -> [UInt8] {
    var bytes = try base.read(block, count: count)
    decrypt(&bytes, from: block)
    return bytes
  }

  public mutating func write(_ block: UInt64, _ bytes: [UInt8]) throws(TaisceError) {
    guard let sealing else { return try base.write(block, bytes) }
    guard bytes.count % blockSize == 0 else { throw .outOfRange }
    let r = sealed(block, count: bytes.count / blockSize)
    guard !r.isEmpty else { return try base.write(block, bytes) }
    var out = bytes
    let start = Int(r.lowerBound - block) * blockSize, end = Int(r.upperBound - block) * blockSize
    unsafe out.withUnsafeMutableBytes { b in
      unsafe sealing.cipher.encrypt(UnsafeMutableRawBufferPointer(rebasing: b[start..<end]), firstUnit: r.lowerBound,
                                    unitSize: blockSize)
    }
    try base.write(block, out)
  }

  public mutating func flush() throws(TaisceError) { try base.flush() }
}

extension SealedDevice: @unchecked Sendable, ConcurrentReadable where Base: ConcurrentReadable {
  public func readConcurrently(_ block: UInt64, count: Int) throws(TaisceError) -> [UInt8] {
    var bytes = try base.readConcurrently(block, count: count)
    decrypt(&bytes, from: block)
    return bytes
  }
}
