# D173. mali(3) runs command streams: the GPU's control, its own MMU, the CSF firmware booted and a scheduler of groups, served as a native capset of the GPU class (2026-11-20, proposed; §9 decided by the owner; built and run on the Orange Pi 6 Plus 2026-11-20; V6f item 6; extends D121, D164, D168, D170)

mali(3) probes the Sky1's Immortalis-G720 and reads its CSF firmware
(D164), and does nothing more. V6f's item 6 asks for command streams
running under that firmware, its MMU and a job scheduler, then UIGPU's
buffers and Vulkan. chinese-wall's panthor spec (`specs/panthor`, 00 to 11)
covers everything a kernel driver does: GPU control, the MMU, the firmware
image and MCU boot, the CSF interface, group scheduling, tiler heaps, buffer
objects and Linux's ioctls. It does **not** cover the user side: the shader
ISA, the descriptors, the tiler's formats, or the CS instructions beyond the
dozen a kernel driver writes. So this decision covers the first half of item
6, which the spec fully covers. The second half is an open question for the
owner (§9).

## The decision

1. **mali(3) is the whole kernel-side driver, in its own host.** That means
   GPU control, the GPU's MMU, firmware loading, the CSF interface and the
   scheduler, each a part of `drivers/gpu/mali/lib` that the host tests can
   reach:
   - `Control`: soft reset, the L2, interrupts, cache flushes.
   - `GPUPageTable`: the MMU's tables.
   - `FirmwareImage`: the image's parser.
   - `CSF`: the shared interface and its request/acknowledge protocol.
   - `Scheduler`: groups, queues and the ring writer.

   `Main.swift` wires these to the registers and the interrupts.

   No kernel change is expected. The driver has what it needs today:
   - three IRQ resources;
   - write-combining pinned memory through its BTI (`PinnedMemory(coherent:
     false)`);
   - its windows as bound VMOs (D170).

   The GPU is an own-MMU master (D168): its driver writes page tables over
   physical memory and is in the board's trusted base. That is already
   listed in `docs/hardware/trust.tsv`.
2. **The Sky1's order** (panthor 11.11), after devmgr's power-up (D170):
   1. Q-channel gating, as now.
   2. GPU_ID, with the RCSU's harvest mask applied to SHADER_PRESENT
      (11.6), so every later mask is the reduced one.
   3. Soft reset and RESET_COMPLETED (03 §3.3).
   4. `COHERENCY_PROTOCOL` set to ACE-Lite, plus bit 5 where
      COHERENCY_FEATURES has it.
   5. The PBHA and SYSC_ALLOC values (11.8.2), then the L2 powered on (bit
      0 of L2_PRESENT only).

   The counters' registers at `0x3068` and on (11.8.2) are left out until
   performance counters are wanted.
3. **Memory is non-cacheable everywhere** (11.7). The CPU side:
   - Every GPU buffer, page table and firmware section is write-combining
     pinned memory.
   - The CPU does no cache maintenance, since nothing it maps is cached.
   - The GPU tables' attribute index for "cached" is never used on the
     Sky1.

   The `AS_MEMATTR` value and the MAIR indices are the non-coherent
   column of panthor 05 §5.3.3, chosen by the record's `coherence` line, so
   a coherent board later only changes the record.
4. **The GPU's page tables are a format of `lib/pagetables`,** not a second
   page-table builder (principle 1). `GPUPageTable` is a `PageTableFormat`:
   - VMSAv8-64 stage 1 with a 4 KiB granule (04 §4.6);
   - AP[1] always set, AF and nG always set;
   - SH and AttrIndx from the mapping's cache policy;
   - 4 KiB pages and 2 MiB blocks only;
   - its levels from MMU_FEATURES' VA bits.

   `PageTableBuilder` writes the tables into pages from the driver's pinned
   memory. LOCK, UNLOCK and FLUSH_PT follow every change (04 §4.4).

   Address spaces:
   - AS 0 is the MCU's VM, which covers 4 GiB.
   - The other bits of AS_PRESENT are given to groups' VMs, with least
     recently used eviction (04 §4.2).
   - A fault is decoded and ends the group whose VM faulted (§6).
