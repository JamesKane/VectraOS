/*
fatfs -- a FAT volume as a 9P tree, in ring 3.

The disk is a file, `/dev/sd0/dos` or whichever partition holds the volume,
and this program is what turns its sectors into a directory a shell can
`cd` into. 9front calls its `dossrv`; Plan 9's was `dosfs`. FAT12, FAT16
and FAT32, long names, read and write.

    fatfs device [srvname]

The volume is read through the device with `pread` and written with
`pwrite`, which is the whole of what it asks of the kernel; the device may
be a partition, the whole disk, or a file in another filesystem, and this
program cannot tell. It posts `srvname` -- `/srv/esp` unless told otherwise
-- and forks: the parent exits so whoever started it can mount on the next
line, and the child serves until the last mount and the name are gone.

## Nodes

A fid names a `Node`, a record on the heap for one file or directory the
server has seen: its long name, its first cluster and size, and where its
directory entry is so the entry can be rewritten when the file changes. A
directory's children are read from the disk the first time anything asks
and kept, so a second listing costs no sectors. Nothing else writes the
volume while this serves it, which is what makes keeping them safe. The
tree is then the same shape `memfs` keeps, with the disk behind it instead
of the heap, and the 9P half of this file is nearly that program's.

## Write-through

Every change goes to the disk as it is made: a table entry when a cluster
is claimed, the directory entry when a size changes, the data when it is
written. The host is watching this volume through QEMU and a change that
sits in a cache is a change the host may never see. It costs a write per
step where a filesystem of Vectra's own will batch, and `docs/SHELL.md`
step 7 is where that filesystem is.
*/
package fatfs

import "vsys:abi"
import "vsys:libuser"
import "vsys:vectra9"

FRAME :: 8192 + 256
frame_in: [FRAME]u8
frame_out: [FRAME]u8
payload: [8192]u8

Node :: struct {
	name:     string, // On the heap
	dir:      bool,
	parent:   ^Node,
	attr:     u8,
	cluster:  u32, // First cluster; zero for an empty file or the FAT12/16 root
	size:     u32,
	slot:     int, // Where its 8.3 entry is in the parent, and how many entries
	nslots:   int,
	children: [dynamic]^Node,
	loaded:   bool, // Children read from the disk
	qid:      u64,
	version:  u32,
	removed:  bool,
	fids:     int,
	// Where the last read left off, so a file read in order walks its chain
	// once rather than from the start per request.
	hint_index:   u32,
	hint_cluster: u32,
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
	if len(args) < 2 {
		libuser.eprint("usage: fatfs device [srvname]\n")
		libuser.exits("usage")
	}
	device := args[1]
	name := "/srv/esp"
	if len(args) > 2 {
		name = args[2]
	}

	fd := libuser.open(device, abi.O_RDWR)
	if fd < 0 {
		libuser.eprint("fatfs: can't open ", device, ": ", libuser.errstr(fd), "\n")
		libuser.exits("open")
	}
	ok, why := mount_volume(int(fd))
	if !ok {
		libuser.eprint("fatfs: ", device, ": ", why, "\n")
		libuser.exits("not fat")
	}

	root = new(Node)
	root.dir = true
	root.parent = root
	root.attr = ATTR_DIRECTORY
	root.cluster = vol.kind == .FAT32 ? vol.root_cluster : 0
	root.qid = next_qid
	next_qid += 1

	sfd, perr := libuser.post(name)
	if perr < 0 {
		libuser.eprint("fatfs: can't post ", name, ": ", libuser.errstr(perr), "\n")
		libuser.exits("post")
	}

	pid := libuser.rfork(abi.RFPROC | abi.RFFDG | abi.RFNOWAIT)
	if pid < 0 {
		libuser.eprint("fatfs: fork failed\n")
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
		libuser.eprint("fatfs: torn frame\n")
		libuser.exits("broken")
	}
}

// -- Nodes ----------------------------------------------------------------------

qid_of :: proc(n: ^Node) -> vectra9.Qid {
	kind: vectra9.Qid_Flags
	if n.dir {
		kind = {.Dir}
	}
	return vectra9.Qid{kind = kind, path = n.qid, version = n.version}
}

