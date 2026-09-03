/*
ramfs -- the first server that is a program in a language.

`servers/` was empty from the first commit, and `/bin/niner` only proved the
transport: it answered 9P with replies built byte by byte, because a page of
assembler carries no codec. This is the other half of the proof. An Odin
program, larger than a page, with `sys/vectra9` linked in and a handler
shaped exactly like a kernel server's, posts `/srv/ramfs` and serves a
small tree:

    /hello    read-only text, out of this program's own rodata
    /note     a writable file, in this program's own bss

The two files are chosen to prove the loader. A read of `/hello` returns
bytes from a rodata segment mapped read-only. A write to `/note` lands in a
bss segment the image never carried, mapped writable. A program that serves
both has every one of its segments where the format said.

Plan 9 keeps a tiny ramfs as its teaching server, and this one keeps that
role: the handler below is the smallest complete answer to `what does a
file server implement`, in the same shape `kernel/srv`'s and `kernel/devfs`'s
handlers are written in.

Removal is the stop, as it was for `niner`: a `Tremove` on any file is
answered and then obeyed, and the exit status says the stop was asked for.
*/
package ramfs

import "base:runtime"

import "vsys:libuser"
import "vsys:vectra9"

// The tree: one directory, two files. A node is an index, a qid path is the
// index plus one so that zero names nothing, and the table never changes --
// an ordinal cookie in the listing is therefore honest here.
NODE_ROOT :: i32(0)
NODE_HELLO :: i32(1)
NODE_NOTE :: i32(2)

HELLO := "these bytes live in a program's own segments\n"

// Larger than the kernel's one-call copy bound on purpose. A note this size
// crosses the pipe in pieces both ways, so serving it is what proves the
// library's read and write loops rather than the easy case.
NOTE_CAP :: 300
note: [NOTE_CAP]u8
note_len: int

// Client fids, bound to nodes. Sixteen is roomy: the kernel client holds a
// handful at a time, and a full table answers ENFILE like every fixed table
// in the tree.


fids: libuser.Fid_Table

// The frame either way, and the payload a reply borrows. Static, because a
// program has no heap unless it builds one, and this one needs none.
FRAME :: 1200
frame_in: [FRAME]u8
frame_out: [FRAME]u8
payload: [1024]u8

/*
_start is where the loader's thread arrives, on this program's own stack.

The runtime starts first, exactly as `kmain` starts it: an empty context --
the nil allocator makes an accidental allocation fail loudly rather than
quietly -- and then the global initialisers. Nothing in this program needs
one today, and running them anyway is what keeps that sentence from
becoming a trap for the next program.
*/
@(export, link_name = "_start")
start :: proc "c" (data: uintptr, arg: u64, arg2: u64) {
	context = {}
	#force_no_inline runtime._startup_runtime()

	fd, perr := libuser.post("/srv/ramfs")
	if perr < 0 {
		libuser.exit(0x71)
	}

	/*
	Three endings, each with its own number, and only one is a fault. A
	Tremove answered and obeyed is the client's stop, and exits zero. A
	stream that ends is the kernel's stop -- the counted release closed the
	posted end because the last mount and the name are both gone -- and 0x68
	says the hang-up did it. Torn framing is the one that means a bug, and
	0x72 stays its number. `kernel/user/verify.odin` matches the middle one
	by value, and the two have to agree.
	*/
	_, why := libuser.serve(fd, handler, nil, frame_in[:], frame_out[:], payload[:])
	switch why {
	case .Removed:
		libuser.exit(0)
	case .Hangup:
		libuser.exit(0x68)
	case .Broken:
		libuser.exit(0x72)
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

name_of :: proc "contextless" (node: i32) -> string {
	switch node {
	case NODE_HELLO:
		return "hello"
	case NODE_NOTE:
		return "note"
	}
	return ""
}

step :: proc "contextless" (from: i32, name: string) -> i32 {
	switch name {
	case ".":
		return from
	case "..":
		// Everything is one level down, and the root's parent is the root,
		// which is what lets a namespace climb out through its own mounts.
		return NODE_ROOT
	}
	if from != NODE_ROOT {
		return -1
	}
	switch name {
	case "hello":
		return NODE_HELLO
	case "note":
		return NODE_NOTE
	}
	return -1
}

content :: proc "contextless" (node: i32) -> []u8 {
	switch node {
	case NODE_HELLO:
		return transmute([]u8)HELLO
	case NODE_NOTE:
		return note[:note_len]
	}
	return nil
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
		data := content(node)
		if m.offset >= u64(len(data)) {
			reply^ = vectra9.Rread{data = nil}
			return
		}
		start_at := int(m.offset)
		end := min(len(data), start_at + min(len(buf), int(m.count)))
		copy(buf[:end - start_at], data[start_at:end])
		reply^ = vectra9.Rread{data = buf[:end - start_at]}

	case vectra9.Twrite:
		node, ok := libuser.node_of(&fids, m.fid, reply)
		if !ok {
			return
		}
		if node != NODE_NOTE {
			// The root is a directory and `hello` is this program's own
			// text about itself. EPERM for both: writable is a property a
			// file either has or has not.
			reply^ = vectra9.error_reply(vectra9.EPERM)
			return
		}
		if m.offset >= NOTE_CAP {
			reply^ = vectra9.error_reply(vectra9.ENOSPC)
			return
		}
		end := min(NOTE_CAP, int(m.offset) + len(m.data))
		n := end - int(m.offset)
		copy(note[m.offset:end], m.data[:n])
		if end > note_len {
			note_len = end
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
			mode    = dir ? 0o040555 : (node == NODE_NOTE ? 0o100666 : 0o100444),
			nlink   = dir ? 2 : 1,
			size    = dir ? 0 : u64(len(content(node))),
			blksize = 512,
		}

	case vectra9.Tclunk:
		libuser.fid_release(&fids, m.fid)
		reply^ = vectra9.Rclunk{}

	case vectra9.Tremove:
		// The stop. The fid is spent either way, the reply says yes, and
		// `serve` returns once the reply is on the pipe.
		libuser.fid_release(&fids, m.fid)
		reply^ = vectra9.Rremove{}

	case vectra9.Tflush:
		// One request at a time: whatever the flush names was answered
		// before this arrived.
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

	// An ordinal cookie, and honestly so: this table never changes, so an
	// ordinal names the same file every time. `kernel/srv` is the directory
	// that could not do this, and its document says why.
	room := min(len(buf), int(m.count))
	c := vectra9.cursor_from(buf[:room])
	for child := i32(m.offset) + 1; child <= NODE_NOTE; child += 1 {
		if vectra9.remaining(&c) < vectra9.dirent_size(name_of(child)) {
			break
		}
		vectra9.put_dirent(
			&c,
			vectra9.Dirent {
				qid = qid_of(child),
				offset = u64(child),
				type = vectra9.DT_REG,
				name = name_of(child),
			},
		)
	}
	if c.err != .None {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}
	reply^ = vectra9.Rreaddir{data = vectra9.written(&c)}
}
