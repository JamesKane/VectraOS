/*
memfs -- a file tree in memory, the whole of it.

`ramfs` is the teaching server: two files, fixed, proving the loader. This
is the working one: a directory tree of any shape, files that grow as they
are written, made and removed by name, listed, stat'd, truncated -- what a
shell and its tools need from a filesystem until the disk arrives in
`docs/SHELL.md` step 5. It posts `/srv/memfs` and serves from the heap.

Plan 9's ramfs does the same and is named for it. This one is `memfs` while
the teaching server holds the name; when the disk lands and that one
retires, this takes it.

The program forks after posting: the parent exits and the child serves, so
a shell that started it can mount `/srv/memfs` on the next line. The child
is detached, and ends when the last mount and the name are both gone --
`unmount` and `rm /srv/memfs` -- which the counted release turns into a
hang-up on the pipe.

A node is a record on the heap. A fid names a node by pointer; a removed
node is marked so a fid that still points at it answers `no such file`
rather than reaching freed memory, and is freed when the last fid lets go.
*/
package memfs

import "vsys:abi"
import "vsys:libuser"
import "vsys:vectra9"

FRAME :: 8192 + 256
frame_in: [FRAME]u8
frame_out: [FRAME]u8
payload: [8192]u8

Node :: struct {
	name:     string, // on the heap
	dir:      bool,
	parent:   ^Node,
	children: [dynamic]^Node, // a directory's
	data:     [dynamic]u8, // a file's
	qid:      u64, // never reused
	version:  u32,
	mode:     u32, // permission bits
	removed:  bool,
	fids:     int, // fids bound here; a removed node frees when this drops to zero
}

root: ^Node
next_qid: u64 = 1

MAX_FIDS :: 128

Fid :: struct {
	fid:  vectra9.Fid,
	node: ^Node,
	open: bool,
	used: bool,
}

fids: [MAX_FIDS]Fid

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)
	name := "/srv/memfs"
	if len(args) > 1 {
		name = args[1]
	}

	root = new(Node)
	root.dir = true
	root.parent = root
	root.qid = next_qid
	root.mode = 0o777
	next_qid += 1

	fd, perr := libuser.post(name)
	if perr < 0 {
		libuser.eprint("memfs: can't post ", name, ": ", libuser.errstr(perr), "\n")
		libuser.exits("post")
	}

	// The parent's work is done once the name exists. The child serves,
	// detached, and the shell that started us can go on to mount.
	pid := libuser.rfork(abi.RFPROC | abi.RFFDG | abi.RFNOWAIT)
	if pid < 0 {
		libuser.eprint("memfs: fork failed\n")
		libuser.exits("fork")
	}
	if pid > 0 {
		libuser.exits("")
	}

	// Tremove removes a file here rather than stopping the server, which is
	// the fixed-tree servers' convention and not a filesystem's.
	_, why := libuser.serve(fd, handler, nil, frame_in[:], frame_out[:], payload[:], remove_stops = false)
	switch why {
	case .Removed, .Hangup:
		libuser.exits("")
	case .Broken:
		libuser.eprint("memfs: torn frame\n")
		libuser.exits("broken")
	}
}

// -- Nodes ---------------------------------------------------------------------------

qid_of :: proc(n: ^Node) -> vectra9.Qid {
	kind: vectra9.Qid_Flags
	if n.dir {
		kind = {.Dir}
	}
	return vectra9.Qid{kind = kind, path = n.qid, version = n.version}
}

child_named :: proc(d: ^Node, name: string) -> ^Node {
	for c in d.children {
		if c.name == name {
			return c
		}
	}
	return nil
}

make_child :: proc(d: ^Node, name: string, dir: bool, mode: u32) -> ^Node {
	n := new(Node)
	n.name = clone(name)
	n.dir = dir
	n.parent = d
	n.qid = next_qid
	n.mode = mode
	next_qid += 1
	append(&d.children, n)
	d.version += 1
	return n
}

// unlink takes a node out of its parent and marks it removed. The record
// goes when the last fid on it is released.
unlink :: proc(n: ^Node) {
	d := n.parent
	for c, i in d.children {
		if c == n {
			ordered_remove(&d.children, i)
			break
		}
	}
	d.version += 1
	n.removed = true
	release_node(n)
}

// release_node frees a removed node nobody names any more.
release_node :: proc(n: ^Node) {
	if n == nil || !n.removed || n.fids > 0 || n == root {
		return
	}
	delete(n.name)
	delete(n.children)
	delete(n.data)
	free(n)
}

clone :: proc(s: string) -> string {
	out := make([]u8, len(s))
	copy(out, s)
	return string(out)
}

// -- Fids ---------------------------------------------------------------------------

fid_slot :: proc(fid: vectra9.Fid) -> ^Fid {
	for &f in fids {
		if f.used && f.fid == fid {
			return &f
		}
	}
	return nil
}

