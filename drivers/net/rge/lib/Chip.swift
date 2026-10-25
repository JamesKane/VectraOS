// SPDX-License-Identifier: BSD-3-Clause

// The Realtek RTL8126's MAC and PHY, brought up as the BSDs' rge(4) does
// (OpenBSD's, as FreeBSD has it, if_rge.c and if_rge_hw.c; the register
// sequences are Realtek's): out of out-of-band mode, the PHY powered,
// the MAC's microcontroller stopped, reset, then the MAC configured, the
// PHY set to autonegotiate every speed to 5 Gb/s, and receive and
// transmit enabled. On the RTL8126_2 Realtek's code is loaded as the
// BSDs load it (RTL8126Code.swift; firmware/README.md lists it, D4): the
// MAC microcontroller's breakpoints with it stopped, and the PHY's RAM
// code and its tuning after the PHY's reset, each only if the chip doesn't already hold that version. Without
// them a gigabit link partner took 16 s to link (the 2.5 and 5 Gb/s
// training stalls), 3.4 s with 1 Gb/s alone. The RTL8126_1 runs without,
// as Linux's r8169 does with no firmware file. The registers are BAR 2's.

import DriverHost
import Sys

/// Busy waits: the chip's handshakes take microseconds.
func spin(microseconds: Int64) {
  let until = Clock.monotonic() + microseconds * 1000
  while Clock.monotonic() < until {}
}

/// Checks `done` up to `tries` times, `every` microseconds apart; whether
/// it came true.
func poll(_ tries: Int, every microseconds: Int64, _ done: () -> Bool) -> Bool {
  for _ in 0..<tries {
    if done() { return true }
    spin(microseconds: microseconds)
  }
  return done()
}

@safe final class Chip: @unchecked Sendable {
  enum Reg {
    static let mac0 = 0x00, mac4 = 0x04, mar0 = 0x08, mar4 = 0x0C
    static let txDescLo = 0x20, txDescHi = 0x24
    static let intCfg0 = 0x34, cmd = 0x37, imr = 0x38, isr = 0x3C
    static let txCfg = 0x40, rxCfg = 0x44, timerCount = 0x48
    static let eeCmd = 0x50, cfg1 = 0x52, cfg5 = 0x56, tdfnr = 0x57
    static let timerInt0 = 0x58, timerInt1 = 0x5C, timerInt2 = 0x8C, timerInt3 = 0xF4
    static let csiData = 0x64, csiAddress = 0x68, phyStatus = 0x6C, pmch = 0x6F
    static let intCfg1 = 0x7A, txStart = 0x90
    static let macOCP = 0xB0, phyOCP = 0xB8, dllpr = 0xD0, twiCmd = 0xD2, mcuCmd = 0xD3
    static let rxMaxSize = 0xDA, cplusCmd = 0xE0, im = 0xE2
    static let rxDescLo = 0xE4, rxDescHi = 0xE8, ppsw = 0xF2
    static let addr0 = 0x19E0, addr1 = 0x19E4
    static let rssCtrl = 0x4500, rxQueueCtrl = 0x4800, eeeTxIdleTimer = 0x6048
    static func interruptMitigation(_ i: Int) -> Int { 0x0A00 + i * 4 }
  }

  /// The interrupts taken: receive and transmit done or failed, the
  /// link's change, the transmit ring empty, and a system error.
  static let interrupts: UInt32 = 0x0001 | 0x0002 | 0x0004 | 0x0008 | 0x0020 | 0x0080 | 0x4000 | 0x8000
  static let linkChange: UInt32 = 0x0020
  static let systemError: UInt32 = 0x8000

  /// TXCFG's hardware revision bits, and the RTL8126's two.
  static let revisionMask: UInt32 = 0x7CF0_0000
  static let revisions: [(UInt32, String)] = [(0x6490_0000, "RTL8126_1"), (0x64A0_0000, "RTL8126_2")]