dir_of :: proc "contextless" (n: ^Node) -> Dir {
	return Dir(n.cluster)
}

// load_children reads a directory from the disk the first time it is asked
// about. False if the disk would not read.
load_children :: proc(d: ^Node) -> bool {
	if d.loaded {
		return true
	}
	s := scan_start(dir_of(d))
	for {
		e: Entry
		more, ok := scan_next(&s, &e)
		if !ok {
			return false
		}
		if !more {
			break
		}
		n := new(Node)
		n.name = e.name
		n.dir = e.dir
		n.parent = d
		n.attr = e.attr
		n.cluster = e.cluster
		n.size = e.size
		n.slot = e.slot
		n.nslots = e.nslots
		n.qid = next_qid
		next_qid += 1
		append(&d.children, n)
	}
	d.loaded = true
	return true
}

child_named :: proc(d: ^Node, name: string) -> ^Node {
	for c in d.children {
		if names_equal(c.name, name) {
			return c
		}
	}
	return nil
}

// entry_of is a node's directory entry, for the writers in `dir.odin`.
entry_of :: proc "contextless" (n: ^Node) -> Entry {
	return Entry {
		name    = n.name,
		dir     = n.dir,
		attr    = n.attr,
		cluster = n.cluster,
		size    = n.size,
		slot    = n.slot,
		nslots  = n.nslots,
	}
}

