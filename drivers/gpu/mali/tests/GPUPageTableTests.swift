// SPDX-License-Identifier: BSD-3-Clause

// The Mali MMU's page tables (panthor 04 §4.6, §4.7, 05 §5.3): built by
// FormattedPageTableBuilder over memory the test owns, then read back.

import PageTables
import Testing

/// Table pages on the host: page-aligned and zeroed, their physical address
/// their address, freed with the arena.
final class Arena {
  var pages: [UnsafeMutableRawPointer] = []
  var limit = Int.max

  deinit { for page in pages { page.deallocate() } }
}

struct HostPages: PageTableMemory {
  let arena = Arena()

  mutating func allocateTable() -> UInt64? {
    guard arena.pages.count < arena.limit else { return nil }
    let page = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 4096)
    page.initializeMemory(as: UInt8.self, repeating: 0, count: 4096)
    arena.pages.append(page)
    return UInt64(UInt(bitPattern: page))
  }

  func tableAddress(_ phys: UInt64) -> UInt {
    UInt(phys)
  }
}

typealias GPUTables = FormattedPageTableBuilder<HostPages, GPUPageTable>
typealias GPUTables39 = FormattedPageTableBuilder<HostPages, GPUPageTable39>

/// Walks `root` for `virt`: the entry that maps it and its level, or nil.
func lookup<F: PageTableLayout>(_ format: F.Type, root: UInt64, _ virt: UInt64) -> (entry: UInt64, level: Int)? {
  var table = root
  for level in 0..<F.levels {
    let entry = UnsafePointer<UInt64>(bitPattern: UInt(table))![F.index(virt, level: level)]
    guard F.isPresent(entry) else { return nil }
    if !F.isTable(entry, level: level) { return (entry, level) }
    table = F.address(entry)
  }
  return nil
}

let MiB: UInt64 = 1 << 20
let GiB: UInt64 = 1 << 30

// Bits, against the table of 04 §4.6.2

@Test func aPageIsTheSpecsBits() throws {
  var tables = try GPUTables(memory: HostPages())
  let phys: UInt64 = 0x1_2345_6000
  try tables.map(virt: 0x1000, phys: phys, size: 0x1000, MapAttributes(writable: true, executable: true, cache: .cached))
  let (e, level) = try #require(lookup(GPUPageTable.self, root: tables.rootLow, 0x1000))
  #expect(level == 3)
  // [1:0] 0b11, AttrIndx 1, AP[1], SH 3, AF, nG, the address, and nothing else.
  #expect(e == phys | 0b11 | 1 << 2 | 1 << 6 | 3 << 8 | 1 << 10 | 1 << 11)
}

@Test func readOnlyNoExecuteAndUncached() throws {
  var tables = try GPUTables(memory: HostPages())
  try tables.map(virt: 0x1000, phys: 0x8000, size: 0x1000, MapAttributes(writable: false, executable: true, cache: .cached))
  try tables.map(virt: 0x2000, phys: 0x9000, size: 0x1000, MapAttributes(writable: true, executable: false, cache: .cached))
  try tables.map(virt: 0x3000, phys: 0xA000, size: 0x1000, MapAttributes(writable: true, executable: true, cache: .uncached))
  let ro = try #require(lookup(GPUPageTable.self, root: tables.rootLow, 0x1000)).entry
  let nx = try #require(lookup(GPUPageTable.self, root: tables.rootLow, 0x2000)).entry
  let uc = try #require(lookup(GPUPageTable.self, root: tables.rootLow, 0x3000)).entry
  #expect(ro == 0x8000 | 0b11 | 1 << 2 | 1 << 6 | 1 << 7 | 3 << 8 | 1 << 10 | 1 << 11)
  #expect(nx == 0x9000 | 0b11 | 1 << 2 | 1 << 6 | 3 << 8 | 1 << 10 | 1 << 11 | 1 << 53 | 1 << 54)
  // AttrIndx 0, SH 2 (outer shareable).
  #expect(uc == 0xA000 | 0b11 | 1 << 6 | 2 << 8 | 1 << 10 | 1 << 11)
}

