/*
Ring 3: running code the kernel does not trust, and getting back.

Everything before this milestone ran at the privilege the loader handed over.
The scheduler switched stacks, the address spaces switched page tables, and all
of it was one program with many threads. This is where that stops being true.

**A program is bytes. A process is what runs them.** That distinction is the
whole of this file's vocabulary and it took three milestones to earn:

    a program     an image, in `program.odin`, and nothing that runs
    a process     an address space, a namespace, and a set of open files

The order the three arrived in was deliberate, and each unblocked the next:

    ring 3        a thread can run somewhere it cannot damage the kernel
    a syscall     it can ask for something anyway
    a process     what it asks for belongs to it rather than to the kernel

## What makes this ring 3 rather than a jump

Three things, and each has a way of failing that looks like something else.

**The selectors in the frame.** `arch.thread_user_init` puts `USER_CODE_SEL|3`
in CS. The RPL is what turns the trap tail's `iretq` into a privilege change.
With RPL 0 the same `iretq` runs the same bytes at ring 0. Every test of a
program then still passes, except the ones about privilege.

**A stack the CPU can push onto.** A trap from ring 3 loads RSP from the TSS
before it pushes anything. `sched.reschedule` writes the incoming thread's own
kernel stack there. A stale value is not a fault. The report of the problem is
the push with nowhere to go, so it is a triple fault and a reset.

**Somewhere for the fault to go.** A program's fault is an ordinary event and
the kernel's is not. `arch.set_user_trap_handler` is a separate table for
exactly that reason, and `on_trap` below is what ends a program instead of the
machine.

## What a process owns

Segments, an address space, a namespace, and a table of open files.

The frames are the *segments'*, not the space's, because `mem.space_destroy`
frees page tables and never leaves. `segment.odin` is the owner that
division always pointed at, and the reference count there is what lets two
processes share one segment's frames.

**The namespace is a copy, and that is the point of having one.** `ns_fork`
with `.Copy` duplicates the mount table and shares the member chans. A process
can therefore rearrange its own view of the tree, and nothing else sees the
change. `kernel/vfs` was built for that four milestones before anything could
use it.

Descriptors 0, 1 and 2 come open on `/dev/cons`, which is the convention every
system with a shell keeps. Nothing reads 0 yet, and a read of it would park
until somebody types, which is the correct answer rather than a bug.

## What ends a process

`SYS_EXIT`, or a fault. Nothing else, and in particular not the kernel.
`destroy` refuses a process that is still running rather than free the tables
underneath it, because its thread is translating through them. Plan 9 ends a
process with a note. That is the missing piece by its proper name.
*/
package user

import "base:intrinsics"
import "base:runtime"

import "kernel:arch"
import "kernel:mem"
import "kernel:sched"
import "kernel:sync"
import "kernel:vfs"

/*
Where a program's three pages go.

Low, fixed, and the same for every program, which is what a space is for. Two
programs both start at `TEXT_VA` and neither can see the other's. The number is
an index into a table only one of them has.

The stack page sits below `STACK_TOP`, so the first push writes inside it.
`STACK_TOP` itself is the first address past the end, which is the convention
every stack pointer follows. That is also why it is 16-byte aligned rather than
a page boundary minus something.
*/
TEXT_VA :: uintptr(0x0040_0000)
DATA_VA :: uintptr(0x0040_1000)
STACK_TOP :: uintptr(0x7FFF_F000)
STACK_VA :: STACK_TOP - uintptr(arch.PAGE_SIZE)

/*
What a VECTRA02 program gets that a blob does not.

Four pages of stack rather than one, because compiled code spends stack the
way assembler never did -- a codec frame here, a message union there. And a
frame budget rather than a page. Sixty-four pages is a quarter megabyte,
which is five of today's `ramfs`, and it is a *format* bound. A program that
outgrows it asks this constant to move, visibly, rather than quietly taking
the machine.
*/
MAX_PROGRAM_FRAMES :: 64
STACK_PAGES2 :: 4
STACK_VA2 :: STACK_TOP - uintptr(STACK_PAGES2 * arch.PAGE_SIZE)

/*
How a program ended.

Filled in by `on_trap`, in interrupt context, on the thread that faulted.
`done` is stored last and volatile, because it is what the observer polls. A
reader that saw `done` set has therefore seen every field before it.

`kind` and `error_code` together are the whole answer to what a program did
wrong. A page fault at an address the kernel maps, and one at an address
nothing maps, are the same `kind` with different error codes. That difference
is exactly the thing this milestone is about.
*/
Exit :: struct {
	done:       bool,
	kind:       arch.Trap_Kind,
	vector:     u64,
	error_code: u64,
	has_error:  bool,
	ip:         uintptr,
	address:    uintptr, // CR2, and meaningful only for a page fault
	from_user:  bool,    // The trap was taken in ring 3 rather than in the kernel

	/*
	The program's own stack pointer at the moment of the fault, and the address
	the kernel's frame was built at.

	Two different address spaces in two fields, which is the point of keeping
	both. `sp` is a number in the program's space and means nothing in the
	kernel's. `kstack` is in the kernel's, and has to fall inside the faulting
	thread's own kernel stack. That is what the TSS said, and what the CPU used
	before anything in software could check it.
	*/
	sp:         uintptr,
	kstack:     uintptr,

	/*
	Whether the program asked to stop, and what it said on the way out.

	`deliberate` is the difference between the two ways out of ring 3 that
	exist. A fault fills `kind` and `error_code` and says what the CPU refused.
	`SYS_EXIT` fills `status` and says what the program chose. Both fill the
	fields above, because both have a frame to fill them from.
	*/
	deliberate: bool,
	status:     u64,

	// Whether a note is what ended it. Never true beside `deliberate`: a
	// noted process dies at a boundary it did not choose to cross that way.
	noted:      bool,
}

