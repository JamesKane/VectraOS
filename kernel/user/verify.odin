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

/*
channel pulls one colour out of a pixel word, through the surface's own shifts.

A self-test that assumed XRGB8888 would agree with itself on this machine and
be wrong on the next one. `fb.pack` goes the other way and reads the same
fields. That is what makes a check comparing a pixel to a palette entry mean
anything.
*/
@(private = "file")
channel :: proc "contextless" (s: ^fb.Surface, value: u32, shift: u8, size: u8) -> u32 {
	if size == 0 {
		return 0
	}
	return (value >> shift) & ((u32(1) << size) - 1)
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

	// What the descriptor tables looked like before a process that will fault
	// took one. See the hangup check below, which reads it again.
	fdt_before := fdt_stats()

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

	/*
	And its descriptors come back with nobody asking, which is the hangup a
	faulting server never used to perform.

	**`sys_exit` releases the group and `on_trap` cannot.** A trap handler runs
	with interrupts off, and `fdt_release` closes chans, and a clunk is a
	message that may park -- `fdtable.odin` says so in as many words. So a
	process that *faulted* kept its descriptors until something called
	`destroy`, and `destroy` ran only from `spawn_path`.

	The cost was a hang rather than a leak: a ring 3 server that faults
	mid-request never hung up its pipe, so a client parked on it waited for a
	reply from a process that no longer existed. Two controls in this session
	stopped a boot that way rather than failing a check.

	**Nothing here calls a collector.** `finish` below is what destroys the
	record, and it has not run yet. The only thing that can have released this
	table is the reaper, woken by the ending itself.
	*/
	hung_up := false
	for _ in 0 ..< PATIENCE {
		if fdt_stats() == fdt_before {
			hung_up = true
			break
		}
		sync.delay(1)
	}
	check(&r, hung_up, "and its descriptors come back with nothing asking, which is the hangup")

	/*
	And the record is still there, which is the other half.

	Plan 9's `pexit` closes the file group and leaves the proc record for a
	parent to `wait` on. Releasing the descriptors is not reaping the process,
	and a collector that took both would answer a parent's wait with nothing.
	*/
	check(&r, p != nil && p.live, "while the record itself waits for whoever asks how it ended")

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

	/*
	And a process the kernel ends from outside, handler or not.
	*/
	verify_stop(&r)

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

	// -- And memory no file serves, which a window's pixels will be ----------

	verify_anon(&r)

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

	/*
	And the sweep sees the shadow page, which is the control that runs on
	every boot.

	The page above is a mapping no segment covers, made on purpose. Every
	other sweep in this file checks that it finds nothing. This one checks
	that it *can* find something: one stray leaf, at the shadow's address,
	and nothing borrowed. The frame under it is the stack's, at a second
	address. A sweep that reported zero here would be one that cannot fail,
	and `docs/TESTING.md` is where the shape comes from.
	*/
	swept := sweep(p)
	check(r, swept.stray == 1, "and the sweep finds the shadow page, a mapping no segment covers")
	check(r, swept.borrowed == 0, "and nothing else, because the frame under it is the stack's own")

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

	/*
	The kernel holds the screen for as long as it means to look at it.

	`/dev/fb` diverts the console now, the way `/dev/scancode` diverts the
	keyboard. The last close gives the glass back **with what the console drew
	in the meantime on it**. The painter's own descriptor is otherwise the only
	holder. So the console takes back the pixel this test is about the moment
	the program exits, before a check can read it.

	So the checker takes a hold of its own and keeps it across the checks. That
	is not a workaround. It is what holding the screen now means, and a test
	that reads the glass is a thing that holds the screen. See
	`kernel/devfs/fbdev.odin`.
	*/
	hold, herr := vfs.open_path(vfs.boot_namespace, PATH_FB, vfs.O_RDONLY)
	check(r, herr == vfs.OK, "the checker takes the screen, so the console does not reclaim it")
	defer if herr == vfs.OK {
		vfs.chan_close(hold)
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

	// The checker holds the screen across the checks, for `verify_painter`'s
	// reason. The program's own descriptor is the last one, and its close
	// hands the glass back to the console with the console's drawing on it.
	hold, herr := vfs.open_path(vfs.boot_namespace, PATH_FB, vfs.O_RDONLY)
	check(r, herr == vfs.OK, "the checker takes the screen for the length of the checks")
	defer if herr == vfs.OK {
		vfs.chan_close(hold)
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
verify_stop is the kernel ending a process that would catch anything else.

`catcher` registers a handler and spins on its first note, and `verify_handler`
just showed that handler answering NCONT and the program surviving. The same
program is the target here, because a stop that a handler could decline is a
note with a longer name. The check that matters is the handler's own count,
which has to stay at zero: the process ended without its handler ever running.

The record is read before it is collected, which is why `end` and `stop` are
two calls. Then `stop` on a process that already ended is the collection alone,
which is the arc `wait_pid` walks for a parent.
*/
@(private = "file")
verify_stop :: proc(r: ^Result) {
	before := stats().live
	p, err := load_held("catcher", program_catcher())
	if !check(r, err == .None && p != nil, "a process is built that catches every note") {
		return
	}
	r.programs += 1
	if !check(r, launch(p), "and it launches") {
		finish(r, p, "and is taken down")
		return
	}

	// Spinning, with its handler registered, before the kernel acts. A stop
	// before the handler exists would prove nothing about handlers.
	armed := false
	for _ in 0 ..< PATIENCE {
		if cell(p, CATCHER_NOTIFIED) == 0 && cell(p, CATCHER_ROUNDS) > 0 {
			armed = true
			break
		}
		sync.delay(1)
	}
	check(r, armed, "it registers its handler and spins")
	check(r, !destroy(p), "and the kernel cannot take it down while it runs, as before")

	check(r, end(p, PATIENCE), "the kernel ends it, and it is gone inside the patience")
	check(r, p.exit.noted && !p.exit.deliberate, "noted, and not on its own terms")
	check(r, note(p) == "sys: killed", "with Plan 9's word for it")
	check(r, cell(p, CATCHER_HANDLED) == 0, "and its handler never ran, because the kernel's word comes first")
	check(r, stop(p, PATIENCE), "and the collection is the rest of the arc")
	check(r, stats().live == before, "so the machine holds no more processes than before")

	/*
	And a second one at the other boundary.

	A spinning target dies at the tick. So a door that looked at the handler
	first was never asked, and the control on it came back clean. This target
	is past its first note and looping on `sleep`, which is the door, with
	its handler registered and one delivery already behind it. The kernel's
	word has to end it at the next call, and the handler's count has to stay
	at one.
	*/
	p, err = load_held("catcher", program_catcher())
	if !check(r, err == .None && p != nil, "a second catcher is built") {
		return
	}
	r.programs += 1
	if !check(r, launch(p), "and it launches") {
		finish(r, p, "and is taken down")
		return
	}
	armed = false
	for _ in 0 ..< PATIENCE {
		if cell(p, CATCHER_NOTIFIED) == 0 && cell(p, CATCHER_ROUNDS) > 0 {
			armed = true
			break
		}
		sync.delay(1)
	}
	check(r, armed && post_note(p, CATCHER_NOTE), "it spins, and an ordinary note is posted to it")
	sleeping := false
	for _ in 0 ..< PATIENCE {
		if cell(p, CATCHER_HANDLED) == 1 {
			sleeping = true
			break
		}
		sync.delay(1)
	}
	check(r, sleeping, "which its handler catches, and it moves on to loop on sleep")
	check(r, end(p, PATIENCE), "the kernel ends it there, at the door, inside the patience")
	check(r, p.exit.noted && note(p) == "sys: killed", "noted, with the same word")
	check(r, cell(p, CATCHER_HANDLED) == 1, "and its handler ran once, for the note, and not for the word")
	check(r, stop(p, PATIENCE), "and it is collected")
	check(r, stats().live == before, "leaving the machine as it was")
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
	// It holds still on a word from here. The reaper takes a detached
	// process back the moment it ends, and there would otherwise be nothing
	// left to look at.
	child := find_child(0, childpid)
	if !check(r, child != nil && child.detached, "the child stands alone, detached to the kernel") {
		return
	}
	ran := false
	for _ in 0 ..< PATIENCE {
		if cell(child, NOWAITER_CHILD_RAN) == 1 {
			ran = true
			break
		}
		sync.delay(1)
	}
	check(r, ran, "it runs with nobody watching, and waits for the kernel's word")

	/*
	And the kernel takes its record back on its own, which is the reaper.

	`reap_orphans` used to be the only collector, and it ran only where a
	fork wanted a slot. A detached process that ended held its record and
	every count in it until then. Its status is nobody's to read now, the way
	a detached child's is nobody's to `wait` for. So this watches the record
	go rather than reads it.
	*/
	before := stats().live
	set_cell(child, NOWAITER_CHILD_STOP, 1)
	check(r, await_collected(child, childpid), "and when it ends the reaper takes its record back, with nothing asking")
	check(r, stats().live < before, "so the machine holds one process fewer")
	check(r, reap_orphans() == 0, "and the collector at the next fork finds nothing left to do")
}

// await_collected waits for a detached process's record to go. It asks by
// slot and pid together, because the slot may already hold a newer process
// by the time this looks.
@(private = "file")
await_collected :: proc(p: ^Process, pid: u64) -> bool {
	for _ in 0 ..< PATIENCE {
		if !p.live || p.pid != pid {
			return true
		}
		sync.delay(1)
	}
	return false
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

	// The child's tables, while it holds two shared segments and a stack of
	// its own. A copy at fork that mapped the parent's stack frame as the
	// child's would pass the pointer checks above. Here it would be a leaf
	// whose frame the child's stack segment does not own.
	swept := sweep(child)
	check(r, swept.stray == 0 && swept.borrowed == 0, "and every page the child maps is a frame its own segments hold")

	// The kernel's write releases the orphan, and the reaper collects it the
	// moment it ends. Its status is nobody's to read, so what is watched is
	// the record going, and then the frame the last release frees.
	childpid := child.pid
	set_cell(child, MEMFORK_STOP, 1)
	check(r, await_collected(child, childpid), "the kernel's write releases the orphan, and the reaper takes it back unasked")
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

// forked_child is the live process a server forked, found by parentage.
// `find_child` wants the pid, which only the server knows. One child is
// what every forking server in the tree has, and the first is the answer.
@(private = "file")
forked_child :: proc "contextless" (parent: ^Process) -> ^Process #no_bounds_check {
	if parent == nil {
		return nil
	}
	for i in 0 ..< MAX_PROCESSES {
		p := &processes[i]
		if p.live && p != parent && p.parent == parent.pid {
			return p
		}
	}
	return nil
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

	/*
	The desktop, read before any window is on it.

	See `desk_measure`: every discovery below stands on this, so it is measured
	rather than restated. It gates as well as checks, because a desktop that
	could not be measured is not a failed claim about the server -- it is the
	absence of the instrument the rest of this procedure reads through.
	*/
	if !check(r, desk_measure(s), "and has painted a desktop, ground and grid, over the whole screen") {
		return
	}

	ctl, cerr := vfs.open_path(vfs.boot_namespace, "/mnt/0/ctl", vfs.O_RDWR)
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

	dc, oerr := vfs.open_path(vfs.boot_namespace, "/mnt/0/data", vfs.O_WRONLY)
	if !check(r, oerr == vfs.OK, "and the command file opens for writing") {
		return
	}

	// -- Where the client area actually is ------------------------------------

	/*
	The report says how big. This finds out *where*, by asking the client to
	fill every pixel it was told it has and then reading the glass back.

	**Nothing here computes the frame.** The test used to inset by the same
	`sys/libdraw` constants `servers/intuition` lays a window out with, which
	made the two agree by construction: no mutation of the frame's geometry
	could fail a check, only a server that stopped drawing a frame at all. The
	frame is a sensor now, and `libdraw` no longer carries a window's layout at
	all -- see `docs/DRAW.md` section 12.

	`PROBE` is a colour nothing else on this screen makes, so its bounding box
	is the client area and nothing else. The client draws the area's *outline*
	rather than its face: the scans only ever read the four edges, and an
	outline is two thousand eight hundred pixels where a face is four hundred
	and eighty-five thousand. The column scanned is the middle of the reported
	width, which crosses the top and bottom edges for any frame shallower than
	half a window.

	Window zero sits at the screen's origin. That is placement policy and stays
	a fixture, the way the cascade below it is: no verb would tell a client
	where it was put.
	*/
	PROBE :: u32(0x0059315B)
	probe: [160]u8
	pat_at := libdraw.put_fill(probe[:], 0, 0, 0, 0, u32(win_w), 1, PROBE)
	pat_at = libdraw.put_fill(probe[:], pat_at, 0, 0, u32(win_h - 1), u32(win_w), 1, PROBE)
	pat_at = libdraw.put_fill(probe[:], pat_at, 0, 0, 0, 1, u32(win_h), PROBE)
	pat_at = libdraw.put_fill(probe[:], pat_at, 0, u32(win_w - 1), 0, 1, u32(win_h), PROBE)
	pat_at = libdraw.put_flush(probe[:], pat_at)
	_, perr := vfs.chan_write(dc, 0, probe[:pat_at])
	if !check(r, perr == vfs.OK, "the client draws round the edge of the area it was told it has") {
		return
	}

	ox, oy, cw, ch := find_rect(s, PROBE, win_w / 2, 0)
	if !check(r, ox >= 0, "which the glass shows, so the test can be told where it landed") {
		return
	}

	/*
	Three claims, and the first is the one the report cannot make about itself.

	A server that answers with the *window* rather than the client area is
	giving a client a number it cannot use, and the fill it provokes is clipped
	to the smaller area it really has. That is a mismatch here rather than a
	readback walking off the screen, which is what it used to be.
	*/
	check(
		r,
		cw == win_w && ch == win_h,
		"and gets exactly the area it was promised, which is the report answering for itself",
	)
	check(
		r,
		ox > 0 && oy > ox,
		"inside a border, and further below a title bar, neither of which it is told about",
	)
	check(
		r,
		fb.get_raw(s, ox - 1, oy) != PROBE && fb.get_raw(s, ox, oy - 1) != PROBE,
		"and not one pixel onto the frame around it, which is the server's and not the client's",
	)

	/*
	And the window's own right edge, found the same way: walk right out of the
	client area until the desktop begins again.

	**A window is opaque over its whole rectangle** is the sentence three
	milestones were spent reaching, and this is the first check that reads it
	directly rather than through a client's pixels. Everything between the
	client area and the ground is frame.

	`fw` is the cascade's step, so the placement fixture below is expressed in
	a number the glass gave up rather than one `libdraw` was asked for.
	*/
	fw := win_right(s, oy + ch / 2, ox + cw)
	check(r, fw > ox + cw && fw < s.width, "the window is opaque out to a border, and the desktop begins where it ends")

	/*
	And the client area sits the same depth in from both edges of it.

	**The discovery above follows a client wherever its pixels went, so it
	cannot on its own say they went to the wrong place.** A server that
	translated one pixel too far would be found one pixel further along and
	every check after would agree with it. This is the anchor: the border is a
	border, so it is the same depth on the left and the right, and window zero
	sits at the screen's origin.

	Neither says how deep. A deeper border or a taller bar moves the report and
	moves these together, which is a look and not a fault.

	**The bottom edge is found, not assumed.** It used to be the screen's,
	because a window was born as tall as the glass. A window is born shorter
	than the glass now -- `rio`'s `goodrect` refuses a rectangle that contains
	the whole screen -- so `win_bottom` walks down out of the window the way
	`win_right` walks out of it sideways.
	*/
	fb_bottom := win_bottom(s, win_w / 2, oy + ch)
	check(
		r,
		fw - (ox + cw) == ox,
		"which is the same depth in from both of its window's edges, because a border is a border",
	)
	check(
		r,
		fb_bottom - (oy + ch) == ox,
		"and the same depth up from its own bottom as it is in from the side, the bar being the top's own",
	)
	/*
	And the glass goes on below it, which is the placement policy.

	Read a little below the window rather than at the screen's last row: the
	desktop is sunk into a recess two pixels deep, so the bottom row is that
	bevel and not ground. `desk_measure` avoids the same recess for the same
	reason.
	*/
	check(
		r,
		fb_bottom < s.height - 16 && is_desk(s, win_w / 2, fb_bottom + 8),
		"and does not fill the glass, which is the placement policy and what lets one grow",
	)

	/*
	The region the test paints, saved to be restored. Four rows of 48 pixels
	on the left, and eight pixels at the right edge of the first.

	`y0` is a *client* row near the bottom of the client area, and `sy` is
	where that row lands on the glass. Every coordinate below is one or the
	other and never both: what goes into a command is the client's, and what
	comes back out of `fb.get_raw` is the screen's.
	*/
	y0 := win_h - 16
	sy := oy + y0
	// Eight pixels short of the *client area's* right edge, so a fill of
	// sixteen runs past it. The coordinate is the client's, and a client's
	// coordinates start at its own origin.
	edge_x := win_w - 8

	// The two pixels the region check below paints, at opposite ends of a row
	// nothing else touches. Restored with the rest at the end, because a
	// composite later in this procedure may repaint them out of the store.
	gap_y := y0 - 8
	sgap := oy + gap_y

	/*
	And the window is standing in a frame, which is the milestone and had no
	check until a control said so.

	Both mutations that removed the frame from a window's store were inert.
	Every other check here reads a pixel a client drew or a pixel a client did
	not, and a window with no border is neither. So these two read the frame
	itself, at the two pixels that say which surface it is.

	The border is `.Raised`, so its top and left edges carry the light. Column
	zero of window zero is that highlight, on a row far from the corner where
	the shadow edge crosses it.

	**The bar is read where it is rather than where its colour is.** Everything
	above the client area and inside the window is border, bar and the well's
	own lip, and a bar is much the tallest of the three, so the middle of that
	band is on it. Looking the bar up *by* its copper and then asking whether it
	is copper is a check of its own premise.

	Both colours come out of `sys/libpal` through `fb`, which is the table this
	side of the door reads, and neither is anything a client's fill or the
	desktop below could produce.
	*/
	check(
		r,
		fb.get_raw(s, 0, sy) == fb.pack(s, fb.MAGNESIUM_HOT),
		"the window stands in a raised border, lit at its left edge like every panel in the chassis",
	)
	check(
		r,
		fb.get_raw(s, ox + 8, oy / 2) == fb.pack(s, fb.COPPER),
		"with a copper bar across the top of it, which is the chassis's own trim",
	)

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
		fb.get_raw(s, ox + 8, sy) == C1 && fb.get_raw(s, ox + 23, sy + 3) == C1,
		"the fill landed on the glass, corner to corner, inset by the frame it never sees",
	)
	blitted := true
	for line in 0 ..< 4 {
		for i in 0 ..< 8 {
			if fb.get_raw(s, ox + 32 + i, sy + line) != (u32(0x00400000) | u32(line * 8 + i)) {
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
	spill_before := fb.get_raw(s, ox, sy + 1)
	beyond_before := fb.get_raw(s, ox + win_w, sy)
	at = libdraw.put_fill(buf[:], 0, 0, u32(edge_x), u32(y0), 16, 1, C1)
	at = libdraw.put_flush(buf[:], at)
	_, werr = vfs.chan_write(dc, 0, buf[:at])
	check(r, werr == vfs.OK, "a fill past the edge clips rather than errors")
	check(r, fb.get_raw(s, ox + win_w - 1, sy) == C1, "and paints up to its client area's last pixel")
	check(r, fb.get_raw(s, ox, sy + 1) == spill_before, "and spills nothing onto the row below")
	/*
	And nothing one pixel further, which is the client area's edge rather than
	the screen's.

	The check above would pass on a server that clipped to the glass, because
	the client area's last column is a real column either way. This one is what
	says the *client area* is the bound. It watches the first pixel a client may
	not have -- which since this milestone is its own window's border, so the
	same check now also says a client cannot draw on its own frame.
	*/
	check(r, fb.get_raw(s, ox + win_w, sy) == beyond_before, "and nothing at all past it")

	/*
	A malformed command fails its whole write, and what stood before it drew
	anyway. That rule did not change. What changed is where `drew` happens.

	A draw lands in the window's own memory now, so the claim cannot be read
	off the glass in the same write. The command that would have made it
	visible is the one that failed.

	So the test makes the claim the way the protocol makes it. The glass must
	*not* have the fill, and a flush of its own must then produce it. Two checks
	where there was one, and the pair says what the single check could not.
	*/
	at = libdraw.put_fill(buf[:], 0, 0, 8, u32(y0), 4, 1, C3)
	buf[at] = 4
	buf[at + 1] = 0
	buf[at + 2] = 9
	buf[at + 3] = 0
	_, werr = vfs.chan_write(dc, 0, buf[:at + 4])
	check(r, werr != vfs.OK, "a malformed command fails the whole write")
	check(
		r,
		fb.get_raw(s, ox + 8, sy) != C3,
		"and nothing of it reached the glass, because the flush was in the write that failed",
	)
	at = libdraw.put_flush(buf[:], 0)
	_, werr = vfs.chan_write(dc, 0, buf[:at])
	check(r, werr == vfs.OK, "a flush of its own is answered")
	check(r, fb.get_raw(s, ox + 8, sy) == C3, "and shows what stood before the bad command, which already drew")

	at = libdraw.put_free(buf[:], 0, 1)
	_, werr = vfs.chan_write(dc, 0, buf[:at])
	check(r, werr == vfs.OK, "a free is answered once")
	_, werr = vfs.chan_write(dc, 0, buf[:at])
	check(r, werr != vfs.OK, "and refused twice")

	/*
	And a flush paints what a client drew, not the box around it.

	Damage is a region rather than a bounding box. Two pixels at opposite ends
	of a row are two rectangles, and the span between them is neither. The
	pixel watched is in that span. No window covers it, so a flush has to leave
	it exactly as it was found.

	**This is the only check in the file a coarser damage record breaks**, and
	it is the reason the region exists. It also stands in for the wart the
	region retired. A magic pixel value used to carry this, and a client paid
	for it by not being able to paint black.
	*/
	mid_before := fb.get_raw(s, ox + win_w / 2, sgap)
	at = libdraw.put_fill(buf[:], 0, 0, 0, u32(gap_y), 1, 1, C1)
	at = libdraw.put_fill(buf[:], at, 0, u32(win_w - 1), u32(gap_y), 1, 1, C1)
	at = libdraw.put_flush(buf[:], at)
	_, werr = vfs.chan_write(dc, 0, buf[:at])
	check(r, werr == vfs.OK, "a client draws one pixel at each end of a row")
	check(
		r,
		fb.get_raw(s, ox, sgap) == C1 && fb.get_raw(s, ox + win_w - 1, sgap) == C1,
		"and both of them land",
	)
	check(
		r,
		fb.get_raw(s, ox + win_w / 2, sgap) == mid_before,
		"and the span between them is untouched, because damage is a region and not a box",
	)

	// -- Two sessions, two windows -------------------------------------------
	//
	// While `dc` is still open, because the claim is about two windows held at
	// once. The image-pool test below closes it.
	verify_windows(r, s, win_w, win_h, ox, oy, fw, y0 - 2, dc, ctl, p)

	at = 0
	for id in 1 ..= 8 {
		at = libdraw.put_alloc(buf[:], at, u32(id), 8, 4)
	}
	_, werr = vfs.chan_write(dc, 0, buf[:at])
	check(r, werr == vfs.OK, "a session fills the whole image pool")
	vfs.chan_close(dc)
	dc2, o2 := vfs.open_path(vfs.boot_namespace, "/mnt/0/data", vfs.O_WRONLY)
	if check(r, o2 == vfs.OK, "the command file opens again") {
		at = libdraw.put_alloc(buf[:], 0, 1, 8, 4)
		_, werr = vfs.chan_write(dc2, 0, buf[:at])
		check(r, werr == vfs.OK, "and the clunk gave the session's images back")
		vfs.chan_close(dc2)
	}

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

/*
glyph_on_glass compares one 8x16 cell on the screen against the one font
table, pixel for pixel, in the terminal's colors.

The comparison is deliberately exact rather than any-lit-pixel. The
controls that swap the atlas arithmetic or invert the bit expansion still
light pixels -- the wrong ones. Only an exact cell tells a right glyph
from a wrong one.
*/
@(private = "file")
glyph_on_glass :: proc "contextless" (
	s: ^fb.Surface,
	x: int,
	y: int,
	ch: u8,
	height := libfont.FONT_HEIGHT,
) -> bool #no_bounds_check {
	rows := &libfont.font_8x16[int(ch) - libfont.FONT_FIRST]
	for line in 0 ..< height {
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
The caret the terminal draws under the cell its cursor is in.

**Read as `the bottom row of a cell is all foreground`**, which does not depend
on how thick the caret is. `CARET_BAND` is deliberately looser than the two
pixels `apps/terminal` draws, so the test says where the caret is and not how
tall, the way `docs/DRAW.md` section 12 leaves a deeper window border inert.

**The looseness has a bound, and it is this number.** A caret thicker than
`CARET_BAND` reaches into the rows `cell_body_blank` reads and every
blank-cell check fails. Four pixels of a sixteen-pixel cell is the room the
terminal has to restyle its caret in without touching this file.
*/
@(private = "file")
CARET_BAND :: 4

/*
await_caret waits for the caret to be at `at` and gone from `was`.

Both halves, because a poll for the caret's arrival alone would pass on the
frame before the old one is rubbed out -- and the terminal draws a whole field
at a time, so the two always land together or not at all. The delivery crosses
a process, which is what makes it a poll rather than a read.
*/
@(private = "file")
await_caret :: proc(s: ^fb.Surface, at: int, was: int, y: int) -> bool {
	for _ in 0 ..< PATIENCE {
		if caret_at(s, at, y) && !caret_at(s, was, y) {
			return true
		}
		sync.delay(1)
	}
	return false
}

@(private = "file")
caret_at :: proc "contextless" (s: ^fb.Surface, x: int, y: int) -> bool #no_bounds_check {
	for i in 0 ..< libfont.FONT_WIDTH {
		if fb.get_raw(s, x + i, y + libfont.FONT_HEIGHT - 1) != TERM_FG {
			return false
		}
	}
	return true
}

// cell_body_blank reports that a cell holds no glyph, ignoring the band the
// caret may sit in. It is `glyph_on_glass` against a space, stopped short of
// the caret, rather than a second copy of that comparison.
@(private = "file")
cell_body_blank :: proc "contextless" (s: ^fb.Surface, x: int, y: int) -> bool {
	return glyph_on_glass(s, x, y, ' ', libfont.FONT_HEIGHT - CARET_BAND)
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
	// This server is a fresh one, so its desktop is measured again rather than
	// inherited from the last procedure's. It gates for `verify_draw`'s reason.
	if !check(r, desk_measure(s), "and paints a desktop over the whole screen before anything else") {
		return
	}

	pt, terr := spawn_path(nil, "/bin/terminal", SPAWN_NS_COPY)
	if !check(r, terr == vfs.OK && pt != nil, "the loader starts the terminal") {
		return
	}
	r.programs += 1

	/*
	Where the terminal's window is, found rather than computed.

	The terminal lays itself out in the *client area* its `ctl` read answered
	with, and that area's ground is the face of the well a window is sunk into
	-- `SLATE`, which is neither the copper above it nor the desktop beside it.
	So the first slate down a column inside the window is the client's top row,
	and the run of slate along a row is the client's own columns.

	`COL` is a column inside window zero and past the terminal's own field, so
	the run under it is unbroken from the client's first row to its last. The
	window has to exist before any of that is true, which is what the first
	poll waits for: the terminal opens its window before it uploads a glyph.

	This read `sys/libdraw`'s frame arithmetic until this milestone, which
	agreed with the server rather than watching it. See `scan_col`.
	*/
	/*
	Wait for the terminal's window, then measure it. Nothing synchronises this
	thread with the terminal's `Tlopen`.

	**The wait is for a window that is wholly there, and it says so itself.**
	An earlier cut waited on one pixel near the bottom of a column it had
	picked by hand, which assumed both that column was inside window zero and
	that composites walk top to bottom -- the second an iteration order of the
	code under test, and the first a number that stops being right the day
	`MAX_WINDOWS` is raised.

	This asks for the answer instead. The window's own column comes from the
	run of not-desktop across the screen's last rows, and the client area found
	in it has to satisfy the same symmetry `verify_draw` anchors on: as far up
	from the bottom as it is in from the side. A half-composited window has a
	client area that stops short and fails that, so the loop goes round again.

	The ground looked for is `SLATE`, the face of the well a window is sunk
	into, which is neither the copper above it nor the desktop beside it.
	*/
	slate := fb.pack(s, fb.SLATE)
	ox, oy, cy_end := -1, -1, -1
	for _ in 0 ..< PATIENCE {
		/*
		The first run of not-desktop across a low row, which is the window.

		Started and ended clear of the screen's own recessed edge: the desktop
		is sunk into the glass, so its outermost two columns are not desktop
		either, and a scan of the whole width answers a run that spans from the
		left bevel to the right one. The *first* run rather than the outermost
		pair, for the same reason.

		A third of the way down rather than four rows off the bottom. A window
		used to be as tall as the glass and a low row was certainly inside one;
		a window is born shorter than that now, and the bottom of the screen is
		where the desktop shows through.
		*/
		lo, hi := -1, -1
		for x in 8 ..< s.width - 8 {
			if !is_desk(s, x, s.height / 3) {
				if lo < 0 {
					lo = x
				}
				hi = x
			} else if lo >= 0 {
				break
			}
		}
		if lo >= 0 {
			col := (lo + hi) / 2
			oy, cy_end = scan_col(s, col, slate, 0, s.height)
			if oy >= 0 {
				ox, _ = scan_row(s, oy + (cy_end - oy) / 2, slate, 0, s.width)
				// The window's own bottom, not the screen's. A window is born
				// shorter than the glass now, so the symmetry is against the
				// edge `win_bottom` finds -- the same one `verify_draw`
				// anchors on.
				if ox >= 0 && win_bottom(s, col, cy_end + 1) - (cy_end + 1) == ox {
					break
				}
			}
			ox = -1
		}
		sync.delay(1)
	}
	if !check(r, ox >= 0, "the terminal opens a window of its own, wholly on the glass") {
		return
	}
	y0 := cy_end - 39

	// The prompt lands only after the terminal mounts the server, reads
	// the geometry, and uploads ninety-five glyphs. The poll waits for
	// the exact glyph, so a wrong atlas never satisfies it.
	prompted := false
	for _ in 0 ..< PATIENCE {
		if glyph_on_glass(s, ox + 8, y0, '>') {
			prompted = true
			break
		}
		sync.delay(1)
	}
	check(r, prompted, "the terminal mounts the server itself and paints its prompt")
	check(r, glyph_on_glass(s, ox + 16, y0, ' '), "whose glyphs match the kernel's own font, pixel for pixel")

	/*
	And the field sits in a well now.

	`kernel/splash.odin` sinks the console into one and says its vocabulary
	should reach `intuition`'s clients. It does: `sys/libdraw` decomposes a
	well into rectangles and `apps/terminal` sends them as ordinary fills.
	There is no chrome verb, which is what section 5 of `docs/DRAW.md` guards.

	The pixel watched is on the well's own edge, four columns left of the
	first glyph. A recessed bevel puts the shadow on the top and left, so this
	is `VOID`. That is the darkest thing in the palette, and nothing the
	terminal's own two colours could produce.
	*/
	check(
		r,
		fb.get_raw(s, ox + 4, y0) == fb.pack(s, fb.VOID),
		"and its field is sunk into a well, out of the chassis's own vocabulary",
	)

	/*
	And the bar across the top of its window says whose window it is.

	The first program in the tree to use the fourth `ctl` line. It sends
	`name terminal` before it uploads a glyph, so by the time the prompt is on
	the glass the bar already carries the name -- drawn by the *server*, out of
	the same font table this program uploads its own copy of.

	The colour is the chassis's engraved wordmark, and the band looked in is
	everything above the client area and inside the window: border, bar and the
	well's lip. None of the three can hold that colour, so a hit in the band is
	a letter on the bar.
	*/
	bx, by, bw, bh := 0, 0, win_right(s, oy / 2, ox), oy
	check(
		r,
		bar_has(s, bx, by, bw, bh, fb.pack(s, fb.SLATE_DEEP)),
		"and the bar across its window carries the name the program gave itself",
	)

	// Three bytes, no newline. The kernel's console echo is off, and this is
	// what says so: the console cursor does not move for a typed byte.
	col0 := column()
	devfs.keyboard_sink('h')
	devfs.keyboard_sink('i')
	devfs.keyboard_sink('!')
	check(r, column() == col0, "three typed bytes move the console cursor nowhere -- the echo is off")

	/*
	And yet they are on the glass, drawn by the program that owns it.

	**This is the check that tells an echo from no echo**, and until this
	milestone nothing here could: every other glyph check in this procedure
	reads the field *after* a newline, where a terminal that only ever drew
	finished lines looks exactly the same.

	No newline has been sent. The characters are on the screen because
	`apps/terminal` took its own window's keyboard raw and drew them as they
	arrived, which is what `rio` does in the window itself and what every
	Plan 9 program that draws its own text does for itself.

	The last glyph is polled rather than the first. The server paints a batch
	left to right, so the first says only that the batch began.
	*/
	echoed := false
	for _ in 0 ..< PATIENCE {
		if glyph_on_glass(s, ox + 40, y0, '!') {
			echoed = true
			break
		}
		sync.delay(1)
	}
	check(r, echoed, "and yet appear on the glass, because the window that draws them holds the line")
	check(
		r,
		glyph_on_glass(s, ox + 24, y0, 'h') && glyph_on_glass(s, ox + 32, y0, 'i'),
		"every one of them, before any newline says the line is finished",
	)

	/*
	And a backspace takes one back, which is `libedit` seen through the glass.

	The same procedure `servers/intuition` cooks a window's lines with, run
	here by the program that draws instead. One set of rules about what the
	keys mean, and two callers with different reasons to hold a line.
	*/
	devfs.keyboard_sink(0x08)
	erased := false
	for _ in 0 ..< PATIENCE {
		if cell_body_blank(s, ox + 40, y0) {
			erased = true
			break
		}
		sync.delay(1)
	}
	check(r, erased, "a backspace takes the last character off the field it was drawn in")
	check(
		r,
		glyph_on_glass(s, ox + 32, y0, 'i'),
		"and leaves the rest of the line where it was",
	)
	// And the caret came back with it, which is the cursor this milestone
	// gave the line. It sits where the next character goes.
	check(r, caret_at(s, ox + 40, y0), "and the caret comes back with it, to where the next one goes")

	/*
	And `^A` moves it to the front of the line, where a person can see it.

	The cell it lands on already holds a letter, so this reads the caret alone
	rather than the whole cell: a glyph and an underline share a cell and the
	exact comparison would fail on the one it is testing for.
	*/
	devfs.keyboard_sink(0x01)
	check(
		r,
		await_caret(s, ox + 24, ox + 40, y0),
		"^A moves the caret to the front of the line, under the first letter",
	)
	check(r, glyph_on_glass(s, ox + 32, y0, 'i'), "and the line it is in is untouched")

	devfs.keyboard_sink(0x05)
	check(
		r,
		await_caret(s, ox + 40, ox + 24, y0),
		"and ^E takes it back to where the next character goes",
	)

	devfs.keyboard_sink('!')

	devfs.keyboard_sink('\n')
	// The poll waits for the line's LAST glyph. The server paints the
	// batch left to right, so the first glyph says only that the batch
	// began. A poll of it once raced the two behind it.
	rendered := false
	for _ in 0 ..< PATIENCE {
		if glyph_on_glass(s, ox + 40, y0, '!') {
			rendered = true
			break
		}
		sync.delay(1)
	}
	check(r, rendered, "the newline completes the line and the terminal renders it")
	check(
		r,
		glyph_on_glass(s, ox + 24, y0, 'h') && glyph_on_glass(s, ox + 32, y0, 'i'),
		"every glyph out of the uploaded atlas, pixel for pixel",
	)
	check(
		r,
		cell_body_blank(s, ox + 48, y0) && caret_at(s, ox + 48, y0),
		"and the cell after the text holds no letter and the caret, which is where the next one goes",
	)

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

	// What the field was painted over does not have to be put back. The
	// terminal's window closed when it exited, and `window_close` repaints the
	// desktop across the whole rectangle it covered. The save and restore that
	// used to sit here predate a compositor that owns the ground, and the
	// buffer went with them.

	// The pool proof: the terminal held six strip images, and its exit
	// clunked them away. A fresh session that allocates all eight shows
	// nothing leaked.
	check(
		r,
		srv.mount(vfs.boot_namespace, "/srv/draw", "/mnt") == vfs.OK,
		"the kernel mounts the draw server",
	)
	refilled := false
	if dc, oerr := vfs.open_path(vfs.boot_namespace, "/mnt/0/data", vfs.O_WRONLY); oerr == vfs.OK {
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

	ctl, cerr := vfs.open_path(vfs.boot_namespace, "/mnt/0/ctl", vfs.O_RDONLY)
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

	/*
	And the checker holds the screen across the checks, for `verify_painter`'s
	reason one page up. The mapper's own descriptor closes when it exits. The
	last close of `/dev/fb` hands the glass back to the console, with the
	console's own drawing on it. The magenta pixel would be gone before anyone
	looked at it.
	*/
	hold, herr := vfs.open_path(vfs.boot_namespace, PATH_FB, vfs.O_RDONLY)
	check(r, herr == vfs.OK, "the checker takes the screen for the length of the checks")
	defer if herr == vfs.OK {
		vfs.chan_close(hold)
	}

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

		// A card's extent is the hardware's, and `syssegbrk` refuses every
		// kind but anonymous memory by name. This is the program written to
		// ask, which `docs/USER.md` said the rule was waiting for.
		check(
			r,
			cell(p, MAPPER_BRK) == refused(vectra9.EINVAL),
			"and a card cannot be resized, because its extent is the hardware's",
		)

		// But it can be given back, and the second attach was. What is left
		// on the list is one device segment, and `untracked_frees` after the
		// teardown says the release handed the card's memory to nobody.
		check(r, i64(cell(p, MAPPER_DETACH)) == 0, "and the second attach was detached whole")
		cards := 0
		for i in 0 ..< p.seg_count {
			if p.segs[i] != nil && p.segs[i].kind == .Device {
				cards += 1
			}
		}
		check(r, cards == 1, "leaving one card on the process's list")
	}

	// The sweep, over a process whose segments are a card's frames. Ownership
	// of device memory is arithmetic over the piece, the same as a run's.
	// This is the one process in the file that holds two of them.
	swept := sweep(p)
	check(r, swept.stray == 0 && swept.borrowed == 0, "every page it maps is a frame one of its segments holds")
	check(r, swept.short == 0, "and every page of both attaches is mapped")

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
verify_cons is the keyboard reaching the window in front, which is what a
focused title bar was reporting before anything was actually sent there.

**The shape is `rio`'s.** A window system does not translate scancodes: 9front's
`rio` opens `/dev/cons`, and prefers `/dev/kbd` when it exists, both of them
served by `kbdfs` one process further out. So `servers/intuition` reads a
cooked keyboard through the same file every other program reads, and what it
diverts is still only the glass.

**A line goes to the window in front, and focus is read when the line
arrives.** `verify_ctl` has just raised window zero, so window zero is the one
listening and window one is the control -- the same line must not be in it.

Four claims:

    the arrival    a line typed at the keyboard reaches the focused window's
                   own `cons`, through a server that never saw a scancode
    the routing    and reaches only that one, which is what focus is for
    the exclusion  one fid at a time holds a window's keyboard, because two
                   readers would each get part of every line
    the drain      and a line read once is gone, the way a queue is

The poll is because the delivery crosses a process. The draw server's reader
child is parked on `/dev/cons` in a process of its own, so a line typed here is
in the kernel's line discipline before it is in a window's ring, and the two
are not the same instant.

**What is polled is the size, not the file**, and the first cut of this got it
wrong in a way worth keeping written down. A read with a deadline looked like
the way to ask an empty queue whether anything was there. It is not: the
deadline flushes the request on the wire and `serve_mux`'s worker never hears
it -- `docs/HANDOFF.md` section 6 names that gap -- so each abandoned read left
a worker polling a ring for ever, and the server wedged once every slot was
spent. `cons` answers its size with the bytes waiting, the way `kbdfs` does, so
the queue can be asked without being read from.
*/
@(private = "file")
verify_cons :: proc(r: ^Result, zero_ctl: ^vfs.Chan, one_ctl: ^vfs.Chan) #no_bounds_check {
	zero, zerr := vfs.open_path(vfs.boot_namespace, "/mnt/0/cons", vfs.O_RDONLY)
	if !check(r, zerr == vfs.OK, "the window in front has a cons file of its own") {
		return
	}
	defer vfs.chan_close(zero)

	/*
	And one holder of it, which is `data`'s rule and `ctl`'s.

	Two readers of one keyboard would each get part of every line, and which
	part is a race. It is the same protection a window's other two files have
	and it is worth exactly as much: a window whose client never opens its
	`cons` leaves it for whoever asks.
	*/
	rival, rverr := vfs.open_path(vfs.boot_namespace, "/mnt/0/cons", vfs.O_RDONLY)
	check(r, rverr != vfs.OK, "and one reader of it, the way its data and its ctl are")
	if rverr == vfs.OK {
		vfs.chan_close(rival)
	}

	one, oerr := vfs.open_path(vfs.boot_namespace, "/mnt/1/cons", vfs.O_RDONLY)
	if !check(r, oerr == vfs.OK, "and so does the window behind it") {
		return
	}
	defer vfs.chan_close(one)

	// `verify_ctl` has just raised window zero, so window zero is listening.
	typed_to(r, zero, one, "hi", "a line typed at the keyboard arrives in the window in front")

	/*
	And again the other way round, which is the half the first cut of this
	did not have.

	**A control that sent every line to window zero was inert**, because
	window zero is the one `verify_ctl` raised and the two answers agreed.
	`docs/TESTING.md` names agreeing by accident as the way a check passes for
	the wrong reason, and one direction of a routing rule is exactly that. So
	the front moves and the same claim is made about the other window.
	*/
	_, rerr := vfs.chan_write(one_ctl, 0, bytes_of("raise\n"))
	check(r, rerr == vfs.OK, "the window behind asks to come to the front")
	typed_to(r, one, zero, "yo", "and the keyboard follows it, which is what focus is for")

	// And the front goes back where the rest of this procedure expects it.
	_, berr := vfs.chan_write(zero_ctl, 0, bytes_of("raise\n"))
	check(r, berr == vfs.OK, "and the first window takes the front back")

	verify_edit(r, zero)
	verify_split(r, zero, one, one_ctl, zero_ctl)
	verify_rawmode(r, zero)
}

/*
verify_edit is the line discipline this server took over, per window.

**`kernel/devfs` still cooks `/dev/cons`**, and this is the same job done one
privilege level out for a window that has the focus. The keys are `rio`'s
`wbswidth`: a character, a line, a word.

`^W` is the one worth naming. `docs/HANDOFF.md` lists word erase and the arrow
keys as the two a person misses next, and a window has the first of them now
while `/dev/cons` still does not.

And one line per read, which is `rio`'s drain rule and was the defect a review
found: the server used to empty its queue into one buffer, so a client that
read while two lines were waiting saw one and lost the other.
*/
@(private = "file")
verify_edit :: proc(r: ^Result, cons: ^vfs.Chan) #no_bounds_check {
	BS :: u8(0x08)
	KILL :: u8(0x15)
	WORD :: u8(0x17)

	typed_reads(r, cons, {'a', 'b', 'c', BS, 'd', '\n'}, "abd\n",
		"a backspace takes off the character before it, in the window's own discipline")
	typed_reads(r, cons, {'a', 'b', 'c', KILL, 'z', '\n'}, "z\n",
		"and ^U takes the whole line, which is the kill the kernel's console has")
	typed_reads(r, cons, {'l', 's', ' ', 'f', 'o', 'o', WORD, '\n'}, "ls \n",
		"and ^W takes one word, which the kernel's console never had")
	typed_reads(r, cons, {'a', ' ', ' ', WORD, '\n'}, "\n",
		"and eats the spaces before it on the way, which is what a word erase is")

	/*
	And the line has a cursor, which `^A` and `^E` move.

	**Those two are `rio`'s `Ksoh` and `Kenq`, and they are ordinary control
	bytes.** The arrow keys are not: in Plan 9 an arrow is a rune in the
	private Unicode space -- `Kleft` is U+F011 -- and nothing in this tree
	speaks runes. So a line moves by whole ends here, and moving by one
	character is what still wants them.

	A character goes in *at* the cursor and an erase takes what is before it,
	which is `winsert` and `wdelete` over one line's worth of buffer.
	*/
	HOME :: u8(0x01)
	END :: u8(0x05)
	typed_reads(r, cons, {'a', 'b', 'c', HOME, 'z', '\n'}, "zabc\n",
		"^A puts the cursor at the front, and a character goes in where it is")
	typed_reads(r, cons, {'a', 'b', 'c', HOME, END, 'z', '\n'}, "abcz\n",
		"and ^E puts it back at the end, which is where it was born")
	typed_reads(r, cons, {'a', 'b', 'c', HOME, BS, '\n'}, "abc\n",
		"and an erase at the front of a line takes nothing, because nothing is behind it")
	typed_reads(r, cons, {'a', 'b', 'c', HOME, END, BS, '\n'}, "ab\n",
		"while at the end it takes the last character, the way it always did")

	/*
	And the arrow keys, which arrive as runes rather than bytes.

	**The compiler encodes them, which is what keeps this independent.**
	`\uF011` is `Kleft` -- `KF|0x11` out of `sys/include/keyboard.h` -- and
	Odin emits the UTF-8 for it. So the bytes on the wire come from an encoder
	that has never heard of `sys/libkey` or of `core:unicode/utf8`'s use here,
	which is what a check of an encoding needs: an oracle that is not the code
	under test.

	The keyboard driver is what turns an extended scancode into one of these;
	`kernel/drivers/kbd` has that end. This end is what a line does when three
	bytes that are not characters arrive in it.
	*/
	typed_runes(r, cons, "abc\uF011z\n", "abzc\n",
		"a left arrow moves the cursor one character, and it arrives as a rune")
	typed_runes(r, cons, "abc\uF011\uF011\uF012z\n", "abzc\n",
		"and a right arrow moves it back, one character at a time")
	typed_runes(r, cons, "abc\uF00Dz\n", "zabc\n",
		"Khome does what ^A does, because they are the same key twice")
	typed_runes(r, cons, "abc\uF00D\uF018z\n", "abcz\n",
		"and Kend what ^E does")

	/*
	And a rune with no glyph does not reach the line.

	`sys/libfont` is an 8x16 table of 7-bit characters, so there is nothing to
	draw for anything else and nothing that stores it could be shown. `Kup` is
	a real key that this line has no use for, and it leaves no trace.
	*/
	typed_runes(r, cons, "a\uF00Eb\n", "ab\n",
		"a rune the line has no use for leaves nothing behind, because it has no glyph either")

	// And a byte that cannot begin a rune is dropped rather than stored, which
	// is `chartorune` answering Runeerror and making progress.
	typed_reads(r, cons, {'a', 0x80, 'b', '\n'}, "ab\n",
		"and a byte that cannot start a rune goes the same way")

	/*
	And two lines typed together come back one at a time.

	The queue holds both before either is read, so a drain that emptied it
	would answer with the pair and leave the client to find the boundary.
	*/
	pair := [8]u8{'o', 'n', 'e', '\n', 't', 'w', 'o', '\n'}
	if !type_settled(pair[:]) || !wait_for_size(cons, 8) {
		check(r, false, "two lines typed together both reach the window")
		return
	}
	check(r, true, "two lines typed together both reach the window")
	got: [64]u8
	n1, e1 := vfs.chan_read(cons, 0, got[:])
	check(
		r,
		e1 == vfs.OK && n1 == 4 && string(got[:4]) == "one\n",
		"and a read answers the first of them and stops at its newline",
	)
	/*
	And the second is still there to be read.

	**Gated, because a server that emptied its queue leaves nothing here** and
	an ordinary read of an empty queue parks for ever. A control that does
	exactly that used to hang the boot rather than fail this check, which
	`docs/TESTING.md` names as the worst way for one to report.
	*/
	if !wait_for_size(cons, 4) {
		check(r, false, "and the next read answers the second, which a client would have lost")
		return
	}
	n2, e2 := vfs.chan_read(cons, 0, got[:])
	check(
		r,
		e2 == vfs.OK && n2 == 4 && string(got[:4]) == "two\n",
		"and the next read answers the second, which a client would have lost",
	)
}

/*
verify_split is the defect this milestone exists to retire.

**A line half-typed when the focus moves used to go whole to the wrong
window.** The editing state was the kernel's and there was one of it, so the
front at the instant of the *newline* decided where every character of the line
went. There is one per window now, so the front at the instant of each
*character* decides, and a window keeps what was typed into it.

Three windows' worth of claim in one sequence: `ab` at the first window, then
the front moves and `cd` is typed, then the front moves back and `e` finishes
the line the first window was in the middle of.
*/
@(private = "file")
verify_split :: proc(r: ^Result, zero: ^vfs.Chan, one: ^vfs.Chan, one_ctl: ^vfs.Chan, zero_ctl: ^vfs.Chan) #no_bounds_check {
	half := [2]u8{'a', 'b'}
	if !check(r, type_settled(half[:]), "half a line is typed at the front window and reaches it") {
		return
	}

	_, rerr := vfs.chan_write(one_ctl, 0, bytes_of("raise\n"))
	check(r, rerr == vfs.OK, "and then the front moves")

	// The second window finishes a line of its own, and gets only its own.
	typed_reads(r, one, {'c', 'd', '\n'}, "cd\n",
		"the window that took the front gets what was typed after it, and not before")

	// And nothing landed in the first window, whose line is still unfinished.
	if attr, aerr := vfs.chan_stat(zero); check(r, aerr == vfs.OK, "the first window's queue answers") {
		check(
			r,
			attr.size == 0,
			"and the half-typed line has not been delivered, because it is not a line yet",
		)
	}

	_, berr := vfs.chan_write(zero_ctl, 0, bytes_of("raise\n"))
	check(r, berr == vfs.OK, "and the front goes back to the first window")
	typed_reads(r, zero, {'e', '\n'}, "abe\n",
		"which finishes the line it was in the middle of, with what it was typed before the front moved")
}

/*
verify_rawmode is a window's own `consctl`, which is what `rio` serves one per
window for.

Raw is `there is no line discipline`, the sentence `kernel/devfs` puts on the
same distinction. A client that asked for it gets every character as it
arrives, editing keys and all, and no newline is needed to make a read answer.
*/
@(private = "file")
verify_rawmode :: proc(r: ^Result, cons: ^vfs.Chan) #no_bounds_check {
	cc, cerr := vfs.open_path(vfs.boot_namespace, "/mnt/0/consctl", vfs.O_RDWR)
	if !check(r, cerr == vfs.OK, "a window has a consctl of its own") {
		return
	}
	buf: [32]u8
	n, rerr := vfs.chan_read(cc, 0, buf[:])
	check(
		r,
		rerr == vfs.OK && n >= 6 && string(buf[:6]) == "rawoff",
		"which reports the mode as the word that would set it, the consctl convention",
	)

	_, werr := vfs.chan_write(cc, 0, bytes_of("rawon"))
	check(r, werr == vfs.OK, "and takes rawon")
	n2, r2 := vfs.chan_read(cc, 0, buf[:])
	check(
		r,
		r2 == vfs.OK && n2 >= 5 && string(buf[:5]) == "rawon",
		"and says so afterwards",
	)

	// No newline, and the read still answers -- which is the whole of what raw
	// means to a client.
	rawkeys := [2]u8{'x', 'y'}
	if !type_settled(rawkeys[:]) || !wait_for_size(cons, 2) {
		check(r, false, "a character typed in raw mode arrives with no newline behind it")
	} else {
		got: [16]u8
		k, kerr := vfs.chan_read(cons, 0, got[:])
		check(
			r,
			kerr == vfs.OK && k == 2 && string(got[:2]) == "xy",
			"a character typed in raw mode arrives with no newline behind it",
		)
	}

	// And the mode goes back with the fid, which is /dev/consctl's rule.
	vfs.chan_close(cc)
	back, berr := vfs.open_path(vfs.boot_namespace, "/mnt/0/consctl", vfs.O_RDWR)
	if check(r, berr == vfs.OK, "its consctl opens again") {
		n3, r3 := vfs.chan_read(back, 0, buf[:])
		check(
			r,
			r3 == vfs.OK && n3 >= 6 && string(buf[:6]) == "rawoff",
			"and the mode went back to cooked with the fid that set it",
		)
		vfs.chan_close(back)
	}
}

/*
type_settled types keys and waits until the console has handed them to a
reader, which is the draw server's child.

**The fence a claim about half a line needs.** `verify_split` asserts what
happens between two typed characters, so it has to know the first reached the
window it was meant for before the front moved. Typing and moving on races the
child, and a race here does not produce a wrong answer -- it produces the *old*
answer, which is the one the check exists to reject.

`devfs.cons_takes` is the only thing in the system that says a reader consumed.
*/
@(private = "file")
type_settled :: proc(keys: []u8) -> bool #no_bounds_check {
	before := devfs.cons_takes()
	for c in keys {
		devfs.keyboard_sink(c)
	}
	for _ in 0 ..< PATIENCE {
		if devfs.cons_takes() >= before + u64(len(keys)) {
			return true
		}
		sync.delay(1)
	}
	return false
}

// wait_for_size polls a window's queue until it holds at least `want` bytes.
// The delivery crosses a process, so a line typed here is in the kernel's
// discipline before it is in a window's ring.
@(private = "file")
wait_for_size :: proc(c: ^vfs.Chan, want: u64) -> bool {
	for _ in 0 ..< PATIENCE {
		if attr, err := vfs.chan_stat(c); err == vfs.OK && attr.size >= want {
			return true
		}
		sync.delay(1)
	}
	return false
}

// typed_reads types a run of keys and checks what one read of `cons` answers.
// The keys are raw: the control characters are the point of most callers.
// typed_runes is `typed_reads` for keys written as runes. Odin encodes the
// string literal, so the bytes that go on the wire come from the compiler
// rather than from the encoder under test.
@(private = "file")
typed_runes :: proc(r: ^Result, cons: ^vfs.Chan, keys: string, want: string, what: string) {
	typed_reads(r, cons, transmute([]u8)keys, want, what)
}

@(private = "file")
typed_reads :: proc(r: ^Result, cons: ^vfs.Chan, keys: []u8, want: string, what: string) #no_bounds_check {
	if !type_settled(keys) {
		check(r, false, what)
		return
	}
	if !wait_for_size(cons, u64(len(want))) {
		check(r, false, what)
		return
	}
	got: [64]u8
	n, err := vfs.chan_read(cons, 0, got[:])
	check(r, err == vfs.OK && n == len(want) && string(got[:n]) == want, what)
}

/*
typed_to types one line at the keyboard and checks it reached `want` and not
`other`.

Three claims per call, and the pair of calls is what makes them a routing rule
rather than a coincidence:

    the arrival    the line is in the window that has the focus
    the routing    and in no other, read before the drain below could hide it
    the drain      and reading it empties the queue, which a file would not

**What is polled is the size, not the file**, and the first cut of this got it
wrong in a way worth keeping written down. A read with a deadline looked like
the way to ask an empty queue whether anything was there. It is not: the
deadline flushes the request on the wire and `serve_mux`'s worker never hears
it -- `docs/HANDOFF.md` section 6 names that gap -- so each abandoned read left
a worker polling a ring for ever, and the server wedged once every slot was
spent. `cons` answers its size with the bytes waiting, the way `kbdfs` does, so
a queue can be asked without being read from.

The poll is because the delivery crosses a process. The draw server's reader
child is parked on `/dev/cons` in a process of its own, so a line typed here is
in the kernel's line discipline before it is in a window's ring, and the two
are not the same instant.
*/
@(private = "file")
typed_to :: proc(r: ^Result, want: ^vfs.Chan, other: ^vfs.Chan, text: string, what: string) #no_bounds_check {
	// The newline is what makes the kernel's line discipline hand the line
	// over. Until it lands there is nothing for any window to be given.
	for c in transmute([]u8)text {
		devfs.keyboard_sink(c)
	}
	devfs.keyboard_sink('\n')

	waiting := u64(0)
	for _ in 0 ..< PATIENCE {
		if attr, err := vfs.chan_stat(want); err == vfs.OK && attr.size > 0 {
			waiting = attr.size
			break
		}
		sync.delay(1)
	}

	// The other window, read before the drain below, because a routing bug
	// that put the line in both would otherwise be hidden by it.
	rest, oserr := vfs.chan_stat(other)
	check(
		r,
		oserr == vfs.OK && rest.size == 0,
		"and in no other window, because a line belongs to the one in front",
	)

	/*
	The line itself, which is what the size was only promising.

	**Gated on the size, so a delivery that never happened fails a check
	rather than stopping the boot.** An ordinary read of an empty queue parks
	until something arrives, and for a window nobody is typing at that is for
	ever. `docs/TESTING.md` names a hang as the worst way for a check to
	report, and the gap that makes one reachable here is a standing one.
	*/
	got: [64]u8
	n := 0
	rerr := vfs.Errno(vfs.OK)
	if waiting > 0 {
		n, rerr = vfs.chan_read(want, 0, got[:])
	}
	check(
		r,
		waiting >= u64(len(text)) && rerr == vfs.OK && n >= len(text) &&
		string(got[:len(text)]) == text,
		what,
	)

	// And the queue gave it up. A file would answer the same bytes twice.
	if attr, aerr := vfs.chan_stat(want); aerr == vfs.OK {
		check(
			r,
			attr.size == 0,
			"and a line read once is gone, the way a queue empties and a file would not",
		)
	}
}

