# D168. A device's coherence has a source, an own-MMU master is untranslated whatever the tables say, and each board's trusted base is listed (2026-11-20, the owner scheduled the backlog's B3)

devmgr takes a device's DMA coherence from its `_CCA`, coherent where
there is none (`Devices.swift`). On the Sky1 the GPU's `_CCA` says 1 and
the GPU isn't (CIX's kernel runs it on ACE-Lite with non-cacheable
mappings because the display doesn't snoop), and the NPU ran ten times
slower under FreeBSD on the wrong memory type. The Mali-G720 and the
Mali-V translate through page tables their own driver writes, so no
SMMU confines them whatever the IORT says: their driver is trusted with
all of memory, and nothing says so.

## The decision

1. **Coherence has a source.** A driver's record (driver(6)) may say
   `coherence coherent|noncoherent SOURCE...`, the value observed and
   where (a document, a board run, a vendor's driver read as
   documentation), and a board rule (D126) may say it for a device on
   one board. Either wins over `_CCA`. devmgr's `status` gives each
   DMA-capable device its coherence and source: `_CCA`, `none (taken
   as coherent)`, or the record's or rule's words. A device bound on
   `none` says so.
2. **An own-MMU master is untranslated.** A record's `own-mmu` line
   says the device translates through tables its driver writes. devmgr
   gives it the passthrough BTI kind whatever the IORT names, and the
   kernel's warning that its DMA reaches physical memory is logged for
   it as for a device behind no IOMMU. mali(3)'s record says it; the
   video codec's and the NPU's will.
3. **Each board's trusted base is listed.** `vx hardware TRUST BOARD`
   (or a section of `vx hardware`'s report) names every driver whose
   DMA the kernel doesn't translate (no IOMMU, or `own-mmu`) and every
   SMC range a board rule grants whose calls take addresses, from the
   records, the board rules and `docs/hardware/support.tsv`. The
   Sky1's is the first.
4. **Quarantine stays as it is** until B2 gives a provider a way to
   report a device reset: a translated device's quarantined pins are
   released when its BTI goes (its domain detached first), an
   untranslated one's stay pinned for good, as now.

## Not chosen

- **Coherence in a table of its own.** The driver's record and the board
  rule are already where a device's facts live (one mechanism).
- **Refusing to bind an own-MMU master.** The GPU is the desktop's; the
  rule is to say what it is trusted with, not to do without it.
