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

import "vsys:libodin"
import "base:intrinsics"
import "base:runtime"

import "kernel:arch"
import "kernel:devfs"
import "kernel:drivers/fb"
import "kernel:mem"
import "kernel:pipe"
import "kernel:sched"
import "kernel:srv"
import "kernel:sync"
import "kernel:vfs"
import "vsys:libdraw"
import "vsys:libfont"
import "vsys:vectra9"

/*
The page fault error code, in the bits `describe_error` turns into words.

Written out here rather than shared, because the two uses are different claims.
`describe_error` renders whatever the CPU reported. These are what the test says
the CPU *must* report. A test that read its expectation from the code under test
would agree with itself.
*/
/*
refused turns an errno into the bit pattern a program sees in `rax`.

A system call answers with a signed number, and a program stores whatever
lands in an unsigned register. So the check has to compare the same bits the
program kept, rather than a sign the program never had.

Written out rather than folded, because Odin will not fold a negative constant
into a `u64` and it is right not to. A run-time cast of a run-time value says
the same thing and compiles.
*/
@(private = "file")
refused :: proc "contextless" (e: vectra9.Errno) -> u64 {
	value := -i64(u32(e))
	return u64(value)
}

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
WITNESS :: u64(0x1234_5678_9ABC_DEF0)

@(private = "file")
kernel_witness: u64 = WITNESS

/*
Where `verify_shadow` maps a page a program may name and may not touch.

In the lower half, so `copy_in`'s range check has nothing to say about it. That
is the whole point: it leaves the `User` check as the only thing that can
refuse.
*/
@(private = "file")
SHADOW_VA :: uintptr(0x0050_0000)

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
	using tally:   libodin.Tally,
	programs:      int,
	spawned:       int, // Of those, started by another process
	traps:         u64, // Returns from ring 3 while the checks ran
	rounds:        u64, // Times `spin` went round its loop in ring 3
	calls:         int, // System calls the programs made
	answered:      u64, // 9P requests a process served over a wire
	pinned:        int, // Heap objects the wires still pin -- zero since the counted release
	leaked:        int, // Heap objects the run did not give back
}

