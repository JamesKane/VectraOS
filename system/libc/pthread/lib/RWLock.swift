// SPDX-License-Identifier: BSD-3-Clause

// Read-write locks (POSIX XSH pthread_rwlock_*, M5k): a state word (the
// writer's bit, or the readers' count), a sequence word waiters sleep on
// (read before they look at the state again, so a release in between
// changes it), and a count of waiters, so a release nobody waits for
// makes no kernel call. No preference: whoever gets there.
//
//   0  state   4  sequence   8  waiters


enum RWLock {
  static let writer: UInt32 = 0x8000_0000

  /// Sleeps until the state may have changed from what `blocked` refuses.
  static func await(_ l: UnsafeMutableRawPointer, _ blocked: (UInt32) -> Bool) {
    let state = unsafe Word(l, 0), seq = unsafe Word(l, 4), waiters = unsafe Word(l, 8)
    waiters.add(1)
    let s = seq.value
    if blocked(state.value) { _ = seq.wait(s, until: Platform.forever) }
    waiters.add(UInt32.max)
  }

  static func tryRead(_ l: UnsafeMutableRawPointer) -> Int32? {
    let state = unsafe Word(l, 0)
    while true {
      let v = state.value
      if v & writer != 0 { return nil }
      if v & ~writer == ~writer { return Errno.EAGAIN }
      if state.cas(v, v + 1) { return 0 }
    }
  }
}

public func pthread_rwlock_init(_ l: UnsafeMutableRawPointer, _ attr: UnsafeRawPointer?) -> Int32 {
  unsafe l.initializeMemory(as: UInt32.self, repeating: 0, count: 8)
  return 0
}

public func pthread_rwlock_destroy(_ l: UnsafeMutableRawPointer) -> Int32 {
  unsafe Word(l, 0).value == 0 ? 0 : Errno.EBUSY
}

public func pthread_rwlock_rdlock(_ l: UnsafeMutableRawPointer) -> Int32 {
  while true {
    if let r = unsafe RWLock.tryRead(l) { return r }
    unsafe RWLock.await(l) { $0 & RWLock.writer != 0 }
  }
}

public func pthread_rwlock_tryrdlock(_ l: UnsafeMutableRawPointer) -> Int32 {
  unsafe RWLock.tryRead(l) ?? Errno.EBUSY
}

public func pthread_rwlock_wrlock(_ l: UnsafeMutableRawPointer) -> Int32 {
  let state = unsafe Word(l, 0)
  while !state.cas(0, RWLock.writer) {
    unsafe RWLock.await(l) { $0 != 0 }
  }
  return 0
}

public func pthread_rwlock_trywrlock(_ l: UnsafeMutableRawPointer) -> Int32 {
  unsafe Word(l, 0).cas(0, RWLock.writer) ? 0 : Errno.EBUSY
}

public func pthread_rwlock_unlock(_ l: UnsafeMutableRawPointer) -> Int32 {
  let state = unsafe Word(l, 0)
  var now: UInt32
  while true {
    let v = state.value
    if v == 0 { return Errno.EPERM }
    now = v == RWLock.writer ? 0 : v - 1
    if state.cas(v, now) { break }
  }
  if now == 0, unsafe Word(l, 8).value != 0 {
    unsafe Word(l, 4).add(1)
    unsafe Word(l, 4).wakeAll()
  }
  return 0
}
