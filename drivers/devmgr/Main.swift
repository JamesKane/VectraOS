// SPDX-License-Identifier: BSD-3-Clause

// bin/devmgr (M3g, architecture §9; V2 item 7c, D74): finds the machine's
// devices, binds drivers to them by their match records (bootfs's
// etc/drivers), and runs a driver host per bound device, given that
// device's resources and nothing more. Its manifest grants it MMIO, IRQ,
// I/O port (amd64) and system resources, the boot data, and `programs`:
// bootfs and a job, under which it runs the hosts with system/launch/lib,
// so they restart by policy like any service.
//
// It reads the firmware's tables from the RSDP in the boot data, loads
// ACPI's namespace with our AML interpreter, its regions over this
// machine (drivers/devmgr/lib/Firmware.swift), enumerates PCI over the
// MCFG's ECAM (each bus mapped as it is walked), names each IOMMU the
// tables describe to the kernel (IOMMUs.swift), and lists ACPI's present
// devices, its platform devices, with their _CRS. A PCI function's host
// gets its BARs, configuration space, its interrupt routed through _PRT,
// an MSI allocation and a BTI on the IOMMU that covers it; a platform
// device's, its _CRS ranges and interrupt and the stub's BTI, and
// `--noncoherent` where its _CCA says its DMA isn't (Grants.swift); the
// ranges of the devices firmware links it to, with `--bar=INDEX:ROLE`
// saying which, an SMC function where a board rule names one, its
// `platform/SERVICE` directory at /dev/acpi (its clocks, resets and
// power), and the SCMI agent's tree at /dev/scmi where it uses SCMI
// (Platform.swift). The power class's hosts start first.
//
// It serves its tree at once, so the launcher sees it ready while it
// binds; `status` grows as it goes, and ends with `bound N`.
//   status             a line a device: name, ids, class, driver host, state, DMA
//   iommus             each unit and whether the kernel took it
//   enumeration        how long finding the PCI functions took, buses mapped
//   acpi               the tables, and how long loading and _STA took
//   dev/               the classes' device directories (D82), granted as /dev
//   drivers/SERVICE/   each driver host's own tree
//   platform/SERVICE/  a platform device's clocks, resets and power

import DevMgr
import DriverHost
import IPC
import Launch
import Node
import PCI
import Sys
import TDACPI

func fail(_ what: String) -> Never {
  print("devmgr: \(what)")
  Process.exit(code: 1)
}

/// A device and what devmgr did about it.
final class Entry: @unchecked Sendable {
  let device: Device
  /// Its driver's match record, and so its program.
  let driver: DriverManifest?
  var program: String? { driver?.name }
  var state: String
  /// Where its BTI came from.
  var dma = "-"
  init(device: Device, driver: DriverManifest?) {
    self.device = device
    self.driver = driver
    state = driver == nil ? "unbound" : "not started"
  }
  var service: String? { program.map { "\($0)-" + (device.pci?.address.description ?? device.name) } }
}

/// What the tree shows, as devmgr learns it.
final class Findings: @unchecked Sendable {
  let lock = Lock()
  var entries: [Entry] = []
  var iommus = "not yet\n"
  var enumeration = "not yet\n"
  var acpi = "not yet\n"
  var done = false

  var status: String {
    lock.withLock {
      entries.map { e in
        let cls = e.device.pci.map {
          hex(UInt32($0.classCode), digits: 2) + "." + hex(UInt32($0.subclass), digits: 2) + "."
            + hex(UInt32($0.progIF), digits: 2)
        } ?? "-"
        return "\(e.device.name) \(e.device.ids) \(cls) \(e.service ?? "-") \(e.state) dma \(e.dma)\n"
      }.joined() + (done ? "bound \(entries.filter { same($0.state, "running") }.count)\n" : "")
    }
  }
}

/// What ACPI found, and how long each part took.
struct ACPIResult {
  var devices: [Device.ACPIDevice] = []
  var routes: [InterruptRoute] = []
  /// The PCI root bridges' buses and windows, from their _CRS.
  var bridges: [RootBridge] = []
  var summary = "no ACPI tables\n"
  /// \_S5's sleep types, for /dev/reboot's poweroff.
  var sleepTypes: (UInt8, UInt8)?
  /// The namespace, kept for power (ACPIState).
  var namespace: TDACPI.Namespace?
}

