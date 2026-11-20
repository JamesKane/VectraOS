// SPDX-License-Identifier: BSD-3-Clause

// What ACPI finds on a machine (D74): its namespace loaded over the
// machine's host, _INI run, and every present device's identity, _CRS
// and links read. devmgr's program runs it at boot; the checks over a
// board's captured tables (D171) run the same code over the tables.

import DeviceTreeBus
import PCI
import Sys
import TDACPI

/// What ACPI found, and how long each part took.
public struct ACPIResult {
  public init() {}
  public var devices: [Device.ACPIDevice] = []
  public var routes: [InterruptRoute] = []
  /// The PCI root bridges' buses and windows, from their _CRS.
  public var bridges: [RootBridge] = []
  public var summary = "no ACPI tables\n"
  /// \_S5's sleep types, for /dev/reboot's poweroff.
  public var sleepTypes: (UInt8, UInt8)?
  /// The namespace, kept for power (ACPIState).
  public var namespace: TDACPI.Namespace?
}

/// Loads the DSDT and SSDTs with load-time code run over the machine
/// (`host`), runs _INI, and reads every device's _STA, HID, CIDs and _CRS.
/// `unknownStatus` is the status of a device whose _STA can't be read, as
/// where it reads firmware memory a captured table set doesn't have: none
/// (the device is absent) as devmgr runs; a board check passes one to
/// judge such devices as present.
public func loadNamespace<C: ConfigSpace>(_ set: TableSet, host: MachineHost<C>, unknownStatus: UInt64? = nil) -> ACPIResult {
  var result = ACPIResult()
  let aml = ([set.dsdt].compactMap { $0 } + set.ssdts)
  let t0 = Clock.monotonic()
  var ns = Namespace(integerBits: set.integerBits)
  var loadFailures = 0
  for t in aml where (try? ns.load(t, host: host)) == nil { loadFailures += 1 }
  let t1 = Clock.monotonic()
  // The APIC model, before _INI and _PRT (whose answers depend on it).
  let picFailed = (try? ns.useAPIC(host: host)) == nil
  let initFailed = ns.initializeDevices(host: host)
  let t2 = Clock.monotonic()
  let nodes = ns.deviceNodes()
  var statuses: [(node: Int, status: UInt64)] = []
  for d in nodes {
    var status: UInt64 = 0
    do throws(ACPIError) { status = try ns.status(d, host: host).raw } catch { if case .unsupported = error { status = unknownStatus ?? 0 } }
    statuses.append((d, status))
  }
  let t3 = Clock.monotonic()
  for (d, status) in statuses where status & 1 != 0 {
    let hid = (try? ns.hardwareID(d, host: host)).flatMap { $0 }.map { String(decoding: $0, as: UTF8.self) }
    let cids = ((try? ns.compatibleIDs(d, host: host)) ?? []).map { String(decoding: $0, as: UTF8.self) }
    let crs = (try? ns.currentResources(d, host: host)).flatMap { $0 } ?? []
    if ([hid].compactMap { $0 } + cids).contains(where: { $0.utf8.elementsEqual("PNP0A08".utf8) || $0.utf8.elementsEqual("PNP0A03".utf8) }) {
      result.bridges.append(RootBridge(resources: crs))
    }
    let coherent = (try? ns.cacheCoherent(d, host: host)).flatMap { $0 }
    var device = Device.ACPIDevice(path: String(decoding: ns.path(d), as: UTF8.self), hid: hid, cids: cids,
                                   status: status, resources: Device.PlatformResource.of(crs), coherent: coherent ?? true,
                                   hasCCA: coherent != nil)
    link(&device, &ns, d, host: host)
    result.devices.append(device)
  }
  let t4 = Clock.monotonic()
  let routesFailed: Bool
  do throws(ACPIError) {
    result.routes = try ns.interruptRoutes(host: host)
    routesFailed = false
  } catch {
    routesFailed = true
  }
  result.sleepTypes = ns.sleepTypes(host: host)
  let t5 = Clock.monotonic()
  let bytes = aml.reduce(0) { $0 + $1.length }
  var s5 = "no \\_S5\n"
  if let (a, b) = result.sleepTypes { s5 = "\\_S5 \(a) \(b)\n" }
  result.summary = "\(set.tables.count) tables, \(aml.count) with AML (\(bytes) bytes), \(ns.nodes.count) nodes\n"
    + "load \((t1 - t0) / 1000) us (\(loadFailures) failed), _INI \((t2 - t1) / 1000) us (\(initFailed.count) failed)\n"
    + "_STA on \(nodes.count) devices \((t3 - t2) / 1000) us, \(result.devices.count) present\n"
    + "_PIC(1) \(picFailed ? "failed" : "ok"), _PRT \(result.routes.count) routes \((t5 - t4) / 1000) us\(routesFailed ? " (failed)" : "")\n"
    + s5
    + result.bridges.map { "root bridge \($0.summary)\n" }.joined()
    + initFailed.map { "_INI failed: \(String(decoding: ns.path($0.device), as: UTF8.self)) \($0.error.name)\n" }.joined()
    + host.log.map { "aml: \($0)\n" }.joined()
  result.namespace = ns
  return result
}

