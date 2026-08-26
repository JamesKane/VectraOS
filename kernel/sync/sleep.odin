/*
The lock that sleeps.

`Spinlock` cannot be held across a wait, because the only thing it does is mask
interrupts: descheduling a thread that holds one leaves the machine with the
interrupt flag clear and nothing scheduled to set it again. That is fine for
the handful of instructions a spinlock is meant to cover, and it is the wrong
shape for the one thing `kernel/vfs` genuinely needs -- exclusive use of a 9P
session for the whole of a message, request through reply.

    Spinlock   masks interrupts; a few instructions; anywhere
    Mutex      parks the thread; a whole message; never inside a Spinlock

Today the in-process transport runs the server's handler on the caller's own
stack and returns, so a `Mutex` around a message is never held for long and is
often uncontended. What it buys now is that the vfs layer became *preemptible*
the moment it stopped masking interrupts for every message it sends. What it
buys next is the transport that could not exist before: a reply that arrives on
an interrupt cannot be waited for by a lock that masks interrupts, so an
out-of-process 9P server needed this file first.

The queue, the scheduler hooks and the rule about stack-allocated nodes all
live in `wait.odin`, because a `Rendez` wants the same three things. What is
left here is the one thing a lock does that a rendezvous does not.

## Handoff, not retry

`mutex_unlock` with a waiter queued does not release the lock. It moves
ownership to one waiter and then makes that thread runnable, so a thread
arriving at `mutex_lock` in between finds the lock held and joins the queue. A
thread that has been woken has nothing left to check, and that is the whole
difference from `sync.sleep`, which loops because a rendezvous has nothing to
transfer.

Retrying instead would be shorter and would let an arriving thread barge past
threads that have been waiting -- fine for throughput, and not fine for the
thing this lock exists to bound. A session lock that can be barged has no bound
at all on how long a reply waits.

Put back to arrival order -- `take_first` instead of `take_best` --
`kernel/verify_vfs.odin` fails about one run in ten rather than every run,
which is worth stating plainly. The spread between its busiest and quietest
worker is two to four times when the lock defers to the scheduler and up to
fifty when it does not, but the tail is what fails the check, not the average.

What this does *not* fix is priority inversion: the lock goes to the best
waiter, but a low-priority *holder* still delays a high-priority waiter for as
long as it holds. Full inheritance is a thing to want when there is a realtime
thread that matters, and Plan 9 never had it either.
*/
package sync

import "kernel:arch"

/*
A mutual exclusion lock that parks the loser instead of masking interrupts.

`held` rather than `owner != nil` is the authority on whether the lock is
taken, because before there is a scheduler there is no thread to name and the
owner is legitimately nil. `owner` is what makes a thread deadlocking against
itself a named panic rather than a machine that stops.
*/
Mutex :: struct {
	held:  bool,
	owner: Waiter,
	queue: Wait_Queue,
}

/*
mutex_lock takes the lock, parking the caller if somebody else has it.

Interrupts are masked for the bookkeeping and stay masked across the park. That
is not a critical section in the `Spinlock` sense and deliberately does not
count as one: the mask travels with the thread through the switch -- it is a
bit in the flags the trap frame restores -- so the thread that runs next gets
its own interrupt state, and this thread gets its mask back when it resumes.
The rule this enforces on *callers* is the opposite one, and it is checked
first: no sleeping lock inside a spinlock.
*/
mutex_lock :: proc "contextless" (m: ^Mutex) {
	if !can_sleep() {
		fail("sleeping lock taken inside a spinlock")
	}
	was_on := arch.irq_save()

	me := have_sched ? hooks.current() : nil

	if !m.held {
		m.held = true
		m.owner = me
		arch.irq_restore(was_on)
		return
	}

	if have_sched && me != nil && m.owner == me {
		arch.irq_restore(was_on)
		fail("sleeping lock taken twice by the same thread")
	}
	if !have_sched {
		// One thread cannot contend with itself, so this is either the case
		// above with no scheduler to name it, or a lock released by nobody.
		arch.irq_restore(was_on)
		fail("sleeping lock contended before there is a scheduler to park on")
	}

	node := Wait_Node {
		waiter = me,
	}
	push(&m.queue, &node)
	sleeps += 1

	hooks.block()

	// Woken only by `mutex_unlock`, which handed the lock over before making
	// this thread runnable: `m.held` is already true and `m.owner` is already
	// us. There is nothing to re-check and no loop, which is the point of
	// handoff.
	arch.irq_restore(was_on)
}

/*
mutex_unlock releases the lock, or hands it to whoever the scheduler would
have picked.

The wake comes last, after the queue and the ownership are already consistent,
so the woken thread sees a finished lock however soon it runs.
*/
mutex_unlock :: proc "contextless" (m: ^Mutex) {
	was_on := arch.irq_save()

	if !m.held {
		arch.irq_restore(was_on)
		fail("sleeping lock released while free")
	}

	best := take_best(&m.queue)
	if best == nil {
		m.held = false
		m.owner = nil
		arch.irq_restore(was_on)
		return
	}

	m.owner = best.waiter
	handoffs += 1

	// `unpark`, not `ready`: a thread that queued for a lock waited on nothing
	// outside itself and is not owed its priority back. See `Scheduler`.
	hooks.unpark(best.waiter)
	arch.irq_restore(was_on)
}

// mutex_held reports whether the lock is taken, by anyone. For assertions in
// code that must run inside one.
mutex_held :: proc "contextless" (m: ^Mutex) -> bool {
	return m.held
}
