// SPDX-License-Identifier: BSD-3-Clause

// The CIX Sky1's DisplayPort transmitter (CIXH502F, a Trilinear DPTX
// core behind each Linlon-D6 engine; chinese-wall's sky1-dp-tx spec):
// the registers bin/dptx reads and its AUX channel, over which the sink's
// DPCD and, through I2C-over-AUX, its EDID come (D146), and link training
// (DisplayPort's clock recovery and equalisation), the drive levels the
// sink asks for given to it and to the PHY. The PHY's rate is PHY.swift's,
// a stream's registers Stream.swift's. Nothing here resets or powers
// anything.

/// Registers, as offsets in the core's window (its first `_CRS` range).
public enum DPTXRegisters {
  public static let windowSize = 0x4000

  public static let linkBandwidth = 0x000  // LINK_BW_SET: the DPCD's rate code
  public static let laneCount = 0x004
  public static let enhancedFraming = 0x008
  public static let transmitterEnable = 0x080
  public static let sourceEnable = 0x094
  public static let coreRevision = 0x0FC

  public static let auxCommand = 0x100
  public static let auxWriteFIFO = 0x104
  public static let auxAddress = 0x108
  public static let auxClockDivider = 0x10C
  public static let hpdInputState = 0x128
  public static let auxReplyData = 0x134
  public static let auxReplyCode = 0x138
  public static let interruptCause = 0x140  // clear on read (presumed)
  public static let interruptMask = 0x144   // 1 = masked
  public static let auxReplyDataCount = 0x148
  public static let auxStatus = 0x14C
  public static let phyStatus = 0x280

  // INTERRUPT_CAUSE / MASK bits.
  public static let hpdEvent: UInt32 = 1 << 0
  public static let hpdIRQ: UInt32 = 1 << 1
  /// HPD's level change and the sink's short pulse unmasked, nothing else.
  public static let hpdOnlyMask: UInt32 = 0x3F & ~(hpdEvent | hpdIRQ)

  // AUX_STATUS bits.
  public static let replyReceived: UInt32 = 1 << 0
  public static let replyInProgress: UInt32 = 1 << 1
  public static let requestInProgress: UInt32 = 1 << 2
  public static let replyError: UInt32 = 1 << 3
}

/// An AUX request (DisplayPort's): its command, address and length.
public struct AUXRequest: Equatable, Sendable {
  public enum Kind: UInt32, Sendable {
    case nativeWrite = 0x8
    case nativeRead = 0x9
    case i2cWrite = 0x0
    case i2cRead = 0x1
  }

  public var kind: Kind
  /// I2C's middle of transaction: no stop after it.
  public var mot: Bool
  /// The DPCD address, or the I2C slave's 7-bit address.
  public var address: UInt32
  /// Bytes written (a write's), or the count read.
  public var data: [UInt8]
  public var count: Int

  public static func read(dpcd address: UInt32, count: Int) -> AUXRequest {
    AUXRequest(kind: .nativeRead, mot: false, address: address, data: [], count: count)
  }

  public static func i2cWrite(_ slave: UInt32, _ data: [UInt8], mot: Bool) -> AUXRequest {
    AUXRequest(kind: .i2cWrite, mot: mot, address: slave, data: data, count: data.count)
  }

  public static func i2cRead(_ slave: UInt32, count: Int, mot: Bool) -> AUXRequest {
    AUXRequest(kind: .i2cRead, mot: mot, address: slave, data: [], count: count)
  }

  public var isI2C: Bool { kind == .i2cRead || kind == .i2cWrite }
  public var isRead: Bool { kind == .nativeRead || kind == .i2cRead }

  /// AUX_COMMAND's value: the request in [11:8] (MOT its bit 2), and the
  /// byte count less one in [3:0], or [12] for an address-only one.
  public var command: UInt32 {
    let request = kind.rawValue | (isI2C && mot ? 0x4 : 0)
    return count == 0 ? request << 8 | 1 << 12 : request << 8 | UInt32(count - 1)
  }
}

/// A reply's command field (AUX_REPLY_CODE): native in [1:0], I2C in
/// [3:2], each 0 ACK, 1 NACK, 2 DEFER.
public enum AUXReply: Equatable, Sendable {
  case ack
  case nack
  case deferred

