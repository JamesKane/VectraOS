/*
The scheduler.

One entry point into the switch, and one way out of it. A voluntary `yield` and
a timer preemption both arrive as an interrupt, and both land in `reschedule`.
Both leave by a return of a different `arch.Resume` to the trap tail. That tail
reloads `rsp` from it, and `iretq`s into whatever thread that was.

There is no second mechanism for a cooperative switch, and deliberately so. The
two paths would drift, and the one that drifts is the one that runs rarely.

    thread A ---- int $0x81 -----+
                                 |
    timer -------- vector 0x20 --+--> trap tail --> reschedule --> thread B
                                 |     (fxsave)       (policy)      (fxrstor)
    fault --------- vector n ----+                                  (rsp swap)

What runs here cannot allocate, cannot log and cannot fault. The run queues are
intrusive, which means the link is a field on `Thread`, for exactly that reason.
A scheduler that had to allocate to record that a thread is runnable could run
out of memory at the one moment it must not.
*/
package sched

import "base:intrinsics"
import "base:runtime"

import "kernel:arch"
import "kernel:mem"
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
twice. On two it is a lock word away from still being true. See `kernel/sync`.
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
ticks is the count of timer interrupts this core took.

Volatile, because an interrupt handler writes it and ordinary code reads it,
usually in a loop that waits for a change. The compiler is entitled to hoist a
plain load out of that loop, and the loop then never ends. That is the single
most confusing way for a scheduler to fail, because everything about it looks
correct in the source.
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

The idle thread is created here rather than lazily, because the alternative is a
`reschedule` that can fail. The moment it would fail is the moment every other
thread exited.
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
			current     = current_waiter,
			block       = block,
			unpark      = unpark_waiter,
			ready       = ready_waiter,
			priority    = waiter_priority,
			interrupted = waiter_interrupted,
		},
	)
	return true
}

// waiter_interrupted answers `sync`'s question inside an interruptible sleep:
// is a note waiting for this thread? Kernel threads answer no for ever.
@(private = "file")
waiter_interrupted :: proc "contextless" (w: sync.Waiter) -> bool {
	t := (^Thread)(w)
	return t != nil && intrinsics.volatile_load(&t.noted)
}

IDLE_STACK_SIZE :: 8 * 1024
DEFAULT_STACK_SIZE :: 32 * 1024

/*
idle_loop is what the core does with nothing to run, and the one thing it
does is give dead threads' stacks back.

**The reap used to run only from `spawn`.** A dead thread still stands on
its stack at the moment it leaves the core. So the free has to wait for
something else to be running, and `spawn` was the only something. A stack
therefore came back at the next spawn rather than when its thread exited.
Every self-test that brackets the heap had to call `reap` by hand before it
measured.

The idle thread is the something else that is always there. It runs exactly
when nothing else can, which is the moment after the last runnable thread
parked or died. So a stack comes back within a tick of its thread's exit
with nobody asking.

The context is the reap's: `free` and `delete` want an allocator, and a
thread's entry is contextless. The reaper in `kernel/user` sets its own the
same way and for the same reason.
*/
@(private = "file")
idle_loop :: proc "contextless" (arg: rawptr) {
	_ = arg
	ctx := runtime.default_context()
	ctx.allocator = mem.allocator()
	context = ctx
	for {
		reap()
		// Interrupts are on in this thread's frame, so the halt ends at the
		// next tick and the scheduler gets another chance to find work. A
		// `pause` loop would burn the core to reach the same place.
		arch.wait_for_interrupt()
	}
}

// -- Creating and ending threads ---------------------------------------------

