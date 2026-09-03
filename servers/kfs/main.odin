/*
kfs -- a filesystem of Vectra's own, in ring 3.

    kfs [-r] device [srvname]

FAT keeps a file's bytes and its name and nothing else the namespace
promises: no owner, no permission bits past read-only, no version on the
qid, and a four-gigabyte ceiling. This is the filesystem that keeps the
rest, on the second disk `build.odin` makes, named for Plan 9's `kfs`
because it plays the same part: the disk a machine calls home. `disk.odin`
is the shape on the disk -- a superblock, a bitmap, an inode table, blocks
-- and this file is the 9P tree over it.

`-r` reams the device: lays a fresh volume down over whatever was there,
with an empty root and a `glenda` directory in it. Without it the device
must hold a volume already, and a device that holds none is reamed anyway,
once, with a line on the console saying so, because the scratch disk the
build makes is blank the first time and a boot that stopped on that would
be a boot nobody wanted.

The server is the shape `servers/fatfs` is: a node on the heap per file
seen, a directory's children read once from its blocks and kept, every
change written through, the parent exiting once the name is posted. Where
fatfs computed a name out of a chain of entries, this reads an inode. The
qid's path is the inode number and its version the inode's, which counts
every write, so a client that cached a file can tell it changed. The mode
is the inode's, permission bits and directory bit as Plan 9 has them.
*/
package kfs

import "vsys:abi"
import "vsys:libuser"
import "vsys:vectra9"

FRAME :: 8192 + 256
frame_in: [FRAME]u8
frame_out: [FRAME]u8
payload: [8192]u8

// A directory entry: an inode number, a length, and the name.
DIRENT :: 128
NAME_MAX :: DIRENT - 5
DIRENTS_PER_BLOCK :: BLOCK / DIRENT

Node :: struct {
	ino:      u32,
	name:     string, // On the heap
	dir:      bool,
	mode:     u32, // The inode's, permission bits and DMDIR
	size:     u64,
	version:  u32,
	parent:   ^Node,
	children: [dynamic]^Node,
	loaded:   bool,
	slot:     u32, // Ordinal of its entry in the parent: block * 32 + position
	removed:  bool,
	fids:     int,
}

root: ^Node

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
	args := libuser.args(block)[1:]
	want_ream := false
	if len(args) > 0 && args[0] == "-r" {
		want_ream = true
		args = args[1:]
	}
	if len(args) < 1 {
		libuser.eprint("usage: kfs [-r] device [srvname]\n")
		libuser.exits("usage")
	}
	device := args[0]
	name := "/srv/kfs"
	if len(args) > 1 {
		name = args[1]
	}

	fd := libuser.open(device, abi.O_RDWR)
	if fd < 0 {
		libuser.eprint("kfs: can't open ", device, ": ", libuser.errstr(fd), "\n")
		libuser.exits("open")
	}
	st: abi.Stat
	if libuser.fstat(int(fd), &st) < 0 || st.length == 0 {
		libuser.eprint("kfs: ", device, ": cannot tell its size\n")
		libuser.exits("size")
	}

	mounted, why := false, ""
	if !want_ream {
		mounted, why = mount_volume(int(fd), st.length)
	}
	if !mounted {
		generation := vol.sb.generation + 1
		libuser.eprint("kfs: reaming ", device, want_ream ? "" : ": ", why, "\n")
		ok, rwhy := ream(int(fd), st.length, generation)
		if !ok {
			libuser.eprint("kfs: ", device, ": ", rwhy, "\n")
			libuser.exits("ream")
		}
	}

	root = new(Node)
	root.ino = ROOT_INODE
	root.dir = true
	root.mode = DMDIR | 0o777
	root.parent = root
	in_: Inode
	if get_inode(ROOT_INODE, &in_) {
		root.size = in_.size
		root.version = in_.version
	}
	if !mounted {
		// The one directory a fresh volume has: the user's.
		if !load_children(root) || make_child(root, "glenda", true, 0o775) == nil {
			libuser.eprint("kfs: cannot make /glenda\n")
			libuser.exits("ream")
		}
	}

	sfd, perr := libuser.post(name)
	if perr < 0 {
		libuser.eprint("kfs: can't post ", name, ": ", libuser.errstr(perr), "\n")
		libuser.exits("post")
	}
	pid := libuser.rfork(abi.RFPROC | abi.RFFDG | abi.RFNOWAIT)
	if pid < 0 {
		libuser.eprint("kfs: fork failed\n")
		libuser.exits("fork")
	}
	if pid > 0 {
		libuser.exits("")
	}

	_, end := libuser.serve(sfd, handler, nil, frame_in[:], frame_out[:], payload[:], remove_stops = false)
	switch end {
	case .Removed, .Hangup:
		libuser.exits("")
	case .Broken:
		libuser.eprint("kfs: torn frame\n")
		libuser.exits("broken")
	}
}

