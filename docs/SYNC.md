# Blocking: spinlocks, sleeping locks, and the sleep queue

`kernel/sync/` — `spin.odin`, `sleep.odin`, `wait.odin`, `rendez.odin`

Two lock types with opposite rules, and one queue underneath everything that
parks a thread.

    Spinlock   masks interrupts; a few instructions; anywhere
    Mutex      parks the thread; a whole message; never inside a Spinlock
    Rendez     parks the thread until a condition holds, with or without a
               deadline

`kernel/sched` imports this package, so nothing here may name a `^Thread`. The
scheduler registers itself through `sync.set_scheduler` and a thread is a
`rawptr` on this side of that line; the clock arrives the same way, handed down
from `sched.on_tick`. Both are in `wait.odin`.

## The lock that sleeps, and the two things it broke

`kernel/sync/sleep.odin` is Milestone 7. `Server.lock` is a `sync.Mutex` now:
it parks the thread that loses instead of masking interrupts, which is what an
out-of-process transport was waiting for — a reply that arrives *on* an
interrupt cannot be waited for by a lock that masks interrupts. Nothing sleeps
under it yet, because the in-process transport runs the handler on the caller's
own stack, but the vfs layer became preemptible the moment it stopped masking
for every message it sends. The self-test measures 12,000 parks a second in
debug and 110,000 in release.

**`kernel/sync` cannot import `kernel/sched`** — the run queues are under a
spinlock, so the dependency already runs the other way. The scheduler registers
itself instead (`sync.set_scheduler`), a thread is a `rawptr` on this side of
that boundary, and `have_sched` makes "there is no thread to park yet" an honest
state rather than a crash during boot. `sync.set_panic` is the same trick for
the panic screen, which lives in `package kernel`, above everything.

**Wait nodes live on the waiting thread's stack.** A parked thread is standing
on the frame that holds its node and is unlinked before it is made runnable, so
the queue costs no allocation and cannot fail — which matters for a lock the
allocator itself may one day want.

Two things the sleeping lock broke, both of which were latent and neither of
which was a locking bug:

**1. A lock that serves in arrival order is a second scheduler, and a worse
one.** FIFO handoff was the first version. `kernel/verify_vfs.odin` showed the
thread using the *least* CPU — the one the scheduler had therefore raised to
priority 7 while the others decayed to 1 — being served last every time, and
getting between a fiftieth and a fifth of the turns it was entitled to. The
scheduler's decision was correct and the lock was overruling it several thousand
times a second. `mutex_unlock` now hands off to the highest-priority waiter,
ties broken by arrival, so it is FIFO *within* a level. Starvation is not
reintroduced, because the defence is already better placed: a thread that loses
every race burns no CPU, so it does not decay, while the threads beating it do —
it rises past them and wins. The spread between busiest and quietest worker went
from up to 50× to a consistent 2–4×.

**2. Decay measured interruptions, not CPU.** `Thread.ticks_left` was refilled
on *every dispatch*, which was the same thing as refilling it every slice for
exactly as long as nothing blocked. Two threads handing a mutex back and forth
are dispatched hundreds of times a second and reach the end of a slice never, so
they sat at their base priority no matter how much of the machine they were
using — and one worker that *was* consuming CPU decayed past them and got five
dispatches in a thousand ticks. A thread now keeps the remainder of its slice
across a block and is only refilled when it runs out, so decay measures CPU
consumed. The two changes belong together: a lock that hands off on priority is
only as fair as the number it hands off on.

**Waking from a lock is not waking from I/O.** `sched.ready` boosts, because a
thread that waited on the world has earned its priority back; `sched.unpark`
does not, because a thread that queued behind another thread doing exactly what
it was doing has earned nothing. Boosting lock wake-ups pins every contender to
the top of the range and leaves the scheduler nothing to tell them apart with —
a negative control that does it fails both self-tests.

**`kernel/verify_sync.odin` tests the lock on its own terms**, because a failure
seen only through the namespace arrives in the vocabulary of mount tables. Two
threads, one mutex, fourteen checks: exclusion, that they really contended, and
that a thread which blocked its way through a whole slice of CPU was still
charged for it. The critical section is a spin deliberately sized to be longer
than a tick and shorter than a slice — that gap is exactly what distinguishes
"charged for the CPU it used" from "never finished a slice".

## The sleep queue

