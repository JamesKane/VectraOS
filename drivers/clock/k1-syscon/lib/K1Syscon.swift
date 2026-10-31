// SPDX-License-Identifier: BSD-3-Clause

// The SpacemiT K1's clock and reset units, the APBC (the APB peripherals'
// clocks, at 0xd4015000) and the APMU (the application subsystem's, at
// 0xd4282800), as bin/k1-syscon drives them: each clock's gate and each
// reset's bits, by the ids dt-bindings/clock/spacemit,k1-syscon.h gives
// them, which a consumer's `clocks` and `resets` cells name. A gate is on
// with every bit of its mask set and off with them clear; a clock with
// no gate (a fixed factor, a mux or a divider alone) is always on. A
// reset is asserted by writing its assert bits into its bits and
// released by writing its deassert bits; the APBC's are mostly a reset
// bit, the APMU's mostly an active-low release. The APMU also holds each
// Ethernet MAC's control register and delay lines, which its node's
// `spacemit,apmu` names by their offset: the MAC's interface (RGMII or
// RMII) and the delays its RGMII clocks are given, set by `emac`. That
// register is also the MAC's clock gate and reset, so the unit's driver
// writes it, one command at a time. Registers and masks are the
// hardware's, as Linux's drivers for the K1 list them
// (drivers/clk/spacemit/ccu-k1.c, drivers/reset/reset-spacemit.c,
// drivers/net/ethernet/spacemit/k1_emac.h).

/// A clock: its binding id, name, control register and gate mask (0: no
/// gate).
public struct Gate: Sendable {
  public let id: UInt32
  public let name: String
  public let register: Int
  public let mask: UInt32
  init(_ id: UInt32, _ name: String, _ register: Int, _ mask: UInt32) {
    self.id = id
    self.name = name
    self.register = register
    self.mask = mask
  }
}

/// A reset: its binding id, name, register, and the bits that assert and
/// release it.
public struct Reset: Sendable {
  public let id: UInt32
  public let name: String
  public let register: Int
  public let assert: UInt32
  public let deassert: UInt32
  init(_ id: UInt32, _ name: String, _ register: Int, assert: UInt32, deassert: UInt32) {
    self.id = id
    self.name = name
    self.register = register
    self.assert = assert
    self.deassert = deassert
  }
}

/// A unit, by its node's `compatible`.
public enum SysconUnit: Sendable {
  case apbc, apmu

  public init?(compatibles: [[UInt8]]) {
    for c in compatibles {
      if c == Array("spacemit,k1-syscon-apbc".utf8) { self = .apbc; return }
      if c == Array("spacemit,k1-syscon-apmu".utf8) { self = .apmu; return }
    }
    return nil
  }

  public var name: String {
    switch self {
    case .apbc: "apbc"
    case .apmu: "apmu"
    }
  }

  /// Its registers' extent, its node's `reg`.
  public var size: Int {
    switch self {
    case .apbc: 0x1000
    case .apmu: 0x400
    }
  }

  public var clocks: [Gate] {
    switch self {
    case .apbc: Tables.apbcClocks
    case .apmu: Tables.apmuClocks
    }
  }

  public var resets: [Reset] {
    switch self {
    case .apbc: Tables.apbcResets
    case .apmu: Tables.apmuResets
    }
  }

  /// The Ethernet MACs' control registers (APMU_EMAC0_CLK_RES_CTRL and
  /// EMAC1's), each followed by its delay lines.
  public var emacs: [Int] {
    switch self {
    case .apbc: []
    case .apmu: [0x3E4, 0x3EC]
    }
  }
}

/// A line written to bin/k1-syscon's ctl: `clock ID on|off`, `reset ID
/// assert|deassert`, or `emac OFFSET rgmii|rmii TX RX`, a MAC's interface
/// and its RGMII delay lines' codes (0-255, of 15.6 ps); numbers in
/// decimal or 0x hex.
public enum Command: Equatable, Sendable {
  case clock(id: UInt32, on: Bool)
  case reset(id: UInt32, asserted: Bool)
  case emac(offset: Int, rgmii: Bool, tx: UInt32, rx: UInt32)