fid_bind :: proc(fid: vectra9.Fid, n: ^Node) -> bool {
	if f := fid_slot(fid); f != nil {
		f.node.fids -= 1
		release_node(f.node)
		f.node = n
		f.open = false
		n.fids += 1
		return true
	}
	for &f in fids {
		if !f.used {
			f = Fid{fid = fid, node = n, used = true}
			n.fids += 1
			return true
		}
	}
	return false
}

fid_release :: proc(fid: vectra9.Fid) {
	if f := fid_slot(fid); f != nil {
		f.node.fids -= 1
		release_node(f.node)
		f^ = Fid{}
	}
}

// live_node is the fid's node, or an error into the reply: EBADF for a fid
// this server never bound, ENOENT for one on a file since removed.
live_node :: proc(fid: vectra9.Fid, reply: ^vectra9.Msg, must_be_open := false) -> ^Node {
	f := fid_slot(fid)
	if f == nil {
		reply^ = vectra9.error_reply(vectra9.EBADF)
		return nil
	}
	if f.node.removed {
		reply^ = vectra9.error_reply(vectra9.ENOENT)
		return nil
	}
	if must_be_open && !f.open {
		reply^ = vectra9.error_reply(vectra9.EINVAL)
		return nil
	}
	return f.node
}

valid_name :: proc(name: string) -> bool {
	if len(name) == 0 || len(name) > 255 || name == "." || name == ".." {
		return false
	}
	for i in 0 ..< len(name) {
		if name[i] == '/' || name[i] == 0 {
			return false
		}
	}
	return true
}

// -- The handler ---------------------------------------------------------------------

handler :: proc "contextless" (
	state: rawptr,
	s: ^vectra9.Session,
	tag: vectra9.Tag,
	request: ^vectra9.Msg,
	reply: ^vectra9.Msg,
	buf: []u8,
) {
	_ = state
	_ = s
	_ = tag
	context = libuser.heap_context()
	reply^ = vectra9.error_reply(vectra9.EOPNOTSUPP)
	dispatch(request, reply, buf)
}

dispatch :: proc(request: ^vectra9.Msg, reply: ^vectra9.Msg, buf: []u8) {
	#partial switch m in request^ {
	case vectra9.Tversion:
		vectra9.version_reply(m, reply, FRAME)

	case vectra9.Tattach:
		if !fid_bind(m.fid, root) {
			reply^ = vectra9.error_reply(vectra9.ENFILE)
			return
		}
		reply^ = vectra9.Rattach{qid = qid_of(root)}

	case vectra9.Twalk:
		walk(m, reply)

	case vectra9.Tlcreate:
		d := live_node(m.fid, reply)
		if d == nil {
			return
		}
		if !d.dir {
			reply^ = vectra9.error_reply(vectra9.ENOTDIR)
			return
		}
		if !valid_name(m.name) {
			reply^ = vectra9.error_reply(vectra9.EINVAL)
			return
		}
		if child_named(d, m.name) != nil {
			reply^ = vectra9.error_reply(vectra9.EEXIST)
			return
		}
		n := make_child(d, m.name, false, m.mode & 0o777)
		// The fid moves to the new file, open, as Tlcreate says.
		fid_bind(m.fid, n)
		fid_slot(m.fid).open = true
		reply^ = vectra9.Rlcreate{qid = qid_of(n), iounit = 0}

	case vectra9.Tmkdir:
		d := live_node(m.dfid, reply)
		if d == nil {
			return
		}
		if !d.dir {
			reply^ = vectra9.error_reply(vectra9.ENOTDIR)
			return
		}
		if !valid_name(m.name) {
			reply^ = vectra9.error_reply(vectra9.EINVAL)
			return
		}
		if child_named(d, m.name) != nil {
			reply^ = vectra9.error_reply(vectra9.EEXIST)
			return
		}
		n := make_child(d, m.name, true, m.mode & 0o777)
		reply^ = vectra9.Rmkdir{qid = qid_of(n)}

	case vectra9.Tlopen:
		n := live_node(m.fid, reply)
		if n == nil {
			return
		}
		if n.dir && m.flags & 0o3 != 0 {
			reply^ = vectra9.error_reply(vectra9.EISDIR)
			return
		}
		if !n.dir && m.flags & 0o1000 != 0 && m.flags & 0o3 != 0 {
			clear(&n.data)
			n.version += 1
		}
		fid_slot(m.fid).open = true
		reply^ = vectra9.Rlopen{qid = qid_of(n), iounit = 0}

	case vectra9.Tread:
		n := live_node(m.fid, reply, true)
		if n == nil {
			return
		}
		if n.dir {
			reply^ = vectra9.error_reply(vectra9.EISDIR)
			return
		}
		if m.offset >= u64(len(n.data)) {
			reply^ = vectra9.Rread{data = nil}
			return
		}
		start_at := int(m.offset)
		end := min(len(n.data), start_at + min(len(buf), int(m.count)))
		copy(buf[:end - start_at], n.data[start_at:end])
		reply^ = vectra9.Rread{data = buf[:end - start_at]}

	case vectra9.Twrite:
		n := live_node(m.fid, reply, true)
		if n == nil {
			return
		}
		if n.dir {
			reply^ = vectra9.error_reply(vectra9.EISDIR)
			return
		}
		end := int(m.offset) + len(m.data)
		if end > len(n.data) {
			old := len(n.data)
			resize(&n.data, end)
			for i in old ..< int(m.offset) {
				n.data[i] = 0
			}
		}
		copy(n.data[m.offset:end], m.data)
		n.version += 1
		reply^ = vectra9.Rwrite{count = u32(len(m.data))}

	case vectra9.Treaddir:
		readdir(m, reply, buf)

	case vectra9.Tremove:
		// The fid is spent either way.
		f := fid_slot(m.fid)
		if f == nil {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		n := f.node
		fid_release(m.fid)
		if n.removed {
			reply^ = vectra9.error_reply(vectra9.ENOENT)
			return
		}
		if n == root {
			reply^ = vectra9.error_reply(vectra9.EPERM)
			return
		}
		if n.dir && len(n.children) > 0 {
			reply^ = vectra9.error_reply(vectra9.ENOTEMPTY)
			return
		}
		unlink(n)
		reply^ = vectra9.Rremove{}

	case vectra9.Tgetattr:
		n := live_node(m.fid, reply)
		if n == nil {
			return
		}
		attr := vectra9.Rgetattr {
			valid   = m.request_mask & 0x000007FF,
			qid     = qid_of(n),
			mode    = (n.dir ? 0o040000 : 0o100000) | n.mode,
			nlink   = n.dir ? 2 : 1,
			size    = n.dir ? 0 : u64(len(n.data)),
			blksize = 512,
		}
		attr.blocks = (attr.size + 511) / 512
		reply^ = attr

	case vectra9.Tsetattr:
		n := live_node(m.fid, reply)
		if n == nil {
			return
		}
		if m.valid & 0x1 != 0 {
			n.mode = m.mode & 0o777
		}
		if m.valid & 0x8 != 0 && !n.dir {
			want := int(m.size)
			old := len(n.data)
			resize(&n.data, want)
			for i in old ..< want {
				n.data[i] = 0
			}
			n.version += 1
		}
		reply^ = vectra9.Rsetattr{}

	case vectra9.Tstatfs:
		reply^ = vectra9.Rstatfs {
			type    = 0x0139_9249,
			bsize   = 512,
			namelen = 255,
		}

	case vectra9.Tclunk:
		fid_release(m.fid)
		reply^ = vectra9.Rclunk{}

	case vectra9.Tflush:
		_ = m
		reply^ = vectra9.Rflush{}
	}
}

