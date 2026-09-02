# The other cores

Vectra runs on every core the bootloader lists. This document records how a
second core arrives, what had to become true before one could, and what is
still one core's truth. `kernel/smp.odin` is the arrival, and
`kernel/verify_smp.odin` is the proof. The two packages that changed
underneath are `kernel/sync` and `kernel/sched`.

## What the bootloader does, and what it does not

The Limine protocol starts the cores. A request in the kernel image asks for
it. With `mp_request` present, the bootloader wakes every application
processor and parks it, spinning on a word of its own. Each waits in the
machine state the boot core got. That is long mode, the bootloader's page
tables, a 64 KiB stack, interrupts off, no IDT and no TSS.

The response lists every core with its LAPIC id. A store of an address to a core's word sends the core
to that address, with a pointer to its record in `rdi`.

That retires the trampoline the handoff once listed. Vectra needs no real-mode
stub, no copy of one below a megabyte, and no INIT-SIPI-SIPI sequence of its
own. What it needs is the same thing the boot core needs. That is an entry
that can run before the runtime, and everything `kmain` did before it had a
scheduler.

What the bootloader does not do is anything after that store. The core's stack
and tables are the bootloader's, in bootloader-reclaimable memory, and nothing
the kernel builds may depend on either. The x2APIC is asked to stay off,
because the LAPIC driver speaks the memory-mapped xAPIC. A bootloader that
cannot turn x2APIC off refuses to boot. That is the honest answer, and a
handoff into a mode nothing here can drive is not.

## How a core arrives

`ap_entry` is where a released core lands, and it does two things. It turns
SSE on, because the next Odin statement may use an XMM register for an
ordinary struct move, exactly as `kmain`'s first line does. Then it leaves the
bootloader's stack and tables through `arch.ap_switch`. That is three register
writes in `ap.S`, which no Odin procedure can make about its own frame. The
stack it moves to is one the boot core took from the heap, and the tables are
the kernel's own.

`ap_main` is `kmain` from the point the two diverge, in the same order and for
the same reasons:

    traps         its own GDT and TSS, the one IDT every core loads
    paging bits   CR0.WP and EFER.NXE, which the bootloader clears
    syscall       the MSRs are per core, and a program may be dispatched here
    APIC          the enable bit is per core, the register page is shared
    scheduler     adopt the arrival as a thread, make an idle thread
    timer         the count the boot core measured, then interrupts on
    publish       `cpu_online`, and only now may a thread be placed here
    exit          the arrival thread dies, and the idle thread has the core

The arrival thread owns the stack it stands on, so the stack goes back to the
heap when the core's idle thread reaps it. The bootloader's stack is simply
abandoned. Nothing reclaims bootloader memory yet. The day something does, it
must not run before every core is gone from there.

**The cores start last.** Every self-test in `kmain` was written for one core
and says so wherever it counts something. They all run first. `init_smp`
releases the cores after `verify_user` and waits a bounded number of ticks
for each to report. The boot core logs the result for all of them, because
the log has no lock. `verify_smp` then asks the questions only a second core
can answer.

## What had to become true first

The handoff named four things that become urgent the moment a second core
runs. Three are done, one turned out to be done already, and a fifth was
found on the way.

### The lock word

`sync.Spinlock` was a name for the interrupt flag with the nesting handled.
It has a word now: the id of the core that holds it, plus one, taken with a
compare-and-swap. A core rather than a thread, because a thread inside a
spinlock has interrupts masked and cannot leave the core. It has to be the
core for a second reason below.

The same core may take a lock it holds.
`resize` calls `alloc`, and both take the heap lock, so `depth` counts the
nesting and the last release clears the word. Every site that needed the word
was already wrapped, which was the point of the wrapping, and no caller
changed.

### The critical depth, per core

`can_sleep` answers `may the code running here park`, and that is a question
about a core. The count of spinlocks and the count of trap handlers both moved
behind `GS`, into `arch.Percpu`. That record already held the kernel stack
pointer the syscall stub finds there. So did the GDT, the TSS and the fault
stacks move. A TSS names the stacks a core switches to, and `ltr` marks its
descriptor busy, so neither can be shared.

### The scheduler lock, held across the switch

This is the one the handoff put third and it is the one that matters most.
`reschedule` writes the outgoing thread's `Resume` and marks it Ready or
Blocked. On one core nothing could act on that before the trap tail was off
the outgoing stack. On two cores a waker on the other core can enqueue the
thread, and a third core can dispatch it. This core's trap tail is then still
reading the `Resume` off that thread's stack.

So the scheduler lock is taken before the switch and let go of after it.
`block` takes it, `reschedule` takes it again nested, and neither releases.
`switch_done` does, called from `isr.S` after the stack pointer is on the
incoming frame and before `fxrstor`. That release is by the core, not the
thread, which is why a lock word names a core. It does not touch the interrupt
flag, because the frame the tail is about to `iretq` into carries the incoming
thread's own. `sync.release_all` exists for exactly this caller.

