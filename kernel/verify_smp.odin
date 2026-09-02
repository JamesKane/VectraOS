/*
The other cores, watched from the first.

Every other self-test in this tree ran on one core and said so. This one runs
after the cores come up and asks the questions only a second core can answer.
Does every core take its own ticks? Does work spread? Does a wake that the
boot core's clock starts reach a thread parked on some other core, and does
that thread run there?

The boot thread watches and never parks on anything a missing core would
have to end. Every wait has a bound, and a bound that runs out is a check
that fails with a name, which `docs/TESTING.md` argues at length. A core
that came up and then stopped would show here as ticks that stopped moving,
and not as a boot that hangs.
*/
package kernel

import "base:intrinsics"

import "kernel:arch"
import "kernel:mem"
import "kernel:sched"
import "kernel:sync"
import "vsys:libodin"

// Workers per phase: two per core on the largest machine this kernel counts. A
// core with nothing to do is then a core the placement chose to leave idle,
// and not one the count could not reach.
@(private = "file")
SMP_WORKERS :: 2 * sched.MAX_CPUS

// How long a spinning worker holds its core. Three slices, so the timer
// preempts it and the core's switch count moves for a reason this test made.
@(private = "file")
SPIN_TICKS :: 30

// How many one-tick delays a parking worker takes. Each is a deadline the
// boot core's clock fires and a placement that may move the thread.
@(private = "file")
DELAY_ROUNDS :: 40

// The bound on every wait here, in ticks.
@(private = "file")
PATIENCE :: 400

// How many times the kick is measured. A wake without a kick waits for the
// idle core's next tick, half a tick on average, so fifty of them cost about
// twenty-five ticks. Fifty with a kick cost a handful.
@(private = "file")
KICK_ROUNDS :: 50

// A short worker: it writes down where it ran and ends. The boot thread spins
// rather than parks while it waits for one. The boot core stays busy, and the
// placement sends the worker to a core that is not.
@(private = "file")
brief_worker :: proc "contextless" (arg: rawptr) {
	i := int(uintptr(arg))
	core := sched.cpu().id
	intrinsics.volatile_store(&worker_where[i], core)
	intrinsics.volatile_store(&worker_done[i], true)
}

Smp_Result :: struct {
	using tally: libodin.Tally,
	cores:       int, // Online, the boot core included
	spread:      int, // Distinct cores the spinning workers ended on
	delays:      u64, // Deadlines the parking workers slept through
	kick_ticks:  u64, // Ticks fifty kicked wakes took, all told
	kicks:       u64, // Kicks the boot core sent while they ran
}

@(private = "file")
scheck :: proc "contextless" (r: ^Smp_Result, ok: bool, what: string) -> bool {
	return libodin.tally(&r.tally, ok, what)
}

// Where each worker was when it finished, and whether it has. `worker_where` is the
// core's id, read once so a preemption between the read and the store cannot
// change the answer half way.
@(private = "file")
worker_where: [SMP_WORKERS]int
@(private = "file")
worker_done: [SMP_WORKERS]bool

@(private = "file")
spin_worker :: proc "contextless" (arg: rawptr) {
	i := int(uintptr(arg))
	start := sched.ticks()
	for sched.ticks() - start < SPIN_TICKS {
		arch.spin_hint()
	}
	core := sched.cpu().id
	intrinsics.volatile_store(&worker_where[i], core)
	intrinsics.volatile_store(&worker_done[i], true)
}

@(private = "file")
delay_worker :: proc "contextless" (arg: rawptr) {
	i := int(uintptr(arg))
	for _ in 0 ..< DELAY_ROUNDS {
		sync.delay(1)
	}
	core := sched.cpu().id
	intrinsics.volatile_store(&worker_where[i], core)
	intrinsics.volatile_store(&worker_done[i], true)
}

@(private = "file")
all_done :: proc "contextless" (arg: rawptr) -> bool {
	n := int(uintptr(arg))
	for i in 0 ..< n {
		if !intrinsics.volatile_load(&worker_done[i]) {
			return false
		}
	}
	return true
}

