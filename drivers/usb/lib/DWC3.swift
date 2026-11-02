// SPDX-License-Identifier: BSD-3-Clause

// A DesignWare USB 3 controller (DWC3) as a host, as bin/xhci sets it up
// before its xHCI: the core's global registers past the xHCI's, at
// 0xc100. The port is made a host's, and its two PHY interfaces, the USB
// 2 PHY's (UTMI or ULPI) and the USB 3 PHY's (PIPE), are set as its node
// says, by the DWC3 binding's quirk properties. The PHYs are never let
// suspend. Registers and bits are the core's (chinese-wall's spacemit-k1
// 08).

public struct DWC3: Equatable, Sendable {
  public static let gctl = 0xc110
  public static let gsnpsid = 0xc120
  public static let gusb2phycfg = 0xc200
  public static let gusb3pipectl = 0xc2c0

  /// `snps,hsphy_interface "utmi"`: the USB 2 PHY's interface is UTMI
  /// where the core has both; `"ulpi"`, ULPI. Else as the core reset it.
  public var hsInterfaceUTMI: Bool?
  /// `phy_type`: `"utmi"` (8 bits) or `"utmi_wide"` (16); nil for
  /// neither, the width as the core reset it.
  public var utmiWide: Bool?
  /// `snps,dis_enblslpm_quirk`: the USB 2 PHY's sleep signal kept off.
  public var noSleepSignal = false
  /// `snps,dis-u2-freeclk-exists-quirk`: the USB 2 PHY has no free
  /// running clock.
  public var noFreeClock = false
  /// `snps,dis_rxdet_inp3_quirk`: no receiver detection in P3.
  public var noReceiverDetectInP3 = false
  /// `snps,del_phy_power_chg_quirk`, `snps,dis-del-phy-power-chg-quirk`:
  /// whether the PHY's power changes are delayed (the latter wins).
  public var delayPowerChange: Bool?

  public init() {}

  /// Read from its node's properties, a line each (devmgr's /dev/dt/node).
  public init(node: String) {
    for line in node.utf8.split(separator: 0x0A) {
      let words = line.split(separator: 0x20, maxSplits: 1)
      guard let key = words.first else { continue }
      let value = words.count > 1 ? Array(words[1]).filter { $0 != UInt8(ascii: "\"") } : []
      let named = { (k: String) in key.elementsEqual(k.utf8) }
      let says = { (v: String) in value.elementsEqual(v.utf8) }
      if named("snps,hsphy_interface") {
        hsInterfaceUTMI = says("utmi") ? true : says("ulpi") ? false : nil
      } else if named("phy_type") {
        utmiWide = says("utmi") ? false : says("utmi_wide") ? true : nil
      } else if named("snps,dis_enblslpm_quirk") {
        noSleepSignal = true
      } else if named("snps,dis-u2-freeclk-exists-quirk") {
        noFreeClock = true
      } else if named("snps,dis_rxdet_inp3_quirk") {
        noReceiverDetectInP3 = true
      } else if named("snps,del_phy_power_chg_quirk") {
        if delayPowerChange == nil { delayPowerChange = true }
      } else if named("snps,dis-del-phy-power-chg-quirk") {
        delayPowerChange = false
      }
    }
  }

  /// Whether GSNPSID names a DWC3 core: DWC_usb3's, DWC_usb31's or
  /// DWC_usb32's.
  public static func isCore(_ id: UInt32) -> Bool {
    let ip = id >> 16
    return ip == 0x5533 || ip == 0x3331 || ip == 0x3332
  }

  /// GCTL: the port a host's (PRTCAPDIR 1), no scale-down.
  public func gctl(_ old: UInt32) -> UInt32 {
    old & ~(3 << 12 | 3 << 4) | 1 << 12
  }

  /// GUSB2PHYCFG(0): the interface and its width, no suspend, the
  /// sleep signal and the free clock as the quirks say.
  public func usb2(_ old: UInt32) -> UInt32 {
    var r = old
    if let utmi = hsInterfaceUTMI { r = utmi ? r & ~(1 << 4) : r | 1 << 4 }
    if let wide = utmiWide {
      // PHYIF and USBTRDTIM: 8 bits and 9 clocks, or 16 and 5.
      r = r & ~(1 << 3 | 0xF << 10) | (wide ? 1 << 3 | 5 << 10 : 9 << 10)
    }
    r &= ~(1 << 6)
    r = noSleepSignal ? r & ~(1 << 8) : r | 1 << 8
    if noFreeClock { r &= ~(1 << 30) }
    return r
  }

  /// GUSB3PIPECTL(0): no suspend nor UX_EXIT_PX, and the quirks.
  public func usb3(_ old: UInt32) -> UInt32 {
    var r = old & ~(1 << 27 | 1 << 17)
    if noReceiverDetectInP3 { r |= 1 << 28 }
    if let delay = delayPowerChange { r = delay ? r | 1 << 18 : r & ~(1 << 18) }
    return r
  }
}
