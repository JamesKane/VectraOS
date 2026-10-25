// SPDX-License-Identifier: BSD-3-Clause

// /proc/cpu (D114): how busy the CPUs are, for Deskbar's gauge. Its text,
// `busy N`, is the percentage of the online CPUs' time not idle between
// two samples of their idle times, and changes only when that moves 5
// points (or reaches 0 or 100), so a reader waiting on it (Node's
// `changing`) wakes only for a change worth showing. proc samples once a
// second, and only while a channel is open at the file.

import Sys

/// The busy percentage shown, from samples of each CPU's idle time.
public struct CPUGauge: Sendable {
  /// What is shown, 0 to 100.
  public private(set) var busy = 0
  var last: (now: Int64, idle: Int64, online: Int)?

  public init() {}

  /// The file's text.
  public var text: String { "busy \(busy)\n" }

  /// A sample at `now` of each CPU's idle nanoseconds (online ones'):
  /// whether what is shown changed. The first after a reset only sets the
  /// baseline, and so does one with another count of CPUs online.
  public mutating func sample(now: Int64, idle: [Int64]) -> Bool {
    let sum = idle.reduce(0, +)
    defer { last = (now, sum, idle.count) }
    guard let a = last, now > a.now, a.online == idle.count, !idle.isEmpty else { return false }
    let total = (now - a.now) * Int64(idle.count)
    let idlePercent = ((sum - a.idle) * 100 + total / 2) / total
    let b = Int(max(0, min(100, 100 - idlePercent)))
    let moved = b > busy ? b - busy : busy - b
    guard moved >= 5 || (moved > 0 && (b == 0 || b == 100)) else { return false }
    busy = b
    return true
  }

  /// No reader: the next sample starts afresh.
  public mutating func reset() { last = nil }
}

/// /proc/sysstat: each CPU's counts since boot, a line a CPU, read afresh
/// at each open: `cpu <n> online|offline wakeups <n> interrupts <n> timer
/// <n> resched <n> generic <n> switches <n> idle <ms>`. On an idle machine
/// every interrupt a CPU takes is a wakeup (CPUStats.wakeups): two reads
/// some seconds apart count the desktop's idle wakeups by CPU and kind.
public enum SysStat {
  public static func line(cpu: UInt32, online: Bool, interrupts: UInt64, timer: UInt64, resched: UInt64,
                          generic: UInt64, switches: UInt64, idleNanoseconds: Int64) -> String {
    "cpu \(cpu) \(online ? "online" : "offline") wakeups \(interrupts + timer + resched + generic) "
      + "interrupts \(interrupts) timer \(timer) resched \(resched) generic \(generic) switches \(switches) "
      + "idle \(idleNanoseconds / 1_000_000)\n"
  }

  public static func text(_ stats: [CPUStats]) -> String {
    stats.map {
      line(cpu: $0.cpu, online: $0.online, interrupts: $0.interrupts, timer: $0.timerInterrupts,
           resched: $0.rescheduleIPIs, generic: $0.genericIPIs, switches: $0.contextSwitches,
           idleNanoseconds: $0.idleTime)
    }.joined()
  }
}
