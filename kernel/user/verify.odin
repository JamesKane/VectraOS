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

import "kernel:arch"
import "kernel:devfs"
import "kernel:drivers/fb"
import "kernel:drivers/mouse"
import "kernel:drivers/virtio"
import "kernel:ether"
import "kernel:env"
import "kernel:mem"
import "kernel:mnt"
import "kernel:pipe"
import "kernel:sched"
import "kernel:smmu"
import "kernel:srv"
import "kernel:sync"
import "kernel:vfs"
import "vsys:abi"
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

// fdt_level is true when the descriptor tables hold what they held at `arg`.
@(private = "file")
fdt_level :: proc "contextless" (arg: rawptr) -> bool {
	return fdt_stats() == (^int)(arg)^
}

// fault_bits is what the CPU said about a fault, in the neutral words
// `arch.fault_bits` decodes each architecture's syndrome into.
@(private = "file")
fault_bits :: proc(p: ^Process) -> arch.Fault_Bits {
	return arch.fault_bits(p.exit.kind, p.exit.vector, p.exit.error_code, p.exit.from_user)
}

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
	resident:      int, // Processes alive before the run: the servers the boot started
	echo_ticks:    int, // How long the terminal took to draw a typed line
	answered:      u64, // 9P requests a process served over a wire
	pinned:        int, // Heap objects the wires still pin -- zero since the counted release
	leaked:        int, // Heap objects the run did not give back
	shell_ticks:   int, // How long the shell took over its script
	tools_ticks:   int, // And over the tool script
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
	p := start_blob(r, name, code, what, arg)
	if p == nil {
		return nil
	}

	// The program's name in the line, because ten tests share this helper
	// and a timeout that says only "it" costs a boot to place.
	sink := libodin.sink_from(helper_line[:])
	libodin.put_str(&sink, "and ")
	libodin.put_str(&sink, name)
	libodin.put_str(&sink, " comes back")
	if !check(r, wait(p, PATIENCE), libodin.str(&sink)) {
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
	check(r, p.exit.sp > STACK_VA && p.exit.sp <= STACK_TOP, "on the stack it was given, in its own space")

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
start_blob loads one blob and counts it, under the site's own check name.

Every program start made the same three moves: load, check the load, count
the program. The helpers keep the moves in one place. Each answers nil when
the load failed. The check said so first, and the site returns.
*/
@(private = "file")
start_blob :: proc(r: ^Result, name: string, code: []u8, what: string, arg: u64 = 0, arg2: u64 = 0) -> ^Process {
	p, err := load(name, code, arg, arg2)
	if !check(r, err == .None && p != nil, what) {
		return nil
	}
	r.programs += 1
	return p
}

// hold_blob is `start_blob` over `load_held`: the process is built and not
// yet launched, so the site can stage its data page first.
@(private = "file")
hold_blob :: proc(r: ^Result, name: string, code: []u8, what: string) -> ^Process {
	p, err := load_held(name, code)
	if !check(r, err == .None && p != nil, what) {
		return nil
	}
	r.programs += 1
	return p
}

// start_path is `start_blob` for a program on a file. The loader copies
// `argv` into the new stack, so the record goes back here, whatever happened.
@(private = "file")
start_path :: proc(r: ^Result, path: string, what: string, argv: ^Argv = nil, flags: u64 = SPAWN_NS_COPY) -> ^Process {
	p, serr := spawn_path(nil, path, flags, argv)
	if argv != nil {
		free(argv)
	}
	if !check(r, serr == vfs.OK && p != nil, what) {
		return nil
	}
	r.programs += 1
	return p
}

// What a poll of a program's data page waits for: one cell, one value.
@(private = "file")
Cell_Wait :: struct {
	p:     ^Process,
	index: int,
	want:  u64,
}

@(private = "file")
cell_is :: proc "contextless" (arg: rawptr) -> bool {
	w := (^Cell_Wait)(arg)
	return cell(w.p, w.index) == w.want
}

@(private = "file")
cell_moved :: proc "contextless" (arg: rawptr) -> bool {
	w := (^Cell_Wait)(arg)
	return cell(w.p, w.index) != 0
}

// await_cell waits for a program to write `want` into one cell of its data
// page. The write happens in ring 3, so it is a poll rather than a read.
@(private = "file")
await_cell :: proc(p: ^Process, index: int, want: u64, patience: int) -> bool {
	w := Cell_Wait{p, index, want}
	return sync.await(cell_is, &w, patience)
}

// await_cell_moves waits for a cell to leave zero: a counter that moved, or
// a mark that landed.
@(private = "file")
await_cell_moves :: proc(p: ^Process, index: int, patience: int) -> bool {
	w := Cell_Wait{p, index, 0}
	return sync.await(cell_moved, &w, patience)
}

// catcher_armed is `catcher` with its handler registered and its loop moving,
// before any note reaches it.
@(private = "file")
catcher_armed :: proc "contextless" (arg: rawptr) -> bool {
	p := (^Process)(arg)
	return cell(p, CATCHER_NOTIFIED) == 0 && cell(p, CATCHER_ROUNDS) > 0
}

// launch_or_finish launches a held program, and takes it down when the
// launch was refused, so the caller only returns. Both checks are the
// site's own.
@(private = "file")
launch_or_finish :: proc(r: ^Result, p: ^Process, what_launch: string, what_down: string) -> bool {
	if !check(r, launch(p), what_launch) {
		finish(r, p, what_down)
		return false
	}
	return true
}

// hold_frames keeps a program's three frames for the sweep after it is
// gone, and checks all three are held while it exists.
@(private = "file")
hold_frames :: proc(r: ^Result, p: ^Process, held: ^[3]uintptr, what: string) {
	held^ = {p.text, p.data, p.stack}
	check(
		r,
		!mem.frame_is_free(held[0]) && !mem.frame_is_free(held[1]) && !mem.frame_is_free(held[2]),
		what,
	)
}

// type_text feeds a line to the keyboard, one byte at a time, the way a
// key arrives.
@(private = "file")
type_text :: proc(text: string) {
	for i in 0 ..< len(text) {
		devfs.keyboard_sink(text[i])
	}
}

// mnt_file names one window's file under the server's mount: `/mnt/<i><name>`.
@(private = "file")
// How many windows the draw server holds, `servers/intuition`'s
// `MAX_WINDOWS`. A scan for a window walks them all. After the menu checks,
// a desktop holds slots past sixteen.
DRAW_SLOTS :: 32

mnt_file :: proc "contextless" (buf: []u8, i: int, name: string, base := "/mnt") -> string {
	n := copy(buf, base)
	buf[n] = '/'
	n += 1
	// Two digits past nine: a desktop with menus and panels up is past ten.
	if i >= 10 {
		buf[n] = u8('0' + i / 10)
		n += 1
	}
	buf[n] = u8('0' + i % 10)
	n += 1
	n += copy(buf[n:], name)
	return string(buf[:n])
}

// report_numbers pulls the numbers out of a window file's report, one per
// slot of `into`, skipping whatever stands between them. The freestanding
// program cannot be trusted to parse. The read itself is proven here.
@(private = "file")
report_numbers :: proc "contextless" (line: []u8, into: []$T) {
	si := 0
	for k in 0 ..< len(into) {
		for si < len(line) && (line[si] < '0' || line[si] > '9') {si += 1}
		for si < len(line) && line[si] >= '0' && line[si] <= '9' {into[k] = into[k] * 10 + T(line[si] - '0'); si += 1}
	}
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
	resident_live = stats().live
	settle()
	before_heap := mem.live_objects(mem.heap_stats())
	r.resident = stats().live
	before_tables := mem.space_stats()
	before_doubles := mem.pmm_stats().double_frees
	before_traps := arch.user_trap_count()
	before_segs := segment_stats()
	segment_pages(seg_pages_before[:])
	// The processes alive before the run: the boot's servers, whose heaps may
	// grow as they serve. Their growth is not the run's to give back.
	{
		guard := sync.acquire(&table_lock)
		for j in 0 ..< MAX_PROCESSES {
			resident_pids[j] = processes[j].live ? processes[j].pid : 0
		}
		sync.release(&table_lock, guard)
	}

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
	check(&r, arch.syscall_masks_interrupts(), "and clears IF on entry, so no interrupt lands before the kernel stack does")
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
			p.exit.present && fault_bits(p) >= {.Write, .User},
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
	hung_up := sync.await(fdt_level, &fdt_before, PATIENCE)
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
		bits := fault_bits(p)
		check(
			&r,
			.Write not_in bits && .User in bits,
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
			p.exit.present && .Write in fault_bits(p),
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
		check(&r, p.exit.kind == arch.PRIVILEGED_FAULT, "and is refused the way this architecture refuses one")
		check(&r, fault_bits(p) == {}, "with nothing to decode, because the fault named no page and no selector")
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
			.Fetch in fault_bits(p),
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

	/*
	And a note posted to a group, which is the fan-out half of the note.
	*/
	verify_notepg(&r)

	// -- And a process that continues from the call site ----------------------

	verify_rfork(&r)
	verify_abi(&r)
	verify_c(&r)
	verify_threads(&r)
	verify_mui(&r)
	verify_mothra(&r)
	verify_plumber(&r)
	verify_feedfs(&r)
	verify_modelfs(&r)
	verify_ghost(&r)
	verify_fedifs(&r)
	verify_atfs(&r)
	verify_matrixfs(&r)
	verify_netfs(&r)
	verify_cryptotest(&r)
	verify_pgptest(&r)
	verify_olmtest(&r)
	verify_fonttest(&r)
	verify_debugtest(&r)
	verify_users(&r)
	verify_debug(&r)
	verify_factotum(&r)
	verify_netserver(&r)
	verify_rc(&r)
	verify_cputype(&r)
	verify_nstest(&r)
	verify_roles(&r)
	verify_root(&r)
	verify_fdtest(&r)
	verify_tools(&r)
	verify_dbg(&r)

	// -- And a process that replaces itself -----------------------------------

	verify_exec(&r, column)
	verify_shared_class(&r)

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

	// -- The toast-stacking reproduction: a popup over windows at the corner --
	verify_popup_stack(&r)

	// -- And the memory the draw server draws through ------------------------

	verify_mapping(&r)

	// -- And memory no file serves, which a window's pixels will be ----------

	verify_anon(&r)

	// -- And the first app, a client of that server ---------------------------

	verify_terminal(&r, column)
	verify_chords(&r)
	verify_muiwin(&r)
	verify_workbench(&r)
	// The platform layer, from both languages over one library: the Odin
	// client, then the same program in C linking the same Odin `sys/libapp`,
	// then a game -- started and closed the same way, its ground its own.
	verify_app(&r, "/bin/apptest", 0x0022_4466, true, true)
	verify_app(&r, "/bin/capp", 0x0022_4466, true, true)
	verify_app(&r, "/bin/rebound", 0x0010_1830, false, false)
	// A device's register window, attached through the tree's `mmio` file.
	verify_tree_mmio(&r)
	// A device interrupt, waited on through the tree's `irq` file.
	verify_tree_irq(&r)
	verify_tree_dma(&r)
	verify_blkfs(&r)
	// A run placed at an address the caller named, which a firmware binary asks.
	verify_fixedseg(&r)
	verify_debugger(&r)

	// -- And a typed ^C, which reaches the program reading the console -------

	verify_interrupt(&r)

	// -- What is left ---------------------------------------------------------

	r.traps = arch.user_trap_count() - before_traps
	check(&r, r.traps > 0, "the machine came back out of ring 3")

	s := stats()
	r.calls = s.calls
	r.spawned = s.spawned
	// A program left standing is named, with the pids it hangs on, so this
	// check says which chain leaked rather than only that one did. The
	// format is `describe_live`'s: name#pid<parent, then D X C flags and T
	// with the thread's state. See `describe_live`.
	if s.live != r.resident {
		sink := detail_sink()
		libodin.put_str(&sink, "and it left these standing (live ")
		libodin.put_uint(&sink, u64(s.live))
		libodin.put_str(&sink, " resident ")
		libodin.put_uint(&sink, u64(r.resident))
		libodin.put_str(&sink, "):")
		describe_live(&sink)
		fail_detail(&r, &sink)
	}
	check(&r, s.live == r.resident, "every program was taken down")
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
	// A segment that grew is named, since a total alone costs a boot to
	// place. One a resident server holds -- fatfs caching a directory the
	// run read first, say -- grew by serving, and is discounted.
	seg_pages_after: [MAX_SEGMENTS]int
	segment_pages(seg_pages_after[:])
	sink := libodin.sink_from(seg_diag[:])
	libodin.put_str(&sink, "and owns no frame it did before, save what a resident grew by")
	resident_growth := 0
	for i in 0 ..< MAX_SEGMENTS {
		if seg_pages_before[i] != seg_pages_after[i] {
			owner := segment_owner_pid(i)
			resident := false
			for j in 0 ..< MAX_PROCESSES {
				if owner != 0 && resident_pids[j] == owner {
					resident = true
					break
				}
			}
			if resident {
				resident_growth += seg_pages_after[i] - seg_pages_before[i]
			}
			libodin.put_str(&sink, " -- slot ")
			libodin.put_int(&sink, i64(i))
			libodin.put_str(&sink, " ")
			libodin.put_str(&sink, segment_kind_name(i))
			libodin.put_str(&sink, " ")
			libodin.put_int(&sink, i64(seg_pages_before[i]))
			libodin.put_str(&sink, " to ")
			libodin.put_int(&sink, i64(seg_pages_after[i]))
			if resident {
				libodin.put_str(&sink, " (pid ")
				libodin.put_uint(&sink, owner)
				libodin.put_str(&sink, ", resident)")
			}
		}
	}
	check(&r, after_segs.frames - before_segs.frames == resident_growth, libodin.str(&sink))

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
	p := start_blob(r, "spin", program_spin(), "a program is loaded into a space of its own")
	if p == nil {
		return
	}

	// Wait for the mark rather than assume it. The program writes nothing until
	// something dispatches it, and that is a scheduler decision.
	started := await_cell(p, CELL_MARK, MARK_SPIN, PATIENCE)
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

	p := hold_blob(r, "hello", program_hello(), "a program is loaded that asks rather than faults")
	if p == nil {
		return
	}
	check(r, set_bytes(p, MESSAGE_OFFSET, bytes_of(MESSAGE)), "with a line in its data page")

	before := column()
	// Staged, and only now a thread. A launch before the staging is a race
	// the program sometimes wins, and a flake found it winning.
	check(r, launch(p, u64(len(MESSAGE))), "and it launches")
	came_back := comes_back(r, p, "and it comes back")
	if came_back {
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
		check(r, p.exit.sp > STACK_VA && p.exit.sp <= STACK_TOP, "on the stack it was given")
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
	p = start_blob(r, "probe", program_probe(), "a second program makes six calls", witness)
	if p == nil {
		return
	}

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
	p := start_blob(r, "shadow", program_shadow(), "a third program is given an address it may not read")
	if p == nil {
		return
	}

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

	hold_frames(r, p, held, "a program holds three frames while it exists")

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

	p := hold_blob(r, "namer", program_namer(), "a process is built with a namespace of its own")
	if p == nil {
		return
	}
	check(r, p.ns != nil, "which is a copy rather than the kernel's")
	check(r, fd_count(p) == 3, "and three descriptors already open on the console")
	check(r, set_bytes(p, SLOT_A, bytes_of(PATH_CONS)), "with a path in its page")
	check(r, set_bytes(p, SLOT_C, bytes_of(NAMED)), "and a line to write")
	check(r, set_bytes(p, SLOT_D, bytes_of(PATH_MISSING)), "and a path that is not there")

	before := column()
	check(r, launch(p, u64(len(PATH_CONS)), u64(len(NAMED))), "and it launches, staged")
	if comes_back(r, p, "and it comes back") {
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

	p = hold_blob(r, "reader", program_reader(), "a second process opens a file to read")
	if p == nil {
		return
	}
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

	p = hold_blob(r, "binder", program_binder(), "a third process rearranges its own namespace")
	if p == nil {
		return
	}
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

	hold_frames(r, p, held, "a process holds three frames while it exists")
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

	p := hold_blob(r, "painter", program_painter(), "a process is built to reach it")
	if p == nil {
		return
	}
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

	p := hold_blob(r, "scanread", program_reader(), "a process is built to read them")
	if p == nil {
		vfs.chan_close(held)
		return
	}
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

	p := hold_blob(r, "bulkio", program_bulkio(), "a process is built to move a large buffer")
	if p == nil {
		return
	}

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
	p := start_path(r, "/bin/child", "a process is built from a file rather than from a blob")
	if p != nil {
		if comes_back(r, p, "and it comes back") {
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

	_, serr := spawn_path(nil, "/bin/no-such", 0)
	check(r, serr == vectra9.ENOENT, "a path with nothing at it is refused by name")

	_, serr = spawn_path(nil, "/dev/zero", 0)
	check(
		r,
		serr == vectra9.ENOEXEC,
		"and a file that is not a program is refused by its header, before a byte of it runs",
	)

	// -- A clean namespace is a world with no names --------------------------

	p = start_path(r, "/bin/child", "a child with a clean namespace still loads, through its parent's", flags = SPAWN_NS_CLEAN)
	if p != nil {
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
	p := start_path(r, "/bin/parent", "a process is started that will start more")
	if p == nil {
		return
	}

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
		check(r, stats().live == r.resident + 1, "and neither outlived being collected -- the parent waited for both")
	}
	cons_finish()

	hold_frames(r, p, held, "a spawned process holds three frames while it exists")
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
	// `/bin` is a union of the disk and `#b` with no member flagged for
	// creation, which is EPERM; a lone read-only tree would say EROFS.
	check(r, cerr == vectra9.EPERM || cerr == vectra9.EROFS, "a read-only tree refuses a create")

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
	p := start_path(r, "/bin/poster", "a process is started that will publish a service")
	if p == nil {
		return
	}

	if comes_back(r, p, "and it comes back") {
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

	settle()
	pin_before := mem.live_objects(mem.heap_stats())

	p := start_path(r, "/bin/niner", "a process is started that will answer 9P")
	if p == nil {
		return
	}

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
		check(r, c.server.poster == p.pid, "and the server built from the posting names the program's pid as its poster")
		check(r, holds_server_of(p.pid, p.pid), "which holds its own files, the self case")
		check(r, !holds_server_of(p.pid + 1000, p.pid), "and a pid that is gone holds none of them")
		check(r, !holds_server_of(p.pid, 0), "and no process holds a file of poster zero, the kernel's")
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

	check(r, libodin.get_u64le(header[:]) == IMAGE2_MAGIC, "and its header says VECTRA02")
	return uintptr(libodin.get_u64le(header[8:])), true
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
	libodin.put_u64le(out[at:], vaddr)
	libodin.put_u64le(out[at + 8:], filesz)
	libodin.put_u64le(out[at + 16:], memsz)
	libodin.put_u64le(out[at + 24:], flags)
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

	settle()
	pin_before := mem.live_objects(mem.heap_stats())

	// -- The image is a file, and says which format it is ---------------------

	image_entry, image_ok := image_header(r, "/bin/ramfs", "/bin serves the compiled image")
	if !image_ok {
		return
	}

	// -- The loader builds a bigger world than a blob's -----------------------

	p := start_path(r, "/bin/ramfs", "the segment loader starts it")
	if p == nil {
		return
	}
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
	// The top page, which is the one the loader maps; the rest of the
	// stack is holes a fault fills as the program grows down into them.
	stack_flags, stack_ok := mem.permissions(p.space, STACK_TOP - uintptr(arch.PAGE_SIZE))
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
		same := rerr == vfs.OK && n == LONG && string(back[:LONG]) == string(long[:])
		check(r, same, "and comes back whole, through the library's loops")

		// -- text: the listing is the program running -------------------------

		if dc, derr := vfs.resolve(vfs.boot_namespace, "/mnt"); derr == vfs.OK {
			names: [64]u8
			// Opened before it is read, which 9P requires and every server
			// enforces now. A resolve alone leaves the fid unopened.
			_ = vfs.chan_open(dc, vfs.O_RDONLY | vfs.O_DIRECTORY)
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

	p := start_blob(r, "spin-noted", program_spin(), "a program is started that loops for ever")
	if p == nil {
		return
	}

	// Mid loop, provably: the counter has to move before the note is
	// posted. Posting on the heels of `load` raced the first dispatch.
	// A tick that caught the thread before its first instruction read a
	// counter of zero. The flake arrived the day the boot's timing
	// shifted. The handshake is `verify_spin`'s, in one direction.
	moving := await_cell_moves(p, CELL_COUNTER, PATIENCE)
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

	p = start_path(r, "/bin/ramfs", "a server is started to park in its pipe")
	if p == nil {
		return
	}

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

	p = start_path(r, "/bin/noter", "a process is started that will end another")
	if p == nil {
		return
	}

	if comes_back(r, p, "and it comes back") {
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
			cell(p, NOTER_STRANGER) == refused(vectra9.ESRCH),
			"while a pid that is nobody answers ESRCH -- notes go by owner now, not parenthood",
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
	p := hold_blob(r, "catcher", program_catcher(), "a process is built that will catch a note")
	if p == nil {
		return
	}
	if !launch_or_finish(r, p, "and it launches", "and is taken down") {
		return
	}

	// Registered and spinning before anything is posted. The counter is the
	// proof of ring 3, the same proof `spin` gives.
	registered := await_cell_moves(p, CATCHER_ROUNDS, PATIENCE)
	check(r, registered, "it registers a handler and spins")
	check(
		r,
		cell(p, CATCHER_EARLY) == refused(vectra9.EINVAL),
		"a noted with no delivery in flight was refused first",
	)
	check(r, cell(p, CATCHER_NOTIFIED) == 0, "and notify answered zero")

	check(r, post_note(p, CATCHER_NOTE), "a note is posted to it, mid spin")
	handled := await_cell_moves(p, CATCHER_HANDLED, PATIENCE)
	if !check(r, handled, "the tick hands the handler the frame it interrupted") {
		finish(r, p, "and the catcher is taken down")
		return
	}
	check(r, !exit_done(p), "and the process is still alive")

	// Seven characters and the NUL are one cell, byte for byte the kernel's.
	note_cell: [8]u8
	copy(note_cell[:], CATCHER_NOTE)
	want := libodin.get_u64le(note_cell[:])
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

	p = hold_blob(r, "dfltnote", program_dfltnote(), "a process is built that will decline one")
	if p == nil {
		return
	}
	if !launch_or_finish(r, p, "and it launches", "and is taken down") {
		return
	}

	moving := await_cell_moves(p, DFLTNOTE_ROUNDS, PATIENCE)
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
	p := hold_blob(r, "catcher", program_catcher(), "a process is built that catches every note")
	if p == nil {
		return
	}
	if !launch_or_finish(r, p, "and it launches", "and is taken down") {
		return
	}

	// Spinning, with its handler registered, before the kernel acts. A stop
	// before the handler exists would prove nothing about handlers.
	armed := sync.await(catcher_armed, p, PATIENCE)
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
	p = hold_blob(r, "catcher", program_catcher(), "a second catcher is built")
	if p == nil {
		return
	}
	if !launch_or_finish(r, p, "and it launches", "and is taken down") {
		return
	}
	armed = sync.await(catcher_armed, p, PATIENCE)
	check(r, armed && post_note(p, CATCHER_NOTE), "it spins, and an ordinary note is posted to it")
	sleeping := await_cell(p, CATCHER_HANDLED, 1, PATIENCE)
	check(r, sleeping, "which its handler catches, and it moves on to loop on sleep")
	check(r, end(p, PATIENCE), "the kernel ends it there, at the door, inside the patience")
	check(r, p.exit.noted && note(p) == "sys: killed", "noted, with the same word")
	check(r, cell(p, CATCHER_HANDLED) == 1, "and its handler ran once, for the note, and not for the word")
	check(r, stop(p, PATIENCE), "and it is collected")
	check(r, stats().live == before, "leaving the machine as it was")
}

/*
verify_notepg is the note group doing something, which `RFNOTEG` recorded for
four milestones and nothing acted on.

`grouper` forks one child into its own group and one, with `RFNOTEG`, into a
group of one, both counting in cells the parent shares. It notes its own
group and expects exactly one process to hear it. The first child ends,
noted, and the second's counter keeps moving across a sleep. Then a note by
pid ends the second, which is the only way into a group of one from
outside. Every claim is a cell the program filled in, and the kernel reads
them after it exits.
*/
@(private = "file")
verify_notepg :: proc(r: ^Result) {
	before := stats().live
	p := start_blob(r, "grouper", program_grouper(), "a program forks two children into two note groups")
	if p == nil {
		return
	}
	r.spawned += 2
	if !check(r, wait(p, PATIENCE), "and comes back") {
		finish(r, p, "and is taken down")
		return
	}
	check(r, cell(p, CELL_MARK) == MARK_GROUPER, "having reached its first instruction")
	check(r, i64(cell(p, GROUPER_A)) > 0 && i64(cell(p, GROUPER_B)) > 0, "both children were made")
	check(r, i64(cell(p, GROUPER_POSTED)) == 1, "a note to its own group reached exactly one process: the child in it, and not the poster")
	check(
		r,
		cell(p, GROUPER_A_WAIT) == refused(vectra9.EINTR),
		"and that child ended noted, which is what its parent's wait says",
	)
	check(r, i64(cell(p, GROUPER_B_MOVED)) > 0, "while the child in a group of its own kept counting")
	check(r, i64(cell(p, GROUPER_B_NOTE)) == 0, "until a note by pid reached it")
	check(r, cell(p, GROUPER_B_WAIT) == refused(vectra9.EINTR), "and it ended noted too")
	check(r, p.exit.deliberate && p.exit.status == 0, "and the parent, never noted, left on its own terms")
	finish(r, p, "and is taken down")
	check(r, stats().live == before, "with both children collected by its waits")
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
	p := hold_blob(r, "execer", program_execer(), "a process is built that will replace itself")
	if p == nil {
		return
	}
	pid_before := p.pid

	before := column()
	if !launch_or_finish(r, p, "and it launches", "and is taken down") {
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
verify_shared_class is Plan 9's third answer to a fork, `SG_SHARED`.

`.Anon` is shared under `RFMEM` or copied, and that was the only choice. The
shared class is shared whatever the flags say, and an exec keeps it. The
program takes one page of each, seeds both, and forks with `RFPROC` alone.
The child writes into both and exits. The parent then reads both, keeps what
it read in the shared page, and execs `/bin/child`. The kernel reads the
shared page afterwards through the segment the exec carried over. The
child's witness in it says a fork without `RFMEM` shared the page. The
private seed beside it says the same fork copied the other. And the segment
being there at all, under a program that never asked for it, says exec kept
it.
*/
@(private = "file")
verify_shared_class :: proc(r: ^Result) {
	segs0 := segment_stats()

	p := start_blob(r, "sharedseg", program_sharedseg(), "a program that asks for the shared class starts")
	if p == nil {
		return
	}
	if check(r, wait(p, PATIENCE), "and comes back, having forked and become another program") {
		check(r, cell(p, CELL_MARK) == MARK_CHILD, "the mark is the program it became")
		check(r, p.exit.deliberate && p.exit.status == CHILD_STATUS, "which exited with its own status")

		shared: ^Segment
		anon := 0
		for i in 0 ..< p.seg_count {
			if p.segs[i] != nil && p.segs[i].kind == .Shared {
				shared = p.segs[i]
			}
			if p.segs[i] != nil && p.segs[i].kind == .Anon {
				anon += 1
			}
		}
		if check(r, shared != nil, "the shared page crossed the exec with the process") {
			words := cast([^]u64)mem.phys_to_virt(segment_frame(shared, 0))
			check(
				r,
				words[SHAREDSEG_CHILD_WROTE] == SHAREDSEG_WITNESS,
				"and holds the witness a child forked without RFMEM wrote into it",
			)
			check(
				r,
				words[SHAREDSEG_SAW_SHARED] == SHAREDSEG_WITNESS,
				"which the parent read back through the same page",
			)
			check(
				r,
				words[SHAREDSEG_SAW_PRIVATE] == SHAREDSEG_PRIVATE_SEED,
				"while its private page kept the seed, because that fork copied it",
			)
			check(r, shared.refs == 1, "and the exec left the process its only holder")
		}
		check(r, anon == 0, "and the private page did not cross the exec")
		left := sweep(p)
		check(r, left.stray == 0 && left.borrowed == 0, "and every page the new image maps is one its segments hold")
	}
	cons_finish()
	finish(r, p, "and the process is taken down")
	check(r, segment_stats().live == segs0.live, "and the shared page went back with it")
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
	p := hold_blob(r, "nowaiter", program_nowaiter(), "a process is built that forks a detached child")
	if p == nil {
		return
	}
	if !launch_or_finish(r, p, "and it launches", "and is taken down") {
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
	ran := await_cell(child, NOWAITER_CHILD_RAN, 1, PATIENCE)
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
	groups0 := env.live()

	// -- Two processes return from one call, and a copy divides them ----------

	p := start_blob(r, "forker", program_forker(), "a program that forks starts")
	if p == nil {
		return
	}
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

	p = start_blob(r, "memfork", program_memfork(), "a program that shares memory starts")
	if p == nil {
		return
	}
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
	// Its own once written: under copy on write a stack page the child has
	// not touched is the parent's frame with two holders, and a page it has
	// is a frame of its own.
	check(
		r,
		child.segs[2].frames[0] != p.segs[2].frames[0] || mem.frame_holders(child.segs[2].frames[0]) > 1,
		"whose frames are the child's own, or shared until it writes them",
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
	saw := await_cell(child, MEMFORK_WITNESS, MEMFORK_WITNESS_VALUE, PATIENCE)
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

	// -- A shared run grows and shrinks in every holder -----------------------

	/*
	`RFMEM` shares the frames a run has at the fork. What it shares after is
	the question. A grow in one process used to be a tail the other never
	had, and a shrink was refused while the other lived. Both reach every
	holder now.

	The parent grows, writes a witness into the new page, and the
	child reads it through its own tables. The parent then shrinks, and the
	child's next touch of that page is a fault, on whichever core the child
	is. That is the shootdown doing its job for a second process, which is
	what a second thread is here.
	*/
	p = start_blob(r, "sharer", program_sharer(), "a program that shares a run and resizes it starts")
	if p == nil {
		return
	}
	if !check(r, wait(p, PATIENCE), "the parent grows, waits for the child to see, shrinks, and leaves") {
		return
	}
	check(r, p.exit.deliberate && p.exit.status == 0, "with zero, every call it made answered")
	check(
		r,
		cell(p, SHARER_SEEN) == SHARER_WITNESS,
		"the child read the witness through the page the parent grew",
	)
	sharer := find_child(p.pid, cell(p, SHARER_PID))
	if check(r, sharer != nil, "the child is still in the table") {
		base := uintptr(cell(p, SHARER_BASE))
		check(r, wait(sharer, PATIENCE), "and it ends")
		check(
			r,
			!sharer.exit.deliberate && sharer.exit.kind == .Page_Fault &&
			sharer.exit.address >= base + uintptr(arch.PAGE_SIZE) &&
			sharer.exit.address < base + 2 * uintptr(arch.PAGE_SIZE),
			"by a page fault on the page the parent shrank away, in the child's own tables",
		)
		check(r, cell(p, SHARER_SURVIVED) == 0, "and it never read that page after the shrink")
		left := sweep(sharer)
		check(
			r,
			left.stray == 0 && left.borrowed == 0,
			"and every page the child still maps is one the run still holds",
		)
		check(r, destroy(sharer), "the child is collected")
	}
	finish(r, p, "and the sharer's parent is taken down")

	// -- A shared descriptor group spends a close once ------------------------

	p = start_blob(r, "fdforker", program_fdforker(), "a program forks sharing its descriptors", RFPROC)
	if p == nil {
		return
	}
	if check(r, wait(p, PATIENCE), "and comes back") {
		check(r, cell(p, FDFORKER_WAITED) == 0, "the child closed descriptor 1 and left")
		check(
			r,
			cell(p, FDFORKER_CLOSED) == refused(vectra9.EBADF),
			"and the parent's own close finds it already spent -- one table",
		)
	}
	finish(r, p, "and the sharer is taken down")

	p = start_blob(r, "fdforker", program_fdforker(), "the same program forks with RFFDG", RFPROC | RFFDG)
	if p == nil {
		return
	}
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

	p = start_blob(r, "refuser", program_refuser(), "a program holds the flags to their refusals")
	if p == nil {
		return
	}
	if check(r, wait(p, PATIENCE), "and comes back") {
		check(r, cell(p, REFUSER_ENVG) == 0, "an environment group of its own is granted in place")
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
		check(r, cell(p, REFUSER_NOTHING) == 0, "while no flags at all asks for nothing and gets it")
		check(r, cell(p, REFUSER_NOTEG) == 0, "and a fresh note group is granted in place")
		check(r, cell(p, REFUSER_NOMNT) == 0, "the mount lock on a namespace of its own is granted in place")
		check(r, cell(p, REFUSER_BIND) == refused(vectra9.EPERM), "and after it a bind is refused")
		check(r, cell(p, REFUSER_UNMOUNT) == refused(vectra9.EPERM), "and an unmount")
		check(r, cell(p, REFUSER_DEVICE) == refused(vectra9.EPERM), "and a #name, the attach by another road")
		check(r, cell(p, REFUSER_OPEN) == 0, "while a name the table already had still opens")
	}
	finish(r, p, "and the refuser is taken down")

	check(r, segment_stats().live == segs0.live, "every fork's segments came back")
	check(r, fdt_stats() == tables0, "and every descriptor group")
	check(r, env.live() == groups0, "and every environment group")
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

/*
settle is what every opening reading of the heap waits for: the reaper idle
with nothing due, this core's dead reaped, and every other core's dead freed.

Two collectors run behind this suite's back. The reaper thread takes a dead
process's descriptors the moment it ends and closes them on its own stack,
and the last close into a dead server's mount releases that server's wire.
Each core's idle thread frees the threads that died on it. A reading taken
while either is part way through counts objects the closing reading will not,
and the bracket goes negative -- `leaked -1` on four cores, and minus
fifty-three the boot the reaper was still closing `authtest`'s descriptors
when the network test opened its bracket. `docs/TESTING.md` has both.
*/
@(private = "file")
settle :: proc() {
	// Every program a test started is gone, and so is every process one of
	// them made. A server on the thread library ends by noting the procs it
	// made and waiting for its own; a proc one of those made is detached,
	// and it may still be parked in a bounded read when the test's `finish`
	// returns. It dies a moment later, and the last holder of the server's
	// namespace copy takes fifty-odd objects with it -- inside the next
	// bracket, once in twenty boots, after the reaper wait alone was in.
	_ = sync.await(live_is_resident, nil, PATIENCE)
	_ = sync.await(settled, nil, PATIENCE)
	sched.reap()
	_ = sync.await(sched.all_reaped, nil, PATIENCE)
}

// The processes the machine holds when the suite begins, the servers boot
// left running. Every opening reading waits for the count to be back here.
@(private = "file")
resident_live: int

@(private = "file")
live_is_resident :: proc "contextless" (arg: rawptr) -> bool {
	_ = arg
	return stats().live == resident_live
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
	if pinned != 0 {
		// A drain that did not level names what is still standing: the
		// count, and every live process with the state its thread is in.
		// A holder that is a process shows here; one that is not is a
		// kernel object, and the count is the clue.
		sink := detail_for(what)
		libodin.put_int(&sink, i64(pinned))
		libodin.put_str(&sink, " objects held, live:")
		describe_live(&sink)
		fail_detail(r, &sink)
	} else {
		check(r, true, what)
	}
	r.pinned += pinned
}

// Room for a failure message that carries more than its name. Two, so a second
// failure in one boot does not overwrite the first's words; a third reuses
// the second's.
@(private = "file")
detail_bufs: [2][512]u8
@(private = "file")
detail_used: int

// detail_for opens a failure line that begins with the check's own name,
// so the line still says which check it was, and then says more.
@(private = "file")
detail_for :: proc "contextless" (what: string) -> libodin.Sink {
	sink := detail_sink()
	libodin.put_str(&sink, what)
	libodin.put_str(&sink, " -- ")
	return sink
}

// fail_detail is the failed check whose name is the detail line built.
// False, the way `check` answers, for a caller that returns it.
@(private = "file")
fail_detail :: proc "contextless" (r: ^Result, sink: ^libodin.Sink) -> bool {
	return check(r, false, libodin.str(sink))
}

@(private = "file")
detail_sink :: proc "contextless" () -> libodin.Sink {
	i := min(detail_used, len(detail_bufs) - 1)
	detail_used += 1
	return libodin.sink_from(detail_bufs[i][:])
}

// describe_live writes every live process: name, pid, parent, and the flags
// D (detached), X (its exit is done), C (being collected), then T and its
// thread's state as a digit (0 ready, 1 running, 2 blocked, 3 dead), or T-
// for a process with no thread.
@(private = "file")
describe_live :: proc "contextless" (sink: ^libodin.Sink) #no_bounds_check {
	for i in 0 ..< MAX_PROCESSES {
		p := &processes[i]
		if !p.live {
			continue
		}
		libodin.put_str(sink, " ")
		libodin.put_str(sink, p.name)
		libodin.put_str(sink, "#")
		libodin.put_uint(sink, p.pid)
		libodin.put_str(sink, "<")
		libodin.put_uint(sink, p.parent)
		if p.detached {
			libodin.put_str(sink, "D")
		}
		if intrinsics.volatile_load(&p.exit.done) {
			libodin.put_str(sink, "X")
		}
		if p.collecting {
			libodin.put_str(sink, "C")
		}
		libodin.put_str(sink, "T")
		if p.thread != nil {
			libodin.put_uint(sink, u64(p.thread.state))
		} else {
			libodin.put_str(sink, "-")
		}
	}
}

// The line the kernel types at the console server, byte by byte through the
// keyboard sink, exactly as IRQ 1's bottom half would deliver it. The
// newline is what the cooked discipline releases a line on.
@(private = "file")
CONSRV_TYPED :: "vectra lives\n"

// A deadline long enough that a read is genuinely parked in a worker before
// the wire gives up on it. And how many such reads `verify_consrv` abandons.
// Three, with a fourth parked beside them, is one more than a pool of three
// slots holds if a flushed worker never leaves.
@(private = "file")
GIVE_UP_TICKS :: 10
@(private = "file")
GIVE_UP_READS :: 3

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
	context = mem.kernel_context()
	_ = arg
	mount_reader.n, mount_reader.err = vfs.chan_read(mount_reader.c, 0, mount_reader.buf[:])
	intrinsics.volatile_store(&mount_reader.done, true)
}

/*
A server the suite starts, mounts, stops, and measures after.

`count0` is /srv before it posted and `pin_before` the heap before it
started. The three servers whose reads park open and close the same
bracket, so its two halves are written once. Every `what` is the site's
own, so each test still names its own claims.
*/
@(private = "file")
Tenant :: struct {
	p:          ^Process,
	name:       string, // What it posts in /srv
	at:         string, // Where the kernel mounts it
	srv_path:   [32]u8,
	count0:     int,
	pin_before: int,
}

// tenant_open takes the two readings the bracket closes against.
@(private = "file")
tenant_open :: proc(t: ^Tenant, name: string, at: string) {
	t.name = name
	t.at = at
	t.count0 = srv.count()
	settle()
	t.pin_before = mem.live_objects(mem.heap_stats())
}

// tenant_start starts the server, waits for its name, and mounts it. False
// when it did not start or did not post, and the site returns.
@(private = "file")
tenant_start :: proc(r: ^Result, t: ^Tenant, path: string, what_start: string, what_posted: string, what_mount: string) -> bool {
	t.p = start_path(r, path, what_start)
	if t.p == nil {
		return false
	}
	if !check(r, await_posted(t.name), what_posted) {
		return false
	}
	sink := libodin.sink_from(t.srv_path[:])
	libodin.put_str(&sink, "/srv/")
	libodin.put_str(&sink, t.name)
	check(r, srv.mount(vfs.boot_namespace, libodin.str(&sink), t.at) == vfs.OK, what_mount)
	return true
}

// The seven claims a stop makes, in the order it makes them.
@(private = "file")
Tenant_Stop :: struct {
	exits:     string,
	zero:      string,
	removed:   string,
	count:     string,
	down:      string,
	unmounted: string,
	drained:   string,
}

// tenant_stop is the tail every server test ends on. The exit, the name,
// the count, the record, the mount, and the heap back where it was.
// start_draw_server starts `intuition`, waits for its name, and measures
// the desktop it painted, which every discovery after it stands on. Nil
// when any of the three did not happen, and the site returns.
@(private = "file")
start_draw_server :: proc(r: ^Result, s: ^fb.Surface, what_start: string, what_posted: string, what_desk: string, argv: ^Argv = nil) -> ^Process {
	ps := start_path(r, "/bin/intuition", what_start, argv)
	if ps == nil {
		return nil
	}
	if !check(r, await_posted("draw"), what_posted) {
		return nil
	}
	if !check(r, desk_measure(s), what_desk) {
		return nil
	}
	return ps
}

@(private = "file")
tenant_stop :: proc(r: ^Result, t: ^Tenant, w: Tenant_Stop) {
	if check(r, wait(t.p, PATIENCE), w.exits) {
		check(r, t.p.exit.deliberate && t.p.exit.status == 0, w.zero)
	}
	check(r, srv.remove(t.name) == vfs.OK, w.removed)
	check(r, srv.count() == t.count0, w.count)
	finish(r, t.p, w.down)
	pipe.quiesce()
	check(r, vfs.unmount_path(vfs.boot_namespace, "", t.at) == vfs.OK, w.unmounted)
	drain_pinned(r, t.pin_before, w.drained)
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
	t: Tenant
	tenant_open(&t, "consrv", "/mnt")

	// -- The image is served, and is the second format ------------------------

	if _, image_ok := image_header(r, "/bin/consrv", "/bin serves the console server's image");
	   !image_ok {
		return
	}

	// -- It starts, forks, and posts ------------------------------------------

	if !tenant_start(r, &t, "/bin/consrv", "the loader starts the console server", "it forks its reader and posts /srv/consrv", "the kernel mounts it") {
		return
	}

	nc, oerr := vfs.open_path(vfs.boot_namespace, "/mnt/line", vfs.O_RDONLY)
	if !check(r, oerr == vfs.OK, "and opens the line file through the mount") {
		return
	}

	// -- A read parks, and the connection serves others while it does ---------

	/*
	The wart is gone: a read of `/line` with nothing typed **parks** now,
	rather than answering empty. The read runs on a thread of its own, because
	a read that never returns on the boot thread would print nothing after it.
	The server holds it and answers other requests while it waits -- which
	the getattr below proves.
	*/
	mount_reader = Mount_Reader{c = nc}
	if !check(r, sched.spawn("consrv-read", mount_read_thread, nil) != nil, "a thread to read /line") {
		return
	}

	// It stays parked. A read that answered empty would come back at once.
	parked := !sync.await_flag(&mount_reader.done, 20)
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

	// -- A read given up on lets its worker go --------------------------------

	/*
	The wire flushes a read whose deadline passes, and the flush used to stop
	at the wire. `serve_mux`'s worker never heard it, so every abandoned read
	left a worker polling the ring for ever. Three were enough to spend the
	pool and park the loop in the fourth. `docs/DRAW.md` section 13 has the
	boot that found it, and `sys/libuser/serve.odin` has the cancel that
	reaches the worker now.

	Three deadline reads, one after another, with the reader above still parked
	in a slot of its own. Each leaves within a tick of its flush. The wire's
	own counters are the witness.

	A discard per flush, because the flushed reply was never sent. No stale
	reply, because nothing wrote under a flushed tag after its Rflush. The stat
	afterwards is the pool not spent. The line typed below reaching the first
	reader whole is the flushed workers having drained nothing on their way
	out.

	With the cancel removed, the third read is answered inline by a loop that
	then parks. Its flush is never read, and the wire poisons itself after
	its own patience, which is what bounds this phase either way.
	*/
	wire := cast(^mnt.Wire)nc.server.session.transport.data
	before := mnt.wire_stats(wire)
	given_up := 0
	for _ in 0 ..< GIVE_UP_READS {
		scratch: [16]u8
		if _, e := vfs.chan_read_for(nc, 0, scratch[:], GIVE_UP_TICKS); e == vectra9.EINTR {
			given_up += 1
		}
	}
	check(r, given_up == GIVE_UP_READS, "three reads with a deadline each give up on the empty line")

	// A flushed worker leaves at its next poll, a tick on. Give the last a few.
	sync.delay(4)
	after := mnt.wire_stats(wire)
	// First, because a wire that poisoned itself is the wedge by name: a
	// flush nobody read, waited out. Every count after it is then wrong too.
	check(r, !after.poisoned, "the wire stands: every flush was answered")
	check(r, after.flushes == before.flushes + GIVE_UP_READS, "each deadline sent a Tflush")
	check(
		r,
		after.discards == before.discards + GIVE_UP_READS,
		"the server discarded every flushed read rather than answering it",
	)
	check(r, after.stale == before.stale, "and no reply went out under a flushed tag")

	if root, rerr := vfs.resolve(vfs.boot_namespace, "/mnt"); rerr == vfs.OK {
		_, aerr := vfs.chan_stat(root)
		check(r, aerr == vfs.OK, "a stat is still answered: the flushed workers gave their slots back")
		vfs.chan_close(root)
	}
	check(r, !intrinsics.volatile_load(&mount_reader.done), "and the first read is still parked")

	// -- A line is typed, and wakes the parked read ---------------------------

	ctl, cerr := vfs.open_path(vfs.boot_namespace, "/dev/consctl", vfs.O_WRONLY)
	if check(r, cerr == vfs.OK, "the kernel takes the echo off first") {
		off := "echooff"
		_, _ = vfs.chan_write(ctl, 0, transmute([]u8)off)
	}

	type_text(CONSRV_TYPED)

	woke := sync.await_flag(&mount_reader.done, PATIENCE)
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

	// The concurrent serve loop forked a worker per parked read, each
	// detached and left for the kernel. The drain collects them before
	// measuring, the way a live server would when its next fork wanted a slot.
	tenant_stop(r, &t, {
		exits     = "the server exits",
		zero      = "with zero -- its noted reader unwound a parked device read and answered EINTR",
		removed   = "the kernel takes the name away",
		count     = "and /srv holds what it held",
		down      = "and the server is taken down",
		unmounted = "the mount of the dead server comes down",
		drained   = "and the forked server's wire comes back whole",
	})
}

// The scancodes the kernel injects into `/dev/scancode`, and the characters
// `kbdfs` translates them to. `k b d` are make and break codes. Then a
// shift press, a `1` that shifts to `!` and its release, a shift release,
// and Enter with its release. The releases and the shift itself produce
// nothing, so the cooked stream is five characters. Every key is released,
// because the `kbd` file reports the keys held and the chord check after
// this one wants none left.
@(private = "file")
KBDFS_CODES :: [?]u8{0x25, 0xA5, 0x30, 0xB0, 0x20, 0xA0, 0x2A, 0x02, 0x82, 0xAA, 0x1C, 0x9C}
@(private = "file")
KBDFS_COOKED :: "kbd!\n"

// A chord: alt down, `n` down, `n` up, alt up. The cooked file must carry
// none of it, and the `kbd` file reports every change of the keys held.
@(private = "file")
KBDFS_CHORD :: [?]u8{0x38, 0x31, 0xB1, 0xB8}

/*
verify_kbdfs is the userland devfs's first tenant: a kernel service rebuilt
as a program.

`kbdfs` opens `/dev/scancode`, which diverts the raw scancodes to it, and
serves the characters it translates from them on `/kbd`. The translation is
`kernel/drivers/kbd`'s, in ring 3 now. So this test injects make codes the
way the keyboard self-test does, and reads the cooked result back through a
mount instead.

The server holds the read of `cons`, so it runs on a thread. Between the open
and the first scancode it waits, which is the proof the file blocks on a key
rather than answering empty. Then the kernel injects `kbd!` and a newline as
scancodes. The parked read wakes carrying exactly the characters the state
machine makes -- shift included, since one of them is shifted.
*/
@(private = "file")
verify_kbdfs :: proc(r: ^Result) {
	t: Tenant
	tenant_open(&t, "kbdfs", "/mnt")
	if !tenant_start(r, &t, "/bin/kbdfs", "the loader starts the keyboard translator", "it forks its reader, opens /dev/scancode, and posts /srv/kbdfs", "the kernel mounts it") {
		return
	}

		kc, oerr := vfs.open_path(vfs.boot_namespace, "/mnt/cons", vfs.O_RDONLY)
	if !check(r, oerr == vfs.OK, "and opens the cooked keyboard file") {
		return
	}

	// The read parks: no key is pressed, and the translated stream is empty.
	// On a thread, because a parked read never returns.
	mount_reader = Mount_Reader{c = kc}
	if !check(r, sched.spawn("kbdfs-read", mount_read_thread, nil) != nil, "a thread to read /kbd") {
		return
	}
	parked := !sync.await_flag(&mount_reader.done, 20)
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

	woke := sync.await_flag(&mount_reader.done, PATIENCE)
	check(r, woke, "the parked read wakes when the keys are pressed")
	check(
		r,
		mount_reader.err == vfs.OK &&
				string(mount_reader.buf[:mount_reader.n]) == KBDFS_COOKED,
		"carrying the characters the state machine made: scancodes, shift and all",
	)

	// -- The keys, with their modifiers, on the other file --------------------

	/*
		`kbd` is 9front's file, a message per read. `k` and `K` carry every
	key held after a press and a release, and `c` the characters typed.
	An alt and an `n` are a chord. `cons` must never see one as a letter.
	`kbd` reports it as the alt key held with the `n` beside it, which is
	what a window manager reads a chord from.
	*/
	kb, kerr := vfs.open_path(vfs.boot_namespace, "/mnt/kbd", vfs.O_RDONLY)
	if check(r, kerr == vfs.OK && kb != nil, "and the kbd file opens beside it") {
		chord := KBDFS_CHORD
		for i in 0 ..< len(chord) {
			devfs.scancode_tap(chord[i])
		}
		want := [?]string{"k\xEF\x80\x95", "k\xEF\x80\x95n", "K\xEF\x80\x95", "K"}
		what := [?]string {
			"alt going down is a message naming the key held, as Plan 9's rune",
			"the n beside it joins the keys held",
			"the n going up leaves alt held",
			"and alt going up leaves nothing held",
		}
		for i in 0 ..< len(want) {
			if !kbd_read(r, kb, want[i], what[i]) {
				break
			}
		}
		// And the cooked file carried none of it: the next key typed is the
		// first byte it answers.
		devfs.scancode_tap(0x2D)
		devfs.scancode_tap(0xAD)
		_ = kbd_read(r, kc, "x", "and the cons file carried none of the chord: the next key typed is its first byte")
		vfs.chan_close(kb)
	}

	// -- Teardown, the same arc consrv taught --------------------------------

	check(r, vfs.chan_remove(kc) == vfs.OK, "a remove is answered, and is the stop")
	vfs.chan_close(kc)

	tenant_stop(r, &t, {
		exits     = "the translator exits",
		zero      = "with zero -- its noted reader unwound a parked scancode read",
		removed   = "the kernel takes the name away",
		count     = "and /srv holds what it held",
		down      = "and the translator is taken down",
		unmounted = "the mount of the dead translator comes down",
		drained   = "and the translator's wire comes back whole",
	})
}

// kbd_read reads one message off a kbdfs file on a thread, waits for it,
// and checks it is `want`. False when the read did not come back.
@(private = "file")
kbd_read :: proc(r: ^Result, c: ^vfs.Chan, want: string, what: string) -> bool {
	mount_reader = Mount_Reader{c = c}
	if !check(r, sched.spawn("kbdfs-read", mount_read_thread, nil) != nil, "a thread to read the file") {
		return false
	}
	woke := sync.await_flag(&mount_reader.done, PATIENCE)
	return check(r, woke && mount_reader.err == vfs.OK && string(mount_reader.buf[:mount_reader.n]) == want, what)
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

	t: Tenant
	tenant_open(&t, "eiafs", "/mnt")
	if !tenant_start(r, &t, "/bin/eiafs", "the loader starts the serial server", "it forks its reader, opens /dev/eia0, and posts /srv/eiafs", "the kernel mounts it") {
		return
	}

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
	parked := !sync.await_flag(&mount_reader.done, 20)
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

	woke := sync.await_flag(&mount_reader.done, PATIENCE)
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

	tenant_stop(r, &t, {
		exits     = "the serial server exits",
		zero      = "with zero -- its noted reader unwound a parked port read",
		removed   = "the kernel takes the name away",
		count     = "and /srv holds what it held",
		down      = "and the serial server is taken down",
		unmounted = "the mount of the dead server comes down",
		drained   = "and the serial server's wire comes back whole",
	})
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
	settle()
	pin_before := mem.live_objects(mem.heap_stats())

	p := start_path(r, "/bin/intuition", "the loader starts the draw server")
	if p == nil {
		return
	}

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
	And a window that wants a person says so, and the frame shows it.

	`state` on `wctl` is `docs/WORKBENCH.md` section 4: `working`, `waiting` or
	`idle`, a lamp on the frame beside the title and the screen bar's
	workspace lamp hot while any window waits. The amber jewel is a colour
	nothing else on a copper bar or a green workspace lamp makes, so its
	presence is the lamp and its absence is idle. The pair -- lit on `waiting`,
	gone on `idle` -- is what says the lamp follows the word and is not some
	fixture that was always there.
	*/
	amber := fb.pack(s, fb.AMBER)
	bar_amber :: proc "contextless" (s: ^fb.Surface, x0: int, y0: int, x1: int, y1: int, want: u32) -> bool #no_bounds_check {
		for y in y0 ..< y1 {
			if first, _ := scan_row(s, y, want, x0, x1); first >= 0 {
				return true
			}
		}
		return false
	}
	// The gadget glyphs are amber too, so the lamp is read where no gadget is:
	// between the close gadget on the bar's left (its amber ends near x18) and
	// the window's title, which is where `state_lamp` puts the jewel. Window
	// zero sits at the screen's origin, so the bar's coordinates are the
	// glass's. The workspace lamps sit in the right-edge column two half-screen
	// windows never reach, clear of this window's own gadgets.
	lamp_x0 := 22
	lamp_x1 := 44
	ws_x0 := max(s.width - 32, 0)
	ws_y1 := min(160, s.height)
	wbuf: [24]u8
	if wc, werr := vfs.open_path(vfs.boot_namespace, mnt_file(wbuf[:], 0, "/wctl"), vfs.O_RDWR); werr == vfs.OK {
		// Before any state is set the gap holds no lamp: the test reads the
		// word's effect, not a fixture.
		check(r, !bar_amber(s, lamp_x0, 6, lamp_x1, 20, amber), "a window with no state shows no lamp beside its title")

		waiting := "state waiting"
		_, serr := vfs.chan_write(wc, 0, transmute([]u8)waiting)
		check(r, serr == vfs.OK, "a window writes `state waiting` to its wctl")
		lit, hot := false, false
		for _ in 0 ..< PATIENCE * 10 {
			if !lit && bar_amber(s, lamp_x0, 6, lamp_x1, 20, amber) {
				lit = true
			}
			if !hot && bar_amber(s, ws_x0, 2, s.width, ws_y1, amber) {
				hot = true
			}
			if lit && hot {
				break
			}
			sync.delay(1)
		}
		check(r, lit, "the frame lights an amber lamp beside the title for it")
		check(r, hot, "and the screen bar's workspace lamp goes hot")

		idle := "state idle"
		_, _ = vfs.chan_write(wc, 0, transmute([]u8)idle)
		cooled := false
		for _ in 0 ..< PATIENCE * 10 {
			if !bar_amber(s, lamp_x0, 6, lamp_x1, 20, amber) {
				cooled = true
				break
			}
			sync.delay(1)
		}
		check(r, cooled, "and `state idle` takes the lamp away again")
		vfs.chan_close(wc)
	}

	/*
	And the snarf buffer, rio's `/dev/snarf` the desktop shares.

	`docs/WORKBENCH.md` section 4: one clipboard, a write replaces it and
	pushes the old contents onto a ten-deep history. The same buffer is
	reachable through a window's own directory, which is what the bind over
	`/dev` turns into `/dev/snarf` with no second bind.
	*/
	if sc, serr := vfs.open_path(vfs.boot_namespace, "/mnt/snarf", vfs.O_RDWR); serr == vfs.OK {
		rb: [64]u8
		first := "hello"
		_, w1 := vfs.chan_write(sc, 0, transmute([]u8)first)
		n1, _ := vfs.chan_read(sc, 0, rb[:])
		check(r, w1 == vfs.OK && string(rb[:n1]) == "hello", "a write to snarf is read back as the buffer")

		second := "world"
		_, _ = vfs.chan_write(sc, 0, transmute([]u8)second)
		n2, _ := vfs.chan_read(sc, 0, rb[:])
		check(r, string(rb[:n2]) == "world", "a second write replaces what snarf holds")
		vfs.chan_close(sc)

		if hc, herr := vfs.open_path(vfs.boot_namespace, "/mnt/snarfhist", vfs.O_RDONLY); herr == vfs.OK {
			hb: [128]u8
			hn, _ := vfs.chan_read(hc, 0, hb[:])
			check(r, hn > 0 && index_of(string(hb[:hn]), "hello") >= 0, "and the buffer it replaced is kept on snarfhist")
			vfs.chan_close(hc)
		}

		if qc, qerr := vfs.open_path(vfs.boot_namespace, "/mnt/0/snarf", vfs.O_RDONLY); qerr == vfs.OK {
			qb: [64]u8
			qn, _ := vfs.chan_read(qc, 0, qb[:])
			check(r, string(qb[:qn]) == "world", "and a window's own snarf is the one shared buffer, for /dev/snarf")
			vfs.chan_close(qc)
		}
	}

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
		fb.get_raw(s, ox + 8, oy - 4) == fb.pack(s, fb.COPPER),
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

	// -- A client attaches the store and paints it, no verb ------------------
	//
	// Window zero is open and its client area is at `(ox, oy)` on the glass.
	// Before a second window is on the screen to occlude it, a ring 3 client
	// maps the store and paints it straight.
	verify_store_client(r, s, ox, oy)

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

/*
verify_popup_stack guards the toast-stacking rule: a `.Popup` floats above
every ordinary window.

A notice toast is a popup below the bar's right corner. The bug it was found
by: a window opened or raised after the toast sat on top of it, because a
popup is marked after `window_open` has already placed it as an ordinary
window, and nothing raised it back. This drives the mechanism without the
desktop's keyboard and mouse automation: two normal windows cover the
top-right band, a popup opens over them, and then -- the heart of it -- a
third normal window opens over the same corner. The popup must stay on the
glass above it. The close-and-reopen step in between mirrors a toast
replacing the one before it, so a reused slot is exercised too.

See `stack_add` and `window_kind` in `servers/intuition`.
*/
@(private = "file")
popup_open :: proc(r: ^Result, slot: int, x: int, y: int, w: int, h: int, col: u32, kind: string, what: string) -> (^vfs.Chan, bool) {
	dbuf: [24]u8
	dc, derr := vfs.open_path(vfs.boot_namespace, mnt_file(dbuf[:], slot, "/data"), vfs.O_WRONLY)
	if !check(r, derr == vfs.OK, what) {
		return nil, false
	}
	wbuf: [24]u8
	wc, werr := vfs.open_path(vfs.boot_namespace, mnt_file(wbuf[:], slot, "/wctl"), vfs.O_RDWR)
	if werr != vfs.OK {
		vfs.chan_close(dc)
		check(r, false, what)
		return nil, false
	}
	defer vfs.chan_close(wc)

	line: [48]u8
	n := copy(line[:], "size ")
	n += put_uint(line[n:], w)
	line[n] = ' ';n += 1
	n += put_uint(line[n:], h)
	vfs.chan_write(wc, 0, line[:n])

	n = copy(line[:], "move ")
	n += put_uint(line[n:], x)
	line[n] = ' ';n += 1
	n += put_uint(line[n:], y)
	vfs.chan_write(wc, 0, line[:n])

	if len(kind) != 0 {
		vfs.chan_write(wc, 0, transmute([]u8)kind)
	}

	cmd: [64]u8
	at := libdraw.put_fill(cmd[:], 0, 0, 0, 0, u32(w), u32(h), col)
	at = libdraw.put_flush(cmd[:], at)
	vfs.chan_write(dc, 0, cmd[:at])
	return dc, true
}

// put_uint writes a non-negative integer as decimal into buf, returning its
// length. The freestanding side parses; the kernel side prints.
@(private = "file")
put_uint :: proc "contextless" (buf: []u8, v: int) -> int #no_bounds_check {
	if v == 0 {
		buf[0] = '0'
		return 1
	}
	tmp: [16]u8
	n := 0
	x := v
	for x > 0 {
		tmp[n] = u8('0' + x % 10)
		n += 1
		x /= 10
	}
	for i in 0 ..< n {
		buf[i] = tmp[n - 1 - i]
	}
	return n
}

verify_popup_stack :: proc(r: ^Result) #no_bounds_check {
	s := devfs.raw_surface()
	if s == nil || s.pixels == nil || s.bytes_pp != 4 {
		return
	}
	count0 := srv.count()
	settle()
	pin_before := mem.live_objects(mem.heap_stats())

	p := start_path(r, "/bin/intuition", "the popup-stack repro starts the draw server")
	if p == nil {
		return
	}
	if !check(r, await_posted("draw"), "it posts /srv/draw") {
		return
	}
	if !check(r, srv.mount(vfs.boot_namespace, "/srv/draw", "/mnt") == vfs.OK, "the kernel mounts it") {
		return
	}
	if !check(r, desk_measure(s), "and has painted a desktop") {
		return
	}

	// A band at the top-right, where a toast lands. Two normal windows cover
	// it; the popup takes the same corner.
	TW := 220
	TH := 90
	TX := s.width - TW - 24
	TY := WB_BAR_H + 12
	CA :: u32(0x0020_4080)
	CB :: u32(0x0040_8020)
	CP1 :: u32(0x00C0_3090)
	CP2 :: u32(0x0030_C0A0)

	// Two normal windows over the band, offset so both own the corner.
	dcA, okA := popup_open(r, 0, TX - 20, TY - 6, TW + 60, TH + 40, CA, "", "a first window covers the top-right band")
	if !okA {
		return
	}
	dcB, okB := popup_open(r, 1, TX - 6, TY - 2, TW + 40, TH + 30, CB, "", "a second window covers it too")
	if !okB {
		vfs.chan_close(dcA)
		return
	}

	// The popup over them, the corner a toast takes.
	dcP, okP := popup_open(r, 2, TX, TY, TW, TH, CP1, "popup", "a popup opens over them, the toast's corner")
	cx := TX + TW / 2
	cy := TY + TH / 2
	shown1 := false
	if okP {
		for _ in 0 ..< PATIENCE * 10 {
			if fb.get_raw(s, cx, cy) == CP1 {
				shown1 = true
				break
			}
			sync.delay(1)
		}
	}
	check(r, shown1, "the popup's pixels are on the glass over the two windows")

	// The toast replaces the one before it: close this popup and open another
	// in the slot it frees, the same corner. A reused slot is the suspect.
	if okP {
		vfs.chan_close(dcP)
	}
	settle()
	dcP2, okP2 := popup_open(r, 2, TX, TY, TW, TH, CP2, "popup", "a second popup reuses the freed slot")
	shown2 := false
	if okP2 {
		for _ in 0 ..< PATIENCE * 10 {
			if fb.get_raw(s, cx, cy) == CP2 {
				shown2 = true
				break
			}
			sync.delay(1)
		}
	}
	check(r, shown2, "and the replacing popup's pixels are on the glass too")

	// The heart of the fix: a normal window that opens over the popup must
	// land *under* it. The toast-stacking bug was a window opened after a
	// popup sitting on top of it, because a popup keeps no place of its own.
	dcC, okC := popup_open(r, 3, TX - 10, TY - 8, TW + 50, TH + 40, CA, "", "a normal window opens over the popup's corner")
	still := false
	if okC {
		for _ in 0 ..< PATIENCE * 10 {
			if fb.get_raw(s, cx, cy) == CP2 {
				still = true
				break
			}
			sync.delay(1)
		}
	}
	check(r, still, "the popup stays on the glass above a window that opened over it")

	if okC {
		vfs.chan_close(dcC)
	}
	if okP2 {
		vfs.chan_close(dcP2)
	}
	vfs.chan_close(dcB)
	vfs.chan_close(dcA)

	// Teardown, the arc every tenant obeys.
	if ctl, cerr := vfs.open_path(vfs.boot_namespace, "/mnt/0/ctl", vfs.O_RDONLY); cerr == vfs.OK {
		check(r, vfs.chan_remove(ctl) == vfs.OK, "a remove of a window's ctl is the server's stop")
		vfs.chan_close(ctl)
	}
	check(r, wait(p, PATIENCE), "the draw server exits")
	check(r, srv.remove("draw") == vfs.OK, "the kernel takes the name away")
	finish(r, p, "and the draw server is taken down")
	pipe.quiesce()
	_ = vfs.unmount_path(vfs.boot_namespace, "", "/mnt")
	check(r, srv.count() == count0, "and /srv holds what it held")
	drain_pinned(r, pin_before, "and the popup repro's wire comes back whole")
}

/*
verify_store_client is the handoff step 1 names: a program attaches its
window's store and paints it, with no draw verb between its pixels and the
glass.

`storetest` opens `/mnt/0/store`, reads the id and geometry the server reports,
`shmattach`es the same frames the server composites from, writes a square of
`STORE_COLOR` into the client area, and writes the store file to have it
flushed. The proof is the glass: the square is read back where the client area
sits, which no cell of the program's could fake -- the same standard
`verify_painter` holds a device write to. `ox, oy` is that client area's origin,
found by `verify_draw` before this runs.
*/
@(private = "file")
verify_store_client :: proc(r: ^Result, s: ^fb.Surface, ox: int, oy: int) {
	PATH :: "/mnt/0/store"
	// The rectangle `storetest` paints, named for its flush. It must match the
	// square `program.odin`'s `STORE_*` place, which is what the glass check
	// below reads.
	FLUSH :: "8 8 24 24"

	// The kernel reads the report and parses it -- the id and the client-area
	// origin -- and stages them into the client's cells. The freestanding
	// program cannot be trusted to parse; the read itself is proven here.
	id, stride, cx, cy: u64
	report_ok := false
	if t, terr := vfs.open_path(vfs.boot_namespace, PATH, vfs.O_RDONLY); terr == vfs.OK {
		sline: [96]u8
		sn, _ := vfs.chan_read(t, 0, sline[:])
		vfs.chan_close(t)
		vals: [4]u64
		report_numbers(sline[:sn], vals[:])
		id, stride, cx, cy = vals[0], vals[1], vals[2], vals[3]
		report_ok = sn > 0
	}
	check(r, report_ok && id != 0, "the store file names a shared-buffer id and geometry")

	p := hold_blob(r, "storetest", program_storetest(), "a client is built to attach the window's store")
	if p == nil {
		return
	}
	check(r, set_bytes(p, SLOT_A, bytes_of(PATH)), "with the store's path in its page")
	check(r, set_bytes(p, SLOT_D, bytes_of(FLUSH)), "and a flush line to send")
	// The id and origin the client attaches and paints at, in cells 3..6.
	set_cell(p, STORE_ID, id)
	set_cell(p, STORE_STRIDE, stride)
	set_cell(p, STORE_CX, cx)
	set_cell(p, STORE_CY, cy)

	check(r, launch(p, u64(len(PATH)), u64(len(FLUSH))), "and it launches, staged")
	if check(r, wait(p, PATIENCE), "and comes back") {
		check(r, cell(p, CELL_MARK) == MARK_STORETEST, "having reached its first instruction")
		check(r, i64(cell(p, STORE_ATTACH)) >= 0, "the window's store attached into the client's own space")
		check(r, i64(cell(p, STORE_FD)) >= 0, "it opened the store to flush")
		check(r, i64(cell(p, STORE_FLUSHED)) >= 0, "and its flush was answered")
		check(
			r,
			fb.get_raw(s, ox + STORE_BX + STORE_SZ / 2, oy + STORE_BY + STORE_SZ / 2) == STORE_COLOR,
			"and the square it painted straight into the store is on the glass, no verb between",
		)
	}
	finish(r, p, "and the client is taken down")
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

// await_glyph is `await_caret` for a character: true once `ch` is on the
// glass at the cell, with the ticks it took, which one caller reports.
@(private = "file")
await_glyph :: proc(s: ^fb.Surface, x: int, y: int, ch: u8, patience: int) -> (found: bool, ticks: int) {
	for _ in 0 ..< patience {
		if glyph_on_glass(s, x, y, ch) {
			return true, ticks
		}
		sync.delay(1)
		ticks += 1
	}
	return false, ticks
}

// await_corner waits for the screen's first pixel to take one colour, which
// is how an overview's ground arrives and leaves.
@(private = "file")
await_corner :: proc(s: ^fb.Surface, want: u32, patience: int) -> bool {
	for _ in 0 ..< patience {
		if fb.get_raw(s, 0, 0) == want {
			return true
		}
		sync.delay(1)
	}
	return false
}

// await_bar finds the window in front by its copper title bar: a wide run of
// copper, scanned top down, which a stray pixel is not. Returns -1 when none
// arrived in the patience.
@(private = "file")
await_bar :: proc(s: ^fb.Surface) -> (bx: int, by: int, bw: int) {
	copper := fb.pack(s, fb.COPPER)
	bx, by, bw = -1, -1, 0
	for _ in 0 ..< PATIENCE * 20 {
		for y in 4 ..< s.height / 2 {
			first, last := scan_row(s, y, copper, 8, s.width - 8)
			if first >= 0 && last - first > 100 {
				bx, by, bw = first, y, last - first + 1
				break
			}
		}
		if bx >= 0 {
			break
		}
		sync.delay(1)
	}
	return
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

// column_profile writes one column of the glass as runs, for a failure
// message: a letter per kind of pixel and the run's length.
@(private = "file")
column_profile :: proc "contextless" (sink: ^libodin.Sink, s: ^fb.Surface, x: int, y0: int, y1: int, face: u32, amber: u32) #no_bounds_check {
	lit := fb.pack(s, fb.MAGNESIUM_LIT)
	dark := fb.pack(s, fb.MAGNESIUM_DARK)
	ground := fb.pack(s, fb.SLATE_DEEP)
	well := fb.pack(s, fb.SLATE)
	last := u8(0)
	run := 0
	for y in y0 ..< y1 {
		px := fb.get_raw(s, x, y)
		kind := u8('o')
		switch px {
		case face: kind = 'M'
		case lit: kind = 'L'
		case dark: kind = 'D'
		case ground: kind = 'G'
		case well: kind = 'S'
		case amber: kind = 'A'
		}
		if kind == last {
			run += 1
			continue
		}
		if last != 0 {
			libodin.put_str(sink, string([]u8{last}))
			libodin.put_int(sink, i64(run))
			libodin.put_str(sink, " ")
		}
		last = kind
		run = 1
	}
	if last != 0 {
		libodin.put_str(sink, string([]u8{last}))
		libodin.put_int(sink, i64(run))
	}
}

// cell_says names what a cell holds, for a failure message: the glyph asked
// for, a blank, or something else with its count of foreground pixels, which
// tells a wrong glyph from a caret from a half-drawn one.
@(private = "file")
cell_says :: proc "contextless" (s: ^fb.Surface, x: int, y: int, ch: u8) -> string #no_bounds_check {
	if glyph_on_glass(s, x, y, ch) {
		return "ok"
	}
	if cell_body_blank(s, x, y) {
		return "blank"
	}
	fg, other := 0, 0
	for line in 0 ..< libfont.FONT_HEIGHT {
		for i in 0 ..< libfont.FONT_WIDTH {
			switch fb.get_raw(s, x + i, y + line) {
			case TERM_FG: fg += 1
			case TERM_BG:
			case: other += 1
			}
		}
	}
	@(static) said: [2][32]u8
	@(static) turn: int
	sink := libodin.sink_from(said[turn & 1][:])
	turn += 1
	libodin.put_str(&sink, "other(fg ")
	libodin.put_int(&sink, i64(fg))
	libodin.put_str(&sink, ", foreign ")
	libodin.put_int(&sink, i64(other))
	libodin.put_str(&sink, ")")
	return libodin.str(&sink)
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
	settle()
	pin_before := mem.live_objects(mem.heap_stats())

	// This server is a fresh one, so its desktop is measured again rather than
	// inherited from the last procedure's. It gates for `verify_draw`'s reason.
	ps := start_draw_server(r, s, "the loader starts the draw server", "it posts /srv/draw for a client to find", "and paints a desktop over the whole screen before anything else")
	if ps == nil {
		return
	}

	pt := start_path(r, "/bin/terminal", "the loader starts the terminal")
	if pt == nil {
		return
	}

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
	// The first row of the grid, eight pixels in from the client area's
	// top, where the shell's prompt lands.
	y0 := oy + 8

	/*
	The prompt is the shell's, not the terminal's: `% ` written to its
	descriptor 2, which is a pipe the terminal reads and draws. So it lands
	only after the terminal has mounted the server, uploaded the font,
	started `/bin/rc` off the disk, and rc has run `rcmain`. The poll waits
	for the exact glyph, so a wrong atlas never satisfies it, and for longer
	than a glyph alone would take, because a program load is in the way.
	*/
	prompted, _ := await_glyph(s, ox + 8, y0, '%', PATIENCE * 10)
	check(r, prompted, "the terminal starts a shell in its window, whose prompt it draws")
	check(r, glyph_on_glass(s, ox + 16, y0, ' '), "whose glyphs match the kernel's own font, pixel for pixel")

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

	The last glyph is polled first, and then the other two. The glass is read
	from another core while the server copies the terminal's damage onto it,
	and the copy is not one store. A cell the caret just left can read half
	painted for a tick after the next glyph is whole.
	*/
	echoed, echo_ticks := await_glyph(s, ox + 40, y0, '!', PATIENCE * 10)
	r.echo_ticks = echo_ticks
	check(r, echoed, "and yet appear on the glass, because the window that draws them holds the line")
	both := false
	for _ in 0 ..< PATIENCE {
		if glyph_on_glass(s, ox + 24, y0, 'h') && glyph_on_glass(s, ox + 32, y0, 'i') {
			both = true
			break
		}
		sync.delay(1)
	}
	if both {
		check(r, true, "every one of them, before any newline says the line is finished")
	} else {
		// The failure says what each cell held, and whether the pair was
		// right later still. A glyph that arrives late and one that never
		// does are two bugs.
		sink := detail_for("every one of them, before any newline says the line is finished")
		libodin.put_str(&sink, "h ")
		libodin.put_str(&sink, cell_says(s, ox + 24, y0, 'h'))
		libodin.put_str(&sink, ", i ")
		libodin.put_str(&sink, cell_says(s, ox + 32, y0, 'i'))
		late := -1
		for tick in 0 ..< PATIENCE {
			if glyph_on_glass(s, ox + 24, y0, 'h') && glyph_on_glass(s, ox + 32, y0, 'i') {
				late = tick
				break
			}
			sync.delay(1)
		}
		if late >= 0 {
			libodin.put_str(&sink, ", both right ")
			libodin.put_int(&sink, i64(late))
			libodin.put_str(&sink, " ticks later")
		} else {
			libodin.put_str(&sink, ", never right; h ")
			libodin.put_str(&sink, cell_says(s, ox + 24, y0, 'h'))
			libodin.put_str(&sink, ", i ")
			libodin.put_str(&sink, cell_says(s, ox + 32, y0, 'i'))
		}
		fail_detail(r, &sink)
	}

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
	kept, _ := await_glyph(s, ox + 32, y0, 'i', PATIENCE)
	check(r, kept, "and leaves the rest of the line where it was")
	// And the caret came back with it, which is the cursor this milestone
	// gave the line. It sits where the next character goes, and not where
	// the rubbed-out one went, polled as the moves below are.
	check(r, await_caret(s, ox + 40, ox + 48, y0), "and the caret comes back with it, to where the next one goes")

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
	rendered, _ := await_glyph(s, ox + 40, y0, '!', PATIENCE)
	check(r, rendered, "the newline completes the line and the terminal renders it")
	check(
		r,
		glyph_on_glass(s, ox + 24, y0, 'h') && glyph_on_glass(s, ox + 32, y0, 'i'),
		"every glyph out of the uploaded atlas, pixel for pixel",
	)
	/*
	The shell got the line. `hi!` names no program, so rc says so on the next
	row and prompts again on the one after, and the caret is there now: the
	terminal's cursor follows the shell's output, and the typed line stays
	where it was, above.
	*/
	answered, _ := await_glyph(s, ox + 8, y0 + 32, '%', PATIENCE * 10)
	check(r, answered, "the shell takes the line, answers it on the next row, and prompts again")
	check(
		r,
		cell_body_blank(s, ox + 48, y0) && caret_at(s, ox + 24, y0 + 32),
		"and the caret sits after the new prompt, which is where the next character goes",
	)

	// The typed stop, and the terminal's own exit.
	type_text("exit\n")
	if check(r, wait(pt, PATIENCE * 10), "the typed exit ends the shell, and the terminal with it") {
		check(
			r,
			pt.exit.deliberate && pt.exit.status == 0,
			"with zero -- the shell's ending is the terminal's own",
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
verify_chords is `docs/WORKBENCH.md` step 2's chords, from the keyboard to
the window manager and the desktop.

The whole init stack, wired the way `init` wires it. `kbdfs` reads the
raw scancodes. The draw server reads `kbdfs`'s `kbd` file, so a modifier
held with a key is a message the server can see. The kernel injects the
scancodes of a chord, and two things follow. `alt-w` is `close` in the
staged `/lib/keys`, so the window in front hangs up. `alt-n` is `window rc
-i`, which the server does not know, so it goes out on `/srv/draw/hotkey`
for the desktop to run.

A machine with no keyboard controller injects into a stream `kbdfs` reads
all the same, so this runs on the three boards alike.
*/
/*
verify_muiwin spawns the toolkit demo and reads its window off the glass.

`apps/muidemo` is the first program on `sys/libmui`. This is the live half of
the toolkit's proof, the half `tests/mui` cannot make: it opens a real window,
lays a gadget tree out in it, and paints it into the window's store. The
checks are the glass's. The focused window wears a copper bar. A button face is
magnesium, in the middle of the window and below the bar, where no frame edge
reaches, so it is the client drawing and not the server's frame. A label on that
face is amber, its glyph's bits laid in the ink over the face in the store,
`docs/CHROME.md` brick 3, which is the "Amiga look" with no atlas under it.

The teardown is the terminal's: the server is stopped by a remove of a window's
ctl, and both processes come down.
*/
@(private = "file")
verify_muiwin :: proc(r: ^Result) #no_bounds_check {
	s := devfs.raw_surface()
	if s == nil || s.pixels == nil || s.bytes_pp != 4 {
		return
	}

	count0 := srv.count()
	settle()
	pin_before := mem.live_objects(mem.heap_stats())

	ps := start_draw_server(r, s, "the loader starts the draw server for the toolkit", "which posts /srv/draw for the demo to find", "and paints a desktop before the demo opens a window")
	if ps == nil {
		return
	}

	// The person's theme is the shipped one here: a personal file an
	// interrupted boot left would dress the demo, and the reload check
	// below writes its own.
	remove_file("/usr/glenda/lib/theme")
	pd := start_path(r, "/bin/muidemo", "the loader starts the toolkit demo")
	if pd == nil {
		return
	}

	// The focused window's bar is copper. Wait for it, scanning top down for a
	// wide run of it, which a title bar is and a stray pixel is not.
	bx, by, bw := await_bar(s)
	if !check(r, bx >= 0, "the demo opens a framed window on the toolkit, its title bar copper") {
		finish(r, pd, "the toolkit demo is taken down")
		finish(r, ps, "and the draw server is taken down")
		return
	}

	// The bar wears its gadgets: a magnesium face on the copper trim, which a
	// rename must repaint rather than paint over. A window sets its name at
	// startup, so a bar that erased its gadgets on rename would show none here.
	bar_mag := fb.pack(s, fb.MAGNESIUM)
	check(r, bar_has(s, bx, by, bw, 20, bar_mag), "and the bar keeps its close, depth and zoom gadgets after the name is set")

	// A button face is magnesium, below the bar and inside the window, clear of
	// the few pixels of magnesium frame at either edge. The client's paint
	// follows the frame by a moment, so this polls
	// three interior columns until a run of face appears under one.
	magnesium := fb.pack(s, fb.MAGNESIUM)
	gtop, gbot, gx := -1, -1, -1
	cols := [3]int{bx + bw / 4, bx + bw / 2, bx + 3 * bw / 4}
	for _ in 0 ..< PATIENCE * 20 {
		for c in cols {
			t, b := scan_col(s, c, magnesium, by + 8, s.height)
			if t > by + 8 && b - t >= libfont.FONT_HEIGHT {
				gtop, gbot, gx = t, b, c
				break
			}
		}
		if gtop > 0 {
			break
		}
		sync.delay(1)
	}
	face := check(r, gtop > 0, "and paints a button face inside it, which is the client drawing through the toolkit")


	/*
	A label on that face is amber, its glyphs laid in the ink over the face.

	The face's extent is measured again on every look, and that is the whole
	of this check's history. The face poll above returns the moment a run of
	face appears under a column, and the compositor paints a window's rows top
	down, so the run it saw can be the top of a button whose bottom rows had
	not reached the glass yet. A band frozen there never holds the label:
	in a full-height window the tools row stretches its buttons to a hundred
	and twenty rows, the label sits fifty rows below the top edge, and five
	boots in two hundred read the band as `55..90` and found nothing amber in
	it for four seconds while the whole button, label and all, stood beneath
	it. The pixels were never wrong; the ruler was.
	*/
	if face {
		amber := fb.pack(s, fb.AMBER)
		found_label := false
		for _ in 0 ..< PATIENCE * 20 {
			t, b := scan_col(s, gx, magnesium, by + 8, s.height)
			if t > by + 8 && b > t {
				gtop, gbot = t, b
				for row in t ..< b {
					if first, _ := scan_row(s, row, amber, gx - bw / 4, gx + bw / 4); first >= 0 {
						found_label = true
						break
					}
				}
			}
			if found_label {
				break
			}
			sync.delay(1)
		}
		if found_label {
			check(r, true, "with an amber label on it, its glyphs laid in the ink over the face")
			// And in the chrome face, `docs/CHROME.md` brick 4: its edges are
			// coverage, so a pixel between the amber and the magnesium stands
			// beside the ink, which the one-bit cells never drew.
			smooth := false
			band: for row in gtop ..< gbot {
				for x in max(gx - bw / 4, 0) ..< min(gx + bw / 4, s.width) {
					v := fb.get_raw(s, x, row)
					if v != amber && v != magnesium && between_px(v, amber, magnesium) {
						smooth = true
						break band
					}
				}
			}
			check(r, smooth, "and the label's edges are smooth, a pixel between the ink and the face: the baked chrome face")
		} else {
			// What stood there instead, so the next miss names itself: the
			// face's rows, the band's census, and the column as runs of what
			// each pixel is -- M face, L lit edge, D dark edge, G the window
			// ground, S the well, A amber, o anything else.
			sink := detail_for("with an amber label on it, its glyphs laid in the ink over the face")
			libodin.put_str(&sink, "none in face rows ")
			libodin.put_int(&sink, i64(gtop))
			libodin.put_str(&sink, "..")
			libodin.put_int(&sink, i64(gbot))
			libodin.put_str(&sink, " at column ")
			libodin.put_int(&sink, i64(gx))
			mag, amb, stray := 0, 0, 0
			for row in gtop ..< gbot {
				for x in max(gx - bw / 4, 0) ..< min(gx + bw / 4, s.width) {
					switch fb.get_raw(s, x, row) {
					case magnesium: mag += 1
					case amber: amb += 1
					case: stray += 1
					}
				}
			}
			libodin.put_str(&sink, "; band face ")
			libodin.put_int(&sink, i64(mag))
			libodin.put_str(&sink, " amber ")
			libodin.put_int(&sink, i64(amb))
			libodin.put_str(&sink, " other ")
			libodin.put_int(&sink, i64(stray))
			libodin.put_str(&sink, ", window ")
			libodin.put_int(&sink, i64(bx))
			libodin.put_str(&sink, ",")
			libodin.put_int(&sink, i64(by))
			libodin.put_str(&sink, " wide ")
			libodin.put_int(&sink, i64(bw))
			libodin.put_str(&sink, "; column from the bar: ")
			column_profile(&sink, s, gx, by, min(by + 220, s.height), magnesium, amber)
			fail_detail(r, &sink)
		}
	}

	// -- A theme change reaches a program that is not the desktop -----------------

	/*
	`docs/WORKBENCH.md` step 5: every program on the toolkit follows the
	theme. A personal theme names the face copper, `reload` on the server's
	`ctl` bumps its `theme` generation, and the demo -- which is not
	Workbench, and read no theme of its own -- lays itself out again, its
	button face now copper. The file goes and a second reload brings the
	magnesium back.
	*/
	// The demo mounted the server in its own namespace; the kernel mounts it
	// here to write `reload`, and takes the mount down after, as the
	// teardown below mounts it again to stop the server.
	if face && check(r, srv.mount(vfs.boot_namespace, "/srv/draw", "/mnt") == vfs.OK, "the kernel mounts the server, to ask it to reload") {
		defer check(r, vfs.unmount_path(vfs.boot_namespace, "", "/mnt") == vfs.OK, "and takes the mount down after")
		// The toolkit said what program the window is, for the rules.
		ab: [128]u8
		an := read_once("/mnt/0/ctl", ab[:])
		check(r, an > 0 && libodin.contains(string(ab[:an]), "app muidemo"), "the toolkit names its program on wctl, and the window's ctl says app muidemo")
		copper := fb.pack(s, fb.COPPER)
		probe_y := gtop + 1
		_ = make_disk_dir("/usr/glenda")
		_ = make_disk_dir("/usr/glenda/lib")
		wrote := write_disk_file("/usr/glenda/lib/theme", "face copper\n")
		turned := false
		if wrote && net_file_write("/mnt/ctl", "reload") {
			for _ in 0 ..< PATIENCE * 20 {
				if fb.get_raw(s, gx, probe_y) == copper {
					turned = true
					break
				}
				sync.delay(1)
			}
		}
		if !check(r, turned, "a theme that names the face copper, and a reload, and the demo's button face is copper: a program that is not the desktop follows the theme") {
			dbg: [256]u8
			sink := libodin.sink_from(dbg[:])
			libodin.put_str(&sink, "theme-diag: wrote ")
			libodin.put_str(&sink, wrote ? "yes" : "no")
			libodin.put_str(&sink, " probe ")
			libodin.put_int(&sink, i64(gx))
			libodin.put_str(&sink, ",")
			libodin.put_int(&sink, i64(probe_y))
			libodin.put_str(&sink, " pix ")
			libodin.put_hex(&sink, u64(fb.get_raw(s, gx, probe_y)))
			libodin.put_str(&sink, " mag ")
			libodin.put_hex(&sink, u64(magnesium))
			libodin.put_str(&sink, " copper ")
			libodin.put_hex(&sink, u64(copper))
			tg: [32]u8
			tn := read_once("/mnt/theme", tg[:])
			libodin.put_str(&sink, " gen ")
			libodin.put_str(&sink, string(tg[:max(tn, 0)]))
			libodin.put_str(&sink, "\n")
			_ = net_file_write("/dev/cons", libodin.str(&sink))
		}
		// A line scoped to the demo wins in the demo, whatever its order.
		cyan := fb.pack(s, fb.CYAN)
		scoped := false
		if write_disk_file("/usr/glenda/lib/theme", "face copper\nmuidemo/face cyan\n") && net_file_write("/mnt/ctl", "reload") {
			for _ in 0 ..< PATIENCE * 20 {
				if fb.get_raw(s, gx, probe_y) == cyan {
					scoped = true
					break
				}
				sync.delay(1)
			}
		}
		check(r, scoped, "a line scoped to the demo, muidemo/face cyan, wins in the demo over the unscoped copper")
		// And which line set it, asked of `style`.
		snames := [?]string{"rc", "/lib/tests/style.rc"}
		script_says(r, "/bin/rc", snames[:], PATIENCE * 20, "the shell starts on the style script", "ok", "style explain says which line won and which it beat, as the demo sees it and as another program does")
		remove_file("/usr/glenda/lib/theme")
		back := false
		if net_file_write("/mnt/ctl", "reload") {
			for _ in 0 ..< PATIENCE * 20 {
				if fb.get_raw(s, gx, probe_y) == magnesium {
					back = true
					break
				}
				sync.delay(1)
			}
		}
		check(r, back, "and with the file gone, a second reload brings the magnesium back")

		// A desktop ground by name: a theme that defines one and picks it. The
		// server reads the person's theme under its own `$home`.
		_ = env.set(ps.env, "home", "/usr/glenda")
		dpx, dpy := s.width - 12, s.height - 12
		before := fb.get_raw(s, dpx, dpy)
		is_desk_px := before == fb.pack(s, fb.SLATE_DEEP) || before == fb.pack(s, fb.VOID)
		if check(r, is_desk_px, "the desktop shows at the glass's bottom right, clear of the demo") {
			recoloured := false
			if write_disk_file("/usr/glenda/lib/theme", "desk flat plain copper\ndesk.ground flat\n") && net_file_write("/mnt/ctl", "reload") {
				for _ in 0 ..< PATIENCE * 10 {
					if fb.get_raw(s, dpx, dpy) == copper {
						recoloured = true
						break
					}
					sync.delay(1)
				}
			}
			check(r, recoloured, "a theme that defines a ground, desk flat plain copper, and picks it lays it: a new ground is a theme edit")
			remove_file("/usr/glenda/lib/theme")
			restored := false
			if net_file_write("/mnt/ctl", "reload") {
				for _ in 0 ..< PATIENCE * 10 {
					if fb.get_raw(s, dpx, dpy) == before {
						restored = true
						break
					}
					sync.delay(1)
				}
			}
			check(r, restored, "and with the file gone the shipped grid is laid again")
		}

		/*
		A frame by name, `docs/CHROME.md` brick 1. The server says a window's
		insets on its `wctl` line, and a theme may size the bar. The client
		area keeps its size and its pixels and the window grows round it, so
		the demo's face moves down by what the bar gained, and the rows the
		client had at the top are bar now.
		*/
		wx, wy, ww, wh, l0, t0, r0, b0, wok := wctl_frame("/mnt/0/wctl")
		check(r, wok && l0 == 5 && t0 == 25 && r0 == 5 && b0 == 5, "the window's wctl line says the frame's insets, 5 25 5 5 for the chassis frame")
		gb: [96]u8
		gn := read_once("/mnt/0/ctl", gb[:])
		cw0, ch0, _, _, _ := libdraw.parse_geometry(gb[:max(gn, 0)])
		if wok && write_disk_file("/usr/glenda/lib/theme", "frame.title 30\n") && net_file_write("/mnt/ctl", "reload") {
			grown := false
			for _ in 0 ..< PATIENCE * 10 {
				if _, _, _, h1, _, t1, _, _, ok1 := wctl_frame("/mnt/0/wctl"); ok1 && t1 == 35 && h1 == wh + 10 {
					grown = true
					break
				}
				sync.delay(1)
			}
			check(r, grown, "a theme that names frame.title 30, and a reload, and the top inset is 35 and the window ten rows taller")
			gn = read_once("/mnt/0/ctl", gb[:])
			cw1, ch1, _, _, _ := libdraw.parse_geometry(gb[:max(gn, 0)])
			check(r, cw1 == cw0 && ch1 == ch0, "and the client area keeps its size, so the client lays out nothing")
			moved := false
			for _ in 0 ..< PATIENCE * 10 {
				if fb.get_raw(s, gx, probe_y + 10) == magnesium && fb.get_raw(s, wx + ww / 2, wy + 30) == copper {
					moved = true
					break
				}
				sync.delay(1)
			}
			check(r, moved, "and the demo's face sits ten rows lower, under a copper bar where its client area began")
			remove_file("/usr/glenda/lib/theme")
			shrunk := false
			if net_file_write("/mnt/ctl", "reload") {
				for _ in 0 ..< PATIENCE * 10 {
					if _, _, _, h2, _, t2, _, _, ok2 := wctl_frame("/mnt/0/wctl"); ok2 && t2 == 25 && h2 == wh {
						shrunk = true
						break
					}
					sync.delay(1)
				}
			}
			check(r, shrunk, "and with the file gone the chassis frame comes back at its old size")
		}

		/*
		Schemes, `docs/CHROME.md` brick 2. A scheme is a file of `colour`
		lines and roles by job, picked with `use`. The toolkit and the server
		read one table of names, so `use neon` turns the demo's face neon's
		`raised` and the front bar neon's `metal.hi`. A personal file may
		define a colour of its own and name it.
		*/
		schemes := [?]struct {
			text: string,
			face: fb.RGB,
			bar:  fb.RGB,
			what: string,
		}{
			{"use neon\n", {0x2a, 0x21, 0x50}, {0x4a, 0x41, 0x78}, "use neon, and a reload, and the demo's face is neon's raised and the front bar neon's metal: one scheme for both halves"},
			{"use daylight\n", {0xf1, 0xee, 0xf8}, {0xf6, 0xf4, 0xfb}, "use daylight turns them daylight's"},
			{"colour sig 123456\nface sig\n", {0x12, 0x34, 0x56}, fb.COPPER, "a personal colour line, colour sig 123456, names a colour a role may take"},
		}
		for sc in schemes {
			face_px, bar_px := fb.pack(s, sc.face), fb.pack(s, sc.bar)
			worn := false
			if write_disk_file("/usr/glenda/lib/theme", sc.text) && net_file_write("/mnt/ctl", "reload") {
				for _ in 0 ..< PATIENCE * 20 {
					if fb.get_raw(s, gx, probe_y) == face_px && bar_colour_near(s, wx + ww / 2, wy, bar_px) {
						worn = true
						break
					}
					sync.delay(1)
				}
			}
			check(r, worn, sc.what)
		}
		remove_file("/usr/glenda/lib/theme")
		unworn := false
		if net_file_write("/mnt/ctl", "reload") {
			for _ in 0 ..< PATIENCE * 20 {
				if fb.get_raw(s, gx, probe_y) == magnesium && fb.get_raw(s, wx + ww / 2, wy + 13) == copper {
					unworn = true
					break
				}
				sync.delay(1)
			}
		}
		check(r, unworn, "and with the file gone the chassis's magnesium and copper come back")

		/*
		The overlay, `docs/CHROME.md` section 9: theme lines the draw server
		keeps in memory, over the files, which is what `Use` in the
		preferences writes. `face copper` there turns the demo's face copper,
		and no file is written. A blank line in its place takes it back.
		*/
		copper_face := fb.pack(s, fb.COPPER)
		used := false
		if net_file_write("/mnt/overlay", "face copper\n") {
			for _ in 0 ..< PATIENCE * 20 {
				if fb.get_raw(s, gx, probe_y) == copper_face {
					used = true
					break
				}
				sync.delay(1)
			}
		}
		check(r, used, "a line written to the draw server's overlay, face copper, turns the demo's face copper")
		ob: [16]u8
		check(r, web_read_file("/usr/glenda/lib/theme", ob[:], raw = true) < 0, "and writes no theme file")
		cancelled := false
		if net_file_write("/mnt/overlay", "\n") {
			for _ in 0 ..< PATIENCE * 20 {
				if fb.get_raw(s, gx, probe_y) == magnesium {
					cancelled = true
					break
				}
				sync.delay(1)
			}
		}
		check(r, cancelled, "and a blank line written over it puts the chassis's magnesium back")

		/*
		The frame past the chassis, `docs/CHROME.md` brick 5. A `glow` puts a
		halo of `focus`, cyan in the chassis, round the front window, drawn by
		the compositor on the pixels beside the window: one just right of the
		demo's frame turns toward cyan. `frame.style metal` makes the bar
		brushed metal with a line of `focus` along its foot. With the file gone
		the pixel beside the window is the desktop's again, exactly.
		*/
		hx, hy := wx + ww + 2, wy + 40
		if hx < s.width {
			plain := fb.get_raw(s, hx, hy)
			haloed := false
			if write_disk_file("/usr/glenda/lib/theme", "glow 60\n") && net_file_write("/mnt/ctl", "reload") {
				for _ in 0 ..< PATIENCE * 20 {
					v := fb.get_raw(s, hx, hy)
					if v != plain && (v >> 8 & 0xFF) > (plain >> 8 & 0xFF) && (v & 0xFF) > (plain & 0xFF) {
						haloed = true
						break
					}
					sync.delay(1)
				}
			}
			check(r, haloed, "a theme with glow 60 lays a halo round the front window: a pixel beside its frame turns toward cyan")
			cyan = fb.pack(s, fb.CYAN)
			lined := false
			if write_disk_file("/usr/glenda/lib/theme", "glow 60\nframe.style metal\n") && net_file_write("/mnt/ctl", "reload") {
				// The bar is FRAME_EDGE down and FRAME_TITLE tall in the chassis
				// metrics, so its last row is the edge plus the title less one.
				foot := wy + 3 + 20 - 1
				for _ in 0 ..< PATIENCE * 20 {
					if fb.get_raw(s, wx + ww / 2, foot) == cyan && fb.get_raw(s, wx + ww / 2 + 1, wy + 4) != fb.get_raw(s, wx + ww / 2 + 1, foot - 2) {
						lined = true
						break
					}
					sync.delay(1)
				}
			}
			check(r, lined, "and frame.style metal makes the bar a gradient with a focus line along its foot")
			/*
			And its gadgets are the study's keys, a glyph in `text` drawn in
			outline. In the chassis metrics the zoom gadget is sixteen square
			at the bar's right, and its glyph's twelve-pixel box starts two in.
			The left edge of that box, halfway down, is amber in the metal key
			and the plain magnesium face in the chassis's gadget.
			*/
			zx, zy := wx + ww - 21 + 2, wy + 5 + 2 + 6
			keyed := false
			if lined {
				for _ in 0 ..< PATIENCE * 5 {
					if v := fb.get_raw(s, zx, zy); (v >> 16 & 0xFF) > 160 && v != fb.pack(s, fb.AMBER) {
						keyed = true
						break
					}
					sync.delay(1)
				}
			}
			check(r, keyed, "and its zoom gadget is the study's key: the glyph's outline in the text colour, where the chassis gadget was plain face")

			remove_file("/usr/glenda/lib/theme")
			cleared := false
			if net_file_write("/mnt/ctl", "reload") {
				for _ in 0 ..< PATIENCE * 20 {
					if fb.get_raw(s, hx, hy) == plain {
						cleared = true
						break
					}
					sync.delay(1)
				}
			}
			check(r, cleared, "and with the file gone the pixel beside the window is the desktop's again, exactly")
		}


		/*
		A menu is a tree, `docs/CHROME.md` brick 6. Button 3 in the demo opens
		its menu at the pointer: a title, then a key per item, the second of
		which, Window, has a submenu. A click on it opens the submenu beside it,
		a second popup, and a click on its second item, Snap right, reaches the
		demo two menus deep: it snaps its own window to the right half.
		*/
		if wx0, wy0, ww0, wh0, _, _, _, _, gok := wctl_frame("/mnt/0/wctl"); gok && devfs.tree().mouse.present && point_to(wx0 + ww0 / 2, wy0 + wh0 / 2) {
			_ = button_held(CLICK_MENU)
			face := fb.pack(s, fb.MAGNESIUM)
			snapped := false
			stage := 0
			// The popup is found where it opened, at the pointer, and its
			// submenu at its right edge; each item by the runs of face down
			// its column.
			px, py, pw, ph, pok := await_window_at(wx0 + ww0 / 2, wy0 + wh0 / 2)
			if pok {
				stage = 1
				if iy := await_key(s, px + 10, py, ph, face, 2, 48); iy >= 0 && point_to(px + pw / 2, iy) && click_held() {
					stage = 2
					if cx, cy, cw, ch, cok := await_window_at(px + pw, -1); cok {
						stage = 3
						if jy := await_key(s, cx + 10, cy, ch, face, 2, 12); jy >= 0 && point_to(cx + cw / 2, jy) && click_held() {
							stage = 4
							for _ in 0 ..< PATIENCE * 10 {
								if sx, _, _, _, _, _, _, _, sok := wctl_frame("/mnt/0/wctl"); sok && sx == s.width / 2 {
									snapped = true
									break
								}
								sync.delay(1)
							}
						}
					}
				}
			}
			what :: "a menu at the pointer opens its Window submenu beside it, and Snap right, two menus deep, snaps the demo right"
			if !check(r, snapped, what) {
				sink := detail_for(what)
				libodin.put_str(&sink, "reached stage ")
				libodin.put_int(&sink, i64(stage))
				libodin.put_str(&sink, " popup ")
				libodin.put_int(&sink, i64(px))
				libodin.put_str(&sink, ",")
				libodin.put_int(&sink, i64(py))
				libodin.put_str(&sink, " wide ")
				libodin.put_int(&sink, i64(pw))
				fail_detail(r, &sink)
				// A menu left standing goes, with a press on the bare desktop.
				_ = point_to(s.width - 24, s.height - 24)
				_ = click_held()
			}
			// Back where it began: a zoom after a snap restores, and only then.
			if snapped {
				_ = net_file_write("/mnt/0/wctl", "zoom")
				for _ in 0 ..< PATIENCE * 5 {
					if bx2, _, _, _, _, _, _, _, bok := wctl_frame("/mnt/0/wctl"); bok && bx2 == wx0 {
						break
					}
					sync.delay(1)
				}
			}
			/*
			The server sized the demo twice, the snap and the zoom back, and
			each time told it with an `r` line on its `mouse`, `rio`'s resize.
			The toolkit paints the new area on it: the button face is where it
			was, and not the blank ground a resize leaves a client that never
			heard.
			*/
			if snapped {
				repainted := false
				for _ in 0 ..< PATIENCE * 10 {
					if fb.get_raw(s, gx, probe_y) == magnesium {
						repainted = true
						break
					}
					sync.delay(1)
				}
				check(r, repainted, "and sized by the server and back, the demo hears the resize and paints its face again")
			}
		}


		/*
		The docked main menu, `docs/CHROME.md` brick 6b. The demo docks its tree
		as a window of the `menu` kind, which the server puts at the top left
		and shows only while the demo is in front. A window the kernel claims
		comes to the front and the dock hides. Given back, the demo is in front
		again and the dock shows. A choice made on the dock, two menus deep,
		reaches the demo as the popup's does: Snap right.
		*/
		if slot, dx, dy, dw := await_slot_at(8, 8); slot > 0 {
			pb: [64]u8
			dock := mnt_file(pb[:], slot, "/wctl")
			_, _, _, _, _, hidden0, _ := wctl_geo(dock)
			check(r, !hidden0, "the demo's main menu is docked at the top left, a menu window shown while the demo is in front")
			nb: [16]u8
			nn := read_once("/mnt/new", nb[:])
			at := 0
			other, ook := libdraw.scan_int(nb[:max(nn, 0)], &at)
			db: [64]u8
			if ook {
				if data, derr := vfs.open_path(vfs.boot_namespace, mnt_file(db[:], other, "/data"), vfs.O_WRONLY); derr == vfs.OK && data != nil {
					hid := false
					for _ in 0 ..< PATIENCE * 10 {
						if _, _, _, _, _, h, gok := wctl_geo(dock); gok && h {
							hid = true
							break
						}
						sync.delay(1)
					}
					check(r, hid, "and another program's window in front hides it")
					vfs.chan_close(data)
					shown_again := false
					for _ in 0 ..< PATIENCE * 10 {
						if _, _, _, _, _, h, gok := wctl_geo(dock); gok && !h {
							shown_again = true
							break
						}
						sync.delay(1)
					}
					check(r, shown_again, "and with that window gone the demo is in front and its menu shows again")
				}
			}
			if devfs.tree().mouse.present {
				face := fb.pack(s, fb.MAGNESIUM)
				right := false
				dstage := 0
				if iy := await_face_run(s, dx + 10, dy, face, 2); iy >= 0 && point_to(dx + 24, iy) && click_held() {
					dstage = 1
					if cx, cy, cw, ch, cok := await_window_at(dx + dw, -1); cok {
						dstage = 2
						if jy := await_key(s, cx + cw - 12, cy, ch, face, 2, 12); jy >= 0 && point_to(cx + 24, jy) && click_held() {
							dstage = 3
							for _ in 0 ..< PATIENCE * 10 {
								if sx, _, _, _, _, _, _, _, sok := wctl_frame("/mnt/0/wctl"); sok && sx == s.width / 2 {
									right = true
									break
								}
								sync.delay(1)
							}
						}
					}
				}
				dwhat :: "and Snap right chosen on the dock, two menus deep, snaps the demo right"
				if !check(r, right, dwhat) {
					sink := detail_for(dwhat)
					libodin.put_str(&sink, "reached stage ")
					libodin.put_int(&sink, i64(dstage))
					lb: [128]u8
					ln := read_once("/mnt/0/wctl", lb[:])
					libodin.put_str(&sink, "; demo ")
					libodin.put_str(&sink, string(lb[:max(ln - 1, 0)]))
					db2: [64]u8
					dn := read_once(dock, lb[:])
					_ = db2
					libodin.put_str(&sink, "; dock ")
					libodin.put_str(&sink, string(lb[:max(dn - 1, 0)]))
					fail_detail(r, &sink)
				}
				if right {
					_ = net_file_write("/mnt/0/wctl", "zoom")
				} else {
					_ = point_to(s.width - 24, s.height - 24)
					_ = click_held()
				}
			}
		} else {
			check(r, false, "the demo's main menu is docked at the top left, a menu window shown while the demo is in front")
		}

		/*
		A menu torn off, `docs/CHROME.md` brick 6c. A press on the title of the
		demo's menu at the pointer tears it off: the popup goes, and the same
		items stand in a window of the `panel` kind where it was, framed with a
		close gadget alone. A press on the bare desktop, which ends a popup,
		leaves the panel standing. A choice made on it, two menus deep, reaches
		the demo. And its close gadget's `close` takes it down.
		*/
		if devfs.tree().mouse.present {
			if wx0, wy0, ww0, wh0, _, _, _, _, gok := wctl_frame("/mnt/0/wctl"); gok && point_to(wx0 + ww0 / 2, wy0 + wh0 / 2) {
				_ = button_held(CLICK_MENU)
				tstage := 0
				tore, stood, chose := false, false, false
				if px, py, pw, _, pok := await_window_at(wx0 + ww0 / 2, wy0 + wh0 / 2); pok {
					tstage = 1
					if point_to(px + pw - 10, py + 6) && click_held() {
						tstage = 2
						if slot, tx, ty, tw := await_panel_at(px, py); slot > 0 {
							tore = true
							pb: [64]u8
							pwctl := mnt_file(pb[:], slot, "/wctl")
							_, _, _, _, tl, _, _, _, _ := wctl_frame(pwctl)
							_ = point_to(s.width - 24, s.height - 24)
							_ = click_held()
							sync.delay(PATIENCE)
							if _, _, _, _, _, hid, hok := wctl_geo(pwctl); hok && !hid {
								stood = true
							}
							face := fb.pack(s, fb.MAGNESIUM)
							if iy := await_face_run(s, tx + tw - tl - 12, ty, face, 2); iy >= 0 && point_to(tx + tl + 24, iy) && click_held() {
								tstage = 3
								if cx, cy, cw, ch, cok := await_window_at(tx + tw - tl, -1); cok {
									tstage = 4
									if jy := await_key(s, cx + cw - 12, cy, ch, face, 2, 12); jy >= 0 && point_to(cx + 24, jy) && click_held() {
										tstage = 5
										for _ in 0 ..< PATIENCE * 10 {
											if sx, _, _, _, _, _, _, _, sok := wctl_frame("/mnt/0/wctl"); sok && sx == s.width / 2 {
												chose = true
												break
											}
											sync.delay(1)
										}
									}
								}
							}
							_ = net_file_write(pwctl, "close")
						}
					}
				}
				twhat :: "a press on the menu's title tears it off: a panel with a close gadget stands where the menu was"
				if !check(r, tore, twhat) {
					sink := detail_for(twhat)
					libodin.put_str(&sink, "reached stage ")
					libodin.put_int(&sink, i64(tstage))
					fail_detail(r, &sink)
					_ = point_to(s.width - 24, s.height - 24)
					_ = click_held()
				}
				check(r, stood, "and a press on the bare desktop, which ends a popup, leaves the panel standing")
				check(r, chose, "and Snap right chosen on the panel, two menus deep, snaps the demo right")
				if chose {
					_ = net_file_write("/mnt/0/wctl", "zoom")
				}
			}
		}

		// The preferences window: a toolkit window of every role, walked
		// off the parser's own list.
		if pp := start_path(r, "/bin/prefs", "the preferences window starts"); pp != nil {
			opened := false
			// Whichever window it took: the one whose ctl says app prefs.
			search: for _ in 0 ..< PATIENCE * 20 {
				for wi in 0 ..< DRAW_SLOTS {
					pb: [128]u8
					path := mnt_file(pb[:], wi, "/ctl")
					cb: [128]u8
					pn := read_once(path, cb[:])
					if pn > 0 && libodin.contains(string(cb[:pn]), "app prefs") {
						opened = true
						break search
					}
				}
				sync.delay(5)
			}
			check(r, opened, "and opens a toolkit window of its own, the second on the glass")
			_ = notepg_kernel(pp.note_group, "kill")
			check(r, end(pp, PATIENCE * 5), "and, told to end, ends")
			finish(r, pp, "and is taken down")
			reap_orphans()
		}
	}

	// -- A relay click on a gadget --------------------------------------------

	/*
	`docs/HANDOFF.md` section 1's tracker-synthesised relay clicks: a MUI
	gadget that activates plays a short click to `/dev/audio`. It is read by
	the device's played-sample count moving when a button is clicked -- the
	same counter `verify_app` watches a tone reach. The button is the one the
	face poll already found, topmost and to the left, which is a tool and not
	the Quit that would end the demo. Skipped on a machine with no mouse or no
	card, where the click is a silent no-op by design.
	*/
	if face && devfs.tree().mouse.present && virtio.sound_present() {
		before := virtio.sound_played()
		cy := (gtop + gbot) / 2
		clicked := false
		for _ in 0 ..< 6 {
			if !point_to(gx, cy) {
				continue
			}
			if !click_held() {
				continue
			}
			for _ in 0 ..< PATIENCE * 10 {
				if virtio.sound_played() > before {
					clicked = true
					break
				}
				sync.delay(1)
			}
			if clicked {
				break
			}
		}
		check(r, clicked, "a click on a gadget plays a relay click, its samples reaching /dev/audio")
	}

	// -- A menu on button 3, the toolkit's own --------------------------------

	/*
	`docs/WORKBENCH.md` section 5: a MUI program's menu is the toolkit's `Menu`,
	a popup the program draws where a button 3 press lands. muidemo opens one
	with three items.

	Pressed low in the window, the menu spills past the bottom edge onto the
	desktop, and that is where it is read: the window's ground is slate and the
	desktop is slate, but a menu's buttons are magnesium, a colour neither has
	below the window until the menu is there. Opening is proven here, and the
	dismiss, a press on the bare desktop. Choosing an item on a popup that
	just opened is proven on Workbench's menu, `verify_workbench`, now that a
	window's mouse is a queue.
	*/
	// The window's right edge is the bar's, plus its border; the menu is read
	// in the desktop just past it, where a magnesium button stands out against
	// a slate ground neither the window nor the desktop paints magnesium on.
	// (The window's own client ground is slate too, so a menu read over the
	// window could not be told from the panel; the desktop to the right can.)
	if devfs.tree().mouse.present && bx + bw + 90 < s.width {
		px := bx + bw - 16 // just inside the right edge, so on_menu fires in the window
		py := by + 40 // below the bar, in the client area
		mx0 := bx + bw + 6 // the desktop strip just past the window's border
		mx1 := min(bx + bw + 86, s.width)
		my1 := min(py + 56, s.height)
		opened := false
		for attempt in 0 ..< 6 {
			if attempt > 0 {
				// A prior try may have left a menu standing; a press on the
				// bare desktop, far from window and menu, takes it away.
				_ = point_to(s.width - 24, s.height - 24)
				_ = click_held()
			}
			if !point_to(px, py) {
				continue
			}
			if !(inject_move(0, 0, CLICK_MENU) && wait_pointer(px, py)) {
				continue
			}
			sync.delay(MENU_HOLD)
			_ = inject_move(0, 0, 0)
			for _ in 0 ..< PATIENCE * 10 {
				if bar_has(s, mx0, py, mx1 - mx0, my1 - py, magnesium) {
					opened = true
					break
				}
				sync.delay(1)
			}
			if opened {
				break
			}
		}
		check(r, opened, "a button 3 press opens the toolkit's menu, its buttons on the desktop past the window's edge")

		if opened {
			_ = point_to(s.width - 24, s.height - 24)
			_ = click_held()
			dismissed := false
			for _ in 0 ..< PATIENCE * 10 {
				if !bar_has(s, mx0, py, mx1 - mx0, my1 - py, magnesium) {
					dismissed = true
					break
				}
				sync.delay(1)
			}
			check(r, dismissed, "and a press on the bare desktop outside it takes it away")
		}
	}

	// -- Teardown, the terminal's way -----------------------------------------

	if !check(r, srv.mount(vfs.boot_namespace, "/srv/draw", "/mnt") == vfs.OK, "the kernel mounts the server to stop it") {
		finish(r, pd, "the toolkit demo is taken down")
		finish(r, ps, "and the draw server is taken down")
		return
	}
	ctl, cerr := vfs.open_path(vfs.boot_namespace, "/mnt/0/ctl", vfs.O_RDONLY)
	if cerr == vfs.OK {
		check(r, vfs.chan_remove(ctl) == vfs.OK, "a remove of a window's ctl is the server's stop")
		vfs.chan_close(ctl)
	}
	if check(r, wait(ps, PATIENCE), "the draw server exits") {
		check(r, ps.exit.deliberate && ps.exit.status == 0, "with zero -- the remove was the stop it obeyed")
	}
	// The demo's cons and mouse are the server's files, so its reads end when
	// the server does, and it comes down on its own.
	check(r, wait(pd, PATIENCE), "and the demo comes down with the server, its files gone")
	check(r, srv.remove("draw") == vfs.OK, "the kernel takes the name away")
	check(r, srv.count() == count0, "and /srv holds what it held")

	finish(r, pd, "and the toolkit demo is reaped")
	finish(r, ps, "and the draw server is reaped")

	pipe.quiesce()
	check(r, vfs.unmount_path(vfs.boot_namespace, "", "/mnt") == vfs.OK, "the mount of the dead server comes down")
	drain_pinned(r, pin_before, "and the toolkit window's wire comes back whole")
}

/*
verify_workbench starts the desktop as `init` does and drives it: `docs/
WORKBENCH.md` step 4's five checks.

`kbdfs` on the raw keyboard, the draw server reading its `kbd` file, and
`apps/workbench` on both. The desktop's bar and backdrop are read off the
glass. Then the plan's five, in its order: a double click on `Home` opens a
drawer of the home directory, with the file `verify_kfs` leaves there as an
icon in it; `Shell` on the first menu opens a window with a shell in it,
typed at through the keyboard translator as `verify_terminal` types; the
`alt-n` chord `/lib/keys` binds opens one more, counted in the process table;
a line written to the served `notice` file comes back off `history`; and the
toast it draws is in the bar's corner.

The desktop is many short-lived threads -- a menu, a drawer, a toast each a
thread that opens and closes -- which is what tripped the reaped-thread wake
`docs/SYNC.md` records. This is the check that drives them all in one boot.
The teardown is the toolkit demo's: the server is stopped by a remove of a
window's ctl, and the desktop, its windows and their shells come down with
it, their files gone.
*/
@(private = "file")
verify_workbench :: proc(r: ^Result) #no_bounds_check {
	s := devfs.raw_surface()
	if s == nil || s.pixels == nil || s.bytes_pp != 4 || !devfs.tree().mouse.present {
		return
	}

	count0 := srv.count()
	settle()
	pin_before := mem.live_objects(mem.heap_stats())

	// -- The desktop, as init starts it -----------------------------------------

	pk := start_path(r, "/bin/kbdfs", "the loader starts the keyboard translator for the desktop")
	if pk == nil {
		return
	}
	if !check(r, await_posted("kbdfs"), "it posts /srv/kbdfs") {
		return
	}
	check(r, srv.mount(vfs.boot_namespace, "/srv/kbdfs", "/n/kbd") == vfs.OK, "the kernel mounts it at /n/kbd, as init does")

	argv := new(Argv)
	if !check(r, argv != nil, "a record for the draw server's argument") {
		return
	}
	names := [?]string{"intuition", "/n/kbd/kbd"}
	check(r, argv_from(argv, names[:]), "holds it")
	ps := start_draw_server(r, s, "the draw server starts, reading the kbd file", "it posts /srv/draw for the desktop to find", "and paints a desktop before the desktop program opens a window", argv)
	if ps == nil {
		return
	}

	// A union for the column view below: the tests' files, then the
	// desktop's. It is made before Workbench starts, so Workbench's
	// namespace, a copy of this one, holds it.
	all_bound := vfs.bind_path(vfs.boot_namespace, "/lib/tests", "/mnt/all", .Replace) == vfs.OK
	all_bound = all_bound && vfs.bind_path(vfs.boot_namespace, "/lib/wb", "/mnt/all", .After) == vfs.OK
	pw := start_path(r, "/bin/workbench", "the loader starts Workbench, as init does")
	if pw == nil {
		return
	}
	// The notice service is the desktop's last thread, and it runs after
	// the bar and the backdrop have attached their stores and painted, so
	// its post gets the patience the glass gets.
	posted_wb := false
	for _ in 0 ..< 20 {
		if await_posted("wb") {
			posted_wb = true
			break
		}
	}
	check(r, posted_wb, "it posts /srv/wb, the notice service")

	// The bar: a strip across the top of the screen, its titles amber on it.
	amber := fb.pack(s, fb.AMBER)
	copper := fb.pack(s, fb.COPPER)
	magnesium := fb.pack(s, fb.MAGNESIUM)
	titled := false
	for _ in 0 ..< PATIENCE * 20 {
		for y in 2 ..< WB_BAR_H {
			if first, _ := scan_row(s, y, amber, 0, s.width); first >= 0 {
				titled = true
				break
			}
		}
		if titled {
			break
		}
		sync.delay(1)
	}
	if !check(r, titled, "and draws its bar across the top of the screen, its wordmark amber on it") {
		return
	}

	// The backdrop's icons under it: a drawer's picture carries a copper lip,
	// and `Home` is the first cell of the grid, at the top left.
	lipped := false
	for _ in 0 ..< PATIENCE * 20 {
		for y in WB_BAR_H ..< WB_BAR_H + libmui_icon_h() {
			if first, _ := scan_row(s, y, copper, WB_DOCK_ROOM, WB_DOCK_ROOM + libmui_icon_w()); first >= 0 {
				lipped = true
				break
			}
		}
		if lipped {
			break
		}
		sync.delay(1)
	}
	check(r, lipped, "and lays the backdrop's icons under it, Home's drawer first with its copper lip")

	/*
	Workbench is up when its dock is. The dock opens last, once the notice
	service's mount is done, and a window is an ordinary one, in front,
	until its kind arrives. A check that drove the desktop before then
	raced the dock's own opening: the alt-w below, meant for a drawer, once
	closed the dock instead.
	*/
	desk_up := srv.mount(vfs.boot_namespace, "/srv/draw", "/n/desk") == vfs.OK
	docked, _, _, _ := await_slot_at(WB_DOCK_X, WB_BAR_H + WB_DOCK_Y, "/n/desk")
	check(r, desk_up && docked > 0, "and docks its main menu, the last of its windows, before anything drives it")
	if desk_up {
		_ = vfs.unmount_path(vfs.boot_namespace, "", "/n/desk")
	}

	// -- 1. A double click on Home opens a drawer ----------------------------------

	// A double click is two presses close enough in the server's own clock,
	// which the injected pair does not always land inside on the first try.
	// So the click is retried until a drawer's bar appears, a few times
	// before it is called a failure. The wait is a long one, so a drawer
	// that opens slowly is not clicked open twice.
	home_x, home_y := WB_DOCK_ROOM + libmui_icon_w() / 2, WB_BAR_H + libmui_icon_h() / 2
	check(r, point_to(home_x, home_y), "the pointer is moved onto Home")
	dx, dy, dw := -1, -1, 0
	for _ in 0 ..< 5 {
		_ = click_held()
		_ = click_held()
		if x, y, w := title_bar_within(s, PATIENCE * 6, WB_DOCK_ROOM); x >= 0 {
			dx, dy, dw = x, y, w
			break
		}
	}
	if check(r, dx >= 0, "a double click on Home opens a drawer window, its bar copper") {
		// An icon in it: the file `verify_kfs` left in the home directory is
		// a project, whose picture and name are drawn in ink, which is amber
		// on the desktop's theme. The band read is inside the window and
		// below its bar, where no frame reaches.
		inked := false
		for _ in 0 ..< PATIENCE * 20 {
			for y in dy + 24 ..< min(dy + 24 + 2 * libmui_icon_h(), s.height) {
				if first, _ := scan_row(s, y, amber, dx + 8, dx + dw - 8); first >= 0 {
					inked = true
					break
				}
			}
			if inked {
				break
			}
			sync.delay(1)
		}
		check(r, inked, "with the icons verify_kfs left in the home directory drawn in it")

		// alt-w closes the window in front, which the drawer is. The bar the
		// drawer wore goes with it.
		inject_chord(0x11) // 'w' is make 0x11
		closed := false
		for _ in 0 ..< PATIENCE * 10 {
			if _, run := row_span(s, dy, copper, 8, s.width - 8); run <= 100 {
				closed = true
				break
			}
			sync.delay(1)
		}
		check(r, closed, "and an alt-w closes the drawer, its bar gone from the glass")
	}

	// -- 2. The docked main menu, and Shell chosen on it ------------------------------

	/*
	Workbench's main menu is docked at the top left, below the bar, and the
	bar carries no menus, `docs/CHROME.md` section 8. Its `Workbench` key
	opens that submenu beside the dock, a popup with `Shell` among its items,
	and a click on that item opens a shell in a window. The click lands on a
	popup that just opened, whose reader may not have run yet.
	That used to be a race the glass could not be driven through, because
	the draw server kept one mouse line per window and the release wrote
	over the press. A window's `mouse` is a queue now, and the press waits
	for the reader. The chosen shell is closed again with an alt-w, so the
	shells the suite types at below are the ones the bound chord opens.
	*/
	// The main menu, docked at the top left below the bar, where the bar's
	// menu titles were, `docs/CHROME.md` section 8.
	// The draw server at `/n/desk` for these, `/mnt` being the notice
	// service's later: taken down again at the section's end.
	menu_mounted := srv.mount(vfs.boot_namespace, "/srv/draw", "/n/desk") == vfs.OK
	dslot, dock_x, dock_y, _ := await_slot_at(WB_DOCK_X, WB_BAR_H + WB_DOCK_Y, "/n/desk")
	shells0 := count_windows()
	menu_ok, chose := false, false
	if check(r, dslot > 0, "Workbench docks its main menu at the top left, below the bar") {
		// Up to three rounds of open-and-choose. A round that finds the popup
		// but whose click opens nothing says so on the console, with where it
		// clicked and what the glass held, and the next round starts clean.
		for round in 0 ..< 3 {
			item_x, item_y, opened := wb_menu_open(s, dock_x, dock_y, magnesium, round > 0)
			menu_ok = menu_ok || opened
			if !opened || !point_to(item_x, item_y) {
				continue
			}
			pix_before := fb.get_raw(s, item_x, item_y)
			if click_held() {
				// A window program started cold reads itself, its shell and
				// its font off the disk first, so the wait is the long one.
				for _ in 0 ..< 10 {
					if await_windows(shells0 + 1) {
						chose = true
						break
					}
				}
			}
			if chose {
				break
			}
			dbg: [256]u8
			sink := libodin.sink_from(dbg[:])
			libodin.put_str(&sink, "menu-diag: round ")
			libodin.put_int(&sink, i64(round))
			libodin.put_str(&sink, " item ")
			libodin.put_int(&sink, i64(item_x))
			libodin.put_str(&sink, ",")
			libodin.put_int(&sink, i64(item_y))
			libodin.put_str(&sink, " pix ")
			libodin.put_hex(&sink, u64(pix_before))
			libodin.put_str(&sink, " now ")
			libodin.put_hex(&sink, u64(fb.get_raw(s, item_x, item_y)))
			libodin.put_str(&sink, " windows ")
			libodin.put_int(&sink, i64(count_windows()))
			libodin.put_str(&sink, "\n")
			_ = net_file_write("/dev/cons", libodin.str(&sink))
		}
	}
	check(r, menu_ok, "the dock's Workbench key opens its submenu beside the dock, Shell its third item")
	check(r, chose, "and a click on Shell in that submenu, a popup that just opened, opens a shell in a window")
	if chose {
		// Its bar in front first, so the chord closes it and not what was
		// in front before it claimed its window.
		bx, _, _ := await_title_bar(s, WB_DOCK_ROOM)
		closed := false
		for _ in 0 ..< 3 {
			if bx < 0 {
				break
			}
			inject_chord(0x11) // 'w' is make 0x11: the chosen shell, in front, closes
			if await_windows(shells0) {
				closed = true
				break
			}
		}
		check(r, closed, "which an alt-w closes again")
	} else {
		// The menu down again, so the shells and the toast below have clear
		// glass. A press on the bare backdrop, outside the popup, closes it.
		_ = point_to(s.width / 2, s.height / 2)
		_ = click_held()
	}

	if menu_mounted {
		_ = vfs.unmount_path(vfs.boot_namespace, "", "/n/desk")
	}

	// -- 3. A shell in a window, typed at, and one more on the chord ------------------

	// The bound chord opens a shell in a window: `alt-n` runs `window rc -i`,
	// which `/lib/keys` binds. Keyboard, so no pointer race.
	inject_chord(0x31) // 'n' is make 0x31
	if check(r, await_windows(shells0 + 1), "an alt-n opens a shell in a window, one more in the process table") {
		/*
		The dock, `docs/CHROME.md` section 12. Its first tile is `rc`'s.
		Its LED lights while a window of rc's is up, off the server's
		`up rc`. It goes dark when the shells close, below.
		*/
		// The dock reads the server's report once a second, then paints.
		lit := false
		for _ in 0 ..< PATIENCE * 30 {
			if wb_tile_lit(s) {
				lit = true
				break
			}
			sync.delay(1)
		}
		check(r, lit, "and the dock's rc tile lights its LED, a window of rc's being up")
		// Its window is the one in front, its bar copper. The well below the
		// bar, and the prompt eight pixels into it.
		bx, by, bw := await_title_bar(s, WB_DOCK_ROOM)
		if check(r, bx >= 0, "the shell's window is on the glass, its bar copper") {
			slate := fb.pack(s, fb.SLATE)
			ox, oy := -1, -1
			for _ in 0 ..< PATIENCE * 10 {
				oy, _ = scan_col(s, bx + bw / 2, slate, by, s.height)
				if oy > by {
					ox, _ = scan_row(s, oy + 4, slate, 0, s.width)
					if ox >= 0 {
						break
					}
				}
				sync.delay(1)
			}
			if check(r, ox >= 0, "and a well below its bar") {
				y0 := oy + 8
				prompted, _ := await_glyph(s, ox + 8, y0, '%', PATIENCE * 10)
				check(r, prompted, "where the shell's prompt lands")
				inject_key(0x23) // 'h'
				inject_key(0x17) // 'i'
				echoed, _ := await_glyph(s, ox + 32, y0, 'i', PATIENCE * 10)
				check(r, echoed, "two keys typed through the translator are on the glass after it, as verify_terminal types")
				inject_key(0x1C) // Enter
				answered, _ := await_glyph(s, ox + 8, y0 + 32, '%', PATIENCE * 10)
				check(r, answered, "and a newline has the shell answer, and prompt again")
			}
		}
	}

	// -- Chords: any wctl word, a mode, and alt and a drag -----------------------------

	/*
	`docs/WORKBENCH.md` step 5's chords. The kernel gives the server a `home`
	and a keys file there, the shipped one and three lines more, and a
	reload reads it. A chord bound to a `wctl` word acts on the window in
	front. A mode entered by a chord takes plain keys, each acting, until
	Escape. And alt with a drag anywhere on a window moves it. The shell in
	front is the window each acts on, and each puts it back.
	*/
	// The draw server's own files, at a mount point of their own: `/mnt` holds
	// the notice service here.
	desk_mounted := srv.mount(vfs.boot_namespace, "/srv/draw", "/n/desk") == vfs.OK
	if front := front_wctl("/n/desk/"); desk_mounted && front != "" {
		keys: [4096]u8
		kn := web_read_file("/lib/keys", keys[:], raw = true)
		extra := "alt-s snap left\nmode nudge alt-r 5000\n[nudge] l move +8 +0\n"
		ktext: [4600]u8
		kt := copy(ktext[:], keys[:max(kn, 0)])
		kt += copy(ktext[kt:], extra)
		_ = env.set(ps.env, "home", "/usr/glenda")
		_ = make_disk_dir("/usr/glenda")
		_ = make_disk_dir("/usr/glenda/lib")
		kwrote := check(r, write_disk_file("/usr/glenda/lib/keys", string(ktext[:kt])), "a keys file with three chords more is written")
		if !kwrote {
			c, cerr := vfs.open_path(vfs.boot_namespace, "/usr/glenda/lib/keys", vfs.O_WRONLY)
			dbg: [160]u8
			sink := libodin.sink_from(dbg[:])
			libodin.put_str(&sink, "keys-diag: open ")
			libodin.put_str(&sink, vectra9.errno_name(cerr))
			if cerr == vfs.OK {
				libodin.put_str(&sink, " iounit ")
				libodin.put_int(&sink, i64(vfs.chan_iounit(c)))
				n, werr := vfs.chan_write(c, 0, ktext[:min(kt, 256)])
				libodin.put_str(&sink, " write ")
				libodin.put_str(&sink, vectra9.errno_name(werr))
				libodin.put_str(&sink, " n ")
				libodin.put_int(&sink, i64(n))
				vfs.chan_close(c)
			}
			libodin.put_str(&sink, "\n")
			_ = net_file_write("/dev/cons", libodin.str(&sink))
		}
		if kwrote && check(r, net_file_write("/n/desk/ctl", "reload"), "and read on a reload") {
			x0, y0, w0, h0, _, _, _ := wctl_geo(front)
			// A chord crosses kbdfs to the server on its own time, so each
			// check waits for what it names.
			inject_chord(0x1F) // 's' is make 0x1F
			check(r, await_geo(front, 0, -1, (s.width - WB_TILES_W) / 2, -1), "a chord bound to a wctl word, snap left, acts on the window in front, in the screen less the dock's strip")
			inject_chord(0x2C) // 'z' is make 0x2C: zoom puts a snapped window back
			check(r, await_geo(front, x0, y0, w0, h0), "and alt-z puts it back")

			inject_chord(0x13) // 'r' is make 0x13: into the mode
			report: [512]u8
			rn := 0
			in_mode := false
			for _ in 0 ..< PATIENCE * 5 {
				rn = read_once("/n/desk/ctl", report[:])
				if rn > 0 && libodin.contains(string(report[:rn]), "mode nudge") {
					in_mode = true
					break
				}
				sync.delay(1)
			}
			check(r, in_mode, "alt-r enters a mode, which the server's ctl names")
			for _ in 0 ..< 2 {
				devfs.scancode_tap(0x26) // 'l' down
				devfs.scancode_tap(0xA6) // and up
				sync.delay(5)
			}
			check(r, await_geo(front, x0 + 16, -1, -1, -1), "and two plain l's in it each move the window right by eight, no modifier held")
			devfs.scancode_tap(0x01) // Escape down
			devfs.scancode_tap(0x81) // and up
			sync.delay(5)
			left := false
			for _ in 0 ..< PATIENCE * 5 {
				rn = read_once("/n/desk/ctl", report[:])
				if rn > 0 && !libodin.contains(string(report[:rn]), "mode nudge") {
					left = true
					break
				}
				sync.delay(1)
			}
			check(r, left, "and Escape leaves the mode")
			_ = net_file_write(front, wctl_pair("move ", x0, y0))

			// Alt held, a press in the window's well, a drag and the release.
			cx, cy := x0 + w0 / 2, y0 + h0 / 2
			if devfs.tree().mouse.present && point_to(cx, cy) {
				devfs.scancode_tap(0x38) // alt down
				sync.delay(5)
				_ = inject_move(0, 0, 1)
				_ = wait_pointer(cx, cy)
				_ = inject_move(30, 0, 1)
				_ = wait_pointer(cx + 30, cy)
				_ = inject_move(0, 0, 0)
				_ = wait_pointer(cx + 30, cy)
				devfs.scancode_tap(0xB8) // alt up
				sync.delay(5)
				check(r, await_geo(front, x0 + 30, -1, -1, -1), "alt and a drag in the window's well moves the window, a mouse bind")
				_ = net_file_write(front, wctl_pair("move ", x0, y0))
			}
		}
		remove_file("/usr/glenda/lib/keys")
		_ = net_file_write("/n/desk/ctl", "reload")
	} else {
		check(r, false, "the draw server mounts for the chord checks, a window in front")
	}
	if desk_mounted {
		_ = vfs.unmount_path(vfs.boot_namespace, "", "/n/desk")
	}

	// One more, the bound chord again, counted in the table.
	shells1 := count_windows()
	inject_chord(0x31) // 'n' is make 0x31
	check(r, await_windows(shells1 + 1), "a second alt-n opens one more shell, counted in the process table")

	// The shells are closed the way a person closes them, an alt-w each,
	// front window first. Their count in the process table is the witness,
	// not the glass: closing the front shell leaves the other's copper bar
	// standing, so "a bar is gone" cannot tell one close from none. A window
	// `alt-w` hangs up ends when its keyboard answers nothing, so this waits
	// for the table to lose one before sending the next chord.
	start_shells := count_windows()
	chords := 0
	for count_windows() > shells0 && chords < start_shells + 4 {
		want := count_windows() - 1
		sync.delay(5) // let the last close's refocus settle before the next chord
		inject_chord(0x11) // 'w' is make 0x11
		chords += 1
		_ = await_windows(want)
	}
	if count_windows() != shells0 {
		sink := detail_for("an alt-w closes each shell window in turn, front first")
		libodin.put_str(&sink, "started ")
		libodin.put_int(&sink, i64(start_shells))
		libodin.put_str(&sink, " baseline ")
		libodin.put_int(&sink, i64(shells0))
		libodin.put_str(&sink, " chords ")
		libodin.put_int(&sink, i64(chords))
		libodin.put_str(&sink, " now ")
		libodin.put_int(&sink, i64(count_windows()))
		fail_detail(r, &sink)
	} else {
		check(r, true, "an alt-w closes each shell window in turn, front first")
	}
	dark := false
	for _ in 0 ..< PATIENCE * 30 {
		if !wb_tile_lit(s) {
			dark = true
			break
		}
		sync.delay(1)
	}
	check(r, dark, "and with the shells gone the rc tile's LED is dark again")

	/*
	The icons by the namespace, `docs/CHROME.md` section 6. With a scheme
	that names icons, a served or union directory wears a cyan emblem in its
	corner, and a plain one does not. System, `/`, is the second cell and a
	plain directory. The kernel mounted kbdfs at `/n/kbd`, so one of the
	cells after the third is a served one. The shells are closed, so the
	backdrop is bare. The chassis comes back after, and Home's copper lip.
	*/
	{
		emblem_mounted := srv.mount(vfs.boot_namespace, "/srv/draw", "/n/desk") == vfs.OK
		_ = make_disk_dir("/usr/glenda")
		_ = make_disk_dir("/usr/glenda/lib")
		emblemed, plain := false, false
		if emblem_mounted && write_disk_file("/usr/glenda/lib/theme", "use neon\n") && net_file_write("/n/desk/ctl", "reload") {
			for _ in 0 ..< PATIENCE * 20 {
				for i in 3 ..< 8 {
					if wb_corner_cyan(s, i) {
						emblemed = true
					}
				}
				if emblemed {
					plain = !wb_corner_cyan(s, 1)
					break
				}
				sync.delay(1)
			}
		}
		check(r, emblemed, "with a scheme that names icons, a served directory on the backdrop wears a cyan emblem in its corner")
		check(r, plain, "and System, a plain directory, wears none")
		remove_file("/usr/glenda/lib/theme")
		if emblem_mounted {
			_ = net_file_write("/n/desk/ctl", "reload")
			relipped := false
			for _ in 0 ..< PATIENCE * 20 {
				for y in WB_BAR_H ..< WB_BAR_H + libmui_icon_h() {
					if first, _ := scan_row(s, y, copper, WB_DOCK_ROOM, WB_DOCK_ROOM + libmui_icon_w()); first >= 0 {
						relipped = true
						break
					}
				}
				if relipped {
					break
				}
				sync.delay(1)
			}
			check(r, relipped, "and with the file gone the chassis's pictures come back, Home's copper lip")
			_ = vfs.unmount_path(vfs.boot_namespace, "", "/n/desk")
		}
	}

	/*
	The bar is status, `docs/CHROME.md` section 12's I: nine LEDs, the
	current workspace's lit. A switch to workspace 2 lights the next one
	along. That says the bar came to the workspace with it. A switch back
	lights the first again.
	*/
	{
		ws_mounted := srv.mount(vfs.boot_namespace, "/srv/draw", "/n/desk") == vfs.OK
		x1 := -1
		for _ in 0 ..< PATIENCE * 10 {
			if x1 = wb_bar_lit_x(s); x1 >= 0 {
				break
			}
			sync.delay(1)
		}
		check(r, x1 >= 0, "the bar shows the workspace as a row of LEDs, the current one lit")
		moved, back := false, false
		if ws_mounted && x1 >= 0 && net_file_write("/n/desk/ctl", "workspace 2") {
			for _ in 0 ..< PATIENCE * 10 {
				if x2 := wb_bar_lit_x(s); x2 > x1 {
					moved = true
					break
				}
				sync.delay(1)
			}
			_ = net_file_write("/n/desk/ctl", "workspace 1")
			for _ in 0 ..< PATIENCE * 10 {
				if wb_bar_lit_x(s) == x1 {
					back = true
					break
				}
				sync.delay(1)
			}
		}
		check(r, moved, "and a switch to workspace 2 lights the next, the bar coming along to it")
		check(r, back, "and a switch back lights the first again")
		if ws_mounted {
			_ = vfs.unmount_path(vfs.boot_namespace, "", "/n/desk")
		}
	}

	// -- 4. A notice, written and read back ------------------------------------------

	if check(r, srv.mount(vfs.boot_namespace, "/srv/wb", "/mnt") == vfs.OK, "the kernel mounts the notice service") {
		posted := false
		if nf, nerr := vfs.open_path(vfs.boot_namespace, "/mnt/notice", vfs.O_WRONLY); nerr == vfs.OK {
			line := "verify the suite says hello\n"
			n, werr := vfs.chan_write(nf, 0, transmute([]u8)line)
			posted = werr == vfs.OK && n == len(line)
			vfs.chan_close(nf)
		}
		check(r, posted, "a line written to notice is taken")
		kept := false
		if hf, herr := vfs.open_path(vfs.boot_namespace, "/mnt/history", vfs.O_RDONLY); herr == vfs.OK {
			buf: [2048]u8
			n, rerr := vfs.chan_read(hf, 0, buf[:])
			kept = rerr == vfs.OK && n > 0 && index_of(string(buf[:n]), "the suite says hello") >= 0
			vfs.chan_close(hf)
		}
		check(r, kept, "and comes back off history")

		// -- 5. And the toast is in the bar's corner ----------------------------------

		// A toast is a popup below the bar's right corner holding one button,
		// whose face is magnesium where the backdrop was.
		toasted := false
		for _ in 0 ..< PATIENCE * 20 {
			if first, _ := scan_row(s, WB_BAR_H + 4 + 8, magnesium, s.width / 2, s.width - WB_TILES_W); first >= 0 {
				toasted = true
				break
			}
			sync.delay(1)
		}
		check(r, toasted, "and the toast's pixels are in the bar's corner")

		/*
		The Recycler, `docs/CHROME.md` section 6. `recycle PATH` on the
		ctl is `Delete...` on a path: the file leaves its drawer for
		`$home/lib/wb/recycler`. A second of the same name takes a number
		and keeps the first. `empty` removes what the Recycler holds.
		*/
		{
			fb: [16]u8
			wrote := write_disk_file("/usr/glenda/recycle-me", "one\n")
			moved := wrote && net_file_write("/mnt/ctl", "recycle /usr/glenda/recycle-me") &&
				web_read_file("/usr/glenda/recycle-me", fb[:], raw = true) < 0 &&
				web_read_file("/usr/glenda/lib/wb/recycler/recycle-me", fb[:], raw = true) == 4
			check(r, moved, "recycle on Workbench's ctl moves a file into $home/lib/wb/recycler, out of its drawer")
			second := write_disk_file("/usr/glenda/recycle-me", "two\n") && net_file_write("/mnt/ctl", "recycle /usr/glenda/recycle-me") &&
				web_read_file("/usr/glenda/lib/wb/recycler/recycle-me.2", fb[:], raw = true) == 4 && string(fb[:4]) == "two\n" &&
				web_read_file("/usr/glenda/lib/wb/recycler/recycle-me", fb[:], raw = true) == 4 && string(fb[:4]) == "one\n"
			check(r, second, "and a second of the same name takes a number, the first kept")
			emptied := net_file_write("/mnt/ctl", "empty") &&
				web_read_file("/usr/glenda/lib/wb/recycler/recycle-me", fb[:], raw = true) < 0 &&
				web_read_file("/usr/glenda/lib/wb/recycler/recycle-me.2", fb[:], raw = true) < 0 &&
				web_read_file("/usr/glenda/lib/wb/recycler", fb[:], raw = true) >= 0
			check(r, emptied, "and empty removes what the Recycler holds, and keeps the Recycler")
		}

		/*
		The column view, `docs/CHROME.md` section 11. `columns PATH` on the
		ctl opens a drawer as columns, and `view` says what it shows. A
		column for a union lists its members' entries in bind order, the
		tests' before the desktop's, and its tag names the members. The
		status line names the server behind the folder.
		*/
		if all_bound {
			vb: [2048]u8
			vn := 0
			if net_file_write("/mnt/ctl", "columns /mnt/all") {
				for _ in 0 ..< PATIENCE * 10 {
					vn = web_read_file("/mnt/view", vb[:], raw = true)
					if vn > 0 && libodin.contains(string(vb[:vn]), "column /mnt/all") {
						break
					}
					sync.delay(1)
				}
			}
			view := string(vb[:max(vn, 0)])
			check(r, libodin.contains(view, "column /mnt/all union: /lib/tests /lib/wb"), "columns on Workbench's ctl opens a drawer as columns, and a union's column is tagged with its members")
			first, last := index_of(view, "\tfeed.rc\n"), index_of(view, "\tdock\n")
			check(r, first >= 0 && last > first, "and lists their entries in bind order, the tests' before the desktop's")
			check(r, libodin.contains(view, "status on "), "and the status line names the server behind the folder")

			/*
			The shelf and the scroller. `shelf PATH` is a drop on the
			shelf: the path is kept in `$home/lib/wb/shelf` and the view
			lists it, and `unshelf` takes it off. Four `column` choices
			from the root make five columns. That is more than the three
			that show, so the view moves along to the deepest and a
			scroller shows. `scroll 0` is the thumb dragged back to the start. The
			drawer in front is columns already, so `columns /` goes to the
			root in it, as its icon path does, and opens no window.
			*/
			sb: [256]u8
			await_view :: proc(want_s: string, vb: []u8) -> string {
				vn := 0
				for _ in 0 ..< PATIENCE * 10 {
					vn = web_read_file("/mnt/view", vb, raw = true)
					if vn > 0 && libodin.contains(string(vb[:vn]), want_s) {
						break
					}
					sync.delay(1)
				}
				return string(vb[:max(vn, 0)])
			}
			shelved := net_file_write("/mnt/ctl", "shelf /lib/tests")
			view = await_view("shelf /lib/tests\n", vb[:])
			sn := web_read_file("/usr/glenda/lib/wb/shelf", sb[:], raw = true)
			check(r, shelved && libodin.contains(view, "shelf /lib/tests\n") && sn > 0 && libodin.contains(string(sb[:sn]), "/lib/tests\n"), "shelf on Workbench's ctl keeps a path on the shelf, in $home/lib/wb/shelf")
			unshelved := net_file_write("/mnt/ctl", "unshelf /lib/tests")
			view = await_view("columns\nshown", vb[:])
			sn = web_read_file("/usr/glenda/lib/wb/shelf", sb[:], raw = true)
			check(r, unshelved && !libodin.contains(view, "shelf /lib/tests") && !libodin.contains(string(sb[:max(sn, 0)]), "/lib/tests"), "and unshelf takes it off")

			deep := net_file_write("/mnt/ctl", "columns /") && net_file_write("/mnt/ctl", "column usr") &&
				net_file_write("/mnt/ctl", "column glenda") && net_file_write("/mnt/ctl", "column lib") &&
				net_file_write("/mnt/ctl", "column wb")
			view = await_view("column /usr/glenda/lib/wb\n", vb[:])
			check(r, deep && libodin.contains(view, "shown 2 3 of 5 scroller\n"), "five columns deep, the view shows the deepest three and a scroller")
			view = net_file_write("/mnt/ctl", "scroll 0") ? await_view("shown 0 ", vb[:]) : ""
			check(r, libodin.contains(view, "shown 0 3 of 5 scroller\n"), "and scroll 0 shows the first three")
		}
		pipe.quiesce()
		check(r, vfs.unmount_path(vfs.boot_namespace, "", "/mnt") == vfs.OK, "the notice mount comes down")
	}

	// -- Teardown, the toolkit demo's way ----------------------------------------------

	if !check(r, srv.mount(vfs.boot_namespace, "/srv/draw", "/mnt") == vfs.OK, "the kernel mounts the server to stop it") {
		finish(r, pw, "the desktop is taken down")
		finish(r, ps, "and the draw server is taken down")
		finish(r, pk, "and the translator is taken down")
		return
	}
	if ctl, cerr := vfs.open_path(vfs.boot_namespace, "/mnt/0/ctl", vfs.O_RDONLY); cerr == vfs.OK {
		check(r, vfs.chan_remove(ctl) == vfs.OK, "a remove of a window's ctl is the server's stop")
		vfs.chan_close(ctl)
	}
	if check(r, wait(ps, PATIENCE), "the draw server exits") {
		check(r, ps.exit.deliberate && ps.exit.status == 0, "with zero -- the remove was the stop it obeyed")
	}
	// The desktop's windows are the server's files, so its loops end when
	// the server does, and it comes down on its own; the shells it opened
	// lose their windows the same way.
	check(r, wait(pw, PATIENCE * 10), "and the desktop comes down with the server, its files gone")
	check(r, srv.remove("draw") == vfs.OK, "the kernel takes the server's name away")
	check(r, srv.remove("wb") == vfs.OK, "and the notice service's")
	pipe.quiesce()
	_ = vfs.unmount_path(vfs.boot_namespace, "", "/mnt")

	// The draw server held the only fid on kbdfs's tree, so kbdfs's wire is
	// idle now, and a Tremove of one of its files is its stop.
	if kc, oerr := vfs.open_path(vfs.boot_namespace, "/n/kbd/cons", vfs.O_RDONLY); oerr == vfs.OK {
		check(r, vfs.chan_remove(kc) == vfs.OK, "a remove stops the keyboard translator")
		vfs.chan_close(kc)
	}
	check(r, wait(pk, PATIENCE), "the translator exits")
	check(r, srv.remove("kbdfs") == vfs.OK, "and the kernel takes its name away too")

	finish(r, pw, "and the desktop is reaped")
	finish(r, ps, "and the draw server is reaped")
	finish(r, pk, "and the translator is reaped")
	pipe.quiesce()
	_ = vfs.unmount_path(vfs.boot_namespace, "", "/n/kbd")
	if all_bound {
		_ = vfs.unmount_path(vfs.boot_namespace, "", "/mnt/all")
	}
	check(r, srv.count() == count0, "and /srv holds what it held")
	drain_pinned(r, pin_before, "and the desktop's wires come back whole")
}

// The desktop's own metrics, as `apps/workbench` and `sys/libmui` lay them:
// the bar's height and an icon cell. Written here rather than imported,
// because the kernel links neither.
WB_BAR_H :: 24
// Workbench's docked main menu: where the server puts it below the bar, and
// the room the backdrop keeps clear for it at its left, `apps/workbench`'s
// `DOCK_ROOM`.
WB_DOCK_X :: 8
WB_DOCK_Y :: 8
WB_DOCK_ROOM :: 160
// The tile dock down the right edge, `apps/workbench/tiles.odin`'s
// `TILES_W`: a `bar right` the server keeps clear.
WB_TILES_W :: 80

// wb_bar_lit_x is the column of the first lit LED on the screen bar's left
// half, the current workspace's, or -1.
wb_bar_lit_x :: proc "contextless" (s: ^fb.Surface) -> int {
	for x in 100 ..< s.width / 2 {
		for y in 2 ..< WB_BAR_H - 2 {
			v := fb.get_raw(s, x, y)
			if channel(s, v, s.green_shift, s.green_size) > 200 && channel(s, v, s.red_shift, s.red_size) < 180 {
				return x
			}
		}
	}
	return -1
}

/*
wb_tile_lit answers whether the first tile's LED, `rc`'s, is lit: a bright
green pixel in the dock's top right corner, where the tile's LED sits.
Unlit, the LED is dark in its own colour.
*/
wb_tile_lit :: proc "contextless" (s: ^fb.Surface) -> bool {
	for y in WB_BAR_H ..< WB_BAR_H + 30 {
		for x in s.width - 40 ..< s.width {
			v := fb.get_raw(s, x, y)
			if channel(s, v, s.green_shift, s.green_size) > 200 && channel(s, v, s.red_shift, s.red_size) < 180 {
				return true
			}
		}
	}
	return false
}

/*
wb_corner_cyan answers whether cell `i` of Workbench's backdrop has an
emblem's cyan in the lower right of its picture. The picture is 36 pixels
square, centred in the 96-pixel cell and 4 below the grid's top, and the
emblem sits in its lower right quarter.
*/
@(private = "file")
wb_corner_cyan :: proc "contextless" (s: ^fb.Surface, i: int) -> bool {
	x0 := WB_DOCK_ROOM + i * libmui_icon_w() + libmui_icon_w() / 2
	n := 0
	for y in WB_BAR_H + 20 ..< min(WB_BAR_H + 46, s.height) {
		for x in x0 ..< min(x0 + 24, s.width) {
			v := fb.get_raw(s, x, y)
			if channel(s, v, s.red_shift, s.red_size) < 120 && channel(s, v, s.green_shift, s.green_size) > 150 && channel(s, v, s.blue_shift, s.blue_size) > 180 {
				n += 1
			}
		}
	}
	return n >= 12
}

@(private = "file")
libmui_icon_w :: proc "contextless" () -> int {
	return 96
}

@(private = "file")
libmui_icon_h :: proc "contextless" () -> int {
	return 64
}

// name_is_window reports whether a live process is a `window` program.
@(private = "file")
name_is_window :: proc "contextless" (p: ^Process) -> bool #no_bounds_check {
	return p.live && name_ends(p.name, "window")
}

/*
count_windows counts the shell windows on the desktop -- the top-level
`window` programs, not the io procs each forks.

`window` is a `sys/libthread` program, so its io procs are forked children
that carry its name: one shell in a window shows as three `window` processes
in the table. Counting the name alone would move by three per shell and lie.
A top-level window's parent is the desktop that spawned it; an io proc's
parent is the window itself. So a `window` process whose parent is also a
`window` is an io proc and is not counted.
*/
@(private = "file")
count_windows :: proc "contextless" () -> int #no_bounds_check {
	n := 0
	for i in 0 ..< MAX_PROCESSES {
		p := &processes[i]
		if !name_is_window(p) {
			continue
		}
		parent_is_window := false
		for j in 0 ..< MAX_PROCESSES {
			q := &processes[j]
			if q.live && q.pid == p.parent && name_ends(q.name, "window") {
				parent_is_window = true
				break
			}
		}
		if !parent_is_window {
			n += 1
		}
	}
	return n
}

// await_windows waits, inside the patience, for the count of shell windows
// to be `want`, collecting orphans as it goes.
@(private = "file")
await_windows :: proc(want: int) -> bool {
	for _ in 0 ..< PATIENCE * 10 {
		if count_windows() == want {
			return true
		}
		reap_orphans()
		sync.delay(1)
	}
	return false
}

/*
button_held presses one rio button where the pointer is and releases it, a
couple of ticks apart, so the two are two packets.

It used to hold the press for more than a hundred ticks either side. The
draw server kept one mouse line per window, and a press and release a tick
apart reached a busy client as the release alone. A window's `mouse` is a
queue now, `servers/intuition/files.odin`, and a button change is never
coalesced, so a click is a click however slowly the client reads.
*/
@(private = "file")
button_held :: proc(button: u8) -> bool {
	cx, cy := mouse.position()
	if !inject_move(0, 0, button) || !wait_pointer(cx, cy) {
		return false
	}
	sync.delay(CLICK_GAP)
	if !inject_move(0, 0, 0) || !wait_pointer(cx, cy) {
		return false
	}
	return true
}

// The `inject_move` button bits are the PS/2 packet's, which the driver
// remaps to rio's: bit 0 is the left button, and bit 1 -- not bit 2 --
// decodes to rio's right, the menu button. `parse_mouse` and the driver's
// `decode` are the two halves of that mapping.
CLICK_LEFT :: u8(1)
CLICK_MENU :: u8(2)

// click_held is the left button, the plain click. `button_held(CLICK_MENU)`
// is the right, which opens a menu.
@(private = "file")
click_held :: proc() -> bool {
	return button_held(CLICK_LEFT)
}

// The ticks between an injected press and its release: enough to make them
// two packets. See `button_held`.
CLICK_GAP :: 2

// How long the menu button is held on a menu, as a person holds it: the menu
// opens on the press and chooses on the release, so the hold is what gives
// the menu time to open under the pointer. Not a workaround.
MENU_HOLD :: 120

// row_span answers the start and length of the longest span of `want`
// along row `y` between `x0` and `x1`, where a span is pixels of it fewer
// than sixteen apart. A title bar is one: its copper is broken by the
// title's letters and the gadgets, each a few pixels wide. A row of drawer
// icons is five short ones, their copper lips sixty pixels apart, which
// `scan_row`'s first-to-last cannot tell from a bar.
@(private = "file")
row_span :: proc "contextless" (s: ^fb.Surface, y: int, want: u32, x0: int, x1: int) -> (start: int, length: int) #no_bounds_check {
	start, length = -1, 0
	span_start, last := -1, -1
	for x in x0 ..< x1 {
		if fb.get_raw(s, x, y) != want {
			continue
		}
		if span_start < 0 || x - last >= 16 {
			if span_start >= 0 && last + 1 - span_start > length {
				start, length = span_start, last + 1 - span_start
			}
			span_start = x
		}
		last = x
	}
	if span_start >= 0 && last + 1 - span_start > length {
		start, length = span_start, last + 1 - span_start
	}
	return
}

// await_title_bar is `await_bar` over `row_span`: the first row, top down,
// that carries a contiguous run of copper wider than a hundred pixels,
// which is the bar of the window in front and nothing else on the desktop.
@(private = "file")
await_title_bar :: proc(s: ^fb.Surface, from := 8) -> (bx: int, by: int, bw: int) {
	copper := fb.pack(s, fb.COPPER)
	bx, by, bw = -1, -1, 0
	// A window program started cold reads itself, its shell and its font
	// off the disk before it claims a window, which is seconds, so the
	// wait is the suite's longest.
	deadline := sched.ticks() + PATIENCE * 100
	for sched.ticks() < deadline {
		bx, by, bw = title_bar(s, copper, from)
		if bx >= 0 {
			break
		}
		sync.delay(1)
	}
	return
}

// title_bar finds a window's bar on the glass now: a span of copper wider
// than a hundred pixels on a row of the top half. A bar that wide crosses
// one of the columns sampled sixty-four apart, so those are read down
// first and only a row with copper on one is measured -- a whole-glass
// read every tick is what a compositor on another core would feel. The
// search starts `from` pixels in. Workbench's checks start past the docked
// menu's corner, whose title strip is copper and as wide as a bar.
@(private = "file")
title_bar :: proc "contextless" (s: ^fb.Surface, copper: u32, from := 8) -> (bx: int, by: int, bw: int) #no_bounds_check {
	for y in 4 ..< s.height / 2 {
		hit := false
		for x := max(40, from); x < s.width - 8; x += 64 {
			if fb.get_raw(s, x, y) == copper {
				hit = true
				break
			}
		}
		if !hit {
			continue
		}
		if start, run := row_span(s, y, copper, from, s.width - 8); run > 100 {
			return start, y, run
		}
	}
	return -1, -1, 0
}

/*
wb_menu_open opens the `Workbench` submenu of Workbench's docked main menu,
`docs/CHROME.md` section 8: a click on the dock's first key, at the top left
below the bar, opens it beside the dock. Answers `Shell`'s point on it, the
third run of face down a column ten pixels in, and whether it opened. A try
after the first clicks the bare backdrop first.
*/
@(private = "file")
wb_menu_open :: proc(s: ^fb.Surface, dx: int, dy: int, magnesium: u32, reset: bool) -> (x: int, y: int, ok: bool) {
	for attempt in 0 ..< 6 {
		if attempt > 0 || reset {
			// A submenu a prior try left standing goes with a press on the
			// bare backdrop, clear of the dock and the icons.
			_ = point_to(s.width / 2, s.height / 2)
			_ = click_held()
			sync.delay(PATIENCE / 4)
		}
		// The dock's first key, `Workbench`, under its title: read down a
		// column ten pixels in, left of the labels and clear of the title's
		// tear-off gadget at its right.
		iy := await_face_run(s, dx + 10, dy, magnesium, 1)
		if iy < 0 || !point_to(dx + 24, iy) || !click_held() {
			continue
		}
		// Its submenu opens at the dock's right edge, and `Shell` is its
		// third key.
		dslot, _, _, dw := await_slot_at(dx, dy, "/n/desk")
		if dslot < 0 {
			continue
		}
		if cx, cy, _, ch, cok := await_window_at(dx + dw, -1, "/n/desk"); cok {
			if jy := await_key(s, cx + 10, cy, ch, magnesium, 3, 12); jy >= 0 {
				return cx + 24, jy, true
			}
		}
	}
	return -1, -1, false
}

// nth_face_run answers the middle row of the n-th run of `face` down column
// `x` from `y0`, or -1 when there are fewer. A run is eight rows or more,
// which a button is and a bevel line is not.
@(private = "file")
nth_face_run :: proc "contextless" (s: ^fb.Surface, x: int, y0: int, face: u32, n: int) -> int #no_bounds_check {
	runs, start := 0, -1
	for y in y0 ..< s.height {
		on := fb.get_raw(s, x, y) == face
		if on && start < 0 {
			start = y
		} else if !on && start >= 0 {
			if y - start >= 8 {
				runs += 1
				if runs == n {
					return (start + y) / 2
				}
			}
			start = -1
		}
	}
	return -1
}

// title_bar_within polls for a window's bar for `ticks`, or answers -1. The
// short-patience form the retries use, where a full `await_title_bar` per
// attempt would be minutes.
@(private = "file")
title_bar_within :: proc(s: ^fb.Surface, ticks: int, from := 8) -> (bx: int, by: int, bw: int) {
	copper := fb.pack(s, fb.COPPER)
	deadline := sched.ticks() + u64(ticks)
	for sched.ticks() < deadline {
		if x, y, w := title_bar(s, copper, from); x >= 0 {
			return x, y, w
		}
		sync.delay(1)
	}
	return -1, -1, 0
}

// amber_group answers the first column of the n-th group of `want` along
// row `y`, where a gap of twenty-four pixels or more separates groups: the
// words on the desktop's bar, each a run of letters a few pixels apart.
// -1 when there are fewer groups.
@(private = "file")
amber_group :: proc "contextless" (s: ^fb.Surface, y: int, want: u32, n: int) -> int #no_bounds_check {
	groups, start, last := 0, -1, -1
	for x in 0 ..< s.width {
		if fb.get_raw(s, x, y) != want {
			continue
		}
		if start < 0 || x - last >= 24 {
			groups += 1
			if groups == n {
				return x
			}
			start = x
		}
		last = x
	}
	return -1
}

// index_of is the position of `sub` in `s`, or -1.
@(private = "file")
index_of :: proc "contextless" (s: string, sub: string) -> int {
	if len(sub) == 0 {
		return 0
	}
	for i in 0 ..= len(s) - len(sub) {
		if s[i:i + len(sub)] == sub {
			return i
		}
	}
	return -1
}

/*
verify_app runs a `sys/libapp` client and reads its frame off the store.

The client at `path` opens a window, attaches its store, and each frame paints
its `ground`. This spawns the draw server and the client, finds the window whose
store the ground was painted into -- `open`, its store attached, and a `frame`'s
pixels -- and checks the ground reached the glass -- `present`. A client that
paints a marker at the pointer (`want_marker`) is moved over and the marker
watched to follow, on a board that has a pointer. Then the server is stopped,
which closes the window under the client so it comes down on its own. Run for
the Odin client, the C client, and a game over the one library. `docs/DEVTOOLS.md`
step 2.
*/
@(private = "file")
verify_app :: proc(r: ^Result, path: string, ground: u32, want_marker: bool, want_sound: bool) #no_bounds_check {
	s := devfs.raw_surface()
	if s == nil || s.pixels == nil || s.bytes_pp != 4 {
		return
	}
	// The pointer part of this needs a mouse; the window, the store and the
	// frame do not. So open, paint and present are checked on every board, and
	// only the marker waits on a board that has a pointer, and a client that
	// paints one.
	has_mouse := devfs.tree().mouse.present && want_marker

	count0 := srv.count()
	settle()
	pin_before := mem.live_objects(mem.heap_stats())

	ps := start_path(r, "/bin/intuition", "the loader starts the draw server for the platform layer")
	if ps == nil {
		return
	}
	if !check(r, await_posted("draw"), "which posts /srv/draw for the client to find") {
		finish(r, ps, "the draw server is taken down")
		return
	}
	if !check(r, desk_measure(s), "and paints a desktop before the client opens a window") {
		finish(r, ps, "the draw server is taken down")
		return
	}

	// The device's sample count before the client, so a client's tone reaching
	// the card is a number that moved.
	sound_before := virtio.sound_played()

	pd := start_path(r, path, "the loader starts the libapp client")
	if pd == nil {
		finish(r, ps, "the draw server is taken down")
		return
	}

	// The kernel mounts the server, to read the client's window files and to
	// stop it at the end.
	if !check(r, srv.mount(vfs.boot_namespace, "/srv/draw", "/mnt") == vfs.OK, "the kernel mounts the server") {
		finish(r, pd, "the client is taken down")
		finish(r, ps, "and the draw server is taken down")
		return
	}

	// Find the client's window. Its index is not fixed -- the server holds
	// windows of its own -- so scan for the one whose store, read straight, the
	// client has painted its ground into. That the store the file names has the
	// ground in it is the client's `open`, its store attached, and a `frame`'s
	// pixels, all in one. `shm_lookup` takes a reference the release below
	// returns; a window that is not the client's is released and passed.
	marker := u32(0x00EE_8822)
	wi := -1
	sid: u64
	stride, cx, cy, cw, ch := 0, 0, 0, 0, 0
	store: [^]u32
	scan: for _ in 0 ..< PATIENCE * 20 {
		for i in 0 ..< 8 {
			pbuf: [16]u8
			sf, se := vfs.open_path(vfs.boot_namespace, mnt_file(pbuf[:], i, "/store"), vfs.O_RDONLY)
			if se != vfs.OK {
				continue
			}
			sl: [96]u8
			sn, _ := vfs.chan_read(sf, 0, sl[:])
			vfs.chan_close(sf)
			v: [6]int
			report_numbers(sl[:sn], v[:])
			if v[0] == 0 || v[4] <= 32 || v[5] <= 32 {
				continue
			}
			phys, _, ok := shm_lookup(u64(v[0]))
			if !ok {
				continue
			}
			st := ([^]u32)(mem.phys_to_virt(phys))
			c := (v[3] + v[5] / 2) * v[1] + v[2] + v[4] / 2
			if st[c] == ground {
				wi = i
				sid = u64(v[0])
				stride, cx, cy, cw, ch = v[1], v[2], v[3], v[4], v[5]
				store = st
				break scan
			}
			shm_release(u64(v[0]))
		}
		sync.delay(1)
	}
	if !check(r, wi >= 0, "the client opens a window and paints its ground into the store, which is a frame's pixels") {
		finish(r, pd, "the client is taken down")
		finish(r, ps, "and the draw server is taken down")
		return
	}

	// The tone the client played before its window, if it plays one and the
	// board has a card: the device's sample count moved past where it was.
	if want_sound && virtio.sound_present() {
		grew := false
		for _ in 0 ..< PATIENCE * 20 {
			if virtio.sound_played() > sound_before + 4096 {
				grew = true
				break
			}
			sync.delay(1)
		}
		check(r, grew, "and its sound reached the device, samples the card took through libapp")
	}

	// And it presents: the ground reaches the glass. Where it landed is the
	// client area's origin on the screen, which the pointer is aimed at.
	ox2, oy2 := -1, -1
	for _ in 0 ..< PATIENCE * 20 {
		for col := 20; col < s.width - 20; col += 32 {
			x, y, w, h := find_rect(s, ground, col, 0)
			if x >= 0 && w > 32 && h > 32 {
				ox2, oy2 = x, y
				break
			}
		}
		if ox2 >= 0 {
			break
		}
		sync.delay(1)
	}
	check(r, ox2 >= 0, "and presents it, so the ground is on the glass")

	// The pointer into the middle of the client area, on a board that has one.
	// A window's mouse file answers in client coordinates, so a `frame` paints
	// the marker at the pointer within the client -- read back out of the store,
	// past the cursor's races on the glass.
	MARK_OFF :: 28
	// Out of the client area first, so the move into it is a real movement the
	// window hears -- a second client sits where the first left the pointer, and
	// a `point_to` that is already there injects nothing.
	if has_mouse {
		_ = point_to(s.width - 4, s.height - 4)
	}
	if has_mouse && ox2 >= 0 && check(r, point_to(ox2 + cw / 2, oy2 + ch / 2), "the pointer is moved into the client area") {
		mark_at := (cy + ch / 2 + MARK_OFF + 8) * stride + cx + cw / 2 + MARK_OFF + 8
		landed := false
		for _ in 0 ..< PATIENCE * 20 {
			if store[mark_at] == marker {
				landed = true
				break
			}
			sync.delay(1)
		}
		check(r, landed, "and a frame paints the marker where the pointer is, which the store shows")
	}

	shm_release(sid)

	// Stop the server by removing the client's window ctl, the terminal's way.
	// That hangs the client's window up, the pointer read its io thread parks on
	// ends, and the client closes and exits on its own.
	cbuf: [16]u8
	if ctl, cerr := vfs.open_path(vfs.boot_namespace, mnt_file(cbuf[:], wi, "/ctl"), vfs.O_RDONLY); cerr == vfs.OK {
		check(r, vfs.chan_remove(ctl) == vfs.OK, "a remove of the window's ctl is the server's stop")
		vfs.chan_close(ctl)
	}
	if check(r, wait(ps, PATIENCE), "the draw server exits") {
		check(r, ps.exit.deliberate && ps.exit.status == 0, "with zero -- the remove was the stop it obeyed")
	}
	check(r, wait(pd, PATIENCE), "and the client comes down with it, its window gone")

	check(r, srv.remove("draw") == vfs.OK, "the kernel takes the name away")
	check(r, srv.count() == count0, "and /srv holds what it held")

	finish(r, pd, "and the client is reaped")
	finish(r, ps, "and the draw server is reaped")

	pipe.quiesce()
	check(r, vfs.unmount_path(vfs.boot_namespace, "", "/mnt") == vfs.OK, "the mount of the dead server comes down")
	drain_pinned(r, pin_before, "and the platform layer's wire comes back whole")
}

/*
verify_tree_mmio attaches a device's register window through `#t`'s `mmio` file
and reads one register. The window model of `docs/HARDWARE.md` section 3: the
kernel synthesises `mmio` from the node's `reg`, a program `segattach`es it as
device memory, and a load reaches the hardware.

The target is the RTC on the arm64 `virt` board, `pl031@9010000`, whose id
register at `0xFE0` is the fixed `0x31` and whose reads have no side effect. A
board whose tree has no such node -- riscv64, or an x86 PC with no tree at all
-- has no `/dev/tree/pl031@9010000/mmio` to open, and this is skipped. The
register window is the same mechanism on every board; the node is this one's.
*/
@(private = "file")
verify_tree_mmio :: proc(r: ^Result) #no_bounds_check {
	PATH :: "/dev/tree/pl031@9010000/mmio"

	probe, perr := vfs.open_path(vfs.boot_namespace, PATH, vfs.O_RDONLY)
	if perr != vfs.OK {
		return // No such node on this board; the mechanism is checked where there is one.
	}
	phys, bytes, device_mem, ok := vfs.chan_device(probe)
	vfs.chan_close(probe)
	check(r, ok && device_mem, "the tree's mmio file answers a device window, not a stream")
	check(r, phys == 0x0901_0000 && bytes == 0x1000, "at the base and size the RTC node's reg names, one page")

	p := hold_blob(r, "treemmio", program_treemmio(), "a program is built to attach the window")
	if p == nil {
		return
	}
	check(r, set_bytes(p, SLOT_A, bytes_of(PATH)), "with the mmio path in its page")
	check(r, launch(p, u64(len(PATH)), 0xFE0), "and it launches, staged with the id register's offset")
	if check(r, wait(p, PATIENCE), "and comes back") {
		check(r, cell(p, CELL_MARK) == MARK_TREEMMIO, "having reached its first instruction")
		check(r, i64(cell(p, TREEMMIO_FD)) >= 0, "it opened the mmio file")
		check(r, i64(cell(p, TREEMMIO_ADDR)) >= 0, "the register window attached into its own space")
		check(
			r,
			cell(p, TREEMMIO_WORD) & 0xFF == 0x31,
			"and a load read the RTC's id register, which is the hardware reached through a mapping",
		)
	}
	finish(r, p, "and the program is taken down")
}

/*
verify_tree_irq waits for a device interrupt through `#t`'s `irq` file. The
stream model of `docs/HARDWARE.md` section 3: the kernel synthesises `irq` from
the node's `interrupts`, a program reads it to park until the line fires, and the
kernel's handler masks the line, acknowledges and wakes the reader -- the whole
handshake driven from ring 3 with nothing but a file and the register window.

The target is the same RTC as `verify_tree_mmio`, `pl031@9010000` on the arm64
`virt` board, whose alarm is the one device interrupt a self-test can raise on
demand: arm the match one tick ahead and it fires within a second. A board whose
tree has no such node -- riscv64, or an x86 PC with no tree -- has no `irq` file
to open, and this is skipped. The mechanism is the same on every board; the node
and its one-hertz clock are this one's.

The wait is its own, longer than `PATIENCE`: the RTC counts seconds, so the alarm
is up to a real second out, where every other program here answers in a
scheduler tick or two.
*/
@(private = "file")
verify_tree_irq :: proc(r: ^Result) #no_bounds_check {
	MMIO :: "/dev/tree/pl031@9010000/mmio"
	IRQ :: "/dev/tree/pl031@9010000/irq"
	IRQ_PATIENCE :: 3000 // ticks; the alarm is up to a wall-clock second out

	probe, perr := vfs.open_path(vfs.boot_namespace, IRQ, vfs.O_RDONLY)
	if perr != vfs.OK {
		return // No such node on this board; the mechanism is checked where there is one.
	}
	vfs.chan_close(probe)

	p := hold_blob(r, "treeirq", program_treeirq(), "a program is built to wait on the line")
	if p == nil {
		return
	}
	check(r, set_bytes(p, SLOT_A, bytes_of(MMIO)), "with the mmio path in its page")
	check(r, set_bytes(p, SLOT_B, bytes_of(IRQ)), "and the irq path beside it")
	check(r, launch(p, u64(len(MMIO)), u64(len(IRQ))), "and it launches, staged with both path lengths")
	if check(r, wait(p, IRQ_PATIENCE), "and comes back once the alarm has fired") {
		check(r, cell(p, CELL_MARK) == MARK_TREEIRQ, "having reached its first instruction")
		check(r, i64(cell(p, TREEIRQ_MFD)) >= 0, "it opened the mmio file to arm the alarm")
		check(r, i64(cell(p, TREEIRQ_BASE)) >= 0, "the register window attached, and the alarm is set through it")
		check(r, i64(cell(p, TREEIRQ_IFD)) >= 0, "it opened the irq file")
		check(r, i64(cell(p, TREEIRQ_READ)) > 0, "the parked read answered when the line fired, which is the interrupt reaching ring 3")
		check(r, cell(p, TREEIRQ_BYTE) == '1', "reporting one fire taken")
		check(r, cell(p, TREEIRQ_RIS) == 0, "and the source is quiet again, the interrupt serviced")
	}
	finish(r, p, "and the program is taken down")
}

/*
verify_tree_dma binds a device's stream to a program's space through `#t`'s
`dma` file, `docs/SMMU.md` section 10's ring 3 half. The program attaches the
scratch disk's slot to itself and tries every refusal the line has. Then it
leaves the slot bound and exits. The kernel checks the last close gave the
stream back: its entry reads `abort`, and no program owns it. A board
whose tree has no walker, riscv64 or a PC, has no `dma` file, and this is
skipped.
*/
@(private = "file")
verify_tree_dma :: proc(r: ^Result) #no_bounds_check {
	DMA :: "/dev/tree/pcie@10000000/dma"
	SLOT :: u32(16)

	probe, perr := vfs.open_path(vfs.boot_namespace, DMA, vfs.O_RDONLY)
	if perr != vfs.OK {
		return // No walker on this board; the mechanism is checked where there is one.
	}
	vfs.chan_close(probe)

	p := hold_blob(r, "treedma", program_treedma(), "a program is built to bind a device to itself")
	if p == nil {
		return
	}
	check(r, set_bytes(p, SLOT_A, bytes_of(DMA)), "with the dma path in its page")
	check(r, launch(p, u64(len(DMA))), "and it launches, staged with the path length")
	if check(r, wait(p, PATIENCE), "and comes back") {
		check(r, cell(p, CELL_MARK) == MARK_TREEDMA, "having reached its first instruction")
		check(r, i64(cell(p, TREEDMA_FD)) >= 0, "it opened the dma file for writing")
		check(r, i64(cell(p, TREEDMA_ATTACH)) > 0, "attach 16 <self> bound the scratch disk's stream to its own space")
		check(r, i64(cell(p, TREEDMA_AGAIN)) == -i64(vectra9.EBUSY), "a second attach of the slot is EBUSY")
		check(r, i64(cell(p, TREEDMA_OTHER)) == -i64(vectra9.EPERM), "an attach to a process that holds nothing of ours is EPERM")
		check(r, i64(cell(p, TREEDMA_PAST)) == -i64(vectra9.EINVAL), "and a slot past the map is EINVAL")
		check(r, i64(cell(p, TREEDMA_DETACH)) > 0, "detach 16 gives the slot back")
		check(r, i64(cell(p, TREEDMA_REDETACH)) == -i64(vectra9.EINVAL), "and a second detach names no binding")
		check(r, i64(cell(p, TREEDMA_LEFT)) > 0, "it attaches once more and leaves the slot bound at exit")
	}
	finish(r, p, "and the program is taken down")
	check(r, !smmu.stream_owned(SLOT), "and the last close gave the stream back")
	check(r, smmu.stream_aborted(SLOT), "with its entry reading abort, so the device faults rather than reads")
}

/*
verify_blkfs runs the disk driver that is a program, `docs/SMMU.md` section
11, and the two proofs `docs/HARDWARE.md` step 0 lists. `blkfs` attaches the
scratch disk's stream to itself and serves the disk through the walker. The
marker `docs/DISK.md` put at the DOS partition's first sector reads the same
through `blkfs` as through `#S`. `#S` answers EIO for the disk while the
program holds it, and serves it again after.

Then the proofs, through `ctl`. A transfer aimed at a page the program
never mapped is refused with
a fault line, and the device recovers. A page the program gave back is not
readable by the device. The control, `--no-invalidate`, fails the last one.
A board with no walker is skipped.
*/
@(private = "file")
verify_blkfs :: proc(r: ^Result) #no_bounds_check {
	probe, perr := vfs.open_path(vfs.boot_namespace, "/dev/tree/pcie@10000000/dma", vfs.O_RDONLY)
	if perr != vfs.OK {
		return
	}
	vfs.chan_close(probe)
	if !virtio.present(1) {
		return
	}
	ns := vfs.boot_namespace

	argv := new(Argv)
	names := [?]string{"blkfs", "2"}
	check(r, argv != nil && argv_from(argv, names[:]), "a record holds the disk driver's argument, the scratch disk's slot")
	p := start_path(r, "/bin/blkfs", "the loader starts blkfs, a disk driver that is a program", argv)
	if p == nil {
		return
	}
	posted := await_posted("blkfs")
	if !posted {
		// Each step of the bring-up has its own exit code, so the log says
		// which door was shut rather than that one was. These come before
		// the posting's own check so the first failure is the door.
		if wait(p, PATIENCE) {
			status := p.exit.status
			check(r, status != 0x74, "it found the host's memory windows in ranges, and opened mmio32 or mmio64")
			check(r, status != 0x75, "it attached the function's configuration page and mapped its three register structures")
			check(r, status != 0x76, "it attached the function's stream to itself through dma")
			check(r, status != 0x77, "it took the memory for its rings")
			check(r, status != 0x78, "and the device completed the handshake on the program's own addresses")
			check(r, status != 0x71, "and /srv/blkfs was posted")
		}
	}
	if !check(r, posted, "which brings the device up through mmio, dma and its own memory, and posts /srv/blkfs") {
		finish(r, p, "and the program is taken down")
		return
	}
	check(r, srv.mount(ns, "/srv/blkfs", "/mnt") == vfs.OK, "the kernel mounts it at /mnt")

	// -- The comparison, section 8 ------------------------------------------------------
	ctl, cerr := vfs.open_path(ns, "/mnt/sd0/ctl", vfs.O_RDWR)
	if check(r, cerr == vfs.OK && ctl != nil, "sd0/ctl opens") {
		line: [256]u8
		n, _ := vfs.chan_read(ctl, 0, line[:])
		check(r, n > 0 && libodin.contains(string(line[:n]), " sectors of 512 bytes"), "and reads the disk's geometry")
	}
	sector: [512]u8
	marker: [512]u8
	if data, derr := vfs.open_path(ns, "/mnt/sd0/data", vfs.O_RDONLY); check(r, derr == vfs.OK && data != nil, "sd0/data opens") {
		n, rerr := vfs.chan_read(data, 0, sector[:])
		check(r, rerr == vfs.OK && n == 512 && sector[510] == 0x55 && sector[511] == 0xAA, "and its first sector, read through the walker, is a partition table")
		lba := u64(libodin.get_u32le(sector[454:]))
		mn, merr := vfs.chan_read(data, lba * 512, marker[:])
		check(r, merr == vfs.OK && mn == 512 && string(marker[:12]) == "VECTRA-PART0", "and the DOS partition's first sector carries the build's marker")
		vfs.chan_close(data)
	}
	if kd, kerr := vfs.open_path(ns, "/dev/sd1/dos", vfs.O_RDONLY); check(r, kerr == vfs.OK, "#S still opens the same disk") {
		back: [512]u8
		_, rerr := vfs.chan_read(kd, 0, back[:])
		check(r, rerr == vectra9.EIO, "and answers EIO for it while the program holds its stream")
		vfs.chan_close(kd)
	}

	// -- The two proofs, section 10 -----------------------------------------------------
	if ctl != nil {
		line: [256]u8
		wn, werr := vfs.chan_write(ctl, 0, transmute([]u8)string("prove unmapped"))
		check(r, werr == vfs.OK && wn > 0, "prove unmapped: a transfer aimed at a page the program never mapped")
		n, _ := vfs.chan_read(ctl, 0, line[:])
		text := string(line[:n])
		check(r, libodin.contains(text, "fault 16 F_TRANSLATION 0x70000000"), "is refused, and the dma file names the stream, the type and the address")
		check(r, libodin.contains(text, "0x70000000 write"), "and the direction, a device write into memory it may not touch")
		check(r, libodin.contains(text, "recovered"), "and the device is reset, its queue rebuilt, and the disk reads correctly after")

		wn, werr = vfs.chan_write(ctl, 0, transmute([]u8)string("prove freed"))
		check(r, werr == vfs.OK && wn > 0, "prove freed: a sector written from a page, the page given back, the same write again")
		n, _ = vfs.chan_read(ctl, 0, line[:])
		text = string(line[:n])
		check(r, libodin.contains(text, "written, page freed at ") && libodin.contains(text, "fault 16 F_TRANSLATION"), "and the second write faults, because the walker was told when the page went")
		check(r, libodin.contains(text, " read"), "a device read of memory it was told is gone, on the dma file")
		check(r, vfs.chan_remove(ctl) == vfs.OK, "a remove is the stop")
		vfs.chan_close(ctl)
	}

	if check(r, wait(p, PATIENCE), "and the program exits") {
		check(r, p.exit.deliberate && p.exit.status == 0, "deliberately, with nothing to report")
	}
	check(r, srv.remove("blkfs") == vfs.OK, "the kernel takes the name away")
	finish(r, p, "and it is taken down")
	// The dead server's wire noticed the hangup, and its reader is leaving,
	// which the unmount and the count after want finished.
	pipe.quiesce()
	check(r, vfs.unmount_path(ns, "", "/mnt") == vfs.OK, "the mount of the dead server comes down")

	// -- After ---------------------------------------------------------------------------
	check(r, smmu.events_of(0x04) == 0, "the walker never reported a bad stream table entry")
	check(r, smmu.events_of(0x0A) == 0, "nor a bad context descriptor")
	check(r, smmu.events_of(0x02) == 0 && smmu.events_of(0x03) == 0 && smmu.events_of(0x09) == 0, "nor a bad stream id or a table it could not fetch")
	check(r, smmu.events_of(0x0B) == 0 && smmu.events_of(0x13) == 0 && smmu.events_of(0x12) == 0, "nor a walk that aborted, a permission fault or an access flag fault")
	check(r, smmu.events_of(0x10) >= 2, "and the two proofs were translation faults, one each at least")
	check(r, !smmu.broken(), "and the part is whole, a queue that overflowed on a device's retries being a record lost and not an error")
	check(r, !smmu.stream_owned(16), "the last close gave the stream back")
	if kd, kerr := vfs.open_path(ns, "/dev/sd1/dos", vfs.O_RDONLY); check(r, kerr == vfs.OK, "#S opens the disk again") {
		back: [512]u8
		n, rerr := vfs.chan_read(kd, 0, back[:])
		same := rerr == vfs.OK && n == 512 && string(back[:]) == string(marker[:])
		check(r, same, "and reads the marker sector byte for byte as the program did, the device brought up again on the kernel's rings")
		vfs.chan_close(kd)
	}
}

/*
verify_fixedseg places a run at an address a program names and refuses a second
there. `segalloc` grew an address argument for the GPU firmware, whose sections
name where in the address space they land, `docs/HARDWARE.md` section 4. A zero
is the old behaviour; a named address is a run that must go there or nowhere.
*/
@(private = "file")
verify_fixedseg :: proc(r: ^Result) #no_bounds_check {
	AT :: uintptr(0x2000_0000) // inside the mappable range, clear of image and stack

	p := hold_blob(r, "fixedseg", program_fixedseg(), "a program is built to place a run")
	if p == nil {
		return
	}
	check(r, launch(p, u64(AT)), "and it launches, asking for an address")
	if check(r, wait(p, PATIENCE), "and comes back") {
		check(r, cell(p, CELL_MARK) == MARK_FIXEDSEG, "having reached its first instruction")
		check(r, cell(p, FIXEDSEG_FIRST) == u64(AT), "segalloc placed the run at the address it named")
		check(r, cell(p, FIXEDSEG_WITNESS) == 0x1234_5678, "and the run is real, a word written into it and read back")
		check(r, i64(cell(p, FIXEDSEG_SECOND)) < 0, "and a second run at that address is refused, because the first is there")
	}
	finish(r, p, "and the program is taken down")
}

/*
verify_debugger opens the debugger's window on the debuggee and steps it
from the keyboard.

`docs/DEVTOOLS.md` step 6's line: the window opens on the debuggee, and a
chord steps it. The draw server and the engine are started as the desktop
starts them, then `debugger /bin/debuggee`, which runs the program under
the engine and opens a window on it. The window's bar is copper, as the
toolkit demo's is. The debuggee stops at its entry, which is the window's
`run`, and the kernel reads its counter from the frame it is stopped on.
An `s` typed at the window is its Step, and the counter moves one
instruction on. A `q` is its Quit, which detaches and closes the window.
The engine ends when its last client and its name are gone, and the draw
server the terminal's way.

The keys come the way `verify_chords` sends them: `kbdfs` on the raw
keyboard, the draw server reading its `kbd` file, and scancodes injected
below both. A plain key reaches the window in front through its cons.
*/
@(private = "file")
verify_debugger :: proc(r: ^Result) #no_bounds_check {
	s := devfs.raw_surface()
	if s == nil || s.pixels == nil || s.bytes_pp != 4 {
		return
	}
	count0 := srv.count()
	settle()
	pin_before := mem.live_objects(mem.heap_stats())

	pk := start_path(r, "/bin/kbdfs", "the loader starts the keyboard translator for the debugger's window")
	if pk == nil {
		return
	}
	if !check(r, await_posted("kbdfs"), "it posts /srv/kbdfs") {
		return
	}
	check(r, srv.mount(vfs.boot_namespace, "/srv/kbdfs", "/n/kbd") == vfs.OK, "the kernel mounts it at /n/kbd, as init does")

	sargv := new(Argv)
	snames := [?]string{"intuition", "/n/kbd/kbd"}
	check(r, sargv != nil && argv_from(sargv, snames[:]), "a record holds the draw server's argument")
	ps := start_draw_server(r, s, "the loader starts the draw server for the debugger's window, reading the kbd file", "which posts /srv/draw", "and paints a desktop before the window opens", sargv)
	if ps == nil {
		return
	}
	pe := start_path(r, "/bin/dbgfs", "the loader starts the debugger's engine")
	if pe == nil {
		return
	}
	if !check(r, await_posted("dbg"), "which posts /srv/dbg") {
		return
	}

	argv := new(Argv)
	names := [?]string{"debugger", "/bin/debuggee"}
	check(r, argv != nil && argv_from(argv, names[:]), "a record holds the window's arguments")
	pd := start_path(r, "/bin/debugger", "the loader starts the debugger's window on the debuggee", argv)
	if pd == nil {
		return
	}

	// The window in front wears a copper bar.
	bx, _, _ := await_bar(s)
	check(r, bx >= 0, "the window opens on the toolkit, its title bar copper")

	// The step is read from the debuggee itself, not from a panel. The
	// kernel does not mount the engine, so the window is the engine's one
	// client and its quit is what lets the engine go. The debuggee is the
	// engine's child, stopped at its `hang` door, and its counter is in the
	// frame `/proc/n/regs` would read.
	entry: uintptr
	for _ in 0 ..< PATIENCE * 20 {
		if pc, ok := debuggee_pc(); ok {
			entry = pc
			break
		}
		sync.delay(1)
	}
	check(r, entry != 0, "the window ran the program under the engine, stopped at its entry")

	// An s at the window is its Step, and the debuggee's counter moves on.
	// The key is sent again every so often, because one typed before the
	// window's reader is parked is lost, and a step by breakpoint on a port
	// is a round trip a slow machine takes its time over.
	stepped := false
	for _ in 0 ..< 40 {
		inject_key(0x1f)
		for _ in 0 ..< PATIENCE * 4 {
			if pc, ok := debuggee_pc(); ok && pc != entry {
				stepped = true
				break
			}
			sync.delay(1)
		}
		if stepped {
			break
		}
	}
	check(r, stepped, "an s typed at the window steps the program, and its counter moves one instruction on")

	// And a q is its Quit, which detaches the target and closes the window.
	inject_key(0x10)
	check(r, wait(pd, PATIENCE), "a q typed at the window is its quit, and the window comes down")

	// -- Teardown: the engine by its name, the draw server the terminal's way --

	// The window was the engine's one client. Its mount is released when it
	// is reaped, not when it exits, so it is reaped first. The name is then
	// the last stake on the engine's wire, and removing it is the hangup the
	// engine ends on, its stopped child reaped with it. This is
	// `tests/dbg.rc`'s `unmount` then `rm`, with the window's reap standing
	// in for the unmount.
	finish(r, pd, "the debugger's window is reaped, and its mount of the engine with it")
	check(r, srv.remove("dbg") == vfs.OK, "the kernel takes the engine's name away")
	check(r, wait(pe, PATIENCE), "and the engine ends when its last client and its name are gone")
	// The engine has exited but is not reaped, and its stopped child is a
	// zombie under it. Reaping the engine orphans the child, which the drain
	// below collects.
	finish(r, pe, "the engine is reaped, and its child orphaned for the drain")
	if check(r, srv.mount(vfs.boot_namespace, "/srv/draw", "/mnt") == vfs.OK, "the kernel mounts the draw server to stop it") {
		ctl, cerr := vfs.open_path(vfs.boot_namespace, "/mnt/0/ctl", vfs.O_RDONLY)
		if cerr == vfs.OK {
			check(r, vfs.chan_remove(ctl) == vfs.OK, "a remove of a window's ctl is the server's stop")
			vfs.chan_close(ctl)
		}
		check(r, wait(ps, PATIENCE), "the draw server exits")
		check(r, srv.remove("draw") == vfs.OK, "the kernel takes its name away")
	}
	pipe.quiesce()
	_ = vfs.unmount_path(vfs.boot_namespace, "", "/mnt")
	// The draw server held the only fid on kbdfs's tree, so a remove of one
	// of its files is its stop, as `verify_chords` stops it.
	if kc, oerr := vfs.open_path(vfs.boot_namespace, "/n/kbd/cons", vfs.O_RDONLY); oerr == vfs.OK {
		check(r, vfs.chan_remove(kc) == vfs.OK, "a remove stops the keyboard translator")
		vfs.chan_close(kc)
	}
	check(r, wait(pk, PATIENCE), "the translator exits")
	check(r, srv.remove("kbdfs") == vfs.OK, "the kernel takes its name away too")
	check(r, srv.count() == count0, "and /srv holds what it held")
	finish(r, ps, "the draw server is reaped")
	finish(r, pk, "and the translator is reaped")
	pipe.quiesce()
	_ = vfs.unmount_path(vfs.boot_namespace, "", "/n/kbd")
	drain_pinned(r, pin_before, "and the debugger's wires come back whole")
}

// debuggee_pc answers the counter of the debuggee the engine holds: the
// one live process named for it, stopped at its door, whose `stop_frame`
// is the frame `/proc/n/regs` reads. False while no such process is
// stopped, which is the moment between a step and the stop that follows.
@(private = "file")
debuggee_pc :: proc "contextless" () -> (uintptr, bool) {
	for i in 0 ..< MAX_PROCESSES {
		p := &processes[i]
		if !p.live || !name_ends(p.name, "debuggee") {
			continue
		}
		if !intrinsics.volatile_load(&p.stopped) || p.stop_frame == nil {
			continue
		}
		return arch.frame_ip(p.stop_frame), true
	}
	return 0, false
}

// name_ends reports whether `s` ends with `suffix`, so a process's full
// path matches its program's name.
@(private = "file")
name_ends :: proc "contextless" (s: string, suffix: string) -> bool {
	return len(s) >= len(suffix) && s[len(s) - len(suffix):] == suffix
}

// inject_key presses one key and releases it, as `inject_chord` does with
// alt held. A plain key reaches the window in front through its cons.
@(private = "file")
inject_key :: proc(make: u8) {
	devfs.scancode_tap(make)
	devfs.scancode_tap(make | 0x80)
}

@(private = "file")
verify_chords :: proc(r: ^Result) #no_bounds_check {
	count0 := srv.count()
	settle()
	pin_before := mem.live_objects(mem.heap_stats())

	// kbdfs on the raw keyboard, mounted where the draw server will read it.
	pk := start_path(r, "/bin/kbdfs", "the loader starts the keyboard translator")
	if pk == nil {
		return
	}
	if !check(r, await_posted("kbdfs"), "it posts /srv/kbdfs") {
		return
	}
	check(r, srv.mount(vfs.boot_namespace, "/srv/kbdfs", "/n/kbd") == vfs.OK, "the kernel mounts it at /n/kbd, as init does")

	// The draw server, reading `kbdfs`'s `kbd` file, which `init` names too.
	argv := new(Argv)
	if !check(r, argv != nil, "a record for the draw server's argument") {
		return
	}
	names := [?]string{"intuition", "/n/kbd/kbd"}
	check(r, argv_from(argv, names[:]), "holds it")
	ps := start_path(r, "/bin/intuition", "the draw server starts, reading the kbd file", argv)
	if ps == nil {
		return
	}
	if !check(r, await_posted("draw"), "it posts /srv/draw") {
		return
	}
	check(r, srv.mount(vfs.boot_namespace, "/srv/draw", "/mnt") == vfs.OK, "and the kernel mounts the draw server")

	// A window, which is the one in front.
	data, derr := vfs.open_path(vfs.boot_namespace, "/mnt/0/data", vfs.O_WRONLY)
	if !check(r, derr == vfs.OK, "a window is claimed, and is the one in front") {
		return
	}

	// -- alt-n reaches the desktop on hotkey ----------------------------------

	hk, herr := vfs.open_path(vfs.boot_namespace, "/mnt/hotkey", vfs.O_RDONLY)
	if check(r, herr == vfs.OK, "the hotkey file opens") {
		mount_reader = Mount_Reader{c = hk}
		if check(r, sched.spawn("hotkey-read", mount_read_thread, nil) != nil, "a thread reads it") {
			inject_chord(0x11 + 0x20) // 'n' is make 0x31
			woke := sync.await_flag(&mount_reader.done, PATIENCE)
			line := string(mount_reader.buf[:max(mount_reader.n, 0)])
			if woke && line == "window rc -i\n" {
				check(r, true, "an alt-n the server does not know reaches the desktop, verbatim")
			} else {
				// Seen once in two hundred boots, before the stale wake in
				// `kernel/sync` was fixed. A reader that never woke and one
				// that got other bytes are two different bugs, so the
				// failure says which, and what the read answered.
				sink := detail_for("an alt-n the server does not know reaches the desktop, verbatim")
				libodin.put_str(&sink, woke ? "read answered " : "the reader never woke, read so far ")
				libodin.put_int(&sink, i64(mount_reader.n))
				libodin.put_str(&sink, " bytes, errno ")
				libodin.put_int(&sink, i64(mount_reader.err))
				libodin.put_str(&sink, ": `")
				if len(line) > 0 && line[len(line) - 1] == '\n' {
					line = line[:len(line) - 1]
				}
				libodin.put_str(&sink, line)
				libodin.put_str(&sink, "`")
				fail_detail(r, &sink)
			}
		}
		vfs.chan_close(hk)
	}

	// -- alt-space opens the overview, and closes it --------------------------

	if s := devfs.raw_surface(); s != nil && s.pixels != nil && s.bytes_pp == 4 {
		// (0, 0) is the top-left of window zero's frame, a raised
		// magnesium edge. The overview dims the whole glass first, and its
		// tiles begin a margin in. So this corner falls to the void under
		// it, and comes back to the frame when the picture closes.
		frame := fb.pack(s, fb.MAGNESIUM_HOT)
		void := fb.pack(s, fb.VOID)
		inject_chord(0x39) // space is make 0x39
		dimmed := await_corner(s, void, PATIENCE)
		check(r, dimmed, "an alt-space dims the glass to the overview's ground")

		// A window dragged from one tile to another moves to that workspace,
		// the overview's half of drag and drop. Window zero is on workspace
		// one, in the first tile at its top-left; it is dragged to the second
		// tile, its workspace read off its wctl, then dragged back so the
		// close below finds it where it was.
		if devfs.tree().mouse.present {
			t1x, t1y := overview_tile_xy(1, s.width, s.height)
			t2x, t2y := overview_tile_xy(2, s.width, s.height)
			if check(r, overview_drag(t1x + 10, t1y + 10, t2x + 24, t2y + 24), "a window is dragged from its tile to another") {
				check(r, window_ws("/mnt/0/wctl") == 2, "and moves to that tile's workspace")
				_ = overview_drag(t2x + 10, t2y + 10, t1x + 10, t1y + 10)
				check(r, window_ws("/mnt/0/wctl") == 1, "and dragging it back returns it to the first")
			}
		}

		inject_chord(0x39)
		closed := await_corner(s, frame, PATIENCE)
		check(r, closed, "and a second alt-space closes it, back to the window it covered")
	}

	// -- alt-w closes the window in front -------------------------------------

	cons, cerr := vfs.open_path(vfs.boot_namespace, "/mnt/0/cons", vfs.O_RDONLY)
	if check(r, cerr == vfs.OK, "the window's keyboard opens") {
		mount_reader = Mount_Reader{c = cons}
		if check(r, sched.spawn("chord-cons", mount_read_thread, nil) != nil, "a thread reads it") {
			inject_chord(0x11) // 'w' is make 0x11
			ended := sync.await_flag(&mount_reader.done, PATIENCE)
			check(r, ended && mount_reader.n == 0, "an alt-w hangs the window in front up, and its keyboard answers nothing")
		}
		vfs.chan_close(cons)
	}
	vfs.chan_close(data)

	// -- Teardown, both servers, each by the Tremove it stops on --------------

	if ctl, oerr := vfs.open_path(vfs.boot_namespace, "/mnt/0/ctl", vfs.O_RDONLY); oerr == vfs.OK {
		check(r, vfs.chan_remove(ctl) == vfs.OK, "a remove stops the draw server")
		vfs.chan_close(ctl)
	}
	check(r, wait(ps, PATIENCE), "the draw server exits")
	check(r, srv.remove("draw") == vfs.OK, "the kernel takes its name away")
	pipe.quiesce()
	_ = vfs.unmount_path(vfs.boot_namespace, "", "/mnt")

	// The draw server held the only fid on kbdfs's tree, so kbdfs's wire is
	// idle now. A Tremove of one of its files is its stop, the way
	// `verify_kbdfs` stops it.
	if kc, oerr := vfs.open_path(vfs.boot_namespace, "/n/kbd/cons", vfs.O_RDONLY); oerr == vfs.OK {
		check(r, vfs.chan_remove(kc) == vfs.OK, "a remove stops the keyboard translator")
		vfs.chan_close(kc)
	}
	check(r, wait(pk, PATIENCE), "the translator exits")
	check(r, srv.remove("kbdfs") == vfs.OK, "the kernel takes its name away too")

	finish(r, ps, "and the draw server is taken down")
	finish(r, pk, "and the translator is taken down")
	pipe.quiesce()
	_ = vfs.unmount_path(vfs.boot_namespace, "", "/n/kbd")
	check(r, srv.count() == count0, "and /srv holds what it held")
	drain_pinned(r, pin_before, "and both servers' wires come back whole")
}

/*
inject_chord presses alt, then the key, then releases both, as the
scancodes `kbdfs` reads off `/dev/scancode`. Alt is make 0x38, and a key's
break is its make with 0x80 set.
*/
@(private = "file")
inject_chord :: proc(make: u8) {
	devfs.scancode_tap(0x38) // alt down
	devfs.scancode_tap(make) // key down
	devfs.scancode_tap(make | 0x80) // key up
	devfs.scancode_tap(0xB8) // alt up
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
	phys, bytes, _, is_device := vfs.chan_device(fbc)
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
		_, _, _, cons_device := vfs.chan_device(cc)
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

	p := hold_blob(r, "mapper", program_mapper(), "a process is loaded that asks for memory")
	if p == nil {
		return
	}
	check(r, set_bytes(p, SLOT_A, bytes_of(PATH_FB)), "with the screen's name in its page")
	check(r, set_bytes(p, SLOT_B, bytes_of(PATH_CONS)), "and a stream's name beside it")
	// Staged, and only now a thread. Launched before the staging, the mapper
	// sometimes read its page first. It opened a name not yet there, and the
	// open answered -2, one boot in fifty.
	check(r, launch(p, u64(corner)), "and it launches")

	if comes_back(r, p, "and it comes back") {
		check(r, cell(p, CELL_MARK) == MARK_MAPPER, "having reached its first instruction")
		if fdv := cell(p, MAPPER_FD); fdv < u64(MAX_FDS) {
			check(r, true, "the screen opened as an ordinary descriptor")
		} else {
			// Seen once in fifty boots with the checker's own open of the
			// screen a line above it fine; the answer says which refusal.
			sink := detail_for("the screen opened as an ordinary descriptor")
			libodin.put_str(&sink, "the open answered ")
			libodin.put_int(&sink, i64(fdv))
			fail_detail(r, &sink)
		}

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
the way to ask an empty queue whether anything was there. It is not. The
deadline flushed the request on the wire and `serve_mux`'s worker never heard
it. Each abandoned read left a worker polling a ring for ever, and the server
wedged once every slot was spent.

The cancel reaches the worker now, and `verify_consrv` abandons three reads a
boot to prove it. But a read is still a claim on the next line, and a poll
should not make one. `cons` answers its size with the bytes waiting, the way
`kbdfs` does, so the queue can be asked without being read from.
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
	And a key with no character does not reach the line.

	`Kup` is a real key this line has no use for -- a rune in Plan 9's private
	space, not text -- so it moves nothing and stores nothing. A printable rune
	past ASCII is a different thing, and the checks below store one.
	*/
	typed_runes(r, cons, "a\uF00Eb\n", "ab\n",
		"a key the line has no use for leaves nothing behind, because it is a key and not a character")

	// And a byte that cannot begin a rune is dropped rather than stored, which
	// is `chartorune` answering Runeerror and making progress.
	typed_reads(r, cons, {'a', 0x80, 'b', '\n'}, "ab\n",
		"and a byte that cannot start a rune goes the same way")

	/*
	And a printable rune past ASCII *is* stored, its UTF-8 reaching the shell
	as the bytes it is. The font reads its ranges from `/lib/font` and the
	window draws runes now, so a name with an accent typed at a prompt is no
	longer dropped for want of a glyph. `\u00E9` is U+00E9, two bytes the compiler
	encodes; the read gives them back whole.
	*/
	typed_runes(r, cons, "caf\u00E9\n", "caf\u00E9\n",
		"an accented letter is stored and read back, its UTF-8 whole")

	// The cursor steps over a multi-byte rune as one, not two: a left arrow
	// past `\u00E9` lands before it, and a character typed there goes in ahead of it.
	typed_runes(r, cons, "caf\u00E9\uF011x\n", "cafx\u00E9\n",
		"a left arrow steps over an accented letter as one rune")

	// And a backspace takes the whole rune off, both its bytes, not one.
	typed_runes(r, cons, "caf\u00E9\b\n", "caf\n",
		"a backspace takes an accented letter off whole")

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
	type_text(string(keys))
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
the way to ask an empty queue whether anything was there. It is not. The
deadline flushed the request on the wire and `serve_mux`'s worker never heard
it. Each abandoned read left a worker polling a ring for ever, and the server
wedged once every slot was spent.

The cancel reaches the worker now, and `verify_consrv` abandons three reads a
boot to prove it. But a read is still a claim on the next line, and a poll
should not make one. `cons` answers its size with the bytes waiting, the way
`kbdfs` does, so a queue can be asked without being read from.

The poll is because the delivery crosses a process. The draw server's reader
child is parked on `/dev/cons` in a process of its own, so a line typed here is
in the kernel's line discipline before it is in a window's ring, and the two
are not the same instant.
*/
@(private = "file")
typed_to :: proc(r: ^Result, want: ^vfs.Chan, other: ^vfs.Chan, text: string, what: string) #no_bounds_check {
	// The newline is what makes the kernel's line discipline hand the line
	// over. Until it lands there is nothing for any window to be given.
	type_text(text)
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
	// Where the `move` below sends the window, and a pixel inside it there.
	// Both step off the first window's right edge rather than the screen's,
	// so a narrower screen -- the `virt` boards' is 800 wide -- keeps the
	// same shape: the moved window clears the ground it stood on, covers
	// `far_x`, and gives it back when it shrinks to 200. On the 1280-wide
	// screen the test was written against these are the 700 and 1000 they
	// were as constants, and the eight pixels between 42 and a rounder step
	// are not free: the shadow sensor below lands on a desktop grid column
	// otherwise.
	far_left := fw + 42
	far_x := far_left + 300
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
	one_x := fw + 40
	lit := fb.pack(s, fb.COPPER)
	dark := fb.pack(s, fb.COPPER_DARK)
	check(
		r,
		fb.get_raw(s, one_x, bar_y) == lit && fb.get_raw(s, ox + 40, bar_y) == dark,
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
		fb.get_raw(s, ox + 40, bar_y) == lit && fb.get_raw(s, one_x, bar_y) == dark,
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
	move_cmd: [32]u8
	move_sink := libodin.sink_from(move_cmd[:])
	libodin.put_str(&move_sink, "move ")
	libodin.put_uint(&move_sink, u64(far_left))
	libodin.put_str(&move_sink, " 0\n")
	_, merr := vfs.chan_write(cfd, 0, libodin.bytes(&move_sink))
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
	And first it grows past the size its slot was born with, into a store that
	already holds it.

	**A run used to be fixed at its one `segalloc`**, so `window_size` refused
	anything taller; then `segbrk` grew it and a wider one was bought and copied.
	Neither survives a store shared with a client: a run cannot move under the
	client that maps it. So the store is bought once, at the whole screen's size,
	and a grow only moves `w`/`h` within it. The client asks without knowing: a
	`ctl` line names a client area, and the window gets bigger inside a run that
	was always big enough.

	The frames are counted across it, because the claim is now the opposite of
	what `segbrk` proved -- a grow allocates *nothing*, because the pages were
	bought at the window's birth.
	*/
	grew_from := mem.pmm_stats().free_frames

	/*
	Where this window's bottom edge is before it grows.

	**This is what a window born shorter than the glass buys.** While every
	window was as tall as the screen, the rows a grow added fell below it and
	`composite` clipped them away, so `segbrk` had a frames-dropped check and
	nothing that could see the result. The edge is on the glass now, and
	`win_bottom` walks down to it out of the window `move` put at `far_left`.
	*/
	grew_col := far_left + ox + 8
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
		mem.pmm_stats().free_frames >= grew_from,
		"and the machine is no poorer for it, because the store was bought whole at the window's birth",
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

	This is the sweep `docs/USER.md` asked for. The store is a `.Device` run,
	one piece, the whole screen's -- shared with the client that painted it two
	windows ago -- so there is no grown tail to walk here, only a run every page
	of which is mapped and owned. The sweep says stray, borrowed and short are
	all zero.

	The server is parked between requests, which is what holds it still for
	the walk. Its reader child holds none of the window runs. They are bought
	at `Tlopen` now, after the fork, and given back at the clunk with
	`segdetach`. So the child is short of nothing, and maps nothing past what
	it was given.
	*/
	swept := sweep(server)
	check(r, swept.stray == 0, "every page the server maps is inside a segment it holds")
	check(r, swept.borrowed == 0, "and every frame under one is that segment's own, the store's run included")
	check(r, swept.short == 0, "and every page of every run it holds is mapped, the store's run included")
	if reader := forked_child(server); check(r, reader != nil, "the server's reader child is in the table") {
		child_swept := sweep(reader)
		check(
			r,
			child_swept.stray == 0 && child_swept.borrowed == 0,
			"and maps only frames its own segments hold",
		)
		check(r, child_swept.short == 0, "and holds no window store at all, because those are bought after the fork")
	}

	/*
	And smaller again, into the same run.

	**A shared run cannot shrink under its client** -- the pages about to go back
	could already be somewhere in the client's kernel -- and the store is shared
	with the client that painted it. So a shrink, like a grow, moves only `w`/`h`
	within the run bought at the window's birth. The window gets smaller and the
	ground behind it comes back; the run stays whole, and the machine is no
	richer for it. Keeping the pages is not refusing the client, which is the
	distinction `window_size` makes and this checks.
	*/
	shrink_from := mem.pmm_stats().free_frames
	_, serr := vfs.chan_write(cfd, 0, bytes_of("size 200 100\n"))
	check(r, serr == vfs.OK, "and makes it smaller, within the run the store keeps whole")
	check(
		r,
		mem.pmm_stats().free_frames <= shrink_from,
		"and the machine is no richer for it, because the run stays whole under the client that holds it",
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
	wr := win_right(s, 7, far_left)
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
	`sys/libfont` -- the baked ASCII table and, past it, a `Loader` it fills
	from `/lib/font`, the same font the kernel console loads -- and stores the
	letters into memory the client cannot reach.

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
	bx, by := far_left, 0
	bw, bh := win_right(s, oy / 2, far_left) - far_left, oy
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

	/*
	And a name past ASCII draws too, out of a subfont the server loaded from
	`/lib/font` rather than the baked table. The name is nothing but accented
	letters, so a hit is a glyph the old byte-wide title path could not have
	drawn: every byte of a `é` is past the baked table's last rune, and the
	code that skipped a byte it did not know would have left the bar blank.
	*/
	_, u8err := vfs.chan_write(cfd, 0, bytes_of("name ééé\n"))
	check(r, u8err == vfs.OK, "the client names its window in runes past ASCII")
	check(
		r,
		bar_has(s, bx, by, bw, bh, ink),
		"and the bar draws them, decoded UTF-8 and loaded from a subfont",
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

// glass_has says whether any pixel of the surface is the colour.
@(private = "file")
glass_has :: proc "contextless" (s: ^fb.Surface, c: fb.RGB) -> bool {
	want := fb.pack(s, c)
	for y in 0 ..< s.height {
		if first, _ := scan_row(s, y, want, 0, s.width); first >= 0 {
			return true
		}
	}
	return false
}

// glass_has_in is glass_has within the columns `x0` to `x1`, below `y0`.
@(private = "file")
glass_has_in :: proc "contextless" (s: ^fb.Surface, c: fb.RGB, x0: int, x1: int, y0: int) -> bool {
	want := fb.pack(s, c)
	for y in max(y0, 0) ..< s.height {
		if first, _ := scan_row(s, y, want, max(x0, 0), min(x1, s.width)); first >= 0 {
			return true
		}
	}
	return false
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

	p := start_blob(r, "anon", program_anon(), "a process is loaded that asks for memory nobody serves", ANON_BYTES)
	if p == nil {
		return
	}

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
	asked := await_cell_moves(p, ANON_AGAIN, PATIENCE)
	check(r, asked, "the program asked twice and waits for the kernel's word before it grows")
	wedge, wedged := mem.alloc_page()
	check(r, wedged, "and the kernel takes the frame the allocator would have handed the grow")
	set_cell(p, ANON_GO, 1)

	// Two megabyte runs, a grow, and a fork that copies all of it: several
	// megabytes allocated, zeroed and copied, which on the slowest emulated
	// board under a busy host is more than one program's patience. The time
	// is reported, so a slowdown shows as a number before it shows as a
	// failure.
	anon_started := sched.ticks()
	anon_back := comes_back(r, p, "and it comes back", PATIENCE * 10)
	anon_ticks := int(sched.ticks() - anon_started)
	if !anon_back {
		if wedged {
			mem.free_page(wedge)
		}
		finish(r, p, "and is taken down")
		return
	}
	timing := libodin.sink_from(helper_line[:])
	libodin.put_str(&timing, "in ")
	libodin.put_uint(&timing, u64(anon_ticks))
	libodin.put_str(&timing, " ticks")
	check(r, anon_ticks < PATIENCE * 10, libodin.str(&timing))
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
	A child inherits its parent's address space and its list of runs. So the
	run it asks for after the fork has to land clear of the runs it already
	holds. `map_reserve` searches that list, so the fresh run lands in the
	first hole clear of them. It checked that before it wrote anything, and
	`ANON_CHILD_REFUSED` is that check failing.
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

	/*
	And the address the detach freed comes back to the next ask.

	The third run had a fourth just above it, and only the third went back. So
	the hole it left has a live run over it. That is what makes this a real
	test, rather than the top of the heap handed back. `map_reserve` searches
	from the bottom and finds that hole, so `ANON_REUSE` is the third run's
	address again. The bump this replaced would have stepped over the run above
	and answered higher, and this would read a different number. Both extra
	runs went back, so nothing here is left holding the address.
	*/
	check(
		r,
		uintptr(cell(p, ANON_REUSE)) == third,
		"and the next ask of that size lands back in the hole below a live run, because the search reuses it",
	)
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
	The second workspace's indicator lamp, at the middle of its jewel.

	A fixture, like the cascade above it. The draw server puts one lamp per
	workspace down the right edge, the one column two half-screen windows
	never cover. `docs/WORKBENCH.md` section 4 says what each state means. A client has no verb that would tell this
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
	lamp_cur_y := LAMP_INSET + LAMP / 2
	lamp_dark := fb.get_raw(s, lamp_x, lamp_y)
	check(
		r,
		lamp_dark != fb.pack(s, fb.PHOSPHOR),
		"the second workspace's lamp is dark, because nothing is on it",
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
		fourth, ferr := vfs.open_path(vfs.boot_namespace, "/mnt/99/data", vfs.O_WRONLY)
	check(r, ferr != vfs.OK, "and a window past the last has no name to walk to")
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

	This pixel is window zero's bar, on the bottom face row below the gadgets
	and the letters. `verify_draw` read it as `COPPER` when
	that window was the only one on the screen. Nothing has touched window zero
	since. So this is the *transition*: a bar that is no longer in front wears
	`COPPER_DARK`, the same trim one step down the same table, which is the
	lamp's dark-in-its-own-colour rule applied to a surface.

	Window one begins half a window across, so it covers none of this.
	*/
	check(
		r,
		fb.get_raw(s, ox + 8, oy - 4) == fb.pack(s, fb.COPPER_DARK),
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
		fb.get_raw(s, lamp_x, lamp_cur_y) == fb.pack(s, fb.PHOSPHOR),
		"and the current workspace's lamp is lit, in the phosphor both sides of the door read from one table",
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
		type_text("zz")
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
		/*
	And a workspace, which is a number on a window and nothing else.

	`wctl workspace 2` takes the second window off the glass, and the
	first window's pixels under it show through. That is what will happen
	when it closes below. The second workspace's lamp says something is on it now.
	A `workspace 2` line to the server's own `ctl` shows that workspace,
	with the second window's row on it and nothing else. A `workspace 1`
	line brings this one back. Every check reads the glass.
	*/
	wctl, wcerr := vfs.open_path(vfs.boot_namespace, "/mnt/1/wctl", vfs.O_RDWR)
	sctl, cerr := vfs.open_path(vfs.boot_namespace, "/mnt/ctl", vfs.O_RDWR)
	if check(r, wcerr == vfs.OK && cerr == vfs.OK, "the second window's wctl and the server's ctl open") {
		to_two := "workspace 2\n"
		_, e1 := vfs.chan_write(wctl, 0, transmute([]u8)to_two)
		check(r, e1 == vfs.OK, "a window is sent to the second workspace by a wctl line")
		check(r, fb.get_raw(s, second_ox, sy) == A2, "and leaves the glass, so the store below shows through")
		lamp_two := fb.get_raw(s, lamp_x, lamp_y)
		check(r, lamp_two != lamp_dark, "and the second workspace's lamp says something is on it")
		_, e2 := vfs.chan_write(sctl, 0, transmute([]u8)to_two)
		check(r, e2 == vfs.OK, "a workspace line to the server's ctl switches to it")
		check(r, fb.get_raw(s, second_ox, sy) == B, "and the window sent there is on the glass again")
		check(r, is_desk(s, ox, sy), "with the first window gone from it, and desktop where it was")
		check(r, fb.get_raw(s, lamp_x, lamp_y) == fb.pack(s, fb.PHOSPHOR), "and its lamp is the lit one now")
		to_one := "workspace 1\n"
		_, e3 := vfs.chan_write(sctl, 0, transmute([]u8)to_one)
		check(r, e3 == vfs.OK && fb.get_raw(s, ox, sy) == A2, "and the first workspace comes back, with its window")
		vfs.chan_close(wctl)
		vfs.chan_close(sctl)
	}

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
		check(r, fb.get_raw(s, lamp_x, lamp_y) == lamp_dark, "and the second workspace's lamp goes dark, its last window gone")
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
		fb.get_raw(s, ox + 8, oy - 4) == fb.pack(s, fb.COPPER),
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

		verify_pointer(r, s, fw, ox, oy, server)
	}

}

/*
verify_pointer is `docs/WORKBENCH.md` step 2's pointer, from the driver
to a window and back.

Every movement here is a packet injected at the 8042. It takes the
driver's whole path, becomes a line on `/dev/mouse`, and moves the draw
server's pointer. A fresh window is claimed for it, half a window across
where the cascade puts a second one.

Three claims follow, each read off the glass or a file. A read of the
window's `mouse` answers the pointer in the window's own coordinates. A
press on the bar and a drag moves the window, which `wctl` says. And a
press on the close gadget hangs the window's keyboard up and takes the
window off the glass.

A machine with no mouse -- the two `virt` boards -- has nothing to inject
into, and the block is skipped rather than failed.
*/
@(private = "file")
verify_pointer :: proc(r: ^Result, s: ^fb.Surface, fw: int, ox: int, oy: int, server: ^Process) #no_bounds_check {
	if !devfs.tree().mouse.present {
		return
	}

	// -- A window for the pointer to be over -----------------------------------

	data, derr := vfs.open_path(vfs.boot_namespace, "/mnt/1/data", vfs.O_WRONLY)
	if !check(r, derr == vfs.OK && data != nil, "a window is claimed for the pointer") {
		return
	}
	defer vfs.chan_close(data)
	second_x := fw / 2

	// -- A window's mouse file answers in the window's coordinates ---------------

	mf, merr := vfs.open_path(vfs.boot_namespace, "/mnt/1/mouse", vfs.O_RDONLY)
	if !check(r, merr == vfs.OK && mf != nil, "and its mouse file opens") {
		return
	}
	mount_reader = Mount_Reader{c = mf}
	if !check(r, sched.spawn("mouse-read", mount_read_thread, nil) != nil, "a thread to read it") {
		vfs.chan_close(mf)
		return
	}
	parked := !sync.await_flag(&mount_reader.done, 20)
	check(r, parked, "a read of it parks until the pointer moves over the window")

		check(r, point_to(second_x + ox + 10, oy + 10), "the pointer is moved into the window's client area")
	woke := sync.await_flag(&mount_reader.done, PATIENCE)
	check(r, woke, "and the read wakes")
	// The parked read caught the first movement into the window, which the
	// pointer entered part-way to its mark, because it began over this
	// window. A second read answers where it settled.
	mount_reader = Mount_Reader{c = mf}
	if sched.spawn("mouse-read2", mount_read_thread, nil) != nil {
		for _ in 0 ..< PATIENCE {
			if intrinsics.volatile_load(&mount_reader.done) {
				break
			}
			// Nudge, so the settled position is newer than the read's mark.
			cx, cy := mouse.position()
			_ = inject_move(second_x + ox + 10 - cx, oy + 10 - cy, 0)
			sync.delay(1)
		}
	}
	mx, my, _, parsed := parse_mouse(mount_reader.buf[:max(mount_reader.n, 0)])
	check(r, parsed && mx == 10 && my == 10, "carrying the pointer in the window's own coordinates, inside the frame")

	/*
	And a press in it grabs the pointer, so a drag that leaves the window is
	still the window's own.

	This is what hands a drag between windows: a file dragged out of a drawer
	and dropped on another. The pointer is pressed in this window's client,
	then dragged left out of it and over window zero -- where, with no grab,
	window zero would take the line and this window would hear nothing. The
	grab keeps it here, and the window sees the pointer outside its own bounds,
	a negative x, with the button still down. `docs/WORKBENCH.md` section 6.
	*/
	gx0, gy0 := mouse.position()
	_ = inject_move(0, 0, 1) // press button 1, beginning the grab
	_ = wait_pointer(gx0, gy0)
	_ = inject_move(-50, 0, 1) // drag left out of the window, button held
	_ = wait_pointer(gx0 - 50, gy0)
	// The window's mouse is a queue: the press comes first, then the drag.
	dragged := false
	for _ in 0 ..< MOUSE_LINES_MAX {
		dragx, _, dragb, dok := mouse_next(mf)
		if !dok {
			break
		}
		if dragb & 1 != 0 && dragx < 0 {
			dragged = true
			break
		}
	}
	check(r, dragged, "a drag out of the window is still delivered to it, the pointer past its own edge")
	_ = inject_move(0, 0, 0) // release, ending the grab
	_ = wait_pointer(gx0 - 50, gy0)

	/*
	No click is lost. A press and its release a tick apart, with no read in
	flight, both reach the window: the lines read in order hold the press
	and, next, the release. With one line kept per window the release wrote
	over the press, and a client between two reads saw no click.
	*/
	if check(r, point_to(second_x + ox + 20, oy + 20), "the pointer goes back into the window") {
		px, py := mouse.position()
		_ = inject_move(0, 0, 1)
		sync.delay(1)
		_ = inject_move(0, 0, 0)
		_ = wait_pointer(px, py)
		saw_press, saw_release := false, false
		for _ in 0 ..< MOUSE_LINES_MAX {
			_, _, b, ok := mouse_next(mf)
			if !ok {
				break
			}
			if saw_press {
				saw_release = b == 0
				break
			}
			saw_press = b & 1 != 0
		}
		check(r, saw_press && saw_release, "a press and its release a tick apart both reach the window, in order: no click is lost")
	}
	vfs.chan_close(mf)

	// -- A drag on the bar moves the window -----------------------------------------

	wctl, werr2 := vfs.open_path(vfs.boot_namespace, "/mnt/1/wctl", vfs.O_RDONLY)
	if !check(r, werr2 == vfs.OK && wctl != nil, "the window's wctl opens") {
		return
	}
	defer vfs.chan_close(wctl)
	check(r, point_to(second_x + 60, oy - 4), "the pointer is moved onto the bar")
	check(r, press_and_move(40, 24), "pressed, dragged, and released")
	moved := false
	for _ in 0 ..< PATIENCE {
		x, y, ok := wctl_place(wctl)
		if ok && x == second_x + 40 && y == 24 {
			moved = true
			break
		}
		sync.delay(1)
	}
	check(r, moved, "and the window is where the drag left it, which wctl says")

	// -- snap, minsize, maxsize and parent on wctl -------------------------------------

	/*
	`docs/WORKBENCH.md` step 5's wctl words. A snap puts the window on half the
	screen or a grid cell and a zoom puts it back where it was. A size stops
	at the window's own least and most. And a transient of window 0 comes to
	the front when window 0 does, and hides with it. The window ends where it
	began, for the close checks after.
	*/
	{
		x0, y0, w0, h0, _, _, gok := wctl_geo("/mnt/1/wctl")
		if check(r, gok, "the window's wctl reports its place and size") {
			check(r, net_file_write("/mnt/1/wctl", "snap left"), "snap left is taken")
			sx, _, sw, _, _, _, _ := wctl_geo("/mnt/1/wctl")
			check(r, sx == 0 && sw == s.width / 2, "and the window is the left half of the screen")
			check(r, net_file_write("/mnt/1/wctl", "zoom"), "zoom after a snap")
			zx, zy, zw, zh, _, _, _ := wctl_geo("/mnt/1/wctl")
			check(r, zx == x0 && zy == y0 && zw == w0 && zh == h0, "puts it back where it was")
			check(r, net_file_write("/mnt/1/wctl", "snap grid 2 2 3"), "snap grid 2 2 3 is taken")
			gx, gy, gw, _, _, _, _ := wctl_geo("/mnt/1/wctl")
			check(r, gx == s.width / 2 && gw == s.width / 2 && gy >= s.height / 2 - 1, "and the window is the grid's last cell, the bottom right")
			check(r, !net_file_write("/mnt/1/wctl", "snap grid 2 2 4"), "a cell past the grid is refused")
			_ = net_file_write("/mnt/1/wctl", "zoom")

			// The frame's own size, from a size written and the size read back.
			_ = net_file_write("/mnt/1/wctl", "size 400 300")
			_, _, w1, h1, _, _, _ := wctl_geo("/mnt/1/wctl")
			dx, dy := w1 - 400, h1 - 300
			_ = net_file_write("/mnt/1/wctl", "minsize 350 250")
			_ = net_file_write("/mnt/1/wctl", "size 100 100")
			_, _, w2, h2, _, _, _ := wctl_geo("/mnt/1/wctl")
			check(r, w2 == 350 + dx && h2 == 250 + dy, "a size under minsize stops at it")
			_ = net_file_write("/mnt/1/wctl", "minsize 0 0")
			_ = net_file_write("/mnt/1/wctl", "maxsize 360 260")
			_ = net_file_write("/mnt/1/wctl", "size 900 700")
			_, _, w3, h3, _, _, _ := wctl_geo("/mnt/1/wctl")
			check(r, w3 == 360 + dx && h3 == 260 + dy, "and a size over maxsize stops at that")
			_ = net_file_write("/mnt/1/wctl", "maxsize 0 0")
			_ = net_file_write("/mnt/1/wctl", wctl_pair("size ", w0 - dx, h0 - dy))
			_ = net_file_write("/mnt/1/wctl", wctl_pair("move ", x0, y0))

			// A transient of window 0.
			if _, _, _, _, _, _, ok0 := wctl_geo("/mnt/0/wctl"); ok0 {
				check(r, net_file_write("/mnt/1/wctl", "parent 0"), "parent 0 makes the window a transient of window 0")
				_ = net_file_write("/mnt/0/wctl", "current")
				_, _, _, _, cur, _, _ := wctl_geo("/mnt/1/wctl")
				check(r, cur, "and when window 0 comes to the front, its transient comes over it")
				_ = net_file_write("/mnt/0/wctl", "hide")
				_, _, _, _, _, hid, _ := wctl_geo("/mnt/1/wctl")
				check(r, hid, "and hides with it")
				_ = net_file_write("/mnt/0/wctl", "unhide")
				_, _, _, _, _, hid2, _ := wctl_geo("/mnt/1/wctl")
				check(r, !hid2, "and comes back with it")
				_ = net_file_write("/mnt/1/wctl", "parent -1")
				_ = net_file_write("/mnt/1/wctl", "current")
			}
			fx, fy, fw2, fh, _, _, _ := wctl_geo("/mnt/1/wctl")
			check(r, fx == x0 && fy == y0 && fw2 == w0 && fh == h0, "and the window is back where it began")
		}
	}

	// -- Rules that apply wctl words ---------------------------------------------------

	/*
	`docs/WORKBENCH.md` step 5's rules: a match and the wctl lines it applies.
	The server reads `$home/lib/workspaces`, so the kernel gives it a `home`
	and writes one there: a title pattern that snaps the window right, a
	program's first window that snaps it left, and a line in the old form,
	a name and a number, that still reads. A zoom puts the window back.
	*/
	if server != nil && server.env != nil {
		_ = env.set(server.env, "home", "/usr/glenda")
		_ = make_disk_dir("/usr/glenda")
		_ = make_disk_dir("/usr/glenda/lib")
		rx0, ry0, rw0, rh0, _, _, _ := wctl_geo("/mnt/1/wctl")
		wrote := write_disk_file("/usr/glenda/lib/workspaces", "# the self-test's rules\ntitle=rule* snap right\napp=ruletest first snap left, current\nrulewin 1\n")
		if check(r, wrote && net_file_write("/mnt/ctl", "reload"), "a rules file is written and read on a reload") {
			check(r, net_file_write("/mnt/1/ctl", "name rulewin"), "the window is named")
			tx, _, _, _, _, _, _ := wctl_geo("/mnt/1/wctl")
			check(r, tx == s.width / 2, "and a rule on a title pattern snaps it right")
			check(r, net_file_write("/mnt/1/wctl", "app ruletest"), "the window says what program it is")
			ax, _, _, _, cur, _, _ := wctl_geo("/mnt/1/wctl")
			check(r, ax == 0 && cur, "and a rule on the program's first window snaps it left and makes it current, two lines in one rule")
			_ = net_file_write("/mnt/1/wctl", "zoom")
			zx, zy, zw, zh, _, _, _ := wctl_geo("/mnt/1/wctl")
			check(r, zx == rx0 && zy == ry0 && zw == rw0 && zh == rh0, "and a zoom puts it back where it began")
		}
		remove_file("/usr/glenda/lib/workspaces")
		_ = net_file_write("/mnt/ctl", "reload")
	}

	// -- The screen lock ---------------------------------------------------------------

	/*
	`docs/WORKBENCH.md` step 5's lock. The kernel reaches factotum at
	`/n/remote`, since `/mnt` is the draw server here; the draw server mounts
	it at its own `/mnt/factotum` when it asks. `factotum` holds Glenda's key, and the
	draw server is told she is the person. `lock` covers the glass and takes
	the keys. A `q` typed while locked reaches no window, a wrong passphrase
	leaves the lock standing, and hers takes it down. Then a line typed at
	the window is `z` alone, which a `q` that got through would have led.
	*/
	if server != nil && server.env != nil {
		pf := start_path(r, "/bin/factotum", "factotum starts for the lock")
		if pf != nil && check(r, await_posted("factotum") && srv.mount(vfs.boot_namespace, "/srv/factotum", "/n/remote") == vfs.OK, "and is mounted") {
			check(r, net_file_write("/n/remote/ctl", "key proto=noise user=glenda dom=home !passphrase=open sesame"), "Glenda's key goes to factotum")
			_ = env.set(server.env, "user", "glenda")
			_ = env.set(server.env, "dom", "home")
			lcons, lerr := vfs.open_path(vfs.boot_namespace, "/mnt/1/cons", vfs.O_RDONLY)
			if check(r, lerr == vfs.OK, "the window's cons opens, a reader parked on it") {
				mount_reader = Mount_Reader{c = lcons}
				reading := sched.spawn("lock-read", mount_read_thread, nil) != nil
				check(r, net_file_write("/mnt/ctl", "lock"), "lock is taken")
				rep: [512]u8
				rn := read_once("/mnt/ctl", rep[:])
				check(r, rn > 0 && libodin.contains(string(rep[:rn]), "locked"), "and the server's ctl says locked")
				lpx := second_x + 40 + fw - 20
				lpy := 24 + oy + 40
				check(r, fb.get_raw(s, lpx, lpy) == fb.pack(s, fb.VOID), "and the window's well is gone from the glass, the lock over it")
				type_text("q")
				type_text("wrong\n")
				still := true
				for _ in 0 ..< PATIENCE * 20 {
					sync.delay(1)
				}
				rn = read_once("/mnt/ctl", rep[:])
				still = rn > 0 && libodin.contains(string(rep[:rn]), "locked")
				check(r, still, "a wrong passphrase leaves the lock standing")
				type_text("open sesame\n")
				unlocked := false
				for _ in 0 ..< PATIENCE * 100 {
					rn = read_once("/mnt/ctl", rep[:])
					if rn > 0 && !libodin.contains(string(rep[:rn]), "locked") {
						unlocked = true
						break
					}
					sync.delay(5)
				}
				check(r, unlocked, "and hers takes it down")
				got_back := false
				for _ in 0 ..< PATIENCE * 5 {
					if fb.get_raw(s, lpx, lpy) == fb.pack(s, fb.SLATE) {
						got_back = true
						break
					}
					sync.delay(1)
				}
				check(r, got_back, "and the window is back on the glass")
				type_text("z\n")
				line_ok := reading && sync.await_flag(&mount_reader.done, PATIENCE) && string(mount_reader.buf[:max(mount_reader.n, 0)]) == "z\n"
				check(r, line_ok, "and the window's next line is z alone: the q typed while locked never reached it")
				vfs.chan_close(lcons)
			}
		}
		if c, err := vfs.open_path(vfs.boot_namespace, "/n/remote/ctl", vfs.O_RDONLY); err == vfs.OK {
			_ = vfs.chan_remove(c)
			vfs.chan_close(c)
		}
		if pf != nil {
			_ = wait(pf, PATIENCE)
			finish(r, pf, "and factotum is taken down")
		}
		_ = srv.remove("factotum")
		_ = vfs.unmount_path(vfs.boot_namespace, "", "/n/remote")
	}

	// -- The close gadget asks, and a window that will not go is killed ------------------

	/*
	A window whose pointer somebody reads is asked to close, not hung up: a
	`c` line on its mouse queue, which a toolkit program answers by ending
	itself. This window's reader is the suite, which does not answer, so
	the window stays. Past the theme's `closegrace` the server lists it on
	its `ctl` as `closing`, and `kill 1` is what the desktop's `Kill`
	writes. A window nobody reads the pointer of is hung up at once, as a
	shell in a `window` is when the suite alt-w's it.
	*/
	cons, cerr := vfs.open_path(vfs.boot_namespace, "/mnt/1/cons", vfs.O_RDONLY)
	if !check(r, cerr == vfs.OK && cons != nil, "the window's cons opens") {
		return
	}
	probe_x := second_x + 40 + fw - 20
	probe_y := 24 + oy + 40
	check(r, fb.get_raw(s, probe_x, probe_y) == fb.pack(s, fb.SLATE), "the window's well is on the glass past the first window's edge")
	mf2, merr2 := vfs.open_path(vfs.boot_namespace, "/mnt/1/mouse", vfs.O_RDONLY)
	if !check(r, merr2 == vfs.OK && mf2 != nil, "its mouse opens again, so the window has a reader to ask") {
		vfs.chan_close(cons)
		return
	}
	check(r, point_to(second_x + 40 + ox + 8, 24 + oy / 2), "the pointer is moved onto the close gadget")
	check(r, press_and_move(0, 0), "and pressed")
	asked := false
	for _ in 0 ..< MOUSE_LINES_MAX {
		mount_reader = Mount_Reader{c = mf2}
		if sched.spawn("close-read", mount_read_thread, nil) == nil || !sync.await_flag(&mount_reader.done, PATIENCE) {
			break
		}
		if mount_reader.n > 0 && mount_reader.buf[0] == 'c' {
			asked = true
			break
		}
	}
	check(r, asked, "the press asks the window to close: a c line on its mouse queue")
	check(r, fb.get_raw(s, probe_x, probe_y) == fb.pack(s, fb.SLATE), "and the window stays, since its reader did not answer")
	listed := false
	report: [512]u8
	for _ in 0 ..< PATIENCE * 40 {
		n := read_once("/mnt/ctl", report[:])
		if n > 0 && libodin.contains(string(report[:n]), "closing 1 ") {
			listed = true
			break
		}
		sync.delay(10)
	}
	if !check(r, listed, "past the grace the server lists it on ctl as closing, for the desktop's Kill") {
		n := read_once("/mnt/ctl", report[:])
		_ = net_file_write("/dev/cons", "close-diag: ctl said: ")
		_ = net_file_write("/dev/cons", string(report[:max(n, 0)]))
		tb: [128]u8
		tn := read_once("/dev/time", tb[:])
		_ = net_file_write("/dev/cons", "close-diag: time: ")
		_ = net_file_write("/dev/cons", string(tb[:max(tn, 0)]))
		_ = net_file_write("/mnt/ctl", "diag")
	}
	check(r, net_file_write("/mnt/ctl", "kill 1"), "and kill 1 is taken")
	vfs.chan_close(mf2)
	mount_reader = Mount_Reader{c = cons}
	if check(r, sched.spawn("cons-read", mount_read_thread, nil) != nil, "a thread to read the keyboard") {
		ended := sync.await_flag(&mount_reader.done, PATIENCE)
		check(r, ended && mount_reader.err == vfs.OK && mount_reader.n == 0, "the keyboard answers nothing, which is how a program learns its window is gone")
	}
	check(r, is_desk(s, probe_x, probe_y), "and the window is off the glass, with the desktop where it was")
	vfs.chan_close(cons)
}

// The most lines a window's mouse ring holds, and so the most a reader
// looking for one line need take. `MOUSE_RING` in `servers/intuition`.
MOUSE_LINES_MAX :: 16

// mouse_next reads one line off a window's `mouse`, on a thread, so a read
// that would park fails the check instead of wedging the suite.
@(private = "file")
mouse_next :: proc(mf: ^vfs.Chan) -> (x: int, y: int, b: int, ok: bool) {
	// An `r` line is a resize, not a movement, and the checks here ask for
	// movements: it is read past.
	for _ in 0 ..< 8 {
		mount_reader = Mount_Reader{c = mf}
		if sched.spawn("mouse-next", mount_read_thread, nil) == nil {
			return
		}
		if !sync.await_flag(&mount_reader.done, PATIENCE) {
			return
		}
		if mount_reader.n > 0 && mount_reader.buf[0] == 'r' {
			continue
		}
		return parse_mouse(mount_reader.buf[:max(mount_reader.n, 0)])
	}
	return
}

// point_to moves the pointer to a screen position by injected packets,
// waiting for the driver to take each. False when the controller refused
// a packet or the driver did not follow.
@(private = "file")
point_to :: proc(x: int, y: int) -> bool {
	for _ in 0 ..< 64 {
		cx, cy := mouse.position()
		if cx == x && cy == y {
			return true
		}
		dx := clamp(x - cx, -127, 127)
		dy := clamp(y - cy, -127, 127)
		if !inject_move(dx, dy, 0) {
			return false
		}
		if !wait_pointer(cx + dx, cy + dy) {
			return false
		}
	}
	return false
}

// press_and_move presses the left button, moves by (dx, dy) with it held,
// and releases, as three packets.
@(private = "file")
press_and_move :: proc(dx: int, dy: int) -> bool {
	cx, cy := mouse.position()
	if !inject_move(0, 0, 1) || !wait_pointer(cx, cy) {
		return false
	}
	if !inject_move(dx, dy, 1) || !wait_pointer(cx + dx, cy + dy) {
		return false
	}
	sync.delay(2)
	return inject_move(0, 0, 0) && wait_pointer(cx + dx, cy + dy)
}

// overview_tile_xy is where workspace `ws`'s tile sits on the glass, the same
// arithmetic `servers/intuition/overview.odin`'s `tile_rect` does -- three by
// three, scaled by three -- so a check can press inside one.
@(private = "file")
overview_tile_xy :: proc "contextless" (ws: int, w: int, h: int) -> (x: int, y: int) {
	col := (ws - 1) % 3
	row := (ws - 1) / 3
	gap := (w / 3) / 16
	cw := (w - 4 * gap) / 3
	ch := (h - 4 * gap) / 3
	return gap + col * (cw + gap), gap + row * (ch + gap)
}

// overview_drag presses at one point, steps to another with the button held,
// and releases: a window dragged between overview tiles. Stepped like
// `point_to`, so a long drag stays inside a packet's reach per move.
@(private = "file")
overview_drag :: proc(fromx: int, fromy: int, tox: int, toy: int) -> bool {
	if !point_to(fromx, fromy) {
		return false
	}
	cx, cy := mouse.position()
	if !inject_move(0, 0, 1) || !wait_pointer(cx, cy) {
		return false
	}
	for _ in 0 ..< 128 {
		px, py := mouse.position()
		if px == tox && py == toy {
			break
		}
		dx := clamp(tox - px, -120, 120)
		dy := clamp(toy - py, -120, 120)
		if !inject_move(dx, dy, 1) || !wait_pointer(px + dx, py + dy) {
			return false
		}
	}
	return inject_move(0, 0, 0) && wait_pointer(tox, toy)
}

// window_ws reads a window's wctl and answers the workspace it reports, the
// last of the numbers in `x y w h current visible N`.
@(private = "file")
window_ws :: proc(path: string) -> int {
	fd, err := vfs.open_path(vfs.boot_namespace, path, vfs.O_RDONLY)
	if err != vfs.OK {
		return -1
	}
	defer vfs.chan_close(fd)
	buf: [96]u8
	n, _ := vfs.chan_read(fd, 0, buf[:])
	nums: [5]int
	report_numbers(buf[:max(n, 0)], nums[:])
	return nums[4]
}

// inject_move is one packet: the movement in screen terms, the buttons as
// the PS/2 packet carries them: bit 0 the left, bit 1 the right, bit 2 the
// middle. The driver renumbers them as rio does. The mouse counts Y up, so the sign is turned over here.
@(private = "file")
inject_move :: proc(dx: int, dy: int, buttons: u8) -> bool {
	my := -dy
	flags := u8(0x08) | (buttons & 7)
	if dx < 0 {
		flags |= 0x10
	}
	if my < 0 {
		flags |= 0x20
	}
	// Delivered straight to the driver's fifo on every board -- the mouse's
	// `scancode_tap`. The 8042 second-port routing is proven separately by the
	// driver's own `verify_interrupt`, so the desktop's pointer checks need
	// only the movement, not a controller to run on.
	mouse.feed_packet(flags, u8(dx & 0xFF), u8(my & 0xFF))
	return true
}

// wait_pointer waits for the driver's position to be (x, y), inside the
// patience.
@(private = "file")
wait_pointer :: proc(x: int, y: int) -> bool {
	for _ in 0 ..< PATIENCE {
		cx, cy := mouse.position()
		if cx == x && cy == y {
			sync.delay(2)
			return true
		}
		sync.delay(1)
	}
	return false
}

// parse_mouse reads the three numbers after the `m` of a mouse line.
@(private = "file")
parse_mouse :: proc "contextless" (line: []u8) -> (x: int, y: int, b: int, ok: bool) {
	if len(line) < 2 || line[0] != 'm' {
		return
	}
	at := 1
	x, ok = libdraw.scan_int(line, &at)
	if !ok {
		return
	}
	y, ok = libdraw.scan_int(line, &at)
	if !ok {
		return
	}
	b, ok = libdraw.scan_int(line, &at)
	return
}

// front_wctl names the wctl of the window in front, the one whose report says
// `current`, or "".
@(private = "file") front_wctl_buf: [32]u8

@(private = "file")
front_wctl :: proc(base: string) -> string {
	for i in 0 ..< DRAW_SLOTS {
		sink := libodin.sink_from(front_wctl_buf[:])
		libodin.put_str(&sink, base)
		libodin.put_int(&sink, i64(i))
		libodin.put_str(&sink, "/wctl")
		path := libodin.str(&sink)
		if _, _, _, _, cur, hid, ok := wctl_geo(path); ok && cur && !hid {
			return path
		}
	}
	return ""
}

// await_geo waits for a window's wctl report to say a place or size; -1 is
// any. For a change that crosses another process first: a chord, a drag.
@(private = "file")
await_geo :: proc(path: string, x: int, y: int, w: int, h: int) -> bool {
	for _ in 0 ..< PATIENCE * 5 {
		gx, gy, gw, gh, _, _, ok := wctl_geo(path)
		if ok && (x < 0 || gx == x) && (y < 0 || gy == y) && (w < 0 || gw == w) && (h < 0 || gh == h) {
			return true
		}
		sync.delay(1)
	}
	return false
}

// wctl_pair is a wctl line of a verb and two numbers, in a buffer of its own.
@(private = "file") wctl_pair_buf: [64]u8

@(private = "file")
wctl_pair :: proc(verb: string, a: int, b: int) -> string {
	sink := libodin.sink_from(wctl_pair_buf[:])
	libodin.put_str(&sink, verb)
	libodin.put_int(&sink, i64(a))
	libodin.put_str(&sink, " ")
	libodin.put_int(&sink, i64(b))
	return libodin.str(&sink)
}

// wctl_geo reads a window's wctl report: its place and size, whether it is
// the current window, and whether it is hidden.
@(private = "file")
wctl_geo :: proc(path: string) -> (x: int, y: int, w: int, h: int, current: bool, hidden: bool, ok: bool) {
	line: [128]u8
	n := read_once(path, line[:])
	if n <= 0 {
		return
	}
	text := string(line[:n])
	at := 0
	ok1, ok2, ok3, ok4: bool
	x, ok1 = libdraw.scan_int(line[:n], &at)
	y, ok2 = libdraw.scan_int(line[:n], &at)
	w, ok3 = libdraw.scan_int(line[:n], &at)
	h, ok4 = libdraw.scan_int(line[:n], &at)
	current = libodin.contains(text, " current")
	hidden = libodin.contains(text, " hidden")
	ok = ok1 && ok2 && ok3 && ok4
	return
}

// between_px reports whether each channel of `v` lies between the same
// channel of `a` and `b`: a pixel blended from the two.
between_px :: proc "contextless" (v: u32, a: u32, b: u32) -> bool {
	for shift in ([3]uint{16, 8, 0}) {
		x, lo, hi := int(v >> shift & 0xFF), int(a >> shift & 0xFF), int(b >> shift & 0xFF)
		if x < min(lo, hi) || x > max(lo, hi) {
			return false
		}
	}
	return true
}

// await_panel_at waits for a framed window shown with its corner at (x, y), a
// torn-off panel where the menu it came from stood, and answers its slot, x, y
// and width, or a slot of -1. The dead popup's slot still answers at the same
// place, unframed and hidden, which is why the frame and the showing are asked.
await_panel_at :: proc(x: int, y: int) -> (slot: int, fx: int, fy: int, fw: int) {
	for _ in 0 ..< PATIENCE * 10 {
		for wi in 1 ..< DRAW_SLOTS {
			pb: [64]u8
			path := mnt_file(pb[:], wi, "/wctl")
			wx, wy, ww, _, l, _, _, _, wok := wctl_frame(path)
			if !wok || wx != x || wy != y || l <= 0 {
				continue
			}
			if _, _, _, _, _, hid, hok := wctl_geo(path); hok && !hid {
				return wi, wx, wy, ww
			}
		}
		sync.delay(1)
	}
	return -1, 0, 0, 0
}

// await_slot_at waits for a window whose corner is at (x, y) and answers its
// slot, its corner and its width, or a slot of -1.
await_slot_at :: proc(x: int, y: int, base := "/mnt") -> (slot: int, fx: int, fy: int, fw: int) {
	for _ in 0 ..< PATIENCE * 10 {
		for wi in 1 ..< DRAW_SLOTS {
			pb: [64]u8
			if wx, wy, ww, _, _, _, _, _, wok := wctl_frame(mnt_file(pb[:], wi, "/wctl", base)); wok && wx == x && wy == y && ww > 0 {
				return wi, wx, wy, ww
			}
		}
		sync.delay(1)
	}
	return -1, 0, 0, 0
}

// await_window_at waits for a window whose corner is at (x, y), a y below
// zero matching any, across the slots past window 0, and answers its place
// and size. A slot nobody holds still answers its `wctl`, with the geometry a
// window there would be born with, so a popup is found by where its program
// put it and not by its number.
await_window_at :: proc(x: int, y: int, base := "/mnt") -> (fx: int, fy: int, fw: int, fh: int, ok: bool) {
	for _ in 0 ..< PATIENCE * 10 {
		for wi in 1 ..< DRAW_SLOTS {
			pb: [64]u8
			if wx, wy, ww, wh, _, _, _, _, wok := wctl_frame(mnt_file(pb[:], wi, "/wctl", base)); wok && wx == x && (y < 0 || wy == y) && ww > 0 {
				return wx, wy, ww, wh, true
			}
		}
		sync.delay(1)
	}
	return
}

/*
await_key is `await_face_run` for a popup that just opened: the n-th of its
own keys, counted inside its rectangle, `top` to `top + h`. And only once
its first key begins within `first_by` of its top, which is the popup's own
paint. Before that the glass under it still shows the window beneath, whose
buttons are the same face. A count read then clicked a key too high:
`Snap left` for `Snap right`.
*/
await_key :: proc(s: ^fb.Surface, x: int, top: int, h: int, face: u32, n: int, first_by: int) -> int {
	for _ in 0 ..< PATIENCE * 10 {
		if first := nth_face_run_in(s, x, top, top + h, face, 1, true); first >= 0 && first <= top + first_by {
			if y := nth_face_run_in(s, x, top, top + h, face, n, false); y >= 0 {
				return y
			}
		}
		sync.delay(1)
	}
	return -1
}

// nth_face_run_in is `nth_face_run` between two rows. With `start` it answers
// where the run begins rather than its middle.
nth_face_run_in :: proc "contextless" (s: ^fb.Surface, x: int, y0: int, y1: int, face: u32, n: int, start: bool) -> int #no_bounds_check {
	runs, from := 0, -1
	for y in max(y0, 0) ..< min(y1, s.height) + 1 {
		on := y < min(y1, s.height) && fb.get_raw(s, x, y) == face
		if on && from < 0 {
			from = y
		} else if !on && from >= 0 {
			if y - from >= 8 {
				runs += 1
				if runs == n {
					return start ? from : (from + y) / 2
				}
			}
			from = -1
		}
	}
	return -1
}

// await_face_run waits for the n-th run of a face down a column to show,
// as a popup's keys do once its program has painted them.
await_face_run :: proc(s: ^fb.Surface, x: int, y0: int, face: u32, n: int) -> int {
	for _ in 0 ..< PATIENCE * 10 {
		if y := nth_face_run(s, x, y0, face, n); y >= 0 {
			return y
		}
		sync.delay(1)
	}
	return -1
}

// bar_colour_near looks for one colour in a box at the top of a window's bar:
// a flat bar is the colour through, and a scheme's metal bar has it on its
// top row, between the hairlines. The box is 21 columns from `x` and the
// first 30 rows from `y`.
bar_colour_near :: proc "contextless" (s: ^fb.Surface, x: int, y: int, want: u32) -> bool {
	for row in y ..< min(y + 30, s.height) {
		for col in x ..< min(x + 21, s.width) {
			if fb.get_raw(s, col, row) == want {
				return true
			}
		}
	}
	return false
}

// wctl_frame reads a window's wctl line: the rectangle, and the frame's four
// insets after the workspace, `docs/CHROME.md` brick 1. The two focus words
// are skipped, so the numbers are x y w h, the workspace, then the insets.
wctl_frame :: proc(path: string) -> (x, y, w, h, l, t, rr, b: int, ok: bool) {
	line: [128]u8
	n := read_once(path, line[:])
	if n <= 0 {
		return
	}
	nums: [9]int
	got := 0
	at := 0
	for at < n && got < len(nums) {
		for at < n && (line[at] == ' ' || line[at] == '\n') {
			at += 1
		}
		start := at
		for at < n && line[at] != ' ' && line[at] != '\n' {
			at += 1
		}
		if at == start {
			break
		}
		if v, vok := libdraw.scan_int_str(line[start:at]); vok {
			nums[got] = v
			got += 1
		}
	}
	if got < len(nums) {
		return
	}
	return nums[0], nums[1], nums[2], nums[3], nums[5], nums[6], nums[7], nums[8], true
}

// wctl_place reads a window's wctl and answers where the window is.
@(private = "file")
wctl_place :: proc(wctl: ^vfs.Chan) -> (x: int, y: int, ok: bool) {
	line: [96]u8
	n, err := vfs.chan_read(wctl, 0, line[:])
	if err != vfs.OK || n <= 0 {
		return
	}
	at := 0
	x, ok = libdraw.scan_int(line[:n], &at)
	if !ok {
		return
	}
	y, ok = libdraw.scan_int(line[:n], &at)
	return
}

/*
verify_abi runs the program `docs/SHELL.md` step 1 was built for.

`/bin/abitest` is an Odin program with a heap, spawned with three arguments.
It reads them back, changes directory and opens a file by a relative name,
stats, reads a directory, duplicates a descriptor, spawns itself with
arguments of its own and awaits the word it says, forks a child that exits
with a word, and says `ok` if every step held or the name of the first that
did not. The kernel's check is that one word, which is what makes the test
one line here and forty in the program.
*/
/*
verify_c runs the C and C++ programs `docs/DEVTOOLS.md` step 0 built.

`chello` is a C program over `sys/libc`: it writes a line and exits with a
word. `cpphello` is C++, whose global constructor `crt0` runs from
`.init_array` before `main`; its word says the constructor ran. `cmix` is
one image of a C `main` and an Odin package that call each other, and its
word says the round trip gave twelve. `abicheck` is the generated header's
proof: the kernel spawns it with its own `abi` constants as arguments, and
it compares each to `sys/abi/abi.h` and says `ok` or the first that
differs. Each program writes its line for a person to see; the kernel
checks the word.
*/
@(private = "file")
c_num_bufs: [10][24]u8
@(private = "file")
c_arg_strs: [11]string

@(private = "file")
verify_c :: proc(r: ^Result) {
	chello := [?]string{"chello", "one", "two"}
	script_says(r, "/bin/chello", chello[:], PATIENCE * 5, "a C program over sys/libc starts", "chello ok", "and writes a line and exits with a word")

	cpp := [?]string{"cpphello"}
	script_says(r, "/bin/cpphello", cpp[:], PATIENCE * 5, "a C++ program starts", "cpp ok", "and its global constructor ran from .init_array before main")

	cmix := [?]string{"cmix"}
	script_says(r, "/bin/cmix", cmix[:], PATIENCE * 5, "the mixed C-and-Odin image starts", "cmix ok", "and a call from C into Odin and back into C held in one image")

	// The generated header's numbers, in `abicheck`'s order, each the
	// kernel's own `abi` constant. The program compares them to `abi.h`.
	nums := [?]u64 {
		abi.SYS_WRITE,
		abi.SYS_READ,
		abi.SYS_OPEN,
		abi.SYS_EXITS,
		abi.O_RDONLY,
		abi.O_WRONLY,
		abi.O_TRUNC,
		abi.RFPROC,
		abi.RFMEM,
		u64(abi.ARGS_MAX),
	}
	c_arg_strs[0] = "abicheck"
	for v, i in nums {
		sink := libodin.sink_from(c_num_bufs[i][:])
		libodin.put_uint(&sink, v)
		c_arg_strs[i + 1] = libodin.str(&sink)
	}
	script_says(r, "/bin/abicheck", c_arg_strs[:], PATIENCE * 5, "the abi header check starts", "abi ok", "and every generated constant agrees with the kernel's")

	// Thread-local storage: two C programs, each with its own thread pointer,
	// run at once by `tls.rc`. Each sleeps so the other runs, and checks its
	// thread-locals held, which they do only if the kernel saved and restored
	// the pointer on the switch. `docs/DEVTOOLS.md` step 0.
	tls := [?]string{"rc", "/lib/tests/tls.rc"}
	script_says(r, "/bin/rc", tls[:], PATIENCE * 20, "two C programs with thread-local storage start at once", "ok", "and each read its own thread-locals across every switch, its thread pointer restored")
	reap_orphans()

	// The POSIX library: `posixtest` prints through `printf`, moves bytes
	// through a `pipe`, and runs `posixchild` through `fork`, `execv` and
	// `waitpid`, checking the child's exit number came back. It exits `0`
	// when every shape held, or the number of the step that did not.
	// `docs/DEVTOOLS.md` step 7.
	posix := [?]string{"posixtest"}
	script_says(r, "/bin/posixtest", posix[:], PATIENCE * 10, "a program over sys/libposix starts", "0", "and printf, pipe, fork, exec, waitpid, mmap, the clock, poll, the environment and the tty all held over the POSIX library", posix_step)
	reap_orphans()

	// Four threads and a mutex: each adds to a shared counter under one
	// lock and keeps its own `errno`. The total is exact only if the lock
	// held, and the `errno` only if the thread pointer is per thread.
	threads := [?]string{"posixthreads"}
	script_says(r, "/bin/posixthreads", threads[:], PATIENCE * 20, "a POSIX program with four threads starts", "0", "and four threads added under a mutex, each with its own errno")
	reap_orphans()

	// A signal caught: the program raises SIGTERM at itself and its handler
	// turns the note back into the signal and runs.
	sig := [?]string{"posixsignal"}
	script_says(r, "/bin/posixsignal", sig[:], PATIENCE * 10, "a POSIX program that catches a signal starts", "0", "and a raised SIGTERM was caught as a signal")
	reap_orphans()
}

// posix_step names the POSIX step a number stands for, so a failing
// `posixtest` says what broke rather than an exit code. Empty for a word
// it does not know, and `script_says` keeps the word itself then.
@(private = "file")
posix_step :: proc "contextless" (said: string) -> string {
	switch said {
	case "1": return "posixtest could not make a pipe"
	case "2", "3": return "posixtest's pipe did not carry its bytes"
	case "4": return "posixtest could not fork"
	case "5": return "posixtest's waitpid returned the wrong pid"
	case "6": return "posixtest's child exited with the wrong number"
	case "7", "8": return "posixtest's mmap did not hold its pages"
	case "9": return "posixtest's clock ran backwards across a sleep"
	case "10", "11": return "posixtest's poll did not see a ready descriptor"
	case "12": return "posixtest could not read back an environment variable"
	case "13", "14": return "posixtest's tty calls did not answer as a console does"
	case "70": return "posixtest's child did not receive the environment execve set"
	}
	return ""
}

@(private = "file")
verify_abi :: proc(r: ^Result) {
	names := [?]string{"abitest", "one", "two", "three"}
	// Seven forks and spawns, each a copy of the program's memory: on the
	// slowest emulated board that is more than one program's patience.
	script_says(r, "/bin/abitest", names[:], PATIENCE * 5, "a program with a heap and three arguments starts", "ok", "and every step of the process ABI held")
}

/*
verify_threads runs the program `docs/PROCS.md` step 4 was built for.

`/bin/threadtest` is a program on `sys/libthread`. It makes threads and
yields between them, meets and queues on channels, waits on two at once
with `alt`, makes a proc that parks in the kernel while its own threads
keep running, hands a `QLock` over in order, wakes a `Rendez`, and ends
with `threadexitsall` while a proc it made is still parked. The word is
`ok` or the name of the first step that failed. The check after the word
is the machine's: the proc it left parked is gone with it, which is what
`every program was taken down` at the end of this file will also say.
*/
@(private = "file")
verify_threads :: proc(r: ^Result) {
	names := [?]string{"threadtest"}
	before := stats().live
	if script_says(r, "/bin/threadtest", names[:], PATIENCE * 5, "a program on the thread library starts", "ok", "and every claim the library makes held") {
		check(r, stats().live == before, "and the procs it made went down with it")
	}
}

/*
verify_mui runs `tests/mui`, which builds gadget trees and lays them out with
`sys/libmui`, then checks the rectangles against the weighting rule worked by
hand. It draws nothing, so the check is a pure test of the layout arithmetic:
three buttons sharing a column by weight, a rigid label the glue beside it does
not shrink, and a nested group laid inside its parent's inset. The word is `ok`
or the name of the first step that failed.
*/
@(private = "file")
verify_mui :: proc(r: ^Result) {
	names := [?]string{"mui"}
	script_says(r, "/bin/mui", names[:], PATIENCE * 5, "a program on the toolkit's layout starts", "ok", "and every rectangle matched the weights")

	// The look's painter, `docs/CHROME.md` brick 3: each of `sys/libraster`'s
	// operations against pixels worked out by hand.
	rnames := [?]string{"rastertest"}
	script_says(r, "/bin/rastertest", rnames[:], PATIENCE * 5, "a program on the look's painter starts", "ok", "and every gradient, disc, grain, bevel, shadow, blur, mask and outline came out as worked by hand")

	// The reader's document model, `docs/WEB.md` step 1: a gemtext page
	// and a markdown page parse to their blocks and lay out to the rows a
	// column count gives them.
	dnames := [?]string{"doctest"}
	script_says(r, "/bin/doctest", dnames[:], PATIENCE * 5, "a program on the reader's document model starts", "ok", "and a page of each kind laid out to the numbers, and a PNG of each shape and a JPEG decoded to their pixels")
}

/*
verify_netfs runs `tests/net`, which builds and parses the wire formats
`sys/libnet` gives the network -- an ethernet frame, an ARP packet, an IPv4
header and an ICMP echo -- and checks a checksum a flipped bit must break. It
touches no card, so the check is pure protocol arithmetic, the foundation
`docs/FLEET.md` step 0's stack stands on. The word is `ok` or the name of the
first step that failed.
*/
@(private = "file")
verify_netfs :: proc(r: ^Result) {
	names := [?]string{"nettest"}
	script_says(r, "/bin/nettest", names[:], PATIENCE * 5, "a program on the network's wire formats starts", "ok", "and every packet parsed and every checksum held")
}

/*
verify_factotum starts the key server, mounts it where a session finds it,
and runs `authtest` against it: two keys in, their public halves out, and a
handshake carried between two of its conversations, which is the exchange
`sys/libauth` will carry across a wire. Then it stops it the way every server
stops, by a remove of one of its files.
*/
@(private = "file")
verify_factotum :: proc(r: ^Result) {
	count0 := srv.count()
	p := start_path(r, "/bin/factotum", "the loader starts factotum")
	if p == nil {
		return
	}
	check(r, await_posted("factotum"), "which posts /srv/factotum")
	if check(r, srv.mount(vfs.boot_namespace, "/srv/factotum", "/mnt/factotum") == vfs.OK, "and the kernel mounts it at /mnt/factotum") {
		names := [?]string{"authtest"}
		script_says(r, "/bin/authtest", names[:], PATIENCE * 40, "a program drives its keys and a handshake", "ok", "and both ends of the handshake hold the same keys")

		// The seal's identity: an openpgp key from a passphrase, its
		// fingerprint in the listing, and a program that seals and signs
		// through factotum without the private key.
		check(r, net_file_write("/mnt/factotum/ctl", "key proto=openpgp user=glenda dom=home !passphrase=correct-horse"), "an openpgp key is derived from a passphrase and a label")
		listing: [2048]u8
		n := web_read_file("/mnt/factotum/ctl", listing[:])
		got := string(listing[:max(n, 0)])
		check(r, n > 0 && libodin.contains(got, "key proto=openpgp user=glenda dom=home fpr=") && !libodin.contains(got, "correct-horse"), "and the listing shows its fingerprint and keeps the passphrase")
		pnames := [?]string{"pgptest", "factotum"}
		script_says(r, "/bin/pgptest", pnames[:], PATIENCE * 60, "a program on the seal starts against factotum", "ok", "and the certificate came over rpc, the same passphrase gave the same identity here, a message sealed to it opened with the session key factotum handed back, and a signature factotum made verified")
	}
	if c, err := vfs.open_path(vfs.boot_namespace, "/mnt/factotum/ctl", vfs.O_RDONLY); err == vfs.OK {
		check(r, vfs.chan_remove(c) == vfs.OK, "a remove of its file is factotum's stop")
		vfs.chan_close(c)
	}
	check(r, wait(p, PATIENCE), "and it exits")
	check(r, srv.remove("factotum") == vfs.OK, "and the kernel takes the name away")
	check(r, srv.count() == count0, "and /srv holds what it held")
	finish(r, p, "and factotum is taken down")
	pipe.quiesce()
	check(r, vfs.unmount_path(vfs.boot_namespace, "", "/mnt/factotum") == vfs.OK, "and its mount comes down")
}

/*
verify_users is the kernel's part of `docs/FLEET.md` section 4: a process has
a user, the host owner's by default, which its status line carries; only a
process of the host owner's may change its own, and a kernel thread with no
process cannot ask for it at all.
*/
@(private = "file")
verify_users :: proc(r: ^Result) {
	p := start_path(r, "/bin/echo", "a program starts as the host owner")
	if p == nil {
		return
	}
	check(r, wait(p, PATIENCE), "and ends")
	check(r, user_of(p) == hostowner_name(), "with the host owner's name on it")
	spath: [40]u8
	if c, err := vfs.open_path(vfs.boot_namespace, proc_file(spath[:], p.pid, "status"), vfs.O_RDONLY); err == vfs.OK {
		line: [256]u8
		n, _ := vfs.chan_read(c, 0, line[:])
		vfs.chan_close(c)
		text := string(line[:n])
		tail := hostowner_name()
		check(r, len(text) > len(tail) + 2 && text[len(text) - len(tail) - 1:len(text) - 1] == tail, "which its status line ends with")
	}
	check(r, !proc_set_user(p.pid, "alice"), "and no thread without a process can rename it")
	finish(r, p, "and it is taken down")
}

/*
verify_debug is `docs/DEVTOOLS.md` section 5's boot line: a debugger's whole
loop through `/proc`, from the kernel side, with no debugger yet.

A held program gets a breakpoint written into its first instruction
through `mem`. `startstop` is asked before it launches, so the breakpoint
stops it before the note it raised is delivered. `note` says why, and
reading it takes it away. `regs` shows the counter past the breakpoint,
and a write takes it back. `mem` puts the instruction back, `step` runs it
alone, and `start` lets the program run to its end. A second program is
stopped at a system call's entry and at its return by `startsyscall`. The
call's number and then its answer are on the frame. A third, started from
a file, is read through `text` and stopped for `waitstop`.

The words that answer only when the process stops are written from a
thread of their own. The thread that writes them is parked until then. A control: with the check before delivery in `on_trap` removed, the
breakpoint ends the program and `startstop` answers EIO.
*/
@(private = "file")
verify_debug :: proc(r: ^Result) {
	p := hold_blob(r, "spin", program_spin(), "a program is loaded and held, for a debugger to arm")
	if p == nil {
		return
	}
	pid := p.pid

	// -- A breakpoint through mem --------------------------------------------

	code := arch.BREAKPOINT_CODE
	first: [len(arch.BREAKPOINT_CODE)]u8
	n, rerr := read_proc(pid, "mem", u64(TEXT_VA), first[:])
	check(
		r,
		rerr == vfs.OK && n == len(first) && string(first[:]) == string(program_spin()[:len(first)]),
		"mem reads the program's first bytes at their own address",
	)
	werr: vfs.Errno
	n, werr = write_proc(pid, "mem", u64(TEXT_VA), code[:])
	check(r, werr == vfs.OK && n == len(code), "and a breakpoint written through mem lands")
	back: [len(arch.BREAKPOINT_CODE)]u8
	n, rerr = read_proc(pid, "mem", u64(TEXT_VA), back[:])
	check(r, rerr == vfs.OK && string(back[:]) == string(code[:]), "and reads back")

	// -- startstop, asked before there is a thread -----------------------------

	if !check(r, ctl_ask(pid, "startstop"), "a thread asks startstop") {
		finish(r, p, "and the held program is taken down")
		return
	}
	armed := sync.await_flag(&p.trace_note, PATIENCE)
	check(r, armed, "which arms the stop before the program has a thread")
	check(r, launch(p, 0), "and the program launches into it")
	cerr, answered := ctl_answered()
	check(r, answered && cerr == vfs.OK, "and startstop answers when the breakpoint stops it")

	status: [256]u8
	n, _ = read_proc(pid, "status", 0, status[:])
	check(r, libodin.contains(string(status[:n]), " Stopped "), "status says Stopped")
	note: [NOTE_MAX]u8
	n, _ = read_proc(pid, "note", 0, note[:])
	if string(note[:n]) == "sys: breakpoint" {
		check(r, true, "and note says sys: breakpoint")
	} else {
		sink := detail_for("and note says sys: breakpoint")
		libodin.put_str(&sink, "it said `")
		libodin.put_str(&sink, string(note[:max(n, 0)]))
		libodin.put_str(&sink, "`, stops ")
		libodin.put_uint(&sink, intrinsics.atomic_load(&p.stops))
		libodin.put_str(&sink, ", noted ")
		libodin.put_int(&sink, p.thread != nil && sched.thread_noted(p.thread) ? 1 : 0)
		fail_detail(r, &sink)
	}
	n, _ = read_proc(pid, "note", 0, note[:])
	check(r, n == 0, "and reading it took it away")

	// -- regs, there and back -------------------------------------------------

	frame: arch.Trap_Frame
	fbytes := (cast([^]u8)&frame)[:size_of(arch.Trap_Frame)]
	n, rerr = read_proc(pid, "regs", 0, fbytes)
	if rerr == vfs.OK && n == len(fbytes) && arch.frame_ip(&frame) == TEXT_VA + arch.BREAKPOINT_ADVANCE {
		check(r, true, "regs shows the counter at the breakpoint")
	} else {
		sink := detail_for("regs shows the counter at the breakpoint")
		libodin.put_str(&sink, "errno ")
		libodin.put_int(&sink, i64(rerr))
		libodin.put_str(&sink, ", ")
		libodin.put_int(&sink, i64(n))
		libodin.put_str(&sink, " bytes, pc ")
		libodin.put_hex(&sink, u64(arch.frame_ip(&frame)), 0)
		libodin.put_str(&sink, " sp ")
		libodin.put_hex(&sink, u64(arch.frame_sp(&frame)), 0)
		libodin.put_str(&sink, " vector ")
		libodin.put_uint(&sink, arch.frame_vector(&frame))
		fail_detail(r, &sink)
	}
	arch.frame_set_ip(&frame, TEXT_VA)
	n, werr = write_proc(pid, "regs", 0, fbytes)
	check(r, werr == vfs.OK && n == len(fbytes), "a regs write takes it back to the instruction")
	n, rerr = read_proc(pid, "regs", 0, fbytes)
	check(r, rerr == vfs.OK && arch.frame_ip(&frame) == TEXT_VA, "and regs reads the counter it wrote")
	n, werr = write_proc(pid, "mem", u64(TEXT_VA), first[:])
	check(r, werr == vfs.OK && n == len(first), "and mem puts the instruction back")

	// -- step -----------------------------------------------------------------

	serr: vfs.Errno
	when arch.HAS_STEP {
		check(r, ctl_ask(pid, "step"), "a thread asks step")
		cerr, answered = ctl_answered()
		check(r, answered && cerr == vfs.OK, "and it answers when one instruction has run")
		n, rerr = read_proc(pid, "regs", 0, fbytes)
		pc := arch.frame_ip(&frame)
		check(r, rerr == vfs.OK && pc > TEXT_VA && pc < TEXT_VA + 16, "with the counter on the next instruction")
	} else {
		_, serr = write_proc(pid, "ctl", 0, bytes_of("step"))
		check(r, serr == vectra9.EOPNOTSUPP, "step is not this architecture's yet, and ctl says so")
	}

	// -- The lists, and the release -------------------------------------------

	lines: [512]u8
	n, _ = read_proc(pid, "segment", 0, lines[:])
	check(r, libodin.contains(string(lines[:n]), "Text ") && libodin.contains(string(lines[:n]), "Stack "), "segment lists its text and its stack")
	n, _ = read_proc(pid, "fd", 0, lines[:])
	check(r, n > 0 && lines[0] == '/' && libodin.contains(string(lines[:n]), "\n0 "), "fd starts with its directory, then descriptor 0")

	set_cell(p, CELL_STOP, 1)
	_, serr = write_proc(pid, "ctl", 0, bytes_of("start"))
	check(r, serr == vfs.OK, "start lets it go")
	check(r, wait(p, PATIENCE), "and it runs to its own end")
	finish(r, p, "and the debugged program is taken down")

	// -- startsyscall: in, and out --------------------------------------------

	p = hold_blob(r, "hello", program_hello(), "a program that makes a system call is loaded and held")
	if p == nil {
		return
	}
	pid = p.pid
	check(r, set_bytes(p, MESSAGE_OFFSET, bytes_of(MESSAGE)), "with a line in its data page")
	check(r, ctl_ask(pid, "startsyscall"), "a thread asks startsyscall")
	armed = sync.await_flag(&p.trace_syscall, PATIENCE)
	check(r, armed && launch(p, u64(len(MESSAGE))), "and the program launches into it")
	cerr, answered = ctl_answered()
	check(r, answered && cerr == vfs.OK, "and startsyscall answers at the call's entry")
	n, rerr = read_proc(pid, "regs", 0, fbytes)
	number, _ := arch.syscall_request(&frame)
	check(r, rerr == vfs.OK && number == SYS_WRITE, "with the write's number on the frame")
	_, serr = write_proc(pid, "ctl", 0, bytes_of("start"))
	check(r, serr == vfs.OK && ctl_ask(pid, "waitstop"), "start, and a thread asks waitstop")
	cerr, answered = ctl_answered()
	check(r, answered && cerr == vfs.OK, "which answers at the call's return")
	n, rerr = read_proc(pid, "regs", 0, fbytes)
	check(r, rerr == vfs.OK && arch.syscall_result(&frame) == i64(len(MESSAGE)), "with the write's answer on the frame")
	_, serr = write_proc(pid, "ctl", 0, bytes_of("start"))
	check(r, serr == vfs.OK && wait(p, PATIENCE), "and started again it exits")
	check(r, p.exit.deliberate && p.exit.status == 0x2A, "with the status it meant")
	finish(r, p, "and it is taken down")

	// -- text and waitstop, on a program from a file ---------------------------

	argv := new(Argv)
	if !check(r, argv != nil, "a record for a program's arguments") {
		return
	}
	names := [?]string{"sleep", "5"}
	check(r, argv_from(argv, names[:]), "holds them")
	ps := start_path(r, "/bin/sleep", "a program from a file starts", argv)
	if ps == nil {
		return
	}
	head: [16]u8
	terr: vfs.Errno
	n, terr = read_proc(ps.pid, "text", 0, head[:])
	file_head: [16]u8
	fn := 0
	if c, oerr := vfs.open_path(vfs.boot_namespace, "/bin/sleep", vfs.O_RDONLY); oerr == vfs.OK {
		fn, _ = vfs.chan_read(c, 0, file_head[:])
		vfs.chan_close(c)
	}
	check(r, terr == vfs.OK && n == len(head) && fn == len(head) && string(head[:]) == string(file_head[:]), "text reads the file it was started from")
	_, serr = write_proc(ps.pid, "ctl", 0, bytes_of("stop"))
	check(r, serr == vfs.OK && ctl_ask(ps.pid, "waitstop"), "stop, and a thread asks waitstop")
	cerr, answered = ctl_answered()
	check(r, answered && cerr == vfs.OK, "which answers once it has stopped")
	n, _ = read_proc(ps.pid, "status", 0, status[:])
	check(r, libodin.contains(string(status[:n]), " Stopped "), "and status says Stopped")
	_, serr = write_proc(ps.pid, "ctl", 0, bytes_of("start"))
	check(r, serr == vfs.OK && end(ps, PATIENCE), "started, it is ended by the kernel's word")
	finish(r, ps, "and taken down")
}

// The blocking words of `/proc/n/ctl`, written from a thread of their own.
@(private = "file")
Ctl_Helper :: struct {
	path:     [32]u8,
	path_len: int,
	word:     string,
	err:      vfs.Errno,
	done:     bool,
}

@(private = "file")
ctl_helper: Ctl_Helper

@(private = "file")
ctl_helper_thread :: proc "contextless" (arg: rawptr) {
	context = mem.kernel_context()
	h := (^Ctl_Helper)(arg)
	c, err := vfs.open_path(vfs.boot_namespace, string(h.path[:h.path_len]), vfs.O_WRONLY)
	if err == vfs.OK {
		_, err = vfs.chan_write(c, 0, transmute([]u8)h.word)
		vfs.chan_close(c)
	}
	h.err = err
	intrinsics.volatile_store(&h.done, true)
}

// ctl_ask starts a thread that writes `word` to the process's ctl and
// answers whether the thread started. `ctl_answered` waits for its answer.
@(private = "file")
ctl_ask :: proc(pid: u64, word: string) -> bool {
	h := &ctl_helper
	h^ = {}
	h.path_len = len(proc_file(h.path[:], pid, "ctl"))
	h.word = word
	return sched.spawn("ctl-ask", ctl_helper_thread, h) != nil
}

@(private = "file")
ctl_answered :: proc(patience := PATIENCE * 5) -> (err: vfs.Errno, answered: bool) {
	for _ in 0 ..< patience {
		if intrinsics.volatile_load(&ctl_helper.done) {
			return ctl_helper.err, true
		}
		sync.delay(1)
	}
	return vectra9.EIO, false
}

// read_proc and write_proc reach one of a process's files by name, at an
// offset, the way a debugger would.
@(private = "file")
proc_file :: proc "contextless" (buf: []u8, pid: u64, name: string) -> string {
	sink := libodin.sink_from(buf)
	libodin.put_str(&sink, "/proc/")
	libodin.put_uint(&sink, pid)
	libodin.put_str(&sink, "/")
	libodin.put_str(&sink, name)
	return libodin.str(&sink)
}

@(private = "file")
read_proc :: proc(pid: u64, name: string, off: u64, out: []u8) -> (n: int, err: vfs.Errno) {
	path: [40]u8
	c, oerr := vfs.open_path(vfs.boot_namespace, proc_file(path[:], pid, name), vfs.O_RDONLY)
	if oerr != vfs.OK {
		return 0, oerr
	}
	defer vfs.chan_close(c)
	return vfs.chan_read(c, off, out)
}

@(private = "file")
write_proc :: proc(pid: u64, name: string, off: u64, data: []u8) -> (n: int, err: vfs.Errno) {
	path: [40]u8
	c, oerr := vfs.open_path(vfs.boot_namespace, proc_file(path[:], pid, name), vfs.O_WRONLY)
	if oerr != vfs.OK {
		return 0, oerr
	}
	defer vfs.chan_close(c)
	return vfs.chan_write(c, off, data)
}

/*
verify_debugtest runs `debugtest`, which reads its own debug file from
`/lib/debug` -- `docs/DEVTOOLS.md` section 6, the file the build writes
beside every program. It finds its entry by name, names a procedure from an
address inside it, finds that address's source line, and reads the
instruction text at its entry. The word it exits with is the first check
that did not hold, or `ok`.
*/
@(private = "file")
verify_debugtest :: proc(r: ^Result) {
	names := [?]string{"debugtest"}
	script_says(r, "/bin/debugtest", names[:], PATIENCE * 5, "a program on its own debug file starts", "ok", "and names, lines, instructions, types and variables read back from it")
}

/*
verify_cryptotest runs the fleet's cryptography against known answers. A
handshake is only as sound as its primitives, so `docs/FLEET.md` step 2's
`sys/libcrypto` is checked before anything is built on it: the AEAD against
RFC 8439, X25519 against RFC 7748, and BLAKE2s against a fixed digest.
*/
@(private = "file")
verify_cryptotest :: proc(r: ^Result) {
	names := [?]string{"cryptotest"}
	script_says(r, "/bin/cryptotest", names[:], PATIENCE * 5, "a program on the fleet's cryptography starts", "ok", "and every cipher matched its published vector")
}

// verify_pgptest runs `pgptest`, RFC 9580's own test vectors through
// `sys/libpgp` from ring 3: the sample certificate's fingerprints and
// signatures, the sample message opened and refused when bent, and the
// sample signed message verified. `docs/WEB.md` step 3's boot line, the
// opening half.
@(private = "file")
verify_pgptest :: proc(r: ^Result) {
	names := [?]string{"pgptest"}
	script_says(r, "/bin/pgptest", names[:], PATIENCE * 10, "a program on the seal starts", "ok", "and RFC 9580's vectors verified and opened through libpgp")
}

/*
verify_fonttest runs `fonttest`, which reads `/lib/font` -- the first data
this system loads at run time rather than bakes. It opens the `.font` index,
draws an ASCII letter from the baked table and a Latin-1 letter and an arrow
from subfonts it loads, and refuses a rune no range holds. The word it exits
with is the first check that did not hold, or `ok`.
*/
@(private = "file")
verify_fonttest :: proc(r: ^Result) {
	names := [?]string{"fonttest"}
	script_says(r, "/bin/fonttest", names[:], PATIENCE * 5, "a program on the runtime font starts", "ok", "and a rune past ASCII loaded from a subfont with ink")
}

/*
verify_netserver runs `servers/netfs`, the IPv4 stack in ring 3, and reads the
`/net` it serves.

The stack opens the card as `#E`, asks who has the gateway, and pings it. Three
files say whether that worked, and each is read here rather than inferred.
`/net/ether0/addr` is the card's own address, which the kernel knows from the
driver and compares. `/net/arp` holds an address this machine resolved, so the
gateway appearing there is an ARP that crossed the card and came back. And
`/net/icmp/stats` counts the echoes, so a reply counted is an IPv4 datagram this stack
built, sent, and matched to its own request.

That is the whole of `docs/FLEET.md` step 0's first claim: a stack in ring 3
reaching the world through a file. TCP and the conversations are the steps
after it.
*/
@(private = "file")
verify_netserver :: proc(r: ^Result) #no_bounds_check {
	if !ether.present() {
		return
	}
	count0 := srv.count()
	settle()
	pin_before := mem.live_objects(mem.heap_stats())

	p := start_path(r, "/bin/netfs", "the loader starts the network stack")
	if p == nil {
		return
	}
	if !check(r, await_posted("net"), "which posts /srv/net") {
		finish(r, p, "and the stack is taken down")
		return
	}
	if !check(r, srv.mount(vfs.boot_namespace, "/srv/net", "/net") == vfs.OK, "the kernel mounts it at /net") {
		finish(r, p, "and the stack is taken down")
		return
	}

	/*
	The names, beside the stack: `dns` asks a resolver and `cs` turns a dial
	string into an address, out of the database or through `dns`. Each is a
	server of its own, mounted after the stack at `/net`, so `/net/dns` and
	`/net/cs` sit in the same directory as the conversations. `dns` is told
	its resolver is this machine, `dnstest` announces the resolver's port and
	answers one name, and both files are asked for it: `/net/dns` for the
	address, `/net/cs` for a dial string the database cannot finish.
	*/
	pdns := start_path(r, "/bin/dns", "the loader starts dns")
	if pdns != nil {
		check(r, await_posted("dns"), "which posts /srv/dns")
		check(r, srv.mount(vfs.boot_namespace, "/srv/dns", "/net", .After) == vfs.OK, "and the kernel mounts it after the stack")
	}
	pcs := start_path(r, "/bin/cs", "the loader starts cs")
	if pcs != nil {
		check(r, await_posted("cs"), "which posts /srv/cs")
		check(r, srv.mount(vfs.boot_namespace, "/srv/cs", "/net", .After) == vfs.OK, "and the kernel mounts it after the stack")
	}

	{
		// This machine's own address, whatever the database gave this card:
		// the bench's two machines are not the solo one.
		local: [32]u8
		ln := 0
		if c, err := vfs.open_path(vfs.boot_namespace, "/net/local", vfs.O_RDONLY); err == vfs.OK {
			n, _ := vfs.chan_read(c, 0, local[:])
			vfs.chan_close(c)
			ln = int(n)
			for ln > 0 && (local[ln - 1] == '\n' || local[ln - 1] == '\r') {
				ln -= 1
			}
		}
		note_buf: [48]u8
		nsink := libodin.sink_from(note_buf[:])
		libodin.put_str(&nsink, "dns=")
		libodin.put_str(&nsink, string(local[:ln]))
		libodin.put_str(&nsink, "\n")
		note := libodin.str(&nsink)
		check(r, ln > 0 && net_file_write("/net/ndb", note), "the stack's note names this machine as the resolver")
		ptest := start_path(r, "/bin/dnstest", "a resolver of one name starts")
		if ptest != nil {
			sync.delay(PATIENCE / 10)
			got: [128]u8
			n := net_file_ask("/net/dns", "fs.test", got[:])
			check(r, n > 0 && string(got[:n]) == "fs.test ip 10.0.0.2\n", "/net/dns asks it and answers the name's address")
			n = net_file_ask("/net/cs", "tcp!fs.test!9fs", got[:])
			check(r, n > 0 && string(got[:n]) == "/net/tcp/clone 10.0.0.2!564\n", "and /net/cs finishes a dial string with it")
			n = net_file_ask("/net/dns", "fs.test", got[:])
			check(r, n > 0 && string(got[:n]) == "fs.test ip 10.0.0.2\n", "a name asked twice is answered from what dns remembers")
			check(r, wait(ptest, PATIENCE), "and the resolver, asked once for the three, exits")
			word := string(ptest.exit.text[:ptest.exit.text_len])
			check(r, word == "ok", word == "ok" ? "with the question the one expected" : word)
			finish(r, ptest, "and is taken down")
		}
	}

	// The card's own address, which the driver knows and the stack serves.
	m: [6]u8
	_ = virtio.mac(0, m[:])
	want_addr: [32]u8
	wsink := libodin.sink_from(want_addr[:])
	libodin.put_mac(&wsink, m[:])
	said := libodin.str(&wsink)

	got: [64]u8
	if c, err := vfs.open_path(vfs.boot_namespace, "/net/ether0/addr", vfs.O_RDONLY); err == vfs.OK {
		n, rerr := vfs.chan_read(c, 0, got[:])
		vfs.chan_close(c)
		hit := rerr == vfs.OK && int(n) == len(said) + 1 && string(got[:len(said)]) == said
		check(r, hit, "and /net/ether0/addr is the address the driver read off the card")
	} else {
		check(r, false, "and /net/ether0/addr opens")
	}

	/*
	An address asked for rather than read. `ipconfig` shouts DHCP on the card
	from no address, QEMU's router answers with the one the database already
	gives this machine, and the stack's route and its note say so. The
	exchange is four datagrams across the card, the first from `0.0.0.0` to
	the broadcast address. It comes before the gateway checks: on the bench
	the router is on the second card, which has no address until this asks,
	and the stack probes the gateway once a route to it appears.
	*/
	{
		// The card that faces the router: the bench's first is the link
		// between its two machines, and its second is the one QEMU's router
		// is on.
		ifc := virtio.net_count() >= 2 ? "ether1" : "ether0"
		names := [?]string{"ipconfig", ifc}
		if script_says(r, "/bin/ipconfig", names[:], PATIENCE * 10, "a program asks the router for an address by DHCP", "", "and the router answered with one") {
			check(r, net_file_holds(r, "/net/ndb", "ip=10.0.2.15 ipmask=255.255.255.0 ipgw=10.0.2.2"), "which the stack notes in /net/ndb, with the mask and the router")
			route := ifc == "ether1" ? "0.0.0.0 0.0.0.0 10.0.2.2 ether1" : "0.0.0.0 0.0.0.0 10.0.2.2 ether0"
			check(r, net_file_holds(r, "/net/iproute", route), "and takes the router as its default route")
		}
	}

	// The gateway resolved by ARP, and the echo it answered. Both are polled,
	// because the frames cross a card and a server between them.
	check(r, net_file_holds(r, "/net/arp", "10.0.2.2"), "the stack resolved the gateway by ARP across the card")
	check(r, net_file_holds(r, "/net/icmp/stats", "received 1"), "and its echo came back, an IPv4 datagram answered")

	/*
	And the conversations, driven by a program rather than from here. `udptest`
	takes two from `/net/udp/clone` and announces a port on one. It connects the
	other to it, then reads back out of the first what it wrote into the second.
	That is the loopback path and the whole conversation shape at once, done
	through the files a program would use.
	*/
	{
		names := [?]string{"udptest"}
		script_says(
			r,
			"/bin/udptest",
			names[:],
			PATIENCE * 5,
			"a program takes a udp conversation from /net/udp/clone",
			"ok",
			"and the datagram it sent came back out of the end that announced",
		)
	}

	/*
	And TCP, which is the same conversation with a state machine under it.
	`tcptest` announces a port, connects to it, and takes the conversation the
	listener answered with off its `listen` file. The connect returns with the
	handshake already finished, since the loopback answers inside the write.
	Bytes go each way, and a hangup puts the far end in `Close_Wait` and ends
	its stream.
	*/
	{
		names := [?]string{"tcptest"}
		script_says(
			r,
			"/bin/tcptest",
			names[:],
			PATIENCE * 5,
			"a program takes a tcp conversation and connects it",
			"ok",
			"and the stream carried bytes each way and closed",
		)
	}

	/*
	And TLS 1.3 over one of them, `docs/WEB.md` step 0: `tlssrv` announces a
	port and answers one handshake with the certificate in `/lib/tls/roots`,
	and `tlsclient` dials it by this machine's name through `/net/cs`, verifies
	the chain against the store and the clock, and relays a line each way.
	`tests/crypto` proves the engine on a pipe; this is the command's own glue
	-- the dial, the store, the clock and the relay -- over a real connection.
	*/
	{
		names := [?]string{"rc", "/lib/tests/web.rc"}
		script_says(
			r,
			"/bin/rc",
			names[:],
			PATIENCE * 100,
			"a scripted TLS server and tlsclient start on this machine's stack",
			"ok",
			"and a line crossed a TLS 1.3 connection, the chain verified against the trust store",
		)
		reap_orphans()
	}

	// And the web as files, `docs/WEB.md` step 0: a body from a scripted
	// server lands in the store under its hash, over http and over https.
	verify_webfs(r)

	// And mail as files, `docs/WEB.md` step 3: a saved IMAP session becomes
	// an inbox of the shape, the password asked of factotum.
	verify_mailfs(r)

	// -- Teardown, a remove of one of its files -------------------------------

	// The names first: each stops on a remove of its file, as the stack does.
	for name in ([?]string{"cs", "dns"}) {
		which := name == "cs" ? pcs : pdns
		if which == nil {
			continue
		}
		path := name == "cs" ? "/net/cs" : "/net/dns"
		if c, err := vfs.open_path(vfs.boot_namespace, path, vfs.O_RDONLY); err == vfs.OK {
			check(r, vfs.chan_remove(c) == vfs.OK, "a remove of its file is the name server's stop")
			vfs.chan_close(c)
		}
		check(r, wait(which, PATIENCE), "and it exits")
		check(r, srv.remove(name) == vfs.OK, "and the kernel takes the name away")
		finish(r, which, "and it is taken down")
	}
	if c, err := vfs.open_path(vfs.boot_namespace, "/net/icmp/stats", vfs.O_RDONLY); err == vfs.OK {
		check(r, vfs.chan_remove(c) == vfs.OK, "a remove of one of its files is the stack's stop")
		vfs.chan_close(c)
	}
	check(r, wait(p, PATIENCE), "the stack exits")
	check(r, srv.remove("net") == vfs.OK, "the kernel takes the name away")
	check(r, srv.count() == count0, "and /srv holds what it held")
	finish(r, p, "and the stack is taken down")
	pipe.quiesce()
	check(r, vfs.unmount_path(vfs.boot_namespace, "", "/net") == vfs.OK, "the mount of the dead stack comes down")
	drain_pinned(r, pin_before, "and the stack's wire comes back whole")
}

// net_file_write writes `text` to one of the stack's files, whole.
@(private = "file")
net_file_write :: proc(path: string, text: string) -> bool {
	c, err := vfs.open_path(vfs.boot_namespace, path, vfs.O_WRONLY)
	if err != vfs.OK {
		return false
	}
	defer vfs.chan_close(c)
	n, werr := vfs.chan_write(c, 0, transmute([]u8)text)
	return werr == vfs.OK && int(n) == len(text)
}

// net_file_ask writes a question to a message file and reads the answer back
// on the same channel, the way a program asks `cs` or `dns`. Answers how many
// bytes came back, and a negative number for a write that was refused.
@(private = "file")
net_file_ask :: proc(path: string, question: string, into: []u8) -> int {
	c, err := vfs.open_path(vfs.boot_namespace, path, vfs.O_RDWR)
	if err != vfs.OK {
		return -1
	}
	defer vfs.chan_close(c)
	n, werr := vfs.chan_write(c, 0, transmute([]u8)question)
	if werr != vfs.OK || int(n) != len(question) {
		return -1
	}
	got, rerr := vfs.chan_read(c, u64(n), into)
	if rerr != vfs.OK {
		return -1
	}
	return int(got)
}

// net_file_holds polls one of the stack's files until it carries `want`, and
// answers whether it ever did. The stack fills these as frames arrive.
@(private = "file")
net_file_holds :: proc(r: ^Result, path: string, want: string) -> bool #no_bounds_check {
	_ = r
	buf: [512]u8
	c, err := vfs.open_path(vfs.boot_namespace, path, vfs.O_RDONLY)
	if err != vfs.OK {
		return false
	}
	defer vfs.chan_close(c)
	// One open, and a read per pass. Opening inside the loop was a walk, an
	// open and a clunk across the mount for every one of these.
	for _ in 0 ..< PATIENCE * 4 {
		n, rerr := vfs.chan_read(c, 0, buf[:])
		if rerr == vfs.OK && n > 0 && libodin.contains(string(buf[:n]), want) {
			return true
		}
		sync.delay(1)
	}
	return false
}

/*
run_script spawns a program with arguments, waits for it, and answers the
word it said, copied into `into` because the tally keeps the string and the
record is cleared before the line is printed. The three programs the shell
plan checks with -- the ABI test, the shell on a script, the shell on the
tool script -- are this with different words. `ok` says it came back and
was taken down; `ticks` is how long it took.
*/
@(private = "file")
run_script :: proc(
	r: ^Result,
	path: string,
	names: []string,
	patience: int,
	into: []u8,
	what: string,
) -> (said: string, ticks: int, ok: bool) {
	argv := new(Argv)
	if !check(r, argv != nil, "a record for the program's arguments") {
		return
	}
	check(r, argv_from(argv, names), "holds them")

	p := start_path(r, path, what, argv)
	if p == nil {
		return
	}
	started := sched.ticks()
	came_back := comes_back(r, p, "and comes back", patience)
	ticks = int(sched.ticks() - started)
	if came_back {
		n := copy(into, p.exit.text[:p.exit.text_len])
		said = string(into[:n])
		if !p.exit.deliberate {
			sink := libodin.sink_from(helper_line[:])
			libodin.put_str(&sink, "it said `")
			libodin.put_str(&sink, said)
			libodin.put_str(&sink, "` and faulted, kind ")
			libodin.put_uint(&sink, u64(p.exit.kind))
			libodin.put_str(&sink, " vector ")
			libodin.put_uint(&sink, p.exit.vector)
			libodin.put_str(&sink, " ip ")
			libodin.put_hex(&sink, u64(p.exit.ip))
			libodin.put_str(&sink, " address ")
			libodin.put_hex(&sink, u64(p.exit.address))
			fail_detail(r, &sink)
			came_back = false
		}
	}
	finish(r, p, "and it is taken down")
	return said, ticks, came_back
}

/*
script_says is `run_script` on a program that answers one word, checked.

`what_start` names the start, `what_pass` the word matched, and the word
itself is the failure line otherwise. It is copied into a detail buffer
first. Every script answers into one buffer, and the next script writes
over it, so a failure line that pointed into it would say the wrong word.
`why` may turn a word into a sentence, and answers empty when it cannot.
Returns whether the program ran, for a caller with more to check.
*/
@(private = "file")
script_says :: proc(
	r: ^Result,
	path: string,
	names: []string,
	patience: int,
	what_start: string,
	want: string,
	what_pass: string,
	why: proc "contextless" (said: string) -> string = nil,
) -> (ran: bool) {
	said, _, ok := run_script(r, path, names, patience, said_buf[:], what_start)
	if !ok {
		return false
	}
	if said == want {
		check(r, true, what_pass)
		return true
	}
	detail := why != nil ? why(said) : ""
	if detail == "" {
		sink := detail_sink()
		libodin.put_str(&sink, said)
		detail = libodin.str(&sink)
	}
	check(r, false, detail)
	return true
}

// Where every script's exit word lands. One buffer, because no test reads
// a word once the next script answers.
@(private = "file") said_buf: [EXITS_MAX]u8
@(private = "file") seg_pages_before: [MAX_SEGMENTS]int
@(private = "file") resident_pids: [MAX_PROCESSES]u64
@(private = "file") seg_diag: [512]u8
@(private = "file") helper_line: [512]u8

/*
comes_back is `wait` as a check, and when it fails the line says everything
the record knows: a program that printed its line and never came back has
several ways to have got there, and a bare "it did not" costs a boot to
place.
*/
@(private = "file")
comes_back :: proc(r: ^Result, p: ^Process, what: string, patience := PATIENCE) -> bool {
	if wait(p, patience) {
		return check(r, true, what)
	}
	sink := libodin.sink_from(helper_line[:])
	libodin.put_str(&sink, what)
	libodin.put_str(&sink, " -- thread ")
	if p.thread != nil {
		switch p.thread.state {
		case .Ready:
			libodin.put_str(&sink, "Ready")
		case .Running:
			libodin.put_str(&sink, "Running")
		case .Blocked:
			libodin.put_str(&sink, "Blocked")
		case .Dead:
			libodin.put_str(&sink, "Dead")
		}
		libodin.put_str(&sink, intrinsics.volatile_load(&p.thread.noted) ? " noted" : " unnoted")
	} else {
		libodin.put_str(&sink, "nil")
	}
	libodin.put_str(&sink, intrinsics.volatile_load(&p.exit.done) ? ", exit done" : ", exit not done")
	libodin.put_str(&sink, p.stopped ? ", stopped" : "")
	libodin.put_str(&sink, p.stop_requested ? ", stop requested" : "")
	libodin.put_str(&sink, ", mark ")
	libodin.put_hex(&sink, cell(p, CELL_MARK))
	libodin.put_str(&sink, ", cells")
	for i in 1 ..< 18 {
		libodin.put_str(&sink, " ")
		libodin.put_hex(&sink, cell(p, i))
	}
	return fail_detail(r, &sink)
}

/*
verify_rc runs the shell on a script and reads what the script says.

The script is `docs/SHELL.md` step 2's proof in one line: a function, a
`for` over a list, a backquote, a pipeline through two programs, a `while`,
a `switch`, `~`, `$#` and `$"`, and an `exit` whose word is everything the
script computed. The word is checked here, so the whole chain -- rc's
parser, its forks, `echo`, `cat`, the pipe and `await` -- is one line of
the boot log. What rc writes to the console lands in the serial log
beside it.
*/
RC_SCRIPT :: "fn twice { echo $1 $1 }; x=(); for(i in a b c) x=($x `{twice $i}); " +
	"y=`{echo hello world | cat}; z=(); while(! ~ $#z 3) z=($z x); " +
	"switch($#x){ case 6; s=six; case *; s=$#x }; echo rc: $x $y $s $#z; " +
	"exit $\"x^' '^$\"y^' '^$s^' '^$#z"

RC_EXPECT :: "a a b b c c hello world six 3"

/*
verify_cputype proves the kernel seeds `$cputype` into a root process's
environment, `docs/FLEET.md` step 3. A shell reads it and `exit $cputype`
makes it the child's status, which `run_script` reads back. The word is the
tree's own name for this architecture -- the `/$cputype/bin` a machine binds
over `/bin`, and the `cputype=` an `ndb` record carries.
*/
verify_cputype :: proc(r: ^Result) {
	names := [?]string{"rc", "-c", "exit $cputype"}
	script_says(
		r,
		"/bin/rc",
		names[:],
		PATIENCE * 10,
		"a shell reads the $cputype the kernel seeded",
		CPUTYPE,
		"and it is this machine's architecture, the tree's own name for it",
	)
}

/*
verify_nstest proves the namespace is a file, `docs/FLEET.md` step 3:
`sys/libuser`'s `newns` replays a file of `bind`/`mount` lines, `$cputype`
expanded from `#e`. `/bin/nstest` replays a test file and resolves a program
through the bind it made; the word is `ok` or the first check that failed.
*/
verify_nstest :: proc(r: ^Result) {
	names := [?]string{"nstest"}
	script_says(
		r,
		"/bin/nstest",
		names[:],
		PATIENCE * 10,
		"a program replays a namespace file with newns",
		"ok",
		"and a bind with $cputype expanded landed, a tool resolving through it",
	)
}

/*
verify_roles proves a machine reads its role off its `ndb` line, `docs/FLEET.md`
step 3: `sys/libuser`'s `ndb_attr` -- the call `cmd/role` and `/lib/init` use --
finds a record by `sys=` and answers whether it carries `terminal=`, `cpu=` or
`fs=`. `/bin/roletest` checks a present role reads true though its value is empty
and an absent one reads false; the word is `ok` or the first check that failed.
*/
verify_roles :: proc(r: ^Result) {
	names := [?]string{"roletest"}
	script_says(
		r,
		"/bin/roletest",
		names[:],
		PATIENCE * 10,
		"a program reads the roles on a machine's ndb line",
		"ok",
		"and a role present reads true, one absent false -- what /lib/init branches on",
	)
}

/*
verify_root proves the boot tells a machine where its tree is, `docs/FLEET.md`
step 3. The kernel reads `root=` off its own command line and seeds `$root` into
the first process's `#e`; a shell reads it back with `exit $root`. This machine's
`limine.conf` says `root=local`, the disk it booted -- a diskless machine is told
a file server here instead, and `/lib/init` dials it and binds it as the root.
*/
verify_root :: proc(r: ^Result) {
	names := [?]string{"rc", "-c", "exit $root"}
	script_says(
		r,
		"/bin/rc",
		names[:],
		PATIENCE * 10,
		"a shell reads the $root the kernel seeded from the command line",
		"local",
		"and it is what limine.conf told this machine: the disk it booted",
	)
}

/*
verify_fdtest proves `#d` names a process's descriptors as files, `docs/FLEET.md`
section 7: `/fd/<n>` reads and writes wherever descriptor `n` points. `/bin/fdtest`
writes a token into one end of a pipe and reads it back through `/fd/<other end>`;
the word is `ok` or the first check that failed. It is what `cpu -f` and `rx`
rest on -- a descriptor reached by name, so a remote command's three may be the
terminal's.
*/
verify_fdtest :: proc(r: ^Result) {
	names := [?]string{"fdtest"}
	script_says(
		r,
		"/bin/fdtest",
		names[:],
		PATIENCE * 10,
		"a program names a descriptor through /fd and reads it",
		"ok",
		"and #d reaches the pipe the descriptor points at -- what cpu -f exports",
	)
}

/*
verify_olmtest runs `tests/olm`: docs/WEB.md section 8's "Olm's and
Megolm's published test vectors seal and open through libolm". Megolm's
ratchet against the reference's known answers, a Megolm session sealing
and opening in any order, and an Olm session both ways from fixed keys.
*/
@(private = "file")
verify_olmtest :: proc(r: ^Result) {
	names := [?]string{"olmtest"}
	script_says(r, "/bin/olmtest", names[:], PATIENCE * 20, "a program on the seal starts", "ok", "and Megolm's ratchet matches the reference's answers, a session seals and opens in any order, and Olm runs both ways")
}

verify_rc :: proc(r: ^Result) {
	names := [?]string{"rc", "-c", RC_SCRIPT}
	// Twenty forks and execs, each a copy of the shell's memory, on an
	// emulated core: a few hundred ticks, ten times what one program takes,
	// and over eight hundred before the ring 3 heap started small.
	said, ticks, ok := run_script(r, "/bin/rc", names[:], PATIENCE * 25, said_buf[:], "the shell starts on a script")
	r.shell_ticks = ticks
	if ok {
		sink := libodin.sink_from(rc_diag[:])
		if said == RC_EXPECT {
			libodin.put_str(&sink, "and a function, a loop, a pipeline, a switch and a while said what they should, in ")
			libodin.put_uint(&sink, u64(ticks))
			libodin.put_str(&sink, " ticks")
		} else {
			libodin.put_str(&sink, "rc said `")
			libodin.put_str(&sink, said)
			libodin.put_str(&sink, "`")
		}
		check(r, said == RC_EXPECT, libodin.str(&sink))
	}
}

@(private = "file") rc_diag: [256]u8


/*
verify_plumber runs `servers/plumber` on the self-test's rules, which include
the shipped `/lib/plumb/rules`. It sends messages the way a program does: a
packed message written to `send`, and a port held open for the answer.

A URL is routed to the web port. A file and a line become the file's path
with an `addr` attribute on the edit port, which is a regular expression's
groups at work. A note nobody reads starts the program its rule names,
which reports back through the plumber. A message no rule takes is refused.
Then the shell runs `tests/plumb.rc`, the same through `cmd/plumb`. That is
`docs/GHOST.md` section 5's "a plumb of a file name opens it".
*/
@(private = "file")
verify_plumber :: proc(r: ^Result) {
	names := [?]string{"plumber", "-r", "/lib/tests/plumb.rules"}
	argv := new(Argv)
	if !check(r, argv != nil && argv_from(argv, names[:]), "a record for the plumber's arguments") {
		return
	}
	p := start_path(r, "/bin/plumber", "the loader starts the plumber on the self-test's rules", argv)
	if p == nil {
		return
	}
	if !check(r, await_posted("plumb"), "which posts /srv/plumb") {
		finish(r, p, "and the plumber is taken down")
		return
	}
	if !check(r, srv.mount(vfs.boot_namespace, "/srv/plumb", "/mnt/plumb") == vfs.OK, "and the kernel mounts it at /mnt/plumb") {
		finish(r, p, "and the plumber is taken down")
		return
	}

	// The ports the rules declare are files.
	ports_ok := true
	for name in ([?]string{"web", "edit", "ghost", "note"}) {
		path_buf: [64]u8
		c, err := vfs.open_path(vfs.boot_namespace, libodin_cat(path_buf[:], "/mnt/plumb/", name), vfs.O_RDONLY)
		if err != vfs.OK {
			ports_ok = false
			continue
		}
		vfs.chan_close(c)
	}
	check(r, ports_ok, "the ports the rules name are files: web, edit, ghost and note")
	rules: [4096]u8
	rn := web_read_file("/mnt/plumb/rules", rules[:])
	check(r, rn > 0 && libodin.contains(string(rules[:rn]), "plumb to web") && libodin.contains(string(rules[:rn]), "plumb to note"), "and rules reads back the shipped file and the included one")

	// A URL, to a reader holding the web port.
	msg: [1024]u8
	if web, err := vfs.open_path(vfs.boot_namespace, "/mnt/plumb/web", vfs.O_RDONLY); check(r, err == vfs.OK, "a reader opens the web port") {
		sent := plumb_send("verify", "", "text", "https://example.com/a", "")
		check(r, sent, "a URL written to send is taken by a rule")
		n, rerr := vfs.chan_read(web, 0, msg[:])
		got := string(msg[:max(n, 0)])
		check(r, rerr == vfs.OK && n > 0 && libodin.contains(got, "\nweb\n") && libodin.contains(got, "\n21\nhttps://example.com/a"), "and the reader gets it back on the web port, its destination set")
		vfs.chan_close(web)
	}

	// A file and a line: the groups of a match become the path and an addr.
	if edit, err := vfs.open_path(vfs.boot_namespace, "/mnt/plumb/edit", vfs.O_RDONLY); check(r, err == vfs.OK, "a reader opens the edit port") {
		sent := plumb_send("verify", "", "text", "/lib/tests/tools.rc:3", "")
		check(r, sent, "a file and a line are taken by the edit rule")
		n, rerr := vfs.chan_read(edit, 0, msg[:])
		got := string(msg[:max(n, 0)])
		check(r, rerr == vfs.OK && libodin.contains(got, "addr=3\n") && libodin.contains(got, "\n19\n/lib/tests/tools.rc"), "and the file's path is the data and its line an addr attribute")
		vfs.chan_close(edit)
	}

	// A message with a destination goes there as it is. The ghost port is
	// held open from here, since the programs the rules start report there.
	ghost, gerr := vfs.open_path(vfs.boot_namespace, "/mnt/plumb/ghost", vfs.O_RDONLY)
	if check(r, gerr == vfs.OK, "a reader opens the ghost port") {
		sent := plumb_send("verify", "ghost", "text", "what is this", "")
		check(r, sent, "a message addressed to a port is taken with no rule")
		n, rerr := vfs.chan_read(ghost, 0, msg[:])
		got := string(msg[:max(n, 0)])
		check(r, rerr == vfs.OK && libodin.contains(got, "\n12\nwhat is this"), "and arrives there as it was")

		// A note nobody reads: the rule starts `plumb -d ghost started:kernel`,
		// which lands here. A marker sent after a patience means the read
		// below always has something to answer, so a program that never
		// started fails the check rather than parking it.
		check(r, plumb_send("verify", "", "text", "note:kernel", ""), "a note with no reader is taken by its rule")
		sync.delay(PATIENCE * 5)
		_ = plumb_send("verify", "ghost", "text", "marker one", "")
		n, rerr = vfs.chan_read(ghost, 0, msg[:])
		got = string(msg[:max(n, 0)])
		started := rerr == vfs.OK && libodin.contains(got, "started:kernel")
		check(r, started, "and the program the rule starts ran, by its words and not a shell, and said so through the plumber")
		if started {
			// The marker is queued behind it, and is taken off.
			_, _ = vfs.chan_read(ghost, 0, msg[:])
		}
	}

	// Nothing takes a message no rule matches.
	check(r, !plumb_send("verify", "", "text", "nothing takes this line", ""), "a message no rule takes is refused")

	// The shell, through cmd/plumb: refused the same line, and its note
	// starts the program too, heard on the ghost port the same way.
	snames := [?]string{"rc", "/lib/tests/plumb.rc"}
	if script_says(r, "/bin/rc", snames[:], PATIENCE * 40, "the shell starts on the plumb script", "ok", "and plumb from the shell was refused a line no rule takes, and sent its note") && gerr == vfs.OK {
		sync.delay(PATIENCE * 5)
		_ = plumb_send("verify", "ghost", "text", "marker two", "")
		n, rerr := vfs.chan_read(ghost, 0, msg[:])
		got := string(msg[:max(n, 0)])
		heard := rerr == vfs.OK && libodin.contains(got, "started:shell")
		if !heard && rerr == vfs.OK && !libodin.contains(got, "marker two") {
			// A late report from the first note; the marker is still queued.
			n, rerr = vfs.chan_read(ghost, 0, msg[:])
			got = string(msg[:max(n, 0)])
			heard = rerr == vfs.OK && libodin.contains(got, "started:shell")
		}
		check(r, heard, "and the shell's note started its program, which reported through the plumber")
	}
	if gerr == vfs.OK {
		vfs.chan_close(ghost)
	}
	reap_orphans()

	check(r, vfs.unmount_path(vfs.boot_namespace, "", "/mnt/plumb") == vfs.OK, "the mount of the plumber comes down")
	check(r, srv.remove("plumb") == vfs.OK, "and the kernel takes its name away")
	check(r, wait(p, PATIENCE * 5), "and the plumber, its pipe gone, exits")
	finish(r, p, "and is taken down")
	reap_orphans()
}

/*
verify_fedifs runs `servers/fedifs` on a saved Mastodon home timeline,
`docs/WEB.md` section 7's "a saved timeline from each network through a
pipe becomes a directory of the right shape". Three statuses land as
three messages in time order: the account's name and address as from,
created_at as the date, the content as an HTML body, the URL and the
attachment and the card as links, and the reply's in_reply_to_id
resolved to the first status's id. A file that is not a timeline is
refused, and so is a write to new, since there is no login yet.
*/
@(private = "file")
verify_fedifs :: proc(r: ^Result) {
	p := start_path(r, "/bin/fedifs", "the loader starts fedifs, the fediverse as conversations")
	if p == nil {
		return
	}
	if !check(r, await_posted("fedi"), "which posts /srv/fedi") || !check(r, srv.mount(vfs.boot_namespace, "/srv/fedi", "/mnt/fedi") == vfs.OK, "and the kernel mounts it at /mnt/fedi") {
		finish(r, p, "and fedifs is taken down")
		return
	}
	ID1 :: "000000006aad0ba0.113000000000000001"
	ID2 :: "000000006aad12a8.113000000000000002"
	ID3 :: "000000006aad19b0.113000000000000003"
	check(r, net_file_write("/mnt/fedi/ctl", "fetch /lib/tests/home.json"), "a saved home timeline's path written to ctl is fetched, and the write returns when it is in")
	check(r, !net_file_write("/mnt/fedi/ctl", "fetch /lib/tests/page.gmi"), "a file that is not a timeline is refused")
	check(r, !net_file_write("/mnt/fedi/new", "to nobody\n\nhello"), "and a write to new, with no login to post as")
	lbuf: [2048]u8
	check(r, dir_names("/mnt/fedi", lbuf[:]) == "ctl me new event dict notify home", "the network lists its files and the timeline, named for the file")
	check(r, dir_names("/mnt/fedi/home", lbuf[:]) == ID1 + " " + ID2 + " " + ID3, "the timeline lists its statuses by id, time order, the instance's id kept as the name")
	text: [2048]u8
	n := web_read_file("/mnt/fedi/home/" + ID1 + "/from", text[:])
	check(r, string(text[:max(n, 0)]) == "Glenda <glenda>", "from is the account's name and address")
	n = web_read_file("/mnt/fedi/home/" + ID2 + "/from", text[:])
	check(r, string(text[:max(n, 0)]) == "carol", "or the address alone when it has no name")
	n = web_read_file("/mnt/fedi/home/" + ID1 + "/date", text[:])
	check(r, string(text[:max(n, 0)]) == "1789725600 2026-09-18T10:00:00.000Z", "date is seconds since the epoch and the instance's text")
	n = web_read_file("/mnt/fedi/home/" + ID1 + "/body", text[:])
	check(r, string(text[:max(n, 0)]) == "<p>Hello, fediverse.</p>", "body is the content")
	n = web_read_file("/mnt/fedi/home/" + ID1 + "/type", text[:])
	check(r, string(text[:max(n, 0)]) == "text/html", "which is HTML, and type says so")
	n = web_read_file("/mnt/fedi/home/" + ID1 + "/links", text[:])
	check(r, string(text[:max(n, 0)]) == "https://one.example/@glenda/1\nhttps://one.example/about", "links is the status's URL and its card's")
	n = web_read_file("/mnt/fedi/home/" + ID2 + "/links", text[:])
	check(r, string(text[:max(n, 0)]) == "https://one.example/@carol/2\nhttps://one.example/media/2.png", "or its URL and its attachment's")
	n = web_read_file("/mnt/fedi/home/" + ID3 + "/replyto", text[:])
	check(r, string(text[:max(n, 0)]) == ID1, "a reply's in_reply_to_id becomes the first status's id")
	check(r, dir_names("/mnt/fedi/home/" + ID1 + "/replies", lbuf[:]) == ID3, "so replies under the first lists the reply")
	n = web_read_file("/mnt/fedi/home/" + ID3 + "/raw", text[:], raw = true)
	check(r, n > 0 && text[0] == '{' && libodin.contains(string(text[:n]), "\"id\": \"113000000000000003\""), "raw is the status as the instance sent it, its own bytes out of the array")
	n = web_read_file("/mnt/fedi/ctl", text[:])
	check(r, n > 0 && libodin.contains(string(text[:n]), "home 3 /lib/tests/home.json"), "a read of ctl says what the timeline holds and where it came from")
	n = read_once("/mnt/fedi/event", text[:])
	check(r, string(text[:max(n, 0)]) == "home/" + ID3 + "\n", "a read of event answers the first status that landed, the newest, since the instance lists them newest first")

	// What came back: notifications into notify, and a mention's status
	// into home, under replies of what it answered.
	ID4 :: "000000006aad243c.113000000000000004"
	N1 :: "000000006aad243c.900000000000000001"
	N2 :: "000000006aad27c0.900000000000000002"
	N3 :: "000000006aad2b44.900000000000000003"
	check(r, net_file_write("/mnt/fedi/ctl", "fetch notifications /lib/tests/notifications.json"), "a saved notifications answer's path is fetched into notify")
	check(r, dir_names("/mnt/fedi/notify", lbuf[:]) == N1 + " " + N2 + " " + N3, "and notify lists the three by id, time order")
	n = web_read_file("/mnt/fedi/notify/" + N1 + "/subject", text[:])
	check(r, string(text[:max(n, 0)]) == "mention", "a notification's kind is its subject")
	n = web_read_file("/mnt/fedi/notify/" + N1 + "/from", text[:])
	check(r, string(text[:max(n, 0)]) == "Bob Jones <bob@two.example>", "from is the account that did it")
	n = web_read_file("/mnt/fedi/notify/" + N1 + "/body", text[:])
	check(r, string(text[:max(n, 0)]) == "<p>@glenda a mention that answers.</p>", "body is the status it carries")
	n = web_read_file("/mnt/fedi/notify/" + N1 + "/replyto", text[:])
	check(r, string(text[:max(n, 0)]) == ID4, "and replyto names that status by its id")
	check(r, dir_names("/mnt/fedi/home", lbuf[:]) == ID1 + " " + ID2 + " " + ID3 + " " + ID4, "which landed in home")
	n = web_read_file("/mnt/fedi/home/" + ID4 + "/replyto", text[:])
	check(r, string(text[:max(n, 0)]) == ID1, "answering the first status")
	check(r, dir_names("/mnt/fedi/home/" + ID1 + "/replies", lbuf[:]) == ID3 + " " + ID4, "so replies under the first lists it beside the earlier reply: the link that came back")
	n = web_read_file("/mnt/fedi/notify/" + N2 + "/replyto", text[:])
	check(r, string(text[:max(n, 0)]) == ID1, "a favourite names the status favourited")
	n = web_read_file("/mnt/fedi/notify/" + N3 + "/from", text[:])
	check(r, string(text[:max(n, 0)]) == "Dave <dave@three.example>", "and a follow is from the follower")
	n = web_read_file("/mnt/fedi/notify/" + N3 + "/body", text[:])
	check(r, n == 0, "with nothing to say")

	// Any object by URL: a saved note, as a message of its own conversation.
	NOTE :: "000000006aad35d0.af5f29eabd18685e"
	check(r, net_file_write("/mnt/fedi/ctl", "object notes /lib/tests/note.json"), "a saved ActivityStreams object's path is fetched into a conversation of its own")
	check(r, dir_names("/mnt/fedi/notes", lbuf[:]) == NOTE, "which lists it under its URL's hash and its published date")
	n = web_read_file("/mnt/fedi/notes/" + NOTE + "/from", text[:])
	check(r, string(text[:max(n, 0)]) == "https://one.example/users/glenda", "from is who it is attributed to")
	n = web_read_file("/mnt/fedi/notes/" + NOTE + "/body", text[:])
	check(r, string(text[:max(n, 0)]) == "<p>An object by URL.</p>", "body is its content")
	n = web_read_file("/mnt/fedi/notes/" + NOTE + "/links", text[:])
	check(r, string(text[:max(n, 0)]) == "https://one.example/@glenda/7\nhttps://one.example/media/7.png", "and links its page and its attachment")
	check(r, vfs.unmount_path(vfs.boot_namespace, "", "/mnt/fedi") == vfs.OK, "the mount of fedifs comes down")
	check(r, srv.remove("fedi") == vfs.OK, "and the kernel takes its name away")
	check(r, wait(p, PATIENCE * 5), "and fedifs, its pipe gone, exits")
	finish(r, p, "and is taken down")
}

/*
verify_atfs runs `servers/atfs` on a saved AT timeline, a `getTimeline`
answer, `docs/WEB.md` section 7's other half of "a saved timeline from
each network through a pipe becomes a directory of the right shape".
Four posts land as four messages: the author's name and handle as
from, the record's createdAt as the date, its text as a plain body, its
page on the web and its image as links, and the reply's parent URI
resolved to the first post's id through the URI's hash. A record's CID
is made again from its JSON through libcid and served as hash, and one
altered after its CID was made reads empty with a line in notify. Then
the two networks' timelines bind after one another under /mnt/all and
list as one: docs/WEB.md step 4's "two saved timelines bound as one, a
record that fails its CID".
*/
@(private = "file")
verify_atfs :: proc(r: ^Result) {
	p := start_path(r, "/bin/atfs", "the loader starts atfs, the AT network as conversations")
	if p == nil {
		return
	}
	if !check(r, await_posted("at"), "which posts /srv/at") || !check(r, srv.mount(vfs.boot_namespace, "/srv/at", "/mnt/at") == vfs.OK, "and the kernel mounts it at /mnt/at") {
		finish(r, p, "and atfs is taken down")
		return
	}
	AT1 :: "000000006aad0f24.cdaa9ac7e2c76a9b"
	AT2 :: "000000006aad162c.9bab1ce9906bfd01"
	AT3 :: "000000006aad1d34.1b7ea8dcfa0c72aa"
	AT4 :: "000000006aad20b8.41f0a883e9334b00"
	check(r, net_file_write("/mnt/at/ctl", "fetch /lib/tests/timeline.json"), "a saved timeline's path written to ctl is fetched, and the write returns when it is in")
	check(r, !net_file_write("/mnt/at/ctl", "fetch /lib/tests/home.json"), "a file that is not an AT timeline, the fediverse's, is refused")
	lbuf: [2048]u8
	check(r, dir_names("/mnt/at/timeline", lbuf[:]) == AT1 + " " + AT2 + " " + AT3 + " " + AT4, "the timeline lists its posts by id, time order, sixteen hex digits of the URI's hash as the name")
	text: [2048]u8
	n := web_read_file("/mnt/at/timeline/" + AT1 + "/from", text[:])
	check(r, string(text[:max(n, 0)]) == "Alice <alice.one.example>", "from is the author's name and handle")
	n = web_read_file("/mnt/at/timeline/" + AT1 + "/date", text[:])
	check(r, string(text[:max(n, 0)]) == "1789726500 2026-09-18T10:15:00.000Z", "date is seconds since the epoch and the record's text")
	n = web_read_file("/mnt/at/timeline/" + AT1 + "/body", text[:])
	check(r, string(text[:max(n, 0)]) == "Hello, AT.", "body is the record's text")
	n = web_read_file("/mnt/at/timeline/" + AT1 + "/type", text[:])
	check(r, string(text[:max(n, 0)]) == "text/plain", "which is plain, and type says so")
	n = web_read_file("/mnt/at/timeline/" + AT2 + "/links", text[:])
	check(r, string(text[:max(n, 0)]) == "https://bsky.app/profile/carol.one.example/post/3kpic\nhttps://cdn.one.example/full/pic.png", "links is the post's page on the web and its image full size")
	n = web_read_file("/mnt/at/timeline/" + AT3 + "/replyto", text[:])
	check(r, string(text[:max(n, 0)]) == AT1, "a reply's parent URI becomes the first post's id, through the same hash")
	check(r, dir_names("/mnt/at/timeline/" + AT1 + "/replies", lbuf[:]) == AT3, "so replies under the first lists the reply")
	n = web_read_file("/mnt/at/timeline/" + AT3 + "/raw", text[:], raw = true)
	check(r, n > 0 && text[0] == '{' && libodin.contains(string(text[:n]), "\"uri\": \"at://did:plc:bob22/app.bsky.feed.post/3kreply\""), "raw is the feed item as the server sent it")

	// A record checks against its hash: the CID the server gave is the
	// hash of the record's DAG-CBOR made again from the JSON.
	n = web_read_file("/mnt/at/timeline/" + AT1 + "/hash", text[:])
	check(r, string(text[:max(n, 0)]) == "bafyreicetkpcso3otre6mxnejq6vqzrcnr6ajipdxq3mmtpviqjawpw4wi", "hash is the record's CID, the network's own name for it, since the record's DAG-CBOR hashes to it")
	n = web_read_file("/mnt/at/timeline/" + AT4 + "/hash", text[:])
	check(r, n == 0, "and a record whose text was altered after its CID was made reads an empty hash")
	check(r, dir_names("/mnt/at/notify", lbuf[:]) == AT4, "with a line in notify under its id")
	n = web_read_file("/mnt/at/notify/" + AT4 + "/body", text[:])
	check(r, string(text[:max(n, 0)]) == "at://did:plc:dave4/app.bsky.feed.post/3kbent", "that names the record by its URI")

	// What came back: notifications into notify, and a reply's post into
	// home, under replies of what it answered.
	AT5 :: "000000006aad243c.6de5409e1fd904a4"
	AN2 :: "000000006aad27c0.54af3754a5a62fc2"
	AN3 :: "000000006aad2b44.3577f531c1263a32"
	check(r, net_file_write("/mnt/at/ctl", "fetch home /lib/tests/timeline.json"), "the timeline is fetched again as home, the account's own")
	check(r, net_file_write("/mnt/at/ctl", "fetch notifications /lib/tests/atnotify.json"), "and a saved notifications answer's path into notify")
	check(r, dir_names("/mnt/at/notify", lbuf[:]) == AT4 + " " + AT5 + " " + AN2 + " " + AN3, "and notify lists the three beside the failed record's line, by id, time order")
	n = web_read_file("/mnt/at/notify/" + AT5 + "/subject", text[:])
	check(r, string(text[:max(n, 0)]) == "reply", "a notification's reason is its subject")
	n = web_read_file("/mnt/at/notify/" + AT5 + "/from", text[:])
	check(r, string(text[:max(n, 0)]) == "Bob Jones <bob.two.example>", "from is the account that did it")
	n = web_read_file("/mnt/at/notify/" + AT5 + "/replyto", text[:])
	check(r, string(text[:max(n, 0)]) == AT5, "and replyto names the post it carries")
	n = web_read_file("/mnt/at/home/" + AT5 + "/replyto", text[:])
	check(r, string(text[:max(n, 0)]) == AT1, "which landed in home, answering the first post")
	check(r, dir_names("/mnt/at/home/" + AT1 + "/replies", lbuf[:]) == AT3 + " " + AT5, "so replies under the first lists it beside the earlier reply: the link that came back")
	n = web_read_file("/mnt/at/home/" + AT5 + "/hash", text[:])
	check(r, n > 0 && libodin.has_prefix(string(text[:n]), "bafyrei"), "and its record checked against its CID on the way in")
	n = web_read_file("/mnt/at/notify/" + AN2 + "/replyto", text[:])
	check(r, string(text[:max(n, 0)]) == AT1, "a like names the post liked, by its subject")
	n = web_read_file("/mnt/at/notify/" + AN3 + "/from", text[:])
	check(r, string(text[:max(n, 0)]) == "Dave <dave.two.example>", "and a follow is from the follower")

	// A record by URI: a saved getRecord answer, checked against its CID.
	check(r, net_file_write("/mnt/at/ctl", "record records /lib/tests/record.json"), "a saved getRecord answer's path is fetched into a conversation of its own")
	check(r, dir_names("/mnt/at/records", lbuf[:]) == AT1, "which lists the record under its URI's hash and its date")
	n = web_read_file("/mnt/at/records/" + AT1 + "/from", text[:])
	check(r, string(text[:max(n, 0)]) == "did:plc:alice1", "from is the repository, since a record names no handle")
	n = web_read_file("/mnt/at/records/" + AT1 + "/hash", text[:])
	check(r, n > 0 && libodin.has_prefix(string(text[:n]), "bafyrei"), "and its value hashes to the CID beside it")

	// The union is the timeline: both networks' under one name.
	ID1 :: "000000006aad0ba0.113000000000000001"
	ID2 :: "000000006aad12a8.113000000000000002"
	ID3 :: "000000006aad19b0.113000000000000003"
	fedi := start_path(r, "/bin/fedifs", "fedifs starts again beside it")
	if fedi != nil {
		mounted := check(r, await_posted("fedi"), "and posts /srv/fedi") && check(r, srv.mount(vfs.boot_namespace, "/srv/fedi", "/mnt/fedi") == vfs.OK, "which the kernel mounts at /mnt/fedi")
		if mounted {
			check(r, net_file_write("/mnt/fedi/ctl", "fetch /lib/tests/home.json"), "with the fediverse's saved timeline in")
			bound := vfs.bind_path(vfs.boot_namespace, "/mnt/fedi/home", "/mnt/all", .After) == vfs.OK
			bound = vfs.bind_path(vfs.boot_namespace, "/mnt/at/timeline", "/mnt/all", .After) == vfs.OK && bound
			check(r, bound, "the two timelines bind after one another under /mnt/all")
			all := dir_names("/mnt/all", lbuf[:])
			check(r, count_words(all) == 7 && libodin.contains(all, ID1) && libodin.contains(all, AT1) && libodin.contains(all, ID2) && libodin.contains(all, AT2) && libodin.contains(all, ID3) && libodin.contains(all, AT3) && libodin.contains(all, AT4), "and the union lists all seven posts as one timeline, each network's in time order and a sort of the names the whole")
			n = web_read_file("/mnt/all/" + AT2 + "/body", text[:])
			check(r, string(text[:max(n, 0)]) == "A picture on AT.", "which reads either network's post by its id alone")
			check(r, vfs.unmount_path(vfs.boot_namespace, "", "/mnt/all") == vfs.OK, "the union comes apart")
			check(r, vfs.unmount_path(vfs.boot_namespace, "", "/mnt/fedi") == vfs.OK, "and the mount of fedifs comes down")
		}
		check(r, srv.remove("fedi") == vfs.OK, "and the kernel takes its name away")
		check(r, wait(fedi, PATIENCE * 5), "and it exits")
		finish(r, fedi, "and is taken down")
	}
	check(r, vfs.unmount_path(vfs.boot_namespace, "", "/mnt/at") == vfs.OK, "the mount of atfs comes down")
	check(r, srv.remove("at") == vfs.OK, "and the kernel takes its name away")
	check(r, wait(p, PATIENCE * 5), "and atfs, its pipe gone, exits")
	finish(r, p, "and is taken down")
}

/*
verify_matrixfs runs `servers/matrixfs` on a saved sync, docs/WEB.md
section 8's "a saved sync through a pipe becomes rooms of the right
shape". Two joined rooms land as two conversations, one named by its
state and one by its id made plain, their message events in time order
with the sender, the server's time, the body with the reply fallback
off, an image's media as a link, and a reply resolved to the event it
answers; and an invite is a line in notify from the inviter, the room's
name its body.
*/
@(private = "file")
verify_matrixfs :: proc(r: ^Result) {
	p := start_path(r, "/bin/matrixfs", "the loader starts matrixfs, rooms as conversations")
	if p == nil {
		return
	}
	if !check(r, await_posted("matrix"), "which posts /srv/matrix") || !check(r, srv.mount(vfs.boot_namespace, "/srv/matrix", "/mnt/matrix") == vfs.OK, "and the kernel mounts it at /mnt/matrix") {
		finish(r, p, "and matrixfs is taken down")
		return
	}
	E1 :: "000000006aad43e0.89750ae9d56358c1"
	E2 :: "000000006aad4ae8.7ffaf27067059faf"
	E3 :: "000000006aad51f0.5f4933fb2d4f4bdd"
	E4 :: "000000006aad4764.af05bd90f8d75c6b"
	INV :: "0000000000000000.31378611cdb298ad"
	check(r, net_file_write("/mnt/matrix/ctl", "sync /lib/tests/sync.json"), "a saved sync's path written to ctl is taken, and the write returns when the rooms are in")
	check(r, !net_file_write("/mnt/matrix/ctl", "sync /lib/tests/home.json"), "a file that is not a sync is refused")
	lbuf: [2048]u8
	listing := dir_names("/mnt/matrix", lbuf[:])
	check(r, libodin.contains(listing, " vectra") && libodin.contains(listing, " plain_one.example") && libodin.contains(listing, " devices") && count_words(listing) == 9, "the network lists its files, notify, devices, and the two rooms: one by its name, one by its id made plain")
	check(r, dir_names("/mnt/matrix/vectra", lbuf[:]) == E1 + " " + E2 + " " + E3 + " members typing", "a room lists its message events by id, time order, the event id's hash the name, and its two files after them")
	text: [2048]u8
	n := web_read_file("/mnt/matrix/vectra/members", text[:])
	check(r, string(text[:max(n, 0)]) == "@glenda:one.example\n@bob:two.example", "members is who the state says is in the room, one a line")
	n = web_read_file("/mnt/matrix/vectra/" + E1 + "/from", text[:])
	check(r, string(text[:max(n, 0)]) == "@glenda:one.example", "from is the sender's user id")
	n = web_read_file("/mnt/matrix/vectra/" + E1 + "/date", text[:])
	check(r, string(text[:max(n, 0)]) == "1789740000 2026-09-18T14:00:00.000Z", "date is the server's time, its milliseconds made seconds")
	n = web_read_file("/mnt/matrix/vectra/" + E1 + "/body", text[:])
	check(r, string(text[:max(n, 0)]) == "Hello, room.", "body is the event's text")
	n = web_read_file("/mnt/matrix/vectra/" + E2 + "/body", text[:])
	check(r, string(text[:max(n, 0)]) == "A reply in the room.", "a reply's body is its formatted body with the quoted reply taken off")
	n = web_read_file("/mnt/matrix/vectra/" + E2 + "/replyto", text[:])
	check(r, string(text[:max(n, 0)]) == E1, "and replyto names the event it answers")
	check(r, dir_names("/mnt/matrix/vectra/" + E1 + "/replies", lbuf[:]) == E2, "so replies under the first lists it")
	n = web_read_file("/mnt/matrix/vectra/" + E3 + "/links", text[:])
	check(r, string(text[:max(n, 0)]) == "https://one.example/_matrix/media/v3/download/one.example/abc123", "an image's media is a link, the mxc URI made a download URL")
	n = web_read_file("/mnt/matrix/vectra/" + E3 + "/raw", text[:], raw = true)
	check(r, n > 0 && text[0] == '{' && libodin.contains(string(text[:n]), "\"event_id\": \"$e3\"") && libodin.contains(string(text[:n]), "mxc://one.example/abc123"), "raw is the event's own bytes out of the sync")
	check(r, dir_names("/mnt/matrix/plain_one.example", lbuf[:]) == E4 + " members typing", "the unnamed room holds its one event")
	check(r, dir_names("/mnt/matrix/notify", lbuf[:]) == INV, "an invite is a line in notify")
	n = web_read_file("/mnt/matrix/notify/" + INV + "/from", text[:])
	check(r, string(text[:max(n, 0)]) == "@bob:two.example", "from the inviter")
	n = web_read_file("/mnt/matrix/notify/" + INV + "/body", text[:])
	check(r, string(text[:max(n, 0)]) == "secret", "with the room's name as its body")
	n = web_read_file("/mnt/matrix/ctl", text[:])
	check(r, n > 0 && libodin.contains(string(text[:n]), "room vectra !vectra:one.example"), "and ctl says each room's name and id")
	check(r, vfs.unmount_path(vfs.boot_namespace, "", "/mnt/matrix") == vfs.OK, "the mount of matrixfs comes down")
	check(r, srv.remove("matrix") == vfs.OK, "and the kernel takes its name away")
	check(r, wait(p, PATIENCE * 5), "and matrixfs, its pipe gone, exits")
	finish(r, p, "and is taken down")
}

/*
verify_modelfs runs `servers/modelfs` on the stub backend, docs/GHOST.md
step 0's boot line: a request written to the stub comes back as the
Messages API's stream events, one a read. The engine is a manual check;
the stub is what every ghost check runs against.
*/
@(private = "file")
verify_modelfs :: proc(r: ^Result) {
	names := [?]string{"modelfs", "-e", "/lib/tests/model.script"}
	argv := new(Argv)
	if !check(r, argv != nil && argv_from(argv, names[:]), "a record for modelfs's arguments") {
		return
	}
	p := start_path(r, "/bin/modelfs", "the loader starts modelfs, a model as files, the stub behind them", argv)
	if p == nil {
		return
	}
	if !check(r, await_posted("model"), "which posts /srv/model") {
		finish(r, p, "and modelfs is taken down")
		return
	}
	if !check(r, srv.mount(vfs.boot_namespace, "/srv/model", "/mnt/model") == vfs.OK, "and the kernel mounts it at /mnt/model") {
		finish(r, p, "and modelfs is taken down")
		return
	}
	text: [2048]u8
	n := web_read_file("/mnt/model/ctl", text[:])
	check(r, string(text[:max(n, 0)]) == "stub", "ctl names the models offered, the stub the one here")
	// A session off `new`, its number, then the request and the reply.
	n = web_read_file("/mnt/model/new", text[:])
	check(r, string(text[:max(n, 0)]) == "0", "a read of new answers a session number")
	lbuf: [512]u8
	check(r, dir_names("/mnt/model/0", lbuf[:]) == "ctl request reply usage", "a session lists its files")
	check(r, net_file_write("/mnt/model/0/request", "{\"model\": \"stub\", \"messages\": [{\"role\": \"user\", \"content\": \"say hello\"}], \"max_tokens\": 64}"), "the request goes to the model as the Messages API's JSON")
	// The reply is a stream: web_read_file reads it to its end, the events
	// one a read, concatenated as it accumulates them.
	n = web_read_file("/mnt/model/0/reply", text[:], raw = true)
	reply := string(text[:max(n, 0)])
	check(r, libodin.contains(reply, "\"type\": \"content_block_delta\"") && libodin.contains(reply, "\"text\": \"hello\"") && libodin.contains(reply, "\"text\": \", ghost\"") && libodin.contains(reply, "\"stop_reason\": \"end_turn\"") && libodin.contains(reply, "\"type\": \"message_stop\""), "and the reply comes back as the API's stream events: the text deltas and the stop, one a read, ended at the stream's end")
	check(r, count_lines(reply) == 7, "seven events, the ones the script named")
	n = web_read_file("/mnt/model/0/usage", text[:])
	check(r, n > 0 && libodin.contains(string(text[:n]), "out 7"), "and usage counts the tokens, the events out")
	check(r, net_file_write("/mnt/model/0/ctl", "hangup"), "hangup ends the session")
	check(r, vfs.unmount_path(vfs.boot_namespace, "", "/mnt/model") == vfs.OK, "the mount of modelfs comes down")
	check(r, srv.remove("model") == vfs.OK, "and the kernel takes its name away")
	check(r, wait(p, PATIENCE * 5), "and modelfs, its pipe gone, exits")
	finish(r, p, "and is taken down")
	reap_orphans()
}

/*
verify_ghost is `docs/GHOST.md` step 1's boot line: the ghost's loop over
the stub model, the sandbox its tools run in, and its control.

`memfs` is the task's directory, mounted at `/n/remote` and named to the
ghost as `work`. The stub's script, `tests/ghost.script`, is one turn of
tool calls. A write inside `/n/work` lands, and one outside is refused. A
`run curl` finds no `curl`, and a `read /proc/1/status` no `/proc`. A
write to a file a script changed since the read is stale. A `kill` parks
on `confirm`, and this answers no. A `bind` is refused, because the
namespace is locked. The log says each, and `ns` shows the table the
tools had.

The control is the ghost started with `-u`, which forks its tools without
`RFNOMNT`: the same `bind` then succeeds, so the check above is the lock
and not an accident of the table. Then `tests/ghost.rc` drives `ask`.

The mode check waits for `docs/FLEET.md` step 2's user `ghost`: the write
outside `/n/work` is refused because nothing writable is named there, and
the refusal is EROFS rather than a permission.
*/
@(private = "file")
verify_ghost :: proc(r: ^Result) {
	// The task's directory, in the namespace the ghost starts from.
	wnames := [?]string{"memfs", "/srv/ghostwork"}
	wargv := new(Argv)
	if !check(r, wargv != nil && argv_from(wargv, wnames[:]), "a record for memfs's arguments") {
		return
	}
	wp := start_path(r, "/bin/memfs", "memfs starts, the ghost's work directory", wargv)
	if wp == nil {
		return
	}
	check(r, wait(wp, PATIENCE * 5), "and leaves its server behind, detached")
	finish(r, wp, "and its first half is collected")
	if !check(r, await_posted("ghostwork") && srv.mount(vfs.boot_namespace, "/srv/ghostwork", "/n/remote") == vfs.OK, "which is mounted at /n/remote") {
		return
	}

	mnames := [?]string{"modelfs", "-e", "/lib/tests/ghost.script"}
	margv := new(Argv)
	if !check(r, margv != nil && argv_from(margv, mnames[:]), "a record for modelfs's arguments") {
		return
	}
	mp := start_path(r, "/bin/modelfs", "the stub model starts on the ghost's script", margv)
	if mp == nil {
		return
	}
	if !check(r, await_posted("model") && srv.mount(vfs.boot_namespace, "/srv/model", "/mnt/model") == vfs.OK, "and is mounted at /mnt/model") {
		finish(r, mp, "and modelfs is taken down")
		return
	}

	text: [8192]u8
	gp := ghost_start(r, false)
	if gp != nil {
		n := web_read_file("/mnt/ghost/new", text[:])
		check(r, string(text[:max(n, 0)]) == "0", "a read of new answers a session")
		lbuf: [256]u8
		check(r, dir_names("/mnt/ghost/0", lbuf[:]) == "ctl prompt reply confirm log status tools ns", "which lists its eight files")
		check(r, net_file_write("/mnt/ghost/0/ctl", "work /n/remote"), "ctl names the work directory")
		check(r, !net_file_write("/mnt/ghost/0/ctl", "class ../post"), "and refuses a class that is not one word")
		n = web_read_file("/mnt/ghost/0/tools", text[:])
		tools := string(text[:max(n, 0)])
		check(r, libodin.contains(tools, "\"name\": \"read\"") && libodin.contains(tools, "\"name\": \"run\"") && libodin.contains(tools, "\"name\": \"look\""), "tools is the seven, as the API's JSON")

		// The namespace the tools will have, printed by a sandbox child.
		n = web_read_file("/mnt/ghost/0/ns", text[:], raw = true)
		ns := string(text[:max(n, 0)])
		if !check(r, libodin.contains(ns, "/n/remote /n/work") && libodin.contains(ns, " /bin\n"), "ns shows the class's binds: the work directory at /n/work, and the tools") {
			_ = net_file_write("/dev/cons", ns)
		}
		check(r, n > 0 && !libodin.contains(ns, "/proc") && !libodin.contains(ns, "/mnt/model") && !libodin.contains(ns, "/mnt/ghost") && !libodin.contains(ns, "/srv"), "and nothing the class did not name: no /proc, no model, no ghost, no /srv")

		check(r, net_file_write("/mnt/ghost/0/prompt", "do the sandbox checks"), "the prompt starts a turn")
		// The kill parks the turn on confirm, and this read parks with it.
		q: [256]u8
		qn := read_once("/mnt/ghost/0/confirm", q[:])
		check(r, qn > 0 && string(q[:qn]) == "run kill 1\n", "a script that names kill parks on confirm, and the read answers the question")
		n = web_read_file("/mnt/ghost/0/status", text[:])
		check(r, string(text[:max(n, 0)]) == "Waiting", "while status says Waiting")
		check(r, net_file_write("/mnt/ghost/0/confirm", "no"), "the answer is no")
		n = web_read_file("/mnt/ghost/0/reply", text[:], raw = true)
		check(r, string(text[:max(n, 0)]) == "done", "the reply streams the answer's text, and ends with the turn")
		n = web_read_file("/mnt/ghost/0/status", text[:])
		check(r, string(text[:max(n, 0)]) == "Idle", "and status is Idle")

		n = web_read_file("/mnt/ghost/0/log", text[:], raw = true)
		log := string(text[:max(n, 0)])
		ghost_logv(r, log, "tool write {\"path\": \"/n/work/note\", \"text\": \"hello\"}\n  ok wrote 5 bytes", "a write inside /n/work lands")
		ghost_logv(r, log, "\"/lib/note\", \"text\": \"x\"}\n  error EROFS", "and one outside it is refused, nothing writable named there (the mode check waits for the user ghost)")
		ghost_logv(r, log, "curl: not found", "run curl finds no curl")
		ghost_logv(r, log, "/proc/1/status\"}\n  error ENOENT", "read /proc/1/status finds no /proc")
		ghost_logv(r, log, "\"mine\"}\n  error stale", "a write to a file a script changed since the read is stale")
		ghost_logv(r, log, "confirm run kill 1\n  answer no\n  error the person said no", "the kill waited on confirm and the no refused it")
		ghost_logv(r, log, "bind: /n/work on /bin: EPERM", "and a bind is refused: the namespace is locked")
		wrote := web_read_file("/n/remote/note", q[:])
		check(r, string(q[:max(wrote, 0)]) == "changed", "the file holds what the script wrote, not the stale write")
		check(r, net_file_write("/mnt/ghost/0/ctl", "hangup"), "hangup ends the session")
		ghost_stop(r, gp)
	}

	// The control: the tools forked without the lock.
	gp = ghost_start(r, true)
	if gp != nil {
		n := web_read_file("/mnt/ghost/new", text[:])
		check(r, n > 0 && net_file_write("/mnt/ghost/0/ctl", "work /n/remote") && net_file_write("/mnt/ghost/0/prompt", "the control"), "the control ghost takes a session and a prompt")
		n = web_read_file("/mnt/ghost/0/reply", text[:], raw = true)
		check(r, string(text[:max(n, 0)]) == "control done", "and ends its turn")
		n = web_read_file("/mnt/ghost/0/log", text[:], raw = true)
		log := string(text[:max(n, 0)])
		if !check(r, libodin.contains(log, "  ok bound") && !libodin.contains(log, "EPERM"), "control: without RFNOMNT the same bind succeeds, so the sandbox check fails without the lock") {
			_ = net_file_write("/dev/cons", log)
		}
		ghost_stop(r, gp)
	}

	// `ask`, the line client, from the shell.
	gp = ghost_start(r, false)
	if gp != nil {
		names := [?]string{"rc", "/lib/tests/ghost.rc"}
		script_says(r, "/bin/rc", names[:], PATIENCE * 50, "the shell starts on the ask script", "ok", "ask streams the answer to its terminal")
		ghost_stop(r, gp)
	}

	ghost_social(r, text[:])

	check(r, vfs.unmount_path(vfs.boot_namespace, "", "/mnt/model") == vfs.OK, "the mount of modelfs comes down")
	check(r, srv.remove("model") == vfs.OK, "and its name")
	check(r, wait(mp, PATIENCE * 5), "and modelfs exits")
	finish(r, mp, "and is taken down")
	check(r, vfs.unmount_path(vfs.boot_namespace, "", "/n/remote") == vfs.OK, "the work directory's mount comes down")
	check(r, srv.remove("ghostwork") == vfs.OK, "and its name, which ends memfs")
	reap_orphans()
}

/*
ghost_social is `docs/WEB.md` step 6's last clause: the ghost reads a
timeline in the `social` class. `feedfs` serves the saved atom feed at
`/mnt/feed`, and the class binds it with `bind -r`. The ghost lists the
conversation and reads an entry's body. A change to the network, a
`fetch` written to its `ctl`, answers EROFS. The model, which no class
names, answers no such file.
*/
@(private = "file")
ghost_social :: proc(r: ^Result, text: []u8) {
	names := [?]string{"feedfs"}
	argv := new(Argv)
	if !check(r, argv != nil && argv_from(argv, names[:]), "a record for feedfs's arguments") {
		return
	}
	fp := start_path(r, "/bin/feedfs", "feedfs starts, the timeline the social class reads", argv)
	if fp == nil {
		return
	}
	if !check(r, await_posted("feed") && srv.mount(vfs.boot_namespace, "/srv/feed", "/mnt/feed") == vfs.OK, "and is mounted at /mnt/feed") {
		finish(r, fp, "and feedfs is taken down")
		return
	}
	check(r, net_file_write("/mnt/feed/ctl", "fetch /lib/tests/one.atom"), "the saved atom feed is fetched")

	gp := ghost_start(r, false)
	if gp != nil {
		n := web_read_file("/mnt/ghost/new", text)
		check(r, n > 0 && net_file_write("/mnt/ghost/0/ctl", "class social") && net_file_write("/mnt/ghost/0/prompt", "what is new in my feeds"), "a session in the social class takes the prompt")
		n = web_read_file("/mnt/ghost/0/reply", text, raw = true)
		check(r, string(text[:max(n, 0)]) == "Hello, feed.", "and answers with what the timeline said")
		n = web_read_file("/mnt/ghost/0/log", text, raw = true)
		log := string(text[:max(n, 0)])
		ghost_logv(r, log, "tool ls {\"path\": \"/mnt/feed/one\"}\n  ok 000000006aaa4c80.5755209cc066ae5a/", "the ghost lists the conversation, its entries by id")
		ghost_logv(r, log, "/body\"}\n  ok Hello, feed.", "and reads an entry's body")
		ghost_logv(r, log, "rc: /mnt/feed/ctl: EROFS", "a change to the network is refused: the class binds it read only")
		ghost_logv(r, log, "\"/mnt/model/ctl\"}\n  error ENOENT", "and the model, in no class, is not there")
		n = web_read_file("/mnt/ghost/0/ns", text, raw = true)
		check(r, libodin.contains(string(text[:max(n, 0)]), "bind -r /mnt/feed /mnt/feed"), "ns shows the read-only bind")
		check(r, dir_names("/mnt/feed", text) == "ctl me new event dict notify one", "and the network outside the sandbox took no fetch")
		ghost_stop(r, gp)
	}

	check(r, vfs.unmount_path(vfs.boot_namespace, "", "/mnt/feed") == vfs.OK, "the mount of feedfs comes down")
	check(r, srv.remove("feed") == vfs.OK, "and its name")
	check(r, wait(fp, PATIENCE * 5), "and feedfs exits")
	finish(r, fp, "and is taken down")
}

// ghost_start starts the ghost, `-u` for the control, and mounts it.
@(private = "file")
ghost_start :: proc(r: ^Result, unlocked: bool) -> ^Process {
	names := [?]string{"ghost", "-u"}
	argv := new(Argv)
	if !check(r, argv != nil && argv_from(argv, names[:unlocked ? 2 : 1]), "a record for the ghost's arguments") {
		return nil
	}
	p := start_path(r, "/bin/ghost", unlocked ? "the ghost starts unlocked, the control" : "the ghost starts, an agent over the stub", argv)
	if p == nil {
		return nil
	}
	if !check(r, await_posted("ghost") && srv.mount(vfs.boot_namespace, "/srv/ghost", "/mnt/ghost") == vfs.OK, "and is mounted at /mnt/ghost") {
		finish(r, p, "and the ghost is taken down")
		return nil
	}
	return p
}

@(private = "file")
ghost_stop :: proc(r: ^Result, p: ^Process) {
	check(r, vfs.unmount_path(vfs.boot_namespace, "", "/mnt/ghost") == vfs.OK, "the ghost's mount comes down")
	check(r, srv.remove("ghost") == vfs.OK, "and its name")
	check(r, wait(p, PATIENCE * 5), "and the ghost, its pipe gone, exits")
	finish(r, p, "and is taken down")
}

// ghost_logv checks the log holds `want`, and echoes the log to the
// console when it does not, so one boot shows every step the ghost took.
@(private = "file")
ghost_logv :: proc(r: ^Result, log: string, want: string, what: string) {
	if !check(r, libodin.contains(log, want), what) {
		_ = net_file_write("/dev/cons", log)
	}
}

/*
verify_feedfs runs `servers/feedfs` on two saved feeds, the offline proof of
`docs/WEB.md` section 4's shape. A feed's path written to `ctl` makes a
conversation of its entries, each a directory of files, in time order by
name. A reply is walked under the message it answers. The two conversations
bound together under `/mnt/all` list as one timeline. A write to `new` is
refused, since a feed is read only. Then the shell runs `tests/feed.rc`,
which reads the union with `ls` and `cat`.
*/
@(private = "file")
verify_feedfs :: proc(r: ^Result) {
	names := [?]string{"feedfs"}
	argv := new(Argv)
	if !check(r, argv != nil && argv_from(argv, names[:]), "a record for feedfs's arguments") {
		return
	}
	p := start_path(r, "/bin/feedfs", "the loader starts feedfs, the first network", argv)
	if p == nil {
		return
	}
	if !check(r, await_posted("feed"), "which posts /srv/feed") {
		finish(r, p, "and feedfs is taken down")
		return
	}
	if !check(r, srv.mount(vfs.boot_namespace, "/srv/feed", "/mnt/feed") == vfs.OK, "and the kernel mounts it at /mnt/feed") {
		finish(r, p, "and feedfs is taken down")
		return
	}

	ID1 :: "000000006aaa4c80.5755209cc066ae5a"
	ID2 :: "000000006aab96f8.6ccf908bcc1f4bee"
	ID3 :: "000000006aad106e.7f920dcf24c8d8b8"
	check(r, net_file_write("/mnt/feed/ctl", "fetch /lib/tests/one.atom"), "a saved atom feed's path written to ctl is fetched, and the write returns when it is in")
	check(r, net_file_write("/mnt/feed/ctl", "fetch /lib/tests/two.rss"), "and a saved rss feed's")
	check(r, !net_file_write("/mnt/feed/ctl", "fetch /lib/tests/page.gmi"), "a file that is not a feed is refused")
	check(r, !net_file_write("/mnt/feed/new", "to nobody\n\nhello"), "a write to new is refused: a feed is read only")

	lbuf: [2048]u8
	check(r, dir_names("/mnt/feed", lbuf[:]) == "ctl me new event dict notify one two", "the network lists its six files and a conversation a feed")
	check(r, dir_names("/mnt/feed/one", lbuf[:]) == ID1 + " " + ID2 + " " + ID3, "a conversation lists its entries by id, which is time order")
	check(r, dir_names("/mnt/feed/one/" + ID1, lbuf[:]) == "from date subject body type raw hash replyto replies links", "and an entry is the shape's files")
	text: [1024]u8
	n := web_read_file("/mnt/feed/one/" + ID1 + "/subject", text[:])
	check(r, string(text[:max(n, 0)]) == "First post", "subject is the entry's title")
	n = web_read_file("/mnt/feed/one/" + ID1 + "/from", text[:])
	check(r, string(text[:max(n, 0)]) == "Glenda", "from is its author")
	n = web_read_file("/mnt/feed/one/" + ID1 + "/date", text[:])
	check(r, string(text[:max(n, 0)]) == "1789545600 2026-09-16T08:00:00Z", "date is seconds since the epoch and the feed's text")
	n = web_read_file("/mnt/feed/one/" + ID1 + "/body", text[:])
	check(r, string(text[:max(n, 0)]) == "Hello, feed.", "body is its text")
	n = web_read_file("/mnt/feed/one/" + ID1 + "/type", text[:])
	check(r, string(text[:max(n, 0)]) == "text/plain", "type is the body's media type")
	n = web_read_file("/mnt/feed/one/" + ID1 + "/hash", text[:])
	check(r, string(text[:max(n, 0)]) == "6eea6772cb789a929f6bbac871317104021d3142e6339852979151b1934b86e3", "hash is sha256 of the entry's own markup")
	n = web_read_file("/mnt/feed/one/" + ID1 + "/links", text[:])
	check(r, string(text[:max(n, 0)]) == "https://one.example/1", "links is what it points at")
	n = web_read_file("/mnt/feed/one/" + ID3 + "/replyto", text[:])
	check(r, string(text[:max(n, 0)]) == ID1, "a reply names the id it answers")
	check(r, dir_names("/mnt/feed/one/" + ID1 + "/replies", lbuf[:]) == ID3 && dir_names("/mnt/feed/one/" + ID3 + "/replies", lbuf[:]) == "", "and replies under the first entry lists the reply, and under the reply nothing")
	n = web_read_file("/mnt/feed/one/" + ID1 + "/replies/" + ID3 + "/subject", text[:])
	check(r, string(text[:max(n, 0)]) == "Re: First post", "walked one level down, the reply is the same shape")
	n = web_read_file("/mnt/feed/ctl", text[:])
	check(r, n > 0 && libodin.contains(string(text[:n]), "one 3 /lib/tests/one.atom") && libodin.contains(string(text[:n]), "two 2 /lib/tests/two.rss"), "a read of ctl says what each feed holds and where it came from")
	// One read, since a read of event is one line and the file never ends.
	n = read_once("/mnt/feed/event", text[:])
	check(r, string(text[:max(n, 0)]) == "one/" + ID2 + "\n", "a read of event answers the first entry that landed, the file's first")
	n = web_read_file("/mnt/feed/dict", text[:])
	check(r, n > 0 && libodin.contains(string(text[:n]), "fetch name url"), "and dict names the verbs")

	// The union is the timeline.
	bound := vfs.bind_path(vfs.boot_namespace, "/mnt/feed/one", "/mnt/all", .After) == vfs.OK
	bound = vfs.bind_path(vfs.boot_namespace, "/mnt/feed/two", "/mnt/all", .After) == vfs.OK && bound
	check(r, bound, "two conversations bind after one another under /mnt/all")
	all := dir_names("/mnt/all", lbuf[:])
	check(r, libodin.contains(all, ID1) && libodin.contains(all, ID3) && libodin.contains(all, "000000006aa9922c.older") && libodin.contains(all, "000000006aac8284.cdeb28bad934d3fd") && count_words(all) == 5, "and the union lists all five entries as one timeline")
	n = web_read_file("/mnt/all/000000006aa9922c.older/subject", text[:])
	check(r, string(text[:max(n, 0)]) == "Older news", "which reads either feed's entry by its id alone")
	check(r, vfs.unmount_path(vfs.boot_namespace, "", "/mnt/all") == vfs.OK, "the union comes apart")

	snames := [?]string{"rc", "/lib/tests/feed.rc"}
	script_says(r, "/bin/rc", snames[:], PATIENCE * 40, "the shell starts on the feed script", "ok", "and the shell bound the two feeds and read the timeline in order, first to last")
	reap_orphans()

	// The LEDs, `docs/CHROME.md` section 10: `srvstat` reads a posted
	// server green, a missing name off, and a `status` word amber or red.
	lnames := [?]string{"rc", "/lib/tests/srvstat.rc"}
	script_says(r, "/bin/rc", lnames[:], PATIENCE * 40, "the shell starts on the srvstat script", "ok", "and srvstat names feed green, a missing name off, and kfs amber and red by its status word")
	reap_orphans()

	// The reading half: a program reads the conversation back from its files.
	dnames := [?]string{"doctest", "msgs", "/mnt/feed/one"}
	script_says(r, "/bin/doctest", dnames[:], PATIENCE * 5, "a program on the message shape starts on the conversation", "ok", "and reads its rows, a message, and a reply back from the files")
	reap_orphans()

	// The reader on the conversation: a timeline, one link row a message.
	// A link's ink is one the desktop under it does not wear, so its
	// arrival on the glass is the timeline drawn.
	if s := devfs.raw_surface(); s != nil && s.pixels != nil && s.bytes_pp == 4 {
		count0 := srv.count()
		if ps := start_draw_server(r, s, "the loader starts the draw server for the timeline", "which posts /srv/draw for the reader to find", "and paints a desktop before the reader opens a window"); ps != nil {
			link := fb.RGB{0x38, 0xE0, 0xE8}
			had_link := glass_has(s, link)
			mnames := [?]string{"mothra", "/mnt/feed/one"}
			margv := new(Argv)
			_ = argv_from(margv, mnames[:])
			if pm := start_path(r, "/bin/mothra", "the loader starts the reader on the conversation", margv); pm != nil {
				bx, _, _ := await_bar(s)
				check(r, bx >= 0, "and the reader opens a framed window on it")
				landed := false
				for _ in 0 ..< PATIENCE * 20 {
					landed = glass_has(s, link)
					if landed {
						break
					}
					sync.delay(1)
				}
				check(r, !had_link && landed, "and the timeline's link rows reach the glass in the link's ink, which nothing under them wore")
				_ = notepg_kernel(pm.note_group, "kill")
				check(r, end(pm, PATIENCE * 5), "and the reader, told to end, ends")
				finish(r, pm, "and is taken down")
			}
			// A message: the page on the left, and in the column its reply.
			enames := [?]string{"mothra", "/mnt/feed/one/" + ID1}
			eargv := new(Argv)
			_ = argv_from(eargv, enames[:])
			if pe := start_path(r, "/bin/mothra", "the loader starts the reader on the first entry", eargv); pe != nil {
				bx, by, bw := await_bar(s)
				check(r, bx >= 0, "and the reader opens a framed window on the message")
				in_column := false
				for _ in 0 ..< PATIENCE * 20 {
					in_column = bx >= 0 && glass_has_in(s, link, bx + bw * 2 / 3, bx + bw, by)
					if in_column {
						break
					}
					sync.delay(1)
				}
				check(r, in_column, "and the column beside it shows the reply as a link row")
				_ = notepg_kernel(pe.note_group, "kill")
				check(r, end(pe, PATIENCE * 5), "and the reader, told to end, ends")
				finish(r, pe, "and is taken down")
			}
			stop_draw_server(r, ps, count0)
		}
	}
	reap_orphans()

	check(r, vfs.unmount_path(vfs.boot_namespace, "", "/mnt/feed") == vfs.OK, "the mount of feedfs comes down")
	check(r, srv.remove("feed") == vfs.OK, "and the kernel takes its name away")
	check(r, wait(p, PATIENCE * 5), "and feedfs, its pipe gone, exits")
	finish(r, p, "and is taken down")
	reap_orphans()
}

/*
verify_securejoin runs Delta Chat's verification handshake between the
mailfs at /mnt/mail, Glenda, and a second at /mnt/mail2, Bob, both with
their identities in factotum, over a spool of files under /usr/glenda.
The control comes first: an invite with a fingerprint that is not
Glenda's stops Bob at the second step, and verified stays no on both
sides. Then the invite as made: four fetches later, verified reads yes on
both. That is docs/WEB.md section 6's "a SecureJoin between two mailfs on
a pipe ends with verified on both sides, and one control ends with no".
*/
@(private = "file")
verify_securejoin :: proc(r: ^Result, host: string) {
	bargs := [?]string{"mailfs", "-s", "mail2"}
	bargv := new(Argv)
	_ = argv_from(bargv, bargs[:])
	pb := start_path(r, "/bin/mailfs", "a second mailfs starts, Bob's, posting another name", bargv)
	if pb == nil {
		return
	}
	if !check(r, await_posted("mail2"), "which posts /srv/mail2") || !check(r, srv.mount(vfs.boot_namespace, "/srv/mail2", "/mnt/mail2") == vfs.OK, "and the kernel mounts it at /mnt/mail2") {
		finish(r, pb, "and Bob's mailfs is taken down")
		return
	}
	line_buf: [512]u8
	check(r, net_file_write("/mnt/mail2/ctl", libodin_cat(line_buf[:], "account bob ", host, " 1143 plain")), "Bob's account")
	check(r, net_file_write("/mnt/mail2/ctl", "identity home"), "and his identity, factotum's second key")
	check(r, net_file_write("/mnt/mail2/ctl", "spool /usr/glenda/spool"), "and both sides on one spool of files")
	check(r, net_file_write("/mnt/mail/ctl", "spool /usr/glenda/spool"), "instead of the servers")
	text: [4096]u8

	// The control: the invite with a fingerprint that is not Glenda's.
	check(r, net_file_write("/mnt/mail/ctl", "invite"), "Glenda makes an invite")
	n := web_read_file("/mnt/mail/ctl", text[:])
	invite := invite_line(string(text[:max(n, 0)]))
	check(r, len(invite) > 100 && libodin.has_prefix(invite, "OPENPGP4FPR:"), "which ctl shows: her fingerprint, address and the two secrets")
	bent: [512]u8
	bn := copy(bent[:], invite)
	bent[12] = bent[12] == '0' ? '1' : '0'
	check(r, net_file_write("/mnt/mail2/ctl", libodin_cat(line_buf[:], "join ", string(bent[:bn]))), "Bob joins an invite whose fingerprint is bent, and his request goes out plain with his key")
	check(r, net_file_write("/mnt/mail/ctl", "fetch") && net_file_write("/mnt/mail2/ctl", "fetch") && net_file_write("/mnt/mail/ctl", "fetch") && net_file_write("/mnt/mail2/ctl", "fetch"), "the sides fetch in turn")
	n = web_read_file(libodin_cat(line_buf[:], "/mnt/mail2/contacts/glenda@", host, "/verified"), text[:])
	check(r, string(text[:max(n, 0)]) == "no", "and Bob stopped at the key that was not the invite's: Glenda stays unverified with him")
	n = web_read_file(libodin_cat(line_buf[:], "/mnt/mail/contacts/bob@", host, "/verified"), text[:])
	check(r, string(text[:max(n, 0)]) == "no", "and Bob stays unverified with her, no auth having come")

	// The invite as made.
	check(r, net_file_write("/mnt/mail/ctl", "invite"), "Glenda makes a fresh invite")
	n = web_read_file("/mnt/mail/ctl", text[:])
	invite = invite_line(string(text[:max(n, 0)]))
	check(r, net_file_write("/mnt/mail2/ctl", libodin_cat(line_buf[:], "join ", invite)), "and Bob joins it")
	check(r, net_file_write("/mnt/mail/ctl", "fetch") && net_file_write("/mnt/mail2/ctl", "fetch") && net_file_write("/mnt/mail/ctl", "fetch") && net_file_write("/mnt/mail2/ctl", "fetch"), "the sides fetch in turn: request, auth-required, request-with-auth, confirm")
	n = web_read_file(libodin_cat(line_buf[:], "/mnt/mail/contacts/bob@", host, "/verified"), text[:])
	check(r, string(text[:max(n, 0)]) == "yes", "and Bob is verified with Glenda: his auth and fingerprint held")
	n = web_read_file(libodin_cat(line_buf[:], "/mnt/mail2/contacts/glenda@", host, "/verified"), text[:])
	check(r, string(text[:max(n, 0)]) == "yes", "and Glenda with Bob: her key was the invite's, and her confirm came sealed")

	check(r, net_file_write("/mnt/mail/ctl", "spool off"), "Glenda goes back to her servers")
	check(r, vfs.unmount_path(vfs.boot_namespace, "", "/mnt/mail2") == vfs.OK, "the mount of Bob's mailfs comes down")
	check(r, srv.remove("mail2") == vfs.OK, "and the kernel takes its name away")
	check(r, wait(pb, PATIENCE * 5), "and it exits")
	finish(r, pb, "and is taken down")
}

/*
verify_idle runs the servers between two mailfs: `tests/smtpsrv -d`, a
relay that delivers into a directory of mailboxes, and `tests/imapsrv -m`
over each mailbox, which answers IDLE. Glenda's mailfs and Bob's each
keep a session idling. A message Bob writes to new crosses the relay and
lands in Glenda's inbox with no fetch asked, and her event answers with
it: docs/WEB.md section 6's "IDLE is the read that parks, so event
answers the moment the server has something". Then the SecureJoin
handshake runs the same way, Bob inviting and Glenda joining, each step
taken as it lands and answered on a sender thread, and ends with Glenda
verified with Bob: the handshake over the servers.
*/
@(private = "file")
verify_idle :: proc(r: ^Result, host: string) {
	RELAY :: "/usr/glenda/relay"
	gbox: [128]u8
	bbox: [128]u8
	glenda_box := libodin_cat(gbox[:], RELAY, "/glenda@", host)
	bob_box := libodin_cat(bbox[:], RELAY, "/bob@", host)

	// The servers: a mailbox each, and the relay between.
	ga := [?]string{"imapsrv", "1144", "-m", glenda_box, "glenda", "hunter2"}
	gargv := new(Argv)
	_ = argv_from(gargv, ga[:])
	pg := start_path(r, "/bin/imapsrv", "a mailbox server starts over Glenda's directory of the relay", gargv)
	if pg == nil {
		return
	}
	ba := [?]string{"imapsrv", "1145", "-m", bob_box, "bob", "hunter2"}
	bargv := new(Argv)
	_ = argv_from(bargv, ba[:])
	pbs := start_path(r, "/bin/imapsrv", "and one over Bob's", bargv)
	ra := [?]string{"smtpsrv", "1588", "-d", RELAY}
	rargv := new(Argv)
	_ = argv_from(rargv, ra[:])
	prs := start_path(r, "/bin/smtpsrv", "and the relay, which delivers into those directories", rargv)
	sync.delay(PATIENCE)

	line_buf: [512]u8
	text: [2048]u8
	if pbs != nil && prs != nil {
		checkv(r, net_file_write("/mnt/factotum/ctl", libodin_cat(line_buf[:], "key proto=pass user=bob server=", host, " !password=hunter2")), "Bob's password goes to factotum, for his login and his submission")

		// Glenda's session.
		checkv(r, net_file_write("/mnt/mail/ctl", libodin_cat(line_buf[:], "account glenda ", host, " 1144 plain")), "Glenda's account moves to the server over her relay mailbox")
		checkv(r, net_file_write("/mnt/mail/ctl", libodin_cat(line_buf[:], "smtp ", host, " 1588 plain")), "and her submission to the relay")
		n := 0

		// Bob's mailfs, before either session idles: a program starting
		// beside a mailbox server's polling of the disk posts late.
		bm := [?]string{"mailfs", "-s", "mail2"}
		bmargv := new(Argv)
		_ = argv_from(bmargv, bm[:])
		pb := start_path(r, "/bin/mailfs", "Bob's mailfs starts again", bmargv)
		if pb != nil {
			mounted := checkv(r, await_posted("mail2"), "which posts /srv/mail2") && checkv(r, srv.mount(vfs.boot_namespace, "/srv/mail2", "/mnt/mail2") == vfs.OK, "and the kernel mounts it at /mnt/mail2")
			if mounted {
				checkv(r, net_file_write("/mnt/mail2/ctl", libodin_cat(line_buf[:], "account bob ", host, " 1145 plain")), "Bob's account is the server over his mailbox")
				checkv(r, net_file_write("/mnt/mail2/ctl", "identity home"), "and his identity")
				checkv(r, net_file_write("/mnt/mail2/ctl", libodin_cat(line_buf[:], "smtp ", host, " 1588 plain")), "and his submission to the same relay")

				// The sessions.
				checkv(r, net_file_write("/mnt/mail/ctl", "idle"), "idle logs in, selects the inbox, and the write returns once Glenda's session idles")
				n = web_read_file("/mnt/mail/ctl", text[:])
				checkv(r, n > 0 && libodin.contains(string(text[:n]), "idle\n"), "which ctl says")
				checkv(r, net_file_write("/mnt/mail2/ctl", "idle"), "and Bob's session idles too")

				// A message over the servers, with no fetch asked.
				before_buf: [2048]u8
				before := dir_names("/mnt/mail/inbox", before_buf[:])
				checkv(r, net_file_write("/mnt/mail2/new", libodin_cat(line_buf[:], "to: glenda@", host, "\nsubject: over the servers\n\nno fetch asked\n")), "Bob writes a message to Glenda, and the relay takes it")
				after_buf: [2048]u8
				after := ""
				landed := false
				for _ in 0 ..< PATIENCE * 10 {
					after = dir_names("/mnt/mail/inbox", after_buf[:])
					if count_words(after) > count_words(before) {
						landed = true
						break
					}
					sync.delay(1)
				}
				checkv(r, landed, "and it lands in Glenda's inbox with no fetch asked: her server said a message came under IDLE, and her session took it")
				fresh := new_word(before, after)
				found := false
				if landed && len(fresh) > 0 {
					// The event was queued as the message went in, so every read
					// here answers at once, and one of them names it.
					want := libodin_cat(line_buf[:], "inbox/", fresh, "\n")
					want_buf: [160]u8
					wn := copy(want_buf[:], want)
					for _ in 0 ..< 300 {
						en := read_once("/mnt/mail/event", text[:])
						if en <= 0 {
							break
						}
						if string(text[:en]) == string(want_buf[:wn]) {
							found = true
							break
						}
					}
				}
				checkv(r, found, "and event answered with it, inbox/<id>, the read that parks")
				n = web_read_file(libodin_cat(line_buf[:], "/mnt/mail/inbox/", fresh, "/subject"), text[:])
				checkv(r, string(text[:max(n, 0)]) == "over the servers", "with the subject Bob wrote")

				// The handshake over the servers: Bob invites, Glenda joins.
				gsent_buf: [2048]u8
				bsent_buf: [2048]u8
				gsent := count_words(dir_names("/mnt/mail/sent", gsent_buf[:]))
				bsent := count_words(dir_names("/mnt/mail2/sent", bsent_buf[:]))
				checkv(r, net_file_write("/mnt/mail2/ctl", "invite"), "Bob makes an invite")
				n = web_read_file("/mnt/mail2/ctl", text[:])
				invite := invite_line(string(text[:max(n, 0)]))
				checkv(r, len(invite) > 100, "which his ctl shows")
				checkv(r, net_file_write("/mnt/mail/ctl", libodin_cat(line_buf[:], "join ", invite)), "and Glenda joins it: her request goes to his mailbox through the relay")
				verified := false
				for _ in 0 ..< PATIENCE * 20 {
					n = web_read_file(libodin_cat(line_buf[:], "/mnt/mail2/contacts/glenda@", host, "/verified"), text[:])
					if string(text[:max(n, 0)]) == "yes" {
						verified = true
						break
					}
					sync.delay(1)
				}
				checkv(r, verified, "and Glenda is verified with Bob: the request, the auth-required, the auth and the confirm each landed under IDLE and were answered from the session")
				// The confirm lands in Bob's sent/ once the relay has taken
				// it, which is after his verified said yes.
				counted := false
				for _ in 0 ..< PATIENCE * 5 {
					gsent2 := count_words(dir_names("/mnt/mail/sent", gsent_buf[:]))
					bsent2 := count_words(dir_names("/mnt/mail2/sent", bsent_buf[:]))
					if gsent2 == gsent + 2 && bsent2 == bsent + 2 {
						counted = true
						break
					}
					sync.delay(1)
				}
				checkv(r, counted, "her request and her auth went from her session on a sender thread, his auth-required and his confirm from his")

				// The end of the sessions.
				checkv(r, net_file_write("/mnt/mail/ctl", "idle off") && net_file_write("/mnt/mail2/ctl", "idle off"), "idle off says DONE and logs out")
				gone := false
				for _ in 0 ..< PATIENCE * 5 {
					n = web_read_file("/mnt/mail/ctl", text[:])
					if n > 0 && !libodin.contains(string(text[:n]), "idle\n") {
						gone = true
						break
					}
					sync.delay(1)
				}
				checkv(r, gone, "and ctl no longer says idle")
				checkv(r, vfs.unmount_path(vfs.boot_namespace, "", "/mnt/mail2") == vfs.OK, "the mount of Bob's mailfs comes down")
			}
			checkv(r, srv.remove("mail2") == vfs.OK, "and the kernel takes its name away")
			checkv(r, wait(pb, PATIENCE * 5), "and it exits")
			finish(r, pb, "and is taken down")
		}
	}

	// The servers go on until ended.
	if prs != nil {
		_ = notepg_kernel(prs.note_group, "kill")
		checkv(r, end(prs, PATIENCE * 5), "the relay, told to end, ends")
		finish(r, prs, "and is taken down")
	}
	if pbs != nil {
		_ = notepg_kernel(pbs.note_group, "kill")
		checkv(r, end(pbs, PATIENCE * 5), "Bob's mailbox server ends")
		finish(r, pbs, "and is taken down")
	}
	_ = notepg_kernel(pg.note_group, "kill")
	checkv(r, end(pg, PATIENCE * 5), "and Glenda's")
	finish(r, pg, "and is taken down")
}

// checkv is check, and a failure said on the console as it happens, so the
// serial log has every one and not the tally's first few.
@(private = "file")
checkv :: proc(r: ^Result, ok: bool, what: string) -> bool {
	if !ok {
		line: [512]u8
		net_file_write("/dev/cons", libodin_cat(line[:], "verify: FAIL ", what, "\n"))
	}
	return check(r, ok, what)
}

// new_word answers the word of `after` that `before` does not have, or "".
@(private = "file")
new_word :: proc(before, after: string) -> string {
	at := 0
	for at < len(after) {
		e := at
		for e < len(after) && after[e] != ' ' {
			e += 1
		}
		w := after[at:e]
		at = e + 1
		if len(w) == 0 {
			continue
		}
		have := false
		bat := 0
		for bat < len(before) {
			be := bat
			for be < len(before) && before[be] != ' ' {
				be += 1
			}
			if before[bat:be] == w {
				have = true
				break
			}
			bat = be + 1
		}
		if !have {
			return w
		}
	}
	return ""
}

/*
verify_fedi_login runs webfs again and a scripted Mastodon instance on
this machine's stack, and logs fedifs in: docs/WEB.md section 7's
authorization code flow with the out-of-band redirect, and step 4's "a
scripted login that ends with a token". `login` registers the app and
ctl shows the page to approve on; a wrong code is refused; the right
code ends with the token in factotum under proto=oauth, unshown, and me
the account. Then `fetch home` takes the account's home timeline with
the token, and an account whose token the instance refuses cannot.
*/
@(private = "file")
verify_fedi_login :: proc(r: ^Result, host: string) {
	wnames := [?]string{"webfs", "-s", "/usr/glenda/lib/web"}
	wargv := new(Argv)
	_ = argv_from(wargv, wnames[:])
	pw := start_path(r, "/bin/webfs", "webfs starts again, for the instance's requests", wargv)
	if pw == nil {
		return
	}
	if !check(r, await_posted("web"), "and posts /srv/web") || !check(r, srv.mount(vfs.boot_namespace, "/srv/web", "/mnt/web") == vfs.OK, "which the kernel mounts") {
		finish(r, pw, "and webfs is taken down")
		return
	}
	sargs := [?]string{"websrv", "8081", "10"}
	sargv := new(Argv)
	_ = argv_from(sargv, sargs[:])
	inst := start_path(r, "/bin/websrv", "a scripted instance starts, ten requests to serve", sargv)
	fnames := [?]string{"fedifs", "-s", "/usr/glenda/lib/web"}
	fargv := new(Argv)
	_ = argv_from(fargv, fnames[:])
	pf := start_path(r, "/bin/fedifs", "and fedifs starts again, with a store", fargv)
	if inst != nil && pf != nil {
		sync.delay(PATIENCE)
		line_buf: [512]u8
		text: [2048]u8
		base := libodin_cat(line_buf[:], "http://", host, ":8081")
		base_buf: [128]u8
		bn := copy(base_buf[:], base)
		base = string(base_buf[:bn])
		if check(r, await_posted("fedi"), "which posts /srv/fedi") && check(r, srv.mount(vfs.boot_namespace, "/srv/fedi", "/mnt/fedi") == vfs.OK, "and the kernel mounts it at /mnt/fedi") {
			check(r, net_file_write("/mnt/fedi/ctl", libodin_cat(line_buf[:], "login ", base)), "login names the instance, and the write returns once the app is registered")
			n := web_read_file("/mnt/fedi/ctl", text[:])
			check(r, n > 0 && libodin.contains(string(text[:n]), libodin_cat(line_buf[:], "authorize ", base, "/oauth/authorize?response_type=code&client_id=cid-1&redirect_uri=urn:ietf:wg:oauth:2.0:oob&scope=read+write+follow")), "and ctl shows the page to approve on, with the client id the instance gave and the out-of-band redirect")
			check(r, !net_file_write("/mnt/fedi/ctl", "code wrong"), "a code the instance does not know is refused")
			check(r, net_file_write("/mnt/fedi/ctl", "code cafe"), "the code the page showed is traded for a token, and the write returns when the token is in factotum")
			n = web_read_file("/mnt/fedi/me", text[:])
			check(r, string(text[:max(n, 0)]) == libodin_cat(line_buf[:], "glenda@", host, ":8081"), "and me is the account the token is, as the instance named it")
			n = web_read_file("/mnt/factotum/ctl", text[:])
			got := string(text[:max(n, 0)])
			check(r, n > 0 && libodin.contains(got, libodin_cat(line_buf[:], "key proto=oauth user=glenda server=", host, ":8081")) && !libodin.contains(got, "token-42"), "and factotum lists the token's key under the account and the host, and keeps the token")
			ID1 :: "000000006aad0ba0.113000000000000001"
			ID2 :: "000000006aad12a8.113000000000000002"
			ID3 :: "000000006aad19b0.113000000000000003"
			check(r, net_file_write("/mnt/fedi/ctl", "fetch home"), "fetch home takes the account's home timeline, the token from factotum in the request")
			lbuf: [2048]u8
			check(r, dir_names("/mnt/fedi/home", lbuf[:]) == ID1 + " " + ID2 + " " + ID3, "and the three statuses the instance holds are the conversation")

			// A status out: the block written to new, posted with the token.
			ID9 :: "000000006aad2ec8.113000000000000009"
			check(r, net_file_write("/mnt/fedi/new", "subject: cw\nreplyto: " + ID1 + "\n\nHello from Vectra & co\n"), "a status written to new as the block is posted as the account, and the write returns when the instance has it")
			check(r, dir_names("/mnt/fedi/home", lbuf[:]) == ID1 + " " + ID2 + " " + ID3 + " " + ID9, "and the status the instance answered is in home")
			n = web_read_file("/mnt/fedi/home/" + ID9 + "/body", text[:])
			check(r, string(text[:max(n, 0)]) == "<p>Hello from Vectra & co</p>", "with the body written, the form's encoding undone by the instance")
			n = web_read_file("/mnt/fedi/home/" + ID9 + "/subject", text[:])
			check(r, string(text[:max(n, 0)]) == "cw", "the subject as its content warning")
			n = web_read_file("/mnt/fedi/home/" + ID9 + "/replyto", text[:])
			check(r, string(text[:max(n, 0)]) == ID1, "and answering the status replyto named, by the instance's id")
			check(r, dir_names("/mnt/fedi/home/" + ID1 + "/replies", lbuf[:]) == ID3 + " " + ID9, "so replies under it lists the new status")
			n = web_read_file("/usr/glenda/lib/web/sent/" + ID9 + ".json", text[:], raw = true)
			check(r, n > 0 && libodin.contains(string(text[:n]), "\"id\": \"113000000000000009\""), "and the store keeps what went out under sent, the status as the instance sent it")
			check(r, !net_file_write("/mnt/fedi/new", "colour: blue\n\nx"), "a write to new with a header no network knows is refused before any wire")
			// A picture on a status: uploaded first, then the status carries it.
			check(r, net_file_write("/mnt/fedi/new", "attach: /lib/tests/dot.png\n\nA picture.\n"), "a status with an attach line uploads the file first, as multipart form data, and posts the status with the media the instance named")
			n = web_read_file("/mnt/fedi/home/" + ID9 + "/links", text[:])
			check(r, libodin.contains(string(text[:max(n, 0)]), "https://one.example/media/m-1.png"), "and the status the instance answered carries the picture among its links")
			NOTE :: "000000006aad35d0.af5f29eabd18685e"
			check(r, net_file_write("/mnt/fedi/ctl", libodin_cat(line_buf[:], "object notes ", base, "/objects/note7")), "an object anywhere is fetched by its URL, with Accept: application/activity+json")
			check(r, dir_names("/mnt/fedi/notes", lbuf[:]) == NOTE, "and is a message of the conversation named, the instance having answered activity JSON to that header")
			check(r, net_file_write("/mnt/factotum/ctl", libodin_cat(line_buf[:], "key proto=oauth user=nobody server=", host, ":8081 !token=bad")), "a token the instance will refuse goes to factotum for another account")
			check(r, net_file_write("/mnt/fedi/ctl", libodin_cat(line_buf[:], "account ", base, " nobody")), "and account names that account, whose token factotum holds already")
			check(r, !net_file_write("/mnt/fedi/ctl", "fetch home"), "whose fetch the instance refuses, and the write says so")
			check(r, vfs.unmount_path(vfs.boot_namespace, "", "/mnt/fedi") == vfs.OK, "the mount of fedifs comes down")
		}
		check(r, srv.remove("fedi") == vfs.OK, "and the kernel takes its name away")
		check(r, wait(pf, PATIENCE * 5), "and fedifs exits")
		finish(r, pf, "and is taken down")
		check(r, wait(inst, PATIENCE * 5), "and the instance, its ten requests served, exits")
		check(r, string(inst.exit.text[:inst.exit.text_len]) == "ok", "with ok")
		finish(r, inst, "and is taken down")
	} else {
		finish(r, pf, "fedifs is taken down")
		finish(r, inst, "and the instance")
	}
	check(r, vfs.unmount_path(vfs.boot_namespace, "", "/mnt/web") == vfs.OK, "the mount of webfs comes down")
	check(r, srv.remove("web") == vfs.OK, "and the kernel takes its name away")
	check(r, wait(pw, PATIENCE * 5), "and webfs exits")
	finish(r, pw, "and is taken down")
}

/*
verify_at_login runs webfs again and a scripted PDS on this machine's
stack, and logs atfs in: docs/WEB.md section 7's app password on
createSession. The app password is a pass key in factotum; a wrong one
is refused by the server; the right one ends with the session's token
in factotum under proto=oauth, unshown, and me the handle and the DID.
Then `fetch home` takes the account's timeline with the token, and an
account whose token the server refuses cannot.
*/
@(private = "file")
verify_at_login :: proc(r: ^Result, host: string) {
	wnames := [?]string{"webfs", "-s", "/usr/glenda/lib/web"}
	wargv := new(Argv)
	_ = argv_from(wargv, wnames[:])
	pw := start_path(r, "/bin/webfs", "webfs starts again, for the PDS's requests", wargv)
	if pw == nil {
		return
	}
	if !check(r, await_posted("web"), "and posts /srv/web") || !check(r, srv.mount(vfs.boot_namespace, "/srv/web", "/mnt/web") == vfs.OK, "which the kernel mounts") {
		finish(r, pw, "and webfs is taken down")
		return
	}
	sargs := [?]string{"websrv", "8081", "8"}
	sargv := new(Argv)
	_ = argv_from(sargv, sargs[:])
	pds := start_path(r, "/bin/websrv", "a scripted PDS starts, eight requests to serve", sargv)
	anames := [?]string{"atfs", "-s", "/usr/glenda/lib/web"}
	aargv := new(Argv)
	_ = argv_from(aargv, anames[:])
	pa := start_path(r, "/bin/atfs", "and atfs starts again, with a store", aargv)
	if pds != nil && pa != nil {
		sync.delay(PATIENCE)
		line_buf: [512]u8
		text: [2048]u8
		base_buf: [128]u8
		base := libodin_cat(base_buf[:], "http://", host, ":8081")
		if check(r, await_posted("at"), "which posts /srv/at") && check(r, srv.mount(vfs.boot_namespace, "/srv/at", "/mnt/at") == vfs.OK, "and the kernel mounts it at /mnt/at") {
			check(r, !net_file_write("/mnt/at/ctl", libodin_cat(line_buf[:], "login ", base, " alice.one.example")), "a login with no app password in factotum is refused before any wire")
			check(r, net_file_write("/mnt/factotum/ctl", libodin_cat(line_buf[:], "key proto=pass user=alice.one.example server=", host, ":8081 !password=wrong-pass")), "an app password goes to factotum as a pass key, a wrong one first")
			check(r, !net_file_write("/mnt/at/ctl", libodin_cat(line_buf[:], "login ", base, " alice.one.example")), "and the server refuses the session, and the write says so")
			check(r, net_file_write("/mnt/factotum/ctl", libodin_cat(line_buf[:], "key proto=pass user=alice.one.example server=", host, ":8081 !password=app-pass-1")), "then the right one")
			check(r, net_file_write("/mnt/at/ctl", libodin_cat(line_buf[:], "login ", base, " alice.one.example")), "and login makes the session, the write returning once the token is in factotum")
			n := web_read_file("/mnt/at/me", text[:])
			check(r, string(text[:max(n, 0)]) == "alice.one.example\ndid did:plc:alice1", "and me is the handle and the DID the session named")
			n = web_read_file("/mnt/factotum/ctl", text[:])
			got := string(text[:max(n, 0)])
			check(r, n > 0 && libodin.contains(got, libodin_cat(line_buf[:], "key proto=oauth user=alice.one.example server=", host, ":8081")) && !libodin.contains(got, "jwt-7"), "and factotum lists the token's key under the handle and the host, and keeps the token")
			AT1 :: "000000006aad0f24.cdaa9ac7e2c76a9b"
			AT4 :: "000000006aad20b8.41f0a883e9334b00"
			check(r, net_file_write("/mnt/at/ctl", "fetch home"), "fetch home takes the account's timeline, the token from factotum in the request")
			lbuf: [2048]u8
			listed := dir_names("/mnt/at/home", lbuf[:])
			check(r, count_words(listed) == 4 && libodin.contains(listed, AT1) && libodin.contains(listed, AT4), "and the four posts the server holds are the conversation")

			// A post out: the block written to new, a record put with the token.
			before_buf: [2048]u8
			before := dir_names("/mnt/at/home", before_buf[:])
			check(r, net_file_write("/mnt/at/new", "replyto: " + AT1 + "\n\nHello from Vectra on AT\n"), "a post written to new as the block is put in the account's repository, and the write returns when the server has named it")
			after := dir_names("/mnt/at/home", lbuf[:])
			fresh := new_word(before, after)
			check(r, count_words(after) == 5 && len(fresh) > 0, "and the record is in home under the URI answered, dated now")
			n = web_read_file(libodin_cat(line_buf[:], "/mnt/at/home/", fresh, "/body"), text[:])
			check(r, string(text[:max(n, 0)]) == "Hello from Vectra on AT", "with the text written")
			n = web_read_file(libodin_cat(line_buf[:], "/mnt/at/home/", fresh, "/replyto"), text[:])
			check(r, string(text[:max(n, 0)]) == AT1, "answering the post replyto named, its URI and CID as the reply's parent and root")
			n = web_read_file(libodin_cat(line_buf[:], "/mnt/at/home/", fresh, "/hash"), text[:])
			check(r, string(text[:max(n, 0)]) == "bafyreinewrecordnewrecordnewrecordnewrecordnewrecordnewrecordq", "and hash is the CID the server named it by")
			n = web_read_file(libodin_cat(line_buf[:], "/usr/glenda/lib/web/sent/", fresh, ".json"), text[:], raw = true)
			check(r, n > 0 && libodin.contains(string(text[:n]), "\"$type\": \"app.bsky.feed.post\"") && libodin.contains(string(text[:n]), "\"parent\": {\"uri\": \"at://did:plc:alice1/app.bsky.feed.post/3kfirst\""), "and the store keeps the record as sent under sent")
			// A picture on a post: uploaded as a blob first, embedded in the record.
			before = dir_names("/mnt/at/home", before_buf[:])
			check(r, net_file_write("/mnt/at/new", "attach: /lib/tests/dot.png\n\nA picture on AT.\n"), "a post with an attach line uploads the file as a blob first, and puts the record with it embedded as an image")
			after = dir_names("/mnt/at/home", lbuf[:])
			fresh = new_word(before, after)
			n = web_read_file(libodin_cat(line_buf[:], "/usr/glenda/lib/web/sent/", fresh, ".json"), text[:], raw = true)
			check(r, len(fresh) > 0 && n > 0 && libodin.contains(string(text[:n]), "\"$type\": \"app.bsky.embed.images\"") && libodin.contains(string(text[:n]), "\"$link\": \"bafkreiblobdotpng"), "and the record kept under sent embeds the blob the server named")
			check(r, net_file_write("/mnt/at/ctl", "record at://did:plc:alice1/app.bsky.feed.post/3kfirst"), "a record is fetched by its URI, its repository, collection and key asked of the server")
			check(r, dir_names("/mnt/at/records", lbuf[:]) == AT1, "and lands in records, checked against its CID")
			check(r, net_file_write("/mnt/factotum/ctl", libodin_cat(line_buf[:], "key proto=oauth user=nobody server=", host, ":8081 !token=bad")), "a token the server will refuse goes to factotum for another account")
			check(r, net_file_write("/mnt/at/ctl", libodin_cat(line_buf[:], "account ", base, " nobody")), "and account names that account")
			check(r, !net_file_write("/mnt/at/ctl", "fetch home"), "whose fetch the server refuses, and the write says so")
			check(r, vfs.unmount_path(vfs.boot_namespace, "", "/mnt/at") == vfs.OK, "the mount of atfs comes down")
		}
		check(r, srv.remove("at") == vfs.OK, "and the kernel takes its name away")
		check(r, wait(pa, PATIENCE * 5), "and atfs exits")
		finish(r, pa, "and is taken down")
		check(r, wait(pds, PATIENCE * 5), "and the PDS, its eight requests served, exits")
		check(r, string(pds.exit.text[:pds.exit.text_len]) == "ok", "with ok")
		finish(r, pds, "and is taken down")
	} else {
		finish(r, pa, "atfs is taken down")
		finish(r, pds, "and the PDS")
	}
	check(r, vfs.unmount_path(vfs.boot_namespace, "", "/mnt/web") == vfs.OK, "the mount of webfs comes down")
	check(r, srv.remove("web") == vfs.OK, "and the kernel takes its name away")
	check(r, wait(pw, PATIENCE * 5), "and webfs exits")
	finish(r, pw, "and is taken down")
}

/*
verify_at_oauth runs webfs again and a scripted authorization server on
this machine's stack, and logs atfs in the way the protocol wants now:
docs/WEB.md section 7's OAuth with PAR, PKCE and DPoP. `oauth` makes a
DPoP key in factotum, pushes the authorization request with a proof on
it, and ctl shows the page to approve on with the request URI the server
gave. Then the page: the reader opens it, the kernel presses its one
button, the server sends the browser to the loopback address with the
code, and atfs, listening there, trades the code with the PKCE verifier
for a token bound to the key, DPoP not Bearer, into factotum: "a
scripted authorization page through mothra ends with a token in
factotum". Then `fetch home` carries the token and a proof, the server
demands its nonce once, and the proof goes again with it. The server verifies every proof with the key in its
own header, its method and its URI, and the token's hash: "a DPoP proof
the test verifies with the public key carries the right method and URL".
*/
@(private = "file")
verify_at_oauth :: proc(r: ^Result, host: string) {
	wnames := [?]string{"webfs", "-s", "/usr/glenda/lib/web"}
	wargv := new(Argv)
	_ = argv_from(wargv, wnames[:])
	pw := start_path(r, "/bin/webfs", "webfs starts again, for the authorization server's requests", wargv)
	if pw == nil {
		return
	}
	if !check(r, await_posted("web"), "and posts /srv/web") || !check(r, srv.mount(vfs.boot_namespace, "/srv/web", "/mnt/web") == vfs.OK, "which the kernel mounts") {
		finish(r, pw, "and webfs is taken down")
		return
	}
	// The server serves until it is ended, since the page's path and the
	// hand's differ in how many requests they make.
	sargs := [?]string{"websrv", "8081", "99"}
	sargv := new(Argv)
	_ = argv_from(sargv, sargs[:])
	as := start_path(r, "/bin/websrv", "a scripted authorization server starts", sargv)
	pa := start_path(r, "/bin/atfs", "and atfs starts again")
	if as != nil && pa != nil {
		sync.delay(PATIENCE)
		line_buf: [512]u8
		text: [2048]u8
		base_buf: [128]u8
		base := libodin_cat(base_buf[:], "http://", host, ":8081")
		if check(r, await_posted("at"), "which posts /srv/at") && check(r, srv.mount(vfs.boot_namespace, "/srv/at", "/mnt/at") == vfs.OK, "and the kernel mounts it at /mnt/at") {
			// Factotum's half first, asked the way atfs asks: a key, and a
			// proof signed on it over one rpc conversation.
			check(r, net_file_write("/mnt/factotum/ctl", libodin_cat(line_buf[:], "key proto=dpop user=alice.one.example server=", host, ":8081")), "a dpop key for the handle at the host is made in factotum")
			answer1: [128]u8
			answer2: [2048]u8
			a1, a2 := rpc_two("/mnt/factotum/rpc", libodin_cat(line_buf[:], "start dpop user=alice.one.example server=", host, ":8081"), "proof htm=POST htu=http://example/oauth/par", answer1[:], answer2[:])
			check(r, a1 > 0 && string(answer1[:a1]) == "ok", "and rpc takes start dpop for that user and server")
			check(r, a2 > 6 && libodin.has_prefix(string(answer2[:a2]), "proof ey"), "and then signs a proof, a JWS whose header base64url begins ey")
			check(r, net_file_write("/mnt/at/ctl", libodin_cat(line_buf[:], "oauth ", base, " alice.one.example")), "oauth names the server and the handle, and the write returns once the request is pushed")
			n := web_read_file("/mnt/factotum/ctl", text[:])
			check(r, n > 0 && libodin.contains(string(text[:n]), libodin_cat(line_buf[:], "key proto=dpop user=alice.one.example server=", host, ":8081")), "a DPoP key for the handle at the host is in factotum, made there")
			n = web_read_file("/mnt/at/ctl", text[:])
			check(r, n > 0 && libodin.contains(string(text[:n]), libodin_cat(line_buf[:], "authorize ", base, "/oauth/authorize?client_id=http://localhost&request_uri=urn%3Aietf%3Aparams%3Aoauth%3Arequest_uri%3Areq-1")), "and ctl shows the page to approve on, with the request URI the server gave for the pushed request, whose proof it verified")
			// The page: the reader opens it, the kernel presses Approve, and
			// the code comes back to the listener.
			approved := false
			if s := devfs.raw_surface(); s != nil && s.pixels != nil && s.bytes_pp == 4 {
				dcount0 := srv.count()
				if ps := start_draw_server(r, s, "the loader starts the draw server for the authorize page", "which posts /srv/draw for the reader to find", "and paints a desktop before the reader opens a window"); ps != nil {
					auth_buf: [768]u8
					auth_url := authorize_line(string(text[:max(n, 0)]), auth_buf[:])
					mnames := [?]string{"mothra", auth_url}
					margv := new(Argv)
					_ = argv_from(margv, mnames[:])
					if pm := start_path(r, "/bin/mothra", "the loader starts the reader on the page to approve on", margv); pm != nil {
						bx, by, bw := await_bar(s)
						check(r, bx >= 0, "and the reader opens a framed window on the page")
						/*
						The page comes over the wire after the window opens.
						Keys typed before the reader reads them are lost. So a
						Tab goes to the one button, until its row sits on a bar
						of the face, as the compose check waits for the address
						row. Then Return presses it.
						*/
						face := fb.pack(s, fb.MAGNESIUM)
						selected := false
						for _ in 0 ..< 5 {
							type_text("\t")
							for _ in 0 ..< PATIENCE * 5 {
								for y in by + 30 ..< min(by + 400, s.height) {
									if _, run := row_span(s, y, face, bx + 4, bx + bw - 4); run > 100 {
										selected = true
										break
									}
								}
								if selected {
									break
								}
								sync.delay(1)
							}
							if selected {
								break
							}
						}
						check(r, selected, "and a Tab selects the Approve button, on a bar of the face: the reader is reading keys")
						type_text("\n")
						// The trade is what sets me, so me is the proof it happened.
						for _ in 0 ..< PATIENCE * 20 {
							n = web_read_file("/mnt/at/me", text[:])
							approved = string(text[:max(n, 0)]) == "alice.one.example\ndid did:plc:alice1"
							if approved {
								break
							}
							sync.delay(1)
						}
						check(r, approved, "and pressing Approve sends the browser to the loopback address with the code, where atfs takes it and trades it for a token bound to the key, into factotum")
						_ = notepg_kernel(pm.note_group, "kill")
						check(r, end(pm, PATIENCE * 5), "and the reader, told to end, ends")
						finish(r, pm, "and is taken down")
					}
					stop_draw_server(r, ps, dcount0)
				}
			}
			if !approved {
				// No glass to press the button on: the code by hand.
				check(r, net_file_write("/mnt/at/ctl", "code dcode"), "the code is traded by hand, with the verifier and a proof")
			}
			sync.delay(PATIENCE)
			n = web_read_file("/mnt/at/me", text[:])
			check(r, string(text[:max(n, 0)]) == "alice.one.example\ndid did:plc:alice1", "and me is the handle and the DID the token is for")
			n = web_read_file("/mnt/factotum/ctl", text[:])
			got := string(text[:max(n, 0)])
			check(r, n > 0 && libodin.contains(got, libodin_cat(line_buf[:], "key proto=oauth user=alice.one.example server=", host, ":8081")) && !libodin.contains(got, "dtok-9"), "and factotum lists the token's key, and keeps the token")
			AT1 :: "000000006aad0f24.cdaa9ac7e2c76a9b"
			check(r, net_file_write("/mnt/at/ctl", "fetch home"), "fetch home carries the token as DPoP with a proof, is asked for the server's nonce once, and goes again with it")
			lbuf: [2048]u8
			listed := dir_names("/mnt/at/home", lbuf[:])
			check(r, count_words(listed) == 4 && libodin.contains(listed, AT1), "and the timeline is the conversation, the server having verified the proof's key, method, URI, nonce and token hash")
			check(r, vfs.unmount_path(vfs.boot_namespace, "", "/mnt/at") == vfs.OK, "the mount of atfs comes down")
		}
		check(r, srv.remove("at") == vfs.OK, "and the kernel takes its name away")
		check(r, wait(pa, PATIENCE * 5), "and atfs exits")
		finish(r, pa, "and is taken down")
		_ = notepg_kernel(as.note_group, "kill")
		check(r, end(as, PATIENCE * 5), "and the authorization server, told to end, ends")
		finish(r, as, "and is taken down")
	} else {
		finish(r, pa, "atfs is taken down")
		finish(r, as, "and the authorization server")
	}
	check(r, vfs.unmount_path(vfs.boot_namespace, "", "/mnt/web") == vfs.OK, "the mount of webfs comes down")
	check(r, srv.remove("web") == vfs.OK, "and the kernel takes its name away")
	check(r, wait(pw, PATIENCE * 5), "and webfs exits")
	finish(r, pw, "and is taken down")
}

/*
verify_matrix_login runs webfs again and a scripted homeserver on this
machine's stack, and logs matrixfs in: the password from factotum, the
token back in factotum and the device's keys uploaded signed, a sync
with it, and a message written to new put in a room. The room is
encrypted, so the message goes sealed: the homeserver holds a second
device, Bob, whose keys are queried and claimed, the room's Megolm key
goes to him by Olm, and he opens the event and writes what it said:
docs/WEB.md section 8's "a message written to new comes out of a
scripted server as a Megolm event the test opens". Then a sync after
carries Bob's own key by Olm and an event he sealed, which opens in
the room: "a sealed message opened by a test key".
*/
@(private = "file")
verify_matrix_login :: proc(r: ^Result, host: string) {
	wnames := [?]string{"webfs", "-s", "/usr/glenda/lib/web"}
	wargv := new(Argv)
	_ = argv_from(wargv, wnames[:])
	pw := start_path(r, "/bin/webfs", "webfs starts again, for the homeserver's requests", wargv)
	if pw == nil {
		return
	}
	if !check(r, await_posted("web"), "and posts /srv/web") || !check(r, srv.mount(vfs.boot_namespace, "/srv/web", "/mnt/web") == vfs.OK, "which the kernel mounts") {
		finish(r, pw, "and webfs is taken down")
		return
	}
	// The homeserver serves until it is ended: the long poll asks as it likes.
	sargs := [?]string{"websrv", "8081", "99"}
	sargv := new(Argv)
	_ = argv_from(sargv, sargs[:])
	hs := start_path(r, "/bin/websrv", "a scripted homeserver starts", sargv)
	mnames := [?]string{"matrixfs", "-s", "/usr/glenda/lib/web", "-i", "glenda", "home"}
	margv := new(Argv)
	_ = argv_from(margv, mnames[:])
	pm := start_path(r, "/bin/matrixfs", "and matrixfs starts again, with a store and an identity to seal it under", margv)
	if hs != nil && pm != nil {
		sync.delay(PATIENCE)
		line_buf: [512]u8
		text: [2048]u8
		base_buf: [128]u8
		base := libodin_cat(base_buf[:], "http://", host, ":8081")
		if check(r, await_posted("matrix"), "which posts /srv/matrix") && check(r, srv.mount(vfs.boot_namespace, "/srv/matrix", "/mnt/matrix") == vfs.OK, "and the kernel mounts it at /mnt/matrix") {
			check(r, net_file_write("/mnt/factotum/ctl", "key proto=noise user=glenda dom=home !passphrase=open sesame"), "a noise key from the passphrase goes to factotum: the store's key is derived from it")
			check(r, net_file_write("/mnt/factotum/ctl", libodin_cat(line_buf[:], "key proto=pass user=glenda server=", host, ":8081 !password=wrong")), "a password goes to factotum as a pass key, a wrong one first")
			check(r, !net_file_write("/mnt/matrix/ctl", libodin_cat(line_buf[:], "login ", base, " glenda")), "and the homeserver refuses the login, and the write says so")
			check(r, net_file_write("/mnt/factotum/ctl", libodin_cat(line_buf[:], "key proto=pass user=glenda server=", host, ":8081 !password=hunter2")), "then the right one")
			check(r, net_file_write("/mnt/matrix/ctl", libodin_cat(line_buf[:], "login ", base, " glenda")), "and login gets a token, the write returning once it is in factotum")
			n := web_read_file("/mnt/matrix/me", text[:])
			check(r, libodin.has_prefix(string(text[:max(n, 0)]), "@glenda:one.example\ndevice VECTRA1\ncurve25519 ") && libodin.contains(string(text[:max(n, 0)]), "\ned25519 "), "and me is the user id, the device id the homeserver named, and the device's two keys, made and uploaded signed at login")
			n = web_read_file("/mnt/factotum/ctl", text[:])
			got := string(text[:max(n, 0)])
			check(r, n > 0 && libodin.contains(got, libodin_cat(line_buf[:], "key proto=oauth user=@glenda:one.example server=", host, ":8081")) && !libodin.contains(got, "syt-1"), "and factotum lists the token's key under the user id and the host, and keeps the token")
			E1 :: "000000006aad43e0.89750ae9d56358c1"
			check(r, net_file_write("/mnt/matrix/ctl", "sync"), "sync takes the account's rooms with the token")
			lbuf: [2048]u8
			listed := dir_names("/mnt/matrix/vectra", lbuf[:])
			check(r, count_words(listed) == 5 && libodin.contains(listed, E1), "and the room the homeserver holds is the conversation")
			n = web_read_file("/mnt/matrix/ctl", text[:])
			check(r, n > 0 && libodin.contains(string(text[:n]), "room vectra !vectra:one.example sealed"), "and ctl says the room is sealed, off its state")
			check(r, net_file_write("/mnt/matrix/new", "to: vectra\nreplyto: " + E1 + "\n\nHello from Vectra.\n"), "a message written to new, to the room by name, goes sealed: Bob's keys queried and a one-time key claimed, the room's key to him by Olm, the event by Megolm, and the write returns when the homeserver has named the event")
			abuf: [2048]u8
			after := dir_names("/mnt/matrix/vectra", abuf[:])
			fresh := new_word(listed, after)
			check(r, count_words(after) == 6 && len(fresh) > 0, "and the event is in the room under the id the homeserver gave, dated now")
			n = web_read_file(libodin_cat(line_buf[:], "/mnt/matrix/vectra/", fresh, "/body"), text[:])
			check(r, string(text[:max(n, 0)]) == "Hello from Vectra.", "with the text written")
			n = web_read_file(libodin_cat(line_buf[:], "/mnt/matrix/vectra/", fresh, "/replyto"), text[:])
			check(r, string(text[:max(n, 0)]) == E1, "answering the event replyto named")
			n = web_read_file("/usr/glenda/matrix-bob.txt", text[:], raw = true)
			check(r, string(text[:max(n, 0)]) == "Hello from Vectra.", "and Bob, on the homeserver, opened the room key by Olm and the event by Megolm, and wrote what it said")
			// The sync after: Bob's key by Olm, and an event he sealed.
			check(r, net_file_write("/mnt/matrix/ctl", "sync"), "the sync after carries Bob's room key in a to-device event, sealed by Olm on a one-time key this device uploaded")
			listed = dir_names("/mnt/matrix/vectra", lbuf[:])
			SEALED :: "000000006aad6af0.05bbf82ba4bd7084"
			check(r, count_words(listed) == 7 && libodin.contains(listed, SEALED), "and an event he sealed with it, in the room")
			n = web_read_file("/mnt/matrix/vectra/" + SEALED + "/body", text[:])
			check(r, string(text[:max(n, 0)]) == "Sealed from Bob.", "which opened with the session his key named: a sealed message opened by a test key")
			n = web_read_file("/mnt/matrix/vectra/" + SEALED + "/from", text[:])
			check(r, string(text[:max(n, 0)]) == "@bob:two.example", "from Bob")
			n = web_read_file("/mnt/matrix/vectra/" + SEALED + "/raw", text[:], raw = true)
			check(r, n > 0 && libodin.contains(string(text[:n]), "\"algorithm\": \"m.megolm.v1.aes-sha2\""), "while raw is the sealed event as it came")
			n = web_read_file("/mnt/matrix/vectra/" + SEALED + "/subject", text[:])
			check(r, string(text[:max(n, 0)]) == "unverified device BOBDEV", "and its subject marks it as from a device not verified, which every message from one carries")
			// The device requester.
			check(r, libodin.contains(dir_names("/mnt/matrix/devices", lbuf[:]), "BOBDEV") && libodin.contains(dir_names("/mnt/matrix/devices", lbuf[:]), "VECTRA1"), "devices/ lists Bob's device, whose keys the query and his room key brought, and this one")
			n = web_read_file("/mnt/matrix/devices/BOBDEV/user", text[:])
			check(r, string(text[:max(n, 0)]) == "@bob:two.example", "with whose it is")
			n = web_read_file("/mnt/matrix/devices/BOBDEV/verified", text[:])
			check(r, string(text[:max(n, 0)]) == "no", "not verified")
			n = web_read_file("/mnt/matrix/devices/VECTRA1/verified", text[:])
			check(r, string(text[:max(n, 0)]) == "yes", "while this device is")
			fpbuf: [128]u8
			n = web_read_file("/mnt/matrix/devices/BOBDEV/fingerprint", fpbuf[:])
			fp := string(fpbuf[:max(n, 0)])
			check(r, count_words(fp) == 11 && len(fp) == 53, "and a fingerprint: the signing key in groups of four, as the other screen shows it")
			check(r, !net_file_write("/mnt/matrix/ctl", "verify NOSUCH"), "verify of a device whose keys never came is refused")
			nbuf: [512]u8
			before_notify := dir_names("/mnt/matrix/notify", nbuf[:])
			check(r, net_file_write("/mnt/matrix/ctl", "verify BOBDEV"), "verify BOBDEV is the requester")
			n = web_read_file("/mnt/matrix/ctl", text[:])
			check(r, n > 0 && libodin.contains(string(text[:n]), libodin_cat(line_buf[:], "verify BOBDEV ", fp)), "and ctl shows the device and its fingerprint to compare")
			after_notify := dir_names("/mnt/matrix/notify", lbuf[:])
			ask := new_word(before_notify, after_notify)
			check(r, len(ask) > 0, "and notify holds the request")
			n = web_read_file(libodin_cat(line_buf[:], "/mnt/matrix/notify/", ask, "/subject"), text[:])
			check(r, string(text[:max(n, 0)]) == "verify", "as a message whose subject is verify")
			n = web_read_file(libodin_cat(line_buf[:], "/mnt/matrix/notify/", ask, "/body"), text[:])
			check(r, string(text[:max(n, 0)]) == libodin_cat(line_buf[:], "device BOBDEV\n", fp), "and whose body is the device and the fingerprint")
			check(r, net_file_write("/mnt/matrix/ctl", "verified BOBDEV"), "verified BOBDEV is the person's yes, the fingerprints compared")
			n = web_read_file("/mnt/matrix/devices/BOBDEV/verified", text[:])
			check(r, string(text[:max(n, 0)]) == "yes", "and the device is verified")
			n = web_read_file("/mnt/matrix/ctl", text[:])
			check(r, n > 0 && !libodin.contains(string(text[:n]), "verify BOBDEV"), "and ctl no longer asks")
			kept := dir_names("/usr/glenda/lib/web/keys/matrix", lbuf[:])
			check(r, kept != "" && kept != "?", "and the store keeps the session under keys/matrix, sealed, for the history it opens after a restart")
			// The stored file is sealed under the passphrase key: a nonce, the
			// 165-byte export, and a 16-byte tag, not the export in the clear.
			sbuf: [512]u8
			sn := web_read_file(libodin_cat(line_buf[:], "/usr/glenda/lib/web/keys/matrix/", kept), sbuf[:], raw = true)
			check(r, sn == 12 + 165 + 16, "and the file is a nonce, the sealed export and its tag, not the export in the clear")
			check(r, !net_file_write("/mnt/matrix/new", "to: nowhere\n\nx"), "a message to a room this account is not in is refused before any wire")
			// The long poll: what comes lands on event, and who is typing.
			LIVE :: "000000006aad9200.76c371bcf5b5f12f"
			WELCOME :: "000000006aadb910.5810b5f548b04061"
			check(r, net_file_write("/mnt/matrix/ctl", "idle"), "idle starts the long poll: a thread syncs from the last batch as things come, and the write returns once it runs")
			n = web_read_file("/mnt/matrix/ctl", text[:])
			check(r, n > 0 && libodin.contains(string(text[:n]), "idle\n"), "and ctl says so")
			ebuf: [256]u8
			last := ""
			for _ in 0 ..< 12 {
				en := read_once("/mnt/matrix/event", ebuf[:])
				last = string(ebuf[:max(en, 0)])
				if last == "plain_one.example/" + LIVE + "\n" {
					break
				}
			}
			check(r, last == "plain_one.example/" + LIVE + "\n", "a read of event, the lines queued before it drained, is answered with the line the poll brought: a message in the plain room")
			n = web_read_file("/mnt/matrix/plain_one.example/" + LIVE + "/body", text[:])
			check(r, string(text[:max(n, 0)]) == "Live from the poll.", "which is in the room")
			SEALED2 :: "000000006aad9200.4120d2698b255e8a"
			n = web_read_file("/mnt/matrix/vectra/" + SEALED2 + "/body", text[:])
			check(r, string(text[:max(n, 0)]) == "Sealed again from Bob.", "and a second sealed line of Bob's, opened with the session kept")
			n = web_read_file("/mnt/matrix/vectra/" + SEALED2 + "/subject", text[:])
			check(r, n <= 0, "whose subject is empty now that his device is verified")
			n = web_read_file("/mnt/matrix/vectra/typing", text[:])
			check(r, string(text[:max(n, 0)]) == "@bob:two.example", "and a read of the sealed room's typing, which parks until someone is, answers Bob, off the sync's ephemeral events")
			n = web_read_file("/mnt/matrix/vectra/members", text[:])
			check(r, string(text[:max(n, 0)]) == "@glenda:one.example\n@bob:two.example", "and members is the two of them")
			// The room's verbs.
			check(r, net_file_write("/mnt/matrix/ctl", "join !secret:two.example"), "join names the room the invite in notify is for, by its id, and the write returns when the homeserver has taken it")
			last = ""
			for _ in 0 ..< 4 {
				en := read_once("/mnt/matrix/event", ebuf[:])
				last = string(ebuf[:max(en, 0)])
				if last == "secret/" + WELCOME + "\n" {
					break
				}
			}
			check(r, last == "secret/" + WELCOME + "\n", "and the poll brings the room, named by its state, its welcome on event")
			n = web_read_file("/mnt/matrix/secret/members", text[:])
			check(r, string(text[:max(n, 0)]) == "@bob:two.example\n@glenda:one.example", "with its members")
			n = web_read_file("/mnt/matrix/ctl", text[:])
			check(r, n > 0 && libodin.contains(string(text[:n]), "room secret !secret:two.example"), "and ctl lists it")
			check(r, net_file_write("/mnt/matrix/ctl", "invite secret @carol:one.example"), "invite names a room here and a user, and the homeserver takes it")
			check(r, !net_file_write("/mnt/matrix/ctl", "invite nowhere @carol:one.example"), "to a room this account is not in it is refused before any wire")
			check(r, net_file_write("/mnt/matrix/ctl", "leave secret"), "leave names a room here, and the homeserver takes it")
			check(r, dir_names("/mnt/matrix/secret", lbuf[:]) == "members typing", "and the room is emptied, its directory staying for a reader's path")
			n = web_read_file("/mnt/matrix/ctl", text[:])
			check(r, n > 0 && !libodin.contains(string(text[:n]), "room secret"), "and ctl no longer lists it")
			check(r, !net_file_write("/mnt/matrix/new", "to: secret\n\nx"), "and a message to it is refused")
			check(r, net_file_write("/mnt/matrix/ctl", "idle off"), "idle off ends the poll")
			stopped := false
			for _ in 0 ..< PATIENCE * 5 {
				n = web_read_file("/mnt/matrix/ctl", text[:])
				if n > 0 && !libodin.contains(string(text[:n]), "idle\n") {
					stopped = true
					break
				}
				sync.delay(1)
			}
			check(r, stopped, "and the thread leaves inside the patience, ctl no longer saying idle")
			check(r, vfs.unmount_path(vfs.boot_namespace, "", "/mnt/matrix") == vfs.OK, "the mount of matrixfs comes down")
		}
		check(r, srv.remove("matrix") == vfs.OK, "and the kernel takes its name away")
		check(r, wait(pm, PATIENCE * 5), "and matrixfs exits")
		finish(r, pm, "and is taken down")
		// The history opens after a restart: a fresh matrixfs on the same
		// store and identity loads the sealed session, off the disk alone,
		// no login and no sync.
		r2names := [?]string{"matrixfs", "-s", "/usr/glenda/lib/web", "-i", "glenda", "home"}
		r2argv := new(Argv)
		_ = argv_from(r2argv, r2names[:])
		pm2 := start_path(r, "/bin/matrixfs", "a fresh matrixfs starts on the same store and identity", r2argv)
		if pm2 != nil && check(r, await_posted("matrix"), "which posts /srv/matrix") && check(r, srv.mount(vfs.boot_namespace, "/srv/matrix", "/mnt/matrix") == vfs.OK, "and the kernel mounts it") {
			rtext: [512]u8
			rn := web_read_file("/mnt/matrix/ctl", rtext[:])
			check(r, rn > 0 && libodin.contains(string(rtext[:rn]), "store 1"), "and ctl says store 1: the sealed session opened under the key derived from the passphrase and was loaded, so history survives a restart")
			check(r, vfs.unmount_path(vfs.boot_namespace, "", "/mnt/matrix") == vfs.OK, "the mount comes down")
		}
		check(r, srv.remove("matrix") == vfs.OK, "and the kernel takes its name away")
		check(r, wait(pm2, PATIENCE * 5), "and the fresh matrixfs exits")
		finish(r, pm2, "and is taken down")
		_ = notepg_kernel(hs.note_group, "kill")
		check(r, end(hs, PATIENCE * 5), "and the homeserver, told to end, ends")
		finish(r, hs, "and is taken down")
	} else {
		finish(r, pm, "matrixfs is taken down")
		finish(r, hs, "and the homeserver")
	}
	check(r, vfs.unmount_path(vfs.boot_namespace, "", "/mnt/web") == vfs.OK, "the mount of webfs comes down")
	check(r, srv.remove("web") == vfs.OK, "and the kernel takes its name away")
	check(r, wait(pw, PATIENCE * 5), "and webfs exits")
	finish(r, pw, "and is taken down")
}

/*
verify_chatmail runs webfs again and a scripted relay on this machine's
stack, and gives mailfs a dcaccount: URL. One request later the address
is the account, the password is in factotum under the address's host, and
the seal is on and cannot go off: docs/WEB.md section 6's "chatmail is an
account in one request".
*/
@(private = "file")
verify_chatmail :: proc(r: ^Result, host: string) {
	wnames := [?]string{"webfs", "-s", "/usr/glenda/lib/web"}
	wargv := new(Argv)
	_ = argv_from(wargv, wnames[:])
	pw := start_path(r, "/bin/webfs", "webfs starts again, for the relay's request", wargv)
	if pw == nil {
		return
	}
	if !check(r, await_posted("web"), "and posts /srv/web") || !check(r, srv.mount(vfs.boot_namespace, "/srv/web", "/mnt/web") == vfs.OK, "which the kernel mounts") {
		finish(r, pw, "and webfs is taken down")
		return
	}
	sargs := [?]string{"websrv", "8081", "1"}
	sargv := new(Argv)
	_ = argv_from(sargv, sargs[:])
	if relay := start_path(r, "/bin/websrv", "a scripted chatmail relay starts", sargv); relay != nil {
		sync.delay(PATIENCE)
		line_buf: [256]u8
		local: [64]u8
		ln := web_read_file("/net/local", local[:])
		check(r, net_file_write("/mnt/mail/ctl", libodin_cat(line_buf[:], "account dcaccount:http://", string(local[:ln]), ":8081/new")), "a dcaccount URL on ctl asks the relay for an account")
		text: [2048]u8
		n := web_read_file("/mnt/mail/ctl", text[:])
		got := string(text[:max(n, 0)])
		check(r, n > 0 && libodin.contains(got, libodin_cat(line_buf[:], "account ac1 ", host, " 993 tls")) && libodin.contains(got, "seal on, chatmail"), "and the address the relay answered is the account, over TLS, with the seal on")
		n = web_read_file("/mnt/mail/me", text[:])
		check(r, libodin.has_prefix(string(text[:max(n, 0)]), libodin_cat(line_buf[:], "ac1@", host)), "and me is the new address")
		n = web_read_file("/mnt/factotum/ctl", text[:])
		got = string(text[:max(n, 0)])
		check(r, n > 0 && libodin.contains(got, libodin_cat(line_buf[:], "key proto=pass user=ac1 server=", host)) && !libodin.contains(got, "relay-made"), "and the password the relay made is in factotum under the address's host, unshown")
		check(r, !net_file_write("/mnt/mail/ctl", "seal off"), "and seal off is refused: the relay refuses cleartext")
		check(r, wait(relay, PATIENCE * 5), "and the relay, its one request served, exits")
		finish(r, relay, "and is taken down")
	}
	check(r, vfs.unmount_path(vfs.boot_namespace, "", "/mnt/web") == vfs.OK, "the mount of webfs comes down")
	check(r, srv.remove("web") == vfs.OK, "and the kernel takes its name away")
	check(r, wait(pw, PATIENCE * 5), "and webfs exits")
	finish(r, pw, "and is taken down")
}

// invite_line answers the invite a mail server's ctl shows, or empty.
@(private = "file")
invite_line :: proc(status: string) -> string {
	at := 0
	for at < len(status) {
		e := at
		for e < len(status) && status[e] != '\n' {
			e += 1
		}
		line := status[at:e]
		if libodin.has_prefix(line, "invite ") {
			return line[len("invite "):]
		}
		at = e + 1
	}
	return ""
}

// dir_names lists a directory's entries in the order it answers them, one
// space between names, into `into`.
@(private = "file")
dir_names :: proc(path: string, into: []u8) -> string {
	dc, err := vfs.resolve(vfs.boot_namespace, path)
	if err != vfs.OK {
		return "?"
	}
	defer vfs.chan_close(dc)
	if vfs.chan_open(dc, vfs.O_RDONLY | vfs.O_DIRECTORY) != vfs.OK {
		return "?"
	}
	raw: [4096]u8
	n := 0
	offset := u64(0)
	for {
		ln, lerr := vfs.readdir(dc, offset, raw[:])
		if lerr != vfs.OK || ln == 0 {
			break
		}
		c := vectra9.cursor_from(raw[:ln])
		for {
			e, ok := vectra9.next_dirent(&c)
			if !ok {
				break
			}
			offset = e.offset
			if n > 0 && n < len(into) {
				into[n] = ' '
				n += 1
			}
			n += copy(into[n:], e.name)
		}
	}
	return string(into[:n])
}

// read_once opens a file and reads it once, for a file where each read is
// one answer and the file never ends.
@(private = "file")
read_once :: proc(path: string, into: []u8) -> int {
	c, err := vfs.open_path(vfs.boot_namespace, path, vfs.O_RDONLY)
	if err != vfs.OK {
		return -1
	}
	defer vfs.chan_close(c)
	n, rerr := vfs.chan_read(c, 0, into)
	if rerr != vfs.OK {
		return -1
	}
	return n
}

@(private = "file")
count_words :: proc(s: string) -> int {
	n := 0
	in_word := false
	for i in 0 ..< len(s) {
		if s[i] == ' ' {
			in_word = false
		} else if !in_word {
			in_word = true
			n += 1
		}
	}
	return n
}

// count_lines answers how many newline-ended lines a string holds.
@(private = "file")
count_lines :: proc(s: string) -> int {
	n := 0
	for i in 0 ..< len(s) {
		if s[i] == '\n' {
			n += 1
		}
	}
	return n
}

// plumb_send writes one packed message to the plumber's send file, and
// answers whether the write was taken.
@(private = "file")
plumb_send :: proc(src, dst, type, data, attr: string) -> bool {
	c, err := vfs.open_path(vfs.boot_namespace, "/mnt/plumb/send", vfs.O_WRONLY)
	if err != vfs.OK {
		return false
	}
	defer vfs.chan_close(c)
	buf: [2048]u8
	count: [24]u8
	sink := libodin.sink_from(count[:])
	libodin.put_uint(&sink, u64(len(data)))
	text := libodin_cat(buf[:], src, "\n", dst, "\n", "", "\n", type, "\n", attr, "\n", libodin.str(&sink), "\n", data)
	n, werr := vfs.chan_write(c, 0, transmute([]u8)text)
	return werr == vfs.OK && int(n) == len(text)
}

/*
verify_mailfs runs `servers/mailfs` against `tests/imapsrv`, a scripted
IMAP server on this machine's stack, with the account's password held by
`factotum` under `proto=pass`. The kernel gives factotum the password and
asks it back over `rpc`, the way mailfs does, and sees the listing keep the
secret. Then mailfs is told the account and to fetch, and `inbox/` holds
the two messages the server sent, in time order, each the shape: the
sender and subject decoded off the headers, the body the plain part, and
the reply's `replyto` the first message's id. A second account with a
wrong password is refused by the server, and the fetch says so. That is
`docs/WEB.md` section 6's "a saved IMAP session through a pipe becomes an
inbox of the right shape".

Then the other direction: `tests/smtpsrv` takes a submission. A message
written to `new` as section 4's block, a reply to the first message with
a line that begins with a dot, comes out of the scripted server as a
message with the headers built for it and the dot-stuffing undone, and
lands in `sent/` in the shape. A recipient the server refuses fails the
write, and a header no network knows fails it before any wire.

Then the compose window: the reader opens on a `mailto:` address, the
kernel types a subject and a body into its form and Return, and the
scripted server gets the message the window wrote to `new`.
*/
@(private = "file")
verify_mailfs :: proc(r: ^Result) {
	local: [64]u8
	ln := web_read_file("/net/local", local[:])
	if ln <= 0 {
		return
	}
	host := string(local[:ln])
	count0 := srv.count()

	// factotum, with the password.
	pf := start_path(r, "/bin/factotum", "the loader starts factotum for the mail's password")
	if pf == nil {
		return
	}
	check(r, await_posted("factotum"), "which posts /srv/factotum")
	if !check(r, srv.mount(vfs.boot_namespace, "/srv/factotum", "/mnt/factotum") == vfs.OK, "and the kernel mounts it at /mnt/factotum") {
		finish(r, pf, "and factotum is taken down")
		return
	}
	line_buf: [256]u8
	check(r, net_file_write("/mnt/factotum/ctl", libodin_cat(line_buf[:], "key proto=pass user=glenda server=", host, " !password=hunter2")), "a pass key is written to factotum: a user, a server and the password")
	check(r, net_file_write("/mnt/factotum/ctl", libodin_cat(line_buf[:], "key proto=pass user=nobody server=", host, " !password=wrong")), "and a second, with a password the server will refuse")
	check(r, net_file_write("/mnt/factotum/ctl", "key proto=openpgp user=glenda dom=home !passphrase=correct-horse"), "and the openpgp identity, from the same passphrase as before, so it is the same key")
	check(r, net_file_write("/mnt/factotum/ctl", "key proto=openpgp user=bob dom=home !passphrase=bobs-secret"), "and one for Bob, the other side of a handshake")
	listing: [1024]u8
	n := web_read_file("/mnt/factotum/ctl", listing[:])
	got := string(listing[:max(n, 0)])
	check(r, n > 0 && libodin.contains(got, "key proto=pass user=glenda server=") && !libodin.contains(got, "hunter2"), "the listing names the key and keeps the secret")
	answer: [128]u8
	an := net_file_ask("/mnt/factotum/rpc", libodin_cat(line_buf[:], "start pass user=glenda server=", host), answer[:])
	check(r, an > 0 && string(answer[:an]) == "password hunter2", "and rpc hands the password to a program that asks for it by user and server")

	// The scripted server, then mailfs.
	iargs := [?]string{"imapsrv", "1143"}
	iargv := new(Argv)
	_ = argv_from(iargv, iargs[:])
	im := start_path(r, "/bin/imapsrv", "a scripted IMAP server starts", iargv)
	if im != nil {
		sync.delay(PATIENCE)
		p := start_path(r, "/bin/mailfs", "the loader starts mailfs, mail as files")
		if p != nil {
			mounted := check(r, await_posted("mail"), "which posts /srv/mail") && check(r, srv.mount(vfs.boot_namespace, "/srv/mail", "/mnt/mail") == vfs.OK, "and the kernel mounts it at /mnt/mail")
			if mounted {
				ID1 :: "000000006aac8284.3714e3891dc03ae6"
				ID2 :: "000000006aacfd90.1ccd7668973d1eec"
				ID3 :: "000000006aae7940.b1ffcbb1bb626e10"
				ID4 :: "000000006aae8048.a9fe6197082cb3cc"
				check(r, net_file_write("/mnt/mail/ctl", libodin_cat(line_buf[:], "account glenda ", host, " 1143 plain")), "an account is a user, a server and a port on ctl")
				text: [2048]u8
				n = web_read_file("/mnt/mail/me", text[:])
				check(r, string(text[:max(n, 0)]) == libodin_cat(line_buf[:], "glenda@", host), "and me is the address")
				check(r, net_file_write("/mnt/mail/ctl", "identity home"), "identity names the openpgp key factotum holds for the user")
				n = web_read_file("/mnt/mail/me", text[:])
				check(r, libodin.has_prefix(string(text[:max(n, 0)]), libodin_cat(line_buf[:], "glenda@", host, "\nfpr ")), "and me gains the key's fingerprint")
				check(r, net_file_write("/mnt/mail/ctl", "fetch"), "fetch logs in with the password from factotum and takes the inbox")
				lbuf: [512]u8
				check(r, dir_names("/mnt/mail/inbox", lbuf[:]) == ID1 + " " + ID2 + " " + ID3 + " " + ID4, "and inbox lists the four messages by id, in time order, the message id hashed into the name")
				n = web_read_file("/mnt/mail/inbox/" + ID1 + "/subject", text[:])
				check(r, string(text[:max(n, 0)]) == "A message with two parts and an file", "a subject is unfolded and its encoded words decoded")
				n = web_read_file("/mnt/mail/inbox/" + ID1 + "/from", text[:])
				check(r, string(text[:max(n, 0)]) == "Gl\u00e9nda of Plan 9 <glenda@example.org>", "from is the sender, decoded")
				n = web_read_file("/mnt/mail/inbox/" + ID1 + "/type", text[:])
				check(r, string(text[:max(n, 0)]) == "text/plain", "type is the plain part's")
				n = web_read_file("/mnt/mail/inbox/" + ID1 + "/body", text[:])
				check(r, libodin.has_prefix(string(text[:max(n, 0)]), "Caf\u00e9 au lait"), "and body is that part, decoded from its transfer encoding and charset")
				n = web_read_file("/mnt/mail/inbox/" + ID1 + "/date", text[:])
				check(r, string(text[:max(n, 0)]) == "1789690500 Thu, 17 Sep 2026 20:15:00 -0400", "date is seconds since the epoch and the header's text")
				n = web_read_file("/mnt/mail/inbox/" + ID1 + "/raw", text[:], raw = true)
				check(r, n > 0 && libodin.has_prefix(string(text[:n]), "From: =?utf-8?q?"), "raw is the message as the server sent it")
				n = web_read_file("/mnt/mail/inbox/" + ID2 + "/replyto", text[:])
				check(r, string(text[:max(n, 0)]) == ID1, "a reply's In-Reply-To becomes the first message's id")
				n = web_read_file("/mnt/mail/inbox/" + ID2 + "/from", text[:])
				check(r, string(text[:max(n, 0)]) == "Bob Jones <bob@example.net>", "and its sender reads")
				check(r, dir_names("/mnt/mail/inbox/" + ID1 + "/replies", lbuf[:]) == ID2, "so replies under the first lists the reply")

				// The chats: the same messages, threaded by the other address.
				check(r, dir_names("/mnt/mail/bob@example.net", lbuf[:]) == ID2 + " " + ID3 + " " + ID4, "a chat named for Bob's address holds his three messages, the same directories inbox has")
				check(r, dir_names("/mnt/mail/glenda@example.org", lbuf[:]) == ID1, "and one for the first message's sender holds it")
				n = web_read_file("/mnt/mail/bob@example.net/" + ID3 + "/body", text[:])
				check(r, string(text[:max(n, 0)]) == "the sealed body", "a message reads the same in its chat")

				// Autocrypt in: the reply's header left Bob's key in contacts.
				check(r, dir_names("/mnt/mail/contacts", lbuf[:]) == "bob@example.net", "the reply's Autocrypt header made a contact of its address")
				n = web_read_file("/mnt/mail/contacts/bob@example.net/name", text[:])
				check(r, string(text[:max(n, 0)]) == "Bob Jones", "with the sender's name")
				n = web_read_file("/mnt/mail/contacts/bob@example.net/fingerprint", text[:])
				check(r, string(text[:max(n, 0)]) == "cb186c4f0609a697e4d52dfa6c722b0c1f1e27c18a56708f6525ec27bad9acc9", "the key's fingerprint, the RFC's sample key's")
				n = web_read_file("/mnt/mail/contacts/bob@example.net/key", text[:])
				check(r, n > 0 && libodin.has_prefix(string(text[:n]), "-----BEGIN PGP PUBLIC KEY BLOCK-----"), "the key armored")
				n = web_read_file("/mnt/mail/contacts/bob@example.net/verified", text[:])
				check(r, string(text[:max(n, 0)]) == "no", "and verified says no, until a handshake says yes")

				// A sealed message in: the seal's test left one sealed to this
				// identity, and the inbox opened it through factotum.
				n = web_read_file("/mnt/mail/inbox/" + ID3 + "/subject", text[:])
				check(r, string(text[:max(n, 0)]) == "sealed subject", "a message sealed to the identity opens: its subject is the one inside, not the placeholder")
				n = web_read_file("/mnt/mail/inbox/" + ID3 + "/body", text[:])
				check(r, string(text[:max(n, 0)]) == "the sealed body", "and its body is the text inside, opened with the session key factotum handed back, its signature verified against Bob's contact key")
				n = web_read_file("/mnt/mail/inbox/" + ID4 + "/body", text[:])
				check(r, string(text[:max(n, 0)]) == "(a sealed message whose signature did not verify)", "and the same sealed message with its signature bent is refused, and says so")
				n = web_read_file("/mnt/mail/inbox/" + ID3 + "/raw", text[:], raw = true)
				check(r, n > 0 && libodin.contains(string(text[:n]), "multipart/encrypted"), "while raw is the sealed message as it came")
				// Out: a submission server, and a message written to new.
				sargs := [?]string{"smtpsrv", "1587", "/usr/glenda/sent.eml", "2"}
				sargv := new(Argv)
				_ = argv_from(sargv, sargs[:])
				if sm := start_path(r, "/bin/smtpsrv", "a scripted SMTP submission server starts", sargv); sm != nil {
					sync.delay(PATIENCE)
					check(r, net_file_write("/mnt/mail/ctl", libodin_cat(line_buf[:], "smtp ", host, " 1587 plain")), "the submission server is named on ctl")
					check(r, !net_file_write("/mnt/mail/new", "colour: blue\n\nx"), "a write to new with a header no network knows is refused before any wire")
					check(r, net_file_write("/mnt/mail/new", "to: bob@example.net\nsubject: hello there\nreplyto: " + ID1 + "\n\nA line.\n.dot line\n"), "a message written to new as the block is submitted, and the write returns when it is taken")
					sent := dir_names("/mnt/mail/sent", lbuf[:])
					check(r, count_words(sent) == 1, "and what went out is a message of sent")
					bob_chat: [512]u8
					chat := dir_names("/mnt/mail/bob@example.net", bob_chat[:])
					check(r, count_words(chat) == 4 && libodin.contains(chat, sent), "and of the chat with Bob, beside his three")
					n = web_read_file(libodin_cat(line_buf[:], "/mnt/mail/sent/", sent, "/subject"), text[:])
					check(r, string(text[:max(n, 0)]) == "hello there", "with its subject")
					n = web_read_file("/usr/glenda/sent.eml", text[:], raw = true)
					arrived := string(text[:max(n, 0)])
					check(r, n > 0 && libodin.contains(arrived, libodin_cat(line_buf[:], "From: glenda@", host, "\r\n")) && libodin.contains(arrived, "To: bob@example.net\r\n") && libodin.contains(arrived, "Subject: ...\r\n"), "the server got the message with its From and To built, and the placeholder subject, since Bob has a key")
					check(r, libodin.contains(arrived, "In-Reply-To: <one@example.org>\r\n"), "and In-Reply-To names the message the reply answers, by its message id")
					check(r, libodin.contains(arrived, libodin_cat(line_buf[:], "Autocrypt: addr=glenda@", host, "; prefer-encrypt=mutual;")) && libodin.contains(arrived, "Content-Type: multipart/encrypted;"), "and it carries the person's key in its Autocrypt header and is sealed")
					unames := [?]string{"pgptest", "unseal", "/usr/glenda/sent.eml"}
					script_says(r, "/bin/pgptest", unames[:], PATIENCE * 10, "a program with Bob's secret key starts on it", "ok", "and opens it: the real subject and the body whole are inside, sealed to the key Bob's header carried")
					check(r, !net_file_write("/mnt/mail/new", "to: nobody@nowhere\n\nx"), "a recipient the server refuses fails the write")
					check(r, net_file_write("/mnt/mail/ctl", "seal on"), "seal on asks for sealed mail only")
					check(r, !net_file_write("/mnt/mail/new", "to: carol@example.org\nsubject: plain\n\nx"), "and a message to a contact without a key is refused before any wire")
					check(r, net_file_write("/mnt/mail/ctl", "seal off"), "and seal off lets it go again")

					// The compose window: typed into, and sent through new.
					if s := devfs.raw_surface(); s != nil && s.pixels != nil && s.bytes_pp == 4 {
						dcount0 := srv.count()
						if ps := start_draw_server(r, s, "the loader starts the draw server for the compose window", "which posts /srv/draw for the reader to find", "and paints a desktop before the reader opens a window"); ps != nil {
							cnames := [?]string{"mothra", "mailto:carol@example.org"}
							cargv := new(Argv)
							_ = argv_from(cargv, cnames[:])
							if pm := start_path(r, "/bin/mothra", "the loader starts the reader on a mailto address, the compose window", cargv); pm != nil {
								bx, by, bw := await_bar(s)
								check(r, bx >= 0, "and the reader opens a framed window on the form")
								/*
								The first Tab selects the address, and a selected row sits on a
								bar of the face. That bar is the sign the reader's key loop is
								running, so the rest is typed only once it shows. A fixed delay
								here used to lose the whole line now and then: typed before the
								reader read keys, the form stayed empty and nothing was sent.
								A Tab with no bar after it is typed again.
								*/
								face := fb.pack(s, fb.MAGNESIUM)
								selected := false
								for _ in 0 ..< 5 {
									type_text("\t")
									for _ in 0 ..< PATIENCE * 5 {
										for y in by + 30 ..< min(by + 400, s.height) {
											if _, run := row_span(s, y, face, bx + 4, bx + bw - 4); run > 100 {
												selected = true
												break
											}
										}
										if selected {
											break
										}
										sync.delay(1)
									}
									if selected {
										break
									}
								}
								check(r, selected, "and a Tab selects the address row, on a bar of the face: the reader is reading keys")
								// Tab to the subject, the subject, Tab to the body, the body, and
								// Return sends.
								type_text("\ttyped subject\ttyped body\n")
								arrived := false
								for _ in 0 ..< PATIENCE * 40 {
									n = web_read_file("/usr/glenda/sent.eml", text[:], raw = true)
									arrived = n > 0 && libodin.contains(string(text[:n]), "Subject: typed subject\r\n")
									if arrived {
										break
									}
									sync.delay(1)
								}
								check(r, arrived, "and the typed subject reaches the submission server through new, the window's form written as the block")
								check(r, arrived && libodin.contains(string(text[:max(n, 0)]), "\r\n\r\ntyped body\r\n") && libodin.contains(string(text[:max(n, 0)]), "To: carol@example.org\r\n"), "with the typed body and the address the mailto filled in, plain since Carol has no key here")
								_ = notepg_kernel(pm.note_group, "kill")
								check(r, end(pm, PATIENCE * 5), "and the reader, told to end, ends")
								finish(r, pm, "and is taken down")
							}
							stop_draw_server(r, ps, dcount0)
						}
					}
					check(r, wait(sm, PATIENCE * 5), "and the submission server, its sessions served, exits")
					check(r, string(sm.exit.text[:sm.exit.text_len]) == "ok", "with ok: two messages taken and one refused")
					finish(r, sm, "and is taken down")
				}

				// SecureJoin, between this mailfs and a second, over a spool of
				// files: a bent fingerprint first, which must end in no, then
				// the invite as made, which ends in yes on both sides.
				verify_securejoin(r, host)

				// IDLE, and the handshake over the servers: a relay and a
				// mailbox server each, both sides idling, no fetch asked.
				verify_idle(r, host)

				// Chatmail: an account in one request, through webfs, from a
				// scripted relay.
				verify_chatmail(r, host)

				// The fediverse login: the authorization code flow against a
				// scripted instance, ending with a token in factotum.
				verify_fedi_login(r, host)

				// The AT login: a session on an app password from factotum,
				// its token back in factotum.
				verify_at_login(r, host)

				// The other way in on AT: OAuth with PAR, PKCE and DPoP, the
				// token bound to a key factotum holds.
				verify_at_oauth(r, host)

				// Chat: a login at a scripted homeserver, a sync with the
				// token, and a message put in a room.
				verify_matrix_login(r, host)

				// Publishing: a directory served as HTTP, static and .md
				// rendered, fetched back through webfs.
				verify_httpd(r, host)

				// The two-way link: a mention out to a scripted endpoint,
				// and one in, verified, kept and served at /mnt/mention.
				verify_webmention(r, host)

				// The wrong password: the server refuses the login, and the fetch says so.
				check(r, net_file_write("/mnt/mail/ctl", libodin_cat(line_buf[:], "account nobody ", host, " 1143 plain")), "a second account, whose password is wrong")
				check(r, !net_file_write("/mnt/mail/ctl", "fetch"), "is refused by the server, and its fetch fails")
				check(r, vfs.unmount_path(vfs.boot_namespace, "", "/mnt/mail") == vfs.OK, "the mount of mailfs comes down")
			}
			check(r, srv.remove("mail") == vfs.OK, "and the kernel takes its name away")
			check(r, wait(p, PATIENCE * 5), "and mailfs, its pipe gone, exits")
			finish(r, p, "and is taken down")
		}
		check(r, wait(im, PATIENCE * 5), "and the scripted server, both sessions served, exits")
		check(r, string(im.exit.text[:im.exit.text_len]) == "ok", "with ok: one login and one refusal")
		finish(r, im, "and is taken down")
	}

	if c, err := vfs.open_path(vfs.boot_namespace, "/mnt/factotum/ctl", vfs.O_RDONLY); err == vfs.OK {
		check(r, vfs.chan_remove(c) == vfs.OK, "a remove of its file is factotum's stop")
		vfs.chan_close(c)
	}
	check(r, wait(pf, PATIENCE), "and factotum exits")
	check(r, srv.remove("factotum") == vfs.OK, "and the kernel takes its name away")
	finish(r, pf, "and factotum is taken down")
	pipe.quiesce()
	check(r, vfs.unmount_path(vfs.boot_namespace, "", "/mnt/factotum") == vfs.OK, "and its mount comes down")
	check(r, srv.count() == count0, "and /srv holds what it held")
	reap_orphans()
}

// remove_file takes a file away by name, if it is there.
@(private = "file")
remove_file :: proc(path: string) {
	c, err := vfs.resolve(vfs.boot_namespace, path)
	if err != vfs.OK {
		return
	}
	_ = vfs.chan_remove(c)
	vfs.chan_close(c)
}

// tofu_fetch runs `tlssrv -u`, the capsule no root names, for one fetch.
@(private = "file")
tofu_fetch :: proc(r: ^Result, url: string, body: []u8, hash: []u8, what: string) -> bool {
	targs := [?]string{"tlssrv", "4433", "-u"}
	targv := new(Argv)
	_ = argv_from(targv, targs[:])
	ts := start_path(r, "/bin/tlssrv", what, targv)
	if ts == nil {
		return false
	}
	sync.delay(PATIENCE)
	bn, _, ok := web_fetch(url, body, hash)
	for i in bn ..< len(body) {
		body[i] = 0
	}
	// The server ends either way: it served, or the client hung up on it.
	_ = wait(ts, PATIENCE * 5)
	finish(r, ts, "and it is taken down")
	return ok
}

// web_socket drives `/mnt/web/N/ws` against websrv's `/ws`: frames each way,
// the ping the server sent answered, and a close answered with the count.
@(private = "file")
web_socket :: proc(r: ^Result, url: string) {
	num: [16]u8
	n := web_read_file("/mnt/web/clone", num[:])
	conv := string(num[:max(n, 0)])
	path: [128]u8
	line: [256]u8
	ctl := libodin_cat(path[:], "/mnt/web/", conv, "/ctl")
	if !check(r, n > 0 && net_file_write(ctl, libodin_cat(line[:], "url ", url)) && net_file_write(ctl, "upgrade"), "a conversation asks for a WebSocket with ctl upgrade") {
		return
	}
	c, err := vfs.open_path(vfs.boot_namespace, libodin_cat(path[:], "/mnt/web/", conv, "/ws"), vfs.O_RDWR)
	if !check(r, err == vfs.OK, "and the open of ws starts the upgrade") {
		return
	}
	frame: [256]u8
	_, werr := vfs.chan_write(c, 0, transmute([]u8)string("hello"))
	got, rerr := vfs.chan_read(c, 0, frame[:])
	check(r, werr == vfs.OK && rerr == vfs.OK && string(frame[:got]) == "echo: hello", "a write is a frame out, and a read the frame that came back")
	_, werr = vfs.chan_write(c, 0, transmute([]u8)string("two"))
	got, rerr = vfs.chan_read(c, 0, frame[:])
	check(r, werr == vfs.OK && rerr == vfs.OK && string(frame[:got]) == "echo: two", "a second frame each way")
	check(r, net_file_write(libodin_cat(path[:], "/mnt/web/", conv, "/ctl"), "hangup"), "hangup closes the socket")
	got, rerr = vfs.chan_read(c, 0, frame[:])
	check(r, rerr == vfs.OK && string(frame[:got]) == "pongs 1", "and the server's last frame says the ping it sent was answered")
	got, rerr = vfs.chan_read(c, 0, frame[:])
	check(r, rerr == vfs.OK && got == 0, "and then the socket ends")
	vfs.chan_close(c)
}

/*
verify_webfs runs `servers/webfs`, the HTTP client as files, against two
scripted servers on this machine's own stack: `websrv`, plain HTTP with a
chunked body, and `tlssrv`, which answers a GET over TLS. A conversation is
taken off `/mnt/web/clone`, the URL written to its `ctl`, the body read to its
end and the hash after it. The body is the bytes the fixture sent, the hash is
their sha256, and the store under `/usr/glenda/lib/web` holds the body under
that hash with a line in `names` naming the URL -- `docs/WEB.md` section 3's
boot line, "a body from a scripted server lands in the store under its hash".
*/
@(private = "file")
verify_webfs :: proc(r: ^Result) {
	names := [?]string{"webfs", "-s", "/usr/glenda/lib/web"}
	argv := new(Argv)
	if !check(r, argv != nil && argv_from(argv, names[:]), "a record for webfs's arguments") {
		return
	}
	p := start_path(r, "/bin/webfs", "the loader starts webfs, the web as files", argv)
	if p == nil {
		return
	}
	if !check(r, await_posted("web"), "which posts /srv/web") {
		finish(r, p, "and webfs is taken down")
		return
	}
	if !check(r, srv.mount(vfs.boot_namespace, "/srv/web", "/mnt/web") == vfs.OK, "and the kernel mounts it at /mnt/web") {
		finish(r, p, "and webfs is taken down")
		return
	}

	// This machine's own address and name, for the URLs.
	local: [64]u8
	ln := web_read_file("/net/local", local[:])
	sysname: [64]u8
	sn := web_read_file("/net/sysname", sysname[:])

	// Plain HTTP, a chunked body.
	{
		wargs := [?]string{"websrv", "8080", "9"}
		wargv := new(Argv)
		_ = argv_from(wargv, wargs[:])
		ws := start_path(r, "/bin/websrv", "a scripted HTTP server starts", wargv)
		if ws != nil {
			sync.delay(PATIENCE)
			url_buf: [128]u8
			line_buf: [128]u8
			url := libodin_cat(url_buf[:], "http://", string(local[:ln]), ":8080/")
			body: [1024]u8
			hash: [80]u8
			bn, hn, ok := web_fetch(url, body[:], hash[:])
			check(r, ok && string(body[:bn]) == "hello, web\n", "webfs fetches a chunked body over http and streams it whole")
			check(r, hn == 65 && string(hash[:64]) == "e65c8086738e71ec1ad09627c56b0c1b90f0cbbf00ff0c253728b094f2bba149", "and its hash is the body's sha256")
			stored: [1024]u8
			sn2 := web_read_file("/usr/glenda/lib/web/store/e65c8086738e71ec1ad09627c56b0c1b90f0cbbf00ff0c253728b094f2bba149", stored[:], raw = true)
			check(r, sn2 == bn && string(stored[:sn2]) == string(body[:bn]), "and the store holds the body under that hash")
			index: [4096]u8
			in_ := web_read_file("/usr/glenda/lib/web/names", index[:])
			check(r, in_ > 0 && libodin.contains(string(index[:in_]), url) && libodin.contains(string(index[:in_]), "e65c8086738e71ec1ad09627c56b0c1b90f0cbbf00ff0c253728b094f2bba149"), "and names has a line for the URL and the hash")

			// A body that arrives gzipped is served inflated, and the hash
			// is of the bytes served.
			url = libodin_cat(url_buf[:], "http://", string(local[:ln]), ":8080/gz")
			bn, hn, ok = web_fetch(url, body[:], hash[:])
			check(r, ok && string(body[:bn]) == "hello, compressed web\n", "a gzipped body is inflated before it is served")
			check(r, hn == 65 && string(hash[:64]) == "f315d54fb4a5d7893272f07a256ea3936b47c0ea54736291bf882e843e41d3a2", "and its hash is the inflated body's")

			// The cookie jar: a response sets one, the next request carries
			// it, the jar file lists it, and `cookies off` leaves it out.
			url = libodin_cat(url_buf[:], "http://", string(local[:ln]), ":8080/cookie")
			bn, hn, ok = web_fetch(url, body[:], hash[:])
			check(r, ok && string(body[:bn]) == "cookie set\n", "a response sets a cookie")
			jar: [1024]u8
			jn := web_read_file("/mnt/web/cookies", jar[:])
			check(r, jn > 0 && libodin.contains(string(jar[:jn]), libodin_cat(line_buf[:], string(local[:ln]), " / session abc")), "which the jar lists as host, path, name and value")
			url = libodin_cat(url_buf[:], "http://", string(local[:ln]), ":8080/whoami")
			bn, hn, ok = web_fetch(url, body[:], hash[:])
			check(r, ok && string(body[:bn]) == "cookie: session=abc\n", "and the next request to that host carries it")
			bn, hn, ok = web_fetch(url, body[:], hash[:], "cookies off")
			check(r, ok && string(body[:bn]) == "cookie: none\n", "unless the conversation said cookies off")

			// A POST: a form's body through the conversation's postbody.
			url = libodin_cat(url_buf[:], "http://", string(local[:ln]), ":8080/login")
			bn, hn, ok = web_fetch(url, body[:], hash[:], "", nil, "user=glenda&pass=secret&next=%2F")
			check(r, ok && string(body[:bn]) == "welcome glenda\n", "a POST carries its body, and the server answers what it was sent")

			// A connection kept for the next request: the server counts the
			// requests a connection carried, and drops it after two.
			url = libodin_cat(url_buf[:], "http://", string(local[:ln]), ":8080/ka")
			bn, hn, ok = web_fetch(url, body[:], hash[:])
			check(r, ok && string(body[:bn]) == "keep 1\n", "a response that did not say close leaves its connection kept")
			bn, hn, ok = web_fetch(url, body[:], hash[:])
			check(r, ok && string(body[:bn]) == "keep 2\n", "and the next request there rides the same connection")
			bn, hn, ok = web_fetch(url, body[:], hash[:])
			check(r, ok && string(body[:bn]) == "keep 1\n", "and one the server dropped while it idled is dialled again, with no error")

			// The WebSocket: upgraded, a ping answered, frames each way, a close.
			url = libodin_cat(url_buf[:], "http://", string(local[:ln]), ":8080/ws")
			web_socket(r, url)
			check(r, wait(ws, PATIENCE * 5), "and the scripted server, its connections served, exits")
			finish(r, ws, "and is taken down")
		}
	}

	// HTTPS, through the same trust store tlsclient uses.
	{
		targs := [?]string{"tlssrv", "4433"}
		targv := new(Argv)
		_ = argv_from(targv, targs[:])
		ts := start_path(r, "/bin/tlssrv", "a scripted TLS server starts for the web", targv)
		if ts != nil {
			sync.delay(PATIENCE)
			url_buf: [128]u8
			url := libodin_cat(url_buf[:], "https://", string(sysname[:sn]), ":4433/")
			body: [1024]u8
			hash: [80]u8
			bn, hn, ok := web_fetch(url, body[:], hash[:])
			check(r, ok && string(body[:bn]) == "hello, secure web\n", "webfs fetches a body over https, the chain verified against the trust store")
			check(r, hn == 65 && string(hash[:64]) == "43e8e41c52a64133b65e76d326756f682ffb1e2ce2293f8d61374529d1f08f70", "and its hash is that body's sha256")
			check(r, wait(ts, PATIENCE * 5), "and the TLS server exits")
			finish(r, ts, "and is taken down")
		}
	}

	// Gemini, the same TLS fixture answering a capsule's line.
	{
		targs := [?]string{"tlssrv", "4433"}
		targv := new(Argv)
		_ = argv_from(targv, targs[:])
		ts := start_path(r, "/bin/tlssrv", "a scripted TLS server starts for gemini", targv)
		if ts != nil {
			sync.delay(PATIENCE)
			url_buf: [128]u8
			url := libodin_cat(url_buf[:], "gemini://", string(sysname[:sn]), ":4433/")
			body: [1024]u8
			hash: [80]u8
			status: [128]u8
			bn, _, ok := web_fetch(url, body[:], hash[:], "", status[:])
			check(r, ok && string(body[:bn]) == "# hello, gemini\n", "webfs fetches a gemini capsule: one TLS connection, one line, one response")
			check(r, libodin.contains(string(status[:]), "20 text/gemini"), "and its status is the capsule's status and media type")
			check(r, wait(ts, PATIENCE * 5), "and the TLS server exits")
			finish(r, ts, "and is taken down")
		}
	}

	// Trust on first use: a capsule whose certificate no root names.
	{
		CAPSULE_FP :: "f8b32a654ccbeb0c19e5a882d3f3faf4eca6a8e47f7576e546e888d93d86df8c"
		url_buf: [128]u8
		key_buf: [128]u8
		url := libodin_cat(url_buf[:], "gemini://", string(sysname[:sn]), ":4433/")
		key := libodin_cat(key_buf[:], string(sysname[:sn]), "!4433 ", CAPSULE_FP)
		body: [1024]u8
		hash: [80]u8
		known: [512]u8
		remove_file("/usr/glenda/lib/web/known")
		ok := tofu_fetch(r, url, body[:], hash[:], "a capsule starts with a certificate no root names")
		check(r, ok && string(body[:len("# hello, gemini\n")]) == "# hello, gemini\n", "webfs trusts it on first use")
		kn := web_read_file("/usr/glenda/lib/web/known", known[:])
		check(r, kn > 0 && string(known[:kn]) == key, "and writes down its host, port and fingerprint")
		ok = tofu_fetch(r, url, body[:], hash[:], "the capsule starts again, the same certificate")
		check(r, ok, "the same certificate the next time is taken")
		check(r, net_file_write("/usr/glenda/lib/web/known", libodin_cat(key_buf[:], string(sysname[:sn]), "!4433 00000000000000000000000000000000000000000000000000000000000000ff\n")), "the line is edited, as for a key that changed")
		ok = tofu_fetch(r, url, body[:], hash[:], "the capsule starts a third time")
		check(r, !ok, "and a certificate that is not the one written down is refused")
		url = libodin_cat(url_buf[:], "https://", string(sysname[:sn]), ":4433/")
		ok = tofu_fetch(r, url, body[:], hash[:], "the capsule's server answers https")
		check(r, !ok, "and https never trusts on first use: the certificate must chain")
		remove_file("/usr/glenda/lib/web/known")
	}

	check(r, vfs.unmount_path(vfs.boot_namespace, "", "/mnt/web") == vfs.OK, "the mount of webfs comes down")
	check(r, srv.remove("web") == vfs.OK, "and the kernel takes its name away")
	check(r, wait(p, PATIENCE * 5), "and webfs, its pipe gone, exits")
	finish(r, p, "and is taken down")
}

/*
verify_httpd runs webfs and cmd/httpd on this machine's stack. A small
site is written under a root, httpd serves it, and webfs fetches it
back: a .md page rendered to HTML, a static file served as it is, and a
directory answered by its index. docs/WEB.md section 9's "a page served
both ways", the HTTP half.
*/
@(private = "file")
verify_httpd :: proc(r: ^Result, host: string) {
	wnames := [?]string{"webfs", "-s", "/usr/glenda/lib/web"}
	wargv := new(Argv)
	_ = argv_from(wargv, wnames[:])
	pw := start_path(r, "/bin/webfs", "webfs starts again, to fetch the site back", wargv)
	if pw == nil {
		return
	}
	if !check(r, await_posted("web"), "and posts /srv/web") || !check(r, srv.mount(vfs.boot_namespace, "/srv/web", "/mnt/web") == vfs.OK, "which the kernel mounts") {
		finish(r, pw, "and webfs is taken down")
		return
	}
	// The site: a root, an index, a page and a static file.
	_ = make_disk_dir("/usr/glenda/site")
	made := write_disk_file("/usr/glenda/site/index.md", "# Home\n\nWelcome to the site.\n\n- one\n- two\n\n[the page](/page.md)\n")
	made = write_disk_file("/usr/glenda/site/page.md", "# The Page\n\nA paragraph with <b>markup</b> & an ampersand.\n\n> a quote\n") && made
	made = write_disk_file("/usr/glenda/site/style.css", "body { color: black; }\n") && made
	check(r, made, "a small site is written under a root: an index, a page and a stylesheet")
	// A feed for the site: mkfeed writes an Atom file, one entry a page,
	// which httpd then serves and a person with feedfs follows.
	base_url: [96]u8
	bu := libodin_cat(base_url[:], "http://", host, ":8082")
	fnames := [?]string{"mkfeed", "-b", bu, "-t", "Glenda's site", "/usr/glenda/site", "/usr/glenda/site/feed.atom"}
	fargv := new(Argv)
	_ = argv_from(fargv, fnames[:])
	pf := start_path(r, "/bin/mkfeed", "mkfeed writes an Atom feed for the site", fargv)
	if pf != nil {
		check(r, wait(pf, PATIENCE * 5), "and mkfeed exits")
		finish(r, pf, "and is taken down")
		fbuf: [4096]u8
		fn := web_read_file("/usr/glenda/site/feed.atom", fbuf[:], raw = true)
		feed := string(fbuf[:max(fn, 0)])
		check(r, libodin.contains(feed, "<feed xmlns=\"http://www.w3.org/2005/Atom\">") && libodin.contains(feed, "<title>The Page</title>") && libodin.contains(feed, "<link href=\"" + "http://") && libodin.contains(feed, "/page.html\"/>") && libodin.contains(feed, "<title>Home</title>"), "the feed is Atom, an entry a page, its title the page's heading and its link the page as .html")
	}
	// Six connections, one per fetch below, then httpd exits cleanly the
	// way the step-0 web server does, so its listen leaves nothing held.
	sargs := [?]string{"httpd", "-r", "/usr/glenda/site", "8082", "6"}
	sargv := new(Argv)
	_ = argv_from(sargv, sargs[:])
	ps := start_path(r, "/bin/httpd", "httpd starts, the site served as HTTP", sargv)
	if ps != nil {
		sync.delay(PATIENCE)
		url_buf: [128]u8
		body: [4096]u8
		hash: [80]u8
		// The .md page, rendered to HTML.
		bn, _, ok := web_fetch(libodin_cat(url_buf[:], "http://", host, ":8082/page.md"), body[:], hash[:])
		got := string(body[:max(bn, 0)])
		check(r, ok && libodin.contains(got, "<h1>The Page</h1>") && libodin.contains(got, "<p>A paragraph with &lt;b&gt;markup&lt;/b&gt; &amp; an ampersand.</p>") && libodin.contains(got, "<blockquote>a quote</blockquote>"), "a .md page is rendered to HTML, its heading, its paragraph with the markup made safe, and its quote")
		// The static file, served as it is.
		bn, _, ok = web_fetch(libodin_cat(url_buf[:], "http://", host, ":8082/style.css"), body[:], hash[:])
		check(r, ok && string(body[:max(bn, 0)]) == "body { color: black; }\n", "a static file is served as it is")
		// The root, answered by its index.
		bn, _, ok = web_fetch(libodin_cat(url_buf[:], "http://", host, ":8082/"), body[:], hash[:])
		check(r, ok && libodin.contains(string(body[:max(bn, 0)]), "<h1>Home</h1>") && libodin.contains(string(body[:max(bn, 0)]), "<li>one</li>"), "a directory is answered by its index, its list rendered")
		// A page that is not there: httpd answers a 404, whose body says
		// so; webfs serves the body of a non-200, so the body is the proof.
		bn, _, _ = web_fetch(libodin_cat(url_buf[:], "http://", host, ":8082/nope.md"), body[:], hash[:])
		check(r, libodin.contains(string(body[:max(bn, 0)]), "not found"), "a page that is not there is a 404, whose body says not found")
		// A path that climbs out of the root is not served, whether the
		// client normalised it away or httpd refused it.
		bn, _, _ = web_fetch(libodin_cat(url_buf[:], "http://", host, ":8082/../secret"), body[:], hash[:])
		got2 := string(body[:max(bn, 0)])
		check(r, libodin.contains(got2, "not found") || libodin.contains(got2, "bad request"), "and a path that climbs out of the root is not served")
		// The feed, served with its Atom type.
		bn, _, ok = web_fetch(libodin_cat(url_buf[:], "http://", host, ":8082/feed.atom"), body[:], hash[:])
		check(r, ok && libodin.contains(string(body[:max(bn, 0)]), "<title>The Page</title>"), "and the feed is served, so the site is followable")
		// Its six connections served, httpd exits on its own; a kill is
		// the fallback if a fetch never reached it.
		if !wait(ps, PATIENCE * 5) {
			_ = notepg_kernel(ps.note_group, "kill")
			_ = end(ps, PATIENCE * 5)
		}
		check(r, exit_done(ps), "and httpd, its six connections served, exits")
		finish(r, ps, "and is taken down")
	} else {
		finish(r, ps, "httpd is taken down")
	}
	// The same site on Gemini: gemd serves it over TLS, and webfs fetches
	// gemini://<this machine>/page.md, the .md served as it is. The cert in
	// /lib/tls/roots names this machine, so a fetch by that name verifies.
	sysname: [64]u8
	syn := web_read_file("/net/sysname", sysname[:])
	if syn > 0 {
		gnames := [?]string{"gemd", "-r", "/usr/glenda/site", "1965", "1"}
		gargv := new(Argv)
		_ = argv_from(gargv, gnames[:])
		pg := start_path(r, "/bin/gemd", "gemd serves the site over Gemini", gargv)
		if pg != nil {
			sync.delay(PATIENCE)
			gurl: [128]u8
			gbody: [4096]u8
			ghash: [80]u8
			bn, _, ok := web_fetch(libodin_cat(gurl[:], "gemini://", string(sysname[:syn]), ":1965/page.md"), gbody[:], ghash[:])
			check(r, ok && libodin.contains(string(gbody[:max(bn, 0)]), "# The Page") && libodin.contains(string(gbody[:max(bn, 0)]), "> a quote"), "the same .md page is served over Gemini as it is, its gemtext raw")
			if !wait(pg, PATIENCE * 5) {
				_ = notepg_kernel(pg.note_group, "kill")
				_ = end(pg, PATIENCE * 5)
			}
			check(r, exit_done(pg), "and gemd, its connection served, exits")
			finish(r, pg, "and is taken down")
		}
	}
	check(r, vfs.unmount_path(vfs.boot_namespace, "", "/mnt/web") == vfs.OK, "the mount of webfs comes down")
	check(r, srv.remove("web") == vfs.OK, "and the kernel takes its name away")
	check(r, wait(pw, PATIENCE * 5), "and webfs exits")
	finish(r, pw, "and is taken down")
}

/*
verify_webmention runs webfs, a scripted endpoint, httpd and mentionfs.
It proves the two-way link both ways: cmd/webmention finds the link in a
page and tells a scripted endpoint, which records the source and target;
and a mention posted to httpd, whose source links to the target, is
verified, kept, and served by mentionfs at /mnt/mention, while a source
that does not link here is refused. docs/WEB.md section 9.
*/
@(private = "file")
verify_webmention :: proc(r: ^Result, host: string) {
	wnames := [?]string{"webfs", "-s", "/usr/glenda/lib/web"}
	wargv := new(Argv)
	_ = argv_from(wargv, wnames[:])
	pw := start_path(r, "/bin/webfs", "webfs starts again, for the mentions", wargv)
	if pw == nil {
		return
	}
	if !check(r, await_posted("web"), "and posts /srv/web") || !check(r, srv.mount(vfs.boot_namespace, "/srv/web", "/mnt/web") == vfs.OK, "which the kernel mounts") {
		finish(r, pw, "and webfs is taken down")
		return
	}
	// The scripted endpoint, and httpd with a mention store.
	enames := [?]string{"websrv", "8083", "99"}
	eargv := new(Argv)
	_ = argv_from(eargv, enames[:])
	es := start_path(r, "/bin/websrv", "a scripted endpoint starts", eargv)
	hnames := [?]string{"httpd", "-r", "/usr/glenda/site", "-m", "/usr/glenda/lib/web", "8082", "99"}
	hargv := new(Argv)
	_ = argv_from(hargv, hnames[:])
	ph := start_path(r, "/bin/httpd", "httpd starts, with a mention store", hargv)
	if es != nil && ph != nil {
		sync.delay(PATIENCE)
		url_buf: [160]u8
		line_buf: [256]u8
		body: [4096]u8
		hash: [80]u8
		// -- Out: a page's link told to the endpoint --------------------------
		// A page of the person's own, linking to the endpoint's target.
		src_link := libodin_cat(line_buf[:], "http://", host, ":8083/wm-target")
		made := write_disk_file("/usr/glenda/site/out.md", libodin_cat(body[:], "# Out\n\nA nod to [a page](", src_link, ").\n"))
		check(r, made, "a page is written that links to a page with an endpoint")
		mnames := [?]string{"webmention", "-s", "http://vectra.example/out.html", "/usr/glenda/site/out.md"}
		margv := new(Argv)
		_ = argv_from(margv, mnames[:])
		pm := start_path(r, "/bin/webmention", "webmention reads the page and tells each link", margv)
		if pm != nil {
			check(r, wait(pm, PATIENCE * 5), "and webmention exits")
			finish(r, pm, "and is taken down")
			rn := web_read_file("/usr/glenda/wm-received.txt", body[:], raw = true)
			got := string(body[:max(rn, 0)])
			tgt_buf: [160]u8
			want_tgt := libodin_cat(tgt_buf[:], "target=http://", host, ":8083/wm-target")
			check(r, libodin.contains(got, "source=http://vectra.example/out.html") && libodin.contains(got, want_tgt), "the endpoint, discovered from the target's Link header, was told the source and the target")
		}
		// -- In: a mention received, verified, and served ---------------------
		// A source that links to the target here is a mention kept. Its URL
		// keeps its own buffer, since url_buf is reused for the POST below.
		src_buf: [96]u8
		src_url := libodin_cat(src_buf[:], "http://", host, ":8083/wm-source")
		form: [512]u8
		fn := libodin_cat(form[:], "source=", src_url, "&target=http%3A%2F%2Fvectra.example%2Fpage.html")
		// httpd's answer body is the proof: web_fetch reports ok on a 2xx.
		bn, _, ok := web_fetch(libodin_cat(url_buf[:], "http://", host, ":8082/mention"), body[:], hash[:], post = fn)
		check(r, ok && libodin.contains(string(body[:max(bn, 0)]), "accepted"), "a mention posted to httpd, whose source links to the target, is accepted")
		// A source that does not link here is refused, its body saying so.
		nn := libodin_cat(form[:], "source=http://", host, ":8083/wm-nolink&target=http%3A%2F%2Fvectra.example%2Fpage.html")
		bn, _, _ = web_fetch(libodin_cat(url_buf[:], "http://", host, ":8082/mention"), body[:], hash[:], post = nn)
		check(r, libodin.contains(string(body[:max(bn, 0)]), "does not link"), "and one whose source does not link here is refused, the control")
		// mentionfs serves the kept mention at /mnt/mention.
		snames := [?]string{"mentionfs", "-s", "/usr/glenda/lib/web"}
		sargv := new(Argv)
		_ = argv_from(sargv, snames[:])
		pms := start_path(r, "/bin/mentionfs", "mentionfs starts on the mention store", sargv)
		if pms != nil && check(r, await_posted("mention"), "which posts /srv/mention") && check(r, srv.mount(vfs.boot_namespace, "/srv/mention", "/mnt/mention") == vfs.OK, "and the kernel mounts it at /mnt/mention") {
			lbuf: [1024]u8
			listing := dir_names("/mnt/mention", lbuf[:])
			check(r, libodin.contains(listing, "page.html"), "the mention is filed under the page it is about, page.html")
			ids := dir_names("/mnt/mention/page.html", lbuf[:])
			id := ids
			for i in 0 ..< len(ids) {
				if ids[i] == ' ' {
					id = ids[:i]
					break
				}
			}
			check(r, len(id) > 0, "which holds the mention as a message")
			n := web_read_file(libodin_cat(line_buf[:], "/mnt/mention/page.html/", id, "/from"), body[:])
			check(r, string(body[:max(n, 0)]) == src_url, "from is the source that mentioned the page")
			n = web_read_file(libodin_cat(line_buf[:], "/mnt/mention/page.html/", id, "/subject"), body[:])
			check(r, string(body[:max(n, 0)]) == "http://vectra.example/page.html", "subject is the target page")
			n = web_read_file(libodin_cat(line_buf[:], "/mnt/mention/page.html/", id, "/body"), body[:])
			check(r, string(body[:max(n, 0)]) == "Source", "and body is the source's title, off the page httpd fetched")
			check(r, vfs.unmount_path(vfs.boot_namespace, "", "/mnt/mention") == vfs.OK, "the mount of mentionfs comes down")
		}
		check(r, srv.remove("mention") == vfs.OK, "and the kernel takes mentionfs's name away")
		_ = notepg_kernel(pms.note_group, "kill")
		check(r, end(pms, PATIENCE * 5), "and mentionfs, told to end, ends")
		finish(r, pms, "and is taken down")
		_ = notepg_kernel(ph.note_group, "kill")
		check(r, end(ph, PATIENCE * 5), "httpd, told to end, ends")
		finish(r, ph, "and is taken down")
		_ = notepg_kernel(es.note_group, "kill")
		check(r, end(es, PATIENCE * 5), "and the endpoint, told to end, ends")
		finish(r, es, "and is taken down")
	} else {
		finish(r, ph, "httpd is taken down")
		finish(r, es, "and the endpoint")
	}
	check(r, vfs.unmount_path(vfs.boot_namespace, "", "/mnt/web") == vfs.OK, "the mount of webfs comes down")
	check(r, srv.remove("web") == vfs.OK, "and the kernel takes its name away")
	check(r, wait(pw, PATIENCE * 5), "and webfs exits")
	finish(r, pw, "and is taken down")
}

// make_disk_dir makes a directory on the disk, true if it is there after.
@(private = "file")
make_disk_dir :: proc(path: string) -> bool {
	c, err := vfs.create_path(vfs.boot_namespace, path, vfs.O_RDONLY, vfs.DMDIR | 0o755)
	if err == vfs.OK {
		vfs.chan_close(c)
		return true
	}
	// Already there is as good as made.
	c2, e2 := vfs.open_path(vfs.boot_namespace, path, vfs.O_RDONLY)
	if e2 == vfs.OK {
		vfs.chan_close(c2)
		return true
	}
	return false
}

// write_disk_file writes `content` to `path`, replacing what was there:
// a file persisted on the disk from a last boot is removed first, the way
// the servers overwrite, since kfs create does not truncate.
@(private = "file")
write_disk_file :: proc(path: string, content: string) -> bool {
	if old, oerr := vfs.open_path(vfs.boot_namespace, path, vfs.O_RDONLY); oerr == vfs.OK {
		_ = vfs.chan_remove(old)
		vfs.chan_close(old)
	}
	c, err := vfs.create_path(vfs.boot_namespace, path, vfs.O_WRONLY, 0o644)
	if err != vfs.OK {
		return false
	}
	defer vfs.chan_close(c)
	// In pieces a message carries: a file past one frame is several writes.
	at := 0
	for at < len(content) {
		piece := min(len(content) - at, 512, max(vfs.chan_iounit(c), 64))
		n, werr := vfs.chan_write(c, u64(at), transmute([]u8)content[at:at + piece])
		if werr != vfs.OK || n <= 0 {
			return false
		}
		at += n
	}
	return true
}

// web_read_file reads a whole small file into `into` and answers the count,
// or -1. Newlines at the end are trimmed unless `raw`, since a name file ends
// with one and a stored body is compared byte for byte.
web_read_file :: proc(path: string, into: []u8, raw := false) -> int {
	c, err := vfs.open_path(vfs.boot_namespace, path, vfs.O_RDONLY)
	if err != vfs.OK {
		return -1
	}
	defer vfs.chan_close(c)
	total := 0
	for total < len(into) {
		n, rerr := vfs.chan_read(c, u64(total), into[total:])
		if rerr != vfs.OK || n == 0 {
			break
		}
		total += int(n)
	}
	for !raw && total > 0 && (into[total - 1] == '\n' || into[total - 1] == '\r') {
		total -= 1
	}
	return total
}

// authorize_line answers the page a network's ctl says to approve on.
@(private = "file")
authorize_line :: proc(status: string, into: []u8) -> string {
	at := 0
	for at < len(status) {
		e := at
		for e < len(status) && status[e] != '\n' {
			e += 1
		}
		line := status[at:e]
		if libodin.has_prefix(line, "authorize ") {
			n := copy(into, line[len("authorize "):])
			return string(into[:n])
		}
		at = e + 1
	}
	return ""
}

// rpc_two asks a message file two questions on one open, the second
// after the first's answer, and answers both lengths.
@(private = "file")
rpc_two :: proc(path: string, q1: string, q2: string, into1: []u8, into2: []u8) -> (n1: int, n2: int) {
	c, err := vfs.open_path(vfs.boot_namespace, path, vfs.O_RDWR)
	if err != vfs.OK {
		return -1, -1
	}
	defer vfs.chan_close(c)
	if w, werr := vfs.chan_write(c, 0, transmute([]u8)q1); werr != vfs.OK || int(w) != len(q1) {
		return -1, -1
	}
	got, rerr := vfs.chan_read(c, 0, into1)
	if rerr != vfs.OK {
		return -1, -1
	}
	n1 = int(got)
	for n1 > 0 && (into1[n1 - 1] == '\n' || into1[n1 - 1] == '\r') {
		n1 -= 1
	}
	if w, werr := vfs.chan_write(c, 0, transmute([]u8)q2); werr != vfs.OK || int(w) != len(q2) {
		return n1, -1
	}
	got, rerr = vfs.chan_read(c, 0, into2)
	if rerr != vfs.OK {
		return n1, -1
	}
	n2 = int(got)
	for n2 > 0 && (into2[n2 - 1] == '\n' || into2[n2 - 1] == '\r') {
		n2 -= 1
	}
	return n1, n2
}

// libodin_cat joins strings into `buf`, the way libuser.cat_into does.
@(private = "file")
libodin_cat :: proc(buf: []u8, parts: ..string) -> string {
	sink := libodin.sink_from(buf)
	for part in parts {
		libodin.put_str(&sink, part)
	}
	return libodin.str(&sink)
}

/*
web_fetch drives one conversation of `/mnt/web`: a number off `clone`, the URL
into `ctl`, the body read to its end, then the hash. Answers the body's and the
hash's lengths (the hash with its newline), and whether every step held.
*/
@(private = "file") web_why: string

@(private = "file")
web_fetch :: proc(url: string, body: []u8, hash: []u8, ctl_extra: string = "", status: []u8 = nil, post: string = "") -> (bn: int, hn: int, ok: bool) {
	num: [16]u8
	n := web_read_file("/mnt/web/clone", num[:])
	if n <= 0 {
		web_why = "clone"
		return 0, 0, false
	}
	conv := string(num[:n])
	path: [128]u8
	line: [1100]u8
	if !net_file_write(libodin_cat(path[:], "/mnt/web/", conv, "/ctl"), libodin_cat(line[:], "url ", url)) {
		web_why = "ctl"
		return 0, 0, false
	}
	if ctl_extra != "" && !net_file_write(libodin_cat(path[:], "/mnt/web/", conv, "/ctl"), ctl_extra) {
		web_why = "ctl extra"
		return 0, 0, false
	}
	if post != "" {
		// A form's body: the method, its type, and the bytes before the fetch.
		if !net_file_write(libodin_cat(path[:], "/mnt/web/", conv, "/ctl"), "method POST") ||
		   !net_file_write(libodin_cat(path[:], "/mnt/web/", conv, "/ctl"), "header Content-Type: application/x-www-form-urlencoded") ||
		   !net_file_write(libodin_cat(path[:], "/mnt/web/", conv, "/postbody"), post) {
			web_why = "post"
			return 0, 0, false
		}
	}
	c, err := vfs.open_path(vfs.boot_namespace, libodin_cat(path[:], "/mnt/web/", conv, "/body"), vfs.O_RDONLY)
	if err != vfs.OK {
		web_why = "open body"
		return 0, 0, false
	}
	web_why = "read body"
	for bn < len(body) {
		got, rerr := vfs.chan_read(c, u64(bn), body[bn:])
		if rerr != vfs.OK {
			vfs.chan_close(c)
			return bn, 0, false
		}
		if got == 0 {
			break
		}
		bn += int(got)
	}
	vfs.chan_close(c)
	h, herr := vfs.open_path(vfs.boot_namespace, libodin_cat(path[:], "/mnt/web/", conv, "/hash"), vfs.O_RDONLY)
	if herr != vfs.OK {
		return bn, 0, false
	}
	got, rerr := vfs.chan_read(h, 0, hash)
	vfs.chan_close(h)
	if rerr != vfs.OK {
		return bn, 0, false
	}
	if status != nil {
		_ = web_read_file(libodin_cat(path[:], "/mnt/web/", conv, "/status"), status)
	}
	return bn, int(got), true
}


/*
verify_mothra opens the reader on a page, `docs/WEB.md` step 1: `mothra` on
`/lib/tests/page.gmi` opens a framed window on the toolkit, which the copper
title bar on the glass shows. The layout under it is `doctest`'s to prove.
*/
@(private = "file")
verify_mothra :: proc(r: ^Result) #no_bounds_check {
	s := devfs.raw_surface()
	if s == nil || s.pixels == nil || s.bytes_pp != 4 {
		return
	}
	count0 := srv.count()
	ps := start_draw_server(r, s, "the loader starts the draw server for the reader", "which posts /srv/draw for the reader to find", "and paints a desktop before the reader opens a window")
	if ps == nil {
		return
	}
	names := [?]string{"mothra", "/lib/tests/page.gmi"}
	argv := new(Argv)
	_ = argv_from(argv, names[:])
	pm := start_path(r, "/bin/mothra", "the loader starts the reader on a gemtext page", argv)
	if pm != nil {
		bx, _, _ := await_bar(s)
		check(r, bx >= 0, "and the reader opens a framed window on the page, its title bar copper")
		// The reader's io procs are processes of its note group, parked in
		// reads of the window's files. Ending the main process alone leaves
		// them standing, so the whole group is noted, the way `^C` is.
		_ = notepg_kernel(pm.note_group, "kill")
		check(r, end(pm, PATIENCE * 5), "and the reader, told to end, ends")
		finish(r, pm, "and is taken down")
		// The reader kept the page's links, both ways: the index is one
		// line a link, the page it was on and the page it names.
		idx: [4096]u8
		n := web_read_file("/usr/glenda/lib/web/links", idx[:], raw = true)
		got := string(idx[:max(n, 0)])
		check(r, n > 0 && libodin.contains(got, "/lib/tests/page.gmi gemini://geminiprotocol.net/\n") && libodin.contains(got, "/lib/tests/page.gmi /lib/tests/page.md\n"), "and the links index names the page and each page it links to, resolved")
	}

	// A picture on its own: the reader decodes a PNG and shows it fitted.
	inames := [?]string{"mothra", "/lib/tests/page.png"}
	iargv := new(Argv)
	_ = argv_from(iargv, inames[:])
	pi := start_path(r, "/bin/mothra", "the loader starts the reader on a picture", iargv)
	if pi != nil {
		bx, _, _ := await_bar(s)
		check(r, bx >= 0, "and the reader opens a framed window on the picture")
		// The picture is a gradient of red across and green down, blue held
		// at 128: its three corners are colours nothing else on the glass
		// wears, and all three landing is the upload path whole.
		corners := [3]fb.RGB{{0, 0, 128}, {255, 0, 128}, {0, 255, 128}}
		landed := false
		for _ in 0 ..< PATIENCE * 20 {
			landed = glass_has(s, corners[0]) && glass_has(s, corners[1]) && glass_has(s, corners[2])
			if landed {
				break
			}
			sync.delay(1)
		}
		check(r, landed, "and the picture's corner pixels reach the glass, decoded and loaded")
		_ = notepg_kernel(pi.note_group, "kill")
		check(r, end(pi, PATIENCE * 5), "and the reader, told to end, ends")
		finish(r, pi, "and is taken down")
	}

	// A picture on the page: a markdown page names the same PNG, the reader
	// fetches it and stands it on rows under its caption.
	mnames := [?]string{"mothra", "/lib/tests/page.md"}
	margv := new(Argv)
	_ = argv_from(margv, mnames[:])
	pd := start_path(r, "/bin/mothra", "the loader starts the reader on a page with a picture", margv)
	if pd != nil {
		bx, _, _ := await_bar(s)
		check(r, bx >= 0, "and the reader opens a framed window on the page")
		corners := [3]fb.RGB{{0, 0, 128}, {255, 0, 128}, {0, 255, 128}}
		landed := false
		for _ in 0 ..< PATIENCE * 20 {
			landed = glass_has(s, corners[0]) && glass_has(s, corners[1]) && glass_has(s, corners[2])
			if landed {
				break
			}
			sync.delay(1)
		}
		check(r, landed, "and the picture's corners reach the glass from its rows on the page")
		// The column, the window's right third: the gemtext page links
		// here, so it is this page's backlink, a link row in the link's ink.
		link := fb.RGB{0x38, 0xE0, 0xE8}
		by := 0
		bw := 0
		bx, by, bw = await_bar(s)
		in_column := false
		for _ in 0 ..< PATIENCE * 20 {
			in_column = bx >= 0 && glass_has_in(s, link, bx + bw * 2 / 3, bx + bw, by)
			if in_column {
				break
			}
			sync.delay(1)
		}
		check(r, in_column, "and the column beside the page shows the page that links here, read backwards from the index")
		_ = notepg_kernel(pd.note_group, "kill")
		check(r, end(pd, PATIENCE * 5), "and the reader, told to end, ends")
		finish(r, pd, "and is taken down")
	}

	stop_draw_server(r, ps, count0)
}

// stop_draw_server takes the draw server down the terminal's way. A remove
// of a window's ctl is the server's stop, and `/srv` is checked back to
// what it held before the server posted.
@(private = "file")
stop_draw_server :: proc(r: ^Result, ps: ^Process, count0: int) {
	if check(r, srv.mount(vfs.boot_namespace, "/srv/draw", "/mnt") == vfs.OK, "the kernel mounts the draw server to stop it") {
		if ctl, cerr := vfs.open_path(vfs.boot_namespace, "/mnt/0/ctl", vfs.O_RDONLY); cerr == vfs.OK {
			check(r, vfs.chan_remove(ctl) == vfs.OK, "a remove of a window's ctl is the server's stop")
			vfs.chan_close(ctl)
		}
		check(r, wait(ps, PATIENCE), "and the draw server exits")
		check(r, srv.remove("draw") == vfs.OK, "and the kernel takes the name away")
		check(r, srv.count() == count0, "and /srv holds what it held")
		finish(r, ps, "and the draw server is reaped")
		pipe.quiesce()
		check(r, vfs.unmount_path(vfs.boot_namespace, "", "/mnt") == vfs.OK, "and the mount of the dead server comes down")
	} else {
		finish(r, ps, "and the draw server is taken down")
	}
}

/*
verify_tools runs the shell on `/lib/tests/tools.rc`, which checks every
tool in `cmd/` once and says how many held.

The script starts `memfs`, mounts it, and works in it, so the tools that
make and remove files have somewhere to do it. Its lines land in the
serial log, one `ok name` per tool, and its exit word is `N ok` or
`failed` and the names. The count is a constant here, so a check added to
the script without a change here fails the boot, and says so.
*/
TOOLS_OK :: "38 ok"

verify_tools :: proc(r: ^Result) {
	names := [?]string{"rc", "/lib/tests/tools.rc"}
	said, ticks, ok := run_script(r, "/bin/rc", names[:], PATIENCE * 100, said_buf[:], "the shell starts on the tool script")
	r.tools_ticks = ticks
	if ok {
		sink := libodin.sink_from(tools_diag[:])
		if said == TOOLS_OK {
			libodin.put_str(&sink, "and every tool did what its line says")
		} else {
			libodin.put_str(&sink, "the tool script said `")
			libodin.put_str(&sink, said)
			libodin.put_str(&sink, "`")
		}
		check(r, said == TOOLS_OK, libodin.str(&sink))
	}
	// The detached memfs the script started ends when its name goes; collect
	// it now, so the balance checks after this do not see it.
	reap_orphans()
}

@(private = "file") tools_diag: [256]u8

/*
verify_dbg runs `tests/dbg.rc`: `docs/DEVTOOLS.md` section 7's script.
The shell starts `dbgfs`, mounts it, runs `debuggee` under it, and breaks
on a line by number. At two stops it reads the globals and the parameter,
and evaluates member and arithmetic expressions. It lists the disassembly
and the registers, and lets the program end. The word is `ok` or the
first check that did not hold.
*/
@(private = "file")
verify_dbg :: proc(r: ^Result) {
	names := [?]string{"rc", "/lib/tests/dbg.rc"}
	script_says(r, "/bin/rc", names[:], PATIENCE * 100, "the shell starts on the debugger script", "ok", "and the engine stopped, read, stepped and released the debuggee as the script says")
	reap_orphans()
}


/*
verify_interrupt types `^C` at a program parked reading the console.

`cat` with no arguments reads descriptor zero, which is `/dev/cons`, and
its read records its note group as the console's owner. A `^C` fed to the
keyboard then posts `interrupt` to that group, and `cat`, which has no
handler, ends noted with that word -- `docs/PROCS.md` step 3's last claim.
*/
@(private = "file")
verify_interrupt :: proc(r: ^Result) {
	argv := new(Argv)
	if !check(r, argv != nil, "a record for cat's arguments") {
		return
	}
	check(r, argv_from(argv, []string{"cat"}), "holds them")
	p := start_path(r, "/bin/cat", "cat starts, to read the console", argv)
	if p == nil {
		return
	}
	// Long enough to load off the disk and park in its first read.
	sync.delay(PATIENCE)
	typed := interrupts_typed
	devfs.keyboard_sink(0x03)
	if check(r, wait(p, PATIENCE), "a typed ^C ends it inside the bound") {
		check(r, p.exit.noted && note(p) == "interrupt", "noted `interrupt`, which is the word ^C posts")
		check(r, interrupts_typed == typed + 1, "and the console counted one interrupt")
	}
	finish(r, p, "and it is taken down")
}
