/*
Waiting for something that is not a lock.

A `Mutex` answers one question, `may I have this?`, and it answers by a handover
of ownership. Almost nothing else a kernel waits for has that shape. A thread
that waits for a reply, for a key, for a disc, or for ten milliseconds waits for
a *condition* to become true. Whoever makes that condition true has nothing to
hand over. `Rendez` is the place those threads wait, and it is Plan 9's `Rendez`
down to the name.

    r: sync.Rendez
    ...
    sync.sleep(&r, proc "contextless" (_: rawptr) -> bool {
        return intrinsics.volatile_load(&ready)
    }, nil)
    ...
    intrinsics.volatile_store(&ready, true)
    sync.wakeup(&r)

## The condition is a procedure, and that is the whole trick

The obvious API is `put me on this queue and stop me`. It has a race the caller
cannot fix from its own side. Between the caller's test of its condition and its
call into the queue, the condition can become true and the wake-up can happen.
The thread then parks to wait for something that already occurred. Nothing in
the queue can see that, and nothing will wake the thread again.

So the queue takes the test rather than the answer, and runs it itself with
interrupts already masked. The check and the park are then one step, and the
window has nowhere left to be. This is why `sleep` takes a procedure, and why
the procedure is `contextless`. It runs in the moment where the machine is not
taking interrupts. So it must not allocate, must not log, must not take a
sleeping lock, and must not be long.

On a second core a mask stops being exclusion. `Rendez` then grows the
`^Spinlock` that Plan 9's carries, held by the caller across both the test and
the wake-up. The shape of the API does not change. That is most of why it has
this shape now.

## Waking is a hint, not a promise

`wakeup` removes a thread from the queue and makes it runnable. It does not
guarantee the condition is still true when that thread actually runs, because a
third thread can consume whatever it was in between. So `sleep` loops. It re-runs
the condition after every wake, and parks again if it is still false. Callers get
`the condition was true when this returned`, which is the only useful promise,
and they get it with no loop of their own.

That is the opposite of `mutex_unlock`, which hands the lock over and wakes a
thread that has nothing left to check. The difference is real and worth knowing.
A mutex can transfer the thing being waited for. A rendezvous cannot.

A `wakeup` that finds nobody waiting does nothing, and nothing remembers it.
That is not a lost wake-up, because the condition is what carries the state. A
thread that arrives afterwards runs the test, finds it true, and never parks.
The state has to live in the condition and not in the queue. The API is shaped
so there is nowhere else to put it.

## Deadlines

`sleep_for` is the same wait, with a tick at which it gives up. `delay` is the
degenerate case of it. It is a rendezvous nobody else can name, so only the
clock can end it.

A thread waiting with a deadline is on two lists, and either may fire first.
Both paths unlink from both lists before waking, so the second one to arrive
finds nothing to do. See `unlink` in `wait.odin`.

The clock is the scheduler's tick, handed to `tick` from the timer interrupt
rather than read from `sched`. The dependency only runs one way, and this
package has no business with a clock of its own. Time is therefore in ticks,
which is exactly as much resolution as there is. A deadline in anything finer
would be a promise the timer cannot keep.
*/
package sync

import "base:intrinsics"

import "kernel:arch"

// A condition, tested by the queue rather than by the caller. Runs with
// interrupts masked: short, no allocation, no sleeping lock.
Condition :: #type proc "contextless" (arg: rawptr) -> bool

// A place to wait. Nothing in it needs initialising, which is what lets one
// live on a stack frame for the length of a single wait -- see `delay`.
Rendez :: struct {
	queue: Wait_Queue,
}

/*
The clock, as this package sees it.

`now_ticks` is whatever the scheduler last reported. `running` says the
scheduler reported anything at all. Both are volatile, because the timer
interrupt writes them and ordinary code reads them, sometimes in a loop that
waits for a change. The compiler may hoist a plain load out of that loop, and
the loop then never ends.
*/
@(private = "file")
now_ticks: u64
@(private = "file")
running: bool

/*
Threads with a deadline, soonest first.

Sorted on insert rather than scanned on every tick, because the tick is the
common case by a wide margin. A thousand times a second it must decide there is
nothing to do, and it decides that from one pointer. The insert is the rare
path, and it is allowed to walk.

A sorted list rather than a timing wheel, for the same reason the run queues are
sixteen scanned levels rather than a bitmask. The number of threads with a
deadline outstanding is small, and the list says what it does. The wheel is what
this becomes if that stops being true.
*/
@(private = "file")
timers: ^Wait_Node

// now is the last tick the scheduler reported. Ticks are the unit of every
// deadline here. What one is worth in wall time is `sched.timer_stats`.
now :: proc "contextless" () -> u64 {
	return intrinsics.volatile_load(&now_ticks)
}

