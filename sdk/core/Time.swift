// SPDX-License-Identifier: BSD-3-Clause

// Time (sdk(2)): the monotonic clock, absolute deadlines, and sleeping
// until one. Time is absolute (principle 3): every wait takes a deadline
// and a leeway, never a relative timeout or a global resolution.

/// A point on the monotonic clock, in nanoseconds.
public struct Deadline: Comparable, Hashable, Sendable {
  public var ns: UInt64

  public init(ns: UInt64) { self.ns = ns }

  public static func < (a: Deadline, b: Deadline) -> Bool { a.ns < b.ns }

  public static func + (d: Deadline, by: Duration) -> Deadline { Deadline(ns: d.ns &+ by.nanoseconds) }

  /// The time from `earlier` to this deadline (zero if it is earlier).
  public func since(_ earlier: Deadline) -> Duration { .nanoseconds(Int64(ns > earlier.ns ? ns - earlier.ns : 0)) }
}

extension Duration {
  /// The duration in whole nanoseconds, saturating at zero.
  public var nanoseconds: UInt64 {
    let (seconds, attoseconds) = components
    guard seconds >= 0 else { return 0 }
    return UInt64(seconds) * 1_000_000_000 + UInt64(attoseconds / 1_000_000_000)
  }
}
