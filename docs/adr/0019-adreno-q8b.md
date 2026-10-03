# ADR-0019: Adreno a6xx on the Radxa Dragon Q8B: `drv-gpu-adreno`, its display back end, and the SC8280XP platform pieces

Status: proposed, 2026-10-02. The vendor ADR for Qualcomm under ADR-0018 (item 3, the Adreno a6xx band). The Q8B is a T1 board (00 §5), brought up in M9, after the GPU stack of M8 (04 §6).

## Context

The Q8B's SoC is the Qualcomm SC8280XP. Its GPU is an **Adreno 690**: chip ID `0x06090000`, msm's `ADRENO_6XX_GEN4` family, 4 MiB of GMEM, a 16 GiB address space for each process, and 8 operating points from 270 to 690 MHz. It is unified memory: the GPU reaches RAM through its own MMU-500 (the GPU SMMU, `0x3DA0000`), and no system IOMMU sits behind that. Three firmware images run it:
- the **SQE** microcode, which is the command processor's (CP's) front end;
- the **GMU** firmware, which runs power: GX collapse, and frequency votes through RPMh;
- a **zap shader** that the secure world authenticates. It takes the GPU out of secure mode.

**AbyssBSD**, our FreeBSD fork, already runs this GPU, and its notes are the ground truth for the hardware (`docs/boards/radxa-dragon-q8b/gpu-display.md`, `lessons.md`, `power-thermal-idle.md`, `kmod/drm-msm/README.md`). It runs Linux 6.13's msm driver over LinuxKPI, which rule 13 rules out for us. Its own work is BSD-licensed:
- the clock, secure-call, command-DB and SMMU libraries (about 2.3k lines);
- `msmfb`, a native display driver that takes over the pipeline UEFI leaves running.

What it established:

- **Turnip works on this GPU at Linux's speed or better.** vkmark at 1080p scores 5446, against 4716 on Linux 7.0 on the same board. It has an address space per process, fault isolation, and hang recovery in about 2.4 s.
- **The hypervisor polices the SMMUs.** A stage-2 CBAR write, or a stream match other than Linux's exact pairs, resets the SoC with no crash dump (01 §7.1).
- **ACPI is not enough.** The DSDT's `GPU0` (`QCOM0636`) has the MMIO and IRQs, but clocks and power go through PEP, which only Windows has. The GPU is fully off at boot: CX and GX collapsed, PLLs off.
- **msm's code is small where it matters for us.** For this one chip, the a6xx core and the parts of msm it uses come to about 8k lines: `a6xx_gpu`, `a6xx_gmu`, `a6xx_hfi`, `adreno_gpu` and the catalog entry. The ring, submit, GPU and IOMMU code adds about 2.5k more.

## Decision

### 1. Scope

