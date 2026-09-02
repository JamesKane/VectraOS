/*
The sleeping lock, checked directly.

`kernel/verify_vfs.odin` exercises `sync.Mutex` hard, at ten thousand parks a
second under five threads. But it does that only through the namespace, where a
lock failure arrives as a wrong directory listing several layers up. This is
the lock on its own terms: two threads, one mutex, and the three properties the
rest of the kernel is entitled to assume.

    exclusion    two threads are never inside it at once
    contention   they really did park, rather than never meeting
    accounting   a thread that spent a slice of CPU decayed, even though it
                 blocked its way through every one of them

The third looks like a scheduler property in a lock's self-test, and it is here
because a sleeping lock is what made it reachable. `Thread.ticks_left` used to
be refilled on every dispatch, which was the same thing as refilling it every
slice for exactly as long as nothing blocked. Two threads that hand a mutex
back and forth are dispatched several hundred times a second, and reach the end
of a slice never. Under the old rule they sit at their base priority, no matter
how much of the machine they use.

And the priority they sit at is now also the one this lock hands off on.

The critical section is a spin rather than a few instructions, deliberately. It
has to be long enough for a timer to land inside it. It also has to be short
enough never to run a whole slice on its own. That gap is precisely what tells
`charged for the CPU it used` apart from `never finished a slice`.
*/
package kernel

import "base:intrinsics"
import "base:runtime"

import "kernel:mem"
import "kernel:sched"
import "kernel:sync"
import "vsys:libodin"

// Long enough for a 1 kHz tick to land inside the critical section a good
// fraction of the time. Far short of the ten ticks in a slice.
@(private = "file")
HOLD_SPINS :: 20_000

@(private = "file")
CONTEND_TICKS :: 200

// Below this a thread did not meaningfully take part, and nothing it did or
// did not observe means anything.
@(private = "file")
MIN_TAKES :: 50

@(private = "file")
CONTENDERS :: 2

// Levels a contender must have sunk by the end. See the accounting check.
@(private = "file")
MIN_DECAY :: 4

@(private = "file")
contend_lock: sync.Mutex
@(private = "file")
contend_inside: bool // True while someone is in the critical section
@(private = "file")
contend_scratch: int // Something for the hold loop to touch
@(private = "file")
contend_deadline: u64
@(private = "file")
contend_violations: int
@(private = "file")
contend_takes: [CONTENDERS]int
@(private = "file")
contend_prio: [CONTENDERS]int
@(private = "file")
contend_done: int

// Where the boot thread waits for the two of them.
@(private = "file")
contend_over: sync.Rendez

// How long past the contenders' own deadline the boot thread keeps waiting
// before deciding one of them is stuck.
@(private = "file")
PATIENCE :: 200

@(private = "file")
both_done :: proc "contextless" (arg: rawptr) -> bool {
	return intrinsics.volatile_load(&contend_done) >= CONTENDERS
}

/*
contend_worker takes the lock, occupies it visibly, and gives it back.

`contend_inside` is a plain bool, and nothing but the mutex guards it. That is
the point. If two threads are ever inside at once, one of them sees it set on
the way in, or clear on the way out. Volatile so the compiler cannot decide
that a variable this thread just wrote is still what it wrote.
*/
@(private = "file")
contend_worker :: proc "contextless" (arg: rawptr) #no_bounds_check {
	c := runtime.default_context()
	c.allocator = mem.allocator()
	context = c

	slot := int(uintptr(arg))

	for sched.ticks() < intrinsics.volatile_load(&contend_deadline) {
		sync.mutex_lock(&contend_lock)

		if intrinsics.volatile_load(&contend_inside) {
			intrinsics.volatile_store(
				&contend_violations,
				intrinsics.volatile_load(&contend_violations) + 1,
			)
		}
		intrinsics.volatile_store(&contend_inside, true)

		for i in 0 ..< HOLD_SPINS {
			intrinsics.volatile_store(&contend_scratch, i)
		}

		// Still ours on the way out, or somebody was in here too.
		if !intrinsics.volatile_load(&contend_inside) {
			intrinsics.volatile_store(
				&contend_violations,
				intrinsics.volatile_load(&contend_violations) + 1,
			)
		}
		intrinsics.volatile_store(&contend_inside, false)

		sync.mutex_unlock(&contend_lock)
		intrinsics.volatile_store(
			&contend_takes[slot],
			intrinsics.volatile_load(&contend_takes[slot]) + 1,
		)
	}

	if t := sched.current(); t != nil {
		intrinsics.volatile_store(&contend_prio[slot], int(t.prio))
	}
	intrinsics.volatile_store(&contend_done, intrinsics.volatile_load(&contend_done) + 1)
	sync.wakeup(&contend_over)
}