/*
verify_ctl is the three lines a client may say about its own window.

    move X Y     put it somewhere else
    size W H     make its client area another shape, inside the run it holds
    raise        bring it to the front
    name TEXT    what the bar across its top says

**Four `ctl` lines rather than four verbs**, which is the distinction
`docs/DRAW.md` section 5 guards. A verb is about pixels, and a window is not a
pixel -- and neither is its name. The lines needed a tree that could name a
window, which is what the numbered directories are for.

The two windows arrive here as `docs/DRAW.md` section 10's cascade left them.
Window zero at the origin holds `A3` across one row. Window one sits half a
window across with nothing drawn in it. Every check below reads the glass.
*/
@(private = "file")
verify_ctl :: proc(
	r: ^Result,
	s: ^fb.Surface,
	win_w: int,
	win_h: int,
	ox: int,
	oy: int,
	sy: int,
	fw: int,
	A3: u32,
	first_ctl: ^vfs.Chan,
	server: ^Process,
) #no_bounds_check {
	/*
	The two sensors this procedure watches, derived rather than handed over.

	`ground_x` is inside the second window's rectangle and outside the first's.
	`far_x` is past where either window ever sits, and is where the `move`
	below has to arrive. Both used to come in as coordinates *and* as a sampled
	pixel value apiece, six parameters for two questions -- and the question is
	always "is this the desktop again", which `is_desk` answers by name. A
	sample that happened to land on a grid column would have satisfied the
	comparison either way.
	*/
	ground_x := fw + 8
	ground_y := sy - 4
	far_x := s.width - 280
	far_y := 50
	cfd, cerr := vfs.open_path(vfs.boot_namespace, "/mnt/1/ctl", vfs.O_RDWR)
	if !check(r, cerr == vfs.OK, "a window's own ctl file opens") {
		return
	}
	defer vfs.chan_close(cfd)

	/*
	And it is exclusive, the way `data` is.

	One fid at a time holds a window's controls, so two clients cannot both
	move one window. It is the whole of the protection a `ctl` line has, and it
	is not much. A window whose client never opens its own controls leaves them
	for whoever asks. Users are what Plan 9 puts in that gap, and there are none
	here.
	*/
	rival, rerr := vfs.open_path(vfs.boot_namespace, "/mnt/1/ctl", vfs.O_RDWR)
	check(r, rerr != vfs.OK, "and a second holder of one window's controls is refused")
	if rerr == vfs.OK {
		vfs.chan_close(rival)
	}

	geo: [64]u8
	gn, gerr := vfs.chan_read(cfd, 0, geo[:])
	cw, ch, _, _, gok := libdraw.parse_geometry(geo[:max(gn, 0)])
	check(
		r,
		gerr == vfs.OK && gok && cw == win_w && ch == win_h,
		"and reads back this window's own client area, which is what it was born with",
	)

	// -- The lines it refuses -------------------------------------------------

	_, uerr := vfs.chan_write(cfd, 0, bytes_of("wiggle\n"))
	check(r, uerr != vfs.OK, "a line this server does not know is refused")
	_, perr := vfs.chan_write(cfd, 0, bytes_of("move 4\n"))
	check(r, perr != vfs.OK, "and a line missing one of its numbers")
	_, xerr := vfs.chan_write(cfd, 0, bytes_of("move 4 5 6\n"))
	check(r, xerr != vfs.OK, "and a line carrying one too many")
	_, berr := vfs.chan_write(cfd, 0, bytes_of("size 9000 9000\n"))
	check(
		r,
		berr != vfs.OK,
		"and a size past the run the window was born with, which is segbrk's absence",
	)

	// -- raise, and the focus that rides on it --------------------------------

	/*
	Which window the machine is listening to, read before the raise and after
	it.

	**Focus is the front**, so `raise` is the whole mechanism and a title bar's
	colour is the whole of what it looks like. The window in front wears the
	chassis's copper and every other bar wears `COPPER_DARK`, which is the
	lamp's dark-in-its-own-colour rule applied to a surface.

	**Both windows are read in both states**, which is what makes this an
	anchor rather than a colour somebody expected: a server that painted every
	bar alike fails one window's pair of readings, and a server with the sense
	inverted fails the other's.

	Neither pixel can be covered by the other window. Window zero's bar is read
	near its left edge, well left of where window one begins, and window one's
	past `fw`, which is where window zero ends. The row is inside the bar for
	both, the bar being much the tallest part of the band above a client area.
	*/
	bar_y := oy / 2
	one_x := fw + 8
	lit := fb.pack(s, fb.COPPER)
	dark := fb.pack(s, fb.COPPER_DARK)
	check(
		r,
		fb.get_raw(s, one_x, bar_y) == lit && fb.get_raw(s, ox + 8, bar_y) == dark,
		"the window that opened last is the one in front, and the bar below it is dark",
	)

	/*
	The first client comes to the front, and the overlap changes hands.

	Slot order was stacking order until this line existed. It cannot be both,
	so the stack is a list of its own and this moves one entry to its end. The
	pixel watched is one the second window sat on from the moment it opened.

	The first client already holds its own controls, and that is the point of
	the exclusion check above rather than a convenience here. It opened
	`/mnt/0/ctl` for the geometry before it ever drew, and a second holder
	would be refused the same way this window's was.
	*/
	_, werr := vfs.chan_write(first_ctl, 0, bytes_of("raise\n"))
	check(r, werr == vfs.OK, "the first client asks its own controls to raise it")
	check(
		r,
		fb.get_raw(s, ox + win_w - 1, sy) == A3,
		"which puts its own pixels over the window that was above it",
	)
	check(
		r,
		fb.get_raw(s, ox + 8, bar_y) == lit && fb.get_raw(s, one_x, bar_y) == dark,
		"and takes the focus with it, because the front is the whole of what focus is",
	)

	verify_cons(r, first_ctl, cfd)

	// -- move -----------------------------------------------------------------

	/*
	**The first thing in this server that damages two rectangles far apart.**
	The old place and the new one go into one region as two entries rather than
	one box around both. That is the case `MAX_RECTS` was sized for, and nothing
	reached it until this line.

	The two checks below watch the move rather than the region. A coarser damage
	record would still be *right* here, because `composite` paints only windows
	and there is no window in the gap. So the mutation that boxes the two
	together is inert, and `docs/DRAW.md` records it that way. What these watch
	is that the window arrives, and that the ground it left comes back.
	*/
	_, merr := vfs.chan_write(cfd, 0, bytes_of("move 700 0\n"))
	check(r, merr == vfs.OK, "the second client moves its window")
	check(r, !is_desk(s, far_x, far_y), "which arrives where it was sent")
	check(
		r,
		is_desk(s, ground_x, ground_y),
		"and leaves the ground behind where it was standing",
	)

	// -- size -----------------------------------------------------------------

	/*
	And it shrinks, inside the run it holds. `far` is past the new edge, so the
	ground has to come back there too. It comes out of the same `desk_paint` a
	close would do, over the part the window gave up.
	*/
	/*
	And first it grows past the size its slot was born with, which is the
	sentence `segbrk` was built for.

	**A run used to be fixed at its one `segalloc`**, so `window_size` refused
	anything taller than the window it was handed and `docs/DRAW.md` recorded
	that as `segbrk`'s absence speaking. The call exists now, and this is the
	client asking for it without knowing: a `ctl` line names a client area, and
	the server turns that into a run that has to get bigger.

	The frames are counted across it, because a grow that answered without
	allocating would pass a geometry check and leak nothing but truth.
	*/
	grew_from := mem.pmm_stats().free_frames

	/*
	Where this window's bottom edge is before it grows.

	**This is what a window born shorter than the glass buys.** While every
	window was as tall as the screen, the rows a grow added fell below it and
	`composite` clipped them away, so `segbrk` had a frames-dropped check and
	nothing that could see the result. The edge is on the glass now, and
	`win_bottom` walks down to it out of the window `move` put at 700.
	*/
	grew_col := 700 + ox + 8
	bottom_before := win_bottom(s, grew_col, 0)

	// Eight rows, not two hundred: the claim is that a window grows past the
	// height its slot was born with, and eight proves it as well as any. The
	// larger number cost 640 KB and a full-height repaint the checks never
	// looked at.
	tall := win_h + 8
	// `libodin`'s formatter, which is what this tree writes numbers with. A
	// fourth hand-rolled digit loop was two of them ago.
	big: [32]u8
	sink := libodin.sink_from(big[:])
	libodin.put_str(&sink, "size 200 ")
	libodin.put_uint(&sink, u64(tall))
	libodin.put_str(&sink, "\n")
	_, gerr3 := vfs.chan_write(cfd, 0, libodin.bytes(&sink))
	check(r, gerr3 == vfs.OK, "a client asks for a window taller than the one its slot was born with")

	geo3: [64]u8
	gn3, ge3 := vfs.chan_read(cfd, 0, geo3[:])
	_, gh3, _, _, gok3 := libdraw.parse_geometry(geo3[:max(gn3, 0)])
	check(
		r,
		ge3 == vfs.OK && gok3 && gh3 == tall,
		"and gets it, which no run fixed at one segalloc could have answered",
	)
	check(
		r,
		mem.pmm_stats().free_frames < grew_from,
		"and the machine is poorer for it, so the pages are real",
	)

	/*
	And the window stands that much taller on the glass, which is the claim a
	frame count cannot make.

	A grow that allocated pages and mapped them somewhere else drops frames
	exactly the same way. What says the run got bigger *where the client was
	promised* is the bottom edge moving by the rows asked for, with the
	compositor reading them out of the store to put them there.
	*/
	bottom_after := win_bottom(s, grew_col, 0)
	check(
		r,
		bottom_after - bottom_before == tall - win_h,
		"and stands that much taller on the glass, which no frame count could say",
	)

	/*
	And every frame the server maps is one its segments own, which is the
	claim the glass cannot make either.

	This is the sweep `docs/USER.md` asked for. A `segment_frame` that reads
	a grown run's tail out of its first piece maps frames past that piece's
	end. The server writes the new rows there and the compositor reads them
	back from there. So the window stands exactly as tall as it should, on
	memory the allocator gave to somebody else. No readback sees it. The
	record does: those frames are in no piece.

	The server is parked between requests, which is what holds it still for
	the walk. Its reader child holds none of the window runs. They are bought
	at `Tlopen` now, after the fork, and given back at the clunk with
	`segdetach`. So the child is short of nothing, and maps nothing past what
	it was given. While the runs were bought at start and shared, the child
	was short of exactly the pages the server's run gained after the fork.
	`segment_grow` says why.
	*/
	grown := 0
	for i in 0 ..< server.seg_count {
		if seg := server.segs[i]; seg != nil && seg.kind == .Anon {
			for j in 1 ..< seg.piece_n {
				grown += seg.pieces[j].pages
			}
		}
	}
	check(r, grown > 0, "the server holds a run with a second piece, which is what a grow leaves")
	swept := sweep(server)
	check(r, swept.stray == 0, "every page the server maps is inside a segment it holds")
	check(r, swept.borrowed == 0, "and every frame under one is that segment's own, the grown tail included")
	check(r, swept.short == 0, "and every page of every run it holds is mapped, the grown tail included")
	if reader := forked_child(server); check(r, reader != nil, "the server's reader child is in the table") {
		child_swept := sweep(reader)
		check(
			r,
			child_swept.stray == 0 && child_swept.borrowed == 0,
			"and maps the shared run's frames, and none past the end it was given",
		)
		check(r, child_swept.short == 0, "and holds no window run at all, because those are bought after the fork")
	}

	/*
	And smaller again, and the run follows now.

	**A shared run may not shrink**, which is `ibrk`'s `Einuse` and
	`docs/USER.md`'s reason: another process maps the same frames and the ones
	about to go back may already be somewhere in its kernel. Every window run
	was shared while the server bought them at start, before its fork. This
	line used to say the run did not have to follow. A run is bought at
	`Tlopen` now, after the fork, so it is the server's alone and the pages go
	back. The frames say so below.

	The window gets smaller either way. Keeping the pages is what a refused
	shrink costs, and refusing the *client* is not -- which is the
	distinction `window_size` makes and this checks.
	*/
	shrink_from := mem.pmm_stats().free_frames
	_, serr := vfs.chan_write(cfd, 0, bytes_of("size 200 100\n"))
	check(r, serr == vfs.OK, "and makes it smaller, and a run the server holds alone follows")
	check(
		r,
		mem.pmm_stats().free_frames > shrink_from,
		"and the machine is richer for it, because a run nobody shares may shrink",
	)
	check(r, is_desk(s, far_x, far_y), "which gives back the ground it was covering")

	gn2, gerr2 := vfs.chan_read(cfd, 0, geo[:])
	nw, nh, _, _, gok2 := libdraw.parse_geometry(geo[:max(gn2, 0)])
	check(
		r,
		gerr2 == vfs.OK && gok2 && nw == 200 && nh == 100,
		"and reads back the client area it asked for, which is the only answer a ctl line gets",
	)

	/*
	And the frame came with it, which a control found nothing watching.

	A window's border lives in its store beside the client's pixels, so a
	resize that moved the edges and left the frame where it was would leave the
	old bar's copper standing where the new right border belongs. The pixel
	watched is that border, on a row above the client area and outside the
	bar's own columns.

	`.Raised` puts the shadow on the right, so this is `MAGNESIUM_DARK` and not
	the highlight the left edge carries.

	Where that edge *is* comes from `win_right`, which walks out of the window
	until the desktop begins. The window's new width was computed from
	`libdraw`'s frame arithmetic until this milestone, and a resize that moved
	the client area without moving the border would have moved this sensor with
	it.
	*/
	wr := win_right(s, 7, 700)
	check(
		r,
		fb.get_raw(s, wr - 1, 7) == fb.pack(s, fb.MAGNESIUM_DARK),
		"and its frame moved to the new edge, over what the old one left in the run",
	)

	// -- name -----------------------------------------------------------------

	/*
	And the bar across the top of it says what the client called it.

	**The one `ctl` line whose operand is not a number**, and the one thing on
	this screen the *server* draws about a client's window. A client uploads
	its own glyphs and blits them, which is section 5's answer to a font verb.
	A title is not the client's text, so it needed no verb: the server links
	`sys/libfont` -- the same 8x16 table the kernel console draws with -- and
	stores the letters into memory the client cannot reach.

	The sensor is the band above this window's client area -- border, bar and
	the well's lip -- taken across the window's own width, which `win_right`
	finds. The letters are `SLATE_DEEP`, which is `kernel/splash.odin`'s
	engraved wordmark and the one colour any of those three could not otherwise
	contain. Looked up positionally rather than by the bar's copper, so a bar
	that is restyled -- the focus colour `docs/DRAW.md` section 12 names next --
	does not take the sensor with it.

	Both directions, because a bar is laid down before its letters are. A name
	that goes away has to take its pixels with it, and only a server that
	repaints the bar can do that.
	*/
	bx, by := 700, 0
	bw, bh := win_right(s, oy / 2, 700) - 700, oy
	ink := fb.pack(s, fb.SLATE_DEEP)
	if !check(r, bw > 0, "the window it moved and resized is where the move put it") {
		return
	}
	check(r, !bar_has(s, bx, by, bw, bh, ink), "a window is born nameless, and its bar is copper and nothing else")

	_, nerr := vfs.chan_write(cfd, 0, bytes_of("name VECTRA\n"))
	check(r, nerr == vfs.OK, "the client names its own window")
	check(
		r,
		bar_has(s, bx, by, bw, bh, ink),
		"and the bar says so, in the font the draw server has and never gave a verb to",
	)

	_, eerr := vfs.chan_write(cfd, 0, bytes_of("name\n"))
	check(r, eerr == vfs.OK, "a name of nothing is a name")
	check(
		r,
		!bar_has(s, bx, by, bw, bh, ink),
		"and takes the old one off with it, because the bar is repainted and not drawn over",
	)
}