// sync_entry writes a node's cluster, size and attributes to its directory
// entry on the disk.
sync_entry :: proc(n: ^Node) -> bool {
	if n == root {
		return true
	}
	e := entry_of(n)
	return update_entry(dir_of(n.parent), &e)
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

release_node :: proc(n: ^Node) {
	if n == nil || !n.removed || n.fids > 0 || n == root {
		return
	}
	delete(n.name)
	delete(n.children)
	free(n)
}

// -- File data ------------------------------------------------------------------

// cluster_at finds the cluster holding byte `off` of `n`, starting from the
// hint when it helps. False past the end of the chain or on a bad table.
cluster_at :: proc(n: ^Node, off: u32) -> (c: u32, ok: bool) {
	if n.cluster == 0 {
		return 0, false
	}
	want := off / vol.cluster_bytes
	c = n.cluster
	idx := u32(0)
	if n.hint_cluster != 0 && n.hint_index <= want {
		c = n.hint_cluster
		idx = n.hint_index
	}
	for idx < want {
		next, end, good := next_cluster(c)
		if !good || end {
			return 0, false
		}
		c = next
		idx += 1
	}
	n.hint_index = idx
	n.hint_cluster = c
	return c, true
}

// file_read fills `buf` from byte `off` of the file, as much as there is.
file_read :: proc(n: ^Node, off: u64, buf: []u8) -> (got: int, ok: bool) {
	if off >= u64(n.size) {
		return 0, true
	}
	want := int(min(u64(len(buf)), u64(n.size) - off))
	pos := u32(off)
	for got < want {
		c, found := cluster_at(n, pos)
		if !found {
			return got, false
		}
		within := pos % vol.cluster_bytes
		take := min(int(vol.cluster_bytes - within), want - got)
		if !read_at(cluster_offset(c) + u64(within), buf[got:got + take]) {
			return got, false
		}
		got += take
		pos += u32(take)
	}
	return got, true
}

// last_cluster walks to the end of a file's chain, answering the last
// cluster and how many there are.
last_cluster :: proc(n: ^Node) -> (last: u32, count: u32, ok: bool) {
	if n.cluster == 0 {
		return 0, 0, true
	}
	c := n.cluster
	count = 1
	for {
		next, end, good := next_cluster(c)
		if !good {
			return 0, 0, false
		}
		if end {
			return c, count, true
		}
		c = next
		count += 1
	}
}

// ensure_clusters makes the file's chain at least `want` clusters long.
ensure_clusters :: proc(n: ^Node, want: u32) -> bool {
	last, count, ok := last_cluster(n)
	if !ok {
		return false
	}
	for count < want {
		fresh, got := alloc_cluster(last)
		if !got {
			return false
		}
		if n.cluster == 0 {
			n.cluster = fresh
		}
		last = fresh
		count += 1
	}
	return true
}

// zero_range writes zeros over `[from, to)` of the file, for a write past
// the end that opens a gap the specification says must read as zero.
zero_range :: proc(n: ^Node, from, to: u32) -> bool {
	zeros: [SECTOR]u8
	pos := from
	for pos < to {
		c, found := cluster_at(n, pos)
		if !found {
			return false
		}
		within := pos % vol.cluster_bytes
		take := min(min(vol.cluster_bytes - within, to - pos), SECTOR)
		if !write_at(cluster_offset(c) + u64(within), zeros[:take]) {
			return false
		}
		pos += take
	}
	return true
}

/*
file_write puts `data` at byte `off`, growing the chain and the size as it
must. The table and the entry are written as they change, so a write that
fails midway leaves a file whose size says what was written and a chain to
match.
*/
file_write :: proc(n: ^Node, off: u64, data: []u8) -> (put: int, ok: bool) {
	if len(data) == 0 {
		return 0, true
	}
	end := off + u64(len(data))
	if end > 0xFFFF_FFFF {
		return 0, false
	}
	clusters_needed := u32((end + u64(vol.cluster_bytes) - 1) / u64(vol.cluster_bytes))
	if !ensure_clusters(n, clusters_needed) {
		return 0, false
	}
	if u32(off) > n.size {
		if !zero_range(n, n.size, u32(off)) {
			return 0, false
		}
	}
	pos := u32(off)
	for put < len(data) {
		c, found := cluster_at(n, pos)
		if !found {
			break
		}
		within := pos % vol.cluster_bytes
		take := min(int(vol.cluster_bytes - within), len(data) - put)
		at := cluster_offset(c) + u64(within)
		if !write_at(at, data[put:put + take]) {
			break
		}
		invalidate_range(at, take)
		put += take
		pos += u32(take)
	}
	if u32(off) + u32(put) > n.size {
		n.size = u32(off) + u32(put)
	}
	n.version += 1
	if !sync_entry(n) {
		return put, false
	}
	return put, put == len(data)
}

// truncate sets a file's size, freeing the clusters past the new end or
// zero-filling up to it.
truncate :: proc(n: ^Node, want: u32) -> bool {
	if want > n.size {
		clusters_needed := (want + vol.cluster_bytes - 1) / vol.cluster_bytes
		if !ensure_clusters(n, clusters_needed) {
			return false
		}
		if !zero_range(n, n.size, want) {
			return false
		}
	} else if want < n.size {
		keep := (want + vol.cluster_bytes - 1) / vol.cluster_bytes
		if keep == 0 {
			if n.cluster != 0 && !free_chain(n.cluster) {
				return false
			}
			n.cluster = 0
		} else {
			c, found := cluster_at(n, (keep - 1) * vol.cluster_bytes)
			if !found {
				return false
			}
			next, end, good := next_cluster(c)
			if !good {
				return false
			}
			if !end {
				if !fat_set(c, end_mark()) || !free_chain(next) {
					return false
				}
			}
		}
		n.hint_cluster = 0
		n.hint_index = 0
	}
	n.size = want
	n.version += 1
	return sync_entry(n)
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

// live_node is the fid's node, or an error into the reply.
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

// mode_of is the Plan 9 view of a FAT file: everyone may read and write it,
// less write when the read-only attribute is set, and a directory is
// searchable. `dossrv` reports the same.
mode_of :: proc "contextless" (n: ^Node) -> u32 {
	if n.dir {
		return 0o040000 | 0o777
	}
	if n.attr & ATTR_READ_ONLY != 0 {
		return 0o100000 | 0o444
	}
	return 0o100000 | 0o666
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

// new_child is the checks a create and a mkdir share, then the entry on the
// disk and the node for it. Nil with the error in the reply.
new_child :: proc(fid: vectra9.Fid, name: string, dir: bool, reply: ^vectra9.Msg) -> ^Node {
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

	cluster := u32(0)
	attr := ATTR_ARCHIVE
	if dir {
		c, ok := alloc_cluster(0)
		if !ok {
			reply^ = vectra9.error_reply(vectra9.ENOSPC)
			return nil
		}
		if !zero_cluster(c) || !init_dir(c, dir_of(d)) {
			_ = free_chain(c)
			reply^ = vectra9.error_reply(vectra9.EIO)
			return nil
		}
		cluster = c
		attr = ATTR_DIRECTORY
	}
	e, ok := add_entry(dir_of(d), name, attr, cluster, 0)
	if !ok {
		if cluster != 0 {
			_ = free_chain(cluster)
		}
		reply^ = vectra9.error_reply(vectra9.ENOSPC)
		return nil
	}
	n := new(Node)
	n.name = e.name
	n.dir = dir
	n.parent = d
	n.attr = attr
	n.cluster = cluster
	n.slot = e.slot
	n.nslots = e.nslots
	n.qid = next_qid
	n.loaded = dir // A fresh directory has nothing to read.
	next_qid += 1
	append(&d.children, n)
	d.version += 1
	return n
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
		n := new_child(m.fid, m.name, false, reply)
		if n == nil {
			return
		}
		fid_bind(m.fid, n)
		fid_slot(m.fid).open = true
		reply^ = vectra9.Rlcreate{qid = qid_of(n), iounit = 0}

	case vectra9.Tmkdir:
		n := new_child(m.dfid, m.name, true, reply)
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
		if !n.dir && m.flags & 0o3 != 0 && n.attr & ATTR_READ_ONLY != 0 {
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
			empty, ok := dir_empty(dir_of(n))
			if !ok {
				reply^ = vectra9.error_reply(vectra9.EIO)
				return
			}
			if !empty {
				reply^ = vectra9.error_reply(vectra9.ENOTEMPTY)
				return
			}
		}
		e := entry_of(n)
		if !remove_entry(dir_of(n.parent), &e) {
			reply^ = vectra9.error_reply(vectra9.EIO)
			return
		}
		if n.cluster != 0 {
			_ = free_chain(n.cluster)
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
			size    = n.dir ? 0 : u64(n.size),
			blksize = u64(vol.cluster_bytes),
		}
		attr.blocks = (attr.size + 511) / 512
		reply^ = attr

	case vectra9.Tsetattr:
		n := live_node(m.fid, reply)
		if n == nil {
			return
		}
		if m.valid & 0x1 != 0 && !n.dir {
			// The one permission FAT keeps: no write bit is read-only.
			if m.mode & 0o222 == 0 {
				n.attr |= ATTR_READ_ONLY
			} else {
				n.attr &= ~ATTR_READ_ONLY
			}
			if !sync_entry(n) {
				reply^ = vectra9.error_reply(vectra9.EIO)
				return
			}
		}
		if m.valid & 0x8 != 0 && !n.dir {
			if m.size > 0xFFFF_FFFF {
				reply^ = vectra9.error_reply(vectra9.ENOSPC)
				return
			}
			if !truncate(n, u32(m.size)) {
				reply^ = vectra9.error_reply(vectra9.EIO)
				return
			}
		}
		reply^ = vectra9.Rsetattr{}

	case vectra9.Tstatfs:
		reply^ = vectra9.Rstatfs {
			type    = 0x4d44, // MSDOS_SUPER_MAGIC, as Linux reports a FAT
			bsize   = u32(vol.cluster_bytes),
			blocks  = u64(vol.clusters),
			bfree   = u64(vol.free_clusters),
			bavail  = u64(vol.free_clusters),
			namelen = NAME_MAX,
		}

	case vectra9.Tfsync:
		// Everything is written through; there is nothing to flush.
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

// readdir lists a directory. The cookie is the child's qid, never reused,
// so a listing paced across a removal neither skips nor repeats; the list
// is in qid order because children are appended as seen and removed in
// place.
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
	first := 0
	for first < len(d.children) && d.children[first].qid <= m.offset {
		first += 1
	}
	for child in d.children[first:] {
		if vectra9.remaining(&c) < vectra9.dirent_size(child.name) {
			break
		}
		vectra9.put_dirent(
			&c,
			vectra9.Dirent {
				qid = qid_of(child),
				offset = child.qid,
				type = child.dir ? vectra9.DT_DIR : vectra9.DT_REG,
				name = child.name,
			},
		)
	}
	if c.err != .None {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}
	reply^ = vectra9.Rreaddir{data = vectra9.written(&c)}
}
