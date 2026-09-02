/*
The scheduler self-test, run on the machine that will use it.

Four questions, in the order they can be answered:

  1. Does a switch work at all, and does round-robin actually rotate?
  2. Does priority order dispatch, strictly?
  3. Does blocking take a thread off the queue, and does waking it boost it?
  4. Does the timer preempt a thread that never yields -- and do all of them
     still make progress afterwards?

The first three run before the timer is armed, on purpose. A cooperative
scheduler is deterministic: the same spawns produce the same sequence every
time, so a failure is reproducible and a passing run means something. Adding an
asynchronous interrupt source to a scheduler that has not been shown to switch
correctly makes every subsequent bug two bugs.

Everything shared with a worker thread goes through `volatile_load` and
`volatile_store`. These are real concurrent variables now. The compiler has no
reason to believe a spin loop's condition can change. Without the volatile it is
entitled to hoist the load, and spin forever.
*/
package sched

import "vsys:libodin"
import "base:intrinsics"

import "kernel:mem"
import "kernel:sync"

WORKER_COUNT :: 3
COOP_ROUNDS :: 32

// How many yields the boot thread will spend waiting for something before
// giving up and failing the check. Generous: the point of the bound is that a
// broken scheduler fails a self-test rather than hanging the boot with no
// output at all.
MAX_WAIT_YIELDS :: 4096

// Ticks to let the spinners run. At 1 kHz and a ten-tick slice, this is a few
// dozen slices. That is enough for every worker to reach a core several times,
// and for decay to show.
PREEMPT_TICKS :: 120

Verify_Result :: struct {
	using tally:   libodin.Tally,

	// Reported at boot, not asserted on: what the run actually did.
	switches:      u64,
	fpu_checked:   int, // Accumulators compared across preemption
	preempted:     int, // Workers that were preempted at least once
	min_progress:  u64, // The least any spinner got done -- zero is starvation
	max_progress:  u64,
	decayed_to:    Priority,
}

@(private = "file")
check :: proc(r: ^Verify_Result, ok: bool, what: string) -> bool {
	return libodin.tally(&r.tally, ok, what)
}

// -- Shared state ------------------------------------------------------------

@(private = "file")
progress: [WORKER_COUNT]u64
@(private = "file")
stop: bool

/*
One floating-point sum per worker, computed in registers deliberately held
across preemption.

This is the only test of the FXSAVE the trap tail does, and the first version of
it did not work. It was ordinary Odin, four accumulators in a loop, and it
passed with the FXSAVE removed. An unoptimised build spills every temporary to
the stack after each instruction, so the values sat on the thread's own stack. A
thread's own stack survives by construction, so the check tested nothing. The
disassembly said so plainly, and the check did not.

So the registers are held from assembly instead. `fpu_hold` fills xmm0 through
xmm3 with multiples of a per-worker value. It then spins *inside the asm block*
until something tells it to stop. Those four registers are therefore live across
every preemption the worker takes, which is the exact condition FXSAVE exists
for. The code sums them at the end, and compares against ten times the value.

Different values per worker, so a failure is not merely wrong. It is
recognisably somebody else's.
*/
@(private = "file")
sums: [WORKER_COUNT]f64

/*
fpu_hold loads four XMM registers, spins until `flag`, and sums them back.

    xmm0 = v    xmm1 = 2v    xmm2 = 3v    xmm3 = 4v    ->  out = 10v

The spin is in here rather than in Odin around it, because that is the whole
point. Between the fill and the sum there must be no instruction the compiler
chose. Given one, it will use these registers for something of its own, and
destroy the thing under measurement. The same loop increments `counter`, so
progress and the FPU check come out of the same spin.

All four registers are declared clobbered, so nothing of the compiler's is
living in them across the call either.
*/
@(private = "file")
fpu_hold :: proc "contextless" (value: ^f64, flag: ^bool, out: ^f64, counter: ^u64) {
	asm(rawptr, rawptr, rawptr, rawptr) {
		`
	movsd ($0), %xmm0
	movapd %xmm0, %xmm1
	addsd %xmm0, %xmm1
	movapd %xmm1, %xmm2
	addsd %xmm0, %xmm2
	movapd %xmm2, %xmm3
	addsd %xmm0, %xmm3
1:
	incq ($3)
	cmpb $$0, ($1)
	je 1b
	addsd %xmm1, %xmm0
	addsd %xmm3, %xmm2
	addsd %xmm2, %xmm0
	movsd %xmm0, ($2)
`,
		"r,r,r,r,~{xmm0},~{xmm1},~{xmm2},~{xmm3},~{memory}",
	}(rawptr(value), rawptr(flag), rawptr(out), rawptr(counter))
}
@(private = "file")
order: [4]int
@(private = "file")
order_len: int
@(private = "file")
woke: bool

