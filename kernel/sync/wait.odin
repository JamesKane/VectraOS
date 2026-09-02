/*
A queue of parked threads, and what this package needs from a scheduler.

Everything in `kernel:sync` that can put a thread to sleep stands on this file.
A `Mutex` parks the losers of a race for one lock. A `Rendez` parks threads that
wait for a condition, with or without a deadline. Both want the same three
things: a list of waiters, a way to stop a thread, and a way to start it again.
Neither wants them enough to own them.

## The scheduler is a dependency this package cannot import

`kernel:sched` imports `kernel:sync`, because the run queues are under a
spinlock. So this package cannot import it back. The scheduler registers itself
instead, and `Waiter` is a `rawptr` because the identity of a thread is the
scheduler's business, not this file's.

The indirection is not only a layering trick. Before `sched.init` runs there is
no thread to park, and `have_sched` says so honestly. Nothing contends for a
lock taken during boot, because there is exactly one thing running.

## Nodes live on the waiting thread's own stack

A node is valid for exactly as long as it is reachable. A thread on one of these
lists is parked inside the procedure that holds its node. Something unlinks that
node before the thread becomes runnable again. A wait therefore costs no
allocation and cannot fail, which matters for machinery the allocator itself may
one day want.

That is why every path that wakes a thread unlinks first and wakes second, in
that order, without exception. The woken thread unlinks itself as well, as it
leaves. That is redundant on purpose, and `wait_on` in `rendez.odin` says what
each half is actually for.

A thread that waits with a deadline is on *two* lists at once. Those are the
queue it waits on, and the timer list in `rendez.odin`. Whichever fires first
takes it off both. `unlink` is safe on a node that is on neither.

## Whoever the scheduler would have picked

`take_best` serves the highest-priority waiter, and uses arrival order only to
break ties. Arrival order alone was the first version, and it was wrong in a way
worth keeping written down. A queue that serves in arrival order is a second
scheduler, and a worse one. It decides who runs next from the one piece of
information the real scheduler is not allowed to use.

`kernel/verify_vfs.odin` made that concrete. Five threads shared a handful of 9P
sessions. The thread that used the *least* CPU was served last every time. The
scheduler raised it to priority 7 while the others decayed to 1. It still got
between a fiftieth and a fifth of the turns it was entitled to. The
scheduler's decision was correct, and the lock quietly overruled it several
thousand times a second.

Arrival order usually defends against starvation. Priority order does not
reintroduce starvation here, because the defence is already somewhere better. A
thread that loses every race burns no CPU, so it does not decay, while the
threads that beat it do. It rises past them and wins. That is the scheduler's
own anti-starvation mechanism at work, which is exactly the argument against a
second one in here.

That mechanism only works if decay measures CPU rather than interruptions, and
it did not until sleeping locks existed. See `Thread.ticks_left`. The two belong
together. A queue that hands off on priority is only as fair as the number it
hands off on.

A linear scan rather than a heap keyed on priority, because the scan reads
priorities *now*. A thread's priority moves while it waits. A queue sorted on
arrival would hand out turns on the strength of what the scheduler thought
several slices ago. It is a scan of the threads that contend for one object, and
that number stays small for the same reason contention does.

## Interrupts, and what stands in for a lock

Every procedure here requires interrupts to be masked, and none of them mask on
their own behalf. The callers do, because the caller's decision and the queue
operation have to be one step. The mask is the exclusion, on one core. It is
also the thing that has to change first on a second core. These lists then need
a real lock word, and `Rendez` grows the `^Spinlock` that Plan 9's `Rendez`
always carried.
*/
package sync

import "kernel:arch"

// A thread, as far as this package is concerned: something the scheduler can
// stop and start, identified by a pointer it chose.
Waiter :: rawptr

/*
What a sleeping wait needs from a scheduler, and nothing more.

`block` takes the calling thread off every run queue until something starts it
again. This package masks interrupts before it calls that. The mask is what
makes `record that I am waiting` and `stop running` a single step. A wake-up
that landed between them would find a running thread marked blocked, and leave
it that way.

`unpark` and `ready` are the same act with different consequences for priority.
They are two hooks rather than one flag, because the difference is about *what
the thread waited for* rather than about the wake:

    unpark   a lock it queued for came free
    ready    the thing it was waiting for happened

A thread woken from a lock did not wait for the world. It queued behind another
thread doing exactly what it was doing. A scheduler that rewards that has no way
left to tell five contending threads apart.

A thread woken from a rendezvous or a deadline did wait on something outside
itself. It gets its priority back as the price of good manners. That is the
whole of Plan 9's boost, and the reason an interactive thread beats a
compute-bound one.

The names are the scheduler's own, so that following one of these hooks is a
grep rather than a puzzle.

`priority` is how a queue hands off to whoever the scheduler would have picked.
Higher is better, and the scale is the scheduler's. Nothing here interprets the
number beyond a comparison of two of them.
*/
Scheduler :: struct {
	current:     proc "contextless" () -> Waiter,
	block:       proc "contextless" (),
	unpark:      proc "contextless" (w: Waiter),
	ready:       proc "contextless" (w: Waiter),
	priority:    proc "contextless" (w: Waiter) -> int,

	// Whether a note is waiting for this thread. Optional, read only by an
	// interruptible sleep, and what makes `sleep_noted` mean something. A
	// scheduler without it makes every interruptible sleep an ordinary one.
	interrupted: proc "contextless" (w: Waiter) -> bool,
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
the caller a decision it cannot make. To carry on would turn a rule into a
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

`queue` is the authority on whether this node is linked, and the presence of a
`next` is not. A node at the end of a list has neither. An unlinked node has
both cleared. `deadline` and `timer` belong to `rendez.odin`, and are inert for
a wait that has no deadline.
*/
@(private)
Wait_Node :: struct {
	waiter:   Waiter,
	queue:    ^Wait_Queue, // The queue it is on, nil once it is off
	next:     ^Wait_Node, // Link within that queue
	writing:  bool, // On a read/write lock's queue, which kind. See `rwlock.odin`.

	deadline: u64, // Absolute tick it is due at
	timed:    bool, // On the timer list; see `rendez.odin`
	timer:    ^Wait_Node, // Link within the timer list
}

// A list of parked threads, oldest first. Served by priority. See the file
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

Strictly greater, so a tie leaves the older node in place. The list is in
arrival order, so equal priorities are served oldest first. The queue is
therefore FIFO within a priority level, which is where FIFO is the right
answer.
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

// unlink removes a node from whatever queue it is on, if it is on one. It is
// safe on an already-unlinked node, which is what makes a wake and a deadline
// that arrive together harmless rather than a corrupted list.
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
// had to park. That is the number that says whether a concurrency test
// contended for anything at all, or merely ran.
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
