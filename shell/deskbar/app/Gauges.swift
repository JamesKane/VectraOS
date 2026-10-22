// SPDX-License-Identifier: BSD-3-Clause

// Deskbar's gauges (D114, board 01's CPU 3% and PACING p99 0.4), each read
// from a file answered when its value changes: proc(4)'s `/proc/cpu`
// (`busy N`, the online CPUs' time not idle), and Radharc's `pacing`
// (`p99 N`, its latch's lateness in microseconds). A bar's full: all the
// CPUs, a frame's period late. GPU and AUDIO come with their sources.

/// A gauge: its name, how full its bar is (0 to 1), what it reads.
public struct Gauge: Equatable, Sendable {
  public var name: String
  public var fraction: Float
  public var reading: String
  public init(name: String, fraction: Float, reading: String) {
    self.name = name
    self.fraction = fraction
    self.reading = reading
  }
}

public enum Gauges {
  /// A number at a line's word `after` (as "busy 40").
  static func value(_ text: String, _ words: [String]) -> Int64? {
    for line in text.split(separator: "\n") {
      let w = line.split(separator: " ").map(String.init)
      guard w.count > words.count, Array(w.prefix(words.count)) == words else { continue }
      return Int64(w[words.count])
    }
    return nil
  }

  static func percent(_ f: Float) -> String { "\(Int((min(max(f, 0), 1) * 100).rounded()))%" }

  /// Tenths, as "2.7".
  static func tenths(_ micro: Int64) -> String {
    let t = (micro + 50) / 100
    return "\(t / 10).\(t % 10)"
  }

  /// /proc/cpu's `busy N`; none read yet, or not served: a dash.
  public static func cpu(_ text: String) -> Gauge {
    guard let p = value(text, ["busy"]) else { return Gauge(name: "CPU", fraction: 0, reading: "—") }
    let f = Float(min(max(p, 0), 100)) / 100
    return Gauge(name: "CPU", fraction: f, reading: percent(f))
  }

  /// Radharc's `pacing`, `p99 N` microseconds late (a latch early is on
  /// time), against a frame's period.
  public static func pacing(_ text: String, period: Int64 = 16_666_667) -> Gauge {
    guard let late = value(text, ["p99"]) else { return Gauge(name: "PACING", fraction: 0, reading: "—") }
    let us = max(0, late)
    return Gauge(name: "PACING", fraction: Float(us * 1000) / Float(period), reading: "p99 " + tenths(us))
  }
}
