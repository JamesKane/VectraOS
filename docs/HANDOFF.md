# Vectra — session handoff

Written 2026-08-26, revised the same day after Milestones 1, 2 and 3. Read this first
when picking the project up in a new session; it records the things the code cannot tell you on its own — what was
decided and why, what cost time, and what is deliberately missing.

---

## 1. What Vectra is

A modular operating system in Odin. Two ideas define it:

- **Plan 9-inspired structure.** Per-process namespaces, private mount tables,
  and a synthetic file protocol (Vectra9 / 9P2000.L) through which *every*
  system service — drivers, network stack, graphics, IPC, thread state — is a
  file tree behind a message-passing endpoint. POSIX is a translation runtime on
  top of that, never a set of hardwired syscalls.
- **"Cyberpunk Workstation 1994" UX.** Heavy skeuomorphic bevels, brushed dark
  magnesium over deep slate, amber/cyan/phosphor accents, copper trim, a
  software dirty-rect compositor, and tracker-synthesised relay clicks.

Target layout — `kernel/` (arch, mem, sched, vfs, drivers), `sys/` (libodin,
libposix, Vectra9), `servers/` (devfs, netfs, intuition), `apps/` (terminal,
filemgr, tracker). Primary arch `x86_64` via Limine, with clean abstractions for
`aarch64` and `riscv64`.

## 2. Where things stand

**Milestone 9 is done: `Tflush` works, and the transport that made it possible.**

Milestone 0 boots it. Milestone 1 gave it a PMM, its own page tables and a heap
behind `context.allocator`. Milestone 2 gave it a GDT, TSS, IDT and a panic
screen. Milestone 3 added `sys/vectra9/` — the whole 9P2000.L message set, a
codec, and the session/transport boundary. Milestone 4 added `kernel/vfs/`, the
namespace that uses it. Milestone 5 added `kernel/sched/` and the local APIC
timer under it. Milestone 6 locks the namespace against the threads Milestone 5
made possible, and proves it with five threads walking, listing, reading and
rebinding the same namespace at once. Milestone 7 makes the one lock held
across a 9P message a *sleeping* lock, which is what an out-of-process
transport was waiting for — and which made the vfs layer preemptible for the
first time. Milestone 8 gives it the other half of blocking: a thread can now
wait for a *condition* rather than for a lock, and it can wait with a deadline.
Milestone 9 spends both on the question `docs/VECTRA9.md` left open longest — a
9P transport that can leave a request pending, and `Tflush` over it.
About 18,000 lines of Odin; the linked image is
~683 KB debug, ~282 KB release.

```
[  --  ] Vectra 0.1.0-pre (amd64) entering kmain
[  ok  ] base revision 6 as requested
[  ok  ] traps: cs 0x8, tr 0x30, 256 vectors, #BP round-trip ok
[  ok  ] framebuffer 1280x800 @ 32bpp, pitch 5120 -> 0xffff800080000000
[  --  ] console 149 cols x 36 rows
[  --  ] booted by Limine 12.6.1 via UEFI (64-bit)
[  ok  ] paging 4-level
[  --  ] kernel phys 0x000000001bbb5000 virt 0xffffffff80000000
[  --  ] hhdm offset 0xffff800000000000
[  --  ] memory map: 28 entries spanning 12.7 GiB
[  ok  ] usable 466.9 MiB, reclaimable 39.5 MiB
[  --  ] largest usable region 395.2 MiB at 0x0000000001600000
[  ok  ] pmm 119536 frames free of 123414 tracked, bitmap 15.0 KiB at 0x0000000000001000
[  ok  ] vmm root 0x0000000000005000, mapped 515.4 MiB in 271 tables (1.0 MiB)
[  --  ] vmm nx on, global pages on, largest leaf 2.0 MiB
[  ok  ] heap online -- context.allocator is live
[  ok  ] memory self-test passed -- 1 slab pages, 0 large blocks live
[  ok  ] vectra9 9P2000.L: 57 message kinds round-trip, both transports agree
[  ok  ] namespace: #/ attached as /, 7 conventional directories
[  ok  ] vfs 51 namespace checks passed -- union of 4 names over two servers, 1 mount point, heap balanced
[  ok  ] sched cpu0 performance, capacity 1024/1024, slice 10 ticks, 16 priority levels
[  ok  ] sched 21 scheduler checks passed -- 132 switches, round-robin and priority verified
[  ok  ] lapic timer 1000 Hz -- bus clock 62.5 MHz measured against the PIT, 62537 counts per tick
[  ok  ] sched preemption 11 checks passed -- 3 threads preempted, none starved (16428925-16578328 rounds), decayed to 5, 3 fpu accumulators intact
[  ok  ] sync 14 sleeping lock checks passed -- 2057 acquisitions, 1962 parked and handed back, decayed to 1
[  ok  ] sync 20 sleep queue checks passed -- 12 parked, 12 woken, 25-tick delay took 25 in 2 switches
[  ok  ] 9p 34 Tflush checks passed -- 34 requests, 11 flushed (10 in flight, 1 stale), Rflush held 40 ticks for a stubborn server
[  ok  ] vfs 35 concurrency checks passed -- 1436 namespace operations across 5 threads, 2510 rebinds under them in 1000 ms, 10956 session waits slept, heap balanced
[  ok  ] boot complete -- idling
```

The last line is the one that moves between builds, on purpose: `just release`
does the same thousand ticks of work and reports about fifty thousand
operations. See "Measuring a concurrency test in ticks" below for why that is
the right way round.

**The design is written down in `docs/VECTRA9.md`, and it is the thing to read
before touching the protocol or the namespace.** Three decisions in it shape
everything downstream, all three taken deliberately:

1. **The wire is 9P2000.L and nothing is added to it.** No new message, no extra
   field, no private version string. When a service needs an operation 9P does
   not have, the answer is a *file* — a `ctl` that takes a line of text.
2. **Servers speak decoded messages; only the transport knows about bytes.**
   Neither the caller nor the handler can tell which transport it has.
3. **The namespace is the full Plan 9 model** — `bind`/`mount` with
   before/after/replace, union directories, per-process mount tables copied or
   shared on fork.

### The switch

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

### The self-tests, and what they cost to make honest

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

### What preemption cost elsewhere

