// SPDX-License-Identifier: BSD-3-Clause

// The SpacemiT K1's Ethernet MAC (k1-emac(3)), as bin/k1-emac drives it:
// its registers and descriptors, its MDIO commands, how a PHY's clause 22
// registers say what the link is, what the driver reads from its node
// (devmgr's /dev/dt/node), and what it asks the APMU for its interface. The
// registers and bits are the hardware's, and a Motorcomm PHY's RGMII
// delays its own (chinese-wall's spacemit-k1 06).

import DriverHost

/// The MAC's registers: its DMA's from 0, the MAC's own from 0x100.
public enum Register {
  public static let dmaConfiguration = 0x000
  public static let dmaControl = 0x004
  public static let dmaStatus = 0x008
  public static let dmaInterruptEnable = 0x00C
  public static let transmitAutoPoll = 0x010
  public static let transmitPollDemand = 0x014
  public static let receivePollDemand = 0x018
  public static let transmitBase = 0x01C
  public static let receiveBase = 0x020
  public static let missedFrames = 0x024
  public static let receiveMitigation = 0x02C

  public static let globalControl = 0x100
  public static let transmitControl = 0x104
  public static let receiveControl = 0x108
  public static let maximumFrameSize = 0x10C
  public static let transmitJabberSize = 0x110
  public static let receiveJabberSize = 0x114
  public static let addressControl = 0x118
  /// Three registers, two bytes each, the first two bytes first.
  public static let address1 = 0x120
  public static let multicastHash = 0x150  // four
  public static let flowControl = 0x160
  public static let flowControlSource = 0x168  // three, as address1
  public static let pauseHighThreshold = 0x18C
  public static let pauseLowThreshold = 0x190
  public static let highPauseTime = 0x184
  public static let mdioControl = 0x1A0
  public static let mdioData = 0x1A4
  public static let transmitFIFOAlmostFull = 0x1C0
  public static let transmitStartThreshold = 0x1C4
  public static let receiveStartThreshold = 0x1C8
  public static let macInterruptEnable = 0x1E4
  /// The extent of its registers, its node's `reg`.
  public static let size = 0x420
}

public enum Bits {
  // DMA configuration.
  public static let softwareReset: UInt32 = 1 << 0
  public static let burst16Words: UInt32 = 1 << 5
  public static let strictBurst: UInt32 = 1 << 17
  public static let dma64Bit: UInt32 = 1 << 18
  // DMA control.
  public static let startTransmit: UInt32 = 1 << 0
  public static let startReceive: UInt32 = 1 << 1
  // DMA status and interrupt enable: the same bits.
  public static let transmitDone: UInt32 = 1 << 0
  public static let transmitUnavailable: UInt32 = 1 << 1
  public static let transmitStopped: UInt32 = 1 << 2
  public static let receiveDone: UInt32 = 1 << 4
  public static let receiveUnavailable: UInt32 = 1 << 5
  public static let receiveStopped: UInt32 = 1 << 6
  public static let receiveMissed: UInt32 = 1 << 7
  /// Every cause the status register latches (bits 0-8), written back to
  /// clear them.
  public static let causes: UInt32 = 0x1F7
  /// The causes the driver is interrupted for.
  public static let interrupts = transmitDone | transmitStopped | receiveDone | receiveStopped | receiveMissed
  // Global control.
  public static let speedMask: UInt32 = 0x3
  public static let speed100: UInt32 = 1 << 0
  public static let speed1000: UInt32 = 1 << 1
  public static let fullDuplex: UInt32 = 1 << 2
  // Transmit and receive control.
  public static let transmitEnable: UInt32 = 1 << 0
  public static let transmitAutoRetry: UInt32 = 1 << 3
  public static let interFrameGapMask: UInt32 = 0x70
  public static let receiveEnable: UInt32 = 1 << 0
  public static let storeAndForward: UInt32 = 1 << 3
  // Address control.
  public static let address1Enable: UInt32 = 1 << 0
  // MDIO control.
  public static let mdioRead: UInt32 = 1 << 10
  public static let mdioStart: UInt32 = 1 << 15
}

