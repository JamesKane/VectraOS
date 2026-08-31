/*
The sleep queue, checked directly.

A rendezvous is harder to test than a lock, because the interesting properties
are all about a thread that is *not running*. Two threads that observe each
other inside a lock catch a lock bug. Only a measurement of what the rest of
the machine did, while the sleeper was gone, catches a sleep bug.

    the clock      a thread asking for N ticks comes back after N ticks, and
                   not after a slice's worth more
    the park       it really left the core, rather than spinning quietly --
                   which is a context switch the machine would not otherwise
                   make
    the condition  a wake-up that arrives before the wait is not lost, because
                   the state is in the condition and not in the queue
    the order      the queue serves the waiter the scheduler would have picked

The park is the one worth explaining. `delay` and a spin loop are
indistinguishable from inside the thread that ran them -- both return after the
right number of ticks. They differ in what the core did in between. With only
the boot thread and the idle thread alive, that difference is exact rather than
statistical.

`reschedule` re-picks a spinning boot thread, and does not count a switch when
the thread it picked is the thread it had. A parked one switches to idle and
back. Two, versus zero.

Ordered after `verify_sleep_lock`, because a rendezvous stands on the same
queue. A broken queue should report itself in the vocabulary of the simplest
thing that uses it.
*/
package kernel

import "base:intrinsics"

import "kernel:sched"
import "kernel:sync"
import "vsys:libodin"

// Long enough to span several slices, so a delay that quietly became a spin
// cannot pass by accident.
@(private = "file")
NAP_TICKS :: 25

/*
How late a deadline may be honoured.

Two ticks, which is tight on purpose. A wake is `ready`, so the sleeper
outranks whatever woke it, and runs at the very next switch. `on_tick` forces a
switch the moment `sync.tick` reports it started anybody. Take that reschedule
out and the sleeper waits for the running thread's slice to end instead, which
is up to ten ticks. That is the failure this number exists to catch, and five
ticks of slack would have hidden it.

One tick of skew is inside the noise, and nothing checks it. The clock can
advance between the moment a caller reads it and the moment `sleep_for`
computes a deadline from it.

No thread something can preempt between those two lines measures its own
latency more finely than that.
*/
@(private = "file")
NAP_SLACK :: 2

@(private = "file")
TIMEOUT_TICKS :: 20

// How long the boot thread will wait for a worker before deciding it is stuck.
// Generous: every one of these finishes in a tick or two when it works at all.
@(private = "file")
PATIENCE :: 200

@(private = "file")
SLEEPERS :: 3

@(private = "file")
gate: sync.Rendez // Where the sleepers wait
@(private = "file")
done: sync.Rendez // Where the boot thread waits for them

@(private = "file")
released: bool // The condition the sleepers are waiting on
@(private = "file")
parked: int // Bumped by a sleeper's condition when it is about to park
@(private = "file")
finished_sleepers: int
@(private = "file")
wake_order: [SLEEPERS]int // Which turn each sleeper was woken on
@(private = "file")
next_turn: int

@(private = "file")
timed_out: bool // What the timeout worker's `sleep_for` returned
@(private = "file")
timed_elapsed: u64
@(private = "file")
timed_finished: bool

/*
The condition the sleepers wait on.

It counts its own false answers. That is the only way to know from outside that
a thread committed to a park. `sleep` runs this with interrupts masked, and
parks the caller immediately afterwards with no unmask. A thread that bumped
`parked` is therefore a thread on its way to sleep. There is no window between
the two for the observer to catch.
*/
@(private = "file")
is_released :: proc "contextless" (arg: rawptr) -> bool {
	if intrinsics.volatile_load(&released) {
		return true
	}
	intrinsics.volatile_store(&parked, intrinsics.volatile_load(&parked) + 1)
	return false
}

@(private = "file")
never :: proc "contextless" (arg: rawptr) -> bool {
	return false
}

@(private = "file")
always :: proc "contextless" (arg: rawptr) -> bool {
	return true
}

@(private = "file")
all_slept :: proc "contextless" (arg: rawptr) -> bool {
	return intrinsics.volatile_load(&finished_sleepers) >= SLEEPERS
}

@(private = "file")
timed_worker_done :: proc "contextless" (arg: rawptr) -> bool {
	return intrinsics.volatile_load(&timed_finished)
}