@(private = "file")
check :: proc "contextless" (r: ^Result, ok: bool, what: string) -> bool {
	return libodin.tally(&r.tally, ok, what)
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
) -> ^Process {
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
in_text :: proc "contextless" (p: ^Process, code: []u8) -> bool {
	return p.exit.ip >= TEXT_VA && p.exit.ip < TEXT_VA + uintptr(len(code))
}

@(private = "file")
finish :: proc(r: ^Result, p: ^Process, what: string) {
	if p == nil {
		return
	}
	check(r, destroy(p), what)
}

/*
verify runs every program and checks what each one was allowed to do.

`column` is the console's cursor column, read from `kernel/main.odin`, which is
the only place that owns the console. It is a parameter rather than an import
because the console is a screen and this is the layer a fault handler lives in.

It is also the one check here that watches the screen rather than a number.
`docs/TESTING.md` has three milestones' worth of reasons for that.
*/
verify :: proc(column: proc "contextless" () -> int) -> (r: Result) {

	/*
	The reap list is drained before the heap is measured, and that is not
	tidiness.

	Threads that exited in an earlier self-test keep their records and their
	stacks until something asks for them back. The first reading would count
	those and the last would not. The difference came out as **minus four
	objects**, which is a run that gave back more than it took. A bracket that
	can go negative is not measuring what it says.
	*/
	sched.reap()
	before_heap := mem.live_objects(mem.heap_stats())
	before_tables := mem.space_stats()
	before_doubles := mem.pmm_stats().double_frees
	before_traps := arch.user_trap_count()
	before_segs := segment_stats()

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
	check(&r, arch.syscall_armed(), "the syscall instruction is armed and points at the stub")
	check(
		&r,
		arch.percpu_id() == 0,
		"and this core's own record answers through GS, which is where the stub finds a stack",
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
	finish(&r, p, "and taken down")

	// -- And a program that asks rather than is refused ----------------------

	verify_syscalls(&r, column, &held)

	// -- And a process, which is a space, a namespace and some open files ----

	verify_processes(&r, column, &held)

	// -- And a process that reaches the hardware -----------------------------

	verify_painter(&r)
	verify_bulkio(&r)
	verify_scancode_reader(&r)

	// -- And a process that starts another one -------------------------------

	verify_loading(&r, column)
	verify_parenthood(&r, column, &held)

	// -- And a process that publishes a service ------------------------------

	verify_posting(&r, column, &held)

	// -- And a process that *answers* one ------------------------------------

	verify_service_answered(&r, column)

	// -- And a program a compiler built, doing the same ----------------------

	verify_runtime(&r, column)

	// -- And an ending delivered from outside --------------------------------

	verify_notes(&r)

	// -- And a note a process catches, and survives ----------------------------

	verify_handler(&r)

	// -- And a process that continues from the call site ----------------------

	verify_rfork(&r)

	// -- And a process that replaces itself -----------------------------------

	verify_exec(&r, column)

	// -- And a child no parent waits for --------------------------------------

	verify_reap(&r)

	// -- And a server that waits on two things at once -------------------------

	verify_consrv(&r)

	// -- And a kernel service rebuilt as a program ----------------------------

	verify_kbdfs(&r)

	// -- And the port itself, served from ring 3 ------------------------------

	verify_eiafs(&r)

	// -- And the screen, spoken to in verbs -----------------------------------

	verify_draw(&r)

	// -- And the memory the draw server draws through ------------------------

	verify_mapping(&r)

	// -- And the first app, a client of that server ---------------------------

	verify_terminal(&r, column)

	// -- What is left ---------------------------------------------------------

	r.traps = arch.user_trap_count() - before_traps
	check(&r, r.traps > 0, "the machine came back out of ring 3")

	s := stats()
	r.calls = s.calls
	r.spawned = s.spawned
	check(&r, s.live == 0, "every program was taken down")
	check(&r, s.faults + s.calls >= r.programs, "each of them by a fault or by asking")

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

	/*
	The heap, which is where a namespace and a descriptor live.

	Frames say nothing about either. A chan and a `Namespace` are heap objects.
	A process that gave back its pages and kept its open files leaves the frame
	count balanced and the object count wrong. This is the only check in the
	file that would notice.

	`sched.reap` runs above it, because a dead thread's stack is a heap object
	too and nothing gives it back until something asks.
	*/
	r.leaked = mem.live_objects(mem.heap_stats()) - before_heap - r.pinned
	check(&r, r.leaked == 0, "and every namespace and open file beyond the wire's deliberate pin")

	after_tables := mem.space_stats()
	check(&r, after_tables.live == before_tables.live, "every address space was destroyed")
	check(&r, after_tables.frames == before_tables.frames, "and gave back every page table it grew")
	check(
		&r,
		mem.pmm_stats().double_frees == before_doubles,
		"and nothing twice",
	)

	after_segs := segment_stats()
	check(&r, after_segs.live == before_segs.live, "every segment was released")
	check(&r, after_segs.frames == before_segs.frames, "and owns no frame it did before")

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

/*
The message `hello` prints, and the only thing in this file a person sees.

No newline. The check on the other side counts console columns, and a newline
would reset the count to zero. `cons_finish` ends the line afterwards, which is
the same split `kernel/devfs/verify.odin` makes for the same reason.
*/
@(private = "file")
MESSAGE :: "-- a program in ring 3 wrote this line"

/*
verify_syscalls runs the two programs that ask the kernel for something.

`hello` is the short one and the one worth reading. It writes a line to
`/dev/cons` and exits with a status. That one sentence crosses every layer the
kernel has. Ring 3, the syscall stub, a copy out of a program's memory, a 9P
write over the real transport, a device server, and the console. **The line it
prints is in the boot log**, which is the shortest proof any of it works.

`probe` is the long one. It makes six calls and stores every answer, so a wrong
one names the call rather than the program.

`held` comes back with the last program's three frames, so the teardown check
outside can ask about frames rather than about a total.
*/
@(private = "file")
verify_syscalls :: proc(r: ^Result, column: proc "contextless" () -> int, held: ^[3]uintptr) {
	// -- A program writes a line to the console ------------------------------

	p, err := load_held("hello", program_hello())
	if !check(r, err == .None && p != nil, "a program is loaded that asks rather than faults") {
		return
	}
	r.programs += 1
	check(r, set_bytes(p, MESSAGE_OFFSET, bytes_of(MESSAGE)), "with a line in its data page")

	before := column()
	// Staged, and only now a thread. A launch before the staging is a race
	// the program sometimes wins, and a flake found it winning.
	check(r, launch(p, u64(len(MESSAGE))), "and it launches")
	if check(r, wait(p, PATIENCE), "and it comes back") {
		after := column()

		check(r, cell(p, CELL_MARK) == MARK_HELLO, "having reached its first instruction")
		check(
			r,
			cell(p, CELL_WROTE) == u64(len(MESSAGE)),
			"the write it asked for reported every byte",
		)
		/*
		And the bytes are on the screen.

		The count above is the syscall's own answer, which rises whether or not
		a glyph is drawn. The console's cursor is one layer closer to the
		effect, and the message carries no newline so the number is exact.
		`docs/TESTING.md` has the three times this file's neighbour learned it.
		*/
		check(r, after - before == len(MESSAGE), "and the console moved that many columns")

		check(r, p.exit.deliberate, "the program ended because it asked to, not because it faulted")
		check(r, p.exit.status == HELLO_STATUS, "with the status it chose")
		check(
			r,
			p.exit.vector == arch.VECTOR_SYSCALL,
			"through the door rather than through the interrupt table",
		)
		check(r, p.exit.from_user, "and the frame it left says ring 3")
		check(r, p.exit.sp == STACK_TOP, "on the stack it was given")
		check(
			r,
			p.exit.kstack > p.kstack_lo && p.exit.kstack < p.kstack_hi,
			"with the kernel's frame on that thread's own kernel stack",
		)
	}
	cons_finish()
	finish(r, p, "the program is taken down")

	// -- And a program that asks for six other things ------------------------

	witness := u64(uintptr(rawptr(&kernel_witness)))
	p, err = load("probe", program_probe(), witness)
	if !check(r, err == .None && p != nil, "a second program makes six calls") {
		return
	}
	r.programs += 1

	if check(r, wait(p, PATIENCE), "and comes back from all of them") {
		check(r, cell(p, CELL_MARK) == MARK_PROBE, "having reached its first instruction")
		check(r, cell(p, CELL_NOP) == 0, "a call that does nothing answers zero")
		check(
			r,
			cell(p, CELL_ARGS) == ARGS_SUM,
			"and one that adds its arguments gets all six of them",
		)
		check(
			r,
			cell(p, CELL_UNKNOWN) == refused(vectra9.ENOSYS),
			"a number nothing implements is refused rather than obeyed",
		)
		check(
			r,
			cell(p, CELL_BAD_ADDRESS) == refused(vectra9.EFAULT),
			"and a kernel address handed in as a buffer is refused",
		)
		check(r, kernel_witness == WITNESS, "with the kernel's own word untouched")

		check(r, cell(p, CELL_SLEPT) == 4, "a call that waits reports what it waited")
		/*
		And it really parked, rather than spun.

		A thread that never blocked has no wake-ups. This is the one number
		that separates a system call which gave the core up from one which held
		it. It comes from the scheduler rather than from the clock.
		*/
		check(r, blocked(p) > 0, "and gave the core up while it did")

		check(r, cell(p, CELL_R8) == KEEP_R8, "a call leaves a caller-saved register alone")
		check(r, cell(p, CELL_R12) == KEEP_R12, "and a callee-saved one")
		check(
			r,
			cell(p, CELL_XMM) == KEEP_XMM,
			"and the floating-point register the dispatcher writes over first",
		)

		/*
		And it kept running in ring 3 after the last call returned.

		`sysret` writes CS and SS out of `STAR` without checking either. A wrong
		user base there produces a program that runs correctly with nonsense in
		CS. The first thing that reads CS is an interrupt. A program that
		returns from a call and exits at once gives nothing a chance to notice.
		That is how a control found this, by passing. See `PROBE_SPIN`.
		*/
		check(r, cell(p, CELL_SPUN) == PROBE_SPIN, "and went on running in ring 3 after the last one returned")

		check(r, p.exit.deliberate && p.exit.status == 0, "and it exits with nothing to report")
	}

	finish(r, p, "and is taken down")

	// -- A page in a program's half that the program may not touch -----------

	verify_shadow(r, held)
}

/*
verify_shadow asks whether the kernel checks the *user* bit, or only the range.

**This program exists because a control came back clean.** The mutation removed
the `User` requirement from `copy_in`, and every check still passed. The reason
was not a weak check. It was that the only bad address the test handed over was
a kernel one, and the range check refuses those before permissions is
consulted.

So this hands over an address in the program's own half that the program itself
cannot touch. `map_at` puts the program's own stack frame at a second address
with no `User` bit on it. The program can name that address and cannot read it.
The kernel's check is then the only thing between a program and memory it may
not have.

**That is the confused deputy, in three pages.** A program that cannot read
something asks the kernel to read it instead.

The kernel maps the page after the program is already running, so the program
waits for the address to appear in its data page. `spin` uses the same
handshake in the other direction.
*/
@(private = "file")
verify_shadow :: proc(r: ^Result, held: ^[3]uintptr) {
	p, err := load("shadow", program_shadow(), 0)
	if !check(r, err == .None && p != nil, "a third program is given an address it may not read") {
		return
	}
	r.programs += 1

	mapped := mem.map_at(p.space, SHADOW_VA, p.stack, {.Write, .No_Execute}, 1)
	check(r, mapped == .None, "a page goes into its half with no user bit on it")

	flags, ok := mem.permissions(p.space, SHADOW_VA)
	check(r, ok && .User not_in flags, "which is present, and not a page ring 3 may reach")

	set_cell(p, CELL_HANDOFF, u64(SHADOW_VA))

	if check(r, wait(p, PATIENCE), "the program is told where it is and asks the kernel to read it") {
		check(r, cell(p, CELL_MARK) == MARK_SHADOW, "having reached its first instruction")
		check(
			r,
			cell(p, CELL_WROTE) == refused(vectra9.EFAULT),
			"and the kernel refuses, because the page is not one the program may reach",
		)
		check(
			r,
			p.exit.deliberate && p.exit.status == 0,
			"rather than because the program gave up waiting",
		)
	}

	held^ = {p.text, p.data, p.stack}
	check(
		r,
		!mem.frame_is_free(held[0]) && !mem.frame_is_free(held[1]) && !mem.frame_is_free(held[2]),
		"a program holds three frames while it exists",
	)
	finish(r, p, "and is taken down")
}

/*
The paths and the line the three file programs are handed.

Every one of these is nine bytes, which is why one register carries the length
for both paths in `binder`. That is a convenience the blobs depend on, and the
check below says so rather than leaves it to be discovered.
*/
@(private = "file") PATH_FB :: "/dev/fb"
@(private = "file") PATH_CONS :: "/dev/cons"
@(private = "file") PATH_ZERO :: "/dev/zero"
@(private = "file") PATH_NULL :: "/dev/null"
@(private = "file") PATH_MISSING :: "/dev/nope"
@(private = "file") PATH_SCANCODE :: "/dev/scancode"

@(private = "file") NAMED :: "-- a process opened this file by name"
@(private = "file") REDIRECTED :: "-- this line went to /dev/null"

@(private = "file")
bytes_of :: proc "contextless" (text: string) -> []u8 {
	t := text
	return raw_data(t)[:len(t)]
}

/*
verify_processes runs the three programs that own something.

A process is a space, a namespace and a set of open files. The space came two
milestones ago and the door came one. **This is where the other two arrive**,
and each program is one sentence about them.

`namer` says a program can turn a path into a number and the number into
bytes on a screen. `reader` says the same in the other direction, and that the
kernel refuses to write where ring 3 may not. `binder` is the one that matters:
it rearranges its own view of the tree, and nothing else on the machine sees
the change.
*/
@(private = "file")
verify_processes :: proc(r: ^Result, column: proc "contextless" () -> int, held: ^[3]uintptr) {
	check(
		r,
		len(PATH_CONS) == len(PATH_ZERO) &&
		len(PATH_CONS) == len(PATH_NULL) &&
		len(PATH_CONS) == len(PATH_MISSING),
		"the four paths are the same length, which is what the programs assume",
	)

	// -- A process opens a file by name --------------------------------------

	p, err := load_held("namer", program_namer())
	if !check(r, err == .None && p != nil, "a process is built with a namespace of its own") {
		return
	}
	r.programs += 1
	check(r, p.ns != nil, "which is a copy rather than the kernel's")
	check(r, fd_count(p) == 3, "and three descriptors already open on the console")
	check(r, set_bytes(p, SLOT_A, bytes_of(PATH_CONS)), "with a path in its page")
	check(r, set_bytes(p, SLOT_C, bytes_of(NAMED)), "and a line to write")
	check(r, set_bytes(p, SLOT_D, bytes_of(PATH_MISSING)), "and a path that is not there")

	before := column()
	check(r, launch(p, u64(len(PATH_CONS)), u64(len(NAMED))), "and it launches, staged")
	if check(r, wait(p, PATIENCE), "and it comes back") {
		after := column()

		check(r, cell(p, CELL_MARK) == MARK_NAMER, "having reached its first instruction")
		check(
			r,
			cell(p, NAMER_OPENED) == 3,
			"the open it asked for gave it the lowest number nothing was using",
		)
		check(r, cell(p, NAMER_WROTE) == u64(len(NAMED)), "the write reported every byte")
		check(r, after - before == len(NAMED), "and the console moved that many columns")
		check(r, cell(p, NAMER_CLOSED) == 0, "the close was accepted")
		check(
			r,
			cell(p, NAMER_AFTER_CLOSE) == refused(vectra9.EBADF),
			"and the number it held stopped meaning anything",
		)
		check(
			r,
			cell(p, NAMER_MISSING) == refused(vectra9.ENOENT),
			"a path with nothing at it is refused by name",
		)
	}
	cons_finish()
	finish(r, p, "the process is taken down")

	// -- And reads one -------------------------------------------------------

	p, err = load_held("reader", program_reader())
	if !check(r, err == .None && p != nil, "a second process opens a file to read") {
		return
	}
	r.programs += 1
	check(r, set_bytes(p, SLOT_A, bytes_of(PATH_ZERO)), "with that path in its page")
	check(r, launch(p, u64(len(PATH_ZERO))), "and it launches, staged")

	if check(r, wait(p, PATIENCE), "and comes back") {
		check(r, cell(p, CELL_MARK) == MARK_READER, "having reached its first instruction")
		check(r, cell(p, READER_OPENED) == 3, "with a descriptor of its own")
		check(r, cell(p, READER_READ) == 8, "the read reported the bytes it asked for")
		check(
			r,
			cell(p, READER_BUFFER) == 0,
			"and they landed in its page, over the value it put there first",
		)
		/*
		And the kernel refused to write into the program's text.

		That page is `User` and not `Write`, so ring 3 cannot touch it. The
		kernel could: its own write goes through a supervisor mapping, where
		the read-only bit is `CR0.WP`'s business rather than the `User` bit's.
		`copy_out` has to say no on its own account, and this is the check that
		it does.
		*/
		check(
			r,
			cell(p, READER_REFUSED) == refused(vectra9.EFAULT),
			"a read into its own text is refused, which ring 3 could not do either",
		)
		check(r, cell(p, READER_CLOSED) == 0, "and the close was accepted")
	}
	finish(r, p, "and is taken down")

	// -- And one rearranges its own view of the tree -------------------------

	p, err = load_held("binder", program_binder())
	if !check(r, err == .None && p != nil, "a third process rearranges its own namespace") {
		return
	}
	r.programs += 1
	check(r, set_bytes(p, SLOT_A, bytes_of(PATH_NULL)), "binding one device")
	check(r, set_bytes(p, SLOT_B, bytes_of(PATH_CONS)), "over another")
	check(r, set_bytes(p, SLOT_C, bytes_of(REDIRECTED)), "with a line to send through both")

	before = column()
	check(r, launch(p, u64(len(PATH_NULL)), u64(len(REDIRECTED))), "and it launches, staged")
	if check(r, wait(p, PATIENCE), "and comes back") {
		after := column()

		check(r, cell(p, CELL_MARK) == MARK_BINDER, "having reached its first instruction")
		check(r, cell(p, BINDER_BOUND) == 0, "the bind was accepted")
		check(r, cell(p, BINDER_OPENED) == 3, "the path it just rebound still opens")
		check(r, cell(p, BINDER_WROTE) == u64(len(REDIRECTED)), "and the write reports every byte")

		check(r, cell(p, BINDER_CLOSED) == 0, "the close was accepted")
		/*
		Then the same bytes again, through the descriptor it started with.

		A bind changes what a *path* resolves to. A descriptor already open
		names a chan, and no rearrangement reaches it. That is Plan 9's rule,
		and it is the first one a program notices.
		*/
		check(r, cell(p, BINDER_AGAIN) == u64(len(REDIRECTED)), "the descriptor it started with wrote")

		/*
		**The same bytes went out twice, and the console moved once.**

		This is the whole milestone in one number. Two writes of the same line,
		one through a path the process rebound and one through a descriptor it
		opened before the rebind. Both report every byte. Only the second one is
		on the screen.

		Measured as a total rather than as two readings, because nothing can
		read the column between two instructions of a program. The total is the
		sharper claim anyway: it fails if the redirected write shows, and it
		fails if the other one does not.
		*/
		check(
			r,
			after - before == len(REDIRECTED),
			"and exactly one of the two reached the console",
		)
	}
	cons_finish()

	held^ = {p.text, p.data, p.stack}
	check(
		r,
		!mem.frame_is_free(held[0]) && !mem.frame_is_free(held[1]) && !mem.frame_is_free(held[2]),
		"a process holds three frames while it exists",
	)
	finish(r, p, "and is taken down")

	// -- And the kernel's own view of the tree is what it was ----------------

	c, cerr := vfs.open_path(vfs.boot_namespace, PATH_CONS, vfs.O_WRONLY)
	if check(r, cerr == vfs.OK && c != nil, "the kernel opens the same path afterwards") {
		mark := column()
		n, werr := vfs.chan_write(c, 0, bytes_of(NAMED))
		check(r, werr == vfs.OK && n == len(NAMED), "and writes to it")
		check(
			r,
			column() - mark == len(NAMED),
			"and reaches the console, so one process changed only its own namespace",
		)
		vfs.chan_close(c)
		cons_finish()
	}
}

/*
verify_painter is the handoff sentence made a process: a device a user
process can reach.

`painter` opens `/dev/fb` by name, seeks to an offset the kernel staged, and
writes pixel bytes it was handed -- twice. The second write is what proves
the descriptor's cursor carried. Then it seeks back, reads its own pixels
into its page, and closes.

The kernel's half of the check is the screen. `fb.get_raw` reads the frame
at the pixel the offset names, which no cell of the program's can fake. A
counter would agree with a broken device. The glass does not.

The bytes go back afterwards, straight through the surface: the program
painted the corner of a screen somebody is using.
*/
@(private = "file")
verify_painter :: proc(r: ^Result) {
	s := devfs.raw_surface()
	if !check(r, s != nil && s.pixels != nil, "the raw framebuffer is behind /dev/fb") {
		return
	}

	// Two pixels, written twice, in the bottom corner away from the boot log.
	bpp := s.bytes_pp
	span := bpp * 2
	x := s.width - 6
	y := s.height - 3
	offset := u64(y * s.pitch + x * bpp)

	pattern: [16]u8
	for i in 0 ..< span {
		pattern[i] = 0x35 + u8(i) * 11
	}
	saved: [32]u8
	for i in 0 ..< span * 2 {
		saved[i] = s.pixels[int(offset) + i]
	}

	p, err := load_held("painter", program_painter())
	if !check(r, err == .None && p != nil, "a process is built to reach it") {
		return
	}
	r.programs += 1
	check(r, set_bytes(p, SLOT_A, bytes_of(PATH_FB)), "with the path in its page")
	set_cell(p, SLOT_B / 8, offset)
	check(r, set_bytes(p, SLOT_C, pattern[:span]), "and pixel bytes to carry")

	check(r, launch(p, u64(len(PATH_FB)), u64(span)), "and it launches, staged")
	if check(r, wait(p, PATIENCE), "and comes back") {
		check(r, cell(p, CELL_MARK) == MARK_PAINTER, "having reached its first instruction")
		check(r, cell(p, PAINTER_OPENED) == 3, "the screen's memory opened as a file")
		check(r, cell(p, PAINTER_SEEKED) == offset, "the seek answered the offset it was given")
		check(r, cell(p, PAINTER_WROTE) == u64(span), "the write took every pixel byte")
		check(r, cell(p, PAINTER_AGAIN) == u64(span), "and so did the second, with no seek between")

		first := pixel_word(pattern[:bpp])
		second := pixel_word(pattern[bpp:span])
		check(r, fb.get_raw(s, x, y) == first, "the first pixel is on the screen where the offset says")
		check(r, fb.get_raw(s, x + 1, y) == second, "the second is beside it")
		check(
			r,
			fb.get_raw(s, x + 2, y) == first && fb.get_raw(s, x + 3, y) == second,
			"and the pair repeats where the carried cursor put the second write",
		)

		check(r, cell(p, PAINTER_RESEEK) == offset, "the seek back was answered")
		check(r, cell(p, PAINTER_READ) == u64(span), "the read back answered every byte")
		readback := true
		for i in 0 ..< (span + 7) / 8 {
			w := cell(p, PAINTER_BUFFER + i)
			for b in 0 ..< 8 {
				at := i * 8 + b
				if at < span && u8(w >> (u64(b) * 8)) != pattern[at] {
					readback = false
				}
			}
		}
		check(r, readback, "and its page holds the bytes it painted")
		check(r, cell(p, PAINTER_CLOSED) == 0, "the close was accepted")
	}

	for i in 0 ..< span * 2 {
		s.pixels[int(offset) + i] = saved[i]
	}
	finish(r, p, "and the process is taken down")
}

/*
verify_scancode_reader is the tap from ring 3: the raw keyboard, read by a
process.

The kernel holds `/dev/scancode` open across the whole run. The stream is
therefore already diverted when `reader` opens it, and stays diverted until
after the process is gone. Sixteen scancodes wait in the ring before the
launch. Eight are for the read that lands in the program's page, and eight
for the read aimed at refused memory. That second read consumes its bytes
before it fails, because `copy_out` runs after the device gives them up.
A tap with nothing left would park it for ever.

Release codes on purpose. A release translates to nothing, so a broken
diversion would still not scribble on the console. The leak itself is the
devfs checks' to catch. This proof is about a process holding raw hardware
bytes in its own page.
*/
@(private = "file")
verify_scancode_reader :: proc(r: ^Result) {
	held, herr := vfs.open_path(vfs.boot_namespace, PATH_SCANCODE, vfs.O_RDONLY)
	if !check(r, herr == vfs.OK && held != nil, "the kernel takes /dev/scancode, diverting the stream") {
		return
	}

	staged := true
	for i in 0 ..< 16 {
		staged = devfs.scancode_tap(u8(0x81 + i)) && staged
	}
	check(r, staged, "sixteen release codes wait in the ring, all consumed by the tap")

	p, perr := load_held("scanread", program_reader())
	if !check(r, perr == .None && p != nil, "a process is built to read them") {
		vfs.chan_close(held)
		return
	}
	r.programs += 1
	check(r, set_bytes(p, SLOT_A, bytes_of(PATH_SCANCODE)), "with the path in its page")
	check(r, launch(p, u64(len(PATH_SCANCODE))), "and it launches, staged")
	if check(r, wait(p, PATIENCE), "and comes back") {
		check(r, cell(p, CELL_MARK) == MARK_READER, "having reached its first instruction")
		check(r, cell(p, READER_OPENED) == 3, "the raw keyboard opened as a file")
		check(r, cell(p, READER_READ) == 8, "the read answered eight raw scancodes")
		check(
			r,
			cell(p, READER_BUFFER) == 0x8887_8685_8483_8281,
			"in arrival order, untranslated, in the program's own page",
		)
		check(
			r,
			cell(p, READER_REFUSED) == refused(vectra9.EFAULT),
			"a read into refused memory still answers EFAULT",
		)
		check(r, cell(p, READER_CLOSED) == 0, "and the close was accepted")
	}
	finish(r, p, "the process is taken down")

	vfs.chan_close(held)
	t := devfs.tree()
	check(r, t.scan_opens == 0, "and the last close gives the keyboard back")
	check(r, !devfs.tap_available(&t.scancode), "with nothing left in the ring")
}

// pixel_word builds the value `fb.get_raw` answers from the bytes a program
// wrote, low byte first. Its own arithmetic on purpose: a check that used
// the device's copy path would agree with it whatever else was broken.
@(private = "file")
pixel_word :: proc "contextless" (bytes: []u8) -> u32 #no_bounds_check {
	v := u32(0)
	for i := len(bytes) - 1; i >= 0; i -= 1 {
		v = v << 8 | u32(bytes[i])
	}
	return v
}

/*
verify_bulkio is the bulk path: a large read and write, each in one call.

`bulkio` writes `BULKIO_LEN` bytes to `/dev/fb` in a single `write`, then reads
them back in a single `read`. The counts are the proof. Before this milestone
a `write` stopped at 256 bytes and made the program loop. Now the kernel loops
for it, so one call moves the whole buffer. `BULKIO_LEN` is over one
`IO_CHUNK`, so each direction makes more than one pass. The framebuffer holds
all of it, which says the passes joined up rather than the first landing and
the rest falling on the floor.

The pattern is a byte ramp, staged into the program's data page. The kernel
saves the framebuffer region first and puts it back after, so the test paints
nothing a person keeps.
*/
@(private = "file")
verify_bulkio :: proc(r: ^Result) #no_bounds_check {
	s := devfs.raw_surface()
	if !check(r, s != nil && s.pixels != nil, "the raw framebuffer is behind /dev/fb") {
		return
	}
	fboff := (s.height - 4) * s.pitch
	if !check(r, u64(fboff) + BULKIO_LEN <= u64(s.height) * u64(s.pitch), "the bulk region fits the frame") {
		return
	}

	p, err := load_held("bulkio", program_bulkio())
	if !check(r, err == .None && p != nil, "a process is built to move a large buffer") {
		return
	}
	r.programs += 1

	// The path and a byte ramp, staged into the program's data page.
	check(r, set_bytes(p, BULKIO_PATH_OFF, bytes_of(BULKIO_PATH)), "with a path and a pattern in its page")
	pattern: [BULKIO_LEN]u8
	for i in 0 ..< BULKIO_LEN {
		pattern[i] = u8(i)
	}
	check(r, set_bytes(p, BULKIO_BUF_OFF, pattern[:]), "and a pattern larger than the copy chunk")

	// The region the write lands in, saved to be restored.
	saved: [BULKIO_LEN]u8
	for i in 0 ..< BULKIO_LEN {
		saved[i] = s.pixels[fboff + i]
	}

	check(r, launch(p, u64(len(BULKIO_PATH)), u64(fboff)), "and it launches, staged")
	if check(r, wait(p, PATIENCE), "and comes back") {
		check(r, cell(p, CELL_MARK) == MARK_BULKIO, "having reached its first instruction")
		check(r, cell(p, BULKIO_OPENED) == 3, "the framebuffer opened")
		check(
			r,
			cell(p, BULKIO_WROTE) == BULKIO_LEN,
			"a write of the whole buffer returned the whole count, not a chunk of it",
		)
		check(
			r,
			cell(p, BULKIO_READ) == BULKIO_LEN,
			"and a read of the whole buffer filled it in one call",
		)

		landed := true
		for i in 0 ..< BULKIO_LEN {
			if s.pixels[fboff + i] != u8(i) {
				landed = false
				break
			}
		}
		check(r, landed, "and every byte of the write is on the screen, passes joined")
	}

	// Put the framebuffer back the way it was found.
	for i in 0 ..< BULKIO_LEN {
		s.pixels[fboff + i] = saved[i]
	}
	finish(r, p, "and the process is taken down")
}

/*
verify_loading is the loader on its own terms, before any process asks.

The claims run inward. The programs are files a namespace can name. A file
begins with a header the format can check. The kernel can build a process
out of one. What is not a program gets the errno that says which rule it
broke.

The refusals matter most. A loader that runs whatever it is handed is a
loader that will one day run a text file.
*/
@(private = "file")
verify_loading :: proc(r: ^Result, column: proc "contextless" () -> int) {
	// -- A program is a file now ---------------------------------------------

	c, err := vfs.open_path(vfs.boot_namespace, "/bin/child", vfs.O_RDONLY)
	if check(r, err == vfs.OK && c != nil, "the kernel's own programs are files under /bin") {
		raw: [IMAGE_HEADER_SIZE]u8
		n, rerr := vfs.chan_read(c, 0, raw[:])
		check(r, rerr == vfs.OK && n == IMAGE_HEADER_SIZE, "a program file begins with a full header")

		h, ok := image_read_header(raw[:])
		check(r, ok && h.magic == IMAGE_MAGIC, "whose first word is the magic")
		check(r, image_check(h), "and whose fields describe something loadable")
		check(
			r,
			h.text == u64(len(program_child())),
			"with exactly the program's bytes declared behind it",
		)
		vfs.chan_close(c)
	}

	/*
	The format's refusals, one field at a time.

	Directly, against headers built here, because no file on the machine
	carries any of these defects and none ever should. Each is one clause of
	`image_check`, and a clause no check exercises is a clause that can go
	missing without a failure. That is `docs/TESTING.md`'s first rule.
	*/
	good := Image_Header {
		magic = IMAGE_MAGIC,
		entry = u64(TEXT_VA),
		text  = 64,
	}
	check(r, image_check(good), "the format accepts a header that keeps its rules")
	bad := good
	bad.magic = 0
	check(r, !image_check(bad), "and refuses one with the wrong magic")
	bad = good
	bad.reserved = 1
	check(r, !image_check(bad), "or a reserved word it does not know, which is the future knocking")
	bad = good
	bad.entry = u64(TEXT_VA) + 64
	check(r, !image_check(bad), "or an entry point past the end of the text")
	bad = good
	bad.text = u64(arch.PAGE_SIZE) + 1
	check(r, !image_check(bad), "or more text than the page the loader maps")
	bad = good
	bad.text = 0
	check(r, !image_check(bad), "or a program with nothing in it")

	// -- The kernel starts a process from a file -----------------------------

	before := column()
	p, serr := spawn_path(nil, "/bin/child", SPAWN_NS_COPY)
	if check(r, serr == vfs.OK && p != nil, "a process is built from a file rather than from a blob") {
		r.programs += 1
		if check(r, wait(p, PATIENCE), "and it comes back") {
			after := column()
			check(r, cell(p, CELL_MARK) == MARK_CHILD, "having reached its first instruction")
			check(
				r,
				cell(p, CHILD_OPENED) == 3,
				"it opened the console by name, on the next descriptor after the three it was given",
			)
			check(r, cell(p, CHILD_WROTE) == u64(len(CHILD_LINE)), "wrote its line from its own text")
			check(r, after - before == len(CHILD_LINE), "and the console moved that many columns")
			check(r, cell(p, CHILD_CLOSED) == 0, "it closed what it opened")
			check(
				r,
				p.exit.deliberate && p.exit.status == CHILD_STATUS,
				"and exited with the status that says all of that in one number",
			)
		}
		cons_finish()
		finish(r, p, "the process is taken down")
	}

	// -- And refuses what it must --------------------------------------------

	_, serr = spawn_path(nil, "/bin/no-such", 0)
	check(r, serr == vectra9.ENOENT, "a path with nothing at it is refused by name")

	_, serr = spawn_path(nil, "/dev/zero", 0)
	check(
		r,
		serr == vectra9.ENOEXEC,
		"and a file that is not a program is refused by its header, before a byte of it runs",
	)

	// -- A clean namespace is a world with no names --------------------------

	p, serr = spawn_path(nil, "/bin/child", SPAWN_NS_CLEAN)
	if check(r, serr == vfs.OK && p != nil, "a child with a clean namespace still loads, through its parent's") {
		r.programs += 1
		if check(r, wait(p, PATIENCE), "and runs") {
			check(r, cell(p, CELL_MARK) == MARK_CHILD, "having reached its first instruction")
			check(
				r,
				cell(p, CHILD_OPENED) == refused(vectra9.ENOENT),
				"but the same open is refused -- an empty namespace has no names in it",
			)
			check(
				r,
				cell(p, CHILD_WROTE) == refused(vectra9.EBADF),
				"and it holds no descriptors either, because those come from names too",
			)
		}
		finish(r, p, "and is taken down")
	}
}

/*
verify_parenthood is the milestone: a process starts another one.

The kernel launches `/bin/parent` and then only watches. Everything after
that -- the loader run, the namespace copy, the descriptor copy, the wait,
the reap -- happens because a program in ring 3 asked, twice.

**The number that matters is the console moving once.** Two children run the
same file, open the same path, write the same line, and report the same
status. Between them the parent bound `/dev/null` over `/dev/cons` in its own
namespace. The second child inherited that choice and its line went to null.
Same program, same path, one line on the screen -- which is a process handing
its child a world it arranged.
*/
@(private = "file")
verify_parenthood :: proc(r: ^Result, column: proc "contextless" () -> int, held: ^[3]uintptr) {
	spawned_before := stats().spawned

	before := column()
	p, serr := spawn_path(nil, "/bin/parent", SPAWN_NS_COPY)
	if !check(r, serr == vfs.OK && p != nil, "a process is started that will start more") {
		return
	}
	r.programs += 1

	/*
	While it lives: nobody else may collect it.

	The caller pid here belongs to no process that ever existed, so the only
	thing between it and a collection is the parentage check. This one is the
	kernel's to make directly, because no program can hold a pid that is not
	its own child's. `spawn` is the only source of pids there is.
	*/
	check(
		r,
		wait_pid(999, p.pid, 1) == -i64(vectra9.ECHILD),
		"a process that is not the parent cannot collect it",
	)

	if check(r, wait(p, PATIENCE), "and it comes back, having raised two children") {
		after := column()

		check(r, cell(p, CELL_MARK) == MARK_PARENT, "having reached its first instruction")

		pid_a := cell(p, PARENT_SPAWN_A)
		pid_b := cell(p, PARENT_SPAWN_B)
		check(r, i64(pid_a) > 0, "its first spawn answered with a pid")
		check(
			r,
			cell(p, PARENT_WAIT_A) == CHILD_STATUS,
			"and its wait collected that child's own exit status",
		)
		check(
			r,
			cell(p, PARENT_AGAIN) == refused(vectra9.ECHILD),
			"a second wait on the same pid found nothing -- collecting is destroying",
		)
		check(r, cell(p, PARENT_BOUND) == 0, "it bound /dev/null over /dev/cons in its own namespace")
		check(r, i64(pid_b) > 0 && pid_b != pid_a, "the second spawn answered with a pid nothing had used")
		check(
			r,
			cell(p, PARENT_WAIT_B) == CHILD_STATUS,
			"and that child ran the same file to the same status",
		)
		check(
			r,
			after - before == len(CHILD_LINE),
			"two children wrote the same line by the same path, and the console moved once",
		)
		check(
			r,
			cell(p, PARENT_MISSING) == refused(vectra9.ENOENT),
			"a spawn of a path with nothing at it was refused",
		)
		check(r, p.exit.deliberate && p.exit.status == 0, "and the parent exits with nothing to report")
		check(
			r,
			stats().spawned - spawned_before == 2,
			"two processes on this machine were started by another process",
		)
		check(r, stats().live == 1, "and neither outlived being collected -- the parent waited for both")
	}
	cons_finish()

	held^ = {p.text, p.data, p.stack}
	check(
		r,
		!mem.frame_is_free(held[0]) && !mem.frame_is_free(held[1]) && !mem.frame_is_free(held[2]),
		"a spawned process holds three frames while it exists",
	)
	finish(r, p, "and is taken down")
}

/*
verify_posting is the milestone's second half: a process publishes a service.

The kernel's part runs first and is all refusals. A read-only tree refuses a
create. A name the kernel reserves in `/srv` is pending. Its read says so, a
mount of it is ENXIO, and a write of a descriptor into it is EBADF. The
boot thread has no process, and a number from nowhere names nothing.

Then `/bin/poster` does the thing the refusals guard. It opens `/dev/cons`,
creates `/srv/cons2`, writes the digit its own text carries, and mounts the
name it just published at `/mnt` in its own namespace. The line it writes
through `/mnt/cons` is on the screen, which is a process reaching hardware
through a name no kernel put anywhere. Then it removes the name and opens
`/mnt/null`. The name is gone and the mount is not, which is Plan 9's rule
about what removal means.
*/
@(private = "file")
verify_posting :: proc(r: ^Result, column: proc "contextless" () -> int, held: ^[3]uintptr) {
	count0 := srv.count()

	// -- Creation is refused where it must be --------------------------------

	_, cerr := vfs.create_path(vfs.boot_namespace, "/bin/nope", vfs.O_WRONLY)
	check(r, cerr == vectra9.EROFS, "a read-only tree refuses a create")

	// -- A reserved name is not yet a service --------------------------------

	c, err := vfs.create_path(vfs.boot_namespace, "/srv/ktest", vfs.O_WRONLY)
	if check(r, err == vfs.OK && c != nil, "creating /srv/ktest reserves a name with nothing behind it") {
		check(r, srv.count() == count0 + 1, "which the table counts")

		digit := [1]u8{'3'}
		_, werr := vfs.chan_write(c, 0, digit[:])
		check(
			r,
			werr == vectra9.EBADF,
			"a thread with no process cannot post a descriptor into it",
		)

		line: [16]u8
		rc, rerr := vfs.open_path(vfs.boot_namespace, "/srv/ktest", vfs.O_RDONLY)
		if check(r, rerr == vfs.OK && rc != nil, "the pending entry opens by name") {
			n, _ := vfs.chan_read(rc, 0, line[:])
			check(r, string(line[:n]) == "pending\n", "and its read says pending")
			vfs.chan_close(rc)
		}

		check(
			r,
			srv.mount(vfs.boot_namespace, "/srv/ktest", "/mnt") == vectra9.ENXIO,
			"a pending name mounts nothing",
		)
		check(r, srv.lookup("ktest") == nil, "and no lookup calls it a service")

		check(r, vfs.chan_remove(c) == vfs.OK, "the reservation is removed like any other name")
		vfs.chan_close(c)
		check(r, srv.count() == count0, "and the table is back where it was")
	}

	// -- A process posts a service, and reaches the console through it -------

	before := column()
	p, serr := spawn_path(nil, "/bin/poster", SPAWN_NS_COPY)
	if !check(r, serr == vfs.OK && p != nil, "a process is started that will publish a service") {
		return
	}
	r.programs += 1

	if check(r, wait(p, PATIENCE), "and it comes back") {
		after := column()

		check(r, cell(p, CELL_MARK) == MARK_POSTER, "having reached its first instruction")
		check(
			r,
			cell(p, POSTER_OPENED) == 3,
			"it opened the console on descriptor 3, the digit its own text carries",
		)
		check(r, cell(p, POSTER_CREATED) == 4, "created /srv/cons2, and holds the reservation")
		check(r, cell(p, POSTER_WROTE_FD) == 1, "wrote one digit into it, which posted the connection")
		check(
			r,
			cell(p, POSTER_REWROTE) == refused(vectra9.EPERM),
			"a second write is refused -- a posted name is not a thing to swap",
		)
		check(r, cell(p, POSTER_CLOSED) == 0, "closed the posting descriptor")
		check(r, cell(p, POSTER_MOUNTED) == 0, "and mounted /srv/cons2 at /mnt in its own namespace")
		check(r, cell(p, POSTER_VIA) == 4, "the console opened through the mount, on the number the close freed")
		check(
			r,
			cell(p, POSTER_WROTE) == u64(len(POSTER_LINE)),
			"and the write through the posted service reported every byte",
		)
		check(r, after - before == len(POSTER_LINE), "which are on the screen")

		check(r, cell(p, POSTER_REMOVED) == 0, "the name was removed")
		check(r, cell(p, POSTER_GONE) == refused(vectra9.ENOENT), "and is gone by name")
		check(r, cell(p, POSTER_AGAIN) == 5, "while the mount still opens /mnt/null")
		check(
			r,
			cell(p, POSTER_WROTE_AGAIN) == u64(len(POSTER_LINE)),
			"and still carries every byte -- removal ends the name, not the service",
		)

		check(r, p.exit.deliberate && p.exit.status == 0, "the process exits with nothing to report")
		check(r, srv.count() == count0, "and /srv holds exactly what it held before it ran")
	}
	cons_finish()

	held^ = {p.text, p.data, p.stack}
	finish(r, p, "and it is taken down")
}

/*
What a wire pins while it lives, and the zero the release settles it to.

Seven objects. Two pipe rings, the wire's arena, the `Wire`, the `Server`,
and the `Wire_End` the io callbacks close over. The seventh is one
reference's worth of chan on the posted end. They stay pinned exactly as
long as the name or a
mount holds the connection. Each flow below removes the name, brings the
last mount down, and then demands the heap got every one of them back. A
release that kept even one shows here as a number rather than a suspicion.
*/

// What `/bin/ramfs` exits with when the counted release hangs up on it,
// written here and as the `.Hangup` arm in `servers/ramfs/main.odin`. The
// two have to agree, and the check fails loudly when they drift.
@(private = "file")
RAMFS_HANGUP :: u64(0x68)

/*
verify_service_answered is the milestone: a process answers 9P.

`/bin/niner` makes a pipe, posts one end, and serves the other. Everything
the kernel then does to `/srv/niner` crosses to ring 3 as bytes, and a
program answers it. That covers the mount's handshake, the walks and the
open, a write, a read, and the remove. The write's payload comes back out on
the console, which is one line that travels kernel to process to kernel to
screen.

The remove is also the stop: `niner` answers it and exits, so the wire's far
side hangs up with the kernel watching. What a dead server leaves behind is
checked to the object: the wire's deliberate pin, and nothing else.
*/
@(private = "file")
verify_service_answered :: proc(r: ^Result, column: proc "contextless" () -> int) {
	count0 := srv.count()

	sched.reap()
	pin_before := mem.live_objects(mem.heap_stats())

	p, serr := spawn_path(nil, "/bin/niner", SPAWN_NS_COPY)
	if !check(r, serr == vfs.OK && p != nil, "a process is started that will answer 9P") {
		return
	}
	r.programs += 1

	// The posting is the process's own doing, so the kernel waits for the
	// name rather than races it. `lookup` answers nil until the descriptor
	// write lands.
	posted := await_posted("niner")
	check(r, posted, "which posts /srv/niner while the kernel watches")

	line: [16]u8
	if rc, rerr := vfs.open_path(vfs.boot_namespace, "/srv/niner", vfs.O_RDONLY); rerr == vfs.OK {
		n, _ := vfs.chan_read(rc, 0, line[:])
		check(r, string(line[:n]) == "| direct\n", "and the name reads back as a posted pipe")
		vfs.chan_close(rc)
	}

	// The mount is where the wire is built, and its handshake is the first
	// 9P message a process ever answered.
	check(
		r,
		srv.mount(vfs.boot_namespace, "/srv/niner", "/mnt") == vfs.OK,
		"the kernel mounts it, which negotiates 9P2000.L with a program",
	)

	c, oerr := vfs.open_path(vfs.boot_namespace, "/mnt/served", vfs.O_RDWR)
	if check(r, oerr == vfs.OK && c != nil, "a path resolves through walks the program answered") {
		before := column()
		wn, werr := vfs.chan_write(c, 0, transmute([]u8)string(NINER_ECHO_LINE))
		check(r, werr == vfs.OK && wn == len(NINER_ECHO_LINE), "a write crosses to ring 3 and back")
		check(
			r,
			column() - before == len(NINER_ECHO_LINE),
			"and its bytes are on the screen, forwarded by the process",
		)

		buf: [64]u8
		rn, rerr := vfs.chan_read(c, 0, buf[:])
		check(r, rerr == vfs.OK && rn == len(NINER_READ_LINE), "a read is answered with a payload")
		check(
			r,
			string(buf[:rn]) == NINER_READ_LINE,
			"whose bytes are the ones the program's own text carries",
		)

		check(r, vfs.chan_remove(c) == vfs.OK, "a remove is answered too, and is the stop")
		vfs.chan_close(c)
	}

	if check(r, wait(p, PATIENCE), "the server exits on its own say-so") {
		check(r, p.exit.deliberate && p.exit.status == 0, "deliberately, with nothing to report")
		check(r, cell(p, CELL_MARK) == MARK_NINER, "having reached its first instruction")
		check(r, cell(p, NINER_PIPE) == NINER_FDS, "sys_pipe put the two ends on 3 and 4")
		check(r, cell(p, NINER_CREATED) == 5, "the reservation took the next number")
		check(r, cell(p, NINER_POSTED) == 1, "one digit posted the client end")
		check(
			r,
			cell(p, NINER_CLOSED_SRV) == 0 && cell(p, NINER_CLOSED_END) == 0,
			"and both spent descriptors closed -- the posting owns its reference",
		)
		r.answered = cell(p, NINER_SERVED)
		check(r, r.answered >= 8, "it served the whole conversation")
	}

	check(r, srv.remove("niner") == vfs.OK, "the kernel takes the name away")
	check(r, srv.count() == count0, "and /srv holds exactly what it held before")

	cons_finish()

	/*
	The teardown order is load-bearing, and backwards from the usual one.

	The process goes down first. Its teardown closes its descriptors, the serve
	end of the pipe closes with them, and the wire poisons on the hangup. Only
	then may the mount come down, because its close clunks a fid on the wire. A
	clunk to a *poisoned* wire fails at once, where a clunk to a merely absent
	server would wait for ever. A server that dies fails its clients fast. A
	server that merely goes quiet holds them, and the note is what will end
	that, not the wire.
	*/
	finish(r, p, "and the process is taken down")

	// The dead server's wire noticed the hangup, and its reader is leaving.
	// The measurement below counts stacks, so the leaving has to finish.
	pipe.quiesce()
	check(
		r,
		vfs.unmount_path(vfs.boot_namespace, "", "/mnt") == vfs.OK,
		"the mount of a dead server comes down like any other",
	)
	/*
	Measured until it settles rather than once. A dead thread is reapable only
	after the scheduler switches off it for good, and two threads just died --
	the server's and the wire reader's. The bound turns `not yet` into `never`,
	and the check after the loop still demands the exact number.

	The number is zero now. The name went and the last mount just came down.
	The unmount's own thread therefore ran the counted release on the way
	through: hang-up, join, and every one of the seven pinned objects back.
	*/
	for _ in 0 ..< PATIENCE {
		sched.reap()
		r.pinned = mem.live_objects(mem.heap_stats()) - pin_before
		if r.pinned == 0 {
			break
		}
		sync.delay(1)
	}
	check(r, r.pinned == 0, "and everything the wire pinned comes back, to the object")
}

/*
What `/mnt/hello` must say, written here and in `servers/ramfs/main.odin`.

The program's copy travels the whole way -- compiler, linker, image, loader,
rodata segment, 9P -- and this copy waits at the end to call it right. The
two have to agree, and the check fails loudly when they drift.
*/
@(private = "file")
RAMFS_HELLO :: "these bytes live in a program's own segments\n"

@(private = "file")
RAMFS_NOTE :: "kept in a ring 3 bss page"

/*
image_header reads the first sixteen bytes of a program in `/bin` and checks
what they say.

Two sections wrote this out. The magic is the same question both times, and the
entry point is the answer only one of them wants.

Returns false when the file is missing or the header is wrong, which is a
caller with nothing left to test. Every caller returns on it.
*/
@(private = "file")
image_header :: proc(r: ^Result, path: string, what: string) -> (entry: uintptr, ok: bool) {
	c, err := vfs.open_path(vfs.boot_namespace, path, vfs.O_RDONLY)
	if err != vfs.OK {
		check(r, false, what)
		return 0, false
	}
	defer vfs.chan_close(c)

	header: [16]u8
	n, _ := vfs.chan_read(c, 0, header[:])
	if !check(r, n == 16, what) {
		return 0, false
	}

	word :: proc "contextless" (b: []u8) -> u64 {
		v := u64(0)
		for i in 0 ..< 8 {
			v |= u64(b[i]) << (8 * u64(i))
		}
		return v
	}
	check(r, word(header[:]) == IMAGE2_MAGIC, "and its header says VECTRA02")
	return uintptr(word(header[8:])), true
}

/*
verify_runtime is the milestone: a compiled program, served from `/bin`,
serving back.

`/bin/ramfs` is an Odin program `build.odin` compiled, thirteen times the
size of a blob, in the segment format. The loader maps its text, rodata and
bss each with its own permissions and gives it a real stack. The program
then posts `/srv/ramfs` through `sys/libuser` and serves a file tree with
`sys/vectra9` -- the same codec the kernel speaks, linked into ring 3.

Each check names the segment it proves. A read of `/mnt/hello` is rodata,
mapped and readable. A fresh read of `/mnt/note` is bss, present and zero.
A write to it and the read-back is bss again, writable this time. The
listing and the walks are text, running. What ends it is the same remove
that ends `niner`, and what stays is one more wire's pin, to the object.
*/
// seg_row writes one segment-table row, for the format checks below.
@(private = "file")
seg_row :: proc "contextless" (out: []u8, at: int, vaddr: u64, filesz: u64, memsz: u64, flags: u64) #no_bounds_check {
	put :: proc "contextless" (b: []u8, v: u64) #no_bounds_check {
		for i in 0 ..< 8 {
			b[i] = u8(v >> (8 * u64(i)))
		}
	}
	put(out[at:], vaddr)
	put(out[at + 8:], filesz)
	put(out[at + 16:], memsz)
	put(out[at + 24:], flags)
}

