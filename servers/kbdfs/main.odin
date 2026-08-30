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

What crossed the privilege boundary is the state machine, byte for byte the
kernel's: the two US-layout tables, shift, caps, control, the extended
prefix, and the rule that a release makes no character. A scancode the kernel
would have turned into a byte on `/dev/cons` this program turns into a byte on
`/kbd`, and nothing but the address space it runs in is different.

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
ring: [RING]u8
head: u64
tail: u64

// The child's scancode buffer. In the shared bss with everything else, and
// touched by the child alone.
chunk: [64]u8

MAX_FIDS :: 16

Fid_Slot :: struct {
	fid:  vectra9.Fid,
	node: i32,
	used: bool,
}

fids: [MAX_FIDS]Fid_Slot

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
stopping: bool

SLOTS :: 3
slot_frame: [SLOTS][FRAME]u8
slot_out: [SLOTS][FRAME]u8
slot_payload: [SLOTS][1024]u8
slots: [SLOTS]libuser.Mux_Slot

// One tick between looks at the ring, for a read parked waiting on a key.
POLL_TICKS :: 1

/*
_start opens the raw stream, forks the translator, and serves.

The open comes first, because the descriptor table is shared by default: one
open, and both processes hold the number. Opening `/dev/scancode` is also what
diverts the raw scancodes to this program -- until something holds it open,
the kernel translates them itself. See `kernel/devfs/tap.odin`.
*/
@(export, link_name = "_start")
start :: proc "sysv" (data: uintptr, arg: u64, arg2: u64) {
	context = {}
	#force_no_inline runtime._startup_runtime()

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
		_ = stop_reader(u64(pid))
		libuser.exit(0x71)
	}

	for i in 0 ..< SLOTS {
		slots[i] = libuser.Mux_Slot {
			frame   = slot_frame[i][:],
			out     = slot_out[i][:],
			payload = slot_payload[i][:],
		}
	}
	mux := libuser.Mux {
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

	intrinsics.volatile_store(&stopping, true)

	if why != .Removed {
		_ = stop_reader(u64(pid))
		libuser.exit(0x72)
	}
	libuser.exit(stop_reader(u64(pid)) ? 0 : 0x75)
}

// blocks is true for exactly the read that waits on a key: a read of /kbd.
// Every other message is a table lookup, answered inline.
blocks :: proc "contextless" (state: rawptr, request: ^vectra9.Msg) -> bool {
	_ = state
	#partial switch m in request^ {
	case vectra9.Tread:
		return fid_lookup(m.fid) == NODE_KBD
	}
	return false
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
				push(b)
			}
		}
	}
}

// stop_reader notes the child out of its parked read and collects the EINTR
// that proves the ending was the one asked for.
stop_reader :: proc "contextless" (pid: u64) -> bool {
	if libuser.note(pid, "stop") != 0 {
		return false
	}
	return libuser.wait(pid) == -i64(vectra9.EINTR)
}

// -- The ring ----------------------------------------------------------------

// push is the producer's half: byte first, then the counter, so a consumer
// never sees a seat its byte has not taken. A full ring drops the character,
// which is what a translator with nowhere to put one does.
push :: proc "contextless" (b: u8) #no_bounds_check {
	h := intrinsics.volatile_load(&head)
	t := intrinsics.volatile_load(&tail)
	if h - t >= RING {
		return
	}
	ring[h % RING] = b
	intrinsics.volatile_store(&head, h + 1)
}

// drain is the consumer's half, under `state_lock` because `serve_mux` gives
// the ring many readers. Only the byte-moving is inside the lock.
drain :: proc "contextless" (buf: []u8) -> int #no_bounds_check {
	libuser.lock(&state_lock)
	t := intrinsics.volatile_load(&tail)
	h := intrinsics.volatile_load(&head)
	n := min(int(h - t), len(buf))
	for i in 0 ..< n {
		buf[i] = ring[(t + u64(i)) % RING]
	}
	intrinsics.volatile_store(&tail, t + u64(n))
	libuser.unlock(&state_lock)
	return n
}

available :: proc "contextless" () -> u64 {
	return intrinsics.volatile_load(&head) - intrinsics.volatile_load(&tail)
}

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

// -- Fids, the same sixteen slots consrv keeps, under the same lock -----------

fid_lookup :: proc "contextless" (fid: vectra9.Fid) -> i32 #no_bounds_check {
	libuser.lock(&state_lock)
	defer libuser.unlock(&state_lock)
	for i in 0 ..< MAX_FIDS {
		if fids[i].used && fids[i].fid == fid {
			return fids[i].node
		}
	}
	return -1
}

