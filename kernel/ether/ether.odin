/*
`#E`: the network card, as files under `/dev/ether`.

    /dev/ether/addr    the card's hardware address, six bytes, read-only
    /dev/ether/data    a frame per read, a frame per write

This is to the virtio-net card what `#S` is to the disk: the join between a
polled driver and a ring 3 server. `docs/FLEET.md` step 0's `netfs` opens
`data`, and every read hands it one received frame and every write sends one. A
read of `data` with no frame ready answers zero bytes rather than parking. So
`netfs` polls it from a thread of its own, the way its io procs park on the
files that do block. The card is the kernel's, and the stack over it is not.

**One frame to a message, and small for now.** A read returns whatever fits the
transport's slot, which is under a full ethernet frame today. ARP and a ping
fit, and that is the increment this serves. A larger `iounit`, or a frame split
across reads, is what TCP's full segments will want, and waits with them.

The 9P server is `#S`'s, one file kind shorter: a flat directory of two files,
no partitions and no per-disk subtree. What differs is only what a read and a
write do, which is a frame in and a frame out rather than a sector.
*/
package ether

import "base:runtime"

import "kernel:drivers/virtio"
import "kernel:mem"
import "kernel:sync"
import "kernel:vfs"
import "vsys:vectra9"

ETHER_MAX_FIDS :: 16

// How long a read of `data` waits for a frame before answering empty, in
// scheduler ticks. Long enough that a caller is not spinning, short enough
// that it is still a read that returns.
ETHER_WAIT_TICKS :: 50

S_IFDIR :: u32(0o040000)
S_IFREG :: u32(0o100000)

/*
The nodes. The root holds one directory named `ether`, and the two files live
under it, so the mount at `/dev` gives `/dev/ether/addr` and `/dev/ether/data`.
A device's root is bound *at* `/dev`. A file directly under the root would be
`/dev/addr`, which is why `#S` names a directory per disk and this names one for
the card.
*/
ROOT :: i32(0)
NODE_DIR :: i32(1)
NODE_ADDR :: i32(2)
NODE_DATA :: i32(3)

@(private = "file")
Ether_Device :: struct {
	fids:   vfs.Fid_Table,
	lock:   sync.Spinlock,
	server: vfs.Server,
	reads:  u64,
	writes: u64,
}

@(private = "file")
dev: Ether_Device

/*
init brings up `#E` over the virtio-net card, if one came up, and binds it into
`/dev` after `#c`. A machine with no card gets no `#E`, the way it gets no
`/dev/sd0`, and `netfs` then finds nothing to open.
*/
init :: proc(ns: ^vfs.Namespace) -> vfs.Errno {
	if !virtio.net_present(0) {
		return vfs.OK
	}
	d := &dev
	if !vfs.fidtab_init(&d.fids, ETHER_MAX_FIDS) {
		return vectra9.ENOMEM
	}
	if err := vfs.server_init(&d.server, "E", ether_handler, d); err != .None {
		vfs.fidtab_destroy(&d.fids)
		return vectra9.EPROTO
	}
	if !vfs.register_device(&d.server) {
		vfs.fidtab_destroy(&d.fids)
		return vectra9.EEXIST
	}
	return vfs.mount_device(ns, "#E", "/dev", .After)
}

present :: proc "contextless" () -> bool {
	return virtio.net_present(0)
}

stats :: proc "contextless" () -> (reads, writes: u64) {
	g := sync.acquire(&dev.lock)
	defer sync.release(&dev.lock, g)
	return dev.reads, dev.writes
}

// -- The node tree ------------------------------------------------------------

node_is_dir :: proc "contextless" (node: i32) -> bool {
	return node == ROOT || node == NODE_DIR
}

qid_of :: proc "contextless" (node: i32) -> vectra9.Qid {
	kind: vectra9.Qid_Flags
	if node_is_dir(node) {
		kind = {.Dir}
	}
	return vectra9.Qid{kind = kind, path = u64(node) + 1}
}

step :: proc "contextless" (from: i32, name: string) -> i32 {
	if name == "." {
		return from
	}
	switch from {
	case ROOT:
		switch name {
		case "..":
			return ROOT
		case "ether":
			return NODE_DIR
		}
	case NODE_DIR:
		switch name {
		case "..":
			return ROOT
		case "addr":
			return NODE_ADDR
		case "data":
			return NODE_DATA
		}
	case:
		if name == ".." {
			return NODE_DIR
		}
	}
	return -1
}