@(private = "file")
nothing_to_reap :: proc "contextless" (arg: rawptr) -> bool {
	_ = arg
	return sched.reap_pending_all() == 0
}

// kicks_sent sums the kicks every core sent. Every core, because the boot
// thread is a thread like any other. It may itself be placed on another core
// between two spawns, and its kicks are then that core's.
@(private = "file")
kicks_sent :: proc "contextless" (cores: int) -> u64 {
	n: u64
	for i in 0 ..< cores {
		n += sched.cpu_stats(i).kicks
	}
	return n
}

// spread counts the distinct cores the first `n` workers ended on.
@(private = "file")
spread :: proc "contextless" (n: int) -> int {
	seen: [sched.MAX_CPUS]bool
	count := 0
	for i in 0 ..< n {
		w := intrinsics.volatile_load(&worker_where[i])
		if w >= 0 && w < sched.MAX_CPUS && !seen[w] {
			seen[w] = true
			count += 1
		}
	}
	return count
}

@(private = "file")
run_workers :: proc(r: ^Smp_Result, name: string, entry: sched.Thread_Proc, n: int, what: string) -> bool {
	for i in 0 ..< n {
		intrinsics.volatile_store(&worker_done[i], false)
		intrinsics.volatile_store(&worker_where[i], -1)
	}
	spawned := 0
	for i in 0 ..< n {
		if sched.spawn(name, entry, rawptr(uintptr(i))) != nil {
			spawned += 1
		}
	}
	if !scheck(r, spawned == n, "every worker was spawned") {
		return false
	}
	return scheck(r, sync.await(all_done, rawptr(uintptr(n)), PATIENCE), what)
}

