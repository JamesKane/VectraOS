// SPDX-License-Identifier: BSD-3-Clause

// The K1's PCIe PHYs as bin/k1-pcie-phy drives them: the combo PHY's
// calibration read and served, a port's lanes, and the writes that set
// up its lanes and PLL.

import K1PciePhy
import Testing

@Test func theCombosCalibrationIsItsResultOnceDone() {
  #expect(Termination(result: 0x0000_0468) == Termination(rx: 8, tx: 6))
  #expect(Termination(result: 0x68) == nil)
  let t = Termination(rx: 8, tx: 6)
  #expect(t.description == "rx 8 tx 6")
  #expect(Termination("rx 8 tx 6\n") == t)
  #expect(Termination("") == nil && Termination("rx 16 tx 0") == nil && Termination("tx 8 rx 6") == nil)
}

@Test func aPortsLanesAreItsNodesOrTwo() {
  #expect(K1PciePhy.lanes(node: "compatible \"spacemit,k1-pcie-phy\"\nnum-lanes <0x1>\n") == 1)
  #expect(K1PciePhy.lanes(node: "num-lanes <0x2>\n") == 2)
  #expect(K1PciePhy.lanes(node: "num-lanes <0x4>\n") == 2)
  #expect(K1PciePhy.lanes(node: "compatible \"spacemit,k1-pcie-phy\"\n") == 2)
}

@Test func setupWritesEachLaneThenThePLL() {
  let u = K1PciePhy.setup(lanes: 2, Termination(rx: 8, tx: 6))
  // Six writes a lane, its timer for each, four for the PLL, and each
  // lane marked done.
  #expect(u.count == 6 * 2 + 2 + 4 + 2)
  #expect(u[0] == PhyUpdate(0x50, mask: 0xF08, value: 0x808))
  #expect(u[2] == PhyUpdate(0x64, mask: 0x200_F000, value: 0x200_6000))
  #expect(u[6].register == 0x450)
  // The RC calibration: CLKSEL's bits kept and 24 MHz's set, the rest
  // cleared, then the toggle.
  #expect(u[3].apply(0x8123_4567) == 0xE000_0000)
  #expect(u[4].apply(0xE000_0000) == 0xE040_0000)
  #expect(u[5].apply(0x0000_02FF) == 0x0000_05FF)
  #expect(u[12] == PhyUpdate(0x08, mask: 0x780, value: 0x300) && u[13].register == 0x408)
  // The PLL from 24 MHz, no spread spectrum: FREF_SEL 1, REF_100_WSSC clear.
  #expect(u[15].apply(0x000A_0000) == 0 && u[17].apply(0x0000_F000) == 0x2000)
  #expect(u.suffix(2) == [PhyUpdate(0x08, mask: 0x800, value: 0x800), PhyUpdate(0x408, mask: 0x800, value: 0x800)])
  #expect(u.allSatisfy { $0.register + 4 <= PhyRegister.size })
  #expect(K1PciePhy.setup(lanes: 1, Termination(rx: 0, tx: 0)).allSatisfy { $0.register < PhyRegister.lane })
}