/*
The read/write lock, held to Plan 9's three rules by a scripted scenario.

Two contenders racing would show exclusion and nothing else. What the lock
promises is about *order*, so this is a script rather than a race. The boot
thread reads, a writer arrives and waits, and a second reader arrives and
waits behind the writer. The first reader leaves and the writer goes first,
and the writer leaving admits the reader. Every step is bounded, and every
"waits" is a check that the thread parked rather than got in.
*/
@(private = "file")
rw: sync.RW_Lock
@(private = "file")
rw_writer_in: bool
@(private = "file")
rw_writer_done: bool
@(private = "file")
rw_reader_in: bool
@(private = "file")
rw_reader_done: bool
@(private = "file")
rw_release_writer: bool
@(private = "file")
rw_step: sync.Rendez

@(private = "file")
rw_writer_may_go :: proc "contextless" (arg: rawptr) -> bool {
	return intrinsics.volatile_load(&rw_release_writer)
}

@(private = "file")
rw_writer_worker :: proc "contextless" (arg: rawptr) {
	_ = arg
	sync.wlock(&rw)
	intrinsics.volatile_store(&rw_writer_in, true)
	sync.wakeup(&rw_step)
	sync.sleep(&rw_step, rw_writer_may_go)
	intrinsics.volatile_store(&rw_writer_in, false)
	sync.wunlock(&rw)
	intrinsics.volatile_store(&rw_writer_done, true)
	sync.wakeup(&rw_step)
}

@(private = "file")
rw_reader_worker :: proc "contextless" (arg: rawptr) {
	_ = arg
	sync.rlock(&rw)
	intrinsics.volatile_store(&rw_reader_in, true)
	sync.wakeup(&rw_step)
	sync.runlock(&rw)
	intrinsics.volatile_store(&rw_reader_done, true)
	sync.wakeup(&rw_step)
}

// await parks the boot thread a tick at a time until `flag` is set, or
// gives up after the patience. A wait with no bound would be a hang with
// no name, which `docs/TESTING.md` forbids.
@(private = "file")
await :: proc(flag: ^bool) -> bool {
	for _ in 0 ..< PATIENCE {
		if intrinsics.volatile_load(flag) {
			return true
		}
		sync.delay(1)
	}
	return false
}

/*
await_parked reports whether a thread this test spawned is parked. That is
how the boot thread sees that it queued on the lock rather than got in.

The thread's own state, and not the package's sleep counter. The first
version counted sleeps, and a control that let a reader pass a queued writer
came back clean. The boot thread's own one-tick delays park too, so the
count moved whether or not the spawned thread did. A sensor the checker
itself moves is a check that cannot fail. `docs/TESTING.md` has that lesson,
under observing the effect rather than the bookkeeping beside it.
*/
@(private = "file")
await_parked :: proc(t: ^sched.Thread) -> bool {
	for _ in 0 ..< PATIENCE {
		if intrinsics.volatile_load(&t.state) == .Blocked {
			return true
		}
		sync.delay(1)
	}
	return false
}