/*
tick advances the clock and starts every thread whose deadline arrived.

The timer interrupt calls it with interrupts already off. It returns how many
threads it made runnable, so the caller can decide whether the running thread
keeps the rest of its slice. Take a thread that asked for a wake at tick N, and
that does not reach the core until tick N+9. It did not wake at tick N in any
sense its author cared about. See `sched.on_tick`.

Every wake here is `ready` rather than `unpark`. A thread that waited for a
deadline waited on something outside itself, and gets its priority back.
*/
tick :: proc "contextless" (now: u64) -> int {
	intrinsics.volatile_store(&now_ticks, now)
	intrinsics.volatile_store(&running, true)

	started := 0
	for timers != nil && timers.deadline <= now {
		n := timers
		timers = n.timer
		n.timer = nil
		n.timed = false

		// It is very likely also on a rendezvous queue. Off both before
		// anything can look at it running.
		unlink(n)

		if have_sched && n.waiter != nil {
			wakeups += 1
			hooks.ready(n.waiter)
		}
		started += 1
	}
	return started
}

@(private = "file")
timer_add :: proc "contextless" (n: ^Wait_Node) {
	n.timed = true
	n.timer = nil

	if timers == nil || n.deadline < timers.deadline {
		n.timer = timers
		timers = n
		return
	}

	// Strictly less, so a node joins after the ones already due at its tick.
	// Deadlines that land together are served in arrival order. That is the
	// only order available, and the one that surprises nobody.
	prev := timers
	for prev.timer != nil && prev.timer.deadline <= n.deadline {
		prev = prev.timer
	}
	n.timer = prev.timer
	prev.timer = n
}

@(private = "file")
timer_remove :: proc "contextless" (n: ^Wait_Node) {
	if !n.timed {
		return
	}
	n.timed = false

	if timers == n {
		timers = n.timer
		n.timer = nil
		return
	}
	prev := timers
	for prev != nil && prev.timer != n {
		prev = prev.timer
	}
	if prev != nil {
		prev.timer = n.timer
	}
	n.timer = nil
}

/*
sleep waits until `cond` is true.

Returns once the condition holds, and only then. `cond` may already be true. In
that case nothing parks and nothing switches, which is what makes a `wakeup`
ahead of a `sleep` harmless.
*/
sleep :: proc "contextless" (r: ^Rendez, cond: Condition, arg: rawptr = nil) {
	_ = wait_on(r, cond, arg, 0, timed = false)
}

/*
sleep_noted waits until `cond` is true, or until a note interrupts it.

Reports whether the condition was met. False means a note is waiting for
this thread. The caller's job is then to unwind toward the boundary that
delivers it -- EINTR outward, however many layers that is. The wake arrives
because `sched.note_thread` made the thread runnable. The wait's own unlink
takes it off every list, and this loop's check is what turns the wake into a
return.

A kernel thread is never noted, so for one this is `sleep` exactly. That is
what lets a path both kinds of thread cross -- a pipe's flows -- wait this
way unconditionally.
*/
sleep_noted :: proc "contextless" (r: ^Rendez, cond: Condition, arg: rawptr = nil) -> bool {
	return wait_on(r, cond, arg, 0, timed = false, interruptible = true)
}

/*
sleep_for waits until `cond` is true, or until `ticks` pass.

Reports whether the condition was met. False is a deadline, not an error, and
the caller must have an opinion about which one it is. A self-test that stops
waiting for a worker found a bug. A driver that stops waiting for a device found
a broken device.

`ticks` of zero is a poll. The condition is tested, and the caller never parks.
*/
sleep_for :: proc "contextless" (
	r: ^Rendez,
	cond: Condition,
	arg: rawptr,
	ticks: u64,
) -> bool {
	return wait_on(r, cond, arg, ticks, timed = true)
}

/*
delay gives up the core for `ticks` and comes back.

The rendezvous is on this frame and its address never leaves, so nothing can
wake this thread early. The clock is the only thing that knows about it. That is
the whole implementation, and it is the reason a sleeping delay did not need any
machinery of its own.

Not a spin. A thread in here is off every run queue, so the core runs whatever
else is ready and halts if there is nothing.
*/
delay :: proc "contextless" (ticks: u64) {
	r: Rendez
	_ = wait_on(&r, nil, nil, ticks, timed = true)
}

/*
wakeup starts the best waiter, if there is one.

Reports whether it found anybody. Safe from an interrupt handler -- it masks,
unlinks and calls `ready`, and takes no lock this package owns.
*/
wakeup :: proc "contextless" (r: ^Rendez) -> bool {
	was_on := arch.irq_save()
	defer arch.irq_restore(was_on)

	n := take_best(&r.queue)
	if n == nil {
		return false
	}
	start(n)
	return true
}

