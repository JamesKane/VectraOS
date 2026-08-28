/*
What a program may ask for, and what happens to a pointer it hands over.

`kernel/arch/amd64/syscall.odin` is the door. This is what is behind it. The
split is the usual one: the architecture knows about `STAR` and `swapgs`, and
this file knows about programs and has never seen a selector.

## The calling convention

    rax           which call
    rdi rsi rdx   the first three arguments
    r10 r8 r9     the next three
    rax           the answer

Six arguments, and `r10` rather than `rcx` in the fourth slot, because
`syscall` puts the return address in `rcx` before the stub can save it. Linux
made the same substitution for the same reason.

The answer is signed. Zero or more is a result, and a negative number is
`-errno` out of `sys/vectra9`. That is the same numbering a 9P reply carries,
and it is deliberate. The calls that matter will be 9P operations, and a
translation layer between two error vocabularies is a place for them to
disagree.

**Only `rax`, `rcx` and `r11` change.** The stub keeps that promise by holding
every register in a `Trap_Frame` across the call, rather than by counting which
ones a dispatcher might touch.

## These five are the mechanism, not the interface

`exit` and `sleep` are permanent. A program that can only end by faulting is
the thing this milestone removes. A program that can wait is what makes a
scheduler visible from ring 3.

`nop` and `args` exist to test the door. They go the day something real needs
their numbers.

`open`, `close`, `read`, `write` and `bind` are the interface. Five calls, and
four of them are 9P operations with a descriptor in front. The fifth is what
makes Vectra a Plan 9 system rather than a Unix one. **A process rearranges its
own namespace, and no other process sees the change.**

`nop` and `args` stay because they cost nothing and they are the only checks
that say every argument register arrives. They are the door's own self-test.

`spawn` and `wait` arrived with the loader. One starts a process from a file
the caller names in its own namespace, and the other collects what it
started. `spawn.odin` says what a child inherits and why the call is not yet
`rfork` and `exec`.

## What is still missing from the interface

No `create`, because `kernel/vfs` has no `chan_create`. No `stat`, because
nothing needs one yet. No `mount`, because posting a service from ring 3 needs
a descriptor to carry the connection, and `docs/SRV.md` says which line that
is. All three are the same shape as the five below and none of them is a design
question.
*/
package user

import "base:intrinsics"
import "base:runtime"

import "kernel:arch"
import "kernel:mem"
import "kernel:sched"
import "kernel:sync"
import "kernel:vfs"
import "vsys:vectra9"

SYS_NOP :: u64(0)
SYS_ARGS :: u64(1)
SYS_WRITE :: u64(2)
SYS_SLEEP :: u64(3)
SYS_EXIT :: u64(4)
SYS_OPEN :: u64(5)
SYS_CLOSE :: u64(6)
SYS_READ :: u64(7)
SYS_BIND :: u64(8)
SYS_SEEK :: u64(9)
SYS_SPAWN :: u64(10)
SYS_WAIT :: u64(11)

// The longest path a program may name in one call. Long enough for anything
// in the tree, short enough to sit on a kernel stack beside the copy buffer.
PATH_MAX :: 128

/*
How much of a program's memory one call may copy.

A bound rather than a loop, and small. The buffer is on the calling thread's
kernel stack, and a kernel stack is 32 KiB. A program that asks for more gets a
short write and the count back. Every write interface in the world already
makes a caller handle that.
*/
COPY_MAX :: 256

// The longest a program may ask to sleep in one call. A program can ask again.
// What this stops is one call parking a thread past the end of the boot, where
// nothing would ever reap it.
SLEEP_MAX :: u64(100)

/*
The kernel's own handle on the console, which is not a process's.

`cons_finish` uses it to end a line a program wrote and did not. Every
descriptor a program holds comes from that process's own namespace instead.
*/
@(private = "file")
cons: ^vfs.Chan

@(private = "file")
calls: int

/*
syscall_init opens the console and arms the instruction.

The order is the one that can fail safely, and the chan comes first. A program
that called `write` before there was anything to write to would get a
descriptor error rather than a fault. That is a harder bug to see.

Returns false when the CPU has no `syscall` instruction, which no amd64 part
does. The caller says so on its own line rather than halting.
*/
syscall_init :: proc(ns: ^vfs.Namespace) -> bool {
	if cons == nil && ns != nil {
		c, err := vfs.open_path(ns, "/dev/cons", vfs.O_WRONLY)
		if err == vfs.OK {
			cons = c
		}
	}
	return arch.syscall_init()
}

syscall_count :: proc "contextless" () -> int {
	return calls
}