/*
scan_col and scan_row answer the first and last place `want` appears down one
column, or along one row, of the glass. Both answer (-1, -1) when the colour is
not there at all.

**This is how the test learns where a client's pixels actually landed.** It
used to compute that from `sys/libdraw`'s frame constants -- the same constants
`servers/intuition` lays a window out with -- and `docs/TESTING.md` names
agreeing with the code under test as the way a check passes for the wrong
reason. An inset both sides read from one table is exactly that agreement, and
it made every mutation of the frame's *geometry* unobservable: only a server
that stopped calling `libdraw` at all could fail.

So a client fills the rectangle it was told it has, and the glass says where
that rectangle is. What comes back is a sensor rather than a restatement.
*/
@(private = "file")
scan_col :: proc "contextless" (s: ^fb.Surface, x: int, want: u32, y0: int, y1: int) -> (first: int, last: int) {
	first, last = -1, -1
	for y in y0 ..< y1 {
		if fb.get_raw(s, x, y) == want {
			if first < 0 {
				first = y
			}
			last = y
		}
	}
	return
}

@(private = "file")
scan_row :: proc "contextless" (s: ^fb.Surface, y: int, want: u32, x0: int, x1: int) -> (first: int, last: int) {
	first, last = -1, -1
	for x in x0 ..< x1 {
		if fb.get_raw(s, x, y) == want {
			if first < 0 {
				first = x
			}
			last = x
		}
	}
	return
}