Process :: struct {
	name:   string,
	space:  ^mem.Address_Space,
	thread: ^sched.Thread,

	/*
	Who this process is, and who started it.

	`pid` is monotonic and never reused, for the same reason `kernel/srv`
	keeps an id rather than a slot. The table reuses slots, and a parent must
	not collect a stranger that moved in. `parent` is zero for a process the
	kernel built, which is what makes `wait` refuse to collect it from ring 3.
	*/
	pid:    u64,
	parent: u64,

	/*
	Whether this process is the kernel's to reap rather than a parent's to
	wait for. True for a child forked `RFNOWAIT`, and for one reparented
	when its own parent went. A detached process answers no `wait` -- its
	parent is zero -- and `reap_orphans` collects it once it ends. False for
	a kernel-launched test process, which the self-test destroys by name and
	the reaper must leave alone.
	*/
	detached: bool,

	// Which note group this process is in. Inherited on fork and spawn,
	// fresh under `RFNOTEG`. Nothing posts to a group yet. The field
	// arrives with `rfork` because the flag does. The fan-out of a note
	// to a whole group is the half of Plan 9's notify still missing --
	// the handler half exists now. See `docs/USER.md`.
	note_group: u64,

	// Where a spawned process's name lives. `load` is handed string literals
	// that live in the image. `spawn_path` is handed a path sitting on the
	// calling thread's syscall stack, which is gone when the call returns.
	name_buf: [PATH_MAX]u8,

	// The frames behind the three blob mappings, as *aliases*. Physical,
	// because `mem.phys_to_virt` needs them to read the data page back for
	// staging and marks. The segments below own the frames and free them;
	// these fields name three of the same frames and free nothing.
	text:   uintptr,
	data:   uintptr,
	stack:  uintptr,

	/*
	The segments behind every mapping, and the owners of every frame.

	A blob is three one-page segments. A compiled program is one per image
	row and a stack. `unload` releases each, and the last holder's release
	frees the frames. That rule is what lets `rfork` map one segment into
	two spaces without a second owner. See `segment.odin`.
	*/
	segs:      [MAX_PROC_SEGS]^Segment,
	seg_count: int,

	/*
	Where the next mapping this process asks for goes, bumped by its extent.

	A bump rather than a fixed address, because a process may ask twice and two
	mappings cannot share a page. It never comes back down: a process that
	attaches and releases leaks address space rather than risks handing the
	same numbers to a second card. Address space is the one resource a
	47-bit half has plenty of.

	**One bump for both kinds, and that is what makes them provably disjoint.**
	`segattach` takes a device and `segalloc` takes a run of anonymous memory.
	Two regions with two bumps would need an argument about which one grows
	into the other. One region has none to make.

	Zero until the first ask, which is what `MAPPING_BASE` means.
	*/
	map_next: uintptr,

	// The bounds of the thread's kernel stack, copied at load time. Copied
	// rather than read back through `thread`, because the next `spawn` frees a
	// dead thread's record and the answer is wanted after that.
	kstack_lo: uintptr,
	kstack_hi: uintptr,

	/*
	This process's own view of the tree.

	A copy rather than a reference, so `SYS_BIND` rearranges one process's
	namespace and no other. `ns_fork` shares the member chans underneath and
	counts references, which is what makes the copy cheap.
	*/
	ns:     ^vfs.Namespace,

	/*
	The open files, as a reference to a group.

	A reference rather than a field, because Plan 9's fork *shares* the
	descriptor group by default and `RFFDG` asks for a copy. The table, its
	lock, and the take/advance discipline live in `fdtable.odin`. The exit
	paths detach and release this in thread context. `unload` releases
	whatever is still attached.
	*/
	fdt:    ^Fd_Table,

	exit:   Exit,
	live:   bool,

	// Claimed by whichever collector reaches a dead process first. The
	// reaper, a fork that wants a slot, and a self-test that destroys by name
	// can all arrive at one record. `unload` run twice releases twice.
	// `destroy` takes this with a compare-and-swap, and `unload`'s final
	// zeroing of the record clears it with `live`.
	collecting: bool,

	// The note's text, posted before delivery and kept for whoever collects
	// the exit -- or reads it in a handler. A process with no handler still
	// only ever hears a note as an ending.
	note_buf: [NOTE_MAX]u8,
	note_len: int,

	/*
	The ring 3 note handler, and the state one delivery is in.

	`handler` is a user address `sys_notify` registered, zero for none.
	`notified` means a handler frame is on the user stack right now: no
	second delivery may start, and `sys_noted` is the only way forward.
	`note_sp` is where that frame sits, for `noted` to read back. Only the
	process's own thread touches all three -- at the door, at the tick that
	catches it, or in `sys_notify` -- so they need no lock. See
	`notify.odin`.
	*/
	handler:  uintptr,
	notified: bool,

	/*
	Whether the kernel decided this process ends at its next boundary,
	whatever handler it registered. Plan 9's `procctl` set to `Proc_exitme`,
	which `killproc` sets and `procctl()` answers with `pexit("Killed")`
	before any note is looked at. `end` sets it. The door and the tick read
	it before they read the note, which is what makes it unconditional.
	*/
	stopping: bool,
	note_sp:  uintptr,
}

