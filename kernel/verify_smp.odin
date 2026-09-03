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
import "base:runtime"

import "kernel:arch"
import "kernel:mem"
import "kernel:sched"
import "kernel:sync"
import "kernel:user"
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
	claims:      int, // Process slots claimed and given back, across cores
	lines:       int, // Log lines four cores wrote at once, all of them whole
	shot_ticks:  u64, // Ticks between an unmap here and the fault on the other core
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

// The claimers: each takes a process slot through the real path, with a space,
// a namespace and a descriptor group. It gives the slot back and writes down
// every pid it was handed. Four of them at once on four cores is the race the
// table lock exists for. A full table is a round that did not happen rather
// than a failure. The ring 3 servers hold slots of their own after boot.
@(private = "file")
CLAIMERS :: 4
@(private = "file")
CLAIM_ROUNDS :: 24
@(private = "file")
claim_pids: [CLAIMERS][CLAIM_ROUNDS]u64
@(private = "file")
claim_code: [16]u8

@(private = "file")
claim_worker :: proc "contextless" (arg: rawptr) {
	context = runtime.default_context()
	context.allocator = mem.allocator()
	i := int(uintptr(arg))
	for round in 0 ..< CLAIM_ROUNDS {
		p, err := user.load_held("smp-claim", claim_code[:])
		if err != .None {
			continue
		}
		claim_pids[i][round] = user.pid_of(p)
		_ = user.destroy(p)
	}
	intrinsics.volatile_store(&worker_done[i], true)
}

// distinct_pids reports how many pids the claimers wrote down, and whether
// any two of them were the same. Two claimers handed one pid is two claimers
// handed one slot, which is the thing the lock forbids.
@(private = "file")
distinct_pids :: proc "contextless" () -> (claims: int, unique: bool) {
	unique = true
	for i in 0 ..< CLAIMERS {
		for r in 0 ..< CLAIM_ROUNDS {
			a := claim_pids[i][r]
			if a == 0 {
				continue
			}
			claims += 1
			for j in 0 ..< CLAIMERS {
				for s in 0 ..< CLAIM_ROUNDS {
					if (j != i || s != r) && claim_pids[j][s] == a {
						unique = false
					}
				}
			}
		}
	}
	return
}

// The writers: each logs four long lines into a logger with no sinks, so the
// lines land in its early buffer, whole or not. The body is the writer's own
// mark repeated. A line built out of two cores' formatting is one whose bytes
// disagree with its first byte. Sixteen lines fill the buffer exactly.
@(private = "file")
LOG_WRITERS :: 4
@(private = "file")
LOG_LINES :: EARLY_LINES_MAX / LOG_WRITERS
@(private = "file")
LOG_BODY :: EARLY_LINE_MAX - 8
@(private = "file")
probe_log: Logger

// How many writers are at the start line. Each waits for all of them before it
// writes. The four then format at the same instant, rather than one after
// another as the spawns landed. A spawn takes longer than a writer's whole
// run, and without this the writers never overlapped.
@(private = "file")
log_arrived: u32

@(private = "file")
log_worker :: proc "contextless" (arg: rawptr) {
	i := int(uintptr(arg))
	mark := u8('a') + u8(i)
	intrinsics.atomic_add(&log_arrived, 1)
	for intrinsics.atomic_load(&log_arrived) < LOG_WRITERS {
		arch.spin_hint()
	}
	for _ in 0 ..< LOG_LINES {
		sink := begin(&probe_log)
		for _ in 0 ..< LOG_BODY {
			libodin.put_str(&sink, string([]u8{mark}))
		}
		emit(&probe_log, .Info, &sink)
	}
	intrinsics.volatile_store(&worker_done[i], true)
}

// whole_lines counts the lines in the probe logger's early buffer, and reports
// whether every byte of every line is the byte the line starts with.
@(private = "file")
whole_lines :: proc "contextless" () -> (lines: int, whole: bool) #no_bounds_check {
	whole = true
	for i in 0 ..< probe_log.early_count {
		slot := &probe_log.early[i]
		lines += 1
		if slot.len != LOG_BODY || slot.truncated {
			whole = false
			continue
		}
		for j in 0 ..< slot.len {
			if slot.text[j] != slot.text[0] {
				whole = false
			}
		}
	}
	return
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