/*
The desktop, measured off a screen it is the only thing on.

**`is_desk` used to restate the desktop's own arithmetic -- the same
formula, the same step, the same two colours as `servers/intuition`'s
`desk_paint`.** Every geometric discovery in
this file runs through it, so that one restatement put the desktop's *look*
back into the test at the same moment the window frame's was taken out. A
restyled desktop would have failed the frame's anchor checks, which is a check
failing for the wrong reason.

So it is read instead. The draw server paints the whole desktop before it posts
`/srv/draw` and no window exists until a client opens `data`, so the glass
right after `await_posted` is a desktop with nothing on it. Three reads and a
short walk give the whole of what `is_desk` needs: the ground, the grid, and
the step between grid lines. A restyled desktop is inert now, the way a deeper
border already is.
*/
@(private = "file")
Desk :: struct {
	ground: u32,
	grid:   u32,
	step:   int,
}

@(private = "file")
desk: Desk

@(private = "file")
desk_measure :: proc "contextless" (s: ^fb.Surface) -> bool {
	/*
	One run of one row, well inside everything else on the screen.

	The row clears the recess the desktop is sunk into, which is two pixels of
	`VOID` around the whole glass -- reading the corner instead is how the
	first cut of this measured the grid twice and answered a step of zero. The
	columns clear that recess on the left and the lamp strip on the right, and
	no window exists yet.

	A plain desktop row is ground with a grid pixel every step, so exactly two
	colours appear on it and the commoner one is the ground. A third colour
	means this is not a bare desktop and there is nothing here to measure.
	*/
	Y :: 101
	x0 := 64
	x1 := min(s.width, x0 + 512)
	if x1 - x0 < 64 {
		return false
	}

	a := fb.get_raw(s, x0, Y)
	b := u32(0)
	na, nb := 0, 0
	for x in x0 ..< x1 {
		v := fb.get_raw(s, x, Y)
		switch {
		case v == a:
			na += 1
		case nb > 0 && v == b:
			nb += 1
		case nb == 0:
			b, nb = v, 1
		case:
			return false
		}
	}
	if nb == 0 {
		return false
	}
	desk = Desk{ground = na >= nb ? a : b, grid = na >= nb ? b : a, step = 0}

	// And the step is the gap between two grid columns on that same row.
	prev := -1
	for x in x0 ..< x1 {
		if fb.get_raw(s, x, Y) != desk.grid {
			continue
		}
		if prev >= 0 {
			desk.step = x - prev
			break
		}
		prev = x
	}
	return desk.step > 1 && Y % desk.step != 0
}