// -- Nodes ----------------------------------------------------------------------

qid_of :: proc(n: ^Node) -> vectra9.Qid {
	kind: vectra9.Qid_Flags
	if n.dir {
		kind = {.Dir}
	}
	return vectra9.Qid{kind = kind, path = u64(n.ino), version = n.version}
}

// refresh copies what the inode says into the node, after the inode changed.
refresh :: proc(n: ^Node, in_: ^Inode) {
	n.mode = in_.mode
	n.size = in_.size
	n.version = in_.version
	n.dir = in_.mode & DMDIR != 0
}

clone_string :: proc(s: string) -> string {
	out := make([]u8, len(s))
	copy(out, s)
	return string(out)
}

/*
load_children reads a directory's blocks the first time anything asks: each
128-byte entry with an inode number is a child, and its inode says the
rest. Blocks a hole would leave are skipped, though a directory never has
one; the check is what `bmap` answers and costs nothing.
*/
load_children :: proc(d: ^Node) -> bool #no_bounds_check {
	if d.loaded {
		return true
	}
	din: Inode
	if !get_inode(d.ino, &din) {
		return false
	}
	nblocks := u32((din.size + BLOCK - 1) / BLOCK)
	for bi := u32(0); bi < nblocks; bi += 1 {
		block, ok := bmap(&din, bi, false)
		if !ok {
			return false
		}
		if block == 0 {
			continue
		}
		for s := 0; s < DIRENTS_PER_BLOCK; s += 1 {
			// Read the block per entry: a child's inode read may evict it.
			data := bread(block)
			if data == nil {
				return false
			}
			e := data[s * DIRENT:(s + 1) * DIRENT]
			ino := u32(e[0]) | u32(e[1]) << 8 | u32(e[2]) << 16 | u32(e[3]) << 24
			if ino == 0 {
				continue
			}
			length := int(e[4])
			if length == 0 || length > NAME_MAX {
				continue
			}
			name := clone_string(string(e[5:5 + length]))
			cin: Inode
			if !get_inode(ino, &cin) || cin.mode == 0 {
				delete(name)
				continue
			}
			n := new(Node)
			n.ino = ino
			n.name = name
			n.parent = d
			n.slot = bi * DIRENTS_PER_BLOCK + u32(s)
			refresh(n, &cin)
			append(&d.children, n)
		}
	}
	d.loaded = true
	return true
}

child_named :: proc(d: ^Node, name: string) -> ^Node {
	for c in d.children {
		if c.name == name {
			return c
		}
	}
	return nil
}

/*
dir_add writes an entry naming `ino` into directory `d`, in the first empty
slot, or in a new block when there is none. The order is the one the file
comment in `disk.odin` sets: the block is taken and zeroed before the
directory's inode grows to include it, and the entry is written last.
Answers the entry's ordinal.
*/
dir_add :: proc(d: ^Node, name: string, ino: u32) -> (slot: u32, ok: bool) #no_bounds_check {
	din: Inode
	if !get_inode(d.ino, &din) {
		return 0, false
	}
	nblocks := u32((din.size + BLOCK - 1) / BLOCK)
	for bi := u32(0); bi <= nblocks; bi += 1 {
		block: u32
		if bi == nblocks {
			// Every slot is taken: one more block.
			if bi >= MAX_FILE_BLOCKS {
				return 0, false
			}
			fresh, got := bmap(&din, bi, true)
			if !got || fresh == 0 {
				return 0, false
			}
			din.size = u64(bi + 1) * BLOCK
			din.version += 1
			if !put_inode(d.ino, &din) {
				return 0, false
			}
			d.size = din.size
			d.version = din.version
			block = fresh
		} else {
			b, got := bmap(&din, bi, false)
			if !got || b == 0 {
				continue
			}
			block = b
		}
		data := bread(block)
		if data == nil {
			return 0, false
		}
		for s := 0; s < DIRENTS_PER_BLOCK; s += 1 {
			e := data[s * DIRENT:(s + 1) * DIRENT]
			if e[0] | e[1] | e[2] | e[3] != 0 {
				continue
			}
			for i in 0 ..< DIRENT {
				e[i] = 0
			}
			e[0] = u8(ino)
			e[1] = u8(ino >> 8)
			e[2] = u8(ino >> 16)
			e[3] = u8(ino >> 24)
			e[4] = u8(len(name))
			copy(e[5:5 + len(name)], name)
			if !bwrite(block) {
				return 0, false
			}
			return bi * DIRENTS_PER_BLOCK + u32(s), true
		}
	}
	return 0, false
}

