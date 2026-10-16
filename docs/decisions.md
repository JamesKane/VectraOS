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

## D24. Desktop look: Platinum Indigo, not neon (2026-10-15, direction decided; details proposed)

The owner asked for a retro-future skeuomorphic look after the 1990s and
early 2000s HIGs, before flat design: BeOS, NeXT, SGI and Amiga MUI,
modernised as vector components that scale from 1080p to 4K and beyond.
It replaces the look in todhchai's `docs/desktop.md` §6 ("retro-future
cyberpunk": neon glow, chamfered cuts, CRT pass). Todhchai's structure
stays: Radharc, Tracker, Deskbar, the yellow tab with close and zoom
boxes, replicants and the trusted prompt.

- **Reference:** the [VectraOS Desktop Storyboard](https://claude.ai/artifact/BcQQLDod1qqmgwVzabeTPX),
  seven frames: the space workspace, its tile projection, a Tracker live
  query, the Inspector, the namespace browser and ring patch bay,
  Appearance with the trusted prompt, and the component kit. Its sources
  are copied in `docs/design/storyboard/`; the canvas is the live copy.
- **Proposed:** the tokens and material rules on the kit frame (light from
  the top left; raised presses, inset holds data, grooved groups; yellow is
  focus, blue is selection, green on black is live).
- **Proposed:** one UI scale per output, 100% to 300%; bevels and outlines
  are one logical pixel snapped to whole device pixels.
- **Proposed:** Archivo and IBM Plex Mono, openly licensed, with license
  and provenance recorded as todhchai's §6 requires for fonts.
- **Kept from §6:** SDF-drawn chrome and MSDF text, the accessibility
  theme as one switch, and the composition budget. The glow, bloom, CRT
  and glitch passes go.

## D25. Sleeps, timers and the counter waits are cut (2026-10-15, decided)

The fourth family of V1's cuts (`docs/syscall-audit.md` §2): six calls,
123 → 117.
- **nanosleep, timer_create, timer_set, timer_cancel** (4, 95–97). A
  sleep is a `port_wait` with a deadline on a port nothing is bound to; a
  timer is the deadline an event loop passes to its `port_wait`, the
  earliest it has. port_wait's leeway (principle 10) runs late, never
  early, and a deadline thread gets none, as timer objects' slack did.
  Timer objects, their slack policies and the NEW_TIMER policy condition
  went. `Objects.lastHandleClosed`, their hook, stays for ports.
- **counter_write, counter_wait** (163, 164). A value is set by adding
  the difference; a wait at a value is an object_bind VALUE binding. The
  thread waits behind counter_wait went with it (`WaitState`,
  `Observer.Kind.wait`, `Thread.waitState`): every observer is now a
  binding.
- **A counter's lent deadline moves to the port** (K10c, ext 5). A
  counter or timeline with a deadline profile lends it to the thread its
  packet wakes in `port_wait` (`Scheduler.wakeOne(lending:)`), where it
  lent it to counter_wait's threads. Interrupts keep lending to their
  interrupt_wait thread until that call is cut.
- **m2 keeps its budgets.** `counter.wake` now runs from `counter_add` to
  the `port_wait` a CHANGE binding (the doorbell) ends, where it ran to
  counter_wait's exit; the timeline wake waits with a VALUE binding; the
  sleeps and `timer.wake_error` sleep through `port_wait`; the exit test
  waits for a counter's value, then to a deadline, where it set a timer.
  Interleaved against D24 under KVM (5 boots each): `counter.wake`
  median 1.0 µs against 969 ns, `timer.wake_error_p99` 26.2 µs against
  27.3; nothing rose past its noise.
- **Tests:** mode 14 (counters) and mode 16's lending check moved to a
  `counters` suite; mode 8's zero slack for a deadline thread moved to
  the bind suite's leeway check, and the rest of mode 8 (timers) went.
  usertest.c sleeps through `sleep_until` (a port of its own each time,
  since the program has no writable data) and waits at a value through
  `wait_value` (a VALUE binding on its own port).
- **Lost:** nothing that still has a mechanism. The checks of timer
  objects themselves (slack policies, set and cancel clearing SIGNALED,
  two threads setting one timer, handle_replace keeping one armed) went
  with them. Many timers on one CPU is still checked by the kernel's
  timer self-test, which arms 200 nodes on one CPU.

## D26. Clocks are cut (2026-10-15, decided)

The fifth family of V1's cuts (`docs/syscall-audit.md` §2): six calls,
117 → 111.
- **clock_create, clock_read, clock_get_details, clock_update,
  vmar_map_clock** (216–219, 77). Clock objects and their mapped page,
  the INFO_CLOCK_MAPPED_SIZE topic and the PA_CLOCK_UTC startup handle
  (nothing handed one out) went. UTC will be the time service's: a
  read-only seqlock VMO it hands each process at start (audit §4). No
  UTC source exists yet, so nothing is lost.
- **clock_monotonic** (3). The vDSO's clock is the one way to read
  monotonic time; the runtime's `croi_clock_monotonic` calls it. m2,
  userboot and the suites use it.
- **A futex_wait with no owner, and futex_wake, need no handle table.**
  Futexes are keyed by address space; only an owner is a handle. So a
  thread with no handles can sleep: the kernel-launched self-tests'
  modes 2 and 3 do.
- **usertest.c reads the vDSO.** It has no writable data, so a process
  mode finds the vDSO's base in its startup block (word 8) and a child
  in its start argument. Mode 3's sleeps had still called nanosleep by
  number since D25, so they had stopped sleeping; they are futex_wait
  timeouts now, 300 µs steps from a vDSO reading. Mode 4 spins until
  the kernel sets a word on its stack: a sample in the vDSO would count
  as foreign.
- **m2 keeps its budgets.** Interleaved against D25 under KVM (5 boots
  each), nothing rose past its noise. `process.spawn_to_main` 73.5 µs
  against 99.4 and `timer.wake_error_p99` 16.5 µs against 29.2: both
  ends now read the clock without a kernel entry. With the 1 ms steps
  measured then, `boot.userboot_start_selftests` was 3.547 s against
  3.425 (within its spread); mode 3's steps went back to the 300 µs it
  slept before D25.
- **Tests:** a Swift `time` suite: the vDSO clock never goes back, and
  a CHANGE packet's kernel timestamp falls between two vDSO readings,
  which was mode 2's check against the syscall. Mode 2 now checks the
  vDSO clock against a futex_wait deadline: never behind it. Mode 17's
  `clocks` went with the clock objects.
- **Lost:** nothing that still has a mechanism. The checks of clock
  objects themselves (rates, backstops, the mapped page's transform,
  STARTED and UPDATED) went with them, and the bench's syscall clock
  timing in mode 2.

## D27. Display timelines are cut (2026-10-15, decided)

The sixth family of V1's cuts (`docs/syscall-audit.md` §2): four calls,
111 → 107.
- **timeline_create, timeline_advance, timeline_set_period,
  timeline_get_page** (170–173). Timeline objects (type 48), their
  vblank page and the display system resource's use (slot 16 stays
  empty) went. A driven display's vblank is a counter its IRQ thread
  adds to; a synthetic one is Radharc's own deadline thread sleeping to
  the vblank time it computes.
