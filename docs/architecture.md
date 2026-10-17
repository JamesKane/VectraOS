# Architecture

## 1. Layers

```
 apps (Swift tier 1, Wasm)        games · Tracker · terminal · tools
 ───────────────────────────────────────────────────────────────────
 SDK                               VX (core) · VXUI · VXCompute · VXData
 ───────────────────────────────────────────────────────────────────
 services (Embedded Swift, tier 0) namespace · launch · devmgr · Taisce
                                   Radharc · router · net · 9gate · accel
 drivers (user processes)          virtio · nvme · uart · qcom-* · adreno · cdsp
 ───────────────────────────────────────────────────────────────────
 control plane: Node protocol over channels   data plane: SPSC rings in VMOs
 ───────────────────────────────────────────────────────────────────
 kernel (croi, slimmed)            address spaces · threads + scheduling contexts
                                   handles/rights · VMOs · channels · ports
                                   counters · futexes · IRQs · IOMMU/BTI · trace
 ───────────────────────────────────────────────────────────────────
 boot                              UEFI loader → handoff v5 → kernel (ACPI only)
```

The two code tiers come from todhchai:
- **Tier 0** is Embedded Swift with `-strict-memory-safety`, no ARC, no
  existentials and no allocation on hot paths. It covers the kernel,
  services, drivers, the file system and every real-time path.
- **Tier 1** is full Swift. It covers apps, kits and host tools.

## 2. Kernel

The kernel is croi, imported whole in V0 and then slimmed in V1 (D2). Its
target role is principle 4: a setup engine.

**Kept:**
- handles with index, generation and rights;
- VMOs and VMARs;
- jobs, processes and threads;
- scheduling contexts (EDF with CBS, admission control, deadline donation);
- channels, for small messages and handle transfer;
- ports, the only wait primitive;
- counters, for ring doorbells and timeline fences;
- futexes;
- timers and clocks;
- interrupts and MSI;
- IOMMU, BTIs and contiguous or physical VMOs;
- resources;
- the pager;
- exceptions;
- debuglog and trace.

**Candidates to cut in V1**, each confirmed by an entry in the decision log:
- **Sockets, streams and FIFOs.** Rings replace them.
- **Eventpairs and events.** Counters and port packets may cover them.
- **The display timeline.** It becomes a counter.
- **Any syscall that duplicates a batched form.** The audit
  (`docs/syscall-audit.md`) settles each one.

The syscall count is published and capped. The cap only ever goes down
(performance.md, "Size").

The kernel stays ACPI-only. The Q8B's firmware provides UEFI and ACPI, and
AbyssBSD boots it that way, so no devicetree path is needed for the first
hardware target. A DT-only board later would need its own ADR. The rv64
board, the Orange Pi RV2, is one: its firmware gives a devicetree, and
how it meets ACPI-only is open in D51.

## 3. The data plane: one ring

Every bulk path uses one ring layout. It lives in a VMO that both sides map.

```
offset 0     producer cursor  (u64, written by producer, release)
offset 8     producer waiting (u32: it sleeps until its doorbell rings)
offset 128   consumer cursor  (u64, written by consumer, release)
offset 136   consumer waiting (u32)
offset 256   header: magic, version, flags, slot size (multiple of 8),
             slot count (power of 2), format descriptor
offset 384+  slots[count]     (fixed size; payloads in the IPC wire format
                               or raw bytes, per the format descriptor)
```

- **Cursors** are free-running 64-bit counters, so the index is
  `cursor & (count-1)`. Each cursor sits alone on a 128-byte line, which
  avoids false sharing on both 64-byte and 128-byte line machines.
- **The producer** writes the slot, then store-releases the producer cursor.
  **The consumer** load-acquires the producer cursor, reads the slot, then
  store-releases the consumer cursor.
- **Doorbells** are kernel counters, signalled only when the other side has
  declared that it is waiting: a side about to sleep sets its waiting
  word, fences and looks again; the other fences after moving its cursor
  and rings only if the word is set. While both sides are busy, the ring
  costs no syscalls; the `ring_kicks = 0` budget checks this.
- **OVERWRITE** (a header flag, D38): the producer never waits and
  readers keep their own cursors; each slot starts with its sequence,
  which a reader checks before and after its copy.