5. **The firmware boots from the image devmgr mounts** (D164):
   - **Parsing:** the parser checks the header and every entry in panthor
     05 §5.2's order and rejects the whole image on any failure. Protected
     sections are skipped and logged.
   - **Loading:** each section is loaded at its fixed MCU address with its
     flags' permissions. The initial bytes are kept for a reload after a
     reset.
   - **Booting:** AS 0 is programmed, then `MCU_CONTROL` is set to AUTO. The
     driver waits for the global interface's interrupt.
   - **Interface:** the driver reads `GLB_VERSION`, and every layout
     difference from 1.0 to 4.1 (06 §6.2.3) is keyed on it, never on the
     GPU's architecture. CSG and CS slots are discovered and bounds-checked
     against the shared section (05 §5.4.5).
   - **Configuration:** the boot-time values are written (05 §5.6.3): the
     power-off and idle timers and the ping.
   - **Status:** `status` names the firmware's git revision, its interface
     version and the slot counts.
6. **The scheduler** is panthor 07's model, with its own choices marked:
   - **Groups and queues:** a group is 1 to N queues over one VM. Queue i
     sits in CS slot i of the group's CSG slot.
   - **The ring:** the kernel writes it, with 07 §7.4.4's sequence: flush,
     CALL the user's stream, then SYNC_ADD64 of the queue's sync object,
     padded to 64 bytes. Userspace never writes the ring.
   - **Completion:** completion is read on CSG `SYNC_UPDATE`. It raises the
     client's counters, the GPU class's syncs (D25: counters only add), as
     virtio-gpu does for Venus.
   - **Residency:** groups take CSG slots, each with a distinct firmware
     priority (at most 16 resident, 07 §7.1). Groups beyond that are
     suspended and resumed on a tick (07 §7.6), so no client is refused for
     want of a slot.
   - **Faults:** a CS fault, a fatal error or an MMU fault ends its group.
     A job past its timeout ends its group too; the timeout is 5 s, policy
     to revisit. The client's context reports `lost`, and every other
     group keeps running.
   - **Reset:** a ping the firmware misses, or a fault the firmware can't
     confine, resets the whole GPU (07 §7.11). The firmware is reloaded
     from the kept sections. Groups that were suspended cleanly survive;
     the rest are lost.
   - **Tiler heaps** (08) wait for rendering (§9).