**The heap has a lock.** `kernel/sync` is that lock: on one core with no SMP,
"nothing else can run" and "interrupts are off" are the same statement, so
`Spinlock` is a name for the interrupt flag with the nesting handled. There is
no lock *word* yet and that is deliberate — a second core needs one, and every
site that will need it has already been found and wrapped. `alloc`, `free` and
`resize` take it; `resize` calls `alloc`, which is why it nests.

**`kernel/vfs` has one now too — five of them, and the interesting part is that
they do not all behave the same way.** See the next section.

### Locking the namespace

`kernel/vfs/lock.odin` is the whole discipline in one file. Five locks, and they
divide into two kinds with opposite rules:

| Lock | Guards | Held across a 9P message? |
|---|---|---|
| `Namespace.lock` | `root`, the mount table, `refs` | spinlock — **never** |
| `object_lock` (global) | `Chan.refs`, `Mount_Point.refs`, `Mount_Point.members` | spinlock — **never** |
| `Server.lock` | the session: fid and tag counters, one message in flight, a borrowed reply's lifetime | **mutex — always** |
| `Static_Tree.lock` | one server's own fid table and directory buffer | spinlock (server side) |
| `device_lock` (global) | the `#name` table | spinlock — never |

**The session lock has to be held across the message; the bookkeeping locks must
never be.** That is not a style preference. `Rread.data` and `Rreaddir.data`
point into the server's own storage — the static server's `dirbuf`, a node's
string in `.rodata` — and "valid until the server's next message" used to be
safe because nothing could interrupt the caller between the reply and the copy.
Preemption ended that. So `rpc` returns a guard and the reply is only valid
until it is released:

```odin
e, g := rpc(c.server, &request, &reply)
defer rpc_end(g)
```

Every caller takes the guard, including the ones whose replies borrow nothing,
so there is no second entry point to reach for and no judgement about which
replies borrow. The same lock is what makes a fid mean something: `alloc_fid` is
a plain increment, and two threads that both read the counter before either
writes it both walk to `newfid`.

The other direction is enforced rather than documented. A `sync.Spinlock` *is*
the interrupt flag, so a bookkeeping lock held while the session is asked for
means blocking with interrupts masked, which is a machine that stops. `rpc`
refuses with `EDEADLK` if `sync.can_sleep()` is false. That check used to be a
counter `vfs` kept for itself; it is now a property of the CPU that `sync`
maintains in `acquire`/`release`, so the rule covers the heap lock and the
scheduler lock as well — both are equally fatal to hold across a wait. A
negative control that moves one clone inside the namespace lock fails four
checks immediately.

**Two bugs that predate threads came out of this.** `Chan.union_head` was a bare
pointer to a `Mount_Point`, and unmounting freed it — reachable with one thread
and a directory held open across an `unmount`. Mount points are reference
counted now, and `unmount` dissolves rather than deletes: the members go, the
struct survives until the last chan lets go, and a chan holding an empty mount
point behaves like one that was never in a union.

The second is `Mount_Point.generation`, and it is the one the self-test found on
its own. A union searched by index while a member is removed from the *front*
shifts every later member down, and a walker resuming at index 1 skips the entry
that used to be there — so a file that never moved comes back `ENOENT`. Plan 9
does not have this problem because it read-locks the mount head for the whole
union search; it can, because its locks sleep. Vectra's cannot. The counter
replaces the lock: a search that finds nothing is only believed if the list is
the same one it started on.

### The lock that sleeps, and the two things it broke

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

### The sleep queue

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

### Tflush, and the transport underneath it

`kernel/mnt` is Milestone 9. It is Plan 9's `devmnt` — the client half of a
mounted connection — plus the server loop lib9p provides on the other side,
and both halves are in one package because both halves of `Tflush` are one
mechanism.

```
client thread ──▶ [ tag pool ] ──▶ work queue ──▶ worker ──▶ handler
      ▲                                                        │
      └──────────────── reply, by tag ─────────────────────────┘
```

**The thing `Tflush` was waiting for was never the protocol.** The message and
its codec have been in `sys/vectra9` since Milestone 3. What was missing was a
transport that can leave a request *pending*: `vectra9.In_Process` runs the
handler on the caller's own stack and returns, so a client behind it has
nothing outstanding to flush and no way to send the flush if it did. That needs
threads to leave a request pending on, and a way to park and wake them — which
is why this milestone is exactly two milestones after the scheduler and one
after the sleep queue.

**The tag is the pool slot.** A `Tflush` names a request by tag, so the server
must be able to find one by tag, so the pool *is* the tag space. A tag that is
not an index into it names no request — which the protocol requires an answer
for rather than an error. The session's own `alloc_tag` counter goes unused
here, and that is the honest arrangement rather than a layering slip: tags have
to be unique among the requests actually in flight, so they belong to whoever
tracks those.

**Each request's flush slot is preallocated above it.** Slot `i + MAX_REQUESTS`
belongs to slot `i`. That is not a micro-optimisation, it is the only thing
between this design and a deadlock reachable by a client doing nothing wrong: a
client whose request is stuck has to be able to send `Tflush`, and if the flush
competed for an ordinary slot then a full pool of stuck requests would leave
nobody able to unstick anything. The self-test fills the pool exactly and
flushes every slot in it; the negative control that makes the flush queue like
everything else deadlocks the boot.

**Rflush is written by whoever finishes the original, not by the worker that
received the Tflush.** The rule is that Rflush comes *after* the flushed
request's fate is decided, and the obvious way to honour it — mark the request,
prod the server, then wait — parks the worker that is holding the flush. A pool
of `n` workers is then emptied by `n` flushes of requests that are themselves
waiting. So the wait is turned inside out: the `Tflush` records itself as the
original's `partner` and returns, and the code that finishes the original
writes the `Rflush` on its way out. The ordering stops being a wait and becomes
the fact that there is no other code path that writes it.

**A server may refuse to abandon the work, and that is legal.** `Conn.abort` is
optional; a connection without one still obeys the protocol, it simply makes
`Rflush` wait for the request to finish on its own. Both kinds are in the
self-test and the stubborn one is what the test is built around — a server that
always aborts makes "after the fate is decided" and "immediately" the same
instant, so an implementation that sent `Rflush` first would pass. Against a
stubborn server the boot thread holds the work open for forty ticks, watches
the client stay parked, and only then lets it finish. The client then gets a
real answer to the request it asked to have cancelled, which is the case the
protocol obliges a client to tolerate and the one nobody remembers to test.