`kernel/sync/wait.odin` and `kernel/sync/rendez.odin` are Milestone 8. A mutex
answers one question — may I have this? — and answers it by handing ownership
over. Almost nothing else a kernel waits for has that shape. A thread waiting
for a reply, a key, a disc or ten milliseconds is waiting for a *condition*, and
whoever makes it true has nothing to hand over. `sync.Rendez` is where those
threads wait, and it is Plan 9's `Rendez` down to the name.

```odin
sync.sleep(&r, cond, arg)               // until cond is true
sync.sleep_for(&r, cond, arg, ticks)    // ...or the deadline; reports which
sync.delay(ticks)                       // give the core up and come back
sync.wakeup(&r) / sync.wakeup_all(&r)   // safe from an interrupt handler
```

**The condition is a procedure, and that is the whole trick.** The obvious API —
"put me on this queue and stop me" — has a race the caller cannot fix from its
own side: between testing the condition and calling in, the condition can become
true and the wake-up can happen, and the thread then parks waiting for something
that has already occurred. So the queue takes the *test* rather than the answer
and runs it itself with interrupts already masked. The check and the park are
then one step and the window has nowhere left to be. That is why `cond` is
`contextless` and must not allocate, log or take a sleeping lock: it runs in the
moment the machine is not taking interrupts.

It is also why a `wakeup` that finds nobody waiting is not a lost wake-up. The
state lives in the condition, never in the queue; a thread arriving afterwards
runs the test, finds it true and never parks. The API is shaped so there is
nowhere else to put that state.

**Waking is a hint, so `sleep` loops.** `wakeup` cannot promise the condition is
still true when the woken thread actually runs — a third thread can consume it
in between — so `sleep` re-tests and parks again. That is the exact opposite of
`mutex_unlock`, which hands the lock over and wakes a thread with nothing left
to check. A mutex can transfer the thing being waited for; a rendezvous cannot.

**The queue, the scheduler hooks and the stack-node rule moved out of
`sleep.odin` into `wait.odin`,** because a `Rendez` wants all three. `Mutex` is
now just handoff on top of them. Priority-ordered service, which Milestone 7 put
in the mutex, is shared code and therefore applies to both.

**Time comes down from the scheduler, never up.** `sched.on_tick` calls
`sync.tick(now)`, which is the only clock this package has; deadlines are in
ticks because that is exactly as much resolution as exists. `tick` returns how
many threads it started, and `on_tick` reschedules when that is non-zero *without
charging the running thread a slice* — the thread did not spend one, and a
deadline honoured somewhere in the next ten ticks is not a deadline honoured.
`reschedule`'s flag was renamed `voluntary` → `spent_slice` for this: the
question is about the outgoing thread, not about why the switch happened.

**A thread with a deadline is on two lists,** the rendezvous and the timer list,
and each of `wakeup` and `tick` unlinks from both before waking. The woken
thread then unlinks itself again on the way out. That is redundant on purpose,
and the negative controls measured exactly how redundant: mutating *either* side
alone passes every check in the suite, and mutating both faults inside the timer
interrupt on a stack frame that has gone. They stay because they are not the
same guarantee — the waker's unlink stops a node being handed out twice while
its thread is runnable but has not run; the sleeper's stops a departing frame
leaving a pointer to itself in a list.

**Three busy-waits went away, and the last of them was the point.**
`kernel/verify_vfs.odin` had spent three attempts trying to have the boot thread
watch a five-thread run without disturbing it: yielding starved the workers,
spinning starved the waiter once lock wake-ups started boosting, and the third
put a progress watchdog on a poll whose correctness still depended on the
priority of the thread running it. The boot thread now parks on a rendezvous
with a deadline, so it is not on a run queue at all and its priority is not a
number anything consults. **A thread that must not compete should not be
runnable**, and every cheaper way of saying that turned out to be a claim about
priorities that a later change was free to falsify.

Getting out of the way is measurable: the churn worker's rebinds went from ~250
a run to ~2,500 in debug and ~24,500 in release, and the sleeping-lock test's
acquisitions roughly doubled. The boot thread had been taking that.

**`kernel/verify_rendez.odin` checks it, and the hard part is that the
interesting properties are all about a thread that is not running.** A lock can
be caught by two threads seeing each other inside it; a sleep can only be caught
by measuring what the rest of the machine did while the sleeper was gone. Twenty
checks over four properties — the clock, the park, the condition, the order:

- *The park.* `delay(25)` and a 25-tick spin are indistinguishable from inside
  the thread that ran them. They differ in the switch count, and with only the
  boot and idle threads alive that difference is exact rather than statistical:
  `reschedule` does not count a switch when the thread it picked is the thread
  it had, so a spin is **zero** switches and a park is **two**.