// The longest note. Plan 9 says ERRMAX for the same field, and the number
// only has to hold a sentence.
NOTE_MAX :: 64

/*
One open file.

The chan is the namespace's answer to a path. The offset is the process's. It
is here rather than on the chan because two descriptors may name one file and
read it at different places. 9P has no cursor on the wire, because every
`Tread` carries an offset. Somebody above the protocol has to keep one, and
this is that somebody.
*/
Fd :: struct {
	chan:   ^vfs.Chan,
	offset: u64,
}

MAX_FDS :: 16

// The three a process starts with, on `/dev/cons`. The numbers are the
// convention rather than a requirement, and every program in `program.odin`
// writes to 1.
FD_STDIN :: 0
FD_STDOUT :: 1
FD_STDERR :: 2

/*
The programs, from a fixed table.

The same argument `mem.spaces` makes. A record a program can make the kernel
allocate is a record a program can exhaust the machine through. This is also
the first code in Vectra that anything untrusted will reach.
*/
MAX_PROCESSES :: 12

@(private)
processes: [MAX_PROCESSES]Process

@(private)
loaded: int
@(private = "file")
faults: int

// The next process id, never reused. Zero is the kernel, so the first process
// is 1. Monotonic and therefore finite, like a fid -- the same one fix
// retires all three counters. See `docs/HANDOFF.md`.
@(private)
next_pid: u64 = 1

// How many processes another process started, rather than the kernel. For
// the boot line, which should say the new thing plainly.
@(private)
spawned: int

Stats :: struct {
	live:    int, // Programs loaded and not destroyed
	loaded:  int, // Programs loaded since boot
	spawned: int, // Of those, started by another process rather than the kernel
	faults:  int, // Faults taken in ring 3
	calls:   int, // System calls answered
	traps:   u64, // Every return from ring 3 through a trap, preemptions included
}

stats :: proc "contextless" () -> Stats {
	live := 0
	for i in 0 ..< MAX_PROCESSES {
		if processes[i].live {
			live += 1
		}
	}
	return Stats {
		live = live,
		loaded = loaded,
		spawned = spawned,
		faults = faults,
		calls = syscall_count(),
		traps = arch.user_trap_count(),
	}
}

/*
init claims the fault path for programs.

Two lines, and the first separates `a fault ends the machine` from `a fault
ends the program`. Until it runs, a trap from ring 3 falls through to
`kernel/panic.odin` and stops the boot. That is the right default for a
privilege level nothing owns yet.

The second arms `syscall` and opens the console behind descriptor 1. It reports
false when the CPU has no such instruction, which no amd64 part does, and the
caller says so rather than halts. Programs then have exactly one way out of
ring 3 again, which is the fault. See `syscall.odin`.
*/
init :: proc(ns: ^vfs.Namespace) -> bool {
	arch.set_user_trap_handler(on_trap)
	sched.set_note_trap(note_trap)
	// The collector before the door opens, so no process can end without one
	// running. See `hangup_dead`.
	if !reaper_start() {
		return false
	}
	return syscall_init(ns)
}

/*
on_trap ends the program the fault came from, and says why.

Runs in interrupt context, on the faulting thread's kernel stack, with
interrupts already off. It therefore allocates nothing, takes no lock and logs
nothing. The report is written into the program's own record and read by
whoever was waiting, in thread context, where a console is safe to touch.

Finding the program is one load: the scheduler carries the record on the thread
and never looks at it. A table searched by thread pointer would be the same
answer with a loop in a fault handler.

The return value is another thread's state, which is what ends this one. A
handler that returned what it was given would `iretq` back to the faulting
instruction. It would then take the same fault for ever, which is a hang rather
than a failed check.
*/
@(private = "file")
on_trap :: proc "contextless" (t: ^arch.Trap, r: arch.Resume) -> arch.Resume {
	faults += 1

	if thread := sched.current(); thread != nil {
		if p := (^Process)(thread.user); p != nil {
			p.exit.kind = t.kind
			p.exit.vector = t.vector
			p.exit.error_code = t.error_code
			p.exit.has_error = t.has_error
			p.exit.ip = t.ip
			p.exit.address = t.fault_address
			p.exit.from_user = t.user
			p.exit.sp = t.sp
			p.exit.kstack = uintptr(rawptr(t.frame))
			// Last, and volatile: it is what the observer polls, and everything
			// above it has to be visible to a reader that sees it set.
			intrinsics.volatile_store(&p.exit.done, true)
		}
	}

	// Interrupts are already off, and `wakeup_all` masks rather than enables,
	// so a woken waiter cannot run before this thread leaves the core.
	sync.wakeup_all(&exit_rendez)
	return sched.kill_current(r)
}

