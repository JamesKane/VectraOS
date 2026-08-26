# The self-tests, and what they cost to make honest

`kernel/verify_*.odin`, `kernel/*/verify.odin`, `sys/vectra9/verify.odin`

Vectra has no test harness and no host-side test build. Every layer proves
itself on the machine that will run it, during boot, and reports one line. That
is a deliberate trade: a self-test that runs on real hardware against the real
page tables finds a different class of bug from one that runs on a workstation
against a mock, and it is the class this project keeps hitting.

The cost is that a self-test can be *unfalsifiable* — passing because it cannot
fail rather than because the code is right — and nothing about a green line says
which. So every milestone ends the same way: mutate the code, one change at a
time, and record which checks catch it. **The mutations that are not caught are
the more interesting half**, and each subsystem's document lists them rather
than filing them as gaps.

## The self-tests, and what they cost to make honest

Two halves. The cooperative half runs **before** the timer is armed, on purpose:
a cooperative scheduler is deterministic, so a failure there is reproducible,
and adding an asynchronous interrupt source to a scheduler not yet shown to
switch correctly makes every subsequent bug two bugs. The preemptive half then
runs three threads that never yield, with the boot thread as a fourth.

Six negative controls, all of which now fail the run they should:

| Mutation | First failure |
|---|---|
| `reschedule` never switches | `every cooperative worker finished` |
| enqueue at the head, not the tail | `every cooperative worker finished` |
| lowest priority picked first | `both priority workers finished` |
| no decay on a full slice | `burning full slices decayed the workers below their base` |
| no boost on wake | `waking boosts it above its base` |
| no FXSAVE/FXRSTOR in the trap tail | `preemption preserved every worker's floating-point registers` |

**Two of those took a second attempt, and both are worth knowing about.**

The FPU check was written first as four floating-point accumulators in an
ordinary Odin loop. It passed with the FXSAVE removed. The disassembly said why:
an unoptimised build spills every temporary to the stack after each instruction,
so the values were sitting on the thread's own stack, which is preserved by
construction, and nothing was being tested. It is now `fpu_hold` — a single asm
block that fills xmm0..xmm3 and spins *inside itself* until told to stop, so
those registers are live across every preemption the worker takes.

The seventh control — removing the EOI from the tick handler — did not fail. It
**hung**, with the last thing printed being the timer coming up successfully.
`verify_preemption` was waiting on the tick count with no bound, so a timer that
stopped stopped the boot. It now checks liveness instead: every 20 million times
round the spin, the tick count has to have moved. A self-test that hangs is
worse than one that fails — it says nothing, in the place hardest to attach a
debugger to.

## Measuring a concurrency test in ticks

`kernel/verify_vfs.odin` runs five threads for a fixed number of *ticks*, not a
fixed number of rounds, and that distinction was worth a rewrite.

The first version ran a fixed round count. It failed correctly under `just run`
with the session lock removed — and passed under `just release`, every time. The
optimised kernel does the same 3,600 operations in a thirteenth of the ticks, so
it got a thirteenth of the preemptions and tested itself thirteen times less
thoroughly. What finds a race is not how much work happens, it is how often a
thread is interrupted in the middle of some. Both builds now get the same
thousand ticks; the fast one simply gets more done between them, and the control
fails in both.

Making the run tick-driven also lengthened the churn thread's share of it from
a sixth to all of it, which is what surfaced the `generation` bug in
`docs/NAMESPACE.md`.

**Five of seven mutations are caught. The two that are not are the more
interesting half**, and the file says so rather than filing it as a gap:

| Mutation | Result |
|---|---|
| remove `Server.lock` | caught — both listers, in both builds |
| free a referenced `Mount_Point` | caught — the reference count check |
| hold a namespace lock across a message | caught — `EDEADLK`, four checks |
| boost a thread woken by a lock | caught — two workers starved |
| serve waiters in arrival order | caught, one run in ten |
| drop `cross_mounts`' reference to a member | **not caught** |
| unlocked chan reference counts | **not caught** |

The two uncaught ones had a standing explanation, and Milestone 7 falsified half
of it. The story was that a uniprocessor holding the interrupt flag for most of
its instructions is nearly impossible to interrupt — turning the tick rate up to
20 kHz delivered only about 1.4× as many ticks, because the LAPIC coalesces what
it cannot deliver, so **a Vectra thread doing file I/O was very nearly
non-preemptible**. A sleeping session lock removed that objection completely: the
same run now parks and switches *a hundred thousand times*, at every message
boundary, in both build modes. Neither mutation was caught.

So the real reason is narrower and worth keeping. Both windows are two or three
instructions wide, and neither is at a lock boundary — the gap between loading a
reference count and storing it back, the gap between reading a member out of the
table and cloning it. Voluntary switches, however many, do not interleave two
threads at an arbitrary instruction; only a timer does, and there are still
about a thousand of those per run. **Only a second CPU makes these reachable**,
which is exactly why they are cheap to leave in now and expensive to find later.

## Where the other control tables are

| Subsystem | Table | Caught |
|---|---|---|
| The namespace under five threads | above | 5 of 7 |
| The sleep queue | `docs/SYNC.md` | 6 of 8 |
| `Tflush` and its transport | `docs/TRANSPORT.md` | 5 of 6 |

**The uncaught ones cluster, and the cluster is the finding.** Every one of them
is a window two or three instructions wide that is not at a lock boundary — a
count loaded and stored back, a slot claimed and not yet marked. Only a second
CPU makes any of them easy to reach, which is why they are cheap to leave in now
and expensive to find later.

## See also

- `docs/SCHED.md` — the preemption self-test, and why it spins inside itself.
- `docs/HANDOFF.md` — the boot log every one of these lines appears in.