// A desktop that was never measured answers false everywhere rather than
// dividing by a step of zero, so a failed measurement is a run of failed
// checks instead of a fault.
@(private = "file")
is_desk :: proc "contextless" (s: ^fb.Surface, x: int, y: int) -> bool {
	if desk.step <= 0 {
		return false
	}
	want := (x % desk.step == 0 || y % desk.step == 0) ? desk.grid : desk.ground
	return fb.get_raw(s, x, y) == want
}

// win_right walks right along one row from inside a window to the first pixel
// that is desktop again, which is where that window's rectangle ends. A window
// is opaque over the whole of it, so nothing in between can answer true.
@(private = "file")
win_right :: proc "contextless" (s: ^fb.Surface, y: int, from: int) -> int {
	x := from
	for x < s.width && !is_desk(s, x, y) {
		x += 1
	}
	return x
}

// win_bottom walks down one column from inside a window to the first pixel
// that is desktop again, which is where that window's rectangle ends. The
// vertical twin of `win_right`, and it exists because a window is no longer
// as tall as the glass -- the screen's bottom edge used to stand in for a
// window's own, and now it cannot.
@(private = "file")
win_bottom :: proc "contextless" (s: ^fb.Surface, x: int, from: int) -> int {
	y := from
	for y < s.height && !is_desk(s, x, y) {
		y += 1
	}
	return y
}

