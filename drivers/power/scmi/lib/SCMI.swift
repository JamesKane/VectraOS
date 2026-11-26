// SPDX-License-Identifier: BSD-3-Clause

// Arm's System Control and Management Interface (SCMI 3.2, DEN0056E), as
// an agent sends it: messages in a shared-memory channel (§5.1.2), each a
// header and 32-bit words, and the commands bin/scmi takes in its ctl.
// The base (0x10), power domain (0x11), performance (0x13) and clock
// (0x14) protocols' messages that bin/scmi uses; the transports, a
// mailbox doorbell or an SMC, are in Main.swift.

/// The shared-memory channel's layout (§5.1.2, Table 4): what bin/scmi
/// reads and writes at these offsets, 32 bits at a time.
public enum SharedMemory {
  /// Bit 0: the channel is free (the platform has answered); bit 1: an
  /// error ended the last message.
  public static let status = 0x04
  /// Bit 0: interrupt the agent on completion (polled here: 0).
  public static let flags = 0x10
  /// The header's and payload's bytes.
  public static let length = 0x14
  public static let header = 0x18
  public static let payload = 0x1C
  /// The smallest channel: 128 bytes, as the Sky1's are.
  public static let minimumSize = 0x80

  public static let free: UInt32 = 1 << 0
  public static let error: UInt32 = 1 << 1
}

/// A protocol's id (§4).
public enum ProtocolID: UInt32, Sendable {
  case base = 0x10
  case power = 0x11
  case performance = 0x13
  case clock = 0x14
}

/// A command's header (§4.1.1): message id 7:0, type 9:8 (0, a command),
/// protocol 17:10, token 27:18.
public func header(_ proto: ProtocolID, message: UInt32, token: UInt32) -> UInt32 {
  message & 0xFF | proto.rawValue << 10 | (token & 0x3FF) << 18
}

/// Messages every protocol answers (§4.2.2), and those bin/scmi sends.
public enum Message {
  public static let protocolVersion: UInt32 = 0x0
  public static let protocolAttributes: UInt32 = 0x1
  /// Base: the vendor's name, 16 bytes (§4.2.2.4).
  public static let discoverVendor: UInt32 = 0x3
  /// Power: flags, domain, state (§4.3.2.4).
  public static let powerStateSet: UInt32 = 0x4
  public static let powerStateGet: UInt32 = 0x5
  /// Clock: id; status, attributes, name (§4.6.2.4).
  public static let clockAttributes: UInt32 = 0x3
  /// Clock: flags, id, rate (two words, low first) (§4.6.2.8).
  public static let clockRateSet: UInt32 = 0x5
  /// Clock: id; status, rate (two words) (§4.6.2.9).
  public static let clockRateGet: UInt32 = 0x6
  /// Clock: id, attributes (bit 0, enabled) (§4.6.2.7).
  public static let clockConfigSet: UInt32 = 0x7
  /// Performance: domain; status, the highest and the lowest level allowed (§4.5.3.7).
  public static let performanceLimitsGet: UInt32 = 0x6
  /// Performance: domain, level (§4.5.3.8).
  public static let performanceLevelSet: UInt32 = 0x7
  /// Performance: domain; status, level (§4.5.3.9).
  public static let performanceLevelGet: UInt32 = 0x8
}

/// A power domain's states (§4.3.2.4): on, and off with its context lost.
public enum PowerState {
  public static let on: UInt32 = 0
  public static let off: UInt32 = 1 << 30
}

/// The platform's answer: a status word (§4.1.4), then the message's.
public enum SCMIStatus: Int32, Sendable {
  case success = 0
  case notSupported = -1
  case invalidParameters = -2
  case denied = -3
  case notFound = -4
  case outOfRange = -5
  case busy = -6
  case commsError = -7
  case genericError = -8
  case hardwareError = -9
  case protocolError = -10