// verify_image2 holds the segment judge to its refusals, one rule at a time.
// Every row here is an image `build.odin` must never emit, and the loader is
// the side that cannot afford to trust that.
@(private = "file")
verify_image2 :: proc(r: ^Result) {
	table: [2 * IMAGE2_SEG_SIZE]u8
	segs: [IMAGE2_MAX_SEGS]Image_Seg
	entry := TEXT_VA + 16

	seg_row(table[:], 0, u64(TEXT_VA), 0x100, 0x100, IMG_FLAG_X)
	seg_row(table[:], IMAGE2_SEG_SIZE, u64(TEXT_VA) + 0x1000, 0x10, 0x2000, IMG_FLAG_W)
	check(r, image2_read_segs(table[:], entry, 2, segs[:], 8), "a well-formed segment table is accepted")

	seg_row(table[:], 0, u64(TEXT_VA) + 5, 0x100, 0x100, IMG_FLAG_X)
	check(r, !image2_read_segs(table[:], entry, 1, segs[:], 8), "a segment off a page boundary is refused")

	seg_row(table[:], 0, u64(TEXT_VA), 0x100, 0x100, IMG_FLAG_X | IMG_FLAG_W)
	check(r, !image2_read_segs(table[:], entry, 1, segs[:], 8), "writable-and-executable is refused -- W^X is the format's rule")

	seg_row(table[:], 0, u64(TEXT_VA), 0x100, 0x2000, IMG_FLAG_X)
	seg_row(table[:], IMAGE2_SEG_SIZE, u64(TEXT_VA) + 0x1000, 0x10, 0x100, IMG_FLAG_W)
	check(r, !image2_read_segs(table[:], entry, 2, segs[:], 8), "segments that overlap are refused")

	seg_row(table[:], 0, u64(TEXT_VA), 0x100, 0x100, IMG_FLAG_W)
	check(r, !image2_read_segs(table[:], entry, 1, segs[:], 8), "an entry outside every executable segment is refused")

	seg_row(table[:], 0, u64(TEXT_VA), 0x100, 0x20000, IMG_FLAG_X)
	check(r, !image2_read_segs(table[:], entry, 1, segs[:], 8), "a segment past the page budget is refused")

	seg_row(table[:], 0, u64(STACK_VA2), 0x100, 0x100, IMG_FLAG_X)
	check(
		r,
		!image2_read_segs(table[:], uintptr(STACK_VA2) + 16, 1, segs[:], 8),
		"a segment inside the stack's ground is refused",
	)
}