  let regs: Registers
  let revision: UInt32

  init(_ regs: consuming Registers) {
    revision = regs.load32(Reg.txCfg) & Self.revisionMask
    self.regs = regs
  }

  /// The revision's name, or nil for a chip this driver doesn't know.
  var revisionName: String? { Self.revisions.first { $0.0 == revision }?.1 }

  // Registers, and the MAC's and PHY's own spaces (OCP) through them.

  func set8(_ r: Int, _ bits: UInt8) { regs.store8(r, regs.load8(r) | bits) }
  func clear8(_ r: Int, _ bits: UInt8) { regs.store8(r, regs.load8(r) & ~bits) }
  func clear16(_ r: Int, _ bits: UInt16) { regs.store16(r, regs.load16(r) & ~bits) }
  func clear32(_ r: Int, _ bits: UInt32) { regs.store32(r, regs.load32(r) & ~bits) }

  func writeMAC(_ reg: UInt16, _ value: UInt16) {
    regs.store32(Reg.macOCP, UInt32(reg >> 1) << 16 | UInt32(value) | 0x8000_0000)
  }

  func readMAC(_ reg: UInt16) -> UInt16 {
    regs.store32(Reg.macOCP, UInt32(reg >> 1) << 16)
    return UInt16(truncatingIfNeeded: regs.load32(Reg.macOCP))
  }

  func modifyMAC(_ reg: UInt16, clear: UInt16 = 0, set: UInt16 = 0) { writeMAC(reg, readMAC(reg) & ~clear | set) }

  func writePHY(_ reg: UInt16, _ value: UInt16) {
    regs.store32(Reg.phyOCP, UInt32(reg >> 1) << 16 | UInt32(value) | 0x8000_0000)
    for _ in 0..<20_000 {
      spin(microseconds: 1)
      if regs.load32(Reg.phyOCP) & 0x8000_0000 == 0 { break }
    }
  }

  /// A read is done when the busy bit sets (a write's when it clears).
  func readPHY(_ reg: UInt16) -> UInt16 {
    regs.store32(Reg.phyOCP, UInt32(reg >> 1) << 16)
    var value: UInt32 = 0
    for _ in 0..<20_000 {
      spin(microseconds: 1)
      value = regs.load32(Reg.phyOCP)
      if value & 0x8000_0000 != 0 { break }
    }
    return UInt16(truncatingIfNeeded: value)
  }

  func modifyPHY(_ reg: UInt16, clear: UInt16 = 0, set: UInt16 = 0) { writePHY(reg, readPHY(reg) & ~clear | set) }

  /// A standard MII register (IEEE 802.3 clause 22): the PHY's at 0xA400.
  static func mii(_ reg: UInt16) -> UInt16 { (0xA40 + reg / 8) << 4 + (reg % 8) * 2 }

  enum MII {
    static let control: UInt16 = 0, advertise: UInt16 = 4, gigabitControl: UInt16 = 9
    static let reset: UInt16 = 0x8000, autonegotiate: UInt16 = 0x1000, restart: UInt16 = 0x0200
  }

  /// The PCIe configuration's extended space, through the CSI window.
  func writeCSI(_ reg: UInt32, _ value: UInt32) {
    regs.store32(Reg.csiData, value)
    regs.store32(Reg.csiAddress, reg & 0xFFF | 0xF << 12 | 0x8000_0000)
    for _ in 0..<20_000 {
      spin(microseconds: 1)
      if regs.load32(Reg.csiAddress) & 0x8000_0000 == 0 { break }
    }
    spin(microseconds: 20)
  }

  func readCSI(_ reg: UInt32) -> UInt32 {
    regs.store32(Reg.csiAddress, reg & 0xFFF | 0xF << 12)
    for _ in 0..<20_000 {
      spin(microseconds: 1)
      if regs.load32(Reg.csiAddress) & 0x8000_0000 != 0 { break }
    }
    spin(microseconds: 20)
    return regs.load32(Reg.csiData)
  }

