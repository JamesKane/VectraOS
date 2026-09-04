/*
kbdfs -- a kernel service, rebuilt as a program.

`kernel/drivers/kbd` translates scancodes to characters inside the kernel.
This is that translation moved to ring 3, over the raw stream `/dev/scancode`
serves. It is the first tenant of the userland devfs the handoff pointed
at. A driver reads a raw device, does its own translation, and serves the
cooked result back as files its clients mount.

The translation is `sys/libkbd`'s, one package both rings call since
`docs/WORKBENCH.md` step 1. This program carried a second copy of the
kernel's tables before that. `docs/KBD.md` said a layout in a driver was
the wrong place for one.

## Two files, because a chord is not a character

`cons` is the keyboard as a byte stream, the characters typed, cooked by
the same rule the kernel's `/dev/cons` uses. Every reader that wants a
byte stream reads it. `kbd` is 9front's, one message per read, for a
reader that wants the keys:

    c<runes>    the characters typed, as UTF-8
    k<runes>    every key held down, after a press
    K<runes>    every key held down, after a release

A reader of `kbd` sees the alt key go down and the `n` go down beside it,
which is a chord, and sees the release. That is the whole of what a
chord needs. It is also why `cons` could never carry one. A key pressed
with alt held makes no character at all, so a chord is never a letter
typed at whatever window is in front. The window manager reads `kbd`,
takes the chords it knows, and passes the rest on.

The shape is `consrv`'s on `sys/libthread`. Two threads in one proc, and
an io proc makes each read that parks:

        the key thread reads /dev/scancode through an io proc, raw make and
                   break codes, and runs the state machine. A character
                   goes into the ring for `cons`. Every change of the keys
                   held becomes a message for `kbd`. Both answer any read
                   held for want of one.
    the serve loop `lib9p.serve`. A read with nothing to give is held
                   rather than answered empty.

Teardown is `consrv`'s. On `Tremove` the serve loop stops and every held
read is answered empty. `threadexitsall` then notes the io procs out of
their parked reads and waits for them. Status zero is that arc succeeding.
*/
package kbdfs

import "base:runtime"
import "core:unicode/utf8"

import "vsys:abi"
import "vsys:lib9p"
import "vsys:libkbd"
import "vsys:libthread"
import "vsys:libuser"
import "vsys:vectra9"

NODE_ROOT :: i32(0)
NODE_CONS :: i32(1)
NODE_KBD :: i32(2)

// The characters waiting to be served on `cons`, kept by the key thread
// for the handler.
RING :: 256
ring_store: [RING]u8
ring: libuser.Ring

/*
The messages waiting to be served on `kbd`, oldest first. A message is a
letter and the runes after it, and one read answers one message. The
queue drops the oldest when full, because a reader that fell that far
behind wants the keys held now rather than the history.
*/
MSG_MAX :: 64
MSGS :: 32

Msg :: struct {
	n:    int,
	data: [MSG_MAX]u8,
}

msgs: [MSGS]Msg
msg_head: int
msg_tail: int

// How many fids hold `kbd`. A message is queued only while somebody
// does, which is the tap's rule. The keys held before a reader arrived
// belong to nobody, and its first message is the first change it sees.
kbd_opens: int

// The keys held, as positions, so the runes they mean can be answered
// under the modifiers of the moment. Sixteen is more fingers than a
// person has.
held: [16]libkbd.Key
nheld: int

state: libkbd.State

fids: libuser.Fid_Table

FRAME :: 1200

srv: lib9p.Srv
raw_fd: int

/*
_start opens the raw stream and hands the process to the thread library.

The open comes first, because the descriptor table is shared: one open, and
the io proc holds the number. Opening `/dev/scancode` is also what diverts
the raw scancodes to this program -- until something holds it open, the
kernel translates them itself. See `kernel/devfs/tap.odin`.
*/
@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	_ = block
	context = {}
	#force_no_inline runtime._startup_runtime()

	ring = libuser.Ring{buf = ring_store[:]}

	raw := libuser.open("/dev/scancode", abi.O_RDONLY)
	if raw < 0 {
		libuser.exit(0x74)
	}
	raw_fd = int(raw)
	libthread.main(threadmain, nil)
}

