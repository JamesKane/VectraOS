# D156. PCIe hosts behind drivers: a host driver gives devmgr its bus, and the kernel takes a DesignWare MSI block as an MSI frame (2026-11-01, decided by the owner; extends D154, D74 and K9d)

D154 made a vendor's PCIe host (DesignWare, PLDA) a devmgr driver,
since the kernel reads no devicetree and an MCFG covers only a plain
ECAM host. It didn't say how the functions behind such a host reach
devmgr, nor how their interrupts reach their drivers. The Orange Pi
RV2's two M.2 slots, behind the SpacemiT K1's DesignWare hosts, need
both for NVMe (the owner, 2026-11-01: "Let's get the NVMe lit up").

Two facts shape the answer:
- **Configuration space isn't ECAM.** A DesignWare host sends config
  requests through an iATU region retargeted at one bus, device and
  function at a time; its root port's own space is its DBI.
- **Its MSIs aren't the interrupt controller's.** The K1 has a PLIC and
  no IMSICs, so msi(2) is NOT_SUPPORTED there. The host's integrated MSI
  receiver latches the vector a device writes to one address in 256
  status bits and raises one wired PLIC source per host. Nothing else
  on the K1's PCIe interrupts: its tree gives the hosts no INTx.

## The decision

1. **The host driver brings its bus up and gives devmgr what it found.**
   It powers the slot, trains the link, numbers the bus, places each
   BAR in its memory window, and fixes an iATU region on each function
   it gives, so the function's 4 KiB of configuration space is a page
   at a fixed physical address. It serves that as `pci` in its tree
   (DriverHost's `HostedBus`): its segment, memory windows, DMA reach,
   MSI block and each function's page. devmgr reads it once, after it
   binds the first pass of devices, and binds each function as it binds
   ECAM's: the same match records, the same grants (a resource over the
   function's page instead of its place in ECAM), DMA narrowed to what
   the host reaches. nvme(3) binds unchanged.
2. **The kernel takes the MSI block as an MSI frame.** No new call:
   `msi_allocate(MSI system resource, 0, out, desc, desc_size)`, a count
   of 0 with a descriptor in its two spare arguments, built as
   `iommu_create`'s is, so the syscall ceiling holds at 91 (D079: a call
   added is paid for by a cut; the owner, 2026-11-01). The
   descriptor: a kind (DesignWare's), the wired interrupt with an IRQ
   resource covering it, and a physical uncached VMO over the block's
   registers, with the target address. The kernel programs the
   target, enables and masks every vector, and owns the wired number
   from then on, as it owns an IOMMU's fault interrupt; its handler
   clears each pending status bit and fires that vector's interrupt
   object. `msi_allocate` given the frame instead of the MSI resource
   allocates its vectors; info, `msi_create`, MSI-X programming and
   masking are as they are for the controller's own MSIs, with the
   frame's target and the vector's number as the message.
   `interrupt_set_affinity` on a frame's vector is NOT_SUPPORTED: they
   go where the wired interrupt goes. A frame lasts until the kernel
   restarts, since the wired number can't be given back.
3. **devmgr makes the frame**, from the host's `pci`, under its MMIO,
   IRQ and MSI roots, and grants each function's driver an allocation
   from it, as it grants an allocation of the controller's MSIs now.

## Not chosen

- **A call of its own, `msi_frame_create`.** Clearer, but the ceiling
  (91) would rise, and no call was found to cut for it.

- **Sharing the wired line as INTx.** The function's MSI is pointed at
  the block, and its driver takes the PLIC source as a shared level
  interrupt beside the host driver, which clears the status. No kernel
  change, but the two drivers' order isn't fixed: a completion that
  comes between the function's scan of its queue and the host's clear
  is lost until the next poll (nvme's 50 ms).
- **Virtual interrupts, Fuchsia's way** (its DesignWare drivers fire
  them from the host driver): V1 cut them (D29), and each interrupt
  would cross two processes.
- **ECAM through the iATU's shift mode.** Some DesignWare cores can
  make the config window ECAM-shaped, but not every version, and the
  K1's is 8 KiB: two functions. A page per function is enough for a
  slot.
- **The host driver as the functions' driver host.** One mechanism per
  job: devmgr is where devices are matched and granted.

## Follow-ups

- A switch behind a root port, more than one function, and a link that
  comes up later are the host driver's BUGS until a board needs them.
- The syscall audit's msi_allocate row notes the frame, msi(2) its
  section, the drivers design note its section, and the divergences
  list the frame.
