// SPDX-License-Identifier: BSD-3-Clause

// The firmware's ACPI tables as a bootfs test program reads them
// (bin/acpi-test, bin/irq-test): the RSDP from the boot data, the tables
// through physical VMOs, and a host with no operation regions yet.

import LibSys
import Sys
import TDACPI

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

func bytes(_ text: StaticString) -> [UInt8] {
  unsafe Array(UnsafeBufferPointer(start: text.utf8Start, count: text.utf8CodeUnitCount))
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
