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

## The scheduler is a dependency this package cannot import

`kernel:sched` imports `kernel:sync` -- the run queues are under a spinlock --
so this package cannot import it back. The scheduler registers itself instead,
and `Waiter` is a `rawptr` because the identity of a thread is the scheduler's
business, not this file's.

The indirection is not only a layering trick. Before `sched.init` runs there is
no thread to park, and `have_sched` says so honestly: a mutex taken during boot
is uncontended by construction, because there is exactly one thing running.

## Handoff, not retry

`mutex_unlock` with a waiter queued does not release the lock. It moves
ownership to one waiter and then makes that thread runnable, so a thread
arriving at `mutex_lock` in between finds the lock held and joins the queue. A
thread that has been woken has nothing left to check.

Retrying instead would be shorter and would let an arriving thread barge past
threads that have been waiting -- fine for throughput, and not fine for the
thing this lock exists to bound. A session lock that can be barged has no bound
at all on how long a reply waits.

## Whoever the scheduler would have picked

The waiter served is the one with the highest priority, and arrival order only
breaks ties. Arrival order alone was the first version and it was wrong in a
way worth keeping written down: a lock that serves in arrival order is a second
scheduler, and a worse one, because it decides who runs next using the one
piece of information the real scheduler is not allowed to use.

`kernel/verify_vfs.odin` made that concrete. Five threads on a handful of 9P
sessions, and the thread using the *least* CPU -- the one the scheduler had
therefore raised to priority 7 while the others decayed to 1 -- was served last
every time, and got between a fiftieth and a fifth of the turns it was entitled
to. The scheduler's decision was correct and the lock was quietly overruling it
several thousand times a second.

Starvation is what arrival order is usually defending against, and priority
order does not reintroduce it here, because the defence is already somewhere
better: a thread that loses every race is a thread burning no CPU, so it does
not decay, while the threads beating it do. It rises past them and wins. That
is the scheduler's own anti-starvation mechanism doing the work, which is
exactly the argument for not having a second one in here.

That mechanism only works if decay measures CPU rather than interruptions, and
it did not until this file existed -- see `Thread.ticks_left`. The two changes
belong together: a lock that hands off on priority is only as fair as the
number it is handing off on.

Put back to arrival order, `kernel/verify_vfs.odin` fails about one run in ten
rather than every run, which is worth stating plainly. The spread between its
busiest and quietest worker is two to four times when the lock defers to the
scheduler and up to fifty when it does not, but the tail is what fails the
check, not the average.

What this does *not* fix is priority inversion: the lock goes to the best
waiter, but a low-priority *holder* still delays a high-priority waiter for as
long as it holds. Full inheritance is a thing to want when there is a realtime
thread that matters, and Plan 9 never had it either.
*/
package sync

import "kernel:arch"

// A thread, as far as this package is concerned: something the scheduler can
// stop and start, identified by a pointer it chose.
Waiter :: rawptr

/*
What a sleeping lock needs from a scheduler, and nothing more.

`block` takes the calling thread off every run queue until `wake` puts it back.
Both are called with interrupts already masked by this package, which is what
makes "record that I am waiting" and "stop running" a single step -- a wake-up
that landed between them would find a running thread marked blocked and leave
it that way.

`wake` must not raise the woken thread's priority. A thread that waited for a
lock did not wait for the world; it queued behind another thread doing exactly
what it was doing, and a scheduler that rewards that has no way left to tell
five contending threads apart. `sched.unpark` is the half of `sched.ready` that
leaves priority alone, and it exists for this.

`priority` is how a lock hands off to whoever the scheduler would have picked.
Higher is better and the scale is the scheduler's; nothing here interprets the
number beyond comparing two of them.
*/
Scheduler :: struct {
	current:  proc "contextless" () -> Waiter,
	block:    proc "contextless" (),
	wake:     proc "contextless" (w: Waiter),
	priority: proc "contextless" (w: Waiter) -> int,
}

@(private = "file")
hooks: Scheduler
@(private = "file")
have_sched: bool

// set_scheduler publishes the scheduler to this package. Called once, from
// `sched.init`, after there is a thread to park.
set_scheduler :: proc "contextless" (s: Scheduler) {
	hooks = s
	have_sched = s.current != nil && s.block != nil && s.wake != nil && s.priority != nil
}