The same rule is checked from the other end: `Stats.unsettled` is incremented
by the *client* whenever an `Rflush` arrives while its request is still
running, and the self-test asserts it is zero.

**Handlers now receive their tag.** `vectra9.Handler` grew one field, and it
reads as redundant for exactly as long as a transport can only have one request
in flight. A server that implements `Tflush` has to be able to say which of its
in-flight requests an `oldtag` refers to, and a handler that cannot name its own
request cannot take part in that.

**The worker pool has to be bigger than the number of requests that can block
at once** — a worker inside a stuck handler is a worker not serving the
`Tflush` that would unstick it. Plan 9 avoids the question with a thread per
request; this counts them instead, and both `serve_start` and the self-test say
where the number came from.

**34 checks in `kernel/verify_flush.odin`, and five of six mutations caught:**

| Mutation | Result |
|---|---|
| answer `Rflush` on receipt | caught — four failures, first is the ordering check |
| never tell the server a request was flushed | caught — seven failures |
| trust the client's `oldtag` as a pool index | caught — `#PF`, from one crafted message |
| the flush queues for an ordinary slot | caught — deadlocks the boot on a full pool |
| the original never answers the flush waiting on it | caught — hangs the boot |
| a claimed slot is not marked as claimed | **not caught** |

The last is the same shape as `kernel/vfs`'s two uncaught races and for the same
reason. Nothing marks the slot between `take` returning it and a worker picking
it up, so two clients can be handed the same one — but only if a timer lands in
that window, and eight client threads that each run for a few microseconds do
not reliably produce one. It is a real bug and only a second CPU makes it easy
to find.

**What `kernel/vfs` still cannot do with this.** A reply that borrows the
server's storage — `Rread.data` into a node's `.rodata`, `Rreaddir.data` into
the server's `dirbuf` — was safe because the session lock spanned the whole
exchange. With several requests in flight it is not, and *the borrow rule turns
out to be a property of the transport rather than of the protocol*. A single-
worker `Conn` still honours it, which is what the transparency check uses:
`static_handler`, unmodified, behind a queue and a thread, answering `Tattach`
and `Twalk` exactly as it does behind `In_Process`. Anything more needs a
payload buffer per slot, and that is the next step rather than this one.

### Measuring a concurrency test in ticks

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
a sixth to all of it, which is what surfaced the `generation` bug above.

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

**What still does not exist.** No userland and no address-space switching — a
thread grows an `^Address_Space` and `reschedule` grows one comparison when
there is one. No SMP: `Cpu` is per-core and `MAX_CPUS` is 8, but only core 0 is
ever brought up, and there is no IPI, no AP trampoline and no lock word. No
`/srv`. No condition variable as such, because `sync.Rendez` is one. No
read/write sleeping lock, which is the piece `Mount_Point.generation` is
standing in for. `Tflush` exists in `kernel/mnt` but `kernel/vfs` cannot use it
yet — see below. No `swapgs`, no per-CPU state behind GS. `kmain` ends by calling `sched.exit`,
so the machine idles rather than halting.

## 3. Build and run

```sh
just run          # build, stage ESP, boot headless, serial on stdio
just gui          # same, with a QEMU window
just debug        # boot halted; `just gdb` in another shell
just release      # -o:speed, bounds checks off
just check        # type-check everything, emit nothing
just font         # regenerate the baked console font
make run          # identical targets, if `just` is absent (it is, here)
```

`build.odin` is the real build system — compile, link, stage, run — and holds
the per-architecture table. `justfile`/`Makefile` are thin wrappers. Invoke the
driver directly as:

```sh
odin run build.odin -file -out:.vectra-build -- run --gfx
```

**The explicit `-out:` is mandatory.** Without it `odin run` names the driver
binary after the script and drops `./build` directly on top of the `build/`
output directory. This bit once already.

Verified toolchain on this machine: Odin `dev-2026-08:8412dc37a`, LLD 21.0.0
(from `~/.swiftly/bin`), QEMU 11.1.0, Python 3 with Pillow (font generation
only). No `just` installed — use `make`. No `xorriso`, no loop devices, no
`sudo` required.

## 4. Toolchain constraints — the expensive ones

These were each found the hard way. Changing any of them will break the build in
ways whose error messages do not point back here.

