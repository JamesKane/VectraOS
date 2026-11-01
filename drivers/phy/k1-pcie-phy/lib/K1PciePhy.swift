// SPDX-License-Identifier: BSD-3-Clause

// The SpacemiT K1's PCIe PHYs (k1-pcie-phy(3)), as bin/k1-pcie-phy drives
// them. Port A's is the combo PHY, shared with USB 3: only it can
// calibrate the receiver's and transmitter's termination, and the PHYs of
// ports B and C, two lanes each with a PLL they share, take its result.
// So the combo PHY's driver calibrates once, unless firmware has, and
// serves the result; a port B or C PHY, turned on by its host, sets each
// lane's termination from it, its reference clock (the board's 24 MHz
// crystal, from which the PLL makes PCIe's 100 MHz), and waits for its
// PLL to lock. The combo PHY can instead be USB 3's, the DWC3's
// SuperSpeed PHY: the APMU gives it to USB, and its PLL is set up and
// locks. Registers, bits and the order of writes are the hardware's, as
// Linux's phy-k1-pcie.c gives them for PCIe and the vendor's
// phy-ky-x1-combphy.c for USB 3.

/// A read-modify-write: the bits of `register` under `mask` become
/// `value`.
public struct PhyUpdate: Equatable, Sendable {
  public var register: Int
  public var mask: UInt32
  public var value: UInt32

  public init(_ register: Int, mask: UInt32, value: UInt32) {
    self.register = register
    self.mask = mask
    self.value = value
  }

  public func apply(_ old: UInt32) -> UInt32 { old & ~mask | value & mask }
}

/// The PHY's registers, a lane's from its lane's offset.
public enum PhyRegister {
  public static let lane = 0x400
  public static let clockConfig = 0x08
  public static let rcDone = 0x18
  public static let rcCalibration = 0x20
  public static let pll1 = 0x48
  public static let pll2 = 0x4C
  public static let rx1 = 0x50
  public static let rx2 = 0x54
  public static let ltssmEntry = 0x5C
  public static let tx1 = 0x64
  /// The combo PHY's alone.
  public static let calibrationResult = 0x84
  /// The registers' extent: two lanes.
  public static let size = 0x800

  /// `clockConfig`'s: the PLL is locked.
  public static let pllReady: UInt32 = 1

  /// The combo PHY's as USB 3's: the receiver's LFPS threshold.
  public static let usbLFPS = 0x58
}

/// PHY_TYPE_USB3, the cell a DWC3's `phys` gives the combo PHY.
public let phyTypeUSB3: UInt32 = 4

/// The combo PHY's calibration, from its result register: four bits each
/// for the receiver's and transmitter's termination.
public struct Termination: Equatable, Sendable {
  public var rx: UInt32
  public var tx: UInt32

  public init(rx: UInt32, tx: UInt32) {
    self.rx = rx & 0xF
    self.tx = tx & 0xF
  }

  /// R_TUNE_DONE, bit 10.
  public static let done: UInt32 = 1 << 10

  /// The result, once the hardware says calibration is done; else nil.
  public init?(result: UInt32) {
    guard result & Self.done != 0 else { return nil }
    self.init(rx: result & 0xF, tx: result >> 4 & 0xF)
  }

  /// `rx 8 tx 6`, as the combo PHY's driver serves it.
  public var description: String { "rx \(rx) tx \(tx)" }

  public init?(_ text: String) {
    let w = text.utf8.split(whereSeparator: { $0 == 0x20 || $0 == 0x0A }).map { String(decoding: $0, as: UTF8.self) }
    guard w.count == 4, w[0].utf8.elementsEqual("rx".utf8), w[2].utf8.elementsEqual("tx".utf8),
      let rx = UInt32(w[1]), let tx = UInt32(w[3]), rx < 16, tx < 16
    else { return nil }
    self.init(rx: rx, tx: tx)
  }
}