/*
dispatch is where the entry stub lands.

Ordinary thread context, on the calling thread's own kernel stack, with
interrupts already back on. So this may allocate, may take a lock that parks,
and may send a 9P message and wait for the reply. A syscall that blocks blocks
the program and nothing else.

The context is built here rather than inherited. A `proc "sysv"` has no
implicit one, and the thread this runs on was never given a default. That is
the same three lines every worker thread in the tree starts with.

The answer goes into `frame.rax`, which the pops at the end of the stub deliver
back to the program. Nothing here returns a value, because there is nowhere for
a return value to go.
*/
@(export, link_name = "vectra_syscall_dispatch")
dispatch :: proc "sysv" (frame: ^arch.Trap_Frame) {
	context = syscall_context()
	calls += 1

	number := frame.rax
	a0 := frame.rdi
	a1 := frame.rsi
	a2 := frame.rdx
	a3 := frame.r10
	a4 := frame.r8
	a5 := frame.r9

	result: i64
	switch number {
	case SYS_NOP:
		result = 0
	case SYS_ARGS:
		// Every argument register, added up. The only thing this proves is
		// that all six arrive, which is the one property the convention has.
		result = i64(a0 + a1 + a2 + a3 + a4 + a5)
	case SYS_WRITE:
		result = sys_write(int(a0), uintptr(a1), int(a2))
	case SYS_READ:
		result = sys_read(int(a0), uintptr(a1), int(a2))
	case SYS_OPEN:
		result = sys_open(uintptr(a0), int(a1), u32(a2))
	case SYS_CLOSE:
		result = sys_close(int(a0))
	case SYS_BIND:
		result = sys_bind(uintptr(a0), int(a1), uintptr(a2), int(a3), a4)
	case SYS_SEEK:
		result = sys_seek(int(a0), a1)
	case SYS_SPAWN:
		result = sys_spawn(uintptr(a0), int(a1), a2)
	case SYS_WAIT:
		result = sys_wait(a0)
	case SYS_SLEEP:
		result = sys_sleep(a0)
	case SYS_EXIT:
		sys_exit(frame, a0)
	case:
		result = -i64(vectra9.ENOSYS)
	}

	frame.rax = u64(result)
}

/*
current reports the process the calling thread belongs to.

One load, through `Thread.user`, which the scheduler carries and never reads.
Every call below starts here, because every call below is about something a
process owns.
*/
@(private = "file")
current :: proc "contextless" () -> ^Process {
	thread := sched.current()
	if thread == nil {
		return nil
	}
	return (^Process)(thread.user)
}

@(private = "file")
sys_write :: proc(fd: int, addr: uintptr, count: int) -> i64 {
	p := current()
	f := fd_at(p, fd)
	if f == nil {
		return -i64(vectra9.EBADF)
	}
	if count <= 0 {
		return 0
	}

	buffer: [COPY_MAX]u8
	n := min(count, COPY_MAX)
	if !copy_in(addr, n, buffer[:]) {
		return -i64(vectra9.EFAULT)
	}

	written, err := vfs.chan_write(f.chan, f.offset, buffer[:n])
	if err != vfs.OK {
		return -i64(err)
	}
	// The cursor is the process's, not the file's. See `Fd`.
	f.offset += u64(written)
	return i64(written)
}

/*
sys_read fills a program's buffer from one of its descriptors.

Two copies, and the middle one is the kernel's. A read straight into a
program's page would hand `vfs.chan_read` an address it cannot check. A 9P
transport is the wrong place to grow a memory-protection opinion.

`copy_out` runs after the read rather than before, so a refused destination
costs the read rather than the file. That is the wrong way round for a device
that consumes what it gives, and the right way round for everything else. The
day `/dev/cons` is read this way, the answer is a buffer the process keeps.
*/
@(private = "file")
sys_read :: proc(fd: int, addr: uintptr, count: int) -> i64 {
	p := current()
	f := fd_at(p, fd)
	if f == nil {
		return -i64(vectra9.EBADF)
	}
	if count <= 0 {
		return 0
	}

	buffer: [COPY_MAX]u8
	n := min(count, COPY_MAX)
	got, err := vfs.chan_read(f.chan, f.offset, buffer[:n])
	if err != vfs.OK {
		return -i64(err)
	}
	if got > 0 && !copy_out(addr, buffer[:got]) {
		return -i64(vectra9.EFAULT)
	}
	f.offset += u64(got)
	return i64(got)
}

