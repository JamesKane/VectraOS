# croi vs Zircon: known divergences

Every place croi's behaviour or ABI knowingly differs from Zircon at the
reference pin (`../fuchsia` at `e8b19ec722db74727411b941cf3cd5d1fae5dfc8`),
gathered from docs/kernel/design/ and docs/kernel/roadmap.md and maintained alongside them:
a change that adds, removes or settles a divergence updates this file too.
Each entry gives its kind: **deliberate** (a croi design choice), **not
yet** (a Zircon feature croi hasn't implemented) or **quirk parity** (croi
matches the pinned tree where upstream docs or expectations say otherwise).

## Scope

- **Boot and discovery** — UEFI + ACPI only (no devicetree, no other boot
  protocol, no ZBI around the boot image). Kind:
  deliberate. Impact: board ports; firmware data reaches user space as
  below.
- **No hypervisor** — Zircon's guest/VCPU objects are out of scope. Kind:
  deliberate. Impact: anything wanting virtualization.

## ABI and syscall packing

- **Direct syscalls, croi's numbers** — user programs call the kernel by
  croi's own syscall numbers (number in rax / x16 / a7) rather than through
  Zircon's vDSO entry points (croi's vDSO has a few functions, such as
  cache_flush, and the shared pages). Kind: deliberate. Impact: binaries built for Zircon
  don't run unmodified.
- **Six argument registers: packed handles** — calls with more arguments
  pack `handle | options << 32`: vmar_map and friends, resource_create
  (`parent | options << 32`), bti_pin (`bti | options << 32`, `vmo |
  addrs_count << 32`, eight arguments in six registers),
  pager_query_dirty_ranges (`pager | vmo << 32`, actual and avail through
  one `size_t out[2]`). Kind: deliberate. Impact: library wrappers.
- **channel_read capacities and actuals** — `bytes | handles << 32` packed
  into one argument each. Kind: deliberate. Impact: library wrappers.
- **vmar_unmap_handle_close_thread_exit is a syscall** (75) — Zircon's is
  vDSO code; a failed close raises an undefined-instruction exception (as
  Zircon's vDSO traps). Kind: deliberate. Impact: none for callers.
- **`croi_iovec_t`** — capacity is `uint64_t` (the ABI headers have no
  `size_t`). Kind: deliberate. Impact: identical layout on 64-bit.
- **CPU_STATS returns a count** — object_get_info CROI_INFO_CPU_STATS fills
  as many records as fit and returns the count, without actual/avail
  pointers (docs/kernel/design/cpu.md, K10f; other topics take Zircon's actual and avail as
  fifth and sixth arguments since K13e). Kind: deliberate. Impact: m2 and
  stats tools.
- **Test-only syscall 6** (`TestHooks`) — croi's self-test hook. Kind:
  deliberate. Impact: none outside tests.
- **No debug_write** (V1, D28) — Zircon's zx_debug_write prints to the
  kernel console; croi logs only through a debuglog
  (`debuglog_write`), which every program gets as fd 1. Kind:
  deliberate (one way to log). Impact: a program without a debuglog
  can't print.

## Handles, objects and IPC

- **No interrupt_wait, interrupt_destroy or virtual interrupts** (V1,
  D29) — a bound port is the one way to wait for an interrupt, and
  closing its last handle destroys it; a counter is a virtual interrupt
  (no interrupt_trigger). Ext 5's lent profile and handed-off context
  go to the thread the packet wakes from its port. Kind: deliberate (one
  way to wait). Impact: ports of Fuchsia drivers that wait on the
  interrupt directly.
- **Interrupt object lifetime** — destroyed with its last reference
  (listed under "Differences from Zircon", K9c). Kind: deliberate. Impact:
  low.
- **Missing families** — IOB, restricted mode, membarrier, the
  ktrace/sampler syscalls (croi has its own trace and PMU calls). Kind:
  not yet. Impact: ports of Fuchsia code using them.

## Sockets, streams and FIFOs

- **Cut** (V1, D21) — croi has none of them; the one ring format and
  mappings replace them. The VMO content size property stays. Kind:
  deliberate. Impact: Fuchsia code using them.

## Channel _etc forms and futex extras

- **Cut** (V1, D22) — no channel_write_etc, channel_read_etc or
  channel_call_etc: rights are narrowed with handle_duplicate before
  sending, and a reader learns a handle's type and rights from
  object_get_info. No futex_requeue, futex_wake_single_owner or
  futex_get_owner: futex_wait still names an owner, and futex_wake clears
  it. Kind: deliberate. Impact: Fuchsia code using them (libsync's
  condition variables requeue).

## Events, signals and waits

- **Cut** (V1, D23) — no event_create, eventpair_create, object_signal,
  object_signal_peer, object_wait_one or object_wait_many, and with them
  no user signals, no SIGNAL_PEER right, no NEW_EVENT or NEW_EVENTPAIR
  policy conditions, no HANDLE_CLOSED signal and no BLOCKED_WAIT_MANY
  thread state. A port is the one wait (object_bind, then port_wait); a
  counter is the event a user drives. Events remain only as the kernel's
  system_get_event objects, until that call is cut too. Kind:
  deliberate. Impact: every Fuchsia program (zx_object_wait_one is
  everywhere, libasync and fdio included).
- **A ONCE binding holds its port** — closing a port's last handle doesn't
  cancel the bindings to it, as Zircon's on_zero_handles does; a pending
  one keeps the port until it fires or its source handle closes. A
  waiter that gives up cancels it (usertest.c's `wait_for`, the suites'
  `Port.signals`). Kind: inherited from croi's K5b; now visible, since
  every timed wait is a binding. Fix: cancel a port's bindings when its
  last handle closes, before ports become rings (D19).

## Sleeps, timers and counter waits

- **Cut** (V1, D25) — no nanosleep, no timer objects (timer_create, set
  and cancel, the slack policies, the NEW_TIMER policy condition), no
  counter_write. A sleep or a timer is a port_wait's deadline (with a
  leeway that only ever runs late, none for a deadline thread); a value
  is set by adding the difference. Kind: deliberate. Impact: every
  Fuchsia program that sleeps (zx_nanosleep) or uses async::Task's
  timers.
