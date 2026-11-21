// SPDX-License-Identifier: BSD-3-Clause

// What the driver says in its status file about what happened, in the order
// it happened, each with the time: the monotonic clock's, in milliseconds
// since the host started. The driver keeps two (its own, `event:`, and the
// firmware link's, `firmware:`), so a reader can put a fault, a reset and the
// firmware's answers on one line of time. Nothing here reads a clock: the
// caller gives the time, so the host tests own it.

/// A bounded log of lines with their times; the oldest go first.
public struct EventLog: Equatable, Sendable {
  public struct Entry: Equatable, Sendable {
    /// Nanoseconds on the clock the log's owner reads.
    public var time: Int64
    public var text: String
  }

  public private(set) var entries: [Entry] = []
  /// The clock's reading when the host started.
  public let origin: Int64
  public let capacity: Int

  public init(origin: Int64, capacity: Int) {
    self.origin = origin
    self.capacity = capacity
  }

  /// Appends `text` at `time`. Times never run backwards in a log: one that
  /// would (a clock read on another thread, a little late) takes the last's.
  public mutating func add(_ text: String, at time: Int64) {
    if entries.count >= capacity { entries.removeFirst() }
    let t = max(time, entries.last?.time ?? time)
    entries.append(Entry(time: t, text: text))
  }

  public var texts: [String] { entries.map { $0.text } }

  /// The status's lines, each opening with its time: `[1234 ms] text`.
  public var lines: [String] {
    var out: [String] = []
    for e in entries { out.append(EventLog.stamp(e.time - origin) + " " + e.text) }
    return out
  }

  /// `[1234 ms]`: milliseconds since the origin, never negative.
  public static func stamp(_ sinceOrigin: Int64) -> String { "[\(max(sinceOrigin, 0) / 1_000_000) ms]" }
}