verify_rw_lock :: proc() {
	r: Sync_Result

	scheck(&r, sync.rw_readers(&rw) == 0 && !sync.rw_writer(&rw), "a fresh read/write lock is free")
	sync.rlock(&rw)
	sync.rlock(&rw)
	scheck(&r, sync.rw_readers(&rw) == 2, "and two readers share it")
	sync.runlock(&rw)
	scheck(&r, sync.rw_readers(&rw) == 1, "one leaves and one remains")

		// A writer arrives while a reader holds the lock, and waits.
	writer := sched.spawn("rw-writer", rw_writer_worker)
	if !scheck(&r, writer != nil, "a writer is spawned") {
		sync.runlock(&rw)
		report_rw_lock(&r)
		return
	}
	scheck(&r, await_parked(writer), "and parks behind the reader")
	scheck(&r, !intrinsics.volatile_load(&rw_writer_in), "rather than getting in beside it")

	// A second reader arrives behind the queued writer, and waits too. This
	// is the rule that stops readers starving a writer, and the one a
	// simpler lock gets wrong.
		reader := sched.spawn("rw-reader", rw_reader_worker)
	if !scheck(&r, reader != nil, "a second reader is spawned") {
		sync.runlock(&rw)
		report_rw_lock(&r)
		return
	}
	scheck(&r, await_parked(reader), "and parks behind the waiting writer")
	scheck(&r, !intrinsics.volatile_load(&rw_reader_in), "rather than joining the reader that holds the lock")

		// The first reader leaves, and the writer goes first. The queue is in
	// arrival order, and the last reader out starts the writer at its head.
	handoffs := sync.sleep_stats().handoffs
	sync.runlock(&rw)
	scheck(&r, await(&rw_writer_in), "the last reader out starts the writer")
	scheck(&r, sync.rw_writer(&rw) && sync.rw_readers(&rw) == 0, "which holds the lock alone")
	scheck(&r, !intrinsics.volatile_load(&rw_reader_in), "while the reader behind it still waits")

	// The writer leaves, and the reader at the head of the queue goes in.
	intrinsics.volatile_store(&rw_release_writer, true)
	sync.wakeup(&rw_step)
	scheck(&r, await(&rw_reader_in), "the writer leaving admits the reader at the head")
	scheck(&r, await(&rw_reader_done) && await(&rw_writer_done), "and both finish")
	scheck(&r, sync.rw_readers(&rw) == 0 && !sync.rw_writer(&rw), "leaving the lock free")
	scheck(&r, sync.sleep_stats().handoffs - handoffs == 2, "with two handoffs, one per waiter, and no release to nobody")
	sched.reap()

	report_rw_lock(&r)
}

@(private = "file")
report_rw_lock :: proc(r: ^Sync_Result) {
	sink := begin(&klog)
	libodin.put_str(&sink, "sync ")
	libodin.put_uint(&sink, u64(r.checks))
	if libodin.passed(r.tally) {
		libodin.put_str(&sink, " read/write lock checks passed -- a writer waited behind a reader, a reader behind the writer, and each was handed the lock in turn")
		emit(&klog, .Ok, &sink)
		return
	}
	libodin.put_str(&sink, " read/write lock checks, ")
	libodin.put_uint(&sink, u64(r.failures))
	libodin.put_str(&sink, " FAILED -- first: ")
	libodin.put_str(&sink, r.first_failure)
	emit(&klog, .Fault, &sink)
}

@(private = "file")
Sync_Result :: struct {
	using tally:   libodin.Tally,
	takes:         int,
	slept:         u64,
	handoffs:      u64,
	prio:          int, // The lower of the two contenders' final priorities
}

@(private = "file")
scheck :: proc "contextless" (r: ^Sync_Result, ok: bool, what: string) -> bool {
	return libodin.tally(&r.tally, ok, what)
}

