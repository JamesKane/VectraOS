// SPDX-License-Identifier: BSD-3-Clause

// A0e: devices: identity, status, initialization order, resources, PCI
// interrupt routing and _OSC.

@testable import TDACPI
import Testing

@Test func eisaIDsDecodeToText() {
  #expect(Namespace.eisaID(0x080A_D041) == Array("PNP0A08".utf8))
  #expect(Namespace.eisaID(0x0A0C_D041) == Array("PNP0C0A".utf8))  // a battery
  // ToUUID's byte order (§19.6.142): the PCI host bridge _OSC UUID.
  #expect(Namespace.uuid("33DB4D5B-1FF7-401C-9657-7441C03DD766")
          == [0x5B, 0x4D, 0xDB, 0x33, 0xF7, 0x1F, 0x1C, 0x40, 0x96, 0x57, 0x74, 0x41, 0xC0, 0x3D, 0xD7, 0x66])
}

@Test func resourceTemplatesDecodeEveryCommonDescriptor() throws {
  var t: [UInt8] = []
  t += [0x23, 0x10, 0x00, 0x19]  // IRQ (4), shared, level, low
  t += [0x47, 0x01, 0x60, 0x00, 0x60, 0x00, 0x01, 0x01]  // IO (Decode16, 0x60, 0x60, 1, 1)
  t += [0x86, 0x09, 0x00, 0x01, 0x00, 0x00, 0xD0, 0xFE, 0x00, 0x10, 0x00, 0x00]  // Memory32Fixed (RW, 0xFED00000, 0x1000)
  var dword: [UInt8] = [0x00, 0x0C, 0x03]  // memory, minimum and maximum fixed, cacheable
  for v: UInt32 in [0, 0xC000_0000, 0xDFFF_FFFF, 0, 0x2000_0000] { dword += le(UInt64(v), 4) }
  t += [0x87] + le(UInt64(dword.count), 2) + dword
  var ext: [UInt8] = [0x0D, 2] + le(40, 4) + le(41, 4) + [0] + Array("\\_SB.GPIO".utf8) + [0]
  t += [0x89] + le(UInt64(ext.count), 2) + ext
  // GPIO interrupt on pins 5 and 6 of \_SB.GPIO (offsets from the descriptor's start).
  let pinTable = 23, name = pinTable + 4
  var gpio: [UInt8] = [1, 0] + le(0, 2) + le(0x0001, 2) + [0] + le(0, 2) + le(0, 2) + le(UInt64(pinTable), 2)
  gpio += [0] + le(UInt64(name), 2) + le(0, 2) + le(0, 2) + le(5, 2) + le(6, 2) + Array("\\_SB.GPIO".utf8) + [0]
  t += [0x8C] + le(UInt64(gpio.count), 2) + gpio
  // I2C at address 0x50, 400 kHz, on \_SB.I2CA.
  let i2cData = le(400_000, 4) + le(0x50, 2)
  ext = [2, 0, 1, 0] + le(0, 2) + [1] + le(UInt64(i2cData.count), 2) + i2cData + Array("\\_SB.I2CA".utf8) + [0]
  t += [0x8E] + le(UInt64(ext.count), 2) + ext
  t += [0x79, 0x00]
  let r = try Resources.decode(t)
  #expect(r.count == 7)
  #expect(r[0] == .irq(mask: 0x10, flags: 0x19))
  #expect(r[1] == .io(decode16: true, minimum: 0x60, maximum: 0x60, alignment: 1, length: 1))
  #expect(r[2] == .memory32Fixed(writable: true, base: 0xFED0_0000, length: 0x1000))
  guard case .address(let a) = r[3] else { throw ACPIError.typeMismatch }
  #expect(a.kind == 0 && a.minimum == 0xC000_0000 && a.maximum == 0xDFFF_FFFF && a.length == 0x2000_0000)
  #expect(r[4] == .extendedIRQ(flags: 0x0D, interrupts: [40, 41], source: ResourceSource(index: 0, path: Array("\\_SB.GPIO".utf8))))
  guard case .gpio(let g) = r[5], case .serialBus(let s) = r[6] else { throw ACPIError.typeMismatch }
  #expect(g.type == 0 && g.pins == [5, 6] && g.source == Array("\\_SB.GPIO".utf8))
  #expect(s.type == 1 && s.typeData == i2cData && s.source == Array("\\_SB.I2CA".utf8))
  // A checksum, when given, must hold; no end tag, or a cut descriptor, is an error.
  var summed = t
  summed[summed.count - 1] = 0 &- summed.dropLast().reduce(0, &+)
  #expect(try Resources.decode(summed).count == 7)
  summed[2] ^= 1  // a data byte: the descriptors still parse
  #expect(throws: ACPIError.badChecksum) { try Resources.decode(summed) }
  #expect(throws: ACPIError.badResourceTemplate) { try Resources.decode(Array(t.dropLast(2))) }
  #expect(throws: ACPIError.badResourceTemplate) { try Resources.decode(Array(t[..<10])) }
}

