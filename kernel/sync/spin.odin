/*
The lock that masks, as opposed to the lock that sleeps.

A critical section on one core is `interrupts off`. On two cores it is
`interrupts off` *and* a word the other core cannot take. `Spinlock` is both,
with the nesting handled. `acquire` reports what the interrupt flag was and
`release` puts it back, so a lock taken inside a handler that was already
masked does not turn interrupts on when it finishes.

`Mutex` in `sleep.odin` is the other one, and the two are not interchangeable.
This one may be held anywhere, and must be released within a few instructions.
That one may be held across a wait, and must never be taken inside this one.
`can_sleep` below is how that rule is checked rather than remembered.

## The word, and who it names

`owner` is the core that holds the lock, as its id plus one, or zero for free.
A core rather than a thread, because a thread inside a spinlock has interrupts
masked and cannot leave the core, so the two are the same thing. It has to be
the core for one more reason: the scheduler takes its lock on one thread and
lets go of it on the next, after the switch, and only a core is there for the
whole of that. See `sched.switch_done`.

The same core may take a lock it already holds. `resize` calls `alloc`, and
both take the heap lock, so `depth` counts the nesting and only the outermost
release clears the word. A different core waits, with interrupts off, until the
word is clear. That wait is bounded by the rule above: the holder is inside a
few instructions and cannot park.

    lock := sync.acquire(&heap_lock)
    defer sync.release(&heap_lock, lock)

`Guard` is deliberately not a nil-able handle. A forgotten `defer` leaves
interrupts masked for the rest of the boot, which is loud. The alternative is a
lock that unlocks itself when it leaves scope, and that needs a destructor Odin
does not have.
*/
package sync

import "base:intrinsics"

import "kernel:arch"

Spinlock :: struct {
	// The core that holds this lock, plus one. Zero is free. Taken with a
	// compare-and-swap, which is the one instruction that makes a claim
	// atomic between cores.
	owner: u32,

	// How many times the holding core has taken it. `held` stays honest
	// through a re-entrant acquire, and only the last release clears `owner`.
	depth: int,
}

// Guard carries what `release` has to put back. Opaque on purpose. A caller
// that inspects it is a caller who reasons about the interrupt flag, and that
// is the thing the lock exists to stop.
Guard :: struct {
	interrupts_were_on: bool,
}

// me is this core's name in a lock word. Never zero, so that a free lock and
// a lock held by core 0 read differently.
@(private = "file")
me :: proc "contextless" () -> u32 {
	return u32(arch.percpu_id()) + 1
}

acquire :: proc "contextless" (l: ^Spinlock) -> Guard {
	// Interrupts off first, so a tick cannot land between the claim and the
	// count. A nested acquire finds them already off, and its guard says
	// `leave them off`, so only the outermost release turns them back on.
	g := Guard {
		interrupts_were_on = arch.irq_save(),
	}
	self := me()
	if intrinsics.atomic_load(&l.owner) != self {
		for {
			if _, won := intrinsics.atomic_compare_exchange_strong(&l.owner, 0, self); won {
				break
			}
			arch.spin_hint()
		}
	}
	l.depth += 1
	arch.percpu_critical_depth()^ += 1
	return g
}

release :: proc "contextless" (l: ^Spinlock, g: Guard) {
	l.depth -= 1
	if l.depth == 0 {
		intrinsics.atomic_store(&l.owner, 0)
	}
	arch.percpu_critical_depth()^ -= 1
	arch.irq_restore(g.interrupts_were_on)
}

// held reports whether a lock is currently taken by anybody, for an assertion
// in code that must run inside one.
held :: proc "contextless" (l: ^Spinlock) -> bool {
	return intrinsics.atomic_load(&l.owner) != 0
}

// held_here reports whether this core holds the lock. The scheduler asks it
// after a switch, to know whether the lock it may have carried across is
// its to let go of.
held_here :: proc "contextless" (l: ^Spinlock) -> bool {
	return intrinsics.atomic_load(&l.owner) == me()
}

/*
release_all lets go of a lock this core holds at any depth, and leaves the
interrupt flag alone.

For exactly one caller, `sched.switch_done`. The scheduler takes its lock
before it switches threads, possibly twice -- once in `block`, once in
`reschedule` -- and the release has to happen after the switch, on the
incoming thread's stack. That release cannot restore an interrupt flag: the
frame the trap tail is about to `iretq` into carries the incoming thread's
own, and that is the one that must win.

The critical depth comes down by the whole nesting, because every acquire
that went into it was this core's and none of them will see a release.
*/
release_all :: proc "contextless" (l: ^Spinlock) {
	depth := l.depth
	l.depth = 0
	intrinsics.atomic_store(&l.owner, 0)
	arch.percpu_critical_depth()^ -= i64(depth)
}

/*
How many spinlocks this core is inside, counting all of them together.

Not per lock -- `Spinlock.depth` is that. This is a property of the core, and
it answers exactly one question. May the code running right now stop running? A
thread inside any spinlock has interrupts masked. If that thread leaves the
core, the interrupt flag stays clear and nothing will set it again. That is a
hang with no error, at a point arbitrarily far from the code that caused it.

So every sleeping wait checks this first, and `kernel/vfs` checks it before it
sends a 9P message. See `rpc_begin`. The count lives behind `GS`, one per
core, because a second core has its own answer. See `arch.Percpu`.

A spinlock is not the only thing that forbids a park. A top half holds none
and still may not sleep. It runs on a thread it does not own, and cannot be
the thing put to sleep. That half of the answer is `arch.in_interrupt`, which
the trap dispatcher brackets a handler with, and `can_sleep` reads both.
*/
can_sleep :: proc "contextless" () -> bool {
	return arch.percpu_critical_depth()^ == 0 && !arch.in_interrupt()
}
