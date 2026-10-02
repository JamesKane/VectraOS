# Phase 1 — Micro-kernel, ring IPC and the zero-copy fabric

_Blueprint v0, 2026-09-30._

## 1. What the kernel does, and what it does not

| In the kernel | In user space |
|---|---|
| Physical memory allocator; page tables; VMOs; address spaces | Filesystems, the page-cache *policy* (through pagers), swap |
| Threads; scheduling contexts; per-CPU run queues; the timer | Process and pid semantics, note groups, sessions, `wait` (`procfs`) |
| Handle tables, rights, capability transfer | Names and paths (`libns`), authentication (`keyd`) |
| Ports, counters, channels; ring *setup* and doorbells | Every protocol that runs over rings and channels (9Px, block, net, present) |
| IRQ routing; the MMIO, I/O-port and DMA-domain (IOMMU) objects | Every device driver, including bus enumeration (PCI, ACPI AML, device tree) |
| CPU bring-up; FPU/SIMD state; mitigations; the minimal debug console | Consoles, logging, crash reporting |

**Size budget:** 15–25 kLOC of C23 including both architecture ports, with assembly confined to `arch/`. `./build loc` checks it on every build (04 §3.2). If a feature would push the kernel past this budget, it belongs in a server. The budget has to cover four IOMMU drivers (VT-d, AMD-Vi, SMMUv3, DART), hybrid-core placement, the pager, the PMU and the debug syscalls, which is why the v1 scheduler is kept minimal (§8).

## 2. Kernel objects

| Object | Purpose | Notes |
|---|---|---|
| `Task` | Address space plus handle table; the unit of isolation | Its id, never reused, is its process's pid; `procfs` keeps the process table (ADR-0011), and `exec` keeps the task (ADR-0012). A task ends with an exit string (ADR-0010) |
| `Thread` | Execution context; belongs to one task | Bound to one `SchedContext` at a time |
| `SchedContext` | CPU budget, period and intent (§8) | In the style of seL4 MCS. It can be *donated* through synchronous calls (§4.5) |
| `Vmo` | Pages: anonymous, physical (MMIO), contiguous, or supplied by a pager | Clone (copy-on-write), seal, cache policy, resize (`vmo_op`), `NODUMP` (never written to a crash directory, 05 §5) |
| `Pager` | A user-space supplier of pages for pager-backed VMOs | This is how `fsd` backs `mmap` of files without copying. Trusted pagers only, with a supply deadline (§5) |
| `Port` | Queue of completion packets; the one wait (§4.4) | A thread waits on one port. Sources are *bound* to ports |
| `Counter` | 64-bit monotonic timeline | Doorbells, GPU/NPU fences, frame sequence numbers |
| `Channel` | Bidirectional datagram pipe carrying bytes plus handles | Control plane and capability transfer (§4.2) |
| `Ring` | Queue pair in a shared VMO, plus doorbells and a handle side channel | Data plane (§4.3) |
| `Irq` | An interrupt line or MSI/MSI-X vector, delivered to a port | Masked until the driver acknowledges it |
| `IoRange` | An x86 I/O-port range | Installed in the I/O permission bitmap of the TSS |
| `DmaDomain` | An IOMMU context (VT-d, AMD-Vi, SMMUv3, Apple DART) bound to a device | Maps VMO pages for device access and pins them (§6) |
| `Resource` | Root authority over ranges of physical memory, IRQs and I/O ports | Held only by `svcd` and `devmgr`, which mint narrower objects from it |

## 3. Capabilities

- **Handles:** 32-bit per-task indices into a table of `(object ref, rights, badge)` entries. Each value is a table index plus a **generation count** in the upper bits, bumped every time a slot is reused, so a stale handle fails with `BAD_HANDLE` instead of reaching a new object. Handle values are deterministic: the same program run twice sees the same handles, which keeps debugging and replay reproducible.
- **Rights:** `READ WRITE EXEC MAP DUPLICATE TRANSFER SIGNAL WAIT MANAGE INSPECT DEBUG`. `DEBUG` on a task allows stopping it and changing its memory and registers (05 §2). Every syscall checks the rights it needs. `handle_dup(h, rights)` can only *reduce* rights.
- **Badges:** a 64-bit value that the minter attaches when creating a channel or ring endpoint for a client. The server sees it on every message, so it can tell clients apart without trusting what they claim, as with seL4 badges.
- **Transfer:** handles move *only* through channels or through a ring's handle side channel, and the kernel moves them. A handle sent without `TRANSFER` is refused.
- **No ambient authority:** a new task starts with exactly the handles its parent passes in the spawn message. There is no global lookup syscall.
- **The spawn message:** a new task's first thread starts with one handle, its bootstrap channel. The first message there is the spawn message: a header, then ndb records (02 §4.1) that name each handle it carries (`self` is the task itself) and give the program its arguments and its namespace as `mount` and `bind` records, which `vx-ns` replays. The format is in `abi/vx/abi.h`. The parent builds the task with the ELF loader in `vx-rt` (§9); the kernel loads only the root task, and sends it a spawn message too. A shell joins programs into pipes by giving them `stdin` and `stdout` channel ends; a channel message is a chunk of the stream, and the writer closing its end is the end of the file.
- **The task tree:** a task's creator is its parent, and a task whose parent has gone passes to its grandparent. `task_info` and `task_kill` take an optional task id, which must be the handle's task or one of its descendants, and `task_info` can list them in id order. So whoever holds a task handle can see and kill that task's tree (as `procfs` does with `svcd`'s), and no one else can: it is still not a global lookup.
- **Revocation (v1):**
  1. Closing one end of a channel or ring disconnects the peer, which gets `PEER_CLOSED` on its port.
  2. Killing a task revokes everything it holds.
  3. `Vmo` *leases*: a VMO can be shared through a revocable derived handle. Revoking the lease unmaps it everywhere and tears down its DMA mappings. This is essential for restarting drivers safely (§7.4).

  General derivation-tree revocation, as in seL4, is deferred. Where it is needed, proxy servers provide it, which suits a namespace system: interpose a server, then cut it off.

### Syscall surface (62 calls)

