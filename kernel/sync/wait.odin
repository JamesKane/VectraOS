/*
A queue of parked threads, and what this package needs from a scheduler.

Everything in `kernel:sync` that can put a thread to sleep stands on this file.
A `Mutex` parks the losers of a race for one lock; a `Rendez` parks threads
waiting for a condition, with or without a deadline. Both want the same three
things -- a list of waiters, a way to stop a thread, and a way to start it
again -- and neither wants them enough to own them.

## The scheduler is a dependency this package cannot import

`kernel:sched` imports `kernel:sync`, because the run queues are under a
spinlock. So this package cannot import it back. The scheduler registers itself
instead, and `Waiter` is a `rawptr` because the identity of a thread is the
scheduler's business, not this file's.

The indirection is not only a layering trick. Before `sched.init` runs there is
no thread to park, and `have_sched` says so honestly: a lock taken during boot
is uncontended by construction, because there is exactly one thing running.

## Nodes live on the waiting thread's own stack

A node is valid for exactly as long as it is reachable: a thread on one of
these lists is parked inside the procedure that holds its node, and the node is
unlinked before the thread is made runnable again. So a wait costs no
allocation and cannot fail, which matters for machinery the allocator itself
may one day want -- and it is why every path that wakes a thread unlinks first
and wakes second, in that order, without exception. The woken thread unlinks
itself as well, on the way out, which is redundant on purpose; `wait_on` in
`rendez.odin` says what each half is actually for.

A thread waiting with a deadline is on *two* lists at once: the queue it is
waiting on and the timer list in `rendez.odin`. Whichever fires first takes it
off both. `unlink` is written to be safe on a node that is on neither.

## Whoever the scheduler would have picked

`take_best` serves the highest-priority waiter and uses arrival order only to
break ties. Arrival order alone was the first version and it was wrong in a way
worth keeping written down: a queue that serves in arrival order is a second
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
it did not until sleeping locks existed -- see `Thread.ticks_left`. The two
belong together: a queue that hands off on priority is only as fair as the
number it is handing off on.

A linear scan rather than a heap keyed on priority, because the scan reads
priorities *now*: a thread's priority moves while it waits, and a queue sorted
on arrival would be handing out turns on the strength of what the scheduler
thought several slices ago. It is a scan of the threads contending for one
object, which is a number that stays small for the same reason contention does.

## Interrupts, and what stands in for a lock

Every procedure here requires interrupts to be masked and none of them mask on
their own behalf -- the callers do, because the caller's decision and the queue
operation have to be one step. Masking is the exclusion, on one core. It is
also the thing that has to change first on a second one: these lists then need
a real lock word, and `Rendez` grows the `^Spinlock` that Plan 9's `Rendez`
always had.
*/
package sync

import "kernel:arch"

// A thread, as far as this package is concerned: something the scheduler can
// stop and start, identified by a pointer it chose.
Waiter :: rawptr

/*
What a sleeping wait needs from a scheduler, and nothing more.

`block` takes the calling thread off every run queue until something starts it
again. It is called with interrupts already masked by this package, which is
what makes "record that I am waiting" and "stop running" a single step -- a
wake-up that landed between them would find a running thread marked blocked and
leave it that way.

`unpark` and `ready` are the same act with different consequences for priority,
and they are two hooks rather than one flag because the difference is about
*what was waited for* rather than about the wake:

    unpark   a lock it queued for came free
    ready    the thing it was waiting for happened

A thread woken from a lock did not wait for the world. It queued behind another
thread doing exactly what it was doing, and a scheduler that rewards that has
no way left to tell five contending threads apart. A thread woken from a
rendezvous or a deadline did wait on something outside itself, and gets its
priority back as the price of having been polite -- which is the whole of Plan
9's boost, and the reason an interactive thread beats a compute-bound one.

The names are the scheduler's own, so that following one of these hooks is a
grep rather than a puzzle.

`priority` is how a queue hands off to whoever the scheduler would have picked.
Higher is better and the scale is the scheduler's; nothing here interprets the
number beyond comparing two of them.
*/
Scheduler :: struct {
	current:  proc "contextless" () -> Waiter,
	block:    proc "contextless" (),
	unpark:   proc "contextless" (w: Waiter),
	ready:    proc "contextless" (w: Waiter),
	priority: proc "contextless" (w: Waiter) -> int,
}

@(private)
hooks: Scheduler
@(private)
have_sched: bool

// set_scheduler publishes the scheduler to this package. Called once, from
// `sched.init`, after there is a thread to park.
set_scheduler :: proc "contextless" (s: Scheduler) {
	hooks = s
	have_sched =
		s.current != nil && s.block != nil && s.unpark != nil && s.ready != nil && s.priority != nil
}

