/*
Ring 3, and the five ways out of it.

**A program runs, the kernel keeps running under it, and everything the program
tries that it may not do is refused.** Every check here is one of those three
sentences.

The order is not arbitrary. `spin` comes first because it is the only one that
proves ring 3 *works* rather than that it is enforced. A machine where the
`iretq` never took the privilege change still passes four of the five refusal
tests, by faulting for the wrong reason. It fails this one, and nothing else.

## Why each program faults, and why that is the design

There is no system call yet, so a program cannot ask to stop. The only way out
of ring 3 is an instruction the CPU refuses. Four of the five programs end on
the instruction the test is about. `spin` ends on a `ud2` it reaches on
purpose, which makes it the control for the other four. Ending is not what the
checks measure.

## What the kernel checks that a program cannot see

Three things, and each is read from the kernel side of a boundary the program
never crosses:

  - The mark in the data page, through the direct map. The program wrote it in
    ring 3, at an address that means nothing in the kernel's space.
  - The frame the CPU pushed, which has to be inside the faulting thread's own
    kernel stack. That is the TSS, tested by its effect rather than by reading
    the slot back.
  - The kernel's own global, which a program tried to write and did not.
*/
package user

import "kernel:arch"
import "kernel:mem"
import "kernel:sched"
import "kernel:sync"

/*
The page fault error code, in the bits `describe_error` turns into words.

Written out here rather than shared, because the two uses are different claims.
`describe_error` renders whatever the CPU reported. These are what the test says
the CPU *must* report. A test that read its expectation from the code under test
would agree with itself.
*/
@(private = "file") PF_PRESENT :: u64(1) << 0
@(private = "file") PF_WRITE :: u64(1) << 1
@(private = "file") PF_USER :: u64(1) << 2
@(private = "file") PF_FETCH :: u64(1) << 4

/*
A kernel global for a program to fail to reach.

An ordinary variable in the kernel's `.bss`, in the higher half, mapped and
writable by the kernel. Every address space has it, because every address space
shares the kernel's upper half. **The only thing between it and a program is
the `User` bit**, which is exactly the claim under test.

Not a constant, and read through `volatile_load`, so the compiler answers from
memory rather than from what it can prove about the value.
*/
@(private = "file")
kernel_witness: u64 = 0x1234_5678_9ABC_DEF0

@(private = "file")
PATIENCE :: 200

// How long to watch `spin` run before telling it to stop. Long enough for the
// timer to preempt it many times, short enough to be noise in a boot.
@(private = "file")
WATCH_TICKS :: 20

/*
What the run found, for `kernel/main.odin` to put on one line.

Returned rather than printed, the same way every other subsystem's self-test
does it. This package has no logger and should not grow one: it is the layer a
fault handler runs in.
*/
Result :: struct {
	checks:        int,
	failures:      int,
	first_failure: string,
	programs:      int,
	traps:         u64, // Returns from ring 3 while the checks ran
	rounds:        u64, // Times `spin` went round its loop in ring 3
}

