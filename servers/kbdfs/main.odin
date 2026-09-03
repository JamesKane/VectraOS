/*
kbdfs -- a kernel service, rebuilt as a program.

`kernel/drivers/kbd` translates scancodes to characters inside the kernel.
This is that translation moved to ring 3, over the raw stream `/dev/scancode`
serves. It is the first tenant of the userland devfs the handoff pointed at:
a driver that reads a raw device, does its own translation, and serves the
cooked result back as a file its clients mount.

The shape is `consrv`'s, because the problem is the same one. A reader child
parks on a device that genuinely blocks, and the parent serves 9P. The two
meet in a shared ring, and `serve_mux` lets a read of the cooked file park in
a worker while the parent answers other clients.

    the child    reads /dev/scancode -- raw make and break codes -- runs the
                 scancode state machine, and pushes the characters it makes
    the parent   posts /srv/kbdfs and serves 9P; a read of /kbd drains the
                 ring, parking until a key is translated

What crossed the privilege boundary is the state machine: the two US-layout
tables, shift, caps, control, the extended prefix, and the rule that a release
makes no character.

**It was the kernel's byte for byte and now it is not.** `kernel/drivers/kbd`
answers a *rune* for the extended keys -- an arrow is `KF|0x11`, encoded as
UTF-8 into the byte sink, see `sys/libkey` -- and this copy still drops them
the way both did before. So a program reading `/kbd` gets no arrow keys, and
one reading `/dev/cons` does.

Nothing consumes `/kbd` for them yet, which is why this is written down rather
than fixed. The fix is not a second copy of the new table: it is the scancode
translation becoming a package both rings call, which is what having two of it
has been asking for since this file was written.

Teardown is `consrv`'s: on `Tremove` the parent notes its reader out of the
parked scancode read, collects the EINTR, and exits zero only if it heard it.
*/
package kbdfs

import "base:intrinsics"
import "base:runtime"

import "vsys:abi"
import "vsys:libuser"
import "vsys:vectra9"

NODE_ROOT :: i32(0)
NODE_KBD :: i32(1)

// The translated characters waiting to be served, a producer-consumer ring
// shared under RFMEM. The child owns `head`, the consumers own `tail`, and
// the counters are monotonic so full and empty never look alike.
RING :: 256
ring_store: [RING]u8
ring: libuser.Ring

// The child's scancode buffer. In the shared bss with everything else, and
// touched by the child alone.
chunk: [64]u8



fids: libuser.Fid_Table

FRAME :: 1200
frame_in: [FRAME]u8
frame_out: [FRAME]u8
payload: [1024]u8

// The write lock `serve_mux` serialises replies with, and a state lock over
// the fid table and the ring's consumer end. `stopping` releases a worker
// parked on an empty ring at teardown. See `servers/consrv` and
// `sys/libuser/serve.odin`.
wlock: libuser.Spin
state_lock: libuser.Spin

SLOTS :: 3
slot_frame: [SLOTS][FRAME]u8
slot_out: [SLOTS][FRAME]u8
slot_payload: [SLOTS][1024]u8
slots: [SLOTS]libuser.Mux_Slot

// The serve loop's state, in shared bss rather than on `_start`'s stack, so a
// worker can ask `libuser.flushed` through it. Its stack is its own copy.
mux: libuser.Mux

// One tick between looks at the ring, for a read parked waiting on a key.

/*
_start opens the raw stream, forks the translator, and serves.

The open comes first, because the descriptor table is shared by default: one
open, and both processes hold the number. Opening `/dev/scancode` is also what
diverts the raw scancodes to this program -- until something holds it open,
the kernel translates them itself. See `kernel/devfs/tap.odin`.
*/
@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	_ = block
	context = {}
	#force_no_inline runtime._startup_runtime()

	// The ring's frame, built before the fork so both halves hold it.
	ring = libuser.Ring{buf = ring_store[:]}

	raw := libuser.open("/dev/scancode", abi.O_RDONLY)
	if raw < 0 {
		libuser.exit(0x74)
	}

	pid := libuser.rfork(abi.RFPROC | abi.RFMEM)
	if pid < 0 {
		libuser.exit(0x73)
	}
	if pid == 0 {
		reader(int(raw))
	}

	fd, perr := libuser.post("/srv/kbdfs")
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
		frame   = frame_in[:],
		out     = frame_out[:],
		payload = payload[:],
		wlock   = &wlock,
		slots   = slots[:],
	}

	_, why := libuser.serve_mux(&mux)

	libuser.respond_all(&mux, vectra9.Rread{data = nil})

	if why != .Removed {
		_ = libuser.stop_child(u64(pid))
		libuser.exit(0x72)
	}
	libuser.exit(libuser.stop_child(u64(pid)) ? 0 : 0x75)
}

