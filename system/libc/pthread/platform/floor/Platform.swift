// SPDX-License-Identifier: BSD-3-Clause

// pthreads' platform natively (M6c): the floor's, runtime-free, so that
// pthreads serve tier 1's full Swift as well as tier 0 (the hosted build's
// is Sys's, platform/hosted).

import CroiSyscall
import Floor
import TDNative

enum Platform {
  static let forever = Int64.max  // croi's ZX_TIME_INFINITE: no timer at all
  static func monotonic() -> Int64 { Runtime.monotonic() }
  static func realtime() -> Int64 { td_utc_now() }

  /// Sleeps while *p == current, until a wake or `deadline`; false if the
  /// deadline passed.
  static func futexWait(_ p: UnsafeMutablePointer<UInt32>, _ current: UInt32, _ deadline: Int64) -> Bool {
    unsafe td_futex_wait(p, current, deadline) != CROI_ERR_TIMED_OUT
  }
  static func futexWake(_ p: UnsafeMutablePointer<UInt32>, _ count: Int) {
    _ = unsafe td_futex_wake(p, UInt32(truncatingIfNeeded: count))
  }

  /// The calling thread's word (the thread block's slot at 16).
  static var slot: UInt {
    get { unsafe UInt(ThreadBlock.current.load(fromByteOffset: 16, as: UInt64.self)) }
    set { unsafe ThreadBlock.current.storeBytes(of: UInt64(newValue), toByteOffset: 16, as: UInt64.self) }
  }

  static func allocate(_ n: Int) -> UnsafeMutableRawPointer? { unsafe malloc(n) }
  static func release(_ p: UnsafeMutableRawPointer) { unsafe free(p) }

  /// entry(arg) on a new thread: its handle and stack, or nil.
  static func start(_ entry: @convention(c) (UInt) -> Void, _ arg: UInt) -> (handle: UInt32, stack: UInt)? {
    FloorThreads.start(entry, arg).map { ($0.thread, $0.stack) }
  }
  /// Waits for the thread to end, then frees its stack and handle.
  static func join(_ handle: UInt32, _ stack: UInt) {
    FloorThreads.waitEnded(handle)
    FloorThreads.unmapStack(stack)
    FloorThreads.close(handle)
  }
  /// Keeps a thread (nil: the calling one) to the CPUs of `mask`: 0 or
  /// the errno (the floor's sched_setaffinity's).
  static func setCPUs(_ handle: UInt32?, _ mask: UInt64) -> Int32 {
    td_thread_set_cpus(handle ?? td_runtime_thread_self, mask)
  }
  /// Gives up the handle of a thread that will free its own stack.
  static func detach(_ handle: UInt32) { FloorThreads.close(handle) }
  /// Ends the calling thread, freeing `stack` (0: someone else will) as it goes.
  static func exit(unmapping stack: UInt) -> Never { FloorThreads.exit(unmapping: stack) }
  /// A started thread's entry returned: a detached one frees its stack.
  static func finished(unmapping stack: UInt) { if stack != 0 { FloorThreads.exit(unmapping: stack) } }
}