- **BYTE_STREAM** (a header flag, D46): each slot is a length, flags and
  that many bytes, so a writer puts any amount and a reader takes any
  amount (a slot in more than one read, each byte copied out once); the
  end of input is a slot flagged END, after the last bytes. stdio, pipes
  and the pty use it.
- **Large payloads** travel by reference. A slot carries the offset and
  length within a shared data VMO, as in sDDF's available and free queues.
  A request/response service uses a pair of rings, SQ and CQ.
- **Implementations:** one in Swift and one C23 header, `ring.h`, for
  C-side drivers (`lib/ring/`, D43). Both are tested against the same model
  checker, RingCheck, which runs the real code of each. The model test
  comes from NeoVectra's `lib/vx-ring`.
- **The kernel as producer:** the debuglog, in OVERWRITE mode (D38), and
  ports made with CROI_PORT_RING, whose packets it writes into a ring the
  reader drains with no syscall; port_wait is that reader's sleep (D44).

## 4. The control plane: the Node protocol

The protocol is todhchai's (D3). Every service exposes a 9P-shaped node tree
with `walk`, `stat`, `readdir`, `read`, `write`, `watch`, `create` and
`remove`, sent as batches: one message runs several on a current node, as
NFSv4's COMPOUND does (D18, D64). Typed interfaces are declared in Swift
with `@IPCLibrary`, which generates zero-allocation Embedded-safe stubs.
`idlc` emits the C headers and enforces ABI baselines. Cancellation follows
Plan 9's Tflush rule.

- **Namespaces** are per process, map paths to channels, and have no global
  root. Bind and union are resolved on the client side. A sealed namespace is
  the sandbox.
