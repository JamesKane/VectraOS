// SPDX-License-Identifier: BSD-3-Clause

// devmgr's supplies for a platform device (Supplies.swift, D170): one per
// provider link, in the order a power-up goes, and the name of the window
// VMO that tells a driver host the range it stands for.

import DevMgr
import DeviceTreeBus
import DriverHost
import Testing

private func gpu() -> Device.ACPIDevice {
  var d = Device.ACPIDevice(path: "\\_SB_.GPU_", hid: "CIXH5000", cids: [], status: 0x0B,
                            resources: [.mmio(base: 0x1500_0000, size: 0x1_0000), .interrupt(0x10D, .levelHigh)])
  d.links = [DeviceLink(kind: "reset", name: "gpu_reset", provider: "", cells: [9]),
             DeviceLink(kind: "clock", name: "gpu_clk_core", provider: "", cells: [0x1F]),
             DeviceLink(kind: "clock", name: "gpu_clk_stacks", provider: "", cells: [0x20]),
             DeviceLink(kind: "gpio", name: "int", provider: "", cells: [1])]
  d.powered = true
  d.properties = "compatible arm,mali\npower-domains 14\n"
  return d
}

@Test func aDeviceHasASupplyForEachProviderLinkInPowerUpOrder() {
  #expect(Supplies.links(of: gpu()) == [
    SupplyLink(kind: "domain", name: "power-domains", raw: 14),
    SupplyLink(kind: "clock", name: "gpu_clk_core", raw: 0x1F),
    SupplyLink(kind: "clock", name: "gpu_clk_stacks", raw: 0x20),
    SupplyLink(kind: "power", name: "_PR0", raw: 0),
    SupplyLink(kind: "reset", name: "gpu_reset", raw: 9),
  ])
}

@Test func aDeviceWithNoMemoryRangeHasNoSupply() {
  var d = gpu()
  d.resources = [.interrupt(0x10D, .levelHigh)]
  #expect(Supplies.links(of: d).isEmpty)
}

@Test func aDeviceWithNoProviderHasNone() {
  let d = Device.ACPIDevice(path: "\\_SB_.UAR0", hid: "ARMH0011", cids: [], status: 0x0F,
                            resources: [.mmio(base: 0x9000_0000, size: 0x1000)])
  #expect(Supplies.links(of: d).isEmpty)
}

@Test func powerDomainsReadSeveralNumbersAndStopAtAWord() {
  var d = gpu()
  d.properties = "power-domains 3 4 5\nother 9\n"
  #expect(Supplies.links(of: d).filter { $0.kind == "domain" }.map { $0.raw } == [3, 4, 5])
  d.properties = "power-domains 3 \\_SB_.PD00\n"
  #expect(Supplies.links(of: d).filter { $0.kind == "domain" }.map { $0.raw } == [3])
}

@Test func aWindowVMOsNameSaysItsRange() {
  let name = DeviceHandle.windowName(base: 0x1500_0800, size: 0x400)
  #expect(name == "m15000800:400")
  #expect(name.utf8.count <= 31)
  let range = DeviceHandle.parseWindow(name)
  #expect(range?.base == 0x1500_0800 && range?.size == 0x400)
  let big = DeviceHandle.windowName(base: 0xFFFF_FFFF_F000_0000, size: 0x1_0000_0000)
  #expect(big.utf8.count <= 31)
  #expect(DeviceHandle.parseWindow(big)?.base == 0xFFFF_FFFF_F000_0000)
  for other in ["", "m", "m15:", "m:15", "x15:1", "m1g:2", "mailbox", "m15:1:2"] {
    #expect(DeviceHandle.parseWindow(other) == nil)
  }
}