@(private = "file")
check :: proc "contextless" (r: ^Result, ok: bool, what: string) -> bool {
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
run_program loads one blob, waits for it to fault, and checks the three things
that are true of every program however it ended.

The mark says it reached its first instruction. `from_user` says the fault was
taken in ring 3 rather than in the kernel. The frame address says the CPU
pushed onto the stack the TSS named.

Returns the program with its space and frames still held, because the caller
has checks left to make against them. Every caller destroys it.
*/
@(private = "file")
run_program :: proc(
	r: ^Result,
	name: string,
	code: []u8,
	mark: u64,
	arg: u64,
	what: string,
) -> ^Program {
	p, err := load(name, code, arg)
	if !check(r, err == .None && p != nil, what) {
		return nil
	}
	r.programs += 1

	if !check(r, wait(p, PATIENCE), "and it comes back") {
		return p
	}

	check(r, cell(p, CELL_MARK) == mark, "having reached its first instruction")
	check(r, p.exit.from_user, "and taken its fault in ring 3, by the selector the CPU pushed")
	/*
	The program counter is in the half a program is given, and the check is
	deliberately no sharper than that here.

	Four of the five faulted on an instruction in their own text, and each of
	those says so for itself. `jump` did not: a fault on an instruction *fetch*
	reports the address being fetched, which for that program is the data page
	it was refused. Both are addresses only a program can name.
	*/
	check(r, p.exit.ip >= TEXT_VA && p.exit.ip < mem.USER_MAX, "at an address in its own half of the space")
	check(r, p.exit.sp == STACK_TOP, "on the stack it was given, in its own space")

	/*
	And the kernel's frame landed on the kernel's stack.

	This is the TSS, checked by what it did rather than by reading the slot
	back. A read of `arch.kernel_stack()` would agree with whatever the
	scheduler last wrote, which is the field the code under test also maintains.
	Where the CPU actually pushed is not.
	*/
	check(
		r,
		p.exit.kstack > p.kstack_lo && p.exit.kstack < p.kstack_hi,
		"and the frame it pushed is inside that thread's kernel stack",
	)
	return p
}

// in_text asks whether a program stopped on one of its own instructions. Four
// of the five did. `jump` stopped on the address it was fetching from, which is
// the point of that one.
@(private = "file")
in_text :: proc "contextless" (p: ^Program, code: []u8) -> bool {
	return p.exit.ip >= TEXT_VA && p.exit.ip < TEXT_VA + uintptr(len(code))
}

@(private = "file")
finish :: proc "contextless" (r: ^Result, p: ^Program, what: string) {
	if p == nil {
		return
	}
	check(r, destroy(p), what)
}

verify :: proc() -> (r: Result) {

	before_tables := mem.space_stats()
	before_doubles := mem.pmm_stats().double_frees
	before_traps := arch.user_trap_count()

	// The three frames of the last program to run, kept so the teardown can be
	// checked frame by frame rather than by a total. See `mem.frame_is_free`.
	held: [3]uintptr

	// -- What the machine has before a program runs --------------------------

	check(&r, len(program_spin()) > 0, "five programs are baked into the image")
	check(&r, len(program_spin()) <= arch.PAGE_SIZE, "and each fits the page it is copied into")
	check(
		&r,
		arch.kernel_stack() != 0,
		"the scheduler has put a kernel stack in the TSS, which a trap from ring 3 needs",
	)
	check(
		&r,
		sched.spawn_user("no-space", nil, TEXT_VA, STACK_TOP) == nil,
		"and a program with no address space of its own is refused",
	)

	// -- A program runs, and the kernel keeps running under it ---------------

	verify_spin(&r)

	// -- The kernel half is not a program's to write -------------------------

	witness := uintptr(rawptr(&kernel_witness))
	was := kernel_witness

	p := run_program(&r, "poke-kernel", program_poke(), MARK_POKE, u64(witness), "a program writes to the kernel")
	if p != nil && p.exit.done {
		check(&r, p.exit.kind == .Page_Fault, "and takes a page fault")
		check(&r, p.exit.address == witness, "at the address it named")
		check(
			&r,
			p.exit.error_code & (PF_PRESENT | PF_WRITE | PF_USER) ==
			PF_PRESENT | PF_WRITE | PF_USER,
			"which the CPU reports as a user write to a page that is present",
		)
		check(&r, kernel_witness == was, "and the kernel's own word is what it was")
		check(&r, in_text(p, program_poke()), "with the program counter still on its own instruction")
	}
	finish(&r, p, "the program is taken down")

	// -- Nor to read ---------------------------------------------------------

	p = run_program(&r, "peek-kernel", program_peek(), MARK_PEEK, u64(witness), "a program reads the kernel")
	if p != nil && p.exit.done {
		check(&r, p.exit.kind == .Page_Fault, "and takes a page fault for that too")
		check(
			&r,
			p.exit.error_code & PF_WRITE == 0 && p.exit.error_code & PF_USER != 0,
			"reported as a read rather than a write, so the User bit stops both",
		)
		check(&r, cell(p, 1) == 0, "and the word it wanted never reached its own page")
		check(&r, in_text(p, program_peek()), "with the program counter still on its own instruction")
	}
	finish(&r, p, "and taken down")

	// -- A program's text is its own, and read-only --------------------------

	p = run_program(&r, "poke-text", program_poke(), MARK_POKE, u64(TEXT_VA), "a program writes to its own text")
	if p != nil && p.exit.done {
		check(&r, p.exit.kind == .Page_Fault, "and faults on a page it can read and execute")
		check(&r, p.exit.address == TEXT_VA, "at the first byte of it")
		check(
			&r,
			p.exit.error_code & (PF_PRESENT | PF_WRITE) == PF_PRESENT | PF_WRITE,
			"which is a write to a present page rather than a missing one",
		)
		first := (cast([^]u8)mem.phys_to_virt(p.text))[0]
		check(&r, first == program_poke()[0], "and the instruction it tried to write over is intact")
	}
	finish(&r, p, "and taken down")

	// -- A program may not turn the interrupts off ---------------------------

	before_ticks := sched.ticks()
	p = run_program(&r, "priv", program_priv(), MARK_PRIV, 0, "a program masks interrupts")
	if p != nil && p.exit.done {
		check(&r, p.exit.kind == .Protection_Fault, "and takes a general protection fault")
		check(&r, p.exit.error_code == 0, "with no selector, because the fault had none")
		sync.delay(2)
		check(&r, sched.ticks() > before_ticks, "and the clock is still running, so the mask never took")
		check(&r, in_text(p, program_priv()), "with the program counter on the instruction it was refused")
	}
	finish(&r, p, "and taken down")

	// -- A program's data is not code ----------------------------------------

	p = run_program(&r, "jump-data", program_jump(), MARK_JUMP, u64(DATA_VA), "a program jumps into its own data")
	if p != nil && p.exit.done {
		check(&r, p.exit.kind == .Page_Fault, "and faults on a page it can read and write")
		check(&r, p.exit.address == DATA_VA, "at the address it jumped to")
		check(
			&r,
			p.exit.error_code & PF_FETCH != 0,
			"which the CPU reports as an instruction fetch, so No_Execute is what refused it",
		)
		check(&r, !in_text(p, program_jump()), "and the program counter is off its text, where it jumped")
	}
	if p != nil {
		held = {p.text, p.data, p.stack}
		check(
			&r,
			!mem.frame_is_free(held[0]) && !mem.frame_is_free(held[1]) && !mem.frame_is_free(held[2]),
			"a program holds three frames while it exists",
		)
	}
	finish(&r, p, "and taken down")

	// -- What is left ---------------------------------------------------------

	r.traps = arch.user_trap_count() - before_traps
	check(&r, r.traps > 0, "the machine came back out of ring 3")

	s := stats()
	check(&r, s.live == 0, "every program was taken down")
	check(&r, s.faults >= r.programs, "each of them by a fault")

	/*
	Frames last, and by name rather than by total.

	A total would be measuring the heap. Every program spawns a thread and a
	thread's stack comes from the heap. The heap takes frames from the physical
	allocator and never gives them back. `verify_space` hit the same wall, and
	answered it with a phase that has no threads in it. There is no such phase
	here, because a program *is* a thread.

	So the question is asked about the three frames the last program held, which
	is exact and does not care what else allocated.
	*/
	sched.reap()
	check(
		&r,
		mem.frame_is_free(held[0]) && mem.frame_is_free(held[1]) && mem.frame_is_free(held[2]),
		"and gave back the three frames it held",
	)

	after_tables := mem.space_stats()
	check(&r, after_tables.live == before_tables.live, "every address space was destroyed")
	check(&r, after_tables.frames == before_tables.frames, "and gave back every page table it grew")
	check(
		&r,
		mem.pmm_stats().double_frees == before_doubles,
		"and nothing twice",
	)

	return r
}

/*
verify_spin is the half that shows ring 3 running rather than being refused.

Three claims, and the second is the one that needs the care.

The program's counter moves, which says its instructions execute. It moves
*while the boot thread also runs*, and on one core that is the definition of
preemption. Both cannot make progress in the same ticks otherwise. The kernel
can also write a word the program then reads, which says the mapping is shared
rather than copied, in both directions.

The stop word is what ends it. `spin` also gives up on its own after four
hundred million rounds, and that safety net is not decoration. A program entered
with interrupts masked cannot be preempted, so no bound the observer holds can
survive it. The observer is not scheduled. See `docs/TESTING.md`.
*/
@(private = "file")
verify_spin :: proc(r: ^Result) {
	p, err := load("spin", program_spin(), 0)
	if !check(r, err == .None && p != nil, "a program is loaded into a space of its own") {
		return
	}
	r.programs += 1

	// Wait for the mark rather than assume it. The program writes nothing until
	// something dispatches it, and that is a scheduler decision.
	started := false
	for _ in 0 ..< PATIENCE {
		if cell(p, CELL_MARK) == MARK_SPIN {
			started = true
			break
		}
		sync.delay(1)
	}
	check(r, started, "and runs, which is the first instruction ever executed in ring 3")

	first := cell(p, CELL_COUNTER)
	traps_before := arch.user_trap_count()
	sync.delay(WATCH_TICKS)
	second := cell(p, CELL_COUNTER)

	r.rounds = second - first
	check(r, second > first, "its counter moves, so it is running rather than parked")
	check(
		r,
		arch.user_trap_count() > traps_before,
		"and the machine came back out of ring 3 while it did, which is a preemption",
	)

	/*
	The boot thread ran through all of those ticks and the program ran between
	them. On one core that is not two things happening: it is the timer taking
	the core away from ring 3 and giving it back.
	*/
	check(r, sched.stats().space_switches > 0, "on a core the two of them share")

	/*
	And the kernel will not take it down while it runs.

	Checked here rather than left as a guard nothing reaches. The space is the
	tree the machine would translate through if this thread ran again. The frames
	are pages it writes to as this line executes. There is no way to stop a
	program yet, so keeping them is the only safe answer. See `destroy`.
	*/
	check(r, !destroy(p), "and the kernel will not take it down while it is still running")

	// The other direction of the same page. The kernel writes, the program
	// reads, and what it does about it is stop.
	set_cell(p, CELL_STOP, 1)
	check(r, wait(p, PATIENCE), "a word the kernel writes reaches it, and ends it")
	check(r, p.exit.kind == .Invalid_Instruction, "on the instruction it runs to say so")
	check(r, p.exit.from_user, "in ring 3")
	check(
		r,
		cell(p, CELL_COUNTER) >= second,
		"having gone round more times than the kernel last looked",
	)
	// And fewer than its own safety net allows, which is the claim that the
	// kernel is what stopped it. See `SPIN_LIMIT`.
	check(
		r,
		cell(p, CELL_COUNTER) < SPIN_LIMIT,
		"because the kernel said so, rather than because it ran out of patience",
	)
	check(r, destroy(p), "and it is taken down")
}
