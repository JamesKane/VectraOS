// SPDX-License-Identifier: BSD-3-Clause

// A lock over futexes, the kernel's waiting on a word in memory: free and
// uncontended locks cost an atomic each way and no kernel call. The word
// is 0 (free), 1 (held) or 2 (held, and someone may be waiting), the
// classic three-state design (Drepper, "Futexes Are Tricky", mutex 3):
// an unlock that finds 2 wakes one waiter, and a waiter marks the word 2
// before it sleeps, so no wakeup is lost.
//
// Not yet priority-inheriting: croi's futexes take an owner (K7c), but a
// thread can only name itself with a thread pointer, which croi's user
// threads don't have yet. Until then the owner is left unset.

import Synchronization

public final class Lock: @unchecked Sendable {
  let word = Atomic<UInt32>(0)

  public init() {}

  public func lock() {
    if word.compareExchange(expected: 0, desired: 1, ordering: .acquiring).exchanged { return }
    // Contended: say so, then sleep while it stays held.
    while word.exchange(2, ordering: .acquiring) != 0 {
      try? unsafe Futex.wait(address, current: 2)
    }
  }

  public func unlock() {
    if word.exchange(0, ordering: .releasing) == 2 {
      unsafe Futex.wake(address, count: 1)
    }
  }

  public func withLock<R, E: Error>(_ body: () throws(E) -> R) throws(E) -> R {
    lock()
    defer { unlock() }
    return try body()
  }

  /// The word's address, for the kernel: `word` is stored in this object,
  /// so it doesn't move.
  var address: UnsafeMutablePointer<UInt32> {
    unsafe withUnsafePointer(to: word) { unsafe UnsafeMutablePointer(mutating: UnsafeRawPointer($0).assumingMemoryBound(to: UInt32.self)) }
  }
}

/// futex_wait and futex_wake: waiting on a 32-bit word in memory, for
/// locks and the like built in user space.
public enum Futex {
  /// The futex_wait and futex_wake calls this process has made: the
  /// futex budgets count them (an uncontended lock makes none).
  public static let waits = Atomic<Int>(0)
  public static let wakes = Atomic<Int>(0)

  /// Sleeps while the word at `address` holds `current`, until a wake or
  /// `deadline`. `badState` if it already holds something else.
  public static func wait(_ address: UnsafeMutablePointer<UInt32>, current: UInt32, deadline: Int64 = infiniteDeadline)
    throws(Status)
  {
    waits.add(1, ordering: .relaxed)
    try unsafe Kernel.futexWait(address, current: current, deadline: deadline)
  }

  /// Wakes up to `count` threads waiting on `address`.
  public static func wake(_ address: UnsafeMutablePointer<UInt32>, count: Int) {
    wakes.add(1, ordering: .relaxed)
    unsafe Kernel.futexWake(address, count: count)
  }
}

/// A value only one thread at a time may touch: Synchronization's Mutex,
/// over `Lock`, which works wherever Sys does (Embedded Swift on croi has
/// no Mutex).
public final class Locked<Value>: @unchecked Sendable {
  let lock = Lock()
  var value: Value

  public init(_ value: Value) { self.value = value }

  public func withLock<R, E: Error>(_ body: (inout Value) throws(E) -> R) throws(E) -> R {
    lock.lock()
    defer { lock.unlock() }
    return try body(&value)
  }
}
