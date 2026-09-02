# The scheduler

`kernel/sched/` — `thread.odin`, `queue.odin`, `sched.odin`, `verify.odin`

A preemptive priority round-robin over one core. The `Cpu` struct is already
per-core, so a second core is a lock word and an AP trampoline rather than a
rewrite. There are sixteen priority levels, and they are dynamic. A thread that
consumes a whole slice sinks a level. A thread that blocks, and that something
then wakes, rises to its base and a little above. That is the whole
anti-starvation mechanism, and it is why there is not a separate one.

## The switch

There is one context-switch mechanism and one place that performs it. The
assembly tail in `kernel/arch/amd64/idt.odin` is the only code in Vectra that
reloads `rsp` from something other than a `pop`. It does that for a preemption,
a voluntary yield and an ordinary interrupt return, and it never learns which
of the three it has:

```
    thread A ---- int $0x81 -----+
                                 |
    timer -------- vector 0x20 --+--> trap tail --> reschedule --> thread B
                                 |     (fxsave)      (policy)       (fxrstor)
    fault --------- vector n ----+                                  (rsp swap)
```

A handler receives the state it interrupted, and returns the state to resume. If
those are the same, nothing happened. If they are different, that was a context
switch. The saved state lives on the switching thread's own stack. That state is
an `arch.Resume`, a `Trap_Frame` pointer and a 512-byte FXSAVE image. Nothing
about it is per-CPU, and none of it is a global.

**Priority is dynamic, as it is in Plan 9.** There are sixteen levels. The
highest non-empty level wins, and rotates within itself. A thread that burns a
whole slice and never blocks drops a level, with a floor of 1. A thread that
blocks, and that something then wakes, rises to its base plus one. The cap is
the bottom of the realtime range.

That is the entire anti-starvation mechanism, which is why there is not a
second one. The boot line shows it: three
compute-bound threads start at 8 and are at 5 by the time the test ends.

**The core's *class* is a first-class input, on a machine that has one class.**
`arch.cpu_class` reports a class and a capacity. A time slice is
`QUANTUM_TICKS * 1024 / capacity`, which is equal work per round rather than
equal time. A thread on a half-speed core therefore gets twice the ticks. On
amd64 that is always `.Performance` at 1024, and the arithmetic is a no-op.

It is there now for two reasons. A retrofit of capacity-awareness into a
scheduler is a rewrite, and a number added to a struct is not. And arm64 will
report three classes.

## Placement, the other half of the class

The slice arithmetic uses a core's capacity once a thread is on it. `pick_cpu`
is what decides *which* core, and it is where `class`, `capacity` and the
affinity a thread carries stop being inert. It runs at the two moments a thread
arrives on the ready side from nowhere: a `spawn`, and a wake from a block. A
thread the timer re-queues stays where it ran, because moving a thread mid-round
throws away its warm cache and its half-spent slice for nothing.

The rule is two comparisons, in order:

1. **Affinity is a hard filter.** A thread that named a set of classes runs on
   one of them. If none is present, it falls back to the boot core rather than
   stranding on a class that does not exist yet. On amd64 every core is
   `.Performance`, so a thread pinned to anything else takes this fallback, and
   there is one core to take it.
2. **Least loaded wins, per unit of capacity.** Load is a core's ready count
   scaled to a common capacity, so a core at twice the speed carries twice the
   threads before it counts as equally loaded. That is what sends steady work to
   the big cores and keeps the little ones for the overflow. A tie goes to the
   faster core, so an idle machine uses its best core first.

**On one core this returns that core every time, and it changed no behaviour the
day it landed.** That is what lets it be built now. The decision is a pure
function of the cores and the thread. So `kernel/sched/verify.odin` drives it
against a fabricated three-class machine, without waiting for a second real core
to boot. The machine is a little, a middle and a big core at one, two and four
units of capacity.

Seven checks cover it. The idle machine takes its fastest core. Affinity filters
both ways. A big core holding three threads is still less loaded than a little
core holding one. The overflow spills down. A class no core has falls back.

The last check ties the pure decision to the live wiring. On this machine's real
cores, every placement is this one core.

Three controls, each breaking one rule. Drop the affinity filter and the
efficiency-pinned thread lands on the big core. Measure load by head count
rather than per capacity and the busier big core loses a race it should win.
Break the capacity tie and the idle machine picks the little core first. Each
fails exactly the check its rule is behind.

## What preemption cost elsewhere

**The heap has a lock.** `kernel/sync` is that lock. On one core with no SMP,
`nothing else can run` and `interrupts are off` are the same statement.
`Spinlock` is therefore a name for the interrupt flag, with the nesting handled.

There is no lock *word* yet, and that is deliberate. A second core needs one,
and this tree already found and wrapped every site that will need it. `alloc`,
`free` and `resize` take it. `resize` calls `alloc`, which is why it nests.

**`kernel/vfs` has one now too. It has five, and the interesting part is that
they do not all behave the same way.** See the next section.

## Decisions, and what would reverse them

- **A deadline that fires reschedules immediately, and charges nobody.**
  `sync.tick` reports how many threads it started. `on_tick` switches when that
  count is non-zero, and passes `spent_slice` as false. The running thread did
  not spend a slice. A thread that asked for a wake at tick N, and that gets the
  core at tick N+9, did not wake at tick N. This is why `reschedule`'s flag is
  `spent_slice` and no longer `voluntary`. The question is about the outgoing
  thread, not about the reason for the switch.

## Two scheduler bugs that `kernel/sync` found

`docs/SYNC.md` carries both, rather than this file. That is where they were
found, and the story only makes sense from that side:

- **Decay measured interruptions, not CPU.** Every dispatch refilled
  `Thread.ticks_left`, which is the same rule as a refill every slice for
  exactly as long as nothing blocks. The first sleeping lock made the difference
  reachable, and it was severe.
- **A wake from a lock is not a wake from I/O.** `ready` boosts and `unpark`
  does not, and the distinction is what keeps five contending threads
  distinguishable.

## See also

- `docs/SYNC.md` — what parks a thread, and everything that wakes one.
- `docs/TESTING.md` — how the preemption self-test is kept honest.
