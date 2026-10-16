// SPDX-License-Identifier: BSD-3-Clause

// A0a: tables, headers and checksums, and the walk from the RSDP.

import TDACPI
import Testing

@Test func aTableReadsItsHeaderAndChecksIt() throws {
  let bytes = table("DSDT", revision: 2, [0x10, 0x20, 0x30])
  let t = try Table(bytes + [0xEE, 0xEE])  // bytes past its length are dropped
  #expect(t.signature == .dsdt && t.length == 39 && t.revision == 2)
  #expect(Array(t.body) == [0x10, 0x20, 0x30])
  #expect(t.oemID == Array("TDHCAI".utf8) && t.oemTableID == Array("TESTTBL ".utf8))
  var damaged = bytes
  damaged[37] ^= 1
  #expect(throws: ACPIError.badChecksum) { try Table(damaged) }
  #expect(throws: ACPIError.truncated) { try Table(Array(bytes[..<30])) }
  var long = bytes
  long[4] = 200  // says it's longer than it is
  #expect(throws: ACPIError.truncated) { try Table(long) }
}

@Test func theWalkFromTheRSDPFindsEveryTableAndTheDSDT() throws {
  // A tiny physical memory: the RSDP, an XSDT, an RSDT, a FADT naming the
  // DSDT through X_DSDT, an SSDT, and a table with a bad checksum.
  var memory: [UInt64: [UInt8]] = [:]
  let dsdt = table("DSDT", revision: 1, [0x08])
  memory[0x5000] = dsdt
  var fadtBody = [UInt8](repeating: 0, count: 244 - 36)
  for (i, b) in le(0x1234, 4).enumerated() { fadtBody[40 - 36 + i] = b }  // DSDT: wrong on purpose
  for (i, b) in le(0x5000, 8).enumerated() { fadtBody[140 - 36 + i] = b }  // X_DSDT wins
  for (i, b) in le(9, 2).enumerated() { fadtBody[46 - 36 + i] = b }
  memory[0x3000] = table("FACP", revision: 6, fadtBody)
  memory[0x4000] = table("SSDT", [0x10])
  var bad = table("BAD!", [1, 2, 3])
  bad[38] ^= 0xFF
  memory[0x6000] = bad
  memory[0x2000] = table("XSDT", le(0x3000, 8) + le(0x4000, 8) + le(0x6000, 8))
  memory[0x1000] = table("RSDT", le(0x3000, 4))
  let pointer = try RSDP(rsdp(rsdt: 0x1000, xsdt: 0x2000))
  #expect(pointer.revision == 2 && pointer.xsdtAddress == 0x2000)
  let set = try TableSet(rsdp: pointer) { address, count in
    guard let t = memory[address], count <= t.count else { return nil }
    return Array(t[..<count])
  }
  #expect(set.tables.count == 3)  // FACP, SSDT, DSDT; not the damaged one
  #expect(set.ssdts.count == 1 && set.dsdt?.bytes == dsdt)
  #expect(set.fadt?.dsdtAddress == 0x5000 && set.fadt?.sciInterrupt == 9)
  #expect(set.integerBits == 32)  // the DSDT's revision is 1
}

@Test func anRSDPIsCheckedBothWays() throws {
  var r = rsdp(rsdt: 1, xsdt: 2)
  #expect(try RSDP(r).xsdtAddress == 2)
  r[30] ^= 1  // in the extended part only
  #expect(throws: ACPIError.badChecksum) { try RSDP(r) }
  var v1 = Array(rsdp(rsdt: 0x1000, xsdt: 0)[..<20])
  v1[15] = 0  // revision 0: 20 bytes, no XSDT
  v1[8] = 0
  v1[8] = 0 &- v1.reduce(0, &+)
  let p = try RSDP(v1)
  #expect(p.revision == 0 && p.rsdtAddress == 0x1000 && p.xsdtAddress == nil)
  #expect(throws: ACPIError.badSignature) { try RSDP([UInt8](repeating: 0x41, count: 36)) }
}

@Test(.enabled(if: Corpus.isPresent, "no corpus: vx acpi import, vx acpi fetch-qemu"))
func everyTableInTheCorpusReadsWithAGoodChecksum() throws {
  var count = 0
  for machine in Corpus.machines {
    // The FACS isn't a description table: no checksum (ACPI 6.5 §5.2.10).
    for file in Corpus.tableFiles(machine) where !file.hasPrefix("FACS") {
      let bytes = try #require(Corpus.bytes(machine, file))
      let table = try Table(bytes)
      #expect(table.length == bytes.count, "\(machine)/\(file): its length is the file's")
      let name = String(decoding: table.signature.bytes, as: UTF8.self)
      // "FACP" is the FADT; files may carry a suffix (QEMU's variants, SSDT1...).
      #expect(file.hasPrefix(name), "\(machine)/\(file) is a \(name)")
      count += 1
    }
  }
  #expect(count > 100)
}
