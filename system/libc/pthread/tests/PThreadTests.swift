// SPDX-License-Identifier: BSD-3-Clause

// Our pthreads (M5k), hosted over Sys's threads and futexes: what each
// call returns, compared with the host's glibc on the same scenario where
// POSIX defines it, and the objects under contention.

import Glibc
import PThread
import Synchronization
import Testing

/// A pthread object of ours: zeroed memory, as its static initializer.
final class Object {
  let p = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 16)
  init() { p.initializeMemory(as: UInt8.self, repeating: 0, count: 64) }
  deinit { p.deallocate() }
}

// MARK: Mutexes, against glibc

/// What a scenario's calls return, for a mutex of `type`: lock, lock again,
/// trylock, unlock, unlock, unlock (one too many for recursive's two), and
/// an unlock from another thread while held.
func mutexScenario(type: Int32, ours: Bool) -> [Int32] {
  var codes: [Int32] = []
  if ours {
    let attr = Object(), m = Object()
    _ = PThread.pthread_mutexattr_init(attr.p)
    codes.append(PThread.pthread_mutexattr_settype(attr.p, type))
    codes.append(PThread.pthread_mutex_init(m.p, attr.p))
    codes.append(PThread.pthread_mutex_lock(m.p))
    codes.append(type == PTHREAD_MUTEX_NORMAL ? -1 : PThread.pthread_mutex_lock(m.p))  // normal: deadlocks
    codes.append(PThread.pthread_mutex_trylock(m.p))
    codes.append(PThread.pthread_mutex_unlock(m.p))
    codes.append(type == PTHREAD_MUTEX_NORMAL ? -1 : PThread.pthread_mutex_unlock(m.p))
    codes.append(type == PTHREAD_MUTEX_NORMAL ? -1 : PThread.pthread_mutex_unlock(m.p))
    codes.append(PThread.pthread_mutex_lock(m.p))
    let other = Atomic<Int32>(0)
    let address = UInt(bitPattern: m.p)
    let t = Thread { other.store(PThread.pthread_mutex_unlock(UnsafeMutableRawPointer(bitPattern: address)!), ordering: .relaxed) }
    t.join()
    codes.append(type == PTHREAD_MUTEX_NORMAL ? -1 : other.load(ordering: .relaxed))
    if type != PTHREAD_MUTEX_NORMAL { codes.append(PThread.pthread_mutex_unlock(m.p)) }
    codes.append(PThread.pthread_mutex_destroy(m.p))
  } else {
    var attr = pthread_mutexattr_t(), m = pthread_mutex_t()
    _ = Glibc.pthread_mutexattr_init(&attr)
    codes.append(Glibc.pthread_mutexattr_settype(&attr, type))
    codes.append(Glibc.pthread_mutex_init(&m, &attr))
    codes.append(Glibc.pthread_mutex_lock(&m))
    codes.append(type == PTHREAD_MUTEX_NORMAL ? -1 : Glibc.pthread_mutex_lock(&m))
    codes.append(Glibc.pthread_mutex_trylock(&m))
    codes.append(Glibc.pthread_mutex_unlock(&m))
    codes.append(type == PTHREAD_MUTEX_NORMAL ? -1 : Glibc.pthread_mutex_unlock(&m))
    codes.append(type == PTHREAD_MUTEX_NORMAL ? -1 : Glibc.pthread_mutex_unlock(&m))
    codes.append(Glibc.pthread_mutex_lock(&m))
    let other = Atomic<Int32>(0)
    withUnsafeMutablePointer(to: &m) { mp in
      let address = UInt(bitPattern: mp)
      let t = Thread {
        other.store(Glibc.pthread_mutex_unlock(UnsafeMutablePointer<pthread_mutex_t>(bitPattern: address)!), ordering: .relaxed)
      }
      t.join()
    }
    codes.append(type == PTHREAD_MUTEX_NORMAL ? -1 : other.load(ordering: .relaxed))
    if type != PTHREAD_MUTEX_NORMAL { codes.append(Glibc.pthread_mutex_unlock(&m)) }
    codes.append(Glibc.pthread_mutex_destroy(&m))
  }
  return codes
}

