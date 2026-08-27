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

## A self-test that hangs says nothing, and it keeps happening

Twice now, in different subsystems, and the second time is what makes it a
pattern rather than an anecdote.

The first was the missing EOI in the tick handler. `verify_preemption` waited on
the tick count with no bound, so a timer that stopped stopped the boot. It
checks liveness instead now.

The second was `chan_read_for` with its deadline ignored. That read never
returns, and the check ran on the boot thread, so the boot printed nothing at
all from that point on. The give-up read runs on a spawned thread now, watched
with a bounded wait. A read that does not come back is then a check that fails.

**The rule that falls out of both: a self-test may never do the blocking thing
on the thread that reports.** Spawn it, watch it with a bound, and treat the
bound running out as the failure it is. What that costs is a thread and ten
lines. What it buys is that the failure names itself, in the place hardest to
attach a debugger to.

**The third time was the keyboard, and it added a second rule.** The control
that removes the EOI from the keyboard's top half hung the boot, exactly as the
one that removed it from the timer's had. The wait was bounded, and the bound
was `sync.delay` -- measured in ticks. With no EOI the APIC delivers nothing at
or below that priority, and the timer sits at that priority. So the bug being
tested was the bug that stops the clock the bound was counting.

**A bound has to be measured in something the failure cannot destroy.** The
keyboard's wait counts yields now. A yield is a software interrupt, so it
executes rather than arriving, and it works whether or not the APIC still
delivers. `verify_preemption` reached the same place from the other direction:
it counts spins and checks the clock, rather than trusting it.

**The fourth time was ring 3, and it found the case where no bound works.** One
control enters a program with interrupts masked. That program cannot be
preempted, so nothing else on the core ever runs. The observer is not slow. The
observer is not scheduled, and a bound it holds is a bound nothing executes.

So the thing under test ends on its own. `spin` counts to four hundred million
and then runs the `ud2` that kills it, whatever the kernel does or does not
say. The kernel normally stops it in a few ticks. A check says the count came
back below the limit, so a run the safety net ended is a run that fails.

**When the failure stops the observer from running, the bound has to be inside
the thing being observed.** That is the last version of this rule, because
there is nowhere further to put it.

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

## Observe the effect, not the bookkeeping beside it

`kernel/devfs/verify.odin` made the same mistake three times, one milestone
apart. That makes it a rule rather than three stories.

The claim was that a write to `/dev/cons` reaches the screen. The check was that
the driver's byte counter went up. The mutation removed the call that draws
glyphs, and the check passed. The counter goes up either way.

So the check became the console's own cursor. Forty-nine bytes written is
forty-nine columns further along, and the newline goes in a second write so the
number is exact. That caught it.

**One milestone later the cursor was the wrong layer too.** A backspace has to
move the cursor back *and* clear the cell it left. The check was the cursor
column, and a `console.backspace` that moved the cursor and cleared nothing
passed it. `fb.get_raw` was added so the check could count lit pixels in the
cell, which is the screen itself.

The same shape a third time, in the line discipline. A mode change discards the
line under construction. Every check typed lines that ended in a newline, so the
buffer being discarded was always empty. The check now leaves four characters in
it.

The pattern in all three: **a field the code under test also maintains will
agree with itself whatever else is broken.** Each fix moved the check one layer
closer to the effect. Each time, the layer left behind was a number rather than
a result. `fpu_hold` in `docs/SCHED.md` is the same lesson in a subsystem with
nothing else in common.

## Where the other control tables are

| Subsystem | Table | Caught |
|---|---|---|
| The namespace under five threads | above | 5 of 8 |
| The sleep queue | `docs/SYNC.md` | 6 of 8 |
| `Tflush` and its transport | `docs/TRANSPORT.md` | 5 of 6 |
| The payload buffer per request slot | `docs/TRANSPORT.md` | 3 of 4 |
| The namespace over a transport with workers | `docs/NAMESPACE.md` | 4 of 6 |
| The first device server | `docs/DEVFS.md` | 18 of 20 |
| Services published by name | `docs/SRV.md` | 9 of 9 |
| The first device that interrupts | `docs/KBD.md` | 7 of 7 |
| Address spaces | `docs/SPACE.md` | 3 checked, 2 faults, 1 inert |
| Ring 3 | `docs/USER.md` | 6 checked, 3 machine failures, 1 uncaught |

**The uncaught ones cluster, and the cluster is the finding.** Almost every one
is a window two or three instructions wide, and none is at a lock boundary.

One is a count loaded and stored back. One is a slot claimed and not yet marked.
One is a fid slot read and written. One is a program record written the
instruction after the thread that needs it becomes runnable. Only a second CPU
makes any of them easy to reach.

**`docs/DEVFS.md`'s two are the exception, and they are a different shape.**
Neither is a narrow window. One guards against two writers to a console, and the
test has one. The other refuses a file creation that no client can request,
because `kernel/vfs` has no `chan_create` yet. Both become reachable the moment
there is something to reach them with. That is why they are cheap to leave in
now, and expensive to find later.

Two more from that file *looked* like the same thing and were not. They came
back clean because the checks were aimed one layer above the effect, and both
fail now that they are not. **Check which kind you have before recording it.**
The section above is what that took.

**The one that does not fit the pattern is worth naming separately.** Deleting
`rpc`'s `can_sleep` refusal in `kernel/vfs` changes nothing, because no correct
caller holds a spinlock across a message and there is therefore nothing to
refuse.

That is not a gap in the test. Deleting a guard which only acts on
already-broken code tests nothing. The control which does test it breaks the
code instead: move a `chan_clone` inside `object_lock` and watch `EDEADLK` come
back. When a mutation of a guard comes back clean, check that the mutation was
the right one before recording it as uncaught.

**`docs/SRV.md` has the other version of this, and it ends differently.** A
control removed a `used: bool` from a table entry and every check passed. The
mutation was wrong again, and for a reason worth acting on. `remove` zeroed the
whole entry, so a test of `used` was already a test of the id beside it. The
field was redundant, and the fix was to delete it rather than to write a check
for it.

A control that comes back clean is a question, not an answer. It asks whether
the check is weak, whether the mutation is inert, or whether the code carries
something it does not need. All three happen.

**`docs/SPACE.md` found a fourth.** A teardown that freed frames it did not own
passed every check, because the physical allocator absorbs a double free without
a word. The count was already safe -- a second release finds the bit clear and
changes nothing -- so the arithmetic agreed and the bug stayed invisible. The
allocator counts double frees now.

So the question a clean control asks has four answers. The fourth: **does
something below the code under test quietly forgive an error?**
An allocator, a lock, or a protocol that absorbs a mistake makes every check
above it weaker than it reads.

## Read where a caught control fails, not only that it did

`docs/USER.md` has a control that removes the kill from the user fault path, so
a faulting program retries its instruction for ever. Nine checks fail, which is
a clear catch and the easy thing to write down.

**The first nine checks passed, and that is the interesting part.** The whole of
`verify_spin` ran green against a program that never stopped. The fault handler
records the exit and *then* ends the thread. A reader that sees the record
therefore learns the program stopped one region too early.

On one core that ordering is safe, because both halves are inside the same
interrupt-disabled handler. On two cores it is a use-after-free of an address
space. Nothing in the tree would have asked the question, and the control asked
it for free.

**A control tells you two things: whether the checks notice, and which ones
did.** The second is the half that finds bugs the mutation was not about.

## See also

- `docs/SCHED.md` — the preemption self-test, and why it spins inside itself.
- `docs/HANDOFF.md` — the boot log every one of these lines appears in.