- **ALIGN_TIMELINE (Todhchai ext 10) goes with them.** It started a
  deadline thread's periods on a timeline's vblanks. Both replacements
  start the period at the wakeup instead: a counter's lent deadline
  starts its period when its packet wakes the thread (K10c), and a
  deadline thread that wakes from a `port_wait` deadline (no leeway)
  starts a new period there. todhchai's Radharc uses the option; V2
  lifts it onto the counter and its own thread. A thread's profile now
  takes no options (HANDOFF is an interrupt's).
- **The `timeline.wake` budgets go with their bench.** They measured
  the deadline thread waking at a synthetic vblank. With the vblank
  computed in user space, that is a deadline thread waking at its
  `port_wait` deadline, which `timer.wake_error_p99` measures, under the
  same 100 µs limit. The judge only checks budgets a run reports, so the
  history's old rows don't matter.
- **Tests:** mode 15 (timelines) went, and mode 16's alignment checks
  (385–388). Nothing in them tests a surviving mechanism: counters,
  VALUE bindings and lending are the counters suite's.
- **Lost:** nothing that still has a mechanism.

## D28. The bring-up calls are cut: debug_write and vmo_map (2026-10-15, decided)

The seventh of V1's cuts (`docs/syscall-audit.md` §2): two calls,
107 → 105. Both were scaffolding from before the mechanism that replaced
them.
- **debug_write** (1) printed a user string on the kernel console, from
  K6, before debuglogs (K8a). `debuglog_write` is the one way to log.
  Every program the kernel or userboot starts gets a debuglog as fd 1;
  the runtime's stdout drops its output without one.
- **vmo_map** (43) mapped a VMO into the calling thread's address space
  "until VMARs (K7)". `vmar_map` is the one way to map. usertest.c's
  process modes map stacks in their root VMAR (`map_stack`). Its child
  processes have no VMAR handle, so `make_child` maps a region of five
  stacks and `child_thread` takes one by index.
- **The boot's assembly user test** (`usertest.S`) used debug_write, and
  still used the clock syscall D26 cut, so since D26 it had printed
  "null syscall 0 ns". It now checks only that registers survive 1000
  null syscalls. m2's `syscall.null` budget times them.
- **Tests:** mode 0's size and mapping checks (169, 181, 20–22) moved to
  the vmo suite. Check 25, debug_write's bad pointer, went; the vmo_read
  and vmo_write bad-pointer checks stay until those calls are cut.
- **Lost:** a program with no debuglog can't print. The kernel and
  userboot always hand one over.

## D29. The interrupt waits are cut (2026-10-15, decided)

The eighth of V1's cuts (`docs/syscall-audit.md` §2): three calls,
105 → 102.
- **interrupt_wait** (143). A bound port is the one way to wait for an
  interrupt, as for everything else. Ext 5's lent deadline and handed-off
  context (K14e) now ride the packet: the thread it wakes from the port
  gets them, as a counter's packet lends (D25).
- **interrupt_destroy** (144). Closing the last handle destroys. Its
  other use was waking an interrupt_wait thread CANCELED, which went
  with the wait.
- **interrupt_trigger** (145) and VIRTUAL interrupts. A counter is a
  virtual interrupt. Tests fire an interrupt object as its device would
  through a test hook (syscall 6, op 13), since a real device can't fire
  on demand everywhere (arm64's PL031 counts whole seconds).
- **Tests:** usertest.c's modes 11 (interrupts, MSI) and 16 (a
  handed-off context) moved to a Swift interrupts suite, which the
  kernel runs on its own where mode 11 ran, with the same checks around
  it (the RTC taken on CPU 1, nothing left behind). It needs device
  registers, so the runtime gained volatile MMIO accessors and amd64 port
  I/O as static inline C (`runtime.h`). Two direct users stayed in C:
  mode 17's idle-state check takes the RTC's interrupt object in place of
  a virtual one, and mode 18 dropped interrupt_destroy before a close.
- **`irq.wait_wake_median` keeps its name and limit.** It measured the
  interrupt_wait thread's wake; it now measures the port_wait's, the
  path drivers use.
- **Lost:** a thread can't wait on one interrupt without a port.

## D30. thread_raise_exception is cut (2026-10-15, decided)

The ninth of V1's cuts (`docs/syscall-audit.md` §2): one call, 102 →
101.
- **thread_raise_exception** (236) offered ZX_EXCP_USER to every job
  debugger up the tree. Nothing raises one: Fuchsia's use is its process
  name change notice, and VectraOS has no debugger yet. One comes back
  with the debugger that needs it.
- **Job debuggers stay.** They still see PROCESS_STARTING, and walking
  their list still prunes closed channels.
- **Tests:** usertest.c's `user_exceptions` (623–627) tested the call
  itself and went. It was also the only test that delivered to a job
  debugger, so the objects suite gained one: two job debuggers see a new
  process's PROCESS_STARTING in turn, then no longer count once closed.
  Suites now get the root job as a startup handle (PA_JOB_DEFAULT).
- **Lost:** a program can't tell a job debugger something on its own.

## D31. system_get_event is cut; the root account reports memory levels (2026-10-15, decided)

The tenth of V1's cuts (`docs/syscall-audit.md` §2): one call, 101 →
100.
- **system_get_event** (235) handed out five kernel event objects, one
  per memory level. Accounts already report their pressure through
  object_bind, so the system's levels became the root account's: one
  mechanism for memory pressure, a packet per change.
- **The root account** is made at boot and never freed. Userboot (and
  the Swift suites) get it as CROI_PA_ROOT_ACCOUNT, with no CHARGE right,
  so nothing charges it. Its level is the memory watchdog's, with two
  levels past CRITICAL (IMMINENT_OUT_OF_MEMORY, OUT_OF_MEMORY); its
  limit is the RAM and its charge the RAM in use. Its limit can't be set.
- **A PRESSURE binding reports the level at once** unless it is normal,
  on any account. An event was a level a new waiter saw at once; a
  binder must not wait for a change to learn it.
- **port_cancel removes a PRESSURE binding.** A binding left on the
  root account would keep its port alive forever.
- **Event objects go.** The kernel's self-tests signal counters.
- **Tests:** usertest.c's checks 615–619 moved to a Swift `memory`
  suite, which also checks the binding's first report and port_cancel.
- **Lost:** an account takes one PRESSURE binding at a time, so only
  one service hears the system's levels (Fuchsia let any holder of the
  root job wait on them). That service passes them on.