/// The MAC's settings, SpacemiT's tuning (spacemit-k1 06 §6.9).
public enum Tuning {
  public static let transmitFIFOAlmostFull: UInt32 = 0x1F8
  public static let transmitStartThreshold: UInt32 = 1518
  public static let receiveStartThreshold: UInt32 = 12
  public static let pauseHighThreshold: UInt32 = 1600
  public static let pauseTime: UInt32 = 0xFFFF
  /// A frame of 1500 bytes' payload, its header, two VLAN tags and its FCS.
  public static let maximumFrame: UInt32 = 1500 + 14 + 8 + 4
  /// Receive interrupts held for 64 frames or 600 us (at 312 MHz).
  public static let receiveMitigation: UInt32 = 1 << 31 | (600 * 312) << 8 | 64
  /// The 802.3x pause frames' destination.
  public static let pauseAddress: [UInt8] = [0x01, 0x80, 0xC2, 0x00, 0x00, 0x01]
}

/// The three registers an address is written to, two bytes each, the
/// first two bytes in the first.
public func addressWords(_ mac: [UInt8]) -> [UInt32] {
  [0, 2, 4].map { UInt32(mac[$0 + 1]) << 8 | UInt32(mac[$0]) }
}

/// A descriptor: 16 bytes, four words. The first is the status, with OWN
/// (the DMA's while set); the second the buffer's size and flags; the
/// third the buffer's address, 32 bits. The last in a ring is marked.
public enum Descriptor {
  public static let size = 16
  public static let own: UInt32 = 1 << 31
  public static let endOfRing: UInt32 = 1 << 26
  public static let sizeMask: UInt32 = 0xFFF
  // Transmit, the second word.
  public static let firstSegment: UInt32 = 1 << 29
  public static let lastSegment: UInt32 = 1 << 30
  public static let interruptOnCompletion: UInt32 = 1 << 31
  // Receive, the first word.
  public static let lengthMask: UInt32 = 0x3FFF
  public static let runt: UInt32 = 1 << 15
  public static let crcError: UInt32 = 1 << 20
  public static let maxLengthError: UInt32 = 1 << 21
  public static let jabberError: UInt32 = 1 << 22
  public static let lengthError: UInt32 = 1 << 23
  public static let lastDescriptor: UInt32 = 1 << 29
  public static let firstDescriptor: UInt32 = 1 << 30
  public static let errors = runt | crcError | maxLengthError | jabberError | lengthError

  /// A receive descriptor's second word: its buffer's size, and the mark
  /// if it is the ring's last.
  public static func receive(size: Int, last: Bool) -> UInt32 {
    UInt32(size) & sizeMask | (last ? endOfRing : 0)
  }

  /// A transmit descriptor's second word: a frame of `length` bytes in
  /// one buffer, which interrupts when sent.
  public static func transmit(length: Int, last: Bool) -> UInt32 {
    firstSegment | lastSegment | interruptOnCompletion | UInt32(length) & sizeMask | (last ? endOfRing : 0)
  }

  /// The frame's length without its FCS, from a receive descriptor the
  /// DMA gave back; nil if it is in error, spans buffers, or is shorter
  /// than a header or longer than `limit`.
  public static func received(_ status: UInt32, limit: Int) -> Int? {
    guard status & (firstDescriptor | lastDescriptor) == firstDescriptor | lastDescriptor,
      status & errors == 0
    else { return nil }
    let n = Int(status & lengthMask) - 4
    return n >= 14 && n <= limit ? n : nil
  }
}

/// An MDIO command: a read or write of `register` on the PHY at
/// `phy`, started.
public func mdioCommand(phy: UInt32, register: UInt32, read: Bool) -> UInt32 {
  phy & 0x1F | (register & 0x1F) << 5 | (read ? Bits.mdioRead : 0) | Bits.mdioStart
}

/// A link: its speed in Mb/s and whether it is full duplex.
public struct LinkMode: Equatable, Sendable {
  public var mbps: Int
  public var fullDuplex: Bool
  public init(mbps: Int, fullDuplex: Bool) {
    self.mbps = mbps
    self.fullDuplex = fullDuplex
  }

  /// The MAC's global control with this link's speed and duplex.
  public func control(_ old: UInt32) -> UInt32 {
    let speed = mbps == 1000 ? Bits.speed1000 : mbps == 100 ? Bits.speed100 : 0
    return old & ~(Bits.speedMask | Bits.fullDuplex) | speed | (fullDuplex ? Bits.fullDuplex : 0)
  }
}