@(private = "file")
verify_runtime :: proc(r: ^Result, column: proc "contextless" () -> int) {
	count0 := srv.count()

	verify_image2(r)

	sched.reap()
	pin_before := mem.live_objects(mem.heap_stats())

	// -- The image is a file, and says which format it is ---------------------

	image_entry, image_ok := image_header(r, "/bin/ramfs", "/bin serves the compiled image")
	if !image_ok {
		return
	}

	// -- The loader builds a bigger world than a blob's -----------------------

	p, serr := spawn_path(nil, "/bin/ramfs", SPAWN_NS_COPY)
	if !check(r, serr == vfs.OK && p != nil, "the segment loader starts it") {
		return
	}
	r.programs += 1
	total_pages := 0
	for i in 0 ..< p.seg_count {
		total_pages += p.segs[i].pages
	}
	check(
		r,
		total_pages > STACK_PAGES2 + 3 && total_pages <= MAX_PROGRAM_FRAMES,
		"holding more pages than any blob could",
	)
	first_frame := p.segs[0].frames[0]
	last_seg := p.segs[p.seg_count - 1]
	last_frame := last_seg.frames[last_seg.pages - 1]

	/*
	The mappings themselves, asked directly. The format's judge refuses a
	writable-and-executable *row*, and this is the other half: the loader
	translated the rows it accepted into page flags. The entry page runs and
	is not writable. The stack's ground is writable and never runs. Both
	carry `User`, or nothing here would run at all.
	*/
	text_flags, text_ok := mem.permissions(p.space, image_entry)
	check(
		r,
		text_ok && .User in text_flags && .Write not_in text_flags && .No_Execute not_in text_flags,
		"the entry's page executes and refuses a write",
	)
	stack_flags, stack_ok := mem.permissions(p.space, STACK_VA2)
	check(
		r,
		stack_ok && .User in stack_flags && .Write in stack_flags && .No_Execute in stack_flags,
		"the stack's page is the reverse",
	)

	posted := await_posted("ramfs")
	check(r, posted, "and it posts /srv/ramfs through the library")

	check(
		r,
		srv.mount(vfs.boot_namespace, "/srv/ramfs", "/mnt") == vfs.OK,
		"the kernel mounts it",
	)

	// -- rodata: bytes the compiler placed, served back -----------------------

	buf: [96]u8
	hc, herr := vfs.open_path(vfs.boot_namespace, "/mnt/hello", vfs.O_RDONLY)
	if check(r, herr == vfs.OK, "a walk the program answers finds /mnt/hello") {
		n, rerr := vfs.chan_read(hc, 0, buf[:])
		check(r, rerr == vfs.OK && n == len(RAMFS_HELLO), "whose read answers every byte")
		check(r, string(buf[:n]) == RAMFS_HELLO, "out of the program's own rodata segment")

		// The line on the screen is the proof a transcript keeps: bytes born
		// in a ring 3 segment, served over 9P, printed by their client.
		if cons, cerr := vfs.open_path(vfs.boot_namespace, "/dev/cons", vfs.O_WRONLY); cerr == vfs.OK {
			before := column()
			_, _ = vfs.chan_write(cons, 0, buf[:n - 1])
			check(r, column() - before == n - 1, "and on the screen, via the kernel")
			vfs.chan_close(cons)
		}
		cons_finish()
		vfs.chan_close(hc)
	}

	// -- bss: zero on arrival, writable after ---------------------------------

	nc, nerr := vfs.open_path(vfs.boot_namespace, "/mnt/note", vfs.O_RDWR)
	if check(r, nerr == vfs.OK, "/mnt/note opens for both directions") {
		n, rerr := vfs.chan_read(nc, 0, buf[:])
		check(r, rerr == vfs.OK && n == 0, "a fresh bss file is empty, which is what zeroed means")

		wn, werr := vfs.chan_write(nc, 0, transmute([]u8)string(RAMFS_NOTE))
		check(r, werr == vfs.OK && wn == len(RAMFS_NOTE), "a write lands in the program's bss")
		n, rerr = vfs.chan_read(nc, 0, buf[:])
		check(
			r,
			rerr == vfs.OK && n == len(RAMFS_NOTE) && string(buf[:n]) == RAMFS_NOTE,
			"and reads back byte for byte",
		)

		/*
		The long exchange, and the length is the check. A frame this size crosses
		the pipe in more pieces than one system call may copy. A server without
		the library's loops would never see the request's tail, and would
		never send the reply's. `LONG` is over the
		kernel's per-call copy bound and under the note's capacity, and both
		bounds have a name.
		*/
		LONG :: 260
		long: [LONG]u8
		for i in 0 ..< LONG {
			long[i] = u8('a' + i % 26)
		}
		wn, werr = vfs.chan_write(nc, 0, long[:])
		check(r, werr == vfs.OK && wn == LONG, "a note longer than one copy bound lands whole")
		back: [LONG + 8]u8
		n, rerr = vfs.chan_read(nc, 0, back[:])
		same := rerr == vfs.OK && n == LONG
		if same {
			for i in 0 ..< LONG {
				same = same && back[i] == long[i]
			}
		}
		check(r, same, "and comes back whole, through the library's loops")

		// -- text: the listing is the program running -------------------------

		if dc, derr := vfs.resolve(vfs.boot_namespace, "/mnt"); derr == vfs.OK {
			names: [64]u8
			ln, lerr := vfs.readdir(dc, 0, names[:])
			seen_hello := false
			seen_note := false
			if lerr == vfs.OK {
				c := vectra9.cursor_from(names[:ln])
				for {
					e, ok := vectra9.next_dirent(&c)
					if !ok {
						break
					}
					seen_hello = seen_hello || e.name == "hello"
					seen_note = seen_note || e.name == "note"
				}
			}
			check(r, seen_hello && seen_note, "a listing names both files, once each")
			vfs.chan_close(dc)
		}

		vfs.chan_close(nc)
	}

	// -- The name goes first, and the service does not stop --------------------

	check(r, srv.remove("ramfs") == vfs.OK, "the kernel takes the name away while the mount lives")
	check(r, srv.count() == count0, "and /srv holds exactly what it held before")

	if hc2, herr2 := vfs.open_path(vfs.boot_namespace, "/mnt/hello", vfs.O_RDONLY); herr2 == vfs.OK {
		n, rerr := vfs.chan_read(hc2, 0, buf[:])
		check(
			r,
			rerr == vfs.OK && string(buf[:n]) == RAMFS_HELLO,
			"and the mount still answers -- removal does not stop a service",
		)
		vfs.chan_close(hc2)
	}

	// -- The release is the stop ------------------------------------------------

	/*
	Nobody told this server to end. Its serve loop is parked in a pipe read,
	healthy. The unmount drops the connection's last chans, and the counted
	release runs on the unmount's own thread. Its hang-up is what the server
	hears: a read of zero bytes, `.Hangup` out of `libuser.serve`, and an
	exit that names it. The first server Vectra stops by releasing it.
	*/
	check(
		r,
		vfs.unmount_path(vfs.boot_namespace, "", "/mnt") == vfs.OK,
		"the last mount comes down, and the release rides the unmount",
	)
	if check(r, wait(p, PATIENCE), "the server ends with nobody telling it to") {
		check(
			r,
			p.exit.deliberate && p.exit.status == RAMFS_HANGUP,
			"deliberately, and its status says the hang-up was the reason",
		)
	}

	finish(r, p, "and the process is taken down")
	check(
		r,
		mem.frame_is_free(first_frame) && mem.frame_is_free(last_frame),
		"with every segment frame given back, first and last by name",
	)

	pinned := 0
	for _ in 0 ..< PATIENCE {
		sched.reap()
		pinned = mem.live_objects(mem.heap_stats()) - pin_before
		if pinned == 0 {
			break
		}
		sync.delay(1)
	}
	check(r, pinned == 0, "and one more wire's pin comes back whole")
	r.pinned += pinned
}