@Test func writeCombiningAndDeviceAreTheUncachedAttributes() throws {
  var tables = try GPUTables(memory: HostPages())
  try tables.map(virt: 0x1000, phys: 0x8000, size: 0x1000, MapAttributes(writable: true, cache: .writeCombining))
  try tables.map(virt: 0x2000, phys: 0x8000, size: 0x1000, MapAttributes(writable: true, cache: .device))
  try tables.map(virt: 0x3000, phys: 0x8000, size: 0x1000, MapAttributes(writable: true, cache: .uncached))
  let a = try #require(lookup(GPUPageTable.self, root: tables.rootLow, 0x1000)).entry
  let b = try #require(lookup(GPUPageTable.self, root: tables.rootLow, 0x2000)).entry
  let c = try #require(lookup(GPUPageTable.self, root: tables.rootLow, 0x3000)).entry
  #expect(a == c && b == c)
  #expect(c >> 2 & 7 == 0 && c >> 8 & 3 == 2)
}

@Test func tableDescriptorsHoldOnlyTheAddress() throws {
  var tables = try GPUTables(memory: HostPages())
  try tables.map(virt: 0x1000, phys: 0x8000, size: 0x1000, MapAttributes(writable: true))
  var table = tables.rootLow
  for level in 0..<3 {
    let e = UnsafePointer<UInt64>(bitPattern: UInt(table))![GPUPageTable.index(0x1000, level: level)]
    let next = GPUPageTable.address(e)
    #expect(e == next | 0b11)
    table = next
  }
}

@Test func theGPUHasOneRoot() throws {
  let tables = try GPUTables(memory: HostPages())
  #expect(tables.rootHigh == tables.rootLow)
  #expect(tables.memory.arena.pages.count == 1)
}

@Test func attributesReadBack() throws {
  var tables = try GPUTables(memory: HostPages())
  try tables.map(virt: 0x1000, phys: 0x8000, size: 0x1000, MapAttributes(writable: false, executable: true, cache: .cached))
  try tables.map(virt: 0x2000, phys: 0x9000, size: 0x1000, MapAttributes(writable: true, executable: false, cache: .writeCombining))
  let a = try #require(lookup(GPUPageTable.self, root: tables.rootLow, 0x1000))
  let b = try #require(lookup(GPUPageTable.self, root: tables.rootLow, 0x2000))
  let ra = GPUPageTable.attributes(a.entry, level: a.level)
  #expect(!ra.writable && ra.executable && ra.cache == .cached)
  let rb = GPUPageTable.attributes(b.entry, level: b.level)
  #expect(rb.writable && !rb.executable && rb.cache == .uncached)
  #expect(GPUPageTable.leafAddress(a.entry, level: a.level) == 0x8000)
}

// Leaf sizes, 04 §4.6.5

@Test func twoMiBBlocksWhereBothAddressesAreAligned() throws {
  var tables = try GPUTables(memory: HostPages())
  try tables.map(virt: 4 * MiB, phys: 0x4000_0000, size: 2 * MiB, MapAttributes(writable: true, executable: true, cache: .cached))
  let (e, level) = try #require(lookup(GPUPageTable.self, root: tables.rootLow, 4 * MiB + 0x1234))
  #expect(level == 2)
  // A block's [1:0] is 0b01.
  #expect(e == 0x4000_0000 | 0b01 | 1 << 2 | 1 << 6 | 3 << 8 | 1 << 10 | 1 << 11)
  #expect(GPUPageTable.leafAddress(e, level: 2) == 0x4000_0000)
  // Root, level 1 and level 2: no level 3 table.
  #expect(tables.memory.arena.pages.count == 3)
}

@Test func aMisalignedPhysicalAddressKeepsPages() throws {
  var tables = try GPUTables(memory: HostPages())
  try tables.map(virt: 4 * MiB, phys: 0x4000_1000, size: 2 * MiB, MapAttributes(writable: true))
  let (_, level) = try #require(lookup(GPUPageTable.self, root: tables.rootLow, 4 * MiB))
  #expect(level == 3)
}

