# ADR-0018: GPU drivers: one native `accel` protocol, Mesa ported to it, hardware whose firmware does the work only

Status: proposed, 2026-10-02; amended the same day for Qualcomm's Adreno, when the Radxa Dragon Q8B became a T1 board (00 §5). This is the GPU kernel-driver ADR that 03 §3 and M7 call for. Each vendor's driver gets an ADR of its own under it.

## Context

03 §3 makes the GPU drivers user-space `drv-gpu-*` processes. They serve Mesa's Vulkan drivers over rings, and `displayd` does modesetting. The kernel half is the largest piece of work in the system. amdgpu alone is hundreds of kLOC. Most of that is not what a Vulkan driver needs to reach the hardware: it is support for every generation since GFX6 and their register headers, kernel-side ring scheduling, DC (the display code), SMU power tables for every chip, KFD for ROCm, SR-IOV and RAS. Rule 13 rules out the route the BSDs took, which is Linux's DRM over a Linux kernel API shim (LinuxKPI).

Other systems show that the shim is not the only route:

- **Fuchsia's Magma** defines one IPC protocol between a user-space system driver (MSD) and a Mesa-derived client driver (ICD). The MSD initialises the hardware, sets up address spaces and contexts, maps buffers, schedules command buffers, and handles faults and power. Vendors add queries and command structures only where they need them. The MSDs (Intel, Arm Mali) were written for Fuchsia. No Linux code sits under them.
- **Haiku** runs NVK on NVIDIA's open kernel modules (NVRM), ported because NVRM is built to be OS-independent, unlike nouveau. It works only on Turing and later, because it relies on the GSP firmware. Haiku's earlier RadeonGfx ran RADV on a user-space server for GFX6 and GFX8. It ran one command buffer at a time.
- **Linux's Nova** splits nova-core from nova-drm. nova-core boots the GSP and runs its command queue, and makes the GSP firmware the authority for the hardware.
- **Asahi** designed its kernel interface backwards from Vulkan: VM_BIND, explicit sync only, no legacy buffer-object calls. It prototyped the driver from a host over m1n1 before writing the kernel part.
- **AbyssBSD**, our FreeBSD fork for the Radxa Dragon Q8B (SC8280XP, Adreno 690), runs Turnip on Linux's msm driver over LinuxKPI, the route rule 13 rules out. Its notes are still the ground truth for the hardware: the GMU and its firmware, the zap shader, the GPU's own MMU-500 with a page table per process, and the hypervisor's rules for programming it (`docs/boards/radxa-dragon-q8b/` there). Its display driver, `msmfb`, is native: it takes over the pipeline UEFI leaves running and adds flips, hotplug, link training and modes. msm's `adreno/` is 21.5k lines for every generation, and the a6xx core about 8k of that.
- **Managarm** reimplements the Linux DRM interface on native drivers, so far for modesetting only.

Hardware has moved scheduling into firmware: NVIDIA's GSP, AMD's MES, Intel's GuC, Mali's CSF and Apple's AGX firmware. On that hardware the kernel half shrinks to loading firmware, managing GPU address spaces, creating queues through the firmware, and handling faults, reset and power. AMD is also adding user-mode queues, where the client rings a doorbell and the kernel is not on the submission path (still being hardened in Linux in 2026).

Mesa already has a seam for the kernel interface in each driver: RADV's winsys, NVK's `nouveau_ws`, ANV's KMD backend (for i915 and xe), panvk's `pan_kmod`. Virtio native contexts already put a different transport under RADV, Asahi and freedreno.

## Decision

1. **One native protocol, the `accel` class (01 §7.3), served by every `drv-gpu-*`.** It is designed from the Vulkan profile (03 §3) backwards, not from DRM:
   - `info`: device identity (the UUID Vulkan reports), memory heaps, `uma` and `coherent` (03 §3), and a vendor block of parameters;
   - GPU address spaces: create, destroy, and VM_BIND-style map and unmap of `vx-buffer`s (01 §6.1), batched;
   - buffers: allocate in a heap, import and export as `vx-buffer`s. Memory is charged to the client's budget (01 §5);
   - queues: create and destroy, with an opaque vendor descriptor;
   - submit: a command stream with wait and signal points on `Counter`s, and nothing else. **Sync is explicit only**: timeline `Counter`s are the only sync objects, and there is no implicit sync on buffers;
   - events: faults, with the faulting address and queue, and resets. They arrive as `VK_ERROR_DEVICE_LOST` in the client (01 §7.4).
   There is no DRM ioctl emulation and no GEM. Vendor-specific behaviour lives only in the vendor blocks and the queue descriptor, as in Magma. The protocol is versioned and specified once, in [`docs/proto/accel.md`](../proto/accel.md), before the first hardware driver.
