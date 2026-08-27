# The self-tests, and what they cost to make honest

`kernel/verify_*.odin`, `kernel/*/verify.odin`, `sys/vectra9/verify.odin`

Vectra has no test harness and no host-side test build. Every layer proves
itself on the machine that will run it, during boot, and reports one line. That
is a deliberate trade. A self-test that runs on real hardware against the real
page tables finds a different class of bug. A self-test on a workstation against
a mock finds another. The first is the class this project keeps hitting.

The cost is that a self-test can be *unfalsifiable*. It passes because it cannot
fail, rather than because the code is right, and nothing about a green line says
which. So every milestone ends the same way. Mutate the code, one change at a
time, and record which checks catch it. **The mutations that nothing catches are
the more interesting half**, and each subsystem's document lists them rather
than files them as gaps.

## The self-tests, and what they cost to make honest

Two halves. The cooperative half runs **before** the timer is armed, on purpose.
A cooperative scheduler is deterministic, so a failure there is reproducible. And
an asynchronous interrupt source added to a scheduler that nothing has yet shown
to switch correctly makes every later bug two bugs. The preemptive half then
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

The FPU check began as four floating-point accumulators in an ordinary Odin
loop. It passed with the FXSAVE removed. The disassembly said why. An
unoptimised build spills every temporary to the stack after each instruction, so
the values sat on the thread's own stack. A thread's own stack survives by
construction, so the check tested nothing.

It is now `fpu_hold`, a single asm
block that fills xmm0..xmm3 and spins *inside itself* until something tells it
to stop. Those registers are therefore live across every preemption the worker
takes.

The seventh control removes the EOI from the tick handler, and it did not fail.
It **hung**. The last line printed was the timer's own success.
`verify_preemption` waited on the tick count with no bound, so a timer that
stopped stopped the boot.

It now checks liveness instead. Every 20 million times round the spin, the tick
count must move. A self-test that hangs is worse than one that fails. It says
nothing, in the place hardest to attach a debugger to.

## Measuring a concurrency test in ticks

`kernel/verify_vfs.odin` runs five threads for a fixed number of *ticks*, not a
fixed number of rounds, and that distinction was worth a rewrite.

The first version ran a fixed round count. With the session lock removed it
failed correctly under `just run`, and passed under `just release` every time.
The optimised kernel does the same 3,600 operations in a thirteenth of the
ticks. It therefore got a thirteenth of the preemptions, and tested itself
thirteen times less thoroughly.

What finds a race is not how much work happens. It is how often a timer
interrupts a thread in the middle of some. Both builds now get the same thousand
ticks. The fast one simply gets more done between them, and the control fails in
both.

A tick-driven run also grew the churn thread's share of it from a sixth to all
of it. That is what surfaced the `generation` bug in `docs/NAMESPACE.md`.

**Five of seven mutations are caught. The two that are not are the more
interesting half**, and the file says so rather than files it as a gap:

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
of it. The story was that a uniprocessor holds the interrupt flag for most of
its instructions, and is therefore nearly impossible to interrupt. A tick rate
raised to 20 kHz delivered only about 1.4× as many ticks, because the LAPIC
coalesces what it cannot deliver. So **a Vectra thread doing file I/O was very
nearly non-preemptible**.

A sleeping session lock removed that objection completely. The same run now parks
and switches *a hundred thousand times*, at every message boundary, in both build
modes. Neither mutation was caught.

So the real reason is narrower, and worth keeping. Both windows are two or three
instructions wide, and neither is at a lock boundary. One is the gap between a
reference count loaded and stored back. The other is the gap between a member
read out of the table and cloned.

Voluntary switches, however many, do not interleave two threads at an arbitrary
instruction. Only a timer does, and there are still about a thousand of those per
run. **Only a second CPU makes these
reachable**, which is exactly why they are cheap to leave in now and expensive
to find later.

## A control that runs on every boot

`kernel/verify_payload.odin` does something the tables above do not, and it is
worth copying where it fits.

Somebody applies every other mutation in this document by hand, observes it
once, and records it in prose. That is honest, and it decays. The mutation is
not in the tree, so nothing re-runs it. A later change that quietly makes a
check unfalsifiable again goes unnoticed until somebody repeats the exercise.

The payload buffer had a control that could stay. The server under test can be
told to answer the old way, out of one buffer for the whole server. That is
exactly what a 9P server looked like before the milestone. Eight readers run
against it, and the check is that they corrupt each other. The same eight then
run against the real arrangement, and the check is that they do not.

    one buffer for the server    1 reader of 8 got its own bytes back
    one buffer per slot          8 of 8

**A failure to corrupt is itself a failure.** Nobody has to revert anything or
reason about anything. If a later change makes the shared arrangement stop
corrupting, the boot says so on the line where the property lives.

This only works where the wrong arrangement is *expressible* rather than absent
— a flag on a test server, not a deleted line of kernel code. Where it is
expressible, it is worth the twenty lines.

## Where the other control tables are

| Subsystem | Table | Caught |
|---|---|---|
| The namespace under five threads | above | 5 of 7 |
| The sleep queue | `docs/SYNC.md` | 6 of 8 |
| `Tflush` and its transport | `docs/TRANSPORT.md` | 5 of 6 |
| The payload buffer per request slot | `docs/TRANSPORT.md` | 3 of 4 |

**The uncaught ones cluster, and the cluster is the finding.** Every one of them
is a window two or three instructions wide, and none is at a lock boundary.

One is a count loaded and stored back. Another is a slot claimed and not yet
marked. Only a second CPU makes any of them easy to reach. That is why they are
cheap to leave in now, and expensive to find later.

## See also

- `docs/SCHED.md` — the preemption self-test, and why it spins inside itself.
- `docs/HANDOFF.md` — the boot log every one of these lines appears in.
