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

Three frames, an address space, a namespace, and a table of open files.

The frames are this package's, not the space's, because `mem.space_destroy`
frees page tables and never leaves. See the file comment in
`kernel/mem/space.odin` for why that division is there and what would change
it.

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

	// Where a spawned process's name lives. `load` is handed string literals
	// that live in the image. `spawn_path` is handed a path sitting on the
	// calling thread's syscall stack, which is gone when the call returns.
	name_buf: [PATH_MAX]u8,

	// The frames behind the three mappings. Physical, because that is what
	// this package has to free and what `mem.phys_to_virt` needs to read the
	// data page back.
	text:   uintptr,
	data:   uintptr,
	stack:  uintptr,

	/*
	The frames behind a VECTRA02 program, segments first and stack last.

	A blob is three pages with three names, and the fields above are those. A
	compiled program is however many pages its segments say. This table is the
	loader's receipt for them: everything `unload` must give back that has no
	name of its own. Fixed, because a bound the image format enforces is a
	bound this record can afford to carry.
	*/
	frames:      [MAX_PROGRAM_FRAMES]uintptr,
	frame_count: int,

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
	The open files, indexed by the number a program holds.

	A fixed table, and small. The argument is the one `MAX_PROCESSES` makes
	below and `srv.MAX_SERVICES` made before it. A descriptor is the first
	kernel object a program can name and get a handle back for. It is therefore
	the first one a program could ask for until the machine stopped.
	*/
	fds:    [MAX_FDS]Fd,

	exit:   Exit,
	live:   bool,
}

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
		name  = name,
		space = space,
		live  = true,
		pid   = next_pid,
	}
	next_pid += 1

	p.ns = vfs.ns_fork(vfs.boot_namespace, {.Copy})
	if p.ns == nil {
		unload(p)
		return nil, .Out_Of_Memory
	}

	ok: bool
	if p.text, ok = mem.alloc_page_zeroed(); !ok {
		unload(p)
		return nil, .Out_Of_Memory
	}
	if p.data, ok = mem.alloc_page_zeroed(); !ok {
		unload(p)
		return nil, .Out_Of_Memory
	}
	if p.stack, ok = mem.alloc_page_zeroed(); !ok {
		unload(p)
		return nil, .Out_Of_Memory
	}

	// The copy the file comment in `program.odin` argues for. No `User` bit
	// sits anywhere on the path to the kernel image. A program could not
	// execute those bytes where they lie, whatever the source was.
	dst := (cast([^]u8)mem.phys_to_virt(p.text))[:arch.PAGE_SIZE]
	for i in 0 ..< len(code) {
		dst[i] = code[i]
	}

	if e := mem.map_user(space, TEXT_VA, p.text, {}, 1); e != .None {
		unload(p)
		return nil, e
	}
	if e := mem.map_user(space, DATA_VA, p.data, {.Write, .No_Execute}, 1); e != .None {
		unload(p)
		return nil, e
	}
	if e := mem.map_user(space, STACK_VA, p.stack, {.Write, .No_Execute}, 1); e != .None {
		unload(p)
		return nil, e
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
	for _ in 0 ..< patience {
		if intrinsics.volatile_load(&p.exit.done) {
			return true
		}
		sync.delay(1)
	}
	return intrinsics.volatile_load(&p.exit.done)
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
	if p == nil || !p.live {
		return false
	}
	if p.thread != nil && !intrinsics.volatile_load(&p.exit.done) {
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

@(private)
unload :: proc(p: ^Process) {
	// The descriptors first, and the namespace after them. A chan holds a
	// reference to the server it came from, and the mount table holds
	// references to the chans it was built out of. The order is deliberate.
	// Closing the namespace first would leave every open file pointing into a
	// mount table with one reference left and no way to reach it.
	for i in 0 ..< MAX_FDS {
		if p.fds[i].chan != nil {
			vfs.chan_close(p.fds[i].chan)
			p.fds[i] = Fd{}
		}
	}
	if p.ns != nil {
		vfs.ns_close(p.ns)
	}
	if p.space != nil {
		mem.space_destroy(p.space)
	}
	if p.text != 0 {
		mem.free_page(p.text)
	}
	if p.data != 0 {
		mem.free_page(p.data)
	}
	if p.stack != 0 {
		mem.free_page(p.stack)
	}
	for i in 0 ..< p.frame_count {
		mem.free_page(p.frames[i])
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

/*
fd_open puts a chan in the lowest free slot and reports the number.

Lowest free, which is the rule every system with a shell depends on. A program
that closes descriptor 1 and opens a file gets descriptor 1 back. That is how
output goes to a file with no call for it.

The chan's reference belongs to the table from here on. `fd_close` gives it
back, and `unload` gives back whatever is left.
*/
@(private)
fd_open :: proc(p: ^Process, c: ^vfs.Chan) -> (int, bool) #no_bounds_check {
	if p == nil || c == nil {
		return 0, false
	}
	for i in 0 ..< MAX_FDS {
		if p.fds[i].chan == nil {
			p.fds[i] = Fd{chan = c}
			return i, true
		}
	}
	return 0, false
}

@(private)
fd_at :: proc "contextless" (p: ^Process, fd: int) -> ^Fd #no_bounds_check {
	if p == nil || fd < 0 || fd >= MAX_FDS || p.fds[fd].chan == nil {
		return nil
	}
	return &p.fds[fd]
}

@(private)
fd_close :: proc(p: ^Process, fd: int) -> bool #no_bounds_check {
	f := fd_at(p, fd)
	if f == nil {
		return false
	}
	vfs.chan_close(f.chan)
	f^ = Fd{}
	return true
}

// fd_count reports how many descriptors a process holds, for a self-test that
// wants to say a close really closed one.
fd_count :: proc "contextless" (p: ^Process) -> int #no_bounds_check {
	n := 0
	if p == nil {
		return 0
	}
	for i in 0 ..< MAX_FDS {
		if p.fds[i].chan != nil {
			n += 1
		}
	}
	return n
}

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