  // Bring-up.

  /// The receive filter off, the FIFOs drained, then a soft reset.
  func reset() throws(Status) {
    clear32(Reg.rxCfg, 0x3F)
    set8(Reg.ppsw, 0x08)  // the RXDV gate on
    set8(Reg.cmd, 0x80)  // stop request
    spin(microseconds: 200)
    _ = poll(3000, every: 50) { regs.load8(Reg.mcuCmd) & 0x30 == 0x30 }
    _ = poll(3000, every: 50) { regs.load16(Reg.im) & 0x0103 == 0x0103 }
    regs.store8(Reg.cmd, regs.load8(Reg.cmd) & 0x0C)
    regs.store8(Reg.cmd, 0x10)
    guard poll(100, every: 100, { regs.load8(Reg.cmd) & 0x10 == 0 }) else { throw .timedOut }
  }

  /// Interrupts masked and cleared, the timers stopped, then `reset`.
  func hardwareReset() throws(Status) {
    regs.store32(Reg.imr, 0)
    regs.store32(Reg.isr, regs.load32(Reg.isr))
    for r in [Reg.timerInt0, Reg.timerInt1, Reg.timerInt2, Reg.timerInt3] { regs.store32(r, 0) }
    try reset()
  }

  /// Takes the chip from its management firmware (out-of-band mode).
  func exitOutOfBand() throws(Status) {
    writeMAC(0xC0BC, 0x00FF)  // RealWoW off
    try reset()
    clear8(Reg.mcuCmd, 0x80)
    modifyMAC(0xE8DE, clear: 0x4000)
    _ = poll(10, every: 100) { regs.load16(Reg.twiCmd) & 0x0200 != 0 }
    writeMAC(0xC0AA, 0x07D0)
    writeMAC(0xC0A6, 0x01B5)
    writeMAC(0xC01E, 0x5555)
    _ = poll(10, every: 100) { regs.load16(Reg.twiCmd) & 0x0200 != 0 }
    if readMAC(0xD42C) & 0x0100 != 0 {
      _ = poll(100, every: 1000) { readPHY(0xA420) & 7 == 2 }
      modifyMAC(0xD42C, clear: 0x0100)
      modifyPHY(0xA466, clear: 0x0001)
      modifyPHY(0xA468, clear: 0x000A)
    }
  }

  /// Writes to the configuration registers (CFG*, INT_CFG*) allowed.
  func unlockConfig(_ on: Bool) { if on { set8(Reg.eeCmd, 0xC0) } else { clear8(Reg.eeCmd, 0xC0) } }

  func disableASPMClockRequest() {
    let locked = regs.load8(Reg.eeCmd) & 0xC0 != 0xC0
    if locked { unlockConfig(true) }
    clear8(Reg.intCfg0, 0x08)
    clear8(Reg.cfg5, 0x01)
    if locked { unlockConfig(false) }
  }

  /// Whether the PHY was found linked as `autonegotiate` leaves it, with
  /// Realtek's code in: a warm boot's (D101). Its link is kept, not reset
  /// and renegotiated, which took 3 s at 1 Gb/s. Judged once, before the
  /// first reset.
  private(set) var linkKept: Bool?

  func judgeLink() -> Bool {
    guard revision == Self.rtl8126_2, link.up else { return false }
    writePHY(0xA436, 0x801E)
    guard readPHY(0xA438) == Self.phyCodeVersion else { return false }
    return readPHY(Self.mii(MII.advertise)) & 0x0FE0 == Self.advertised
      && readPHY(Self.mii(MII.gigabitControl)) & 0x0200 == 0x0200
      && readPHY(0xA5D4) & 0x0180 == multigigabit
  }