/*
reader is the child's whole life: read scancodes, translate, publish.

A failed read is not a loop to break out of. A noted process's read answers
EINTR, and its next system call is the boundary the note ends it at, so asking
again *is* the teardown protocol. `consrv`'s reader has the same shape, over a
different device.
*/
reader :: proc "contextless" (raw: int) -> ! {
	for {
		n := libuser.read(raw, chunk[:])
		if n <= 0 {
			continue
		}
		for i in 0 ..< int(n) {
			b, produced := step(chunk[i])
			if produced {
				libuser.ring_push(&ring, b)
			}
		}
		answer_held()
	}
}

// wants_read is what a held request has to be for the reader to answer it:
// a read of the file the ring feeds.
wants_read :: proc "contextless" (state: rawptr, request: ^vectra9.Msg) -> bool {
	_ = state
	#partial switch m in request^ {
	case vectra9.Tread:
		return libuser.fid_lookup(&fids, m.fid) == NODE_KBD
	}
	return false
}

/*
answer_held gives what the ring holds to the reads held for it, oldest
first, from the reader's own process. Under `wlock`, which is what makes
this and the handler's "empty, hold me" one decision: either the handler
saw the byte, or this sees the held read. See `libuser.serve_mux`.
*/
answer_held :: proc "contextless" () {
	libuser.lock(&wlock)
	for {
		slot, tag, request, ok := libuser.held(&mux, wants_read)
		if !ok {
			break
		}
		m := request.(vectra9.Tread)
		buf := libuser.slot_payload(&mux, slot)
		room := min(len(buf), int(m.count))
		got := libuser.ring_drain(&ring, buf[:room], &state_lock)
		if got == 0 {
			break
		}
		_ = libuser.respond(&mux, slot, tag, vectra9.Rread{data = buf[:got]})
	}
	libuser.unlock(&wlock)
}

// -- The ring ----------------------------------------------------------------

// -- The scancode state machine, the kernel's byte for byte -------------------
//
// `kernel/drivers/kbd` owns the reasoning behind every line here. This is the
// same translation, in the address space of a program rather than the kernel.

SC_EXTENDED :: u8(0xE0)
SC_RELEASE :: u8(0x80)
SC_LSHIFT :: u8(0x2A)
SC_RSHIFT :: u8(0x36)
SC_CTRL :: u8(0x1D)
SC_CAPS :: u8(0x3A)

// The keyboard as positions, unshifted and shifted. Two tables and no rule,
// because `2` shifts to `@` and only a picture of the keyboard predicts it.
// The first initialised tables a program in this tree carries: the compiler
// puts their bytes in the image, and the loader maps them, so a program can
// read a static array as readily as the kernel does.
PLAIN := [0x40]u8 {
	0, 0, '1', '2', '3', '4', '5', '6',
	'7', '8', '9', '0', '-', '=', '\b', '\t',
	'q', 'w', 'e', 'r', 't', 'y', 'u', 'i',
	'o', 'p', '[', ']', '\n', 0, 'a', 's',
	'd', 'f', 'g', 'h', 'j', 'k', 'l', ';',
	'\'', '`', 0, '\\', 'z', 'x', 'c', 'v',
	'b', 'n', 'm', ',', '.', '/', 0, '*',
	0, ' ', 0, 0, 0, 0, 0, 0,
}

