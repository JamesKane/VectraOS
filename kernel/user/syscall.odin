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

`write` is a placeholder around a real path. **Descriptor 1 is `/dev/cons`,
opened once at boot, and there is no table behind it.** A file descriptor
belongs to a process, and a process is the next milestone. Until then this is a
hardcoded chan with a number in front of it. What is real about it is
everything after the copy: a genuine 9P write, over the real transport, to the
real console. A program's own bytes reach the boot log through it.
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

// The one descriptor there is. See the file comment for why it is a constant
// rather than an index.
FD_CONS :: u64(1)

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
		result = sys_write(a0, uintptr(a1), int(a2))
	case SYS_SLEEP:
		result = sys_sleep(a0)
	case SYS_EXIT:
		sys_exit(frame, a0)
	case:
		result = -i64(vectra9.ENOSYS)
	}

	frame.rax = u64(result)
}

@(private = "file")
sys_write :: proc(fd: u64, addr: uintptr, count: int) -> i64 {
	if fd != FD_CONS || cons == nil {
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

	written, err := vfs.chan_write(cons, 0, buffer[:n])
	if err != vfs.OK {
		return -i64(err)
	}
	return i64(written)
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
		if p := (^Program)(thread.user); p != nil {
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
@(private = "file")
copy_in :: proc "contextless" (addr: uintptr, n: int, dst: []u8) -> bool {
	if n <= 0 || n > len(dst) {
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
		if !ok || .User not_in flags {
			return false
		}
	}

	src := cast([^]u8)addr
	for i in 0 ..< n {
		dst[i] = src[i]
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