  public init(code: UInt32, i2c: Bool) {
    let native = code & 3, i2cCode = code >> 2 & 3
    let worst = i2c ? max(native, i2cCode) : native
    self = worst == 0 ? .ack : worst == 1 ? .nack : .deferred
  }
}

public enum AUXError: Error, Equatable, Sendable {
  /// HPD is low: no sink to answer.
  case noSink
  case busy
  case timedOut
  case nack
  /// DEFERred more often than DisplayPort allows.
  case deferred
  /// A read's reply held other than the bytes asked for.
  case short

  public var name: String {
    switch self {
    case .noSink: "no sink"
    case .busy: "busy"
    case .timedOut: "timed out"
    case .nack: "NACK"
    case .deferred: "deferred too often"
    case .short: "short reply"
    }
  }
}

/// Something that carries one AUX request of at most 16 bytes: the core,
/// or a test's sink.
public protocol AUXChannel {
  mutating func transfer(_ r: AUXRequest) throws(AUXError) -> (AUXReply, [UInt8])
}

extension AUXChannel {
  /// One request, DEFER retried (at least 7 times, as DisplayPort asks;
  /// 32 here), NACK refused.
  public mutating func request(_ r: AUXRequest) throws(AUXError) -> [UInt8] {
    for _ in 0..<32 {
      let (reply, bytes) = try transfer(r)
      switch reply {
      case .ack:
        guard !r.isRead || bytes.count == r.count else { throw .short }
        return bytes
      case .nack: throw .nack
      case .deferred: continue
      }
    }
    throw .deferred
  }

  /// `count` bytes of the DPCD from `address`, 16 a request.
  public mutating func readDPCD(_ address: UInt32, count: Int) throws(AUXError) -> [UInt8] {
    var out: [UInt8] = []
    while out.count < count {
      out += try request(.read(dpcd: address + UInt32(out.count), count: min(16, count - out.count)))
    }
    return out
  }

  /// The EDID over I2C-over-AUX (VESA E-DDC): block 0, then as many
  /// extensions as it counts (up to `maxBlocks` in all), each segment of
  /// two blocks chosen through the segment pointer, 0x30.
  public mutating func readEDID(maxBlocks: Int = 4) throws(AUXError) -> [UInt8] {
    var edid = try readEDIDBlock(0)
    let blocks = min(maxBlocks, 1 + Int(edid.count == 128 ? edid[126] : 0))
    for b in 1..<max(1, blocks) { edid += try readEDIDBlock(b) }
    return edid
  }

  mutating func readEDIDBlock(_ block: Int) throws(AUXError) -> [UInt8] {
    defer { _ = try? request(.i2cRead(EDIDBus.slave, count: 0, mot: false)) }  // stop
    if block >= 2 { _ = try request(.i2cWrite(EDIDBus.segment, [UInt8(block / 2)], mot: true)) }
    _ = try request(.i2cWrite(EDIDBus.slave, [UInt8(block % 2 * 128)], mot: true))
    var out: [UInt8] = []
    while out.count < 128 { out += try request(.i2cRead(EDIDBus.slave, count: 16, mot: true)) }
    return out
  }
}

/// E-DDC's I2C addresses.
public enum EDIDBus {
  public static let slave: UInt32 = 0x50
  public static let segment: UInt32 = 0x30
}

/// What the sink's DPCD says, from its receiver capabilities (0x000-0x00F)
/// and the sink count (0x200).
public struct SinkCapabilities: Equatable, Sendable {
  public var revision: UInt8
  public var maxRate: UInt8
  public var maxLanes: Int
  public var enhancedFraming: Bool
  /// A branch device, such as a DisplayPort-to-HDMI converter: its
  /// downstream port present (0x005 bit 0).
  public var branch: Bool

  public init(_ caps: [UInt8]) {
    revision = caps.count > 0 ? caps[0] : 0
    maxRate = caps.count > 1 ? caps[1] : 0
    maxLanes = caps.count > 2 ? Int(caps[2] & 0x1F) : 0
    enhancedFraming = caps.count > 2 && caps[2] & 0x80 != 0
    branch = caps.count > 5 && caps[5] & 1 != 0
  }

  /// `1.4 HBR2 x4, branch`.
  public var text: String {
    "\(revision >> 4).\(revision & 0xF) \(rateName(maxRate)) x\(maxLanes)" + (enhancedFraming ? ", enhanced framing" : "")
      + (branch ? ", branch" : "")
  }
}

