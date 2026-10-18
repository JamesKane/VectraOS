// SPDX-License-Identifier: BSD-3-Clause

// VectraOS's rule table (docs/performance.md): which rule each measurement
// is judged by. The mechanism is Judge.swift (todhchai's); the names here
// are this tree's. A budget's limit comes from whoever reports it (the
// kernel's and m2's `budget ... limit=` lines), so the rules here only set
// how much noise a measurement may show before it counts as a regression.

extension Rule {
  /// The kernel's and m2's boot budgets (croi's tools/bench.py RULES,
  /// sized from what the same tree measured under KVM on a shared
  /// machine, 2026-10-10: channel_call 1.39-1.42 µs quiet, 1.8-2.2 µs with
  /// a build running). Floors in seconds, or in the count or bytes.
  static let boot: [String: (tolerance: Double, floor: Double)] = [
    "syscall.null": (0.25, 10e-9),
    "ipc.channel_call": (0.15, 150e-9),
    "port.wake_median": (0.25, 300e-9),
    "port.wake_p99": (0.50, 5e-6),
    "counter.wake_median": (0.25, 300e-9),
    "counter.wake_p99": (0.50, 5e-6),
    "timer.wake_error_p99": (0.50, 20e-6),
    "process.spawn_to_main": (0.50, 30e-6),
    "trace.probe_enabled": (0.25, 5e-9),
    "irq.wait_wake_median": (0.25, 3e-6),
    "boot.userboot_start": (0.15, 15e-3),
    "boot.userboot_start_selftests": (0.25, 300e-3),
    "edf.deadline_misses": (0.0, 0.5),
    "edf.worst_wake": (0.50, 20e-6),
    "power.shutdown_kernel": (0.50, 1e-3),
    "power.log_drain": (0.50, 20e-3),
    "idle.wakeups": (0.0, 0.5),
    "ring.per_1000_slots": (0.25, 2e-6),
    "ring.round_trip": (0.25, 50e-9),
    "ring.kicks": (0.0, 0.5),
    // The services' resident memory (V2's exit, < 32 MiB), from the
    // services boot: bootfs and heaps, steady to a few pages.
    "services.rss": (0.10, 1_048_576),
    // 64 MiB between two memory files through NodeFile (D103), from the
    // services boot: its rings, the copies and the threads' handoffs.
    "node.file_copy": (0.25, 10e-3),
  ]

  /// The rule for a measurement, by name.
  public static func `for`(_ name: String) -> Rule {
    switch name {
    case "trace.zone.enabled": return .traceZoneEnabled
    case "trace.zone.disabled": return .traceZoneDisabled
    default: break
    }
    if let r = boot[name] { return Rule(tolerance: r.tolerance, floor: r.floor, window: 5) }
    if name.hasPrefix("build.clean.") { return .cleanBuild }
    if name.hasPrefix("build.") { return .buildTime }
    // A boot budget not in the table yet: croi's default, +25% and no floor.
    return Rule(tolerance: 0.25, floor: 0, window: 5)
  }
}