@Test func aDeviceTellsWhatItIs() throws {
  let host = RecordingHost()
  var ns = Namespace()
  let aml = AML.scope("\\_SB", AML.device("PCI0", AML.nameObject("_HID", AML.integer(0x080A_D041))
    + AML.nameObject("_CID", AML.packageOf([AML.integer(0x030A_D041), AML.string("ACPI0008")]))
    + AML.nameObject("_UID", AML.integer(21)) + AML.nameObject("_ADR", AML.integer(0x0008_0001))
    + AML.method("_STA", AML.returning(AML.integer(0x0B)))
    + AML.device("CHLD", AML.nameObject("_HID", AML.string("AMDI0010")))))
  try ns.load(try Table(AML.dsdt(aml)), host: host)
  let pci = ns.lookup("\\_SB.PCI0")!, child = ns.lookup("\\_SB.PCI0.CHLD")!
  #expect(try ns.hardwareID(pci, host: host) == Array("PNP0A08".utf8))
  #expect(try ns.compatibleIDs(pci, host: host) == [Array("PNP0A03".utf8), Array("ACPI0008".utf8)])
  #expect(try ns.uniqueID(pci, host: host) == Array("21".utf8))
  #expect(try ns.address(pci, host: host) == 0x0008_0001)
  let s = try ns.status(pci, host: host)
  #expect(s.raw == 0x0B && s.present && s.enabled && s.functioning)
  #expect(try ns.status(child, host: host) == .assumed)  // no _STA
  #expect(try ns.hardwareID(child, host: host) == Array("AMDI0010".utf8) && ns.uniqueID(child, host: host) == nil)
  #expect(ns.deviceNodes() == [pci, child])
}

@Test func initializationRunsParentsFirstAndSkipsWhatIsntThere() throws {
  // Each _INI appends its letter to \ORD: a device absent and not
  // functioning keeps its children from initializing; one functioning but
  // absent doesn't run its own _INI, but its children's run.
  func ini(_ letter: String) -> [UInt8] {
    AML.method("_INI", AML.store(AML.op(0x73, AML.name("\\ORD"), AML.string(letter), AML.none), AML.name("\\ORD")))
  }
  func sta(_ v: UInt64) -> [UInt8] { AML.method("_STA", AML.returning(AML.integer(v))) }
  let aml = AML.nameObject("ORD", AML.string(""))
    + AML.scope("\\_SB", ini("S")
      + AML.device("A", ini("a") + AML.device("A1", ini("b")))
      + AML.device("GONE", sta(0) + ini("x") + AML.device("G1", ini("y")))
      + AML.device("FUNC", sta(8) + ini("z") + AML.device("F1", ini("c"))))
  let host = RecordingHost()
  var ns = Namespace()
  try ns.load(try Table(AML.dsdt(aml)), host: host)
  #expect(ns.initializeDevices(host: host).isEmpty)
  #expect(try ns.evaluate(ns.lookup("\\ORD")!, host: host).string == Array("Sabc".utf8))
}

@Test func routingAndCapabilities() throws {
  // _PRT: slot 2 INTA through link \_SB.LNKA, slot 3 INTB to GSI 19.
  let prt = AML.packageOf([
    AML.packageOf([AML.integer(0x0002_FFFF), AML.integer(0), AML.name("\\_SB.LNKA"), AML.integer(0)]),
    AML.packageOf([AML.integer(0x0003_FFFF), AML.integer(1), AML.integer(0), AML.integer(19)]),
  ])
  // _OSC grants what it's asked for, less bit 1 of the second dword.
  let osc = AML.method("_OSC", args: 4, AML.op(0x8A, AML.arg(3), AML.integer(4), AML.name("CTRL"))
                         + AML.store(AML.op(0x7B, AML.name("CTRL"), AML.integer(~UInt64(2) & 0xFFFF_FFFF), AML.none), AML.name("CTRL"))
                         + AML.returning(AML.arg(3)))
  let aml = AML.scope("\\_SB", AML.device("LNKA", []) + AML.device("PCI0", AML.nameObject("_PRT", prt) + osc))
  let host = RecordingHost()
  var ns = Namespace()
  try ns.load(try Table(AML.dsdt(aml)), host: host)
  let pci = ns.lookup("\\_SB.PCI0")!
  #expect(try ns.routing(pci, host: host) == [PCIRoute(device: 2, pin: 0, link: ns.lookup("\\_SB.LNKA"), index: 0),
                                             PCIRoute(device: 3, pin: 1, link: nil, index: 19)])
  let granted = try ns.operatingSystemCapabilities(pci, uuid: Namespace.uuid("33DB4D5B-1FF7-401C-9657-7441C03DD766"),
                                                   revision: 1, [0, 0x1F, 0x1D], host: host)
  #expect(granted == [0, 0x1D, 0x1D])
}