// The spinning program's counter, read through its data frame from here. The
// program increments it on every pass. A count that moved is a program that
// runs, and one that stopped moving is a program that faulted.
@(private = "file")
spin_moving :: proc "contextless" (arg: rawptr) -> bool {
	return user.cell(cast(^user.Process)arg, 1) > 0
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

// shoots_sent is the same for shootdowns, for a check made by a thread that
// may not be on the core it started on.
@(private = "file")
shoots_sent :: proc "contextless" (cores: int) -> u64 {
	n: u64
	for i in 0 ..< cores {
		n += sched.cpu_stats(i).shoots
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
	// Nearly every round, and not every one. A worker that has reported and
	// not yet left its core leaves that core's next reschedule imminent, and
	// a placement there needs no kick and sends none. That is the scheduler
	// being right, once in fifty on the ports, and the check asks for the
	// forty-five that were kicks.
	scheck(&r, r.kicks * 10 >= u64(KICK_ROUNDS) * 9, "and a core kicked an idle core for nearly every one of them")
	scheck(&r, r.kick_ticks < KICK_ROUNDS / 2, "and the fifty wakes together cost less than the ticks they would have waited for")
	received: u64
	for i in 1 ..< r.cores {
		received += sched.cpu_stats(i).ipis
	}
	scheck(&r, received >= u64(KICK_ROUNDS), "and the kicks arrived on the other cores")

	// -- Two cores claim a process slot at once ---------------------------------

	/*
	Four claimers, each taking and giving back a process record through the
	real path, at once. A claim finds a slot that is not live and makes it
	live. Two cores that did that unlocked would both find the same slot and
	both write a pid into it. Every pid handed out is written down, and one pid
	in two places is the failure. The live count and the heap say the records
	all came back.
	*/
	for i in 0 ..< CLAIMERS {
		for r in 0 ..< CLAIM_ROUNDS {
			claim_pids[i][r] = 0
		}
	}
	live_before := user.stats().live
	claim_heap := mem.live_objects(mem.heap_stats())
	if run_workers(&r, "smp-claim", claim_worker, CLAIMERS, "every claimer finished inside the bound") {
		unique: bool
		r.claims, unique = distinct_pids()
		scheck(&r, r.claims >= CLAIMERS * CLAIM_ROUNDS / 2, "the claimers were handed process records, most rounds")
		scheck(&r, unique, "and no two claimers were handed one record")
		scheck(&r, user.stats().live == live_before, "and every record they took was given back")
		_ = sync.await(nothing_to_reap, nil, PATIENCE)
		sched.reap()
		scheck(&r, mem.live_objects(mem.heap_stats()) == claim_heap, "with the heap where it was")
	}

		// -- Four cores log at once ----------------------------------------------

	/*
	Four writers, each formatting long lines and emitting them into a logger
	that has no sinks, at once. A line is built in a buffer per core, and the
	early buffer takes it under the lock. Every line that lands is therefore
	one writer's, whole. A shared buffer would hand one writer's line to
	another half way through, and the byte check finds that. Sixteen lines fill
	the early buffer exactly, so nothing was dropped either.
	*/
	probe_log = Logger{}
	intrinsics.atomic_store(&log_arrived, 0)
	if run_workers(&r, "smp-log", log_worker, LOG_WRITERS, "every log writer finished inside the bound") {
		whole: bool
		r.lines, whole = whole_lines()
		scheck(&r, r.lines == EARLY_LINES_MAX, "every line four cores logged at once was kept")
		scheck(&r, whole, "and each is one writer's, whole")
	}

	// -- An unmap here reaches a translation cached over there -----------------

	/*
	A program spins on its data page, so the core running it holds the page's
	translation in its TLB. The boot thread is busy, so the program lands on
	another core. Then this core unmaps that page. Without a shootdown the
	other core keeps translating through the entry it cached, and the program
	runs on for as long as its loop lasts. With one, its next touch of the page
	is a fault, and the fault is what this waits for.
	*/
	if prog, lerr := user.load("smp-spin", user.program_spin(), 0); scheck(&r, lerr == .None, "a spinning program was loaded") {
		running := sync.await(spin_moving, prog, PATIENCE)
		scheck(&r, running, "and it runs, counting on its data page")
		// This thread's own core, read now rather than assumed to be the boot
		// core. The boot thread parks and is placed afresh like any other, and
		// nothing between here and the unmap parks it again.
		me := sched.cpu().id
		on := prog.thread != nil && prog.thread.cpu != nil ? prog.thread.cpu.id : me
		scheck(&r, on != me, "on a core that is not this one")
		shot_before := shoots_sent(r.cores)
		before := sched.cpu_stats(on).shot

		sent_at := sched.ticks()
		/*
		The fault is the proof, and the program survives it now: a page a
		segment still names is refilled by the fault handler, as Plan 9's
		`fixfault` would, and the program runs on. What the shootdown
		reached is therefore counted rather than mourned -- one more fault
		in ring 3, one more refill -- and the program is taken down after.
		*/
		faults_before := user.stats().faults
		refills_before := user.page_refills
		scheck(&r, mem.unmap_user(prog.space, user.DATA_VA, 1) == .None, "this core unmapped its data page")
		faulted := sync.await(fault_after, &faults_before, PATIENCE)
		r.shot_ticks = sched.ticks() - sent_at
		scheck(&r, faulted, "and the program faulted inside the bound")
		scheck(
			&r,
			user.page_refills > refills_before && !prog.exit.done,
			"by a page fault in ring 3 the kernel refilled from its segment, and it ran on",
		)
		// Summed over the cores rather than read for `me`: the sender waits
		// for the answer with interrupts on, and a thread that waits may be
		// placed afresh on another core, which is what `me` stops naming.
		scheck(&r, shoots_sent(r.cores) > shot_before, "which a core asked for")
		scheck(&r, sched.cpu_stats(on).shot > before, "and the other core answered")
		scheck(&r, user.end(prog, PATIENCE), "and the program, still running, was ended")
		scheck(&r, user.destroy(prog), "and taken down")
	}

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
		libodin.put_str(&sink, " ticks, ")
		libodin.put_uint(&sink, u64(r.claims))
		libodin.put_str(&sink, " process slots claimed across cores, ")
		libodin.put_uint(&sink, u64(r.lines))
		libodin.put_str(&sink, " log lines whole, an unmap reached another core's TLB in ")
		libodin.put_uint(&sink, r.shot_ticks)
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

// fault_after is whether ring 3 has faulted since the count `arg` names.
@(private = "file")
fault_after :: proc "contextless" (arg: rawptr) -> bool {
	return user.stats().faults > (^int)(arg)^
}
