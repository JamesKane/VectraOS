/*
Threads, priorities, and what a core is.

A thread here is a kernel thread. It has one stack, one saved `Resume`, and no
address space of its own. There is no userland yet, so nothing in this package
switches CR3. When there is, a thread grows an `^Address_Space` and `reschedule`
grows one comparison, and nothing else in this file changes.

Priority is dynamic. A thread has a `base` it was created at, and a `prio` it is
running at. The two drift apart in the two directions Plan 9 drifts them. A
thread that accumulates a whole slice of CPU sinks a level. A thread that
blocks, and that something then wakes, rises to its base and a little above.

That is the whole anti-starvation mechanism, and it is why there is not a
separate one. A compute-bound thread settles at the bottom of the range within a
few slices. An interactive one stays near the top. Nothing ever tells either
which it is.

*Accumulates* is load-bearing. It used to say `burns without blocking`, which
was the same sentence for as long as nothing blocked. See `ticks_left`.
*/
package sched

import "kernel:arch"
import "kernel:mem"

/*
Sixteen levels, of which three are reserved.

    15  \
    14   >  realtime -- never decays, and will starve everything below it
    13  /
    12
    ...  the ordinary range: threads sink through it under load
    8      PRIORITY_NORMAL, where a new thread starts
    ...
    1   the floor for anything that is not the idle thread
    0   the idle thread, and only the idle thread

Realtime is a promise the scheduler keeps rather than a hint. That is exactly
why it is not the default, because a runaway thread up there stops the machine.
Nothing in Vectra runs there yet.
*/
Priority :: distinct int

PRIORITY_LEVELS :: 16
PRIORITY_IDLE :: Priority(0)
PRIORITY_MIN :: Priority(1)
PRIORITY_NORMAL :: Priority(8)
PRIORITY_REALTIME :: Priority(13)
PRIORITY_MAX :: Priority(PRIORITY_LEVELS - 1)

Thread_State :: enum {
	Ready, // On a run queue, waiting for a core
	Running, // On a core right now
	Blocked, // Off every queue until someone calls `ready`
	Dead, // Finished; its stack is waiting to be reclaimed
}

/*
Which classes of core a thread may run on.

Empty means `no constraint`. It does not mean the empty set, which would be
`nowhere`. An unset affinity is by far the common case, and the zero value keeps
`spawn` from a sentinel. `eligible` is the one place that decides the
distinction.

On amd64 every core is `.Performance` and this is inert. On a big.LITTLE arm64
part it is the difference between a housekeeping thread that belongs on an
efficiency core and a compositor that does not.
*/
Cpu_Classes :: bit_set[arch.Cpu_Class]

ANY_CLASS :: Cpu_Classes{}

Thread_Proc :: #type proc "contextless" (arg: rawptr)

Thread :: struct {
	// Where this thread's CPU state lives when it is not running. Both halves
	// point into its own stack, so the state travels with the thread and
	// nothing about it is per-core.
	resume: arch.Resume,
	stack:  []u8,

	name:   string,
	id:     int,
	entry:  Thread_Proc,
	arg:    rawptr,

	state:  Thread_State,

	base:   Priority, // Where a wake-up restores it to
	prio:   Priority, // Where it is now, after decay and boost

	/*
	Ticks left in the current slice, sized from the core's capacity so the
	same thread gets a longer slice on a slower core.

	Refilled when it runs out, *not* on every dispatch. That difference is the
	whole of a thread's CPU accounting. A thread that blocks keeps what is
	left of its slice, and resumes on it. The slice therefore measures CPU
	consumed rather than time between blocks.

	A refill on every dispatch was the original, and it was invisible until
	something blocked. A thread that parks forty times a tick never reaches
	the end of a slice. It therefore never decays, and sits at its base
	priority for ever, while the thread that does steady work sinks past it.

	The first sleeping lock made that reachable, and `kernel/verify_vfs.odin`
	found it immediately. The one worker that did not block got five
	dispatches in a thousand ticks. Decay is meant to measure appetite for
	the CPU, and a thread's appetite is what it consumes, not what interrupts
	it.
	*/
	ticks_left: int,

	affinity: Cpu_Classes,
	cpu:      ^Cpu,

	/*
	The address space this thread translates through, or nil for the kernel's.

	Nil rather than a pointer to the kernel space, and the difference is what
	`reschedule` compares. Every kernel thread carries nil, so a switch between
	two of them compares two nils and writes no CR3. That is the common case by
	a wide margin, and the one that must cost nothing.

	A thread with a space is not yet a process. A process is a space, a
	namespace and a set of open files, and this is the first of the three.
	*/
	space: ^mem.Address_Space,

	// Counters, all of them for the self-test rather than for the scheduler.
	slices:      u64, // Whole slices of CPU consumed, blocking or not
	preemptions: u64,
	dispatches:  u64,
	wakeups:     u64,

	next:       ^Thread, // Run queue and reap list link
	owns_stack: bool, // False for the boot thread, whose stack is the loader's
}

