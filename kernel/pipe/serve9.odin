/*
A posted pipe end, turned into a server a namespace can mount.

Plan 9 posts a *channel* in `/srv`, and the 9P client over it is built at
mount time by `devmnt`. This file is that step. `kernel/srv` holds the chan
a process's descriptor named, and the first mount of the name lands here to
ask what server that chan is. For a pipe end the answer is a `mnt.Wire`.
Requests go encoded down the pipe, replies come back matched by tag, and a
program on the far side answers them. That program is the first server in
Vectra the kernel did not write.

One wire per pipe, built once and kept. Every mount of the name shares it,
exactly as every mount of a kernel service shares one `vfs.Server`. What the
wire drives is the *posted* end. The process keeps the other, reads requests
from it, and writes replies back.

## The handshake, and its deadline

The wire speaks Tversion before the first attach, as any client of an unknown
server must. The far side is a program that may answer nothing, so the
handshake carries a deadline where `vectra9.negotiate` does not. A server that
misses it gets its connection torn down: the end closes, the reader leaves,
and everything built here goes back to the heap. The mount that asked fails
with ENXIO, which is `/srv`'s sentence for a name whose service is not there.

## What is pinned, and what that costs

A successful build pins three things for the life of the machine. Those are
the wire and its arena, the server record, and one reference on the posted
chan. The reference is the load-bearing one. Removing a `/srv` name closes
the entry's chan. Without this reference, that close would reach the pipe
and poison the wire under every existing mount. Plan 9's rule is that
removal does not stop a service, and the reference is what keeps it here.

None of the three can come back until a posted service can be released, which
is the reference count `docs/SRV.md` already names as future work. The leak is
deliberate and visible: the pipe stays in `count`, and the wire's thread
stays in the scheduler's.
*/
package pipe

import "kernel:mnt"
import "kernel:sync"
import "kernel:vfs"
import "vsys:vectra9"

// Bytes for the wire's arena: one reply buffer per request slot plus the
// transmit buffer. What one slot holds becomes the connection's msize.
@(private = "file")
WIRE_ARENA :: 1024 * (mnt.MAX_REQUESTS + 1)

// Ticks the Tversion answer may take before the connection is torn down. Half
// a second of a parked server that has only to read seven bytes and echo them.
@(private = "file")
NEGOTIATE_TICKS :: 500

// What `io.data` points at: which pipe, and which end the wire drives.
@(private = "file")
Wire_End :: struct {
	p:   ^Pipe,
	end: int,
}

@(private = "file")
wire_read :: proc "contextless" (data: rawptr, buf: []u8) -> int {
	we := cast(^Wire_End)data
	return read(we.p, we.end, buf)
}

@(private = "file")
wire_write :: proc "contextless" (data: rawptr, frame: []u8) -> bool {
	we := cast(^Wire_End)data
	n, err := write(we.p, we.end, frame)
	return err == vfs.OK && n == len(frame)
}

/*
server_for answers `which server is this chan?` for a posted pipe end.

Nil for a chan that is not a pipe end, and for a pipe already spoken for
from its other end. Nil too for a server that failed the handshake.
`kernel/srv` turns nil into the chan's own device server, which for a pipe
answers nothing a mount can use. The mount fails rather than lands somewhere
surprising.

Serialised by a mutex, because two mounts of a fresh name can arrive
together. The loser of that race must find the winner's wire rather than
build a second one over the same bytes.
*/
server_for :: proc(c: ^vfs.Chan) -> ^vfs.Server {
	t := &pipes
	p, end := chan_pipe(c)
	if p == nil {
		return nil
	}

	sync.mutex_lock(&t.build)
	defer sync.mutex_unlock(&t.build)

	// Re-read under the build lock: the pipe may have died, or another mount
	// may have finished the build, while this caller waited its turn.
	g := sync.acquire(&t.lock)
	alive := live(p) && u64(node_of(p.id, end)) == c.qid.path
	existing := p.server9
	wired_end := p.wire_end
	sync.release(&t.lock, g)

	if !alive {
		return nil
	}
	if existing != nil {
		return wired_end == end ? existing : nil
	}

	we := new(Wire_End)
	arena := make([]u8, WIRE_ARENA)
	w := new(mnt.Wire)
	sv := new(vfs.Server)
	if we == nil || arena == nil || w == nil || sv == nil {
		free(we)
		delete(arena)
		free(w)
		free(sv)
		return nil
	}
	we^ = Wire_End{p = p, end = end}

	if !mnt.wire_init(w, mnt.Wire_IO{data = we, read = wire_read, write = wire_write}, arena) ||
	   !mnt.wire_start(w) {
		free(we)
		delete(arena)
		free(w)
		free(sv)
		return nil
	}

	sv.name = "pipe"
	sv.session = mnt.wire_session(w)^

	if !handshake(&sv.session) {
		/*
		The server never said 9P2000.L, so the connection comes down. Closing
		the wire's end is what unparks the reader -- it sees EOF and leaves --
		and `wire_join` is what makes the frees below safe.
		*/
		close_end(p, end)
		mnt.wire_join(w)
		free(we)
		delete(arena)
		free(w)
		free(sv)
		return nil
	}

	g2 := sync.acquire(&t.lock)
	p.server9 = sv
	p.wire_end = end
	sync.release(&t.lock, g2)

	// The pin described in the file comment. Without this reference, removing
	// the /srv name would close the chan and the close would reach the pipe.
	// The wire would then poison under every mount the removal was not allowed
	// to stop.
	_ = vfs.chan_incref(c)
	return sv
}

/*
quiesce waits for the reader of every dead wire to finish leaving.

A wire whose far side hung up is poisoned at once, and its reader thread
leaves a moment later. A self-test that measures the heap cannot ignore that
moment, because a leaving thread's stack is a heap object until it is
reaped. Healthy wires are not waited on. Their readers are parked on
purpose, for as long as the service lives.
*/
quiesce :: proc "contextless" () {
	t := &pipes
	for i in 0 ..< MAX_PIPES {
		p := &t.table[i]
		if !live(p) || p.server9 == nil {
			continue
		}
		w := cast(^mnt.Wire)p.server9.session.transport.data
		if mnt.wire_broken(w) {
			mnt.wire_join(w)
		}
	}
}

// handshake is `vectra9.negotiate` with a deadline. Same clamps, same refusal
// of any version but the one asked for.
@(private = "file")
handshake :: proc "contextless" (s: ^vectra9.Session) -> bool {
	request := vectra9.Msg(vectra9.Tversion{msize = s.msize, version = vectra9.VERSION})
	reply: vectra9.Msg
	if vectra9.call_for(s, &request, &reply, NEGOTIATE_TICKS) != .None {
		return false
	}
	answer, ok := reply.(vectra9.Rversion)
	if !ok || answer.version != vectra9.VERSION {
		return false
	}
	s.msize = min(s.msize, answer.msize)
	return true
}
