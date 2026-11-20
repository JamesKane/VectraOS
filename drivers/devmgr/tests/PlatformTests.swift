// SPDX-License-Identifier: BSD-3-Clause

// What a platform device's driver gets past its _CRS (Platform.swift): CIX's
// clock and reset tables as the Sky1's GPU has them, which BAR each linked
// range is, and the board rule for the Sky1's SCMI over SMC.

import DevMgr
import DeviceTreeBus
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
  #expect(PlatformTables.clocks(clkt) == [DeviceLink(kind: "clock", name: "gpu_clk_core", provider: "", cells: [0x1F]),
                                         DeviceLink(kind: "clock", name: "gpu_clk_stacks", provider: "", cells: [0x20])])
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
  // The GPU: two ranges and three interrupts of its own, then a linked one.
  var gpu = Device.ACPIDevice(path: "\\_SB_.GPU_", hid: "CIXH5000", cids: [], status: 0x0B,
                              resources: [.mmio(base: 0x1500_0000, size: 0x1_0000), .mmio(base: 0x1501_0000, size: 0x48_0000),
                                          .interrupt(0x10D, .levelHigh), .interrupt(0x10E, .levelHigh)])
  gpu.linked = [Device.LinkedRange(role: "phy", base: 0x1600_0000, size: 0x1000)]
  #expect(PlatformTables.barRoles(gpu, firmwareCall: false).map { "\($0.index):\($0.role)" } == ["2:phy"])
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

// MARK: ACPI's connections as links

/// The AML a device's _CRS and _DSD need, as an ASL compiler emits it.
private enum Aml {
  static func pkg(_ content: [UInt8]) -> [UInt8] {
    if content.count + 1 < 0x40 { return [UInt8(content.count + 1)] + content }
    let total = content.count + 2
    return [0x40 | UInt8(total & 0x0F), UInt8(truncatingIfNeeded: total >> 4)] + content
  }
  static func name(_ path: String) -> [UInt8] {
    let segs = path.split(separator: ".").map { s -> [UInt8] in
      Array(s.utf8) + [UInt8](repeating: 0x5F, count: 4 - s.utf8.count)
    }
    return segs.count == 1 ? segs[0] : [0x2F, UInt8(segs.count)] + segs.flatMap { $0 }
  }
  static func integer(_ v: UInt64) -> [UInt8] { [0x0C] + le(v, 4) }
  static func string(_ s: String) -> [UInt8] { [0x0D] + Array(s.utf8) + [0] }
  static func buffer(_ bytes: [UInt8]) -> [UInt8] { [0x11] + pkg(integer(UInt64(bytes.count)) + bytes) }
  static func packageOf(_ elements: [[UInt8]]) -> [UInt8] { [0x12] + pkg([UInt8(elements.count)] + elements.flatMap { $0 }) }
  static func device(_ n: String, _ body: [UInt8]) -> [UInt8] { [0x5B, 0x82] + pkg(name(n) + body) }
  static func named(_ n: String, _ v: [UInt8]) -> [UInt8] { [0x08] + name(n) + v }
}

/// A _CRS template: an I2cSerialBus connection at `address`, one on a
/// controller that isn't there, an SPI one (not an I2C), and a GpioInt
/// on `pins` with `flags`.
private func connectionTemplate(i2c: String, address: UInt16, gpio: String, pins: [UInt16], flags: UInt16) -> [UInt8] {
  var t: [UInt8] = []
  func descriptor(_ type: UInt8, _ body: [UInt8]) -> [UInt8] { [0x80 | type] + le(UInt64(body.count), 2) + body }
  func serial(_ source: String, _ address: UInt16, type: UInt8 = 1) -> [UInt8] {
    let data = le(400_000, 4) + le(UInt64(address), 2)
    return descriptor(0x0E, [1, 0, type, 0] + le(0, 2) + [1] + le(UInt64(data.count), 2) + data + Array(source.utf8) + [0])
  }
  t += serial(i2c, address)
  t += serial("\\_SB.NONE", 0x10)
  t += serial(i2c, 0x77, type: 2)
  // GpioInt (offsets from the descriptor's start, its 3 header bytes included).
  let pinTable = 23, nameAt = pinTable + 2 * pins.count
  var g: [UInt8] = [1, 0] + le(0, 2) + le(UInt64(flags), 2) + [0] + le(0, 2) + le(0, 2) + le(UInt64(pinTable), 2)
  g += [0] + le(UInt64(nameAt), 2) + le(0, 2) + le(0, 2)
  for p in pins { g += le(UInt64(p), 2) }
  g += Array(gpio.utf8) + [0]
  t += descriptor(0x0C, g)
  t += [0x79, 0x00]
  return t
}

