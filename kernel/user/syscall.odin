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

`create`, `mount` and `remove` arrived with posting. Together they are Plan
9's `/srv` arc from ring 3. Reserve a name, write a descriptor into it,
mount what it names, take the name away. `docs/SRV.md` owns that design, and
`resolve_fd_chan` below is this package's part of it.

`pipe` arrived with the wire, and it is the call that lets a program be a
*server*. Two descriptors on one channel, either of which can be posted.
`docs/PIPE.md` owns the channel, and `/bin/niner` in `program.odin` is the
first program that answers what comes down one.

## What is still missing from the interface

No `stat`, because nothing in ring 3 needs one yet. `vfs.chan_stat` exists,
the call is the same shape as the ones below, and it is not a design
question.
*/
package user

import "base:intrinsics"
import "base:runtime"

import "kernel:arch"
import "kernel:mem"
import "kernel:pipe"
import "kernel:sched"
import "kernel:srv"
import "kernel:sync"
import "kernel:vfs"
import "vsys:abi"
import "vsys:vectra9"

// The numbers live in `sys/abi`, the one file both sides of the door
// include, so the dispatcher and the userland library cannot drift apart.
SYS_NOP :: abi.SYS_NOP
SYS_ARGS :: abi.SYS_ARGS
SYS_WRITE :: abi.SYS_WRITE
SYS_SLEEP :: abi.SYS_SLEEP
SYS_EXIT :: abi.SYS_EXIT
SYS_OPEN :: abi.SYS_OPEN
SYS_CLOSE :: abi.SYS_CLOSE
SYS_READ :: abi.SYS_READ
SYS_BIND :: abi.SYS_BIND
SYS_SEEK :: abi.SYS_SEEK
SYS_SPAWN :: abi.SYS_SPAWN
SYS_WAIT :: abi.SYS_WAIT
SYS_CREATE :: abi.SYS_CREATE
SYS_MOUNT :: abi.SYS_MOUNT
SYS_REMOVE :: abi.SYS_REMOVE
SYS_PIPE :: abi.SYS_PIPE
SYS_NOTE :: abi.SYS_NOTE
SYS_RFORK :: abi.SYS_RFORK
SYS_NOTIFY :: abi.SYS_NOTIFY
SYS_NOTED :: abi.SYS_NOTED
SYS_EXEC :: abi.SYS_EXEC
SYS_SEGATTACH :: abi.SYS_SEGATTACH

// The longest path a program may name in one call. Long enough for anything
// in the tree, short enough to sit on a kernel stack beside the copy buffer.
PATH_MAX :: 128

/*
The chunk one `read` or `write` moves per pass, and the buffer that holds it.

On the calling thread's kernel stack, which is 32 KiB. `read` and `write` no
longer stop at one chunk. They loop until the whole count is moved, so a
program transfers a large buffer in one call rather than one call per chunk.

The loop still bounds each *copy*. A program that hands over a bad pointer
part-way loses only the tail, and gets the count of what landed. The chunk is
also clamped to the server's `iounit`, so a 9P message never serialises past
its frame. See `sys_write` and `sys_read`.

The other `copy_in` callers -- a path, a note -- stay small and single, so
they keep their own tight bounds rather than this one.

A page, which is also exactly one `devfs` payload slot. The buffer costs an
eighth of a 32 KiB kernel stack. A chunk now fills the largest frame the
bulk-heavy server offers, so the iounit is what binds -- 9front's client
chunks by iounit alone. The pipe wire's 1 KiB slots remain the real ceiling
for a userland server. Raising this buys nothing until an msize grows. A
program that names a huge buffer wants a mapped one anyway rather than
this copy.
*/
IO_CHUNK :: 4096

// io_chunk is the most one pass of a bulk loop moves: the kernel's copy
// buffer, or the server's iounit when that is smaller. A degenerate iounit
// falls back to the copy bound and leaves an unframeable chunk to the
// transport, whose refusal names the broken session.
@(private = "file")
io_chunk :: proc "contextless" (c: ^vfs.Chan) -> int {
	chunk := min(IO_CHUNK, vfs.chan_iounit(c))
	return chunk > 0 ? chunk : IO_CHUNK
}

// partial resolves a bulk pass that failed. What already moved is the call's
// answer, which every read and write interface makes a caller handle. Only a
// failure on the very first pass is the whole call's error.
@(private = "file")
partial :: proc "contextless" (total: int, err: vfs.Errno) -> i64 {
	return total > 0 ? i64(total) : -i64(err)
}

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
	// This package owns descriptor tables, so it is the one that can say what
	// a number in a Twrite to `/srv` means. See `resolve_fd_server`.
	srv.set_fd_resolver(resolve_fd_chan)
	return arch.syscall_init()
}

