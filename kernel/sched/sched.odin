/*
The scheduler.

One entry point into the switch and one way out of it. A voluntary `yield` and a
timer preemption both arrive as an interrupt, both land in `reschedule`, and
both leave by returning a different `arch.Resume` to the trap tail -- which
reloads `rsp` from it and `iretq`s into whatever thread that was. There is no
second mechanism for cooperative switching and deliberately so: the two paths
would drift, and the one that drifts is the one that runs rarely.

    thread A ---- int $0x81 -----+
                                 |
    timer -------- vector 0x20 --+--> trap tail --> reschedule --> thread B
                                 |     (fxsave)       (policy)      (fxrstor)
    fault --------- vector n ----+                                  (rsp swap)

What runs here cannot allocate, cannot log and cannot fault. The run queues are
intrusive -- the link is a field on `Thread` -- for exactly that reason: a
scheduler that had to allocate to record that a thread is runnable could not
run out of memory at the one moment it must not.
*/
package sched

import "base:intrinsics"

import "kernel:arch"
import "kernel:sync"

@(private)
cpus: [MAX_CPUS]Cpu
@(private)
cpu_count: int
@(private)
next_id: int

/*
The scheduler lock.

Every mutation of a run queue happens either inside an interrupt handler, where
interrupts are already off, or under this. On one core that is the same thing
twice; on two it is a lock word away from still being true. See `kernel/sync`.
*/
@(private)
lock: sync.Spinlock

// cpu returns the core this code is running on. One core today, and the
// indirection is the point: every caller already asks rather than assuming.
cpu :: proc "contextless" () -> ^Cpu {
	return &cpus[0]
}

current :: proc "contextless" () -> ^Thread {
	return cpu().current
}

/*
ticks is the count of timer interrupts this core has taken.

Volatile because it is written by an interrupt handler and read by ordinary
code, usually in a loop waiting for it to change. A plain load there is one the
compiler is entitled to hoist out of the loop, and the loop then never ends --
which is the single most confusing way for a scheduler to fail, because
everything about it looks correct in the source.
*/
ticks :: proc "contextless" () -> u64 {
	return intrinsics.volatile_load(&cpu().ticks)
}

// -- Bring-up ----------------------------------------------------------------

/*
init adopts the boot context as a thread and gives the core an idle thread.

Adopting rather than creating, because the boot context already has a stack --
Limine's -- and is already running. It becomes thread 0 at normal priority and
is scheduled like anything else from the next tick onward. Its stack is not ours
to free, which is what `owns_stack` records.

The idle thread is created here rather than lazily because the alternative is a
`reschedule` that can fail, and the moment it would fail is the moment every
other thread has exited.
*/
init :: proc() -> bool {
	c := cpu()
	if c.idle != nil {
		return true
	}

	class, capacity := arch.cpu_class()
	c.id = 0
	c.class = class
	c.capacity = capacity
	cpu_count = 1

	boot := new(Thread)
	if boot == nil {
		return false
	}
	boot.name = "boot"
	boot.id = next_id
	next_id += 1
	boot.state = .Running
	boot.base = PRIORITY_NORMAL
	boot.prio = PRIORITY_NORMAL
	boot.cpu = c
	boot.ticks_left = slice_ticks(c)
	boot.owns_stack = false
	c.current = boot

	idle := spawn_at(c, "idle", idle_loop, nil, PRIORITY_IDLE, ANY_CLASS, IDLE_STACK_SIZE)
	if idle == nil {
		return false
	}
	// The idle thread is never on a queue -- `enqueue` refuses it by identity,
	// so this assignment has to happen before anything tries.
	remove(c, idle)
	c.idle = idle
	idle.state = .Ready

	arch.set_interrupt_handler(arch.VECTOR_YIELD, on_yield)
	arch.set_interrupt_handler(arch.VECTOR_SPURIOUS, on_spurious)

	// Last, because it publishes a working scheduler to `kernel:sync`: from
	// here on a `sync.Mutex` parks its loser instead of refusing. Everything
	// above this line ran with one thread and could not contend.
	sync.set_scheduler(
		sync.Scheduler {
			current  = current_waiter,
			block    = block,
			unpark   = unpark_waiter,
			ready    = ready_waiter,
			priority = waiter_priority,
		},
	)
	return true
}

IDLE_STACK_SIZE :: 8 * 1024
DEFAULT_STACK_SIZE :: 32 * 1024

@(private = "file")
idle_loop :: proc "contextless" (arg: rawptr) {
	_ = arg
	for {
		// Interrupts are on in this thread's frame, so the halt ends at the
		// next tick and the scheduler gets another chance to find work. A
		// `pause` loop would burn the core to reach the same place.
		arch.wait_for_interrupt()
	}
}