/*
One core.

Vectra has one, and the struct is per-core anyway. The alternative is a
scheduler written against globals, which somebody has to unpick the first time a
second core starts. Run queues, the current thread, the idle thread and the tick
count are all properties of a core. None of them are properties of the machine.

`class` and `capacity` come from `arch.cpu_class`. On amd64 that is always
`.Performance` at full capacity. On arm64 it is what makes a three-tier part
schedule sensibly.
*/
Cpu :: struct {
	id:       int,
	class:    arch.Cpu_Class,
	capacity: int,

	current: ^Thread,
	idle:    ^Thread,
	runq:    Run_Queue,

	ticks:       u64,
	switches:    u64,

	// Switches that also reloaded CR3. A fraction of `switches`, and the
	// fraction is the point: two kernel threads cost none.
	space_switches: u64,
	preemptions: u64,

	// Threads that exited, and that wait for somebody in thread context to
	// give their stacks back. A stack freed inside the timer interrupt would
	// mean an allocation from an interrupt handler. It would also mean a free
	// of the stack the interrupt stands on.
	reap: ^Thread,
}

MAX_CPUS :: 8

// eligible reports whether `t` may run on `c`. An empty affinity is no
// constraint. Anything else is a whitelist of core classes.
eligible :: proc "contextless" (t: ^Thread, c: ^Cpu) -> bool {
	if t.affinity == ANY_CLASS {
		return true
	}
	return c.class in t.affinity
}

/*
QUANTUM_TICKS is the slice a thread gets on a full-capacity core.

Ten milliseconds at the default 1 kHz tick. Long enough that the switch itself
is noise and short enough that four compute-bound threads still feel like four
things happening at once.
*/
QUANTUM_TICKS :: 10

/*
slice_ticks is that quantum, scaled by how fast the core is.

Equal *work*, not equal *time*. A core at half capacity does half as much in a
tick, so a thread there gets twice as many ticks. Without that, a thread moved
to an efficiency core would silently get half as much done per round of the
queue. The round-robin would then be fair only in a unit nobody cares about.
*/
slice_ticks :: proc "contextless" (c: ^Cpu) -> int {
	if c.capacity <= 0 {
		return QUANTUM_TICKS
	}
	ticks := QUANTUM_TICKS * arch.CAPACITY_FULL / c.capacity
	return max(ticks, 1)
}

/*
decay drops a thread a level for consuming a whole slice.

Floored at `PRIORITY_MIN` rather than at zero. Level zero belongs to the idle
thread, and a compute-bound thread that reached it would contend with the one
thing that must always lose.

Realtime threads do not decay. That is the promise, and it is also the hazard.
*/
decay :: proc "contextless" (t: ^Thread) {
	// Counted here rather than at dispatch, which makes `slices` the count of
	// slices *consumed*. That is the same quantity `ticks_left` measures, and
	// not the number of times a core took the thread.
	t.slices += 1
	if t.prio >= PRIORITY_REALTIME {
		return
	}
	if t.prio > PRIORITY_MIN {
		t.prio -= 1
	}
}

/*
boost lifts a thread that blocked and was woken.

Back to its base, plus one, capped below realtime. An interactive thread
therefore recovers everything a run of full slices cost it, and gets a little on
top. That is what makes it win the race to the CPU against the compute-bound
thread that woke it. Frequent blocks cannot climb it into realtime. A thread has
to ask for that level.
*/
boost :: proc "contextless" (t: ^Thread) {
	t.wakeups += 1
	if t.base >= PRIORITY_REALTIME {
		t.prio = t.base
		return
	}
	t.prio = min(t.base + 1, PRIORITY_REALTIME - 1)
}