| Constraint | Why |
|---|---|
| `-no-thread-local` | Odin otherwise emits `STT_TLS` symbols with no `PT_TLS` segment; `ld.lld` refuses the image. Per-CPU state must go through `GS` explicitly. |
| `ld.lld`, not `ld` | Apple's linker cannot produce ELF. |
| `-out:.vectra-build` | See above — `./build` collides with `build/`. |
| ESP is a **directory**, not an image | QEMU's vvfat (`-drive format=raw,file=fat:rw:build/esp`) presents it as FAT. This is what makes the build work on macOS, where `losetup`/`mkfs.vfat` do not exist. Same commands work on Linux. |
| `arch.early_init()` runs first | Limine base revision 5+ clears every `cr0`/`cr4`/`EFER` bit the protocol does not require — `CR4.OSFXSR` included. Odin's codegen uses XMM for ordinary struct moves, so the *first* Odin statement after entry faults without SSE re-enabled. |
| `@(link_section = ".limine_requests")` on every request | Since base revision 2 the request delimiters are **binding, not hints**. A request outside the section compiles, links, boots — and its `response` stays nil forever. Silent. |
| EFER.NXE before the first NX mapping | Bit 63 of a page table entry is *reserved*, not ignored, until `EFER.NXE` is set. Install a mapping with it first and the fault comes on first touch, as a reserved-bit #PF, nowhere near the cause. `amd64.enable_paging_features` is what turns it on, and `leaf_encode` drops the bit if it did not take. |
| Segment bounds come from `link_amd64.ld`, not from Odin | `__text_start` … `__data_end` are declared in a bare `foreign { }` block in `kernel/mem/vmm.odin`. They are defined *inside* their output sections in the linker script on purpose: written between sections they become orphans, and ld is free to attach an orphan to whichever segment it likes. |
| `intrinsics` has `mem_zero` and `mem_copy`, but no `mem_set` | There is no fill-with-a-byte intrinsic. The PMM's bitmap fill is a plain loop. `memset`/`memcpy`/`memmove` *are* provided by stock `base:runtime`, which is why the link has no undefined symbols. |
| `proc "naked"`, not `@(naked)` | Odin has no `naked` attribute — it is a *calling convention*. `@(naked)` fails with "Unknown attribute element name", and the suggested `-ignore-unknown-attributes` would silence the error while still emitting a prologue, which corrupts the interrupt frame. |
| `$$` in an inline-asm template | Odin substitutes `$0`, `$1` … for operands, so a literal immediate needs `$$0x10`. Operands passed under the `i` constraint supply their own `$` — `movw $2, %ax` with `u64(0x10)` assembles as `movw $0x10, %ax`. |
| The error-code vector list is written twice | Once as an assembler `.if` inside the stub blob and once as `vector_has_error_code` in Odin. They cannot share a definition — one is consumed at build time, the other at run time — and if they disagree every field in `Trap_Frame` reads as the one next door. They live in the same file for that reason. |
| An unoptimised build spills every temporary | Debug builds keep nothing in a register across an instruction boundary. This is not a curiosity: a test written to verify that FXSAVE preserves XMM passed with the FXSAVE removed, because the values it was checking were on the stack the whole time. Anything that must observe *register* state has to pin it with inline asm and hold it there — see `fpu_hold` in `kernel/sched/verify.odin`. |
| A missing EOI stops the timer silently | The local APIC delivers nothing further at or below that priority. There is no error, no fault, and no bit anywhere saying so — it looks exactly like a timer that was never armed. Any loop waiting on the tick count needs a liveness bound, or a one-line bug hangs the boot with the last line printed being the timer coming up successfully. |
| A freed object reads as a valid one | The slab allocator writes its free-list link over the first field and leaves the rest. A `Mount_Point` freed one reference early still reports zero members, which is exactly what a correctly dissolved one reports — so the obvious use-after-free check passes whether or not the bug is there. Testing a lifetime bug means testing the *reference count*, or forcing the block to be reused first. |
| The LAPIC coalesces what it cannot deliver | Ticks that arrive while interrupts are masked do not queue up. Raising the timer from 1 kHz to 20 kHz over a lock-heavy workload delivered about 1.4× as many interrupts, not 20×. Anything that expects a preemption *rate* has to account for how much of the time interrupts are actually on. |
| A voluntary switch is not a preemption | Making a layer block often does not make its narrow races reachable. A sleeping session lock took `kernel/verify_vfs.odin` from ~1,000 context switches a run to ~110,000, and caught not one additional mutation — every added switch is at a lock boundary, and a two-instruction read-modify-write window is not. Only a timer, or a second core, interleaves two threads at an arbitrary instruction. |
| Refilling a slice on dispatch is not scheduling | `Thread.ticks_left` reset on every dispatch is indistinguishable from resetting it every slice, right up until something blocks. A thread that parks hundreds of times a second then never reaches the end of a slice, never decays, and outranks the thread doing steady work for ever. Decay has to measure CPU consumed, which means carrying the remainder across a block. |
| `int $8` is not a double fault | A software interrupt to an error-code vector does **not** push an error code, so it lands on a stub that assumes one was pushed. Never test `#DF` that way; provoke a real one by faulting on a bad stack. |

**No vendored runtime shim.** The neighbouring `odin-os` project hand-maintains
a copy of `base:runtime` that must track the compiler. Current Odin ships
`runtime-os_specific_freestanding`, so Vectra builds against **stock
`base:runtime`**. Do not reintroduce a shim.

## 5. Decisions made, and what would reverse them

- **Limine 12.6.1, base revision 6.** Vendored UEFI binaries only (x64, aa64,
  riscv64, ia32) in `boot/limine/`; no BIOS stage, no `limine` deploy tool,
  because Vectra boots UEFI everywhere. `kmain` reports the granted revision.
- **Paging pinned to 4-level** (`min_mode = max_mode = 4LVL` in
  `paging_mode_request`). Limine would otherwise hand us 5-level on capable
  hardware, moving the canonical hole and changing every table walk. Adding
  5-level support should be a deliberate edit to that request.
- **Base revision 6's HHDM is restrictive** — only usable,
  bootloader-reclaimable, executable, framebuffer, reserved-mapped, ACPI
  reclaimable and ACPI NVS regions are mapped. **The VMM must respect this.**
  `check_base_revision()` currently only *warns* on a mismatch; make it a hard
  stop as soon as anything dereferences an HHDM address.
- **`arch` is the only CPU-facing import** the portable kernel may use.
  Per-architecture bindings are selected by `#+build` tag
  (`arch_amd64.odin`, `arch_arm64.odin`, `arch_riscv64.odin`); the latter two
  are stubs that exist so a port is filling in blanks, not editing call sites.
- **Inline asm, no nasm.** Odin's `asm(...)` with LLVM AT&T templates and
  register constraints covers port I/O, control registers and MSRs. Verified by
  disassembly.
- **The framebuffer `Surface` is the shared drawing type.** The boot splash, the
  future panic screen, and `intuition`'s off-screen window buffers are all
  Surfaces, so a bevel drawn at boot and one on a titlebar are the same code.
  `kernel/drivers/fb/palette.odin` is the single source of colour truth.
- **Console font is host-rasterised.** `tools/genfont.py` bakes PTMono at 13px
  (exactly 8×16) into `kernel/drivers/console/font_data.odin`. Serviceable, but
  a hand-drawn bitmap face is the right long-term answer for the amber terminal.
- **The logger replays.** Lines emitted before the framebuffer exists are
  buffered (16 × 128 bytes, static) and drawn by `attach_screen()` when the
  console attaches, so screen and serial agree line-for-line.

Memory, added in Milestone 1:

- **`arch` owns the page table *encoding*; `kernel/mem` owns the *walk*.** This
  is where the "only CPU-facing import" rule landed for paging. `arch` supplies
  `table_index`, `level_size`, `leaf_encode`, `branch_encode`, `entry_flags` and
  friends; `vmm.odin` implements the descend-and-allocate loop once against
  them. The walk genuinely is not amd64-specific — aarch64's stage-1 tables and
  riscv64's Sv39/Sv48 are the same radix tree, nine bits at a stride — so a port
  supplies an encoding rather than a second walker.
