// SPDX-License-Identifier: BSD-3-Clause

// ACPI tables from a devicetree (D51): the Orange Pi RV2's U-Boot tree's
// shape and QEMU virt's, read and written out, then walked by the ACPI
// bus driver's own parser.

import DtAcpi
import TDACPI
import Testing

/// A DTB, built node by node.
struct FdtBuilder {
  var structure: [UInt8] = []
  var strings: [UInt8] = []

  mutating func begin(_ name: String) {
    word(1)
    structure += Array(name.utf8) + [0]
    pad()
  }

  mutating func end() { word(2) }

  mutating func prop(_ name: String, _ value: [UInt8]) {
    word(3)
    word(UInt32(value.count))
    word(nameOffset(name))
    structure += value
    pad()
  }

  mutating func prop(_ name: String, cells: [UInt32]) { prop(name, cells.flatMap(Self.be)) }
  mutating func prop(_ name: String, strings list: [String]) { prop(name, list.flatMap { Array($0.utf8) + [0] }) }
  mutating func prop(_ name: String, _ text: String) { prop(name, strings: [text]) }

  func blob() -> [UInt8] {
    let structStart = 40 + 16  // header, then an empty reservation map
    let stringsStart = structStart + structure.count + 4
    let total = stringsStart + strings.count
    var out = [UInt8]()
    for v in [0xd00d_feed, UInt32(total), UInt32(structStart), UInt32(stringsStart), 40, 17, 16, 0,
              UInt32(strings.count), UInt32(structure.count + 4)] as [UInt32] {
      out += Self.be(v)
    }
    out += [UInt8](repeating: 0, count: 16)
    out += structure + Self.be(9)
    out += strings
    return out
  }

  static func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }

  private mutating func word(_ v: UInt32) { structure += Self.be(v) }
  private mutating func pad() { while structure.count % 4 != 0 { structure.append(0) } }

  private mutating func nameOffset(_ name: String) -> UInt32 {
    let bytes = Array(name.utf8) + [0]
    var i = 0
    while i + bytes.count <= strings.count {
      if Array(strings[i..<(i + bytes.count)]) == bytes { return UInt32(i) }
      i += 1
    }
    strings += bytes
    return UInt32(strings.count - bytes.count)
  }
}

/// The RV2's tree as its U-Boot passes it (docs/boards/orangepi-rv2): base
/// letters only, the PLIC as "riscv,plic0" with an unwired M context per
/// hart, the console through an alias.
func rv2Tree(harts: Int = 8) -> [UInt8] {
  var b = FdtBuilder()
  b.begin("")
  b.prop("#address-cells", cells: [2])
  b.prop("#size-cells", cells: [2])
  b.prop("compatible", strings: ["ky,x1", "riscv"])
  b.begin("chosen")
  b.prop("stdout-path", "serial0:115200n8")
  b.end()
  b.begin("aliases")
  b.prop("serial0", "/soc/uart@d4017000")
  b.prop("mmc0", "/soc/sdh@d4280000")
  b.end()
  b.begin("cpus")
  b.prop("#address-cells", cells: [1])
  b.prop("#size-cells", cells: [0])
  b.prop("timebase-frequency", cells: [24_000_000])
  for i in 0..<harts {
    b.begin("cpu@\(i)")
    b.prop("compatible", "riscv")
    b.prop("device_type", "cpu")
    b.prop("reg", cells: [UInt32(i)])
    b.prop("status", "okay")
    b.prop("riscv,isa", "rv64imafdcv")
    b.prop("mmu-type", "riscv,sv39")
    b.begin("interrupt-controller")
    b.prop("#interrupt-cells", cells: [1])
    b.prop("compatible", "riscv,cpu-intc")
    b.prop("phandle", cells: [UInt32(i + 1)])
    b.end()
    b.end()
  }
  b.end()
  b.begin("soc")
  b.prop("#address-cells", cells: [2])
  b.prop("#size-cells", cells: [2])
  b.prop("compatible", "simple-bus")
  b.begin("interrupt-controller@e0000000")
  b.prop("compatible", "riscv,plic0")
  b.prop("interrupts-extended", cells: (0..<harts).flatMap { [UInt32($0 + 1), 0xffff_ffff, UInt32($0 + 1), 9] })
  b.prop("reg", cells: [0, 0xe000_0000, 0, 0x0400_0000])
  b.prop("riscv,max-priority", cells: [7])
  b.prop("riscv,ndev", cells: [159])
  b.end()
  b.begin("uart@d4017000")
  b.prop("compatible", "ns16550")
  b.prop("reg", cells: [0, 0xd401_7000, 0, 0x100])
  b.prop("reg-shift", cells: [2])
  b.prop("reg-io-width", cells: [4])
  b.prop("interrupts", cells: [42])
  b.prop("clock-frequency", cells: [14_000_000])
  b.end()
  b.end()
  b.end()
  return b.blob()
}