## D32. port_cancel_key merges into port_cancel (2026-10-15, decided)

The first of V1's merges (`docs/syscall-audit.md` §2): one call, 100 →
99.
- **port_cancel(port, source, key)** with source 0 cancels the key from
  every source, as port_cancel_key (212) did: each binding to the port
  with the key, and each queued packet with it, user packets included.
  NOT_FOUND if there were none. No handle is 0, so the two forms can't
  be confused.
- **The options argument goes.** port_cancel_key took one and refused
  any bit; nothing used it.
- **Tests:** the Swift `objects` suite's check moved to the merged call.

## D33. handle_close takes an array (2026-10-15, decided)

The second of V1's merges: one call, 99 → 98.
- **handle_close(handles, count)** (10) is what handle_close_many (211)
  was: 0 skipped, a bad value BAD_HANDLE with the rest still closed, 64
  copied in at a time. Where there is one handle there will be many
  (principle 12), so the batch is the call and one handle is an array
  of one.
- **croi_handle_close(handle)** in `croi/syscall.h` is the one-handle
  form for C and Swift callers; usertest.c's 216 closes, the runtime's,
  userboot's, m2's and the Swift suites' go through it.
- **Tests:** the Swift `objects` suite's handle_close_many checks moved
  to the merged call.

## D34. handle_replace merges into handle_duplicate (2026-10-15, decided)