  public init?(_ line: String) {
    let words = line.utf8.split(separator: 0x20).map { Array($0) }
    if words.count == 5, words[0] == Array("emac".utf8), let offset = number(words[1]),
      words[2] == Array("rgmii".utf8) || words[2] == Array("rmii".utf8),
      let tx = number(words[3]), let rx = number(words[4]), tx < 256, rx < 256
    {
      self = .emac(offset: Int(offset), rgmii: words[2] == Array("rgmii".utf8), tx: tx, rx: rx)
      return
    }
    guard words.count == 3, let n = number(words[1]) else { return nil }
    switch (words[0], words[2]) {
    case (Array("clock".utf8), Array("on".utf8)): self = .clock(id: n, on: true)
    case (Array("clock".utf8), Array("off".utf8)): self = .clock(id: n, on: false)
    case (Array("reset".utf8), Array("assert".utf8)): self = .reset(id: n, asserted: true)
    case (Array("reset".utf8), Array("deassert".utf8)): self = .reset(id: n, asserted: false)
    default: return nil
    }
  }

  public var description: String {
    switch self {
    case .clock(let id, let on): "clock \(id) \(on ? "on" : "off")"
    case .reset(let id, let asserted): "reset \(id) \(asserted ? "assert" : "deassert")"
    case .emac(let offset, let rgmii, let tx, let rx): "emac 0x\(String(offset, radix: 16)) \(rgmii ? "rgmii" : "rmii") \(tx) \(rx)"
    }
  }
}

/// What a command writes: the bits of `register` under `mask` become
/// `value` (no write where `mask` is 0).
public struct Update: Equatable, Sendable {
  public var register: Int
  public var mask: UInt32
  public var value: UInt32
  public init(register: Int, mask: UInt32, value: UInt32) {
    self.register = register
    self.mask = mask
    self.value = value
  }
}

/// Why a command can't be done.
public enum SysconError: Error, Equatable, Sendable {
  /// The unit has no clock, reset or MAC by that id or offset.
  case noSuch
  /// A clock with no gate can't be turned off.
  case ungated

  public var description: String {
    switch self {
    case .noSuch: "no such id"
    case .ungated: "no gate"
    }
  }
}

extension SysconUnit {
  /// The writes `c` makes, in order.
  public func updates(_ c: Command) throws(SysconError) -> [Update] {
    switch c {
    case .clock(let id, let on):
      guard let g = clocks.first(where: { $0.id == id }) else { throw .noSuch }
      if g.mask == 0 {
        guard on else { throw .ungated }
        return []
      }
      return [Update(register: g.register, mask: g.mask, value: on ? g.mask : 0)]
    case .reset(let id, let asserted):
      guard let r = resets.first(where: { $0.id == id }) else { throw .noSuch }
      return [Update(register: r.register, mask: r.assert | r.deassert, value: asserted ? r.assert : r.deassert)]
    case .emac(let offset, let rgmii, let tx, let rx):
      guard emacs.contains(offset) else { throw .noSuch }
      // The interface, its reference and transmit clocks from the PHY,
      // and the MAC's AXI transactions under one id, as Linux sets them;
      // then each delay line on, in 15.6 ps steps, for RGMII.
      let control = Update(register: offset, mask: EMAC.interfaceMask,
                           value: (rgmii ? EMAC.rgmii : 0) | EMAC.axiSingleID)
      let delays = Update(register: offset + 4, mask: EMAC.delayMask,
                          value: rgmii ? EMAC.rxDelayOn | rx << 8 | EMAC.txDelayOn | tx << 24 : 0)
      return [control, delays]
    }
  }