The Adreno 690 on the SC8280XP only. The driver is written for the a6xx gen4 family with a GMU, so siblings such as the a660 are a catalog entry each, and nothing else. Excluded:
- a6xx parts without a full GMU (a610, a619's "GMU wrapper");
- everything older than a6xx.

The a7xx (Snapdragon X, T2) is a later amendment to this ADR.

### 2. The pieces

| Piece | Where | Does | Estimate |
|---|---|---|---|
| `drv-gpu-adreno` | `drivers/` | Serves `accel` (§3). Boots the GMU and speaks its HFI messages. Loads the SQE. Asks for the zap shader's authentication. Owns the ring, submission, fences, faults, hang recovery, and frequency scaling (§5) | 7–10k lines |
| `disp-msm` | a `displayd` back end | §6 | ported from `msmfb`; measured when ported |
| `drv-qcom-gcc` | `drivers/` | Serves the `clock` class (01 §7.2): the global clock controller and the GPU's clock controller, their GDSCs, RCGs and branch clocks, in `qcom_gpucc`'s order | about 0.6k |
| SCM operations | `svcd`'s platform service (01 §7.1) | Authenticates the zap shader through PAS, at first load and with "resume" after a restart. Sets the GPU SMMU's aperture. Reads the RPMh command DB from the AOP message RAM, for `gfx.lvl` | about 0.9k |
| MMU-500 | the kernel | Adopts the firmware's setup, then drives stage-1 context banks (01 §7.1, §3 below) | about 1k, inside the kernel's budget (01 §1) |
| `/boot/soc/sc8280xp.ndb` | boot image | Facts ACPI leaves out (§7) | a page |
| `tu_knl_accel.cc` | the Mesa import | Turnip's backend for `accel` (`docs/proto/accel.md` §1) | comparable to `tu_knl_drm_msm.cc` |

Register headers are generated once, when the import is vendored (04 §3, rule 3). They come from the MIT-licensed register XML that Mesa and msm share (`a6xx.xml`, `a6xx_gmu.xml`, `adreno_pm4.xml`, `adreno_common.xml`), and only the a6xx headers are committed. No GPL code is copied. Linux's msm and AbyssBSD's port are read, not linked (ADR-0018 item 5).

### 3. Address spaces and isolation

- **The kernel owns the page tables.** Each `accel` vm is a `DmaDomain` the kernel builds as an LPAE stage-1 table. It is not attached to a context bank: the CP switches to it. `drv-gpu-adreno` gets each table's TTBR value and maps buffers at the addresses `VM_BIND` names. So page tables are written in one place, the kernel's MMU-500 code, and a driver bug cannot corrupt them. A dead driver's mappings are revoked like any other (01 §7.4). 01 §7.1 gives this as placed and switched domains: `VX_DMA_SWITCHED` from the device's own domain, `dma_map` with `VX_DMA_AT`, and `dma_unmap` by range.
- **Context bank 0 is split, as msm's is.** TTBR1 holds the driver's own upper half: the ring, its fence memory and GMU buffers, mapped privileged (`HW_APRIV`). TTBR0 is switched for each session by `CP_SMMU_TABLE_UPDATE` in the driver's ring.
- **The GMU's stream** (`5, 0xc00`) gets its own domain. Its entries carry `PRIV`, because the GMU fetches instructions as a privileged master.
- **Sessions are isolated by the CP's protection.** User command buffers run as unprivileged IB1s. The protected-register list (msm's `a690_protect`, 48 ranges) and the CP's refusal of privileged packets outside the ring keep a session from switching tables or touching the GPU's control registers. A test proves it as AbyssBSD's `msmfault` does: one session's write to another's buffer takes a translation fault, and the other buffer is untouched.
- **The driver is `trusted`** (ADR-0018 item 9). The TTBR it writes into the ring is a physical address the GPU will use, so a hostile driver could point the GPU anywhere. `/dev/accel/gpu0/info` says `trusted=yes reason=device-mmu`.
- **Faults** come in on the context bank's IRQ. The handler records FSR, FSYNR0/1 and FAR, clears the fault, and terminates the access, with no stall. The driver reports a `FAULT` event (`accel` §4.5) to the session whose table was live.

### 4. The `accel` vendor parts (`docs/proto/accel.md` §7)

- **`INFO`:** flags `UMA`. There is one heap, `RAM | DEVICE_LOCAL | HOST_VISIBLE | HOST_COHERENT | HOST_CACHED`. A buffer chooses write-combining or cached and coherent (the chip has `HAS_CACHED_COHERENT`) by its VMO's cache policy. There is one family, `GRAPHICS` (3D and compute share the one CP), with as many queues as the client wants: the driver multiplexes them. The va range is msm's per-process range, from 4 GiB for 16 GiB. The **vendor block** is the facts Turnip reads from msm's `GET_PARAM` today, each 8 bytes:
  - `chip_id`;
  - `gmem_size`, `gmem_base`;
  - `max_freq`;
  - `highest_bank_bit`, `ubwc_swizzle`, `macrotile_mode`;
  - `nr_priorities`.
- **Queue descriptor:** empty in version 1. Priority is the queue record's own field.
- **Submit payload:** an array of `{ iova[8] dwords[4] type[4] }`, where type is `CMD 1` or `CTX_RESTORE 3`. There are no relocations and no buffer list: buffers are resident through `VM_BIND`, as with msm's VM_BIND interface. The driver writes, in its ring:
  1. `CP_SMMU_TABLE_UPDATE`, if the session changed;
  2. one `CP_INDIRECT_BUFFER` per entry;
  3. a `CP_EVENT_WRITE` of the submit's sequence number to its fence memory.
  The interrupt that follows signals the submit's `Counter`s.