/*
spawn creates a runnable thread.

Allocates two things, the `Thread` and its stack, and does so from the caller's
context, never from the scheduler's. The reap happens here too, and in the
idle thread, which is what makes a dead thread's stack come back when nothing
is spawning. A free of a stack requires something else to be standing on.
*/
spawn :: proc(
	name: string,
	entry: Thread_Proc,
	arg: rawptr = nil,
	priority: Priority = PRIORITY_NORMAL,
	affinity: Cpu_Classes = ANY_CLASS,
	stack_size: int = DEFAULT_STACK_SIZE,
	space: ^mem.Address_Space = nil,
) -> ^Thread {
	reap()
	return spawn_at(cpu(), name, entry, arg, priority, affinity, stack_size, space)
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
	space: ^mem.Address_Space = nil,
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
	t.kstack_top = arch.kernel_stack_top(stack)
	t.owns_stack = true
	t.name = name
	t.entry = entry
	t.arg = arg
	t.base = priority
	t.prio = priority
	t.id = next_id
	next_id += 1

	/*
	The space is set before the thread is enqueued, and that ordering is the
	whole of it. The next interrupt can dispatch a thread sitting on a run queue.
	One dispatched with the wrong space runs its first instruction through
	somebody else's tables.

	Nil is the kernel's, which is what every thread before this milestone
	carried and what every kernel thread still does.
	*/
	t.space = space

	guard := sync.acquire(&lock)
	enqueue(c, t)
	sync.release(&lock, guard)
	return t
}

/*
spawn_user creates a thread whose first instruction is a program's.

The same thread as any other, built the same way. It differs in exactly one
place: the frame `arch.thread_user_init` writes names a ring 3 code selector
rather than the kernel's. Everything after that is the ordinary path. The
scheduler dispatches it and the trap tail `iretq`s it. The CPU learns about the
privilege change when it reads the selector out of the frame, and not before.

`entry` and `sp` are addresses in `space`, and this procedure does not
dereference either. A caller that maps neither gets a thread that faults on its
first instruction fetch. That is the correct answer to nothing to run.

`space` is not optional and the check is not defensive. A user thread with no
space of its own would translate through the kernel's. Nothing in the kernel
half carries the bit that lets a program reach it, which is the whole point of
that half. The program would fault at once, four layers away from the mistake.

`record` is what `Thread.user` carries, which is what a fault handler in
interrupt context uses to find out whose program this was.
*/
spawn_user :: proc(
	name: string,
	space: ^mem.Address_Space,
	entry: uintptr,
	sp: uintptr,
	arg0: u64 = 0,
	arg1: u64 = 0,
	arg2: u64 = 0,
	record: rawptr = nil,
	priority: Priority = PRIORITY_NORMAL,
	stack_size: int = DEFAULT_STACK_SIZE,
) -> ^Thread {
	if space == nil || entry == 0 || sp == 0 || stack_size < arch.MIN_STACK_SIZE {
		return nil
	}
	reap()

	c := cpu()
	t := new(Thread)
	if t == nil {
		return nil
	}

	stack := make([]u8, stack_size)
	if stack == nil {
		free(t)
		return nil
	}

	resume, ok := arch.thread_user_init(stack, entry, sp, arg0, arg1, arg2)
	if !ok {
		delete(stack)
		free(t)
		return nil
	}

	t.resume = resume
	t.stack = stack
	t.kstack_top = arch.kernel_stack_top(stack)
	t.owns_stack = true
	t.name = name
	t.base = priority
	t.prio = priority
	t.affinity = ANY_CLASS
	t.id = next_id
	next_id += 1

	// Both before the enqueue, and for the same reason the space alone was.
	// The next interrupt may dispatch this thread. One dispatched without its
	// kernel stack in the TSS takes its first trap onto whatever address the
	// last thread left there.
	t.space = space
	t.user = record

	guard := sync.acquire(&lock)
	enqueue(c, t)
	sync.release(&lock, guard)
	return t
}