The hook runs on the incoming thread's stack, below both its frame and its
FXSAVE area. An interrupted thread has the area below its frame, and a fresh
one has it above. The first cut put the hook's frame at the frame base, which
is inside an interrupted thread's FXSAVE area. `fxrstor` then read an area the
hook used as a stack. The reserved tail of the area absorbed it on every boot
but one. `isr.S` takes the lower of the two now.

### The wait lists

Every wait list in `kernel/sync` was under the interrupt mask. They are under
one lock now, `wait_lock`, one for every queue and the timer list together.
Plan 9 has a lock per `Rendez`, and the handoff expected the same. One lock
was the better answer. A thread with a deadline is on a queue and on the
timer list at once, and a wake may start from either side. Two locks would be
taken in both orders.

One lock has no order to get wrong.

What that lock does not cover is the condition. A condition may take the
spinlock of the thing it reads, and a waker may hold that same spinlock while
it calls `wakeup`. A condition tested under `wait_lock` would take the two in
the other order, and on two cores that is a deadlock. So `wait_on` registers
first, under the lock, tests second, with none, and parks third, only if the
node is still registered.

`block` takes a pointer to the node's `queue` field and reads it under the
scheduler lock. A waker unlinks under `wait_lock` and readies under the
scheduler lock. Either the park sees the unlink and does not happen, or the
ready sees a parked thread and starts it. The scheduler lock serialises the
two, and there is no third order.

The condition therefore runs with interrupts on, which it did not before. None
in the tree assumed otherwise. The file comment in `rendez.odin` now says what
a condition may and may not do.

### The reference counts

The handoff's first item, atomic increments for `Chan.refs` and
`Mount_Point.refs`, was already answered. Both are under `object_lock`, which
is a `Spinlock`, and a `Spinlock` with a word is exclusion. Nothing needed to
change. `docs/NAMESPACE.md` was right about where the counts were guarded.

### The clock

Every core has a timer and only one of them is the clock. `sync.tick`
advances on the boot core alone, and a deadline is a number on that count. An
application processor's tick is preemption and nothing else. `sched.ticks`
reads the boot core's count wherever it is called. A thread that read its own
core's count would read a different clock every time it moved.

## What the self-test proves

`verify_smp` runs after the cores are up. The boot thread never parks on
anything a missing core would have to end, and every wait has a bound.
Thirteen checks:

- every core the bootloader listed is online, and there is more than one
- every core's tick count moves over twenty ticks of the boot core's clock
- sixteen spinning workers, each holding a core for three slices, end on more
  than one core, and every core's switch count moved while they ran
- sixteen parking workers, each sleeping a tick at a time forty times, all
  finish, and every delay ended by its deadline. They too end on more than
  one core. That is a wait list written from several cores, and a scheduler
  lock taken from several. It is also a thread let go of by one core and
  taken by another, six hundred times
- every core reaps its own dead, and the heap is balanced afterwards

The ring 3 servers that `verify_user` leaves running -- the console, the
keyboard, the draw server -- are scheduled across the cores from then on.
They are not checked by name here, and `boot complete` after them is the
check.

## What is still one core's

- **No IPI.** A thread woken for an idle core waits for that core's next tick,
  up to a millisecond. Placement is right and delivery is late. An IPI on wake
  is the fix. A TLB shootdown and a panic broadcast need the same LAPIC
  register, so all three arrive together.
- **No TLB shootdown.** A process has one thread, and a core switching to a
  process reloads CR3, which flushes every non-global entry. That is what
  makes it safe today. The day a process has two threads on two cores, an
  unmap on one has to reach the other.
- **The log has no lock.** Only the boot core logs. A panic on another core
  writes the screen and the serial line under nobody's exclusion and halts
  only itself. A broadcast stop is an IPI, above.
- **The process table has no lock.** `kernel/user` claims a slot by finding
  one that is not live. Two `rfork` calls on two cores can find the same one.
  The ring 3 servers running after boot have not tripped it. It is next.
- **`cpu_class` is still one class.** Every core reports `.Performance` at
  full capacity, so the placement policy spreads by load alone. The three
  tiers `docs/SCHED.md` argues wait for an arm64 `cpu_class`.
- **The NMI window.** `arch.Percpu` documents an NMI between the syscall
  stub's `swapgs` and its next instruction. A handler that read the per-core
  depths there would read them through the program's base. Nothing handles an
  NMI yet, and the paranoid entry is the answer when something does.

## See also

- `docs/SYNC.md` -- the sleeping locks the wait lock now covers
- `docs/SCHED.md` -- placement, which was built for this and was inert until
  now
- `docs/TESTING.md` -- why every wait here has a bound
- `docs/HANDOFF.md` -- where this sits on the forward list