/// The sink count in DPCD 0x200: bits 5:0 and bit 7 above them.
public func sinkCount(_ byte: UInt8) -> Int { Int(byte & 0x3F) | Int(byte & 0x80) >> 1 }

/// A DPCD link-rate code's name: `HBR2`, or the code in hex.
public func rateName(_ code: UInt8) -> String {
  switch code {
  case 0x06: "RBR"
  case 0x0A: "HBR"
  case 0x14: "HBR2"
  case 0x1E: "HBR3"
  default: "rate 0x" + String(decoding: [hexDigit(code >> 4), hexDigit(code & 0xF)], as: UTF8.self)
  }
}

/// A nibble's lower-case hex digit.
public func hexDigit(_ v: UInt8) -> UInt8 { v < 10 ? 0x30 + v : 0x57 + v }

// MARK: Link training (D146)

extension DPTXRegisters {
  public static let trainingPattern = 0x00C
  public static let disableScrambling = 0x014
  public static let downspread = 0x018
  public static let softReset = 0x090
  public static let forceScramblerReset = 0x0C0
  /// Source 0's main-stream block.
  public static let videoStreamEnable = 0x800
  public static let secondaryStreamEnable = 0x804
}

extension AUXRequest {
  public static func write(dpcd address: UInt32, _ data: [UInt8]) -> AUXRequest {
    AUXRequest(kind: .nativeWrite, mot: false, address: address, data: data, count: data.count)
  }
}

/// The sink's link status, DPCD 0x202-0x207, for its first `lanes` lanes.
public struct LaneStatus: Equatable, Sendable {
  public var bytes: [UInt8]
  public var lanes: Int

  public init(_ bytes: [UInt8], lanes: Int) {
    self.bytes = bytes
    self.lanes = lanes
  }

  func lane(_ l: Int) -> UInt8 { bytes.count > l / 2 ? bytes[l / 2] >> UInt8(4 * (l % 2)) & 0xF : 0 }

  /// Clock recovery done on every lane.
  public var clockRecovered: Bool { (0..<lanes).allSatisfy { lane($0) & 1 != 0 } }

  /// Equalised, symbols locked and the lanes aligned: the link is up.
  public var trained: Bool {
    clockRecovered && (0..<lanes).allSatisfy { lane($0) & 6 == 6 } && bytes.count > 2 && bytes[2] & 1 != 0
  }

  /// The highest swing and pre-emphasis any lane asks for (0x206-0x207):
  /// applied to every lane, as the vendor's driver does.
  public var requested: (swing: UInt8, preEmphasis: UInt8) {
    var swing: UInt8 = 0, pre: UInt8 = 0
    for l in 0..<lanes where bytes.count > 4 + l / 2 {
      let v = bytes[4 + l / 2] >> UInt8(4 * (l % 2)) & 0xF
      swing = max(swing, v & 3)
      pre = max(pre, v >> 2 & 3)
    }
    return (swing, pre)
  }

  /// `0x77 0x77 0x01` for the bytes 0x202-0x204.
  public var text: String {
    bytes.prefix(3).map { "0x" + String(decoding: [hexDigit($0 >> 4), hexDigit($0 & 0xF)], as: UTF8.self) }
      .joined(separator: " ")
  }
}

/// TRAINING_LANEx_SET (DPCD 0x103-0x106): a lane's swing and
/// pre-emphasis, with the maximum-reached flags.
public func laneSet(swing: UInt8, preEmphasis: UInt8) -> UInt8 {
  swing | (swing == 3 ? 4 : 0) | preEmphasis << 3 | (preEmphasis >= 2 ? 0x20 : 0)
}

/// How a training went.
public struct TrainingResult: Equatable, Sendable {
  public var trained: Bool
  /// `clock recovery` or `equalisation` where it failed.
  public var stage: String
  public var swing: UInt8, preEmphasis: UInt8
  public var tries: Int
  public var status: LaneStatus
}

/// What training needs of the core besides AUX: its training-pattern and
/// scrambler registers, the PHY's drive levels, and a wait.
public protocol TrainingCore: AUXChannel {
  mutating func setPattern(_ pattern: UInt32, scrambled: Bool)
  /// Every lane's swing and pre-emphasis, in the PHY.
  mutating func setDrive(swing: UInt8, preEmphasis: UInt8)
  mutating func wait(microseconds: Int)
}