// -- Creating and ending threads ---------------------------------------------

/*
spawn creates a runnable thread.

Allocates two things -- the `Thread` and its stack -- and does so from the
caller's context, never from the scheduler's. Reaping happens here too, which
is why a dead thread's stack comes back at the next spawn rather than at the
moment it exits: freeing a stack requires being off it.
*/
spawn :: proc(
	name: string,
	entry: Thread_Proc,
	arg: rawptr = nil,
	priority: Priority = PRIORITY_NORMAL,
	affinity: Cpu_Classes = ANY_CLASS,
	stack_size: int = DEFAULT_STACK_SIZE,
) -> ^Thread {
	reap()
	return spawn_at(cpu(), name, entry, arg, priority, affinity, stack_size)
}

@(private)
spawn_at :: proc(
	c: ^Cpu,
	name: string,
	entry: Thread_Proc,
	arg: rawptr,
	priority: Priority,
	affinity: Cpu_Classes,
	stack_size: int,
) -> ^Thread {
	if entry == nil || stack_size < arch.MIN_STACK_SIZE {
		return nil
	}

	t := new(Thread)
	if t == nil {
		return nil
	}

	// An affinity that excludes this core is a thread that would sit on a queue
	// nothing drains. Refused here rather than enqueued, because the failure is
	// otherwise invisible: the thread simply never runs.
	t.affinity = affinity
	if !eligible(t, c) {
		free(t)
		return nil
	}

	stack := make([]u8, stack_size)
	if stack == nil {
		free(t)
		return nil
	}

	resume, ok := arch.thread_resume_init(stack, rawptr(thread_start), t, nil)
	if !ok {
		delete(stack)
		free(t)
		return nil
	}

	t.resume = resume
	t.stack = stack
	t.owns_stack = true
	t.name = name
	t.entry = entry
	t.arg = arg
	t.base = priority
	t.prio = priority
	t.id = next_id
	next_id += 1

	guard := sync.acquire(&lock)
	enqueue(c, t)
	sync.release(&lock, guard)
	return t
}

/*
thread_start is where every thread's first `iretq` lands.

It exists so that an entry procedure is reached by an ordinary `call` -- with
the stack alignment the ABI promises and a real return address behind it -- and
so that returning from one is caught here instead of jumping to whatever the
initial frame happened to leave in the return slot.
*/
@(private = "file")
thread_start :: proc "sysv" (arg: rawptr) {
	t := cast(^Thread)arg
	if t != nil && t.entry != nil {
		t.entry(t.arg)
	}
	exit()
}

/*
exit ends the calling thread and does not return.

The thread is marked dead and yields; `reschedule` moves it onto the reap list
rather than back onto a queue, and the next `spawn` gives its stack back. The
loop is not defensive padding -- it is what happens if this thread is somehow
scheduled again, and halting inside it is better than falling off the end of a
stack that is being reclaimed.
*/
exit :: proc "contextless" () -> ! {
	arch.disable_interrupts()
	if t := current(); t != nil {
		t.state = .Dead
	}
	for {
		arch.yield_now()
	}
}

/*
reap gives back the stacks of threads that have exited.

Called from thread context only. A dead thread is still standing on its stack
at the moment it is descheduled -- the trap tail read its frame out of it --
so the free has to wait until something else is running.
*/
reap :: proc() {
	c := cpu()
	for {
		guard := sync.acquire(&lock)
		t := c.reap
		if t != nil {
			c.reap = t.next
			t.next = nil
		}
		sync.release(&lock, guard)

		if t == nil {
			return
		}
		if t.owns_stack && t.stack != nil {
			delete(t.stack)
		}
		free(t)
	}
}

// -- Blocking and waking -----------------------------------------------------

/*
block takes the caller off every queue until someone calls `ready` on it.

Interrupts stay masked from the state change through the yield, which is what
closes the window: a tick landing between "I am blocked" and the switch would
find a Running thread marked Blocked and leave it off the queue with nothing
scheduled to put it back. Masking makes the two one step.

There is no lost wake-up in the other direction. If `ready` runs on another
thread before this one reaches the `int`, it sets the state back to Ready and
enqueues it, and the yield then finds an ordinary runnable thread.
*/
block :: proc "contextless" () {
	was_on := arch.irq_save()
	if t := current(); t != nil {
		t.state = .Blocked
	}
	arch.yield_now()
	arch.irq_restore(was_on)
}