attr_of :: proc "contextless" (node: i32, mask: u64) -> vectra9.Rgetattr {
	dir := node_is_dir(node)
	mode: u32
	size: u64
	if dir {
		mode = S_IFDIR | 0o555
	} else if node == NODE_ADDR {
		mode = S_IFREG | 0o444
		size = 6
	} else {
		mode = S_IFREG | 0o666
	}
	return vectra9.Rgetattr {
		valid   = mask & vfs.GETATTR_BASIC,
		qid     = qid_of(node),
		mode    = mode,
		nlink   = dir ? 2 : 1,
		size    = size,
		blksize = 2048,
	}
}

// -- The handler --------------------------------------------------------------

ether_handler :: proc "contextless" (
	server: rawptr,
	s: ^vectra9.Session,
	tag: vectra9.Tag,
	request: ^vectra9.Msg,
	reply: ^vectra9.Msg,
	buf: []u8,
) {
	_ = server
	_ = s
	_ = tag
	ctx := runtime.default_context()
	ctx.allocator = mem.allocator()
	context = ctx

	#partial switch m in request^ {
	case vectra9.Tread:
		do_read(m, reply, buf)
		return
	case vectra9.Twrite:
		do_write(m, reply)
		return
	}
	dispatch(request, reply, buf)
}

do_read :: proc(m: vectra9.Tread, reply: ^vectra9.Msg, buf: []u8) #no_bounds_check {
	d := &dev
	g := sync.acquire(&d.lock)
	node := vfs.fidtab_node(&d.fids, m.fid)
	open := node >= 0 && vfs.fidtab_is_open(&d.fids, m.fid)
	sync.release(&d.lock, g)

	if node < 0 {
		reply^ = vectra9.error_reply(vectra9.EBADF)
		return
	}
	if !open {
		reply^ = vectra9.error_reply(vectra9.EINVAL)
		return
	}
	if node_is_dir(node) {
		reply^ = vectra9.error_reply(vectra9.EISDIR)
		return
	}
	room := min(len(buf), int(m.count))

	if node == NODE_ADDR {
		// The six-byte hardware address, at the offset the read names.
		mac: [6]u8
		_ = virtio.mac(0, mac[:])
		off := int(m.offset)
		if off >= 6 || room == 0 {
			reply^ = vectra9.Rread{data = buf[:0]}
			return
		}
		n := min(6 - off, room)
		for i in 0 ..< n {
			buf[i] = mac[off + i]
		}
		reply^ = vectra9.Rread{data = buf[:n]}
		return
	}

	/*
	NODE_DATA: one received frame. The card is polled, so this waits for one
	rather than answering empty at once: a tick at a time, up to a bound. A
	reader then parks in the kernel instead of spinning in ring 3, and a frame
	comes back within a tick of arriving. The bound keeps the wait finite, and
	a reader that gets nothing simply asks again.
	*/
	n := 0
	for _ in 0 ..< ETHER_WAIT_TICKS {
		n = virtio.recv(0, buf[:room])
		if n > 0 {
			break
		}
		sync.delay(1)
	}
	if n > 0 {
		g2 := sync.acquire(&d.lock)
		d.reads += 1
		sync.release(&d.lock, g2)
	}
	reply^ = vectra9.Rread{data = buf[:n]}
}

do_write :: proc(m: vectra9.Twrite, reply: ^vectra9.Msg) #no_bounds_check {
	d := &dev
	g := sync.acquire(&d.lock)
	node := vfs.fidtab_node(&d.fids, m.fid)
	open := node >= 0 && vfs.fidtab_is_open(&d.fids, m.fid)
	sync.release(&d.lock, g)

	if node < 0 {
		reply^ = vectra9.error_reply(vectra9.EBADF)
		return
	}
	if !open {
		reply^ = vectra9.error_reply(vectra9.EINVAL)
		return
	}
	if node != NODE_DATA {
		// The address is read-only, and a directory takes no write.
		reply^ = vectra9.error_reply(vectra9.EPERM)
		return
	}
	if !virtio.send(0, m.data) {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}
	g2 := sync.acquire(&d.lock)
	d.writes += 1
	sync.release(&d.lock, g2)
	reply^ = vectra9.Rwrite{count = u32(len(m.data))}
}

// -- The rest of 9P, `#S`'s ---------------------------------------------------

