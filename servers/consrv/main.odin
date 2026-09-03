/*
consrv -- the first server that waits on two things at once.

`ramfs` answers one pipe, and can, because files in memory never park. A
console server has the problem `docs/HANDOFF.md` kept on its list: the
keyboard and the clients both park a reader, and one thread cannot wait on
both. This is `rfork`'s answer, in the shape Plan 9 gives it. One process
becomes two sharing their data and bss, each parks on its own thing, and a
ring of bytes in the shared bss is the meeting point:

    the child    reads /dev/cons -- a device read that genuinely parks --
                 and pushes what arrives into the ring
    the parent   posts /srv/consrv and serves 9P; a read of /line drains
                 the ring

The ring is single-producer single-consumer on purpose: the child owns
`head`, the parent owns `tail`, and each advances its own counter only
after the bytes it covers are in place. Two writers would need a lock, and
ring 3 has no lock to give them yet.

A read of `/line` **parks now** until a byte arrives, which is what a read of
a device should do. It does not hold the connection while it waits, because
`serve_mux` hands it to a worker process of its own. The main loop reads the
next request at once, and a `getattr` or a walk from another client is
answered while the read is still parked. The wart this file owned for two
milestones -- a read of empty `/line` answering zero bytes, which a client
could not tell from an end of file -- is gone. See `sys/libuser/serve.odin`.

Three things the concurrency needs, and each is here. A worker per parked
read, forked `RFNOWAIT` so the kernel reaps it. A write lock, so a worker's
reply and the main loop's never interleave on the pipe. And a state lock,
because the fid table and the ring's consumer end are now touched by the main
loop and every worker at once. The ring's *producer* stays lockless: the
child is still the only writer of `head`.

Teardown is strictly child-first, and by note. A `Tremove` stops the serve
loop; the parent notes its reader -- parked deep in a device read, which is
exactly what the note was built to unwind -- collects the EINTR that says
the ending was asked for, and only then exits. The other order would orphan
the child: pids never reuse and nothing reparents, so a child that outlives
its parent is a leak the machine reports for ever.
*/
package consrv

import "base:intrinsics"
import "base:runtime"

import "vsys:abi"
import "vsys:libuser"
import "vsys:vectra9"

NODE_ROOT :: i32(0)
NODE_LINE :: i32(1)

// The meeting point: bytes from the keyboard, waiting to be served. The
// counters are monotonic and the difference is the content, so full and
// empty cannot be confused. Shared under RFMEM, like every global here.
RING :: 256
ring_store: [RING]u8
ring: libuser.Ring

// The child's read buffer. In the shared bss like everything else, and
// touched by the child alone -- the stack would be private, but a buffer a
// syscall fills is clearer with a name.
chunk: [64]u8



fids: libuser.Fid_Table

FRAME :: 1200
frame_in: [FRAME]u8
frame_out: [FRAME]u8
payload: [1024]u8

/*
The two locks and the shutdown flag, all in shared bss.

`wlock` serialises pipe writes, held only for the length of a write.
`state_lock` guards the ring's consumer end, held only for a drain and never
across the poll a parked read spins on. The fid table carries its own lock now,
in `libuser.Fid_Table`. `stopping` is set at teardown so a worker parked on an
empty ring leaves instead of polling for a byte that will never come.
*/
wlock: libuser.Spin
state_lock: libuser.Spin
stopping: bool

/*
The worker pool: three parked reads at once, and a fourth stalls the loop.

The same bound `kernel/devfs` documents for its four threads, moved to
userland and raised by adding a slot rather than a thread. Three is enough
for a console, where one client reads `/line` at a time. Each slot carries
its own request, reply and payload buffers, because a worker reads and writes
them while the main loop and other workers use theirs.
*/
SLOTS :: 3
slot_frame: [SLOTS][FRAME]u8
slot_out: [SLOTS][FRAME]u8
slot_payload: [SLOTS][1024]u8
slots: [SLOTS]libuser.Mux_Slot

// The serve loop's state, in shared bss rather than on `_start`'s stack, so a
// worker can ask `libuser.flushed` through it. Its stack is its own copy.
mux: libuser.Mux

// How long a parked read sleeps between looks at the ring. One tick, which is
// the console's own poll cadence. A worker off every run queue in between.
POLL_TICKS :: 1