@Test(arguments: [Int32(PTHREAD_MUTEX_NORMAL), Int32(PTHREAD_MUTEX_RECURSIVE), Int32(PTHREAD_MUTEX_ERRORCHECK)])
func mutexesAnswerAsGlibcs(type: Int32) {
  let ours = mutexScenario(type: type, ours: true), glibc = mutexScenario(type: type, ours: false)
  #expect(ours == glibc)
}

@Test func attributesAnswerAsGlibcs() {
  let a = Object()
  var g = pthread_mutexattr_t()
  _ = Glibc.pthread_mutexattr_init(&g)
  _ = PThread.pthread_mutexattr_init(a.p)
  #expect(PThread.pthread_mutexattr_settype(a.p, 7) == Glibc.pthread_mutexattr_settype(&g, 7))
  var t1: Int32 = -1, t2: Int32 = -1
  _ = PThread.pthread_mutexattr_gettype(a.p, &t1)
  _ = Glibc.pthread_mutexattr_gettype(&g, &t2)
  #expect(t1 == t2)
  var ga = pthread_attr_t()
  _ = Glibc.pthread_attr_init(&ga)
  let pa = Object()
  _ = PThread.pthread_attr_init(pa.p)
  #expect(PThread.pthread_attr_setdetachstate(pa.p, 5) == Glibc.pthread_attr_setdetachstate(&ga, 5))
  #expect(PThread.pthread_attr_setdetachstate(pa.p, 1) == Glibc.pthread_attr_setdetachstate(&ga, 1))
  var d1: Int32 = 0, d2: Int32 = 0
  _ = PThread.pthread_attr_getdetachstate(pa.p, &d1)
  _ = Glibc.pthread_attr_getdetachstate(&ga, &d2)
  #expect(d1 == d2)
  #expect(PThread.pthread_attr_setstacksize(pa.p, 100) == Glibc.pthread_attr_setstacksize(&ga, 100))
  #expect(PThread.pthread_attr_setstacksize(pa.p, 1 << 20) == Glibc.pthread_attr_setstacksize(&ga, 1 << 20))
  var s1 = 0, s2 = 0
  _ = PThread.pthread_attr_getstacksize(pa.p, &s1)
  _ = Glibc.pthread_attr_getstacksize(&ga, &s2)
  #expect(s1 == s2)
  let ca = Object()
  var gc = pthread_condattr_t()
  _ = Glibc.pthread_condattr_init(&gc)
  _ = PThread.pthread_condattr_init(ca.p)
  #expect(PThread.pthread_condattr_setclock(ca.p, 1) == Glibc.pthread_condattr_setclock(&gc, 1))
  #expect(PThread.pthread_condattr_setclock(ca.p, 99) == Glibc.pthread_condattr_setclock(&gc, 99))
}

/// An absolute time `ms` from now on `clock`, as a timespec.
func after(_ ms: Int, clock: clockid_t = CLOCK_REALTIME) -> timespec {
  var t = timespec()
  clock_gettime(clock, &t)
  let ns = Int(t.tv_nsec) + ms * 1_000_000
  t.tv_sec += ns / 1_000_000_000
  t.tv_nsec = ns % 1_000_000_000
  return t
}