/*
verify_sleep_lock runs the whole thing and reports.

Ordered before the namespace self-test on purpose. If the lock itself is
broken, the five-thread namespace run says so in the vocabulary of mount
tables. This says so in the vocabulary of locks.
*/
verify_sleep_lock :: proc() #no_bounds_check {
	r: Sync_Result

	// Uncontended, on the boot thread, before anything else can be involved.
	scheck(&r, !sync.mutex_held(&contend_lock), "a fresh mutex is free")
	sync.mutex_lock(&contend_lock)
	scheck(&r, sync.mutex_held(&contend_lock), "and is held once taken")
	sync.mutex_unlock(&contend_lock)
	scheck(&r, !sync.mutex_held(&contend_lock), "and free again once given back")

	// The rule the whole file rests on, from both sides.
	scheck(&r, sync.can_sleep(), "a thread holding no spinlock may sleep")
	{
		probe: sync.Spinlock
		g := sync.acquire(&probe)
		inside := sync.can_sleep()
		sync.release(&probe, g)
		scheck(&r, !inside, "a thread inside one may not")
	}
	scheck(&r, sync.can_sleep(), "and may again once it is out")

	intrinsics.volatile_store(&contend_done, 0)
	intrinsics.volatile_store(&contend_violations, 0)
	intrinsics.volatile_store(&contend_inside, false)
	for i in 0 ..< CONTENDERS {
		intrinsics.volatile_store(&contend_takes[i], 0)
		intrinsics.volatile_store(&contend_prio[i], 0)
	}
	before := sync.sleep_stats()
	intrinsics.volatile_store(&contend_deadline, sched.ticks() + CONTEND_TICKS)

	spawned := 0
	if sched.spawn("lock-a", contend_worker, rawptr(uintptr(0))) != nil {
		spawned += 1
	}
	if sched.spawn("lock-b", contend_worker, rawptr(uintptr(1))) != nil {
		spawned += 1
	}
	if !scheck(&r, spawned == CONTENDERS, "both contenders spawned") {
		report_sleep_lock(&r)
		return
	}

	// The boot thread has nothing to do here, and no business in contention with
	// the two threads it measures. So it parks.
	//
	// It is off every run queue until the second of them finishes. The deadline
	// makes a contender that wedges a failed check, rather than a hung boot.
	scheck(
		&r,
		sync.sleep_for(&contend_over, both_done, nil, CONTEND_TICKS + PATIENCE),
		"both contenders finished",
	)
	sched.reap()

	after := sync.sleep_stats()
	r.slept = after.sleeps - before.sleeps
	r.handoffs = after.handoffs - before.handoffs

	a := intrinsics.volatile_load(&contend_takes[0])
	b := intrinsics.volatile_load(&contend_takes[1])
	r.takes = a + b
	r.prio = min(
		intrinsics.volatile_load(&contend_prio[0]),
		intrinsics.volatile_load(&contend_prio[1]),
	)

	scheck(&r, a >= MIN_TAKES && b >= MIN_TAKES, "both contenders took the lock repeatedly")
	scheck(&r, intrinsics.volatile_load(&contend_violations) == 0, "and never both at once")
	scheck(&r, !sync.mutex_held(&contend_lock), "the lock came back free")

	// Without this the run proves only that two threads took turns politely.
	scheck(&r, r.slept > 0, "they contended for it rather than taking turns")
	scheck(&r, r.handoffs > 0, "and it was handed over rather than released")

	/*
	The accounting check.

	Two threads that hand a lock back and forth are dispatched hundreds of times a
	second and finish a slice on their own never. They are also using the entire
	machine between them. A scheduler that only decays a thread at the end of a
	slice leaves both of them near their base priority for ever. That is what
	happened before `Thread.ticks_left` learned to carry its remainder across a
	block.

	The bar is four levels rather than one, because one level is what the old rule
	manages by accident. Each thread's first dispatch runs uncontended, and does
	reach the end of a slice. Charged properly, the two of them reach the floor.
	Charged per dispatch, they stop at seven.
	*/
	scheck(
		&r,
		r.prio > 0 && r.prio <= int(sched.PRIORITY_NORMAL) - MIN_DECAY,
		"and a thread that blocked through a whole slice was still charged for it",
	)

	report_sleep_lock(&r)
}

@(private = "file")
report_sleep_lock :: proc(r: ^Sync_Result) {
	sink := begin(&klog)
	libodin.put_str(&sink, "sync ")
	libodin.put_uint(&sink, u64(r.checks))
	if libodin.passed(r.tally) {
		libodin.put_str(&sink, " sleeping lock checks passed -- ")
		libodin.put_uint(&sink, u64(r.takes))
		libodin.put_str(&sink, " acquisitions, ")
		libodin.put_uint(&sink, r.slept)
		libodin.put_str(&sink, " parked and handed back, decayed to ")
		libodin.put_uint(&sink, u64(r.prio))
		emit(&klog, .Ok, &sink)
		return
	}

	libodin.put_str(&sink, " sleeping lock checks, ")
	libodin.put_uint(&sink, u64(r.failures))
	libodin.put_str(&sink, " FAILED -- first: ")
	libodin.put_str(&sink, r.first_failure)
	emit(&klog, .Fault, &sink)
}