  public var name: String {
    switch self {
    case .success: "success"
    case .notSupported: "not supported"
    case .invalidParameters: "invalid parameters"
    case .denied: "denied"
    case .notFound: "not found"
    case .outOfRange: "out of range"
    case .busy: "busy"
    case .commsError: "comms error"
    case .genericError: "generic error"
    case .hardwareError: "hardware error"
    case .protocolError: "protocol error"
    }
  }
}

/// Why a command failed: the platform's status, a channel that never
/// came free or reported an error, or an answer too short to read.
public enum SCMIError: Error, Equatable, Sendable {
  case status(Int32)
  case timedOut
  case channelError
  case short
  /// No transport carries the protocol.
  case noChannel

  public var description: String {
    switch self {
    case .status(let s): "status \(s)" + (SCMIStatus(rawValue: s).map { " (\($0.name))" } ?? "")
    case .timedOut: "timed out"
    case .channelError: "channel error"
    case .short: "short answer"
    case .noChannel: "no channel"
    }
  }
}

/// An answer's words (its payload after the header) as the command's
/// result: the status word checked, the rest returned.
public func result(_ payload: [UInt32]) throws(SCMIError) -> [UInt32] {
  guard let first = payload.first else { throw .short }
  let status = Int32(bitPattern: first)
  guard status == 0 else { throw .status(status) }
  return Array(payload.dropFirst())
}

/// A version word (§4.2.2.1): major 31:16, minor 15:0.
public func versionText(_ v: UInt32) -> String { "\(v >> 16).\(v & 0xFFFF)" }

/// A name in words, NUL-ended (base vendor, clock names: 16 bytes).
public func nameText(_ words: ArraySlice<UInt32>) -> String {
  var bytes: [UInt8] = []
  for w in words {
    for i in 0..<4 {
      let b = UInt8(truncatingIfNeeded: w >> (8 * UInt32(i)))
      if b == 0 { return String(decoding: bytes, as: UTF8.self) }
      bytes.append(b)
    }
  }
  return String(decoding: bytes, as: UTF8.self)
}

/// A line written to bin/scmi's ctl: `power DOMAIN on|off`, `clock ID
/// on|off`, `clock ID rate HZ`, `perf DOMAIN level [LEVEL]` or `perf DOMAIN
/// limits`; numbers in decimal or 0x hex.
public enum Command: Equatable, Sendable {
  case power(domain: UInt32, on: Bool)
  case clock(id: UInt32, on: Bool)
  /// The rate asked for; the platform rounds it down to one it has, read
  /// back after (CLOCK_RATE_GET).
  case rate(id: UInt32, hertz: UInt32)
  /// The clock's rate as it is, asked for (CLOCK_RATE_GET); the status
  /// then shows it as `clock ID rate HZ`.
  case rateGet(id: UInt32)
  /// A performance domain's level: set (PERFORMANCE_LEVEL_SET, then read back), or as it is (PERFORMANCE_LEVEL_GET), in the
  /// platform's units.
  case level(domain: UInt32, level: UInt32)
  case levelGet(domain: UInt32)
  /// A performance domain's limits (PERFORMANCE_LIMITS_GET): asked for, and as answered.
  case limitsGet(domain: UInt32)
  case limits(domain: UInt32, lowest: UInt32, highest: UInt32)

  public init?(_ line: String) {
    let words = line.utf8.split(separator: 0x20).map { Array($0) }
    if words.count >= 3, words[0] == Array("perf".utf8), let d = Self.number(words[1]) {
      if words.count == 3, words[2] == Array("level".utf8) {
        self = .levelGet(domain: d)
        return
      }
      if words.count == 3, words[2] == Array("limits".utf8) {
        self = .limitsGet(domain: d)
        return
      }
      if words.count == 4, words[2] == Array("level".utf8), let v = Self.number(words[3]) {
        self = .level(domain: d, level: v)
        return
      }
      return nil
    }
    if words.count == 3, words[0] == Array("clock".utf8), words[2] == Array("rate".utf8), let id = Self.number(words[1]) {
      self = .rateGet(id: id)
      return
    }
    if words.count == 4, words[0] == Array("clock".utf8), words[2] == Array("rate".utf8),
      let id = Self.number(words[1]), let hz = Self.number(words[3])
    {
      self = .rate(id: id, hertz: hz)
      return
    }
    guard words.count == 3, let n = Self.number(words[1]) else { return nil }
    let on: Bool
    if words[2] == Array("on".utf8) {
      on = true
    } else if words[2] == Array("off".utf8) {
      on = false
    } else {
      return nil
    }
    if words[0] == Array("power".utf8) {
      self = .power(domain: n, on: on)
    } else if words[0] == Array("clock".utf8) {
      self = .clock(id: n, on: on)
    } else {
      return nil
    }
  }

