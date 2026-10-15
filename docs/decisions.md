# Decision log

Entries are dated and never edited after the fact. A reversal is a new entry
that names the one it replaces.

- **Decided** means the project owner made the call.
- **Proposed** means it was drafted with the founding docs and stands until
  someone confirms or reverses it.

## D1. Languages: Embedded Swift first, C23 where necessary (2026-10-15, decided)

The toolchain is Swift 6.4 (swiftly), with the clang, lld and llvm-objcopy
bundled with it. Tier 0 uses Embedded Swift with `-strict-memory-safety`.
Tier 1 uses full Swift. C23 is allowed for ABI headers, the compiler runtime,
trampolines and code that Embedded Swift cannot express (principle 29).

## D2. The kernel: lift croi, then slim it (2026-10-15, decided)

Import croi whole in V0 so the system boots from day one. In V1, audit every
object and syscall against the setup-engine role (principle 4). Cut what
rings replace. Publish a syscall-count ceiling that only goes down.

- **Rejected:** a new minimal kernel mined from croi. It is slower to reach
  a boot, and croi's object model is already capability-based.
- **Rejected:** keeping croi unchanged. That leaves two bulk mechanisms.

## D3. The control plane: todhchai's Node protocol locally, 9P2000.L only at the network edge (2026-10-15, decided)

On the machine, services speak the Node protocol and typed `@IPCLibrary`
interfaces over croi channels, using the IPC wire format. `9gate` is the only
component that speaks 9P2000.L. It exports subtrees to the network and
imports remote servers.

- **Principle 1:** the gateway is a translator at a boundary, not a second
  local mechanism. No local service may speak 9P.
- **Rejected:** 9P2000.L everywhere, and NeoVectra's 9Px.

## D4. Third-party code: first-party on the device, heavy tools only on the host (2026-10-15, decided)

Everything that executes on a VectraOS device is first-party Swift or C23.
That includes the Wasm runtime, the TOSA executor, crypto, codecs and the
network stack.

- **Host tools** may use third-party compilers as build tools. MLIR and
  StableHLO, inside `vxc`, are the expected case. A host tool's output must
  be one of our artifact formats.
- **Firmware blobs** that the hardware requires are listed with their
  provenance in `firmware/README.md`. The Q8B's ADSP, CDSP and GPU firmware
  are examples.
- **Rejected:** vendoring pinned libraries onto the device (NeoVectra's
  model), and zero third-party code even on the host.

## D5. First hardware: Radxa Dragon Q8B (2026-10-15, decided)

The board is a Qualcomm SC8280XP: Cortex-X1C/A78C cores, an Adreno 690 GPU
and a Hexagon CDSP NPU, with UEFI and ACPI firmware.

- **Why:** AbyssBSD already runs it under ACPI with the CDSP working, and its
  notes (`AbyssBSD/docs/boards/radxa-dragon-q8b/`) are ground truth. croi's
  ACPI-only boot path carries over, so no devicetree work is needed.
- **Later:** RK3588 and Hailo-8 follow once the accelerator protocol exists.

## D6. One wire format: todhchai's IPC wire format, not FlatBuffers (2026-10-15, proposed)

The paper asks for FlatBuffers so ring payloads can be read in place. The IPC
wire format already gives that: little-endian, 8-byte aligned and decoded in
place. It is also what the Node protocol uses. Adopting FlatBuffers as well
would mean two encodings (principle 7).

- **Ring payloads** use the wire format's layout rules, with no message
  header.

## D7. Wasm as a process, not a unikernel (2026-10-15, proposed)

The paper compiles WASI apps into unikernels to avoid OS overhead. On this
kernel a process with ring-mapped I/O already has that property. So `wasmd`
runs each Wasm app as an ordinary process, with WASI imports mapped onto
nodes and rings. There is no second kernel image format.

## D8. One file system: Taisce (2026-10-15, decided)

When two projects solved the same problem, we keep the one that gives
BeOS-style database abilities. Taisce has typed attributes, indices, live
queries and a change journal. NeoVectra's Bε-tree FS has none of these, so it
is not carried forward. FAT stays read-only for the ESP.

## D9. Desktop: tile and space workspace modes, switchable live (2026-10-15, decided; details proposed)

The owner asked for tiling and spatial window management to be easy to
switch between, with several workspaces of either kind. The design is in
architecture §7.

- **Proposed:** plain stacking is `space` at 1:1, not a third mode.
- **Proposed:** both arrangements persist as Taisce attributes.

## D10. Performance contracts from todhchai (2026-10-15, decided)

