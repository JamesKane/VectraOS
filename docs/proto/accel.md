# The `accel` class protocol

Status: draft, written before M7 (ADR-0018). Frozen when M7 lands, with Venus as its first user. Each vendor's ADR defines the vendor parts (§7) before its driver is written.

`accel` is how a GPU's user-space Vulkan driver (Mesa, in the client's process) reaches the `drv-gpu-*` that owns the hardware. It is one protocol for every vendor, shaped like Fuchsia's Magma: the driver sets up address spaces, buffers and queues, and the client builds the command streams. Sync is explicit only: GPU work waits on and signals timeline `Counter`s (01 §4.4), and nothing else.

## 1. The client code that uses it

Each Mesa driver gets one backend at the seam it already has for kernel interfaces (ADR-0018 §2). No Mesa code above that seam changes.

| Mesa driver | Its seam | Our backend | Needed by |
|---|---|---|---|
| Venus (virtio-gpu) | `vn_renderer` (`src/virtio/vulkan/vn_renderer.h`), beside `vn_renderer_virtgpu.c` and `vn_renderer_vtest.c` | `vn_renderer_accel.c` | M7, first user |
| Turnip (Adreno) | `tu_knl` (`src/freedreno/vulkan/tu_knl.h`), beside its msm, KGSL and virtio back ends | `tu_knl_accel.cc` (Turnip is C++, 04 §1) | the Q8B (T1) |
| Asahi (AGX) | `agx_device` (`src/asahi/lib/`), which already has a virtio back end | `agx_device_accel.c` | its vendor ADR |
| NVK (NVIDIA) | `nvkmd` (`src/nouveau/vulkan/nvkmd/`), beside its nouveau back end | `nvkmd/accel/` | its vendor ADR |
| panvk (Mali) | `pan_kmod` (`src/panfrost/lib/kmod/`), beside panfrost and panthor | `pan_kmod_accel.c` | its vendor ADR |
| Rocket (Rockchip NPU), under the Teflon delegate | its kernel calls in `src/gallium/drivers/rocket/`, which today speak Linux's `accel/rocket` | an `accel` backend in the same directory | if a Rockchip NPU board is in a tier (ADR-0023 item 9) |
| RADV (AMD) | `radv_winsys` (`src/amd/vulkan/winsys/`), beside amdgpu and null | `winsys/accel/` | its vendor ADR |

Each backend is a patch to the Mesa import, counted in the ledger (04 §3.2) and offered upstream.

## 2. Where it is served

- A driver for device N posts its listen channel as `/srv/gpuN` and serves its tree at `/dev/accel/gpuN/` (02 §5.3). `info` there holds the same facts as `INFO` (§4.1) as ndb text, for scripts and for discovery. The Vulkan loader enumerates GPUs by reading `/dev/accel/*/info` and dials only the ones with `kind=gpu`.
- A client opens a **session** with `vx_session_dial` (`lib/vx-ring/session.c`), ordinal `VX_ACCEL_CONNECT`. Each session is its own ring, so each queue has one producer (01 §4.3). A driver serves any number of sessions. One Vulkan `VkDevice` is one session.
- A session owns everything made through it. When its ring's peer closes, the driver frees all of it: queues stop, bindings go, leases are revoked (01 §3). When the driver's end closes (the driver crashed or restarted), the client reports `VK_ERROR_DEVICE_LOST` for that device (01 §7.4).
- Sessions are local. A remote GPU (02 §6) is reached through its tree, not through `accel` rings across the network.

Ring parameters (`VX_ACCEL_PARAMS`):

| Field | Value | Why |
|---|---|---|
| `sq_entries`, `cq_entries` | 256 each | binds and submits in flight together |
| `sqe_size`, `cqe_size` | 64 and 32, the generic `vx_sqe` and `vx_cqe` | |
| `client_arena` | 1 MiB | bind lists, submit records and vendor payloads, written by the client |
| `server_arena` | 64 KiB | `INFO` answers and event records, written by the driver |

## 3. Objects and ids

A session holds four kinds of object, each named by a 32-bit id **the client chooses**, as 9P's fids are. So a client can make an object and use it in the next entry without waiting for a completion. Id 0 is never valid. Ids of different kinds are separate spaces. Reusing a live id is `ERR_EXISTS`.

| Kind | Is | Made by |
|---|---|---|
| buffer | memory the GPU can reach | `BUFFER_IMPORT` (RAM), `BUFFER_NEW` (device memory), `BUFFER_JOIN` (shared) |
| vm | a GPU address space | `VM_NEW` |
| queue | a firmware queue (§5) | `QUEUE_NEW` |
| sync | a `Counter` the driver may wait on or signal | `SYNC_IMPORT` |

