// SPDX-License-Identifier: BSD-3-Clause

// bin/pci-test (V2 item 7b, D74): PCI over the ECAM this boot's firmware
// describes, what PCITests checks over a model: the MCFG's window from the
// tables walked from the RSDP, mapped uncached, every function enumerated,
// BARs sized and left as they were, and capability lists walked. qemu.sh
// gives each arch the same devices: edu at 00:10.0 (a 1 MiB BAR and MSI),
// virtio-blk and virtio-rng (modern virtio's vendor capabilities, MSI-X
// and a 64-bit BAR), and on rv64 the RISC-V IOMMU at 00:08.0. userboot
// starts it (userboot.next=bin/pci-test, the boot-pci test), with the root
// resource and the boot data; it exits 0 if every check passed.

import PCI
import Sys
import TDACPI

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func check(_ condition: Bool, _ name: StaticString) {
  checks += 1
  if !condition {
    failures += 1
    print("pci-test: FAILED: \(name)")
  }
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

func function(_ found: [Function], vendor: UInt16, device: UInt16) -> Function? {
  found.first { $0.vendor == vendor && $0.device == device }
}

@main struct PCITest {
  static func main() {
    let start = Startup.current
    guard let root = start.take(HandleType.info(HandleType.rootResource)),
      let bootData = start.take(HandleType.info(HandleType.vmoBootData))
    else {
      print("pci-test: FAILED: no root resource or boot data")
      Process.exit(code: 1)
    }
    guard let address = rsdpAddress(bootData), let raw = readPhysical(root, address, 36),
      let rsdp = try? RSDP(raw),
      let tables = try? TableSet(rsdp: rsdp, read: { (a: UInt64, n: Int) -> [UInt8]? in readPhysical(root, a, n) })
    else {
      print("pci-test: FAILED: no tables from the RSDP")
      Process.exit(code: 1)
    }
    guard let t = tables.table(MCFG.signature), let window = (try? MCFG(t))?.windows.first(where: { $0.segment == 0 })
    else {
      print("pci-test: FAILED: no MCFG window for segment 0")
      Process.exit(code: 1)
    }
    check(window.endBus >= window.startBus, "the MCFG gives segment 0's window")

    // The window's base is bus 0's (PCI Firmware 3.2 §4.1.2), so its buses
    // start startBus MiB in.
    let buses = Int(window.endBus) - Int(window.startBus) + 1
    let size = ECAM.size(buses: buses)
    let base = window.base + UInt64(ECAM.offset(bus: Int(window.startBus), device: 0, function: 0))
    let t0 = Clock.monotonic()
    guard let vmo = try? VMO.physical(resource: root, address: base, size: size),
      (try? VMO.setCachePolicy(vmo, .uncachedDevice)) != nil,
      let mapping = try? VMO.map(vmo, length: size)
    else {
      print("pci-test: FAILED: can't map ECAM")
      Process.exit(code: 1)
    }
    let ecam = unsafe ECAM(unsafe: mapping.address, startBus: window.startBus, endBus: window.endBus)
    let t1 = Clock.monotonic()
    let found = enumerate(ecam, bus: window.startBus)
    let t2 = Clock.monotonic()
    for f in found { print("pci-test: \(f.description)") }

    check(found.contains { $0.address.bus == window.startBus && $0.classCode == 0x06 && $0.subclass == 0x00 },
          "a host bridge on the root bus")

    // edu: its identity, its 1 MiB BAR and its MSI.
    let edu = function(found, vendor: 0x1234, device: 0x11E8)
    check(edu?.address == FunctionAddress(bus: window.startBus, device: 0x10, function: 0), "edu at 00:10.0")
    check(edu?.classCode == 0x00 && edu?.subclass == 0xFF, "edu's class")
    check(edu?.bars.first.map { $0.index == 0 && $0.space == .memory && $0.size == 0x10_0000 } ?? false,
          "edu's BAR 0, 1 MiB")
    check(edu?.capability(0x05) != nil, "edu's MSI")

    // Modern virtio (1af4:1040 + id, or transitional 1af4:1000-103f):
    // vendor capabilities, MSI-X and a 64-bit BAR for its registers.
    let virtio = found.filter { $0.vendor == 0x1AF4 }
    check(virtio.count >= 2, "virtio-blk and virtio-rng")
    check(virtio.allSatisfy { v in v.capabilities.contains { $0.id == 0x09 } && v.capability(0x11) != nil },
          "virtio's vendor capabilities and MSI-X")
    check(virtio.allSatisfy { v in v.bars.contains { $0.space == .memory && $0.is64 && $0.size >= 0x4000 } },
          "virtio's 64-bit BAR")
    #if arch(riscv64)
    check(found.contains { $0.address.device == 0x08 && $0.classCode == 0x08 && $0.subclass == 0x06 },
          "the RISC-V IOMMU at 00:08.0")
    #endif

    // Sizing leaves every BAR and command register as it was: a second
    // pass finds the same.
    check(enumerate(ecam, bus: window.startBus) == found, "enumerating again finds the same")
    print("pci-test: \(found.count) functions on \(buses) buses, mapped in \((t1 - t0) / 1000) us, enumerated in \((t2 - t1) / 1000) us")
    print("pci-test: \(checks - failures) of \(checks) checks passed")
    _ = consume mapping
    Process.exit(code: failures == 0 ? 0 : 1)
  }
}
