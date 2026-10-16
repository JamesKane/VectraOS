// SPDX-License-Identifier: BSD-3-Clause

// Swift concurrency on croi (M6f): the toolchain's Concurrency runtime
// with VectraOS's global and main executors (a thread per CPU, sleeping on
// croi ports) and Synchronization's Mutex over croi's futexes. A task
// group's work spread over the CPUs, an actor many tasks update, sleeps
// woken in deadline order and on time, a hop to the main actor and back,
// a contended Mutex, cancellation, an AsyncStream, and a continuation
// resumed from a thread of our own. Exits 0 if all held.

import Synchronization
import TDFloor
import CroiSyscall
import TDNative
import VectraOSLibc

nonisolated(unsafe) var failures = 0
func check(_ ok: Bool, _ what: String) {
  if !ok {
    print("swift-async: FAILED: \(what)")
    failures += 1
  }
}

/// The calling thread, as a number to compare.
func threadID() -> UInt { UInt(pthread_self()) }

actor Counter {
  var value = 0
  var order: [Int] = []
  func add(_ n: Int) { value += n }
  func arrived(_ tag: Int) { order.append(tag) }
}

/// Work enough to keep a CPU busy for a while: no allocation, no sharing.
func spin(_ seed: UInt64) -> UInt64 {
  var x = seed | 1
  for _ in 0..<2_000_000 {
    x ^= x << 13
    x ^= x >> 7
    x ^= x << 17
  }
  return x
}

