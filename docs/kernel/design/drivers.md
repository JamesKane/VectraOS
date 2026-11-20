# Driver support: resources, interrupts, MSI, DMA, SMC

Part of croi's design notes (index in CLAUDE.md). IOMMUs are in iommu.md.

## Driver support (K9a)

Driver support, K9a (Kernel/Object/Resource.swift, User/DriverSyscalls.swift,
User/IoPorts.swift, include/resource.h, include/vmo.h; Todhchai M3):
- Resources are Zircon's: kind (MMIO 0, IRQ 1, IOPORT 2 amd64, SMC 4
  arm64, SYSTEM 5), base, size, flags, name. Size 0 is the kind's ranged
  root; the root resource (kind ROOT 3, PA_RESOURCE) is every kind's.
  userboot also gets each kind's ranged root (PA_MMIO_RESOURCE 0x50 ...
  PA_SYSTEM_RESOURCE 0x54) and passes them on. `resource_create` (130,
  parent | options << 32) follows Zircon's checks in order (WRITE on the
  parent; a child inside its parent; EXCLUSIVE only from a ranged root
  and no children of it; overlaps with an exclusive one NOT_FOUND, an
  MMIO resource compared by the 4 KiB pages it touches, not by bytes:
  `Resources.overlapRange`, D167; boot check `rsrc`).
  A ranged root refuses a range whose end (rounded to pages) wraps past
  2^64 (OUT_OF_RANGE, review round 1: the wrapped end passed every
  overlap test, so the MMIO root mapped all of RAM; check 688).
  `Resources.validate` is Zircon's validate_ranged_resource (non-strict:
  an MMIO resource grants the pages it touches); `check(system:)` uses
  it. `RootFilter` is the root filter: RAM (`PhysicalMap`; firmware
  ranges and RESERVED ones such as PCIe ECAM are allowed, as in Zircon),
  device registers the kernel maps (`mapPhysical` with device caching
  records them; the console UART, the amd64 LAPIC/MSI window, the GIC
  ITS), and on amd64 the 8259 and console UART ports.
  ZX_INFO_RESOURCE (18). The tracing base is Zircon's 14.
