// SPDX-License-Identifier: BSD-3-Clause

// A0d: operation regions and field units, through a host that keeps each
// space's bytes and records every access.

@testable import TDACPI
import Testing

/// Loads `aml`, runs \M, and returns the host to look at.
func runRegions(_ aml: [UInt8], _ host: RecordingHost = RecordingHost()) throws(ACPIError) -> (Datum, RecordingHost) {
  var ns = Namespace()
  try ns.load(try Table(AML.dsdt(aml)), host: host)
  return (try ns.evaluate(ns.lookup("\\M")!, host: host), host)
}

@Test func aFieldReadsItsBitsInUnitsOfItsAccessWidth() throws {
  // OperationRegion (R, SystemMemory, 0x1000, 0x10); Field (R, DWordAcc, NoLock, Preserve)
  //   { Offset (1), A, 12, B, 4, Offset (8), C, 32 }
  let host = RecordingHost()
  host.memory[0] = [0x1000: 0x11, 0x1001: 0x22, 0x1002: 0x33, 0x1003: 0x44, 0x1008: 0xEF, 0x1009: 0xBE, 0x100A: 0xAD, 0x100B: 0xDE]
  let aml = AML.region("R", space: 0, AML.integer(0x1000), AML.integer(0x10))
    + AML.field("R", 0x03, [.reserved(8), .named("A", 12), .named("B", 4), .reserved(32), .named("C", 32)])
    + method(AML.returning(AML.op(0x72, AML.op(0x77, AML.name("A"), AML.integer(0x10), AML.none), AML.name("B"), AML.none)))
  let (v, _) = try runRegions(aml, host)
  #expect(v.integer == 0x322 * 0x10 + 0x3)  // A = 0x322 (bits 8-19), B = 0x3 (bits 20-23)
  #expect(host.accesses.allSatisfy { $0.1.width == 4 && $0.1.address == 0x1000 })  // DWordAcc
  // C reads its own dword.
  let (c, _) = try runRegions(AML.region("R", space: 0, AML.integer(0x1000), AML.integer(0x10))
                              + AML.field("R", 0x03, [.reserved(64), .named("C", 32)]) + method(AML.returning(AML.name("C"))), host)
  #expect(c.integer == 0xDEAD_BEEF)
}

@Test func writesKeepOrSetTheBitsAroundThemByTheUpdateRule() throws {
  // A nibble at bits 4-7 of a byte holding 0xA5: Preserve keeps the rest,
  // WriteAsOnes sets it, WriteAsZeros clears it.
  for (rule, expected) in [(UInt8(0), UInt8(0x35)), (1, 0x3F), (2, 0x30)] {
    let host = RecordingHost()
    host.memory[0] = [0x2000: 0xA5]
    let aml = AML.region("R", space: 0, AML.integer(0x2000), AML.integer(1))
      + AML.field("R", 0x01 | rule << 5, [.reserved(4), .named("N", 4)])
      + method(AML.store(AML.integer(3), AML.name("N")))
    _ = try runRegions(aml, host)
    #expect(host.memory[0]?[0x2000] == expected, "update rule \(rule)")
    #expect(host.accesses.contains { $0.write } && (rule == 0) == host.accesses.contains { !$0.write })  // only Preserve reads
  }
}

@Test func anyAccessTakesTheSmallestAlignedUnitThatHoldsTheField() throws {
  let host = RecordingHost()
  // AnyAcc: a 16-bit field at byte 2 is one word; a 16-bit field at byte 3
  // straddles words, so the smallest unit holding it is a dword.
  let aml = AML.region("R", space: 1, AML.integer(0x60), AML.integer(8))
    + AML.field("R", 0x00, [.reserved(16), .named("W", 16), .reserved(8), .named("S", 16)])
    + method(AML.store(AML.name("W"), AML.local(0)) + AML.store(AML.name("S"), AML.local(1)) + AML.returning(AML.integer(0)))
  _ = try runRegions(aml, host)
  #expect(host.accesses.map { $0.1.width } == [2, 4])
  #expect(host.accesses.map { $0.1.address } == [0x62, 0x64])
}

@Test func aFieldWiderThanAnIntegerIsABuffer() throws {
  let host = RecordingHost()
  for i in 0..<12 { host.memory[0, default: [:]][0x3000 + UInt64(i)] = UInt8(i + 1) }
  let aml = AML.region("R", space: 0, AML.integer(0x3000), AML.integer(12))
    + AML.field("R", 0x01, [.named("BIG", 96)]) + method(AML.returning(AML.name("BIG")))
  #expect(try runRegions(aml, host).0.bytes == Array(1...12))
}

@Test func anIndexFieldWritesTheOffsetThenUsesTheData() throws {
  // OperationRegion (IO, SystemIO, 0x70, 2); Field (IO, ByteAcc) { IDX, 8, DAT, 8 }
  // IndexField (IDX, DAT, ByteAcc) { Offset (0x10), REG, 8 }
  let host = RecordingHost()
  let aml = AML.region("IO", space: 1, AML.integer(0x70), AML.integer(2))
    + AML.field("IO", 0x01, [.named("IDX", 8), .named("DAT", 8)])
    + AML.indexField("IDX", "DAT", 0x01, [.reserved(0x80), .named("REG", 8)])
    + method(AML.store(AML.integer(0x5A), AML.name("REG")) + AML.returning(AML.name("REG")))
  #expect(try runRegions(aml, host).0.integer == 0x5A)
  // Write: index 0x10 to 0x70, data to 0x71; read: index again, then data.
  #expect(host.accesses.map { [$0.write ? 1 : 0, Int($0.1.address), Int($0.2)] }
          == [[1, 0x70, 0x10], [1, 0x71, 0x5A], [1, 0x70, 0x10], [0, 0x71, 0x5A]])
}