/// QEMU virt's shape: isa-extensions, M and S contexts, a path console.
func qemuTree() -> [UInt8] {
  var b = FdtBuilder()
  b.begin("")
  b.prop("#address-cells", cells: [2])
  b.prop("#size-cells", cells: [2])
  b.prop("compatible", "riscv-virtio")
  b.begin("chosen")
  b.prop("stdout-path", "/soc/serial@10000000")
  b.end()
  b.begin("cpus")
  b.prop("#address-cells", cells: [1])
  b.prop("#size-cells", cells: [0])
  b.prop("timebase-frequency", cells: [10_000_000])
  for i in 0..<2 {
    b.begin("cpu@\(i)")
    b.prop("device_type", "cpu")
    b.prop("reg", cells: [UInt32(i)])
    b.prop("riscv,isa", "rv64imafdc_zicsr_zifencei")
    b.prop("riscv,isa-extensions", strings: ["i", "m", "a", "f", "d", "c", "zicbom", "zba", "svpbmt"])
    b.prop("riscv,cbom-block-size", cells: [64])
    b.prop("mmu-type", "riscv,sv57")
    b.begin("interrupt-controller")
    b.prop("compatible", "riscv,cpu-intc")
    b.prop("phandle", cells: [UInt32(10 + i)])
    b.end()
    b.end()
  }
  b.end()
  b.begin("soc")
  b.prop("#address-cells", cells: [2])
  b.prop("#size-cells", cells: [2])
  b.begin("serial@10000000")
  b.prop("compatible", "ns16550a")
  b.prop("reg", cells: [0, 0x1000_0000, 0, 0x100])
  b.prop("interrupts", cells: [10])
  b.end()
  b.begin("plic@c000000")
  b.prop("compatible", strings: ["sifive,plic-1.0.0", "riscv,plic0"])
  b.prop("interrupts-extended", cells: [10, 11, 10, 9, 11, 11, 11, 9])
  b.prop("reg", cells: [0, 0x0c00_0000, 0, 0x0060_0000])
  b.prop("riscv,ndev", cells: [95])
  b.end()
  b.end()
  b.end()
  return b.blob()
}

let x60 = (vendor: UInt64(0x710), architecture: UInt64(0x8000_0000_5800_0001))

func platform(_ blob: [UInt8], vendor: UInt64 = 0, architecture: UInt64 = 0) -> Platform? {
  blob.span.bytes.withUnsafeBytes { raw in
    guard let fdt = Fdt(RawSpan(_unsafeBytes: raw)) else { return nil }
    return Platform(fdt, vendor: vendor, architecture: architecture)
  }
}

func isa(_ p: Platform) -> String { String(decoding: (0..<p.isaCount).map { p.isa[$0] }, as: UTF8.self) }

/// The tables `p` writes at `address`, walked as devmgr walks them.
func tables(_ p: Platform, at address: UInt64 = 0x7000_0000) throws -> (TableSet, [UInt8]) {
  var buffer = [UInt8](repeating: 0xEE, count: p.tablesSize)
  let rsdp = try #require(buffer.withUnsafeMutableBytes { raw in
    var span = MutableRawSpan(_unsafeBytes: raw)
    return p.writeTables(into: &span, at: address)
  })
  let memory = buffer
  let read: (UInt64, Int) -> [UInt8]? = { at, count in
    guard at >= address, Int(at - address) + count <= memory.count else { return nil }
    return Array(memory[Int(at - address)..<(Int(at - address) + count)])
  }
  let r = try RSDP(try #require(read(address + UInt64(rsdp), 36)))
  return (try TableSet(rsdp: r, read: read), buffer)
}