/*
find_rect answers the bounding box of one colour on the glass, given a column
it is known to cross.

The shape every discovery in this file has: scan a column for the run's top and
bottom, then scan the middle of that run for its left and right. Three callers
wrote it out before this was lifted. A width of zero is nothing found.
*/
@(private = "file")
find_rect :: proc "contextless" (s: ^fb.Surface, want: u32, probe_x: int, from_x: int) -> (x: int, y: int, w: int, h: int) {
	top, bot := scan_col(s, probe_x, want, 0, s.height)
	if top < 0 {
		return -1, -1, 0, 0
	}
	left, right := scan_row(s, (top + bot) / 2, want, from_x, s.width)
	if left < 0 {
		return -1, -1, 0, 0
	}
	return left, top, right - left + 1, bot - top + 1
}

// bar_has reports whether one colour appears anywhere in a rectangle of the
// glass. The title checks want a letter somewhere on a bar rather than a
// letter at a place, because where a name starts is the server's padding and
// not a rule worth freezing into a test.
@(private = "file")
bar_has :: proc "contextless" (s: ^fb.Surface, x: int, y: int, w: int, h: int, want: u32) -> bool {
	for row in 0 ..< h {
		if first, _ := scan_row(s, y + row, want, x, x + w); first >= 0 {
			return true
		}
	}
	return false
}

