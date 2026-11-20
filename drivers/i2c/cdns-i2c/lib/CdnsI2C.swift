// SPDX-License-Identifier: BSD-3-Clause

// The CIX Sky1's I2C controller (cdns-i2c(3)), Cadence's r1p14, as
// bin/cdns-i2c drives it: its registers, the divider that makes the bus
// rate from the input clock's, the messages of a transfer and how a long
// read keeps its counter ahead of the bus, and what each failure the
// controller reports means to the caller. Registers and sequences are the
// hardware's (chinese-wall's sky1-peripherals 02).

public enum CdnsI2C {
  public static let cr = 0x00, sr = 0x04, address = 0x08, data = 0x0C, isr = 0x10, transferSize = 0x14
  public static let timeOut = 0x1C, imr = 0x20, ier = 0x24, idr = 0x28
  /// The registers' extent.
  public static let size = 0x30
  /// Each direction's FIFO, in bytes.
  public static let fifoDepth = 16

  public enum Control {
    public static let receive: UInt32 = 1 << 0, host: UInt32 = 1 << 1, sevenBit: UInt32 = 1 << 2
    public static let ack: UInt32 = 1 << 3, hold: UInt32 = 1 << 4, clearFIFO: UInt32 = 1 << 6
    /// The bus's idle value, over the dividers.
    public static let idle: UInt32 = ack | sevenBit | host
  }

  public enum Status {
    public static let rxData: UInt32 = 1 << 5, busActive: UInt32 = 1 << 8
  }

  public enum Interrupt {
    public static let complete: UInt32 = 1 << 0, data: UInt32 = 1 << 1, nack: UInt32 = 1 << 2
    public static let timeout: UInt32 = 1 << 3, rxOverflow: UInt32 = 1 << 5, txOverflow: UInt32 = 1 << 6
    public static let rxUnderflow: UInt32 = 1 << 7, arbitrationLost: UInt32 = 1 << 9
    /// Every interrupt, to mask.
    public static let all: UInt32 = 0x2FF
    /// What ends a message badly.
    public static let failures = nack | rxOverflow | txOverflow | rxUnderflow | arbitrationLost
  }

  /// `TIME_OUT`'s value: the longest bus hold, which keeps the bogus read
  /// after the timeout from happening while it is masked.
  public static let longestHold: UInt32 = 0xFF

  /// The bus rate's dividers: `DIV_A` and `DIV_B` as CR holds them, and
  /// the rate they make.
  public struct Dividers: Equatable, Sendable {
    public var a: UInt32, b: UInt32, rate: UInt32
    public init(a: UInt32, b: UInt32, rate: UInt32) {
      self.a = a
      self.b = b
      self.rate = rate
    }
    /// CR's bits for them.
    public var bits: UInt32 { b << 8 | a << 14 }
  }

  /// The dividers for `target` Hz from an input clock of `input` Hz: the
  /// rate F / (22 (A + 1) (B + 1)) nearest `target` without going over it,
  /// or nil where none of A in 0...3 and B + 1 in 1...64 gets there.
  public static func dividers(input: UInt32, target: UInt32) -> Dividers? {
    guard input > 0, target > 0 else { return nil }
    let f = UInt64(input), t = UInt64(target)
    guard f / (22 * t) != 0, f / (22 * t) <= 256 else { return nil }
    var best: Dividers?
    for a in UInt64(0)..<4 {
      let per = 22 * t * (a + 1)
      let b1 = (f + per - 1) / per
      guard (1...64).contains(b1) else { continue }
      let rate = UInt32(f / (22 * (a + 1) * b1))
      if best == nil || rate > best!.rate { best = Dividers(a: UInt32(a), b: UInt32(b1 - 1), rate: rate) }
    }
    return best
  }

  /// CR in host mode at idle, with `dividers`.
  public static func base(_ dividers: Dividers) -> UInt32 { Control.idle | dividers.bits }

  /// The largest receive chunk from what XFER_SIZE read back after 0xFF:
  /// three short of it, as the re-arm of a long read needs.
  public static func largestChunk(readBack: UInt32) -> Int { max(Int(readBack & 0xFF) - 3, 0) }

  /// One message of a transfer: a direction to the address.
  public struct Message: Equatable, Sendable {
    public var read: Bool
    public var length: Int
    /// The transfer's last: ended with a STOP, not held for a repeated START.
    public var last: Bool
    /// A read made only to see the address answer; its byte dropped.
    public var discard: Bool

    public init(read: Bool, length: Int, last: Bool, discard: Bool) {
      self.read = read
      self.length = length
      self.last = last
      self.discard = discard
    }

    /// HOLD set before the address is written: the message is longer than
    /// the FIFO, or another follows.
    public var holdAtStart: Bool { length > CdnsI2C.fifoDepth || !last }

    /// A read the FIFO holds whole, whose HOLD is cleared right after the
    /// address is written, before the counter can run out.
    public var releasesAtStart: Bool { read && last && length <= CdnsI2C.fifoDepth }
  }

