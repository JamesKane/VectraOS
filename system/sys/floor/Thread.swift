// SPDX-License-Identifier: BSD-3-Clause

// Each thread's block and its ELF TLS, found through the thread pointer
// (croi 869cb83's user TLS: FS's base on amd64, set through
// object_set_property; TPIDR_EL0 on arm64 and tp on rv64, set directly).
// Tier 0 has no thread-local variables, only the block's slots; C, Zig
// and Odin code has `_Thread_local` (M5k), whose initial image is the
// program's PT_TLS segment, copied into each thread's area here.
//
// Where they sit is the psABIs' (and so what ld.lld's local-exec offsets
// assume):
//   amd64 (variant II): the thread pointer is the block, whose first word
//     points to itself (%fs:0); the TLS ends just below it, at
//     TP - roundup(p_memsz, p_align).
//   arm64, rv64 (variant I): the TLS starts above the thread pointer, after
//     a gap (16 bytes on arm64, none on rv64) and the padding that makes it
//     congruent to p_vaddr modulo p_align; the block sits just below it.
//
// The block:
//   0   self (amd64 reads %fs:0)
//   8   the thread's trace ring (system/trace), 0 until it claims one
//   16  Sys.ThreadSlot's word (libc's pthread record)
//   24  a floor thread's own handle (FloorThreads, for its exit)
//   32  the thread's port (Waits.swift), 0 until its first wait
//   40  reserved, to 64
//
// The main thread's block is static until the heap is up, then moves to
// an area with its TLS (if the program has any); another thread's area
// sits at the top of its stack (system/sys/backend/native), prepared by
// its creator and installed first thing as it starts.

import CroiSyscall
import TDNative

public enum ThreadBlock {
  public static let size = 64
  static let traceRing = 8
  static let portSlot = 32

  nonisolated(unsafe) static var main = InlineArray<8, UInt64>(repeating: 0)

  /// The program's TLS segment (PT_TLS): where its initial image is, how
  /// much of it is in the file, its size and alignment; size 0 if none.
  nonisolated(unsafe) static var tls = (image: UInt(0), fileSize: 0, size: 0, align: 1)

  #if arch(x86_64)
    static let gap = 0
  #elseif arch(arm64)
    static let gap = 16
  #else
    static let gap = 0
  #endif

  /// The program's TLS segment, from its own program headers (mapped in its
  /// first segment: `__ehdr_start`).
  static func findTLS() {
    guard let header = unsafe td_image_header() else { return }
    let phoff = unsafe Int(header.load(fromByteOffset: 32, as: UInt64.self))
    let entry = unsafe Int(header.load(fromByteOffset: 54, as: UInt16.self))
    let count = unsafe Int(header.load(fromByteOffset: 56, as: UInt16.self))
    for i in 0..<count {
      let ph = unsafe header + phoff + i * entry
      guard unsafe ph.load(as: UInt32.self) == 7 else { continue }  // PT_TLS
      tls = unsafe (UInt(ph.load(fromByteOffset: 16, as: UInt64.self)),
                           Int(ph.load(fromByteOffset: 32, as: UInt64.self)),
                           Int(ph.load(fromByteOffset: 40, as: UInt64.self)),
                           max(1, Int(ph.load(fromByteOffset: 48, as: UInt64.self))))
    }
  }

  /// The bytes an area for a thread's block and TLS takes, from any start.
  public static var areaSize: Int {
    let t = tls
    let a = max(t.align, 16)
    return size + gap + t.size + 2 * a
  }