/*
verify_anon is the memory a program asks for rather than owns at birth.

**This is the milestone `docs/DRAW.md` section 10 named a milestone before it
existed.** A 640 by 800 window is two megabytes. `MAX_PROGRAM_FRAMES` bounds a
whole program at a quarter of one, and static `bss` was all a program had. So
a window with pixels of its own was never a graphics question. It was a
segment described by a base and an extent, and a call to ask for one.

Six claims, and each is a different kind of claim:

    the address    a run lands in the program's own half
    the zero       and arrives clean, because the frames came back from a
                   program that ended
    the far end    a store half a megabyte in comes back, so the run is
                   mapped whole and not only at its first page
    the arithmetic the caller's errno refuses nothing and too-much
    the fork       a child's store lands in the child's copy
    the frames     and both runs go back to the allocator by name

The last one is the one with no confounder in it. `mem.frame_is_free` asks
about the exact frame the segment held. A total would hide a leak inside
whatever a thread stack allocated in between. `docs/TESTING.md` argues that
distinction at length, and this is the shape it argues for.
*/
@(private = "file")
verify_anon :: proc(r: ^Result) {
	pages := int(ANON_BYTES / u64(arch.PAGE_SIZE))
	check(r, pages > MAX_PROGRAM_FRAMES, "the run asked for is longer than a frame list holds")

	frames_before := mem.pmm_stats().free_frames
	untracked_before := mem.pmm_stats().untracked_frees
	segs_before := segment_stats()

	p, err := load("anon", program_anon(), ANON_BYTES)
	if !check(r, err == .None && p != nil, "a process is loaded that asks for memory nobody serves") {
		return
	}
	r.programs += 1

	/*
	The wedge, and why the program waits for it.

	The allocator hands out adjacent runs. A grow that follows the ask with
	nothing between lands on the frames right after the run's block. A
	`segment_frame` that reads a grown run's tail out of its first piece then
	answers the right frames by luck. The sweep below has nothing to see.
	That control came back clean once for exactly this reason.

	So the program stops after its second ask and waits for a word. The
	kernel takes one frame, which is the one the allocator would have handed
	to the grow, and only then says go. The grown piece cannot be adjacent
	now, and the control fails where it should. The frame goes back after
	the teardown, before the totals are read.
	*/
	asked := false
	for _ in 0 ..< PATIENCE {
		if cell(p, ANON_AGAIN) != 0 {
			asked = true
			break
		}
		sync.delay(1)
	}
	check(r, asked, "the program asked twice and waits for the kernel's word before it grows")
	wedge, wedged := mem.alloc_page()
	check(r, wedged, "and the kernel takes the frame the allocator would have handed the grow")
	set_cell(p, ANON_GO, 1)

	if !check(r, wait(p, PATIENCE), "and it comes back") {
		if wedged {
			mem.free_page(wedge)
		}
		finish(r, p, "and is taken down")
		return
	}
	check(r, cell(p, CELL_MARK) == MARK_ANON, "having reached its first instruction")

	addr := uintptr(cell(p, ANON_ADDR))
	check(
		r,
		addr >= mem.USER_MIN && addr < mem.USER_MAX,
		"the run landed at an address in the program's own half",
	)
	check(
		r,
		cell(p, ANON_ZERO) == 0,
		"and arrived zero, because a page the last program wrote is not this one's to read",
	)
	check(
		r,
		cell(p, ANON_BACK) == ANON_PATTERN,
		"a store half a megabyte in came back, so the run is mapped end to end",
	)

	/*
	A second ask is a second address, and the check says *address* on purpose.

	`verify_mapping` learned this the hard way one milestone ago. A check that
	asks only whether the second number is larger passes when the second call
	*fails*. A negative errno reads back as an enormous unsigned number. So
	this asks the bound at both ends, and asks for the span between them as
	well.
	*/
	again := uintptr(cell(p, ANON_AGAIN))
	span := uintptr(pages) * uintptr(arch.PAGE_SIZE)
	check(
		r,
		again >= mem.USER_MIN && again < mem.USER_MAX && again >= addr + span,
		"a second ask is a second address, clear of the first run's whole extent",
	)

	check(
		r,
		cell(p, ANON_HUGE) == refused(vectra9.EINVAL),
		"a gigabyte is refused, because a resource with no bound is not a bounded resource",
	)
	check(r, cell(p, ANON_NONE) == refused(vectra9.EINVAL), "and so is a request for nothing at all")

	/*
	And a fork copied it.

	`RFPROC` alone, so `RFMEM` is clear and anonymous memory answers that flag
	the way data does. The child stored its own word over the first one and
	exited. What the parent reads is the fork rule in one word. The two values
	differ, so a wrong answer says which process wrote last.

	The status carries the child's own claim, which the parent cannot make.
	A child inherits its parent's address space and the mark above it. So the
	run it asks for after the fork has to land clear of the runs it already
	holds. It checked that before it wrote anything, and `ANON_CHILD_REFUSED`
	is that check failing. See `Process.map_next`.
	*/
	check(
		r,
		cell(p, ANON_STATUS) == ANON_CHILD_STATUS,
		"a forked child got a run of its own that did not land on one it inherited",
	)
	check(
		r,
		cell(p, ANON_KEPT) == ANON_PATTERN,
		"and the parent's run still holds the parent's word, because a fork without RFMEM copies",
	)

	/*
	And the second run grew, was written at its new end, and shrank part-way
	back.

	This is `segbrk` asked by a program rather than by the draw server. It
	is here for what it leaves behind: a run of two pieces, one of them
	trimmed. The store into the tail is the check that the grow was real. A
	grow that answered without mapping faults on that line and the program
	never comes back.
	*/
	check(r, i64(cell(p, ANON_GROWN)) == 0, "the second run grew by four pages when asked")
	check(r, cell(p, ANON_TAIL) == ANON_PATTERN, "and a word stored at the new end came back")
	check(r, i64(cell(p, ANON_SHRUNK)) == 0, "and it gave two of the four back")

	/*
	And a third run went back whole, which is `segdetach`.

	The mapping and the segment both have to go, and each half has a check
	that sees it alone. A detach that released the segment and left the
	mapping is a stray leaf in the sweep below. One that unmapped and never
	released is a live segment after the teardown, in the balance check at
	the end. The two refusals are the rule `sys_segdetach` states: a run may
	go, an image's shape may not, and an address nothing covers is nothing.
	*/
	third := uintptr(cell(p, ANON_THIRD))
	check(r, third >= mem.USER_MIN && third < mem.USER_MAX, "a third run was asked for, one page, to give back")
	check(r, i64(cell(p, ANON_DETACHED)) == 0, "and detached whole")
	check(r, proc_segment_at(p, third) == nil, "so no segment of the process covers its address now")
	check(
		r,
		cell(p, ANON_DETACH_TEXT) == refused(vectra9.EINVAL),
		"while the text a program was born with is refused by kind",
	)
	check(
		r,
		cell(p, ANON_DETACH_NONE) == refused(vectra9.EINVAL),
		"and an address no segment covers is refused by name",
	)

	// The wedge did its work: the grown piece does not start where the first
	// piece ends. Without this the sweep's ownership question has one answer
	// whatever `segment_frame` does, and the control it exists for is inert.
	grown_run := proc_segment_at(p, uintptr(cell(p, ANON_AGAIN)))
	check(r, grown_run != nil && grown_run.piece_n == 2, "the second run is two pieces now")
	check(
		r,
		grown_run != nil &&
		grown_run.piece_n == 2 &&
		grown_run.pieces[1].base != grown_run.pieces[0].base + uintptr(grown_run.pieces[0].pages) * uintptr(arch.PAGE_SIZE),
		"and the second piece is not adjacent to the first, because the kernel took the frame between them",
	)

	/*
	And the sweep can see a borrowed frame, which is the control for its
	second number and runs on every boot.

	No mutation reaches this number alive. A `segment_frame` that answers the
	wrong frame for a grown run's tail stops the boot in the draw server. Its
	window grow writes rows onto memory the run does not own, long before
	this process exists.

	So the test makes the wrong arrangement by hand, where it is expressible.
	It points one page of the run at the kernel's wedge frame behind the
	record's back. The sweep has to name exactly that, and then the page goes
	back. The program ended. Nothing translates through these tables while
	they lie.
	*/
	if grown_run != nil && wedged {
		page_va := grown_run.va
		was, had := mem.translate(p.space, page_va)
		swapped :=
			had &&
			mem.unmap_user(p.space, page_va, 1) == .None &&
			mem.map_user(p.space, page_va, wedge, grown_run.flags, 1) == .None
		check(r, swapped, "one page of the run is pointed at the kernel's wedge frame, behind the record's back")
		tampered := sweep(p)
		check(
			r,
			tampered.borrowed == 1 && tampered.stray == 0 && tampered.short == 0,
			"and the sweep names it: one frame under a segment that the segment does not own, and nothing else",
		)
		restored :=
			mem.unmap_user(p.space, page_va, 1) == .None &&
			mem.map_user(p.space, page_va, was, grown_run.flags, 1) == .None
		check(r, restored, "and the page is put back where the record says it is")
	}

	/*
	Every frame the process maps belongs to one of its segments.

	This is the check `docs/USER.md` said no readback could make. A grown run
	whose `segment_frame` reads every page out of its first piece maps frames
	past that piece's end. It writes them, reads them back, and releases the
	frames its record names. Every total balances, and the pixels are right,
	because the write and the read went to the same wrong place. The walk
	over the tables is the only witness. It asks the record which frames are
	the segment's, rather than asking `segment_frame` where page n went.

	`short` is zero here and not in every sweep. Nothing shares a run with
	this process, so every page of every segment it holds is its own to map.
	*/
	swept := sweep(p)
	check(r, swept.leaves > 2 * pages, "the sweep walked the process's tables and found its runs")
	check(r, swept.stray == 0, "every mapped page is inside a segment the process holds")
	check(r, swept.borrowed == 0, "and every frame under one is a frame that segment owns")
	check(r, swept.short == 0, "and every page of every segment is mapped")

	/*
	The frames the two runs held, taken by name before the teardown.

	`p.segs` is this package's own, which is why this check can be sharper
	than a total. This asks about every `.Anon` segment the process holds,
	piece by piece, after `destroy`. So a release that frees the first page
	and forgets the rest fails here, rather than hiding inside a heap that
	always allocates. The second run is two pieces now, so the walk is over
	pieces rather than from one base.
	*/
	held: [MAX_PROC_SEGS * MAX_RUN_PIECES]Run_Piece
	held_n := 0
	held_pages := 0
	runs := 0
	for i in 0 ..< p.seg_count {
		if p.segs[i].kind == .Anon {
			runs += 1
			for j in 0 ..< p.segs[i].piece_n {
				held[held_n] = p.segs[i].pieces[j]
				held_pages += held[held_n].pages
				held_n += 1
			}
		}
	}
	check(r, runs == 2, "the process holds two anonymous segments and no more")
	check(r, held_n == 3, "in three pieces, because one of them grew")
	check(r, held_pages == 2 * pages + 2, "which together are the two runs and the two pages kept")
	check(
		r,
		segment_stats().frames - segs_before.frames >= 2 * pages,
		"and the segment table counts every page of them",
	)

	check(r, destroy(p), "the process is taken down")
	if wedged {
		mem.free_page(wedge)
	}

	back := 0
	for i in 0 ..< held_n {
		for j in 0 ..< held[i].pages {
			if mem.frame_is_free(held[i].base + uintptr(j) * uintptr(arch.PAGE_SIZE)) {
				back += 1
			}
		}
	}
	check(r, back == held_pages, "and every frame of both runs went back to the allocator, by name")
	check(
		r,
		mem.pmm_stats().untracked_frees == untracked_before,
		"to the allocator that owned them, and not past the end of its bitmap",
	)

	/*
	And the total agrees, as loosely as a total honestly can.

	The frame count is not back where it started and should not be checked as
	if it were. A forked child's thread stack came out of the heap while this
	ran. The heap takes runs from this allocator and does not give them back.

	So the claim here is only that the shortfall is smaller than one run. No
	leak of a run can satisfy that, and every thread stack in the machine does.
	The check above is the sharp one. This is the one that would catch a
	release that freed the wrong address entirely.

	`verify_mapping` reaches for the same shape one page up, for the same
	reason. `docs/TESTING.md` calls the sharp form the one to prefer, and this
	is what the loose form is still worth.
	*/
	short := frames_before - mem.pmm_stats().free_frames
	check(r, short < pages, "with the machine less than one run poorer than it was")
	check(r, segment_stats().live == segs_before.live, "every segment it held was released")
}