/// A PHY's clause 22 registers.
public enum PHY {
  public static let control = 0, status = 1, id1 = 2, id2 = 3, advertise = 4, partner = 5
  public static let control1000 = 9, status1000 = 10
  public static let reset: UInt16 = 1 << 15
  public static let autonegotiate: UInt16 = 1 << 12
  public static let restart: UInt16 = 1 << 9
  public static let linked: UInt16 = 1 << 2
  public static let negotiated: UInt16 = 1 << 5
  /// 10 and 100 Mb/s, half and full duplex, 802.3.
  public static let advertised: UInt16 = 0x01E1
  /// 1000 Mb/s, full duplex only.
  public static let advertised1000: UInt16 = 1 << 9

  /// The link the registers say is up, the best both ends advertise;
  /// nil while it is down or still negotiating.
  public static func link(status: UInt16, advertise: UInt16, partner: UInt16, control1000: UInt16,
                          status1000: UInt16) -> LinkMode?
  {
    guard status & linked != 0, status & negotiated != 0 else { return nil }
    let gigabit = control1000 & (status1000 >> 2)
    if gigabit & 0x200 != 0 { return LinkMode(mbps: 1000, fullDuplex: true) }
    if gigabit & 0x100 != 0 { return LinkMode(mbps: 1000, fullDuplex: false) }
    let common = advertise & partner
    if common & 0x100 != 0 { return LinkMode(mbps: 100, fullDuplex: true) }
    if common & 0x080 != 0 { return LinkMode(mbps: 100, fullDuplex: false) }
    return LinkMode(mbps: 10, fullDuplex: common & 0x040 != 0)
  }
}

/// A Motorcomm YT8531's RGMII clocks: its extended registers, read and
/// written through clause 22's 0x1e (the register) and 0x1f (its data).
public enum Motorcomm {
  public static let yt8531: UInt32 = 0x4F51_E91B
  public static let select = 0x1E, data = 0x1F
  public static let chipConfig: UInt16 = 0xA001
  public static let rgmiiConfig1: UInt16 = 0xA003
  public static let sleepControl: UInt16 = 0x27
  /// The extended writes a mode takes, each `(register, mask, value)`: the
  /// receive clock's 1.9 ns delay off, then 1.95 ns (13 steps of 150 ps)
  /// on the clocks the mode leaves to the PHY; and with `noSleep`, auto
  /// sleep off.
  public static func setup(_ mode: PHYMode, noSleep: Bool) -> [(register: UInt16, mask: UInt16, value: UInt16)] {
    let rx: UInt16 = 13 << 10, tx: UInt16 = 13
    let delays: UInt16 =
      switch mode {
      case .rgmii, .rmii: 0
      case .rgmiiID: rx | tx
      case .rgmiiRXID: rx
      case .rgmiiTXID: tx
      }
    var out: [(register: UInt16, mask: UInt16, value: UInt16)] = [
      (chipConfig, 1 << 8, 0), (rgmiiConfig1, 0x3C0F, delays),
    ]
    if noSleep { out.append((sleepControl, 1 << 15, 0)) }
    return out
  }
}

/// The node's `phy-mode`: the delays an RGMII mode leaves to the PHY.
public enum PHYMode: Equatable, Sendable {
  case rgmii, rgmiiID, rgmiiRXID, rgmiiTXID, rmii

  public init?(_ name: String) {
    let modes: [(String, PHYMode)] = [("rgmii", .rgmii), ("rgmii-id", .rgmiiID), ("rgmii-rxid", .rgmiiRXID),
                                      ("rgmii-txid", .rgmiiTXID), ("rmii", .rmii)]
    guard let m = modes.first(where: { $0.0.utf8.elementsEqual(name.utf8) }) else { return nil }
    self = m.1
  }

  public var isRGMII: Bool { self != .rmii }
}

/// What the driver reads from its node (`/dev/dt/node`, a property a
/// line, as dtc writes them).
public struct NodeConfig: Equatable, Sendable {
  public var mode: PHYMode
  /// The MAC's own delay lines' codes, from `tx-internal-delay-ps` and
  /// `rx-internal-delay-ps` in steps of 15.6 ps.
  public var txDelay: UInt32
  public var rxDelay: UInt32
  /// The PHY's address on the MDIO bus: `reg` of the first node under
  /// `mdio-bus`; nil if it names none.
  public var phy: UInt32?
  /// Whether that PHY's auto sleep is to be off.
  public var phyNoSleep: Bool
  /// `local-mac-address`, else `mac-address`, if a unicast address and not
  /// zero.
  public var mac: [UInt8]?

