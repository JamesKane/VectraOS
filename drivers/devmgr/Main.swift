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
// device's, its _CRS ranges and interrupt (Grants.swift).
//
// It serves its tree at once, so the launcher sees it ready while it
// binds; `status` grows as it goes, and ends with `bound N`.
//   status             a line a device: name, ids, class, driver host, state, DMA
//   iommus             each unit and whether the kernel took it
//   enumeration        how long finding the PCI functions took, buses mapped
//   acpi               the tables, and how long loading and _STA took
//   dev/               the classes' device directories (D82), granted as /dev
//   drivers/SERVICE/   each driver host's own tree

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
  var summary = "no ACPI tables\n"
  /// \_S5's sleep types, for /dev/reboot's poweroff.
  var sleepTypes: (UInt8, UInt8)?
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
    result.devices.append(Device.ACPIDevice(path: String(decoding: ns.path(d), as: UTF8.self), hid: hid, cids: cids,
                                            status: status, resources: Device.PlatformResource.of(crs)))
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
    + initFailed.map { "_INI failed: \(String(decoding: ns.path($0.device), as: UTF8.self)) \($0.error.name)\n" }.joined()
    + host.log.map { "aml: \($0)\n" }.joined()
  return result
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

    // ECAM: the MCFG's window for segment 0, each bus mapped as it is walked.
    guard let t = tableSet.table(MCFG.signature), let w = (try? MCFG(t))?.windows.first(where: { $0.segment == 0 })
    else { fail("no MCFG: can't reach PCI") }
    let ecam = ECAMWindows(mmioRoot: mmioRaw, base: w.base, startBus: w.startBus, endBus: w.endBus)

    // ACPI's namespace, its regions over this machine.
    let host = MachineHost(
      readMemory: { memory.read($0, width: $1) }, writeMemory: { memory.write($0, width: $1, $2) },
      readPort: ports.map { p in { p.read($0, width: $1) } }, writePort: ports.map { p in { p.write($0, width: $1, $2) } },
      config: ecam)
    let acpi = loadNamespace(tableSet, host: host)
    sleepTypes.withLock { $0 = acpi.sleepTypes }
    let acpiSummary = "tables read in \(tablesRead / 1000) us\n" + acpi.summary
      + "physical pages mapped \(memory.mappedPages)\n"
    findings.lock.withLock { findings.acpi = acpiSummary }
    for line in lines(acpiSummary) { print("devmgr: acpi: \(line)") }

    // The PCI functions.
    let t1 = Clock.monotonic()
    let functions = enumerate(ecam, bus: w.startBus)
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
    let configBase = w.base + UInt64(ECAM.offset(bus: Int(w.startBus), device: 0, function: 0))
    // Its namespace: kbdfs's kbin, for keyboards, and the mouse service's
    // mousein, for pointers (D83).
    let namespace = try? Namespace(start)
    launcher.extraStartup = { service, startup in
      guard let e = entries.first(where: { $0.service.map { s in same(s, service) } == true }) else { return }
      // An input driver pushes its keys to kbdfs and its pointer's records
      // to the mouse service (D83): its own channel to each.
      if let d = e.driver, same(d.deviceClass, "input") {
        if let kbin = try? namespace?.connect("/dev/kbin") { startup.mount(kbin, at: "/dev/kbin") }
        if let mousein = try? namespace?.connect("/dev/mousein") { startup.mount(mousein, at: "/dev/mousein") }
      }
      let mmio = Handle(raw: mmioRaw)
      let io: Handle? = ioRaw != 0 ? Handle(raw: ioRaw) : nil
      let irqs: Handle? = irqRaw != 0 ? Handle(raw: irqRaw) : nil
      let msi: Handle? = msiRaw != 0 ? Handle(raw: msiRaw) : nil
      var made: [(info: UInt32, handle: UInt32)]?
      if let f = e.device.pci {
        // The root bus's slots, through _PRT.
        let route = f.address.bus == w.startBus
          ? acpi.routes.first { $0.slot == f.address.device && $0.pin == f.interruptPin } : nil
        var dma = ""
        made = try? grants(for: f, ecam: configBase, startBus: w.startBus, mmio: mmio, ioports: io, interrupt: route,
                           irqs: irqs, iommus: units, stub: stub, addressBits: e.driver?.addressBits ?? 64, msi: msi,
                           dma: &dma)
        findings.lock.withLock { e.dma = dma }
      } else if let a = e.device.acpi {
        made = try? platformGrants(for: a, mmio: mmio, ioports: io, irqs: irqs)
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
    for e in entries {
      guard let program = e.program, let service = e.service else { continue }
      let manifest = "service \(service)\nprogram \(program)\nexport\nrestart on-failure\n"
      do throws(LaunchError) {
        try launcher.start([(path: "devmgr/\(service)", text: manifest)])
        _ = tree.mount("drivers/\(service)", try launcher.channel(to: service))
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