/*
_start opens the console, forks the reader, and serves.

The open comes first because the descriptor table is shared by default: one
open, and both processes hold the number. The child never returns from
`reader` -- its whole life is the read loop -- and the parent never reads
the console at all.
*/
@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	_ = block
	context = {}
	#force_no_inline runtime._startup_runtime()

	// The ring's frame, built before the fork so both halves hold it.
	ring = libuser.Ring{buf = ring_store[:]}

	cons := libuser.open("/dev/cons", abi.O_RDONLY)
	if cons < 0 {
		libuser.exit(0x74)
	}

	pid := libuser.rfork(abi.RFPROC | abi.RFMEM)
	if pid < 0 {
		libuser.exit(0x73)
	}
	if pid == 0 {
		reader(int(cons))
	}

	fd, perr := libuser.post("/srv/consrv")
	if perr < 0 {
		_ = libuser.stop_child(u64(pid))
		libuser.exit(0x71)
	}

	for i in 0 ..< SLOTS {
		slots[i] = libuser.Mux_Slot {
			frame   = slot_frame[i][:],
			out     = slot_out[i][:],
			payload = slot_payload[i][:],
		}
	}
	mux = libuser.Mux {
		fd      = fd,
		handler = handler,
		blocks  = blocks,
		frame   = frame_in[:],
		out     = frame_out[:],
		payload = payload[:],
		wlock   = &wlock,
		slots   = slots[:],
	}

	_, why := libuser.serve_mux(&mux)

	// The stop is set for whatever workers are still parked on the ring, so
	// they leave rather than poll for a byte the torn-down console cannot
	// send. See `handler`'s Tread case.
	intrinsics.volatile_store(&stopping, true)

	if why != .Removed {
		_ = libuser.stop_child(u64(pid))
		libuser.exit(0x72)
	}
	// Status zero is the whole teardown arc succeeding: the note landed, the
	// parked read unwound, and the wait heard EINTR -- the kernel's word for
	// an ending this parent asked for.
	libuser.exit(libuser.stop_child(u64(pid)) ? 0 : 0x75)
}

/*
blocks reports whether a request might park, which is the one thing the
serve loop cannot work out for itself.

Only a read of `/line` parks. A read of the root is EISDIR at once, and every
other message is a table lookup. So the loop forks a worker for exactly the
reads that wait for a keystroke, and answers the rest inline.
*/
blocks :: proc "contextless" (state: rawptr, request: ^vectra9.Msg) -> bool {
	_ = state
	#partial switch m in request^ {
	case vectra9.Tread:
		return libuser.fid_lookup(&fids, m.fid) == NODE_LINE
	}
	return false
}

/*
reader is the child's whole life: park on the keyboard, publish what comes.

A failed read is not a loop to break out of. A noted process's read answers
EINTR, and its next system call is the boundary the note ends it at -- so
asking again *is* the teardown protocol, not a bug's retry.
*/
reader :: proc "contextless" (cons: int) -> ! {
	for {
		n := libuser.read(cons, chunk[:])
		if n <= 0 {
			continue
		}
		for i in 0 ..< int(n) {
			libuser.ring_push(&ring, chunk[i])
		}
	}
}

// -- Fids, the same sixteen slots ramfs keeps ---------------------------------


// -- The tree ----------------------------------------------------------------

qid_of :: proc "contextless" (node: i32) -> vectra9.Qid {
	kind: vectra9.Qid_Flags
	if node == NODE_ROOT {
		kind = {.Dir}
	}
	return vectra9.Qid{kind = kind, path = u64(node) + 1}
}

step :: proc "contextless" (from: i32, name: string) -> i32 {
	switch name {
	case ".":
		return from
	case "..":
		return NODE_ROOT
	}
	if from == NODE_ROOT && name == "line" {
		return NODE_LINE
	}
	return -1
}

// -- The handler -------------------------------------------------------------

