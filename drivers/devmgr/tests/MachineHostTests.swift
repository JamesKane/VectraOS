// SPDX-License-Identifier: BSD-3-Clause

// devmgr's ACPI host over QEMU's q35 tables (M3h): AML's regions reach
// memory, ports and the function's configuration space as given.

import DevMgr
import Foundation
import PCI
import TDACPI
import Testing

/// Configuration space that remembers accesses: every function reads as
/// zeros except for a few values set.
final class RecordingConfig: ConfigSpace, @unchecked Sendable {
  var values: [FunctionAddress: [Int: UInt32]] = [:]
  var accesses: [(FunctionAddress, Int, Int, Bool)] = []
  func read(_ f: FunctionAddress, _ offset: Int, width: Int) -> UInt32 {
    accesses.append((f, offset, width, false))
    var v: UInt32 = 0
    for i in 0..<width { v |= UInt32((values[f]?[offset + i] ?? 0) & 0xFF) << (8 * UInt32(i)) }
    return v
  }
  func write(_ f: FunctionAddress, _ offset: Int, width: Int, _ value: UInt32) {
    accesses.append((f, offset, width, true))
    for i in 0..<width { values[f, default: [:]][offset + i] = (value >> (8 * UInt32(i))) & 0xFF }
  }
}

func q35Tables() -> [Table]? {
  let dir = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../.cache/acpi/qemu-x86-q35")
  guard let dsdt = try? Data(contentsOf: dir.appending(path: "DSDT")) else { return nil }
  return [try! Table(Array(dsdt))]
}

/// The status q35's AML gives each device, over a machine where
/// `config` holds the LPC bridge's registers and the HPET's capabilities
/// read as `hpet`.
func q35Statuses(_ tables: [Table], _ config: RecordingConfig, hpet: [UInt64: UInt64])
  throws -> (statuses: [String: UInt64], memory: [UInt64], ports: [UInt16])
{
  var memory: [UInt64] = [], ports: [UInt16] = []
  let host = MachineHost(readMemory: { a, _ in memory.append(a); return hpet[a] ?? 0 },
                         writeMemory: { _, _, _ in true }, readPort: { p, _ in ports.append(p); return 0 },
                         writePort: { _, _, _ in true }, config: config)
  var ns = Namespace(integerBits: 64)
  for t in tables { try ns.load(t, host: host) }
  #expect(ns.initializeDevices(host: host).isEmpty)
  var statuses: [String: UInt64] = [:]
  for d in ns.deviceNodes() { statuses[String(decoding: ns.path(d), as: UTF8.self)] = (try ns.status(d, host: host)).raw }
  return (statuses, memory, ports)
}

@Test func q35RegionsReachTheMachine() throws {
  guard let tables = q35Tables() else { return }  // no corpus (vx acpi fetch-qemu)
  let lpc = FunctionAddress(bus: 0, device: 0x1F, function: 0)
  let config = RecordingConfig()
  // PIRQA routed nowhere (bit 7), the rest to IRQs.
  config.values[lpc] = [0x60: 0x80, 0x61: 0x0B, 0x62: 0x0A, 0x63: 0x0B, 0x68: 0x0A, 0x69: 0x0A, 0x6A: 0x0B, 0x6B: 0x0B]
  let hpet: [UInt64: UInt64] = [0xFED0_0000: 0x8086_A201, 0xFED0_0004: 0x0098_9680]
  let (statuses, memory, ports) = try q35Statuses(tables, config, hpet: hpet)
  // Every configuration access is the LPC bridge's PIRQ routing registers.
  #expect(!config.accesses.isEmpty)
  #expect(config.accesses.allSatisfy { $0.0 == lpc && ((0x60...0x63).contains($0.1) || (0x68...0x6B).contains($0.1)) })
  // A link whose PIRQ is routed nowhere is disabled (_STA 0x09), the rest enabled (0x0B).
  #expect(statuses["\\_SB_.LNKA"] == 0x09)
  #expect(statuses["\\_SB_.LNKB"] == 0x0B)
  #expect(statuses["\\_SB_.LNKH"] == 0x0B)
  // The HPET is present when its registers say an HPET is there.
  #expect(memory.allSatisfy { $0 >= 0xFED0_0000 && $0 < 0xFED0_0400 })
  #expect(statuses["\\_SB_.HPET"] == 0x0F)
  #expect(!ports.isEmpty)
  // With nothing behind it, the HPET is absent.
  #expect(try q35Statuses(tables, RecordingConfig(), hpet: [:]).statuses["\\_SB_.HPET"] == 0)
}

/// q35's root bus in APIC mode: every slot's pins through GSIA-GSIH,
/// GSIs 16-23, level and active high (QEMU's IOAPIC PCI lines).
@Test func q35RoutesThroughTheAPIC() throws {
  guard let tables = q35Tables() else { return }
  let host = MachineHost(readMemory: { _, _ in 0 }, writeMemory: { _, _, _ in true }, readPort: { _, _ in 0 },
                         writePort: { _, _, _ in true }, config: RecordingConfig())
  var ns = Namespace(integerBits: 64)
  for t in tables { try ns.load(t, host: host) }
  try ns.useAPIC(host: host)
  let routes = try ns.interruptRoutes(host: host)
  #expect(routes.count == 32 * 4)
  #expect(Set(routes.map { $0.gsi }) == Set(16...23))
  #expect(routes.allSatisfy { $0.mode == .levelHigh })
  // Each slot's four pins reach four different GSIs.
  let slot3 = routes.filter { $0.slot == 3 }.sorted { $0.pin < $1.pin }
  #expect(slot3.map { $0.pin } == [1, 2, 3, 4] && Set(slot3.map { $0.gsi }).count == 4)
  print("q35 slot 3:", slot3.map { "INT\(["A", "B", "C", "D"][Int($0.pin) - 1]) GSI \($0.gsi)" })
}