  /// Out of band, the PHY powered up, the MAC's microcontroller stopped,
  /// reset.
  func initialize() throws(Status) {
    if linkKept == nil { linkKept = judgeLink() }
    try exitOutOfBand()
    set8(Reg.pmch, 0xC0)
    writePHY(Self.mii(MII.control), MII.autonegotiate)
    _ = poll(100, every: 1000) { readPHY(0xA420) & 7 == 3 }

    disableASPMClockRequest()
    clear8(0xF1, 0x80)
    modifyMAC(0xD40A, clear: 0x0010)  // UPS off
    // The MAC's microcontroller: its break points cleared and it off.
    writeMAC(0xFC48, 0)
    for reg in stride(from: UInt16(0xFC28), to: 0xFC48, by: 2) { writeMAC(reg, 0) }
    spin(microseconds: 3000)
    writeMAC(0xFC26, 0)
    if revision == Self.rtl8126_2 { loadMACCode() }
    // PCIe uncorrectable error status.
    writeCSI(0x108, readCSI(0x108) | 0x0010_0000)
    try hardwareReset()
  }

  /// The address the chip was programmed with (ADDR0/1), else MAC0/4's.
  func readAddress() -> [UInt8] {
    let lo = regs.load32(Reg.addr0), hi = regs.load16(Reg.addr1)
    var mac = (0..<4).map { UInt8(truncatingIfNeeded: lo >> ($0 * 8)) } + [UInt8(truncatingIfNeeded: hi), UInt8(hi >> 8)]
    if mac.allSatisfy({ $0 == 0 }) || mac.allSatisfy({ $0 == 0xFF }) {
      mac = (0..<6).map { regs.load8(Reg.mac0 + $0) }
    }
    return mac
  }

  func setAddress(_ mac: [UInt8]) {
    unlockConfig(true)
    regs.store32(Reg.mac0, UInt32(mac[3]) << 24 | UInt32(mac[2]) << 16 | UInt32(mac[1]) << 8 | UInt32(mac[0]))
    regs.store32(Reg.mac4, UInt32(mac[5]) << 8 | UInt32(mac[4]))
    unlockConfig(false)
  }

  /// The PHY reset, its 2.5 and 5 Gb/s advertisements off until
  /// `autonegotiate`, and EEE, ALDPS and Gigabit Lite off; a kept link
  /// (`linkKept`) is neither reset nor its advertisements changed.
  func configurePHY() throws(Status) {
    if linkKept != true {
      modifyPHY(Self.mii(MII.advertise), clear: 0x01E0)
      modifyPHY(Self.mii(MII.gigabitControl), clear: 0x0300)
      modifyPHY(0xA5D4, clear: 0x0080 | 0x0100)
      writePHY(Self.mii(MII.control), MII.reset | MII.autonegotiate | MII.restart)
      guard poll(2500, every: 1000, { readPHY(Self.mii(MII.control)) & MII.reset == 0 }) else { throw .timedOut }
    }
    if revision == Self.rtl8126_2 { tunePHY() }

    modifyPHY(0xA442, set: 0x0800)  // 10 Mb/s on
    modifyPHY(0xA5B4, clear: 0x8000)  // legacy force mode off
    modifyPHY(0xA430, clear: 0x0004)  // ALDPS off
    // EEE off.
    modifyMAC(0xE040, clear: 0x0003)
    modifyPHY(0xA5D0, clear: 0x0006)
    modifyPHY(0xA6D4, clear: 0x0003)
    modifyPHY(0xA6D8, clear: 0x0010)
    modifyPHY(0xA428, clear: 0x0080)
    modifyPHY(0xA4A2, clear: 0x0200)
    // Advanced EEE off.
    modifyMAC(0xE052, clear: 0x0001)
    modifyPHY(0xA442, clear: 0x3000)
    modifyPHY(0xA430, clear: 0x8000)
  }

  // MARK: Realtek's code (the RTL8126_2's, firmware/README.md)