@(private = "file")
sleeper :: proc "contextless" (arg: rawptr) #no_bounds_check {
	slot := int(uintptr(arg))

	sync.sleep(&gate, is_released)

	// Woken, and the condition really is true -- `sleep` does not return until it
	// is. The turn is taken here rather than in the waker, so it records the
	// order the queue *released* threads in. That is the order the queue chose.
	turn := intrinsics.volatile_load(&next_turn)
	intrinsics.volatile_store(&next_turn, turn + 1)
	intrinsics.volatile_store(&wake_order[slot], turn)

	intrinsics.volatile_store(
		&finished_sleepers,
		intrinsics.volatile_load(&finished_sleepers) + 1,
	)
	sync.wakeup(&done)
}

// A thread that waits for something that never happens, so the only thing that
// can end it is the deadline.
@(private = "file")
timeout_worker :: proc "contextless" (arg: rawptr) {
	started := sched.ticks()
	got := sync.sleep_for(&gate, never, nil, TIMEOUT_TICKS)
	intrinsics.volatile_store(&timed_elapsed, sched.ticks() - started)
	intrinsics.volatile_store(&timed_out, !got)
	intrinsics.volatile_store(&timed_finished, true)
	sync.wakeup(&done)
}

@(private = "file")
Rendez_Result :: struct {
	using tally:   libodin.Tally,
	nap:           u64, // Ticks a NAP_TICKS delay actually took
	switches:      u64, // Switches the machine made while it napped
	slept:         u64,
	woke:          u64,
}

@(private = "file")
rcheck :: proc "contextless" (r: ^Rendez_Result, ok: bool, what: string) -> bool {
	return libodin.tally(&r.tally, ok, what)
}

// wait_parked spins the boot thread down onto the clock until `want` threads
// commit to a sleep. A poll, but a polite one. Between looks, this thread is
// off the run queue entirely, so the threads it waits for have the core to
// themselves.
@(private = "file")
wait_parked :: proc "contextless" (want: int) -> bool {
	for _ in 0 ..< PATIENCE {
		if intrinsics.volatile_load(&parked) >= want {
			return true
		}
		sync.delay(1)
	}
	return false
}