/*
Where everything that ends a process reports it, and where collectors wait.

One rendezvous rather than one per process, because an exit is rare and a
scan per wake is nothing. The condition is the child's own `exit.done`, so a
wake for somebody else's child is a loop iteration rather than a wrong
answer. This is what let `wait` stop polling: a parked parent costs the
machine nothing until an ending wakes it.
*/
@(private)
exit_rendez: sync.Rendez

@(private)
exit_done :: proc "contextless" (arg: rawptr) -> bool {
	return intrinsics.volatile_load(&(^Process)(arg).exit.done)
}

/*
post_note delivers an ending to a process, from outside it.

The note is a flag on the thread and a line of text on the process. What
makes it an *ending* is the boundaries: the next system call the thread
enters, or the next tick that catches it in ring 3. `sched.note_thread`
readies a parked thread, so an interruptible sleep unwinds toward one of
those. Delivery is not instant, and this does not wait for it. A caller that
wants the corpse waits on the exit and then destroys. That is `wait_pid`'s
arc for parents, and the kernel's for itself.

Refused on a process that already ended. The note would outlive its target
and kill whatever reuses the thread, which is the aliasing every id in this
tree exists to prevent.
*/
post_note :: proc "contextless" (p: ^Process, text: string) -> bool {
	if p == nil || !p.live || p.thread == nil {
		return false
	}
	if intrinsics.volatile_load(&p.exit.done) {
		return false
	}

	n := min(len(text), NOTE_MAX)
	for i in 0 ..< n {
		p.note_buf[i] = text[i]
	}
	p.note_len = n

	sched.note_thread(p.thread)
	return true
}

/*
end stops a process from outside, and waits for it to be gone.

**This is the kill the kernel did not have.** A note is a request a handler
may decline, and `destroy` refuses a process whose thread still translates
through the space. So a process that caught every note and never exited was
the kernel's to keep for ever. `docs/HANDOFF.md` carried it as the honest
leak for four milestones.

Plan 9's `killproc` is the shape. It sets `procctl` to `Proc_exitme` and
pushes a "sys: killed" note beside it. The note is what wakes a parked
process and what the exit record carries. The word is what makes the ending
unconditional. `procctl()` runs before `notify` looks at any note or any
handler, and answers `pexit("Killed")`.

Here `stopping` is the word and `sched.note_thread` is the wake. The door
and the tick both read the word before the handler. So a process ends at its
next boundary whether or not it registered one, and whether or not a
delivery is in flight.

The wait is bounded, the way every wait in this tree is. A process that
reaches no boundary inside `patience` ticks is still running when this
returns false, and is still the caller's to leave alone. Nothing here can
end a thread that never crosses back into the kernel, and a tick is a
boundary, so nothing runs that long.

True means the process ended, noted, and its record is still there for the
caller to read. `stop` is this and the collection.
*/
end :: proc(p: ^Process, patience: int) -> bool {
	if p == nil || !p.live || p.thread == nil {
		return false
	}
	if intrinsics.volatile_load(&p.exit.done) {
		return true
	}
	text := "sys: killed"
	for i in 0 ..< len(text) {
		p.note_buf[i] = text[i]
	}
	p.note_len = len(text)
	intrinsics.volatile_store(&p.stopping, true)
	sched.note_thread(p.thread)
	return wait(p, patience)
}

// stop is `end` and the collection, which is the whole arc `wait_pid` walks
// for a parent, walked by the kernel for itself.
stop :: proc(p: ^Process, patience: int) -> bool {
	if !end(p, patience) {
		return false
	}
	return destroy(p)
}

// note reports the text an ending carried, empty when nothing was posted.
note :: proc "contextless" (p: ^Process) -> string {
	if p == nil {
		return ""
	}
	return string(p.note_buf[:p.note_len])
}

