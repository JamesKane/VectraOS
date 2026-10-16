// SPDX-License-Identifier: BSD-3-Clause

// Thread-specific data (POSIX XSH pthread_key_create, M5k): 128 keys, a
// table of their generations (odd: in use) and destructors, and each
// thread's values in its record as (generation, value), so a deleted key's
// values never show through a key made again in its place. Making and
// deleting keys take a lock; reading a value doesn't (a generation is one
// atomic word).

import TDAtomic

public typealias Destructor = @convention(c) (UnsafeMutableRawPointer?) -> Void

enum Keys {
  static let max = 128, iterations = 4

  /// The keys' table, static: per key its generation (a word, odd: in use)
  /// at 0 and its destructor's address at 8, 16 bytes each; then a mutex
  /// (Mutex.swift's 32 bytes) for making and deleting keys.
  nonisolated(unsafe) static var storage = InlineArray<260, UInt64>(repeating: 0)

  static var base: UnsafeMutableRawPointer { unsafe withUnsafeMutablePointer(to: &storage) { unsafe UnsafeMutableRawPointer($0) } }
  static var lock: UnsafeMutableRawPointer { unsafe base + max * 16 }

  static func generation(_ key: Int) -> UInt32 { unsafe Word(base, key * 16).value }
  static func destructor(_ key: Int) -> UInt { unsafe base.load(fromByteOffset: key * 16 + 8, as: UInt.self) }

  /// Under the lock: makes `key` in use with `destructor` (its address,
  /// or 0), or not.
  static func set(_ key: Int, inUse: Bool, destructor: UInt) {
    if inUse { unsafe base.storeBytes(of: destructor, toByteOffset: key * 16 + 8, as: UInt.self) }
    unsafe Word(base, key * 16).add(1)
    if !inUse { unsafe base.storeBytes(of: UInt(0), toByteOffset: key * 16 + 8, as: UInt.self) }
  }

  static func locked<R>(_ body: () -> R) -> R {
    _ = unsafe Mutex.acquire(lock, until: Platform.forever)
    defer { unsafe Mutex.release(lock) }
    return body()
  }

  /// The calling thread's slot for `key`.
  static func slot(_ r: UnsafeMutableRawPointer, _ key: Int) -> UnsafeMutableRawPointer {
    unsafe r + Record.values + key * 16
  }

  /// Runs the destructors of the thread's values, as long as there are
  /// some, up to PTHREAD_DESTRUCTOR_ITERATIONS rounds.
  static func runDestructors(_ r: UnsafeMutableRawPointer) {
    for _ in 0..<iterations {
      var ran = false
      for key in 0..<max {
        let s = unsafe slot(r, key)
        guard let value = unsafe s.load(fromByteOffset: 8, as: UnsafeMutableRawPointer?.self) else { continue }
        let g = generation(key), d = destructor(key)
        guard unsafe s.load(as: UInt64.self) == UInt64(g), g & 1 == 1, d != 0 else { continue }
        unsafe s.storeBytes(of: nil, toByteOffset: 8, as: UnsafeMutableRawPointer?.self)
        unsafe unsafeBitCast(d, to: Destructor.self)(value)
        ran = true
      }
      if !ran { return }
    }
  }
}

public func pthread_key_create(_ key: UnsafeMutablePointer<UInt32>, _ destructor: Destructor?) -> Int32 {
  Keys.locked {
    var free = -1
    for k in 0..<Keys.max where Keys.generation(k) & 1 == 0 {
      free = k
      break
    }
    guard free >= 0 else { return Errno.EAGAIN }
    let k = free
    Keys.set(k, inUse: true, destructor: unsafe destructor.map { unsafe unsafeBitCast($0, to: UInt.self) } ?? 0)
    unsafe key.pointee = UInt32(k)
    return 0
  }
}

public func pthread_key_delete(_ key: UInt32) -> Int32 {
  Keys.locked {
    guard Int(key) < Keys.max, Keys.generation(Int(key)) & 1 == 1 else { return Errno.EINVAL }
    Keys.set(Int(key), inUse: false, destructor: 0)
    return 0
  }
}

public func pthread_getspecific(_ key: UInt32) -> UnsafeMutableRawPointer? {
  guard Int(key) < Keys.max else { return nil }
  let s = unsafe Keys.slot(Record.current, Int(key))
  guard unsafe s.load(as: UInt64.self) == UInt64(Keys.generation(Int(key))) else { return nil }
  return unsafe s.load(fromByteOffset: 8, as: UnsafeMutableRawPointer?.self)
}

public func pthread_setspecific(_ key: UInt32, _ value: UnsafeRawPointer?) -> Int32 {
  guard Int(key) < Keys.max else { return Errno.EINVAL }
  let g = Keys.generation(Int(key))
  guard g & 1 == 1 else { return Errno.EINVAL }
  let s = unsafe Keys.slot(Record.current, Int(key))
  unsafe s.storeBytes(of: UInt64(g), as: UInt64.self)
  unsafe s.storeBytes(of: UnsafeMutableRawPointer(mutating: value), toByteOffset: 8, as: UnsafeMutableRawPointer?.self)
  return 0
}