The third of V1's merges: one call, 98 → 97.
- **handle_duplicate(handle, rights, out, options)** (11) with
  CROI_HANDLE_DUPLICATE_CONSUME is what handle_replace (12) was: the
  handle goes, even when the rights asked for are refused, and needs no
  DUPLICATE right. Any other option is INVALID_ARGS.
- **Callers keep working:** options is the fourth argument, which every
  existing caller already passed as 0. Nothing called handle_replace.
- **Tests:** the Swift `objects` suite gains `consume`: a replace with
  fewer rights, the old handle gone, a refusal still consuming, an
  unknown option refused. handle_replace had no test before.

## D35. One test call (2026-10-15, decided)

The fourth of V1's merges: one call, 97 → 96.
- **CROI_SYS_TEST (6)**, test_profile until now, takes test_report's
  job as op 14, CROI_TEST_REPORT(value): the value the kernel's side of
  a self-test reads. The other ops are TestHooks' as before.
- **test_report is gated now.** It was open to every process; like the
  hooks, it answers NOT_SUPPORTED unless `croi.test=1` or
  `croi.debug_syscalls=on`. Every boot that runs the self-tests has
  `croi.test=1`.
- **Tests:** the callers (usertest.c's four, the interrupts suite's
  latency report) moved to the op; the self-tests that read the values
  are the check.

## D36. vmo_get_size and process_info become info topics (2026-10-15, decided)

The fifth of V1's merges: two calls, 96 → 94.
- **vmo_get_size** (44) is object_get_info's VMO topic: `size_bytes`
  is the same size (a reference's is its root's, K14g) and needs no
  rights either. `croi_vmo_size(vmo, &size)` in `croi/syscall.h` wraps it
  for userboot, m2 and the tests.
- **process_info** (68), croi's own call, is CROI_INFO_PROCESS, which
  already held the return code and the STARTED and EXITED flags (and
  more). croi_process_info_t and its flags go.
- **Cost:** the VMO topic also counts what is committed, a walk of the
  VMO's pages. Its callers size a VMO once, before mapping it (bootfs,
  the boot data, trace rings), so none is on a hot path.
- **Tests:** the size checks (VmoSuite's, usertest.c's nine) and every
  exit code read go through the topics.

## D37. vmo_read and vmo_write are cut (2026-10-15, decided)

