# The scheduler

`kernel/sched/` — `thread.odin`, `queue.odin`, `sched.odin`, `verify.odin`

A preemptive priority round-robin over one core, with the `Cpu` struct already
per-core so that a second one is a lock word and an AP trampoline rather than a
rewrite. Sixteen priority levels, dynamic: a thread that consumes a whole slice
sinks a level, a thread that blocks and is woken is lifted back to its base and
a little above. That is the whole anti-starvation mechanism and it is why there
is not a separate one.

## The switch

There is one context-switch mechanism and one place that performs it. The
assembly tail in `kernel/arch/amd64/idt.odin` is the only code in Vectra that
reloads `rsp` from something other than a `pop`, and it does that for a
preemption, a voluntary yield and an ordinary interrupt return without knowing
which it has:

```
    thread A ---- int $0x81 -----+
                                 |
    timer -------- vector 0x20 --+--> trap tail --> reschedule --> thread B
                                 |     (fxsave)      (policy)       (fxrstor)
    fault --------- vector n ----+                                  (rsp swap)
```

A handler is handed the state it interrupted and returns the state to resume. If
those are the same, nothing happened. If they are different, that was a context
switch. The saved state — `arch.Resume`, a `Trap_Frame` pointer and a 512-byte
FXSAVE image — lives on the switching thread's own stack, so nothing about it is
per-CPU and none of it is a global.

**Priority is dynamic, following Plan 9.** Sixteen levels; highest non-empty
wins and rotates within itself. A thread that burns a whole slice without
blocking drops a level, floored at 1. A thread that blocks and is woken is
lifted to its base plus one, capped below the realtime range. That is the entire
anti-starvation mechanism, which is why there is not a second one, and it is
visible in the boot line: three compute-bound threads start at 8 and are at 5 by
the time the test ends.

**The core's *class* is a first-class input, on a machine that has one class.**
`arch.cpu_class` reports a class and a capacity, and a time slice is
`QUANTUM_TICKS * 1024 / capacity` — equal work per round rather than equal time,
so a thread on a half-speed core gets twice the ticks. On amd64 that is always
`.Performance` at 1024 and the arithmetic is a no-op. It is there now because
retrofitting capacity-awareness into a scheduler is a rewrite and adding a
number to a struct is not, and because arm64 will report three classes.

## What preemption cost elsewhere

**The heap has a lock.** `kernel/sync` is that lock: on one core with no SMP,
"nothing else can run" and "interrupts are off" are the same statement, so
`Spinlock` is a name for the interrupt flag with the nesting handled. There is
no lock *word* yet and that is deliberate — a second core needs one, and every
site that will need it has already been found and wrapped. `alloc`, `free` and
`resize` take it; `resize` calls `alloc`, which is why it nests.

**`kernel/vfs` has one now too — five of them, and the interesting part is that
they do not all behave the same way.** See the next section.

## Decisions, and what would reverse them

- **A deadline that fires reschedules immediately, and charges nobody.**
  `sync.tick` reports how many threads it started and `on_tick` switches when
  that is non-zero, with `spent_slice` false: the running thread did not spend a
  slice, and a thread that asked to be woken at tick N and gets the core at tick
  N+9 was not woken at tick N. This is why `reschedule`'s flag is `spent_slice`
  and no longer `voluntary` — the question is about the outgoing thread, not
  about the reason for the switch.

## Two scheduler bugs that `kernel/sync` found

Both are written up in `docs/SYNC.md` rather than here, because that is where
they were found and the story only makes sense from that side:

- **Decay measured interruptions, not CPU.** `Thread.ticks_left` was refilled on
  every dispatch, which is the same thing as refilling it every slice for
  exactly as long as nothing blocks. The first sleeping lock made the difference
  reachable and it was severe.
- **Waking from a lock is not waking from I/O.** `ready` boosts and `unpark`
  does not, and the distinction is what keeps five contending threads
  distinguishable.

## See also

- `docs/SYNC.md` — blocking, and everything that parks a thread.
- `docs/TESTING.md` — how the preemption self-test is kept honest.
