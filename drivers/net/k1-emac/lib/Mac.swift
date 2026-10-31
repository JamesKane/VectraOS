// SPDX-License-Identifier: BSD-3-Clause

// The K1 EMAC's registers as bin/k1-emac uses them (Emac.swift has their
// names): stopping it, setting it up as Linux's k1_emac.c does, its MDIO
// bus and the PHY on it, its address, and starting its DMA on the rings.

import DriverHost
import Sys

final class Mac: @unchecked Sendable {
  let regs: Registers

  init(_ regs: consuming Registers) { self.regs = regs }

  func load(_ r: Int) -> UInt32 { regs.load32(r) }
  func store(_ r: Int, _ v: UInt32) { regs.store32(r, v) }

  /// Interrupts off, the MAC's receiver and transmitter off, the DMA
  /// stopped: as firmware may have left it running.
  func stop() {
    store(Register.macInterruptEnable, 0)
    store(Register.dmaInterruptEnable, 0)
    store(Register.receiveControl, 0)
    store(Register.transmitControl, 0)
    store(Register.dmaControl, 0)
  }

  /// The MAC's filters, thresholds and frame sizes, flow control's
  /// settings (left off), receive interrupt mitigation, then the DMA
  /// reset and configured: 16-word strict bursts, 64-bit.
  func setUp() {
    store(Register.receiveControl, 0)
    store(Register.transmitControl, 0)
    store(Register.addressControl, Bits.address1Enable)
    for i in 0..<4 { store(Register.multicastHash + 4 * i, 0) }
    store(Register.transmitFIFOAlmostFull, Tuning.transmitFIFOAlmostFull)
    store(Register.transmitStartThreshold, Tuning.transmitStartThreshold)
    store(Register.receiveStartThreshold, Tuning.receiveStartThreshold)
    store(Register.maximumFrameSize, Tuning.maximumFrame)
    store(Register.transmitJabberSize, Tuning.maximumFrame)
    store(Register.receiveJabberSize, Tuning.maximumFrame)
    setAddress(Tuning.pauseAddress, at: Register.flowControlSource)
    store(Register.pauseHighThreshold, Tuning.pauseHighThreshold)
    store(Register.highPauseTime, Tuning.pauseTime)
    store(Register.pauseLowThreshold, 0)
    store(Register.receiveMitigation, Tuning.receiveMitigation)
    store(Register.dmaControl, 0)
    store(Register.dmaConfiguration, Bits.softwareReset)
    pause(10_000_000)
    store(Register.dmaConfiguration, 0)
    pause(10_000_000)
    store(Register.dmaConfiguration, Bits.strictBurst | Bits.dma64Bit | Bits.burst16Words)
  }

  func setAddress(_ mac: [UInt8], at register: Int = Register.address1) {
    for (i, w) in addressWords(mac).enumerated() { store(register + 4 * i, w) }
  }

  /// The address in the first filter, as firmware may have left it.
  var address: [UInt8] {
    (0..<3).flatMap { i -> [UInt8] in
      let w = load(Register.address1 + 4 * i)
      return [UInt8(truncatingIfNeeded: w), UInt8(truncatingIfNeeded: w >> 8)]
    }
  }

  /// The rings' bus addresses, then each side started.
  func start(receive: UInt32, transmit: UInt32) {
    store(Register.transmitBase, transmit)
    store(Register.receiveBase, receive)
    store(Register.transmitControl,
          load(Register.transmitControl) & ~Bits.interFrameGapMask | Bits.transmitEnable | Bits.transmitAutoRetry)
    store(Register.transmitAutoPoll, 0)
    store(Register.receiveControl, load(Register.receiveControl) | Bits.receiveEnable | Bits.storeAndForward)
    store(Register.dmaControl, Bits.startTransmit | Bits.startReceive)
    store(Register.macInterruptEnable, 0)
    store(Register.dmaInterruptEnable, Bits.interrupts)
  }