/// What platform device `d`'s driver is linked to (DevMgr's Platform.swift):
/// the ranges of the devices its _DSD names as its SCMI shared memory and
/// mailboxes or its DisplayPort PHY; its RSTL's resets and CLKT's clocks; whether
/// it has power resources, its own or its power-supply's, and whether it
/// talks to SCMI (clocks, or _DSD's power-domains).
public func link<C: ConfigSpace>(_ device: inout Device.ACPIDevice, _ ns: inout TDACPI.Namespace, _ d: Int, host: MachineHost<C>) {
  let properties = (try? ns.deviceProperties(d, host: host)) ?? []
  var supplies: [Int] = []
  for p in properties {
    if p.name.elementsEqual("shmem".utf8) || p.name.elementsEqual("mboxes".utf8) {
      let role = String(decoding: p.name, as: UTF8.self)
      for n in TDACPI.Namespace.referencedNodes(p.value) {
        for r in mmioRanges(&ns, n, host: host) { device.linked.append(Device.LinkedRange(role: role, base: r.base, size: r.size)) }
      }
    } else if p.name.elementsEqual("dp_phy".utf8) {
      // A DisplayPort transmitter's PHY: a child of the PHY's device names
      // its port, and the PHY's registers are that device's (D146).
      for n in TDACPI.Namespace.referencedNodes(p.value) where ns.nodes[n].parent >= 0 {
        for r in mmioRanges(&ns, ns.nodes[n].parent, host: host) {
          device.linked.append(Device.LinkedRange(role: "phy", base: r.base, size: r.size))
        }
      }
    } else if p.name.elementsEqual("power-supply".utf8) {
      supplies += TDACPI.Namespace.referencedNodes(p.value)
    } else if p.name.elementsEqual("power-domains".utf8) {
      device.usesSCMI = true
      // The SCMI agent's domains, in the graph (PowerOrder.swift).
      for id in PlatformTables.powerDomains(p.value) {
        device.links.append(DeviceLink(kind: "power-domain", provider: "", cells: [id]))
      }
    }
  }
  if let rstl = try? ns.childValue(d, "RSTL", host: host) {
    // The controller's page is its driver's alone (D167): a device resets
    // through the provider, never by a range of its own.
    for r in PlatformTables.resets(rstl) {
      device.links.append(DeviceLink(kind: "reset", name: r.name, provider: String(decoding: ns.path(r.controller), as: UTF8.self),
                                     cells: [r.index]))
    }
  }
  if let clkt = try? ns.childValue(d, "CLKT", host: host) { device.links += PlatformTables.clocks(clkt) }
  device.links += PlatformTables.connections((try? ns.currentResources(d, host: host)).flatMap { $0 } ?? [], in: ns, from: d)
  device.properties = PlatformTables.properties(properties, in: ns)
  if device.links.contains(where: { same($0.kind, "clock") }) { device.usesSCMI = true }
  for n in [d] + supplies where !((try? ns.powerResources(n, host: host)) ?? []).isEmpty { device.powered = true }
}

/// Node `n`'s memory ranges, from its _CRS.
public func mmioRanges<C: ConfigSpace>(_ ns: inout TDACPI.Namespace, _ n: Int, host: MachineHost<C>) -> [(base: UInt64, size: UInt64)] {
  let crs = (try? ns.currentResources(n, host: host)).flatMap { $0 } ?? []
  var out: [(base: UInt64, size: UInt64)] = []
  for r in Device.PlatformResource.of(crs) {
    if case .mmio(let base, let size) = r { out.append((base, size)) }
  }
  return out
}