  static let rtl8126_2: UInt32 = 0x64A0_0000
  /// What starting the chip did with Realtek's code: `loaded`, `held`
  /// (the chip had that version already) or `none` (no code for it).
  private(set) var macCode = "none", phyCode = "none"
  /// The PHY RAM code's version the table is (RGE_MAC_R26_2_RCODE_VER).
  static let phyCodeVersion: UInt16 = 0x0060

  /// The MAC microcontroller's RAM page (0-2) its registers reach.
  func switchMCUPage(_ page: UInt16) { modifyMAC(0xE446, clear: 0x0003, set: page) }

  /// The MAC's breakpoints written (pages 0 and 1) unless the chip holds
  /// their version already (page 2), then set and the version stamped
  /// (if_rge_hw.c's rge_mac_config_ext_mcu).
  func loadMACCode() {
    let values = RTL8126Code.macValues, registers = RTL8126Code.macRegisters
    var held: UInt64 = 0, version: UInt64 = 0
    switchMCUPage(2)
    for i in stride(from: 0, to: 8, by: 2) { held = held << 16 | UInt64(readMAC(0xF9F8 + UInt16(i))) }
    switchMCUPage(0)
    for v in values.suffix(4) { version = version << 16 | UInt64(v) }
    macCode = "held"
    if held != version {
      for i in 0..<256 { writeMAC(registers[i], values[i]) }
      switchMCUPage(1)
      for i in 256..<registers.count { writeMAC(registers[i], values[i]) }
      macCode = "loaded"
    }
    writeMAC(0xFC26, 0x8000)
    writeMAC(0xFC2C, 0x14A4)
    writeMAC(0xFC2E, 0x4176)
    writeMAC(0xFC30, 0x41FC)
    writeMAC(0xFC32, 0x4298)
    writeMAC(0xFC3A, 0x234A)
    writeMAC(0xFC48, 0x023C)
    switchMCUPage(2)
    var v = version
    for i in stride(from: 0, to: 8, by: 2) {
      writeMAC(0xF9F8 + 6 - UInt16(i), UInt16(truncatingIfNeeded: v))
      v >>= 16
    }
    switchMCUPage(0)
  }

  /// The PHY's microcontroller held for patching (`on`) or let go, and
  /// waited for (rge_patch_phy_mcu).
  func patchPHY(_ on: Bool) {
    modifyPHY(0xB820, clear: on ? 0 : 0x0010, set: on ? 0x0010 : 0)
    _ = poll(1000, every: 100) { (readPHY(0xB800) & 0x0040 != 0) == on }
  }

  /// One of the PHY's extended registers (`index`, through `select`'s
  /// window at `select + 2`), its high byte set to `high`.
  func setHighByte(_ select: UInt16, _ index: UInt16, _ high: UInt16) {
    writePHY(select, index)
    writePHY(select + 2, readPHY(select + 2) & 0x00FF | high << 8)
  }

