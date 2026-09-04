/*
consrv -- the first server that waits on two things at once.

`ramfs` answers one pipe, and can, because files in memory never park. A
console server has the problem `docs/HANDOFF.md` kept on its list: the
keyboard and the clients both park a reader, and one thread cannot wait on
both. This is `sys/libthread`'s answer, in the shape Plan 9 gives it. A
proc of its own reads the console, which is the one read here that
genuinely parks, and sends what arrives down a channel. The program's own
proc is two threads that only ever block on each other:

    the reader     a proc parked in `read` on /dev/cons, sending what it
                   reads on `keys`
    the key thread receives `keys`, pushes into the ring, and answers
                   any read of /line that was held for want of a byte
    the serve loop `lib9p.serve`: a request off its channel, the handler,
                   the reply. A read of /line with nothing to give is held
                   rather than answered empty.

**Nothing here is locked.** The ring's consumer end, the fid table and the
held list are all touched by threads of one proc, and a thread runs until
it blocks. The server this file replaced kept two spinlocks and a
shutdown flag for the worker processes it forked per parked read;
`docs/PROCS.md` counts what those cost.

A read of `/line` parks until a byte arrives, which is what a read of a
device should do, and holds no other client while it waits: the loop
answers a `getattr` from another client while the read is held, which
`verify_consrv` proves.

Teardown is `threadexitsall`. A `Tremove` stops the serve loop, every
held read is answered empty, and the library notes the reader proc out of
its parked device read and waits for it before this process exits. Status
zero is that whole arc succeeding.
*/
package consrv

import "base:runtime"

import "vsys:abi"
import "vsys:lib9p"
import "vsys:libthread"
import "vsys:libuser"
import "vsys:vectra9"

NODE_ROOT :: i32(0)
NODE_LINE :: i32(1)

// The bytes that have arrived and not yet been read, kept by the key
// thread for the handler. A ring rather than the channel's own buffer,
// because a read takes what is there and a channel gives one element.
RING :: 256
ring_store: [RING]u8
ring: libuser.Ring

/*
What the reader proc sends: one read's worth of bytes, and how many. A
read of the served file answers what one read of the device delivered,
which for a cooked console is a whole line, so the bytes cross together
rather than one at a time.
*/
CHUNK :: 64

Chunk :: struct {
	n:    int,
	data: [CHUNK]u8,
}

fids: libuser.Fid_Table

FRAME :: 1200

srv: lib9p.Srv
keys: ^libthread.Chan
cons_fd: int

/*
_start opens the console and hands the process to the thread library.

The open comes first because the descriptor table is shared: one open,
and every proc holds the number. 0x74 is a console that would not open.
*/
@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	_ = block
	context = {}
	#force_no_inline runtime._startup_runtime()

	ring = libuser.Ring{buf = ring_store[:]}

	cons := libuser.open("/dev/cons", abi.O_RDONLY)
	if cons < 0 {
		libuser.exit(0x74)
	}
	cons_fd = int(cons)
	libthread.main(threadmain, nil)
}

// threadmain is the first thread: the reader proc, the posting, the key
// thread, and then the serve loop until something ends it.
threadmain :: proc "contextless" (arg: rawptr) {
	_ = arg
	keys = libthread.chancreate(size_of(Chunk), 4)
	if keys == nil {
		libthread.threadexitsall("no memory")
	}
	if libthread.proccreate(reader, nil) < 0 {
		libthread.threadexitsall("proccreate")
	}
	fd, perr := libuser.post("/srv/consrv")
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

	// Every held read answered empty, so no client waits on a record the
	// stopped server will never fill.
	lib9p.respond_all(&srv, vectra9.Rread{data = nil})
	libthread.threadexitsall(why == .Removed ? "" : "hangup")
}

/*
reader is the reader proc's whole life: park on the console, send what
comes. A failed read is not a loop to break out of. A noted proc's read
answers EINTR, and its next system call is the boundary the note ends it
at -- so asking again *is* the teardown protocol, not a bug's retry.
*/
reader :: proc "contextless" (arg: rawptr) {
	_ = arg
	chunk: Chunk
	for {
		n := libuser.read(cons_fd, chunk.data[:])
		if n <= 0 {
			continue
		}
		chunk.n = int(n)
		libthread.send(keys, &chunk)
	}
}

// key_thread takes each chunk off the channel, keeps its bytes, and gives
// what the ring holds to the reads held for it.
key_thread :: proc "contextless" (arg: rawptr) {
	_ = arg
	chunk: Chunk
	for {
		libthread.recv(keys, &chunk)
		for i in 0 ..< chunk.n {
			libuser.ring_push(&ring, chunk.data[i])
		}
		answer_held()
	}
}

// wants_read is what a held request has to be for the key thread to
// answer it: a read of the file the ring feeds.
wants_read :: proc "contextless" (state: rawptr, request: ^vectra9.Msg) -> bool {
	_ = state
	#partial switch m in request^ {
	case vectra9.Tread:
		return libuser.fid_lookup(&fids, m.fid) == NODE_LINE
	}
	return false
}

// answer_held gives what the ring holds to the reads held for it, oldest
// first. See `lib9p.held`.
answer_held :: proc "contextless" () {
	for {
		req, ok := lib9p.held(&srv, wants_read)
		if !ok {
			break
		}
		m := req.msg.(vectra9.Tread)
		room := min(len(req.payload), int(m.count))
		got := libuser.ring_drain(&ring, req.payload[:room])
		if got == 0 {
			break
		}
		_ = lib9p.respond(req, vectra9.Rread{data = req.payload[:got]})
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
		A read of `/line` takes what has arrived, or is held until
		something does: the key thread answers it when a byte comes. The
		offset is ignored, because this file is what has arrived and a
		drain consumes it. A zero count asks for nothing and gets it.
		*/
		room := min(len(buf), int(m.count))
		if room <= 0 {
			reply^ = vectra9.Rread{data = nil}
			return
		}
		got := libuser.ring_drain(&ring, buf[:room])
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
