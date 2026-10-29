// SPDX-License-Identifier: BSD-3-Clause

// The combo PHY's settings and a stream's registers (D146), against what
// firmware left on the Orange Pi 6 Plus: 1080p at 60 Hz on HBR x4.

import DPTX
import Testing

@Test func eachRateHasItsPLL1Setting() {
  // Firmware's HBR, as the board's PHY reads.
  let hbr = ComboPHY.setting(rate: 0x0A)!
  #expect(hbr.clockSelect == 0x0701 && hbr.intDiv == 0x1C2 && hbr.highThreshold == 0x12C && hbr.hsClockDivider == 1)
  #expect(ComboPHY.rate(clockSelect: 0x0701, intDiv: 0x1C2, hsClockDivider: 1) == 0x0A)
  #expect(ComboPHY.rate(clockSelect: 0x0F01, intDiv: 0x195, hsClockDivider: 2) == 0x06)
  #expect(ComboPHY.rate(clockSelect: 0x0301, intDiv: 0x1C2, hsClockDivider: 0) == 0x14)
  // HBR3's setting is an open question: not offered.
  #expect(ComboPHY.setting(rate: 0x1E) == nil)
  // The extras first, the four lanes' dividers, then PLL1, its clock select last.
  let w = ComboPHY.rateWrites(ComboPHY.setting(rate: 0x06)!)
  #expect(w.count == 12 && w.filter { $0.lane != nil }.count == 4)
  #expect(w.last!.index == ComboPHY.pll1ClockSelect && w.last!.value == 0x0F01)
  // A register's index is a word; a lane's are 0x200 indices apart.
  #expect(ComboPHY.offset(ComboPHY.margin, lane: 1) == (0x4050 + 0x200) * 4)
}

@Test func driveLevelsComeFromTheTable() {
  #expect(ComboPHY.drive(swing: 0, preEmphasis: 0) == (0x28, 0))
  #expect(ComboPHY.drive(swing: 1, preEmphasis: 1) == (0x13, 0x12))
  #expect(ComboPHY.drive(swing: 3, preEmphasis: 0) == (0, 0))
  // Past a sum of 3, clamped as the vendor's table fills it.
  #expect(ComboPHY.drive(swing: 2, preEmphasis: 3) == (0, 0x13))
}

let p1080 = StreamTiming(clock: 148_500, hActive: 1920, hSyncStart: 2008, hSyncEnd: 2052, hTotal: 2200,
                         vActive: 1080, vSyncStart: 1084, vSyncEnd: 1089, vTotal: 1125, hPositive: true, vPositive: true)

@Test func aModeTakesTheSlowestLinkThatCarriesIt() {
  // 1080p60: RBR x4 has 5 % to spare, RBR x2 doesn't.
  let c = LinkMath.candidates(clock: 148_500, maxRate: 0x14, maxLanes: 4)
  #expect(c.first! == (0x06, 4))
  #expect(c.map { $0.lanes } == [4, 2, 4, 1, 2, 4])  // HBR2 x1 carries it too
  #expect(LinkMath.candidates(clock: 25_175, maxRate: 0x14, maxLanes: 4).first! == (0x06, 1))
  #expect(LinkMath.candidates(clock: 800_000, maxRate: 0x14, maxLanes: 4).isEmpty)
  // HBR2 x4 carries 720 MHz at 24 bits a pixel; HBR3 isn't trained.
  #expect(LinkMath.capacity(maxRate: 0x14, maxLanes: 4) == 720_000)
  #expect(LinkMath.capacity(maxRate: 0x1E, maxLanes: 4) == 720_000)
}

@Test func theStreamsRegistersAreFirmwares() {
  // Firmware's values on the board: TU 26 6/16, data count 1440, window
  // 114, HSTART 192, VSTART 41, polarity 3, user sync 0xF.
  let regs = LinkMath.streamRegisters(p1080, rate: 0x0A, lanes: 4, invertSyncs: false)
  func value(_ o: Int) -> UInt32? { regs.last { $0.offset == o }?.value }
  #expect(value(DPTXRegisters.transferUnit) == 0x061A_0040)
  #expect(value(DPTXRegisters.userDataCount) == 1440)
  #expect(value(DPTXRegisters.secondaryDataWindow) == 114)
  #expect(value(DPTXRegisters.hStart) == 192 && value(DPTXRegisters.vStart) == 41)
  #expect(value(DPTXRegisters.polarity) == 3 && value(DPTXRegisters.userSyncPolarity) == 0xF)
  #expect(value(DPTXRegisters.misc0) == 0x20 && value(DPTXRegisters.dataControl) == 0x2004)
  // The transfer unit written 64 first.
  #expect(regs.first { $0.offset == DPTXRegisters.transferUnit }!.value == 64)
  // At RBR x4 the board ran 44 0/16.
  #expect(LinkMath.transferUnit(clock: 148_500, rate: 0x06, lanes: 4) == 0x002C_0040)
  #expect(!StreamTiming(clock: 1, hActive: 10, hSyncStart: 5, hSyncEnd: 20, hTotal: 30, vActive: 1, vSyncStart: 2,
                        vSyncEnd: 3, vTotal: 4, hPositive: true, vPositive: true).isValid)
}