/*
spawn_user_clone starts a user thread that continues where another is now.

`spawn_user`'s shape with the initial state copied rather than built.
`arch.thread_user_clone` duplicates the caller's trap frame and FPU image
onto the new thread's own kernel stack. The copy answers zero where the
original will answer the child's pid. This is `rfork`'s half of the split.
The caller has already built the record, the space, and the copies the
frame's addresses land in. The enqueue at the bottom is the moment the
next interrupt may dispatch the child.
*/
spawn_user_clone :: proc(
	name: string,
	space: ^mem.Address_Space,
	src: ^arch.Trap_Frame,
	record: rawptr = nil,
	priority: Priority = PRIORITY_NORMAL,
	stack_size: int = DEFAULT_STACK_SIZE,
) -> ^Thread {
	if space == nil || src == nil || stack_size < arch.MIN_STACK_SIZE {
		return nil
	}
	reap()

	c := cpu()
	t := new(Thread)
	if t == nil {
		return nil
	}

	stack := make([]u8, stack_size)
	if stack == nil {
		free(t)
		return nil
	}

	resume, ok := arch.thread_user_clone(stack, src)
	if !ok {
		delete(stack)
		free(t)
		return nil
	}

	t.resume = resume
	t.stack = stack
	t.kstack_top = arch.kernel_stack_top(stack)
	t.owns_stack = true
	t.name = name
	t.base = priority
	t.prio = priority
	t.affinity = ANY_CLASS
	t.id = next_id
	next_id += 1

	t.space = space
	t.user = record

	guard := sync.acquire(&lock)
	enqueue(c, t)
	sync.release(&lock, guard)
	return t
}

/*
kill_current ends the running thread from inside a trap handler.

Takes the state the trap arrived with and returns the state to resume, which
will be some other thread's. That is the only way to end a thread that is not
cooperating. `exit` needs the thread to call it, and a program that faulted
calls nothing.

`spent_slice` is false. A thread that faulted did not consume a slice, and
charging it one would decay a priority that is about to stop existing.

The dead thread's stack is not freed here. `reschedule` puts it on the reap
list, and the next `spawn` gives it back, because the stack this trap is
standing on is that thread's.
*/
/*
note_thread marks a thread noted and makes it runnable if it was parked. The
flag is the note, as far as this package knows. `ready` is what turns a
parked thread's note into motion. The thread resumes inside its wait, the
wait's own unlink takes its node off every list, and an interruptible sleep
sees the flag and returns. The boundary checks handle a thread that was
running, at its next system call or its next tick, so `ready` leaves one
alone.

`ready` already refuses a thread that is Ready, Running or Dead, so this is
safe whatever the target is doing, including dying.
*/
note_thread :: proc "contextless" (t: ^Thread) {
	if t == nil {
		return
	}
	intrinsics.volatile_store(&t.noted, true)
	ready(t)
}

// clear_note consumes a thread's note flag. Delivery calls it -- the door
// or the tick, whichever hands the note to a ring 3 handler first. A note
// that stayed set through its own delivery would deliver again for ever.
clear_note :: proc "contextless" (t: ^Thread) {
	if t != nil {
		intrinsics.volatile_store(&t.noted, false)
	}
}

// thread_noted reports whether a note is waiting for a thread. For the
// boundary checks, which act where the flag alone cannot.
thread_noted :: proc "contextless" (t: ^Thread) -> bool {
	return t != nil && intrinsics.volatile_load(&t.noted)
}

/*
What the tick does with a noted thread it caught in ring 3.

Registered by `kernel/user`, the owner of processes, exactly as the fault
handler is. The tick is the one boundary a program cannot avoid crossing. A
compute-bound loop never makes a system call, and the timer is what makes `a
note ends a process` true for it too. The hook runs in interrupt context
with the interrupted thread's own frame, fills the record, and answers with
`kill_current`.
*/
Note_Trap :: #type proc "contextless" (r: arch.Resume) -> arch.Resume

@(private = "file")
note_trap: Note_Trap

set_note_trap :: proc "contextless" (h: Note_Trap) {
	note_trap = h
}

kill_current :: proc "contextless" (r: arch.Resume) -> arch.Resume {
	if t := cpu().current; t != nil {
		t.state = .Dead
	}
	return reschedule(r, spent_slice = false)
}