V1's cut of the two VMO copy calls: 94 → 92. Bytes go in and out of a
VMO through a mapping, the one way to reach its pages.
- **Callers:** userboot fills a misaligned segment and writes the
  relocations through a mapping of its own; m2 writes its exit test's VMO
  the same way. The tests' copies go through `vmo_get`/`vmo_set` in
  usertest.c, which map the pages a copy spans.
- **What a reader learns:** vmo_read returned why a page couldn't be
  had; a fault had no way to say. Now `UserAspaces.handleFault` throws
  the status and a user page fault's exception carries it as its
  `synth_code`, as Zircon's does: a pager's FAIL status, BAD_STATE once
  the pager detached, NOT_FOUND for a discarded VMO or no mapping,
  OUT_OF_RANGE past a shrunk end, ACCESS_DENIED for an access the
  mapping doesn't allow, NO_MEMORY.
- **Lost:** vmo_read's read-ahead. A read across two of a pager's pages
  was one request; through a mapping it is a fault and a request each.
  A pager that wants read-ahead supplies more than it was asked for
  (supply_pages takes any range). Reading an uncached or device VMO is now a
  mapping with that cache policy, not a refusal. vmo_read read a zero
  interval's zeros, and a child's parent, without committing; a read
  fault commits the page, so a child's first read takes its copy and a
  read inside a zero interval splits it (Zircon's "at least on write"
  allows both). Checks 413/414, 575, 670, 673 and 675 no longer read there.
- **Found:** a fault on a pager VMO whose page changed hands between its
  looks and the commit (a supply, ZERO, writeback) failed with NO_MEMORY,
  killing the thread; vmo_read's copy retried, which hid it until check
  740's stress read through a mapping. The fault now waits for the pager
  or retries, as the copy did.
- **Kept:** the kernel's page-locked copy (`VmoUserCopy`, K14h) stays
  for process_read_memory and process_write_memory.
- **Tests:** the bad-pointer checks and mode 0's copies went with the
  calls. The checks of vmo_read's statuses moved to the vmo suite's
  `faultStatuses`, which reads them from faults' exceptions; K14h's
  copy race moved there too, over process_read_memory.

## D38. The debuglog becomes a read-only ring; debuglog_read is cut (2026-10-15, proposed)

V1's last cut (`docs/syscall-audit.md` §2, roadmap V1 item 5): one call,
92 → 91, the audit's target. It lands after the one ring (item 4): the
debuglog is the first ring the kernel produces, so it uses that ring's
layout, not one of its own.
- **One ring, overwrite mode.** Architecture §3's ring is SPSC, and its
  producer waits for the consumer cursor. The debuglog's producer is the
  kernel, which never waits; its readers are any number of processes,
  mapping it read only. So the one ring gains a header flag, OVERWRITE:
  the producer ignores the consumer cursor (offset 128 stays zero), and
  each slot begins with its u64 sequence number, which the producer sets
  to all ones before it writes the slot and to the sequence after,
  each with release order, then advances the producer cursor. A reader
  keeps its cursor to itself: it skips to `producer - count` if it fell
  behind (the gap is its drop count), copies a slot, and keeps it only
  if the slot's sequence read the same, and equal to its cursor, before
  and after the copy. This is a format rule, so item 4's Swift ring,
  `ring.h` and the model checker cover it. The trace rings' CIRCULAR
  mode is the same idea; they move onto the ring at V2 (audit §4).
- **The slots** are today's: 512 of 256 bytes, each a `croi_log_record_t`
  and its text. The format descriptor names log records. The ring lives
  in a contiguous VMO mapped into the kernel, as the trace rings do; the
  dumper reads it in place and is otherwise unchanged.
- **The doorbell** is a counter the kernel owns, made at boot. Its value
  is the producer cursor: each record adds one, after the cursor's
  release. A reader that has caught up binds a VALUE trigger at its
  cursor plus one, which is how it declares that it is waiting (§3); one
  that wants a packet per record binds CHANGE. This is the first counter
  the kernel adds to; `Counters.add` is already a plain locked call.
- **Delivery, as D31's root account.** Userboot gets the ring as
  CROI_PA_VMO_DEBUGLOG (READ | MAP | GET_PROPERTY, no WRITE) and the
  counter as CROI_PA_DEBUGLOG_COUNTER (READ only: readable and bindable,
  not addable), and passes them to whoever reads the log: today the
  self-tests, at V2 todhchai's console service, at V3 `log -f`. Holding
  the handles is the right to read; the debuglog system resource
  (base 12) has no other use and goes with it.
