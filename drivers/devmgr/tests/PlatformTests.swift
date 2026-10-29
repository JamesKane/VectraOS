// SPDX-License-Identifier: BSD-3-Clause

// What a platform device's driver gets past its _CRS (Platform.swift): CIX's
// clock and reset tables as the Sky1's GPU has them, which BAR each linked
// range is, and the board rule for the Sky1's SCMI over SMC.

import DevMgr
import Sys
import TDACPI
import Testing

@Test func cixTablesNameTheGPUsClocksAndResets() {
  let rst0 = 7, gpu = 9
  let clkt = Datum.package(PackageObject([
    .package(PackageObject([.integer(0x1F), .string(Array("gpu_clk_core".utf8)), .reference(.node(gpu))])),
    .package(PackageObject([.integer(0x20), .string(Array("gpu_clk_stacks".utf8)), .reference(.node(gpu))])),
    .integer(3),  // not a package: left out
  ]))
  #expect(PlatformTables.clocks(clkt) == [Device.Clock(id: 0x1F, name: "gpu_clk_core"),
                                         Device.Clock(id: 0x20, name: "gpu_clk_stacks")])
  let rstl = Datum.package(PackageObject([
    .package(PackageObject([.reference(.node(rst0)), .integer(9), .reference(.node(gpu)), .string(Array("gpu_reset".utf8))])),
    .package(PackageObject([.reference(.node(rst0)), .integer(0x77), .reference(.node(gpu)),
                            .string(Array("gpu_rcsu_reset".utf8))])),
  ]))
  let resets = PlatformTables.resets(rstl)
  #expect(resets.map { $0.controller } == [rst0, rst0])
  #expect(resets.map { $0.index } == [9, 0x77])
  #expect(resets.map { $0.name } == ["gpu_reset", "gpu_rcsu_reset"])
  #expect(PlatformTables.clocks(.integer(0)).isEmpty && PlatformTables.resets(.integer(0)).isEmpty)
}

@Test func linkedRangesFollowTheDevicesOwn() {
  // The GPU: two ranges and three interrupts of its own, then RST0's.
  var gpu = Device.ACPIDevice(path: "\\_SB_.GPU_", hid: "CIXH5000", cids: [], status: 0x0B,
                              resources: [.mmio(base: 0x1500_0000, size: 0x1_0000), .mmio(base: 0x1501_0000, size: 0x48_0000),
                                          .interrupt(0x10D, .levelHigh), .interrupt(0x10E, .levelHigh)])
  gpu.linked = [Device.LinkedRange(role: "reset", base: 0x1600_0000, size: 0x1000)]
  #expect(PlatformTables.barRoles(gpu, firmwareCall: false).map { "\($0.index):\($0.role)" } == ["2:reset"])
  // The SCMI agent: no _CRS; its shared memories and mailboxes, then TF-A's memory.
  var agent = Device.ACPIDevice(path: "\\_SB_.SCMI", hid: "CIXHA006", cids: [], status: 0x0B)
  agent.linked = [Device.LinkedRange(role: "shmem", base: 0x0659_0000, size: 0x80),
                  Device.LinkedRange(role: "shmem", base: 0x065A_0000, size: 0x80),
                  Device.LinkedRange(role: "mboxes", base: 0x0659_0000, size: 0x1_0000),
                  Device.LinkedRange(role: "mboxes", base: 0x065A_0000, size: 0x1_0000)]
  #expect(PlatformTables.barRoles(agent, firmwareCall: true).map { "\($0.index):\($0.role)" }
          == ["0:shmem", "1:shmem", "2:mboxes", "3:mboxes", "4:firmware"])
  // Six BARs at most: what doesn't fit isn't named.
  agent.linked += agent.linked
  #expect(PlatformTables.barRoles(agent, firmwareCall: true).count == 6)
}

@Test func onlyTheSky1sAgentCallsTFA() {
  let call = FirmwareCall.rule(oemID: Array("CIXTEK".utf8), oemTableID: Array("SKY1EDK2".utf8), hid: "CIXHA006")
  #expect(call == FirmwareCall(function: 0xC200_0001, memory: 0x8438_0000, size: 0x80))
  #expect(FirmwareCall.rule(oemID: Array("CIXTEK".utf8), oemTableID: Array("SKY1EDK2".utf8), hid: "CIXH5000") == nil)
  #expect(FirmwareCall.rule(oemID: Array("BOCHS ".utf8), oemTableID: Array("BXPC    ".utf8), hid: "CIXHA006") == nil)
}

@Test func theNthTransmitterGoesWithTheNthEngine() {
  // The Sky1's engines 4, 0 and 1, and transmitters 0, 4 and 1 (D146).
  let engines: [UInt64] = [0x141D_0000, 0x1401_0000, 0x1408_0000]
  let links: [UInt64] = [0x1406_4000, 0x1422_4000, 0x140D_4000]
  let pairs = PlatformTables.pairs(engines: engines, links: links)
  #expect(pairs.map { [$0.engine, $0.link] } == [[1, 0], [2, 2], [0, 1]])
  // A transmitter with no engine goes unpaired.
  #expect(PlatformTables.pairs(engines: [0x1401_0000], links: links).count == 1)
}
