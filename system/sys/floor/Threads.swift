// SPDX-License-Identifier: BSD-3-Clause

// Threads the floor starts (M6c): for pthreads beneath tier 1's full Swift
// as well as tier 0, so runtime-free, and for Sys's own threads, which
// take Swift closures and start through td_thread_start. Each gets a stack
// of its own mapped from a VMO, its block and TLS at the stack's top
// (ThreadBlock.prepare), and runs a C function with an argument from
// td_floor_thread_entry. Whoever waits for its end unmaps the stack
// (pthreads); a thread nobody will wait for unmaps its own as it exits
// (croi's vmar_unmap_handle_close_thread_exit), as Sys's threads always
// do. A thread's port (its waits', Waits.swift) is closed as it ends.

import CroiSyscall
import TDNative

public enum FloorThreads {
  public static let stackSize = 256 * 1024

  public typealias Entry = @convention(c) (UInt) -> Void

  /// entry(arg) on a new thread of this process: its handle (the caller's)
  /// and its stack's address, which the caller unmaps once it has ended;
  /// or nil.
  public static func start(_ entry: Entry, _ arg: UInt) -> (thread: UInt32, stack: UInt)? {
    var thread: UInt32 = 0
    let name: StaticString = "pthread"
    let made = withUnsafeMutablePointer(to: &thread) { p in
      unsafe croi_syscall(CROI_SYS_THREAD_CREATE, UInt64(Runtime.processSelf), UInt64(UInt(bitPattern: name.utf8Start)),
                         UInt64(name.utf8CodeUnitCount), 0, UInt64(UInt(bitPattern: p)))
    }
    guard made == 0 else { return nil }
    let (stack, status) = launch(thread, entry, arg, ownsStack: false)
    guard status == 0 else {
      close(thread)
      return nil
    }
    return (thread, stack)
  }

  /// Starts `thread` (made, not started; the caller's handle, kept)
  /// running entry(arg) on a new stack: the stack's address and 0, or 0 and
  /// why not. With `ownsStack`, the thread unmaps it as it exits.
  static func launch(_ thread: UInt32, _ entry: Entry, _ arg: UInt, ownsStack: Bool) -> (stack: UInt, status: Int64) {
    let stack = Heap.map(stackSize)
    // The thread's own handle, for its FS base on amd64, and for its exit.
    var own: UInt32 = 0
    let dup = unsafe croi_handle_duplicate(thread, CROI_RIGHT_SAME_RIGHTS, &own, 0)
    guard stack != 0, dup == 0, let record = unsafe malloc(40) else {
      if stack != 0 { Heap.unmap(stack, stackSize) }
      if dup == 0 { close(own) }
      return (0, dup != 0 ? dup : CROI_ERR_NO_MEMORY)
    }
    // Its block and TLS at the stack's top, and the stack below them (amd64
    // code expects to have been called: 8 off 16 at entry).
    let area = stack + UInt(stackSize - ThreadBlock.areaSize)
    let block = unsafe UInt(bitPattern: ThreadBlock.prepare(UnsafeMutableRawPointer(bitPattern: area)!))
    #if arch(x86_64)
      let top = UInt64(area & ~15) - 8
    #else
      let top = UInt64(area & ~15)
    #endif
    unsafe record.storeBytes(of: unsafe unsafeBitCast(entry, to: UInt.self), toByteOffset: 0, as: UInt.self)
    unsafe record.storeBytes(of: arg, toByteOffset: 8, as: UInt.self)
    unsafe record.storeBytes(of: UInt(own), toByteOffset: 16, as: UInt.self)
    unsafe record.storeBytes(of: block, toByteOffset: 24, as: UInt.self)
    unsafe record.storeBytes(of: ownsStack ? stack : 0, toByteOffset: 32, as: UInt.self)
    let pc: @convention(c) (UInt64, UInt64) -> Void = td_floor_thread_entry
    let entryAddress = unsafe UInt64(UInt(bitPattern: unsafeBitCast(pc, to: UnsafeRawPointer.self)))
    let r = unsafe croi_syscall(CROI_SYS_THREAD_START, UInt64(thread), entryAddress, top,
                                UInt64(UInt(bitPattern: record)), 0)
    guard r == 0 else {
      unsafe free(record)
      Heap.unmap(stack, stackSize)
      close(own)
      return (0, r)
    }
    return (stack, 0)
  }