- **Bitmap PMM, not a free list.** A free list has to live in the pages it
  tracks, so one stray write corrupts the allocator itself; and contiguous
  multi-page allocation, which page tables and large heap blocks both need, is a
  run search over a bitmap versus a linear walk over a list. The cost is a scan,
  bounded by a rotating hint and by skipping fully-taken bytes eight frames at a
  time.
- **The bitmap indexes from physical zero**, holes included, so `phys /
  PAGE_SIZE` is the index with nothing to subtract. Hole frames are born taken
  and never freed. It is 15 KiB on this machine.
- **Frame 0 is reserved forever.** Base revision 6 lets the firmware call the
  page at physical zero usable. Handing it out costs the one thing that makes a
  null dereference announce itself.
- **Bootloader-reclaimable memory is *not* reclaimed.** It is 39 MiB and worth
  having, but at the end of `mem.init` the kernel is still standing on three
  things inside it: the stack `kmain` is running on, every Limine response, and
  the memory map itself. `pmm_reclaim` is written and ready; it becomes callable
  once the scheduler is on a kernel stack of its own and anything wanted from
  the responses has been copied out.
- **All 256 higher-half top-level entries are pre-populated** at VMM init. A
  kernel mapping made after a user address space is created must appear in that
  address space too, and if the top-level entry did not exist at copy time it
  never will. Costs 1 MiB, paid once; buys never having to propagate a kernel
  mapping by hand. This is most of the "269 tables" in the boot log.
- **The kernel image is mapped a segment at a time**, with the permissions the
  linker script implies — text read-execute, rodata read-only, data read-write
  and no-execute — and `CR0.WP` is set, so they bind on supervisor writes too.
  Verified by reading the entries back out of the live tables, not by trusting
  the code that wrote them.
- **The direct map rounds outward; the PMM rounds inward.** Different jobs: the
  PMM must never hand out a frame that is partly somebody else's, and the direct
  map must never fail to map a page a structure straddles.
- **NX, global pages and 1 GiB leaves are all detected, not assumed.**
  `enable_paging_features` reads CPUID and records what took; `leaf_encode`
  silently drops a bit whose feature is off, so callers can ask unconditionally.
  On `-cpu qemu64` NX and PGE are present and 1 GiB pages are not, hence the
  2 MiB largest leaf in the boot log.
- **The framebuffer is added to the region list by hand if the map omitted it.**
  Base revision 6 guarantees the framebuffer is direct-mapped; it does not
  guarantee the firmware described it as a memory map entry. Getting that wrong
  kills the machine on the first character drawn after the CR3 switch — with the
  console being the thing that would have reported it.
- **Slab classes are 16 B … 2 KiB, powers of two**, one page per slab, free
  objects threaded through their own first eight bytes. Every allocation carries
  a 16-byte header immediately below the returned pointer holding a magic, the
  class (or "large"), the page count and the offset back to the block start.
  That header is what makes `free` a constant-time dispatch with no lookup
  structure, and what makes over-aligned allocation possible at all.
- **`free` checks the magic and clears it.** A pointer that did not come from
  `alloc` is ignored rather than acted on, and a double free fails the check
  instead of putting the same object on a free list twice. Leaking is the
  cheaper outcome.
- **`-default-to-nil-allocator` stays in the build.** `context.allocator` is
  installed at the very end of `kmain`, so an accidental allocation during early
  boot still returns nil and fails at its use, rather than quietly succeeding
  against a heap that does not exist yet.

Traps, added in Milestone 2:

- **Traps come up before the framebuffer**, immediately after the serial port
  and the base revision check. Everything after that point is code that faults
  while it is being written, and a fault before it is a triple fault with
  nothing to show for it. The consequence is that the fault stacks have to be
  static `.bss` arrays rather than PMM pages — which is the right trade, because
  it is memory bring-up above all that this needs to be able to debug.
- **The selector layout is fixed by SYSCALL/SYSRET**, not by taste. `SYSCALL`
  takes CS from `STAR[47:32]` and SS from that plus 8; `SYSRET` to 64-bit code
  takes CS from `STAR[63:48]` plus 16 and SS from plus 8. Hence kernel code then
  kernel data, and user code32 then user data then user code64 — with the
  code32 slot present purely as a placeholder. Renumbering these later does not
  break the build, it breaks the first system call.
- **Three vectors get interrupt stacks of their own**: the double fault (IST1),
  NMI (IST2) and the machine check (IST3). The double fault is the one that
  matters — a fault that happens *because* the stack is bad has nowhere to push
  its frame, and that is a triple fault. Verified by provoking one.
- **All 256 vectors are installed, not just the 32 exceptions.** A stray
  interrupt on a vector with no descriptor is a `#GP`, and a `#GP` with no
  handler is a double fault, so the cheapest way to make a stray interrupt say
  "vector 39 arrived and nobody was expecting it" is to give every vector a stub.
- **The stubs are generated by the assembler, not written out or code-generated
  into a file.** `.rept` emits 256 of them and `.balign 16` makes each exactly
  sixteen bytes whether or not it pushed a dummy error code, so `idt_init` finds
  the nth by multiplying. That alignment is load-bearing: it is what turns a
  table of 256 function pointers into one label and a shift.
- **The legacy PICs are remapped *and* masked** before anything could call
  `sti`. Masking alone is not enough — a spurious IRQ 7 can still get through,
  and unremapped it arrives as a **page fault** with a garbage error code and a
  stale CR2, which the panic screen would then report with total confidence.
- **A trap handler returns a bool: resume, or stop.** The only thing that ever
  resumes today is the breakpoint the boot self-test arms for itself, and that
  narrowness is deliberate — a stray `#BP` from anywhere else still panics.
- **The panic screen's body text is amber, not red.** The alarm is carried by
  the red band, the `[ FAIL ]` tags and the FAULT lamp; the report itself is
  mostly hex that has to be read carefully, and a wall of red is the worst way
  to present it.
- **The panic path reports what was *mapped* at CR2, not just the address.**
  "nothing is mapped there" and "mapped read-only and you wrote to it" are
  different bugs that produce the same CR2, and `mem.permissions` already knew
  how to tell them apart.

Vectra9, added in Milestone 3. The full argument is in `docs/VECTRA9.md`; these
are the load-bearing bits:

