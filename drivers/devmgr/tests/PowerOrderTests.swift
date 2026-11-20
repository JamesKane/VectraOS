// SPDX-License-Identifier: BSD-3-Clause

// A device's power in its graph's order (D170): the order from a
// synthetic device's links, its cut in reverse, the `ctl` grammar, and
// what a step or a provider that doesn't answer leaves.

import DevMgr
import DeviceTreeBus
import TDACPI
import Testing

/// A GPU's links as CIX's tables give them: its domain, two clocks and a
/// third it doesn't need, and the reset on a controller.
let gpuLinks: [DeviceLink] = [
  DeviceLink(kind: "reset", name: "gpu_reset", provider: "\\_SB_.RST0", cells: [9]),
  DeviceLink(kind: "clock", name: "gpu_clk_core", provider: "", cells: [31]),
  DeviceLink(kind: "power-domain", provider: "", cells: [21]),
  DeviceLink(kind: "clock", name: "gpu_clk_stacks", provider: "", cells: [32]),
  DeviceLink(kind: "clock", name: "gpu_clk_other", provider: "", cells: [33]),
]
let gpuServices = ["sky1-reset-RST0", "", "", "", ""]

final class Recorder: PowerActuator, SupplyHolder, HostControl, @unchecked Sendable {
  var log: [String] = []
  /// Actions (their lines) that aren't taken.
  var refuse: [String] = []
  var suppliesEnd = true
  var hostStarts = true
  var clock: Int64 = 0
  /// What an action costs, in nanoseconds, by its line.
  var cost: [String: Int64] = [:]

  func run(_ a: PowerAction) -> Bool {
    log.append(a.line)
    clock += cost[a.line] ?? 1_000_000
    return !refuse.contains(a.line)
  }
  func end(_ service: String, deadlineNs: Int64) -> Bool {
    log.append("supplies end \(service) \(deadlineNs / 1_000_000) ms")
    return suppliesEnd
  }
  func renew(_ service: String) { log.append("supplies renew \(service)") }
  func endHost(_ service: String) { log.append("host end") }
  func startHost(_ service: String) -> Bool {
    log.append("host start")
    return hostStarts
  }
}

func gpu(_ r: Recorder, pulse: UInt32? = 20) -> PowerController {
  var c = PowerController(now: { r.clock })
  let steps = PowerOrder.steps(links: gpuLinks, services: gpuServices, clocks: ["gpu_clk_core", "gpu_clk_stacks"], powered: true)
  c.devices = [PowerDevice(service: "mali-acpi-_SB_.GPU_", path: "\\_SB_.GPU_", steps: steps, pulse: pulse)]
  return c
}

@Test func theGraphIsDomainsThenClocksThenResourcesThenResets() {
  let steps = PowerOrder.steps(links: gpuLinks, services: gpuServices, clocks: ["gpu_clk_core", "gpu_clk_stacks"], powered: true)
  #expect(steps == [.domain(21), .clock(31), .clock(32), .resource, .reset(service: "sky1-reset-RST0", index: 9)])
  // No named clocks: every clock the device has, in the order its links give.
  let all = PowerOrder.steps(links: gpuLinks, services: gpuServices, clocks: [], powered: false)
  #expect(all == [.domain(21), .clock(31), .clock(32), .clock(33), .reset(service: "sky1-reset-RST0", index: 9)])
  // A reset no running driver serves is not in the graph, and is named.
  #expect(PowerOrder.steps(links: gpuLinks, services: ["", "", "", "", ""], clocks: [], powered: false).count == 4)
  #expect(PowerOrder.unserved(links: gpuLinks, services: ["", "", "", "", ""]) == ["gpu_reset"])
  #expect(PowerOrder.unserved(links: gpuLinks, services: gpuServices).isEmpty)
}

@Test func powerUpSendsEachStepToItsOwnerInOrder() {
  let r = Recorder()
  var c = gpu(r)
  let ok1 = c.powerUp(0, r)
  #expect(ok1)
  #expect(r.log == ["power 21 on", "clock 31 on", "clock 32 on", "on", "reset 9 pulse 20"])
  #expect(c.devices[0].state == "on" && c.devices[0].detail.isEmpty)
  #expect(c.text.hasPrefix("mali-acpi-_SB_.GPU_ on last on "))
  // Without a pulse in its record, a reset is released.
  let q = Recorder()
  var d = gpu(q, pulse: nil)
  let ok2 = d.powerUp(0, q)
  #expect(ok2)
  #expect(q.log.last == "reset 9 deassert")
}

@Test func aStepThatIsNotTakenStopsThePowerUpThere() {
  let r = Recorder()
  r.refuse = ["clock 32 on"]
  var c = gpu(r)
  let ok3 = !c.powerUp(0, r)
  #expect(ok3)
  #expect(r.log == ["power 21 on", "clock 31 on", "clock 32 on"])
  #expect(c.devices[0].state == "failed" && c.devices[0].detail == "clock 32 not turned on")
}

@Test func powerOffEndsSuppliesAndTheHostThenCutsInReverse() {
  let r = Recorder()
  var c = gpu(r)
  let ok4 = c.powerUp(0, r)
  #expect(ok4)
  r.log = []
  let ok5 = c.powerDown(0, r, supplies: r, host: r)
  #expect(ok5)
  #expect(r.log == ["supplies end mali-acpi-_SB_.GPU_ 500 ms", "host end", "reset 9 assert", "off", "clock 32 off",
                    "clock 31 off", "power 21 off"])
  #expect(c.devices[0].state == "off" && c.devices[0].detail.isEmpty)
}