/*
sys_open resolves a path in **this process's** namespace and returns a number.

The number is the lowest free one, which is the rule a shell depends on. The
path comes through `copy_in` like every other pointer from ring 3, into a
buffer bounded by `PATH_MAX`.

The namespace is the process's fork, so two processes can hand this the same
string and get different files. `verify_namespaces` is that sentence as a
check.
*/
@(private = "file")
sys_open :: proc(addr: uintptr, length: int, flags: u32) -> i64 {
	p := current()
	if p == nil || p.ns == nil {
		return -i64(vectra9.EBADF)
	}

	path: [PATH_MAX]u8
	if length <= 0 || length > PATH_MAX || !copy_in(addr, length, path[:]) {
		return -i64(vectra9.EFAULT)
	}

	c, err := vfs.open_path(p.ns, string(path[:length]), flags)
	if err != vfs.OK {
		return -i64(err)
	}

	fd, ok := fd_open(p, c)
	if !ok {
		vfs.chan_close(c)
		return -i64(vectra9.EMFILE)
	}
	return i64(fd)
}

@(private = "file")
sys_close :: proc(fd: int) -> i64 {
	if !fd_close(current(), fd) {
		return -i64(vectra9.EBADF)
	}
	return 0
}

/*
sys_bind rearranges this process's view of the tree, and nobody else's.

**This is the call that makes Vectra a Plan 9 system.** Every other call here
has a Unix twin. This one does not, because in Unix the mount table belongs to
the machine and here it belongs to the process.

`order` is `Mount_Order`, and it is a number from ring 3 rather than a name. An
order the enum does not have becomes `.Replace`. A bind that lands somewhere
unexpected is worse than one that lands where a caller with no opinion would
want it.

A descriptor already open is not affected. It names a chan, and a bind changes
what a *path* resolves to. That is Plan 9's rule and it is the one a program
notices first.
*/
@(private = "file")
sys_bind :: proc(src: uintptr, src_len: int, dst: uintptr, dst_len: int, order: u64) -> i64 {
	p := current()
	if p == nil || p.ns == nil {
		return -i64(vectra9.EBADF)
	}
	if src_len <= 0 || src_len > PATH_MAX || dst_len <= 0 || dst_len > PATH_MAX {
		return -i64(vectra9.EINVAL)
	}

	source: [PATH_MAX]u8
	target: [PATH_MAX]u8
	if !copy_in(src, src_len, source[:]) || !copy_in(dst, dst_len, target[:]) {
		return -i64(vectra9.EFAULT)
	}

	how := vfs.Mount_Order.Replace
	switch order {
	case 1: how = .Before
	case 2: how = .After
	}

	err := vfs.bind_path(p.ns, string(source[:src_len]), string(target[:dst_len]), how)
	if err != vfs.OK {
		return -i64(err)
	}
	return 0
}

/*
sys_spawn starts a process on another process's say-so.

The first call here that creates a kernel object bigger than a descriptor.
The path is copied in like every other pointer from ring 3. Everything else
-- the loader, the namespace cases, the descriptor copy -- is `spawn_path`,
shared with the kernel's own launches. The answer is the child's pid, which
is the name `sys_wait` takes.
*/
@(private = "file")
sys_spawn :: proc(addr: uintptr, length: int, flags: u64) -> i64 {
	p := current()
	if p == nil || p.ns == nil {
		return -i64(vectra9.EBADF)
	}

	path: [PATH_MAX]u8
	if length <= 0 || length > PATH_MAX || !copy_in(addr, length, path[:]) {
		return -i64(vectra9.EFAULT)
	}

	child, err := spawn_path(p, string(path[:length]), flags)
	if err != vfs.OK {
		return -i64(err)
	}
	return i64(child.pid)
}

// sys_wait collects one ended child by pid, and is the other half of
// `sys_spawn`. What it returns is the status the child handed to `SYS_EXIT`.
// What it takes down is everything the spawn built. See `wait_pid`.
@(private = "file")
sys_wait :: proc(pid: u64) -> i64 {
	p := current()
	if p == nil {
		return -i64(vectra9.ECHILD)
	}
	return wait_pid(p.pid, pid, WAIT_PATIENCE)
}

// sys_seek moves a descriptor's cursor. The cursor is the process's, so this
// touches nothing the file knows about. There is no `whence`, because there is
// no size to seek relative to until something answers `stat`.
@(private = "file")
sys_seek :: proc(fd: int, offset: u64) -> i64 {
	f := fd_at(current(), fd)
	if f == nil {
		return -i64(vectra9.EBADF)
	}
	f.offset = offset
	return i64(offset)
}

@(private = "file")
sys_sleep :: proc(ticks: u64) -> i64 {
	held := min(ticks, SLEEP_MAX)
	if held == 0 {
		sched.yield()
		return 0
	}
	sync.delay(held)
	return i64(held)
}

