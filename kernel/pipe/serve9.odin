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

## What is pinned, and what releases it

A successful build pins three things: the wire and its arena, the server
record, and one reference on the posted chan. The reference is the
load-bearing one. Removing a `/srv` name closes the entry's chan. Without
this reference, that close would reach the pipe and poison the wire under
every existing mount. Plan 9's rule is that removal does not stop a
service, and the reference is what keeps it here.

**The pin is counted now, and the count is the `Server`'s.** `kernel/vfs`
counts every live chan on the server, and `pins` carries the two stakes
that are not chans. One is the `/srv` name's, taken at the build. The other
is a mount still being built, taken by `server_for` for its caller. When
the last mount is gone and the name is gone, both counts are zero, and
`wire_release` runs on whichever thread dropped the last piece.

The release is the hang-up. Closing the pinned chan clunks the posted end,
which ends both flows. The far process's next read answers zero bytes, and
`libuser.serve` returns `.Hangup`. A server that outlives its last client
ends through its own front door, with no note needed. The wire's reader
sees the same EOF and leaves, `wire_join` collects it, and everything the
build allocated goes back to the heap. The pipe's slot goes back last of
all, through `unpin` after the join, because the reader the close wakes has
to have left before the slot is zeroed. `reclaim` in `pipe.odin` owns that
argument.

A revived server is the race worth naming. Between the decision to fire
and the release's own lock, a new mount of a still-posted name can pin the
server back. The release re-checks under `Pipe_Table.build`, which every
build and reuse also holds, and walks away if anything took a stake. See
`vfs.server_release_confirm`.
*/
package pipe

import "kernel:mnt"
import "kernel:sync"
import "kernel:vfs"
import "vsys:vectra9"

// Bytes for the wire's arena: one reply buffer per request slot plus the
// transmit buffer. What one slot holds becomes the connection's msize. The
// slot size is the protocol's `WIRE_SLOT`, so a ring 3 client sizes its
// writes by the number this arena is cut from.
@(private = "file")
WIRE_ARENA :: vectra9.WIRE_SLOT * (mnt.MAX_REQUESTS + 1)

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
		if wired_end != end {
			return nil
		}
		// The caller's stake, released by `srv.mount` once the attach holds
		// chans of its own. It is what stops a racing removal from tearing
		// the wire down under the mount that just found it.
		vfs.server_pin(existing)
		return existing
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
		and `wire_join` is what makes the frees below safe. The pin goes on
		first, for the reason `wire_release` gives: a far side that already
		went would make this close the last, and the slot must outlive the
		reader parked on it.
		*/
		g3 := sync.acquire(&t.lock)
		p.server9 = sv
		sync.release(&t.lock, g3)
		close_end(p, end)
		mnt.wire_join(w)
		unpin(p)
		free(we)
		delete(arena)
		free(w)
		free(sv)
		return nil
	}

	/*
	The hook and the stakes go on before the server is findable. No drop to
	zero can then miss the hook, and no concurrent drop can fire it early.
	Two stakes: the /srv name's, released by `unpost` when the name goes,
	and the calling mount's, released by `srv.mount` after its attach. No
	lock, because nothing can reach `sv` yet.
	*/
	sv.release = wire_release
	sv.pins = 2

	g2 := sync.acquire(&t.lock)
	p.server9 = sv
	p.wire_end = end
	p.wire_arena = arena
	// The pin described in the file comment. Without this reference, removing
	// the /srv name would close the chan and the close would reach the pipe.
	// The wire would then poison under every mount the removal was not allowed
	// to stop. `wire_release` is what closes it, last of all.
	p.pinned = vfs.chan_incref(c)
	p.staked = true
	sync.release(&t.lock, g2)
	return sv
}