func seconds(_ d: Duration) -> Double {
  Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

nonisolated(unsafe) var mainThread: UInt = 0

@MainActor func onMainThread() -> Bool { threadID() == mainThread }

/// A pthread that resumes a continuation after a short sleep.
final class Resumer: @unchecked Sendable {
  let continuation: CheckedContinuation<Int, Never>
  init(_ c: CheckedContinuation<Int, Never>) { continuation = c }
}

/// croi's context switches so far, all CPUs (object_get_info CPU_STATS on
/// the system resource); nil without the resource.
func contextSwitches() -> UInt64? {
  let resource = systemResource
  guard resource != 0 else { return nil }
  var stats = [croi_info_cpu_stats_t](repeating: croi_info_cpu_stats_t(), count: 64)
  let n = stats.withUnsafeMutableBytes { b in
    croi_syscall6(CROI_SYS_OBJECT_GET_INFO, UInt64(resource), UInt64(CROI_INFO_CPU_STATS),
                  UInt64(UInt(bitPattern: b.baseAddress)), UInt64(b.count), 0, 0)
  }
  guard n >= 0 else { return nil }
  return (0..<Int(n)).reduce(0) { $0 + stats[$1].context_switches }
}

/// The system resource (processargs' PA_SYSTEM_RESOURCE), if the program was started with it.
let systemResource: UInt32 = td_startup_take(croi_pa_hnd(UInt32(CROI_PA_SYSTEM_RESOURCE), 0))

@main struct Async {
  static func main() async {
    mainThread = threadID()
    let clock = ContinuousClock()
    let cpus = sysconf(Int32(_SC_NPROCESSORS_ONLN))

    // A task group across the CPUs: the work's threads, and its time
    // against the same work done serially.
    let jobs = 32
    var start = clock.now
    var serial: UInt64 = 0
    for i in 0..<8 { serial &+= spin(UInt64(i)) }
    let serialTime = (clock.now - start) * (jobs / 8)
    start = clock.now
    let (sum, threads) = await withTaskGroup(of: (UInt64, UInt).self) { group in
      for i in 0..<jobs { group.addTask { (spin(UInt64(i)), threadID()) } }
      var sum: UInt64 = 0
      var threads: [UInt] = []
      for await (x, t) in group {
        sum &+= x
        if !threads.contains(t) { threads.append(t) }
      }
      return (sum, threads)
    }
    let parallelTime = clock.now - start
    var expected: UInt64 = 0
    for i in 0..<jobs { expected &+= spin(UInt64(i)) }
    check(sum == expected, "a task group's results")
    var first8: UInt64 = 0
    for i in 0..<8 { first8 &+= spin(UInt64(i)) }
    check(serial == first8, "the serial work's results")
    check(cpus < 2 || threads.count >= 2, "a task group on more than one thread (\(threads.count) of \(cpus) CPUs)")
    let speedup = seconds(serialTime) / seconds(parallelTime)
    print("swift-async: \(jobs) jobs on \(threads.count) threads of \(cpus) CPUs: \(parallelTime), serially \(serialTime) (\(speedup)x)")

    // An actor that a hundred tasks update.
    let counter = Counter()
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<100 {
        group.addTask { for _ in 0..<1000 { await counter.add(1) } }
      }
    }
    check(await counter.value == 100_000, "an actor's updates")

    // Sleeps: woken in their deadlines' order, and not early.
    start = clock.now
    await withTaskGroup(of: Void.self) { group in
      for tag in [30, 10, 20] {
        group.addTask {
          try? await Task.sleep(for: .milliseconds(tag))
          await counter.arrived(tag)
        }
      }
    }
    let slept = clock.now - start
    check(await counter.order == [10, 20, 30], "sleeps in deadline order: \(await counter.order)")
    check(slept >= .milliseconds(30), "a sleep not early: \(slept)")
    // Fifty 2 ms sleeps in a row: how late each wakes, from the deadline
    // to the task running again, and how many times croi's CPUs switched
    // threads meanwhile (the system resource's CPU_STATS, if userboot gave
    // it: each deadline should wake one of the idle workers, not all).
    let switchesBefore = contextSwitches()
    var lateness: [Duration] = []
    for _ in 0..<50 {
      let deadline = clock.now + .milliseconds(2)
      try? await Task.sleep(until: deadline, clock: clock)
      lateness.append(clock.now - deadline)
    }
    let switches = contextSwitches().map { after in switchesBefore.map { after - $0 } ?? 0 } ?? 0
    lateness.sort()
    print("swift-async: 50 sleeps woke late by median \(lateness[25]), p90 \(lateness[45]), most \(lateness[49]); \(switches) context switches")
    check(lateness[0] >= .zero && lateness[25] < .milliseconds(5), "sleeps' lateness: \(lateness[25])")

    // The main actor: the main thread, from a task on the pool.
    let fromPool = await Task.detached { () -> (Bool, Bool) in
      let here = threadID() != mainThread
      return (here, await onMainThread())
    }.value
    check(fromPool.0, "a detached task off the main thread")
    check(fromPool.1, "the main actor on the main thread")

    // A contended Mutex.
    let total = Mutex(0)
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<8 {
        group.addTask { for _ in 0..<20_000 { total.withLock { $0 += 1 } } }
      }
    }
    check(total.withLock { $0 } == 160_000, "a contended Mutex")

    // Cancellation reaches a sleeping task.
    let sleeper = Task { () -> Bool in
      do {
        try await Task.sleep(for: .seconds(60))
        return false
      } catch {
        return error is CancellationError
      }
    }
    try? await Task.sleep(for: .milliseconds(2))
    sleeper.cancel()
    check(await sleeper.value, "a sleep cancelled")

    // An AsyncStream between two tasks.
    let (stream, continuation) = AsyncStream.makeStream(of: Int.self)
    Task {
      for i in 1...100 { continuation.yield(i) }
      continuation.finish()
    }
    var streamed = 0
    for await i in stream { streamed += i }
    check(streamed == 5050, "an AsyncStream")

    // A continuation resumed from a pthread of our own.
    let resumed = await withCheckedContinuation { (c: CheckedContinuation<Int, Never>) in
      let box = Unmanaged.passRetained(Resumer(c)).toOpaque()
      var thread: pthread_t = 0
      let r = pthread_create(&thread, nil, { arg in
        var ts = timespec(tv_sec: 0, tv_nsec: 1_000_000)
        nanosleep(&ts, nil)
        Unmanaged<Resumer>.fromOpaque(arg!).takeRetainedValue().continuation.resume(returning: 42)
        return nil
      }, box)
      if r == 0 { pthread_detach(thread) } else { c.resume(returning: -1) }
    }
    check(resumed == 42, "a continuation resumed from a pthread")

    print("swift-async: \(failures == 0 ? "passed" : "FAILED")")
    exit(failures == 0 ? 0 : 1)
  }
}