@Test func aRangeStepsFromPagesToBlocksAndBack() throws {
  var tables = try GPUTables(memory: HostPages())
  let start = 2 * MiB - 0x2000
  try tables.map(virt: start, phys: 0x4000_0000 - 0x2000, size: 4 * MiB + 0x4000, MapAttributes(writable: true))
  let levels = [start, 2 * MiB, 4 * MiB - 0x1000, 4 * MiB, 6 * MiB - 0x1000, 6 * MiB, 6 * MiB + 0x1000].map {
    lookup(GPUPageTable.self, root: tables.rootLow, $0)?.level
  }
  #expect(levels == [3, 2, 2, 2, 2, 3, 3])  // 2 to 4 MiB and 4 to 6 MiB are blocks
  #expect(lookup(GPUPageTable.self, root: tables.rootLow, start - 0x1000) == nil)
  #expect(lookup(GPUPageTable.self, root: tables.rootLow, 6 * MiB + 0x2000) == nil)
}

@Test func noOneGiBBlocksEver() throws {
  var tables = try GPUTables(memory: HostPages())
  try tables.map(virt: GiB, phys: 4 * GiB, size: GiB, MapAttributes(writable: true))
  let (_, level) = try #require(lookup(GPUPageTable.self, root: tables.rootLow, GiB + 0x40_0000))
  #expect(level == 2)
  #expect(!GPUPageTable.leafAllowed(level: 1) && GPUPageTable.leafAllowed(level: 2) && GPUPageTable.leafAllowed(level: 3))
}

@Test func mappingErrors() throws {
  var tables = try GPUTables(memory: HostPages())
  let rw = MapAttributes(writable: true)
  #expect(throws: MapError.self) { try tables.map(virt: 0x1800, phys: 0x8000, size: 0x1000, rw) }
  #expect(throws: MapError.self) { try tables.map(virt: 0x1000, phys: 0x8000, size: 0x800, rw) }
  try tables.map(virt: 0x1000, phys: 0x8000, size: 0x2000, rw)
  #expect(throws: MapError.self) { try tables.map(virt: 0x2000, phys: 0x9000, size: 0x1000, rw) }
  // A page inside a range a block would cover: the block can't go over it.
  #expect(throws: MapError.self) { try tables.map(virt: 0, phys: 0x4000_0000, size: 2 * MiB, rw) }
  tables.memory.arena.limit = tables.memory.arena.pages.count
  #expect(throws: MapError.self) { try tables.map(virt: 1 << 40, phys: 0x8000, size: 0x1000, rw) }
}

// Unmapping

@Test func unmapPagesAndBlocks() throws {
  var tables = try GPUTables(memory: HostPages())
  let rw = MapAttributes(writable: true)
  try tables.map(virt: 0x1000, phys: 0x8000, size: 0x3000, rw)
  try tables.map(virt: 4 * MiB, phys: 0x4000_0000, size: 2 * MiB, rw)
  try tables.unmap(virt: 0x2000, size: 0x1000)
  #expect(lookup(GPUPageTable.self, root: tables.rootLow, 0x1000) != nil)
  #expect(lookup(GPUPageTable.self, root: tables.rootLow, 0x2000) == nil)
  #expect(lookup(GPUPageTable.self, root: tables.rootLow, 0x3000) != nil)
  try tables.unmap(virt: 4 * MiB, size: 2 * MiB)
  #expect(lookup(GPUPageTable.self, root: tables.rootLow, 4 * MiB) == nil)
  // The same range maps again, and a hole in an unmap is skipped.
  try tables.map(virt: 4 * MiB, phys: 0x5000_0000, size: 2 * MiB, rw)
  try tables.unmap(virt: 0, size: 8 * MiB)
  #expect(lookup(GPUPageTable.self, root: tables.rootLow, 0x1000) == nil)
  #expect(lookup(GPUPageTable.self, root: tables.rootLow, 5 * MiB) == nil)
  #expect(throws: MapError.self) { try tables.unmap(virt: 0x1100, size: 0x1000) }
}