@(private = "file")
bump :: proc "contextless" (index: int) #no_bounds_check {
	intrinsics.volatile_store(&progress[index], intrinsics.volatile_load(&progress[index]) + 1)
}

@(private = "file")
read_progress :: proc "contextless" (index: int) -> u64 #no_bounds_check {
	return intrinsics.volatile_load(&progress[index])
}

@(private = "file")
record :: proc "contextless" (id: int) #no_bounds_check {
	n := intrinsics.volatile_load(&order_len)
	if n < len(order) {
		intrinsics.volatile_store(&order[n], id)
		intrinsics.volatile_store(&order_len, n + 1)
	}
}

// -- Worker bodies -----------------------------------------------------------

// Yields between every increment, so a working round-robin interleaves all
// three and a broken one runs them to completion in turn. The counters do not
// distinguish those, but the switch count does.
@(private = "file")
coop_worker :: proc "contextless" (arg: rawptr) {
	index := int(uintptr(arg))
	for _ in 0 ..< COOP_ROUNDS {
		bump(index)
		yield()
	}
}

/*
Never yields, and holds floating-point state while not yielding.

Only the timer can take this off the core, which is the first half of what this
checks. `fpu_hold` is the second. Both come out of the same spin.
*/
@(private = "file")
spin_worker :: proc "contextless" (arg: rawptr) #no_bounds_check {
	index := int(uintptr(arg))
	value := f64(index) + 1
	fpu_hold(&value, &stop, &sums[index], &progress[index])
}

@(private = "file")
order_worker :: proc "contextless" (arg: rawptr) {
	record(int(uintptr(arg)))
}

@(private = "file")
blocking_worker :: proc "contextless" (arg: rawptr) {
	_ = arg
	block()
	intrinsics.volatile_store(&woke, true)
}

// -- Helpers -----------------------------------------------------------------

@(private = "file")
wait_until_dead :: proc(threads: []^Thread) -> bool {
	for _ in 0 ..< MAX_WAIT_YIELDS {
		all_done := true
		for t in threads {
			if t.state != .Dead {
				all_done = false
			}
		}
		if all_done {
			return true
		}
		yield()
	}
	return false
}

@(private = "file")
wait_until_blocked :: proc(t: ^Thread) -> bool {
	for _ in 0 ..< MAX_WAIT_YIELDS {
		if t.state == .Blocked {
			return true
		}
		yield()
	}
	return false
}

// -- The test ----------------------------------------------------------------

/*
verify runs the cooperative half: switching, round-robin, priority, blocking.

Must be called after `init` and before `start_timer`. Every thread it creates
is dead and reaped before it returns, so the machine is left as it was found.
*/
verify :: proc() -> Verify_Result {
	r: Verify_Result

	if !check(&r, current() != nil, "the boot context was adopted as a thread") {
		return r
	}
	check(&r, cpu().idle != nil, "the core has an idle thread")
	check(&r, cpu().idle.prio == PRIORITY_IDLE, "the idle thread sits below everything")

	before := stats().switches
	verify_round_robin(&r)
	r.switches = stats().switches - before

	verify_priority_order(&r)
	verify_block_and_boost(&r)

	reap()
	return r
}

/*
verify_round_robin runs three threads that yield between every increment.

The counters prove they all finished. The switch count proves they took turns
rather than ran one after another. Three threads that yield `COOP_ROUNDS` times
each cannot finish in fewer than that many switches. A scheduler that ran each
to completion would show far fewer.
*/
@(private = "file")
verify_round_robin :: proc(r: ^Verify_Result) {
	threads: [WORKER_COUNT]^Thread
	for i in 0 ..< WORKER_COUNT {
		intrinsics.volatile_store(&progress[i], 0)
		threads[i] = spawn("coop", coop_worker, rawptr(uintptr(i)))
		if !check(r, threads[i] != nil, "spawn a cooperative worker") {
			return
		}
	}

	if !check(r, wait_until_dead(threads[:]), "every cooperative worker finished") {
		return
	}

	all_complete := true
	for i in 0 ..< WORKER_COUNT {
		if read_progress(i) != COOP_ROUNDS {
			all_complete = false
		}
	}
	check(r, all_complete, "each worker ran to completion")
	check(
		r,
		stats().switches >= u64(WORKER_COUNT * COOP_ROUNDS),
		"the workers took turns rather than running in sequence",
	)
}

