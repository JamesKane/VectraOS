// SPDX-License-Identifier: BSD-3-Clause

// Threads (POSIX XSH pthread_create, _join, _detach, _exit, _self, M5k;
// runtime-free since M6c) over the platform's (platform/: the floor's
// natively, Sys's hosted). A pthread_t is the address of the thread's
// record, which the thread's slot names for the thread itself; a thread
// pthreads didn't start (the main thread, a Sys thread) gets one the first
// time it asks. The record holds the thread's handle and stack, so a join
// waits for the kernel to say the thread has ended (then nothing of it
// touches the record or the stack), and a state word settles who frees
// them when the thread is detached: a detached thread frees its own,
// natively unmapping its stack as it exits.
//
//   0   state: 0 running, 1 finished (a joiner frees), 2 detached (it frees)
//   4   id, for mutexes' owners (never 0)
//   8   result
//   16  start routine; 24 its argument
//   32  the thread's handle (0: one pthreads didn't start)
//   40  its stack (0: the platform's to free, or none)
//   48  1 once the stack is set (the thread starts before its creator knows it)
//   56  thread-specific values: a key's (generation, value), 16 bytes each

import TDAtomic

/// A start routine and its argument (void *(*)(void *)).
public typealias StartRoutine = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?

enum Record {
  static let state = 0, id = 4, result = 8, start = 16, arg = 24, handle = 32, stack = 40, stackSet = 48
  static let values = 56
  static let size = values + Keys.max * 16
  static let running: UInt32 = 0, finished: UInt32 = 1, detached: UInt32 = 2

  /// The next thread id (atomic: td_atomic_add).
  nonisolated(unsafe) static var nextID: UInt32 = 1

  static func make() -> UnsafeMutableRawPointer? {
    guard let r = unsafe Platform.allocate(size) else { return nil }
    unsafe r.initializeMemory(as: UInt8.self, repeating: 0, count: size)
    let id = unsafe withUnsafeMutablePointer(to: &nextID) { p in unsafe td_atomic_add(p, 1) }
    unsafe r.storeBytes(of: id, toByteOffset: Record.id, as: UInt32.self)
    return unsafe r
  }

  static func free(_ r: UnsafeMutableRawPointer) { unsafe Platform.release(r) }

  /// The calling thread's record.
  static var current: UnsafeMutableRawPointer {
    if let r = unsafe UnsafeMutableRawPointer(bitPattern: Platform.slot) { return unsafe r }
    // (A thread pthreads didn't start; if the heap is out, there's no record to give.)
    let r = unsafe make()!
    Platform.slot = UInt(bitPattern: r)
    return unsafe r
  }

  /// The calling thread's id, for a mutex's owner.
  static var currentID: UInt32 { unsafe current.load(fromByteOffset: id, as: UInt32.self) }

  /// The thread is done with `result`: its keys' destructors run, then
  /// whoever joins it (or it, if detached) frees its record. The stack to
  /// free as the thread exits if it is detached (it freed its own record),
  /// else 0.
  static func finish(_ r: UnsafeMutableRawPointer, result: UnsafeMutableRawPointer?) -> UInt {
    unsafe Keys.runDestructors(r)
    unsafe r.storeBytes(of: result, toByteOffset: Record.result, as: UnsafeMutableRawPointer?.self)
    let stack = unsafe r.load(fromByteOffset: Record.stack, as: UInt.self)
    if unsafe !Word(r, state).cas(running, finished) {
      // Detached: nobody else will.
      unsafe free(r)
      return stack
    }
    return 0
  }
}

/// Starts a thread running `start(arg)`; its pthread_t in `thread`.
public func pthread_create(_ thread: UnsafeMutablePointer<UInt>, _ attr: UnsafeRawPointer?,
                           _ start: StartRoutine, _ arg: UnsafeMutableRawPointer?) -> Int32
{
  guard let r = unsafe Record.make() else { return Errno.EAGAIN }
  let detached = unsafe attr.map { unsafe $0.load(as: UInt32.self) != 0 } ?? false
  if detached { unsafe r.storeBytes(of: Record.detached, toByteOffset: Record.state, as: UInt32.self) }
  unsafe r.storeBytes(of: unsafe unsafeBitCast(start, to: UInt.self), toByteOffset: Record.start, as: UInt.self)
  unsafe r.storeBytes(of: arg, toByteOffset: Record.arg, as: UnsafeMutableRawPointer?.self)
  let address = UInt(bitPattern: r)
  unsafe thread.pointee = address
  guard let (handle, stack) = Platform.start(threadEntry, address) else {
    unsafe Record.free(r)
    return Errno.EAGAIN
  }
  if !detached { unsafe r.storeBytes(of: handle, toByteOffset: Record.handle, as: UInt32.self) }
  // The stack, then the word that says it's there (an atomic store after it).
  unsafe r.storeBytes(of: stack, toByteOffset: Record.stack, as: UInt.self)
  unsafe Word(r, Record.stackSet).value = 1
  if detached { Platform.detach(handle) }
  return 0
}

/// The record's stack, once its creator has set it (a thread pthreads
/// didn't start, which has no start routine, has none: 0).
func stackOf(_ r: UnsafeMutableRawPointer) -> UInt {
  guard unsafe r.load(fromByteOffset: Record.start, as: UInt.self) != 0 else { return 0 }
  while unsafe Word(r, Record.stackSet).value == 0 {}
  return unsafe r.load(fromByteOffset: Record.stack, as: UInt.self)
}