@Test func unmappingPartOfABlockSplitsIt() throws {
  var tables = try GPUTables(memory: HostPages())
  let attributes = MapAttributes(writable: false, executable: false, cache: .cached)
  try tables.map(virt: 2 * MiB, phys: 0x4000_0000, size: 2 * MiB, attributes)
  // Out of the middle: 0x10 pages from 0x20 pages in.
  try tables.unmap(virt: 2 * MiB + 0x2_0000, size: 0x1_0000)
  var present = 0
  for page in 0..<512 {
    let va = 2 * MiB + UInt64(page) * 0x1000
    guard let (e, level) = lookup(GPUPageTable.self, root: tables.rootLow, va) else {
      #expect(page >= 0x20 && page < 0x30)
      continue
    }
    present += 1
    #expect(level == 3)
    #expect(GPUPageTable.leafAddress(e, level: 3) == 0x4000_0000 + UInt64(page) * 0x1000)
    // The pieces keep the block's attributes.
    let a = GPUPageTable.attributes(e, level: 3)
    #expect(!a.writable && !a.executable && a.cache == .cached)
    #expect(e == GPUPageTable.leaf(0x4000_0000 + UInt64(page) * 0x1000, level: 3, attributes))
  }
  #expect(present == 512 - 16)
}

@Test func unmappingAcrossBlocksSplitsBothEnds() throws {
  var tables = try GPUTables(memory: HostPages())
  let rw = MapAttributes(writable: true)
  try tables.map(virt: 0, phys: 0x4000_0000, size: 6 * MiB, rw)
  try tables.unmap(virt: 2 * MiB - 0x1000, size: 2 * MiB + 0x2000)
  #expect(lookup(GPUPageTable.self, root: tables.rootLow, 2 * MiB - 0x2000)?.level == 3)
  #expect(lookup(GPUPageTable.self, root: tables.rootLow, 2 * MiB - 0x1000) == nil)
  #expect(lookup(GPUPageTable.self, root: tables.rootLow, 3 * MiB) == nil)
  #expect(lookup(GPUPageTable.self, root: tables.rootLow, 4 * MiB) == nil)
  #expect(lookup(GPUPageTable.self, root: tables.rootLow, 4 * MiB + 0x1000)?.level == 3)
  #expect(lookup(GPUPageTable.self, root: tables.rootLow, 6 * MiB - 0x1000)?.level == 3)
  #expect(lookup(GPUPageTable.self, root: tables.rootLow, 0)?.level == 3)
}

// Depth

@Test func fortyEightBitsTakeFourLevels() throws {
  var tables = try GPUTables(memory: HostPages())
  let top: UInt64 = (1 << 48) - 0x1000
  try tables.map(virt: top, phys: 0x8000, size: 0x1000, MapAttributes(writable: true))
  let (e, level) = try #require(lookup(GPUPageTable.self, root: tables.rootLow, top))
  #expect(level == 3 && GPUPageTable.address(e) == 0x8000)
  #expect(tables.memory.arena.pages.count == 4)
}

@Test func thirtyTwoBitsTakeThreeLevels() throws {
  var tables = try GPUTables39(memory: HostPages())
  let top: UInt64 = (1 << 32) - 0x1000
  try tables.map(virt: top, phys: 0x8000, size: 0x1000, MapAttributes(writable: true))
  try tables.map(virt: 0x0400_0000, phys: 0x4000_0000, size: 2 * MiB, MapAttributes(writable: true))
  #expect(lookup(GPUPageTable39.self, root: tables.rootLow, top)?.level == 2)
  #expect(lookup(GPUPageTable39.self, root: tables.rootLow, 0x0400_0000)?.level == 1)
  #expect(tables.memory.arena.pages.count == 4)
  // Its descriptors are the same bits.
  let a = try #require(lookup(GPUPageTable39.self, root: tables.rootLow, top)).entry
  var wide = try GPUTables(memory: HostPages())
  try wide.map(virt: top, phys: 0x8000, size: 0x1000, MapAttributes(writable: true))
  #expect(a == lookup(GPUPageTable.self, root: wide.rootLow, top)?.entry)
  try tables.unmap(virt: top, size: 0x1000)
  #expect(lookup(GPUPageTable39.self, root: tables.rootLow, top) == nil)
  #expect(GPUPageTable39.leafAllowed(level: 0) == false && GPUPageTable39.leafAllowed(level: 1))
}