7. **The GPU class gains a native capset, `csf`** (D121's Device):
   - `Device.open(capset:)` returns a channel that speaks a new protocol,
     `todhchai.gpu.csf.Context`, beside Venus's `Context`. It is one class,
     a protocol per capset. The context's methods:
     - `info`: GPU_ID, the reduced masks, `GLB_VERSION`, the slot counts.
     - `createVM` and `destroyVM`.
     - `createBuffer(size, flags)`: a write-combining VMO the driver pins
       and the client maps, the shape of D56's unified-memory heap.
     - `bind` and `unbind`: a buffer's range at a VA in a VM.
     - `createGroup(vm, queues, priority)` and `destroyGroup`.
     - `submit(group, jobs, waits, signals)`: each job is a queue, a stream
       VA and a size; the waits and signals are the class's syncs.
     - `groupState`.
   - The objects and their limits are panthor's (10). Linux's ioctl
     encoding is not kept: VectraOS has no DRM to be compatible with. The
     object model is, so a user-side driver written later maps onto it one
     to one.
8. **The checks:**
   - **Host tests** (`drivers/gpu/mali/tests`):
     - The image parser, against the cached real image where
       `.cache/firmware` has it (as the ACPI corpus is judged only where
       present) and against crafted bad images, one for each rule.
     - The GPU format through `PageTableBuilder`'s tests.
     - The ring writer's words against 07 §7.4.5's literal encodings.
     - The CSF protocol against a model firmware: a Swift stand-in over the
       same shared memory that acknowledges, raises events and moves
       EXTRACT.
   - **A model check:** the request/acknowledge toggles, the doorbells and
     the interrupt's acknowledge order (06 §6.3.6-§6.3.7), through
     `lib/check` (D166's world shape): no request is lost and no
     acknowledge is double-counted, in every interleaving.
   - **On the board,** board-test adds three checks, through `gpu-test`, a
     client of the `csf` capset:
     - `ok: the GPU's firmware booted`: interface version and slots.
     - `ok: the GPU ran a command stream`: a user stream of MOV48,
       STORE_STATE timestamp and SYNC_ADD64 into a buffer. The client reads
       a non-zero timestamp back and sees its counter raised.
     - `ok: a faulting stream ended only its group`: a CALL to an unmapped
       VA. Its context is `lost`, its fault is named in `status`, and a new
       context's stream then runs.

     D170's power off and on is run once more after these, and must show
     the firmware booting again.
   - **Two budgets,** reported by board-test from the start:
     - `gpu.mali.boot_ms`: devmgr's start of the host to the global
       interface's acknowledge.
     - `gpu.mali.empty_job_us`: submit to the counter's raise, for a
       zero-instruction stream, the median of 100.

     Their limits are set from the first recorded board runs, in the change
     that records them (`docs/performance.md`).
   - **The hardware row:** sky1-mali-g720 moves from development to experimental in
     `docs/hardware/support.tsv` with the command stream's check.

   QEMU has no Mali, so there is no boot test. `docs/risk.tsv` already
   maps `drivers/gpu/` to MaliTests and boot-board; the protocol adds its
   IDL check.
9. **The user side (item 6's second half): our own, chosen by the owner
   (2026-11-20).** Vulkan compute and rendering on the G720 needs:
   - the Valhall shader ISA and a compiler from SPIR-V to it;
   - the resource and sampler descriptors;
   - the tiler's and fragment's formats;
   - the CS instructions a user driver writes.

   No chinese-wall spec covers them; their open source is Mesa's panvk and
   its compiler. So chinese-wall writes a new spec set of Valhall's user
   side from Mesa (`specs/valhall`), and from it we write our own compiler
   and Vulkan driver in Swift, behind our loader, by a team of agents
   working in parallel against the spec's sections. D55's open question
   (all of Vulkan, or a Loinnir-shaped interface) is answered in that
   driver's own decision. Not chosen: kernels compiled on the host by a
   third-party compiler (general Vulkan never follows from it), and moving
   the user side out of V6f. §7's protocol is already the shape that
   driver needs.

## Not chosen

- **Linux's ioctl ABI.** It exists for Mesa's binaries, which can't run
  here (D4). The object model is kept, the encoding isn't.
- **A firmware or scheduler in a second process** (mali's control in one
  host, the scheduler in another). The CSF interface is one shared page
  that both would write, and every event needs both. One host, as for
  every other driver.
- **Refusing groups beyond the CSG slots.** It is simpler, but a desktop
  with a compositor, a few clients and a test has more groups than slots
  soon enough. The tick is panthor's and is specified.
- **Cached memory with cache maintenance.** It is faster for CPU reads of
  GPU results. But the display can't see what isn't cleaned (11.7), and
  every buffer may become a scanout. A `readback` heap that is cached and
  maintained can follow, when a measurement asks for it.

## The order of the work

Each part is tested on the host before the next is built on it. Parts 1 to
3 are independent of each other:

1. The image parser, and `GPUPageTable` over `lib/pagetables`.
2. The CSF interface (layouts by version, request/acknowledge), the model
   firmware, and the model check.
3. The ring writer and the scheduler's state machine, against the model
   firmware.
4. On the board: control (§2), AS 0, firmware boot. Then `status`, and
   board-test's first check.
5. The `csf` protocol (IDL, the class's client), `gpu-test`, and the
   other two checks.
6. Residency past 16 groups, and full reset. Then D170's power cycle with
   the firmware.

DVFS through SCMI performance domain 0 (11.10, rate-limited: one change
per 100 ms, no core-scaling levels) is part of item 2's governor work,
not this decision.

## As built (2026-11-20)

- **Parts 1 to 3, tested on the host:**
  - `lib/Firmware.swift`, the image's parser.
  - `GPUPageTable`, a format of `lib/pagetables`. Its builder became
    generic over a format and gained `unmap`.
  - `CSF.swift`, `CSFHost.swift` and `ModelFirmware.swift`: the interface
    by version, the request/acknowledge protocol, and a stand-in
    firmware. The handshake's model check (`MaliCheckTests`) passes the
    protocol and catches five broken orderings.
  - `Ring.swift`, `VARange.swift`, `ASSlots.swift` and `Scheduler.swift`.
- **Parts 4 and 5, on the board:**
  - `Control.swift` holds the Sky1's order. `Device.swift` and
    `Backend.swift` are the hardware side; `Link.swift` and `MMU.swift`
    are the scheduler's link and the address-space sequences.
  - `Service.swift` and `ServiceIPC.swift` hold the `csf` protocol's
    engine and server (`GPUCapset.csf`, 0x1000). The protocol is
    `drivers/gpu/lib/CSF.swift` and its client
    `drivers/gpu/client/CSF.swift`.
  - gpu-test, started by board-test through the launcher.
- **What the board showed:**
  - Firmware interface 3.13.0, between the 1.x and 4.x layouts §5 named.
  - 8 CSG slots of 8 CS slots, 128 work registers, 16 scoreboards,
    GPU_TIMESTAMP at 1 GHz.
  - `gpu.mali.boot_ms` 3 ms at boot, 7 ms after D170's power off and on.
    The MCU is halted before the supply ends (`HostShutdown` in
    DriverHost), in under 1 ms.
  - gpu-test's user stream wrote a GPU timestamp and raised its counter.
  - The faulting stream raised a translation fault on address space 1
    at its unmapped VA. Only its group ended (state 2, one fatal queue),
    and a fresh context ran.
  - `gpu.mali.empty_job_us` was 16 us, the median of 100 zero-size
    submissions through IPC.
- **Changes beyond mali:**
  - devmgr grants all of a platform device's interrupts by index. It
    mounts a GPU's tree at `dev/gpu<n>` where it starts a host it powers
    up: mali starts there at boot too, so gpu-test first found no GPU.
  - The kernel's reboot gives the console up to 10 s to drain, not 2 s.
    board-test's 40 KB report lost its verdict to the cap at 115200
    baud.
- **Follow-ups (2026-11-20, to be shown on the board):**
  - The GPU line (index 2) is served: FAULT, PROTM_FAULT, RESET_COMPLETED and
    CLEAN_CACHES_COMPLETED unmasked (panthor 03 section 3.8.4), a fault read
    into an `event:` line and no reset after it; the line missing is said in
    status and its faults read by the other threads' pumps.
  - Thread limits (THREAD_MAX_THREADS, THREAD_MAX_WORKGROUP_SIZE,
    THREAD_MAX_BARRIER_SIZE, THREAD_FEATURES) are probed, in status, and given
    by the protocol's new `limits` call (version 2: `Info` is a struct a
    baseline can't grow). gpu-test sizes its dispatch from them.
  - Every `event:` and `firmware:` line has its time (ms since the host
    started). A reset's `event:` line names its cause, one per request that
    merged into it; a CS fatal other than CS_UNRECOVERABLE resets nothing.
- **Open:**
  - TILER_OOM is never acknowledged (rendering's).
  - The two budgets' limits, to be set from recorded runs.
  - DVFS (item 2's governor).
  - §9's user side.