- **Nothing is added to the wire.** The version string is `9P2000.L` and a stock
  Linux `v9fs` client must be able to mount a Vectra server. Extensions are
  files, not messages. The payoff is not interoperability for its own sake — it
  is that the protocol stops being a design surface, because the answer to "what
  messages does my subsystem need" is always the same nine.
- **Servers speak decoded messages.** The transport is the only thing that knows
  bytes exist. Rejected alternatives, both defensible: marshal everywhere (one
  code path, but two memcpys and a parse on every read of every file, in a
  system where thread state *is* a file), and a typed device vtable with 9P only
  for remote servers, which is what Plan 9 itself does (faster still, but two
  interfaces to keep in step and a server that cannot move between kernel and
  userland without a rewrite).
- **A decoded message borrows its buffer.** Strings and slices inside a `Msg`
  point into whatever it was decoded from. This is what makes an `Rread` of
  4 KiB free to pass around, and it is the rule most likely to be broken. Odin
  cannot express the lifetime, so it is stated at the top of `proto.odin` and
  nowhere else.
- **`Twalk` bounds names at sixteen, so they live inline.** That is the only
  reason a `Msg` is a stack value; the `#assert` on `size_of(Msg)` is there to
  stop it quietly becoming something else.
- **Codec errors and protocol errors are separate types.** `Error` means the
  bytes are wrong and no reply can be built. `Errno` means the request was
  well-formed and the answer is no. Merging them would let a corrupt message be
  answered as though it had been understood.
- **The codec latches errors; `libodin.Sink` saturates.** Opposite choices, both
  right: a truncated log line beats no log line, and a truncated 9P message is a
  protocol violation the far end would blame on itself.
- **`decode` bounds the cursor by the message's declared size, not the buffer.**
  A body that reads past its own message is then a malformed message rather than
  a short buffer, and every accessor gets that for free. A declared size larger
  than the buffer is refused outright — that is the classic way a codec is
  talked into reading past the end of a packet.
- **Where Plan 9 has an answer, Vectra takes it.** Four questions that were open
  in the first draft of the design are settled in `VECTRA9.md` section 7, each
  against what Plan 9's source actually does rather than what is remembered
  about it: a fid is a number and never a pointer (`Chan.fid` is a `ulong`, and
  the table lookup is what makes a fid a capability); the root is an ordinary
  in-kernel server, as `devroot` is a real device rather than a special case in
  `namec`; `Tflush` needs a tag-indexed pool of in-flight requests and `Rflush`
  is the barrier, which is what `mountio` and lib9p between them implement; and
  a union `create` goes to the first `Create`-flagged member and **does not fall
  through** if it fails, exactly as `createdir` refuses to.
- **`Encoded_Loopback` is a test instrument that is also the skeleton of a real
  transport.** It does every step a pipe transport would except crossing an
  address space, so writing that transport is replacing two copies with reads
  and writes — and meanwhile it is how the boot self-test proves a handler
  cannot tell which transport it is behind.

## 6. Known warts

- **The trap stub saves general-purpose registers only.** No `FXSAVE`, so a
  handler that *returns* into code with live SSE state would corrupt it. Panics
  never return, and the only resuming path today is a breakpoint the kernel
  raised on itself, so this is fine now and is the first thing that has to grow
  the day anything resumes arbitrary code — a debugger, or a page fault that
  fixes up and retries.
- **No `swapgs` in the entry path.** Correct today, because nothing runs at
  CPL 3. It becomes wrong the moment userland does, and the fix has to land in
  the same tail that the point above rewrites.
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
- **The tag space belongs to whatever tracks the requests in flight.**
  `kernel/mnt` indexes its pool by tag and hands out slot indices, because a
  `Tflush` names a request by tag and a tag that cannot be looked up is a
  request that cannot be flushed. `Session.next_tag` is then unused on that
  transport. The alternative — a session-wide counter and a map from tag to
  slot — buys nothing but a data structure, since the pool is small by design
  and a bounded pool is what stops a client exhausting the server.
- **A request's `Tflush` slot is reserved, not allocated.** A client whose
  request is stuck must be able to flush it, so the flush cannot be allowed to
  queue for the resource the stuck requests are holding. Reversing this makes a
  deadlock reachable through a legal sequence of legal messages, which the
  negative control demonstrates by hanging the boot.
- **`Rflush` is written by the code that finishes the flushed request.** The
  protocol's one ordering rule stops being something to remember and becomes
  the fact that no other code path writes it. The alternative — the flush's
  worker waits for the original — is correct and parks a worker, and `n` such
  flushes empty a pool of `n` workers.
- **`vectra9.Handler` takes the tag it is answering.** Redundant on a transport
  that can only have one request outstanding, and load-bearing on any that
  cannot: a server implementing `Tflush` must be able to say which of its
  in-flight requests an `oldtag` names.
- **The clock is handed down to `kernel/sync`, not reached up for.**
  `sched.on_tick` calls `sync.tick(now)`; `sync` keeps no clock of its own and
  deadlines are in ticks, because that is exactly the resolution the timer has.
  It is the same dependency direction as `sync.set_scheduler` and for the same
  reason — `sched` imports `sync`, so nothing in `sync` may name a `^Thread` or
  a `^Cpu`.
- **A deadline that fires reschedules immediately, and charges nobody.**
  `sync.tick` reports how many threads it started and `on_tick` switches when
  that is non-zero, with `spent_slice` false: the running thread did not spend a
  slice, and a thread that asked to be woken at tick N and gets the core at tick
  N+9 was not woken at tick N. This is why `reschedule`'s flag is `spent_slice`
  and no longer `voluntary` — the question is about the outgoing thread, not
  about the reason for the switch.
- **The panic screen has no backtrace.** It reports the faulting instruction and
  the register state but cannot walk the stack; that needs frame pointers kept
  deliberately or unwind tables retained. It is the largest single thing missing
  from an otherwise complete fault report.
- **Every Vectra9 server so far is a self-test or a synthetic tree.**
  `static.odin` is real code with real clients, but it is read-only and serves
  from a node table; nothing has yet had to block, fail partway, or answer out
  of order. `kernel/verify_flush.odin`'s server is the first that deliberately
  will not finish, and it found nothing — which is a statement about how little
  has been asked of the layer, not about how solid it is.