/// Where a thread pthreads started begins: its record's address the argument.
let threadEntry: @convention(c) (UInt) -> Void = { address in
  let r = unsafe UnsafeMutableRawPointer(bitPattern: address)!
  Platform.slot = address
  let start = unsafe unsafeBitCast(r.load(fromByteOffset: Record.start, as: UInt.self), to: StartRoutine.self)
  let result = unsafe start(r.load(fromByteOffset: Record.arg, as: UnsafeMutableRawPointer?.self))
  _ = unsafe stackOf(r)
  let stack = unsafe Record.finish(r, result: result)
  Platform.finished(unmapping: stack)
}

/// Waits for `thread` to end, and frees it; its result in `result`.
public func pthread_join(_ thread: UInt, _ result: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32 {
  guard let r = unsafe UnsafeMutableRawPointer(bitPattern: thread) else { return Errno.ESRCH }
  if thread == Platform.slot { return Errno.EDEADLK }
  let handle = unsafe r.load(fromByteOffset: Record.handle, as: UInt32.self)
  guard handle != 0, unsafe Word(r, Record.state).value != Record.detached else { return Errno.EINVAL }
  unsafe Platform.join(handle, stackOf(r))
  if let result = unsafe result { unsafe result.pointee = unsafe r.load(fromByteOffset: Record.result, as: UnsafeMutableRawPointer?.self) }
  unsafe Record.free(r)
  return 0
}

/// Lets `thread` free itself when it ends.
public func pthread_detach(_ thread: UInt) -> Int32 {
  guard let r = unsafe UnsafeMutableRawPointer(bitPattern: thread) else { return Errno.ESRCH }
  let handle = unsafe r.load(fromByteOffset: Record.handle, as: UInt32.self)
  guard handle != 0 else { return Errno.EINVAL }
  let word = unsafe Word(r, Record.state)
  if word.value == Record.detached { return Errno.EINVAL }
  unsafe r.storeBytes(of: UInt32(0), toByteOffset: Record.handle, as: UInt32.self)
  if word.cas(Record.running, Record.detached) {
    // Running: it frees its record and stack as it ends.
    Platform.detach(handle)
  } else {
    // Finished: wait for its last instructions, then free what it left.
    unsafe Platform.join(handle, stackOf(r))
    unsafe Record.free(r)
  }
  return 0
}

public func pthread_self() -> UInt { unsafe UInt(bitPattern: Record.current) }

/// Keeps `thread` to the CPUs of `set`, a cpu_set_t of `size` bytes (its
/// first 64 bits): 0, or the error.
public func pthread_setaffinity_np(_ thread: UInt, _ size: Int, _ set: UnsafeRawPointer?) -> Int32 {
  guard size >= 8, let set = unsafe set else { return Errno.EINVAL }
  let mask = unsafe set.load(as: UInt64.self)
  if thread == pthread_self() { return Platform.setCPUs(nil, mask) }
  guard let r = unsafe UnsafeMutableRawPointer(bitPattern: thread) else { return Errno.ESRCH }
  let handle = unsafe r.load(fromByteOffset: Record.handle, as: UInt32.self)
  guard handle != 0 else { return Errno.ESRCH }
  return Platform.setCPUs(handle, mask)
}

public func pthread_equal(_ a: UInt, _ b: UInt) -> Int32 { a == b ? 1 : 0 }

/// Ends the calling thread with `result`.
public func pthread_exit(_ result: UnsafeMutableRawPointer?) -> Never {
  let r = unsafe Record.current
  _ = unsafe stackOf(r)
  let stack = unsafe Record.finish(r, result: result)
  Platform.exit(unmapping: stack)
}

// MARK: Attributes: { detached, stack size in KiB }

public func pthread_attr_init(_ attr: UnsafeMutableRawPointer) -> Int32 {
  unsafe attr.storeBytes(of: UInt64(0), as: UInt64.self)
  return 0
}

public func pthread_attr_destroy(_ attr: UnsafeMutableRawPointer) -> Int32 { 0 }

public func pthread_attr_setdetachstate(_ attr: UnsafeMutableRawPointer, _ state: Int32) -> Int32 {
  guard state == 0 || state == 1 else { return Errno.EINVAL }
  unsafe attr.storeBytes(of: UInt32(state), as: UInt32.self)
  return 0
}

public func pthread_attr_getdetachstate(_ attr: UnsafeRawPointer, _ state: UnsafeMutablePointer<Int32>) -> Int32 {
  unsafe state.pointee = Int32(unsafe attr.load(as: UInt32.self))
  return 0
}

/// The floor's threads have stacks of one size (256 KiB natively): a size
/// is kept for the asking, and must be at least PTHREAD_STACK_MIN's 16 KiB.
public func pthread_attr_setstacksize(_ attr: UnsafeMutableRawPointer, _ size: Int) -> Int32 {
  guard size >= 16384 else { return Errno.EINVAL }
  unsafe attr.storeBytes(of: UInt32(min(size / 1024, Int(UInt32.max))), toByteOffset: 4, as: UInt32.self)
  return 0
}

public func pthread_attr_getstacksize(_ attr: UnsafeRawPointer, _ size: UnsafeMutablePointer<Int>) -> Int32 {
  let k = unsafe attr.load(fromByteOffset: 4, as: UInt32.self)
  unsafe size.pointee = k == 0 ? 256 * 1024 : Int(k) * 1024
  return 0
}