// dir_del clears the entry at ordinal `slot` of directory `d`.
dir_del :: proc(d: ^Node, slot: u32) -> bool #no_bounds_check {
	din: Inode
	if !get_inode(d.ino, &din) {
		return false
	}
	block, ok := bmap(&din, slot / DIRENTS_PER_BLOCK, false)
	if !ok || block == 0 {
		return false
	}
	data := bread(block)
	if data == nil {
		return false
	}
	at := int(slot % DIRENTS_PER_BLOCK) * DIRENT
	for i in 0 ..< DIRENT {
		data[at + i] = 0
	}
	if !bwrite(block) {
		return false
	}
	din.version += 1
	if !put_inode(d.ino, &din) {
		return false
	}
	d.version = din.version
	return true
}

/*
make_child makes a file or a directory named `name` in `d`: an inode taken
and written whole, then the entry that names it, then the node. A
directory starts with one zeroed block so a listing has something to read.
Nil when the volume is out of inodes or blocks, with nothing half made.
*/
make_child :: proc(d: ^Node, name: string, dir: bool, perm: u32) -> ^Node {
	ino, ok := alloc_inode()
	if !ok {
		return nil
	}
	in_ := Inode {
		mode    = perm & 0o777,
		version = 1,
	}
	if dir {
		in_.mode |= DMDIR
		block, got := alloc_block(true)
		if !got {
			return nil
		}
		in_.direct[0] = block
		in_.size = BLOCK
	}
	if !put_inode(ino, &in_) {
		return nil
	}
	slot, added := dir_add(d, name, ino)
	if !added {
		in_.mode = 0
		_ = free_blocks_from(&in_, 0)
		_ = put_inode(ino, &in_)
		return nil
	}
	n := new(Node)
	n.ino = ino
	n.name = clone_string(name)
	n.parent = d
	n.slot = slot
	n.loaded = dir
	refresh(n, &in_)
	append(&d.children, n)
	return n
}

unlink :: proc(n: ^Node) {
	d := n.parent
	for c, i in d.children {
		if c == n {
			ordered_remove(&d.children, i)
			break
		}
	}
	n.removed = true
	release_node(n)
}

release_node :: proc(n: ^Node) {
	if n == nil || !n.removed || n.fids > 0 || n == root {
		return
	}
	delete(n.name)
	delete(n.children)
	free(n)
}

// -- File data ------------------------------------------------------------------

// file_read fills `buf` from byte `off`, a hole reading as zeros.
file_read :: proc(n: ^Node, off: u64, buf: []u8) -> (got: int, ok: bool) #no_bounds_check {
	in_: Inode
	if !get_inode(n.ino, &in_) {
		return 0, false
	}
	if off >= in_.size {
		return 0, true
	}
	want := int(min(u64(len(buf)), in_.size - off))
	pos := off
	for got < want {
		idx := u32(pos / BLOCK)
		within := int(pos % BLOCK)
		take := min(BLOCK - within, want - got)
		block, found := bmap(&in_, idx, false)
		if !found {
			return got, false
		}
		if block == 0 {
			for i in 0 ..< take {
				buf[got + i] = 0
			}
		} else {
			data := bread(block)
			if data == nil {
				return got, false
			}
			copy(buf[got:got + take], data[within:within + take])
		}
		got += take
		pos += u64(take)
	}
	return got, true
}