- **Fault detail:** `fsr[4] fsynr0[4] fsynr1[4] cb[4]`, and for a hang, the CP's ring read pointer and the IB it was in.

### 5. Power and frequency

- **Bring-up is AbyssBSD's order:**
  1. CX power through `drv-qcom-gcc`;
  2. boot the GMU;
  3. collapse and restore GX through the GMU;
  4. load the SQE;
  5. authenticate the zap shader.
- **CX stays on while the driver runs**, as in AbyssBSD. A real CX collapse loses the GPU SMMU's state, which the kernel would have to restore. That waits for suspend work.
- **Runtime suspend with an autosuspend delay.** Without one, the GPU suspended every frame and the frame rate collapsed.
- **Frequency scaling is in the driver**, with msm's policy:
  - a 50 ms poll of the GMU's busy counter;
  - the top operating point above 50% busy, hold down to 40%, otherwise scale down in proportion;
  - a boost after idle.
  A change is one GMU HFI perf vote, which moves the clock and `gfx.lvl` together. `/dev/accel/gpu0/ctl` takes `freq pin`, `freq auto`, and `freq max HZ`, the cap the thermal policy sets (ADR-0021), and `status` shows the frequency and load.

### 6. Display: `disp-msm`

A `displayd` back end ported from `msmfb`. That is our own BSD-2 code, so it is ported, not reread. It takes over the pipeline UEFI leaves running:

SSPP VIG2 → LM2 → CTL2 → INTF6 → DP2 → Chrontel CH7218A → HDMI

The port comes in two stages, as ADR-0018 item 7 says:

- **Flip only first.** A flip writes `SSPP_SRC0_ADDR` and `YSTRIDE0` and sets `CTL_FLUSH` bit 2. It takes effect at vsync, and INTF6's vsync interrupt drives the vblank `Counter`. When `winsrv` exits, UEFI's framebuffer is shown again.
- **Then the rest of `msmfb`:**
  - AUX transfers and EDID;
  - HPD and IRQ_HPD;
  - link training with Linux's swing and pre-emphasis tables;
  - modes, in msm's disable-then-enable order (push idle before stopping the INTF);
  - DPMS.

  `msmfb`'s timing calculation (`msm_freebsd_dp_calc.c`) is Linux's GPL code. It is rewritten first-party from the DP specification and UEFI's values, which it must reproduce exactly for 1080p (M/N 11/200).

Scan-out has two constraints:
- **Buffers are physically contiguous, below 4 GiB, write-combining.** The display's SMMU streams are in bypass and SSPP addresses are 32 bits. They come from a 64 MiB pool that `disp-msm` reserves at boot from the `contiguous` zone (01 §5). AbyssBSD found that after a long build there was no contiguous low memory left at run time.
- **`disp-msm` is `trusted`** (01 §7.4), because its device reads physical memory with no IOMMU in between.

Not in scope until a need arrives: PHY and link-rate changes, other DP outputs (USB-C alt mode), cursor and overlay planes, DSC.

### 7. The SoC record

`/boot/soc/sc8280xp.ndb` is chosen by `\_SB.SOID` 449 (01 §7.2). It holds:

- **Register windows ACPI doesn't name**, and its quirks. ACPI resource 6 (GPU CC `0x3D90000`) lies inside resource 3 (GMU `0x3D60000`), so the GPU CC is reached as resource 3 plus an offset.
- **SMMU stream pairs, exactly:**
  - GPU: `0, 0xc00` and `1, 0xc00`;
  - GMU: `5, 0xc00`, privileged.

  No packing, and no other pairs.
- **The operating points:** 8 levels, 270–690 MHz, each with its `gfx.lvl` level from the command DB.
- **Firmware paths** (§8), and the clock sequences' register offsets for `drv-qcom-gcc`.

### 8. Firmware

From linux-firmware, under `LICENSE.qcom`, which allows redistribution. Loaded unmodified from `/lib/firmware/qcom/` in the release tree (ADR-0018 item 6):

