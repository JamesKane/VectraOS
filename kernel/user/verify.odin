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
import "kernel:pipe"
import "kernel:sched"
import "kernel:srv"
import "kernel:sync"
import "kernel:vfs"
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
	checks:        int,
	failures:      int,
	first_failure: string,
	programs:      int,
	spawned:       int, // Of those, started by another process
	traps:         u64, // Returns from ring 3 while the checks ran
	rounds:        u64, // Times `spin` went round its loop in ring 3
	calls:         int, // System calls the programs made
	answered:      u64, // 9P requests a process served over a wire
	pinned:        int, // Heap objects the wire keeps on purpose
	leaked:        int, // Heap objects the run did not give back
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
	before_heap := live_objects(mem.heap_stats())
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

	// -- And a process that starts another one -------------------------------

	verify_loading(&r, column)
	verify_parenthood(&r, column, &held)

	// -- And a process that publishes a service ------------------------------

	verify_posting(&r, column, &held)

	// -- And a process that *answers* one ------------------------------------

	verify_service_answered(&r, column)

	// -- And a program a compiler built, doing the same ----------------------

	verify_runtime(&r, column)

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
	r.leaked = live_objects(mem.heap_stats()) - before_heap - r.pinned
	check(&r, r.leaked == 0, "and every namespace and open file beyond the wire's deliberate pin")

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

/*
The message `hello` prints, and the only thing in this file a person sees.

No newline. The check on the other side counts console columns, and a newline
would reset the count to zero. `cons_finish` ends the line afterwards, which is
the same split `kernel/devfs/verify.odin` makes for the same reason.
*/
@(private = "file")
MESSAGE :: "-- a program in ring 3 wrote this line"

// The message as bytes, which is what a write takes. A string constant has no
// address until something gives it one.
@(private = "file")
message_bytes :: proc "contextless" () -> []u8 {
	text := MESSAGE
	return raw_data(text)[:len(text)]
}

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
	check(r, set_bytes(p, MESSAGE_OFFSET, message_bytes()), "with a line in its data page")

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
@(private = "file") PATH_CONS :: "/dev/cons"
@(private = "file") PATH_ZERO :: "/dev/zero"
@(private = "file") PATH_NULL :: "/dev/null"
@(private = "file") PATH_MISSING :: "/dev/nope"

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
What a wire deliberately keeps, counted in heap objects.

Two pipe rings, the wire's arena, the `Wire`, the `Server`, and the
`Wire_End` the io callbacks close over. The seventh is one reference's worth
of chan on the posted end. All seven stay until a posted service can be
released, which is the reference count `docs/SRV.md` names as future work.

A constant rather than a measurement, so the check below breaks when the pin
grows. A pin that can grow silently is a leak with a title.
*/
@(private = "file")
WIRE_PIN :: 7

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
	pin_before := live_objects(mem.heap_stats())

	p, serr := spawn_path(nil, "/bin/niner", SPAWN_NS_COPY)
	if !check(r, serr == vfs.OK && p != nil, "a process is started that will answer 9P") {
		return
	}
	r.programs += 1

	// The posting is the process's own doing, so the kernel waits for the
	// name rather than races it. `lookup` answers nil until the descriptor
	// write lands.
	posted := false
	for _ in 0 ..< PATIENCE {
		if srv.lookup("niner") != nil {
			posted = true
			break
		}
		sync.delay(1)
	}
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
	*/
	for _ in 0 ..< PATIENCE {
		sched.reap()
		r.pinned = live_objects(mem.heap_stats()) - pin_before
		if r.pinned == WIRE_PIN {
			break
		}
		sync.delay(1)
	}
	check(r, r.pinned == WIRE_PIN, "what stays is the wire's pin, to the object")
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
	pin_before := live_objects(mem.heap_stats())

	// -- The image is a file, and says which format it is ---------------------

	header: [16]u8
	image_entry := uintptr(0)
	if bc, berr := vfs.open_path(vfs.boot_namespace, "/bin/ramfs", vfs.O_RDONLY); berr == vfs.OK {
		n, _ := vfs.chan_read(bc, 0, header[:])
		check(r, n == 16, "/bin serves the compiled image")
		word :: proc "contextless" (b: []u8) -> u64 {
			v := u64(0)
			for i in 0 ..< 8 {
				v |= u64(b[i]) << (8 * u64(i))
			}
			return v
		}
		check(r, word(header[:]) == IMAGE2_MAGIC, "and its header says VECTRA02")
		image_entry = uintptr(word(header[8:]))
		vfs.chan_close(bc)
	} else {
		check(r, false, "/bin serves the compiled image")
		return
	}

	// -- The loader builds a bigger world than a blob's -----------------------

	p, serr := spawn_path(nil, "/bin/ramfs", SPAWN_NS_COPY)
	if !check(r, serr == vfs.OK && p != nil, "the segment loader starts it") {
		return
	}
	r.programs += 1
	check(
		r,
		p.frame_count > STACK_PAGES2 + 3 && p.frame_count <= MAX_PROGRAM_FRAMES,
		"holding more pages than any blob could",
	)
	first_frame := p.frames[0]
	last_frame := p.frames[p.frame_count - 1]

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

	posted := false
	for _ in 0 ..< PATIENCE {
		if srv.lookup("ramfs") != nil {
			posted = true
			break
		}
		sync.delay(1)
	}
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

		check(r, vfs.chan_remove(nc) == vfs.OK, "a remove is answered, and is the stop")
		vfs.chan_close(nc)
	}

	// -- The teardown, in the order the wire taught -----------------------

	if check(r, wait(p, PATIENCE), "the server exits") {
		check(r, p.exit.deliberate && p.exit.status == 0, "deliberately, with nothing to report")
	}

	check(r, srv.remove("ramfs") == vfs.OK, "the kernel takes the name away")
	check(r, srv.count() == count0, "and /srv holds exactly what it held before")

	finish(r, p, "and the process is taken down")
	check(
		r,
		mem.frame_is_free(first_frame) && mem.frame_is_free(last_frame),
		"with every segment frame given back, first and last by name",
	)

	pipe.quiesce()
	check(
		r,
		vfs.unmount_path(vfs.boot_namespace, "", "/mnt") == vfs.OK,
		"the mount of the dead server comes down",
	)

	pinned := 0
	for _ in 0 ..< PATIENCE {
		sched.reap()
		pinned = live_objects(mem.heap_stats()) - pin_before
		if pinned == WIRE_PIN {
			break
		}
		sync.delay(1)
	}
	check(r, pinned == WIRE_PIN, "and what stays is one more wire's pin, to the object")
	r.pinned += pinned
}

// live_objects counts what the heap is holding. The same arithmetic
// `kernel/main.odin` does for the namespace and service self-tests, repeated
// here because this package cannot reach into that one.
@(private = "file")
live_objects :: proc "contextless" (s: mem.Heap_Stats) -> int {
	live := s.large_blocks
	for i in 0 ..< len(s.class_total) {
		live += s.class_total[i] - s.class_free[i]
	}
	return live
}