  /// The protocol, message and payload it sends.
  public var request: (proto: ProtocolID, message: UInt32, payload: [UInt32]) {
    switch self {
    case .power(let domain, let on): (.power, Message.powerStateSet, [0, domain, on ? PowerState.on : PowerState.off])
    case .clock(let id, let on): (.clock, Message.clockConfigSet, [id, on ? 1 : 0])
    // Flags 0: synchronous, rounded down.
    case .rate(let id, let hz): (.clock, Message.clockRateSet, [0, id, hz, 0])
    case .rateGet(let id): (.clock, Message.clockRateGet, [id])
    case .level(let d, let v): (.performance, Message.performanceLevelSet, [d, v])
    case .levelGet(let d): (.performance, Message.performanceLevelGet, [d])
    case .limitsGet(let d), .limits(let d, _, _): (.performance, Message.performanceLimitsGet, [d])
    }
  }

  /// A line for the status: `power 21 on`.
  public var description: String {
    switch self {
    case .power(let domain, let on): "power \(domain) \(on ? "on" : "off")"
    case .clock(let id, let on): "clock \(id) \(on ? "on" : "off")"
    case .rate(let id, let hz): "clock \(id) rate \(hz)"
    case .rateGet(let id): "clock \(id) rate"
    case .level(let d, let v): "perf \(d) level \(v)"
    case .levelGet(let d): "perf \(d) level"
    case .limitsGet(let d): "perf \(d) limits"
    case .limits(let d, let lo, let hi): "perf \(d) limits \(lo) \(hi)"
    }
  }

  /// Whose state it sets: a power domain, or a clock's gate or its rate.
  public func sameSubject(_ other: Command) -> Bool {
    switch (self, other) {
    case (.power(let a, _), .power(let b, _)), (.clock(let a, _), .clock(let b, _)), (.rate(let a, _), .rate(let b, _)),
      (.rateGet(let a), .rateGet(let b)), (.rateGet(let a), .rate(let b, _)), (.rate(let a, _), .rateGet(let b)),
      (.level(let a, _), .level(let b, _)), (.levelGet(let a), .levelGet(let b)), (.level(let a, _), .levelGet(let b)),
      (.levelGet(let a), .level(let b, _)), (.limits(let a, _, _), .limits(let b, _, _)), (.limitsGet(let a), .limitsGet(let b)),
      (.limits(let a, _, _), .limitsGet(let b)), (.limitsGet(let a), .limits(let b, _, _)):
      a == b
    default: false
    }
  }

  static func number(_ digits: [UInt8]) -> UInt32? {
    var d = digits[...], radix: UInt32 = 10
    if d.count > 2, d.starts(with: Array("0x".utf8)) {
      d = d.dropFirst(2)
      radix = 16
    }
    guard !d.isEmpty else { return nil }
    var v: UInt32 = 0
    for c in d {
      let digit: UInt32
      switch c {
      case 0x30...0x39: digit = UInt32(c - 0x30)
      case 0x61...0x66 where radix == 16: digit = UInt32(c - 0x57)
      case 0x41...0x46 where radix == 16: digit = UInt32(c - 0x37)
      default: return nil
      }
      let (m, o1) = v.multipliedReportingOverflow(by: radix)
      let (s, o2) = m.addingReportingOverflow(digit)
      guard !o1, !o2 else { return nil }
      v = s
    }
    return v
  }
}