threadmain :: proc "contextless" (arg: rawptr) {
	_ = arg
	fd, perr := libuser.post("/srv/kbdfs")
	if perr < 0 {
		libthread.threadexitsall("post")
	}
	srv = lib9p.Srv {
		fd      = fd,
		handler = handler,
		msize   = FRAME,
	}
	if libthread.threadcreate(key_thread, nil) < 0 {
		libthread.threadexitsall("threadcreate")
	}

	_, why := lib9p.serve(&srv)

	lib9p.respond_all(&srv, vectra9.Rread{data = nil})
	libthread.threadexitsall(why == .Removed ? "" : "hangup")
}

/*
key_thread is the keyboard's whole life: scancodes through an io proc,
the state machine, and what it makes to whoever holds a read. A failed
read is not a loop to break out of. A noted io proc's read answers EINTR,
and its next call is the boundary the note ends it at.
*/
key_thread :: proc "contextless" (arg: rawptr) {
	_ = arg
	io := libthread.ioproc()
	if io == nil {
		libthread.threadexitsall("ioproc")
	}
	codes: [64]u8
	for {
		n := libthread.ioread(io, raw_fd, codes[:])
		if n <= 0 {
			continue
		}
		chars, changes := 0, 0
		for i in 0 ..< int(n) {
			c, k := key(codes[i])
			chars += c
			changes += k
		}
		if chars > 0 {
			lib9p.answer_reads(&srv, rawptr(uintptr(NODE_CONS)), wants_read, drain_cons)
		}
		if changes > 0 {
			lib9p.answer_reads(&srv, rawptr(uintptr(NODE_KBD)), wants_read, drain_kbd)
		}
	}
}

/*
key runs one scancode through the state machine and records what it
made. A character goes into the ring and becomes a `c` message. A `k` or
`K` message carries every key held after the change. Answers how many
characters and how many messages it made.
*/
key :: proc "contextless" (code: u8) -> (chars: int, messages: int) #no_bounds_check {
	k, down, ok := libkbd.step(&state, code)
	if !ok {
		return 0, 0
	}
	if down {
		hold_key(k)
		if r, made := libkbd.char_of(&state, k); made {
			buf, n := utf8.encode_rune(r)
			for i in 0 ..< n {
				libuser.ring_push(&ring, buf[i])
			}
			msg_push('c', buf[:n])
			chars = 1
			messages += 1
		}
	} else {
		release_key(k)
	}
	msg_push_held(down ? 'k' : 'K')
	return chars, messages + 1
}

@(private = "file")
hold_key :: proc "contextless" (k: libkbd.Key) #no_bounds_check {
	for i in 0 ..< nheld {
		if held[i] == k {
			return
		}
	}
	if nheld < len(held) {
		held[nheld] = k
		nheld += 1
	}
}

@(private = "file")
release_key :: proc "contextless" (k: libkbd.Key) #no_bounds_check {
	for i in 0 ..< nheld {
		if held[i] == k {
			held[i] = held[nheld - 1]
			nheld -= 1
			return
		}
	}
}

// msg_push_held queues a `k` or `K` message: the letter, then the rune
// each held key means under the modifiers now.
@(private = "file")
msg_push_held :: proc "contextless" (letter: u8) #no_bounds_check {
	body: [MSG_MAX]u8
	n := 0
	for i in 0 ..< nheld {
		r, ok := libkbd.rune_of(&state, held[i])
		if !ok {
			continue
		}
		enc, len := utf8.encode_rune(r)
		if n + len > MSG_MAX - 1 {
			break
		}
		for j in 0 ..< len {
			body[n] = enc[j]
			n += 1
		}
	}
	msg_push(letter, body[:n])
}

@(private = "file")
msg_push :: proc "contextless" (letter: u8, body: []u8) #no_bounds_check {
	if kbd_opens == 0 {
		return
	}
	if msg_head - msg_tail >= MSGS {
		msg_tail += 1
	}
	m := &msgs[msg_head % MSGS]
	m.data[0] = letter
	n := copy(m.data[1:], body)
	m.n = n + 1
	msg_head += 1
}