verify_smp :: proc() {
	r: Smp_Result

	mp := mp_request.response
	expected := mp == nil ? 1 : min(int(mp.cpu_count), sched.MAX_CPUS)
	r.cores = sched.online_count()
	scheck(&r, r.cores == expected, "every core the bootloader listed is online")
	if !scheck(&r, r.cores >= 2, "there is a second core to test against") {
		report_smp(&r)
		return
	}

	// -- Every core keeps its own time ----------------------------------------

	before: [sched.MAX_CPUS]sched.Cpu_Stats
	for i in 0 ..< r.cores {
		before[i] = sched.cpu_stats(i)
	}
	sync.delay(20)
	ticking := true
	for i in 0 ..< r.cores {
		if sched.cpu_stats(i).ticks <= before[i].ticks {
			ticking = false
		}
	}
	scheck(&r, ticking, "every core takes its own timer ticks")

	sched.reap()
	_ = sync.await(nothing_to_reap, nil, PATIENCE)
	pin_before := mem.live_objects(mem.heap_stats())

	// -- Work spreads ---------------------------------------------------------

	/*
	Twice as many spinning workers as cores, each holding a core for three
	slices. `pick_cpu` sends each new one to the least loaded core, so on a
	machine with a second core the second worker lands there. The core each
	ended on is what it wrote down. More than one core in that list is the
	placement doing what `docs/SCHED.md` says it does.
	*/
	if run_workers(&r, "smp-spin", spin_worker, SMP_WORKERS, "every spinning worker finished inside the bound") {
		r.spread = spread(SMP_WORKERS)
		scheck(&r, r.spread >= 2, "the spinning workers ran on more than one core")
		moved := true
		for i in 0 ..< r.cores {
			if sched.cpu_stats(i).switches <= before[i].switches {
				moved = false
			}
		}
		scheck(&r, moved, "every core switched threads while they ran")
	}

	// -- A wake crosses cores -------------------------------------------------

	/*
	Each parking worker sleeps a tick at a time. The deadline is on the boot
	core's clock, and the boot core's tick is what readies the thread, wherever
	it parked. `ready` places it afresh, so a thread that parked on one core
	may run its next round on another. Every round is therefore a wait list
	written from two cores and a scheduler lock taken from two. It is also a
	switch that let go of a thread one core was leaving so another could take
	it.
	*/
	stats_before := sync.sleep_stats()
	if run_workers(&r, "smp-park", delay_worker, SMP_WORKERS, "every parking worker finished inside the bound") {
		r.delays = sync.sleep_stats().timeouts - stats_before.timeouts
		scheck(
			&r,
			r.delays >= u64(SMP_WORKERS * DELAY_ROUNDS),
			"every one-tick delay ended by its deadline",
		)
		scheck(&r, spread(SMP_WORKERS) >= 2, "the parking workers woke on more than one core")
	}

	// -- A wake reaches an idle core now ----------------------------------------

	/*
	Every other core is idle, halted with interrupts on. The boot thread spawns
	a worker, which lands on one of them, and spins until it reports. Without a
	kick that core finds the worker at its next tick, so fifty rounds cost
	about twenty-five ticks. With one they cost almost none. The bound on the
	spin is the same patience every other wait here has. A kick counter says a
	core sent them rather than got lucky.
	*/
	kicks_before := kicks_sent(r.cores)
	start := sched.ticks()
	rounds := 0
	for round in 0 ..< KICK_ROUNDS {
		intrinsics.volatile_store(&worker_done[0], false)
		if sched.spawn("smp-brief", brief_worker, rawptr(uintptr(0))) == nil {
			break
		}
		for !intrinsics.volatile_load(&worker_done[0]) {
			if sched.ticks() - start > PATIENCE {
				break
			}
			arch.spin_hint()
		}
		if !intrinsics.volatile_load(&worker_done[0]) {
			break
		}
		rounds = round + 1
	}
	r.kick_ticks = sched.ticks() - start
	r.kicks = kicks_sent(r.cores) - kicks_before
	scheck(&r, rounds == KICK_ROUNDS, "fifty brief workers each ran on an idle core and reported")
	scheck(&r, r.kicks >= u64(KICK_ROUNDS), "and a core kicked an idle core for each of them")
	scheck(&r, r.kick_ticks < KICK_ROUNDS / 2, "and the fifty wakes together cost less than the ticks they would have waited for")
	received: u64
	for i in 1 ..< r.cores {
		received += sched.cpu_stats(i).ipis
	}
	scheck(&r, received >= u64(KICK_ROUNDS), "and the kicks arrived on the other cores")

	// -- Nothing left behind --------------------------------------------------

	// Each worker's stack comes back on the core it died on, when that core's
	// idle thread next runs. Waited for rather than assumed.
	scheck(&r, sync.await(nothing_to_reap, nil, PATIENCE), "every core reaped its dead")
	sched.reap()
	scheck(&r, mem.live_objects(mem.heap_stats()) == pin_before, "and the heap is balanced")

	report_smp(&r)
}

@(private = "file")
report_smp :: proc(r: ^Smp_Result) {
	ok := libodin.passed(r.tally)

	sink := begin(&klog)
	libodin.put_str(&sink, "smp ")
	libodin.put_uint(&sink, u64(r.checks))
	if ok {
		libodin.put_str(&sink, " multiprocessor checks passed -- ")
		libodin.put_uint(&sink, u64(r.cores))
		libodin.put_str(&sink, " cores ticking, workers spread over ")
		libodin.put_uint(&sink, u64(r.spread))
		libodin.put_str(&sink, ", ")
		libodin.put_uint(&sink, r.delays)
		libodin.put_str(&sink, " deadlines fired across them, ")
		libodin.put_uint(&sink, u64(KICK_ROUNDS))
		libodin.put_str(&sink, " kicked wakes in ")
		libodin.put_uint(&sink, r.kick_ticks)
		libodin.put_str(&sink, " ticks, heap balanced")
		emit(&klog, .Ok, &sink)
		return
	}

	libodin.put_str(&sink, " checks, ")
	libodin.put_uint(&sink, u64(r.failures))
	libodin.put_str(&sink, " FAILED -- first: ")
	libodin.put_str(&sink, r.first_failure)
	emit(&klog, .Fault, &sink)
}