/*
ready makes a blocked thread runnable again, and boosts it for having blocked.

Safe to call on a thread that is already ready or running -- waking something
twice is a race every caller would otherwise have to avoid, and the second wake
is a no-op rather than a second queue entry.
*/
ready :: proc "contextless" (t: ^Thread) {
	wake(t, boosted = true)
}

/*
unpark makes a thread runnable *without* boosting it.

The distinction is the one Plan 9's boost is really about. A thread woken from
I/O waited on something outside itself and gets its priority back as the price
of having been polite -- that is what makes an interactive thread beat a
compute-bound one. A thread woken because a lock it wanted came free waited on
nothing of the kind: it was running flat out and merely queued behind another
thread doing the same. Boosting that one pays a thread for contending.

It is not a fine distinction in practice. `kernel/verify_vfs.odin` puts five
threads on one 9P session, where every message is a lock: with `ready` the
worker whose rounds are longest was starved twenty-fold, because every thread's
priority was pinned to the top by the contention itself and the scheduler had
nothing left to tell them apart with.
*/
unpark :: proc "contextless" (t: ^Thread) {
	wake(t, boosted = false)
}

@(private = "file")
wake :: proc "contextless" (t: ^Thread, boosted: bool) {
	if t == nil {
		return
	}
	guard := sync.acquire(&lock)
	defer sync.release(&lock, guard)

	if t.state == .Ready || t.state == .Running || t.state == .Dead {
		return
	}
	if boosted {
		boost(t)
	} else {
		t.wakeups += 1
	}
	enqueue(cpu(), t)
}

/*
What `kernel:sync` is handed so its sleeping locks can park a thread.

Adapters rather than the procedures themselves because `sync` cannot name a
`^Thread`: it is imported *by* this package, so the dependency only runs one
way, and a thread is a `rawptr` on the other side of it. See `kernel/sync/
sleep.odin`.
*/
@(private = "file")
current_waiter :: proc "contextless" () -> rawptr {
	return rawptr(current())
}

@(private = "file")
unpark_waiter :: proc "contextless" (w: rawptr) {
	unpark((^Thread)(w))
}

@(private = "file")
ready_waiter :: proc "contextless" (w: rawptr) {
	ready((^Thread)(w))
}

@(private = "file")
waiter_priority :: proc "contextless" (w: rawptr) -> int {
	t := (^Thread)(w)
	if t == nil {
		return int(PRIORITY_IDLE)
	}
	return int(t.prio)
}

// yield gives up the rest of the current slice without losing priority. A
// thread that yields has not burned its slice, so it does not decay -- which
// is what stops a polite thread from being punished for being polite.
yield :: proc "contextless" () {
	arch.yield_now()
}

// -- The switch --------------------------------------------------------------

@(private = "file")
on_yield :: proc "contextless" (r: arch.Resume) -> arch.Resume {
	return reschedule(r, spent_slice = false)
}

/*
on_tick is the preemption path, and the only clock anything else has.

The acknowledgement comes first and unconditionally. Everything after it can
decide not to switch, but nothing after it may decide not to acknowledge: an
un-acknowledged local APIC delivers no further interrupt at that priority, and
the symptom is a timer that stopped with nothing anywhere reporting an error.

Deadlines are next, before the slice is charged and long before anyone decides
who runs. `sync.tick` starts every thread whose deadline has arrived and says
how many that was; a thread due at this tick is on a run queue by the time
`reschedule` looks. The direction is the one that is allowed -- this package
imports `kernel:sync`, so the clock is handed down rather than reached up for.

A wake is a reason to re-decide, and it is not a reason to charge anybody. The
running thread has not spent its slice, so `spent_slice` is false and it neither
decays nor counts a preemption; it goes to the back of its own level and gets
the core straight back unless the thread that just woke outranks it. Without
that call a thread that asked for one tick would be handed the core somewhere
in the next ten, which is not what it asked for.
*/
@(private = "file")
on_tick :: proc "contextless" (r: arch.Resume) -> arch.Resume {
	arch.timer_ack()

	c := cpu()
	now := c.ticks + 1
	intrinsics.volatile_store(&c.ticks, now)

	woken := sync.tick(now)

	t := c.current
	if t != nil && t.state == .Running {
		t.ticks_left -= 1
		if t.ticks_left > 0 {
			if woken == 0 {
				return r
			}
			return reschedule(r, spent_slice = false)
		}
	}
	return reschedule(r, spent_slice = true)
}

// on_spurious is the local APIC saying an interrupt it had begun to deliver
// was withdrawn. It is not acknowledged -- the architecture says a spurious
// interrupt does not set the in-service bit, so an EOI here would retire
// somebody else's.
@(private = "file")
on_spurious :: proc "contextless" (r: arch.Resume) -> arch.Resume {
	return r
}

