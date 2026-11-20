// SPDX-License-Identifier: BSD-3-Clause

// A CPU's desired-performance register (ACPI's CPPC) as power(8) asks bin/scmi
// to write it (D167): devmgr's list of the registers, the `cppc` line in
// ctl, and the check that a write lands only in a listed register inside a
// page the agent was granted.

/// A CPU's desired-performance register that devmgr's `cpus` lists, as
/// devmgr hands it to the agent: `--cppc=0x<address>/<bits>`.
public struct CPPCRegister: Equatable, Sendable {
  public var address: UInt64
  public var width: UInt8

  public init(address: UInt64, width: UInt8) {
    self.address = address
    self.width = width
  }

  /// The argument devmgr passes for the register.
  public var argument: String { "--cppc=0x" + String(address, radix: 16) + "/\(width)" }

  /// `argument` read back; nil for any other text.
  public init?(argument text: String) {
    let b = Array(text.utf8)
    let prefix = Array("--cppc=0x".utf8)
    guard b.count > prefix.count, b.starts(with: prefix), let slash = b.firstIndex(of: UInt8(ascii: "/")),
      slash > prefix.count, let a = UInt64(String(decoding: b[prefix.count..<slash], as: UTF8.self), radix: 16),
      let w = UInt8(String(decoding: b[(slash + 1)...], as: UTF8.self)), [8, 16, 32, 64].contains(w)
    else { return nil }
    self.init(address: a, width: w)
  }
}

/// A line written to bin/scmi's ctl that writes a CPU's desired-performance
/// register for power(8): `cppc ADDRESS VALUE WIDTH`, WIDTH in bits (8, 16,
/// 32 or 64), numbers in decimal or `0x` hexadecimal.
public struct CPPCWrite: Equatable, Sendable {
  public var address: UInt64
  public var value: UInt64
  public var width: UInt8

  public init(address: UInt64, value: UInt64, width: UInt8) {
    self.address = address
    self.value = value
    self.width = width
  }

  public init?(_ line: String) {
    let w = line.utf8.split(separator: 0x20).map { Array($0) }
    guard w.count == 4, w[0] == Array("cppc".utf8), let a = Self.number(w[1]), let v = Self.number(w[2]),
      let n = Self.number(w[3]), [8, 16, 32, 64].contains(n)
    else { return nil }
    self.init(address: a, value: v, width: UInt8(n))
  }

  /// The line, as the status shows it and power writes it.
  public var description: String { "cppc 0x" + String(address, radix: 16) + " \(value) \(width)" }

  /// Whether a write is allowed, or why not.
  public enum Verdict: Equatable, Sendable {
    /// The window (an index into the ranges given) and the offset in it.
    case write(window: Int, offset: Int)
    /// Not a register devmgr listed, or listed at another width, or not
    /// aligned to its width.
    case notListed
    /// The value doesn't fit the width.
    case tooWide
    /// Listed, but in no page the agent was granted.
    case notGranted
  }

  /// `registers` is what devmgr listed; `windows` is each granted range's
  /// physical base and the bytes mapped from it (to its page's end). The
  /// register must be listed at this width and lie wholly in one window.
  public func verdict(registers: [CPPCRegister], windows: [(base: UInt64, size: UInt64)]) -> Verdict {
    guard registers.contains(where: { $0.address == address && $0.width == width }) else { return .notListed }
    guard width == 64 || value >> UInt64(width) == 0 else { return .tooWide }
    let bytes = UInt64(width / 8)
    guard address % bytes == 0 else { return .notListed }
    for (i, w) in windows.enumerated() where address >= w.base && address - w.base <= w.size {
      if w.size - (address - w.base) >= bytes { return .write(window: i, offset: Int(address - w.base)) }
    }
    return .notGranted
  }

  static func number(_ digits: [UInt8]) -> UInt64? {
    var d = digits[...], radix: UInt64 = 10
    if d.count > 2, d.starts(with: Array("0x".utf8)) {
      d = d.dropFirst(2)
      radix = 16
    }
    guard !d.isEmpty else { return nil }
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
}