private func connectionNamespace() throws -> (ns: Namespace, rtc: Int, host: MachineHost<RecordingConfig>) {
  let crs = connectionTemplate(i2c: "\\_SB.I2C3", address: 0x32, gpio: "\\_SB.GPI1", pins: [5, 9], flags: 0x0006)
  let dsd = Aml.packageOf([
    Aml.buffer(Namespace.devicePropertiesUUID),
    Aml.packageOf([
      Aml.packageOf([Aml.string("clock-frequency"), Aml.integer(400_000)]),
      Aml.packageOf([Aml.string("label"), Aml.string("rtc")]),
      Aml.packageOf([Aml.string("modes"), Aml.packageOf([Aml.integer(1), Aml.integer(2)])]),
      Aml.packageOf([Aml.string("blob"), Aml.buffer([1, 2])]),
    ]),
  ])
  let body = [0x10] + Aml.pkg(
    [0x5C] + Aml.name("_SB")
      + Aml.device("GPI1", Aml.named("_HID", Aml.string("CIXH1002")))
      + Aml.device("I2C3", Aml.named("_HID", Aml.string("CIXH200B"))
        + Aml.device("RTC0", Aml.named("_HID", Aml.string("RX008900")) + Aml.named("_CRS", Aml.buffer(crs))
          + Aml.named("_DSD", dsd))))
  let host = MachineHost(readMemory: { _, _ in 0 }, writeMemory: { _, _, _ in true }, readPort: { _, _ in 0 },
                         writePort: { _, _, _ in true }, config: RecordingConfig())
  var ns = Namespace(integerBits: 64)
  try ns.load(table("DSDT", body), host: host)
  return (ns, try #require(ns.lookup("\\_SB.I2C3.RTC0")), host)
}

@Test func anI2CConnectionIsALinkToItsController() throws {
  var (ns, rtc, host) = try connectionNamespace()
  let crs = try #require(try ns.currentResources(rtc, host: host))
  let links = PlatformTables.connections(crs, in: ns, from: rtc)
  // The controller by its namespace path, the slave address its cell; a
  // connection to a controller that isn't there has no provider; an SPI
  // connection is no link.
  #expect(links.count == 3)
  #expect(links[0] == DeviceLink(kind: "i2c", provider: "\\_SB_.I2C3", cells: [0x32]))
  #expect(links[1] == DeviceLink(kind: "i2c", provider: "", cells: [0x10]))
  // A GpioInt names its controller and has its pins, then its flags word.
  #expect(links[2] == DeviceLink(kind: "gpio", name: "int", provider: "\\_SB_.GPI1", cells: [5, 9, 6]))
}

@Test func anACPIDevicesLinksTextNamesItsProvidersServices() throws {
  var (ns, rtc, host) = try connectionNamespace()
  let crs = try #require(try ns.currentResources(rtc, host: host))
  let clock = DeviceLink(kind: "clock", name: "core", provider: "", cells: [7])
  let links = [clock] + PlatformTables.connections(crs, in: ns, from: rtc)
  let service = { (path: String) -> String? in
    path == "\\_SB_.I2C3" ? "acpi-_SB_.I2C3" : nil
  }
  #expect(Links.text(links, service: service)
    == "clock core - 7\ni2c - acpi-_SB_.I2C3 50\ni2c - - 16\ngpio int - 5 9 6\n")
}

@Test func aDevicesPropertiesAreLines() throws {
  var (ns, rtc, host) = try connectionNamespace()
  let list = try ns.deviceProperties(rtc, host: host)
  #expect(PlatformTables.properties(list, in: ns) == "clock-frequency 400000\nlabel rtc\nmodes 1 2\n")
}

@Test func providersStartBeforeTheirACPIConsumers() {
  // The RTC, then its controller and a GPIO controller, which have no links.
  #expect(Links.order([[1, 2], [], []]) == [1, 2, 0])
}