  /// The largest delay the lines take, in ps (code 254).
  public static let maxDelay: UInt32 = 3962

  public init(mode: PHYMode, txDelay: UInt32 = 0, rxDelay: UInt32 = 0, phy: UInt32? = nil, phyNoSleep: Bool = false,
              mac: [UInt8]? = nil) {
    self.mode = mode
    self.txDelay = txDelay
    self.rxDelay = rxDelay
    self.phy = phy
    self.phyNoSleep = phyNoSleep
    self.mac = mac
  }

  /// Read from the node's text; nil without a mode the MAC has, or with a
  /// delay past its lines'.
  public init?(node text: String) {
    var mode: PHYMode?, tx: UInt32 = 0, rx: UInt32 = 0, phy: UInt32?, noSleep = false
    var local: [UInt8]?, fixed: [UInt8]?
    for line in text.utf8.split(separator: 0x0A) {
      let space = line.firstIndex(of: 0x20) ?? line.endIndex
      let name = Array(line[..<space]), value = Array(line[space...].dropFirst())
      if name.elementsEqual("phy-mode".utf8) {
        mode = PHYMode(String(decoding: value.filter { $0 != UInt8(ascii: "\"") }, as: UTF8.self))
      } else if name.elementsEqual("tx-internal-delay-ps".utf8) {
        guard let v = Self.cells(value).first else { return nil }
        tx = v
      } else if name.elementsEqual("rx-internal-delay-ps".utf8) {
        guard let v = Self.cells(value).first else { return nil }
        rx = v
      } else if name.elementsEqual("local-mac-address".utf8) {
        local = Self.bytes(value)
      } else if name.elementsEqual("mac-address".utf8) {
        fixed = Self.bytes(value)
      } else if name.starts(with: "mdio-bus/".utf8), let slash = name.dropFirst(9).firstIndex(of: 0x2F) {
        // The first PHY's: `mdio-bus/phy@1/reg <0x1>`.
        let property = name[(slash + 1)...]
        if phy == nil, property.elementsEqual("reg".utf8) { phy = Self.cells(value).first }
        if property.elementsEqual("motorcomm,auto-sleep-disabled".utf8) { noSleep = true }
      }
    }
    guard let mode, tx <= Self.maxDelay, rx <= Self.maxDelay else { return nil }
    let usable = { (m: [UInt8]?) -> [UInt8]? in
      guard let m, m.count == 6, m.contains(where: { $0 != 0 }), m[0] & 1 == 0 else { return nil }
      return m
    }
    self.init(mode: mode, txDelay: Self.code(tx), rxDelay: Self.code(rx), phy: phy, phyNoSleep: noSleep,
              mac: usable(local) ?? usable(fixed))
  }

  /// A delay in ps as a code of 15.6 ps steps, rounded.
  public static func code(_ ps: UInt32) -> UInt32 { (ps * 10 + 78) / 156 }

  /// `<0x1 0x2>`'s cells.
  static func cells(_ v: [UInt8]) -> [UInt32] {
    guard v.first == UInt8(ascii: "<"), v.last == UInt8(ascii: ">") else { return [] }
    return v.dropFirst().dropLast().split(separator: 0x20).compactMap { w in
      guard w.count > 2, w.starts(with: "0x".utf8) else { return nil }
      return UInt32(String(decoding: w.dropFirst(2), as: UTF8.self), radix: 16)
    }
  }

  /// `[00 1a]`'s bytes.
  static func bytes(_ v: [UInt8]) -> [UInt8]? {
    guard v.first == UInt8(ascii: "["), v.last == UInt8(ascii: "]") else { return nil }
    var out: [UInt8] = []
    for w in v.dropFirst().dropLast().split(separator: 0x20) {
      guard let b = UInt8(String(decoding: w, as: UTF8.self), radix: 16) else { return nil }
      out.append(b)
    }
    return out
  }
}

/// The command the APMU's `ctl` (k1-syscon(3)) takes for the MAC's
/// `spacemit,apmu` link: its interface and delay lines; nil for another
/// link.
public func emacCommand(_ link: ProvidedLink, _ config: NodeConfig) -> String? {
  guard link.isKind("syscon"), let offset = link.cells.first else { return nil }
  return "emac 0x\(String(offset, radix: 16)) \(config.mode.isRGMII ? "rgmii" : "rmii") \(config.txDelay) \(config.rxDelay)"
}