/*
unpost takes the `/srv` name's stake off a posted pipe's connection, and
hands the caller the server to drop it on.

`kernel/srv` calls this when a name is removed, with the entry's chan still
referenced and no lock of its own held. Nil for a chan that is not a wired
pipe end, or for a connection whose stake already went. Two names can post
one chan, and the first removal spends the only stake. The document calls
that edge by name.

**The caller closes its chan before it drops the stake, which is the first
of the three parks.** The stake's drop may be the last one, and the release
it fires hangs the connection up by closing the pinned chan. That close is
the last reference on the posted end only if the remover's own reference is
already gone. 
`unpost` used to drop the stake itself, with the entry's chan still held by
the thread it ran on. The end stayed open and the wire's reader stayed
parked on it. `wire_join` parked for ever holding `Pipe_Table.build`, with
every later mount of a pipe behind it.

So this returns the server, the caller closes what it holds, and then calls
`vfs.server_unpin`, outside every lock because the release takes `build`.
*/
unpost :: proc(c: ^vfs.Chan) -> ^vfs.Server {
	t := &pipes
	p, end := chan_pipe(c)
	if p == nil {
		return nil
	}

	sv: ^vfs.Server
	g := sync.acquire(&t.lock)
	if live(p) && u64(node_of(p.id, end)) == c.qid.path &&
	   p.server9 != nil && p.wire_end == end && p.staked {
		p.staked = false
		sv = p.server9
	}
	sync.release(&t.lock, g)
	return sv
}

/*
wire_release gives back everything `server_for` built, and is the counted
release the handoff promised.

Runs on whichever thread dropped the server's last chan or last pin --
an unmount, a process teardown, a failed mount, a removal. All of those are
contexts where a message may park, and this parks twice: once to hang up,
once to join the reader.

`build` serialises this against a build or a reuse, and the confirm is what
makes the race with a reviving mount safe. Everything after the confirm is
single-handed: the server is unfindable the moment `staked` clears, so
nothing can take a new stake on it.
*/
@(private = "file")
wire_release :: proc(sv: ^vfs.Server) {
	t := &pipes
	sync.mutex_lock(&t.build)

	g := sync.acquire(&t.lock)
	p: ^Pipe
	for i in 0 ..< MAX_PIPES {
		if t.table[i].server9 == sv {
			p = &t.table[i]
			break
		}
	}
	if p == nil {
		// Released already, by whoever beat this thread to `build`. The
		// pointer was compared and never followed.
		sync.release(&t.lock, g)
		sync.mutex_unlock(&t.build)
		return
	}
	sync.release(&t.lock, g)

	if !vfs.server_release_confirm(sv) {
		// A mount revived the server between the fire decision and here.
		// The confirm cleared the once-guard, and a later last-drop decides
		// again.
		sync.mutex_unlock(&t.build)
		return
	}

	g2 := sync.acquire(&t.lock)
	w := cast(^mnt.Wire)sv.session.transport.data
	arena := p.wire_arena
	pinned := p.pinned
	p.wire_end = 0
	p.wire_arena = nil
	p.pinned = nil
	p.staked = false
	sync.release(&t.lock, g2)

	/*
	The hang-up, through the front door. The last reference on the posted
	end clunks it, and both flows end. Two readers notice: the far process
	answers zero bytes out of its serve loop, and the wire's own reader
	leaves.

	`server9` stays set across the close, because it is what keeps
	`close_end` from reclaiming the slot. The wire's reader is parked on
	this end, the close is what wakes it, and it re-reads the pipe's flags
	only when it next runs. This used to clear the pin first, so a far side
	that was already gone made this close the last one and the slot was
	zeroed under the reader. It woke to a pipe that looked open, parked
	again on a slot that no longer existed, and `wire_join` parked behind
	it for ever -- one boot in forty, at the draw server's teardown. `unpin`
	reclaims after the join, when there is nobody left to wake.
	*/
	vfs.chan_close(pinned)
	mnt.wire_join(w)
	unpin(p)

	we := cast(^Wire_End)w.io.data
	free(we)
	delete(arena)
	free(w)
	free(sv)

	sync.mutex_unlock(&t.build)
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