SHIFTED := [0x40]u8 {
	0, 0, '!', '@', '#', '$', '%', '^',
	'&', '*', '(', ')', '_', '+', '\b', '\t',
	'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I',
	'O', 'P', '{', '}', '\n', 0, 'A', 'S',
	'D', 'F', 'G', 'H', 'J', 'K', 'L', ':',
	'"', '~', 0, '|', 'Z', 'X', 'C', 'V',
	'B', 'N', 'M', '<', '>', '?', 0, '*',
	0, ' ', 0, 0, 0, 0, 0, 0,
}

// The modifier state. Owned by the child alone, so it needs no lock.
shift: bool
caps: bool
ctrl: bool
extended: bool

/*
step advances the modifier state and reports the byte a scancode produced.

`false` is the common case: a release, a modifier in either direction, the
extended prefix, or a position with no character on it. The one difference
from the kernel's is where the state lives -- three package globals rather
than a `Keyboard` struct -- because a program that is only ever one keyboard
needs no handle to it.
*/
step :: proc "contextless" (code: u8) -> (b: u8, produced: bool) #no_bounds_check {
	if code == SC_EXTENDED {
		extended = true
		return 0, false
	}

	was_extended := extended
	extended = false

	released := code & SC_RELEASE != 0
	make_code := code &~ SC_RELEASE

	switch make_code {
	case SC_LSHIFT, SC_RSHIFT:
		shift = !released
		return 0, false
	case SC_CTRL:
		ctrl = !released
		return 0, false
	case SC_CAPS:
		if !released {
			caps = !caps
		}
		return 0, false
	}

	if released || was_extended || int(make_code) >= len(PLAIN) {
		return 0, false
	}

	b = shift ? SHIFTED[make_code] : PLAIN[make_code]
	if b == 0 {
		return 0, false
	}

	// Caps lock is not another shift: it flips the case of a letter, after
	// the table has already answered, and touches nothing else.
	if caps {
		if b >= 'a' && b <= 'z' {
			b -= 32
		} else if b >= 'A' && b <= 'Z' {
			b += 32
		}
	}

	// Control makes a letter the control character at the same position, `^A`
	// through `^Z`, which is what makes a typed `^D` reach a line discipline.
	if ctrl {
		u := b
		if u >= 'a' && u <= 'z' {
			u -= 32
		}
		if u >= 'A' && u <= 'Z' {
			return u - 'A' + 1, true
		}
		return 0, false
	}
	return b, true
}


// -- The tree ----------------------------------------------------------------

qid_of :: proc "contextless" (node: i32) -> vectra9.Qid {
	kind: vectra9.Qid_Flags
	if node == NODE_ROOT {
		kind = {.Dir}
	}
	return vectra9.Qid{kind = kind, path = u64(node) + 1}
}

step_name :: proc "contextless" (from: i32, name: string) -> i32 {
	switch name {
	case ".":
		return from
	case "..":
		return NODE_ROOT
	}
	if from == NODE_ROOT && name == "kbd" {
		return NODE_KBD
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
		libuser.walk(&fids, m, reply, step_name, qid_of)

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
		A read of /kbd parks until a key is translated, off in a worker of its
		own -- `blocks` sent it here. A flush, when the client gave up on the
		read, lets the worker leave with an answer nobody sends, which is
		`libuser.flushed`'s contract. The shutdown flag lets a parked read leave
		at teardown rather than poll for a key the torn-down keyboard will never
		send. A zero count asks for nothing and gets it.
		*/
		room := min(len(buf), int(m.count))
		if room <= 0 {
			reply^ = vectra9.Rread{data = nil}
			return
		}
		// What has arrived, or nothing yet: the loop holds the request and
		// the reader answers it when a byte comes. See `libuser.hold`.
		got := libuser.ring_drain(&ring, buf[:room], &state_lock)
		if got > 0 {
			reply^ = vectra9.Rread{data = buf[:got]}
			return
		}
		libuser.hold(&mux)

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
	if m.offset < 1 && vectra9.remaining(&c) >= vectra9.dirent_size("kbd") {
		vectra9.put_dirent(
			&c,
			vectra9.Dirent {
				qid = qid_of(NODE_KBD),
				offset = 1,
				type = vectra9.DT_REG,
				name = "kbd",
			},
		)
	}
	if c.err != .None {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}
	reply^ = vectra9.Rreaddir{data = vectra9.written(&c)}
}