- **Lending through a port** — croi's counters lend their
  deadline profile (ext 5) to the thread their packet wakes in
  port_wait, where they lent it to counter_wait's threads. Zircon has
  neither. Kind: deliberate. Impact: none.

## VM and VMOs

- **Snapshot child of a shrinking parent** (K13h) — croi's child reads
  zeros past the cut only while the parent stays that small; Zircon clamps
  the child's parent limit permanently. Kind: deliberate (simplification).
  Impact: low; within at-least-on-write semantics. Fix: a per-child parent
  limit clamped at shrink.
- **Untracked zeroing past a content size of a child** (K14i) —
  a content size cut zeroes up to the new size's page end as Zircon
  does; past it a plain VMO's pages are decommitted and a pager VMO's
  become an untracked zero interval (K14k), but a snapshot child's (or a
  slice's) committed pages are zeroed in place, so its absent pages there
  still read as its parent's (Zircon inserts zero markers). Kind:
  deliberate (no markers in children). Impact: vmo_read past the content
  size of a child.
- **Per-page range operations** (K14i) — decommit, ZERO, cache ops, page
  states and dirty ranges are sparse; COMMIT, PREFETCH, ALWAYS_NEED, a
  child's ZERO and a TRAP_DIRTY pager VMO's ZERO still touch every page of
  their range. Kind: not yet. Impact: such an operation over most of an
  UNBOUNDED VMO runs until memory or the pager gives out.
