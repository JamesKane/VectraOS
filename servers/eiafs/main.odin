/*
eiafs -- the serial port, served from ring 3.

`kbdfs` proved a kernel driver can stand one privilege level out: raw
scancodes in, a translation, characters served on a file. The port asks a
smaller and a larger question at once. Smaller, because serial bytes need
no translation -- what arrives on the wire is already the content, so the
child pushes what it reads and nothing more. Larger, because `/dev/eia0`
is the first raw device a program may also *write*. So this is the first
userland server whose `Twrite` reaches hardware: a write to the served
file goes down the shared descriptor and out the wire.

The shape is `consrv`'s, byte for byte where it can be:

    the child    reads /dev/eia0 -- a device read that genuinely parks --
                 and pushes what arrives into the ring
    the parent   posts /srv/eiafs and serves 9P; a read of /eia0 drains
                 the ring, and a write of /eia0 goes out the wire

The open takes `O_RDWR` and comes before the fork, so both halves hold
the one descriptor: the child reads it for its whole life, and the
parent's handler writes it. A write never parks -- the UART takes bytes
as fast as its FIFO drains -- so the serve loop answers a `Twrite`
inline, and only a read of `/eia0` goes to a worker.

Two properties of the wire are the kernel's, not this server's, and a
client should know both. The device expands LF to CRLF on the way out,
so a byte stream through `/eia0` is a terminal's, not a modem's. And the
kernel log writes the same wire unserialised -- the ordering of a log
line against a served write is undefined, which `kernel/devfs` documents
as the deliberate cost of a log that cannot park.

Teardown is strictly child-first, and by note, exactly as `consrv` does
it. A `Tremove` stops the serve loop; the parent notes its reader out of
the parked device read, collects the EINTR that says the ending was
asked for, and only then exits.
*/
package eiafs

import "base:intrinsics"
import "base:runtime"

import "vsys:abi"
import "vsys:libuser"
import "vsys:vectra9"

NODE_ROOT :: i32(0)
NODE_EIA :: i32(1)

// The meeting point: bytes off the wire, waiting to be served. The
// counters are monotonic and the difference is the content, so full and
// empty cannot be confused. Shared under RFMEM, like every global here.
RING :: 256
ring_store: [RING]u8
ring: libuser.Ring

// The child's read buffer. In the shared bss like everything else, and
// touched by the child alone -- the stack would be private, but a buffer a
// syscall fills is clearer with a name.
chunk: [64]u8

// The device descriptor, shared by the fork. The child reads it, and the
// parent's Twrite case writes it. Neither half closes it -- the process
// exit is the close.
eia_fd: int



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
for a port, where one client reads `/eia0` at a time. Each slot carries
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
// the port poller's own cadence. A worker off every run queue in between.
POLL_TICKS :: 1

/*
_start opens the port, forks the reader, and serves.

The open comes first because the descriptor table is shared by default: one
open, and both processes hold the number. It takes `O_RDWR` because the two
halves want different directions -- the child reads the descriptor for its
whole life, and the parent writes it on a client's behalf. An open that
fails is also the portless machine: a port that failed its probe answers
ENXIO, and this server has nothing to serve.
*/
@(export, link_name = "_start")
start :: proc "sysv" (data: uintptr, arg: u64, arg2: u64) {
	context = {}
	#force_no_inline runtime._startup_runtime()

	// The ring's frame, built before the fork so both halves hold it.
	ring = libuser.Ring{buf = ring_store[:]}

	fd := libuser.open("/dev/eia0", abi.O_RDWR)
	if fd < 0 {
		libuser.exit(0x74)
	}
	eia_fd = int(fd)

	pid := libuser.rfork(abi.RFPROC | abi.RFMEM)
	if pid < 0 {
		libuser.exit(0x73)
	}
	if pid == 0 {
		reader(eia_fd)
	}

	sfd, perr := libuser.post("/srv/eiafs")
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
		fd      = sfd,
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
	// they leave rather than poll for a byte the released port cannot
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

Only a read of `/eia0` parks. A write goes straight to the device and comes
back -- the UART takes bytes at its own pace and never holds the caller
across a wait the scheduler can see. So the loop forks a worker for exactly
the reads that wait for the wire, and answers the rest inline.
*/
blocks :: proc "contextless" (state: rawptr, request: ^vectra9.Msg) -> bool {
	_ = state
	#partial switch m in request^ {
	case vectra9.Tread:
		return libuser.fid_lookup(&fids, m.fid) == NODE_EIA
	}
	return false
}

/*
reader is the child's whole life: park on the port, publish what comes.

A failed read is not a loop to break out of. A noted process's read answers
EINTR, and its next system call is the boundary the note ends it at -- so
asking again *is* the teardown protocol, not a bug's retry.
*/
reader :: proc "contextless" (port: int) -> ! {
	for {
		n := libuser.read(port, chunk[:])
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
	if from == NODE_ROOT && name == "eia0" {
		return NODE_EIA
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
		A read of `/eia0` parks until a byte arrives, which is what a read of
		a device does. This runs in a worker, so parking here holds no other
		client -- the whole point of `serve_mux`. The offset is ignored: this
		file is what has arrived, and a drain consumes it.

		Three ways out besides a byte. A flush, when the client gave up on this
		read: the worker leaves and its answer is never sent, which is
		`libuser.flushed`'s contract. The shutdown flag, set at teardown, lets
		a parked read leave with an empty answer rather than poll for a byte
		the released port will never send. And a zero `count`, which asks
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
		/*
		The half neither `consrv` nor `kbdfs` has: a write that reaches
		hardware. The bytes go down the shared descriptor and out the wire,
		on the serve loop itself -- the device takes a write without parking,
		so no worker is spent on it. The device's count is the answer, and a
		device error is the client's error.
		*/
		node, ok := libuser.node_of(&fids, m.fid, reply)
		if !ok {
			return
		}
		if node == NODE_ROOT {
			reply^ = vectra9.error_reply(vectra9.EISDIR)
			return
		}
		n := libuser.write(eia_fd, m.data)
		if n < 0 {
			reply^ = vectra9.error_reply(vectra9.Errno(u32(-n)))
			return
		}
		reply^ = vectra9.Rwrite{count = u32(n)}

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
			mode    = dir ? 0o040555 : 0o100666,
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
	if m.offset < 1 && vectra9.remaining(&c) >= vectra9.dirent_size("eia0") {
		vectra9.put_dirent(
			&c,
			vectra9.Dirent {
				qid = qid_of(NODE_EIA),
				offset = 1,
				type = vectra9.DT_REG,
				name = "eia0",
			},
		)
	}
	if c.err != .None {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}
	reply^ = vectra9.Rreaddir{data = vectra9.written(&c)}
}
