// SPDX-License-Identifier: BSD-3-Clause

// The heap: memory from VMOs mapped into the root VMAR. Requests of up to
// 128 KiB (with their 16-byte header) at alignments up to 16 come from size
// classes (32 B to 128 KiB, powers of two) carved from 1 MiB chunks and
// kept on per-class free lists; anything else gets a mapping of its own,
// unmapped when freed. The classes reach that far because a mapping costs
// system calls, page faults and, unmapped, a TLB shootdown: a 4 KiB block
// with its header, or a channel's largest message, must not (M3e measured
// a channel read at 137 us when its 64 KiB buffer was a mapping). Embedded Swift allocates through posix_memalign and
// free. Correct first, then measured (principle 9).

import CroiSyscall
import TDNative

enum Heap {
  static let classes = 13
  static let smallest = 32
  static let chunkSize = 1024 * 1024
  static let pageSize = 4096
  /// A header's tag: a class index, or this bit and a mapping's length.
  static let largeBit: UInt64 = 1 << 63

  nonisolated(unsafe) static var vmar: UInt32 = 0
  nonisolated(unsafe) static var free = InlineArray<13, UInt>(repeating: 0)
  nonisolated(unsafe) static var chunk: UInt = 0
  nonisolated(unsafe) static var chunkLeft = 0
  /// Every allocation since start (M6m: the editor's criterion counts
  /// those in a frame's layout and paint), counted under the lock.
  nonisolated(unsafe) static var allocations: UInt64 = 0
  static let lock = RuntimeLock()

  /// A fresh read-write mapping of `length` bytes (a page multiple), or 0.
  static func map(_ length: Int) -> UInt {
    var vmo: UInt32 = 0
    let made = unsafe withUnsafeMutablePointer(to: &vmo) { p in
      unsafe croi_syscall(CROI_SYS_VMO_CREATE, UInt64(length), 0, UInt64(UInt(bitPattern: p)), 0, 0)
    }
    guard made == 0 else { return 0 }
    defer { _ = croi_handle_close(vmo) }
    var address: UInt64 = 0
    let mapped = unsafe croi_vmar_map(vmar, CROI_VM_PERM_READ | CROI_VM_PERM_WRITE, 0, vmo, 0, UInt64(length), &address)
    return mapped == 0 ? UInt(address) : 0
  }

  static func unmap(_ address: UInt, _ length: Int) {
    _ = croi_vmar_unmap(vmar, UInt64(address), UInt64(length))
  }

  static func classIndex(_ size: Int) -> Int? {
    var c = 0
    var block = smallest
    while block < size + 16 {
      c += 1
      block <<= 1
      if c == classes { return nil }
    }
    return c
  }

  static func allocate(_ size: Int, _ alignment: Int) -> UInt {
    if alignment <= 16, let c = classIndex(size) {
      td_heap_noted()
      return lock.locked { () -> UInt in
        allocations &+= 1
        var block = free[c]
        if block != 0 {
          free[c] = unsafe UnsafePointer<UInt>(bitPattern: block)!.pointee
        } else {
          let blockSize = smallest << c
          if chunkLeft < blockSize {
            chunk = map(chunkSize)
            guard chunk != 0 else { return 0 }
            chunkLeft = chunkSize
          }
          block = chunk
          chunk += UInt(blockSize)
          chunkLeft -= blockSize
        }
        unsafe UnsafeMutablePointer<UInt64>(bitPattern: block)!.pointee = UInt64(c)
        return block + 16
      }
    }
    let align = max(alignment, 16)
    let length = (size + align + 16 + pageSize - 1) & ~(pageSize - 1)
    let base = map(length)
    guard base != 0 else { return 0 }
    lock.locked { allocations &+= 1 }
    td_heap_noted()
    let user = (base + 16 + UInt(align) - 1) & ~(UInt(align) - 1)
    unsafe UnsafeMutablePointer<UInt64>(bitPattern: user - 16)!.pointee = largeBit | UInt64(length)
    unsafe UnsafeMutablePointer<UInt64>(bitPattern: user - 8)!.pointee = UInt64(base)
    return user
  }

