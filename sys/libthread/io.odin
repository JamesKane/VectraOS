/*
An io proc: a proc that makes a blocking call on a thread's behalf.

A thread that calls `read` parks its whole proc in the kernel, and every
other thread of that proc with it. Plan 9's answer is `ioproc`, a proc
whose one job is to make that call. The *thread* parks on a channel, and
the proc it belongs to keeps running. `ioread(io, fd, buf)` is a `read` a
thread may make. It sends the call to the io proc, which parks in the
kernel with the caller's buffer, and the thread waits on the reply. What
comes back is what one `read` delivered, whole, which is what a read of a
cooked console owes its reader.

One io proc makes one call at a time, and two threads that share one take
turns. So a program gives each thing that parks an io proc of its own. A
server has one for the pipe it serves and one for the device it reads.
The proc costs a scheduler stack and a small one for the loop. It is the
whole reason a program on this library has more processes than it had
threads that block, and `docs/THREAD.md` section 9 counts them.

The call's record is on the caller's stack. The caller is parked until
the reply names it, so the io proc reads and writes the record freely.
*/
package libthread

import "vsys:libuser"
import "vsys:vectra9"

Io_Op :: enum u8 {
	Read,
	Write,
	Sleep, // `ticks` in `fd`: a wait a thread may make without parking its proc
	Exit, // leave the loop, so `ioclose` can give the proc back
}

Io_Call :: struct {
	op:     Io_Op,
	fd:     int,
	buf:    []u8,
	result: i64,
}

Ioproc :: struct {
	calls:   ^Chan, // `^Io_Call` to the io proc
	replies: ^Chan, // the same pointer back, when the call is made
	pid:     i64,
}

// The io proc's loop is a receive, a system call and a send, and its
// stack is the least a thread may have.
IO_STACK :: 4096

// ioproc makes an io proc, or answers nil when there is no memory or no
// proc for it.
ioproc :: proc "contextless" () -> ^Ioproc {
	io := (^Ioproc)(libuser.heap_alloc(size_of(Ioproc)))
	if io == nil {
		return nil
	}
	io^ = {}
	io.calls = chancreate(size_of(rawptr), 0)
	io.replies = chancreate(size_of(rawptr), 0)
	if io.calls == nil || io.replies == nil {
		return nil
	}
	io.pid = proccreate(io_loop, io, IO_STACK)
	if io.pid < 0 {
		return nil
	}
	return io
}

/*
ioclose gives an io proc back: the record, its two channels, and the proc
itself. Without it an io proc lives as long as the program. That is right
for a server's, made once, but a leak for one a window makes and drops.

The loop is told to leave with an `Exit` call, and `iocall` waits for the
ack the loop sends before it returns. So by the time this frees the
channels the loop is on its way out of them. Only safe when the io proc is
idle, between calls rather than parked in one. A reader closes its own
descriptor first, so a read in flight ends and the loop comes back to wait
for the `Exit`. See `sys/libmui`'s `window_close`.

The proc is waited for, not just told to go. The maker of an io proc is the
one that waits for it, the same as `wait_children` at exit. So its record is
back, not a zombie holding a table slot through a desktop's churn. A proc the
kernel collects itself, made detached by a proc that is not the first,
answers the wait at once. This is right for either.
*/
ioclose :: proc "contextless" (io: ^Ioproc) {
	if io == nil {
		return
	}
	c := Io_Call{op = .Exit}
	iocall(io, &c)
	if io.pid > 0 {
		for {
			r := libuser.wait(u64(io.pid))
			if r != -i64(vectra9.EAGAIN) {
				break
			}
		}
	}
	chanfree(io.calls)
	chanfree(io.replies)
	libuser.heap_free(io)
}

@(private = "file")
io_loop :: proc "contextless" (arg: rawptr) {
	io := (^Ioproc)(arg)
	for {
		c := (^Io_Call)(recvp(io.calls))
		if c.op == .Exit {
			// Acked, not answered: `ioclose` waits for this send. By the
			// time it returns the loop is on its way out and touches neither
			// channel again, so freeing them is safe.
			sendp(io.replies, c)
			return
		}
		switch c.op {
		case .Read:
			c.result = libuser.read(c.fd, c.buf)
		case .Write:
			c.result = libuser.write(c.fd, c.buf)
		case .Sleep:
			c.result = libuser.sleep(u64(c.fd))
		case .Exit:
		}
		sendp(io.replies, c)
	}
}

@(private = "file")
iocall :: proc "contextless" (io: ^Ioproc, c: ^Io_Call) -> i64 {
	sendp(io.calls, c)
	_ = recvp(io.replies)
	return c.result
}

// ioread is `libuser.read` made from a thread: the answer is the kernel's,
// a count or `-errno`, and the proc ran its other threads meanwhile.
ioread :: proc "contextless" (io: ^Ioproc, fd: int, buf: []u8) -> i64 {
	c := Io_Call{op = .Read, fd = fd, buf = buf}
	return iocall(io, &c)
}

iowrite :: proc "contextless" (io: ^Ioproc, fd: int, data: []u8) -> i64 {
	c := Io_Call{op = .Write, fd = fd, buf = data}
	return iocall(io, &c)
}

// iosleep is `libuser.sleep` made from a thread: the io proc waits the
// ticks, and the proc runs its other threads meanwhile. A thread that
// slept with the system call itself would park every thread beside it,
// which is what a desktop's clock must never do.
iosleep :: proc "contextless" (io: ^Ioproc, ticks: int) -> i64 {
	c := Io_Call{op = .Sleep, fd = ticks}
	return iocall(io, &c)
}

// ioread_full is `libuser.read_full` through an io proc: the whole buffer,
// however many calls that takes, and false when the descriptor ended.
ioread_full :: proc "contextless" (io: ^Ioproc, fd: int, buf: []u8) -> bool {
	got := 0
	for got < len(buf) {
		n := ioread(io, fd, buf[got:])
		if n <= 0 {
			return false
		}
		got += int(n)
	}
	return true
}