extension TrainingCore {
  public mutating func setDrive(swing: UInt8, preEmphasis: UInt8) {}

  /// The link status now, for `lanes` lanes.
  public mutating func laneStatus(lanes: Int) throws(AUXError) -> LaneStatus {
    LaneStatus(try readDPCD(0x202, count: 6), lanes: lanes)
  }

  /// Trains the link at `rate` (the DPCD's code) on `lanes` lanes, the
  /// sink's capabilities `caps` (DPCD 0x000-0x00F): DisplayPort's clock
  /// recovery, then equalisation with the best pattern both have, then
  /// the pattern ended. The core's rate, lanes and the PHY's rate are set
  /// already; each step's drive levels go to the sink and the PHY.
  public mutating func train(rate: UInt8, lanes: Int, caps: [UInt8], enhancedFraming: Bool,
                             downspread: Bool) throws(AUXError) -> TrainingResult {
    // The intervals the sink asks for (0x00E): 0 is 100 us for clock
    // recovery and 400 us for equalisation, else 4 ms a step.
    let interval = caps.count > 0xE ? Int(caps[0xE] & 0x7F) : 0
    let crWait = interval == 0 ? 100 : interval * 4000
    let eqWait = interval == 0 ? 400 : interval * 4000

    // The sink awake (D0), then the link's configuration.
    _ = try request(.write(dpcd: 0x600, [1]))
    wait(microseconds: 4000)
    _ = try request(.write(dpcd: 0x107, [downspread ? 0x10 : 0]))
    _ = try request(.write(dpcd: 0x108, [1]))  // 8b/10b
    _ = try request(.write(dpcd: 0x100, [rate, UInt8(lanes) | (enhancedFraming ? 0x80 : 0)]))

    var swing: UInt8 = 0, pre: UInt8 = 0, tries = 0, sameSwing = 0
    func set(_ pattern: UInt8) -> [UInt8] {
      [pattern] + [UInt8](repeating: laneSet(swing: swing, preEmphasis: pre), count: lanes)
    }
    func end(_ ok: Bool, _ stage: String, _ s: LaneStatus) -> TrainingResult {
      TrainingResult(trained: ok, stage: stage, swing: swing, preEmphasis: pre, tries: tries, status: s)
    }

    // Clock recovery: TPS1, unscrambled.
    setPattern(1, scrambled: false)
    var status = LaneStatus([], lanes: lanes)
    var recovered = false
    while tries < 32 {
      tries += 1
      setDrive(swing: swing, preEmphasis: pre)
      _ = try request(.write(dpcd: 0x102, set(0x21)))
      wait(microseconds: crWait)
      status = try laneStatus(lanes: lanes)
      if status.clockRecovered {
        recovered = true
        break
      }
      let ask = status.requested
      if swing == 3 { break }
      sameSwing = ask.swing == swing ? sameSwing + 1 : 0
      if sameSwing >= 5 { break }
      (swing, pre) = (ask.swing, min(ask.preEmphasis, 3 - ask.swing))
    }
    guard recovered else {
      try finish()
      return end(false, "clock recovery", status)
    }

    // Equalisation: TPS4 (scrambled) if the sink has it, else TPS3, else TPS2.
    let tps4 = caps.count > 3 && caps[3] & 0x80 != 0, tps3 = caps.count > 2 && caps[2] & 0x40 != 0
    let core: UInt32 = tps4 ? 4 : tps3 ? 3 : 2
    setPattern(core, scrambled: tps4)
    for _ in 0..<5 {
      tries += 1
      setDrive(swing: swing, preEmphasis: pre)
      _ = try request(.write(dpcd: 0x102, set(tps4 ? 0x07 : tps3 ? 0x23 : 0x22)))
      wait(microseconds: eqWait)
      status = try laneStatus(lanes: lanes)
      if status.trained { break }
      if !status.clockRecovered { break }
      let ask = status.requested
      (swing, pre) = (ask.swing, min(ask.preEmphasis, 3 - ask.swing))
    }
    try finish()
    return end(status.trained, status.trained ? "" : "equalisation", status)
  }

  /// Training ended, at once: the sink's pattern off, then the core's.
  public mutating func finish() throws(AUXError) {
    _ = try request(.write(dpcd: 0x102, [0]))
    setPattern(0, scrambled: true)
  }
}
