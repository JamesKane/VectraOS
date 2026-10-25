// SPDX-License-Identifier: BSD-3-Clause

// pthreads' platform hosted (M6c): Sys's, over the hosted kernel, for the
// tests that compare them with glibc (natively it is the floor's,
// platform/floor).

import Glibc
import Sys

enum Platform {
  static let forever = infiniteDeadline
  static func monotonic() -> Int64 { Clock.monotonic() }
  static func realtime() -> Int64 { Clock.realtime() }

  static func futexWait(_ p: UnsafeMutablePointer<UInt32>, _ current: UInt32, _ deadline: Int64) -> Bool {
    do throws(Status) {
      try unsafe Futex.wait(p, current: current, deadline: deadline)
    } catch {
      if error == .timedOut { return false }
    }
    return true
  }
  static func futexWake(_ p: UnsafeMutablePointer<UInt32>, _ count: Int) { unsafe Futex.wake(p, count: count) }

  static var slot: UInt {
    get { ThreadSlot.value }
    set { ThreadSlot.value = newValue }
  }

  static func allocate(_ n: Int) -> UnsafeMutableRawPointer? { unsafe Glibc.malloc(n) }
  static func release(_ p: UnsafeMutableRawPointer) { unsafe Glibc.free(p) }

  struct Entry: @unchecked Sendable {
    let f: @convention(c) (UInt) -> Void
  }

  static func start(_ entry: @convention(c) (UInt) -> Void, _ arg: UInt) -> (handle: UInt32, stack: UInt)? {
    let e = Entry(f: entry)
    guard let t = try? Thread.spawn({ e.f(arg) }) else { return nil }
    return (t.release(), 0)
  }
  static func join(_ handle: UInt32, _ stack: UInt) {
    let h = Handle(raw: handle)
    try? Thread.join(h)
  }
  static func detach(_ handle: UInt32) { _ = Handle(raw: handle) }
  /// Hosted threads aren't pinned: ENOSYS.
  static func setCPUs(_ handle: UInt32?, _ mask: UInt64) -> Int32 { 38 }
  static func exit(unmapping stack: UInt) -> Never { Thread.exit() }
  static func finished(unmapping stack: UInt) {}
}