@Test func theRV2sTreeGivesItsHartsContextsAndConsole() throws {
  let p = try #require(platform(rv2Tree(), vendor: x60.vendor, architecture: x60.architecture))
  #expect(p.hartCount == 8 && p.timebase == 24_000_000 && p.mmuType == 0)
  #expect((0..<8).allSatisfy { p.harts[$0].id == UInt64($0) && p.harts[$0].context == UInt32(2 * $0 + 1) })
  let plic = try #require(p.plic)
  #expect(plic.base == 0xe000_0000 && plic.size == 0x0400_0000 && plic.sources == 159 && plic.maxPriority == 7)
  let uart = try #require(p.uart)
  #expect(uart.base == 0xd401_7000 && uart.regShift == 2 && uart.width == 4 && uart.gsi == 42)
  #expect(p.boardId[0] == UInt8(ascii: "k") && p.boardId[4] == UInt8(ascii: "1") && p.boardId[5] == UInt8(ascii: " "))
}

@Test func aBaseOnlyIsaIsTheKnownCoresElseLeftAsItIs() throws {
  let known = try #require(platform(rv2Tree(), vendor: x60.vendor, architecture: x60.architecture))
  #expect(known.isaSource == .knownCore && known.cmoBlockLog2 == 6)
  let s = isa(known)
  #expect(s.hasPrefix("rv64imafdcv_") && s.contains("_zba_") && s.contains("_zicbom_") && s.hasSuffix("_svpbmt"))
  let unknown = try #require(platform(rv2Tree()))
  #expect(unknown.isaSource == .baseOnly && isa(unknown) == "rv64imafdcv" && unknown.cmoBlockLog2 == 0)
}

@Test func isaExtensionsWinOverTheIsaString() throws {
  let p = try #require(platform(qemuTree(), vendor: x60.vendor, architecture: x60.architecture))
  #expect(p.isaSource == .devicetree && isa(p) == "rv64imafdc_zicbom_zba_svpbmt")
  #expect(p.cmoBlockLog2 == 6 && p.mmuType == 2 && p.timebase == 10_000_000)
  #expect(p.harts[0].context == 1 && p.harts[1].context == 3)
  #expect(p.uart?.base == 0x1000_0000 && p.uart?.width == 1 && p.uart?.regShift == 0)
}