/*
file_write puts `data` at byte `off`. Each block is taken, filled and
written before the inode says the file reaches it, so a stop between two
writes leaves a file whose size covers only blocks that hold their bytes.
*/
file_write :: proc(n: ^Node, off: u64, data: []u8) -> (put: int, ok: bool) #no_bounds_check {
	if len(data) == 0 {
		return 0, true
	}
	in_: Inode
	if !get_inode(n.ino, &in_) {
		return 0, false
	}
	end := off + u64(len(data))
	if end > u64(MAX_FILE_BLOCKS) * BLOCK {
		return 0, false
	}
	pos := off
	for put < len(data) {
		idx := u32(pos / BLOCK)
		within := int(pos % BLOCK)
		take := min(BLOCK - within, len(data) - put)
		block, found := bmap(&in_, idx, true)
		if !found || block == 0 {
			break
		}
		blk := bread(block)
		if blk == nil {
			break
		}
		copy(blk[within:within + take], data[put:put + take])
		if !bwrite(block) {
			break
		}
		put += take
		pos += u64(take)
	}
	if off + u64(put) > in_.size {
		in_.size = off + u64(put)
	}
	in_.version += 1
	if !put_inode(n.ino, &in_) {
		return put, false
	}
	refresh(n, &in_)
	return put, put == len(data)
}

// truncate sets a file's size. Shrinking frees the blocks past the new end;
// growing leaves a hole, which reads as zeros.
truncate :: proc(n: ^Node, want: u64) -> bool {
	in_: Inode
	if !get_inode(n.ino, &in_) {
		return false
	}
	if want > u64(MAX_FILE_BLOCKS) * BLOCK {
		return false
	}
	if want < in_.size {
		keep := u32((want + BLOCK - 1) / BLOCK)
		if !free_blocks_from(&in_, keep) {
			return false
		}
		if want % BLOCK != 0 && keep > 0 {
			// The last kept block: zero what is past the new end, so a
			// later growth reads zeros there.
			block, ok := bmap(&in_, keep - 1, false)
			if ok && block != 0 {
				data := bread(block)
				if data != nil {
					for i := int(want % BLOCK); i < BLOCK; i += 1 {
						data[i] = 0
					}
					if !bwrite(block) {
						return false
					}
				}
			}
		}
	}
	in_.size = want
	in_.version += 1
	if !put_inode(n.ino, &in_) {
		return false
	}
	refresh(n, &in_)
	return true
}

// -- Fids -----------------------------------------------------------------------

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

valid_name :: proc "contextless" (name: string) -> bool {
	if len(name) == 0 || len(name) > NAME_MAX || name == "." || name == ".." {
		return false
	}
	for i in 0 ..< len(name) {
		if name[i] == '/' || name[i] == 0 {
			return false
		}
	}
	return true
}

// -- The handler ------------------------------------------------------------------

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

// new_child is the checks a create and a mkdir share, then the file.
new_child :: proc(fid: vectra9.Fid, name: string, dir: bool, perm: u32, reply: ^vectra9.Msg) -> ^Node {
	d := live_node(fid, reply)
	if d == nil {
		return nil
	}
	if !d.dir {
		reply^ = vectra9.error_reply(vectra9.ENOTDIR)
		return nil
	}
	if !valid_name(name) {
		reply^ = vectra9.error_reply(vectra9.EINVAL)
		return nil
	}
	if !load_children(d) {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return nil
	}
	if child_named(d, name) != nil {
		reply^ = vectra9.error_reply(vectra9.EEXIST)
		return nil
	}
	n := make_child(d, name, dir, perm)
	if n == nil {
		reply^ = vectra9.error_reply(vectra9.ENOSPC)
	}
	return n
}