dispatch :: proc(request: ^vectra9.Msg, reply: ^vectra9.Msg, buf: []u8) #no_bounds_check {
	d := &dev
	reply^ = vectra9.error_reply(vectra9.EOPNOTSUPP)
	if vectra9.creates(vectra9.kind(request^)) {
		reply^ = vectra9.error_reply(vectra9.EPERM)
		return
	}

	g := sync.acquire(&d.lock)
	defer sync.release(&d.lock, g)

	#partial switch m in request^ {
	case vectra9.Tversion:
		vectra9.version_reply(m, reply)

	case vectra9.Tattach:
		if !vfs.fidtab_bind(&d.fids, m.fid, ROOT) {
			reply^ = vectra9.error_reply(vectra9.ENFILE)
			return
		}
		reply^ = vectra9.Rattach{qid = qid_of(ROOT)}

	case vectra9.Twalk:
		walk(m, reply)

	case vectra9.Tlopen:
		node := vfs.fidtab_node(&d.fids, m.fid)
		if node < 0 {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		if node_is_dir(node) && m.flags & 0o3 != vfs.O_RDONLY {
			reply^ = vectra9.error_reply(vectra9.EISDIR)
			return
		}
		vfs.fidtab_set_open(&d.fids, m.fid, true)
		reply^ = vectra9.Rlopen{qid = qid_of(node), iounit = 0}

	case vectra9.Treaddir:
		readdir(m, reply, buf)

	case vectra9.Tgetattr:
		node := vfs.fidtab_node(&d.fids, m.fid)
		if node < 0 {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		reply^ = attr_of(node, m.request_mask)

	case vectra9.Tstatfs:
		if vfs.fidtab_node(&d.fids, m.fid) < 0 {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		reply^ = vectra9.Rstatfs{type = 0x0139_9249, bsize = 2048, namelen = 16}

	case vectra9.Tremove:
		_ = vfs.fidtab_release(&d.fids, m.fid)
		reply^ = vectra9.error_reply(vectra9.EPERM)

	case vectra9.Tclunk:
		_ = vfs.fidtab_release(&d.fids, m.fid)
		reply^ = vectra9.Rclunk{}

	case vectra9.Tflush:
		_ = m
		reply^ = vectra9.Rflush{}
	}
}

walk :: proc(m: vectra9.Twalk, reply: ^vectra9.Msg) #no_bounds_check {
	d := &dev
	node := vfs.fidtab_node(&d.fids, m.fid)
	if node < 0 {
		reply^ = vectra9.error_reply(vectra9.EBADF)
		return
	}
	if vfs.fidtab_is_open(&d.fids, m.fid) {
		reply^ = vectra9.error_reply(vectra9.EBUSY)
		return
	}
	answer: vectra9.Rwalk
	cur := node
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
		if !vfs.fidtab_bind(&d.fids, m.newfid, cur) {
			reply^ = vectra9.error_reply(vectra9.ENFILE)
			return
		}
	}
	reply^ = answer
}

readdir :: proc(m: vectra9.Treaddir, reply: ^vectra9.Msg, buf: []u8) #no_bounds_check {
	d := &dev
	node := vfs.fidtab_node(&d.fids, m.fid)
	if node < 0 {
		reply^ = vectra9.error_reply(vectra9.EBADF)
		return
	}
	if !node_is_dir(node) {
		reply^ = vectra9.error_reply(vectra9.ENOTDIR)
		return
	}
	room := min(len(buf), int(m.count))
	c := vectra9.cursor_from(buf[:room])
	names: []string
	nodes: []i32
	if node == ROOT {
		names = []string{"ether"}
		nodes = []i32{NODE_DIR}
	} else {
		names = []string{"addr", "data"}
		nodes = []i32{NODE_ADDR, NODE_DATA}
	}
	for i := int(m.offset); i < len(names); i += 1 {
		if vectra9.remaining(&c) < vectra9.dirent_size(names[i]) {
			break
		}
		t := node_is_dir(nodes[i]) ? vectra9.DT_DIR : vectra9.DT_REG
		vectra9.put_dirent(
			&c,
			vectra9.Dirent{qid = qid_of(nodes[i]), offset = u64(i + 1), type = t, name = names[i]},
		)
	}
	if c.err != .None {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}
	reply^ = vectra9.Rreaddir{data = vectra9.written(&c)}
}
