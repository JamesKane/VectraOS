// SPDX-License-Identifier: BSD-3-Clause

// Condition variables (POSIX XSH pthread_cond_*, M5k): a sequence word a
// waiter sleeps on, read before it lets go of the mutex, so a signal in
// between changes it and the wait returns at once; a count of waiters, so
// a signal nobody waits for makes no kernel call. Waking can be spurious,
// as POSIX allows. A waiter takes the mutex back marked contended, so
// those a broadcast woke hand it on.
//
//   0  sequence   4  clock (CLOCK_REALTIME or CLOCK_MONOTONIC)   8  waiters


enum Condition {
  static func wait(_ c: UnsafeMutableRawPointer, _ m: UnsafeMutableRawPointer, until deadline: Int64) -> Int32 {
    let seq = unsafe Word(c, 0), waiters = unsafe Word(c, 8)
    let type = unsafe Mutex.type(m)
    let owner = unsafe Word(m, 8), depth = unsafe Word(m, 12)
    var held: UInt32 = 0
    if type != Mutex.normal {
      guard owner.value == Record.currentID else { return Errno.EPERM }
      held = depth.value
      owner.value = 0
      depth.value = 0
    }
    let s = seq.value
    waiters.add(1)
    unsafe Mutex.release(m)
    let woke = seq.wait(s, until: deadline)
    waiters.add(UInt32.max)  // - 1
    _ = unsafe Mutex.acquire(m, until: Platform.forever, contended: true)
    if type != Mutex.normal {
      owner.value = Record.currentID
      depth.value = held
    }
    return woke ? 0 : Errno.ETIMEDOUT
  }
}

public func pthread_condattr_init(_ attr: UnsafeMutableRawPointer) -> Int32 {
  unsafe attr.storeBytes(of: UInt32(0), as: UInt32.self)
  return 0
}

public func pthread_condattr_destroy(_ attr: UnsafeMutableRawPointer) -> Int32 { 0 }

public func pthread_condattr_setclock(_ attr: UnsafeMutableRawPointer, _ clock: Int32) -> Int32 {
  guard clock == Int32(Clocks.realtime) || clock == Int32(Clocks.monotonic) else { return Errno.EINVAL }
  unsafe attr.storeBytes(of: UInt32(clock), as: UInt32.self)
  return 0
}

public func pthread_condattr_getclock(_ attr: UnsafeRawPointer, _ clock: UnsafeMutablePointer<Int32>) -> Int32 {
  unsafe clock.pointee = Int32(unsafe attr.load(as: UInt32.self))
  return 0
}

public func pthread_cond_init(_ c: UnsafeMutableRawPointer, _ attr: UnsafeRawPointer?) -> Int32 {
  unsafe c.initializeMemory(as: UInt32.self, repeating: 0, count: 8)
  unsafe c.storeBytes(of: unsafe attr.map { unsafe $0.load(as: UInt32.self) } ?? 0, toByteOffset: 4, as: UInt32.self)
  return 0
}

public func pthread_cond_destroy(_ c: UnsafeMutableRawPointer) -> Int32 {
  unsafe Word(c, 8).value == 0 ? 0 : Errno.EBUSY
}

public func pthread_cond_wait(_ c: UnsafeMutableRawPointer, _ m: UnsafeMutableRawPointer) -> Int32 {
  unsafe Condition.wait(c, m, until: Platform.forever)
}

public func pthread_cond_timedwait(_ c: UnsafeMutableRawPointer, _ m: UnsafeMutableRawPointer,
                                   _ abstime: UnsafeRawPointer) -> Int32
{
  let clock = unsafe c.load(fromByteOffset: 4, as: UInt32.self)
  guard let d = unsafe deadline(abstime, clock: clock) else { return Errno.EINVAL }
  return unsafe Condition.wait(c, m, until: d)
}

public func pthread_cond_signal(_ c: UnsafeMutableRawPointer) -> Int32 {
  let seq = unsafe Word(c, 0)
  seq.add(1)
  if unsafe Word(c, 8).value != 0 { seq.wake(1) }
  return 0
}

public func pthread_cond_broadcast(_ c: UnsafeMutableRawPointer) -> Int32 {
  let seq = unsafe Word(c, 0)
  seq.add(1)
  if unsafe Word(c, 8).value != 0 { seq.wakeAll() }
  return 0
}