/*
wakeup_all starts every waiter and reports how many.

For a condition that genuinely became true for everybody, such as a device that
arrived, or a run that finished. A wake of all of them for a resource only one
can have is the thundering herd. The loop in `sleep` makes that correct, and
does not make it a good idea.
*/
wakeup_all :: proc "contextless" (r: ^Rendez) -> int {
	was_on := arch.irq_save()
	defer arch.irq_restore(was_on)

	started := 0
	for {
		n := take_first(&r.queue)
		if n == nil {
			return started
		}
		start(n)
		started += 1
	}
}

// start unlinks a node from the timer list too, and makes its thread runnable.
// The unlink comes first in every path that wakes anybody. See `wait.odin`.
@(private = "file")
start :: proc "contextless" (n: ^Wait_Node) {
	timer_remove(n)
	if have_sched && n.waiter != nil {
		wakeups += 1
		hooks.ready(n.waiter)
	}
}

/*
The wait itself.

Interrupts stay masked for the whole of it, including across the park. That is
not a critical section in the `Spinlock` sense, and deliberately does not count
as one. The mask travels with the thread through the switch, because it is a bit
in the flags that the trap frame restores. The thread that runs next therefore
gets its own interrupt state, and this thread gets its mask back when it
resumes. The rule this enforces on *callers* is the opposite one, and the first
line checks it.
*/
@(private = "file")
wait_on :: proc "contextless" (
	r: ^Rendez,
	cond: Condition,
	arg: rawptr,
	ticks: u64,
	timed: bool,
	interruptible: bool = false,
) -> bool {
	if !can_sleep() {
		fail("slept on a rendezvous inside a spinlock")
	}
	if cond == nil && !timed {
		fail("slept on a rendezvous with no condition and no deadline")
	}

	was_on := arch.irq_save()
	defer arch.irq_restore(was_on)

	deadline: u64
	if timed {
		if !intrinsics.volatile_load(&running) {
			// Nothing will ever advance the clock, so this would not be a
			// wait, it would be a stop.
			arch.irq_restore(was_on)
			fail("timed wait before the clock is running")
		}
		deadline = intrinsics.volatile_load(&now_ticks) + ticks
	}

	for {
		if cond != nil && cond(arg) {
			return true
		}
		if timed && intrinsics.volatile_load(&now_ticks) >= deadline {
			timeouts += 1
			return false
		}
		if interruptible && have_sched && hooks.interrupted != nil &&
		   hooks.interrupted(hooks.current()) {
			// A note outranks the wait. The condition had its chance above,
			// so a wake that raced the note still answers true.
			return false
		}
		if !have_sched {
			// One thread cannot wait for itself to make something true.
			arch.irq_restore(was_on)
			fail("slept on a rendezvous before there is a scheduler to park on")
		}

		node := Wait_Node {
			waiter   = hooks.current(),
			deadline = deadline,
		}
		push(&r.queue, &node)
		if timed {
			timer_add(&node)
		}
		sleeps += 1

		hooks.block()

		/*
		Off both lists, again.

		Whoever woke us already did this. `wakeup` and `tick` both unlink
		before they wake, without exception, so in a working kernel these
		are two loads of nil.

		The pair is deliberately redundant, and the redundancy turned out
		to be exactly measurable. A mutation of either side on its own
		passes every check in `kernel/verify_rendez.odin`. A mutation of
		both faults inside the timer interrupt, on a stack frame the thread
		already left.

		They stay because they are not the same guarantee. The waker's
		unlink stops a node reaching two callers in the window where its
		thread is runnable and has not yet run. This one stops a departing
		frame from leaving a pointer to itself in a list. That holds
		whoever woke it, and for whatever reason.
		*/
		unlink(&node)
		timer_remove(&node)
	}
}

/*
await polls `cond` until it comes true, up to a bound in ticks.

Six callers wrote this loop before it lived here, and the argument for each of
them is in `docs/TESTING.md`. **A self-test may never do the blocking thing on
the thread that reports.** It spawns the worker, watches it with a bound, and
treats the bound running out as the failure it is. What that buys is a failure
that names itself, in the place hardest to attach a debugger to.

A poll rather than a `sleep_for`, and the difference is the point. `sleep_for`
parks on a rendezvous that the thing being watched has to know about and has to
wake. `await` watches something that promised nothing, which is what an observer
is for.

Returns false when the bound runs out. That is a failure the caller has to have
an opinion about, exactly as `sleep_for`'s is.

**One caller does not use this, and the reason is worth knowing.**
`kernel/drivers/kbd/verify.odin` counts yields instead, because the failure it
watches for is the failure that stops the clock this counts in. See
`docs/KBD.md`, and `docs/TESTING.md` on bounds a failure can destroy.
*/
await :: proc "contextless" (cond: Condition, arg: rawptr, patience: int) -> bool {
	for _ in 0 ..< patience {
		if cond(arg) {
			return true
		}
		delay(1)
	}
	return cond(arg)
}