/*
note_trap is the tick's half of delivery: a noted thread caught in ring 3.

Interrupt context, exactly like `on_trap`, and the same rules -- no lock, no
log, no allocation. `deliver_note` keeps them. It walks page tables and
writes user memory through mappings that are live right now, because the
tick caught this very thread running.

Three ways out. A handler mid-delivery holds the note and resumes, and the
next boundary after `noted` finishes takes it. A registered handler gets
the frame the tick interrupted, redirected. And a process with no handler,
or no stack a frame fits on, ends here. The record says a note did it, and
the descriptors stay open until `destroy` closes them, which is the fault
path's arrangement too.
*/
@(private = "file")
note_trap :: proc "contextless" (r: arch.Resume) -> arch.Resume {
	thread := sched.current()
	if thread != nil {
		// The kernel's word first, before any handler. See `end`.
		if p := (^Process)(thread.user); p != nil && p.handler != 0 && !intrinsics.volatile_load(&p.stopping) {
			if p.notified {
				// One delivery at a time. The note waits, flagged, for the
				// boundary after the handler's own `noted`.
				return r
			}
			if deliver_note(p, r.frame) {
				sched.clear_note(thread)
				return r
			}
		}
	}

	if thread != nil {
		if p := (^Process)(thread.user); p != nil {
			p.exit.ip = uintptr(r.frame.rip)
			p.exit.sp = uintptr(r.frame.rsp)
			p.exit.kstack = uintptr(rawptr(r.frame))
			p.exit.from_user = true
			p.exit.noted = true
			intrinsics.volatile_store(&p.exit.done, true)
		}
	}
	sync.wakeup_all(&exit_rendez)
	return sched.kill_current(r)
}

/*
load builds a space, puts a program in it, and starts a thread on it.

Three mappings, and the flags on each are the whole of what a program may do:

    text    read and execute, and **not write**
    data    read and write, and not execute
    stack   read and write, and not execute

Every one of those is a fault the self-test provokes on purpose, because a
permission nothing tests is a permission that may not be there. `mem.map_user`
adds `User` to all three, which is the bit that lets ring 3 reach them at all.

`arg` and `arg2` are the program's second and third arguments. The blobs take
an address to touch, or a length to use. Which address a blob receives is what
makes one run a test of the kernel half and another a test of a read-only page.

**The namespace is forked here rather than shared**, and the descriptors are
opened through the fork rather than through the kernel's. A caller that
rearranges the fork before this returns therefore changes what descriptor 1
means, which is the whole demonstration in `verify_namespaces`.
*/
load :: proc(name: string, code: []u8, arg: u64 = 0, arg2: u64 = 0) -> (^Process, mem.Error) {
	p, err := load_held(name, code)
	if err != .None {
		return nil, err
	}
	if !launch(p, arg, arg2) {
		unload(p)
		return nil, .Out_Of_Memory
	}
	return p, .None
}

// load_held is `load` up to the brink: space, namespace, pages, descriptors,
// and no thread. What a caller stages into the data page before `launch` is
// the program's from its first instruction.
load_held :: proc(name: string, code: []u8) -> (^Process, mem.Error) {
	if len(code) == 0 || len(code) > arch.PAGE_SIZE {
		return nil, .Not_Canonical
	}

	p := free_slot()
	if p == nil {
		return nil, .Out_Of_Memory
	}

	space, err := mem.space_new()
	if err != .None {
		return nil, err
	}
	p^ = Process {
		name       = name,
		space      = space,
		live       = true,
		pid        = next_pid,
		note_group = next_pid,
	}
	next_pid += 1

	p.ns = vfs.ns_fork(vfs.boot_namespace, {.Copy})
	if p.ns == nil {
		unload(p)
		return nil, .Out_Of_Memory
	}
	if p.fdt = fdt_new(); p.fdt == nil {
		unload(p)
		return nil, .Out_Of_Memory
	}

	if p.text = segment_one_page(p, TEXT_VA, {}, .Text); p.text == 0 {
		unload(p)
		return nil, .Out_Of_Memory
	}
	if p.data = segment_one_page(p, DATA_VA, {.Write, .No_Execute}, .Data); p.data == 0 {
		unload(p)
		return nil, .Out_Of_Memory
	}
	if p.stack = segment_one_page(p, STACK_VA, {.Write, .No_Execute}, .Stack); p.stack == 0 {
		unload(p)
		return nil, .Out_Of_Memory
	}

	// The copy the file comment in `program.odin` argues for. No `User` bit
	// sits anywhere on the path to the kernel image. A program could not
	// execute those bytes where they lie, whatever the source was. Mapped
	// already, but there is no thread yet, so there is no race to lose.
	dst := (cast([^]u8)mem.phys_to_virt(p.text))[:arch.PAGE_SIZE]
	for i in 0 ..< len(code) {
		dst[i] = code[i]
	}

	// Before the thread, not after. A program's first instruction may be a
	// write to descriptor 1. The next interrupt can dispatch any thread that
	// is already on a run queue.
	open_standard(p)
	return p, .None
}

/*
launch puts a thread on a held program, which is the moment it can run.

Split from `load_held` for one reason, found as a one-in-twenty flake. A
caller that stages bytes into the data page *after* the thread exists races
the program for its own memory. The next interrupt can dispatch the new
thread, and a program whose first message is half-staged prints the staged
half and zeroes for the rest. Staging before `launch` is not a convention to
remember. There is no thread yet, so there is no race to lose.

The thread gets `p` before it can run, because the fault handler reads it
and the first fault may arrive on the very next interrupt.
*/
launch :: proc(p: ^Process, arg: u64 = 0, arg2: u64 = 0) -> bool {
	if p == nil || p.thread != nil {
		return false
	}
	p.thread = sched.spawn_user(p.name, p.space, TEXT_VA, STACK_TOP, u64(DATA_VA), arg, arg2, p)
	if p.thread == nil {
		return false
	}
	p.kstack_lo = uintptr(raw_data(p.thread.stack))
	p.kstack_hi = p.thread.kstack_top
	loaded += 1
	return p.thread != nil
}