/*
verify_notes is the milestone: an ending delivered from outside.

Three deliveries, one per boundary. A compute-bound program never makes a
system call, so the tick is what catches it in ring 3. `spin` dies mid loop,
within a few ticks of the note, and its moving counter proves it was deep in
its own business. A parked server sits in a pipe read, so the note unwinds
the sleep. EINTR climbs out of the pipe, the serve loop turns toward its
exit, and the door's check ends it before that exit is heard.

And a process notes its own child from ring 3. It collects the EINTR that
says a note did it, and hears ECHILD for a pid that is nobody's child.

Every wait below also tests the other half of the milestone. `wait` and
`wait_pid` park on the exit rendezvous now. The elapsed-tick check on the
first delivery is what says the wake was a wake rather than a timeout.
*/
@(private = "file")
verify_notes :: proc(r: ^Result) {
	// -- The tick's delivery: a program that never crosses on its own ---------

	p, err := load("spin-noted", program_spin(), 0)
	if !check(r, err == .None && p != nil, "a program is started that loops for ever") {
		return
	}
	r.programs += 1

	// Mid loop, provably: the counter has to move before the note is
	// posted. Posting on the heels of `load` raced the first dispatch.
	// A tick that caught the thread before its first instruction read a
	// counter of zero. The flake arrived the day the boot's timing
	// shifted. The handshake is `verify_spin`'s, in one direction.
	moving := false
	for _ in 0 ..< PATIENCE {
		if cell(p, CELL_COUNTER) > 0 {
			moving = true
			break
		}
		sync.delay(1)
	}
	check(r, moving, "and its counter moves")

	before := sync.now()
	check(r, post_note(p, "die"), "a note is posted to it")
	if check(r, wait(p, 100), "and it ends") {
		check(r, sync.now() - before < 50, "promptly -- the wake was a wake, not a timeout")
		check(r, p.exit.noted, "the record says a note did it")
		check(r, !p.exit.deliberate, "and not the program")
		check(r, p.exit.from_user, "caught in ring 3, mid loop")
		check(r, cell(p, CELL_COUNTER) > 0, "with its counter moving when the tick took it")
		check(r, note(p) == "die", "and the text arrived whole")
		check(r, !post_note(p, "again"), "a second note is refused -- the target is gone")
	}
	finish(r, p, "and it is taken down")

	// -- The sleep's delivery: a server parked in a pipe ----------------------

	serr: vfs.Errno
	p, serr = spawn_path(nil, "/bin/ramfs", SPAWN_NS_COPY)
	if !check(r, serr == vfs.OK && p != nil, "a server is started to park in its pipe") {
		return
	}
	r.programs += 1

	posted := await_posted("ramfs")
	check(r, posted, "and it posts, then parks with nothing to serve")

	check(r, post_note(p, "enough"), "a note is posted to the parked server")
	if check(r, wait(p, 200), "the sleep unwinds and it ends") {
		check(r, p.exit.noted, "by the note, at the door")
		check(r, !p.exit.deliberate, "not by the exit it was walking toward")
	}
	check(r, srv.remove("ramfs") == vfs.OK, "the name comes away")
	finish(r, p, "and the server is taken down")

	// -- Ring 3's delivery: a parent ends its own child -----------------------

	p, serr = spawn_path(nil, "/bin/noter", SPAWN_NS_COPY)
	if !check(r, serr == vfs.OK && p != nil, "a process is started that will end another") {
		return
	}
	r.programs += 1

	if check(r, wait(p, PATIENCE), "and it comes back") {
		check(r, cell(p, CELL_MARK) == MARK_NOTER, "having reached its first instruction")
		check(r, i64(cell(p, NOTER_SPAWNED)) > 0, "it spawned a child that loops for ever")
		check(r, cell(p, NOTER_NOTED) == 0, "noted it")
		check(
			r,
			cell(p, NOTER_WAITED) == refused(vectra9.EINTR),
			"and collected EINTR -- the kernel's word for a note-ended child",
		)
		check(
			r,
			cell(p, NOTER_STRANGER) == refused(vectra9.ECHILD),
			"while a pid that is nobody's child answers ECHILD",
		)
		check(r, p.exit.deliberate && p.exit.status == 0, "then exited with nothing to report")
	}
	finish(r, p, "and it is taken down")
}

/*
verify_handler is the milestone: a note a process catches, and survives.

`catcher` registers a handler and spins, with a magic number parked in a
register the handler will trash on purpose. The first note lands at the
tick, mid loop -- the handler counts it, copies the text out, and answers
NCONT. The second lands while the program loops on `sleep`, which is the
door. After both, the program writes the register to a cell and exits
zero. The magic in that cell is the frame restore proven twice: the
handler zeroed r13, and NCONT put it back, both times.

`dfltnote`'s handler is the other answer. It counts the delivery and says
NDFLT, and the process ends exactly as a handlerless one does: noted, not
deliberate. Its own code saw the note first, though. A handler may look at
a note and still decline it.
*/
@(private = "file")
verify_handler :: proc(r: ^Result) {
	p, err := load_held("catcher", program_catcher())
	if !check(r, err == .None && p != nil, "a process is built that will catch a note") {
		return
	}
	r.programs += 1
	if !check(r, launch(p), "and it launches") {
		finish(r, p, "and is taken down")
		return
	}

	// Registered and spinning before anything is posted. The counter is the
	// proof of ring 3, the same proof `spin` gives.
	registered := false
	for _ in 0 ..< PATIENCE {
		if cell(p, CATCHER_ROUNDS) > 0 {
			registered = true
			break
		}
		sync.delay(1)
	}
	check(r, registered, "it registers a handler and spins")
	check(
		r,
		cell(p, CATCHER_EARLY) == refused(vectra9.EINVAL),
		"a noted with no delivery in flight was refused first",
	)
	check(r, cell(p, CATCHER_NOTIFIED) == 0, "and notify answered zero")

	check(r, post_note(p, CATCHER_NOTE), "a note is posted to it, mid spin")
	handled := false
	for _ in 0 ..< PATIENCE {
		if cell(p, CATCHER_HANDLED) >= 1 {
			handled = true
			break
		}
		sync.delay(1)
	}
	if !check(r, handled, "the tick hands the handler the frame it interrupted") {
		finish(r, p, "and the catcher is taken down")
		return
	}
	check(r, !exit_done(p), "and the process is still alive")

	// Seven characters and the NUL are one cell, byte for byte the kernel's.
	text := string(CATCHER_NOTE)
	want := u64(0)
	for i := len(text) - 1; i >= 0; i -= 1 {
		want = want << 8 | u64(text[i])
	}
	check(r, cell(p, CATCHER_TEXT) == want, "the handler read the note's own text")

	check(r, post_note(p, "again"), "a second note is posted, into its syscall loop")
	if check(r, wait(p, PATIENCE), "and the program comes back from both") {
		check(r, cell(p, CATCHER_HANDLED) == 2, "each delivery ran the handler once")
		check(
			r,
			p.exit.deliberate && !p.exit.noted && p.exit.status == 0,
			"and the exit is the program's own -- a process survived two notes",
		)
		check(
			r,
			cell(p, CATCHER_MAGIC) == CATCHER_MAGIC_VALUE,
			"with a register the handler trashed restored, twice, by noted",
		)
	}
	finish(r, p, "and the catcher is taken down")

	// -- The other answer ------------------------------------------------------

	p, err = load_held("dfltnote", program_dfltnote())
	if !check(r, err == .None && p != nil, "a process is built that will decline one") {
		return
	}
	r.programs += 1
	if !check(r, launch(p), "and it launches") {
		finish(r, p, "and is taken down")
		return
	}

	moving := false
	for _ in 0 ..< PATIENCE {
		if cell(p, DFLTNOTE_ROUNDS) > 0 {
			moving = true
			break
		}
		sync.delay(1)
	}
	check(r, moving, "it registers and spins")

	check(r, post_note(p, "enough"), "a note is posted")
	if check(r, wait(p, PATIENCE), "and it ends") {
		check(r, cell(p, DFLTNOTE_RAN) == 1, "the handler ran first")
		check(
			r,
			p.exit.noted && !p.exit.deliberate,
			"and NDFLT is the ending the note always was",
		)
	}
	finish(r, p, "and it is taken down")
}

/*
verify_exec is the seam's other half: a program that replaces itself.

`execer` writes its own mark, then execs `/bin/child`. If exec works, the
process is `child` from there on -- same pid, same descriptors, same
namespace -- and three things say so. Its mark cell holds `child`'s mark,
not `execer`'s, because the data page it wrote first is gone with the old
image. `child`'s line reaches the console through a descriptor `execer`
opened and `child` inherited. And the exit status collected on `execer`'s
pid is `child`'s own.

The console moving is the end-to-end proof. `execer` never opened
`/dev/cons`. The standard descriptors it was born with are what `child`
writes through, which is exactly the redirect a shell sets up before it
execs.
*/
@(private = "file")
verify_exec :: proc(r: ^Result, column: proc "contextless" () -> int) {
	p, err := load_held("execer", program_execer())
	if !check(r, err == .None && p != nil, "a process is built that will replace itself") {
		return
	}
	r.programs += 1
	pid_before := p.pid

	before := column()
	if !check(r, launch(p), "and it launches") {
		finish(r, p, "and is taken down")
		return
	}
	if check(r, wait(p, PATIENCE), "and comes back, having become another program") {
		after := column()

		check(r, p.pid == pid_before, "under the pid it started with -- exec keeps the process")
		check(r, cell(p, CELL_MARK) == MARK_CHILD, "the mark is the new program's, not the old one's")
		check(
			r,
			cell(p, CHILD_OPENED) == 3,
			"the new program opened a fourth descriptor beside the three it inherited",
		)
		check(r, cell(p, CHILD_WROTE) == u64(len(CHILD_LINE)), "and wrote its line from its own text")
		check(r, after - before == len(CHILD_LINE), "which reached the console through an inherited descriptor")
		check(
			r,
			p.exit.deliberate && p.exit.status == CHILD_STATUS,
			"and it exits with the new program's status",
		)
	}
	cons_finish()
	finish(r, p, "and the replaced process is taken down")
}

/*
verify_reap is a child no parent waits for, and the leak that used to be.

`nowaiter` forks with `RFNOWAIT`, which hands the child to the kernel at
birth. The parent records the child's pid and tries to `wait` it, and hears
ECHILD -- a detached child is nobody's to collect from ring 3. The child
runs to its own exit under no parent, and `reap_orphans` is what finally
takes its record back. Before this milestone that record was an honest
leak, visible in `stats().live` and collectable by nothing.
*/
@(private = "file")
verify_reap :: proc(r: ^Result) {
	p, err := load_held("nowaiter", program_nowaiter())
	if !check(r, err == .None && p != nil, "a process is built that forks a detached child") {
		return
	}
	r.programs += 1
	if !check(r, launch(p), "and it launches") {
		finish(r, p, "and is taken down")
		return
	}
	if !check(r, wait(p, PATIENCE), "the parent comes back") {
		finish(r, p, "and is taken down")
		return
	}

	childpid := cell(p, NOWAITER_PID)
	check(r, childpid > 0, "it forked a child, RFPROC and RFNOWAIT")
	check(
		r,
		cell(p, NOWAITER_WAITED) == refused(vectra9.ECHILD),
		"and could not wait for it -- a detached child is the kernel's",
	)

	finish(r, p, "the parent is taken down")
	r.programs += 1 // The detached child is a process too, counted where it is collected.

	// The child is the kernel's now: parent zero, detached, its own to run.
	child := find_child(0, childpid)
	if !check(r, child != nil && child.detached, "the child stands alone, detached to the kernel") {
		return
	}

	done := false
	for _ in 0 ..< PATIENCE {
		if exit_done(child) {
			done = true
			break
		}
		sync.delay(1)
	}
	check(r, done, "it runs to its own end with nobody watching")
	check(
		r,
		child.exit.deliberate && child.exit.status == NOWAITER_CHILD_STATUS,
		"with the status it chose",
	)

	before := stats().live
	collected := reap_orphans()
	check(r, collected >= 1, "and reap_orphans collects it -- the orphan leak retired")
	check(r, stats().live < before, "so the machine holds one process fewer")
}

/*
verify_rfork holds the fork to Plan 9's rules, one blob per claim.

The four claims, in order. Two processes return from one call, and a copied
data page isolates them. `RFMEM` shares the page instead, and the sharing
outlives the parent. The kernel talks to the orphan through the dead
parent's alias, which is the segment count doing real work.

A shared descriptor group spends a close once. A copied one spends it
twice. And the flag word refuses what the kernel does not implement,
loudly.

The bracket is the segment and table pools. Every path through here has to
give back what it took, and the two sensors are what the negative controls
in `docs/TESTING.md` lean on.
*/
@(private = "file")
verify_rfork :: proc(r: ^Result) {
	segs0 := segment_stats()
	tables0 := fdt_stats()

	// -- Two processes return from one call, and a copy divides them ----------

	p, err := load("forker", program_forker())
	if !check(r, err == .None && p != nil, "a program that forks starts") {
		return
	}
	r.programs += 1
	if check(r, wait(p, PATIENCE), "and both of it come back") {
		check(r, cell(p, CELL_MARK) == MARK_FORKER, "having reached its first instruction")
		check(r, i64(cell(p, FORKER_PID)) > 0, "the parent was answered a pid")
		check(
			r,
			cell(p, FORKER_STATUS) == FORKER_SEED + 1,
			"the child continued from the call site, saw the seed, and moved it",
		)
		check(
			r,
			cell(p, FORKER_ISO) == FORKER_SEED,
			"and the parent's copy never felt the child's write",
		)
		check(r, p.exit.deliberate && p.exit.status == 0, "the parent collected it and left")
	}
	finish(r, p, "and the forker is taken down")

	// -- RFMEM shares the page, and the share outlives the parent -------------

	p, err = load("memfork", program_memfork())
	if !check(r, err == .None && p != nil, "a program that shares memory starts") {
		return
	}
	r.programs += 1
	if !check(r, wait(p, PATIENCE), "the parent exits first, child still running") {
		return
	}
	check(r, p.exit.deliberate && p.exit.status == MEMFORK_PARENT_STATUS, "and says so")

	child := find_child(p.pid, u64(cell(p, MEMFORK_PID)))
	if !check(r, child != nil, "the child is still in the table") {
		_ = destroy(p)
		return
	}

	// The structure, while both records stand: one text segment between
	// them, one data segment between them, and two stacks that share
	// nothing. The pointers are the proof, and the stack frames the
	// counter-proof.
	check(r, child.segs[0] == p.segs[0], "the child holds the parent's text segment itself")
	check(r, child.segs[1] == p.segs[1], "and under RFMEM the data segment itself")
	check(r, child.segs[2] != p.segs[2], "but never the stack segment")
	check(
		r,
		child.segs[2].frames[0] != p.segs[2].frames[0],
		"whose frames are the child's own",
	)

	shared_text := p.segs[0].frames[0]
	shared_data := p.data
	check(r, destroy(p), "the parent is collected while the child runs")
	check(r, !mem.frame_is_free(shared_text), "and the shared text stays mapped")
	check(r, segment_stats().live > segs0.live, "held by the segments the child keeps")

	// The parent's teardown reparented the child, so a pid that will never
	// call `wait` no longer dangles at the front of it. The kernel is the
	// child's now, and `reap_orphans` is what its record answers to.
	check(
		r,
		child.parent == 0 && child.detached,
		"and the parent's going reparented the child to the kernel",
	)

	// The witness crossed the shared page, and the stop goes back the same
	// way. It is written through what was the parent's data alias, now
	// nobody's but the segment's.
	saw := false
	for _ in 0 ..< PATIENCE {
		if cell(child, MEMFORK_WITNESS) == MEMFORK_WITNESS_VALUE {
			saw = true
			break
		}
		sync.delay(1)
	}
	check(r, saw, "the child's write arrived through the shared frame")
	check(r, child.data == shared_data, "which is the frame the parent's alias named")

	set_cell(child, MEMFORK_STOP, 1)
	if check(r, wait(child, PATIENCE), "the kernel's write releases the orphan") {
		check(
			r,
			child.exit.deliberate && child.exit.status == 0,
			"and it leaves on its own terms",
		)
	}
	finish(r, child, "the orphan is taken down")
	check(r, mem.frame_is_free(shared_text), "and the last release frees the shared text")

	// -- A shared descriptor group spends a close once ------------------------

	p, err = load("fdforker", program_fdforker(), RFPROC)
	if !check(r, err == .None && p != nil, "a program forks sharing its descriptors") {
		return
	}
	r.programs += 1
	if check(r, wait(p, PATIENCE), "and comes back") {
		check(r, cell(p, FDFORKER_WAITED) == 0, "the child closed descriptor 1 and left")
		check(
			r,
			cell(p, FDFORKER_CLOSED) == refused(vectra9.EBADF),
			"and the parent's own close finds it already spent -- one table",
		)
	}
	finish(r, p, "and the sharer is taken down")

	p, err = load("fdforker", program_fdforker(), RFPROC | RFFDG)
	if !check(r, err == .None && p != nil, "the same program forks with RFFDG") {
		return
	}
	r.programs += 1
	if check(r, wait(p, PATIENCE), "and comes back") {
		check(r, cell(p, FDFORKER_WAITED) == 0, "the child closed its copy's descriptor 1")
		check(
			r,
			i64(cell(p, FDFORKER_CLOSED)) == 0,
			"and the parent's close still finds its own -- two tables",
		)
	}
	finish(r, p, "and the copier is taken down")

	// -- The flag word refuses what it does not mean --------------------------

	p, err = load("refuser", program_refuser())
	if !check(r, err == .None && p != nil, "a program holds the flags to their refusals") {
		return
	}
	r.programs += 1
	if check(r, wait(p, PATIENCE), "and comes back") {
		check(r, cell(p, REFUSER_ENVG) == refused(vectra9.EINVAL), "an environment group is refused")
		check(r, cell(p, REFUSER_NOWAIT) == refused(vectra9.EINVAL), "dissociation is refused")
		check(
			r,
			cell(p, REFUSER_LONE_MEM) == refused(vectra9.EINVAL),
			"a memory share with no child is refused",
		)
		check(
			r,
			cell(p, REFUSER_BOTH_FDG) == refused(vectra9.EINVAL),
			"copy-and-clean together is refused",
		)
		check(r, cell(p, REFUSER_NOMNT) == refused(vectra9.EINVAL), "mount restriction is refused")
		check(r, cell(p, REFUSER_NOTHING) == 0, "while no flags at all asks for nothing and gets it")
		check(r, cell(p, REFUSER_NOTEG) == 0, "and a fresh note group is granted in place")
	}
	finish(r, p, "and the refuser is taken down")

	check(r, segment_stats().live == segs0.live, "every fork's segments came back")
	check(r, fdt_stats() == tables0, "and every descriptor group")
}