public enum K1PciePhy {
  /// A port B or C PHY's lanes: its node's `num-lanes`, 1 or 2, else 2.
  public static func lanes(node: String) -> Int {
    for line in node.utf8.split(separator: 0x0A) where line.starts(with: "num-lanes ".utf8) {
      let digits = line.dropFirst(10).filter { $0 != UInt8(ascii: "<") && $0 != UInt8(ascii: ">") }
      let s = String(decoding: digits, as: UTF8.self)
      let n = s.utf8.starts(with: "0x".utf8) ? Int(String(decoding: s.utf8.dropFirst(2), as: UTF8.self), radix: 16) : Int(s)
      return n == 1 ? 1 : 2
    }
    return 2
  }

  /// The writes that set up a port B or C PHY for PCIe, in order: each
  /// lane's termination, its reference clock's frequency (recalibrating
  /// its RC), and the reference clock driven to the slot; then the PLL's
  /// setup on lane 0, from the 24 MHz crystal with no spread spectrum,
  /// and each lane marked set up. Then the PLL locks (`pllReady`).
  public static func setup(lanes: Int, _ t: Termination) -> [PhyUpdate] {
    var out: [PhyUpdate] = []
    for l in 0..<lanes {
      let base = l * PhyRegister.lane
      // AFE_RTERM_REG and EN_RTERM; RX_RTERM_SEL clear, to use them.
      out.append(PhyUpdate(base + PhyRegister.rx1, mask: 0xF08, value: t.rx << 8 | 1 << 3))
      out.append(PhyUpdate(base + PhyRegister.rx2, mask: 1 << 5, value: 0))
      // TX_RTERM_REG and TX_RTERM_SEL.
      out.append(PhyUpdate(base + PhyRegister.tx1, mask: 0xF000 | 1 << 25, value: t.tx << 12 | 1 << 25))
      // CLKSEL's 24 MHz bits set, every other bit but CLKSEL's clear, then
      // RC_CAL_TOGGLE set.
      out.append(PhyUpdate(base + PhyRegister.rcCalibration, mask: ~(1 << 31), value: 3 << 29))
      out.append(PhyUpdate(base + PhyRegister.rcCalibration, mask: 1 << 22, value: 1 << 22))
      // OVRD_REFCLK_MODE, and CFG_REFCLK_MODE the driver's.
      out.append(PhyUpdate(base + PhyRegister.ltssmEntry, mask: 0x700, value: 0x500))
    }
    for l in 0..<lanes {
      // CFG_INTERNAL_TIMER_ADJ, PCIe's.
      out.append(PhyUpdate(l * PhyRegister.lane + PhyRegister.clockConfig, mask: 0x780, value: 6 << 7))
    }
    // CFG_FORCE_RCV_RETRY; no SSC_DEP_SEL; GEN_REF100; then FREF_SEL 24
    // MHz without REF_100_WSSC.
    out.append(PhyUpdate(PhyRegister.rcDone, mask: 1 << 10, value: 1 << 10))
    out.append(PhyUpdate(PhyRegister.pll1, mask: 0xF_0000, value: 0))
    out.append(PhyUpdate(PhyRegister.pll2, mask: 1 << 4, value: 1 << 4))
    out.append(PhyUpdate(PhyRegister.pll1, mask: 0xF000, value: 1 << 13))
    for l in 0..<lanes {
      // CFG_SW_PHY_INIT_DONE.
      out.append(PhyUpdate(l * PhyRegister.lane + PhyRegister.clockConfig, mask: 1 << 11, value: 1 << 11))
    }
    return out
  }
}

extension K1PciePhy {
  /// The writes that set the combo PHY up as USB 3's, in order, once the
  /// APMU has given it to USB: its PLL and receiver set up, then its PLL
  /// locks (`pllReady` in `clockConfig`). The values are the vendor's.
  public static let usb3: [PhyUpdate] = [
    PhyUpdate(0x68, mask: ~0, value: 0),
    PhyUpdate(PhyRegister.pll1, mask: ~0, value: 0x603a_2276),
    PhyUpdate(PhyRegister.clockConfig, mask: ~0, value: 0x97c),
    PhyUpdate(PhyRegister.rcDone, mask: ~0, value: 0),
  ]

  /// Once it locks: the LFPS threshold, the vendor's default 3.
  public static let usb3LFPS = PhyUpdate(PhyRegister.usbLFPS, mask: 0x700, value: 3 << 8)
}
