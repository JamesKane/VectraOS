# D139. Zircon's synchronous wake for channel_call, tried and rejected: on the Orange Pi 6 Plus a client and server on two CPUs beat taking turns on one (2026-10-26, rejected; D68's amendment unchanged)

On the Orange Pi 6 Plus, D127's small-file row has fs blocking and
waking ~45,000 times a second, about twice per request, and ~13% of its
time in port_wait's block and wake. Each request woke fs on an idle CPU
by IPI while the client's CPU went idle, and each reply woke the client
on its now idle CPU in turn.

Zircon avoids both. `channel_call` writes its request with the caller's
waiter queue, which the port observer passes to `Semaphore::Post`,
which wakes the server with `Scheduler::UnblockSynchronous`: placement
takes the caller's CPU if the work is admissible there, and the
reschedule waits until the caller blocks. The reply is an ordinary
wake, but placement keeps a thread on its last CPU when that CPU's
estimated queue time is within `INTRA_CLUSTER_THRESHOLD` (25 µs), so
the caller stays behind a server that blocks again at once.

**What was tried (owner's choices, 2026-10-26; 32af4a3, reverted):**
a `Scheduler.Wake` value on the notify path carrying a synchronous mark,
set by channel_call's request and by its reply (option b, in place of
Zircon's queue-time rule, option a); the woken thread went on the
waker's CPU if only the waker ran there, unless a bigger CPU was idle;
steals in the window were left alone.

**What the board measured** (five runs each, one session):

| Kernel | small_read | tree_walk | fs migrations/s |
|---|---|---|---|
| without it (a92ef1b) | 48.7–53.3 µs | 91–104 µs/entry | 11 |
| request and reply marked | 69.5–74.5 | 106–113 | 24,739 |
| + the waker not preempted | 71–75 | 109–117 | 24,438 |
| + close's PEER_CLOSED marked too | 54–70 | 90–114 | ~0 |

read_4k was unchanged (8.6–12.6 µs throughout).

- **The reply preempted fs at once:** a fair thread running alone has
  no slice timer, and `preemptIfRequested` takes that as its slice
  ended, so any wakeup onto its CPU switches it out. fs sat queued
  behind the client, a CPU going idle stole it, and the next request
  pulled it back: two migrations a request.
- **Without that, the close moved it:** a small_read iteration is open
  and read (channel_calls) and close, whose PEER_CLOSED is an ordinary
  wake: fs went to an idle CPU and the next reply pulled the client
  after it. Zircon covers this with its queue-time rule; a hint on
  channel_call alone can't.
- **With every wake of fs local** (28,118 of 28,141), small_read was
  no better than without the change. On two warm A720s, the IPI wakes
  cost about what the overlap of fs's work after a reply with the
  client's next step gains. So option (a) would not pay here either.

**Decision (owner, 2026-10-26):** rejected and reverted. Fair placement
stays as D68's amendment has it (race to completion, `steal_thresh`).
Worth a second look only on a machine where a CPU's wake is dear
(deep idle states, a busy interrupt CPU) or where the server's work
after a reply is small; measured, as here, against the rows above.

Covers: nothing in the tree (reverted). Measured: bench/peers
2026-10-25-vectraos NOTES.md.