// mode_of is the mode as 9P2000.L carries it: Linux's type bits over Plan
// 9's permission bits.
mode_of :: proc "contextless" (n: ^Node) -> u32 {
	return (n.dir ? u32(0o040000) : u32(0o100000)) | n.mode & 0o777
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
		n := new_child(m.fid, m.name, false, m.mode, reply)
		if n == nil {
			return
		}
		fid_bind(m.fid, n)
		fid_slot(m.fid).open = true
		reply^ = vectra9.Rlcreate{qid = qid_of(n), iounit = 0}

	case vectra9.Tmkdir:
		n := new_child(m.dfid, m.name, true, m.mode, reply)
		if n == nil {
			return
		}
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
		if !n.dir && m.flags & 0o3 != 0 && n.mode & 0o222 == 0 {
			reply^ = vectra9.error_reply(vectra9.EPERM)
			return
		}
		if !n.dir && m.flags & 0o1000 != 0 && m.flags & 0o3 != 0 {
			if !truncate(n, 0) {
				reply^ = vectra9.error_reply(vectra9.EIO)
				return
			}
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
		room := min(len(buf), int(m.count))
		got, ok := file_read(n, m.offset, buf[:room])
		if !ok {
			reply^ = vectra9.error_reply(vectra9.EIO)
			return
		}
		reply^ = vectra9.Rread{data = buf[:got]}

	case vectra9.Twrite:
		n := live_node(m.fid, reply, true)
		if n == nil {
			return
		}
		if n.dir {
			reply^ = vectra9.error_reply(vectra9.EISDIR)
			return
		}
		put, ok := file_write(n, m.offset, m.data)
		if !ok {
			reply^ = vectra9.error_reply(put == 0 ? vectra9.ENOSPC : vectra9.EIO)
			return
		}
		reply^ = vectra9.Rwrite{count = u32(put)}

	case vectra9.Treaddir:
		readdir(m, reply, buf)

	case vectra9.Tremove:
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
		if n.dir {
			if !load_children(n) {
				reply^ = vectra9.error_reply(vectra9.EIO)
				return
			}
			if len(n.children) > 0 {
				reply^ = vectra9.error_reply(vectra9.ENOTEMPTY)
				return
			}
		}
		// The entry first, so a stop after it leaves an unreachable inode
		// rather than an entry naming a freed one.
		if !dir_del(n.parent, n.slot) {
			reply^ = vectra9.error_reply(vectra9.EIO)
			return
		}
		in_: Inode
		if get_inode(n.ino, &in_) {
			_ = free_blocks_from(&in_, 0)
			in_.mode = 0
			_ = put_inode(n.ino, &in_)
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
			mode    = mode_of(n),
			nlink   = n.dir ? 2 : 1,
			size    = n.dir ? 0 : n.size,
			blksize = BLOCK,
		}
		attr.blocks = (attr.size + 511) / 512
		reply^ = attr

	case vectra9.Tsetattr:
		n := live_node(m.fid, reply)
		if n == nil {
			return
		}
		if m.valid & 0x1 != 0 {
			in_: Inode
			if !get_inode(n.ino, &in_) {
				reply^ = vectra9.error_reply(vectra9.EIO)
				return
			}
			in_.mode = in_.mode & DMDIR | m.mode & 0o777
			in_.version += 1
			if !put_inode(n.ino, &in_) {
				reply^ = vectra9.error_reply(vectra9.EIO)
				return
			}
			refresh(n, &in_)
		}
		if m.valid & 0x8 != 0 && !n.dir {
			if !truncate(n, m.size) {
				reply^ = vectra9.error_reply(vectra9.EIO)
				return
			}
		}
		reply^ = vectra9.Rsetattr{}

	case vectra9.Tstatfs:
		reply^ = vectra9.Rstatfs {
			type    = 0x4B46_5330, // "KFS0"
			bsize   = BLOCK,
			blocks  = u64(vol.sb.blocks),
			bfree   = u64(vol.free),
			bavail  = u64(vol.free),
			files   = u64(vol.sb.inodes),
			namelen = NAME_MAX,
		}

	case vectra9.Tfsync:
		if live_node(m.fid, reply) == nil {
			return
		}
		reply^ = vectra9.Rfsync{}

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
			if !load_children(cur) {
				reply^ = vectra9.error_reply(vectra9.EIO)
				return
			}
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

// readdir lists a directory. The cookie is the entry's ordinal plus one,
// which a removal between two reads does not move: the entries after it
// keep their slots.
readdir :: proc(m: vectra9.Treaddir, reply: ^vectra9.Msg, buf: []u8) {
	d := live_node(m.fid, reply, true)
	if d == nil {
		return
	}
	if !d.dir {
		reply^ = vectra9.error_reply(vectra9.ENOTDIR)
		return
	}
	if !load_children(d) {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}
	room := min(len(buf), int(m.count))
	c := vectra9.cursor_from(buf[:room])
	after := m.offset
	for {
		// The child with the smallest ordinal past the cookie, so the
		// listing is in slot order whatever order the list holds.
		best: ^Node
		for child in d.children {
			if u64(child.slot) + 1 <= after {
				continue
			}
			if best == nil || child.slot < best.slot {
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
				offset = u64(best.slot) + 1,
				type = best.dir ? vectra9.DT_DIR : vectra9.DT_REG,
				name = best.name,
			},
		)
		after = u64(best.slot) + 1
	}
	if c.err != .None {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}
	reply^ = vectra9.Rreaddir{data = vectra9.written(&c)}
}