/*
wait polls for a program to end, up to a bound in ticks.

Polling rather than parking. What this waits for is a fault in interrupt
context, and nothing there may take a lock or wake a sleeper. A rendezvous
becomes the right answer the moment a program can exit deliberately. Until then
the only event is a trap, and a trap is the worst place to grow a dependency.

Returns false when the bound runs out, which is a program that did not end. The
caller has to treat that as the failure it is: `destroy` will refuse it, and
its space and frames stay out of circulation.
*/
wait :: proc "contextless" (p: ^Process, patience: int) -> bool {
	if p == nil {
		return false
	}
	return sync.sleep_for(&exit_rendez, exit_done, p, u64(patience))
}

/*
blocked reports how many times a program's thread was woken.

A thread that never parked has none. A system call that parks is therefore
visible from outside as a number, rather than inferred from how long the
program took.

**Valid only until the next `load`.** A dead thread's record is still allocated
until something reaps it, and `spawn` is what reaps. `destroy` clears the
pointer, which is why this reads zero afterwards rather than reads freed
memory.
*/
blocked :: proc "contextless" (p: ^Process) -> u64 {
	if p == nil || p.thread == nil {
		return 0
	}
	return p.thread.wakeups
}

// ended reports whether a program already faulted, without waiting.
ended :: proc "contextless" (p: ^Process) -> bool {
	return p != nil && intrinsics.volatile_load(&p.exit.done)
}

/*
cell reads one eight-byte word of a program's data page, from the kernel side.

Through the direct map, not through the program's space. The kernel is not
translating through those tables and must not have to be. That is also what
makes the page shared in the honest sense: the same frame, two mappings, two
privilege levels, and neither one a copy.
*/
cell :: proc "contextless" (p: ^Process, index: int) -> u64 {
	if p == nil || p.data == 0 || index < 0 || index >= arch.PAGE_SIZE / size_of(u64) {
		return 0
	}
	words := cast([^]u64)mem.phys_to_virt(p.data)
	return intrinsics.volatile_load(&words[index])
}

// set_cell writes one word of a program's data page. The other direction of
// `cell`, and what tells `spin` to stop.
set_cell :: proc "contextless" (p: ^Process, index: int, value: u64) {
	if p == nil || p.data == 0 || index < 0 || index >= arch.PAGE_SIZE / size_of(u64) {
		return
	}
	words := cast([^]u64)mem.phys_to_virt(p.data)
	intrinsics.volatile_store(&words[index], value)
}

/*
destroy gives back a program's space and its three frames.

Refuses a program that did not end. The space is the tree the machine would
translate through if its thread ran again. The frames are pages that thread may
still write to. There is no way to stop it, so the only safe answer is to keep
them.

That refusal is a leak, and it is the honest kind: it is visible in
`stats().live` and in the frame count, rather than absorbed. See the file
comment.
*/
destroy :: proc(p: ^Process) -> bool {
	if p == nil {
		return false
	}
	return collect(p, p.pid)
}

/*
collect is `destroy` for a collector that saw the record a moment ago, and
names the process it saw.

**A slot is not an identity, and a pid is.** The reaper, a fork that wants a
slot, and a parent's `wait` each read a record, decide it is dead, and reach
for it. A tick between the two lets the slot be freed and reborn. The claim
below then lands on a process the caller never looked at, a newborn whose
thread has not run. It passes the "ended" test for the wrong reason. The
compare-and-swap on `collecting` closes the double release on one record and
says nothing about two records in one slot.

The pid is the generation. It is monotonic and never reused, which is what
`kernel/srv` keeps an id for and `wait` already leans on. So the claim is
taken and then the pid is read again, and a claim on a slot that changed
tenants is given back untouched. The loser answers false, which is the answer
it would get from a record that was already gone.
*/
collect :: proc(p: ^Process, pid: u64) -> bool {
	if p == nil || !p.live || p.pid != pid {
		return false
	}
	if p.thread != nil && !intrinsics.volatile_load(&p.exit.done) {
		return false
	}
	// One collector. The reaper takes a detached process the moment it ends,
	// and a fork or a self-test may reach for the same record a tick later.
	if _, won := intrinsics.atomic_compare_exchange_strong(&p.collecting, false, true); !won {
		return false
	}
	if p.pid != pid {
		// Reborn between the check and the claim. The claim is the newborn's
		// now, and it goes back before anything else is touched.
		intrinsics.volatile_store(&p.collecting, false)
		return false
	}
	unload(p)
	return true
}