/// A host for a whole corpus machine: QEMU's spaces read as zeros; this
/// machine's, without its firmware memory, have no handler.
func corpusHost(_ machine: String) -> RecordingHost {
  let host = RecordingHost()
  if !machine.hasPrefix("qemu-") { host.unhandled = Set(0...255) }
  host.interfaces = OSInterfaces.windows + OSInterfaces.features
  return host
}

@Test(.enabled(if: Corpus.isPresent, "no corpus: vx acpi import, vx acpi fetch-qemu"))
func everyResourceTemplateAndRouteInTheCorpusDecodes() throws {
  var resources = 0, routes = 0
  for machine in Corpus.machines {
    for set in corpusLoads(machine) {
      var ns = Namespace()
      let host = corpusHost(machine)
      for file in set { try ns.load(try Table(try #require(Corpus.bytes(machine, file))), host: host) }
      for d in ns.deviceNodes() {
        let where_ = "\(machine) \(set.count > 1 ? "base" : set[0]) \(String(decoding: ns.path(d), as: UTF8.self))"
        do {
          resources += try ns.currentResources(d, host: host)?.count ?? 0
        } catch .unsupported {
        } catch {
          Issue.record("\(where_) _CRS: \(error)")
        }
        do {
          for r in try ns.routing(d, host: host) ?? [] {
            routes += 1
            if let link = r.link { #expect(ns.nodes[link].object == .device, "\(where_): a _PRT link isn't a device") }
          }
        } catch .unsupported {
        } catch {
          Issue.record("\(where_) _PRT: \(error)")
        }
      }
      for f in ns.initializeDevices(host: host) where f.error != .unsupported {
        Issue.record("\(machine) \(set): _INI of \(String(decoding: ns.path(f.device), as: UTF8.self)): \(f.error)")
      }
    }
  }
  #expect(resources > 1000 && routes > 5000)
}

@Test(.enabled(if: Corpus.machines.contains { Corpus.bytes($0, "linux-devices.tsv") != nil }, "no oracle: vx acpi import"))
func whatDevicesSayTheyAreMatchesLinux() throws {
  // For every device Linux lists, each of _HID, _CID, _UID, _ADR and _STA
  // we can evaluate (without firmware memory, some can't) equals Linux's.
  for machine in Corpus.machines {
    guard let oracle = Corpus.bytes(machine, "linux-devices.tsv") else { continue }
    var ns = Namespace()
    let host = corpusHost(machine)
    for file in corpusLoads(machine).first ?? [] { try ns.load(try Table(try #require(Corpus.bytes(machine, file))), host: host) }
    var compared = 0
    func check(_ ours: () throws(ACPIError) -> String?, _ linux: String, _ what: String, _ path: String) {
      do {
        guard let v = try ours() else {
          #expect(linux.isEmpty, "\(machine) \(path) \(what): Linux has \(linux), we have none")
          return
        }
        compared += 1
        #expect(v == linux, "\(machine) \(path) \(what): ours \(v), Linux's \(linux)")
      } catch .unsupported {
      } catch {
        Issue.record("\(machine) \(path) \(what): \(error)")
      }
    }
    for line in String(decoding: oracle, as: UTF8.self).split(separator: "\n") where !line.hasPrefix("#") {
      let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      guard f.count >= 6, let d = ns.lookup(Array(f[0].utf8)), ns.nodes[d].object == .device else { continue }
      let text = { (b: [UInt8]?) in b.map { String(decoding: $0, as: UTF8.self) } }
      // Linux names some devices itself (LNXVIDEO, LNXSYBUS...): not the firmware's.
      if !f[1].hasPrefix("LNX") { check({ () throws(ACPIError) in text(try ns.hardwareID(d, host: host)) }, f[1], "_HID", f[0]) }
      check({ () throws(ACPIError) in text(try ns.uniqueID(d, host: host)) }, f[2], "_UID", f[0])
      check({ () throws(ACPIError) -> String? in
        guard let a = try ns.address(d, host: host) else { return nil }
        let hex = String(a, radix: 16)
        return "0x" + String(repeating: "0", count: max(0, 8 - hex.count)) + hex
      }, f[3], "_ADR", f[0])
      if !f[4].isEmpty {
        check({ () throws(ACPIError) in String(try ns.status(d, host: host).raw) }, f[4], "_STA", f[0])
      }
      // The modalias: acpi:HID:CID...: (Linux's own IDs aside).
      let ids = f[5].split(separator: ":").dropFirst().map(String.init).filter { !$0.hasPrefix("LNX") }
      if ids.count > 1 {
        check({ () throws(ACPIError) in try ns.compatibleIDs(d, host: host).map { String(decoding: $0, as: UTF8.self) }
          .filter { !$0.hasPrefix("LNX") }.joined(separator: ":") }, ids.dropFirst().joined(separator: ":"), "_CID", f[0])
      }
    }
    #expect(compared > 200, "\(machine): only \(compared) values compared")
  }
}
