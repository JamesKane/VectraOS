// SPDX-License-Identifier: BSD-3-Clause

// Mapped file data (M3l, D131): a file's bytes at their own offsets in
// the VMO the fs service keeps them in, mapped read-only by its clients,
// so a cached read is a copy, not a call. What a reader needs besides the
// bytes is in the volume's slot table, mapped read-only too: a slot for
// each mapped file, 32 bytes:
//
//     0   generation UInt64  a seqlock: odd while the service writes
//     8   size       UInt64  the file's size
//     16  flags      UInt32  gone (1): unlinked, renamed, or a directory
//                            above it renamed: the path that found it may
//                            not any more; replaced (2): map it again
//
// The service bumps the generation to odd, changes the data, size or
// flags, and bumps it to even; a reader copies between two equal, even
// readings and tries again otherwise. Each slot field is read or written
// once, with a fence on each side of the change and of the copy: the
// compiler keeps the accesses where they are, and arm64 and rv64 see the
// stores in the order x86 does. A file that grew past what a client
// mapped is mapped again.

import Synchronization

public enum MappedFile {
  public static let slotSize = 32
  /// Slots in a volume's table: as many files mapped at once.
  public static let slots = 65536
  public static let gone: UInt32 = 1
  public static let replaced: UInt32 = 2
  /// Hosted, files larger than this aren't mapped (read them through Node).
  public static let largest = 64 << 20
}

/// A file's slot in a table's mapping: one side's view of it.
@safe public struct MappedSlot {
  let base: UInt

  /// `table` maps a slot table, which stays mapped.
  public init(unsafe table: UnsafeRawPointer, slot: Int) {
    base = unsafe UInt(bitPattern: table) + UInt(slot * MappedFile.slotSize)
  }

  var at: UnsafeMutableRawPointer { unsafe UnsafeMutableRawPointer(bitPattern: base)! }
  func load<T: FixedWidthInteger>(_ o: Int, _: T.Type) -> T { unsafe at.load(fromByteOffset: o, as: T.self) }
  func store<T: FixedWidthInteger>(_ o: Int, _ v: T) { unsafe at.storeBytes(of: v, toByteOffset: o, as: T.self) }

  public var generation: UInt64 { load(0, UInt64.self) }
  public var size: UInt64 { load(8, UInt64.self) }
  public var flags: UInt32 { load(16, UInt32.self) }

  // MARK: The service's side

  /// The slot given to a file of `size` bytes: no flags. The generation
  /// goes on from where it was.
  public func start(size: UInt64) {
    update {
      store(8, size)
      store(16, UInt32(0))
    }
  }

  /// Runs `change` with the generation odd.
  public func update(_ change: () -> Void) {
    let g = generation
    store(0, g | 1)
    atomicMemoryFence(ordering: .acquiringAndReleasing)  // odd before the change
    change()
    atomicMemoryFence(ordering: .acquiringAndReleasing)  // the change before even
    store(0, (g | 1) &+ 1)
  }

  /// The size, inside `update`.
  public func setSize(_ size: UInt64) { store(8, size) }

  public func setFlags(_ f: UInt32) { update { store(16, flags | f) } }

  // MARK: A client's side

  /// Up to `into.count` bytes from `offset` of the file whose bytes
  /// `data` maps (`length` of them), consistent with one generation, with
  /// nothing allocated (several readers at once share no allocator): how
  /// many; nil if the slot is gone or replaced, or the bytes are past what
  /// is mapped (map it again).
  public func read(_ data: UnsafeRawPointer, length: Int, offset: UInt64, into: UnsafeMutableRawBufferPointer) -> Int? {
    while true {
      let g = generation
      if g & 1 == 1 { continue }
      atomicMemoryFence(ordering: .acquiringAndReleasing)  // the generation before the copy
      if flags != 0 { return nil }
      let size = self.size
      let n = offset >= size ? 0 : Int(min(UInt64(unsafe into.count), size - offset))
      if n > 0 {
        guard offset + UInt64(n) <= UInt64(length) else { return nil }
        unsafe into.baseAddress!.copyMemory(from: data + Int(offset), byteCount: n)
      }
      atomicMemoryFence(ordering: .acquiringAndReleasing)  // the copy before the generation again
      if generation == g { return n }
    }
  }
}