/*
verify_windows is two milestones' sentences, one row of the glass at a time.

The first was **two clients hold the same coordinates and mean two places**.
The second is **a window has pixels of its own**, and it changes what that row
can be asked. Windows overlap now, because a window is a store rather than a
clip and placement no longer has to keep clients apart.

Five claims, in the order the row is painted:

    the origin     each client's coordinates start at its own window
    occlusion      where two windows meet, the top one is what the glass has
    the order      a covered client's flush repaints what it owns, and does
                   not lift it over the window on top
    the clip       a rectangle wider than the screen still stops at a
                   window's edge
    the uncover    a window that closes gives back what it was covering, and
                   the client underneath draws nothing to make that happen

**The last one is what a backing store is.** Nothing asks the first client to
repaint. Its pixels were its own for the whole time they were invisible, and
the compositor puts them back from memory it held. That is also why this
server has no expose event: the event exists to ask a client for pixels the
compositor did not keep.

The glass is put back before this returns. One row, saved whole, because the
checks below paint across most of its width.
*/
@(private = "file")
verify_windows :: proc(
	r: ^Result,
	s: ^fb.Surface,
	win_w: int,
	win_h: int,
	ox: int,
	oy: int,
	fw: int,
	y: int,
	first: ^vfs.Chan,
	first_ctl: ^vfs.Chan,
	server: ^Process,
) #no_bounds_check {
	/*
	`y` is a client row, and this is where it lands on the glass. Every command
	below is written in the first client's coordinates and read back in the
	screen's.

	**The row this paints across is not saved.** It used to be, into an eight
	kilobyte buffer, behind a guard that returned early when the screen was
	wider than two thousand and forty-eight pixels -- which would have skipped
	this whole milestone and the `ctl` one behind it in silence. Both went with
	the saves in `verify_draw`, and for the same reason: the compositor and
	`devfs.screen_revert` put the glass back without being asked.
	*/
	sy := oy + y

	/*
	Where the second window sits, as a fixture rather than as a question.

	The server cascades by half a *window*, frame included, and no verb would
	tell a client so. A test that could ask the server where it put things would
	be agreeing with the code under test. `docs/TESTING.md` names that as the way
	a check passes for the wrong reason.

	Three x coordinates come out of it, and keeping them apart is most of what
	a frame cost this procedure. `second_x` is where the second *window*
	begins. `second_ox` is where its client's own (0, 0) lands, a border
	further in. `under_x` is the last pixel of the first window that the second
	one does not cover -- which used to be `second_ox - 1` and is not, because
	the pixel before a client's origin is now that client's own border.
	*/
	second_x := fw / 2
	second_ox := second_x + ox
	under_x := second_x - 1

	/*
	A pixel inside the second window's rectangle and outside the first's, on a
	row no check below paints.

	It is the sensor for the desktop, and for the sentence three milestones
	were spent reaching: **a window owns its whole rectangle**. Right now it is
	desktop, because only the first client has a window and this is past its
	edge. When the second window opens it must stop being desktop, without any
	client having drawn there. When that window closes it must be desktop
	again.

	The pixel used to watch the opposite claim. A window covered only what its
	client drew, so this had to stay exactly as found. The boot chassis, showing
	through a window with no ground of its own.
	*/
	ground_x := fw + 8
	ground_y := sy - 4
	check(r, is_desk(s, ground_x, ground_y), "past the first window's edge the desktop is all there is")

	/*
	The second window's indicator lamp, at the middle of its jewel.

	A fixture, like the cascade above it. The draw server puts one lamp per
	window down the right edge, which is the one column of desktop two
	half-screen windows never cover. A client has no verb that would tell this
	test so.

	It is chrome out of `sys/libdraw` and colour out of `sys/libpal`, which is
	the table this side of the door reads through `fb`. So the check can name
	the colour rather than compare two pixels and hope.
	*/
	LAMP :: 12
	LAMP_GAP :: 6
	LAMP_INSET :: 20
	lamp_x := s.width - LAMP_INSET - LAMP + LAMP / 2
	lamp_y := LAMP_INSET + (LAMP + LAMP_GAP) + LAMP / 2
	lamp_dark := fb.get_raw(s, lamp_x, lamp_y)
	check(
		r,
		lamp_dark != fb.pack(s, fb.PHOSPHOR),
		"the second window's lamp is dark, because nothing holds that window",
	)
	/*
	And dark in its own colour rather than in grey.

	`kernel/splash.odin` states the rule and the reason. A bank of lamps with
	none of them on still has to read as several of the same kind of thing. It
	is the one part of the chassis idiom that is a judgement rather than an
	arithmetic, so it is the part worth a check.

	The channels come out through the surface's own shifts. The kernel draws on
	whatever mode the bootloader set, and this test may not assume one.
	*/
	dr := channel(s, lamp_dark, s.red_shift, s.red_size)
	dg := channel(s, lamp_dark, s.green_shift, s.green_size)
	db := channel(s, lamp_dark, s.blue_shift, s.blue_size)
	check(r, dg > dr && dg > db, "and dark in its own colour, which is what an unlit lamp is")

	/*
	And one pixel of the desktop's grid, beside one of its ground.

	The grid is decoration and the ground is arithmetic, and this is the
	difference. A control that flattens the desktop to one colour changes
	nothing a check could see until the two are read together. The column is a
	multiple of the step `desk_measure` found and the one beside it is not, on a
	row that is neither.
	*/
	grid_x := ((fw + 40) / desk.step) * desk.step
	check(
		r,
		fb.get_raw(s, grid_x, ground_y) != fb.get_raw(s, grid_x + 1, ground_y),
		"the desktop has a grid engraved in it, a step apart from its ground",
	)

	/*
	The second client opens the second window *by name*.

	The tree is a directory per window now. A session is a fid on a *named*
	window's `data`, rather than on whichever one the server had spare. That is
	what lets a `ctl` line be about something. `docs/DRAW.md` section 4 called this
	growth free on the wire, and it was. These are ordinary walks.
	*/
	second, oerr := vfs.open_path(vfs.boot_namespace, "/mnt/1/data", vfs.O_WRONLY)
	if !check(r, oerr == vfs.OK, "a second client opens the second window by name") {
		return
	}

	/*
	And two refusals, which used to be one.

	A window somebody holds is refused, which is the claim that makes a
	directory a session. And a window that does not exist is refused a step
	earlier, at the walk, which is the cap `MAX_WINDOWS` sets.
	*/
	third, terr := vfs.open_path(vfs.boot_namespace, "/mnt/0/data", vfs.O_WRONLY)
	check(r, terr != vfs.OK, "a window another session holds is refused to a third")
	if terr == vfs.OK {
		vfs.chan_close(third)
	}
	fourth, ferr := vfs.open_path(vfs.boot_namespace, "/mnt/2/data", vfs.O_WRONLY)
	check(r, ferr != vfs.OK, "and a window that does not exist has no name to walk to")
	if ferr == vfs.OK {
		vfs.chan_close(fourth)
	}

	check(
		r,
		!is_desk(s, ground_x, ground_y),
		"the second window covers ground no client has drawn on, because it owns its rectangle",
	)

	/*
	And the window that arrived took the front, which the bar under it says.

	**Focus is which window is in front**, and nothing else on this screen
	could mean anything else: there is no pointer and no keystroke to route.
	So it is a reading of the stacking order rather than a second thing to keep
	in step with it, and one colour on a title bar is the whole of what it
	looks like.

	This pixel is window zero's bar, and `verify_draw` read it as `COPPER` when
	that window was the only one on the screen. Nothing has touched window zero
	since. So this is the *transition*: a bar that is no longer in front wears
	`COPPER_DARK`, the same trim one step down the same table, which is the
	lamp's dark-in-its-own-colour rule applied to a surface.

	Window one begins half a window across, so it covers none of this.
	*/
	check(
		r,
		fb.get_raw(s, ox + 8, oy / 2) == fb.pack(s, fb.COPPER_DARK),
		"and the front with it, so the bar of the window it covered goes dark",
	)

	A :: u32(0x0011AA33)
	A2 :: u32(0x00119933)
	B :: u32(0x00AA1133)
	MARK :: u32(0x00205020)
	buf: [128]u8

	// -- Each client's coordinates are its own --------------------------------

	at := libdraw.put_fill(buf[:], 0, 0, 0, u32(y), u32(win_w), 1, A)
	at = libdraw.put_flush(buf[:], at)
	_, aerr := vfs.chan_write(first, 0, buf[:at])
	check(r, aerr == vfs.OK, "the first client fills its whole width from its own origin")
	check(
		r,
		fb.get_raw(s, ox, sy) == A,
		"which lands inside its window's frame, where its client area is and the screen's origin is not",
	)

	at = libdraw.put_fill(buf[:], 0, 0, 0, u32(y), 8, 1, B)
	at = libdraw.put_flush(buf[:], at)
	_, berr := vfs.chan_write(second, 0, buf[:at])
	check(r, berr == vfs.OK, "and the second fills at the same coordinates")
	check(
		r,
		fb.get_raw(s, second_ox, sy) == B,
		"half a window across and a border further in, which is where the second client area is",
	)
	check(
		r,
		fb.get_raw(s, lamp_x, lamp_y) == fb.pack(s, fb.PHOSPHOR),
		"and its lamp is lit, in the phosphor both sides of the door read from one table",
	)
	check(
		r,
		fb.get_raw(s, under_x, sy) == A,
		"and the pixel before that window begins is still the first client's",
	)

	// -- Where they overlap, the top window is what the glass has -------------

	/*
	The claim placement used to make, made by the compositor instead.

	Before this milestone two windows could not overlap. A draw went straight
	to the glass, so two clients on one pixel would have taken turns destroying
	each other. The store removed the reason, and the placement moved the
	windows on top of each other to put the new rule under a check. Slot order
	is stacking order, and the second window is the higher slot.
	*/
	at = libdraw.put_fill(buf[:], 0, 0, 0, u32(y), u32(win_w), 1, B)
	at = libdraw.put_flush(buf[:], at)
	_, werr := vfs.chan_write(second, 0, buf[:at])
	check(r, werr == vfs.OK, "the second client fills its whole width too")
	check(
		r,
		fb.get_raw(s, ox + win_w - 1, sy) == B,
		"and the glass where they overlap is the window on top",
	)
	check(
		r,
		fb.get_raw(s, under_x, sy) == A,
		"and the window underneath still has the part nothing covers",
	)

	/*
	And the covered client draws again, which is the check that watches the
	*order* rather than the arithmetic.

	A flush composites the damage out of every window, back to front, not out
	of the one that asked. A server that simply copied the flushing client's
	pixels onto the glass would pass every check above. It fails this one, by
	lifting a covered window over the one on top of it.
	*/
	at = libdraw.put_fill(buf[:], 0, 0, 0, u32(y), u32(win_w), 1, A2)
	at = libdraw.put_flush(buf[:], at)
	_, a2err := vfs.chan_write(first, 0, buf[:at])
	check(r, a2err == vfs.OK, "the covered client fills its width a second time")
	check(r, fb.get_raw(s, under_x, sy) == A2, "and its flush repaints what it owns")
	check(
		r,
		fb.get_raw(s, ox + win_w - 1, sy) == B,
		"without lifting one pixel of it over the window on top",
	)

	// -- The clip is still the window's ---------------------------------------

	/*
	Now the whole world, asked for by the client that may not have it.

	A rectangle wider than the screen, from the second session. It clips to
	that session's window, so its last column is its own and the column past
	it belongs to nobody.
	*/
	edge := second_ox + win_w
	beyond_before := fb.get_raw(s, edge, sy)
	at = libdraw.put_fill(buf[:], 0, 0, 0, u32(y), u32(s.width * 2), 1, B)
	at = libdraw.put_flush(buf[:], at)
	_, werr = vfs.chan_write(second, 0, buf[:at])
	check(r, werr == vfs.OK, "the second asks for a rectangle wider than the screen")
	check(r, fb.get_raw(s, edge - 1, sy) == B, "and gets its window, out to its last column")
	check(r, fb.get_raw(s, edge, sy) == beyond_before, "and not one pixel past it")

	/*
	And a blit, which is the only way to prove the *other* translation.

	A control that removed the origin from `run_blit` passed everything, and
	the reason was that every blit in this file came from window zero. There,
	translating by the origin is translating by nothing. This one comes from
	the session half a window across.
	*/
	pat: [8 * 4]u8
	for i in 0 ..< 8 {
		libdraw.put_u32(pat[:], i * 4, MARK)
	}
	at = libdraw.put_alloc(buf[:], 0, 1, 8, 1)
	at = libdraw.put_load(buf[:], at, 1, 0, 0, 8, 1, pat[:])
	at = libdraw.put_blit(buf[:], at, 0, 16, u32(y), 1, 0, 0, 8, 1)
	at = libdraw.put_flush(buf[:], at)
	_, blerr := vfs.chan_write(second, 0, buf[:at])
	check(r, blerr == vfs.OK, "the second client loads an image and blits it")
	check(r, fb.get_raw(s, second_ox + 16, sy) == MARK, "which lands inside its own window")
	check(r, fb.get_raw(s, ox + 16, sy) != MARK, "and not in the window beside it")

	/*
	And a line typed at the second window, left in its queue and never read.

	The slot is about to change hands, and what it must not carry across is
	checked below. Waiting for the line to land rather than typing and moving
	on: the delivery crosses a process, and a line still in flight when the
	window closes would arrive in whatever window the focus fell to and spoil
	a later check rather than this one.
	*/
	stale_cons, scerr := vfs.open_path(vfs.boot_namespace, "/mnt/1/cons", vfs.O_RDONLY)
	if check(r, scerr == vfs.OK, "the second window's keyboard opens") {
		for c in transmute([]u8)string("zz") {
			devfs.keyboard_sink(c)
		}
		devfs.keyboard_sink('\n')
		for _ in 0 ..< PATIENCE {
			if attr, e := vfs.chan_stat(stale_cons); e == vfs.OK && attr.size > 0 {
				break
			}
			sync.delay(1)
		}
		vfs.chan_close(stale_cons)
	}

	// -- The uncover, which is the milestone ----------------------------------

	/*
	The second session goes, and the first client is not told and does not
	draw. What comes back is what it put in its own memory, before it was
	ever covered.

	The pixel watched is one the second window was sitting on. A server
	without a store has nothing to put there, and the only honest thing it
	could do is ask the client to repaint. That request is the expose event
	`docs/DRAW.md` section 9 deferred, and this is the check that retires it.
	*/
	vfs.chan_close(second)
	check(
		r,
		fb.get_raw(s, ox + win_w - 1, sy) == A2,
		"a window that closes gives back the pixels it covered, out of the store below it",
	)
	check(
		r,
		fb.get_raw(s, second_ox, sy) == A2,
		"across the whole overlap, and the client under it drew nothing to earn that",
	)
	check(
		r,
		is_desk(s, ground_x, ground_y),
		"and where no window is left, the desktop is back",
	)
	check(r, fb.get_raw(s, lamp_x, lamp_y) == lamp_dark, "and its lamp goes out with its session")
	/*
	And the front goes to what is left, which is the one path where focus
	arrives at a window that did nothing to ask for it.

	`raise` is a client saying so and an open is a client arriving. This is
	neither: the window below is simply the one in front now, and it is not
	told. The bar is read at the same pixel as the two checks above it, so the
	three together are one window's bar lit, dark, and lit again.
	*/
	check(
		r,
		fb.get_raw(s, ox + 8, oy / 2) == fb.pack(s, fb.COPPER),
		"and the window under it comes to the front, which nothing had to ask for",
	)


	// The window comes back with the fid, so a client can open again.
	again, aerr2 := vfs.open_path(vfs.boot_namespace, "/mnt/1/data", vfs.O_WRONLY)
	if check(r, aerr2 == vfs.OK, "a clunk gives the window back") {
		/*
		And it comes back with a rectangle of its own, and nothing of the last
		session's in it.

		Two claims in one pixel, and the second is why the store is cleared at
		`Tlopen` again. A slot's memory outlives the session it was lent to,
		because nothing gives a run back. The last client's drawing is still
		sitting in the run, and every pixel of a window reaches the screen now.
		An uncleared slot would put the last client's work on the glass under
		this one's name.

		`fresh` is this window's own ground, read where no client ever drew.
		The pixel the covered client repaints has to become equal to it. Covered,
		because a window that drew nothing still owns its rectangle. And
		*ground* rather than the last session's blue, because the slot was
		cleared.
		*/
		fresh := fb.get_raw(s, ground_x, ground_y)
		check(r, !is_desk(s, ground_x, ground_y), "a window is there again, over the ground it uncovered")
		/*
		And what it covers that ground with is a *well*.

		A window is a raised plinth with a sunken screen in it, which is the
		chassis in one sentence, and the well's own face is what a client that
		has drawn nothing gets. A frame whose client area was left as the
		plinth it stands on covers exactly as much glass and reads as the wrong
		object, and nothing here could tell until this named the colour.
		*/
		check(
			r,
			fresh == fb.pack(s, fb.SLATE),
			"and the window's own ground is the well it is sunk into, not the plinth around it",
		)

		/*
		And with an empty keyboard, which is the pixels' rule one file along.

		A slot's key ring outlives the session it was lent to exactly the way
		its store does, and a line typed at the last client and never read is
		still sitting in it. A new session's first read would answer with what
		somebody else was typed. The store is cleared by the frame that paints
		over it, and the queue has to be cleared on purpose.
		*/
		fresh_cons, fcerr := vfs.open_path(vfs.boot_namespace, "/mnt/1/cons", vfs.O_RDONLY)
		if check(r, fcerr == vfs.OK, "and its keyboard opens for the new session") {
			attr, cerr2 := vfs.chan_stat(fresh_cons)
			check(
				r,
				cerr2 == vfs.OK && attr.size == 0,
				"with nothing in it, because a slot does not carry the last client's keystrokes either",
			)
			vfs.chan_close(fresh_cons)
		}

		A3 :: u32(0x00117733)
		at = libdraw.put_fill(buf[:], 0, 0, 0, u32(y), u32(win_w), 1, A3)
		at = libdraw.put_flush(buf[:], at)
		_, a3err := vfs.chan_write(first, 0, buf[:at])
		check(r, a3err == vfs.OK, "and the client below repaints across where the new window sits")
		check(
			r,
			fb.get_raw(s, under_x, sy) == A3,
			"whose pixels stand where nothing covers them",
		)
		check(
			r,
			fb.get_raw(s, ox + win_w - 1, sy) == fresh,
			"and are covered where they meet a window whose session drew nothing at all",
		)

		verify_ctl(r, s, win_w, win_h, ox, oy, sy, fw, A3, first_ctl, server)
		vfs.chan_close(again)
	}

}
