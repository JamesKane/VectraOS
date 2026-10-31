// SPDX-License-Identifier: BSD-3-Clause

// A lock and a detached thread, over pthreads: vx links FoundationEssentials,
// which has neither NSLock nor Thread.

import HostSystem

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
  if let thread = startThread(body) {
    pthread_detach(thread)
  } else {
    body()
  }
}