// await_posted polls /srv for the name a spawned server should post, with
// the suite's patience. Bounded, because a hang says nothing.
@(private = "file")
await_posted :: proc(name: string) -> bool {
	for _ in 0 ..< PATIENCE {
		if srv.lookup(name) != nil {
			return true
		}
		sync.delay(1)
	}
	return false
}

// drain_pinned collects orphans and dead threads until the heap reads
// level with the bracket's opening, then checks it got there. The tail
// every server test ends on, written once.
@(private = "file")
drain_pinned :: proc(r: ^Result, pin_before: int, what: string) {
	pinned := 0
	for _ in 0 ..< PATIENCE {
		reap_orphans()
		sched.reap()
		pinned = mem.live_objects(mem.heap_stats()) - pin_before
		if pinned == 0 {
			break
		}
		sync.delay(1)
	}
	check(r, pinned == 0, what)
	r.pinned += pinned
}

// The line the kernel types at the console server, byte by byte through the
// keyboard sink, exactly as IRQ 1's bottom half would deliver it. The
// newline is what the cooked discipline releases a line on.
@(private = "file")
CONSRV_TYPED :: "vectra lives\n"

/*
One read of a mounted file, on a thread, and what it came back with.

A read that parks cannot run on the boot thread -- a read that never returns
would print nothing after it. `done` goes true when the read returns, watched
from the boot thread with a bound. Shared by the three servers whose reads
park, `consrv`, `kbdfs` and `eiafs`.
*/
@(private = "file")
Mount_Reader :: struct {
	c:    ^vfs.Chan,
	n:    int,
	err:  vfs.Errno,
	done: bool,
	buf:  [64]u8,
}

@(private = "file")
mount_reader: Mount_Reader

@(private = "file")
mount_read_thread :: proc "contextless" (arg: rawptr) {
	context = runtime.default_context()
	context.allocator = mem.allocator()
	_ = arg
	mount_reader.n, mount_reader.err = vfs.chan_read(mount_reader.c, 0, mount_reader.buf[:])
	intrinsics.volatile_store(&mount_reader.done, true)
}

/*
verify_consrv is the milestone's showpiece: a server that waits on two
things at once, which is the sentence `docs/HANDOFF.md` kept for three
milestones.

The shape under test. `/bin/consrv` forks with `RFMEM`. Its child parks
reading `/dev/cons` -- a real device read through the transport, a devfs
worker held -- while its parent serves 9P from `/srv/consrv`. Two parked
readers, one process's worth of shared bss between them. The kernel types
a line into the keyboard sink, and reads it back through the mount. The
path is keyboard, child, shared ring, parent, pipe, here -- across ring 3
twice.

Echo goes off first, through `/dev/consctl`. The echo runs on the
*feeding* thread -- this one -- and would paint the injected line into the
boot transcript. The mode reverts when the ctl chan closes, whatever
happens in between.

The teardown is the note doing the job it was built for. A remove stops
the serve loop. The parent notes its reader out of a parked device read,
collects EINTR, and exits zero **only if it heard it**. Status 0x75 is a
teardown that ended some other way.
*/
@(private = "file")
verify_consrv :: proc(r: ^Result) {
	count0 := srv.count()
	sched.reap()
	pin_before := mem.live_objects(mem.heap_stats())

	// -- The image is served, and is the second format ------------------------

	if _, image_ok := image_header(r, "/bin/consrv", "/bin serves the console server's image");
	   !image_ok {
		return
	}

	// -- It starts, forks, and posts ------------------------------------------

	p, serr := spawn_path(nil, "/bin/consrv", SPAWN_NS_COPY)
	if !check(r, serr == vfs.OK && p != nil, "the loader starts the console server") {
		return
	}
	r.programs += 1

	posted := await_posted("consrv")
	if !check(r, posted, "it forks its reader and posts /srv/consrv") {
		return
	}
	check(
		r,
		srv.mount(vfs.boot_namespace, "/srv/consrv", "/mnt") == vfs.OK,
		"the kernel mounts it",
	)

	nc, oerr := vfs.open_path(vfs.boot_namespace, "/mnt/line", vfs.O_RDONLY)
	if !check(r, oerr == vfs.OK, "and opens the line file through the mount") {
		return
	}

	// -- A read parks, and the connection serves others while it does ---------

	/*
	The wart is gone: a read of `/line` with nothing typed **parks** now,
	rather than answering empty. The read runs on a thread of its own, because
	a read that never returns on the boot thread would print nothing after it.
	`serve_mux` hands it to a worker, so the server can answer other requests
	while it waits -- which the getattr below proves.
	*/
	mount_reader = Mount_Reader{c = nc}
	if !check(r, sched.spawn("consrv-read", mount_read_thread, nil) != nil, "a thread to read /line") {
		return
	}

	// It stays parked. A read that answered empty would come back at once.
	parked := true
	for _ in 0 ..< 20 {
		sync.delay(1)
		if intrinsics.volatile_load(&mount_reader.done) {
			parked = false
			break
		}
	}
	check(r, parked, "the read parks on the empty line, rather than answering empty")

	// And the server answers another request while that read is parked. The
	// getattr is inline in the main loop, the read off in a worker.
	if root, rerr := vfs.resolve(vfs.boot_namespace, "/mnt"); rerr == vfs.OK {
		_, aerr := vfs.chan_stat(root)
		// The getattr runs inline in the main loop while the read waits off in
		// a worker, which is the whole point of the mux.
		check(r, aerr == vfs.OK, "and a stat is answered while the read still parks")
		check(r, !intrinsics.volatile_load(&mount_reader.done), "which did not wake the parked read")
		vfs.chan_close(root)
	}

	// -- A line is typed, and wakes the parked read ---------------------------

	ctl, cerr := vfs.open_path(vfs.boot_namespace, "/dev/consctl", vfs.O_WRONLY)
	if check(r, cerr == vfs.OK, "the kernel takes the echo off first") {
		off := "echooff"
		_, _ = vfs.chan_write(ctl, 0, transmute([]u8)off)
	}

	typed := CONSRV_TYPED
	for i in 0 ..< len(typed) {
		devfs.keyboard_sink(typed[i])
	}

	woke := false
	for _ in 0 ..< PATIENCE {
		if intrinsics.volatile_load(&mount_reader.done) {
			woke = true
			break
		}
		sync.delay(1)
	}
	check(r, woke, "the parked read wakes when the line is typed")
	check(
		r,
		mount_reader.err == vfs.OK &&
		string(mount_reader.buf[:mount_reader.n]) == CONSRV_TYPED,
		"carrying the whole line: keyboard, reader, shared ring, worker, wire",
	)

	if ctl != nil {
		vfs.chan_close(ctl)
	}

	// -- The teardown: a remove, a note, an EINTR, an exit --------------------

	check(r, vfs.chan_remove(nc) == vfs.OK, "a remove is answered, and is the stop")
	vfs.chan_close(nc)

	if check(r, wait(p, PATIENCE), "the server exits") {
		check(
			r,
			p.exit.deliberate && p.exit.status == 0,
			"with zero -- its noted reader unwound a parked device read and answered EINTR",
		)
	}

	check(r, srv.remove("consrv") == vfs.OK, "the kernel takes the name away")
	check(r, srv.count() == count0, "and /srv holds what it held")

	finish(r, p, "and the server is taken down")

	pipe.quiesce()
	check(
		r,
		vfs.unmount_path(vfs.boot_namespace, "", "/mnt") == vfs.OK,
		"the mount of the dead server comes down",
	)

	// The concurrent serve loop forked a worker per parked read, each
	// detached and left for the kernel. Collect them before measuring, the
	// way a live server would when its next fork wanted a slot.
	drain_pinned(r, pin_before, "and the forked server's wire comes back whole")
}

// The scancodes the kernel injects into `/dev/scancode`, and the characters
// `kbdfs` translates them to. `k b d` are make codes, then a shift press, a
// `1` that shifts to `!`, a shift release, and Enter. The releases and the
// shift itself produce nothing, so the cooked stream is five characters.
@(private = "file")
KBDFS_CODES :: [?]u8{0x25, 0x30, 0x20, 0x2A, 0x02, 0xAA, 0x1C}
@(private = "file")
KBDFS_COOKED :: "kbd!\n"

/*
verify_kbdfs is the userland devfs's first tenant: a kernel service rebuilt
as a program.

`kbdfs` opens `/dev/scancode`, which diverts the raw scancodes to it, and
serves the characters it translates from them on `/kbd`. The translation is
`kernel/drivers/kbd`'s, in ring 3 now. So this test injects make codes the
way the keyboard self-test does, and reads the cooked result back through a
mount instead.

The read of `/kbd` parks in a worker, so it runs on a thread. Between the open
and the first scancode it waits, which is the proof the file blocks on a key
rather than answering empty. Then the kernel injects `kbd!` and a newline as
scancodes. The parked read wakes carrying exactly the characters the state
machine makes -- shift included, since one of them is shifted.
*/
@(private = "file")
verify_kbdfs :: proc(r: ^Result) {
	count0 := srv.count()
	sched.reap()
	pin_before := mem.live_objects(mem.heap_stats())

	p, serr := spawn_path(nil, "/bin/kbdfs", SPAWN_NS_COPY)
	if !check(r, serr == vfs.OK && p != nil, "the loader starts the keyboard translator") {
		return
	}
	r.programs += 1

	posted := await_posted("kbdfs")
	if !check(r, posted, "it forks its reader, opens /dev/scancode, and posts /srv/kbdfs") {
		return
	}
	check(
		r,
		srv.mount(vfs.boot_namespace, "/srv/kbdfs", "/mnt") == vfs.OK,
		"the kernel mounts it",
	)

	kc, oerr := vfs.open_path(vfs.boot_namespace, "/mnt/kbd", vfs.O_RDONLY)
	if !check(r, oerr == vfs.OK, "and opens the cooked keyboard file") {
		return
	}

	// The read parks: no key is pressed, and the translated stream is empty.
	// On a thread, because a parked read never returns.
	mount_reader = Mount_Reader{c = kc}
	if !check(r, sched.spawn("kbdfs-read", mount_read_thread, nil) != nil, "a thread to read /kbd") {
		return
	}
	parked := true
	for _ in 0 ..< 20 {
		sync.delay(1)
		if intrinsics.volatile_load(&mount_reader.done) {
			parked = false
			break
		}
	}
	check(r, parked, "a read of /kbd parks until a key, rather than answering empty")

	// Opening /dev/scancode diverted the raw stream to kbdfs. The kernel's own
	// translation sees nothing now, which is what the diversion is for.
	check(r, devfs.tap_active(&devfs.tree().scancode), "opening the file diverted the raw stream to it")

	// The kernel presses keys at the controller's level. `kbdfs`'s reader
	// child drains them from /dev/scancode and translates.
	codes := KBDFS_CODES
	for i in 0 ..< len(codes) {
		devfs.scancode_tap(codes[i])
	}
	drained := false
	for _ in 0 ..< PATIENCE {
		if !devfs.tap_available(&devfs.tree().scancode) {
			drained = true
			break
		}
		sync.delay(1)
	}
	check(r, drained, "and its reader child drains them from the raw stream")

	woke := false
	for _ in 0 ..< PATIENCE {
		if intrinsics.volatile_load(&mount_reader.done) {
			woke = true
			break
		}
		sync.delay(1)
	}
	check(r, woke, "the parked read wakes when the keys are pressed")
	check(
		r,
		mount_reader.err == vfs.OK &&
		string(mount_reader.buf[:mount_reader.n]) == KBDFS_COOKED,
		"carrying the characters the state machine made: scancodes, shift and all",
	)

	// -- Teardown, the same arc consrv taught --------------------------------

	check(r, vfs.chan_remove(kc) == vfs.OK, "a remove is answered, and is the stop")
	vfs.chan_close(kc)

	if check(r, wait(p, PATIENCE), "the translator exits") {
		check(
			r,
			p.exit.deliberate && p.exit.status == 0,
			"with zero -- its noted reader unwound a parked scancode read",
		)
	}

	check(r, srv.remove("kbdfs") == vfs.OK, "the kernel takes the name away")
	check(r, srv.count() == count0, "and /srv holds what it held")

	finish(r, p, "and the translator is taken down")

	pipe.quiesce()
	check(
		r,
		vfs.unmount_path(vfs.boot_namespace, "", "/mnt") == vfs.OK,
		"the mount of the dead translator comes down",
	)

	drain_pinned(r, pin_before, "and the translator's wire comes back whole")
}

// The bytes the kernel puts on the raw serial stream, through the producer's
// own seam. The newline matters: it comes back as a newline, because the
// diverted stream passes no line discipline that could cook it.
@(private = "file")
EIAFS_SENT :: "eia0 raw\n"