**Memory in RAM is always the client's.** A RAM buffer is a VMO the client created, so it is charged to the client's memory budget (01 §5), and on unified memory that is all memory. The driver maps it into the device's `DmaDomain` and pins it against the client's pin budget. **Device memory is the driver's**: VRAM on a discrete GPU, or a host-visible region the device provides (virtio-gpu's shared memory). The driver charges it to a per-session device budget, reported in `INFO` (§4.1) and in `/dev/accel/gpuN/N/mem`, and refuses an allocation past it with `ERR_NO_MEMORY`.

## 4. Operations

Every operation is one `vx_sqe`. `opcode` is below; `target` is the object's id. Every entry is completed exactly once, with `result` 0 or more on success and a negative `vx_status` on failure. A client keeps no more entries outstanding than the completion queue holds (as `net`, 01 §7.3). Records in the client arena are named by `arena_off` and `len`, with `VX_SQE_DREF`; handles go with `VX_SQE_HANDLES` (01 §4.3).

**Entries are processed in ring order.** An entry sees every earlier entry's effect: a `SUBMIT` after a `VM_BIND` runs with that binding in place, without waiting for the bind's completion. A failed entry does not stop later ones unless it was `VX_SQE_LINK`ed to them.

| Opcode | `target` | In | Completion |
|---|---|---|---|
| `INFO` 1 | — | — | `result` the record's length; `aux2` its offset in the server arena (§4.1) |
| `BUFFER_IMPORT` 2 | buffer id | handle: a VMO; `inline_data`: `flags[4]` | 0. A VMO with a cache policy the device cannot use is `ERR_INVALID` |
| `BUFFER_NEW` 3 | buffer id | `offset`: size; `inline_data`: `heap[4] flags[4]` | 0, and with `HOST_VISIBLE` a handle slot in `aux`: a lease of the buffer's CPU window |
| `BUFFER_SHARE` 4 | buffer id | `inline_data`: `holds[4]` | `aux2`: offset of a 16-byte token in the server arena, good for `holds` joins |
| `BUFFER_JOIN` 5 | new buffer id | `inline_data`: `token[16]` | 0; the buffer in this session is the shared one |
| `BUFFER_FREE` 6 | buffer id | — | 0, once no binding and no queue uses it (§4.2) |
| `VM_NEW` 7 | vm id | — | 0. `ERR_UNSUPPORTED` where `INFO` says `HOST_VM` |
| `VM_BIND` 8 | vm id | client arena: an array of bind records (§4.2) | the count of records applied |
| `VM_FREE` 9 | vm id | — | 0, once no queue uses it |
| `SYNC_IMPORT` 10 | sync id | handle: a `Counter` | 0 |
| `SYNC_FREE` 11 | sync id | — | 0 |
| `QUEUE_NEW` 12 | queue id | client arena: a queue record (§4.3) | 0; with `USER_MODE`, handle slot in `aux` (§5) |
| `QUEUE_FREE` 13 | queue id | — | 0, once its work has finished or been cancelled |
| `SUBMIT` 14 | queue id | client arena: a submit record (§4.4) | 0 once the driver has handed the work to the firmware. That is acceptance, not completion: completion is the signal `Counter`s |
| `EVENT` 15 | slot | — | when an event happens: `result` its length, `aux2` its offset (§4.5) |

### 4.1 `INFO`

A client asks first, and again whenever it wants current budgets (for `VK_EXT_memory_budget`). The record, little-endian:

```
version[4]        accel protocol version: 1
vendor[4]         PCI vendor ID: 0x106b Apple, 0x10de NVIDIA, 0x13b5 Arm, 0x1002 AMD, 0x1af4 virtio
device[4] revision[4]
flags[4]          UMA 1 · COHERENT 2 · USER_QUEUES 4 · HOST_VM 8 (the device manages its own addresses: Venus)
device_uuid[16]   what VkPhysicalDeviceIDProperties reports (03 §3)
driver_uuid[16]   changes with the driver build; keys the pipeline cache (03 §3)
va_base[8] va_size[8]   the range a vm's bindings may use
page_size[4]      binding granularity, a power of two, at least 4096
timestamp_ns[4]   nanoseconds per GPU timestamp tick, as a 16.16 fixed-point number
n_heaps[4] n_families[4] vendor_off[4] vendor_len[4]
heaps[n_heaps]    { size[8] used[8] budget[8] flags[4] pad[4] }
                  flags: DEVICE_LOCAL 1 · HOST_VISIBLE 2 · HOST_COHERENT 4 · HOST_CACHED 8 · RAM 16
families[n_families]  { kind[4] count[4] }   kind: GRAPHICS 1 · COMPUTE 2 · COPY 3 · VIDEO_DECODE 4 · VIDEO_ENCODE 5 · NPU 6
vendor block      vendor_len bytes at vendor_off, defined by the vendor ADR (§7)
```