/*
resolve_fd_chan answers `/srv`'s question: whose connection is descriptor n?

The calling thread's process's, which is the only sound answer and the reason
the hook lives here. `/srv` is synchronous, so its handler runs on the thread
that wrote, and `current()` names the process that holds the number. A kernel
thread has no process and gets nil, which `/srv` turns into EBADF -- a number
from nowhere names nothing.

Runs under `/srv`'s spinlock: table lookups only, no messages, no lock that
parks. What it hands back is the chan **with a reference of its own**, taken
under the table's lock. `/srv` keeps that reference as the posting. A
borrow would not survive a shared table -- a sibling's close could spend the
chan between this answer and `/srv`'s increment. Lock order: `/srv` before
the table, here and nowhere the other way.
*/
@(private = "file")
resolve_fd_chan :: proc "contextless" (fd: int) -> ^vfs.Chan {
	c, _, ok := fd_take(current(), fd)
	if !ok {
		return nil
	}
	return c
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

	/*
	The door is the boundary a note waits at, and the check comes before the
	call. A noted program's next request is one nothing should honour. With
	no handler the program ends here, and with one, the call it was about to
	make is aborted and the handler gets the frame. That abort is Plan 9's
	rule for an interrupted call. Its EINTR is written into `rax` before the
	frame is saved, so NCONT resumes into the answer. A delivery already in
	flight holds the note instead -- the handler's own calls, `noted` above
	all, must still work.
	*/
	if thread := sched.current(); sched.thread_noted(thread) {
		p := current()
		if p == nil || p.handler == 0 {
			note_exit(frame)
		}
		if !p.notified {
			frame.rax = transmute(u64)(-i64(vectra9.EINTR))
			if !deliver_note(p, frame) {
				note_exit(frame)
			}
			sched.clear_note(thread)
			return
		}
	}

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
	case SYS_CREATE:
		result = sys_create(uintptr(a0), int(a1), u32(a2), u32(a3))
	case SYS_MOUNT:
		result = sys_mount(uintptr(a0), int(a1), uintptr(a2), int(a3), a4)
	case SYS_REMOVE:
		result = sys_remove(uintptr(a0), int(a1))
	case SYS_PIPE:
		result = sys_pipe()
	case SYS_NOTE:
		result = sys_note(a0, uintptr(a1), int(a2))
	case SYS_RFORK:
		// The frame crosses like `SYS_EXIT`'s, and for a bigger reason: the
		// frame *is* the child's first state. See `rfork.odin`.
		result = sys_rfork(frame, a0)
	case SYS_NOTIFY:
		result = sys_notify(uintptr(a0))
	case SYS_NOTED:
		// The frame crosses because NCONT rewrites it: the answer to this
		// call is the interrupted program's own state. See `notify.odin`.
		result = sys_noted(frame, a0)
	case SYS_EXEC:
		// The frame crosses because exec rewrites it in place: on success
		// the door returns into a new program. See `exec.odin`.
		result = sys_exec(frame, uintptr(a0), int(a1))
	case SYS_SEGATTACH:
		result = sys_segattach(int(a0))

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
process owns. `rfork.odin` starts at the same place, for the same reason.
*/
@(private)
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
	c, offset, ok := fd_take(p, fd)
	if !ok {
		return -i64(vectra9.EBADF)
	}
	// The reference, not the slot. A sibling on a shared table may close
	// this descriptor while the write below is parked. The chan must
	// outlive the operation it is in. See `fdtable.odin`.
	defer vfs.chan_close(c)
	if count <= 0 {
		return 0
	}

	/*
	The whole count in one call, a chunk at a time. Each pass copies a chunk
	from the program and writes it. So a large buffer costs one door crossing
	rather than one per chunk. The chunk is clamped to the server's `iounit`
	as well, so no `Twrite` serialises past its frame.

	A pass that fails part-way keeps what already landed -- see `partial`.
	The buffer is uninitialised because `copy_in` fills every byte a pass
	hands on. Zeroing it would cost each call an `IO_CHUNK` memset.
	*/
	buffer: [IO_CHUNK]u8 = ---
	chunk := io_chunk(c)
	total := 0
	for total < count {
		n := min(count - total, chunk)
		if !copy_in(addr + uintptr(total), n, buffer[:n]) {
			return partial(total, vectra9.EFAULT)
		}
		written, err := vfs.chan_write(c, offset + u64(total), buffer[:n])
		if err != vfs.OK {
			return partial(total, err)
		}
		total += written
		if written < n {
			// The device took less than offered -- a full ring, an edge. It
			// will take no more this call.
			break
		}
	}
	// The cursor is the process's, not the file's, and it moves only if the
	// descriptor still means this chan. See `fd_advance`.
	fd_advance(p, fd, c, u64(total))
	return i64(total)
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
	c, offset, ok := fd_take(p, fd)
	if !ok {
		return -i64(vectra9.EBADF)
	}
	// A reference of this call's own, for the same reason `sys_write` takes
	// one -- a parked read must not have its chan spent under it.
	defer vfs.chan_close(c)
	if count <= 0 {
		return 0
	}

	/*
	One loop for a stream and a file alike, which is `devmnt`'s in Plan 9. It
	chunks at the server's iounit and stops on a short chunk. A console read
	returns the one line it has, because a short chunk breaks the loop. A file
	read fills the whole count, a full chunk at a time. The distinction is the
	data, not the server. A stream answers short and a file answers full, and
	neither has to be labelled.

	An interruptible server fetches each chunk with a deadline, and checks the
	note between retries. So a note can end a read that parks. A synchronous
	server has no deadline to lean on and no worker to park, so its chunk is a
	plain read. A `copy_out` that fails part-way keeps what already landed, the
	way the bulk write keeps what it wrote. The buffer is uninitialised for the
	same reason the write's is: only bytes a read landed are ever handed on.
	*/
	buffer: [IO_CHUNK]u8 = ---
	chunk := io_chunk(c)
	interruptible := vfs.server_interruptible(c.server)
	total := 0
	for total < count {
		n := min(count - total, chunk)
		got: int
		err: vfs.Errno
		if interruptible {
			for {
				got, err = vfs.chan_read_for(c, offset + u64(total), buffer[:n], NOTE_POLL)
				if err != vectra9.EINTR {
					break
				}
				if sched.thread_noted(sched.current()) {
					return partial(total, vectra9.EINTR)
				}
			}
		} else {
			got, err = vfs.chan_read(c, offset + u64(total), buffer[:n])
		}
		if err != vfs.OK {
			return partial(total, err)
		}
		if got > 0 && !copy_out(addr + uintptr(total), buffer[:got]) {
			return partial(total, vectra9.EFAULT)
		}
		total += got
		if got < n {
			// A short chunk is a stream answering with what it had, or a file
			// reaching its end. Either way, no more comes this call.
			break
		}
	}
	fd_advance(p, fd, c, u64(total))
	return i64(total)
}