| File | Bytes | BLAKE2b-512 |
|---|---|---|
| `qcom/a660_sqe.fw` | 43292 | `765264d0cbabbb52fcf50c0f29bb0177496dd6016084a2bb2aa0883fa83325f2da0e1e4bcdfa5ad1d43c21bef0e9a6ff977028d7215b73e7f3b5e3ca3fead3c9` |
| `qcom/a660_gmu.bin` | 55252 | `10ed12f84b993269ea553b364e3bb48302b9fd62441f4e809635e63690626dfd4074e52ab7bc2e64e41af849311c0e8a48e0f00882d2e0421fb3930a48ac6f2c` |
| `qcom/sc8280xp/LENOVO/21BX/qcdxkmsuc8280.mbn` | 14392 | `bfb59746c20f06ce4359519e9a7f23b42c85de2f426cb48a30de47a99bc2beeea427c04122f303ccd3226d272d35dc55c7c8d30fd97eae7ad0007e5890e6a95a` |

The zap shader is the one linux-firmware ships for the Lenovo ThinkPad X13s. It is signed for the SC8280XP and authenticates on the Q8B, as AbyssBSD found. msm's catalog names `a690_zap.mdt`, which linux-firmware does not have.

### 9. Bring-up order and checks

Each step has a check that runs on the board before the next one starts:

1. **Platform.** The SoC record, `drv-qcom-gcc`, the SCM operations, and the MMU-500 adopted with no write to a firmware-owned bank. Check: CX up, and the SMMU state read back unchanged.
2. **GPU alive.** GMU boot, SQE, zap. Check: a submission of `CP_NOP`s completes and signals its `Counter` (AbyssBSD's `msmtest`).
3. **Isolation.** Switched tables. Check: the cross-session write faults, and the other buffer is unchanged (`msmfault`).
4. **Recovery.** Check: a submission that never ends is detected, the GPU is recovered, the guilty session gets `RESET`, and other sessions' queued work runs.
5. **Turnip.** `tu_knl_accel.cc`. Check: `vkcube`, then vkmark at 1080p within 5% of AbyssBSD's 5446.
6. **Display.** `disp-msm` flip only, then hotplug and modes. Check: `winsrv` on Vulkan at 1080p60, and every EDID mode of the test monitor.
7. **Power.** Scaling and runtime suspend. Check: 270 MHz for a vsync-bound client, 690 MHz under saturation, and a suspended GPU when idle.

Hazards are taken from AbyssBSD's `lessons.md` as rules, not rediscovered:
- Only ever write CBAR with type 1.
- A wrong GMU stream mask resets the SoC the moment the GMU leaves reset.
- A teardown must stop every asynchronous source (timers, the hang check, interrupts) before it stops the device. With the driver in user space, that means stopping the CP before the process exits, and the kernel revoking its mappings if it does not.
- Stream the logs off the board during tests, because a reset leaves no dump.

## Consequences

- The Q8B's GPU needs no Linux code: about 10k first-party lines for the driver and its platform pieces, plus generated register headers. That is against msm's 130k lines, ported over LinuxKPI.
- The kernel grows MMU-500 support, with switched domains and `dma_map` at a chosen address. Those reach every GPU whose MMU is its only one.
- Two drivers on this board are `trusted`, `drv-gpu-adreno` and `disp-msm`, and both say so. Sessions are still isolated from each other by the CP's protection, which is tested at step 3.
- The board's facts live in one record, `sc8280xp.ndb`. A second SC8280XP board (the X13s) is a record, not a driver change.
- AbyssBSD stays the place to find out how the hardware behaves. Its notes are cited, not copied. A discovery made here about the hardware goes back to its notes.

## Open questions

1. **Several rings and preemption.** Linux 6.13 enables preemption for a7xx only. Version 1 has one ring, and priorities only order the driver's queue. Does a REALTIME `winsrv` queue need preemption on a6xx?
2. **CX collapse** for suspend, which needs the kernel to save and restore the GPU SMMU.
3. **The CH7218A bridge** is not controllable from our side. A second output needs USB-C DisplayPort alt mode, which is pmic_glink work on the ADSP.
4. **Sharing a scan-out buffer** between `drv-gpu-adreno` and `disp-msm`. With unified memory and a RAM buffer it is a VMO (`accel` §4.2). The constraint is that it must come from `disp-msm`'s pool, below 4 GiB, so `winsrv` allocates scan-out images from `disp-msm` and imports them into its `accel` session.