/*
thread_start is where every thread's first `iretq` lands.

It exists for two reasons. An ordinary `call` reaches the entry procedure, with
the stack alignment the ABI promises and a real return address behind it. And a
return from that procedure lands here, rather than jumping to whatever the
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

The thread marks itself dead and yields. `reschedule` moves it onto the reap
list rather than back onto a queue, and the next `spawn` gives its stack back.

The loop is not defensive padding. It is what happens if something schedules
this thread again. A halt inside it beats a fall off the end of a stack somebody
is reclaiming.
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

// reap_pending is how many dead threads are waiting for their stacks to be
// given back. A sensor for the self-test that checks the idle thread reaps
// them with nobody asking.
reap_pending :: proc "contextless" () -> int {
	c := cpu()
	guard := sync.acquire(&lock)
	defer sync.release(&lock, guard)
	n := 0
	for t := c.reap; t != nil; t = t.next {
		n += 1
	}
	return n
}

/*
reap gives back the stacks of threads that exited.

Called from thread context only. A dead thread still stands on its stack at the
moment it leaves the CPU, because the trap tail read its frame out of it. The
free therefore has to wait until something else is running.
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

Interrupts stay masked from the state change through the yield, and that is what
closes the window. A tick that landed between `I am blocked` and the switch
would find a Running thread marked Blocked. It would leave that thread off the
queue, with nothing scheduled to put it back. The mask makes the two one step.

There is no lost wake-up in the other direction. Say `ready` runs on another
thread before this one reaches the `int`. It sets the state back to Ready and
enqueues the thread, and the yield then finds an ordinary runnable thread.
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

Safe on a thread that is already ready or running. A double wake is a race every
caller would otherwise have to avoid. The second wake is a no-op rather than a
second queue entry.
*/
ready :: proc "contextless" (t: ^Thread) {
	wake(t, boosted = true)
}