  /// Lays out a thread's block and TLS in `area` (`areaSize` bytes, any
  /// alignment): the TLS from the program's image, the block zero. Returns
  /// the block.
  public static func prepare(_ area: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
    let t = tls
    let start = UInt(bitPattern: area)
    let a = UInt(max(t.align, 16))
    func up(_ v: UInt, _ to: UInt) -> UInt { (v + to - 1) & ~(to - 1) }
    let tp: UInt
    let image: UInt
    #if arch(x86_64)
      let below = up(UInt(t.size), UInt(t.align))
      tp = up(start + below, a)
      image = tp - below
    #else
      tp = up(start + UInt(size), a)
      image = tp + UInt(gap) + ((t.image &- UInt(gap)) & (UInt(t.align) - 1))
    #endif
    let block = unsafe UnsafeMutableRawPointer(bitPattern: blockAddress(tp))!
    unsafe block.initializeMemory(as: UInt8.self, repeating: 0, count: size)
    if t.size > 0 {
      let to = unsafe UnsafeMutableRawPointer(bitPattern: image)!
      unsafe to.copyMemory(from: UnsafeRawPointer(bitPattern: t.image)!, byteCount: t.fileSize)
      unsafe (to + t.fileSize).initializeMemory(as: UInt8.self, repeating: 0, count: t.size - t.fileSize)
    }
    return unsafe block
  }

  /// The block of the thread whose thread pointer is `tp`, and back.
  @inline(__always) static func blockAddress(_ tp: UInt) -> UInt {
    #if arch(x86_64)
      tp
    #else
      tp - UInt(size)
    #endif
  }

  /// Makes `block` (`size` bytes, zeroed or prepared, living as long as the
  /// thread) the calling thread's; `thread` is its own handle (amd64 needs
  /// it).
  public static func install(_ block: UnsafeMutableRawPointer, thread: UInt32) {
    unsafe block.storeBytes(of: UInt64(UInt(bitPattern: block)), as: UInt64.self)
    #if arch(x86_64)
      var value = UInt64(UInt(bitPattern: block))
      _ = withUnsafeMutablePointer(to: &value) { p in
        croi_syscall(CROI_SYS_OBJECT_SET_PROPERTY, UInt64(thread), UInt64(CROI_PROP_REGISTER_FS),
                     UInt64(UInt(bitPattern: p)), 8, 0)
      }
    #else
      unsafe td_set_thread_pointer(block + size)
    #endif
  }

  /// The main thread's, from td_start: the static block, with no TLS yet.
  static func installMain(thread: UInt32) {
    withUnsafeMutablePointer(to: &main) { p in unsafe install(UnsafeMutableRawPointer(p), thread: thread) }
  }

  /// Once the heap is up: the main thread's TLS, if the program has any,
  /// in an area of its own, keeping what its static block held.
  static func installMainTLS(thread: UInt32) {
    findTLS()
    guard tls.size > 0, let area = unsafe malloc(areaSize) else { return }
    let block = unsafe prepare(area)
    unsafe block.copyMemory(from: current, byteCount: size)
    unsafe install(block, thread: thread)
  }

  /// The calling thread's block.
  @inline(__always)
  public static var current: UnsafeMutableRawPointer { unsafe td_thread_block()! }

  /// The calling thread's port (td_thread_port), 0 until made.
  static var port: UInt32 {
    get { unsafe UInt32(truncatingIfNeeded: current.load(fromByteOffset: portSlot, as: UInt64.self)) }
    set { unsafe current.storeBytes(of: UInt64(newValue), toByteOffset: portSlot, as: UInt64.self) }
  }
}

// td_floor.h: the block for what can't import this module (tier 1's Sys).
@c public func td_thread_area_size() -> Int { ThreadBlock.areaSize }
@c public func td_thread_prepare(_ area: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
  unsafe ThreadBlock.prepare(area)
}
@c public func td_thread_install(_ block: UnsafeMutableRawPointer, _ thread: UInt32) {
  unsafe ThreadBlock.install(block, thread: thread)
}

/// The trace writer's per-thread ring (system/trace's td_trace_cpu.h).
@c public func td_trace_thread_ring() -> UnsafeMutableRawPointer? {
  unsafe UnsafeMutableRawPointer(bitPattern: UInt(ThreadBlock.current.load(fromByteOffset: ThreadBlock.traceRing,
                                                                             as: UInt64.self)))
}

@c public func td_trace_set_thread_ring(_ ring: UnsafeMutableRawPointer?) {
  unsafe ThreadBlock.current.storeBytes(of: UInt64(UInt(bitPattern: ring)), toByteOffset: ThreadBlock.traceRing,
                                        as: UInt64.self)
}