This list is the whole surface, and `./build loc` counts it. A new syscall needs an ADR, and the ADR says what it replaces or why nothing can.

```
task_create  task_exec  task_kill  task_info                          # task_exec: ADR-0012
thread_create  thread_start  thread_exit  thread_interrupt  thread_state(get/set registers, debug registers, single step)
thread_suspend  thread_resume  task_mem_rw  exception_bind  exception_resume   # debugging (05 §2)
sched_ctx_create  sched_ctx_bind  sched_ctx_configure  sched_reserve   # intents, admission, core reservations (§8)
vmo_create(kind: anonymous/physical/contiguous)  vmo_clone  vmo_seal
vmo_rw  vmo_op(commit/decommit/resize/cache_clean/cache_inval/lock)  vmo_lease  vmo_revoke
pager_create  pager_supply  pager_op
as_reserve  as_map  as_unmap  as_protect  as_query
handle_dup  handle_close  handle_replace
port_create  port_bind  port_wait  port_post  port_cancel
counter_create  counter_signal  counter_read
futex_wait  futex_wake                                                 # §4.6
channel_create  channel_write  channel_read  channel_call
ring_create  ring_notify  ring_xfer_handles
irq_create  irq_ack  iorange_create  dma_domain_create  dma_map  dma_unmap
clock_read  debug_write (only while a debug capability is held)
pmu_configure                                                          # performance counters (05 §9)
```

`clock_read` also runs from a vDSO page without entering the kernel, as does reading counters, which live in a shared page. Batchable calls (`dma_map`, `port_bind`, `handle_close`, `vmo_rw`, `vmo_op`, `task_mem_rw`) take arrays (rule 11).

## 4. IPC

### 4.1 Two tiers

```
                control plane                         data plane
  client ── channel (kernel copies ≤64 KiB, ≤64 handles) ──► server
  client ══ ring (shared VMO; the kernel is not on the path) ══► server
              ▲ doorbell = Counter, completion lands on the client's Port
```

- **Channels** handle bootstrap, capability transfer, rare control operations and the synchronous `channel_call` fast path (§4.5).
- **Rings** handle everything with volume: 9Px messages, block and network I/O, input events, present requests, audio buffers, inference requests.

A server normally hands out a ring *through* a channel. A ring is created in one call and both endpoints are returned. The server keeps one endpoint and sends the other to the client over the channel the client came in on.

### 4.2 Channels