@Test func timedWaitsTimeOutAsGlibcs() {
  // A held mutex, timed out; a condition nobody signals, on both clocks; an
  // abstime with nanoseconds out of range.
  let m = Object(), c = Object(), ca = Object()
  _ = PThread.pthread_mutex_lock(m.p)
  let held = UInt(bitPattern: m.p)
  let code = Atomic<Int32>(0)
  Thread {
    var t = after(20)
    code.store(PThread.pthread_mutex_timedlock(UnsafeMutableRawPointer(bitPattern: held)!, &t), ordering: .relaxed)
  }.join()
  var gm = pthread_mutex_t(), gc = pthread_cond_t()
  _ = Glibc.pthread_mutex_init(&gm, nil)
  _ = Glibc.pthread_cond_init(&gc, nil)
  _ = Glibc.pthread_mutex_lock(&gm)
  let gcode = Atomic<Int32>(0)
  withUnsafeMutablePointer(to: &gm) { gp in
    let address = UInt(bitPattern: gp)
    Thread {
      var t = after(20)
      gcode.store(Glibc.pthread_mutex_timedlock(UnsafeMutablePointer(bitPattern: address)!, &t), ordering: .relaxed)
    }.join()
  }
  #expect(code.load(ordering: .relaxed) == gcode.load(ordering: .relaxed))

  var t = after(20)
  let start = Clock.monotonicNow
  let ours = PThread.pthread_cond_timedwait(c.p, m.p, &t)
  #expect(Clock.monotonicNow - start >= 19_000_000)
  let glibc = Glibc.pthread_cond_timedwait(&gc, &gm, &t)
  #expect(ours == glibc)
  _ = PThread.pthread_condattr_init(ca.p)
  _ = PThread.pthread_condattr_setclock(ca.p, CLOCK_MONOTONIC)
  let mc = Object()
  _ = PThread.pthread_cond_init(mc.p, ca.p)
  var tm = after(20, clock: CLOCK_MONOTONIC)
  #expect(PThread.pthread_cond_timedwait(mc.p, m.p, &tm) == ETIMEDOUT)
  var bad = timespec(tv_sec: 0, tv_nsec: 2_000_000_000)
  #expect(PThread.pthread_cond_timedwait(c.p, m.p, &bad) == Glibc.pthread_cond_timedwait(&gc, &gm, &bad))
  _ = PThread.pthread_mutex_unlock(m.p)
  _ = Glibc.pthread_mutex_unlock(&gm)
}

// MARK: Threads

/// A thread's start: returns its argument plus one.
let addOne: StartRoutine = { arg in UnsafeMutableRawPointer(bitPattern: UInt(bitPattern: arg) + 1) }

@Test func threadsJoinWithTheirResults() {
  var threads = [UInt](repeating: 0, count: 8)
  for i in 0..<8 {
    #expect(PThread.pthread_create(&threads[i], nil, addOne, UnsafeMutableRawPointer(bitPattern: 0x1000 * (i + 1))) == 0)
  }
  for i in 0..<8 {
    var result: UnsafeMutableRawPointer? = nil
    #expect(PThread.pthread_join(threads[i], &result) == 0)
    #expect(UInt(bitPattern: result) == UInt(0x1000 * (i + 1) + 1))
  }
  // Joining yourself: EDEADLK, as glibc's.
  #expect(PThread.pthread_join(PThread.pthread_self(), nil) == Glibc.pthread_join(Glibc.pthread_self(), nil))
  #expect(PThread.pthread_equal(PThread.pthread_self(), PThread.pthread_self()) != 0)
}

nonisolated(unsafe) var exitKey: UInt32 = 0
let destroyed = Atomic<Int>(0)
let countDestroyed: Destructor = { value in
  if value != nil { destroyed.add(1, ordering: .relaxed) }
}