  /// An Ethernet MAC's control register's bits, and its delay lines'.
  enum EMAC {
    static let rgmii: UInt32 = 1 << 2
    static let referenceClock: UInt32 = 1 << 3
    static let transmitClock: UInt32 = 1 << 8
    static let axiSingleID: UInt32 = 1 << 13
    static let interfaceMask = rgmii | referenceClock | transmitClock | axiSingleID
    static let rxDelayOn: UInt32 = 1
    static let txDelayOn: UInt32 = 1 << 16
    /// Each line's enable, step (bits 4-5, 20-21) and code (8-15, 24-31).
    static let delayMask: UInt32 = 0xFF31_FF31
  }

  /// A line for each clock and reset, read through `load`: `clock 37
  /// emac0_bus on` (`ungated` for one with no gate), `reset 35 emac0
  /// deasserted`; then each MAC's, `emac 0x3e4 rgmii tx 0 rx 0`.
  public func states(_ load: (Int) -> UInt32) -> [String] {
    var out: [String] = []
    for g in clocks {
      let state = g.mask == 0 ? "ungated" : load(g.register) & g.mask == g.mask ? "on" : "off"
      out.append("clock \(g.id) \(g.name) \(state)")
    }
    for r in resets {
      let asserted = load(r.register) & (r.assert | r.deassert) == r.assert
      out.append("reset \(r.id) \(r.name) \(asserted ? "asserted" : "deasserted")")
    }
    for e in emacs {
      let rgmii = load(e) & EMAC.rgmii != 0, delays = load(e + 4)
      out.append("emac 0x\(String(e, radix: 16)) \(rgmii ? "rgmii" : "rmii") tx \(delays >> 24) rx \(delays >> 8 & 0xFF)")
    }
    return out
  }
}

/// A number in decimal or 0x hex.
func number(_ w: [UInt8]) -> UInt32? {
  var digits = w[...], radix: UInt32 = 10
  if w.count > 2, w[0] == 0x30, w[1] | 0x20 == 0x78 {
    digits = w[2...]
    radix = 16
  }
  guard !digits.isEmpty else { return nil }
  var v: UInt64 = 0
  for b in digits {
    let d: UInt32
    switch b {
    case 0x30...0x39: d = UInt32(b - 0x30)
    case 0x61...0x66: d = UInt32(b - 0x61 + 10)
    case 0x41...0x46: d = UInt32(b - 0x41 + 10)
    default: return nil
    }
    guard d < radix else { return nil }
    v = v * UInt64(radix) + UInt64(d)
    guard v <= UInt64(UInt32.max) else { return nil }
  }
  return UInt32(v)
}

