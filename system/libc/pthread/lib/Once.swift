// SPDX-License-Identifier: BSD-3-Clause

// pthread_once (POSIX XSH, M5k): a word, 0 (not yet), 1 (running) or 2
// (done); a thread that finds it running sleeps until it's done.


public typealias OnceRoutine = @convention(c) () -> Void

public func pthread_once(_ once: UnsafeMutablePointer<UInt32>, _ initialize: OnceRoutine) -> Int32 {
  let word = unsafe Word(UnsafeMutableRawPointer(once), 0)
  if word.value == 2 { return 0 }
  if word.cas(0, 1) {
    initialize()
    word.value = 2
    word.wakeAll()
    return 0
  }
  while word.value == 1 { _ = word.wait(1, until: Platform.forever) }
  return 0
}
