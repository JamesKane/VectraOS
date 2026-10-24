// SPDX-License-Identifier: BSD-3-Clause

// The Realtek RTL8126's MAC and PHY, brought up as the BSDs' rge(4) does
// (OpenBSD's, as FreeBSD has it, if_rge.c and if_rge_hw.c; the register
// sequences are Realtek's): out of out-of-band mode, the PHY powered,
// the MAC's microcontroller stopped, reset, then the MAC configured, the
// PHY set to autonegotiate every speed to 5 Gb/s, and receive and
// transmit enabled. Without Realtek's microcode: neither the MAC's patch
// table nor the PHY's RAM code is loaded, as Linux's r8169 runs the chip
// when its firmware file is missing, and the PHY's tuning for that code is
// left out with it. The registers are BAR 2's.

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

  /// Out of band, the PHY powered up, the MAC's microcontroller stopped,
  /// reset.
  func initialize() throws(Status) {
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
  /// `autonegotiate`, and EEE, ALDPS and Gigabit Lite off.
  func configurePHY() throws(Status) {
    modifyPHY(Self.mii(MII.advertise), clear: 0x01E0)
    modifyPHY(Self.mii(MII.gigabitControl), clear: 0x0300)
    modifyPHY(0xA5D4, clear: 0x0080 | 0x0100)
    writePHY(Self.mii(MII.control), MII.reset | MII.autonegotiate | MII.restart)
    guard poll(2500, every: 1000, { readPHY(Self.mii(MII.control)) & MII.reset == 0 }) else { throw .timedOut }

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

  /// Advertises every speed from 10 Mb/s to 5 Gb/s, with pause, and
  /// restarts autonegotiation.
  func autonegotiate() {
    modifyPHY(0xA428, clear: 0x0200)  // Gigabit Lite off
    modifyPHY(0xA5EA, clear: 0x0007)
    writePHY(Self.mii(MII.advertise), 0x0100 | 0x0080 | 0x0040 | 0x0020 | 0x0800 | 0x0400)
    writePHY(Self.mii(MII.gigabitControl), 0x0200 | 0x0100)
    modifyPHY(0xA5D4, set: 0x0080 | 0x0100)
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

    autonegotiate()
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