/*
unpark makes a thread runnable *without* boosting it.

The distinction is the one Plan 9's boost is really about. A thread woken from
I/O waited on something outside itself. It gets its priority back as the price
of good manners, and that is what makes an interactive thread beat a
compute-bound one.

A thread woken because a lock it wanted came free waited on nothing of the kind.
It ran flat out, and merely queued behind another thread that did the same. A
boost there pays a thread for contention.

It is not a fine distinction in practice. `kernel/verify_vfs.odin` puts five
threads on one 9P session, where every message is a lock. With `ready`, the
worker whose rounds are longest starved twenty-fold. The contention itself
pinned every thread's priority to the top, and the scheduler had nothing left to
tell them apart with.
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

Adapters rather than the procedures themselves, because `sync` cannot name a
`^Thread`. This package imports it, so the dependency only runs one way, and a
thread is a `rawptr` on the other side of it. See `kernel/sync/sleep.odin`.
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

// yield gives up the rest of the current slice and keeps its priority. A thread
// that yields did not burn its slice, so it does not decay. That is what stops
// the scheduler from punishing a polite thread for good manners.
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
decide not to switch. Nothing after it may decide not to acknowledge. An
un-acknowledged local APIC delivers no further interrupt at that priority, and
the symptom is a timer that stopped with nothing anywhere reporting an error.

Deadlines are next, before anything charges a slice, and long before anyone
decides who runs. `sync.tick` starts every thread whose deadline arrived, and
says how many that was. A thread due at this tick is on a run queue by the time
`reschedule` looks. The direction is the one that is allowed. This package
imports `kernel:sync`, so the clock comes down rather than up.

A wake is a reason to re-decide, and it is not a reason to charge anybody. The
running thread did not spend its slice, so `spent_slice` is false. It neither
decays nor counts a preemption. It goes to the back of its own level, and gets
the core straight back unless the thread that just woke outranks it. Without
that call, a thread that asked for one tick would reach the core somewhere in
the next ten. That is not what it asked for.
*/
@(private = "file")
on_tick :: proc "contextless" (r: arch.Resume) -> arch.Resume {
	arch.timer_ack()

	c := cpu()
	now := c.ticks + 1
	intrinsics.volatile_store(&c.ticks, now)

	woken := sync.tick(now)

	// A noted thread caught in ring 3 dies here, because here is the one
	// boundary it cannot help crossing. The frame is the interrupted
	// thread's own, which is what the hook fills the record from.
	if t := c.current; t != nil && note_trap != nil {
		if intrinsics.volatile_load(&t.noted) && arch.frame_is_user(r.frame) {
			return note_trap(r)
		}
	}

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

// on_spurious is the local APIC's report that it withdrew an interrupt it began
// to deliver. Nothing acknowledges it. The architecture says a spurious
// interrupt does not set the in-service bit, so an EOI here would retire
// somebody else's.
@(private = "file")
on_spurious :: proc "contextless" (r: arch.Resume) -> arch.Resume {
	return r
}

/*
reschedule is the policy, and it is the only thing that changes `cpu.current`.

Runs with interrupts off in every case, because the gates are interrupt gates
and `block` masks by hand. It therefore takes no lock, and must not acquire one.

The outgoing thread's fate depends on the state it was in, not on why we got
here:

    Running, spent a slice   decays a level, goes to the back of the new level
    Running, did not         keeps its priority, goes to the back of its level
    Blocked                  goes nowhere, and `ready` is what brings it back
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
		// Before `init` runs there is nothing to switch to, and a return of
		// what we were given is an ordinary interrupt return.
		return r
	}

	/*
	The address space, before anything else about the incoming thread.

	Compared rather than written, because a write to CR3 flushes every
	non-global translation whether or not the value changed. Two kernel threads
	both carry nil, so the common switch does one comparison and no flush.

	The kernel half is identical in every space and mapped `Global`. The code
	executing this line, the stack under it and the thread record it reads all
	survive the reload. That is what `populate_higher_half` and
	`map_kernel_image` were for, four milestones before there was anything to
	switch to.
	*/
	if next.space != prev_space(prev) {
		c.space_switches += 1
		if next.space != nil {
			mem.space_switch(next.space)
		} else {
			mem.space_switch(mem.kernel_address_space())
		}
	}

	/*
	And where the CPU will push a frame that arrives from ring 3.

	Unconditional for every thread that owns a stack, rather than only for the
	ones that will reach ring 3. The scheduler does not know which those are,
	and the cost of being wrong is not a fault. A trap from ring 3 pushes onto
	whatever this says, before anything can check it. A stale value is
	therefore a triple fault with nothing on the screen.

	The boot thread carries zero, because its stack is the loader's and it will
	never be in ring 3 to come back from. Skipped rather than written, so the
	slot keeps the last real stack instead of a null one.
	*/
	if next.kstack_top != 0 {
		arch.set_kernel_stack(next.kstack_top)
	}

	c.current = next
	next.state = .Running
	next.cpu = c
	// A fresh slice only for a thread that spent its last one. A thread that
	// blocked halfway through keeps the other half. That is what makes decay
	// a measure of CPU consumed, rather than of how often something
	// interrupted it. See `Thread.ticks_left`.
	if next.ticks_left <= 0 {
		next.ticks_left = slice_ticks(c)
	}
	next.dispatches += 1
	if next != prev {
		c.switches += 1
	}
	return next.resume
}

// prev_space is the space the machine is translating through right now. Nil
// when the outgoing thread was a kernel one, and nil when there was none at
// all. The first dispatch on a core runs out of the kernel's space, because
// nothing else exists yet.
@(private = "file")
prev_space :: proc "contextless" (prev: ^Thread) -> ^mem.Address_Space {
	return prev == nil ? nil : prev.space
}

// -- The tick ----------------------------------------------------------------

@(private)
timer_hz: u64
@(private)
timer_count: u32

/*
start_timer arms the local timer and lets interrupts in for the first time.

`hz` is the tick rate, not the slice. A slice is `QUANTUM_TICKS` of these. One
kilohertz gives a ten-millisecond slice, with a tick fine enough to be worth
having for anything else that will eventually want one.

Returns false when the timer could not be calibrated. That is not fatal, and the
caller must say so rather than halt. A kernel with no preemption still runs. It
just runs whatever thread does not yield.
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

	// Switches that also reloaded CR3, which is a fraction of `switches` and
	// meant to be. Two kernel threads share the kernel's space and cost none.
	space_switches: u64,
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
		space_switches = c.space_switches,
		preemptions = c.preemptions,
		class       = c.class,
		capacity    = c.capacity,
		slice       = slice_ticks(c),
	}
}