  /// Waits until `thread` has ended.
  public static func waitEnded(_ thread: UInt32) {
    _ = unsafe td_wait_one(thread, CROI_SIGNAL_TASK_TERMINATED, Int64.max, nil)
  }

  public static func close(_ handle: UInt32) { _ = croi_handle_close(handle) }

  /// A stack whose thread has ended, unmapped.
  public static func unmapStack(_ stack: UInt) { Heap.unmap(stack, stackSize) }

  /// The calling floor thread's own handle, kept in its block's slot at 24
  /// (0 for a thread the floor didn't start).
  static var ownHandle: UInt32 {
    get { unsafe UInt32(truncatingIfNeeded: ThreadBlock.current.load(fromByteOffset: 24, as: UInt64.self)) }
    set { unsafe ThreadBlock.current.storeBytes(of: UInt64(newValue), toByteOffset: 24, as: UInt64.self) }
  }

  /// The stack the calling floor thread unmaps as it exits, in its block's
  /// slot at 40 (0: its joiner does, or the floor didn't start it).
  static var ownStack: UInt {
    get { unsafe UInt(ThreadBlock.current.load(fromByteOffset: 40, as: UInt64.self)) }
    set { unsafe ThreadBlock.current.storeBytes(of: UInt64(newValue), toByteOffset: 40, as: UInt64.self) }
  }

  /// Ends the calling thread, unmapping `stack` as it goes (by default the
  /// one it owns, if any): the thread runs on it, so croi does both at
  /// once, closing the thread's own handle with them (as Zircon, croi traps
  /// if there's no handle to close).
  public static func exit(unmapping given: UInt? = nil) -> Never {
    let stack = given ?? ownStack
    let own = ownHandle
    if ThreadBlock.port != 0 { close(ThreadBlock.port) }
    if stack != 0 && own != 0 {
      _ = croi_syscall(CROI_SYS_VMAR_UNMAP_HANDLE_CLOSE_THREAD_EXIT, UInt64(Runtime.vmarRoot), UInt64(stack),
                       UInt64(stackSize), UInt64(own), 0)
    }
    if own != 0 { close(own) }
    _ = croi_syscall(CROI_SYS_THREAD_EXIT, 0, 0, 0, 0, 0)
    while true {}
  }
}

/// Where a floor thread begins: on its own stack, with its start record.
@c func td_floor_thread_entry(_ arg: UInt64, _ unused: UInt64) {
  let record = unsafe UnsafeMutableRawPointer(bitPattern: UInt(arg))!
  let entry = unsafe unsafeBitCast(record.load(fromByteOffset: 0, as: UInt.self), to: FloorThreads.Entry.self)
  let value = unsafe record.load(fromByteOffset: 8, as: UInt.self)
  let own = unsafe UInt32(record.load(fromByteOffset: 16, as: UInt.self))
  let block = unsafe record.load(fromByteOffset: 24, as: UInt.self)
  let stack = unsafe record.load(fromByteOffset: 32, as: UInt.self)
  unsafe free(record)
  unsafe ThreadBlock.install(UnsafeMutableRawPointer(bitPattern: block)!, thread: own)
  // Kept: an exit that unmaps the stack closes it (FloorThreads.exit).
  FloorThreads.ownHandle = own
  FloorThreads.ownStack = stack
  entry(value)
  FloorThreads.exit()
}

/// Starts `thread` (thread_create's, the caller's handle, kept) running
/// entry(arg) on a stack of its own, which it unmaps as it exits: 0, or the
/// status (NO_MEMORY, or thread_start's).
@c public func td_thread_start(_ thread: UInt32, _ entry: FloorThreads.Entry, _ arg: UInt) -> Int32 {
  Int32(truncatingIfNeeded: FloorThreads.launch(thread, entry, arg, ownsStack: true).status)
}

/// Ends the calling thread: a floor thread's port closed and the stack it
/// owns unmapped (FloorThreads.exit).
@c public func td_thread_exit() -> Never { FloorThreads.exit() }