- **debuglog_create loses READABLE.** Every log object only writes, so
  it takes no resource: `debuglog_create(0, 0, out)`. A log object's
  reader position, its READABLE signal and the readers list go.
  CROI_INFO_DEBUGLOG (written, printed) stays: m2 paces its trace export
  by it.
- **Callers:** the Swift boot test's round trip (`user/test/swift/Main.swift`)
  and usertest.c's record search (its debuglog_read loop) move to a Swift
  `debuglog` suite, which reads through the mapping. todhchai's console
  service (`services/console/Main.swift`) and `Debuglog.reader` in its
  `sys` move to the ring when V2 lifts them.
- **Tests:** the suite checks that a record written comes back with its
  pid, tid, severity and text; that a caught-up reader's VALUE binding
  fires on the next write; that a reader lapped by more than 512 records
  resynchronises and counts its drops; and that the VMO and counter
  handles refuse WRITE, a writable mapping and counter_add. The model
  checker covers torn slots.
- **Lost:** per-reader positions kept by the kernel (a reader keeps its
  own), and READABLE as a signal (the counter replaces it). Reading needs
  a 132 KiB mapping where it needed a 256-byte buffer.
- **Rejected:** a READABLE log object that hands out the VMO and counter
  (two handles from one call, and a second way to gate reading); a
  separate overwrite ring format (principle 6); a counter add only when
  a reader is bound (the add is cheap, and a VALUE binding already
  fires at once on a value it has passed).

## D39. handle_duplicate takes an array (2026-10-15, decided)

The first of V1's batched forms (`docs/syscall-audit.md` §3, roadmap V1
item 3). The count stays at 92: the array form replaces the single one.
- **handle_duplicate(items, count)** (11) takes up to 64
  `croi_handle_duplicate_item_t` (ipc.h, 24 bytes): handle, rights and
  options in; the new handle and a status out. It follows object_bind
  (D20), not handle_close (D33): in order, stopping at the first item
  that fails, each processed item's status written back, the count of
  successes returned. A bad pointer or count fails the call before any
  item is done, and nothing done is undone (audit §3). handle_close
  goes on past a bad handle because closing has nothing to leave half
  done; a duplicate's caller needs to know which handles it holds.
- **CONSUME is per item** (D34's replace): a batch can duplicate some
  handles and replace others.
- **A new handle whose value can't be written back is closed again.**
  Nobody could learn its value, so it would leak until the process went.
- **Callers:** `croi_handle_duplicate(handle, rights, &out, options)` in
  syscall.h is the one-item form, as `croi_handle_close` is D33's;
  usertest.c and the suites (`Sys.duplicate`) use it. Userboot
  duplicates the new process's process and thread handles in one call,
  the launcher case audit §3 names.
- **Tests:** the objects suite's `duplicateMany`.

## D40. The wakes take arrays: port_queue, port_wait, counter_add, interrupt_ack (2026-10-15, decided)

The second family of V1's batched forms (`docs/syscall-audit.md` §3,
roadmap V1 item 3). The count stays at 92: each array form replaces its
single form.
- **port_queue(port, packets, count)** (32) queues up to 64 user packets
  to one port, in order, and stops at the first that fails (SHOULD_WAIT
  when the port is full; the packets after it would fail too, and their
  order matters). It returns how many it queued, or the first packet's
  status if that one failed: a packet has no status of its own to write
  back (its `status` field is the receiver's payload). The packets are
  only read, so no writable precheck: an unreadable one stops the batch.
- **port_wait(port, deadline, packets, count, leeway)** (33) waits only
  while the port is empty, then takes up to `count` (64 at most) without
  waiting again, and returns how many. The leeway moves to the fifth
  argument. A packet popped but not copied out (an unmapped page past
  the precheck) ends the batch; it is lost, as one was before.
- **counter_add(items, count)** (161) and **interrupt_ack(items, count)**
  (142) take up to 64 `croi_counter_add_item_t` (counter.h: handle,
  status, int64 amount; 16 bytes) or `croi_interrupt_ack_item_t`
  (interrupt.h: handle, status; 8 bytes). They go on past an item that
  fails, as handle_close does (D33), not stop as object_bind and
  handle_duplicate do (D39): each item stands alone and leaves nothing
  half done, and a service ringing every client's doorbell should ring
  the rest when one client has gone. Each item's status is written back;
  the call returns how many succeeded. A bad pointer or count fails the
  call before any item (`Syscalls.eachItem`).
- **Callers:** syscall.h's `croi_port_queue`, `croi_port_wait`,
  `croi_counter_add` and `croi_interrupt_ack` are the one-item forms;
  usertest.c, the suites, m2 and userboot use them. m2's wake budgets
  match counter_add's trace records by their first argument, now the
  item's address, so the measured adds go through one static item.
- **Port batches are interim** (audit §3): ports become rings (D19, V1
  item 5), and then a wait drains the ring.
- **Tests:** the objects suite's `packetBatches`, the counters suite's
  `batch`, and a batch ack in the interrupts suite's state machine.

## D41. channel_read and channel_write take arrays (2026-10-15, decided)

The third family of V1's batched forms (`docs/syscall-audit.md` §3,
roadmap V1 item 3). The count stays at 92. channel_call keeps one
channel: its batch is the Node operations in its message (D18, V2).
- **channel_write(items, count)** (81) takes up to 64
  `croi_channel_write_item_t` (ipc.h, 40 bytes: channel, options, bytes,
  handles, their counts; a status out), and **channel_read(items,
  count)** (82) up to 64 `croi_channel_read_item_t` (48 bytes: channel,
  options, buffers, capacities; the actual sizes and a status out). The
  packed capacities and actuals of K7b go: each is a field of its own.
