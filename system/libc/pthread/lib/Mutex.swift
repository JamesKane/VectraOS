// SPDX-License-Identifier: BSD-3-Clause

// Mutexes (POSIX XSH pthread_mutex_*, M5k): Sys.Lock's three-state word
// (Drepper, "Futexes Are Tricky", mutex 3: 0 free, 1 held, 2 held and maybe
// waited on), plus, for recursive and error-checking ones, the owner's id
// and the depth. An all-zero mutex is a normal one.
//
//   0  word   4  type   8  owner (a thread's id)   12  depth


enum Mutex {
  static let normal: UInt32 = 0, recursive: UInt32 = 1, errorCheck: UInt32 = 2

  static func type(_ m: UnsafeMutableRawPointer) -> UInt32 { unsafe m.load(fromByteOffset: 4, as: UInt32.self) }

  /// Takes the word, sleeping until `deadline`; false if it passed.
  static func acquire(_ m: UnsafeMutableRawPointer, until deadline: Int64, contended: Bool = false) -> Bool {
    let word = unsafe Word(m, 0)
    if !contended && word.cas(0, 1) { return true }
    // Contended: say so, then sleep while it stays held.
    while word.exchange(2) != 0 {
      if !word.wait(2, until: deadline) { return false }
    }
    return true
  }

  static func release(_ m: UnsafeMutableRawPointer) {
    let word = unsafe Word(m, 0)
    if word.exchange(0) == 2 { word.wake(1) }
  }

  static func lock(_ m: UnsafeMutableRawPointer, until deadline: Int64) -> Int32 {
    let type = unsafe type(m)
    if type == normal { return unsafe acquire(m, until: deadline) ? 0 : Errno.ETIMEDOUT }
    let me = Record.currentID
    let owner = unsafe Word(m, 8), depth = unsafe Word(m, 12)
    if owner.value == me {
      guard type == recursive else { return Errno.EDEADLK }
      guard depth.value < UInt32.max else { return Errno.EAGAIN }
      depth.value += 1
      return 0
    }
    guard unsafe acquire(m, until: deadline) else { return Errno.ETIMEDOUT }
    owner.value = me
    depth.value = 1
    return 0
  }
}

public func pthread_mutexattr_init(_ attr: UnsafeMutableRawPointer) -> Int32 {
  unsafe attr.storeBytes(of: UInt32(0), as: UInt32.self)
  return 0
}

public func pthread_mutexattr_destroy(_ attr: UnsafeMutableRawPointer) -> Int32 { 0 }

public func pthread_mutexattr_settype(_ attr: UnsafeMutableRawPointer, _ type: Int32) -> Int32 {
  guard type >= 0 && type <= 2 else { return Errno.EINVAL }
  unsafe attr.storeBytes(of: UInt32(type), as: UInt32.self)
  return 0
}

public func pthread_mutexattr_gettype(_ attr: UnsafeRawPointer, _ type: UnsafeMutablePointer<Int32>) -> Int32 {
  unsafe type.pointee = Int32(unsafe attr.load(as: UInt32.self))
  return 0
}

public func pthread_mutex_init(_ m: UnsafeMutableRawPointer, _ attr: UnsafeRawPointer?) -> Int32 {
  unsafe m.initializeMemory(as: UInt32.self, repeating: 0, count: 8)
  unsafe m.storeBytes(of: unsafe attr.map { unsafe $0.load(as: UInt32.self) } ?? 0, toByteOffset: 4, as: UInt32.self)
  return 0
}

public func pthread_mutex_destroy(_ m: UnsafeMutableRawPointer) -> Int32 {
  unsafe Word(m, 0).value == 0 ? 0 : Errno.EBUSY
}

public func pthread_mutex_lock(_ m: UnsafeMutableRawPointer) -> Int32 { unsafe Mutex.lock(m, until: Platform.forever) }

public func pthread_mutex_timedlock(_ m: UnsafeMutableRawPointer, _ abstime: UnsafeRawPointer) -> Int32 {
  guard let d = unsafe deadline(abstime, clock: Clocks.realtime) else { return Errno.EINVAL }
  return unsafe Mutex.lock(m, until: d)
}

public func pthread_mutex_trylock(_ m: UnsafeMutableRawPointer) -> Int32 {
  let type = unsafe Mutex.type(m)
  if type != Mutex.normal {
    let owner = unsafe Word(m, 8), depth = unsafe Word(m, 12)
    if owner.value == Record.currentID {
      guard type == Mutex.recursive else { return Errno.EBUSY }
      depth.value += 1
      return 0
    }
  }
  guard unsafe Word(m, 0).cas(0, 1) else { return Errno.EBUSY }
  if type != Mutex.normal {
    unsafe Word(m, 8).value = Record.currentID
    unsafe Word(m, 12).value = 1
  }
  return 0
}

public func pthread_mutex_unlock(_ m: UnsafeMutableRawPointer) -> Int32 {
  if unsafe Mutex.type(m) != Mutex.normal {
    let owner = unsafe Word(m, 8), depth = unsafe Word(m, 12)
    guard owner.value == Record.currentID else { return Errno.EPERM }
    if depth.value > 1 {
      depth.value -= 1
      return 0
    }
    owner.value = 0
    depth.value = 0
  }
  unsafe Mutex.release(m)
  return 0
}