// msg_pop copies the oldest message into `out` and answers its length,
// or zero when there is none.
@(private = "file")
msg_pop :: proc "contextless" (out: []u8) -> int #no_bounds_check {
	if msg_tail == msg_head {
		return 0
	}
	m := &msgs[msg_tail % MSGS]
	n := copy(out, m.data[:m.n])
	msg_tail += 1
	return n
}

// wants_read is what a held request has to be for the key thread to
// answer it: a read of the file `arg` names.
wants_read :: proc "contextless" (arg: rawptr, request: ^vectra9.Msg) -> bool {
	#partial switch m in request^ {
	case vectra9.Tread:
		return libuser.fid_lookup(&fids, m.fid) == i32(uintptr(arg))
	}
	return false
}

drain_cons :: proc "contextless" (arg: rawptr, buf: []u8) -> int {
	_ = arg
	return libuser.ring_drain(&ring, buf)
}

drain_kbd :: proc "contextless" (arg: rawptr, buf: []u8) -> int {
	_ = arg
	return msg_pop(buf)
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
	if from == NODE_ROOT {
		switch name {
		case "cons":
			return NODE_CONS
		case "kbd":
			return NODE_KBD
		}
	}
	return -1
}

name_of :: proc "contextless" (node: i32) -> string {
	return node == NODE_CONS ? "cons" : "kbd"
}

// -- The handler -------------------------------------------------------------

handler :: proc "contextless" (
	state_: rawptr,
	s: ^vectra9.Session,
	tag: vectra9.Tag,
	request: ^vectra9.Msg,
	reply: ^vectra9.Msg,
	buf: []u8,
) #no_bounds_check {
	_ = state_
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
		if node == NODE_KBD {
			kbd_opens += 1
		}
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
		A read of `cons` takes what was typed, and a read of `kbd` takes
		one message. Either is held until there is something, and the key
		thread answers it. A flush, when the client gave up on the read,
		drops the held record. A zero count asks for nothing and gets it.
		*/
		room := min(len(buf), int(m.count))
		if room <= 0 {
			reply^ = vectra9.Rread{data = nil}
			return
		}
		got := node == NODE_CONS ? libuser.ring_drain(&ring, buf[:room]) : msg_pop(buf[:room])
		if got > 0 {
			reply^ = vectra9.Rread{data = buf[:got]}
			return
		}
		lib9p.hold(&srv)

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
		size: u64
		switch node {
		case NODE_CONS:
			size = libuser.ring_available(&ring)
		case NODE_KBD:
			size = u64(msg_head - msg_tail)
		}
		reply^ = vectra9.Rgetattr {
			valid   = m.request_mask & 0x000007FF,
			qid     = qid_of(node),
			mode    = dir ? 0o040555 : 0o100444,
			nlink   = dir ? 2 : 1,
			size    = size,
			blksize = 512,
		}

		case vectra9.Tclunk:
		kbd_release(m.fid)
		reply^ = vectra9.Rclunk{}

	case vectra9.Tremove:
		kbd_release(m.fid)
		reply^ = vectra9.Rremove{}

	case vectra9.Tflush:
		_ = m
		reply^ = vectra9.Rflush{}
	}
}

// kbd_release lets a fid go, and when it was the last holder of `kbd`,
// drops the messages nobody will read.
kbd_release :: proc "contextless" (fid: vectra9.Fid) {
	if libuser.fid_lookup(&fids, fid) == NODE_KBD && libuser.fid_is_open(&fids, fid) {
		kbd_opens -= 1
		if kbd_opens == 0 {
			msg_tail = msg_head
		}
	}
	libuser.fid_release(&fids, fid)
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
	for entry in i32(1) ..= i32(2) {
		name := name_of(entry)
		if m.offset >= u64(entry) || vectra9.remaining(&c) < vectra9.dirent_size(name) {
			continue
		}
		vectra9.put_dirent(
			&c,
			vectra9.Dirent {
				qid = qid_of(entry),
				offset = u64(entry),
				type = vectra9.DT_REG,
				name = name,
			},
		)
	}
	if c.err != .None {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}
	reply^ = vectra9.Rreaddir{data = vectra9.written(&c)}
}