fid_bind :: proc "contextless" (fid: vectra9.Fid, node: i32) -> bool #no_bounds_check {
	libuser.lock(&state_lock)
	defer libuser.unlock(&state_lock)
	for i in 0 ..< MAX_FIDS {
		if fids[i].used && fids[i].fid == fid {
			fids[i].node = node
			return true
		}
	}
	for i in 0 ..< MAX_FIDS {
		if !fids[i].used {
			fids[i] = Fid_Slot{fid = fid, node = node, used = true}
			return true
		}
	}
	return false
}

fid_release :: proc "contextless" (fid: vectra9.Fid) #no_bounds_check {
	libuser.lock(&state_lock)
	defer libuser.unlock(&state_lock)
	for i in 0 ..< MAX_FIDS {
		if fids[i].used && fids[i].fid == fid {
			fids[i] = Fid_Slot{}
			return
		}
	}
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
	_ = tag

	if vectra9.creates(vectra9.kind(request^)) {
		reply^ = vectra9.error_reply(vectra9.EPERM)
		return
	}
	reply^ = vectra9.error_reply(vectra9.EOPNOTSUPP)

	#partial switch m in request^ {
	case vectra9.Tversion:
		if m.version != vectra9.VERSION {
			reply^ = vectra9.Rversion{msize = m.msize, version = "unknown"}
			return
		}
		reply^ = vectra9.Rversion{msize = min(m.msize, FRAME), version = vectra9.VERSION}

	case vectra9.Tattach:
		if !fid_bind(m.fid, NODE_ROOT) {
			reply^ = vectra9.error_reply(vectra9.ENFILE)
			return
		}
		reply^ = vectra9.Rattach{qid = qid_of(NODE_ROOT)}

	case vectra9.Twalk:
		walk(m, reply)

	case vectra9.Tlopen:
		node := fid_lookup(m.fid)
		if node < 0 {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		reply^ = vectra9.Rlopen{qid = qid_of(node), iounit = 0}

	case vectra9.Tread:
		node := fid_lookup(m.fid)
		if node < 0 {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		if node == NODE_ROOT {
			reply^ = vectra9.error_reply(vectra9.EISDIR)
			return
		}
		/*
		A read of /kbd parks until a key is translated, off in a worker of its
		own -- `blocks` sent it here. The shutdown flag lets a parked read leave
		at teardown rather than poll for a key the torn-down keyboard will never
		send. A zero count asks for nothing and gets it.
		*/
		room := min(len(buf), int(m.count))
		if room <= 0 {
			reply^ = vectra9.Rread{data = nil}
			return
		}
		for {
			got := drain(buf[:room])
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
		node := fid_lookup(m.fid)
		if node < 0 {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		dir := node == NODE_ROOT
		reply^ = vectra9.Rgetattr {
			valid   = m.request_mask & 0x000007FF,
			qid     = qid_of(node),
			mode    = dir ? 0o040555 : 0o100444,
			nlink   = dir ? 2 : 1,
			size    = dir ? 0 : available(),
			blksize = 512,
		}

	case vectra9.Tclunk:
		fid_release(m.fid)
		reply^ = vectra9.Rclunk{}

	case vectra9.Tremove:
		fid_release(m.fid)
		reply^ = vectra9.Rremove{}

	case vectra9.Tflush:
		_ = m
		reply^ = vectra9.Rflush{}
	}
}

walk :: proc "contextless" (m: vectra9.Twalk, reply: ^vectra9.Msg) #no_bounds_check {
	from := fid_lookup(m.fid)
	if from < 0 {
		reply^ = vectra9.error_reply(vectra9.EBADF)
		return
	}

	answer: vectra9.Rwalk
	cur := from
	for i in 0 ..< m.count {
		next := step_name(cur, m.names[i])
		if next < 0 {
			if i == 0 {
				reply^ = vectra9.error_reply(vectra9.ENOENT)
				return
			}
			break
		}
		cur = next
		answer.qids[answer.count] = qid_of(cur)
		answer.count += 1
	}

	if answer.count == m.count {
		if !fid_bind(m.newfid, cur) {
			reply^ = vectra9.error_reply(vectra9.ENFILE)
			return
		}
	}
	reply^ = answer
}

readdir :: proc "contextless" (m: vectra9.Treaddir, reply: ^vectra9.Msg, buf: []u8) #no_bounds_check {
	node := fid_lookup(m.fid)
	if node < 0 {
		reply^ = vectra9.error_reply(vectra9.EBADF)
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