@Test func exitRunsDestructorsAndDetachedThreadsEnd() {
  #expect(PThread.pthread_key_create(&exitKey, countDestroyed) == 0)
  // pthread_exit from inside a callee, with a value set for the key.
  var t: UInt = 0
  _ = PThread.pthread_create(&t, nil, { _ in
    _ = PThread.pthread_setspecific(exitKey, UnsafeRawPointer(bitPattern: 0x10))
    PThread.pthread_exit(UnsafeMutableRawPointer(bitPattern: 0x77))
  }, nil)
  var result: UnsafeMutableRawPointer? = nil
  #expect(PThread.pthread_join(t, &result) == 0)
  #expect(UInt(bitPattern: result) == 0x77)
  #expect(destroyed.load(ordering: .relaxed) == 1)
  // Detached, by attribute and after starting: both run to their end.
  let attr = Object()
  _ = PThread.pthread_attr_init(attr.p)
  _ = PThread.pthread_attr_setdetachstate(attr.p, 1)
  for detachLater in [false, true] {
    _ = PThread.pthread_create(&t, detachLater ? nil : attr.p, { _ in
      _ = PThread.pthread_setspecific(exitKey, UnsafeRawPointer(bitPattern: 0x20))
      return nil
    }, nil)
    if detachLater { #expect(PThread.pthread_detach(t) == 0) }
  }
  let deadline = Clock.monotonicNow + 2_000_000_000
  while destroyed.load(ordering: .relaxed) < 3 && Clock.monotonicNow < deadline { usleep(1000) }
  #expect(destroyed.load(ordering: .relaxed) == 3)
  #expect(PThread.pthread_key_delete(exitKey) == 0)
}

@Test func keysAreEachThreadsAndDeletedOnesReadNothing() {
  var a: UInt32 = 0, b: UInt32 = 0
  #expect(PThread.pthread_key_create(&a, nil) == 0)
  #expect(PThread.pthread_getspecific(a) == nil)
  #expect(PThread.pthread_setspecific(a, UnsafeRawPointer(bitPattern: 5)) == 0)
  var t: UInt = 0
  nonisolated(unsafe) var key = a
  _ = withUnsafeMutablePointer(to: &key) { kp in
    PThread.pthread_create(&t, nil, { arg in
      let k = arg!.load(as: UInt32.self)
      return UnsafeMutableRawPointer(bitPattern: UInt(bitPattern: PThread.pthread_getspecific(k)) + 1)
    }, kp)
  }
  var seen: UnsafeMutableRawPointer? = nil
  _ = PThread.pthread_join(t, &seen)
  #expect(UInt(bitPattern: seen) == 1)  // its own: none
  #expect(UInt(bitPattern: PThread.pthread_getspecific(a)) == 5)
  #expect(PThread.pthread_key_delete(a) == 0)
  #expect(PThread.pthread_key_delete(a) == EINVAL)
  #expect(PThread.pthread_key_create(&b, nil) == 0)
  #expect(PThread.pthread_getspecific(b) == nil)  // even if it's a's slot again
  _ = PThread.pthread_key_delete(b)
}

// MARK: Under contention

/// What the contention tests' threads share.
final class Shared: @unchecked Sendable {
  let mutex = Object(), cond = Object(), rwlock = Object()
  var counter = 0, readers = 0, writers = 0, bad = 0
  var queue: [Int] = [], taken = 0
  let once = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
  init() { once.pointee = 0 }
  deinit { once.deallocate() }
}

/// Runs `body` on `n` of Sys's threads, through pthread_create.
func onThreads(_ n: Int, _ shared: Shared, _ body: @escaping StartRoutine) {
  var threads = [UInt](repeating: 0, count: n)
  let arg = Unmanaged.passUnretained(shared).toOpaque()
  for i in 0..<n { _ = PThread.pthread_create(&threads[i], nil, body, arg) }
  for t in threads { _ = PThread.pthread_join(t, nil) }
}

func shared(_ arg: UnsafeMutableRawPointer?) -> Shared { Unmanaged<Shared>.fromOpaque(arg!).takeUnretainedValue() }

@Test func aMutexKeepsACounterRight() {
  let s = Shared()
  onThreads(8, s) { arg in
    let s = shared(arg)
    for _ in 0..<20_000 {
      _ = PThread.pthread_mutex_lock(s.mutex.p)
      s.counter += 1
      _ = PThread.pthread_mutex_unlock(s.mutex.p)
    }
    return nil
  }
  #expect(s.counter == 160_000)
}

@Test func aConditionHandsOverEveryItem() {
  // Four producers, four consumers, a queue under the mutex.
  let s = Shared()
  onThreads(8, s) { arg in
    let s = shared(arg)
    let producer = PThread.pthread_mutex_lock(s.mutex.p) == 0 && { defer { s.writers += 1 }; return s.writers < 4 }()
    _ = PThread.pthread_mutex_unlock(s.mutex.p)
    for i in 0..<5_000 {
      _ = PThread.pthread_mutex_lock(s.mutex.p)
      if producer {
        s.queue.append(i)
        _ = PThread.pthread_cond_signal(s.cond.p)
      } else {
        while s.queue.isEmpty { _ = PThread.pthread_cond_wait(s.cond.p, s.mutex.p) }
        s.queue.removeLast()
        s.taken += 1
      }
      _ = PThread.pthread_mutex_unlock(s.mutex.p)
    }
    return nil
  }
  #expect(s.taken == 20_000 && s.queue.isEmpty)
}

@Test func aBroadcastWakesEveryone() {
  let s = Shared()
  let go = Object()
  _ = go
  onThreads(9, s) { arg in
    let s = shared(arg)
    _ = PThread.pthread_mutex_lock(s.mutex.p)
    s.readers += 1
    if s.readers == 9 {
      s.counter = 1
      _ = PThread.pthread_cond_broadcast(s.cond.p)
    }
    while s.counter == 0 { _ = PThread.pthread_cond_wait(s.cond.p, s.mutex.p) }
    _ = PThread.pthread_mutex_unlock(s.mutex.p)
    return nil
  }
  #expect(s.readers == 9)
}

@Test func aReadWriteLockKeepsWritersAlone() {
  let s = Shared()
  onThreads(8, s) { arg in
    let s = shared(arg)
    for i in 0..<3_000 {
      if i % 4 == 0 {
        _ = PThread.pthread_rwlock_wrlock(s.rwlock.p)
        s.writers += 1
        if s.writers != 1 || s.readers != 0 { s.bad += 1 }
        s.counter += 1
        s.writers -= 1
      } else {
        _ = PThread.pthread_rwlock_rdlock(s.rwlock.p)
        _ = PThread.pthread_mutex_lock(s.mutex.p)
        s.readers += 1
        if s.writers != 0 { s.bad += 1 }
        _ = PThread.pthread_mutex_unlock(s.mutex.p)
        _ = PThread.pthread_mutex_lock(s.mutex.p)
        s.readers -= 1
        _ = PThread.pthread_mutex_unlock(s.mutex.p)
      }
      _ = PThread.pthread_rwlock_unlock(s.rwlock.p)
    }
    return nil
  }
  #expect(s.bad == 0 && s.counter == 8 * 750)
  #expect(PThread.pthread_rwlock_unlock(s.rwlock.p) == EPERM)
}

let onceRuns = Atomic<Int>(0)

@Test func onceRunsOnceAndOthersWaitForIt() {
  let s = Shared()
  onThreads(8, s) { arg in
    _ = PThread.pthread_once(shared(arg).once) {
      usleep(10_000)
      onceRuns.add(1, ordering: .relaxed)
    }
    // Everyone sees it done.
    return onceRuns.load(ordering: .relaxed) == 1 ? nil : UnsafeMutableRawPointer(bitPattern: 1)
  }
  #expect(onceRuns.load(ordering: .relaxed) == 1 && s.once.pointee == 2)
}

// MARK: Helpers

/// A host thread, for a scenario's other side.
final class Thread {
  var t = pthread_t()
  init(_ body: @escaping @Sendable () -> Void) {
    let box = Unmanaged.passRetained(Box(body)).toOpaque()
    Glibc.pthread_create(&t, nil, { arg in
      Unmanaged<Box>.fromOpaque(arg!).takeRetainedValue().body()
      return nil
    }, box)
  }
  func join() { Glibc.pthread_join(t, nil) }
  final class Box { let body: @Sendable () -> Void; init(_ b: @escaping @Sendable () -> Void) { body = b } }
}

enum Clock {
  static var monotonicNow: Int {
    var t = timespec()
    clock_gettime(CLOCK_MONOTONIC, &t)
    return t.tv_sec * 1_000_000_000 + t.tv_nsec
  }
}