  /// The causes latched, cleared.
  func takeCauses() -> UInt32 {
    let s = load(Register.dmaStatus) & Bits.causes
    if s != 0 { store(Register.dmaStatus, s) }
    return s
  }

  func kickTransmit() { store(Register.transmitPollDemand, 1) }
  func kickReceive() { store(Register.receivePollDemand, 1) }

  func setLink(_ link: LinkMode) { store(Register.globalControl, link.control(load(Register.globalControl))) }

  // MARK: MDIO

  /// Waits for the MDIO command to end: false after 10 ms.
  func mdioIdle() -> Bool {
    let deadline = Clock.monotonic() + 10_000_000
    while load(Register.mdioControl) & Bits.mdioStart != 0 {
      guard Clock.monotonic() < deadline else { return false }
      pause(100_000)
    }
    return true
  }

  func mdioRead(_ phy: UInt32, _ register: Int) -> UInt16? {
    store(Register.mdioData, 0)
    store(Register.mdioControl, mdioCommand(phy: phy, register: UInt32(register), read: true))
    guard mdioIdle() else { return nil }
    return UInt16(truncatingIfNeeded: load(Register.mdioData))
  }

  @discardableResult
  func mdioWrite(_ phy: UInt32, _ register: Int, _ value: UInt16) -> Bool {
    store(Register.mdioData, UInt32(value))
    store(Register.mdioControl, mdioCommand(phy: phy, register: UInt32(register), read: false))
    return mdioIdle()
  }

  /// The PHY's id (its registers 2 and 3); nil if nothing answers.
  func phyID(_ phy: UInt32) -> UInt32? {
    guard let a = mdioRead(phy, PHY.id1), let b = mdioRead(phy, PHY.id2) else { return nil }
    let id = UInt32(a) << 16 | UInt32(b)
    return id == 0 || id == 0xFFFF_FFFF ? nil : id
  }

  /// The first address 0-31 a PHY answers at.
  func findPHY() -> UInt32? { (0..<32).first { phyID($0) != nil } }

  /// The PHY reset, its vendor's setup for `config`'s mode, then
  /// autonegotiation started, advertising 10, 100 and 1000 Mb/s; false if
  /// it doesn't come out of reset.
  func setUpPHY(_ phy: UInt32, id: UInt32, _ config: NodeConfig) -> Bool {
    mdioWrite(phy, PHY.control, PHY.reset)
    let deadline = Clock.monotonic() + 500_000_000
    while (mdioRead(phy, PHY.control) ?? PHY.reset) & PHY.reset != 0 {
      guard Clock.monotonic() < deadline else { return false }
      pause(1_000_000)
    }
    if id == Motorcomm.yt8531 {
      for (register, mask, value) in Motorcomm.setup(config.mode, noSleep: config.phyNoSleep) {
        mdioWrite(phy, Motorcomm.select, register)
        let old = mdioRead(phy, Motorcomm.data) ?? 0
        mdioWrite(phy, Motorcomm.select, register)
        mdioWrite(phy, Motorcomm.data, old & ~mask | value)
      }
    }
    mdioWrite(phy, PHY.advertise, PHY.advertised)
    mdioWrite(phy, PHY.control1000, PHY.advertised1000)
    mdioWrite(phy, PHY.control, PHY.autonegotiate | PHY.restart)
    return true
  }

  /// The link the PHY says is up; nil while it is down.
  func phyLink(_ phy: UInt32) -> LinkMode? {
    // The link bit latches low: the second read is now.
    _ = mdioRead(phy, PHY.status)
    guard let status = mdioRead(phy, PHY.status), let advertise = mdioRead(phy, PHY.advertise),
      let partner = mdioRead(phy, PHY.partner), let c1000 = mdioRead(phy, PHY.control1000),
      let s1000 = mdioRead(phy, PHY.status1000)
    else { return nil }
    return PHY.link(status: status, advertise: advertise, partner: partner, control1000: c1000, status1000: s1000)
  }
}

/// Sleeps `ns` nanoseconds.
func pause(_ ns: Int64) { sleep(until: Clock.monotonic() + ns) }
