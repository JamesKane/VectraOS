/*
The sleeping lock, checked directly.

`kernel/verify_vfs.odin` exercises `sync.Mutex` hard -- ten thousand parks a
second under five threads -- but only through the namespace, where a lock
failure arrives as a wrong directory listing several layers up. This is the
lock on its own terms: two threads, one mutex, and the three properties the
rest of the kernel is entitled to assume.

    exclusion    two threads are never inside it at once
    contention   they really did park, rather than never meeting
    accounting   a thread that spent a slice of CPU decayed, even though it
                 blocked its way through every one of them

The third looks like a scheduler property in a lock's self-test, and it is
here because a sleeping lock is what made it reachable. `Thread.ticks_left`
used to be refilled on every dispatch, which was the same thing as refilling
it every slice for exactly as long as nothing blocked. Two threads handing a
mutex back and forth are dispatched several hundred times a second and reach
the end of a slice never, so under the old rule they sit at their base
priority no matter how much of the machine they are using -- and the priority
they are sitting at is now also the one this lock hands off on.

The critical section is a spin rather than a few instructions, deliberately.
It has to be long enough that a timer lands inside it and short enough that it
never runs a whole slice on its own, because that gap is precisely what
distinguishes "charged for the CPU it used" from "never finished a slice".
*/
package kernel

import "base:intrinsics"
import "base:runtime"

import "kernel:mem"
import "kernel:sched"
import "kernel:sync"
import "vsys:libodin"

// Long enough for a 1 kHz tick to land inside the critical section a good
// fraction of the time; far short of the ten ticks in a slice.
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

`contend_inside` is a plain bool guarded by nothing but the mutex, which is
the point: if two threads are ever inside at once, one of them sees it set on
the way in or clear on the way out. Volatile so the compiler cannot decide
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

@(private = "file")
Sync_Result :: struct {
	checks:        int,
	failures:      int,
	first_failure: string,
	takes:         int,
	slept:         u64,
	handoffs:      u64,
	prio:          int, // The lower of the two contenders' final priorities
}

@(private = "file")
scheck :: proc "contextless" (r: ^Sync_Result, ok: bool, what: string) -> bool {
	r.checks += 1
	if !ok {
		r.failures += 1
		if r.first_failure == "" {
			r.first_failure = what
		}
	}
	return ok
}

/*
verify_sleep_lock runs the whole thing and reports.

Ordered before the namespace self-test on purpose: if the lock itself is
broken, the five-thread namespace run says so in the vocabulary of mount
tables, and this says so in the vocabulary of locks.
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

	// The boot thread has nothing to do here and no business competing with
	// the two threads it is measuring, so it parks: off every run queue until
	// the second of them is finished, with a deadline so that a contender
	// that wedges is a failed check rather than a hung boot.
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

	Two threads that hand a lock back and forth are dispatched hundreds of
	times a second and finish a slice on their own never. They are also using
	the entire machine between them. A scheduler that only decays a thread for
	reaching the end of a slice leaves both of them near their base priority
	for ever, which is what happened before `Thread.ticks_left` learned to
	carry its remainder across a block.

	The bar is four levels rather than one because one level is what the old
	rule manages by accident: each thread's first dispatch runs uncontended
	and does reach the end of a slice. Charged properly the two of them reach
	the floor; charged per dispatch they stop at seven.
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
	if r.failures == 0 && r.checks > 0 {
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