@Test func aProviderThatDoesNotConfirmInTimeLeavesTheDeviceStuck() {
  // One that refuses, and one that answers too late; the rest are still asked.
  let r = Recorder()
  r.refuse = ["clock 31 off"]
  var c = gpu(r)
  let ok6 = !c.powerDown(0, r, supplies: r, host: r)
  #expect(ok6)
  #expect(c.devices[0].state == "stuck" && c.devices[0].detail == "clock 31 not cut")
  #expect(r.log.last == "power 21 off")
  #expect(c.devices[0].last.hasPrefix("off unconfirmed "))

  let slow = Recorder()
  slow.cost = ["off": 600_000_000]
  var d = gpu(slow)
  let ok7 = !d.powerDown(0, slow, supplies: slow, host: slow)
  #expect(ok7)
  #expect(d.devices[0].state == "stuck" && d.devices[0].detail == "power resource cut after more than 500 ms")
  #expect(d.text.contains("stuck last off unconfirmed"))
}

@Test func suppliesTakenAtTheDeadlineAreReportedButTheDeviceGoesOff() {
  let r = Recorder()
  r.suppliesEnd = false
  var c = gpu(r)
  let ok8 = c.powerDown(0, r, supplies: r, host: r)
  #expect(ok8)
  #expect(c.devices[0].state == "off" && c.devices[0].detail == "supplies taken at the deadline")
}

@Test func powerOnMakesTheSuppliesAgainThenStartsTheHost() {
  let r = Recorder()
  var c = gpu(r)
  let ok9 = c.powerDown(0, r, supplies: r, host: r)
  #expect(ok9)
  r.log = []
  let ok10 = c.restore(0, r, supplies: r, host: r)
  #expect(ok10)
  #expect(r.log == ["power 21 on", "clock 31 on", "clock 32 on", "on", "reset 9 pulse 20", "supplies renew mali-acpi-_SB_.GPU_",
                    "host start"])
  #expect(c.devices[0].state == "on")
  // A step that fails leaves the host unstarted.
  let f = Recorder()
  f.refuse = ["on"]
  var d = gpu(f)
  let ok11 = !d.restore(0, f, supplies: f, host: f)
  #expect(ok11)
  #expect(!f.log.contains("host start") && d.devices[0].state == "failed")
  // A host that doesn't start leaves it failed with the device on.
  let h = Recorder()
  h.hostStarts = false
  var e = gpu(h)
  let ok12 = !e.restore(0, h, supplies: h, host: h)
  #expect(ok12)
  #expect(e.devices[0].state == "failed" && e.devices[0].detail == "its host did not start")
}

@Test func ctlTakesPowerDeviceOnOrOff() {
  #expect(PowerCommand.parse("power mali-acpi-_SB_.GPU_ off") == .off("mali-acpi-_SB_.GPU_"))
  #expect(PowerCommand.parse("power \\_SB_.GPU_ on") == .on("\\_SB_.GPU_"))
  #expect(PowerCommand.parse("  power   x   on ") == .on("x"))
  #expect(PowerCommand.parse("power x") == nil)
  #expect(PowerCommand.parse("power x sideways") == nil)
  #expect(PowerCommand.parse("reboot x on") == nil)
  #expect(PowerCommand.parse("power x on now") == nil)
  #expect(PowerCommand.parse("") == nil)
}

@Test func aDeviceIsFoundByItsServiceOrItsPath() {
  let c = gpu(Recorder())
  #expect(c.index(of: "mali-acpi-_SB_.GPU_") == 0)
  #expect(c.index(of: "\\_SB_.GPU_") == 0)
  #expect(c.index(of: "mali") == nil)
}

@Test func theRecordOptsInToThePowerGraph() throws {
  let i = try index("""
    driver mali
    match acpi CIXH5000
    power-up graph
    power-clocks gpu_clk_core gpu_clk_stacks
    reset-pulse 20
    driver other
    match acpi PNP0B00
    """)
  #expect(i.drivers[0].powerUp && i.drivers[0].powerClocks == ["gpu_clk_core", "gpu_clk_stacks"] && i.drivers[0].resetPulse == 20)
  #expect(!i.drivers[1].powerUp && i.drivers[1].powerClocks.isEmpty && i.drivers[1].resetPulse == nil)
  for bad in ["power-up", "power-up everything", "power-clocks", "reset-pulse", "reset-pulse 0", "reset-pulse 100001",
              "reset-pulse x"] {
    #expect(throws: IndexError.self) { try index("driver a\nmatch acpi X\n\(bad)\n") }
  }
}

@Test func aPowerDomainsPropertyGivesItsIds() {
  #expect(PlatformTables.powerDomains(.integer(21)) == [21])
}

/// `power-resets` keeps a reset it doesn't name out of the order: the GPU's
/// RCSU reset, pulsed after its _ON, undid that _ON on the Orange Pi 6 Plus.
@Test func onlyTheNamedResetsArePowered() {
  let links = gpuLinks + [DeviceLink(kind: "reset", name: "rcsu_reset", provider: "\\_SB_.RST0", cells: [114])]
  let services = gpuServices + ["sky1-reset-RST0"]
  let named = PowerOrder.steps(links: links, services: services, clocks: [], resets: ["gpu_reset"], powered: true)
  #expect(named.contains(.reset(service: "sky1-reset-RST0", index: 9)))
  #expect(!named.contains(.reset(service: "sky1-reset-RST0", index: 114)))
  let all = PowerOrder.steps(links: links, services: services, clocks: [], powered: true)
  #expect(all.contains(.reset(service: "sky1-reset-RST0", index: 114)))
}
