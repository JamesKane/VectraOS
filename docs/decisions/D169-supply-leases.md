# D169. Supply leases: a register window, an interrupt and a BTI can depend on a supply their provider holds, and ending it takes them away from their holder before the provider may cut (2026-11-20, proposed for the backlog's B2)

A device's power-up order is today each driver's convention: mali(3)
turns on its power domain, clocks, power resource and reset in a strict
order, because a register read before all of them raises an SError, and
croi panics on any SError. Nothing orders power-down at all: devmgr's
links (D154, D163) order binding, not removal, so a provider that cut a
supply would leave its consumer's mappings live, and the next read
would take the machine down. The Rust reenvisioning's review (the
roadmap's backlog, B2) found a mechanism that runs on the same SoC: the
window is derived from a lease on what powers it, and ending the lease
takes the window away first.

## Proposal

1. **A supply object** (`supply_create`, from the device's MMIO
   resource), held by the provider that powers the device (scmi(3) for
   a power domain or clock, devmgr for an ACPI power resource, the
   reset controller's driver for a reset). Its handle's rights say who
   may end it.
2. **Bound objects** (`supply_bind(supply, object)`): a physical VMO
   made from the device's MMIO resource, an interrupt object, a BTI.
   Each may be bound to several supplies (a device that needs a domain,
   two clocks and a reset is bound to four); it is usable only while
   all are live. A VMO bound to a supply that has ended can't be
   mapped; a mapping already made is gone.
3. **Ending one** (`supply_end(supply, deadline)`) runs, in order:
   - each bound object is signalled `SUPPLY_ENDING`, which its holder
     waits on with its host's one port, at a point its driver chose;
   - at the holder's release (it unmaps and closes the bound objects)
     or at the deadline: every mapping of each bound VMO is unmapped and
     shot down (interrupts on, never under the scheduler lock), each
     bound interrupt masked, each bound BTI's domain set to abort and
     the abort waited out;
   - the supply is signalled `SUPPLY_ENDED`, and only then may the
     provider cut. A stray access after it is a page fault in the
     holder's process, which its exception channel sees, not an SError.
   The provider has a deadline too: a supply ended but not cut by then
   is reported.
4. **What a deadline can't do:** a master the kernel doesn't translate
   (D168's `own-mmu`, or no IOMMU) can't be aborted, so its quarantined
   pins stay until the provider reports the device reset
   (`bti_release_quarantine` by devmgr on that report); a foreign
   processor (the PM core, a DSP) can't be forced, so its provider
   leaves it on and the supply ends *pinned*.
5. **devmgr** turns the provider graph's other direction on: a
   provider's driver holds the supplies of what it feeds, devmgr binds
   each device's grants to them as it grants them, and it refuses a
   graph with a cycle or a supply with no root. scmi(3), devmgr's `_ON`
   and the reset controller (D167) become providers of supplies, not
   steps a driver calls; mali(3)'s bring-up order goes away.
6. **Drivers:** DriverHost's `Registers` becomes a borrow of the grant
   (`~Escapable`), so a view can't outlive a release; a driver handles
   `SUPPLY_ENDING` by quiescing and releasing; firmware's state is read
   first, since a device may be inherited running.
7. **Kernel cost and rules:** three calls (91 to 94; the syscall audit
   updated), lock orders supply -> aspace -> vmo, supply -> IRQ table,
   supply -> IOMMU unit; a section in `drivers.md`; an entry in
   `zircon-divergences.md` (Zircon has no such object).
8. **Checked as it ships:** the supply's state machine is generic over a
   world, as D166's lifetimes are, and lib/check explores it within
   30 s; a budget `supply.end_to_clear` (end to `SUPPLY_ENDED` with
   holders that release at once), its limit set from a first
   measurement; on the board, a driver that reads on after its supply
   ends faults and the board runs on.

**Exit:** mali(3)'s power-up has no order of its own, and the G720 is
powered off and on under a running desktop without a power cycle.

## Not covered

Core idle and hardware clock gating (too fast for a lease: a table of
which idle states each timer allows), and a cut firmware makes by
itself (a thermal trip), which stays an SError.

## Not chosen

- **Leases on handles alone** (closing the device's handles as the
  end). A mapping outlives its handle, and an interrupt or a DMA in
  flight isn't a handle.
- **Ordering in devmgr only** (devmgr stops the driver before it lets
  the provider cut). It needs every driver to stop when asked, and a
  driver that doesn't takes the machine down; the kernel's unmap
  doesn't need its cooperation.