- **K11a children copy on first touch** — a SNAPSHOT_AT_LEAST_ON_WRITE
  child copies a parent page at its first read or write (allowed by "at
  least on write"; no hidden nodes); DECOMMIT on a child is NOT_SUPPORTED
  and ZERO writes zeros into a copy. Kind: deliberate. Impact: more memory
  for read-mostly children.
- **Full snapshots copy at creation** (K14g) — SNAPSHOT (and
  SNAPSHOT_MODIFIED wherever Zircon makes it a full snapshot) copies every
  page the parent shows in range when the child is created; Zircon moves
  them into a hidden node both sides share until written. Contents and
  isolation are the same; the copy costs memory and time up front, and a
  write racing the creation may land in the snapshot on one page and not
  on another (Zircon's is atomic). The parent itself stays a plain VMO,
  so it can still DECOMMIT (Zircon's parent, now under a hidden node,
  can't). Kind: deliberate (no hidden nodes). Impact: memory for large
  snapshots that are mostly never written; racy writers only.
- **Aliases' mapping counts** (K14g) — ZX_INFO_VMO's num_mappings for a
  slice or reference of an anonymous VMO is 0: mappings of it are listed
  on its root. Kind: simplification. Impact: diagnostics only.
- **arm64 UNCACHED** — vmo_set_cache_policy maps UNCACHED and
  UNCACHED_DEVICE both as device memory, so arm64 gets Device-nGnRE where
  Zircon uses Device-nGnRnE for UNCACHED. Kind: deliberate. Impact: arm64
  drivers relying on UNCACHED being Normal-NC-like or nGnRnE.
- **CACHE_INVALIDATE** — vmo_op_range answers NOT_SUPPORTED; Zircon offers
  invalidate-only behind a debugging option (croi keeps the gate closed).
  Kind: deliberate. Impact: none for correct DMA code (use
  CLEAN_INVALIDATE).
- **Zero intervals** (K14k) — as Zircon's (dirty, awaiting clean,
  untracked), kept as a sorted list per VMO rather than markers in the
  page list, and exact where Zircon tracks one awaiting-clean length per
  interval. Under TRAP_DIRTY, ZERO still zeroes page by page (Zircon asks
  the pager to dirty the range first). Kind: deliberate / not yet.
  Impact: TRAP_DIRTY pagers zeroing large ranges.
- **KMEM_STATS fields** — total, free, wired, heap, vmo, mmu, other and
  (K14a) the reclaim and discardable fields filled; loaned, ipc, cache,
  slab, zram and reclaim_disabled are 0. Kind: not yet. Impact: memory
  dashboards.
- **Page loaning** — as Zircon's for decommitted contiguous VMOs (K14f),
  plus croi's boot contiguous pool lending its free pages; on by default
  (`croi.ppb.loan=off`; Zircon's kernel.ppb.loan and borrow-on-mru
  default off). Borrowing happens at aging passes (Zircon: on the MRU
  sweep), and taking a page back always evicts (Zircon's
  replace-on-unloan copy isn't there). Kind: deliberate. Impact: none.

## Reclamation (K14a)

- **No page queues** — Zircon keeps every page on one of its queues (an
  8-generation LRU ring, isolate lists); croi keeps a list of reclaimable
  VMOs and an age in each page record, and walks them. Ages, the two
  protected newest ages, DONT_NEED first and the watchdog's oldest-only
  eviction behave as Zircon's. Kind: deliberate (simplification). Impact:
  eviction and aging cost grows with reclaimable pages, not with need.
- **Aging only while reclaimable VMOs exist** — no aging thread wakeups on
  a machine with no pager or discardable VMOs (M4's idle machine); no
  active-ratio early aging (the 15 s maximum interval only). Kind:
  deliberate. Impact: low.
- **Single pages** — evicted page by page; Zircon takes the aligned 64 KiB
  block around a chosen page. Kind: deliberate. Impact: more READ
  requests on refault.
- **Discardable VMOs age like pager pages** — reclaimable once unlocked,
  by their first page's age; with Zircon's default options (anonymous
  reclaim off) a discardable VMO is never discarded. Kind: deliberate (the
  documented behaviour). Impact: discardable memory actually goes.
- **Discard takes pages before unmapping** — croi takes a discarded VMO's
  (or an evicted page's) pages under its lock, then unmaps, then frees
  (Zircon unmaps under the VMO lock, which croi's aspace -> vmo lock order
  doesn't allow); a write through a stale mapping in that window is lost,
  which for a discard only matters if a LOCK lands in the same window.
  Kind: deliberate. Impact: very low.
- **OOM** — reboot only (`croi.oom.reboot_timeout_ms`, Zircon's 50 s
  default), and no HaltToken, so the wait is never cut short; no jobkill
  behaviour, no ZX_PROP_JOB_KILL_ON_OOM; no continuous eviction mode; no
  delayed CAN_WAIT allocations below OOM. Kind: not yet. Impact: a system
  that wants to survive OOM by killing jobs.
- **Hints on snapshot children** — DONT_NEED / ALWAYS_NEED through a child
  of a pager VMO apply to the pager VMO's pages over the whole range,
  including pages the child has already copied. Kind: deliberate. Impact:
  none.
- **Not yet**: compression (zram), zero-page dedupe, page-table reclaim,
  high-priority VMOs (`reclaim_disabled_bytes` 0), memory
  stall watching. Kind: not yet.

## Pager

- **One packet per request** — each new range gets its own READ/DIRTY
  packet; Zircon keeps one request in flight per VMO. Kind: deliberate.
  Impact: a pager may see more, smaller packets.
- **No withdrawal** — a packet isn't taken back when its request resolves
  before the pager reads it. Kind: deliberate. Impact: pagers must
  tolerate stale requests (supplying already-present pages is harmless).
- **Source holds its port** — a pager VMO's source keeps a reference to
  its port. Kind: deliberate. Impact: the port lives as long as the
  source.
- **DECOMMIT on a pager VMO** — NOT_SUPPORTED. Kind: not yet. Impact: low.
- **Eviction** — clean pager pages are evicted and the hints honoured
  since K14a; its differences are under "Reclamation (K14a)".

## Clocks and time

- **Cut** (V1, D26) — no clock objects (clock_create, read, get_details,
  update, vmar_map_clock, INFO_CLOCK_MAPPED_SIZE) and no
  clock_get_monotonic syscall. Monotonic time is the vDSO's only (Zircon
  has it there too, and the syscall besides); UTC is the time service's,
  in a read-only seqlock VMO each process gets at start. Kind:
  deliberate. Impact: every Fuchsia program reading UTC
  (zx_utc_reference_get, zx_clock_read) and anything calling the
  monotonic syscall directly.
- **BOOT is monotonic** — no suspend, so the boot timeline equals the
  monotonic one (interrupt timestamps are monotonic). Kind: deliberate (until suspend exists). Impact: none today.
- **futex_wait without an owner needs no handle table** — futexes are
  keyed by address space, so a thread with no handles can sleep on one
  (croi's kernel-launched self-tests do). Zircon's threads always have a
  process. Kind: deliberate. Impact: none.

## Tasks, exceptions and debugging

- **Syscall restart in the kernel** — for suspension Zircon wakes
  interruptible waits with INTR_RETRY and its vDSO re-issues the call;
  croi's programs call the kernel directly, so the kernel rewinds the PC
  over the syscall for the restartable waits (port_wait, vmo_read,
  futex_wait). Other waits (channel_call, exceptions)
  suspend when they end. Kind: deliberate. Impact: debuggers see the PC at
  the syscall instruction.
- **Debugging syscalls option** — process_write_memory and debug-register
  / single-step writes need `croi.debug_syscalls=on` (implied by
  `croi.test=1`), else NOT_SUPPORTED. Kind: deliberate (croi's option
  name). Impact: debugger setup on croi boots.
- **process_exit marks the caller killed** before it exits, so its
  THREAD_EXITING doesn't wait for a debugger. Kind: quirk parity (Zircon
  kills it too). Impact: none.
- **rv64 debugging** — single-step NOT_SUPPORTED, debug registers a u32
  written and ignored. Kind: quirk parity (Zircon's). Impact: none vs the
  pin.
- **SError** — kernel SErrors other than corrected ones panic; delivery of
  a recoverable SError to the faulting process is planned (Zircon only
  counts SErrors). Kind: deliberate / not yet. Impact: arm64 hardware
  errors.
- **Thread info** — page-fault and lock-contention time aren't tracked.
  Kind: not yet. Impact: profilers.

## Drivers, interrupts, DMA and IOMMUs

- **AMD and RISC-V IOMMU types are croi's** — iommu_create types
  CROI_IOMMU_TYPE_AMD (0x10000, croi_iommu_desc_amd_t) and
  CROI_IOMMU_TYPE_RISCV (0x10001, `{ register_base }`); Zircon has
  neither. Kind: deliberate. Impact: drivers on AMD or RISC-V machines.
- **ARM_SMMU means SMMUv3 (and v1/v2 by IORT node)** — Zircon's type and
  descriptor, but Zircon's driver is SMMUv2 from a devicetree. Kind:
  deliberate. Impact: none for callers.
- **Intel VT-d** — the pinned Fuchsia has no Intel driver; croi's follows
  the specification behind Zircon's ABI. Devices no driver claims stay
  pass-through (Zircon blocks them). Kind: deliberate / not yet. Impact:
  unclaimed devices can DMA anywhere.
- **No-IOMMU BTI warning** — creating one writes a WARNING debuglog record
  (a recorded trust decision). Kind: deliberate. Impact: log noise only.
- **amd64 MSI destinations** — without interrupt remapping, APIC ids above
  255 are NOT_SUPPORTED. Kind: not yet (remapping lifts it). Impact:
  large machines without VT-d/AMD-Vi remapping.
- **Plain MSI affinity** — interrupt_set_affinity is NOT_SUPPORTED for
  plain MSI (the driver owns the capability); MSI-X moves per vector.
  Kind: deliberate. Impact: drivers of MSI-only devices.
- **arm64 MSIs work** — croi drives the GICv3 ITS; Zircon's is
  unimplemented (panics). Kind: deliberate. Impact: none (strictly more).
- **SMC resources by function ID** (K13i) — an SMC resource is a range of
  SMCCC function IDs; Zircon's is a range of 6-bit service call numbers
  (OEN), so a Zircon-style resource (base 0x02, size 1: SiP) doesn't
  carry over. Kind: deliberate (an OEN grants every SiP call). Impact:
  drivers and devmgr making SMC resources.
- **smc_call's conduit** — the FADT's PSCI conduit (HVC where firmware
  runs at EL2); Zircon always issues SMC. Kind: deliberate. Impact: none
  where firmware is at EL3.
- **The kernel's PSCI calls refused** — CPU_ON/OFF/SUSPEND, MIGRATE,
  SYSTEM_OFF/RESET/RESET2/SUSPEND, CPU_FREEZE, CPU_DEFAULT_SUSPEND can't
  be reached through smc_call or an SMC resource, even the root's; Zircon
  doesn't filter. Kind: deliberate. Impact: none (system_powerctl).
- **Qualcomm yielding calls** — behind `croi.smccc_qcom=on` (Zircon's
  boot option arm64_smccc_qcom). Kind: parity, croi's option name.
- **powerctl on amd64** — plain SHUTDOWN is NOT_SUPPORTED: user space
  passes \_S5's sleep types with ACPI_TRANSITION_S_STATE; suspend,
  hotplug, PL1 and bootloader/recovery reboots are NOT_SUPPORTED on every
  arch. Kind: deliberate / not yet. Impact: power services.

## Boot and loading

- **No ZBI** — bootfs.img is Zircon's bootfs format without a ZBI around
  it; firmware data (RSDP, SMBIOS, framebuffer, memory map) reaches
  userboot as a ZBI-format container in PA_VMO_BOOTDATA built by the
  kernel. Kind: deliberate. Impact: user space reads `include/zbi.h`
  items only.

## croi additions (not in Zircon)

- object_bind VALUE — a packet when a counter reaches a value (packet
  type 0x82). A counter with a deadline profile lends it to the thread
  its packet wakes.
- `object_bind` (22, V1) — replaces object_wait_async, interrupt_bind,
  counter_wait_async, thread_bind_overrun_port and
  account_bind_pressure_port: a batch of bindings, ONCE or PERSISTENT
  (a coalescing packet with a count), plus a counter's CHANGE doorbell
  (packet type 0x83). port_cancel unbinds interrupts; port_wait takes a
  leeway. Kind: deliberate (VectraOS D20).
- Deadline-carrying wakeups — object_set_profile on interrupts and
  counters. (Display timelines, type 48, and ALIGN_TIMELINE were cut in
  V1, D27: a vblank is a counter.)
- Admission refusal reasons — profile_create / object_set_profile report
  why a deadline profile was refused (Zircon has no admission).
- channel_call donation — the reader of a call inherits the caller's
  profile until the reply.
- Budget-overrun packets (type 0x80), through object_bind OVERRUN.
- `job_set_cpu_reservation` (108) — CPUs reserved for a job.
- `interrupt_set_affinity` (146) — route an interrupt to a CPU mask.
- `bti_set_properties` (156) and CROI_INFO_BTI_PROPERTIES — narrow a BTI's
  address width, window and memory type.
- CROI_INFO_THREAD_TRACE, CROI_INFO_DEBUGLOG — trace id of a thread; the
  dumper's printed count.
- `trace_configure`, `pmu_configure` (51) — croi's per-CPU trace rings,
  sampling and PMU counters.
- Topology and power pages in the vDSO's shared pages.
- `croi_flow_id` — user-computable flow ids joining channel calls and
  replies in traces.
- Display system resource (base 16).
- Memory accounts and pressure packets (ext 6) — kernel-only today.
- `croi.kill_watch=1` — lockup report after task_kill.