- VMOs: `vmo_create_physical` (47; MMIO resource; uncached-device by
  default), `vmo_set_cache_policy` (46; MAP right; unmapped only, else
  BAD_STATE; UNCACHED and UNCACHED_DEVICE both map `.device`, so arm64
  gets Device-nGnRE where Zircon uses nGnRnE for UNCACHED),
  `vmo_op_range` (45: COMMIT/PREFETCH round out, DECOMMIT aligned, ZERO
  by bytes, cache CLEAN/CLEAN_INVALIDATE by bytes, CACHE_SYNC syncs the
  I-cache, CACHE_INVALIDATE NOT_SUPPORTED). Device and uncached VMOs are
  read through mappings with their cache policy (V1 cut vmo_read/write,
  which refused them, D37). Zero-size
  anonymous VMOs exist. `Vmo.syncInstructions` (arm64 dc cvau + ic ivau,
  rv64 fence.i plus SBI remote fence.i) runs after ProgramLoader copies
  code; user loaders (userboot, Todhchai's) must do the same through
  `cache_flush` on arm64 hardware (QEMU TCG is coherent).
- The vDSO header is version 2 with `cache_flush` (Zircon's
  zx_cache_flush; runtime `croi_cache_flush`); the topology page
  (version 2) publishes `dcache_line`/`icache_line`. User cache ops are
  opened on every CPU (`arch_user_cache_enable`: arm64 SCTLR_EL1.UCI and
  UCT, rv64 senvcfg.CBCFE with Zicbom).
- amd64 IO ports (131/132): each CPU's TSS carries an 8 KiB I/O bitmap
  (deny all); a process's bitmap lives on its `UserAspaceRecord` with a
  never-reused id, copied in at a switch to a user thread when the
  loaded id differs, and pushed by IPI to every CPU that has it loaded
  or runs the process when it changes (so a release is immediate).
- Boot test: the drivers suite (user/test/swift/DriverSuite.swift, run
  on its own by `ProcessSelfTest.runDrivers`; usertest.c's mode 10
  before D125) reads the first ECAM window's first bus's device 0
  through a physical VMO (`swift.ecam=`), refuses the first RAM page in
  the boot data and the page `RootFilter.firstKernelMmio` names
  (`swift.kernelmmio=`), and reads the boot tests' framebuffer pattern
  when they drew it (`swift.fbpattern=`).

## Firmware data for user space (K9b)

Firmware data for user space, K9b (Kernel/User/BootData.swift,
include/zbi.h; Todhchai item 20):
- Boot data: one ZBI container (Zircon's format; croi has no ZBI
  otherwise) of ACPI_RSDP, SMBIOS, FRAMEBUFFER (zbi_swfb_t; GOP BGRX is
  RGB_X888, RGBX is BGR_888_X) and MEM_CONFIG (RAM the kernel owns,
  PERIPHERAL for MMIO and the framebuffer, RESERVED for the rest)
  items, and DEVICETREE (D154: the flattened tree, copied, when the
  loader made the ACPI tables from one, for devmgr's devicetree bus;
  the kernel never parses it). `BootData.build` writes it into boot allocator pages before the
  PMM takes over (the memory map lives in handoff memory); `makeObject`
  adopts them into a VMO. userboot gets it read only (no WRITE) as
  Zircon's PA_VMO_BOOTDATA (0x1A) and passes it on. zbi.h is the whole
  contract (Todhchai writes its own reader).
- Firmware memory is read through physical VMOs under an MMIO resource
  (always cached, see Physical above); RAM stays refused. The kernel
  unmaps the framebuffer after its self-test, so a driver's physical VMO
  over it (WRITE_COMBINING) is its only mapping.
- Boot test mode 10 continues (startup block word 4 is the boot data):
  the container and every item well formed, the RSDP through a narrow
  MMIO resource (uncached and WC refused), the XSDT's checksum, every
  MEM_CONFIG RAM range refused, the SMBIOS anchor, and the kernel's
  framebuffer pattern read back write-combining. QEMU has SMBIOS and a
  framebuffer on all three machines.

## Interrupt objects (K9c)

Interrupt objects, K9c (Kernel/Object/InterruptObject.swift,
Kernel/Irq/DeviceIrqs.swift, include/interrupt.h, syscalls 140, 142
and 146 in User/DriverSyscalls.swift; Todhchai item 13):
- Zircon's InterruptDispatcher: states IDLE / TRIGGERED / NEEDACK /
  DESTROYED, delivered as a port packet (type 7, payload[0] the
  timestamp; the port needs BIND_TO_INTERRUPT, and its interrupt packets
  are a list of their own read first, owned by the object so firing never
  allocates). A fire while unbound is kept until bound. Level interrupts
  are masked when they fire and unmasked on ack. Rights are Zircon's
  (bind READ + port WRITE, ack WRITE). Timestamps are monotonic (no
  suspend, so boot time is the same).
- V1 cut interrupt_wait, interrupt_destroy and interrupt_trigger with
  virtual interrupts (D29): a bound port is the one way to wait, closing
  the last handle destroys, and a counter is a virtual interrupt. Tests
  fire an object as its device would through test hook 13 (syscall 6,
  `TestHooks.fire`), since a real device can't fire on demand
  everywhere.
- Numbers: amd64 GSI (IOAPIC pins, vector 0x30 + GSI below 0x80; MADT
  overrides for MODE_DEFAULT and REMAP_IRQ; else ISA edge-high, PCI
  level-low), arm64 INTID (GICv3 SPIs; active high only), rv64 GSI (PLIC
  sources, the RINTC's context per hart; active high only).
  EDGE_BOTH is NOT_SUPPORTED. An edge number takes one object
  (ALREADY_BOUND); a level number up to four of the same mode, since
  PCI's INTx lines are shared (on rv64's PLIC, without MSIs, QEMU's
  virtio keyboard and test mouse share one): each gets every fire, and
  holds the line masked from its fire to its ack (`DeviceIrqs.hold`, a
  count a number under `controllerLock`); it opens when none holds it.
  The first object routes it; `interrupt_set_affinity` on any moves it
  for all.
- `interrupt_set_affinity` (146, croi's): routes to the lowest CPU of the
  mask with `interruptsReady` (IOAPIC physical destination, IROUTER, PLIC
  enable bits); INVALID_ARGS when none.
  Until set, the boot CPU. CPUs another job reserved are skipped (K10d).
- `DeviceIrqs`: handler table (heap, four slots a number) under
  `tableLock`, held while a handler runs, so `unregister` means no
  handler is running; lock order table -> object -> controller (and
  object -> scheduler -> port packets). A number with no handler is
  masked when it fires; the last object's `unregister` masks it.
- Differences from Zircon: the object is destroyed with its last
  reference. Ext 5's lent profile and scheduling-context handoff (K14e)
  go with the packet: `Ports.queueInterrupt` wakes a thread from the
  port on them.
- Boot test: the Swift program's interrupts suite
  (user/test/swift/InterruptSuite.swift, run on its own by
  `ProcessSelfTest.runInterrupts`; usertest.c's mode 11 until D29): the
  state machine through test hook 13, then each machine's RTC (amd64
  CMOS periodic, GSI 8, edge; arm64 PL031, INTID 34, level; rv64
  goldfish, GSI 11, level) by port, routed to CPU 1 (the kernel checks
  where it was taken). It reports the median wake (fire timestamp to
  the port_wait's return) as `irq.wait_wake_median`: KVM ~4.5 us. QEMU's
  PLIC pends only on a rising line, so rv64 skips the "acked while still
  asserted fires again" check. The RTC check runs where the kernel knows
  the RTC (`swift.rtc=`): a PC's, or on arm64 and rv64 QEMU's machine
  (its FADT's OEM ID is "BOCHS ").
- Boot test on a machine whose devices only ACPI names: bin/irq-test
  (drivers/bus/acpi/tests/native/irq, `userboot.next=bin/irq-test`, boot-irq on
  arm64 with QEMU virt's second PL011) finds an ARMH0011 whose page the
  root resource grants (the console's is refused), takes its interrupt
  from _CRS, and in loopback checks a packet per byte, one held until
  the ack, and delivery after interrupt_set_affinity to CPU 1. On the
  Orange Pi 6 Plus: uart0, interrupt 328.

## MSI (K9d)

MSI, K9d (Kernel/Object/MsiObject.swift, DeviceIrqs MSI part,
include/interrupt.h; syscalls 147 msi_allocate, 148 msi_create):
- Zircon's model: an allocation object (type 32, rights BASIC) of `count`
  (power of two, up to 32) contiguous vectors aligned to `count` on the
  boot CPU, from the MSI system resource (base 11); ZX_INFO_MSI (28)
  gives target address/data. `msi_create` makes interrupt object `id`:
  MSI-X (option 1) programs the table entry in the VMO (physical,
  uncached) and masks through its vector control; plain MSI checks the
  capability (ID 5) and masks through per-vector mask bits if present;
  the driver programs the capability itself. MSIs are edge interrupts,
  never masked while delivered: one that comes before the ack is kept
  and sent at the ack. Zircon masks them as level interrupts; each mask
  and unmask is a read and a write of the device's table, and under KVM
  each is an exit to QEMU (virtio-blk's interrupt_ack took 57 µs at the
  median, most of a refault's cost there; 2026-10-29). Destroying an
  MSI-X object clears and masks its entry.
- amd64: vectors 0xB0..<0xF0 per CPU (`DeviceIrqs.allocateMsi`), handler
  table by (CPU, vector), message 0xFEE00000 | APIC ID << 12 (IDs above
  255 NOT_SUPPORTED), or with interrupt remapping (K12f) the remappable
  format naming the (CPU, vector) entry, written by `DeviceIrqs.prepareMsi`
  at msi_create and retarget and cleared by `releaseMsi`. set_affinity moves an
  MSI-X vector: a vector on the new CPU, the entry rewritten under its
  mask, the old vector dropped; plain MSI is NOT_SUPPORTED (the driver
  owns the capability). arm64: through the GICv3 ITS (K12h, below); rv64:
  through AIA's IMSICs (K12i, below), else NOT_SUPPORTED (the PLIC).
- The kernel's mappings of MSI-X tables and capabilities are `shared`
  (`mapPhysical(shared:)`): they don't enter the root filter's list of
  kernel MMIO, so the driver keeps its resource over them.
- Boot test (the interrupts suite, amd64; croi's QEMU gets `-device
  edu,addr=0x10`): edu's MSI by port, with the driver programming the
  capability from the info; a virtio device's MSI-X table (MSI-X not
  enabled, so it never fires) read back after create, a move to CPU 1,
  and close. Both are found by scanning bus 0 and skipped when absent,
  and the config registers touched are restored: Todhchai boots this
  kernel on other machine shapes, with its own edu driver (INTx). KVM
  timing note: channel_call in m2 reads 1.4-2.8 us when the host is
  busy; compare builds interleaved, not one after the other.

## MSI frames: a PCIe host's own MSIs (D156)

MSI frames (Kernel/Object/MsiFrame.swift, MsiObject's frame paths,
msi_allocate with count 0, object type 64):
- Why: the SpacemiT K1 has a PLIC and no IMSICs, so msi_allocate is
  NOT_SUPPORTED there, and its DesignWare PCIe hosts latch MSIs in their
  own block (iMSI-RX) and raise one wired PLIC source each (142 and 143
  for the RV2's slots). Fuchsia's DesignWare drivers fire virtual
  interrupts from user space; croi cut those (D29), and the kernel takes
  the block instead.
- msi_allocate(MSI system resource, 0, out, desc, desc_size): kind
  (CROI_MSI_FRAME_DWC), an IRQ resource covering the wired number, a
  physical uncached VMO and offset (PCIE_MSI_ADDR_LO), and the target.
  The kernel maps the registers (shared, as an MSI-X table), writes the
  target, enables and masks all 256 vectors, clears their status, and
  takes the number with `DeviceIrqs.setKernelHandler` (level), as an
  IOMMU's fault interrupt: permanent, so a frame outlives its object.
- The handler (interrupt context): under the frame's lock, each group's
  status read, written back to clear it, and each set bit's object
  fired. A vector that arrives after the clear sets its bit again and
  keeps the line up; the PLIC delivers it after the claim completes.
- msi_allocate(frame, count): count aligned vectors from the frame's
  bitmap (`MsiObject.frame` set, cpu 0). Info: target_addr the frame's
  target, target_data the first vector. msi_create: as for the
  controller's MSIs (MSI-X entry masked, programmed with the target and
  vector, unmasked), but the handler goes in the frame's table, the
  vector is unmasked in the frame, and nothing is mapped at the ITS or
  remapped. set_affinity: NOT_SUPPORTED. detach: masked in the frame,
  its handler cleared (no run firing it once that returns).
- Locks: the frame's lock (allocations, handlers) is taken before an
  object's lock when firing, as DeviceIrqs' table lock is; the frame's
  mask lock is a leaf.
- Test: the interrupts suite checks the call's refusals on every arch,
  and on rv64 makes a frame on source 95 over a function that isn't
  there (bus 254), allocations from it, their message and alignment,
  and a closed allocation's vectors freed. The vectors' delivery runs
  only on the board (nvme(3) behind k1-pcie(3)).

## The GICv3 ITS: MSIs on arm64 (K12h)

The GICv3 ITS: MSIs on arm64, K12h (Kernel/Irq/Its.swift, DeviceIrqs'
arm64 MSI part, MsiObject):
- `Its.initialize` (from `GicV3.initializeBootCpu`; bounded spins, the
  clock isn't up): device and collection tables (64 KiB pages, a flat
  device table of up to 2^16 DeviceIDs), a 4 KiB command queue, one
  LPI configuration table (14 INTID bits: LPIs 8192-16383). Each CPU
  (`enableThisCpu`, from `GicV3.initializeThisCpu`): PROPBASER, its own
  pending table (64 KiB aligned, PTZ), EnableLPIs, MAPC (ICID = CPU,
  RDbase per GITS_TYPER.PTA) + SYNC.
- EventIDs are global (msi_allocate precedes knowing the device): 2048,
  allocations consecutive and aligned, LPI = 8192 + EventID, each
  device's ITT covering all 2048. The message is GITS_TRANSLATER and the
  EventID. msi_create finds the device (plain MSI: `Mcfg.requesterId` of
  the capability; MSI-X: `Pci.msixOwner`, the function whose MSI-X
  capability names that table address, walking buses from each segment 0
  MCFG window's first bus through bridges, a bus mapped when first read;
  a window's base is bus 0's, which the CIX Sky1 doesn't decode, and an
  ECAM read of an undecoded bus never completes, so a bus is never
  reached by an offset from the window's first bus), its DeviceID
  (`Iort.itsDeviceId`: a root complex's mapping to an ITS group, or via
  an SMMUv3's stream id and that SMMU's mappings), then MAPD (once per
  device), the LPI enabled, MAPTI, INV, SYNC; set_affinity is MOVI (the
  message stays); destroy DISCARDs. LPIs dispatch through `DeviceIrqs`'
  table lock (`dispatchMsi`).
- SMMUv3 domains identity-map the doorbell page, so a claimed device's
  MSIs still reach the ITS (Linux's MSI window).
- Mode 11's msi_test runs on arm64 (edu's MSI, an event not mapped for
  edu refused, virtio MSI-X entries, MOVI to CPU 1).
- The tables and commands are cleaned to memory with `VmoCache.line`,
  which is found before interrupt bring-up (`VmoCache.findLine`). It was
  found later, so the ITS's first cleans did nothing: QEMU's ITS is
  coherent and never noticed, the CIX Sky1's GIC-700 (r2p1) read stale
  commands and stalled at a different MAPC each boot
  (IMDEF_INVALID_COMMAND).
- A stalled queue is reported once on the console: GITS_IIDR, TYPER,
  CBASER, CWRITER, CREADR, every BASER as it reads back, the command at
  CREADR, the CPU's GICR_CTLR (read 32 bits wide: the GIC-700 returns 0
  to a 64-bit read), PROPBASER, PENDBASER; and on a GIC-700 (IIDR
  product 4) the RAS error records in its GICT page, 128 KiB below ITS0:
  ITS command errors are records 27 and up, the full syndrome in MISC0
  (the GIC-700 TRM's table 4-22).

## RISC-V AIA: the APLIC and IMSICs (K12i)

RISC-V AIA: the APLIC and IMSICs, K12i (Kernel/Irq/Aia.swift; cpu.S
`arch_rv_imsic_*` through siselect/sireg/stopei by CSR number):
- Used where the MADT has an IMSIC, RINTCs with IMSIC files and an
  S-level APLIC, and every hart has Ssaia; else the PLIC, as before.
  `Aia.initialize` (instead of `Plic.initialize`): hart index = a file's
  place among the files; every source inactive and disabled; domaincfg
  IE + DM (MSI delivery; the root domain's MSI addresses are firmware's).
  Each hart: eidelivery 1, eithreshold 0, every eie bit, SEIE.
- Identities are global: a wired source s is identity s (APLIC target:
  hart index, EIID s; sourcecfg level-high or rising-edge); MSIs take
  consecutive, aligned identities from the first multiple of 64 above
  the sources. scause 9 claims through stopei (`claimAll`): wired to
  `DeviceIrqs.dispatch`, MSIs to `dispatchMsi`. Masking: the APLIC's
  clrienum/setienum (a level source also gets setipnum on unmask: in MSI
  mode it pends again only on a new edge, and the write counts only
  while the line is asserted), MSIs at the device. The MSI message is
  the hart's file and the identity; set_affinity rewrites the address.
- The RISC-V IOMMU now comes up at boot (`RiscvIommus.boot`, devices
  passed through): QEMU resets it Off, which blocked edu's MSIs.
- QEMU: `qemu.sh --aia` (`aia=aplic-imsic`); test `boot-aia` runs the
  whole boot test there.

## DMA (K9e)

DMA, K9e (Kernel/Object/Dma.swift, User/DmaSyscalls.swift, include/dma.h;
syscalls 150-156; Todhchai item 14 without an IOMMU):
- Zircon's iommu_create (stub only: one-byte descriptor; INTEL/ARM_SMMU
  NOT_SUPPORTED), bti_create, bti_pin (bti | options << 32, vmo |
  addrs_count << 32: eight arguments in six registers; per page,
  CONTIGUOUS for a contiguous VMO, COMPRESS = pages for the stub; Zircon's
  rights and option checks), pmt_unpin (consumes the handle),
  bti_release_quarantine, vmo_create_contiguous; ZX_INFO_BTI (20).
  Objects: IOMMU 23, BTI 24, PMT 26 (INSPECT only, so its one handle is
  its only one). Device addresses are physical (no translation).
- Pinning (`Vmo.pin`/`unpin`, `VmoRecord.pins`): commits the range and
  records it; decommit refuses pinned pages (VmError.pinned ->
  BAD_STATE), ZERO zeroes them in place, the cache policy can't change.
- Quarantine: closing a PMT's handle while pinned (process death too)
  moves it to its BTI's list (the BTI holds it; it drops its own
  reference to the BTI); bti_release_quarantine unpins them. A BTI that
  dies with quarantined PMTs leaves them pinned for good and says so in
  the debuglog (Zircon's orphan). PMT state changes under the BTI lock.
- A PMT holds its BTI from bti_pin until the PMT is destroyed (or
  quarantine hands it over: `PmtObject.holdsBti`), not until unpin.
  pmt_unpin closes the PMT's handle after unpinning, and that close
  takes the BTI's lock, so a BTI whose last handle had gone (a driver
  host's PinnedMemory closes its BTI before its regions) was freed by
  the unpin and the close took its freed lock: "spinlock: holder isn't
  a CPU", found with devmgr's edu driver (V2 7c). The `dma` suite
  (user/test/swift/DmaSuite.swift) unpins after the BTI's last handle
  closes.
- The lifetime logic is `lib/dmalife/DmaLife.swift` (D166), generic over
  a `DmaWorld`: pin's last step (the retains and `livePins`), `unpin`,
  `handleClosed`, `releaseQuarantine`, `destroyPmt` and `destroyBti`'s
  quarantine walk and orphan accounting. Dma.swift's `KernelDmaWorld`
  is the real objects (one call to the same operation as before, same
  lock order, no existentials: the file is specialised into the kernel);
  `DmaLifeCheckTests` (lib/dmalife/tests) is the model world, on the
  shared checker (lib/check): a BTI, two PMTs over one page and up to
  three processes, every interleaving of their pins, unpins, handle
  closes, quarantine releases and BTI closes, with and without an IOMMU
  domain, the invariants of D166 section 3 at every step. Its broken variants
  (the 7c bug restored; the quarantine taken without the list's
  reference) must fail. Host only, on Linux (ucontext), about 15 s.
- croi's BTI properties (`bti_set_properties`, 156; CROI_INFO_BTI_
  PROPERTIES 0x10000): address width, window and memory type. Narrowing
  only (ACCESS_DENIED on a widening), the memory type only while nothing
  is pinned or quarantined. Pins outside are OUT_OF_RANGE;
  vmo_create_contiguous allocates inside (`floor`/`limit` through
  ContiguousPool and the PMM) with the memory type as cache policy
  (non-coherent: uncached). devmgr narrows before granting the BTI.
- Creating a no-IOMMU BTI writes a WARNING debuglog record naming the
  BTI id and the creating process's koid (a recorded trust decision).
- Boot test mode 12 (`ProcessSelfTest.runDma`): all of the above,
  including the debuglog record, with windows chosen so the checks don't
  depend on where pages land. Quarantine through process
  death and a BTI dying with PMTs quarantined are covered by
  DmaLifeCheckTests only.

## SMC calls (K13i)

SMC calls, K13i (User/SmcSyscalls.swift, smp.S `arch_smccc_call`, syscall
234; resource.h; Todhchai requirement 13):
- smc_call(resource, croi_smc_parameters_t *, croi_smc_result_t *):
  Zircon's layouts and order (null pointers INVALID_ARGS, the parameters
  read, the resource validated, the call, the result written). arm64:
  w0 the function ID, x1-x6, w7 = secure_os_id << 16 | client_id; result
  x0-x3 and x6. Through the FADT's PSCI conduit (`Power.psci`: SMC, or
  HVC where firmware runs at EL2, as under QEMU; Zircon always uses SMC).
  Elsewhere NOT_SUPPORTED (after the validation).
- SMC resources are function-ID ranges (Zircon's are 6-bit service call
  numbers: an OEN-scoped resource grants every SiP call, the board review's
  reason). The root filter refuses the PSCI calls that change CPU or system
  state (CPU_SUSPEND/OFF/ON, MIGRATE, SYSTEM_OFF/RESET/RESET2/SUSPEND,
  CPU_FREEZE, CPU_DEFAULT_SUSPEND, both conventions): the kernel's, even
  to the root resource (system_powerctl is the way).
- Yielding calls (bit 31 clear) with `croi.smccc_qcom=on` follow
  Qualcomm's resume protocol under one Mutex (Zircon's arm64_smccc_qcom):
  while x0 is INTERRUPTED (1), call again with function ID 1 and the x6
  session id. The Q8B needs it.
- Mode 17's `smc`: PSCI_VERSION through a one-function resource on arm64
  (QEMU's PSCI over HVC), OUT_OF_RANGE outside it, CPU_OFF and SYSTEM_OFF
  refused.

## Supply leases (D169)

Supply leases (Object/Supply.swift, User/SupplySyscalls.swift, syscalls
246-248; supply.h; lib/supplylife/SupplyLife.swift; D169, the backlog's B2).
Zircon has nothing like it; devmgr's graph orders binding, not removal, and
a register read after a provider cut its power is an SError, which panics
the kernel.

- A supply object (type 65) is made from an MMIO resource that covers a
  device's registers (`supply_create`; not a ranged root). Its handle has
  the basic rights and WRITE, which binds and ends. `supply_bind` takes a
  handle of a physical VMO (device memory inside the supply's pages, not RAM,
  not a slice or a parent), an interrupt object or a BTI, each with WRITE; the
  supply holds a reference to it from then on, and the object a count of
  its leases.
- An object is usable only while every supply it is bound to is live.
  `revoked` (the VMO record's, the interrupt's and the BTI's own, under the
  object's lock) is set when one ends and never cleared: a revoked VMO can't
  be mapped (`UserAspace.insert` reads it after listing the mapper), a fault
  on a mapping of it fails (ACCESS_DENIED: a page fault in the holder, which
  its exception channel sees), has no child (`childAdded(unlessLent:)`) and
  can't be pinned; a revoked interrupt drops its fires and refuses its ack;
  a revoked BTI refuses `bti_pin`. A VMO with children can't be bound.
- `supply_end` runs in the caller's thread: the supply goes `ending` (no more
  bindings; another end is BAD_STATE), each bound object is signalled
  SUPPLY_ENDING, then it waits for every holder to let go (no handle but the
  supply's reference, no mapping of the VMO, no live pin through the BTI) or
  for the deadline; then every bound object is revoked, and each cleared:
  `unmapEverywhere` over the whole VMO (aspace -> vmo, interrupts on, nothing
  held across it, so the TLB shootdown waits as it does for decommit), the
  interrupt masked for good (a held pin or its MSI entry), the BTI's domain
  aborted. Then the state is `ended` and SUPPLY_ENDED is signalled; only then
  may the provider cut. A deadline that passes with a holder holding (the
  forced path) is a log line and `Supplies.forcedEnds`.
- Why the caller's thread and not a timer or worker: the wait has no kernel
  waker (a handle's close and an unmap don't know the supplies bound to what
  they drop), so the ender looks again after 20 us, doubling to about 1 ms,
  and a killed thread's wait ends at once (its deadline is now, which still
  finishes the end). A holder that releases at once is found at the first or
  second look; the forced path costs the deadline. A timer or a worker would
  need the same polling or hooks in every handle close and unmap, and
  `supply_end`'s caller wants the answer (SUPPLY_ENDED) before it cuts anyway.
- Aborting a domain (`IoDomains.abort`): the root table page is zeroed and the
  domain's IOTLB invalidated, which every unit does (VT-d, AMD-Vi, SMMUv3,
  SMMUv2 and RISC-V IOMMU all treat a zero entry as no translation), so the
  device's DMA faults in its IOMMU and is logged. The domain stays attached
  (`Iommus.detach` blocks and frees it at the BTI's end); pins made before
  unmap normally. A BTI with no IOMMU (the stub, or a master the kernel
  doesn't translate) has nothing to abort: the end logs it, `pmt_unpin` on
  it quarantines the pages instead of releasing them, and
  `bti_release_quarantine` (devmgr, on the provider's report that the device
  was reset) releases them (D169 §4).
- Locks: supply -> object (the VMO's lock, an interrupt's or a BTI's header
  lock) while binding; the ending holds none across the wait or the clearing,
  which take aspace -> vmo, an interrupt's lock -> the irq table and an IOMMU
  domain's lock -> unit each as the rest of the kernel does (rules.md).
  A supply destroyed live (its last handle closed without `supply_end`) lets
  go of what it bound as it was: the objects go on unleased; a provider that
  dies doesn't take its devices' windows away.
- Limits: a holder is any handle (the provider's own copy of the VMO it
  bound keeps it from being released: it closes it first); a mapping that is
  forced away stays as an address range until its process unmaps it, and a
  stray access to it faults; the ending doesn't wait for a DMA in flight to
  finish, only for the domain's translations to go. Foreign processors can't
  be forced (D169 §4): the provider leaves them on.
- Check: SupplyCheckTests runs SupplyLife (the same file) on lib/check's
  checker with a model world: five machines (a prompt holder, a stubborn
  one with the deadline, a bind racing an end, a window bound to two
  supplies, one ended and one closed live, a supply closed live), the ones
  with a BTI with and without a domain (about 9 s on brimstone, under the
  30 s of D169 §8), and broken variants (the ended signal before the clear, a bind accepted on an
  ending supply) that must fail. The invariants: nothing bound is usable,
  mapped, unmasked or unaborted once the supply is ended; no binding after
  ending began; no object freed twice or touched after it is freed; the
  deadline used only when a holder holds. Boot self-test
  (`SupplySelfTest`, in boot-smoke): a window mapped and bound, ended at a
  deadline (the mapping gone, the fault refused, a new map refused, no
  second end), ended with a holder that lets go (no forced path), a BTI and
  an interrupt revoked; budget `supply.end_to_clear` (limit not yet set,
  D169 §8).