/*
sys_exit ends the program, and is the first way out of ring 3 that is not a
fault.

**The record is written with interrupts off, and that is not tidiness.** The
observer polls `exit.done` and takes the program's space and frames down when
it sees it. Between the store and the moment this thread leaves the core, this
thread is still translating through that space. A tick in that window is enough
for the observer to run.

`on_trap` gets the same property for free, because a fault handler already runs
with interrupts masked. This path had to ask for it. `docs/TESTING.md` has the
control that found the shape of this, one milestone before it could happen.
*/
@(private = "file")
sys_exit :: proc(frame: ^arch.Trap_Frame, status: u64) {
	arch.disable_interrupts()

	if thread := sched.current(); thread != nil {
		if p := (^Process)(thread.user); p != nil {
			p.exit.vector = frame.vector
			p.exit.ip = uintptr(frame.rip)
			p.exit.sp = uintptr(frame.rsp)
			p.exit.kstack = uintptr(rawptr(frame))
			p.exit.from_user = arch.frame_is_user(frame)
			p.exit.status = status
			p.exit.deliberate = true
			intrinsics.volatile_store(&p.exit.done, true)
		}
	}

	sched.exit()
}

/*
copy_in brings `n` bytes of a program's memory into the kernel's.

Two steps, and the order is the whole of it. **Check every page, then read.**
The kernel is translating through the program's space at this moment, so the
address is directly readable. An unchecked read of a bad one faults in the
kernel. A program would then have a way to stop the machine with a number.

The check demands what the hardware demands of ring 3. The range is inside the
half a program may name, every page in it is present, and every page carries
`User`. The last of those is the one that matters. Without it a program could
name a kernel address, and the kernel's own read would succeed.

**There is a window between the check and the read**, and nothing closes it. A
second thread in the same space could unmap the page in between. Nothing can
unmap anything yet and a program has one thread, so the window is not
reachable. The first program with two threads reaches it. The answer then is
the one every kernel reaches for: fault the read and recover from it.
*/
/*
copy_out is the other direction, with one more thing to demand.

The same range and the same `User` bit, and a `Write` bit as well. A program
that names its own text page as a destination is asking the kernel to write
where ring 3 may not. The kernel has to say no on its own account. `CR0.WP`
turns that request into a page fault **in the kernel**, which is a program
stopping the machine with an address.

`set_bytes` in `user.odin` is the *kernel's* copy in this direction and checks
none of it. The kernel owns the frame and reaches it through the direct map.
That asymmetry is the whole reason these two exist and `set_bytes` does not.
*/
@(private = "file")
copy_out :: proc "contextless" (addr: uintptr, src: []u8) -> bool {
	if !reachable(addr, len(src), {.User, .Write}) {
		return false
	}
	dst := cast([^]u8)addr
	for i in 0 ..< len(src) {
		dst[i] = src[i]
	}
	return true
}

@(private = "file")
copy_in :: proc "contextless" (addr: uintptr, n: int, dst: []u8) -> bool {
	if n <= 0 || n > len(dst) {
		return false
	}
	if !reachable(addr, n, {.User}) {
		return false
	}

	src := cast([^]u8)addr
	for i in 0 ..< n {
		dst[i] = src[i]
	}
	return true
}

/*
reachable answers whether ring 3 could do this itself.

One question asked once, so the two copy directions cannot drift apart. The
range is inside the half a program may name, every page in it is present, and
every page carries every flag in `need`.

`addr >= USER_MAX` is not redundant beside `addr + span > USER_MAX`, and a
control aimed at the wrong half of that pair proved it. An address near the top
of the arithmetic wraps, and the sum comes out small. The first test is the one
that catches it.
*/
@(private = "file")
reachable :: proc "contextless" (addr: uintptr, n: int, need: arch.Page_Flags) -> bool {
	if n <= 0 {
		return false
	}
	if addr < mem.USER_MIN || addr >= mem.USER_MAX {
		return false
	}
	span := uintptr(n)
	if addr + span > mem.USER_MAX {
		return false
	}

	thread := sched.current()
	if thread == nil || thread.space == nil {
		return false
	}

	page := uintptr(arch.PAGE_SIZE)
	first := addr & ~(page - 1)
	last := (addr + span - 1) & ~(page - 1)
	for at := first; at <= last; at += page {
		flags, ok := mem.permissions(thread.space, at)
		if !ok || need - flags != {} {
			return false
		}
	}
	return true
}

/*
cons_finish ends the line a program wrote and did not.

`hello` writes its message without a newline, because the check on the other
side counts columns and a newline would reset the count. The line still has to
end, and the kernel is what ends it. `kernel/devfs/verify.odin` splits its own
write for the same reason, and this is the same split with the halves in two
privilege levels.
*/
@(private)
cons_finish :: proc() {
	if cons != nil {
		newline := [1]u8{'\n'}
		_, _ = vfs.chan_write(cons, 0, newline[:])
	}
}

@(private = "file")
syscall_context :: proc "contextless" () -> runtime.Context {
	c := runtime.default_context()
	c.allocator = mem.allocator()
	return c
}