handler :: proc "contextless" (
	state: rawptr,
	s: ^vectra9.Session,
	tag: vectra9.Tag,
	request: ^vectra9.Msg,
	reply: ^vectra9.Msg,
	buf: []u8,
) #no_bounds_check {
	_ = state
	_ = s

	if !libuser.default_reply(request, reply) {
		return
	}

	#partial switch m in request^ {
	case vectra9.Tversion:
		vectra9.version_reply(m, reply, FRAME)

	case vectra9.Tattach:
		libuser.attach(&fids, m, reply, NODE_ROOT, qid_of)

	case vectra9.Twalk:
		libuser.walk(&fids, m, reply, step, qid_of)

	case vectra9.Tlopen:
		node, ok := libuser.node_of(&fids, m.fid, reply)
		if !ok {
			return
		}
		libuser.fid_open(&fids, m.fid)
		reply^ = vectra9.Rlopen{qid = qid_of(node), iounit = 0}

	case vectra9.Tread:
		node, ok := libuser.open_node(&fids, m.fid, reply)
		if !ok {
			return
		}
		if node == NODE_ROOT {
			reply^ = vectra9.error_reply(vectra9.EISDIR)
			return
		}
		/*
		A read of `/line` parks until a byte arrives, which is what a read of
		a device does. This runs in a worker, so parking here holds no other
		client -- the whole point of `serve_mux`. The offset is ignored: this
		file is what has arrived, and a drain consumes it.

		Three ways out besides a byte. A flush, when the client gave up on this
		read: the worker leaves and its answer is never sent, which is
		`libuser.flushed`'s contract. The shutdown flag, set at teardown, lets
		a parked read leave with an empty answer rather than poll for a byte
		the torn-down console will never send. And a zero `count`, which asks
		for nothing and gets it.
		*/
		room := min(len(buf), int(m.count))
		if room <= 0 {
			reply^ = vectra9.Rread{data = nil}
			return
		}
		for {
			// The flush is checked before the drain, and the order keeps a byte
			// from being lost to a flush that raced its arrival. A flushed
			// request's reply is dropped, so a drain into one would consume the
			// bytes and hand them to nobody. See `libuser.flushed`.
			if libuser.flushed(&mux, tag) {
				reply^ = vectra9.error_reply(vectra9.EINTR)
				return
			}
			got := libuser.ring_drain(&ring, buf[:room], &state_lock)
			if got > 0 {
				reply^ = vectra9.Rread{data = buf[:got]}
				return
			}
			if intrinsics.volatile_load(&stopping) {
				reply^ = vectra9.Rread{data = nil}
				return
			}
			_ = libuser.sleep(POLL_TICKS)
		}

	case vectra9.Twrite:
		reply^ = vectra9.error_reply(vectra9.EPERM)

	case vectra9.Treaddir:
		readdir(m, reply, buf)

	case vectra9.Tgetattr:
		node, ok := libuser.node_of(&fids, m.fid, reply)
		if !ok {
			return
		}
		dir := node == NODE_ROOT
		reply^ = vectra9.Rgetattr {
			valid   = m.request_mask & 0x000007FF,
			qid     = qid_of(node),
			mode    = dir ? 0o040555 : 0o100444,
			nlink   = dir ? 2 : 1,
			size    = dir ? 0 : libuser.ring_available(&ring),
			blksize = 512,
		}

	case vectra9.Tclunk:
		libuser.fid_release(&fids, m.fid)
		reply^ = vectra9.Rclunk{}

	case vectra9.Tremove:
		libuser.fid_release(&fids, m.fid)
		reply^ = vectra9.Rremove{}

	case vectra9.Tflush:
		_ = m
		reply^ = vectra9.Rflush{}
	}
}

readdir :: proc "contextless" (m: vectra9.Treaddir, reply: ^vectra9.Msg, buf: []u8) #no_bounds_check {
	node, ok := libuser.open_node(&fids, m.fid, reply)
	if !ok {
		return
	}
	if node != NODE_ROOT {
		reply^ = vectra9.error_reply(vectra9.ENOTDIR)
		return
	}

	room := min(len(buf), int(m.count))
	c := vectra9.cursor_from(buf[:room])
	if m.offset < 1 && vectra9.remaining(&c) >= vectra9.dirent_size("line") {
		vectra9.put_dirent(
			&c,
			vectra9.Dirent {
				qid = qid_of(NODE_LINE),
				offset = 1,
				type = vectra9.DT_REG,
				name = "line",
			},
		)
	}
	if c.err != .None {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}
	reply^ = vectra9.Rreaddir{data = vectra9.written(&c)}
}