  /// The messages of a transfer to one address: `write` sent, then after
  /// a repeated START `read` bytes received. An address alone (a probe,
  /// which the controller can't send as a message of no bytes) is one
  /// byte read and dropped.
  public static func messages(write: Int, read: Int) -> [Message] {
    var out: [Message] = []
    if write > 0 { out.append(Message(read: false, length: write, last: read == 0, discard: false)) }
    if read > 0 { out.append(Message(read: true, length: read, last: true, discard: false)) }
    if out.isEmpty { out.append(Message(read: true, length: 1, last: true, discard: true)) }
    return out
  }

  /// A write's next bytes: how many of `remaining` fit the FIFO, which
  /// `queued` bytes of it XFER_SIZE still counts.
  public static func pushable(remaining: Int, queued: Int) -> Int { max(min(remaining, fifoDepth - queued), 0) }

  /// The first XFER_SIZE of a read of `length`.
  public static func firstChunk(length: Int, largest: Int) -> Int { min(length, largest) }

  /// Whether a long read must stop draining and re-arm the counter: it
  /// is armed for less than the message, and exactly one more than the
  /// FIFO's depth of the armed bytes are still to come.
  public static func needsRearm(total: Int, drained: Int, armed: Int) -> Bool {
    armed < total && armed - drained == fifoDepth + 1
  }

  /// The XFER_SIZE to write then (once it has fallen to the one byte the
  /// full FIFO leaves it), and the bytes the message is armed for after.
  public static func rearm(total: Int, drained: Int, largest: Int) -> (chunk: Int, armed: Int) {
    let beyond = total - drained - fifoDepth
    let chunk = min(beyond, largest)
    return (chunk, drained + fifoDepth + chunk)
  }

  /// Whether a read of `length` can be made with a counter of `largest`:
  /// whole in one chunk, or with room for the re-arm.
  public static func readFits(length: Int, largest: Int) -> Bool {
    length <= largest || largest >= fifoDepth + 2
  }

  /// Whether HOLD is cleared now, in a last read, `expected` bytes from
  /// its end: the controller then ends with a NAK and a STOP.
  public static func releasesHold(last: Bool, expected: Int) -> Bool { last && expected <= fifoDepth }

  /// What went wrong, as the caller is told.
  public enum Failure: Equatable, Sendable {
    case noDevice, nak, busError, arbitrationLost
  }

  /// The failure the interrupt bits of ISR mean, if any. `moved` is how
  /// many bytes of the message the target took or gave before it: a NACK
  /// with none is the address's, so nothing answering it.
  public static func failure(isr: UInt32, moved: Int) -> Failure? {
    if isr & Interrupt.arbitrationLost != 0 { return .arbitrationLost }
    if isr & Interrupt.nack != 0 { return moved == 0 ? .noDevice : .nak }
    if isr & (Interrupt.rxOverflow | Interrupt.txOverflow | Interrupt.rxUnderflow) != 0 { return .busError }
    return nil
  }

  /// The input clock's rate in Hz as `scmi`'s status line says it:
  /// `clock <id> rate <hz>`; nil where there is none or it is 0.
  public static func clockRate(status: String, id: UInt32) -> UInt32? {
    for line in status.utf8.split(separator: 0x0A) {
      let w = line.split(separator: 0x20).map { Array($0) }
      guard w.count == 4, w[0] == Array("clock".utf8), w[2] == Array("rate".utf8),
        number(w[1]) == UInt64(id), let hz = number(w[3]), hz > 0, hz <= UInt64(UInt32.max)
      else { continue }
      return UInt32(hz)
    }
    return nil
  }

  /// The `clock-frequency` line of devmgr's properties (`name value`),
  /// decimal or 0x hexadecimal, capped at the 400 kHz of fast mode; 100 kHz
  /// where there is none.
  public static func busRate(properties: String) -> UInt32 {
    for line in properties.utf8.split(separator: 0x0A) {
      let w = line.split(separator: 0x20).map { Array($0) }
      guard w.count >= 2, w[0] == Array("clock-frequency".utf8), let v = number(w[1]), v > 0 else { continue }
      return UInt32(min(v, 400_000))
    }
    return 100_000
  }

  static func number(_ digits: [UInt8]) -> UInt64? {
    var d = digits[...], radix: UInt64 = 10
    if d.count > 2, d.starts(with: Array("0x".utf8)) {
      d = d.dropFirst(2)
      radix = 16
    }
    guard !d.isEmpty, d.count <= 16 else { return nil }
    var v: UInt64 = 0
    for c in d {
      let digit: UInt64
      switch c {
      case 0x30...0x39: digit = UInt64(c - 0x30)
      case 0x61...0x66 where radix == 16: digit = UInt64(c - 0x57)
      case 0x41...0x46 where radix == 16: digit = UInt64(c - 0x37)
      default: return nil
      }
      let (m, o1) = v.multipliedReportingOverflow(by: radix)
      let (s, o2) = m.addingReportingOverflow(digit)
      guard !o1, !o2 else { return nil }
      v = s
    }
    return v
  }

  /// The first number in a text's first line, for CLKT's id in
  /// `/dev/acpi/clocks` (`<id> <name>`, the name empty here).
  public static func firstNumber(_ text: String) -> UInt32? {
    for line in text.utf8.split(separator: 0x0A) {
      guard let w = line.split(separator: 0x20).first, let v = number(Array(w)), v <= UInt64(UInt32.max) else { continue }
      return UInt32(v)
    }
    return nil
  }
}
