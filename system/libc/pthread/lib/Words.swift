// SPDX-License-Identifier: BSD-3-Clause

// What the pthread objects are built from (M5k): 32-bit words in memory
// the caller owns (a C struct, system/libc/include/pthread.h), changed
// atomically (td_atomic.h) and waited on with croi's futexes; error
// numbers; deadlines from a timespec.

import TDAtomic

/// A word at `offset` in a pthread object.
@safe struct Word {
  let p: UnsafeMutableRawPointer

  init(_ object: UnsafeMutableRawPointer, _ offset: Int) { unsafe p = unsafe object + offset }

  var value: UInt32 {
    get { unsafe td_atomic_load(p) }
    nonmutating set { unsafe td_atomic_store(p, newValue) }
  }

  func exchange(_ v: UInt32) -> UInt32 { unsafe td_atomic_exchange(p, v) }
  func cas(_ expected: UInt32, _ desired: UInt32) -> Bool { unsafe td_atomic_cas(p, expected, desired) != 0 }
  /// The value before adding.
  @discardableResult func add(_ v: UInt32) -> UInt32 { unsafe td_atomic_add(p, v) }

  /// Sleeps while the word holds `current`, until a wake or `deadline`;
  /// false if the deadline passed.
  func wait(_ current: UInt32, until deadline: Int64) -> Bool {
    unsafe Platform.futexWait(p.assumingMemoryBound(to: UInt32.self), current, deadline)
  }

  func wake(_ count: Int) { unsafe Platform.futexWake(p.assumingMemoryBound(to: UInt32.self), count) }
  func wakeAll() { wake(Int(Int32.max)) }
}

/// The error numbers pthreads return (errno.h's, Linux's values).
enum Errno {
  static let EPERM: Int32 = 1, ESRCH: Int32 = 3, EAGAIN: Int32 = 11, ENOMEM: Int32 = 12, EBUSY: Int32 = 16
  static let EINVAL: Int32 = 22, EDEADLK: Int32 = 35, ETIMEDOUT: Int32 = 110
}

/// time.h's clocks.
enum Clocks {
  static let realtime: UInt32 = 0, monotonic: UInt32 = 1
}

/// A deadline on the monotonic clock from an absolute timespec on `clock`
/// (POSIX's abstime), or nil if it isn't one (a nanosecond field out of
/// range).
func deadline(_ abstime: UnsafeRawPointer, clock: UInt32) -> Int64? {
  let seconds = unsafe abstime.load(as: Int64.self)
  let nanoseconds = unsafe abstime.load(fromByteOffset: 8, as: Int64.self)
  guard nanoseconds >= 0 && nanoseconds < 1_000_000_000 else { return nil }
  let (scaled, over) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
  if over || seconds < 0 { return seconds < 0 ? 0 : Platform.forever }
  let (at, over2) = scaled.addingReportingOverflow(nanoseconds)
  if over2 { return Platform.forever }
  if clock == Clocks.monotonic { return at }
  // The realtime clock: how far away it is, from now on the monotonic one.
  let (left, over3) = at.subtractingReportingOverflow(Platform.realtime())
  if over3 { return Platform.forever }
  let (d, over4) = Platform.monotonic().addingReportingOverflow(left)
  return over4 ? Platform.forever : max(d, 0)
}