/*
verify_priority_order checks that a higher level wins, strictly.

Both threads are spawned above the boot thread, and the higher of the two must
record itself first. High-then-low would pass by accident on a scheduler that
ignored priority entirely, so they are spawned low first. A FIFO with no
priority in it would record 20 before 21.
*/
@(private = "file")
verify_priority_order :: proc(r: ^Verify_Result) {
	intrinsics.volatile_store(&order_len, 0)

	low := spawn("prio-low", order_worker, rawptr(uintptr(20)), PRIORITY_NORMAL + 2)
	high := spawn("prio-high", order_worker, rawptr(uintptr(21)), PRIORITY_NORMAL + 4)
	if !check(r, low != nil && high != nil, "spawn the priority pair") {
		return
	}

	if !check(r, wait_until_dead({low, high}), "both priority workers finished") {
		return
	}
	if !check(r, intrinsics.volatile_load(&order_len) == 2, "both recorded themselves") {
		return
	}
	check(r, intrinsics.volatile_load(&order[0]) == 21, "the higher priority ran first")
	check(r, intrinsics.volatile_load(&order[1]) == 20, "the lower priority ran second")
}

/*
verify_block_and_boost is the anti-starvation mechanism, in miniature.

A blocked thread must be off every queue. Merely marked, it would keep reaching
a core, and `block` would be a busy wait. And a woken thread must come back
*above* where it started. That is the whole of what keeps an interactive thread
responsive against a compute-bound one.
*/
@(private = "file")
verify_block_and_boost :: proc(r: ^Verify_Result) {
	intrinsics.volatile_store(&woke, false)

	t := spawn("blocker", blocking_worker)
	if !check(r, t != nil, "spawn a blocking worker") {
		return
	}
	if !check(r, wait_until_blocked(t), "the worker blocked") {
		return
	}

	check(r, ready_count(cpu()) == 0, "a blocked thread is on no queue")

	ready(t)
	check(r, t.state == .Ready, "waking makes it runnable")
	check(r, t.prio == t.base + 1, "waking boosts it above its base")

	if !check(r, wait_until_dead({t}), "the woken worker ran and finished") {
		return
	}
	check(r, intrinsics.volatile_load(&woke), "it ran past the block")
}

