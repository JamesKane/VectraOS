// SPDX-License-Identifier: BSD-3-Clause

// A lock and a detached thread, over pthreads: vx links FoundationEssentials,
// which has neither NSLock nor Thread.

import Glibc

final class Lock: @unchecked Sendable {
  let mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)

  init() { pthread_mutex_init(mutex, nil) }

  deinit {
    pthread_mutex_destroy(mutex)
    mutex.deallocate()
  }

  func withLock<R, E: Error>(_ body: () throws(E) -> R) throws(E) -> R {
    pthread_mutex_lock(mutex)
    defer { pthread_mutex_unlock(mutex) }
    return try body()
  }
}

/// Runs `body` on a thread of its own, detached.
func spawn(_ body: @escaping @Sendable () -> Void) {
  final class Box {
    let body: @Sendable () -> Void
    init(_ body: @escaping @Sendable () -> Void) { self.body = body }
  }
  let box = Unmanaged.passRetained(Box(body)).toOpaque()
  var thread = pthread_t()
  let started = pthread_create(&thread, nil, { p in
    let box = Unmanaged<Box>.fromOpaque(p!).takeRetainedValue()
    box.body()
    return nil
  }, box)
  if started == 0 {
    pthread_detach(thread)
  } else {
    Unmanaged<Box>.fromOpaque(box).release()
    body()
  }
}