- **`Session.alloc_fid` is a monotonic counter.** It runs out after four billion
  opens without ever reusing one. The right fix is a free list fed by `Tclunk`,
  not a wider counter.
- **The two transports in `sys/vectra9` are synchronous, and `kernel/vfs` uses
  one of them.** `In_Process` and `Encoded_Loopback` both run the handler on
  the caller's own stack, so a client behind either can never have two requests
  outstanding. `kernel/mnt` is the asynchronous one and it lives in the kernel
  because it needs threads; what keeps `kernel/vfs` on the synchronous side is
  the borrow rule, not the interface. See section 7.
- **A reply's payload has no owner on an asynchronous transport.** `Rread.data`
  points into the server's storage and is valid until that server's next
  message, which was a workable rule while the session lock spanned the whole
  exchange. It is not one when eight exchanges are in flight. A `Conn` with one
  worker still honours it; anything more needs the payload copied into the
  request's own slot, and nothing does that yet.
- **The PMM has no lock.** The heap does — `sync.Spinlock`, taken by `alloc`,
  `free` and `resize` — but `pmm.odin`'s bitmap does not, because nothing
  allocates frames after boot. It needs one before the first AP comes up or the
  first interrupt handler allocates.
- **Slabs are never returned to the PMM.** Reclaiming one means proving every
  object in it is free, which means per-slab occupancy counts and a
  partial/full/empty chain per class. The fix belongs in `slab_grow`/`slab_free`,
  not in the callers.
- **`map_at` refuses to map over an existing mapping** rather than splitting a
  large page. Nothing yet needs to, and making it an error means that when
  something does, it says so instead of silently doing the wrong half of it.
- **The framebuffer is mapped write-back, not write-combining.** That needs PAT
  setup. It will matter to the compositor and does not matter yet.
- **1 MiB goes to higher-half page tables** at boot, most of it never touched.
  Deliberate — see section 5 — but it is the largest single line item in the
  kernel's own footprint.
- **OVMF is borrowed from `../odin-os/ovmf/ovmf_x64.fd`.** `build.odin` hard-codes
  that path and dies if it is missing. Vectra should vendor its own firmware, and
  will need `AAVMF`/`RISCV_VIRT` equivalents before the other arches can boot.
- **QEMU's vvfat is read-write, so OVMF writes `NvVars` into `build/esp/`.**
  Harmless, but it means the staged ESP is not byte-reproducible.
- **`arm64` and `riscv64` are stubs, and are falling further behind.**
  `build.odin` has their rows filled in and the vendored bootloaders are
  present, but there are no `link_arm64.ld` / `link_riscv64.ld` scripts, and
  `arch_amd64.odin` has now grown both the paging interface *and* the trap
  interface that the other two do not declare.
- **Memory-map entry count varies run to run** (27, 31, 33) with OVMF/vvfat. Not
  a bug; do not chase it.

## 7. Where to go next

The scheduler was the thing blocking everything else, the namespace it exposed
is now locked, the lock that holds a session across a message sleeps, and a
thread can now wait for a condition or a deadline. The primitives a driver needs
in order to be written all exist. What is left is mostly *using* them.

**A payload buffer per request slot is the next piece, and it is what
`kernel/vfs` is waiting for.** The borrow rule — `Rread.data` and
`Rreaddir.data` valid until that server's next message — held because the
session lock spanned the whole exchange, and `kernel/mnt` can have eight
exchanges going at once. Until a reply's payload is copied into storage the
request owns, a `Conn` serving `kernel/vfs` is limited to one worker, which is
`In_Process` with extra steps. This is a small change with a large consequence:
it is what lets the namespace sit on a transport that can be flushed, and after
it `Server.lock` stops having to mean "one request in flight" and can go back to
meaning "the fid counter is mine".

**A read/write sleeping lock is the other piece worth wanting.**
`Mount_Point.generation` exists only because a read lock could not be held
across a union search — Plan 9 holds one, because its locks sleep. Now that
Vectra's can, the retry loop in `walk1_ex` could become a read lock and the
generation counter could go. `Wait_Queue` is the right foundation and the
reader/writer policy is the only new thinking: which of two waiting kinds
`take_best` should prefer, and whether a waiting writer blocks arriving readers.

**Priority inheritance is the known gap in what exists.** A lock or a rendezvous
goes to the best waiter, but a low-priority *holder* still delays a
high-priority waiter for as long as it holds. It has not bitten because nothing
runs at realtime; it will the moment something does. Plan 9 never had it either,
which is an argument about cost rather than about correctness.

**Then, in roughly this order:**
1. **`kernel/vfs` on `kernel/mnt`.** See the payload buffer above. This is what
   makes `Tflush` reachable from a path rather than from a self-test, and it is
   what an interruptible read from a slow device needs.
2. **A first real device server.** `devfs` with `/dev/cons` over the console
   driver, which makes the whole path from a name to a byte on screen exist end
   to end. `static.odin` is the wrong shape only because it is read-only.
3. **`/srv`**, which needs a thread on each side of a transport and therefore
   needed the scheduler.
4. **Userland.** A thread grows an `^Address_Space`, `reschedule` grows one
   comparison, and the GDT already has the selectors laid out for
   SYSCALL/SYSRET. `swapgs` and per-CPU state behind GS belong to this step and
   are cheaper to build with it than after it.

**SMP, when it is wanted.** The shapes are already right: `Cpu` is per-core,
`Resume` is per-thread and lives on that thread's stack, and every mount-table,
namespace and heap mutation is inside a `sync.Spinlock`. What is missing is a
lock word in that struct, an AP trampoline, IPIs, and a placement policy for
`enqueue` — which is where `eligible` and the class/capacity fields stop being
inert. Three things become urgent the moment a second core runs: `Chan.refs` and
`Mount_Point.refs` want atomic increments rather than a global lock;
`sync.critical_depth` has to become per-CPU state; and `sync.Mutex` needs the
scheduler to drop its guard *after* the switch, since a parked thread currently
relies on the interrupt mask travelling with it through the trap frame. A fourth
arrived with the sleep queue: masking is what stands in for a lock on every wait
list, so `Wait_Queue` needs a real lock word and `Rendez` grows the `^Spinlock`
Plan 9's always had, held by the caller across both the condition test and the
wake-up. The API was given its present shape partly so that change would not
alter it. All four are named where they live.

**Smaller things worth doing when convenient:**

