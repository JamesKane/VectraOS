// SPDX-License-Identifier: BSD-3-Clause

// Threads for 9gate's requests, kept between them: a request that may
// wait (a 9P round trip, a file's read) runs on a thread of its own, and
// starting a thread for each, then ending it, cost more than the
// request's own work. A job goes to a thread left idle by the last, or to
// a new one when none is, so no job waits for another's end (one may wait
// for another's result: a read for the block read ahead of it). An idle
// thread sleeps on a futex, and ends once idle for `linger`.

import Synchronization
import Sys

final class Workers: @unchecked Sendable {
  /// How long a thread is kept idle.
  static let linger: Int64 = 2_000_000_000

  final class Worker: @unchecked Sendable {
    /// 1 once a job is given, 0 while it waits for one.
    let word = Atomic<UInt32>(0)
    var job: (@Sendable () -> Void)?

    var address: UnsafeMutablePointer<UInt32> {
      unsafe withUnsafePointer(to: word) { unsafe UnsafeMutablePointer(mutating: UnsafeRawPointer($0).assumingMemoryBound(to: UInt32.self)) }
    }
  }

  let lock = Lock()
  /// The threads waiting for a job, the last idle last.
  var idle: [Worker] = []

  init() {}

  /// Runs `job` on an idle thread, or a new one.
  func run(_ job: @escaping @Sendable () -> Void) throws(Status) {
    if let w = lock.withLock({ idle.popLast() }) {
      w.job = job
      w.word.store(1, ordering: .releasing)
      unsafe Futex.wake(w.address, count: 1)
      return
    }
    let w = Worker()
    w.job = job
    _ = try Thread.spawn { [self] in serve(w) }
  }

  /// A thread's jobs, until it has been idle for `linger`.
  func serve(_ w: Worker) {
    while true {
      let job = w.job
      w.job = nil
      job?()
      lock.withLock { idle.append(w) }
      let deadline = Clock.monotonic() + Self.linger
      while w.word.load(ordering: .acquiring) == 0 {
        try? unsafe Futex.wait(w.address, current: 0, deadline: deadline)
        guard w.word.load(ordering: .acquiring) == 0, Clock.monotonic() >= deadline else { continue }
        // Idle too long: it ends, unless a job was given it meanwhile.
        let ends = lock.withLock { () -> Bool in
          guard let i = idle.firstIndex(where: { $0 === w }) else { return false }
          idle.remove(at: i)
          return true
        }
        if ends { return }
        // Taken from `idle`: its job is coming.
        while w.word.load(ordering: .acquiring) == 0 { try? unsafe Futex.wait(w.address, current: 0) }
      }
      w.word.store(0, ordering: .relaxed)
    }
  }
}