  /// The bytes a block from `allocate` may hold.
  static func usable(_ user: UInt) -> Int {
    let tag = unsafe UnsafePointer<UInt64>(bitPattern: user - 16)!.pointee
    if tag & largeBit != 0 {
      let base = unsafe UnsafePointer<UInt64>(bitPattern: user - 8)!.pointee
      return Int(tag & ~largeBit) - Int(user - UInt(base))
    }
    return (smallest << Int(tag)) - 16
  }

  static func release(_ user: UInt) {
    let tag = unsafe UnsafePointer<UInt64>(bitPattern: user - 16)!.pointee
    if tag & largeBit != 0 {
      let base = unsafe UnsafePointer<UInt64>(bitPattern: user - 8)!.pointee
      unmap(UInt(base), Int(tag & ~largeBit))
      return
    }
    let c = Int(tag)
    precondition(c < classes, "free: not a heap block")
    let block = user - 16
    lock.locked {
      unsafe UnsafeMutablePointer<UInt>(bitPattern: block)!.pointee = free[c]
      free[c] = block
    }
  }
}

@c public func posix_memalign(
  _ out: UnsafeMutablePointer<UnsafeMutableRawPointer?>, _ alignment: Int, _ size: Int
) -> Int32 {
  let p = Heap.allocate(size, alignment)
  guard p != 0 else { return 12 }  // ENOMEM
  unsafe out.pointee = UnsafeMutableRawPointer(bitPattern: p)
  return 0
}

/// C23's aligned_alloc: any power-of-two alignment (C leaves others to the
/// implementation: here they fail).
@c public func aligned_alloc(_ alignment: Int, _ size: Int) -> UnsafeMutableRawPointer? {
  guard alignment > 0, alignment & (alignment - 1) == 0 else { return nil }
  return unsafe UnsafeMutableRawPointer(bitPattern: Heap.allocate(size, alignment))
}

/// glibc's malloc_usable_size: the bytes a block can hold, which Swift's
/// collections grow into (0 for a null pointer).
@c public func malloc_usable_size(_ p: UnsafeMutableRawPointer?) -> Int {
  guard let p = unsafe p else { return 0 }
  return Heap.usable(UInt(bitPattern: p))
}

/// The heap's allocations since start (M6m): a frame's layout and paint
/// are measured by it.
@c public func td_heap_allocations() -> UInt64 { Heap.lock.locked { Heap.allocations } }

@c public func malloc(_ size: Int) -> UnsafeMutableRawPointer? {
  unsafe UnsafeMutableRawPointer(bitPattern: Heap.allocate(size, 16))
}

@c public func free(_ p: UnsafeMutableRawPointer?) {
  guard let p = unsafe p else { return }
  Heap.release(UInt(bitPattern: p))
}

/// calloc (C23 §7.24.3.2): `count` objects of `size` bytes, zeroed; null if
/// the product overflows.
@c public func calloc(_ count: Int, _ size: Int) -> UnsafeMutableRawPointer? {
  let (bytes, overflow) = count.multipliedReportingOverflow(by: size)
  guard !overflow, bytes >= 0, let p = unsafe malloc(bytes) else { return nil }
  unsafe p.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
  return unsafe p
}

/// realloc (C23 §7.24.3.7): the block grown or shrunk, its contents kept up
/// to the smaller size. In place when it already fits; a size of zero
/// frees it and gives null, as glibc does.
@c public func realloc(_ p: UnsafeMutableRawPointer?, _ size: Int) -> UnsafeMutableRawPointer? {
  guard let p = unsafe p else { return unsafe malloc(size) }
  if size == 0 {
    unsafe free(p)
    return nil
  }
  let have = Heap.usable(UInt(bitPattern: p))
  if size <= have { return unsafe p }
  guard let q = unsafe malloc(size) else { return nil }
  unsafe q.copyMemory(from: p, byteCount: have)
  unsafe free(p)
  return unsafe q
}