- A stack backtrace on the panic screen. Everything else a fault report wants to
  say is already there.
- Make `check_base_revision()` a hard stop rather than a warning.
- A free list for fids. `alloc_fid` is monotonic and therefore finite: four
  billion opens per session, never reused.
- `reap` only runs from `spawn` and from the self-tests, so a dead thread's stack
  comes back at the next spawn rather than when it exits. Fine now; an idle-time
  reaper is the fix. Both concurrency self-tests have to call `sched.reap()` by
  hand before measuring the heap, which is the smell.
- `sync.Mutex` has no priority inheritance. Handoff goes to the best *waiter*,
  but a low-priority *holder* still delays a high-priority waiter for as long as
  it holds. Worth wanting when there is a realtime thread that matters; Plan 9
  never had it either.
- `readdir` over a union is still index-based and still documented as undefined
  if the union is rebound mid-listing — the cookie names a position in a list
  that moved. `walk` no longer has that property (see `Mount_Point.generation`);
  a listing could get the same treatment if it ever matters.
- Teach `arch_arm64.odin` / `arch_riscv64.odin` the paging, trap and scheduling
  interfaces. `cpu_class` is the one that pays off immediately — a big.LITTLE
  part reporting three classes makes the capacity arithmetic do real work.

## 8. File map

```
build.odin              Build driver: compile, link, stage ESP, run QEMU
justfile / Makefile     Thin wrappers over build.odin
boot/
  limine.conf           Limine config (new-style), staged to /EFI/BOOT/
  limine/               Vendored Limine 12.6.1 UEFI binaries + VERSION + README
kernel/
  main.odin             kmain, Limine requests, boot survey, memory bring-up
  verify_sync.odin      The sleeping lock on its own terms: 14 checks, 2 threads
  verify_rendez.odin    The sleep queue: 20 checks -- the clock, the park, the
                        condition, the order
  verify_flush.odin     Tflush: 34 checks, against a server that will not finish
                        -- abortable and stubborn, and the stubborn one is the
                        test
  verify_vfs.odin       The namespace under five threads: 35 checks, two servers
  splash.odin           Boot chassis: plinth, copper bar, well, lamps
  log.odin              Kernel log; serial + screen, with early-line replay
  panic.odin            The panic screen, and the trap handler behind it
  link_amd64.ld         Static-PIE layout; orders .limine_requests, exports
                        the __text/__rodata/__data segment bounds
  arch/
    arch_amd64.odin     The architecture interface, bound to amd64
    arch_arm64.odin     Stub
    arch_riscv64.odin   Stub
    amd64/cpu.odin      Port I/O, control regs, MSRs, CPUID, EFER, SSE
    amd64/paging.odin   Page table format: entry bits, encode/decode, TLB
    amd64/gdt.odin      GDT, TSS, and the interrupt stack table
    amd64/idt.odin      IDT, the 256 entry stubs, dispatch, fault reporting
    amd64/pic.odin      Legacy 8259s: remapped clear of the exceptions, masked
    amd64/lapic.odin    Local APIC, the timer that preempts, EOI
    amd64/pit.odin      Channel 2 as a ruler, to measure the LAPIC against
    amd64/context.odin  A new thread's first saved state; what class a core is
  boot/limine/
    limine.odin         Protocol bindings (v12.6.1)
    markers.odin        Base revision tag + request delimiters
  drivers/
    uart/uart.odin      16550 serial, polled
    fb/fb.odin          Surface, clipping, bevels, gradients, brushed fill
    fb/palette.odin     The system palette — single source of colour truth
    console/console.odin  Framebuffer text console
    console/font_data.odin GENERATED — do not hand-edit
  mem/
    mem.odin            Region/Boot_Memory types, HHDM, alignment, mem.init
    pmm.odin            Bitmap physical page allocator
    vmm.odin            Page table walk, kernel address space, translate
    heap.odin           Slab allocator + Odin's context.allocator
  vfs/
    lock.odin           What guards what, in what order, and the borrow rule
    vfs.odin            Server, the #name device table, the guarded RPC pair
    chan.odin           Chan, refcounting, open/read/write/stat/clone
    mount.odin          The mount table, bind/unmount, union member lists
    namespace.odin      Namespace, rfork semantics, teardown
    walk.odin           attach, walk1, cross_mounts, `..`, resolve
    readdir.odin        Union directory reads and the member-index cookie
    static.odin         A read-only server over a node table, and its fid table
    root.odin           `#/`, an instance of it, and the boot namespace
    verify.odin         The boot self-test: 51 checks, two real servers
  sched/
    thread.odin         Thread, Cpu, priorities, decay and boost, slice scaling
    queue.odin          Per-level FIFOs and the pick
    sched.odin          init, spawn, block/ready/unpark, reschedule, the tick
                        that also drains sync's deadlines
    verify.odin         The boot self-test: cooperative half and preemptive half
  mnt/
    mnt.odin            A 9P connection with several requests in flight: the
                        tag pool, the work queue, and the client's flush
    serve.odin          The workers, and where Rflush's ordering rule lives
  sync/
    spin.odin           The lock that masks: the interrupt flag, nesting handled
    wait.odin           Wait queues, scheduler hooks, priority-ordered service
    sleep.odin          The lock that parks: Mutex, and handoff rather than retry
    rendez.odin         Waiting for a condition, with or without a deadline
sys/
  libodin/format.odin   Allocation-free formatting (Sink)
  vectra9/
    proto.odin          Message kinds, Qid, the 57 bodies, the Msg union
    codec.odin          Encode/decode over a bounds-checked cursor; dirents
    errors.odin         Codec Error and protocol Errno, kept separate
    session.odin        Session, Transport, Handler; in-process and loopback
    verify.odin         The boot self-test
  libposix/             Empty
servers/ apps/          Empty
tools/genfont.py        TTF -> font_data.odin
docs/
  HANDOFF.md            This file
  VECTRA9.md            The protocol and namespace design -- sections 1-4 are
                        sys/vectra9/, section 5 is kernel/vfs/, section 7 is
                        why four arguments are over
  milestone0-boot.png   Milestone 0 screenshot -- it boots
  milestone1-memory.png Milestone 1 screenshot -- PMM, VMM, heap
  panic-screen.png      Milestone 2 screenshot -- a deliberate #PF, reported
```