/*
set_bytes copies into a program's data page from the kernel side.

The other direction of `copy_in` in `syscall.odin`, and much the easier one.
The kernel owns the frame, reaches it through the direct map, and is not
guessing about what is mapped where. That asymmetry is the whole reason a
kernel has a `copy_in` and does not have a `copy_out` that checks anything.
*/
set_bytes :: proc "contextless" (p: ^Process, offset: int, data: []u8) -> bool {
	if p == nil || p.data == 0 || offset < 0 {
		return false
	}
	if offset + len(data) > arch.PAGE_SIZE {
		return false
	}
	dst := (cast([^]u8)mem.phys_to_virt(p.data))[:arch.PAGE_SIZE]
	for i in 0 ..< len(data) {
		dst[offset + i] = data[i]
	}
	return true
}

/*
reparent_children detaches every live child of a process about to go.

A child's `parent` is a pid, and a pid never reuses. Once the parent's slot
is gone, the child names a parent that will never call `wait`. It dangles
uncollectable then, the honest leak the handoff named beside `RFNOWAIT`. So
the teardown hands its children to the kernel: `parent` zero, `detached` set,
and `reap_orphans` collects each when it ends. This is Plan 9's
reparent-to-init with the kernel standing in for init.

Runs before the record is zeroed, off `p.pid`. A process the kernel built
has a zero parent already, so its children are no one else's to wait for.
*/
@(private = "file")
reparent_children :: proc "contextless" (dying_pid: u64) #no_bounds_check {
	if dying_pid == 0 {
		return
	}
	for i in 0 ..< MAX_PROCESSES {
		c := &processes[i]
		if c.live && c.parent == dying_pid {
			c.parent = 0
			c.detached = true
		}
	}
}

/*
reap_orphans collects every detached process that ended, and reports how
many.

The counterpart to `wait_pid` for a process no parent will wait for. A
detached process is the kernel's, so the kernel gives its record back. But
only once its thread is gone, which `exit.done` reports and `destroy`
re-checks. A detached process still running is left for a later pass.

Called from the reaper at every ending now, and still where a slot is wanted
and where a count is about to be believed. The reaper is what makes a
detached process go back on its own. The other callers make it go back
*before* a decision that depends on it. The reaper is a thread, and a thread
runs when the scheduler gets to it. A self-test that wants to
look at a detached process has to hold it alive to do so, and `verify_reap`
does.
*/
/*
hangup_dead gives back the descriptors of every process whose thread has gone,
and reports how many tables it released.

**This is the hangup a faulting server never performed.** `sys_exit` releases
the descriptor group before it publishes the exit record, so a process that
ends deliberately hangs up its pipes on the way out. `on_trap` cannot: it is a
trap handler with interrupts off, and `fdt_release` closes chans, and a clunk
is a message that may park. So a process that *faulted* kept its descriptors
until something called `destroy`, and `destroy` ran only from `spawn_path`.

The consequence was not a leak but a **hang**. A ring 3 server that faults
mid-request never hangs up its pipe, so the client parked on it waits for a
reply from a process that no longer exists. `docs/TESTING.md` names a hang as
the worst way for a check to report, and this is the one gap in the tree that
turns a failed check into one.

**The record stays for a parent.** Only the descriptors go here, which is
Plan 9's `pexit` closing the file group while the proc record waits for its
parent. A parent parked in `wait` still gets its child's exit status. A
record nobody will wait for is a different case, and the reaper collects it
whole through `reap_orphans` one call later -- see the thread below.

The exchange is atomic because three paths race for the same pointer -- this
one, `sys_exit` on another thread, and `unload` from a collector. Whoever wins
releases, and the losers find nil. That is the "one release per holder,
whichever paths ran" rule `unload` already states, made true rather than
argued.
*/
hangup_dead :: proc() -> (released: int) #no_bounds_check {
	for i in 0 ..< MAX_PROCESSES {
		p := &processes[i]
		pid := p.pid
		if !p.live || !intrinsics.volatile_load(&p.exit.done) {
			continue
		}
		if t := intrinsics.atomic_exchange(&p.fdt, nil); t != nil {
			if p.pid != pid {
				// The slot changed tenants between the check and the
				// exchange, and the table taken is a newborn's. It goes
				// straight back. On one core nothing ran between the two
				// exchanges, so the newborn never saw its table gone. The
				// day a second core makes that window real, this is the
				// line that has to become a lock. See `collect`.
				intrinsics.atomic_store(&p.fdt, t)
				continue
			}
			fdt_release(t)
			released += 1
		}
	}
	return released
}

// dead_needs_collecting is the reaper's wake condition. Some process ended
// and still holds a descriptor group, or is nobody's and still holds a
// record.
@(private = "file")
dead_needs_collecting :: proc "contextless" (arg: rawptr) -> bool #no_bounds_check {
	for i in 0 ..< MAX_PROCESSES {
		p := &processes[i]
		if p.live && intrinsics.volatile_load(&p.exit.done) && (p.fdt != nil || p.detached) {
			return true
		}
	}
	return false
}