2. **Mesa is ported to `accel`, not wrapped.** Each Mesa driver that we ship gets one new backend at its existing seam: a winsys or KMD backend that speaks `accel`. It lives in the Mesa import as a patch, counted in the ledger, and is offered upstream as Fuchsia offered Magma. Mesa never sees a Linux interface.
3. **Hardware whose firmware does the work, one generation band per vendor.** A driver supports the generations where firmware or microcode does power management and command processing, so that submitting work is only writing packets to a ring the hardware consumes, and nothing older, ever. Firmware that also schedules the queues (GSP, MES, GuC, CSF) is better still:
   - Qualcomm: Adreno a6xx and later (the GMU for power, the SQE microcode for the command processor; the driver writes the ring);
   - Apple: AGX (G13 and later);
   - NVIDIA: Turing and later (GSP);
   - Arm: Mali with CSF (panthor's range);
   - AMD: RDNA3 and later (GFX11+, MES);
   - Intel: Xe2 and later (GuC), if Intel is taken on at all.
   Each vendor ADR states its band, its line-count estimate, and the firmware it loads.
4. **User-mode queues where the hardware has them.** The driver creates the queue through the firmware, then gives the client the ring memory and its doorbell page directly: the doorbell as a one-page `Vmo` lease of the BAR (01 §3), revoked on reset or driver restart. Submission then never goes through the driver. The driver handles setup, faults, reset and power. Where the client cannot ring the firmware itself, `submit` goes to the driver, which hands it to the firmware queue. Whether a lease can be narrowed to a page range is settled in the first vendor ADR that needs it. Adreno has none: its ring carries privileged packets, so its driver submits.
5. **The drivers are first-party.** Vendor and Linux code is documentation. NVRM (MIT) and Nova are the references for a GSP client, Asahi's driver for AGX, and amdgpu for MES. None of it is vendored. Importing NVRM as Haiku did would bring NVIDIA's OS-interface layer, a portability layer that rule 13 rules out. It is not a fallback.
6. **Firmware is treated as hardware.** Blobs are loaded unmodified, pinned by BLAKE2b hash in the vendor ADR, and served read-only from the release tree. They are listed in the ledger by size, not counted as code. A blob whose licence forbids redistribution is not shipped.
7. **Display is separate from rendering.** The `drv-gpu-*` render driver and the vendor's `displayd` back end share only `vx-buffer`s and `Counter`s. They may be one process for a vendor, but they speak two protocols. Each vendor's first display back end is **flip only**: it keeps the mode the firmware set at boot, as `simplefb` does, and changes only the scanout address on vblank. That gives accelerated rendering on one output with no hotplug, mode changes, VRR or HDR. Full display support (atomic planes, link training, multiple outputs) is a later ADR for each vendor. AMD's DC equivalent is expected to be the largest of them.
8. **Order:** `simplefb` → virtio-gpu 2D → Venus in QEMU → Adreno a6xx (the Q8B, T1) → Apple AGX → NVIDIA (GSP) → Mali (CSF) → AMD (MES). AMD stays last mostly because of display. With MES and user-mode queues, its render side is no longer the largest. Intel is decided when Xe2 hardware is a target.
9. **A driver that chooses its GPU's page tables is `trusted`.** Where the GPU's own MMU is the only IOMMU in front of it and the driver selects the page table (Adreno switches it with `CP_SMMU_TABLE_UPDATE`, a packet in the driver's ring), the driver can point the GPU at any memory. It is marked `trusted` in `devmgr`'s policy, like a driver for a device without an IOMMU (01 §7.4), and `/dev/accel/gpuN/info` says so. Clients are still isolated from each other, by the page table per session. A GPU behind a system IOMMU (discrete GPUs, AGX behind DART) needs no such mark.
10. **Drivers are developed against the hardware from user space.** A `drv-gpu-*` is an ordinary process, so `dbg`, crash directories (05) and driver hot restart (01 §7.4) apply during bring-up. A vendor ADR may add a host-side harness that pokes the hardware over a debug link, as Asahi did with m1n1.

## Consequences

- The Q8B's GPU driver is trusted with DMA, as item 9 says. That is the price of Adreno's design, shown, not hidden.
- The kernel interface for GPUs is one protocol, not one per vendor. A new vendor is a driver and a Mesa backend, not a new interface.
- Each vendor is a bounded piece of work, sized in its ADR, and the work grows only by adding generations forward. Users with older GPUs (pre-Turing NVIDIA, pre-RDNA3 AMD, Mali before CSF) get `simplefb` and the CPU compositor.
- The Mesa backends are patches we carry until upstream takes them. Each Mesa upgrade rebases them, and the ledger shows their size.
- GPU-direct work is cheap: a user-mode queue is a ring and a `Counter` in the client, the same shape as the rest of the system (01 §4).
- A flip-only display means the first accelerated desktop on real hardware has one output at the boot mode. That is stated in each vendor's `/dev/accel/gpuN/info`, not hidden.
- The same pattern is the default for other large subsystems (Wi-Fi, audio DSPs, NPUs): find the firmware boundary, define a native protocol shaped by its user, port the user-space library at its own seam, read Linux and vendor code without linking it, and support generations forward from a cut line. A subsystem that cannot follow it needs its own ADR saying why.

## References

- Fuchsia: [Magma design](https://fuchsia.dev/fuchsia-src/development/graphics/magma/concepts/design), [RFC-0198](https://fuchsia.dev/fuchsia-src/contribute/governance/rfcs/0198_magma_api_design), [porting guide](https://fuchsia.dev/fuchsia-src/development/graphics/magma/concepts/porting)
- Haiku: [NVRM and NVK](https://www.phoronix.com/news/NVIDIA-Haiku-OS-NVRM), [NVIDIA-Haiku 0.0.1](https://www.phoronix.com/news/NVIDIA-Haiku-0.0.1), [RadeonGfx](https://github.com/jwalds/RadeonGfx)
- Linux: [Nova](https://rust-for-linux.com/nova-gpu-driver), [Nova in 7.2](https://www.phoronix.com/news/Linux-7.2-DRM-Rust), [amdgpu user queues](https://ratatoskr.run/amd-gfx/2026/08/17474202/t), [virtio-gpu native contexts](https://patchew.org/QEMU/20250126201121.470990-1-dmitry.osipenko@collabora.com/)
- AbyssBSD: `docs/boards/radxa-dragon-q8b/gpu-display.md` and `lessons.md`, `kmod/drm-msm/README.md`
- Managarm: [end-of-2022 update](https://managarm.org/2022/12/31/end-of-year-update.html)