- **Rings are attached to nodes.** A client makes a ring pair and its data
  VMO and attaches them, with their doorbell counters, to a node its
  channel is at (Node's `attach`, D67). That exchange is the only way a
  ring comes to exist between a client and a service.
- **Discovery:** each service directory has `.help` and `.schema` nodes.

## 5. The network: 9gate and the swarm

`9gate` is a translator service, and it is the only thing that speaks
9P2000.L. It works in both directions:
- **Export.** It serves a chosen subtree of the namespace to the network.
  Linux `v9fs` and 9front mount it unchanged.
- **Import.** It mounts a remote 9P2000.L server as a node subtree.

Between VectraOS peers, 9gate negotiates extension messages:
- typed attributes and queries, so Taisce works remotely;
- leases and notifications, for `watch`;
- remote rings. These are bridged by 9gate as a stream: local ring → 9P
  reads and writes on a large msize → remote ring. A dedicated transport is
  an open question for V7.

The transport is first-party Noise IK over TCP. The swarm design follows
NeoVectra's docs/02 §6: node roles (terminal, CPU, accelerator, file, auth),
`/swarm/pool` leases for accelerators, and remote `/dev/accel`.

The CPU role is Plan 9's cpu (D75; from V3, D77): `cpu -h NODE` runs rc
on another node with the terminal's tree at `/mnt/term` and its `/dev/cons` bound
over the node's, so neither side has a pty. The auth role is factotum
(D75: todhchai's keyring, under Plan 9's name): it holds every key,
Noise IK's static key among them, and runs the protocols for programs,
which never see a long-term key.

### Bring-up access (D15, D77)

During development, the dev machine reaches a node through the same cpu
session, brought forward to V3: `vx cpu NODE` (Swift, in vx) exports
the dev machine's tree to the node's rc at `/mnt/term`, over 9gate's
9P2000.L core and Noise IK. Copies are `cp` from `/mnt/term`, logs are
the debuglog's node, and `warmboot` (a `SYSTEM_POWERCTL` command) loads
a new kernel and bootfs from `/mnt/term` into memory, with no firmware
involved. There is no SSH (D77).

The listener is a development tool, not a system mechanism:
- It is off unless the image is built with `--cpu PUBKEY`.
- It listens only on-link and accepts only the pinned dev machine's key.

## 6. Storage: Taisce

Taisce comes from todhchai, unchanged in design (`todhchai/docs/filesystem.md`):
- **Attributes** are typed: string, int64, uint64, double, time, bool, bytes,
  ref and MIME. They live in the `sys:`, `user:` and `derived:` namespaces.
- **Indices** are declared, with automatic back-fill.
- **Queries** use BFS infix syntax plus ranges, `order by` and `limit`.
- **Live queries** emit added, removed and changed updates. They can be
  resumed from a change-journal sequence number.
- **On disk:** copy-on-write B+trees, a superblock ring, BLAKE3-128 checksums
  on every pointer, and an intent log.

Taisce is the one file system. FAT is read-only, for the ESP. NeoVectra's
gefs-style FS is not carried forward (D8).

## 7. Desktop: Radharc and workspace modes

The compositor is todhchai's Radharc: a retained layer tree, present credits,
late latching, and the ability to run nested. The window list is a node
(`/svc/windows`) with typed `wctl` verbs.

**Text windows are rio's** (D75). The terminal is Plan 9's rio window,
not an xterm: it serves its programs' `/dev/cons` and `/dev/consctl`,
edits their input itself, and shows plain text. Radharc stays the
window manager; `vt` runs in a window for programs that want xterm.

**Workspaces.** Each workspace has exactly one mode, and the user can switch
it at any time:

| Mode | Behaviour |
|---|---|
| `tile` | Windows are arranged by a layout policy, starting with master-stack. Focus moves and placements are bound to chords. |
| `space` | Free placement, with spatial memory: every window and Tracker folder reopens exactly where it was. Plain stacking is `space` at a 1:1 view. |

- **Both arrangements persist.** Switching modes is a projection, not a
  loss. A workspace switched from `space` to `tile` and back restores every
  window's spatial frame. Frames are stored as Taisce attributes on the
  window's document or app, following Be's `_trk/windframe`.
- **Mixing modes.** Any number of workspaces of either mode can exist, per
  output. A window moved between workspaces takes the target's mode.
- **Layout policies** are Swift libraries behind one protocol. Adding a
  layout is a library, not a new mechanism.
- **From todhchai:** tab stacking, stashing and the focus area with a live
  periphery. Each one must earn its place against principle 1 in V5.

**Look: Platinum Indigo** (D24). The desktop is skeuomorphic in the manner
of the 1990s and early 2000s: BeOS structure and yellow tabs, NeXT bevels
and column browsers, SGI Indigo Magic colour, MUI grooved groups. All
chrome is vector, so 1080p to 4K and beyond is a scale factor, not a
second set of bitmaps. The storyboard is the reference:
[VectraOS Desktop Storyboard](https://claude.ai/artifact/BcQQLDod1qqmgwVzabeTPX)
(a copy of its sources is in [design/storyboard/](design/storyboard/)).

## 8. Compute: accelerators as nodes

```
host: ONNX / StableHLO ──(vxc, MLIR-based host tool)──► TOSA artifact (.vxm)
device: /dev/accel/<dev>  ctl node: load .vxm, bind rings, query caps
        backends:  cpu (NEON/SSE TOSA executor)  · adreno (Vulkan compute)
                   cdsp (Hexagon, via FastRPC driver)  · later: rknpu, hailo
```

- **Artifact:** `.vxm`, a TOSA graph serialised in the IPC wire format.
  `vxc` is the only producer. It runs on the host, and it alone may use
  MLIR (D4).
- **On the device:** a first-party TOSA executor with one backend per
  device class. The CPU backend is the reference, and every other backend is
  checked against it.
- **Data:** tensors move on the same rings as everything else (principle 6).
  Camera, NPU and renderer are connected ring to ring.
- **Research tracks:** the Halide-style schedule split, hetIR-style
  migration, and Hexagon kernels from upstream LLVM.

## 9. Wasm

`wasmd` is a first-party Wasm runtime. It starts with an interpreter, then
adds ahead-of-time compilation by `vxc` on the host. An on-device JIT, built
on croi's W^X JIT reservations, comes only if AOT proves insufficient, and
needs its own decision. WASI imports map directly
onto the Node protocol and rings. A Wasm app is one process, with no
separate unikernel image (D7).

## 10. Repository layout (target)

```
boot/       UEFI loader                         ← croi/boot
kernel/     kernel + arch                        ← croi/kernel
lib/        handoff, elf, pagetables, fmt, rt, ring
system/     ipc, node, ns, launch, trace, libc   ← todhchai/system
services/   radharc, router, net, 9gate, accel, wasmd
drivers/    virtio, nvme, uart, qcom-*, adreno, cdsp
fs/taisce/                                       ← todhchai/fs/taisce
sdk/        VX, VXUI, VXCompute, VXData, macros
apps/       tracker, deskbar, terminal, reference programs
tools/vx/   the front door: build · boot · test · bench · trace · ci
tests/      host, native (QEMU), hardware
docs/
```
