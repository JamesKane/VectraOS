// SPDX-License-Identifier: BSD-3-Clause

// bin/acpi-test (V2 item 7a, D74): the AML interpreter natively, on the
// firmware tables this boot was given, what ACPITests checks hosted over
// QEMU's: the RSDP from the boot data, the tables walked from it with
// their checksums, the DSDT and SSDTs loaded with their load-time code
// run, the devices initialized, a PCI host bridge with its _CRS and _PRT,
// and on amd64 \_S5 (what userboot's byte scan finds) and the CMOS clock
// (PNP0B00, devmgr's first platform device, 7c). It has no operation
// regions yet (devmgr's host gives them), so code that needs one fails as
// `unsupported`, and nothing else may. userboot starts it
// (userboot.next=bin/acpi-test, the boot-acpi test), with the root
// resource and the boot data; it exits 0 if every check passed.

import LibSys
import Sys
import TDACPI

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func check(_ condition: Bool, _ name: StaticString) {
  checks += 1
  if !condition {
    failures += 1
    print("acpi-test: FAILED: \(name)")
  }
}

func bytes(_ text: StaticString) -> [UInt8] {
  unsafe Array(UnsafeBufferPointer(start: text.utf8Start, count: text.utf8CodeUnitCount))
}

/// What the interpreter asks of the machine: no operation regions yet.
final class Host: ACPIHost {
  func supportsInterface(_ name: [UInt8]) -> Bool { OSInterfaces.claims(name) }
  func sleep(milliseconds: UInt64) {}
  func stall(microseconds: UInt64) {}
  func notify(_ node: Int, _ value: UInt64) {}
  func timer() -> UInt64 { UInt64(Clock.monotonic() / 100) }
  func debug(_ text: [UInt8]) {}
  func fatal(type: UInt8, code: UInt32, argument: UInt64) {}
}

/// Firmware memory, read through a physical VMO (cached, as K9b's are).
func readPhysical(_ root: borrowing Handle, _ address: UInt64, _ count: Int) -> [UInt8]? {
  let page: UInt64 = 4096
  let first = address & ~(page - 1)
  let length = Int(((address + UInt64(count) + page - 1) & ~(page - 1)) - first)
  guard let vmo = try? VMO.physical(resource: root, address: first, size: length),
    (try? VMO.setCachePolicy(vmo, .cached)) != nil,
    let m = try? VMO.map(vmo, length: length, writable: false)
  else { return nil }
  return m.read(at: Int(address - first), count: count)
}

/// The RSDP's address: the boot data's ACPI_RSDP item (zbi.h).
func rsdpAddress(_ bootData: borrowing Handle) -> UInt64? {
  guard let size = try? VMO.size(bootData), let m = try? VMO.map(bootData, length: size, writable: false) else {
    return nil
  }
  let header = 32
  var at = header  // past the container's own
  while at + header <= size {
    let type = m.load(UInt32.self, at: at)
    let length = Int(m.load(UInt32.self, at: at + 4))
    if type == 0x5044_5352, length == 8, at + header + 8 <= size { return m.load(UInt64.self, at: at + header) }  // "RSDP"
    at += header + ((length + 7) & ~7)
  }
  return nil
}

@main struct ACPITest {
  static func main() {
    let start = Startup.current
    guard let root = start.take(HandleType.info(HandleType.rootResource)),
      let bootData = start.take(HandleType.info(HandleType.vmoBootData))
    else {
      print("acpi-test: FAILED: no root resource or boot data")
      Process.exit(code: 1)
    }
    guard let address = rsdpAddress(bootData), let raw = readPhysical(root, address, 36),
      let rsdp = try? RSDP(raw)
    else {
      print("acpi-test: FAILED: no RSDP")
      Process.exit(code: 1)
    }
    check(true, "the boot data gives the RSDP")
    let read = { (a: UInt64, n: Int) -> [UInt8]? in readPhysical(root, a, n) }
    guard let tables = try? TableSet(rsdp: rsdp, read: read), let dsdt = tables.dsdt else {
      print("acpi-test: FAILED: no tables from the RSDP")
      Process.exit(code: 1)
    }
    check(tables.fadt != nil, "the tables have a FADT")

    // The DSDT, then each SSDT, load-time code run.
    var ns = Namespace(integerBits: tables.integerBits)
    let host = Host()
    var loaded = true
    for table in [dsdt] + tables.ssdts {
      do throws(ACPIError) { try ns.load(table, host: host) } catch { loaded = false }
    }
    check(loaded, "the DSDT and SSDTs load")
    check(ns.problems.allSatisfy { $0.kind == .codeFailed(.unsupported) }, "loading has no problem but regions")
    let failed = ns.initializeDevices(host: host)
    check(failed.allSatisfy { $0.error == .unsupported }, "devices initialize but for regions")

    // Each device's identity, and the PCI host bridge's resources and routes.
    var devices = 0, bridges = 0, routes = 0, resources = 0
    var clock: [TDACPI.Resource]? = nil
    for d in ns.deviceNodes() {
      devices += 1
      let hid = (try? ns.hardwareID(d, host: host)) ?? nil
      let cids = (try? ns.compatibleIDs(d, host: host)) ?? []
      if let r = (try? ns.currentResources(d, host: host)) ?? nil { resources += r.count }
      if hid == bytes("PNP0B00") { clock = (try? ns.currentResources(d, host: host)) ?? nil }
      guard hid == bytes("PNP0A08") || hid == bytes("PNP0A03") || cids.contains(bytes("PNP0A03")) else { continue }
      bridges += 1
      if let r = (try? ns.routing(d, host: host)) ?? nil { routes += r.count }
    }
    check(bridges >= 1, "a PCI host bridge")
    check(routes > 0, "its _PRT routes")
    check(resources > 0, "devices' _CRS decode")
    #if arch(x86_64)
    // \_S5: the sleep types userboot's byte scan finds.
    var s5 = false
    if let n = ns.lookup("\\_S5_"), case .package(let p)? = try? ns.evaluate(n, host: host), p.elements.count >= 2,
      case .integer = p.elements[0], case .integer = p.elements[1]
    {
      s5 = true
    }
    check(s5, "\\_S5 evaluates to its sleep types")
    // The CMOS clock, at its ports.
    let ports = clock?.contains { r in
      if case .io(_, let minimum, _, _, let length) = r { return minimum == 0x70 && length >= 2 }
      if case .fixedIO(let base, let length) = r { return base == 0x70 && length >= 2 }
      return false
    } ?? false
    check(ports, "PNP0B00, the CMOS clock, at ports 0x70")
    #else
    _ = clock
    #endif
    print("acpi-test: \(tables.tables.count) tables, \(ns.nodes.count) nodes, \(devices) devices, \(bridges) PCI bridges, \(routes) routes")
    print("acpi-test: \(checks - failures) of \(checks) checks passed")
    Process.exit(code: failures == 0 ? 0 : 1)
  }
}