/// Loads the DSDT and SSDTs with load-time code run over the machine
/// (`host`), runs _INI, and reads every device's _STA, HID, CIDs and _CRS.
func loadNamespace<C: ConfigSpace>(_ set: TableSet, host: MachineHost<C>) -> ACPIResult {
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
  for d in nodes { statuses.append((d, (try? ns.status(d, host: host))?.raw ?? 0)) }
  let t3 = Clock.monotonic()
  for (d, status) in statuses where status & 1 != 0 {
    let hid = (try? ns.hardwareID(d, host: host)).flatMap { $0 }.map { String(decoding: $0, as: UTF8.self) }
    let cids = ((try? ns.compatibleIDs(d, host: host)) ?? []).map { String(decoding: $0, as: UTF8.self) }
    let crs = (try? ns.currentResources(d, host: host)).flatMap { $0 } ?? []
    if ([hid].compactMap { $0 } + cids).contains(where: { $0.utf8.elementsEqual("PNP0A08".utf8) || $0.utf8.elementsEqual("PNP0A03".utf8) }) {
      result.bridges.append(RootBridge(resources: crs))
    }
    let coherent = (try? ns.cacheCoherent(d, host: host)).flatMap { $0 } ?? true
    var device = Device.ACPIDevice(path: String(decoding: ns.path(d), as: UTF8.self), hid: hid, cids: cids,
                                   status: status, resources: Device.PlatformResource.of(crs), coherent: coherent)
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
/// mailboxes, and of its RSTL's reset controllers; CLKT's clocks; whether
/// it has power resources, its own or its power-supply's, and whether it
/// talks to SCMI (clocks, or _DSD's power-domains).
func link<C: ConfigSpace>(_ device: inout Device.ACPIDevice, _ ns: inout TDACPI.Namespace, _ d: Int, host: MachineHost<C>) {
  let properties = (try? ns.deviceProperties(d, host: host)) ?? []
  var supplies: [Int] = []
  for p in properties {
    if p.name.elementsEqual("shmem".utf8) || p.name.elementsEqual("mboxes".utf8) {
      let role = String(decoding: p.name, as: UTF8.self)
      for n in TDACPI.Namespace.referencedNodes(p.value) {
        for r in mmioRanges(&ns, n, host: host) { device.linked.append(Device.LinkedRange(role: role, base: r.base, size: r.size)) }
      }
    } else if p.name.elementsEqual("power-supply".utf8) {
      supplies += TDACPI.Namespace.referencedNodes(p.value)
    } else if p.name.elementsEqual("power-domains".utf8) {
      device.usesSCMI = true
    }
  }
  if let rstl = try? ns.childValue(d, "RSTL", host: host) {
    var controllers: [Int] = []
    for r in PlatformTables.resets(rstl) {
      device.resets.append(Device.Reset(controller: String(decoding: ns.path(r.controller), as: UTF8.self), index: r.index,
                                        name: r.name))
      if !controllers.contains(r.controller) { controllers.append(r.controller) }
    }
    for c in controllers {
      for r in mmioRanges(&ns, c, host: host) { device.linked.append(Device.LinkedRange(role: "reset", base: r.base, size: r.size)) }
    }
  }
  if let clkt = try? ns.childValue(d, "CLKT", host: host) { device.clocks = PlatformTables.clocks(clkt) }
  if !device.clocks.isEmpty { device.usesSCMI = true }
  for n in [d] + supplies where !((try? ns.powerResources(n, host: host)) ?? []).isEmpty { device.powered = true }
}

/// Node `n`'s memory ranges, from its _CRS.
func mmioRanges<C: ConfigSpace>(_ ns: inout TDACPI.Namespace, _ n: Int, host: MachineHost<C>) -> [(base: UInt64, size: UInt64)] {
  let crs = (try? ns.currentResources(n, host: host)).flatMap { $0 } ?? []
  var out: [(base: UInt64, size: UInt64)] = []
  for r in Device.PlatformResource.of(crs) {
    if case .mmio(let base, let size) = r { out.append((base, size)) }
  }
  return out
}

/// ACPI's namespace, kept after loading for what devmgr evaluates later:
/// a platform device's power, which its driver asks for (/dev/acpi/power).
final class ACPIState<C: ConfigSpace>: @unchecked Sendable {
  let lock = Lock()
  var ns: TDACPI.Namespace
  let host: MachineHost<C>
  /// The power resources devmgr has turned on.
  var turnedOn: [Int] = []

  init(_ ns: TDACPI.Namespace, host: MachineHost<C>) {
    self.ns = ns
    self.host = host
  }

  /// Turns device `path` on (D0) or off: the power resources its _PR0
  /// names, and its _DSD power-supply's, then its _PS0; or _PS3 first, then
  /// the resources off. A resource devmgr hasn't yet turned on has its _ON
  /// run whatever its _STA says, as Linux does (firmware may have set
  /// _STA's bit and left the rest undone); one it has, not again; and off,
  /// a resource it turned on. What it ran, as a line; throws if it has no
  /// power resources or a method failed.
  func power(_ path: String, on: Bool) throws(ACPIError) -> String {
    try lock.withLock { () throws(ACPIError) -> String in
      let (d, resources) = try powerResources(path)
      var ran: [String] = []
      if !on, try ns.childValue(d, "_PS3", host: host) != nil { ran.append("_PS3") }
      for r in on ? resources : resources.reversed() where turnedOn.contains(r) != on {
        _ = try ns.setPower(r, on: on, checkStatus: false, host: host)
        if on { turnedOn.append(r) } else { turnedOn.removeAll { $0 == r } }
        ran.append(String(decoding: ns.path(r), as: UTF8.self) + (on ? "._ON" : "._OFF"))
      }
      if on, try ns.childValue(d, "_PS0", host: host) != nil { ran.append("_PS0") }
      return ran.isEmpty ? "already \(on ? "on" : "off")" : ran.joined(separator: " ")
    }
  }

  /// Whether every power resource of device `path` says it is on (_STA's
  /// bit 0), as firmware left them: a driver asks before it reads the
  /// registers of a device firmware may have left lit (linlon(3)).
  func firmwareOn(_ path: String) throws(ACPIError) -> Bool {
    try lock.withLock { () throws(ACPIError) -> Bool in
      for r in try powerResources(path).resources {
        guard let s = try ns.childValue(r, "_STA", host: host)?.integer, s & 1 != 0 else { return false }
      }
      return true
    }
  }

  /// devmgr's `cpus` and `thermal` (Performance.swift), under the lock.
  func performanceText() -> String { lock.withLock { ns.performanceText(host: host) } }
  func thermalText() -> String { lock.withLock { ns.thermalText(host: host) } }

  /// Device `path`'s node and the power resources its _PR0 names, and its
  /// _DSD power-supply's. Under the lock.
  func powerResources(_ path: String) throws(ACPIError) -> (device: Int, resources: [Int]) {
    guard let d = ns.lookup(Array(path.utf8)) else { throw ACPIError.notFound }
    var nodes = [d]
    for p in try ns.deviceProperties(d, host: host) where p.name.elementsEqual("power-supply".utf8) {
      nodes += TDACPI.Namespace.referencedNodes(p.value)
    }
    var resources: [Int] = []
    for n in nodes { resources += try ns.powerResources(n, host: host) }
    guard !resources.isEmpty else { throw ACPIError.notFound }
    return (d, resources)
  }
}

/// A bootfs file's bytes, through a mapping of its pages (V1 cut vmo_read, D37).
func read(_ bootfs: borrowing Handle, _ file: ProgramEntry) -> [UInt8]? {
  let first = file.offset & ~4095
  guard let m = try? VMO.map(bootfs, offset: first, length: file.offset + file.length - first, writable: false) else {
    return nil
  }
  return m.read(at: file.offset - first, count: file.length)
}

@main struct DevMgrProgram {
  static func main() {
    let start = Startup.current
    guard let mmio = start.take(HandleType.info(HandleType.resource(.mmio))) else {
      fail("no MMIO resource (its manifest's `resource mmio`)")
    }
    guard let bootfs = start.take(HandleType.info(HandleType.vmoBootfs)),
      let job = start.take(HandleType.info(HandleType.jobDefault))
    else { fail("no bootfs or job (its manifest's `programs`)") }
    // Kept raw for devmgr's life: grants borrow them, and the hosts' programs
    // are loaded from bootfs.
    let mmioRaw = mmio.release()
    let bootfsRaw = bootfs.release()
    let ioRaw = start.take(HandleType.info(HandleType.resource(.ioport)))?.release() ?? 0
    let irqRaw = start.take(HandleType.info(HandleType.resource(.irq)))?.release() ?? 0
    // arm64's SMC functions, for firmware a board rule names (FirmwareCall).
    let smcRaw = start.take(HandleType.info(HandleType.resource(.smc)))?.release() ?? 0
    // The system resource: the IOMMUs, the MSI resource for the hosts'
    // allocations, and the power resource for /dev/reboot.
    var iommuResource: UInt32 = 0, msiRaw: UInt32 = 0, powerRaw: UInt32 = 0
    if let system = start.take(HandleType.info(HandleType.resource(.system))) {
      iommuResource = (try? Sys.Resource.create(parent: system, kind: .system, base: DMA.iommuSystemBase, size: 1,
                                                name: "iommu"))?.release() ?? 0
      msiRaw = (try? Sys.Resource.create(parent: system, kind: .system, base: Interrupt.msiSystemBase, size: 1,
                                         name: "msi"))?.release() ?? 0
      powerRaw = (try? Sys.Resource.create(parent: system, kind: .system, base: Power.systemBase, size: 1,
                                           name: "power"))?.release() ?? 0
    }

    // The tree, served at once.
    let findings = Findings()
    let dispatcher: IPCDispatcher
    do { dispatcher = try IPCDispatcher() } catch { fail("can't make a dispatcher") }
    let tree = NodeTree(dispatcher: dispatcher)
    tree.text("status", read: { findings.status })
    tree.text("iommus", read: { findings.lock.withLock { findings.iommus } })
    tree.text("enumeration", read: { findings.lock.withLock { findings.enumeration } })
    tree.text("acpi", read: { findings.lock.withLock { findings.acpi } })
    // The classes' device directories (D82), bound in as their drivers come;
    // manifests mount them at /dev and /net.
    tree.directory("dev")
    tree.directory("net")
    tree.directory("platform")
    // /dev/reboot (D79): a command a line, `reboot`, `poweroff` or
    // `warmboot`, through the power resource; poweroff on amd64 takes \_S5's
    // sleep types, known once ACPI's namespace has loaded. A warm boot
    // (D101) takes the images written to /dev/warm, with every PCI
    // function's bus mastering off first (put back if the kernel refuses).
    let sleepTypes = Locked<(UInt8, UInt8)?>(nil)
    let busMastering = Locked<(stop: @Sendable () -> Void, restore: @Sendable () -> Void)?>(nil)
    var staged: [(node: TreeNode, vmo: UInt32)] = []
    for (name, capacity) in [("kernel", UInt64(64) << 20), ("bootfs", UInt64(512) << 20), ("cmdline", UInt64(4096))] {
      do throws(Status) {
        let vmo = try VMO.create(size: Int(capacity))
        let node = try tree.memory("dev/warm/" + name, growable: try vmo.duplicate(), capacity: capacity)
        staged.append((node, vmo.release()))
      } catch {
        print("devmgr: no /dev/warm/\(name): \(error.rawValue)")
      }
    }
    let warm = staged
    tree.text("dev/reboot", read: { "" }, write: { (text: String) throws(NodeError) in
      for line in lines(text) where !line.isEmpty {
        let power = Handle(raw: powerRaw)  // borrowed: devmgr's for its life
        var failed: Status?
        if same(line, "reboot") {
          print("devmgr: rebooting, as /dev/reboot asked")
          do throws(Status) { try Power.reboot(power) } catch { failed = error }
        } else if same(line, "poweroff") {
          print("devmgr: powering off, as /dev/reboot asked")
          do throws(Status) { try Power.poweroff(power, sleepTypes: sleepTypes.withLock { $0 }) } catch { failed = error }
        } else if same(line, "warmboot") {
          failed = warmboot(power, warm, tree, busMastering.withLock { $0 })
        } else {
          _ = power.release()
          throw .invalid
        }
        _ = power.release()
        if let failed { throw failed == .invalidArgs ? .invalid : .unsupported }
      }
    })
    guard let export = start.export() else { fail("no export (its manifest's `export`)") }
    do throws(Status) {
      try tree.serve(export)
      _ = try Thread.spawn { _ = try? dispatcher.run() }.release()
    } catch {
      fail("can't serve: \(error.rawValue)")
    }

    // The firmware's tables, from the RSDP in the boot data.
    let memory = PhysicalMemory(mmioRoot: mmioRaw)
    let ports = ioRaw != 0 ? PortSpace(ioportRoot: ioRaw) : nil
    let t0 = Clock.monotonic()
    var tableSet: TableSet?
    if let data = start.take(HandleType.info(HandleType.vmoBootData)), let at = rsdpAddress(bootData: data),
      let bytes = memory.bytes(at, 36), let rsdp = try? RSDP(bytes)
    {
      tableSet = try? TableSet(rsdp: rsdp, read: { memory.bytes($0, $1) })
    }
    let tablesRead = Clock.monotonic() - t0
    guard let tableSet else { fail("no ACPI tables from the boot data (its manifest's `bootdata`)") }

    // ECAM: the MCFG's windows for segment 0 (a host bridge each), each bus
    // mapped as it is walked.
    var windows: [MCFG.Window] = []
    if let t = tableSet.table(MCFG.signature), let mcfg = try? MCFG(t) {
      windows = mcfg.windows.filter { $0.segment == 0 }
    }
    guard !windows.isEmpty else { fail("no MCFG: can't reach PCI") }
    let ecam = ECAMWindows(mmioRoot: mmioRaw, windows: windows.map {
      ECAMWindows.Window(base: $0.base, startBus: $0.startBus, endBus: $0.endBus)
    })

    // ACPI's namespace, its regions over this machine.
    let host = MachineHost(
      readMemory: { memory.read($0, width: $1) }, writeMemory: { memory.write($0, width: $1, $2) },
      readPort: ports.map { p in { p.read($0, width: $1) } }, writePort: ports.map { p in { p.write($0, width: $1, $2) } },
      config: ecam)
    let acpi = loadNamespace(tableSet, host: host)
    sleepTypes.withLock { $0 = acpi.sleepTypes }
    let acpiState = acpi.namespace.map { ACPIState($0, host: host) }
    // The power service's (power(8), D130): each processor's _CPC and each
    // thermal zone's temperature and trips, evaluated as they are read.
    tree.text("cpus", read: { acpiState?.performanceText() ?? "" })
    tree.text("thermal", read: { acpiState?.thermalText() ?? "" })
    let oemID = tableSet.fadt?.table.oemID ?? [], oemTableID = tableSet.fadt?.table.oemTableID ?? []
    let acpiSummary = "tables read in \(tablesRead / 1000) us\n" + acpi.summary
      + "physical pages mapped \(memory.mappedPages)\n"
    findings.lock.withLock { findings.acpi = acpiSummary }
    for line in lines(acpiSummary) { print("devmgr: acpi: \(line)") }

    // The PCI functions.
    let t1 = Clock.monotonic()
    let functions = ecam.windows.flatMap { enumerate(ecam, bus: $0.startBus) }
    // For a warm boot: each function's command register with Bus Master
    // Enable (bit 2) cleared, and put back as it was.
    let addresses = functions.map { $0.address }
    let saved = Locked<[UInt16]>([])
    busMastering.withLock {
      $0 = (stop: {
        saved.withLock { s in
          s = addresses.map { ecam.read16($0, 4) }
          for (a, command) in zip(addresses, s) { ecam.write16(a, 4, command & ~(1 << 2)) }
        }
      }, restore: {
        saved.withLock { s in for (a, command) in zip(addresses, s) { ecam.write16(a, 4, command) } }
      })
    }
    let enumerated = Clock.monotonic() - t1
    let enumeration = "\(functions.count) functions in \(enumerated / 1000) us, \(ecam.mappedBuses) buses mapped\n"
    findings.lock.withLock { findings.enumeration = enumeration }

    // The IOMMUs, each named to the kernel; the stub where none covers a device.
    var units: [(raw: UInt32, name: String)] = []
    var iommuLines = ""
    var stub: UInt32 = 0
    if iommuResource != 0 {
      let resource = Handle(raw: iommuResource)  // kept: devmgr's for its life
      for u in IOMMUs.units(tableSet, functions: functions) {
        do throws(Status) {
          units.append((try DMA.iommu(resource: resource, type: u.type, descriptor: u.descriptor).release(), u.name))
          iommuLines += "\(u.name) ok\n"
        } catch {
          iommuLines += "\(u.name) refused \(error.rawValue)\n"
        }
      }
      stub = (try? DMA.stubIOMMU(resource: resource))?.release() ?? 0
      _ = resource.release()
    } else {
      iommuLines += "no system resource: no DMA\n"
    }
    if units.isEmpty { iommuLines += "no IOMMU: DMA is passthrough (WARNING)\n" }
    findings.lock.withLock { findings.iommus = iommuLines }
    for line in lines(iommuLines) { print("devmgr: iommu: \(line)") }

    // The drivers' match records, every driver.manifest in bootfs's etc/drivers.
    var programs: [(name: String, entry: ProgramEntry)] = []
    var driverText = ""
    let image = Handle(raw: bootfsRaw)  // kept
    do throws(Status) {
      for file in try ProgramEntry.bootfs(image) {
        if file.name.utf8.starts(with: "bin/".utf8) {
          programs.append((String(decoding: file.name.utf8.dropFirst(4), as: UTF8.self), file))
        } else if file.name.utf8.elementsEqual("etc/drivers".utf8), let bytes = read(image, file) {
          driverText = String(decoding: bytes, as: UTF8.self)
        }
      }
    } catch {
      fail("can't read bootfs: \(error.rawValue)")
    }
    _ = image.release()
    let index: DriverIndex
    do throws(IndexError) { index = try DriverIndex(text: driverText, file: "etc/drivers") } catch {
      fail("\(error.description)")
    }
    let devices = functions.map { Device(pci: $0) } + acpi.devices.map { Device(acpi: $0) }
    let entries = devices.map { d -> Entry in
      switch index.match(d) {
      case .driver(let i): return Entry(device: d, driver: index.drivers[i])
      case .none: return Entry(device: d, driver: nil)
      case .ambiguous(let names):
        let e = Entry(device: d, driver: nil)
        e.state = "ambiguous: " + names.joined(separator: " ")
        return e
      }
    }
    findings.lock.withLock { findings.entries = entries }
    print("devmgr: \(functions.count) PCI functions, \(acpi.devices.count) ACPI devices, \(units.count) IOMMUs; \(entries.filter { $0.program != nil }.count) to bind")

    // A bound function decodes its BARs; bus mastering is its driver's to turn on.
    for e in entries where e.program != nil {
      guard let f = e.device.pci else { continue }
      var command = ecam.read16(f.address, Register.command)
      if f.bars.contains(where: { $0.space == .memory }) { command |= Command.memory }
      if f.bars.contains(where: { $0.space == .io }) { command |= Command.io }
      ecam.write16(f.address, Register.command, command)
    }

    // Driver hosts, each a service of devmgr's own launcher.
    let launcher: Launcher
    do throws(Status) {
      launcher = try Launcher(programs: programs, rootJob: job)
    } catch {
      fail("can't make a launcher: \(error.rawValue)")
    }
    let firstWindow = ecam.windows[0]
    // A platform device's directory (Platform.swift), its host's
    // /dev/acpi: its clocks and resets, as firmware's tables name them, and
    // `power`, which runs its power resources' _ON or _OFF, AML being
    // devmgr's alone.
    var platformDirectories: [(service: String, node: TreeNode)] = []
    for e in entries {
      guard let a = e.device.acpi, let service = e.service else { continue }
      let base = "platform/\(service)"
      let node = tree.directory(base)
      tree.text(base + "/clocks", read: { a.clocks.map { "\($0.id) \($0.name)\n" }.joined() })
      tree.text(base + "/resets", read: { a.resets.map { "\($0.controller) \($0.index) \($0.name)\n" }.joined() })
      if a.powered, let acpiState {
        let path = a.path
        // Until a driver sets it, what firmware left: its resources' _STA.
        let state = Locked<String?>(nil)
        tree.text(base + "/power", read: {
          if let set = state.withLock({ $0 }) { return set }
          return (try? acpiState.firmwareOn(path)) == true ? "on\n" : "off\n"
        }, write: { (text: String) throws(NodeError) in
          for line in lines(text) where !line.isEmpty {
            let on = same(line, "on")
            guard on || same(line, "off") else { throw .invalid }
            do throws(ACPIError) {
              let ran = try acpiState.power(path, on: on)
              print("devmgr: \(service): power \(line): \(ran)")
              state.withLock { $0 = line + "\n" }
            } catch {
              print("devmgr: \(service): power \(line) failed: \(error.name)")
              throw .unsupported
            }
          }
        })
      }
      platformDirectories.append((service, node))
    }
    let platform = platformDirectories
    // The SCMI agent's host (the power class), once it runs: its tree is
    // the /dev/scmi of each platform device with clocks or SCMI power
    // domains.
    let agent = Locked<String?>(nil)
    // Its namespace: kbdfs's kbin, for keyboards, and the mouse service's
    // mousein, for pointers (D83).
    let namespace = try? Namespace(start)
    launcher.extraStartup = { service, startup in
      guard let e = entries.first(where: { $0.service.map { s in same(s, service) } == true }) else { return }
      if let node = platform.first(where: { same($0.service, service) })?.node {
        do throws(Status) {
          let ends = try Channel.create()
          try tree.serve(ends.a, at: node)
          startup.mount(ends.b, at: "/dev/acpi")
        } catch {
          print("devmgr: \(service): no /dev/acpi: \(error.rawValue)")
        }
      }
      if e.device.acpi?.usesSCMI == true, let scmi = agent.withLock({ $0 }), !same(scmi, service),
        let channel = try? launcher.channel(to: scmi)
      {
        startup.mount(channel, at: "/dev/scmi")
      }
      // An input driver pushes its keys to kbdfs and its pointer's records
      // to the mouse service (D83): its own channel to each. So does a USB
      // host controller's, for the keyboards and mice on its bus.
      if let d = e.driver, same(d.deviceClass, "input") || same(d.deviceClass, "usb") {
        if let kbin = try? namespace?.connect("/dev/kbin") { startup.mount(kbin, at: "/dev/kbin") }
        if let mousein = try? namespace?.connect("/dev/mousein") { startup.mount(mousein, at: "/dev/mousein") }
      }
      let mmio = Handle(raw: mmioRaw)
      let io: Handle? = ioRaw != 0 ? Handle(raw: ioRaw) : nil
      let irqs: Handle? = irqRaw != 0 ? Handle(raw: irqRaw) : nil
      let msi: Handle? = msiRaw != 0 ? Handle(raw: msiRaw) : nil
      var made: [(info: UInt32, handle: UInt32)]?
      if let f = e.device.pci, let w = ecam.window(f.address.bus) {
        // The first root bus's slots, through _PRT (the one bridge's routes
        // devmgr reads).
        let route = f.address.bus == firstWindow.startBus
          ? acpi.routes.first { $0.slot == f.address.device && $0.pin == f.interruptPin } : nil
        let configBase = w.base + UInt64(ECAM.offset(bus: Int(w.startBus), device: 0, function: 0))
        var dma = ""
        let bridge = acpi.bridges.first { $0.covers(bus: f.address.bus) }
        made = try? grants(for: f, ecam: configBase, startBus: w.startBus, bridge: bridge, mmio: mmio, ioports: io,
                           interrupt: route,
                           irqs: irqs, iommus: units, stub: stub, addressBits: e.driver?.addressBits ?? 64, msi: msi,
                           dma: &dma)
        findings.lock.withLock { e.dma = dma }
      } else if let a = e.device.acpi {
        // A stub device id of its own, past every requester id.
        let id = UInt64(1) << 32 | UInt64(entries.firstIndex { $0 === e } ?? 0)
        var dma = "", firmware = ""
        let smc: Handle? = smcRaw != 0 ? Handle(raw: smcRaw) : nil
        made = try? platformGrants(for: a, mmio: mmio, ioports: io, irqs: irqs, stub: stub, id: id,
                                   addressBits: e.driver?.addressBits ?? 64,
                                   call: FirmwareCall.rule(oemID: oemID, oemTableID: oemTableID, hid: a.hid), smc: smc,
                                   firmware: &firmware, dma: &dma)
        if let smc { _ = smc.release() }
        if !firmware.isEmpty { print("devmgr: \(service): firmware \(firmware)") }
        findings.lock.withLock { e.dma = dma }
      }
      _ = mmio.release()
      if let io { _ = io.release() }
      if let irqs { _ = irqs.release() }
      if let msi { _ = msi.release() }
      for h in made ?? [] { startup.add(raw: h.handle, info: h.info) }
    }
    var ethers = 0, displays = 0
    // Each sd(3) letter's units so far (D106): sdF0, sdF1, ...
    var disks: [(letter: String, count: Int)] = []
    // The power class first: its tree is other hosts' /dev/scmi.
    let isPower = { (e: Entry) -> Bool in e.driver.map { same($0.deviceClass, "power") } == true }
    for e in entries.filter(isPower) + entries.filter({ !isPower($0) }) {
      guard let program = e.program, let service = e.service else { continue }
      // A platform device whose DMA isn't cache coherent (_CCA 0): its
      // driver maps the memory it shares with the device uncached; one
      // given other devices' ranges or firmware's memory is told which
      // BAR each is.
      var args = ""
      if let a = e.device.acpi {
        if !a.coherent { args += "arg --noncoherent\n" }
        let call = smcRaw != 0 && FirmwareCall.rule(oemID: oemID, oemTableID: oemTableID, hid: a.hid) != nil
        for b in PlatformTables.barRoles(a, firmwareCall: call) { args += "arg --bar=\(b.index):\(b.role)\n" }
      }
      let manifest = "service \(service)\nprogram \(program)\n\(args)export\nrestart on-failure\n"
      do throws(LaunchError) {
        try launcher.start([(path: "devmgr/\(service)", text: manifest)])
        _ = tree.mount("drivers/\(service)", try launcher.channel(to: service))
        if isPower(e), e.device.acpi != nil { agent.withLock { $0 = service } }
        // A NIC's ether(3) directory, at net/etherN (D82).
        if let d = e.driver, same(d.deviceClass, "net") {
          var host = NodeIPC.NodeClient(channel: try launcher.channel(to: service))
          if let ether = try? host.open("ether") {
            _ = tree.mount("net/ether\(ethers)", ether.takeChannel())
            ethers += 1
          }
        }
        // A display's host tree (D120), at dev/display<n>: its `display`
        // service and its `status`.
        if let d = e.driver, same(d.deviceClass, "display") {
          _ = tree.mount("dev/display\(displays)", try launcher.channel(to: service))
          displays += 1
        }
        // A disk's sd(3) directory, at dev/sd<letter><n>.
        if let d = e.driver, same(d.deviceClass, "block"), !d.sdLetter.isEmpty {
          var host = NodeIPC.NodeClient(channel: try launcher.channel(to: service))
          if let sd = try? host.open("sd") {
            let i = disks.firstIndex { same($0.letter, d.sdLetter) } ?? {
              disks.append((d.sdLetter, 0))
              return disks.count - 1
            }()
            _ = tree.mount("dev/sd\(d.sdLetter)\(disks[i].count)", sd.takeChannel())
            disks[i].count += 1
          }
        }
        findings.lock.withLock { e.state = "running" }
      } catch {
        findings.lock.withLock { e.state = "failed" }
        print("devmgr: \(service): \(error.description)")
      }
    }
    findings.lock.withLock { findings.done = true }
    print("devmgr: bound \(entries.filter { same($0.state, "running") }.count)")
    while true { sleep(until: Int64.max) }
  }
}

/// `text`'s lines (bytes: String's split needs Unicode tables).
/// /dev/reboot's `warmboot` (D101): the images in /dev/warm (kernel and
/// bootfs, and the command line if one was written), each VMO's content
/// size its file's length, with bus mastering off on every PCI function
/// (`busMastering`, once enumerated), back on if the kernel refuses. Why
/// it failed, if it returned.
func warmboot(_ power: borrowing Handle, _ warm: [(node: TreeNode, vmo: UInt32)], _ tree: NodeTree,
              _ busMastering: (stop: @Sendable () -> Void, restore: @Sendable () -> Void)?) -> Status? {
  guard warm.count == 3 else { return .notSupported }
  let lengths = warm.map { tree.length($0.node) ?? 0 }
  guard lengths[0] > 0, lengths[1] > 0 else { return .invalidArgs }  // nothing staged
  for (i, w) in warm.enumerated() where lengths[i] > 0 {
    let vmo = Handle(raw: w.vmo)  // borrowed: devmgr's
    let set = refusal { () throws(Status) in try VMO.setContentSize(vmo, lengths[i]) }
    _ = vmo.release()
    if let set { return set }
  }
  print("devmgr: warm boot, as /dev/reboot asked: kernel \(lengths[0]) bytes, bootfs \(lengths[1]) bytes")
  busMastering?.stop()
  let kernel = Handle(raw: warm[0].vmo), bootfs = Handle(raw: warm[1].vmo), cmdline = Handle(raw: warm[2].vmo)
  let failed = refusal { () throws(Status) in
    if lengths[2] > 0 {
      try Power.warmboot(power, kernel: kernel, bootfs: bootfs, cmdline: cmdline)
    } else {
      try Power.warmboot(power, kernel: kernel, bootfs: bootfs)
    }
  }
  _ = kernel.release()
  _ = bootfs.release()
  _ = cmdline.release()
  busMastering?.restore()
  print("devmgr: the kernel refused the warm boot: \(failed?.rawValue ?? 0)")
  return failed ?? .internal
}

/// What `body` threw, if it did.
func refusal(_ body: () throws(Status) -> Void) -> Status? {
  do throws(Status) { try body() } catch { return error }
  return nil
}

func lines(_ text: String) -> [String] {
  var out: [String] = [], line: [UInt8] = []
  for b in text.utf8 {
    if b == 0x0A {
      out.append(String(decoding: line, as: UTF8.self))
      line = []
    } else {
      line.append(b)
    }
  }
  if !line.isEmpty { out.append(String(decoding: line, as: UTF8.self)) }
  return out
}
