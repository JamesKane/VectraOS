# D139. A channel_call's request and reply wake their thread on the waker's CPU, Zircon's synchronous wake (2026-10-26, decided; extends D68's amendment)

On the Orange Pi 6 Plus, D127's small-file row has fs blocking and
waking ~45,000 times a second, about twice per request, and ~13% of its
time in port_wait's block and wake. Each request woke fs on an idle CPU
by IPI while the client's CPU went idle, and each reply woke the client
on its now idle CPU in turn: two sleeping CPUs woken per round trip.

Zircon avoids both. `channel_call` writes its request with the caller's
waiter queue (`write_self_locked(..., Some(&waiter.wait_queue))`), which
the port observer passes to `Semaphore::Post`, which wakes the server
with `Scheduler::UnblockSynchronous`: placement takes the caller's CPU
if the work is admissible there, and the reschedule waits until the
caller blocks, so the server replaces it in one switch. The reply is an
ordinary wake, but placement keeps a thread on its last CPU when that
CPU's estimated queue time is within `INTRA_CLUSTER_THRESHOLD` (25 µs),
so the caller stays behind a server that blocks again at once. croi's
`place` counts load, not queue time: a busy last CPU always loses to an
idle one.

**The decision (owner, 2026-10-26):**
- **A wake can be synchronous** (`Scheduler.Wake`, beside the lent
  profile it replaces as the parameter on the notify path: one value,
  `updateSignals` → `Observers.notify` → the port → `wakeOne` →
  `place`). `Channels.call` marks its request's write; `finishCall`
  marks the reply's wake of the caller. Nothing else does.
- **Where it goes:** the waker's CPU, if only the waker runs there,
  unless the CPU `FairPlacement.prefers` is idle and bigger
  (`FairPlacement.placesOnWaker`): D68's race to completion still moves
  work off a little core. Deadline and pinned threads place as before.
- **The reply carries the mark too** (option b), not Zircon's
  queue-time rule (option a): that needs per-thread demand, D68's
  proposal, and changes every fair placement. It can replace this when
  demand tracking lands.
- **Steals are left alone:** between the request and the caller's
  block, its CPU has a load of 2, so a CPU going idle may take the
  server (Zircon's check against that is compiled out too).

Rejected: marking the request only (the reply then moved the client to
an idle CPU and the next request pulled fs after it: both would change
CPUs every request, where fs stays put today); a per-CPU "waker" flag
set around the write (an interrupt's wake in that window would read
it).

Covers: kernel Sched/Scheduler.swift, Sched/Profile.swift,
Object/Channel.swift, Object/Wait.swift, Object/Port.swift,
Object/KernelObject.swift; channel(2); docs/kernel/design/cpu.md,
zircon-divergences.md. Tests: the sched self-test's policy orders;
ChannelSuite's synchronous wake (most of 40 calls on one CPU). Measured
on the board with D127's small_read and tree_walk (bench/peers
NOTES.md).
