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

A read of `/line` with nothing arrived answers zero bytes, which a client
cannot tell from an end of file. The wart is real and stays: parking the
Tread instead would hold this serve loop's one request for as long as the
keyboard is silent, which starves every other client. The fix is a serve
loop with a thread per request, and that is the next milestone's argument,
not this one's.

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
ring: [RING]u8
head: u64
tail: u64

// The child's read buffer. In the shared bss like everything else, and
// touched by the child alone -- the stack would be private, but a buffer a
// syscall fills is clearer with a name.
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

/*
_start opens the console, forks the reader, and serves.

The open comes first because the descriptor table is shared by default: one
open, and both processes hold the number. The child never returns from
`reader` -- its whole life is the read loop -- and the parent never reads
the console at all.
*/
@(export, link_name = "_start")
start :: proc "sysv" (data: uintptr, arg: u64, arg2: u64) {
	context = {}
	#force_no_inline runtime._startup_runtime()

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
		_ = stop_reader(u64(pid))
		libuser.exit(0x71)
	}

	_, why := libuser.serve(fd, handler, nil, frame_in[:], frame_out[:], payload[:])
	if why != .Removed {
		_ = stop_reader(u64(pid))
		libuser.exit(0x72)
	}
	// Status zero is the whole teardown arc succeeding: the note landed, the
	// parked read unwound, and the wait heard EINTR -- the kernel's word for
	// an ending this parent asked for.
	libuser.exit(stop_reader(u64(pid)) ? 0 : 0x75)
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
			push(chunk[i])
		}
	}
}

// stop_reader is the teardown: note the child out of its parked read, and
// collect the EINTR that proves the ending was the one asked for.
stop_reader :: proc "contextless" (pid: u64) -> bool {
	if libuser.note(pid, "stop") != 0 {
		return false
	}
	return libuser.wait(pid) == -i64(vectra9.EINTR)
}

// push is the producer's half of the ring: bytes first, then the counter,
// so the consumer never reads a seat the byte has not taken. A full ring
// drops the byte -- a console that is not being served is not a place to
// park the keyboard behind.
push :: proc "contextless" (b: u8) #no_bounds_check {
	h := intrinsics.volatile_load(&head)
	t := intrinsics.volatile_load(&tail)
	if h - t >= RING {
		return
	}
	ring[h % RING] = b
	intrinsics.volatile_store(&head, h + 1)
}

// drain is the consumer's half: read the producer's counter once, take what
// it covers, then publish the new tail. Only the parent calls it.
drain :: proc "contextless" (buf: []u8) -> int #no_bounds_check {
	t := intrinsics.volatile_load(&tail)
	h := intrinsics.volatile_load(&head)
	n := min(int(h - t), len(buf))
	for i in 0 ..< n {
		buf[i] = ring[(t + u64(i)) % RING]
	}
	intrinsics.volatile_store(&tail, t + u64(n))
	return n
}

// available reports the bytes waiting, for a getattr's size field.
available :: proc "contextless" () -> u64 {
	return intrinsics.volatile_load(&head) - intrinsics.volatile_load(&tail)
}

// -- Fids, the same sixteen slots ramfs keeps ---------------------------------

fid_lookup :: proc "contextless" (fid: vectra9.Fid) -> i32 #no_bounds_check {
	for i in 0 ..< MAX_FIDS {
		if fids[i].used && fids[i].fid == fid {
			return fids[i].node
		}
	}
	return -1
}

fid_bind :: proc "contextless" (fid: vectra9.Fid, node: i32) -> bool #no_bounds_check {
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

creates :: proc "contextless" (k: vectra9.Kind) -> bool {
	#partial switch k {
	case .Tlcreate, .Tmkdir, .Tmknod, .Tsymlink, .Tlink, .Trename, .Trenameat:
		return true
	}
	return false
}

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

	if creates(vectra9.kind(request^)) {
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
		// The offset is ignored: this file is what has arrived, and a
		// drain consumes it. Empty answers zero bytes -- the wart the
		// file comment owns up to.
		room := min(len(buf), int(m.count))
		got := drain(buf[:room])
		reply^ = vectra9.Rread{data = buf[:got]}

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
		next := step(cur, m.names[i])
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
