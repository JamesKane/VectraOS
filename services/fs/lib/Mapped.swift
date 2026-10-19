// SPDX-License-Identifier: BSD-3-Clause

// Mapped file data (M3l, decided 2026-10-10): a file's bytes in a VMO the
// fs service keeps up to date and its clients map read-only, so a cached
// read is a copy, not a call. The VMO's first page is a header, the data
// follows it:
//
//     0   magic      UInt32  "TDMF"
//     4   flags      UInt32  gone (1): unlinked, renamed, or a directory
//                            above it renamed: the path that found it may
//                            not any more; replaced (2): it outgrew this
//                            VMO: map it again
//     8   generation UInt64  a seqlock: odd while the service writes
//     16  size       UInt64  the file's size
//     24  capacity   UInt64  bytes of data the VMO holds
//     4096...        data
//
// The service bumps the generation to odd, changes data, size or flags,
// and bumps it to even; a reader copies between two equal, even readings
// and tries again otherwise. Each header field is read or written once,
// with a fence on each side of the change and of the copy: the compiler
// keeps the accesses where they are, and arm64 and rv64 see the stores in
// the order x86 does.

import Synchronization

public enum MappedFile {
  public static let headerSize = 4096
  public static let magic: UInt32 = 0x464D_4454  // "TDMF"
  public static let gone: UInt32 = 1
  public static let replaced: UInt32 = 2
  /// Files larger than this aren't mapped (read them through Node).
  public static let largest = 64 << 20

  /// The VMO size for a file of `size` bytes: room to grow by a quarter, in pages.
  public static func vmoSize(for size: Int) -> Int {
    let capacity = (size + size / 4 + 4095) & ~4095
    return headerSize + max(capacity, 4096)
  }
}

/// The header at a mapping's start: one side's view of it.
@safe public struct MappedHeader {
  let base: UInt

  /// `base` maps the VMO's first page (at least), and stays mapped.
  public init(unsafe base: UnsafeMutableRawPointer) { self.base = unsafe UInt(bitPattern: base) }

  var at: UnsafeMutableRawPointer { unsafe UnsafeMutableRawPointer(bitPattern: base)! }
  func load<T: FixedWidthInteger>(_ o: Int, _: T.Type) -> T { unsafe at.load(fromByteOffset: o, as: T.self) }
  func store<T: FixedWidthInteger>(_ o: Int, _ v: T) { unsafe at.storeBytes(of: v, toByteOffset: o, as: T.self) }

  public var magic: UInt32 { load(0, UInt32.self) }
  public var flags: UInt32 { load(4, UInt32.self) }
  public var generation: UInt64 { load(8, UInt64.self) }
  public var size: UInt64 { load(16, UInt64.self) }
  public var capacity: UInt64 { load(24, UInt64.self) }

  var data: UnsafeMutableRawPointer { unsafe UnsafeMutableRawPointer(bitPattern: base + UInt(MappedFile.headerSize))! }

  // MARK: The service's side

  /// A new header for `size` bytes of data in `capacity`.
  public func start(size: UInt64, capacity: UInt64) {
    store(0, MappedFile.magic)
    store(4, UInt32(0))
    store(8, UInt64(0))
    store(16, size)
    store(24, capacity)
  }

  /// Runs `change` with the generation odd.
  public func update(_ change: () -> Void) {
    let g = generation
    store(8, g | 1)
    atomicMemoryFence(ordering: .acquiringAndReleasing)  // odd before the change
    change()
    atomicMemoryFence(ordering: .acquiringAndReleasing)  // the change before even
    store(8, (g | 1) &+ 1)
  }

  public func setFlags(_ f: UInt32) { update { store(4, flags | f) } }

  /// Writes `bytes` at `offset` and the size (the caller checked capacity).
  public func write(_ bytes: [UInt8], at offset: Int, size: UInt64) {
    update {
      unsafe bytes.withUnsafeBytes { unsafe (data + offset).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
      store(16, size)
    }
  }

  /// A new size; bytes past the old end read as zero.
  public func resize(_ new: UInt64) {
    update {
      let old = size
      if new > old { unsafe (data + Int(old)).initializeMemory(as: UInt8.self, repeating: 0, count: Int(new - old)) }
      store(16, new)
    }
  }

  // MARK: A client's side

  /// Up to `count` bytes from `offset`, consistent with one generation;
  /// nil if the mapping is gone or replaced (look the file up again).
  public func read(offset: UInt64, count: Int) -> [UInt8]? {
    while true {
      let g = generation
      if g & 1 == 1 { continue }
      atomicMemoryFence(ordering: .acquiringAndReleasing)  // the generation before the copy
      if flags != 0 { return nil }
      let size = self.size
      let n = offset >= size ? 0 : Int(min(UInt64(count), size - offset))
      var out = [UInt8](repeating: 0, count: n)
      if n > 0 {
        unsafe out.withUnsafeMutableBytes { unsafe $0.baseAddress!.copyMemory(from: data + Int(offset), byteCount: n) }
      }
      atomicMemoryFence(ordering: .acquiringAndReleasing)  // the copy before the generation again
      if generation == g { return out }
    }
  }
}