/*
verify_eiafs is the userland devfs's second tenant, and the first server
whose Twrite reaches hardware.

`eiafs` opens `/dev/eia0`, which diverts the port's bytes to it, and serves
them raw on `/eia0`. There is no translator: the port's bytes are already
the content, and the proof is the newline coming back uncooked. The write
half is the new ground. A write through the mount goes down the server's
shared descriptor and out the wire. The console's own write count does not
move -- the bytes took the raw path, not the cooked one.

The whole check stands behind `input_started`. A machine whose port failed
its probe answers ENXIO to the server's open. A server with nothing to
serve is not a reason to fail the boot.
*/
@(private = "file")
verify_eiafs :: proc(r: ^Result) {
	if !devfs.input_started() {
		return
	}

	count0 := srv.count()
	sched.reap()
	pin_before := mem.live_objects(mem.heap_stats())

	p, serr := spawn_path(nil, "/bin/eiafs", SPAWN_NS_COPY)
	if !check(r, serr == vfs.OK && p != nil, "the loader starts the serial server") {
		return
	}
	r.programs += 1

	posted := await_posted("eiafs")
	if !check(r, posted, "it forks its reader, opens /dev/eia0, and posts /srv/eiafs") {
		return
	}
	check(
		r,
		srv.mount(vfs.boot_namespace, "/srv/eiafs", "/mnt") == vfs.OK,
		"the kernel mounts it",
	)

	ec, oerr := vfs.open_path(vfs.boot_namespace, "/mnt/eia0", vfs.O_RDWR)
	if !check(r, oerr == vfs.OK, "and opens the port file through the mount") {
		return
	}

	// The read parks: the wire is silent, and the served ring is empty. On a
	// thread, because a parked read never returns.
	mount_reader = Mount_Reader{c = ec}
	if !check(r, sched.spawn("eiafs-read", mount_read_thread, nil) != nil, "a thread to read /eia0") {
		return
	}
	parked := true
	for _ in 0 ..< 20 {
		sync.delay(1)
		if intrinsics.volatile_load(&mount_reader.done) {
			parked = false
			break
		}
	}
	check(r, parked, "a read of /eia0 parks until the wire speaks, rather than answering empty")

	// Opening /dev/eia0 diverted the port's bytes to eiafs. The kernel's own
	// line discipline sees nothing now, which is what the diversion is for.
	check(r, devfs.tap_active(&devfs.tree().serial), "opening the file diverted the port's bytes to it")

	// The kernel puts bytes on the stream at the poller's level. `eiafs`'s
	// reader child drains them from /dev/eia0, uncooked.
	sent := EIAFS_SENT
	for i in 0 ..< len(sent) {
		devfs.serial_deliver(&devfs.tree().cons, sent[i])
	}
	drained := false
	for _ in 0 ..< PATIENCE {
		if !devfs.tap_available(&devfs.tree().serial) {
			drained = true
			break
		}
		sync.delay(1)
	}
	check(r, drained, "and its reader child drains them from the raw stream")

	woke := false
	for _ in 0 ..< PATIENCE {
		if intrinsics.volatile_load(&mount_reader.done) {
			woke = true
			break
		}
		sync.delay(1)
	}
	check(r, woke, "the parked read wakes when the wire speaks")
	check(
		r,
		mount_reader.err == vfs.OK &&
		string(mount_reader.buf[:mount_reader.n]) == EIAFS_SENT,
		"carrying the port's bytes unchanged, newline and all",
	)

	// -- The new ground: a write that reaches hardware ------------------------

	/*
	The bytes go through the mount, down the server's shared descriptor, and
	out the wire -- the first userland Twrite that reaches a device. The
	console's own count stands still, which is the proof the bytes took the
	raw path. The line itself lands in a captured boot log, the way the devfs
	test's wire line does.
	*/
	writes_before := devfs.tree().cons.writes
	line := "-- these bytes went through a ring 3 server to the wire\n"
	wn, werr := vfs.chan_write(ec, 0, transmute([]u8)line)
	check(r, werr == vfs.OK && wn == len(line), "a write through the mount takes every byte, out the wire")
	check(r, devfs.tree().cons.writes == writes_before, "without touching the console's own count")

	// -- Teardown, the same arc consrv taught ---------------------------------

	check(r, vfs.chan_remove(ec) == vfs.OK, "a remove is answered, and is the stop")
	vfs.chan_close(ec)

	if check(r, wait(p, PATIENCE), "the serial server exits") {
		check(
			r,
			p.exit.deliberate && p.exit.status == 0,
			"with zero -- its noted reader unwound a parked port read",
		)
	}

	check(r, srv.remove("eiafs") == vfs.OK, "the kernel takes the name away")
	check(r, srv.count() == count0, "and /srv holds what it held")

	finish(r, p, "and the serial server is taken down")

	pipe.quiesce()
	check(
		r,
		vfs.unmount_path(vfs.boot_namespace, "", "/mnt") == vfs.OK,
		"the mount of the dead server comes down",
	)

	drain_pinned(r, pin_before, "and the serial server's wire comes back whole")
}

/*
verify_draw is the draw server against its own design document.

`intuition`'s first half serves `docs/DRAW.md`'s six verbs over the screen.
The test speaks them through a mount and checks the glass, the way the
painter test taught. What a command stream claims to draw must read back
from the framebuffer's own memory. One write carries the whole batch,
which is the property the protocol exists for.

The rules get one check each. A fill past the edge clips rather than
errors. A malformed command fails its whole write, and what stood before
it already drew. A free answers once and refuses twice. And a clunk gives
a session's images back, proved by a pool filled, closed, and refilled.
*/
@(private = "file")
verify_draw :: proc(r: ^Result) #no_bounds_check {
	s := devfs.raw_surface()
	if s == nil || s.pixels == nil || s.bytes_pp != 4 {
		return
	}

	count0 := srv.count()
	sched.reap()
	pin_before := mem.live_objects(mem.heap_stats())

	p, serr := spawn_path(nil, "/bin/intuition", SPAWN_NS_COPY)
	if !check(r, serr == vfs.OK && p != nil, "the loader starts the draw server") {
		return
	}
	r.programs += 1

	posted := await_posted("draw")
	if !check(r, posted, "it reads the screen's shape and posts /srv/draw") {
		return
	}
	check(
		r,
		srv.mount(vfs.boot_namespace, "/srv/draw", "/mnt") == vfs.OK,
		"the kernel mounts it",
	)

	ctl, cerr := vfs.open_path(vfs.boot_namespace, "/mnt/ctl", vfs.O_RDONLY)
	if !check(r, cerr == vfs.OK, "and opens its ctl file") {
		return
	}
	// Wide enough for the whole report, because the test parses it now rather
	// than glancing at its first word.
	geo: [64]u8
	gn, gerr := vfs.chan_read(ctl, 0, geo[:])
	check(
		r,
		gerr == vfs.OK && gn >= 5 && string(geo[:5]) == "size ",
		"whose read answers a geometry",
	)

	/*
	And the geometry is a *window's*, not the screen's.

	A client that could read the screen's width could tell how much of it it
	was not being given. `/ctl` answers with the tile every session gets, which
	is all a client needs to lay itself out and all it may know.
	*/
	win_w, win_h, _, _, geo_ok := libdraw.parse_geometry(geo[:max(gn, 0)])
	check(r, geo_ok, "which parses as four numbers")
	check(r, win_w > 0 && win_w < s.width, "and is narrower than the screen it does not name")
	check(r, win_h == s.height, "at the screen's full height, which is the placement policy")

	dc, oerr := vfs.open_path(vfs.boot_namespace, "/mnt/data", vfs.O_WRONLY)
	if !check(r, oerr == vfs.OK, "and the command file opens for writing") {
		return
	}

	// The region the test paints, saved to be restored. Four rows of 48
	// pixels on the left, and eight pixels at the right edge of the first.
	y0 := s.height - 16
	// Eight pixels short of the *window's* right edge, so a fill of sixteen
	// runs past it. The coordinate is the client's, and a client's
	// coordinates start at its own origin.
	edge_x := win_w - 8
	saved_a: [4 * 48 * 4]u8
	for line in 0 ..< 4 {
		o := (y0 + line) * s.pitch
		copy(saved_a[line * 192:][:192], s.pixels[o:o + 192])
	}
	saved_b: [8 * 4]u8
	copy(saved_b[:], s.pixels[y0 * s.pitch + edge_x * 4:][:8 * 4])

	// -- One write, five verbs, and the glass answers -------------------------

	C1 :: u32(0x00336699)
	C3 :: u32(0x00CC2200)
	pat: [128]u8
	for i in 0 ..< 32 {
		libdraw.put_u32(pat[:], i * 4, u32(0x00400000) | u32(i))
	}

	buf: [512]u8
	at := libdraw.put_fill(buf[:], 0, 0, 8, u32(y0), 16, 4, C1)
	at = libdraw.put_alloc(buf[:], at, 1, 8, 4)
	at = libdraw.put_load(buf[:], at, 1, 0, 0, 8, 4, pat[:])
	at = libdraw.put_blit(buf[:], at, 0, 32, u32(y0), 1, 0, 0, 8, 4)
	at = libdraw.put_flush(buf[:], at)
	wn, werr := vfs.chan_write(dc, 0, buf[:at])
	check(
		r,
		at > 0 && werr == vfs.OK && wn == at,
		"one write carries a fill, an image, a load, a blit, and a flush",
	)
	check(
		r,
		fb.get_raw(s, 8, y0) == C1 && fb.get_raw(s, 23, y0 + 3) == C1,
		"the fill landed on the glass, corner to corner",
	)
	blitted := true
	for line in 0 ..< 4 {
		for i in 0 ..< 8 {
			if fb.get_raw(s, 32 + i, y0 + line) != (u32(0x00400000) | u32(line * 8 + i)) {
				blitted = false
			}
		}
	}
	check(r, blitted, "and the blit landed the loaded pixels beside it")

	// -- The rules, one check each --------------------------------------------

	/*
	The spill a dropped clip makes is not a refused write. The file is
	offset-addressed over the whole frame, so an unclipped edge fill wraps
	onto the next row's left edge instead of failing. The pixel watched
	here is that landing spot, which is what makes this check strong. The
	first cut watched only the painted edge, and the control walked past it.
	*/
	spill_before := fb.get_raw(s, 0, y0 + 1)
	beyond_before := fb.get_raw(s, win_w, y0)
	at = libdraw.put_fill(buf[:], 0, 0, u32(edge_x), u32(y0), 16, 1, C1)
	_, werr = vfs.chan_write(dc, 0, buf[:at])
	check(r, werr == vfs.OK, "a fill past the edge clips rather than errors")
	check(r, fb.get_raw(s, win_w - 1, y0) == C1, "and paints up to its window's last pixel")
	check(r, fb.get_raw(s, 0, y0 + 1) == spill_before, "and spills nothing onto the row below")
	/*
	And nothing one pixel further, which is the window's edge rather than the
	screen's.

	The check above would pass on a server that clipped to the glass, because
	the window's last column is a real column either way. This one is what says
	the *window* is the bound. It watches the first pixel a client may not
	have.
	*/
	check(r, fb.get_raw(s, win_w, y0) == beyond_before, "and nothing at all past it")

	at = libdraw.put_fill(buf[:], 0, 0, 8, u32(y0), 4, 1, C3)
	buf[at] = 4
	buf[at + 1] = 0
	buf[at + 2] = 9
	buf[at + 3] = 0
	_, werr = vfs.chan_write(dc, 0, buf[:at + 4])
	check(r, werr != vfs.OK, "a malformed command fails the whole write")
	check(r, fb.get_raw(s, 8, y0) == C3, "and what stood before it already drew")

	at = libdraw.put_free(buf[:], 0, 1)
	_, werr = vfs.chan_write(dc, 0, buf[:at])
	check(r, werr == vfs.OK, "a free is answered once")
	_, werr = vfs.chan_write(dc, 0, buf[:at])
	check(r, werr != vfs.OK, "and refused twice")

	// -- Two sessions, two windows -------------------------------------------
	//
	// While `dc` is still open, because the claim is about two windows held at
	// once. The image-pool test below closes it.
	verify_windows(r, s, win_w, y0 - 2, dc)

	at = 0
	for id in 1 ..= 8 {
		at = libdraw.put_alloc(buf[:], at, u32(id), 8, 4)
	}
	_, werr = vfs.chan_write(dc, 0, buf[:at])
	check(r, werr == vfs.OK, "a session fills the whole image pool")
	vfs.chan_close(dc)
	dc2, o2 := vfs.open_path(vfs.boot_namespace, "/mnt/data", vfs.O_WRONLY)
	if check(r, o2 == vfs.OK, "the command file opens again") {
		at = libdraw.put_alloc(buf[:], 0, 1, 8, 4)
		_, werr = vfs.chan_write(dc2, 0, buf[:at])
		check(r, werr == vfs.OK, "and the clunk gave the session's images back")
		vfs.chan_close(dc2)
	}

	// Put the glass back the way it was found.
	for line in 0 ..< 4 {
		o := (y0 + line) * s.pitch
		copy(s.pixels[o:o + 192], saved_a[line * 192:][:192])
	}
	copy(s.pixels[y0 * s.pitch + edge_x * 4:][:8 * 4], saved_b[:])

	// -- Teardown, the arc every tenant obeys ---------------------------------

	check(r, vfs.chan_remove(ctl) == vfs.OK, "a remove is answered, and is the stop")
	vfs.chan_close(ctl)

	if check(r, wait(p, PATIENCE), "the draw server exits") {
		check(
			r,
			p.exit.deliberate && p.exit.status == 0,
			"with zero -- the remove was the stop it obeyed",
		)
	}

	check(r, srv.remove("draw") == vfs.OK, "the kernel takes the name away")
	check(r, srv.count() == count0, "and /srv holds what it held")

	finish(r, p, "and the draw server is taken down")

	pipe.quiesce()
	check(
		r,
		vfs.unmount_path(vfs.boot_namespace, "", "/mnt") == vfs.OK,
		"the mount of the dead server comes down",
	)

	drain_pinned(r, pin_before, "and the draw server's wire comes back whole")
}

// The terminal's two colors, duplicated as fixtures. A test that read
// them from the code under test would agree with itself.
@(private = "file")
TERM_FG :: u32(0x00FFB028)
@(private = "file")
TERM_BG :: u32(0x00181F28)

// What the terminal paints over, saved to be restored: 16 rows of 352
// pixels. In the bss, because 22 KiB does not belong on a kernel stack.
@(private = "file")
term_saved: [16 * 352 * 4]u8

/*
glyph_on_glass compares one 8x16 cell on the screen against the one font
table, pixel for pixel, in the terminal's colors.

The comparison is deliberately exact rather than any-lit-pixel. The
controls that swap the atlas arithmetic or invert the bit expansion still
light pixels -- the wrong ones. Only an exact cell tells a right glyph
from a wrong one.
*/
@(private = "file")
glyph_on_glass :: proc "contextless" (s: ^fb.Surface, x: int, y: int, ch: u8) -> bool #no_bounds_check {
	rows := &libfont.font_8x16[int(ch) - libfont.FONT_FIRST]
	for line in 0 ..< libfont.FONT_HEIGHT {
		bits := rows[line]
		for i in 0 ..< libfont.FONT_WIDTH {
			want := bits & (0x80 >> u8(i)) != 0 ? TERM_FG : TERM_BG
			if fb.get_raw(s, x + i, y + line) != want {
				return false
			}
		}
	}
	return true
}