// Ticks between note checks on a read that waits for a device. Short enough
// that a note lands promptly, long enough that a parked console reader costs
// a handful of flushes a second rather than a poll.
@(private = "file")
NOTE_POLL :: u64(25)

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
sys_create makes a file where a path says, and returns a descriptor on it.

A separate call rather than a flag on `open`, which is Plan 9's split and
9P's. Tlopen and Tlcreate are different messages. To fold them back together
here would be a translation layer's job done in the wrong place. The first
thing creation is for is posting a service, and `/srv` is the first server
that answers it.
*/
@(private = "file")
sys_create :: proc(addr: uintptr, length: int, flags: u32, mode: u32) -> i64 {
	p := current()
	if p == nil || p.ns == nil {
		return -i64(vectra9.EBADF)
	}

	path: [PATH_MAX]u8
	if length <= 0 || length > PATH_MAX || !copy_in(addr, length, path[:]) {
		return -i64(vectra9.EFAULT)
	}

	c, err := vfs.create_path(p.ns, string(path[:length]), flags, mode)
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

/*
sys_mount attaches a posted service and binds it in this process's namespace.

The pair to `sys_bind`: bind rearranges names a namespace already has, and
mount brings a *service* into one by the name `/srv` gave it. Both paths
resolve in the caller's own namespace. A fork that dropped `/srv`, or a
bind over it, changes what this can reach. That is the design, not a leak.
`docs/SRV.md` says why the source must be a `/srv` entry and nothing else.
*/
@(private = "file")
sys_mount :: proc(src: uintptr, src_len: int, dst: uintptr, dst_len: int, order: u64) -> i64 {
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

	err := srv.mount(p.ns, string(source[:src_len]), string(target[:dst_len]), how)
	if err != vfs.OK {
		return -i64(err)
	}
	return 0
}

/*
sys_pipe makes a pipe and returns both ends, packed as two descriptors.

End 0's descriptor sits in the low byte and end 1's in the next, which is the
same packing `child` uses for its exit status. Two out-parameters would need
a pointer from ring 3 and a copy out, to say two numbers that each fit in a
byte. A caller that wants them apart shifts.

The ends are ordinary descriptors from here on. They travel to children
through `spawn`, and they close through `close`. Either one can be written
into a `/srv` entry, which is the posting that makes the far side of the
pipe a service. See `docs/SRV.md`.
*/
@(private = "file")
sys_pipe :: proc() -> i64 {
	p := current()
	if p == nil {
		return -i64(vectra9.EBADF)
	}

	pp := pipe.create()
	if pp == nil {
		return -i64(vectra9.ENOSPC)
	}

	c0, e0 := pipe.open_end(pp, 0)
	c1, e1 := pipe.open_end(pp, 1)
	if e0 != vfs.OK || e1 != vfs.OK {
		if c0 != nil {
			vfs.chan_close(c0)
		} else {
			pipe.close_end(pp, 0)
		}
		if c1 != nil {
			vfs.chan_close(c1)
		} else {
			pipe.close_end(pp, 1)
		}
		return -i64(vectra9.ENOSPC)
	}

	fd0, ok0 := fd_open(p, c0)
	if !ok0 {
		vfs.chan_close(c0)
		vfs.chan_close(c1)
		return -i64(vectra9.EMFILE)
	}
	fd1, ok1 := fd_open(p, c1)
	if !ok1 {
		_ = fd_close(p, fd0)
		vfs.chan_close(c1)
		return -i64(vectra9.EMFILE)
	}
	return i64(fd0 | fd1 << 8)
}

/*
sys_note posts a note to one of the caller's own children.

The same authority rule as `wait`. A pid that is not the caller's child gets
ECHILD exactly like a pid that never existed. A process therefore learns
nothing about the table by noting. Plan 9 grants notes by user rather than by
parenthood, and will again here the day processes have owners. The text
crosses like every pointer from ring 3, bounded by what a note can hold.
*/
@(private = "file")
sys_note :: proc(pid: u64, addr: uintptr, length: int) -> i64 {
	p := current()
	if p == nil {
		return -i64(vectra9.ECHILD)
	}
	if length < 0 || length > NOTE_MAX {
		return -i64(vectra9.EINVAL)
	}

	text: [NOTE_MAX]u8
	if length > 0 && !copy_in(addr, length, text[:]) {
		return -i64(vectra9.EFAULT)
	}

	child := find_child(p.pid, pid)
	if child == nil {
		return -i64(vectra9.ECHILD)
	}
	if !post_note(child, string(text[:length])) {
		return -i64(vectra9.ESRCH)
	}
	return 0
}

/*
note_exit is the door's half of delivery, and the half that finishes.

The shape is `sys_exit`'s with the record saying `noted` instead of a
status. The descriptors close first, in this thread context, because it is
the last one this process ever has. That is the difference from the tick's
half, whose interrupt context must leave them for `destroy`. A server noted
while parked unwinds to ring 3 with EINTR and re-enters on its next call. It
ends here, with its pipe already hung up for its clients.
*/
@(private)
note_exit :: proc(frame: ^arch.Trap_Frame) -> ! {
	p := current()
	if p != nil {
		// Detach before the record is published, release in thread context.
		// On a shared table this is one holder leaving, not a close-all: a
		// sibling's descriptors survive their sibling's death.
		t := p.fdt
		p.fdt = nil
		fdt_release(t)
	}

	arch.disable_interrupts()
	if p != nil {
		p.exit.ip = uintptr(frame.rip)
		p.exit.sp = uintptr(frame.rsp)
		p.exit.kstack = uintptr(rawptr(frame))
		p.exit.from_user = arch.frame_is_user(frame)
		p.exit.noted = true
		intrinsics.volatile_store(&p.exit.done, true)
	}
	sync.wakeup_all(&exit_rendez)
	sched.exit()
}

// sys_remove takes a file away by name, in this process's namespace. The fid
// is spent whether or not the server agrees -- that is Tremove's rule, and
// `vfs.chan_remove` keeps it. So the chan is closed on both paths.
@(private = "file")
sys_remove :: proc(addr: uintptr, length: int) -> i64 {
	p := current()
	if p == nil || p.ns == nil {
		return -i64(vectra9.EBADF)
	}

	path: [PATH_MAX]u8
	if length <= 0 || length > PATH_MAX || !copy_in(addr, length, path[:]) {
		return -i64(vectra9.EFAULT)
	}

	c, err := vfs.resolve(p.ns, string(path[:length]))
	if err != vfs.OK {
		return -i64(err)
	}
	err = vfs.chan_remove(c)
	vfs.chan_close(c)
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
	if !fd_seek(current(), fd, offset) {
		return -i64(vectra9.EBADF)
	}
	return i64(offset)
}

/*
Where a process's first device mapping lands, and how far apart they sit.

High in the lower half, clear of everything a loader places. Text, data and
stack come out of the image's own addresses, and no format this kernel reads
asks for anything above a few megabytes.
*/
DEVICE_BASE :: uintptr(0x1000_0000)

/*
sys_segattach maps the device behind an open descriptor into this process.

**The namespace is what says which device, and whether this process may have
it.** A process that cannot open `/dev/fb` cannot ask, and a process whose
namespace binds something else over that name asks about the something else.
That permission story came free with taking a descriptor rather than a name
out of a kernel table. `docs/DRAW.md` section 7 is where the shape was
argued.

A syscall rather than a 9P message, because there is no reply that can carry
an address space. The wire rule of `docs/VECTRA9.md` is untouched. Nothing was
added to 9P, and `vfs.chan_device` is a second thing a server offers the kernel
rather than a seventh verb on a file.

The mapping is writable and never executable. A framebuffer a program can jump
into is one a program can be tricked into jumping into. No device this will ever
answer for is code.

Returns the address, or `-errno`. `ENODEV` is the honest answer for a file
that is a stream, which is almost all of them.
*/
@(private = "file")
sys_segattach :: proc(fd: int) -> i64 {
	p := current()
	c, _, held := fd_take(p, fd)
	if !held {
		return -i64(vectra9.EBADF)
	}
	defer vfs.chan_close(c)

	phys, bytes, ok := vfs.chan_device(c)
	if !ok || bytes == 0 {
		return -i64(vectra9.ENODEV)
	}

	// Whole pages, both ends. A device that ends mid-page still owns the rest
	// of it, and a mapping cannot be finer than the hardware page it lands in.
	pages := int((bytes + u64(arch.PAGE_SIZE) - 1) / u64(arch.PAGE_SIZE))
	if pages <= 0 {
		return -i64(vectra9.ENODEV)
	}

	if p.device_next == 0 {
		p.device_next = DEVICE_BASE
	}
	va := p.device_next
	span := uintptr(pages) * uintptr(arch.PAGE_SIZE)
	if va + span >= mem.USER_MAX {
		return -i64(vectra9.ENOMEM)
	}

	seg := segment_new(va, {.Write, .No_Execute}, .Device)
	if seg == nil {
		return -i64(vectra9.ENOMEM)
	}
	seg.base = phys
	seg.pages = pages
	if !proc_add_segment(p, seg) {
		return -i64(vectra9.ENOMEM)
	}

	/*
	One page at a time, and a failure part-way leaves the segment on the
	process's list.

	That is deliberate rather than lazy. `unload` releases every segment a
	process holds, and a `.Device` release frees nothing, so the half-built
	mapping costs page tables the space teardown already walks. Unwinding by
	hand would be a second teardown path for the same frames.
	*/
	for i in 0 ..< pages {
		at := va + uintptr(i) * uintptr(arch.PAGE_SIZE)
		frame := phys + uintptr(i) * uintptr(arch.PAGE_SIZE)
		if mem.map_user(p.space, at, frame, {.Write, .No_Execute}, 1) != .None {
			return -i64(vectra9.ENOMEM)
		}
	}

	p.device_next = va + span
	return i64(va)
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
	/*
	The descriptors close here, on the exiting thread, before anything else.
	This is thread context, where a clunk is legal, and it is the last moment
	one ever runs for this process. `on_trap` cannot close anything, because a
	fault handler may not send a message. The rule this keeps is the wire's. A
	server that ends holding a pipe open is not dead, it is *quiet*, and its
	clients park on requests nothing will answer.

	A control found exactly that
	hang. The kernel sat parked in a write, and the only thread that could have
	run the teardown sat parked with it. A faulting process still holds its
	descriptors until `destroy`, and that is the note's job to finish. An
	ending the kernel delivers is an ending the kernel can also clean up after.

	On a shared table the close-all became a release: this holder leaves, and
	the chans close only when the last one does. The detach comes before the
	record is published, so `unload` finds nothing to release twice.
	*/
	if p := current(); p != nil {
		t := p.fdt
		p.fdt = nil
		fdt_release(t)
	}

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

	// The parent may be parked on the exit rendezvous. Interrupts are off, and
	// `wakeup_all` masks rather than enables, so the woken waiter cannot run
	// before this thread leaves the core.
	sync.wakeup_all(&exit_rendez)
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
sibling sharing the page could unmap it in between, and `rfork` means the
sibling exists now. What still does not exist is any way to unmap, so the
window stays unreachable. The first unmap reaches it. The answer then is
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

@(private)
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
@(private)
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