@Test func aBankFieldSelectsItsBankFirst() throws {
  let host = RecordingHost()
  let aml = AML.region("IO", space: 1, AML.integer(0x80), AML.integer(4))
    + AML.field("IO", 0x01, [.named("BNK", 8)])
    + AML.bankField("IO", "BNK", AML.integer(2), 0x01, [.reserved(16), .named("VAL", 8)])
    + method(AML.returning(AML.name("VAL")))
  host.memory[1] = [0x82: 0x77]
  #expect(try runRegions(aml, host).0.integer == 0x77)
  #expect(host.accesses.map { [$0.write ? 1 : 0, Int($0.1.address), Int($0.2)] } == [[1, 0x80, 2], [0, 0x82, 0x77]])
}

@Test func aRegionsPlaceIsEvaluatedAndPCIRegionsFindTheirFunction() throws {
  // A region whose base is a Name; and a PCI_Config region in a device
  // (_ADR 0x001F0003) under a root bridge with _BBN 2.
  let host = RecordingHost()
  let aml = AML.nameObject("BASE", AML.integer(0x4000))
    + AML.region("MEM", space: 0, AML.name("BASE"), AML.integer(4)) + AML.field("MEM", 0x03, [.named("D", 32)])
    + AML.scope("\\_SB", AML.device("PCI0", AML.nameObject("_BBN", AML.integer(2))
      + AML.device("LPC", AML.nameObject("_ADR", AML.integer(0x001F_0003))
        + AML.region("CFG", space: 2, AML.integer(0x40), AML.integer(0x10)) + AML.field("CFG", 0x03, [.named("V", 32)]))))
    + method(AML.store(AML.name("D"), AML.local(0)) + AML.returning(AML.name("\\_SB.PCI0.LPC.V")))
  _ = try runRegions(aml, host)
  #expect(host.accesses[0].1.address == 0x4000)
  #expect(host.accesses[1].1 == RegionAccess(space: 2, address: 0x40, width: 4,
                                             pci: PCIAddress(segment: 0, bus: 2, device: 0x1F, function: 3)))
}

@Test func aSpaceWithNoHandlerAbortsTheMethod() throws {
  let host = RecordingHost()
  host.unhandled = [3]  // EmbeddedControl
  let aml = AML.region("EC", space: 3, AML.integer(0), AML.integer(0xFF)) + AML.field("EC", 0x01, [.named("TMP", 8)])
    + method(AML.returning(AML.name("TMP")))
  #expect(throws: ACPIError.unsupported) { try runRegions(aml, host) }
}

@Test(.enabled(if: Corpus.machines.contains { SnapshotHost.hasMemory($0) }, "no memory snapshot: sudo vx acpi import"))
func everyDeviceLinuxSeesIsInTheNamespaceWithTheMachinesMemory() throws {
  // The tables loaded as Linux loaded them: load-time conditions read the
  // firmware memory Linux saw (vx acpi import's snapshot), and _OSI
  // answers as Windows does. Every device Linux enumerated is then here.
  for machine in Corpus.machines where SnapshotHost.hasMemory(machine) {
    guard let oracle = Corpus.bytes(machine, "linux-devices.tsv") else { continue }
    var ns = Namespace()
    let host = SnapshotHost(machine)
    for file in corpusLoads(machine).first ?? [] { try ns.load(try Table(try #require(Corpus.bytes(machine, file))), host: host) }
    #expect(ns.problems.isEmpty, "\(machine): \(ns.problems.prefix(5))")
    var missing: [String] = []
    var checked = 0
    for line in String(decoding: oracle, as: UTF8.self).split(separator: "\n") where !line.hasPrefix("#") {
      let path = String(line.split(separator: "\t", omittingEmptySubsequences: false)[0])
      checked += 1
      if ns.lookup(Array(path.utf8)) == nil { missing.append(path) }
    }
    #expect(missing.isEmpty, "\(machine): \(missing.count) of \(checked) missing: \(missing.prefix(8))")
  }
}

@Test func aRegionMadeInAMethodTakesItsPlaceFromTheCall() throws {
  // Method (M, 1) { OperationRegion (VARM, SystemIO, Arg0, 4); Field (VARM, DWordAcc) { VARR, 32 }
  //   Store (0x1234, VARR) }, called with 0x80: the region's offset is evaluated as the
  // OperationRegion runs, with the method's arguments (§19.6.98).
  let host = RecordingHost()
  var ns = Namespace()
  let body = AML.region("VARM", space: 1, AML.arg(0), AML.integer(4)) + AML.field("VARM", 0x03, [.named("VARR", 32)])
    + AML.store(AML.integer(0x1234), AML.name("VARR"))
  try ns.load(try Table(AML.dsdt(AML.method("M", args: 1, body))), host: host)
  _ = try ns.evaluate(ns.lookup("\\M")!, [.integer(0x80)], host: host)
  #expect(host.accesses.map { [$0.1.address, $0.2] } == [[0x80, 0x1234]])
  #expect(ns.lookup("\\M.VARM") == nil)  // gone with the call
}