- `Judge` (`todhchai/tools/bench/lib/Judge.swift`) decides pass or fail:
  median of the last 5 runs plus a tolerance and a floor, and an optional
  hard limit.
- Budgets are reported on the console as `budget name=… value=… unit=…
  limit=…` lines and kept in a per-host history.
- The tracer uses one 32-byte record, shared by kernel and user space.

These carry over unchanged. See performance.md.

## D11. One front door: `vx` (2026-10-15, proposed)

todhchai's `td` becomes `vx`: build, boot, test, bench, trace and ci. There
is one build graph, CMake and Ninja with presets (from croi). Whether host
tests also run under SwiftPM, as in todhchai, or only under CTest is decided
in V0.

## D12. Names (2026-10-15, proposed)

Component names from the earlier projects stay: Taisce, Radharc and croi
inside `kernel/`. Renaming adds churn and buys nothing.

## D13. Host tools under SwiftPM, images under CMake (2026-10-15, decided in V0)

This settles D11's open question. SwiftPM (`Package.swift`) builds `vx`,
the host libraries (Bench, TraceFormat, TraceReader) and their tests.
CMake builds the loader, kernel and user images, one tree per arch. The
two never build the same target, and `vx` drives both, so this is still
one way to build.

- **`tools/bench.py` is removed.** `vx bench` replaces it, judged by
  todhchai's `Judge`. The two duplicated each other (principle 1).
- **History units.** `bench/history/brimstone.tsv` was converted from
  nanoseconds to seconds, the unit Judge uses.
- **Limits.** The kernel's exclusive `limit=L` is read as Judge's inclusive
  `L - 1` (in ns or the count).

## D14. No Python in the build (2026-10-15, decided)

The owner asked for this to cut the build chain's dependencies. croi's
Python tools are rewritten in Swift as `vx` subcommands:
- `elf2efi`, `mkbootfs` and `check-pixels`, over the `ImageFormats`
  library;
- `qemu-monitor`, `todhchai-check`, and `bench --zircon` (was
  `zircon-bench/compare.py`).

CMake builds `vx` with SwiftPM and runs it for its build steps.

- **Checked before removal.** Every output was compared with the Python
  version's: the PE images of all three arches' loaders, every arch's
  `bootfs.img`, the pixel checks, and the names in Todhchai's bootfs
  images. All were byte-identical. Then the Python was removed.
- **What a build needs now:** the Swift toolchain, CMake, Ninja, QEMU and
  bash. `qemu.sh` and `zircon-bench/run.sh` stay as bash.

## D15. A bring-up link before the board, over SSH (2026-10-15, decided)

The owner asked for a remote shell and file copies to the board during
bring-up, ahead of V4. The roadmap now has V3, the bring-up link,
between V2 and V4. Later milestones are renumbered: Taisce on disk is V5,
the desktop V6, the edge V7, compute V8, Wasm V9. V1 moves off the
critical path and runs alongside.

- **Protocol: SSH, lifted from todhchai's N1** (owner's choice over a 9P
  subset of 9gate). The crypto, network stack, sshd and SFTP are mostly
  built and tested there. Stock OpenSSH on the dev machine needs nothing
  of ours, and the link is encrypted and key-authenticated from the first
  day.
- **This amends D3.** SSH is allowed as a development tool:
  - off unless the image is built with `--ssh`;
  - on-link only;
  - public keys only;
  - never spoken by a local service.

  9gate remains the only namespace protocol on the network, and reuses
  V3's stack and crypto.