/*
verify_terminal is the first program in apps/, run against both services
it consumes.

The terminal is the tree's first ring 3 mounter. The kernel leaves /mnt
alone until it exits, so the mount it draws through is its own work. The
prompt poll waits for the exact `>` glyph, which makes it double as the
font-fidelity check. The echo bracket types three bytes with no newline
and reads the console cursor before and after. Echo runs synchronously
on this thread, so an unmoved cursor is proof, not a race. The typed
`exit` is the teardown's first half, and the draw server's remove is the
second, child-first as every tenant taught.
*/
@(private = "file")
verify_terminal :: proc(r: ^Result, column: proc "contextless" () -> int) #no_bounds_check {
	s := devfs.raw_surface()
	if s == nil || s.pixels == nil || s.bytes_pp != 4 {
		return
	}

	count0 := srv.count()
	sched.reap()
	pin_before := mem.live_objects(mem.heap_stats())

	ps, serr := spawn_path(nil, "/bin/intuition", SPAWN_NS_COPY)
	if !check(r, serr == vfs.OK && ps != nil, "the loader starts the draw server") {
		return
	}
	r.programs += 1

	posted := await_posted("draw")
	if !check(r, posted, "it posts /srv/draw for a client to find") {
		return
	}

	// The field the terminal will paint, saved before it exists.
	y0 := s.height - 40
	for line in 0 ..< 16 {
		o := (y0 + line) * s.pitch + 8 * 4
		copy(term_saved[line * 1408:][:1408], s.pixels[o:o + 1408])
	}

	pt, terr := spawn_path(nil, "/bin/terminal", SPAWN_NS_COPY)
	if !check(r, terr == vfs.OK && pt != nil, "the loader starts the terminal") {
		return
	}
	r.programs += 1

	// The prompt lands only after the terminal mounts the server, reads
	// the geometry, and uploads ninety-five glyphs. The poll waits for
	// the exact glyph, so a wrong atlas never satisfies it.
	prompted := false
	for _ in 0 ..< PATIENCE {
		if glyph_on_glass(s, 8, y0, '>') {
			prompted = true
			break
		}
		sync.delay(1)
	}
	check(r, prompted, "the terminal mounts the server itself and paints its prompt")
	check(r, glyph_on_glass(s, 16, y0, ' '), "whose glyphs match the kernel's own font, pixel for pixel")

	// Three bytes, no newline. Echo runs synchronously on this thread,
	// so the cursor comparison needs no settle loop.
	col0 := column()
	devfs.keyboard_sink('h')
	devfs.keyboard_sink('i')
	devfs.keyboard_sink('!')
	check(r, column() == col0, "three typed bytes move the console cursor nowhere -- the echo is off")

	devfs.keyboard_sink('\n')
	// The poll waits for the line's LAST glyph. The server paints the
	// batch left to right, so the first glyph says only that the batch
	// began. A poll of it once raced the two behind it.
	rendered := false
	for _ in 0 ..< PATIENCE {
		if glyph_on_glass(s, 40, y0, '!') {
			rendered = true
			break
		}
		sync.delay(1)
	}
	check(r, rendered, "the newline completes the line and the terminal renders it")
	check(
		r,
		glyph_on_glass(s, 24, y0, 'h') && glyph_on_glass(s, 32, y0, 'i'),
		"every glyph out of the uploaded atlas, pixel for pixel",
	)
	check(r, glyph_on_glass(s, 48, y0, ' '), "and the cell after the text is background")

	// The typed stop, and the terminal's own exit.
	stop := "exit\n"
	for i in 0 ..< len(stop) {
		devfs.keyboard_sink(stop[i])
	}
	if check(r, wait(pt, PATIENCE), "the typed exit stops the terminal") {
		check(
			r,
			pt.exit.deliberate && pt.exit.status == 0,
			"with zero -- the exit was the terminal's own choice",
		)
	}

	// Put the field back the way it was found.
	for line in 0 ..< 16 {
		o := (y0 + line) * s.pitch + 8 * 4
		copy(s.pixels[o:o + 1408], term_saved[line * 1408:][:1408])
	}

	// The pool proof: the terminal held six strip images, and its exit
	// clunked them away. A fresh session that allocates all eight shows
	// nothing leaked.
	check(
		r,
		srv.mount(vfs.boot_namespace, "/srv/draw", "/mnt") == vfs.OK,
		"the kernel mounts the draw server",
	)
	refilled := false
	if dc, oerr := vfs.open_path(vfs.boot_namespace, "/mnt/data", vfs.O_WRONLY); oerr == vfs.OK {
		pool: [160]u8
		at := 0
		for id in 1 ..= 8 {
			at = libdraw.put_alloc(pool[:], at, u32(id), 8, 4)
		}
		_, werr := vfs.chan_write(dc, 0, pool[:at])
		refilled = werr == vfs.OK
		vfs.chan_close(dc)
	}
	check(
		r,
		refilled,
		"a fresh session allocates the whole pool -- the dead terminal's images came back",
	)

	// -- Teardown, the draw server's half -------------------------------------

	ctl, cerr := vfs.open_path(vfs.boot_namespace, "/mnt/ctl", vfs.O_RDONLY)
	if check(r, cerr == vfs.OK, "and opens its ctl file") {
		check(r, vfs.chan_remove(ctl) == vfs.OK, "a remove is answered, and is the stop")
		vfs.chan_close(ctl)
	}

	if check(r, wait(ps, PATIENCE), "the draw server exits") {
		check(
			r,
			ps.exit.deliberate && ps.exit.status == 0,
			"with zero -- the remove was the stop it obeyed",
		)
	}

	check(r, srv.remove("draw") == vfs.OK, "the kernel takes the name away")
	check(r, srv.count() == count0, "and /srv holds what it held")

	finish(r, pt, "and the terminal is taken down")
	finish(r, ps, "and the draw server is taken down")

	pipe.quiesce()
	check(
		r,
		vfs.unmount_path(vfs.boot_namespace, "", "/mnt") == vfs.OK,
		"the mount of the dead server comes down",
	)

	drain_pinned(r, pin_before, "and the first app's wire comes back whole")
}

/*
verify_mapping attaches the framebuffer to a process and checks what that
costs and what it does not.

**The mapping is already load-bearing before this runs.** `servers/intuition`
has no write path left, so every check in `verify_draw` above goes through a
store to mapped memory.

This adds the four things that path cannot show. Which files may be attached.
What the pages carry. Whether a second attach is a second address. And whether
a process ending gives the card back to nobody.

`docs/DRAW.md` section 7 itemised all four a milestone before the code.
*/
@(private = "file")
verify_mapping :: proc(r: ^Result) {
	check(r, len(PATH_FB) == 7 && len(PATH_CONS) == 9, "the two paths are the lengths the program assumes")

	surface := devfs.raw_surface()
	if !check(r, surface != nil && surface.pixels != nil, "the screen is a surface the kernel can name") {
		return
	}

	// -- What the namespace says a file is ------------------------------------

	fbc, ferr := vfs.open_path(vfs.boot_namespace, PATH_FB, vfs.O_WRONLY)
	if !check(r, ferr == vfs.OK, "/dev/fb opens") {
		return
	}
	phys, bytes, is_device := vfs.chan_device(fbc)
	check(r, is_device, "and answers that it is memory rather than a stream")
	check(
		r,
		phys == mem.virt_to_phys(rawptr(surface.pixels)),
		"at the physical address the surface's direct-map pointer means",
	)
	check(r, bytes >= u64(surface.height * surface.pitch), "for every scanline it has")
	vfs.chan_close(fbc)

	cc, cerr := vfs.open_path(vfs.boot_namespace, PATH_CONS, vfs.O_WRONLY)
	if check(r, cerr == vfs.OK, "/dev/cons opens too") {
		_, _, cons_device := vfs.chan_device(cc)
		check(r, !cons_device, "and answers that it is a stream, which almost every file is")
		vfs.chan_close(cc)
	}

	// -- A process attaches it -------------------------------------------------

	/*
	Where the program stores its one pixel, as a byte offset into the screen.

	The bottom-right corner. The chassis paints it once at boot and nothing
	repaints it. A magenta pixel there at the end of this procedure came from a
	program in ring 3 and from nothing else.
	*/
	corner := (surface.height - 1) * surface.pitch + (surface.width - 1) * 4
	before := fb.get_raw(surface, surface.width - 1, surface.height - 1)

	/*
	The four bytes under that pixel, saved and put back at the end.

	Every other test in this file restores what it paints, and this one did
	not. The pixel is the last of the screen, which is where nothing repaints
	over a mistake and where a screenshot would keep it for ever. Found by
	taking one.
	*/
	corner_saved: [4]u8
	copy(corner_saved[:], surface.pixels[corner:corner + 4])
	defer copy(surface.pixels[corner:corner + 4], corner_saved[:])

	frames_before := mem.pmm_stats().free_frames
	untracked_before := mem.pmm_stats().untracked_frees
	segs_before := segment_stats().live

	p, err := load("mapper", program_mapper(), u64(corner))
	if !check(r, err == .None && p != nil, "a process is loaded that asks for memory") {
		return
	}
	r.programs += 1
	check(r, set_bytes(p, SLOT_A, bytes_of(PATH_FB)), "with the screen's name in its page")
	check(r, set_bytes(p, SLOT_B, bytes_of(PATH_CONS)), "and a stream's name beside it")

	if check(r, wait(p, PATIENCE), "and it comes back") {
		check(r, cell(p, CELL_MARK) == MARK_MAPPER, "having reached its first instruction")
		check(r, cell(p, MAPPER_FD) < u64(MAX_FDS), "the screen opened as an ordinary descriptor")

		addr := uintptr(cell(p, MAPPER_ADDR))
		check(r, addr >= mem.USER_MIN && addr < mem.USER_MAX, "and attached at an address in its own half")

		/*
		And the store went to the glass.

		Read through `fb.get_raw`, which is the kernel's own view of the same
		physical memory through the direct map. Two mappings, two privilege
		levels, one card. That is the whole milestone in one pixel.
		*/
		after := fb.get_raw(surface, surface.width - 1, surface.height - 1)
		check(r, after != before, "a store through it changed the screen")

		/*
		A second attach is a second address, and the check has to say *address*.

		The first version asked only whether the number was larger than the
		first. A control that removed the bump made the second attach fail
		instead. A negative errno reads back as an enormous unsigned number,
		which is larger. The check passed for a reason that had nothing to do
		with what it claimed. See `docs/TESTING.md`.
		*/
		again := uintptr(cell(p, MAPPER_AGAIN))
		check(
			r,
			again >= mem.USER_MIN && again < mem.USER_MAX && again != addr,
			"a second attach is a second address, because two devices cannot share a page",
		)
		check(
			r,
			cell(p, MAPPER_BAD_FD) == refused(vectra9.EBADF),
			"a descriptor nobody opened is refused",
		)
		check(
			r,
			cell(p, MAPPER_STREAM) == refused(vectra9.ENODEV),
			"and a file that is a stream is refused by name rather than mapped",
		)

		perms, perm_ok := mem.permissions(p.space, addr)
		check(r, perm_ok && .User in perms && .Write in perms, "the pages carry user and write")
		check(r, perm_ok && .No_Execute in perms, "and never execute, because no card is code")
	}

	check(r, destroy(p), "the process is taken down")

	/*
	And the card went back to nobody.

	`segment_release` frees a `.Device` segment's frames to no allocator,
	because no allocator ever had them. Two numbers, because two machines.

	On a machine where the framebuffer is *inside* the tracked range, a release
	returns a thousand frames at once, and the free count says so. The
	bound is the screen's own page count against a handful of page tables the
	teardown legitimately gives back. That is three orders of magnitude of
	margin rather than an exact figure.

	On *this* machine the screen sits above every tracked frame, so that free
	would be silent. `mem.free_pages` counts an untracked free for exactly this
	reason, and that number is the one with no confounder in it.
	*/
	fb_pages := int(bytes / u64(arch.PAGE_SIZE))
	returned := mem.pmm_stats().free_frames - frames_before
	check(r, returned < fb_pages, "and the allocator did not get a screen's worth of frames back")
	check(
		r,
		mem.pmm_stats().untracked_frees == untracked_before,
		"with nothing offered back that it never owned",
	)
	check(r, segment_stats().live == segs_before, "every segment it held was released")
}

/*
One screen row, saved while the window checks paint over it.

Static because a kernel self-test has a heap and should not put five kilobytes
through it to look at pixels. The same reason `term_saved` above is static.
*/
@(private = "file")
row_saved: [8192]u8

/*
verify_windows is the milestone's sentence: **two clients hold the same
coordinates and mean two places.**

`first` is a session already open, holding window zero. This opens a second,
which gets window one, and then asks both of them to draw at the origin. The
readback is two different pixels, half a screen apart.

The second half is the stronger claim. The second client asks for a rectangle
wider than the whole screen, and gets its window. A pixel one column *left* of
its origin is the first client's, and it does not move.

The glass is put back before this returns. One row, saved whole, because the
checks below paint across most of its width.
*/
@(private = "file")
verify_windows :: proc(
	r: ^Result,
	s: ^fb.Surface,
	win_w: int,
	y: int,
	first: ^vfs.Chan,
) #no_bounds_check {
	span := s.width * 4
	if span > len(row_saved) || y <= 0 {
		return
	}
	copy(row_saved[:span], s.pixels[y * s.pitch:][:span])

	second, oerr := vfs.open_path(vfs.boot_namespace, "/mnt/data", vfs.O_WRONLY)
	if !check(r, oerr == vfs.OK, "a second client opens the command file") {
		return
	}

	/*
	And a third is refused, because there are two windows.

	A cap rather than a design, and the refusal is the honest form of it. A
	client that cannot have a window learns so at open, before it draws
	anything it would have to take back.
	*/
	third, terr := vfs.open_path(vfs.boot_namespace, "/mnt/data", vfs.O_WRONLY)
	check(r, terr != vfs.OK, "and a third is refused, because a window is what a session is")
	if terr == vfs.OK {
		vfs.chan_close(third)
	}

	A :: u32(0x0011AA33)
	B :: u32(0x00AA1133)
	MARK :: u32(0x00205020)
	buf: [128]u8

	at := libdraw.put_fill(buf[:], 0, 0, 0, u32(y), 8, 1, A)
	_, aerr := vfs.chan_write(first, 0, buf[:at])
	check(r, aerr == vfs.OK, "the first client fills at its own origin")

	at = libdraw.put_fill(buf[:], 0, 0, 0, u32(y), 8, 1, B)
	_, berr := vfs.chan_write(second, 0, buf[:at])
	check(r, berr == vfs.OK, "and the second fills at the same coordinates")

	check(r, fb.get_raw(s, 0, y) == A, "the first landed at the screen's origin")
	check(
		r,
		fb.get_raw(s, win_w, y) == B,
		"and the second half a screen away, which is what a window is",
	)

	/*
	Now the whole world, asked for by the client that may not have it.

	A rectangle wider than the screen, from the second session. It clips to
	that session's window. The last column of the glass is then its own, and
	the column before its origin is still the first client's.
	*/
	at = libdraw.put_fill(buf[:], 0, 0, 0, u32(y), u32(s.width * 2), 1, B)
	_, werr := vfs.chan_write(second, 0, buf[:at])
	check(r, werr == vfs.OK, "the second asks for a rectangle wider than the screen")
	check(r, fb.get_raw(s, s.width - 1, y) == B, "and gets its window, out to the last column")
	check(
		r,
		fb.get_raw(s, win_w - 1, y) != B,
		"and not one pixel of the window beside it",
	)

	/*
	And a blit, which is the only way to prove the *other* translation.

	A control that removed the origin from `run_blit` passed everything, and
	the reason was that every blit in this file came from window zero. There,
	translating by the origin is translating by nothing. This one comes from
	the session half a screen across.
	*/
	pat: [8 * 4]u8
	for i in 0 ..< 8 {
		libdraw.put_u32(pat[:], i * 4, MARK)
	}
	at = libdraw.put_alloc(buf[:], 0, 1, 8, 1)
	at = libdraw.put_load(buf[:], at, 1, 0, 0, 8, 1, pat[:])
	at = libdraw.put_blit(buf[:], at, 0, 16, u32(y), 1, 0, 0, 8, 1)
	_, blerr := vfs.chan_write(second, 0, buf[:at])
	check(r, blerr == vfs.OK, "the second client loads an image and blits it")
	check(r, fb.get_raw(s, win_w + 16, y) == MARK, "which lands inside its own window")
	check(r, fb.get_raw(s, 16, y) != MARK, "and not in the window beside it")

	vfs.chan_close(second)

	// The window comes back with the fid, so a client can open again.
	again, aerr2 := vfs.open_path(vfs.boot_namespace, "/mnt/data", vfs.O_WRONLY)
	if check(r, aerr2 == vfs.OK, "a clunk gives the window back") {
		vfs.chan_close(again)
	}

	copy(s.pixels[y * s.pitch:][:span], row_saved[:span])
}