- **Both go on past an item that fails**, as counter_add and
  interrupt_ack do (D40): one client gone (PEER_CLOSED) or one channel
  with nothing to read (SHOULD_WAIT) is a server's ordinary case, and
  shouldn't keep the rest of its replies or reads back. Each item's
  status is written back, and a read item's actual sizes on success and
  on BUFFER_TOO_SMALL; the call returns how many succeeded.
- **A write item's handles are consumed whether it succeeds or not**, as
  Zircon's are. A bad pointer or count fails the call before any item and
  consumes nothing, since the handles can't be known (channel_call's rule
  for unreadable arguments).
- **Callers:** syscall.h's `croi_channel_read` and `croi_channel_write`
  are the one-message forms; usertest.c, the C runtime's bootstrap read,
  m2 and userboot use them, and the suites `Sys.readChannel` and
  `Sys.writeChannel`.
- **Tests:** the channel suite's `batches`: three writes, the middle one
  to a channel whose peer is gone (two done, PEER_CLOSED, its handle
  consumed); three reads (one message, one too small with the size it
  needs, one SHOULD_WAIT); counts 0 and 65.

## D42. vmar_map, vmar_unmap and vmar_protect take arrays (2026-10-15, decided)

The last family of V1's batched forms (`docs/syscall-audit.md` §3,
roadmap V1 item 3). The count stays at 92.
- **vmar_map(vmar, items, count)** (71) takes up to 64
  `croi_vmar_map_item_t` (task.h, 48 bytes: VMO, options, VMAR offset,
  VMO offset, length; the address and a status out), all into one VMAR.
  It **stops at the first item that fails**, as object_bind and
  handle_duplicate do: a program's segments are all or nothing, and its
  loader tears the process down on any failure, so mapping the rest is
  wasted work. What it mapped stays mapped (audit §3).
- **vmar_unmap and vmar_protect(vmar, ranges, count)** (72, 73) take up
  to 64 `croi_vmar_range_t` (24 bytes: address, length, options; a
  status out), unmap's with options 0, protect's with the permissions.
  They **go on past a range that fails**, as counter_add and the channel
  calls do (D40, D41): each range stands alone, and teardown should
  unmap the rest.
- Each call returns how many succeeded; a bad pointer or count fails it
  before any item. The packed `vmar | options << 32` first argument goes
  from these three; vmar_allocate and vmar_map_view keep it, and
  vmar_unmap_handle_close_thread_exit stays one range (it ends the
  thread).
- **Spawn maps a program's segments in one call:** userboot's `load`
  prepares each segment's item (the bootfs VMO for a read-only segment
  as it is, else a filled, relocated VMO of its own) and `mapSegments`
  maps them all at once; the segments' VMOs are closed after. This is
  the case audit §3 names for spawn → main < 200 µs.
