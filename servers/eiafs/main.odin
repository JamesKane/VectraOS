/*
eiafs -- the serial port, served from ring 3.

`kbdfs` proved a kernel driver can stand one privilege level out: raw
scancodes in, a translation, characters served on a file. The port asks a
smaller and a larger question at once. Smaller, because serial bytes need
no translation -- what arrives on the wire is already the content, so the
reader sends what it reads and nothing more. Larger, because `/dev/eia0`
is the first raw device a program may also *write*. So this is the first
userland server whose `Twrite` reaches hardware: a write to the served
file goes down the shared descriptor and out the wire.

The shape is `consrv`'s on `sys/libthread`, byte for byte where it can be:

    the byte thread reads /dev/eia0 through an io proc, pushes what
                    arrives into the ring, and answers any read of /eia0
                    held for want of a byte
        the serve loop  `lib9p.serve`. A read of /eia0 with nothing arrived is
                    held, and a write of /eia0 goes out the wire inline.

The open takes `O_RDWR` and comes first, so the io proc holds the one
descriptor. It reads it for its whole life, and the handler writes it. A
write never parks -- the UART takes bytes as fast as its FIFO drains --
so the serve loop answers a `Twrite` inline.

Two properties of the wire are the kernel's, not this server's, and a
client should know both. The device expands LF to CRLF on the way out,
so a byte stream through `/eia0` is a terminal's, not a modem's. And the
kernel log writes the same wire unserialised -- the ordering of a log
line against a served write is undefined, which `kernel/devfs` documents
as the deliberate cost of a log that cannot park.

Teardown is `consrv`'s. On `Tremove` the serve loop stops and every held
read is answered empty. `threadexitsall` then notes the io procs out of
their parked reads and waits for them. Status zero is that arc succeeding.
*/
package eiafs

import "base:runtime"

import "vsys:abi"
import "vsys:lib9p"
import "vsys:libthread"
import "vsys:libuser"
import "vsys:vectra9"

NODE_ROOT :: i32(0)
NODE_EIA :: i32(1)

// The bytes off the wire, waiting to be served, kept by the byte thread
// for the handler.
RING :: 256
ring_store: [RING]u8
ring: libuser.Ring

// The device descriptor. The io proc reads it, and the handler's Twrite
// case writes it. Nobody closes it -- the process exit is the close.
eia_fd: int

fids: libuser.Fid_Table

FRAME :: 1200

srv: lib9p.Srv

/*
_start opens the port and hands the process to the thread library.

The open comes first because the descriptor table is shared: one open,
and the io proc holds the number. It takes `O_RDWR` because the two sides
want different directions. An open that fails is also the portless
machine: a port that failed its probe answers ENXIO, and this server has
nothing to serve.
*/
@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	_ = block
	context = {}
	#force_no_inline runtime._startup_runtime()

	ring = libuser.Ring{buf = ring_store[:]}

	fd := libuser.open("/dev/eia0", abi.O_RDWR)
	if fd < 0 {
		libuser.exit(0x74)
	}
	eia_fd = int(fd)
	libthread.main(threadmain, nil)
}

threadmain :: proc "contextless" (arg: rawptr) {
	_ = arg
	sfd, perr := libuser.post("/srv/eiafs")
	if perr < 0 {
		libthread.threadexitsall("post")
	}
	srv = lib9p.Srv {
		fd      = sfd,
		handler = handler,
		msize   = FRAME,
	}
	if libthread.threadcreate(byte_thread, nil) < 0 {
		libthread.threadexitsall("threadcreate")
	}

	_, why := lib9p.serve(&srv)

	lib9p.respond_all(&srv, vectra9.Rread{data = nil})
	libthread.threadexitsall(why == .Removed ? "" : "hangup")
}

/*
byte_thread is the port's whole life: a read through an io proc, what
arrives into the ring, and the ring to whoever holds a read of /eia0. A
failed read is not a loop to break out of. A noted io proc's read answers
EINTR, and its next call is the boundary the note ends it at.
*/
byte_thread :: proc "contextless" (arg: rawptr) {
	_ = arg
	io := libthread.ioproc()
	if io == nil {
		libthread.threadexitsall("ioproc")
	}
	chunk: [64]u8
	for {
		n := libthread.ioread(io, eia_fd, chunk[:])
		if n <= 0 {
			continue
		}
		for i in 0 ..< int(n) {
			libuser.ring_push(&ring, chunk[i])
		}
		lib9p.answer_reads(&srv, nil, wants_read, drain)
	}
}

// wants_read is what a held request has to be for the byte thread to
// answer it: a read of the file the ring feeds.
wants_read :: proc "contextless" (arg: rawptr, request: ^vectra9.Msg) -> bool {
	_ = arg
	#partial switch m in request^ {
	case vectra9.Tread:
		return libuser.fid_lookup(&fids, m.fid) == NODE_EIA
	}
	return false
}

drain :: proc "contextless" (arg: rawptr, buf: []u8) -> int {
	_ = arg
	return libuser.ring_drain(&ring, buf)
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
		A read of `/eia0` takes what has arrived, or is held until something
		does: the byte thread answers it when the port delivers. The offset
		is ignored, because this file is what has arrived and a drain
		consumes it. A flush, when the client gave up on the read, drops the
		held record. A zero count asks for nothing and gets it.
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