- **Links: a serial console plus Ethernet** (owner's choice).
  - A GENI UART driver makes the board's output and hangs visible from the
    first boot. It needs a 1.8 V USB-serial adapter on the header.
  - The TC956x Ethernet carries SSH.
  - Both are developed against QEMU first: virtio-net there, and a
    register-level model for GENI.
- **Warm boot from memory** (owner's choice), so a new kernel needs no
  stick and no walk. The kernel hands off to an image held in memory,
  reusing the loader's ELF, page-table and handoff libraries. It is a
  `SYSTEM_POWERCTL` command, so there is no new syscall. UEFI network boot
  was not chosen (roadmap, open question 7).
- **Files land in Taisce on a RAM-backed block device**, so bring-up has
  no second file system.
- **The shell is todhchai's rc**, since SSH sessions run it. NeoVectra's rc
  is dropped. This settles open question 2.

## D16. Milestones run in order (2026-10-15, decided; corrects D15)

D15 moved V1 off a "critical path" to run alongside V2–V4. That framing
was wrong. The aim is to have the board's dependencies in place before
bring-up is attempted, not to reach the board as fast as possible. The
milestones run in order, V0 → V1 → V2 → V3 → V4 → …. V3 (the bring-up
link) stays ahead of V4 because the board work depends on it.

## D17. Boot budget history starts at V2 (2026-10-15, decided)

V1 trims and changes the kernel, so a baseline recorded at V0 would only
measure code that is about to change. `vx bench` still runs and reports
in the meantime, as advisory. The first `--record` happens at V2's exit,
on the kernel as V1 left it. The existing history in
`bench/history/brimstone.tsv` (croi's, converted to seconds) is kept for
reference, but it is not a VectraOS baseline.

## D18. The control plane stays on channels, and is batched (2026-10-15, decided)

The V1 audit (`docs/syscall-audit.md`) asked whether the Node protocol
should move to request and response rings, leaving channels to carry only
handles. It stays on channels:
- **`channel_call` is the latency path.** One syscall per call, a direct
  switch to the waiting server, and the caller's deadline donated to it.
  A ring pair needs two wakeups, about 3–4 µs against `channel_call`'s
  1.45 µs today (budget < 1 µs), and the kernel can't donate a deadline
  to a ring's server.
- **Node replies carry handles** (`walk`, `map`), which need a channel
  anyway.
- **Rings take everything with volume.** A service offers a ring as a
  node (architecture §4), and V2 moves todhchai's bulk Node traffic
  (32 KiB `read`/`write` calls, listing VMOs) onto rings.

**Batching is designed in, not added later** (principle 12: where there
is one, there will be many):
- **A Node message is a batch.** A request carries an array of
  operations, and its reply an array of results in the same order. A
  later operation may name an earlier one's result, as NFSv4's COMPOUND
  does, so walk, stat and open of one path are one call. The batch stops
  at the first failure and returns the results so far. A single
  operation is a batch of one.
- **Hot syscalls take arrays with counts** (audit §3): closing handles,
  binding event sources, ringing doorbells, reading and replying on many
  channels, mapping a program's segments and acknowledging interrupts.
  A server's loop is: drain its port ring, read every ready channel in
  one call, reply to all of them in one call.
- **No generic syscall batch.** A mixed submission queue, as in
  io_uring, would be a second way to make every call and a large attack
  surface. Each call takes an array of its own items instead.

## D19. Ports become rings (2026-10-15, decided)

The kernel writes port packets into a mapped ring in the one format
(architecture §3), with the consumer cursor in user memory. A thread
drains pending events with no syscall and calls `port_wait` only when the
ring is empty. This is done in V1 after the cuts and `object_bind`, so
that it is built on the reduced set of event sources.

## D20. object_bind, the first cut (2026-10-15, decided)

Step 1 of V1 (`docs/syscall-audit.md` §1). `object_bind(port, items,
count)` is the one way an event source reports to a port, and it takes a
batch (D18). It replaces five calls: `object_wait_async`,
`interrupt_bind`, `counter_wait_async`, `thread_bind_overrun_port` and
`account_bind_pressure_port`. The syscall count goes from 154 to 150, and
the ceiling with it.
- **Bindings are ONCE or PERSISTENT.** A persistent binding owns one
  packet. It is queued at an event and only counts further events while
  it waits to be read, so a busy source costs nothing per event once
  bound.
- **A counter's CHANGE binding is the ring doorbell** (architecture §3).
  Every add or write rings it.
- **`port_cancel` unbinds every kind,** interrupts included. That replaces
  interrupt_bind's UNBIND.
- **`port_wait` takes a leeway** (principle 10), so that sleeps coalesce
  once timers are cut.

Two consequences:
- **`vx todhchai-check` is retired.** todhchai's binaries use the old
  calls. From here on the ABI is VectraOS's, and V2 lifts the userland
  onto it.
- **New tests are Embedded Swift suites** (`user/test/swift/`, one file
  per subsystem, named checks, run by the kernel's
  `ProgramSelfTest.runSuites`), not additions to croi's monolithic
  `usertest.c`. That file shrinks as the calls it tests are cut, and is
  only edited to keep its remaining tests compiling.

## D21. FIFOs, sockets and streams are cut (2026-10-15, decided)

The first family of V1's cuts (`docs/syscall-audit.md` §2): fifteen
calls, 150 → 135.
- **FIFOs and sockets** (87–89, 190–193). The one ring format replaces
  both: a record ring for FIFOs, the byte-stream mode for sockets. Their
  info topic, threshold properties, policy conditions (NEW_SOCKET,
  NEW_FIFO) and the MANAGE_SOCKET right went with them.
- **Streams and the stream-size calls** (194–201). A mapping replaces a
  stream. A VMO's content size stays, as the property
  ZX_PROP_VMO_CONTENT_SIZE: Taisce's mapped files need a byte length. It
  is now the one way to read or set it, and it keeps Zircon's per-VMO
  size lock (`ContentSize.swift`).
- **Tests move to Swift as they are touched.** A `usertest.c` test of a
  cut call is deleted. Checks of what survives move to a Swift suite,
  here `VmoSuite` (content size, the size lock, executable VMOs). A C test
  that only needed the same kernel path through another call (a
  stream-size read becoming the property) is edited in place, and moves
  with its function when the waits are cut.
- **Lost:** the WRONG_TYPE refusal of a name on an unnamed type. Sockets
  were the last user-creatable unnamed type with SET_PROPERTY, so the
  check has no caller to test it with.

## D22. The channel _etc forms and the futex extras are cut (2026-10-15, decided)

The second family of V1's cuts (`docs/syscall-audit.md` §2): six calls,
135 → 129.
- **channel_write_etc, channel_read_etc, channel_call_etc** (213–215).
  One form per job: a handle's rights are narrowed with
  `handle_duplicate` before it is sent, and a reader that needs a
  handle's type or rights asks `object_get_info`. channel_read keeps what
  K13e gave it: unknown options are NOT_SUPPORTED, and MAY_DISCARD drops
  a message that doesn't fit.
- **futex_requeue, futex_wake_single_owner, futex_get_owner** (92–94).
  todhchai's Lock and pthreads use wait and wake only. futex_wait still
  names an owner, which inherits its waiters' profiles, and futex_wake
  clears it. With no requeue, a waiter's futex record is the one it
  blocked on, so `Thread.futex` and the scheduler's `moveWaiters` and
  `wakeFirst` went too.
- **Tests:** the futex checks of `usertest.c`'s mode 8 moved to a Swift
  `futex` suite, and the channel checks of `small_calls` that survive
  (MAY_DISCARD, and narrowed rights arriving narrowed) to a `channel`
  suite. `runSuites` now lends `test_profile` a deadline context, and
  fails if a futex record is left after the suites.
- **Lost:** the direct check that a wake clears the owner (get_owner read
  it back). It is checked indirectly: an owned record is never retired,
  so a cleared owner is what lets `runSuites` find no record left.

## D23. Events, signals and the thread waits are cut (2026-10-15, decided)

The third family of V1's cuts (`docs/syscall-audit.md` §2): six calls,
129 → 123.
- **object_wait_one, object_wait_many** (21, 210). A port is the one wait
  (architecture §2): bind the source with `object_bind`, then
  `port_wait`. `ObjectWait` went; the thread-wait observers stay for
  `counter_wait` until it is cut.
- **event_create, eventpair_create, object_signal, object_signal_peer**
  (30, 84, 20, 85). User signals were only ever eventpair kicks; a
  counter is the event a user drives, and a ring's peer death is its
  negotiating channel's PEER_CLOSED. The user signal bits, the
  SIGNAL_PEER right, the NEW_EVENT and NEW_EVENTPAIR policy conditions,
  the HANDLE_CLOSED signal and the BLOCKED_WAIT_MANY state went with
  them, and so did D21's leftovers: NEW_ANY's FIFO and socket
  conditions, and the stream reads in the restartable list.
- **Event objects stay, kernel-made,** until `system_get_event` is cut.
  The audit replaces it with a binding on the root account, and there is
  no root account object yet.
- **m2 keeps its budgets' paths.** `port.wake` binds ONCE to a counter's
  POSITIVE signal where it bound to an event's SIGNALED, and the waker's
  `counter_add` stands where `object_signal` stood. The `channel_call`
  server is now as V1's servers are: its channel bound PERSISTENT to its
  port, drained at each packet. Interleaved against D22 under KVM (5
  boots each): `ipc.channel_call` 1.1 µs against 1.2 µs, `port.wake`
  median 1.1 µs against 1.7 µs; nothing rose past its noise.
- **Tests:** moved where the cut calls were called directly. Modes 0 and
  7's event, signal, port and channel checks and all of `small_calls`
  moved to an `objects` suite and the `channel` suite. Tests that only
  waited went on through `usertest.c`'s `wait_for`, rewritten as a ONCE
  binding on a port of its own (D21's in-place edits move when a later
  cut touches them). A pending ONCE binding holds its port, so a waiter
  that gives up cancels it (`zircon-divergences.md`).
- **Lost:** the kernel's check that one signal wakes eight waiters on
  one object across CPUs (`notify` running many observers at once). Its
  V1 form is many bindings on one object, which nothing checks yet.
  Checks of the cut calls themselves (user signal bits, `wait_many`'s
  items, eventpairs) went with them.
