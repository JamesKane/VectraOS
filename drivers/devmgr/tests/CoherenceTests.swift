// SPDX-License-Identifier: BSD-3-Clause

// A device's DMA coherence and its source, and an own-MMU master's BTI kind
// (D168, driver(6), devmgr(8)).

import DevMgr
import Testing

@Test func coherenceAndOwnMMUParseFromTheRecord() throws {
  let i = try index("""
    driver mali
    match acpi CIXH5000
    own-mmu
    coherence noncoherent ACE-Lite, non-cacheable (a board run) # observed
    driver plain
    match acpi PNP0B00
    """)
  #expect(i.drivers[0].ownMMU && i.drivers[0].coherence == false)
  #expect(i.drivers[0].coherenceSource == "ACE-Lite, non-cacheable (a board run)")
  #expect(!i.drivers[1].ownMMU && i.drivers[1].coherence == nil)
  #expect(throws: IndexError.self) { try index("driver a\nmatch acpi X\ncoherence noncoherent") }
  #expect(throws: IndexError.self) { try index("driver a\nmatch acpi X\ncoherence maybe somewhere") }
  #expect(throws: IndexError.self) { try index("driver a\nmatch acpi X\nown-mmu now") }
}

@Test func aRecordsCoherenceWinsOverCCAAndNoneIsTakenAsCoherent() throws {
  let i = try index("driver g\nmatch acpi CIXH5000\ncoherence noncoherent vendor driver read\ndriver h\nmatch acpi PNP0B00\n")
  let record = DMACoherence.choose(record: i.drivers[0], firmware: true)
  #expect(record == DMACoherence(coherent: false, source: "record: vendor driver read"))
  #expect(record.description == "noncoherent (record: vendor driver read)")
  #expect(DMACoherence.choose(record: i.drivers[1], firmware: false).description == "noncoherent (_CCA)")
  #expect(DMACoherence.choose(record: i.drivers[1], firmware: true).description == "coherent (_CCA)")
  #expect(DMACoherence.choose(record: i.drivers[1], firmware: nil).description == "coherent (none (taken as coherent))")
  #expect(DMACoherence.choose(record: nil, firmware: nil).source == "none (taken as coherent)")
  #expect(DMACoherence.choose(record: nil, firmware: false, firmwareSource: "devicetree").source == "devicetree")
}

@Test func anOwnMMUMasterGetsThePassthroughKindWhateverTheIORTNames() {
  #expect(DMAPath.choose(ownMMU: true, named: true, stub: true) == .ownMMU)
  #expect(DMAPath.choose(ownMMU: true, named: false, stub: true) == .ownMMU)
  #expect(DMAPath.choose(ownMMU: true, named: true, stub: false) == .none)
  #expect(DMAPath.choose(ownMMU: false, named: true, stub: true) == .translated)
  #expect(DMAPath.choose(ownMMU: false, named: false, stub: true) == .passthrough)
  #expect(DMAPath.choose(ownMMU: false, named: false, stub: false) == .none)
  #expect(DMAPath.ownMMU.note == "passthrough: own MMU, no IOMMU confines it")
  #expect(DMAPath.passthrough.note == "passthrough: no IOMMU covers it")
}