walk :: proc(m: vectra9.Twalk, reply: ^vectra9.Msg) {
	f := fid_slot(m.fid)
	if f == nil {
		reply^ = vectra9.error_reply(vectra9.EBADF)
		return
	}
	if f.open {
		reply^ = vectra9.error_reply(vectra9.EBUSY)
		return
	}
	cur := f.node
	answer: vectra9.Rwalk
	for i in 0 ..< m.count {
		name := m.names[i]
		next: ^Node
		switch {
		case cur.removed:
		case name == ".":
			next = cur
		case name == "..":
			next = cur.parent
		case cur.dir:
			next = child_named(cur, name)
		}
		if next == nil {
			if i == 0 {
				reply^ = vectra9.error_reply(cur.dir ? vectra9.ENOENT : vectra9.ENOTDIR)
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

// readdir lists a directory. The cookie is the child's qid, which never
// comes back, so a listing paced across a removal neither skips nor
// repeats -- the rule `kernel/srv` set for a directory that changes.
readdir :: proc(m: vectra9.Treaddir, reply: ^vectra9.Msg, buf: []u8) {
	d := live_node(m.fid, reply, true)
	if d == nil {
		return
	}
	if !d.dir {
		reply^ = vectra9.error_reply(vectra9.ENOTDIR)
		return
	}
	room := min(len(buf), int(m.count))
	c := vectra9.cursor_from(buf[:room])
	after := m.offset
	for {
		best: ^Node
		for child in d.children {
			if child.qid > after && (best == nil || child.qid < best.qid) {
				best = child
			}
		}
		if best == nil {
			break
		}
		if vectra9.remaining(&c) < vectra9.dirent_size(best.name) {
			break
		}
		vectra9.put_dirent(
			&c,
			vectra9.Dirent {
				qid = qid_of(best),
				offset = best.qid,
				type = best.dir ? vectra9.DT_DIR : vectra9.DT_REG,
				name = best.name,
			},
		)
		after = best.qid
	}
	if c.err != .None {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}
	reply^ = vectra9.Rreaddir{data = vectra9.written(&c)}
}