- **Callers:** syscall.h's `croi_vmar_map`, `croi_vmar_unmap` and
  `croi_vmar_protect` are the one-item forms, in Zircon's argument
  order; usertest.c (71 sites, rewritten mechanically), the C runtime's
  malloc, the suites, m2 and userboot use them.
- **Tests:** the vmo suite's `vmarBatches`: four maps whose third names
  no handle (two mapped, BAD_HANDLE, the fourth untried), three protects
  and three unmaps whose middle range fails (two done each), counts 0
  and 65.

## D43. The one ring: Ring.swift, ring.h, and RingCheck on both (2026-10-15, decided)

Roadmap V1 item 4: architecture §3's ring, in Swift and as a C23 header,
with a model checker. Doorbells are counters (D20's CHANGE binding).
- **One format, two implementations.** `lib/ring/ring.h` defines it and
  implements it for C-side drivers; `lib/ring/Ring` (Ring.swift,
  RingMemory.swift) is the Swift one, built into user programs as it
  stands (no Foundation, no ARC types) and into the host package. A host
  test (`RingTests.oneFormat`) pins every constant and the header bytes
  equal. The layout is §3's, with what it left open settled: each side's
  128-byte line holds its u64 cursor and, at +8, a u32 waiting word; the
  header at 256 is magic "VRNG", version 1, flags, slot size (a multiple
  of 8, up to 64 KiB), slot count (a power of two, up to 2^20) and the
  format descriptor (a u64 both sides agree on).
- **The protocol is NeoVectra's vx-ring's, both ways.** A side about to
  sleep sets its waiting word, fences (seq_cst), and looks again; the
  other side fences after moving its cursor and rings only if the word is
  set. So the consumer sleeps on an empty ring and the producer on a full
  one, and neither enters the kernel while both are busy. The calls are
  batch-first (principle 12): `space`/`ready` say how many, `publish`
  and `release` move the cursor by a count, and each says whether to
  ring the other side's doorbell. Shared memory is hostile: the header is
  validated once against what the side expects and used from a private
  copy, every slot is copied out exactly once, and a cursor that runs past
  the other's breaks the ring for good.
- **OVERWRITE is a header flag** (D38): the writer never waits, readers
  keep their cursors to themselves, and each slot starts with its u64
  sequence, all ones while it is written. A reader keeps a copy only if
  the sequence read its cursor before and after; anything else drops that
  one record, so a writer stopped halfway never holds a reader up.
- **RingCheck runs the real code** (the owner's choice over checking a
  hand-written model, as vx-check did). Ring is generic over
  `RingMemory`, and ring.h's atomics and slot copies are macros; the host
  check build sends both to the checker (`CheckedMemory`, and
  CROI_RING_CHECKED's hooks). Model threads run as coroutines (a small C
  shim over ucontext; Swift can't call makecontext), and every memory
  operation is a point where the checker chooses what happens next. It
  explores every order depth first, replaying each from the start, and
  prunes a state it has reached before. Its memory model lets stores
  reach memory out of order, as arm64 does, except where release orders
  and fences forbid it; loads are never reordered, so it can't show that
  an acquire, or the consumer's release (its copies before its cursor),
  is needed. Coroutine code runs without Swift's runtime exclusivity
  checks, whose record of accesses switching stacks would break.
- **What it checks, on both implementations alike:** the wakes (one and
  three entries through two slots, so that the producer waits too: about
  124,000 states for three), and OVERWRITE with a lapping writer (no
  torn record kept, in order, kept plus dropped equals written). Broken
  on purpose, each must fail: no producer fence, no consumer fence, a
  relaxed publish (the consumer reads a slot before its bytes land), no
  recheck, and a writer without its release orders (a torn record kept).
  The model tests take about 40 s in a debug build.
- **On the target:** a `ring` suite (two threads, a VMO, counters bound
  CHANGE as doorbells; refusals, 20,000 entries checked, a consumer asleep
  first woken), and m2's budgets from performance.md: `ring.per_1000_slots`
  (limit 10 µs: 100 M slots/s, 64-byte slots, across cores),
  `ring.round_trip` (submission and completion, both busy: limit 300 ns)
  and `ring.kicks` (doorbells rung, both busy: 0). KVM, one run: 6.3 µs,
  100 ns and 0.
- **Not yet:** the kernel produces no ring until item 5 (ports, D19; the
  debuglog, D38), and ring.h isn't on a target include path until a
  C-side driver uses it (V2). The byte-stream mode audit §4 mentions for
  pipes comes with them.