/*
verify_preemption is the other half, and needs the timer already running.

Three threads that never yield. On a kernel with no preemption, the first one to
reach a core runs forever and this never returns. That is why the boot thread
waits on the tick count rather than on the workers, and why ticks bound the wait
rather than iterations.

This asserts two different things. A worker that something preempted proves the
timer interrupts and switches. A worker that made progress proves the
round-robin still turns under preemption. A scheduler that preempted correctly,
and then always re-picked the same thread, would pass the first and fail the
second.
*/
verify_preemption :: proc(r: ^Verify_Result) {
	for i in 0 ..< WORKER_COUNT {
		intrinsics.volatile_store(&progress[i], 0)
		intrinsics.volatile_store(&sums[i], 0)
	}
	intrinsics.volatile_store(&stop, false)

	threads: [WORKER_COUNT]^Thread
	for i in 0 ..< WORKER_COUNT {
		threads[i] = spawn("spin", spin_worker, rawptr(uintptr(i)))
		if !check(r, threads[i] != nil, "spawn a spinning worker") {
			return
		}
	}

	// The wait is on the clock, not on the workers. Nothing here can ask them
	// to stop until the timer gets a chance to take them off the core.
	start := ticks()
	if !check(r, start > 0 || timer_hz > 0, "the timer is running") {
		return
	}
	/*
	Deliberately not a yield. The boot thread is a fourth compute-bound thread
	for the duration. This therefore asks the round-robin to share the core
	four ways, rather than hands it back voluntarily.

	Bounded by liveness rather than by iterations, because iterations are not a
	unit anything here knows the length of. Every `STALL_SPINS` times round,
	the tick count must move. A spin that long is orders of magnitude longer
	than a millisecond on any machine that can boot this. A live timer
	therefore always moves it. This catches a stopped timer in one window
	instead of never.

	That bound is not hypothetical. Remove the EOI from the tick handler, one
	line, and the local APIC delivers nothing further. Without this bound the
	boot hung here, and the last line printed was the timer's own success. A
	self-test that hangs is worse than one that fails. It says
	nothing, and it says it in the place hardest to attach a debugger to.
	*/
	STALL_SPINS :: 20_000_000

	deadline := start + PREEMPT_TICKS
	last := start
	spins := 0
	stalled := false

	for ticks() < deadline {
		spins += 1
		if spins < STALL_SPINS {
			continue
		}
		now := ticks()
		if now == last {
			stalled = true
			break
		}
		last = now
		spins = 0
	}

	// Set before the check below returns, so the workers can finish either
	// way. Once this is true they leave their spin the next time they reach a
	// core. A `yield` gives them one even with no timer at all.
	intrinsics.volatile_store(&stop, true)
	check(r, !stalled, "the timer went on ticking")
	if !check(r, wait_until_dead(threads[:]), "every spinning worker stopped") {
		return
	}

	r.min_progress = max(u64)
	preempted := 0
	all_ran := true
	for i in 0 ..< WORKER_COUNT {
		got := read_progress(i)
		r.min_progress = min(r.min_progress, got)
		r.max_progress = max(r.max_progress, got)
		if got == 0 {
			all_ran = false
		}
		if threads[i].preemptions > 0 {
			preempted += 1
		}
		r.decayed_to = max(r.decayed_to, threads[i].prio)
	}
	r.preempted = preempted

	check(r, preempted == WORKER_COUNT, "every spinning worker was preempted")
	check(r, all_ran, "no spinning worker starved")
	verify_fpu(r)
	check(r, stats().preemptions > 0, "the core recorded preemptions")
	check(
		r,
		r.decayed_to < PRIORITY_NORMAL,
		"burning full slices decayed the workers below their base",
	)

	reap()
}

/*
verify_idle_reap is the idle thread giving a dead thread's stack back, with
nothing spawning and nothing asking.

A thread that returns at once is dead within a tick. The checker parks for
two, which is what lets the idle thread run at all: idle runs only when
nothing else can. Then the reap list has to be empty and the heap has to be
where it was. Neither `spawn` nor `reap` was called between the two
readings.

Every other self-test that brackets the heap still calls `reap` by hand
first. A reading taken before the idle thread's turn would be wrong for a
reason that is not a leak. A bracket that depends on timing is not a
bracket.
*/
verify_idle_reap :: proc(r: ^Verify_Result) {
	reap()
	before := mem.live_objects(mem.heap_stats())
	t := spawn("brief", brief_worker)
	if !check(r, t != nil, "a thread that returns at once is spawned") {
		return
	}
	check(r, mem.live_objects(mem.heap_stats()) > before, "and costs the heap a record and a stack")

	// Parked, so the worker runs and dies, and then the idle thread runs
	// because nothing else can. `yield` would not do: a checker that spins
	// is a thread that is always runnable, and idle would never get a turn.
	sync.delay(2)
	check(r, reap_pending() == 0, "two ticks later nothing waits on the reap list")
	check(
		r,
		mem.live_objects(mem.heap_stats()) == before,
		"and the heap has its record and stack back, with no spawn and no reap asked for",
	)
}

@(private = "file")
brief_worker :: proc "contextless" (arg: rawptr) {
	_ = arg
}

/*
verify_fpu checks that preemption preserved each worker's XMM registers.

Every worker filled xmm0..xmm3 with v, 2v, 3v and 4v, and held them across every
preemption it took, so the sum can only be 10v. A trap tail that did not save
them would leave a worker to resume with whatever the previous thread had. More
often, that is whatever the scheduler itself last put in xmm0.

Exact comparison. There is no rounding anywhere in this, so a tolerance would
only serve to hide the thing being looked for.
*/
@(private = "file")
verify_fpu :: proc(r: ^Verify_Result) #no_bounds_check {
	intact := true
	for i in 0 ..< WORKER_COUNT {
		want := (f64(i) + 1) * 10
		if intrinsics.volatile_load(&sums[i]) != want {
			intact = false
		}
		r.fpu_checked += 1
	}
	check(r, intact, "preemption preserved every worker's floating-point registers")
}