A heap with `RAM` is filled by `BUFFER_IMPORT`; any other heap by `BUFFER_NEW`. `used` and `budget` are this session's.

### 4.2 Buffers and bindings

- **Flags** (`BUFFER_IMPORT`, `BUFFER_NEW`): `HOST_VISIBLE` 1, `WRITE_COMBINE` 2, `UNCACHED` 4, `PROTECTED` 8 (refused unless `INFO`'s vendor block offers it). The CPU window's cache policy is the VMO's own (01 §5), so it can never disagree with the CPU's mapping.
- **Sharing** across sessions and processes uses a token, as the `posix` extension's `Tshare` and `Tjoin` do (`docs/proto/posix.md`). A RAM buffer can also be shared as its VMO, which is how a `vx-buffer` (01 §6.1) carries it to `winsrv`, the video decoder or `netd`. Sharing a device-memory buffer with anything but another session of the same driver goes through a RAM copy for now (§8, question 1).
- **A bind record**, 40 bytes:

```
op[4]       MAP 1 · UNMAP 2
flags[4]    READ 1 · WRITE 2 · EXEC 4 · UNCACHED 8
buffer[4]   buffer id (MAP only)
pad[4]
buffer_off[8]  va[8]  size[8]   page-aligned
```

  Records apply in order. A record that fails stops the batch: `result` is the count applied before it, and `aux` holds the failed record's `vx_status` (0 when all applied). Mapping over a mapped range is `ERR_EXISTS`: unmap first. Unmapping memory that queued work still uses is the client's error, as it is in Vulkan, and shows up as a fault (§4.5), never as a use of freed memory: a buffer is not freed while a binding or a queue holds it.
- Sparse binding on a queue's timeline (binds that wait on and signal `Counter`s) is not in version 1. The Vulkan profile does not require it.

### 4.3 Queues

A queue record:

```
vm[4]        vm id; 0 where INFO says HOST_VM
family[4]    a kind from INFO's families
priority[4]  LOW 0 · NORMAL 1 · HIGH 2 · REALTIME 3; capped by /dev/accel/gpuN/ctl's priority classes,
             and REALTIME only for a session whose ring has a real-time service class (01 §4.3)
flags[4]     USER_MODE 1: ask for a user-mode queue (§5)
desc_len[4]  pad[4]
desc[desc_len]   the vendor's queue descriptor (§7)
```

A `USER_MODE` request on a device or family without user-mode queues is `ERR_UNSUPPORTED`, so a client always knows which kind it got.

### 4.4 Submitting

A submit record:

```
n_wait[4] n_signal[4] payload_len[4] pad[4]
waits[n_wait]      { sync[4] pad[4] value[8] }   start when each Counter is at least value
signals[n_signal]  { sync[4] pad[4] value[8] }   set each Counter to value when the work is done
payload[payload_len]   the vendor's command payload (§7): command buffer addresses, a Venus stream
```

- The driver binds a `COUNTER_GE` on each wait (01 §4.4) and hands the work to the firmware only when all have fired. The client never waits on the CPU to order GPU work.
- When the firmware reports the work done, the driver signals each `Counter`. A `Counter` cannot go backwards, so a value below the current one is `ERR_INVALID` at submit time.
- Work on one queue runs in submit order. Order across queues comes only from `Counter`s.
- There is no implicit sync: a buffer's `vx-buffer` timeline is just another `Counter`, imported with `SYNC_IMPORT` and named in waits and signals like any other.

### 4.5 Events

A client keeps one or more `EVENT` entries outstanding, each offering a slot of the server arena (`target`, 0 to 31, 256 bytes each), as `net`'s `RX` offers slots (01 §7.3). The driver completes one when something happens, and writes the record:

```
kind[4]   FAULT 1 · RESET 2 · LOST 3 · BUDGET 4
queue[4]  the queue it concerns, or 0
FAULT:    va[8] access[4] (READ 1 · WRITE 2 · EXEC 4) vendor_len[4] vendor[…]
RESET:    guilty[4]   1 if this queue's work caused it
LOST:     —           the whole session is lost: every queue is stopped
BUDGET:   heap[4]     a heap's budget changed; INFO again for the numbers
```

After `FAULT` or `RESET`, the queue is stopped: every later `SUBMIT` to it is `ERR_BAD_STATE`, and its pending signals are never signalled. The client frees it and reports `VK_ERROR_DEVICE_LOST`. Events that arrive with no slot offered are kept, at most 32 per session. Past that, the session gets `LOST`.

## 5. User-mode queues

Where `INFO` says `USER_QUEUES` and `QUEUE_NEW` asked for `USER_MODE`, the driver creates the queue through the firmware and gives the client, in the completion's handle slot:

1. the queue's ring memory, a VMO in the client's own address space and charged to it;
2. the doorbell, a one-page `Vmo` lease of the device's doorbell range;
3. optionally, a fence page the firmware writes completed values to, as the vendor ADR says.

The client writes commands to the ring and rings the doorbell itself. `SUBMIT` to that queue is then `ERR_BAD_STATE`, because the driver is not on the submission path. Waits and signals follow the vendor's mechanism, given in its ADR: the hardware waiting on fence memory, with the driver signalling the `Counter`s from the firmware's interrupts. On a reset, driver restart or `QUEUE_FREE`, the leases are revoked first (01 §7.4), so a client can never ring a doorbell that now belongs to someone else.

This needs a `Vmo` lease that covers one page of a physical VMO. 01 §3 does not yet say whether a lease can be narrowed to a range. The first vendor ADR with user-mode queues settles it.

## 6. Constants

```c
enum : uint32_t { VX_ACCEL_CONNECT = 0x6c63'6361 };  // "accl": the listen channel's one ordinal
enum : uint16_t {
  VX_ACCEL_INFO = 1, VX_ACCEL_BUFFER_IMPORT, VX_ACCEL_BUFFER_NEW, VX_ACCEL_BUFFER_SHARE,
  VX_ACCEL_BUFFER_JOIN, VX_ACCEL_BUFFER_FREE, VX_ACCEL_VM_NEW, VX_ACCEL_VM_BIND, VX_ACCEL_VM_FREE,
  VX_ACCEL_SYNC_IMPORT, VX_ACCEL_SYNC_FREE, VX_ACCEL_QUEUE_NEW, VX_ACCEL_QUEUE_FREE,
  VX_ACCEL_SUBMIT, VX_ACCEL_EVENT,
};
static constexpr uint32_t VX_ACCEL_EVENT_SLOTS = 32, VX_ACCEL_EVENT_SLOT = 256;
```

They go in `lib/vx-driver/accelproto.h`, as `net`'s are in `netproto.h`.

## 7. What each vendor ADR defines

Exactly four things, and nothing else may vary by vendor:

| Part | Carried in | Example |
|---|---|---|
| The `INFO` vendor block | §4.1 | AMD: the GFX IP version, CU count, tiling configuration that RADV reads from `amdgpu_gpu_info` today |
| The queue descriptor | §4.3 | NVIDIA: the engine class for the GSP to create a channel of |
| The submit payload | §4.4 | AGX: the render and compute command layouts; Venus: the encoded Vulkan stream |
| The fault detail | §4.5 | the engine and client unit that faulted; Adreno: the SMMU's FSR and FSYNR |

A vendor whose hardware needs anything more (a new operation, a second kind of sync) amends this protocol with a new version. It does not get a side channel.

**Venus**, the first user, shows the range. `INFO` says `HOST_VM`, since the host's driver manages GPU addresses, so there are no vms and no bindings. Host-visible device memory is `BUFFER_NEW` in the heap the virtio shared-memory region backs, and its CPU window is a lease of that region. The vendor block is the Venus capability set, the queue descriptor names the Venus ring, and the payload is the encoded command stream.

## 8. Open questions

1. **Device memory in a `vx-buffer`.** A RAM buffer is its VMO. A VRAM buffer has no VMO a third party can use, except through a resizable BAR, and even then `winsrv` on another device cannot read it. Version 1 copies through RAM. The first discrete vendor (NVIDIA) decides whether `vx-buffer` gains a device-memory form, such as a token with the device UUID, or whether peer `DmaDomain` mappings (01 §6.4) cover it.
2. **Narrowed leases** (§5): a lease of one page of a physical VMO.
3. **Sparse binding** (§4.2): left out until an app needs it under the profile.
4. **Conformance:** every protocol here has a suite run against our client and our server (04). For `accel`, the server side is a fake driver in `tests/host/` that keeps buffers, bindings and `Counter`s in software, so the Mesa backends are tested without hardware.