verify_sleep_queue :: proc() #no_bounds_check {
	r: Rendez_Result

	before := sync.sleep_stats()

	// -- The clock ----------------------------------------------------------

	rcheck(&r, sync.now() > 0, "the clock is running")

	{
		// Nothing else is alive at this point, so the switch count below is
		// exact rather than a lower bound with traffic in it.
		s0 := sched.stats()
		t0 := sched.ticks()
		sync.delay(NAP_TICKS)
		r.nap = sched.ticks() - t0
		r.switches = sched.stats().switches - s0.switches

		rcheck(&r, r.nap >= NAP_TICKS, "a thread that asked for a delay got all of it")
		rcheck(&r, r.nap <= NAP_TICKS + NAP_SLACK, "and was given the core back promptly")
		rcheck(&r, r.switches >= 2, "and left the core while it waited, rather than spinning")
	}

	// -- Conditions ---------------------------------------------------------

	{
		// A condition that is already true is the case that makes a wake-up
		// racing ahead of a wait harmless. Nothing may park.
		s0 := sync.sleep_stats()
		sync.sleep(&gate, always)
		rcheck(
			&r,
			sync.sleep_stats().sleeps == s0.sleeps,
			"a wait whose condition already holds does not park",
		)
	}

	rcheck(&r, !sync.wakeup(&gate), "waking an empty rendezvous finds nobody")

	{
		// The lost wake-up, from the direction it actually happens in: the
		// waker gets there first and there is nothing to wake. The state is
		// in the condition, so the waiter that arrives afterwards never
		// sleeps at all.
		intrinsics.volatile_store(&released, true)
		woke := sync.wakeup(&gate)
		s0 := sync.sleep_stats()
		sync.sleep(&gate, is_released)
		rcheck(
			&r,
			!woke && sync.sleep_stats().sleeps == s0.sleeps,
			"a wake-up that arrives before the wait is not lost",
		)
	}

	{
		// A deadline of nothing is a poll: the condition is tested once and
		// the caller keeps the core.
		s0 := sync.sleep_stats()
		got := sync.sleep_for(&gate, never, nil, 0)
		rcheck(
			&r,
			!got && sync.sleep_stats().sleeps == s0.sleeps,
			"a wait with no time left polls rather than parks",
		)
	}

	// -- Three sleepers, and the order they are let go in --------------------

	intrinsics.volatile_store(&released, false)
	intrinsics.volatile_store(&parked, 0)
	intrinsics.volatile_store(&finished_sleepers, 0)
	intrinsics.volatile_store(&next_turn, 0)
	for i in 0 ..< SLEEPERS {
		intrinsics.volatile_store(&wake_order[i], -1)
	}

	/*
	Started one at a time, lowest priority first, so that arrival order and
	priority order disagree.

	All three at once does not achieve that, and quietly makes the ordering check
	worthless. That is exactly what happened.

	The scheduler dispatches the highest-priority thread first, so it is also the
	first to reach the queue. A queue that serves in arrival order then gets the
	same answer as one that serves by priority. The first version of this check
	passed with the priority scan disabled.

	So each sleeper is parked before the next is created. The queue then holds
	them low-to-high in arrival order, and the two orderings can only agree by
	accident once.
	*/
	spawned := 0
	bases := [SLEEPERS]sched.Priority {
		sched.PRIORITY_NORMAL - 2,
		sched.PRIORITY_NORMAL,
		sched.PRIORITY_NORMAL + 2,
	}
	for i in 0 ..< SLEEPERS {
		if sched.spawn("rendez", sleeper, rawptr(uintptr(i)), bases[i]) == nil {
			break
		}
		spawned += 1
		if !wait_parked(spawned) {
			break
		}
	}
	if !rcheck(&r, spawned == SLEEPERS, "every sleeper spawned and parked in turn") {
		report_sleep_queue(&r)
		return
	}
	rcheck(&r, sync.sleep_stats().sleeps - before.sleeps >= u64(SLEEPERS), "and really slept")

	// Released before the first wake, so a woken thread finds its condition
	// true and goes rather than parking again.
	intrinsics.volatile_store(&released, true)

	// One at a time, with this thread off the core in between, so each wake
	// is finished before the next one is asked for.
	first := sync.wakeup(&gate)
	sync.delay(2)
	second := sync.wakeup(&gate)
	sync.delay(2)
	rest := sync.wakeup_all(&gate)

	rcheck(&r, first && second, "waking a rendezvous with waiters finds them")
	rcheck(&r, rest == SLEEPERS - 2, "and waking the rest takes the rest")

	rcheck(
		&r,
		sync.sleep_for(&done, all_slept, nil, PATIENCE),
		"every sleeper came back",
	)

	high := intrinsics.volatile_load(&wake_order[2])
	mid := intrinsics.volatile_load(&wake_order[1])
	low := intrinsics.volatile_load(&wake_order[0])
	rcheck(
		&r,
		high == 0 && mid == 1 && low == 2,
		"and the queue let them go in the order the scheduler would have",
	)

	// -- A deadline nothing satisfies ---------------------------------------

	intrinsics.volatile_store(&timed_finished, false)
	intrinsics.volatile_store(&timed_out, false)
	timeouts_before := sync.sleep_stats().timeouts

	if rcheck(
		&r,
		sched.spawn("rendez-timeout", timeout_worker) != nil,
		"the timeout worker spawned",
	) {
		rcheck(
			&r,
			sync.sleep_for(&done, timed_worker_done, nil, PATIENCE),
			"a wait for something that never happens still ends",
		)
		rcheck(&r, intrinsics.volatile_load(&timed_out), "and says it gave up rather than won")
		rcheck(
			&r,
			intrinsics.volatile_load(&timed_elapsed) >= TIMEOUT_TICKS,
			"and waited the whole of its deadline first",
		)
		rcheck(
			&r,
			sync.sleep_stats().timeouts > timeouts_before,
			"and was counted as a deadline rather than a wake",
		)
	}

	sched.reap()

	after := sync.sleep_stats()
	r.slept = after.sleeps - before.sleeps
	r.woke = after.wakeups - before.wakeups

	rcheck(&r, !sync.waiting(&gate.queue), "the rendezvous came back empty")

	report_sleep_queue(&r)
}

@(private = "file")
report_sleep_queue :: proc(r: ^Rendez_Result) {
	sink := begin(&klog)
	libodin.put_str(&sink, "sync ")
	libodin.put_uint(&sink, u64(r.checks))
	if libodin.passed(r.tally) {
		libodin.put_str(&sink, " sleep queue checks passed -- ")
		libodin.put_uint(&sink, r.slept)
		libodin.put_str(&sink, " parked, ")
		libodin.put_uint(&sink, r.woke)
		libodin.put_str(&sink, " woken, ")
		libodin.put_uint(&sink, u64(NAP_TICKS))
		libodin.put_str(&sink, "-tick delay took ")
		libodin.put_uint(&sink, r.nap)
		libodin.put_str(&sink, " in ")
		libodin.put_uint(&sink, r.switches)
		libodin.put_str(&sink, " switches")
		emit(&klog, .Ok, &sink)
		return
	}

	libodin.put_str(&sink, " sleep queue checks, ")
	libodin.put_uint(&sink, u64(r.failures))
	libodin.put_str(&sink, " FAILED -- first: ")
	libodin.put_str(&sink, r.first_failure)
	emit(&klog, .Fault, &sink)
}