@Test func theTablesWalkFromTheirRSDP() throws {
  let p = try #require(platform(rv2Tree(), vendor: x60.vendor, architecture: x60.architecture))
  let (set, _) = try tables(p)
  for s in ["APIC", "RHCT", "SPCR", "FACP", "DSDT"] { #expect(set.table(Signature(bytes: Array(s.utf8))) != nil, "\(s)") }
  let fadt = try #require(set.fadt)
  #expect(fadt.isHardwareReduced && fadt.table.length == 276)
  #expect(set.dsdt?.length == 36 && set.dsdt?.revision == 2)
  #expect(fadt.table.oemID == Array("VECTRA".utf8) && fadt.table.oemTableID == Array("ky,x1   ".utf8))
}

@Test func theMadtHasARintcPerHartAndThePlic() throws {
  let p = try #require(platform(rv2Tree(), vendor: x60.vendor, architecture: x60.architecture))
  let madt = try #require(try tables(p).0.table(Signature(bytes: Array("APIC".utf8)))).bytes
  var at = 44
  var harts: [(id: UInt64, uid: UInt32, context: UInt32)] = []
  var plic: (sources: UInt16, size: UInt32, base: UInt64)?
  while at + 2 <= madt.count {
    let type = madt[at], length = Int(madt[at + 1])
    if type == 0x18 { harts.append((madt.le64(at + 8), madt.le32(at + 16), madt.le32(at + 20))) }
    if type == 0x1B { plic = (madt.le16(at + 12), madt.le32(at + 20), madt.le64(at + 24)) }
    at += length
  }
  #expect(harts.count == 8 && harts.enumerated().allSatisfy { $1.id == UInt64($0) && $1.uid == UInt32($0) && $1.context == UInt32(2 * $0 + 1) })
  #expect(plic?.sources == 159 && plic?.size == 0x0400_0000 && plic?.base == 0xe000_0000)
}

@Test func theRhctHasTheTimebaseIsaCmoMmuAndHartNodes() throws {
  let p = try #require(platform(rv2Tree(), vendor: x60.vendor, architecture: x60.architecture))
  let rhct = try #require(try tables(p).0.table(Signature(bytes: Array("RHCT".utf8)))).bytes
  #expect(rhct.le64(40) == 24_000_000 && rhct.le32(48) == 3 + 8 && rhct.le32(52) == 56)
  var at = 56
  var isaString = "", cmo: UInt8 = 0, mmu: UInt8 = 0xFF, hartInfo = 0
  for _ in 0..<rhct.le32(48) {
    let type = rhct.le16(at), length = Int(rhct.le16(at + 2))
    switch type {
    case 0: isaString = String(decoding: rhct[(at + 8)..<(at + 8 + Int(rhct.le16(at + 6)) - 1)], as: UTF8.self)
    case 1: cmo = rhct[at + 7]
    case 2: mmu = rhct[at + 7]
    case 0xFFFF:
      #expect(rhct.le16(at + 6) == 3 && rhct.le32(at + 8) == UInt32(hartInfo) && rhct.le32(at + 12) == 56)
      hartInfo += 1
    default: Issue.record("node type \(type)")
    }
    at += length
  }
  #expect(isaString == isa(p) && cmo == 6 && mmu == 0 && hartInfo == 8 && at == rhct.count)
}

@Test func theSpcrDescribesThe16550() throws {
  let p = try #require(platform(rv2Tree(), vendor: x60.vendor, architecture: x60.architecture))
  let spcr = try #require(try tables(p).0.table(Signature(bytes: Array("SPCR".utf8)))).bytes
  #expect(spcr[36] == 0x12 && spcr[40] == 0 && spcr[41] == 32 && spcr[43] == 3 && spcr.le64(44) == 0xd401_7000)
  #expect(spcr[52] == 0x10 && spcr.le32(54) == 42 && spcr[58] == 7)
}

@Test func aTreeWithoutHartsOrPlicMakesNoTables() throws {
  var b = FdtBuilder()
  b.begin("")
  b.end()
  #expect(platform(b.blob()) == nil)
  let noPlic = Platform()
  var buffer = [UInt8](repeating: 0, count: 4096)
  let rsdp = buffer.withUnsafeMutableBytes { raw in
    var span = MutableRawSpan(_unsafeBytes: raw)
    return noPlic.writeTables(into: &span, at: 0)
  }
  #expect(rsdp == nil)
}

@Test func aDamagedBlobIsRefused() {
  var blob = rv2Tree()
  blob[0] = 0
  #expect(platform(blob) == nil)
  #expect(platform(Array(rv2Tree()[..<100])) == nil)
}

@Test func harts64AreKeptAndMoreDropped() throws {
  let p = try #require(platform(rv2Tree(harts: 70), vendor: x60.vendor, architecture: x60.architecture))
  #expect(p.hartCount == 64)
  let (set, _) = try tables(p)
  #expect(set.table(Signature(bytes: Array("RHCT".utf8))) != nil)
}

extension Array where Element == UInt8 {
  fileprivate func le16(_ at: Int) -> UInt16 { UInt16(self[at]) | UInt16(self[at + 1]) << 8 }
  fileprivate func le32(_ at: Int) -> UInt32 { UInt32(le16(at)) | UInt32(le16(at + 2)) << 16 }
  fileprivate func le64(_ at: Int) -> UInt64 { UInt64(le32(at)) | UInt64(le32(at + 4)) << 32 }
}

@Test func aLongIsaIsKeptWholeAndOneTooLongRefused() throws {
  func tree(_ extensions: [String]) -> [UInt8] {
    var b = FdtBuilder()
    b.begin("")
    b.begin("cpus")
    b.prop("#address-cells", cells: [1])
    b.prop("#size-cells", cells: [0])
    b.begin("cpu@0")
    b.prop("reg", cells: [0])
    b.prop("riscv,isa-extensions", strings: ["i", "m"] + extensions)
    b.end()
    b.end()
    b.end()
    return b.blob()
  }
  // QEMU's -cpu max: some 800 bytes, svpbmt near the end.
  let long = (0..<100).map { "zx\($0)abcd" } + ["svpbmt"]
  let p = try #require(platform(tree(long)))
  #expect(isa(p).hasSuffix("_svpbmt") && p.isaCount > 800)
  #expect(platform(tree((0..<300).map { "zx\($0)abc" })) == nil)
}