  /// The PHY's RAM code loaded unless it holds that version, then its
  /// tuning (rge_phy_config_mcu and rge_phy_config_mac_r26_2).
  func tunePHY() {
    writePHY(0xA436, 0x801E)
    phyCode = "held"
    if readPHY(0xA438) != Self.phyCodeVersion {
      phyCode = "loaded"
      patchPHY(true)
      for (reg, value) in RTL8126Code.phy { writePHY(reg, value) }
      patchPHY(false)
      writePHY(0xA436, 0x801E)
      writePHY(0xA438, Self.phyCodeVersion)
    }
    modifyPHY(0xA442, set: 0x0800)
    setHighByte(0xA436, 0x8183, 0x59)
    modifyPHY(0xA654, set: 0x0800)
    modifyPHY(0xB648, set: 0x4000)
    modifyPHY(0xAD2C, set: 0x8000)
    modifyPHY(0xAD94, set: 0x0020)
    modifyPHY(0xADA0, set: 0x0002)
    modifyPHY(0xAE06, clear: 0xFC00, set: 0x7C00)
    for (index, high) in [(UInt16(0x8647), UInt16(0xE6)), (0x8036, 0x30), (0x8078, 0x30)] {
      setHighByte(0xB87C, index, high)
    }
    writePHY(0xB87C, 0x89E9)
    modifyPHY(0xB87E, set: 0xFF00)
    for (index, high) in [(UInt16(0x8FFD), UInt16(0x01)), (0x8FFE, 0x02), (0x8FFF, 0x04)] {
      setHighByte(0xB87C, index, high)
    }
    setHighByte(0xA436, 0x8018, 0x77)
    writePHY(0xA436, 0x8F9C)
    for value in [UInt16(0x0005), 0x0000, 0x00ED, 0x0502, 0x0B00, 0xD401] { writePHY(0xA438, value) }
    setHighByte(0xA436, 0x8FA8, 0x29)
    for (index, high) in [
      (UInt16(0x814B), UInt16(0x11)), (0x814D, 0x11), (0x814F, 0x0B), (0x8142, 0x01), (0x8144, 0x01), (0x8150, 0x01),
      (0x8118, 0x07), (0x811A, 0x07), (0x811C, 0x05), (0x810F, 0x01), (0x8111, 0x01), (0x811D, 0x01),
    ] {
      setHighByte(0xB87C, index, high)
    }
    modifyPHY(0xAD1C, set: 0x0100)
    modifyPHY(0xADE8, clear: 0xFFC0, set: 0x1400)
    setHighByte(0xB87C, 0x864B, 0x9D)
    setHighByte(0xB87C, 0x862C, 0x12)
    writePHY(0xA436, 0x8566)
    for value in [UInt16(0x003F), 0x3F02, 0x023C, 0x3B0A, 0x1C00, 0x0000, 0x0000, 0x0000, 0x0000] {
      writePHY(0xA438, value)
    }
    modifyPHY(0xAD9C, set: 0x0020)
    setHighByte(0xB87C, 0x8122, 0x0C)
    let b87e: [UInt16] = [
      0x03ED, 0x03FF, 0x0009, 0x03FE, 0x000B, 0x0021, 0x03F7, 0x03B8, 0x03E0, 0x0049, 0x0049, 0x03E0, 0x03B8, 0x03F7,
      0x0021, 0x000B, 0x03FE, 0x0009, 0x03FF, 0x03ED, 0x82A0, 0x000E, 0x03FE, 0x03ED, 0x0006, 0x001A, 0x03F1, 0x03D8,
      0x0023, 0x0054, 0x0322, 0x00DD, 0x03AB, 0x03DC, 0x0027, 0x000E, 0x03E5, 0x03F9, 0x0012, 0x0001, 0x03F1,
    ]
    writePHY(0xB87C, 0x82C8)
    for value in b87e[0..<20] { writePHY(0xB87E, value) }
    setHighByte(0xB87C, 0x80EF, 0x0C)
    for value in b87e[20...] { writePHY(0xB87E, value) }
    modifyPHY(0xA430, set: 0x0003)
    modifyPHY(0xB54C, clear: 0xFFC0, set: 0x3700)
    modifyPHY(0xB648, set: 0x0040)
    setHighByte(0xB87C, 0x8082, 0x5D)
    setHighByte(0xB87C, 0x807C, 0x50)
    setHighByte(0xB87C, 0x809D, 0x50)
  }

  /// The fastest speed advertised, in Mb/s: 1000 by default, since a
  /// gigabit partner offered 2.5 and 5 Gb/s took 16 s to link (FreeBSD's
  /// rge0 too), and 3.4 s offered 1 Gb/s alone; 2500 or 5000 on request
  /// (rge's ctl), for a multi-gigabit partner.
  var maxSpeed = 1000

