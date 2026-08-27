/*
Ring 3: running code the kernel does not trust, and getting back.

Everything before this milestone ran at the privilege the loader handed over.
The scheduler switched stacks, the address spaces switched page tables, and all
of it was one program with many threads. This is where that stops being true.

A program is three mapped pages and a thread whose saved frame names a ring 3
code selector. Nothing else. There is no loader, no system call and no process,
and the order is deliberate:

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

## What a program owns, and what ends it

Three frames and an address space. The frames are this package's, not the
space's, because `mem.space_destroy` frees page tables and never leaves. See
the file comment in `kernel/mem/space.odin` for why that division is there and
what would change it.

A program ends by faulting, and there is currently no other way. It cannot ask,
because there is no system call yet. The kernel cannot tell it either, because
nothing but the clock interrupts a program. `destroy` therefore refuses a
program that is still running, rather than free the tables underneath it. Plan
9 ends a process with a note. That is the same missing piece by its proper
name.
*/
package user

import "base:intrinsics"

import "kernel:arch"
import "kernel:mem"
import "kernel:sched"
import "kernel:sync"

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
}

Program :: struct {
	name:   string,
	space:  ^mem.Address_Space,
	thread: ^sched.Thread,

	// The frames behind the three mappings. Physical, because that is what
	// this package has to free and what `mem.phys_to_virt` needs to read the
	// data page back.
	text:   uintptr,
	data:   uintptr,
	stack:  uintptr,

	// The bounds of the thread's kernel stack, copied at load time. Copied
	// rather than read back through `thread`, because the next `spawn` frees a
	// dead thread's record and the answer is wanted after that.
	kstack_lo: uintptr,
	kstack_hi: uintptr,

	exit:   Exit,
	live:   bool,
}

/*
The programs, from a fixed table.

The same argument `mem.spaces` makes. A record a program can make the kernel
allocate is a record a program can exhaust the machine through. This is also
the first code in Vectra that anything untrusted will reach.
*/
MAX_PROGRAMS :: 8

@(private = "file")
programs: [MAX_PROGRAMS]Program

@(private = "file")
loaded: int
@(private = "file")
faults: int

Stats :: struct {
	live:   int, // Programs loaded and not destroyed
	loaded: int, // Programs loaded since boot
	faults: int, // Faults taken in ring 3, which is how every program has ended
	traps:  u64, // Every return from ring 3, preemptions included
}

stats :: proc "contextless" () -> Stats {
	live := 0
	for i in 0 ..< MAX_PROGRAMS {
		if programs[i].live {
			live += 1
		}
	}
	return Stats{live = live, loaded = loaded, faults = faults, traps = arch.user_trap_count()}
}

/*
init claims the fault path for programs.

One line, and it is the line that separates `a fault ends the machine` from `a
fault ends the program`. Until it runs, a trap from ring 3 falls through to
`kernel/panic.odin` and stops the boot. That is the right default for a
privilege level nothing owns yet.
*/
init :: proc "contextless" () {
	arch.set_user_trap_handler(on_trap)
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
		if p := (^Program)(thread.user); p != nil {
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

`arg` is whatever the program's second argument should be. The blobs take an
address to touch in it. Which address a blob receives is what makes one run a
test of the kernel half and another a test of a read-only page.
*/
load :: proc(name: string, code: []u8, arg: u64 = 0) -> (^Program, mem.Error) {
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
	p^ = Program {
		name  = name,
		space = space,
		live  = true,
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

	// The thread gets `p` before it can run. The fault handler reads it, and
	// the first fault may arrive on the very next interrupt.
	p.thread = sched.spawn_user(name, space, TEXT_VA, STACK_TOP, u64(DATA_VA), arg, p)
	if p.thread == nil {
		unload(p)
		return nil, .Out_Of_Memory
	}

	p.kstack_lo = uintptr(raw_data(p.thread.stack))
	p.kstack_hi = p.thread.kstack_top

	loaded += 1
	return p, .None
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
wait :: proc "contextless" (p: ^Program, patience: int) -> bool {
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

// ended reports whether a program already faulted, without waiting.
ended :: proc "contextless" (p: ^Program) -> bool {
	return p != nil && intrinsics.volatile_load(&p.exit.done)
}

/*
cell reads one eight-byte word of a program's data page, from the kernel side.

Through the direct map, not through the program's space. The kernel is not
translating through those tables and must not have to be. That is also what
makes the page shared in the honest sense: the same frame, two mappings, two
privilege levels, and neither one a copy.
*/
cell :: proc "contextless" (p: ^Program, index: int) -> u64 {
	if p == nil || p.data == 0 || index < 0 || index >= arch.PAGE_SIZE / size_of(u64) {
		return 0
	}
	words := cast([^]u64)mem.phys_to_virt(p.data)
	return intrinsics.volatile_load(&words[index])
}

// set_cell writes one word of a program's data page. The other direction of
// `cell`, and what tells `spin` to stop.
set_cell :: proc "contextless" (p: ^Program, index: int, value: u64) {
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
destroy :: proc "contextless" (p: ^Program) -> bool {
	if p == nil || !p.live {
		return false
	}
	if p.thread != nil && !intrinsics.volatile_load(&p.exit.done) {
		return false
	}
	unload(p)
	return true
}

@(private = "file")
unload :: proc "contextless" (p: ^Program) {
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
	p^ = Program{}
}

@(private = "file")
free_slot :: proc "contextless" () -> ^Program #no_bounds_check {
	for i in 0 ..< MAX_PROGRAMS {
		if !programs[i].live {
			return &programs[i]
		}
	}
	return nil
}