/*
Where a broken locking rule goes.

Every failure this file can detect is an invariant violation with no sensible
recovery -- a lock released by nobody, a lock waited on with interrupts masked.
Returning an error would hand the caller a decision it cannot make; carrying on
would turn a rule into a suggestion. So it stops the machine and says which
rule, which is the whole reason these are checks rather than comments.

Registered rather than called directly because the panic screen lives in
`package kernel`, above everything here.
*/
@(private = "file")
panic_hook: proc "contextless" (reason: string) -> !

set_panic :: proc "contextless" (p: proc "contextless" (reason: string) -> !) {
	panic_hook = p
}

@(private = "file")
fail :: proc "contextless" (reason: string) -> ! {
	if panic_hook != nil {
		panic_hook(reason)
	}
	// Before anything registered a panic screen there is nowhere to report
	// this, and continuing would be worse than stopping quietly.
	arch.halt_forever()
}

/*
One waiter, living on the waiting thread's own stack.

It is valid for exactly as long as it is reachable: a thread on this list is
parked inside `mutex_lock`, standing on the frame that holds its node, and it
is removed from the list before it is made runnable again. So the queue costs
no allocation and cannot fail, which matters for a lock the allocator itself
may one day want.

A singly-linked list scanned at handoff rather than a heap keyed on priority,
because the scan reads priorities *now*: a thread's priority moves while it
waits, and a queue that sorted on arrival would be handing the lock out on the
strength of what the scheduler thought several slices ago. It is a linear scan
of the threads contending for one lock, which is a number that stays small for
the same reason contention does.
*/
@(private = "file")
Wait_Node :: struct {
	waiter: Waiter,
	next:   ^Wait_Node,
}

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
	head:  ^Wait_Node, // Oldest waiter first; served by priority, ties by age
	tail:  ^Wait_Node, // Joined here
}

// Counters, for the self-tests. `sleeps` is how many times a thread actually
// had to park -- the number that says whether a concurrency test contended for
// anything at all, or merely ran.
@(private = "file")
sleeps: u64
@(private = "file")
handoffs: u64

Sleep_Stats :: struct {
	sleeps:   u64, // Threads parked on a contended mutex
	handoffs: u64, // Locks passed straight to a waiter rather than released
}

sleep_stats :: proc "contextless" () -> Sleep_Stats {
	return Sleep_Stats{sleeps = sleeps, handoffs = handoffs}
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
	if m.tail == nil {
		m.head = &node
	} else {
		m.tail.next = &node
	}
	m.tail = &node
	sleeps += 1

	hooks.block()

	// Woken only by `mutex_unlock`, which handed the lock over before making
	// this thread runnable: `m.held` is already true and `m.owner` is already
	// us. There is nothing to re-check and no loop, which is the point of
	// handoff.
	arch.irq_restore(was_on)
}

/*
mutex_unlock releases the lock, or hands it to whoever has waited longest.

The wake comes last, after the list and the ownership are already consistent,
so the woken thread sees a finished lock however soon it runs.
*/
mutex_unlock :: proc "contextless" (m: ^Mutex) {
	was_on := arch.irq_save()

	if !m.held {
		arch.irq_restore(was_on)
		fail("sleeping lock released while free")
	}

	if m.head == nil {
		m.held = false
		m.owner = nil
		arch.irq_restore(was_on)
		return
	}

	/*
	The best waiter, and its predecessor so it can be unlinked.

	Strictly greater, so a tie leaves the older node in place: the list is in
	arrival order, so equal priorities are served oldest first and the lock is
	FIFO within a priority level, which is where FIFO is the right answer.
	*/
	best := m.head
	prev: ^Wait_Node
	top := hooks.priority(best.waiter)
	scan := m.head
	for scan.next != nil {
		p := hooks.priority(scan.next.waiter)
		if p > top {
			top = p
			best = scan.next
			prev = scan
		}
		scan = scan.next
	}

	if prev == nil {
		m.head = best.next
	} else {
		prev.next = best.next
	}
	if m.tail == best {
		m.tail = prev
	}
	best.next = nil
	m.owner = best.waiter
	handoffs += 1

	hooks.wake(best.waiter)
	arch.irq_restore(was_on)
}

// mutex_held reports whether the lock is taken, by anyone. For assertions in
// code that must run inside one.
mutex_held :: proc "contextless" (m: ^Mutex) -> bool {
	return m.held
}