- They carry datagrams, not a byte stream. Each message has a 16-byte header `{txid, ordinal, flags, sender_intent}`, a body of up to 64 KiB, and up to 64 handles. The kernel writes `sender_intent`, the intent of the sending thread's scheduling context, so a server can trust it (§4.3).
- `channel_write` copies the body into a kernel buffer and moves the handles. `channel_read` copies them out.
- The per-endpoint queue is bounded (64 messages and 1 MiB in v1, charged to the sender's budget once budgets exist), so a flood fails the sender with `SHOULD_WAIT`, never growing the kernel. Handles written to a channel leave the writer's table whether or not the write succeeds.
- Readable and peer-closed signals are delivered to a bound port.

### 4.3 Rings

A ring is one VMO mapped into both tasks at addresses each side chooses:

```
 offset 0      RingHeader (read-only after creation)                          4 KiB
                 magic 'VXRB' · version · entry_size · sq_entries · cq_entries
                 offsets of the SQ, CQ and arenas · features bitmap
 +4 KiB        SQ producer line   { tail: AtomicU32 }                   ← own 64 B line
               SQ consumer line   { head: AtomicU32, flags: NEED_WAKEUP }  ← own line
               CQ producer line   { tail }                                ← own line
               CQ consumer line   { head, flags }                         ← own line
 +8 KiB        SQ entries  [sq_entries × entry_size]
               CQ entries  [cq_entries × entry_size]
 +N            Client TX arena   (the client allocates; the server reads)
               Server TX arena   (the server allocates; the client reads)
```

**Queues:** each queue is **single-producer, single-consumer**, so both ends are wait-free. The client produces SQ entries and consumes CQ entries; the server does the reverse. Indices are free-running `u32` values, masked by `entries - 1` (which is a power of two).
- *Why SPSC:* a multi-producer queue needs a CAS loop, and it lets one client corrupt the queue for others. Instead, a server keeps one ring per client, which scales with clients and isolates them. Threads in one client share a ring through the client library, or open one ring each.

**Entries:** the default `entry_size` is 64 bytes, one cache line. The generic descriptor is below; each protocol defines its own opcodes and may use the inline bytes for small payloads.

```c
enum vx_sqe_flags : uint16_t { VX_SQE_LINK = 1, VX_SQE_DREF = 2, VX_SQE_HANDLES = 4, VX_SQE_FENCE = 8 };

typedef struct vx_sqe {              // submission entry, 64 bytes
    alignas(64) uint16_t opcode;
    uint16_t flags;                  // LINK (chain), DREF (data in arena), HANDLES, FENCE
    uint8_t  _rsvd[4];               // no per-entry priority: the service class belongs to the ring (below)
    uint64_t user_data;              // echoed in the vx_cqe
    uint64_t target;                 // fid, block, socket, surface: protocol-defined
    uint64_t offset;
    uint32_t arena_off;              // valid if DREF
    uint32_t len;
    uint32_t handle_slot;            // valid if HANDLES: index into the side channel
    uint32_t _pad;
    uint8_t  inline_data[16];
} vx_sqe;
static_assert(sizeof(vx_sqe) == 64);

typedef struct vx_cqe {              // completion entry, 32 bytes
    alignas(32) uint64_t user_data;
    int64_t  result;
    uint32_t flags, aux;
    uint64_t aux2;
} vx_cqe;
static_assert(sizeof(vx_cqe) == 32);
```

**Arenas:** each side allocates only from *its own* TX arena, so there is no shared allocator. A buffer is returned when the peer's completion names it. Large or long-lived payloads go in separate VMOs sent as handles, not in the arena.

**Service class:** a ring's class is fixed when the server creates it, from the `sender_intent` the kernel stamped on the channel message that asked for it (§4.2). Nothing in an entry can raise it, so a client cannot jump the queue by claiming `realtime`. A client that needs real-time service asks for a second ring from a thread with a `realtime` context.

**Memory ordering** (the protocol is model-checked by `vx-check`, an in-tree exhaustive interleaving checker, see 04 §7):

```
producer:  write entry[tail & mask];  tail.store(t+1, Release)
           fence(SeqCst);  if consumer.flags.load(Relaxed) & NEED_WAKEUP { ring_notify(sq) }
consumer:  t = tail.load(Acquire); while head != t { process entry[head & mask]; head += 1 }
           head.store(head, Release)
           if idle: flags.store(NEED_WAKEUP); fence(SeqCst); recheck tail; if still empty → port_wait
```

The flag-and-recheck step with a `SeqCst` fence on both sides prevents lost wake-ups, as `IORING_SQ_NEED_WAKEUP` does in `io_uring`. When both sides are busy, **no syscalls are made at all**. A consumer with an `interactive-frame` or `realtime` intent may spin for a bounded time (default 2 µs) before arming the flag.

**Doorbells:** each ring end has a doorbell `Counter`. `ring_notify` adds one to the peer's, and a `COUNTER_GE` binding on the peer's end (§4.4) turns that into a packet on its port; `counter_read` on an end reads its own doorbell. That is the only kernel entry on the data path, and it happens only when the peer is asleep. A consumer reads its doorbell, announces the sleep, rechecks the queue, and only then binds and waits; `vx-check` explores every interleaving of that protocol, and of four broken variants it must reject (`tests/host/ring_model_test.c`).

**Handle side channel:** an entry cannot carry a capability, because the kernel never reads ring contents. Instead, the sender calls `ring_xfer_handles(ring, PUT, handles[]) → slot`, which queues the handles in the kernel under a slot number, and sets `handle_slot` in the entry. The receiver claims the slot with `ring_xfer_handles(ring, TAKE, slot)` when it processes the entry. Each direction has 16 slots of up to 4 handles in v1. Unclaimed slots are released when the ring closes.

**Treat shared memory as hostile.** A server reads each entry into a local copy *once*, then validates it; it never reads the same entry twice (no double fetch). An index that runs ahead of the other (`tail - head > entries`) is a protocol violation and disconnects the client. A server that must depend on payload bytes not changing, for example to checksum then write, copies them, or asks the client to send them as a separate VMO and `vmo_seal` it (make it read-only for the client). A range inside the ring's arena cannot be sealed.

### 4.4 Ports and counters: the one wait

```c
vx_status port_bind(vx_handle port, vx_handle source, vx_trigger trigger, uint64_t key); // READABLE, PEER_CLOSED, COUNTER_GE(v), IRQ, EXIT, ...
size_t    port_wait(vx_handle port, vx_instant deadline, vx_duration leeway, vx_packet *out, size_t out_len);
vx_status port_post(vx_handle port, const vx_packet *packet); // self-wake and user events; replaces eventfd and EVFILT_USER
```

- Every source a program cares about is bound to one port. That includes ring completions, channels, IRQs, child exit, counters (GPU fences, the frame sequence) and user posts. A thread then makes one call to `port_wait`.
- There is **no separate timer object**. The deadline is a parameter of the wait, and the leeway lets the kernel coalesce wake-ups. Periodic work is a loop on absolute deadlines.
- Packets are 32 bytes: `{key, source, trigger, value, timestamp}`, where `value` is the counter value, the IRQ count, or for `EXIT` the length of the task's exit string (0: success; the string itself from `task_info`, ADR-0010). `port_wait` returns up to `out_len` packets at once (rule 11).
- **One clock.** Every timestamp in the system is on the same monotonic clock, in nanoseconds: port packets, deadlines, frame and input events, the audio contract and debug events. Profiler zones record raw cycle counts, which `/sys/clock/info` converts to that clock (02 §5.1). No subsystem keeps a timebase of its own.
- **Bindings are one-shot, and ports are bounded.** `port_bind` attaches a binding to a source for one trigger: `READABLE` or `PEER_CLOSED` on a channel end, `COUNTER_GE(v)` on a counter, `EXIT` on a task. It fires once, at once if its condition already holds, so no wake-up can be lost between checking and binding; a program re-binds after handling it. Each binding is the packet it will deliver, allocated when it is bound, so bindings can never overflow a port. `port_post` packets go in a fixed ring per port, and `port_post` fails with `SHOULD_WAIT` when it is full; charging them to the poster's budget comes with budgets.
- A **Counter** is a kernel object with a monotonic value; it cannot go backwards. `counter_signal(c, v)` sets the value to `max(current, v)` and wakes every binding whose threshold is at or below it. Its current value is also visible in a read-only shared page, so polling costs no syscall. GPU drivers signal counters from their IRQ threads, which gives *timeline fences* that any process can wait on (§6.2).

### 4.5 Synchronous call fast path

`channel_call(ch, msg, reply_buf, deadline)` sends a message and blocks for the reply in one kernel entry. If the server thread is waiting in `channel_read` on that channel, the kernel switches to it directly, **donating the caller's `SchedContext`**, so the server runs on the client's budget and intent, and switches back on reply. This is the seL4 IPC fast path. It exists for small latency-critical RPCs, such as `nsd`'s `bind` and `mount`, registering a child with `procfs`, `keyd` signing, and `devmgr` queries. It is not used for bulk data. In v1 (M2) the kernel picks the request's `txid` and hands the reply whose `txid` matches straight to the waiting caller, never through the queue; donation and the direct switch come with scheduling contexts.

### 4.6 Futexes

A Counter only goes up, so it cannot express "sleep while this word still holds the value I saw", which pthreads, musl, Mesa and every engine's job system need. Two calls provide it:

```c
vx_status futex_wait(const _Atomic uint32_t *addr, uint32_t expected, vx_instant deadline);
vx_status futex_wake(const _Atomic uint32_t *addr, uint32_t count);
```

- The kernel keys a wait on (VMO, offset), so a futex in shared memory works across tasks. Private anonymous memory is keyed on the address alone.
- `futex_wait` returns at once if `*addr != expected`, which closes the race between checking the value and sleeping.
- A futex wait blocks outside the port. It is for locks and condition variables, which are held briefly. Anything a thread waits on for long goes through its port (rule 4).

## 5. Memory management

**Physical memory:** a buddy allocator per NUMA node, with per-CPU page caches. There are three zones:
- `normal`;
- `dma32`, for devices that cannot address above 4 GiB;
- `contiguous`, a reserved pool for devices without an IOMMU and for large pages.

**VMO kinds:**

| Kind | Backing | Uses |
|---|---|---|
| Anonymous | Zero-filled on demand; copy-on-write clones | Heaps, stacks, rings, `fork` |
| Physical | A fixed physical range | MMIO, framebuffers, firmware tables |
| Contiguous | Pinned physically contiguous pages | DMA for devices without an IOMMU or with small scatter-gather lists |
| Pager-backed | Pages supplied by a user-space `Pager` (`fsd`) | `mmap` of files, and the page cache shared between processes |

- **Pagers are trusted or absent.** Only a task that `svcd` has marked as a pager (`fsd`) can create pager-backed VMOs. Every `pager_supply` has a deadline; if the pager misses it, the faulting thread gets a `PAGER_TIMEOUT` exception (`SIGBUS` under POSIX) instead of hanging. A `Tmap` from a remote or user-mounted server never returns a pager VMO: the client copies the range into an anonymous VMO (02 §3.3).
- **NUMA placement:** `vmo_create` takes a placement: first touch (the default), one node, or interleaved across nodes. HPC programs place memory next to the cores they reserved (§8).
- **Cache policy per VMO:** write-back, write-combining, uncached or device. Mixing policies on one physical page is refused, because mismatched attributes on aarch64 are undefined behaviour.
- **Address spaces:**
  - `as_reserve` creates a *reservation*: placeholder address space with no commit, in the style of Windows placeholders (F-218). It normally picks a random base (ASLR). With `AS_FIXED` it takes the base the caller names. The flag is honoured in any task started with the `dev` policy, so a program can keep its memory at the same address across runs and across code reloads (03 §6.1); release services never get it.
  - `as_map` places a VMO *view* inside a reservation atomically, and `as_unmap` returns the range to the reservation. Emulators, JITs and GPU drivers need this.
  - **W^X:** a mapping may be writable or executable, never both. JITs map one VMO twice, once RW and once RX, at unrelated addresses.
  - arm64 BTI and PAC, and x86 CET shadow stacks, are enabled for user space from the start.
- **Page tables:**
  - x86_64 uses 4-level tables (5-level when the CPU supports LA57) with PCID.
  - aarch64 uses a 4 KiB granule, 48-bit virtual addresses, ASIDs and `TTBR0`/`TTBR1` split.
  - 2 MiB mappings are used opportunistically for large VMOs, and for the kernel's direct map.
  - A program can also *ask* for large pages: `as_map` with `PAGE_2M` or `PAGE_1G` either maps the view with that page size or fails, and never falls back silently. Game and engine arenas, model weights and GPU heaps use it. 2 MiB pages come from the `contiguous` pool. 1 GiB pages come only from a pool reserved at boot, because they cannot be assembled reliably later. Both are charged to the budget like any other.
  - TLB shootdowns are batched per `as_unmap` call.
- **Accounting:** every VMO is charged to a **memory budget** attached to a task group. GPU and NPU buffers count too, because on unified memory they *are* system memory (F-109). A budget has a limit and a pressure level (`normal`, `warn`, `critical`), and its pressure change can be bound to a port. `aid` uses this to unload models before the system has to kill anything.
- **Commit, not overcommit:** an anonymous VMO's size is charged to the budget when it is created or resized, and a copy-on-write clone is charged in full, as on Windows. A task that cannot get memory learns it from a failed call, never from a fault that kills it later. So `fork` of a large process can fail, and `posix_spawn` is the fast path (§9).

## 6. The zero-copy fabric

Data moves by **sharing or transferring pages**, never by copying, with two exceptions:
- payloads under about 4 KiB, where a copy is cheaper than setting up a mapping and the TLB shootdown that follows;
- crossing into a device that is not cache-coherent and has no IOMMU. Such a device gets a bounce buffer, flagged in `/dev/.../info` so the cost is visible.

### 6.1 The buffer: one currency (rule 7)

The kernel provides the pieces (VMO, Counter, DmaDomain). The convention that joins them, `vx-buffer`, lives in user space and is used by every subsystem:

```c
typedef struct vx_buffer {
    vx_handle      memory;      // Vmo: the pages
    vx_buffer_desc desc;        // format (DRM fourcc-compatible), modifier, planes[{offset, stride}], size, colour space
    vx_handle      timeline;    // Counter: acquire point = value before readers may start; release point = value after they are done
} vx_buffer;
```

The same `Buffer` is what:
- a camera driver produces;
- the video decoder, a Vulkan image import and an NPU tensor read;
- `winsrv` scans out;
- `netd` sends from, over TCP (and later RDMA).

Vulkan imports it with `VK_EXT_external_memory_*`, using a VectraOS handle type, and with timeline semaphores backed by the Counter.

### 6.2 Coherence domains

Each device the kernel knows about is tagged with one of three coherence domains:

| Domain | Examples | What the kernel does |
|---|---|---|
| **IO-coherent** | Unified-memory SoCs with a coherent interconnect (Apple M, Snapdragon X, AMD APUs); PCIe snooped traffic on x86 | Nothing. CPU and device see the same cache hierarchy. The Counter orders access. |
| **Non-coherent** | Many ARM SoC blocks: display controllers, some NPUs such as the RK3588's, camera ISPs | `dma_map` and the fence hand-off perform cache clean or invalidate over the VMO range. User space never issues cache instructions (the heritage "manual flush" warning). |
| **Device-local** | Discrete GPU VRAM | VRAM appears as a `DeviceLocal` VMO class owned by the GPU driver. CPU access, when needed, goes through a write-combining BAR mapping (resizable BAR). |

### 6.3 On a unified-memory SoC

```
 app (CPU)  ── writes into Buffer.memory ──┐
                                           │ same physical pages
 NPU  ◄── dma_map(DmaDomain[npu], vmo) ────┤ (SMMU / DART page tables)
 GPU  ◄── dma_map(DmaDomain[gpu], vmo) ────┤
 display ◄─ scanout plane ─────────────────┘
 ordering: timeline Counter  (app signals 1 → NPU runs → signals 2 → GPU runs → signals 3 → display latches)
```

No staging copies are made. A camera frame goes through NPU inference, then a GPU overlay, then scan-out, with **zero copies and zero CPU cache operations** on coherent parts. `dma_map` pins the pages, which counts against the budget, and returns an I/O virtual address the driver programs into the device.

### 6.4 On a traditional PC with a discrete GPU

- **Upload:** the app writes to a host-visible `Buffer` in system RAM, and the GPU reads it over PCIe through the IOMMU. This is host-pointer import, with `minImportedHostPointerAlignment` equal to the page size (F-108). Alternatively, the GPU driver copies into VRAM with its copy engine. That copy is done by the device, not the CPU, and is the only transfer the hardware requires.
- **Residency and migration:** the GPU driver process decides placement in VRAM or system RAM. The kernel still accounts the task's budget for both, so `VK_EXT_memory_budget` reports one figure.
- **Peer-to-peer (later):** a `DmaDomain` may map another device's BAR, so NVMe or NIC traffic goes straight to VRAM. That gives GPU direct storage and GPU-direct RDMA for `9px+rdma`, used by the swarm (02 §6).

### 6.5 Across the network

Over TCP, `netd` sends straight from the `Buffer` pages with scatter-gather and TSO, so there is no copy into a socket buffer. When the RDMA transport arrives (02 §3.2), `netd` and the NIC driver will register VMOs as RDMA memory regions, and a 9Px `Rread` will name a remote key and offset instead of carrying bytes.

## 7. User-space drivers

### 7.1 What the kernel provides

- `Irq` objects for legacy lines, MSI and MSI-X, one per line. Delivery is a port packet (`VX_TRIGGER_IRQ`, whose value counts the interrupts); a binding made after the line fired fires at once. A level-triggered line is masked when it fires and stays masked until the driver calls `irq_ack`. An edge-triggered line is never masked, because an edge that arrived while it was masked would be lost, and the device with it; its driver handles everything the device has pending before binding again. Lines are ISA IRQs (through the MADT's overrides) or GSIs on x86_64, routed through the IOAPICs, and GIC SPIs on arm64.
- MMIO through `vmo_create` of kind `physical`, mapped uncached as device memory. A physical VMO never covers RAM or firmware memory, which the kernel knows from the boot memory map.
- `IoRange` objects on x86. A task may use the ports once `as_map` has been called with the range in place of a VMO; they are loaded into each CPU's TSS I/O bitmap when the task's threads run there.
- These come from a `Resource`. Until `devmgr`, there is one, the root, which the kernel gives `svcd`; `svcd` mints each driver's objects from the `ioport=`, `mmio=` and `irq=` records of its manifest, keeps them, and gives every instance of the driver its own handles to them.
- **The kernel console:** the kernel writes to its early console until a driver is given that device. From then on the device is the driver's, the kernel keeps its output in an in-memory log (`kmesg`), and it writes to the device again only to report a panic. `vx.kconsole` on the command line keeps the kernel writing to it, for debugging.
- MSI and MSI-X through `Irq` objects too: `irq_create` with `VX_IRQ_MSI` and the PCI function's requester ID returns the address and data to program into the device. On x86_64 that is a local-APIC vector; on arm64 an LPI, which the kernel maps through the GIC's ITS (DeviceID = requester ID), set up the first time an MSI is made.
- `DmaDomain` objects for the IOMMU. Until the IOMMU drivers (M5), a domain is pass-through: `dma_map` holds the VMO and returns its pages' physical addresses, which is safe only with devices QEMU emulates.
- The firmware's ACPI tables, on both architectures (edk2 provides them on arm64 QEMU too): the kernel reads the MADT itself, and gives the root task every table, end to end, in a read-only VMO, which `svcd` passes to `devmgr`.
- On arm64, PSCI and SMC calls go through `svcd`'s platform service, never to drivers directly.

### 7.2 Enumeration and matching

1. `svcd` starts `devmgr` and hands it the `Resource` handle, the ACPI RSDP or DTB as a read-only VMO, and the boot framebuffer.
2. `devmgr` runs the **bus drivers**, which are ordinary processes:
   - `bus-pci` walks ECAM;
   - `bus-acpi` runs the AML interpreter in user space (ACPICA, vendored C, pinned and reviewed; a first-party AML interpreter is a later replacement);
   - `bus-dt` walks the device tree.

   Each one publishes device nodes, with properties, into `devmgr`.
3. Driver packages carry a **match manifest**:
   ```
   match  bus=pci vendor=0x1af4 device=0x1041      # virtio-net (modern)
   match  bus=dt compatible=arm,pl011
   driver binary=drv-virtio-net class=net intent=interactive restart=always
   ```
4. For each match, `devmgr` spawns the driver with **only** that device's MMIO VMOs, IRQs, `DmaDomain` and I/O ranges, plus a channel to `devmgr`.

In M3 the manifests are ndb records in the boot image, `/boot/drv/*.ndb`, one line per match: `match=pci vendor=0x1af4 device=0x1041 program=/boot/bin/drv-virtio-net post=ether0 msi=2`. A PCI driver gets the function's 4 KiB of configuration space, each memory BAR, the MSIs it asks for (with their address and data as records), a `DmaDomain`, and the server end of the post it serves. Posts are rendezvous points that `svcd` makes: `devmgr`'s manifest claims `ether0` (`claim=ether0`), a client's manifest connects to it (`connect=ether0`), and a client may connect before the driver is running. `devmgr` restarts a driver that exits, up to five times. Before it does, it turns off the function's bus mastering: in pass-through mode the device could otherwise write into the dead driver's freed DMA memory. The IOMMU (M5) closes the window between the driver's death and that write.

### 7.3 What a driver serves

- A **device-class tree** (02 §5). For example `drv-virtio-net` serves `/dev/net/ether0/{info,ctl,stats}` and exposes a ring pair for frames that `netd` connects to.
- The **net** class, as built in M3 (`lib/vx-driver/netproto.h`): a client opens a ring session on the driver's post (`/srv/ether0`; `lib/vx-ring/session.c`), one client at a time. `INFO` gives the MAC address and MTU; `TX` sends a frame from the client's arena; `RX` offers a slot of the driver's arena, and completes when a frame has been copied there. A frame that arrives with no slot offered is dropped, as a full NIC would drop it. The `/dev/net` tree comes with `netd`.
- Class protocols are specified once per class and versioned: `block`, `net`, `input`, `display`, `audio`, `accel`, `sensor`, `serial`.
- Serial drivers share `vx-driver`'s console server (`lib/vx-driver/cons.c`), which serves `/cons` with Plan 9's cooked semantics: echo, erase and kill-line, a read returns one line, and `^D` sends a line or, on an empty one, ends the file. A read with nothing typed, or a write with no room, is held by the 9Px server framework and answered after the driver's next interrupt makes progress. Programs whose manifest says `console` write to `/srv/cons` through `vx-rt`, a line at a time, and connect again if the driver restarts.
- Drivers are written against `vx-driver`, which provides typed MMIO register accessors (one header per device of `static inline` functions over `volatile` pointers), DMA pools over `Buffer`, IRQ-to-port glue, and the class-protocol server skeletons.

### 7.4 Crash, restart and hot reload

- **Supervision:** `svcd` watches every driver's task-exit packet. Its restart policy is `always`, `on-failure` or `never`, with exponential backoff, in the style of the MINIX 3 reincarnation server.
- **DMA safety on death:** all `DmaDomain` mappings and `Vmo` leases the dead driver held are revoked *before* its device is handed to the new instance. The IOMMU context is cleared and the device reset (FLR where supported), so a dying driver cannot leave the device writing to memory.
- **Client continuity:** clients hold their own buffers, because the arenas are client-owned. After a restart they re-attach and resubmit anything in flight, and class protocols require operations to be idempotent or tagged. A block write carries a sequence number; a dropped network frame is recovered by TCP. The client library hides this, and the application sees latency, not an error.
- **GPU drivers are the exception.** A restarted GPU driver has lost every GPU context, and Vulkan requires reporting that: applications see `VK_ERROR_DEVICE_LOST` and recreate their devices. `winsrv` and `vxui` do this themselves, so desktop apps survive. An engine that uses Vulkan directly must handle it, as it must on any OS.
- **Live update:** the new version is started alongside, and the old instance quiesces, finishing in-flight work and refusing new submissions. Optionally the old instance writes its state to a `handoff` VMO, then exits, and clients re-attach to the new one. This is how drivers are upgraded without a reboot.
- **Devices without an IOMMU** can only be driven by drivers marked `trusted` in `devmgr`'s policy. This is shown in `/dev/.../info` and in `/proc/N/status`, not hidden.

## 8. Scheduling

**Scheduling contexts:** each has a budget, a period, an intent and a CPU class mask derived from the intent. A thread runs only while its context has budget. Contexts can be donated through `channel_call` (§4.5).

**Intents (rule 6), and the policy behind each:**

| Intent | Policy | Example |
|---|---|---|
| `realtime(period, budget)` | EDF with an **admission test**: if the requested utilisation does not fit, the call fails with a reason; it never degrades silently. Unprivileged within a per-user real-time budget (F-215) | `audiod` mixer, audio callbacks, `winsrv` composition |
| `interactive-frame` | High-priority fair class; deadline hints from the frame clock; placed on performance cores | Game and app render threads |
| `interactive` | Fair class (EEVDF-like) with latency bias | UI threads, shells |
| `throughput` | Fair class; co-scheduled on one core type (F-204's llama.cpp case) | Compilers, inference batches |
| `background` | Idle-biased; placed on efficiency cores; timers coalesced aggressively | Indexing, sync, updates |

**The v1 implementation is small.** Each intent maps to a fixed priority band, and threads in one band share it round robin. `realtime` is a constant-bandwidth server behind the admission test: a thread that uses up its budget is throttled until its next period, so an admitted budget cannot be overrun. EDF, EEVDF-style lag tracking and frame-clock deadline hints wait until measurements from `audiod` and `winsrv` show they are needed (§13). The intents are the API; the policy behind them can change without breaking programs. On several CPUs (M1), every CPU serves one shared ready queue under one lock, each CPU keeps its own sleep queue and one-shot timer, a busy CPU runs user threads in 10 ms slices while an idle one stays tickless, and a thread made ready wakes an idle CPU with an inter-processor interrupt. Per-CPU ready queues with load balancing replace the shared queue when measurements show the lock contended.

**Heterogeneous cores:** the topology is published as data under `/sys/cpu` (02 §5), so programs read it instead of probing with `cpuid`. The kernel places threads by intent and utilisation, using the HFI and Thread Director tables on Intel hybrid parts and cluster capacities from the device tree on arm64. There are no affinity masks in the public API; `sched_ctx_configure` carries a kernel-internal mask for drivers that need a particular core.

**Core reservations:** a program that needs dedicated cores, such as a game engine's job system with one worker per core, reserves them. This is the only form of affinity a program can ask for:

```c
vx_status sched_reserve(vx_handle ctx, uint32_t count, vx_core_class cls, vx_domain domain, vx_reserve_flags flags, vx_core_set *out);
// cls:    VX_CORE_PERF | VX_CORE_EFF | VX_CORE_ANY
// domain: VX_DOMAIN_ANY, or an llc= or numa= id from /sys/cpu/topology
// flags:  VX_RESERVE_NO_SMT_SIBLINGS | VX_RESERVE_SAME_LLC
```

- **Granted or refused, never degraded.** Like the real-time admission test, the call grants whole cores or fails with a reason ("only 5 performance cores can be reserved").
- **Reserved cores are quiet:** no other user threads, IRQs steered elsewhere, and no timer tick while one thread runs there. That is what Linux's `isolcpus` and `nohz_full` provide, but requested per program.
- **Binding within the grant:** the program binds one thread to each granted core (`sched_ctx_bind` with a core from `out`). That is the only place a thread names a core.
- **Locality:** `/sys/cpu/topology` names the cores that share a last-level cache (`llc=`) and the cores on each NUMA node (`numa=`). A game on a Ryzen X3D part reserves on the V-Cache chiplet's `llc`; an MPI rank reserves on one `numa` node and places its memory there (§5).
- **Games usually should not reserve.** A game's frame depends on other processes, not just its own threads: `drv-gpu`, `winsrv`, `audiod`, the input driver and `netd`. Reserving all but one performance core leaves those sharing one core, and frame times spike. Games use `interactive-frame`. Reservations are for HPC, benchmarks and programs that own the whole machine.
- **Limits:** at least one performance core always stays shared, so `winsrv`, `audiod` and the shell never starve. There is a per-user quota, like the real-time budget, and on battery `/sys/power` policy can refuse new reservations.
- **Visible and scoped:** grants appear in `/sys/cpu/topology` (`reserved=42`) and in `/proc/N/status`, and are released when the task exits.

**SMT and trust:** threads from different trust domains, such as different swarm users' jobs, never run on the two SMT siblings of one core at the same time, as with Linux core scheduling. Leaks between siblings of the MDS and L1TF class make this necessary once a node runs other people's work.

**Timers and wake-ups:** the kernel is tickless. The next timer event is set from the earliest (deadline + leeway) on each CPU. A `realtime` or `interactive-frame` wait gets near-zero leeway by default, and `background` waits get up to 10% of the interval.

**Hierarchy:** hierarchical budgets per task group, a subset of cgroup semantics, are how `svcd` and `swarmd` enforce "this job may use 4 cores and 8 GiB". They are also the mechanism behind leases in the swarm pool (02 §6.4).

## 9. The POSIX personality

This is how LLVM, Python and Git run without touching the kernel.

```
  app ──► musl libc (unchanged API) ──► vx back end (replaces __syscall)
                                          │ fd table lives in the process (as in fdio)
          fd → { 9Px fid on a ring | socket (/net fid) | pipe ring | pty fid | event port }
                                          │
          process-model calls ──9Px files──► procfs   (/proc/N: status, ctl, note, notepg, wait)
```

| POSIX area | Implementation |
|---|---|
| `open` `read` `write` `stat` `readdir` | In-process: `libns` resolves the path to a mount, then 9Px `walk`/`open`/`read` over that mount's ring. `read` and `write` on a local mount cost no kernel entry while the ring is busy. |
| Open-file descriptions | An fd refers to an open-file description, kept by the server with the fid: the offset, `O_APPEND` and the status flags. `fork`, `dup` and fd passing share it, as POSIX requires, so `(a; b) > f` and concurrent appends to one log behave. This needs the `posix` 9Px extension (02 §3.3). |
| `rename` `link` `symlink` `fcntl` locks `fsync` | The `posix` 9Px extension, which uses 9P2000.L's messages for these unchanged. 9P2000 alone can only rename within one directory, and Git renames objects across directories. |
| `mmap` of a file | 9Px `Tmap` returns a pager-backed VMO cap (02 §3), and libc maps it. `MAP_SHARED` is coherent through the page cache in `fsd`. |
| `pipe` | A ring between two processes, owned by libc. `procfs` is not involved. |
| sockets | The BSD socket calls translate to `/net/tcp/clone` and the files in the connection directory, as Plan 9's APE does. The data path is `netd`'s rings. |
| `poll` `select` `epoll` `kqueue` | All built on the one port. Each fd type knows how to bind its readiness source. A 9Px fid is readable only once a read has returned, so libc keeps one read-ahead request outstanding per polled fd and buffers its reply. |
| `fork` | libc asks the kernel to clone the address space copy-on-write, duplicates the handle table (with inheritance rules), and copies the fd table in libc. Ring mappings are not inherited: the child's first use of a connection opens a new ring, because a copied ring is broken and a shared one would have two producers. `fork` is correct but not fast; `posix_spawn` and `vfork`-then-`exec` have a fast path that never clones. |
| `exec` | Implemented in the library. The ELF loader in `libvxrt` builds the new image in a scratch task, and `task_exec` moves it into the caller, which keeps its task, and so its pid, parent and registration (ADR-0012), as 9front's `exec` keeps the `Proc`. |
| process calls | `getpid`, `kill`, `killpg`, `setpgid`, `setsid` and `waitpid` are reads and writes of `/proc/N/{status,note,notepg,ctl,wait}`, as 9front's APE does (ADR-0011). Process groups are note groups. |
| signals | Signals are built on notes (ADR-0010). `kill` writes a note; the kernel delivers it by `thread_interrupt`, which diverts a thread to the back end's note handler. That handler maps the note to a signal and applies the masks, pending sets and `SA_RESTART` kept in libc. A note at a blocked 9P call flushes it with `Tflush`. Synchronous faults arrive through the task's exception port and are turned into `SIGSEGV`, `SIGFPE` and so on. A handler never runs in the middle of a ring submission: the client library blocks signals for the few instructions of a submit, so a handler that calls `write()` cannot corrupt the ring. |
| ttys and ptys | `ptyd` serves `/dev/pty`. Line discipline is in the server. The output path is a pass-through: with output processing off, `ptyd` forwards the writer's buffers to the terminal's ring without touching each byte, and with `ONLCR` on it scans for newlines only. `ptyd` sits on the path of the terminal throughput budget (00 §8), as conhost did in refterm's measurements. |
| `/proc`, `/dev/null`, `/dev/urandom`, `/tmp`, uids | Served by ordinary servers and bound into the POSIX namespace template (`/lib/ns/posix`). |
| threads | pthreads on kernel threads; futexes are the kernel's futex calls (§4.6). |

**Faults handled in the task.** Emulators such as Dolphin and RPCS3 map guest memory into large reservations and handle thousands of page faults a second themselves ("fastmem"). A trip out to an exception port and back through a server would cost several context switches each. So `exception_bind` has an in-task mode: the kernel diverts the faulting thread to a handler in its own task, with the fault's registers on a handler stack, and the handler resumes with `exception_resume`. Faults go first to a debugger that asked for first chance (05 §2), then to the in-task handler, then to the exception port, then to default handling.

**Targets, in order:** a BusyBox-class userland, then Lua, then Python 3, then Git, then clang and lld, then **VectraOS rebuilding itself** with its own `build` (04 §6, M10).

## 10. Boot sequence

1. Firmware (UEFI or BIOS) loads **Limine**, which loads the kernel ELF and modules, sets up the higher-half direct map, and passes the memory map, framebuffer, RSDP or DTB, and SMP information. With Secure Boot on, Limine is signed, and the hash of its config is enrolled into the binary. The config gives the BLAKE2B hash of the kernel and of every module, so the firmware's measurement of Limine into TPM PCR 4 covers the whole chain. `keyd` seals keys to those PCRs (02 §6.2).
2. The kernel sets up its page tables, physical allocator, per-CPU data, interrupt controller (APIC or GICv3), timer (TSC deadline or the arm generic timer) and IOMMU (on from the start in deny-all mode, with identity maps only for regions the firmware reserves, such as VT-d RMRRs and IORT RMRs; no device can DMA until `devmgr` gives it a `DmaDomain`, which closes the window that Thunderbolt and USB4 DMA attacks use), and brings up the other CPUs.
3. The kernel creates the root task, `svcd`, from the `svcd` module. Its spawn message (§3) carries a handle to the task itself, the boot image (the `bootfs.tar` module, as a read-only VMO), the ACPI tables, the root `Resource` and the kernel command line; the framebuffer VMO joins them when its user does. Until there is a debug-log object, permission to write the kernel log is a task flag that a task's children inherit, so services can report before the console moves to user space (04 §5, M2).
4. `svcd` reads the manifests in `boot/svc/*.ndb` from the boot image itself, since the server for it is one of the services it starts. It starts `bootfs` (the boot image as a read-only 9Px tree), `devmgr`, drivers, `netd`, `nsd`, `procfs` and the rest, each with only the handles and namespace its manifest names, and restarts those marked `restart` when they exit. It then starts the console shell on `/dev/cons`.

## 11. Security hardening checklist

- **Kernel:** KASLR; SMEP, SMAP, UMIP / PAN, PXN; x86 CET-IBT and arm64 BTI in the kernel; guard pages on kernel stacks; no RWX mappings.
- **Compiler:** `-fsanitize=kcfi`, `-fstack-protector-strong`, `-ftrivial-auto-var-init=zero`; the debug kernel traps on undefined behaviour (04 §1.2).
- **Speculative execution:** per-CPU mitigations are selected at boot and reported in `/sys/cpu/vulns`. There is no global KPTI on CPUs that are not affected.
- **Randomisation:** ASLR in user space (handle values are deterministic, §3). A stack canary and W^X in every binary we build.
- **Shared-memory discipline:** the rules in §4.3, enforced by the `vx-ring` library, which gives servers a copy-on-read API only.
- **DMA:** the IOMMU is in deny-all mode from kernel entry (§10). Pass-through exists only under QEMU, for M3 (04 §5).
- **FP/SIMD:** each thread's x87/SSE (FXSAVE) or arm64 FP/SIMD registers are saved and loaded at every switch between threads, so no task reads another's. The kernel itself is built `-mgeneral-regs-only` and never touches them. AVX, SVE and SME stay turned off, and fault, until their larger state is saved too.
- **Failure is never success:** a nil object's methods return `VX_ERR_NIL`, never zero, and the kernel and authorization paths do not use nil objects at all (04 §1.1).
- **Secrets stay out of dumps:** `NODUMP` VMOs are never written to crash directories, and `keyd` and `tlsd` are never dumped (05 §5).
- **SMT isolation** between trust domains (§8).
- **Fuzzing:** the 9Px parser and the class protocols are fuzzed continuously by an in-tree harness built with clang's `-fsanitize=fuzzer` (libFuzzer from compiler-rt). Syscalls are fuzzed from a hostile user task under QEMU (a syzkaller-style harness, later).

## 12. Performance budgets

These are targets, measured in CI under KVM and on T1 hardware from M6 onward. The end-to-end budgets a user feels are in 00 §8.

| Operation | Target |
|---|---|
| Null syscall round trip (x86_64), mitigations off | < 100 ns |
| Null syscall round trip (x86_64), with the mitigations the CPU needs (§11) | Measured and published per CPU model in CI; no target until M2 gives a first number |
| Ring submit plus completion, both sides busy, cross-core | < 300 ns, no syscalls |
| `ring_notify` to the peer's `port_wait` returning, cross-core | < 2 µs |
| `channel_call` round trip, same core, with context donation | < 1 µs |
| IRQ to the driver thread running (modern x86) | < 5 µs |
| `port_wait` deadline accuracy, p99, interactive intent, idle core | < 100 µs (F-203) |
| 4 KiB 9Px read from a local ramfs over a ring | < 2 µs |

## 13. Open questions

1. **Scheduler policy after v1.** v1 is priority bands plus a constant-bandwidth server (§8). Is pure EDF for `realtime` with EEVDF elsewhere worth its code, or one EEVDF with deadline hints? Both need to be prototyped and measured with `audiod`.
2. **Revocation.** Are leases plus proxies enough for delegating to agents (02 §7), or do we need derivation-tree revocation?
3. **Channel message cap.** Is 64 KiB right? Zircon uses 64 KiB, seL4 uses about 480 bytes in registers. Measure what `procfs`, `nsd` and `devmgr` actually send.
4. **SMP scalability of the handle table.** Use a per-task RCU table or a sharded lock? Decide once `fork` pressure shows up at M4.
5. **Donation on rings.** A ring's class comes from the kernel-stamped intent of the client that asked for it (§4.3), so a client cannot claim a better class. Is serving in class order enough to prevent priority inversion in servers, or do servers need to borrow the client's scheduling context, as `channel_call` does?