/*
Where a broken waiting rule goes.

Every failure this package can detect is an invariant violation with no
sensible recovery -- a lock released by nobody, a wait entered with interrupts
masked, a rendezvous that nothing could ever end. Returning an error would hand
the caller a decision it cannot make; carrying on would turn a rule into a
suggestion. So it stops the machine and says which rule, which is the whole
reason these are checks rather than comments.

Registered rather than called directly because the panic screen lives in
`package kernel`, above everything here.
*/
@(private = "file")
panic_hook: proc "contextless" (reason: string) -> !

set_panic :: proc "contextless" (p: proc "contextless" (reason: string) -> !) {
	panic_hook = p
}

@(private)
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

`queue` is the authority on whether this node is linked, not the presence of a
`next` -- a node at the end of a list has neither, and a node that has been
taken off has both cleared. `deadline` and `timer` belong to `rendez.odin` and
are inert for a wait that has no deadline.
*/
@(private)
Wait_Node :: struct {
	waiter:   Waiter,
	queue:    ^Wait_Queue, // The queue it is on, nil once it is off
	next:     ^Wait_Node, // Link within that queue

	deadline: u64, // Absolute tick it is due at
	timed:    bool, // On the timer list; see `rendez.odin`
	timer:    ^Wait_Node, // Link within the timer list
}

// A list of parked threads, oldest first. Served by priority; see the file
// comment for why the order in the list is not the order it is served in.
Wait_Queue :: struct {
	head: ^Wait_Node,
	tail: ^Wait_Node,
}

// waiting reports whether anything is parked on this queue.
waiting :: proc "contextless" (q: ^Wait_Queue) -> bool {
	return q.head != nil
}

// push adds a node at the back. Interrupts must already be masked.
@(private)
push :: proc "contextless" (q: ^Wait_Queue, n: ^Wait_Node) {
	n.next = nil
	n.queue = q
	if q.tail == nil {
		q.head = n
	} else {
		q.tail.next = n
	}
	q.tail = n
}

/*
take_best removes and returns the waiter the scheduler would have picked.

Strictly greater, so a tie leaves the older node in place: the list is in
arrival order, so equal priorities are served oldest first and the queue is
FIFO within a priority level, which is where FIFO is the right answer.
*/
@(private)
take_best :: proc "contextless" (q: ^Wait_Queue) -> ^Wait_Node {
	if q.head == nil {
		return nil
	}

	best := q.head
	prev: ^Wait_Node
	top := priority_of(best)

	scan := q.head
	for scan.next != nil {
		p := priority_of(scan.next)
		if p > top {
			top = p
			best = scan.next
			prev = scan
		}
		scan = scan.next
	}

	if prev == nil {
		q.head = best.next
	} else {
		prev.next = best.next
	}
	if q.tail == best {
		q.tail = prev
	}
	best.next = nil
	best.queue = nil
	return best
}

// take_first removes and returns the oldest waiter, ignoring priority. For
// `wakeup_all`, where every waiter is going anyway and a scan per node would
// turn one wake into a quadratic one.
@(private)
take_first :: proc "contextless" (q: ^Wait_Queue) -> ^Wait_Node {
	n := q.head
	if n == nil {
		return nil
	}
	q.head = n.next
	if q.head == nil {
		q.tail = nil
	}
	n.next = nil
	n.queue = nil
	return n
}

// unlink takes a node off whatever queue it is on, if it is on one. Safe to
// call on a node that has already been taken off, which is what makes a wake
// and a deadline arriving together harmless rather than a corrupted list.
@(private)
unlink :: proc "contextless" (n: ^Wait_Node) {
	q := n.queue
	if q == nil {
		return
	}

	if q.head == n {
		q.head = n.next
		if q.head == nil {
			q.tail = nil
		}
	} else {
		prev := q.head
		for prev != nil && prev.next != n {
			prev = prev.next
		}
		if prev == nil {
			// Not on the queue it claims to be on. There is no repair for
			// that and no way it happens without a bug above here.
			fail("wait node on a queue it is not on")
		}
		prev.next = n.next
		if q.tail == n {
			q.tail = prev
		}
	}

	n.next = nil
	n.queue = nil
}

@(private)
priority_of :: proc "contextless" (n: ^Wait_Node) -> int {
	if !have_sched || n.waiter == nil {
		return 0
	}
	return hooks.priority(n.waiter)
}

// Counters, for the self-tests. `sleeps` is how many times a thread actually
// had to park -- the number that says whether a concurrency test contended for
// anything at all, or merely ran.
@(private)
sleeps: u64
@(private)
handoffs: u64
@(private)
wakeups: u64
@(private)
timeouts: u64

Sleep_Stats :: struct {
	sleeps:   u64, // Threads parked, on a mutex or a rendezvous
	handoffs: u64, // Locks passed straight to a waiter rather than released
	wakeups:  u64, // Threads started again by `wakeup`, `wakeup_all` or a deadline
	timeouts: u64, // Timed waits that gave up
}

sleep_stats :: proc "contextless" () -> Sleep_Stats {
	return Sleep_Stats {
		sleeps = sleeps,
		handoffs = handoffs,
		wakeups = wakeups,
		timeouts = timeouts,
	}
}