- *The clock.* Two ticks of slack, which is tight on purpose — it is what
  catches the missing reschedule in `on_tick`, where the sleeper would instead
  wait out the running thread's slice. One tick of skew is not checked and is
  not checkable: the clock can advance between a caller reading it and
  `sleep_for` computing a deadline from it.
- *The order.* Three sleepers at spread priorities, **started one at a time**.
  Spawning all three at once quietly made this check worthless and the negative
  control found it: the scheduler dispatches the highest-priority thread first,
  so it is also the first to reach the queue, and arrival order and priority
  order agree. The check passed with the priority scan disabled. Each sleeper is
  parked before the next is created now.

**Six of eight mutations are caught**, and the two that are not are the halves
of that deliberate redundancy:

| Mutation | Result |
|---|---|
| `sleep` does not re-test after waking | caught — three failures, all three suites |
| serve waiters in arrival order | caught — the ordering check, deterministically |
| no reschedule when a deadline fires | caught — "given the core back promptly" |
| park before testing the condition | caught — hangs the boot, loudly and at once |
| neither side unlinks from the rendezvous | caught — "the rendezvous came back empty" |
| neither side unlinks from the timer list | caught — `#PF` at `0x19`, in the tick |
| only the timer skips the unlink | **not caught** — the sleeper covers it |
| only the waker skips the timer removal | **not caught** — the sleeper covers it |

## Decisions, and what would reverse them

- **Two lock types, and the rule between them is checked.** `sync.Spinlock`
  masks interrupts and may be held anywhere for a few instructions;
  `sync.Mutex` parks the thread and may be held across a wait. Taking a mutex
  inside a spinlock is a hang with no error, so `sync` counts spinlock nesting
  per CPU and `can_sleep()` is the check — `vfs.rpc_begin` turns it into an
  `EDEADLK`, and `mutex_lock` stops the machine and names the rule. Reversing
  this means going back to a namespace that cannot talk to an out-of-process
  server.
- **`sync.Mutex` hands off to the highest-priority waiter, not the first.** A
  lock that serves in arrival order decides who runs next using information the
  scheduler is not allowed to use, and it measurably overruled the scheduler
  several thousand times a second. Ties break by arrival, so it is FIFO within a
  priority level. What makes this safe against starvation is that decay measures
  CPU consumed — the loser of every race burns nothing and rises past the
  winners. The two are one decision, not two.
- **A rendezvous takes the condition, not the answer.** `sync.sleep` is handed a
  `contextless` predicate and runs it itself with interrupts masked, so the test
  and the park are one step. Handing the queue an already-computed answer leaves
  a window between the caller's test and the call that nothing inside the queue
  can see, and the thread parks waiting for something that has already happened.
  The same shape is what makes an early `wakeup` harmless — the state lives in
  the condition, never in the queue — and it is what will survive SMP unchanged,
  where the mask is replaced by a spinlock held across both.
- **`sync.sleep` loops; `mutex_unlock` does not.** A mutex transfers the thing
  being waited for, so a woken thread has nothing to re-check. A rendezvous
  transfers nothing, so a wake is only ever a hint and the condition is
  re-tested. Callers get "the condition held when this returned" without writing
  a loop of their own, and a mutation that removes the loop fails all three
  concurrency self-tests.
- **The clock is handed down to `kernel/sync`, not reached up for.**
  `sched.on_tick` calls `sync.tick(now)`; `sync` keeps no clock of its own and
  deadlines are in ticks, because that is exactly the resolution the timer has.
  It is the same dependency direction as `sync.set_scheduler` and for the same
  reason — `sched` imports `sync`, so nothing in `sync` may name a `^Thread` or
  a `^Cpu`.

## Known gaps

- **No priority inheritance.** A lock or a rendezvous goes to the best waiter,
  but a low-priority *holder* still delays a high-priority waiter for as long as
  it holds. It has not bitten because nothing runs at realtime; it will the
  moment something does. Plan 9 never had it either, which is an argument about
  cost rather than about correctness.
- **Masking is what stands in for a lock.** On a second CPU the wait lists need
  a real lock word, and `Rendez` grows the `^Spinlock` Plan 9's always had, held
  by the caller across both the condition test and the wake-up. The API was
  given its present shape partly so that change would not alter it.

## See also

- `docs/SCHED.md` — what `block`, `ready` and `unpark` do on the other side.
- `docs/NAMESPACE.md` — the session lock, which is why `Mutex` exists.