/*
reschedule is the policy, and it is the only thing that changes `cpu.current`.

Runs with interrupts off in every case -- the gates are interrupt gates and
`block` masks by hand -- so it takes no lock and must not acquire one.

The outgoing thread's fate depends on the state it was in, not on why we got
here:

    Running, spent a slice   decays a level, goes to the back of the new level
    Running, did not         keeps its priority, goes to the back of its level
    Blocked                  goes nowhere; `ready` is what brings it back
    Dead                     goes on the reap list

`spent_slice` is the whole of the charge, and it is a question about the
outgoing thread rather than about why the switch happened. A thread that
yielded did not spend one. Neither did one that was interrupted so that a
thread whose deadline arrived could be looked at. Only running out of
`ticks_left` spends a slice, which is what makes decay a measure of CPU
consumed -- see `Thread.ticks_left`.
*/
@(private)
reschedule :: proc "contextless" (r: arch.Resume, spent_slice: bool) -> arch.Resume {
	c := cpu()
	prev := c.current

	if prev != nil {
		// Where the outgoing thread's registers live until it runs again.
		// Written before anything can pick it, which on one core is anything
		// at all after this line.
		prev.resume = r

		switch prev.state {
		case .Running:
			if spent_slice {
				prev.preemptions += 1
				c.preemptions += 1
				decay(prev)
			}
			prev.state = .Ready
			if prev != c.idle {
				enqueue(c, prev)
			}
		case .Ready:
			if prev != c.idle {
				enqueue(c, prev)
			}
		case .Blocked:
		// Off every queue on purpose.
		case .Dead:
			prev.next = c.reap
			c.reap = prev
		}
	}

	next := dequeue_highest(c)
	if next == nil {
		next = c.idle
	}
	if next == nil {
		// Before `init` has run there is nothing to switch to, and returning
		// what we were given is an ordinary interrupt return.
		return r
	}

	c.current = next
	next.state = .Running
	next.cpu = c
	// A fresh slice only for a thread that has spent its last one. A thread
	// that blocked halfway through keeps the other half, which is what makes
	// decay a measure of CPU consumed rather than of how often it was
	// interrupted -- see `Thread.ticks_left`.
	if next.ticks_left <= 0 {
		next.ticks_left = slice_ticks(c)
	}
	next.dispatches += 1
	if next != prev {
		c.switches += 1
	}
	return next.resume
}

// -- The tick ----------------------------------------------------------------

@(private)
timer_hz: u64
@(private)
timer_count: u32

/*
start_timer arms the local timer and lets interrupts in for the first time.

`hz` is the tick rate, not the slice: a slice is `QUANTUM_TICKS` of these. One
kilohertz gives a ten-millisecond slice with a tick fine enough to be worth
having for anything else that will eventually want one.

Returns false when the timer could not be calibrated. That is not fatal and the
caller is expected to say so rather than halt -- a kernel with no preemption
still runs, it just runs whatever thread does not yield.
*/
start_timer :: proc "contextless" (hz: u64 = 1000) -> bool {
	if !arch.timer_attached() || hz == 0 {
		return false
	}

	frequency := arch.timer_calibrate()
	if frequency == 0 {
		return false
	}

	count := frequency / hz
	if count == 0 {
		return false
	}

	timer_hz = hz
	timer_count = u32(min(count, u64(max(u32))))

	arch.set_interrupt_handler(arch.VECTOR_TIMER, on_tick)
	arch.timer_periodic(u8(arch.VECTOR_TIMER), timer_count)
	arch.enable_interrupts()
	return true
}

// stop_timer masks the tick and leaves interrupts on. Used by the self-test to
// put the machine back the way it found it after measuring preemption.
stop_timer :: proc "contextless" () {
	arch.timer_stop()
}

Timer_Stats :: struct {
	hz:        u64,
	count:     u32,
	frequency: u64, // What the calibration measured, in LAPIC ticks per second
}

timer_stats :: proc "contextless" () -> Timer_Stats {
	return Timer_Stats{hz = timer_hz, count = timer_count, frequency = timer_hz * u64(timer_count)}
}

Stats :: struct {
	threads:     int,
	ready:       int,
	ticks:       u64,
	switches:    u64,
	preemptions: u64,
	class:       arch.Cpu_Class,
	capacity:    int,
	slice:       int,
}

stats :: proc "contextless" () -> Stats {
	c := cpu()
	return Stats {
		threads     = next_id,
		ready       = ready_count(c),
		ticks       = c.ticks,
		switches    = c.switches,
		preemptions = c.preemptions,
		class       = c.class,
		capacity    = c.capacity,
		slice       = slice_ticks(c),
	}
}