@Test func levelsFollowTheVABits() {
  #expect(GPUAddressSpace.levels(vaBits: 48) == 4)
  #expect(GPUAddressSpace.levels(vaBits: 40) == 4)
  #expect(GPUAddressSpace.levels(vaBits: 39) == 3)
  #expect(GPUAddressSpace.levels(vaBits: 32) == 3)
  #expect(GPUAddressSpace.levels(vaBits: 30) == 2)
}

// The CPU's builder, which these share the code of

@Test func theCPUsBuilderIsStillTheCPUsFormat() throws {
  var tables = try PageTableBuilder(memory: HostPages())
  try tables.map(virt: 0x1000, phys: 0x8000, size: 0x1000, MapAttributes(writable: true))
  let (e, level) = try #require(lookup(PageTableFormat.self, root: tables.rootLow, 0x1000))
  #expect(level == PageTableFormat.levels - 1)
  #expect(PageTableFormat.address(e) == 0x8000)
  try tables.unmap(virt: 0x1000, size: 0x1000)
  #expect(lookup(PageTableFormat.self, root: tables.rootLow, 0x1000) == nil)
}

// AS_MEMATTR and AS_TRANSCFG

@Test func memAttrIsTheSpecsValues() {
  #expect(GPUAddressSpace.memAttr(coherent: false) == 0x4C4C_4C4C_8C4C_8F4C)
  #expect(GPUAddressSpace.memAttr(coherent: true) == 0x4C4C_4C4C_9C4C_9F4C)
}

@Test func memAttrEntriesFollowTheMAIRBytes() {
  // 04 §4.7.2: anything not write-back at both levels is 0x4C.
  for mair: UInt8 in [0x00, 0x04, 0x44, 0x4F, 0xF0, 0xFB, 0x0F, 0x84] {
    #expect(GPUAddressSpace.memAttrEntry(mair: mair, coherent: false) == 0x4C)
    #expect(GPUAddressSpace.memAttrEntry(mair: mair, coherent: true) == 0x4C)
  }
  // Write-back: memory type 2, explicit allocation, hints from the inner nibble, shareability 0 or 1.
  #expect(GPUAddressSpace.memAttrEntry(mair: 0xFF, coherent: false) == 0x8F)
  #expect(GPUAddressSpace.memAttrEntry(mair: 0xFF, coherent: true) == 0x9F)
  #expect(GPUAddressSpace.memAttrEntry(mair: 0xF5, coherent: false) == 0x8D)  // write-allocate only
  #expect(GPUAddressSpace.memAttrEntry(mair: 0xF6, coherent: false) == 0x8E)  // read-allocate only
  #expect(GPUAddressSpace.memAttrEntry(mair: 0xF4, coherent: false) == 0x8C)
  #expect(GPUAddressSpace.memAttrEntry(mair: 0xF4, coherent: true) == 0x9C)
}

@Test func theAttributeIndicesMeanWhatTheTablesSay() {
  let m = GPUAddressSpace.memAttr(coherent: false)
  func entry(_ index: UInt64) -> UInt64 { m >> (8 * index) & 0xFF }
  #expect(entry(GPUDescriptor.attrIndex(.cached)) == 0x8F)
  #expect(entry(GPUDescriptor.attrIndex(.uncached)) == 0x4C)
  #expect(entry(GPUDescriptor.attrIndex(.writeCombining)) == 0x4C)
}

@Test func transCfgIsTheSpecsValues() {
  #expect(GPUAddressSpace.transCfg(vaBits: 48, coherent: false) == 0x0000_0000_4200_01C6)
  #expect(GPUAddressSpace.transCfg(vaBits: 48, coherent: true) == 0x0000_0000_6200_01C6)
  // INA_BITS = 55 - VA bits, in [10:6].
  #expect(GPUAddressSpace.transCfg(vaBits: 32, coherent: false) >> 6 & 0x1F == 23)
  #expect(GPUAddressSpace.transCfg(vaBits: 40, coherent: false) >> 6 & 0x1F == 15)
  #expect(GPUAddressSpace.transCfgUnmapped == 1)
}
