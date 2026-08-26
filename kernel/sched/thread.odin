/*
Threads, priorities, and what a core is.

A thread here is a kernel thread: one stack, one saved `Resume`, and no address
space of its own. There is no userland yet, so nothing in this package switches
CR3 -- when there is, a thread grows an `^Address_Space` and `reschedule` grows
one comparison, and nothing else in this file changes.

Priority is dynamic. A thread has a `base` it was created at and a `prio` it is
running at, and the two drift apart in the two directions Plan 9 drifts them: a
thread that accumulates a whole slice of CPU sinks a level, and a thread that
blocks and is woken is lifted back to its base and a little above. That is the
whole anti-starvation mechanism, and it is why there is not a separate one. The
effect is that a compute-bound thread settles at the bottom of the range within
a few slices while an interactive one stays near the top without either of them
being told which they are.

*Accumulates* is load-bearing and used to say "burns without blocking", which
was the same sentence for as long as nothing blocked. See `ticks_left`.
*/
package sched

import "kernel:arch"

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

Realtime is a promise the scheduler keeps rather than a hint, which is exactly
why it is not the default: a runaway thread up there stops the machine. Nothing
in Vectra runs there yet.
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

Empty means "no constraint", which is not the same as the empty set meaning
"nowhere" -- an unset affinity is by far the common case and making it the
zero value keeps `spawn` from needing a sentinel. `eligible` is the one place
that distinction is decided.

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

	Refilled when it runs out, *not* on every dispatch, and the difference is
	the whole of a thread's CPU accounting. A thread that blocks keeps what is
	left of its slice and resumes on it, so the slice measures CPU consumed
	rather than time between blocks.

	Refilling on every dispatch was the original and it was invisible until
	something blocked. A thread that parks forty times a tick never reaches
	the end of a slice, so it never decays, so it sits at its base priority
	for ever while the thread doing steady work sinks past it. The first
	sleeping lock made that reachable and `kernel/verify_vfs.odin` found it
	immediately: the one worker that was not blocking got five dispatches in a
	thousand ticks. Decay is meant to measure appetite for the CPU, and a
	thread's appetite is what it consumes, not how it is interrupted.
	*/
	ticks_left: int,

	affinity: Cpu_Classes,
	cpu:      ^Cpu,

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

Vectra has one and the struct is per-core anyway, because the alternative is a
scheduler written against globals that has to be unpicked the first time a
second core comes up. Run queues, the current thread, the idle thread and the
tick count are all properties of a core and none of them are properties of the
machine.

`class` and `capacity` come from `arch.cpu_class`. On amd64 that is always
`.Performance` at full capacity; on arm64 it is what makes a three-tier part
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
	preemptions: u64,

	// Threads that have exited, waiting for someone in thread context to give
	// their stacks back. Freeing a stack from inside the timer interrupt would
	// mean allocating from an interrupt handler, and it would mean freeing the
	// stack the interrupt is standing on.
	reap: ^Thread,
}

MAX_CPUS :: 8

// eligible reports whether `t` may run on `c`. An empty affinity is no
// constraint; anything else is a whitelist of core classes.
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
tick, so a thread there gets twice as many ticks -- otherwise moving a thread to
an efficiency core would silently halve what it gets done per round of the
queue, and the round-robin would be fair only in a unit nobody cares about.
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

Floored at `PRIORITY_MIN` rather than at zero: level zero belongs to the idle
thread, and a compute-bound thread that reached it would be competing with the
one thing that must always lose.

Realtime threads do not decay. That is the promise, and it is also the hazard.
*/
decay :: proc "contextless" (t: ^Thread) {
	// Counted here rather than at dispatch, which makes `slices` the count of
	// slices *consumed* -- the same quantity `ticks_left` measures, and not
	// the number of times the thread was put on a core.
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

Back to its base, plus one, capped below realtime -- so an interactive thread
recovers everything a run of full slices cost it and gets a little on top,
which is what makes it win the race to the CPU against the compute-bound thread
that woke it. It cannot climb into realtime by blocking often; that level has to
be asked for.
*/
boost :: proc "contextless" (t: ^Thread) {
	t.wakeups += 1
	if t.base >= PRIORITY_REALTIME {
		t.prio = t.base
		return
	}
	t.prio = min(t.base + 1, PRIORITY_REALTIME - 1)
}