  /// The speeds `autonegotiate` accepts as the fastest.
  static let speeds = [1000, 2500, 5000]

  /// 10 and 100 Mb/s, half and full duplex, with pause.
  static let advertised: UInt16 = 0x0100 | 0x0080 | 0x0040 | 0x0020 | 0x0800 | 0x0400

  /// The 2.5 and 5 Gb/s advertisements for `maxSpeed`.
  var multigigabit: UInt16 { maxSpeed >= 5000 ? 0x0080 | 0x0100 : maxSpeed >= 2500 ? 0x0080 : 0 }

  /// Advertises every speed from 10 Mb/s to `maxSpeed`, with pause, and
  /// restarts autonegotiation.
  func autonegotiate() {
    modifyPHY(0xA428, clear: 0x0200)  // Gigabit Lite off
    modifyPHY(0xA5EA, clear: 0x0007)
    writePHY(Self.mii(MII.advertise), Self.advertised)
    writePHY(Self.mii(MII.gigabitControl), 0x0200 | 0x0100)
    modifyPHY(0xA5D4, clear: 0x0080 | 0x0100, set: multigigabit)
    writePHY(Self.mii(MII.control), MII.reset | MII.autonegotiate | MII.restart)
  }

  /// The MAC set up over rings at `receive` and `transmit` (device
  /// addresses), frames to `maxFrame` bytes, every multicast taken; then
  /// receive and transmit on, and `interrupts` unmasked.
  func start(receive: UInt64, transmit: UInt64, maxFrame: Int) throws(Status) {
    clear32(Reg.rxCfg, 0x3F)
    try hardwareReset()
    modifyMAC(0xC0AC, clear: 0x1F80)
    try initialize()
    try configurePHY()

    unlockConfig(true)
    clear8(0xF1, 0x80)
    disableASPMClockRequest()
    regs.store16(Reg.eeeTxIdleTimer, 1500 + 14 + 32)
    regs.store32(Reg.rxDescLo, UInt32(truncatingIfNeeded: receive))
    regs.store32(Reg.rxDescHi, UInt32(receive >> 32))
    regs.store32(Reg.txDescLo, UInt32(truncatingIfNeeded: transmit))
    regs.store32(Reg.txDescHi, UInt32(transmit >> 32))
    // 32-byte receive descriptors (bit 24), as the transmit ones (0xEB58).
    regs.store32(Reg.rxCfg, 0x4120_0D00)
    regs.store32(Reg.txCfg, 0x0300_0700)
    writeCSI(0x70C, readCSI(0x70C) & ~0x3F00_0000 | 0x2700_0000)
    writeCSI(0x890, readCSI(0x890) & ~1)  // L1 timeout off
    regs.store8(Reg.rssCtrl, 0)
    clear16(Reg.rxQueueCtrl, 0x001C)  // one queue
    clear8(Reg.cfg1, 0x10)  // speed down off
    writeMAC(0xC140, 0xFFFF)
    writeMAC(0xC142, 0xFFFF)
    modifyMAC(0xEB58, set: 0x0001)
    clear8(0xD8, 0x02)
    modifyMAC(0xE614, clear: 0x0700, set: 0x0300)
    modifyMAC(0xE63E, clear: 0x0C00)
    modifyMAC(0xE63E, clear: 0x0030, set: 0x0020)
    modifyMAC(0xC0B4, clear: 0x0001)
    modifyMAC(0xC0B4, set: 0x0001)
    modifyMAC(0xC0B4, set: 0x000C)
    modifyMAC(0xEB6A, clear: 0x00FF, set: 0x0033)
    modifyMAC(0xEB50, clear: 0x03E0, set: 0x0040)
    modifyMAC(0xE056, clear: 0x00F0)
    regs.store8(Reg.tdfnr, 0x10)
    modifyMAC(0xE040, clear: 0x1000)
    modifyMAC(0xEA1C, clear: 0x0003, set: 0x0001)
    writeMAC(0xE0C0, 0x4000)
    modifyMAC(0xE052, set: 0x0060)
    modifyMAC(0xE052, clear: 0x0088)
    modifyMAC(0xD430, clear: 0x0FFF, set: 0x045F)
    set8(Reg.dllpr, 0x40 | 0x80)
    modifyMAC(0xE080, clear: 0x0002)  // EEE plus off
    modifyMAC(0xEA1C, clear: 0x0304)
    // The TCAM's entries cleared.
    modifyMAC(0xEB54, set: 0x0001)
    spin(microseconds: 1)
    modifyMAC(0xEB54, clear: 0x0001)
    clear16(0x1880, 0x0030)
    clear8(Reg.intCfg0, 0x01)
    for r in [Reg.timerInt0, Reg.timerInt1, Reg.timerInt2, Reg.timerInt3] { regs.store32(r, 0) }
    for i in 0..<32 { regs.store32(Reg.interruptMitigation(i), 0) }
    clear8(Reg.intCfg0, 0x02 | 0x10 | 0x04)  // timeout, RDU and mitigation bypasses
    regs.store16(Reg.intCfg1, 0)
    modifyMAC(0xC0AC, set: 0x1F80)
    writeMAC(0xE098, 0xC302)
    modifyMAC(0xE032, clear: 0x0003)
    writeCSI(0x98, readCSI(0x98) & ~0xFF00)
    modifyMAC(0xE092, clear: 0x00FF)
    clear32(Reg.rxCfg, 0x00C0_0000)  // no VLAN stripping
    clear16(Reg.cplusCmd, 0x0020)  // no receive checksums
    _ = regs.load16(Reg.cplusCmd)
    regs.store16(Reg.rxMaxSize, UInt16(maxFrame))
    clear8(Reg.ppsw, 0x08)  // the RXDV gate off
    spin(microseconds: 2000)
    // Our address, broadcasts and every multicast.
    regs.store32(Reg.rxCfg, regs.load32(Reg.rxCfg) & ~0x01 | 0x02 | 0x04 | 0x08)
    regs.store32(Reg.mar0, 0xFFFF_FFFF)
    regs.store32(Reg.mar4, 0xFFFF_FFFF)
    disableASPMClockRequest()
    unlockConfig(false)
    spin(microseconds: 10)

    if linkKept != true { autonegotiate() }
    regs.store8(Reg.cmd, 0x04 | 0x08)  // transmit and receive on
    // An interrupt a completion: neither the timer nor the chip's own
    // mitigation.
    regs.store32(Reg.imr, Self.interrupts)
    regs.store32(Reg.timerInt0, 0)
    regs.store16(Reg.im, 0)
  }

  /// Masks interrupts and returns what fired, acknowledged.
  func takeInterrupts() -> UInt32 {
    regs.store32(Reg.imr, 0)
    let status = regs.load32(Reg.isr)
    if status != 0 { regs.store32(Reg.isr, status) }
    return status
  }

  func unmaskInterrupts() { regs.store32(Reg.imr, Self.interrupts) }

  /// Whether any interrupt taken is latched, unacknowledged.
  func pendingInterrupts() -> Bool { regs.load32(Reg.isr) & Self.interrupts != 0 }

  /// Tells the chip the transmit ring has frames.
  func kickTransmit() { regs.store16(Reg.txStart, 1) }

  /// The link's state and speed in Mb/s, from PHYSTAT.
  var link: (up: Bool, mbps: Int) {
    let s = regs.load16(Reg.phyStatus)
    guard s & 0x0002 != 0 else { return (false, 0) }
    let mbps = s & 0x1000 != 0 ? 5000 : s & 0x0400 != 0 ? 2500 : s & 0x0010 != 0 ? 1000 : s & 0x0008 != 0 ? 100 : 10
    return (true, mbps)
  }
}