/// The units' clocks and resets, in the bindings' order.
enum Tables {
  static let apbcClocks: [Gate] = [
    Gate(0, "uart0", 0x0, 0x2),
    Gate(1, "uart2", 0x4, 0x2),
    Gate(2, "uart3", 0x24, 0x2),
    Gate(3, "uart4", 0x70, 0x2),
    Gate(4, "uart5", 0x74, 0x2),
    Gate(5, "uart6", 0x78, 0x2),
    Gate(6, "uart7", 0x94, 0x2),
    Gate(7, "uart8", 0x98, 0x2),
    Gate(8, "uart9", 0x9c, 0x2),
    Gate(9, "gpio", 0x8, 0x2),
    Gate(10, "pwm0", 0xc, 0x2),
    Gate(11, "pwm1", 0x10, 0x2),
    Gate(12, "pwm2", 0x14, 0x2),
    Gate(13, "pwm3", 0x18, 0x2),
    Gate(14, "pwm4", 0xa8, 0x2),
    Gate(15, "pwm5", 0xac, 0x2),
    Gate(16, "pwm6", 0xb0, 0x2),
    Gate(17, "pwm7", 0xb4, 0x2),
    Gate(18, "pwm8", 0xb8, 0x2),
    Gate(19, "pwm9", 0xbc, 0x2),
    Gate(20, "pwm10", 0xc0, 0x2),
    Gate(21, "pwm11", 0xc4, 0x2),
    Gate(22, "pwm12", 0xc8, 0x2),
    Gate(23, "pwm13", 0xcc, 0x2),
    Gate(24, "pwm14", 0xd0, 0x2),
    Gate(25, "pwm15", 0xd4, 0x2),
    Gate(26, "pwm16", 0xd8, 0x2),
    Gate(27, "pwm17", 0xdc, 0x2),
    Gate(28, "pwm18", 0xe0, 0x2),
    Gate(29, "pwm19", 0xe4, 0x2),
    Gate(30, "ssp3", 0x7c, 0x2),
    Gate(31, "rtc", 0x28, 0x82),
    Gate(32, "twsi0", 0x2c, 0x2),
    Gate(33, "twsi1", 0x30, 0x2),
    Gate(34, "twsi2", 0x38, 0x2),
    Gate(35, "twsi4", 0x40, 0x2),
    Gate(36, "twsi5", 0x4c, 0x2),
    Gate(37, "twsi6", 0x60, 0x2),
    Gate(38, "twsi7", 0x68, 0x2),
    Gate(39, "twsi8", 0x20, 0x3),
    Gate(40, "timers1", 0x34, 0x2),
    Gate(41, "timers2", 0x44, 0x2),
    Gate(42, "aib", 0x3c, 0x2),
    Gate(43, "onewire", 0x48, 0x2),
    Gate(44, "sspa0", 0x80, 0x2),
    Gate(45, "sspa1", 0x84, 0x2),
    Gate(46, "dro", 0x58, 0x2),
    Gate(47, "ir", 0x5c, 0x2),
    Gate(48, "tsen", 0x6c, 0x2),
    Gate(49, "ipc_ap2aud", 0x90, 0x2),
    Gate(50, "can0", 0xa0, 0x2),
    Gate(51, "can0_bus", 0xa0, 0x1),
    Gate(52, "uart0_bus", 0x0, 0x1),
    Gate(53, "uart2_bus", 0x4, 0x1),
    Gate(54, "uart3_bus", 0x24, 0x1),
    Gate(55, "uart4_bus", 0x70, 0x1),
    Gate(56, "uart5_bus", 0x74, 0x1),
    Gate(57, "uart6_bus", 0x78, 0x1),
    Gate(58, "uart7_bus", 0x94, 0x1),
    Gate(59, "uart8_bus", 0x98, 0x1),
    Gate(60, "uart9_bus", 0x9c, 0x1),
    Gate(61, "gpio_bus", 0x8, 0x1),
    Gate(62, "pwm0_bus", 0xc, 0x1),
    Gate(63, "pwm1_bus", 0x10, 0x1),
    Gate(64, "pwm2_bus", 0x14, 0x1),
    Gate(65, "pwm3_bus", 0x18, 0x1),
    Gate(66, "pwm4_bus", 0xa8, 0x1),
    Gate(67, "pwm5_bus", 0xac, 0x1),
    Gate(68, "pwm6_bus", 0xb0, 0x1),
    Gate(69, "pwm7_bus", 0xb4, 0x1),
    Gate(70, "pwm8_bus", 0xb8, 0x1),
    Gate(71, "pwm9_bus", 0xbc, 0x1),
    Gate(72, "pwm10_bus", 0xc0, 0x1),
    Gate(73, "pwm11_bus", 0xc4, 0x1),
    Gate(74, "pwm12_bus", 0xc8, 0x1),
    Gate(75, "pwm13_bus", 0xcc, 0x1),
    Gate(76, "pwm14_bus", 0xd0, 0x1),
    Gate(77, "pwm15_bus", 0xd4, 0x1),
    Gate(78, "pwm16_bus", 0xd8, 0x1),
    Gate(79, "pwm17_bus", 0xdc, 0x1),
    Gate(80, "pwm18_bus", 0xe0, 0x1),
    Gate(81, "pwm19_bus", 0xe4, 0x1),
    Gate(82, "ssp3_bus", 0x7c, 0x1),
    Gate(83, "rtc_bus", 0x28, 0x1),
    Gate(84, "twsi0_bus", 0x2c, 0x1),
    Gate(85, "twsi1_bus", 0x30, 0x1),
    Gate(86, "twsi2_bus", 0x38, 0x1),
    Gate(87, "twsi4_bus", 0x40, 0x1),
    Gate(88, "twsi5_bus", 0x4c, 0x1),
    Gate(89, "twsi6_bus", 0x60, 0x1),
    Gate(90, "twsi7_bus", 0x68, 0x1),
    Gate(91, "twsi8_bus", 0x0, 0x0),
    Gate(92, "timers1_bus", 0x34, 0x1),
    Gate(93, "timers2_bus", 0x44, 0x1),
    Gate(94, "aib_bus", 0x3c, 0x1),
    Gate(95, "onewire_bus", 0x48, 0x1),
    Gate(96, "sspa0_bus", 0x80, 0x1),
    Gate(97, "sspa1_bus", 0x84, 0x1),
    Gate(98, "tsen_bus", 0x6c, 0x1),
    Gate(99, "ipc_ap2aud_bus", 0x90, 0x1),
    Gate(100, "sspa0_i2s_bclk", 0x80, 0x8),
    Gate(101, "sspa1_i2s_bclk", 0x84, 0x8),
  ]
  static let apmuClocks: [Gate] = [
    Gate(0, "cci550", 0x300, 0x0),
    Gate(1, "cpu_c0_hi", 0x38c, 0x0),
    Gate(2, "cpu_c0_core", 0x38c, 0x0),
    Gate(3, "cpu_c0_ace", 0x38c, 0x0),
    Gate(4, "cpu_c0_tcm", 0x38c, 0x0),
    Gate(5, "cpu_c1_hi", 0x390, 0x0),
    Gate(6, "cpu_c1_core", 0x390, 0x0),
    Gate(7, "cpu_c1_ace", 0x390, 0x0),
    Gate(8, "ccic_4x", 0x50, 0x10),
    Gate(9, "ccic1phy", 0x50, 0x20),
    Gate(10, "sdh_axi_aclk", 0x54, 0x8),
    Gate(11, "sdh0", 0x54, 0x10),
    Gate(12, "sdh1", 0x58, 0x10),
    Gate(13, "sdh2", 0xe0, 0x10),
    Gate(14, "usb_p1_aclk", 0x5c, 0x20),
    Gate(15, "usb_axi", 0x5c, 0x2),
    Gate(16, "usb30", 0x5c, 0x100),
    Gate(17, "qspi", 0x60, 0x10),
    Gate(18, "qspi_bus", 0x60, 0x8),
    Gate(19, "dma", 0x64, 0x8),
    Gate(20, "aes", 0x68, 0x20),
    Gate(21, "vpu", 0xa4, 0x8),
    Gate(22, "gpu", 0xcc, 0x10),
    Gate(23, "emmc", 0x104, 0x10),
    Gate(24, "emmc_x", 0x104, 0x8000),
    Gate(25, "audio", 0x14c, 0x1000),
    Gate(26, "hdmi_mclk", 0x1b8, 0x1),
    Gate(27, "pmua_aclk", 0x388, 0x0),
    Gate(28, "pcie0_master", 0x3cc, 0x4),
    Gate(29, "pcie0_slave", 0x3cc, 0x2),
    Gate(30, "pcie0_dbi", 0x3cc, 0x1),
    Gate(31, "pcie1_master", 0x3d4, 0x4),
    Gate(32, "pcie1_slave", 0x3d4, 0x2),
    Gate(33, "pcie1_dbi", 0x3d4, 0x1),
    Gate(34, "pcie2_master", 0x3dc, 0x4),
    Gate(35, "pcie2_slave", 0x3dc, 0x2),
    Gate(36, "pcie2_dbi", 0x3dc, 0x1),
    Gate(37, "emac0_bus", 0x3e4, 0x1),
    Gate(38, "emac0_ptp", 0x3e4, 0x8000),
    Gate(39, "emac1_bus", 0x3ec, 0x1),
    Gate(40, "emac1_ptp", 0x3ec, 0x8000),
    Gate(41, "jpg", 0x20, 0x2),
    Gate(42, "ccic2phy", 0x24, 0x20),
    Gate(43, "ccic3phy", 0x24, 0x40000000),
    Gate(44, "csi", 0x24, 0x10),
    Gate(45, "camm0", 0x24, 0x10000000),
    Gate(46, "camm1", 0x24, 0x40),
    Gate(47, "camm2", 0x24, 0x8),
    Gate(48, "isp_cpp", 0x38, 0x10000000),
    Gate(49, "isp_bus", 0x38, 0x20000),
    Gate(50, "isp", 0x38, 0x2),
    Gate(51, "dpu_mclk", 0x4c, 0x1),
    Gate(52, "dpu_esc", 0x44, 0x4),
    Gate(53, "dpu_bit", 0x44, 0x10000),
    Gate(54, "dpu_pxclk", 0x4c, 0x10000),
    Gate(55, "dpu_hclk", 0x44, 0x20),
    Gate(56, "dpu_spi", 0x48, 0x2),
    Gate(57, "dpu_spi_hbus", 0x48, 0x8),
    Gate(58, "dpu_spi_bus", 0x48, 0x20),
    Gate(59, "dpu_spi_aclk", 0x48, 0x40),
    Gate(60, "v2d", 0x44, 0x100),
    Gate(61, "emmc_bus", 0x104, 0x8),
  ]
  static let apbcResets: [Reset] = [
    Reset(0, "uart0", 0x0, assert: 0x4, deassert: 0x0),
    Reset(1, "uart2", 0x4, assert: 0x4, deassert: 0x0),
    Reset(9, "gpio", 0x8, assert: 0x4, deassert: 0x0),
    Reset(10, "pwm0", 0xc, assert: 0x4, deassert: 0x1),
    Reset(11, "pwm1", 0x10, assert: 0x4, deassert: 0x1),
    Reset(12, "pwm2", 0x14, assert: 0x4, deassert: 0x1),
    Reset(13, "pwm3", 0x18, assert: 0x4, deassert: 0x1),
    Reset(14, "pwm4", 0xa8, assert: 0x4, deassert: 0x1),
    Reset(15, "pwm5", 0xac, assert: 0x4, deassert: 0x1),
    Reset(16, "pwm6", 0xb0, assert: 0x4, deassert: 0x1),
    Reset(17, "pwm7", 0xb4, assert: 0x4, deassert: 0x1),
    Reset(18, "pwm8", 0xb8, assert: 0x4, deassert: 0x1),
    Reset(19, "pwm9", 0xbc, assert: 0x4, deassert: 0x1),
    Reset(20, "pwm10", 0xc0, assert: 0x4, deassert: 0x1),
    Reset(21, "pwm11", 0xc4, assert: 0x4, deassert: 0x1),
    Reset(22, "pwm12", 0xc8, assert: 0x4, deassert: 0x1),
    Reset(23, "pwm13", 0xcc, assert: 0x4, deassert: 0x1),
    Reset(24, "pwm14", 0xd0, assert: 0x4, deassert: 0x1),
    Reset(25, "pwm15", 0xd4, assert: 0x4, deassert: 0x1),
    Reset(26, "pwm16", 0xd8, assert: 0x4, deassert: 0x1),
    Reset(27, "pwm17", 0xdc, assert: 0x4, deassert: 0x1),
    Reset(28, "pwm18", 0xe0, assert: 0x4, deassert: 0x1),
    Reset(29, "pwm19", 0xe4, assert: 0x4, deassert: 0x1),
    Reset(30, "ssp3", 0x7c, assert: 0x4, deassert: 0x0),
    Reset(2, "uart3", 0x24, assert: 0x4, deassert: 0x0),
    Reset(31, "rtc", 0x28, assert: 0x4, deassert: 0x0),
    Reset(32, "twsi0", 0x2c, assert: 0x4, deassert: 0x0),
    Reset(40, "timers1", 0x34, assert: 0x4, deassert: 0x0),
    Reset(42, "aib", 0x3c, assert: 0x4, deassert: 0x0),
    Reset(41, "timers2", 0x44, assert: 0x4, deassert: 0x0),
    Reset(43, "onewire", 0x48, assert: 0x4, deassert: 0x0),
    Reset(44, "sspa0", 0x80, assert: 0x4, deassert: 0x0),
    Reset(45, "sspa1", 0x84, assert: 0x4, deassert: 0x0),
    Reset(46, "dro", 0x58, assert: 0x4, deassert: 0x0),
    Reset(47, "ir", 0x5c, assert: 0x4, deassert: 0x0),
    Reset(33, "twsi1", 0x30, assert: 0x4, deassert: 0x0),
    Reset(48, "tsen", 0x6c, assert: 0x4, deassert: 0x0),
    Reset(34, "twsi2", 0x38, assert: 0x4, deassert: 0x0),
    Reset(35, "twsi4", 0x40, assert: 0x4, deassert: 0x0),
    Reset(36, "twsi5", 0x4c, assert: 0x4, deassert: 0x0),
    Reset(37, "twsi6", 0x60, assert: 0x4, deassert: 0x0),
    Reset(38, "twsi7", 0x68, assert: 0x4, deassert: 0x0),
    Reset(39, "twsi8", 0x20, assert: 0x4, deassert: 0x0),
    Reset(49, "ipc_ap2aud", 0x90, assert: 0x4, deassert: 0x0),
    Reset(3, "uart4", 0x70, assert: 0x4, deassert: 0x0),
    Reset(4, "uart5", 0x74, assert: 0x4, deassert: 0x0),
    Reset(5, "uart6", 0x78, assert: 0x4, deassert: 0x0),
    Reset(6, "uart7", 0x94, assert: 0x4, deassert: 0x0),
    Reset(7, "uart8", 0x98, assert: 0x4, deassert: 0x0),
    Reset(8, "uart9", 0x9c, assert: 0x4, deassert: 0x0),
    Reset(50, "can0", 0xa0, assert: 0x4, deassert: 0x0),
  ]
  static let apmuResets: [Reset] = [
    Reset(0, "ccic_4x", 0x50, assert: 0x0, deassert: 0x2),
    Reset(1, "ccic1_phy", 0x50, assert: 0x0, deassert: 0x4),
    Reset(2, "sdh_axi", 0x54, assert: 0x0, deassert: 0x1),
    Reset(3, "sdh0", 0x54, assert: 0x0, deassert: 0x2),
    Reset(4, "sdh1", 0x58, assert: 0x0, deassert: 0x2),
    Reset(5, "sdh2", 0xe0, assert: 0x0, deassert: 0x2),
    Reset(6, "usbp1_axi", 0x5c, assert: 0x0, deassert: 0x10),
    Reset(7, "usb_axi", 0x5c, assert: 0x0, deassert: 0x1),
    Reset(8, "usb30_ahb", 0x5c, assert: 0x0, deassert: 0x200),
    Reset(9, "usb30_vcc", 0x5c, assert: 0x0, deassert: 0x400),
    Reset(10, "usb30_phy", 0x5c, assert: 0x0, deassert: 0x800),
    Reset(11, "qspi", 0x60, assert: 0x0, deassert: 0x2),
    Reset(12, "qspi_bus", 0x60, assert: 0x0, deassert: 0x1),
    Reset(13, "dma", 0x64, assert: 0x0, deassert: 0x1),
    Reset(14, "aes", 0x68, assert: 0x0, deassert: 0x10),
    Reset(15, "vpu", 0xa4, assert: 0x0, deassert: 0x1),
    Reset(16, "gpu", 0xcc, assert: 0x0, deassert: 0x2),
    Reset(17, "emmc", 0x104, assert: 0x0, deassert: 0x2),
    Reset(18, "emmc_x", 0x104, assert: 0x0, deassert: 0x1),
    Reset(19, "audio_sys", 0x14c, assert: 0x0, deassert: 0x1),
    Reset(20, "audio_mcu", 0x14c, assert: 0x0, deassert: 0x4),
    Reset(21, "audio_apmu", 0x14c, assert: 0x0, deassert: 0x8),
    Reset(22, "hdmi", 0x1b8, assert: 0x0, deassert: 0x200),
    Reset(25, "pcie0_dbi", 0x3cc, assert: 0x0, deassert: 0x8),
    Reset(24, "pcie0_slave", 0x3cc, assert: 0x0, deassert: 0x10),
    Reset(23, "pcie0_master", 0x3cc, assert: 0x0, deassert: 0x20),
    Reset(26, "pcie0_global", 0x3cc, assert: 0x100, deassert: 0x0),
    Reset(29, "pcie1_dbi", 0x3d4, assert: 0x0, deassert: 0x8),
    Reset(28, "pcie1_slave", 0x3d4, assert: 0x0, deassert: 0x10),
    Reset(27, "pcie1_master", 0x3d4, assert: 0x0, deassert: 0x20),
    Reset(30, "pcie1_global", 0x3d4, assert: 0x100, deassert: 0x0),
    Reset(33, "pcie2_dbi", 0x3dc, assert: 0x0, deassert: 0x8),
    Reset(32, "pcie2_slave", 0x3dc, assert: 0x0, deassert: 0x10),
    Reset(31, "pcie2_master", 0x3dc, assert: 0x0, deassert: 0x20),
    Reset(34, "pcie2_global", 0x3dc, assert: 0x100, deassert: 0x0),
    Reset(35, "emac0", 0x3e4, assert: 0x0, deassert: 0x2),
    Reset(36, "emac1", 0x3ec, assert: 0x0, deassert: 0x2),
    Reset(37, "jpg", 0x20, assert: 0x0, deassert: 0x1),
    Reset(38, "ccic2phy", 0x24, assert: 0x0, deassert: 0x4),
    Reset(39, "ccic3phy", 0x24, assert: 0x0, deassert: 0x20000000),
    Reset(40, "csi", 0x24, assert: 0x0, deassert: 0x2),
    Reset(43, "isp", 0x38, assert: 0x0, deassert: 0x1),
    Reset(41, "isp_cpp", 0x38, assert: 0x0, deassert: 0x8000000),
    Reset(42, "isp_bus", 0x38, assert: 0x0, deassert: 0x8),
    Reset(44, "isp_ci", 0x38, assert: 0x0, deassert: 0x10000),
    Reset(45, "dpu_mclk", 0x4c, assert: 0x0, deassert: 0x200),
    Reset(46, "dpu_esc", 0x44, assert: 0x0, deassert: 0x8),
    Reset(47, "dpu_hclk", 0x44, assert: 0x0, deassert: 0x10),
    Reset(48, "dpu_spibus", 0x48, assert: 0x0, deassert: 0x10),
    Reset(49, "dpu_spi_hbus", 0x48, assert: 0x0, deassert: 0x4),
    Reset(50, "v2d", 0x44, assert: 0x0, deassert: 0x8000000),
    Reset(51, "mipi", 0x44, assert: 0x0, deassert: 0x8000),
    Reset(52, "mc", 0xe8, assert: 0x0, deassert: 0x1),
  ]
}