/*
The reaper thread, which is what makes the release above happen without
anybody asking, and takes a detached process's record back the same way.

It parks on `exit_rendez`, the rendezvous every ending already wakes -- the
deliberate exit, the note, and the fault. So the trigger costs nothing and no
death path grew a line.

**A detached process goes whole, and the moment it ends.** It used to wait
for the next fork, because `reap_orphans` ran only where a slot was wanted.
That left every count a dead process still held standing until then. A
concurrent server's worker, forked `RFNOWAIT` per parked request, kept its
segments after it answered and exited. `segbrk` counted three dead ones as
sharers of every window run. The general shape of that fix is this thread.

A process nobody will wait for is the kernel's, and the kernel collects it
when it ends, which is init reaping on Plan 9. A process a parent may still
`wait` for keeps its record, as before.

The deadline is a backstop rather than a schedule. Every ending wakes this,
and a wake that finds nothing goes straight back to sleep, so the timeout only
matters if a wake were ever missed.
*/
REAP_PATIENCE :: 50

@(private = "file")
reaper :: proc "contextless" (arg: rawptr) {
	// A clunk crossing to a ring 3 server runs a codec on this stack, and a
	// codec may allocate. `kernel/mnt`'s worker takes a context for the same
	// reason and in the same words.
	ctx := runtime.default_context()
	ctx.allocator = mem.allocator()
	context = ctx

	for {
		_ = sync.sleep_for(&exit_rendez, dead_needs_collecting, nil, REAP_PATIENCE)
		hangup_dead()
		reap_orphans()
	}
}

// reaper_start puts the collector on the scheduler. Called once, from init.
reaper_start :: proc() -> bool {
	return sched.spawn("reaper", reaper) != nil
}

reap_orphans :: proc() -> (collected: int) #no_bounds_check {
	for i in 0 ..< MAX_PROCESSES {
		p := &processes[i]
		pid := p.pid
		if p.live && p.detached && intrinsics.volatile_load(&p.exit.done) {
			if collect(p, pid) {
				collected += 1
			}
		}
	}
	return collected
}

@(private)
unload :: proc(p: ^Process) {
	// Children first, before the pid this reparenting keys on is zeroed. A
	// process that outlives its parent becomes the kernel's to reap rather
	// than a dangling pointer to a pid nobody holds. See `reparent_children`.
	reparent_children(p.pid)

	// The descriptors first, and the namespace after them. A chan holds a
	// reference to the server it came from, and the mount table holds
	// references to the chans it was built out of. The order is deliberate.
	// Closing the namespace first would leave every open file pointing into a
	// mount table with one reference left and no way to reach it. A process
	// that exited deliberately already detached its table, and this release
	// finds nothing -- one release per holder, whichever paths ran.
	//
	// Taken with an exchange, not a test, because the reaper thread takes it
	// the same way and the two race for real. A process that faulted or was
	// noted still holds its table when its ending wakes both this collector
	// and the reaper. The reaper usually gets there first. When it does not,
	// a test-then-release here left the pointer standing for as long as the
	// closes took, and the reaper found it and released the table a second
	// time. The first release had already given the pool slot back, so the
	// second closed whichever process had been handed that slot since --
	// three chans out from under a live process, and a namespace mount point
	// whose count never came back to zero. It showed up as one 64-byte
	// object leaked, one boot in twenty or so, first in the draw server's
	// teardown and then wherever timing put it.
	if t := intrinsics.atomic_exchange(&p.fdt, nil); t != nil {
		fdt_release(t)
	}
	if p.ns != nil {
		vfs.ns_close(p.ns)
	}
	if p.space != nil {
		mem.space_destroy(p.space)
	}
	// Segments after the space, deliberately. The tables come down first, so
	// there is no window where a still-standing table entry names a frame the
	// release already recycled. The frames themselves outlive this process
	// whenever another still holds the segment.
	for i in 0 ..< p.seg_count {
		segment_release(p.segs[i])
	}
	p^ = Process{}
}

@(private)
free_slot :: proc "contextless" () -> ^Process #no_bounds_check {
	for i in 0 ..< MAX_PROCESSES {
		if !processes[i].live {
			return &processes[i]
		}
	}
	return nil
}

// -- Descriptors -------------------------------------------------------------
//
// The table itself, its pool, and every per-descriptor operation live in
// `fdtable.odin`. What stays here is the one procedure that knows which
// files a process is *born* holding.

/*
open_standard gives a new process the three descriptors a program expects.

All three on `/dev/cons`, through **this process's** namespace rather than the
kernel's. That distinction is inert today, because the fork is a faithful copy
at the moment it is made. It stops being inert the first time somebody
rearranges the fork before the process starts.

A failure here is not fatal to the process. A program that writes to a
descriptor it does not have gets `EBADF`, which is a better answer than a
process that could not start.
*/
@(private)
open_standard :: proc(p: ^Process) {
	if p == nil || p.ns == nil {
		return
	}
	modes := [3]u32{vfs.O_RDONLY, vfs.O_WRONLY, vfs.O_WRONLY}
	for mode in modes {
		c, err := vfs.open_path(p.ns, "/dev/cons", mode)
		if err != vfs.OK {
			return
		}
		if _, ok := fd_open(p, c); !ok {
			vfs.chan_close(c)
			return
		}
	}
}
