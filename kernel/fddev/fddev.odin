/*
`#d` -- a process's own descriptors, as files. Bound at `/fd`.

`/fd/0`, `/fd/1`, `/fd/2` and the rest are this process's open descriptors,
each a file that reads and writes wherever that descriptor points -- a pipe, a
console, a file on a mounted disk. Plan 9's `#d`, and the reason `cpu` can put a
remote command's standard input and output on the terminal's: the terminal
exports `/fd`, and the far shell opens `/mnt/term/fd/{0,1,2}`. `docs/FLEET.md`
section 7.

The device is synchronous, its handler on the caller's own thread. That is what
lets an open read the descriptor out of **the calling process's** table -- the
same reason `/srv` is synchronous and takes its descriptor the same way. An open
captures the descriptor's channel then and there, with a reference of its own, so
a later read or write reaches it through the io proc or worker that a served
client's read arrives on, where the caller is no longer the process that owns the
number. A read may park -- a console waits for a key -- and parks only the thread
it is on, because the handler holds no lock across it.
*/
package fddev

import "kernel:mem"
import "kernel:sync"
import "kernel:vfs"

import "vsys:vectra9"

// The root is a directory; a descriptor `n` is the node `n + 1`, so the root's
// own zero is not a descriptor's.
ROOT_ID :: i32(0)

// Descriptors this device will name. A number past it is a descriptor no table
// holds, and the resolver refuses it anyway.
MAX_FD :: 256

// Open fids at once, across every client of this one device.
FD_MAX_FIDS :: 64

// How a descriptor number becomes its channel: registered by `kernel/user`,
// which owns descriptor tables, and asked for the calling process's own. Nil
// until userland exists. The channel comes back with a reference of its own.
Fd_Resolver :: #type proc "contextless" (fd: int) -> (c: ^vfs.Chan, pid: u64)

@(private)
fd_resolver: Fd_Resolver

set_fd_resolver :: proc "contextless" (r: Fd_Resolver) {
	fd_resolver = r
}

// One open fid's captured channel: the descriptor it named, taken at open.
@(private)
Open_Fd :: struct {
	used: bool,
	fid:  vectra9.Fid,
	chan: ^vfs.Chan,
}

@(private)
Fd_Tree :: struct {
	fids:   vfs.Fid_Table,
	opens:  [FD_MAX_FIDS]Open_Fd,
	lock:   sync.Spinlock,
	server: vfs.Server,
}

@(private)
fd_tree: Fd_Tree

/*
init brings `#d` up and binds it at `/fd`. Every process's namespace carries it,
because the descriptors it names are each process's own -- the device answers for
whoever opens it, not for one owner.
*/
init :: proc(ns: ^vfs.Namespace) -> vfs.Errno {
	t := &fd_tree
	if !vfs.fidtab_init(&t.fids, FD_MAX_FIDS) {
		return vectra9.ENOMEM
	}
	if err := vfs.server_init(&t.server, "d", fd_handler, t); err != .None {
		vfs.fidtab_destroy(&t.fids)
		return vectra9.EPROTO
	}
	if !vfs.register_device(&t.server) {
		vfs.fidtab_destroy(&t.fids)
		return vectra9.EEXIST
	}
	return vfs.mount_device(ns, "#d", "/fd")
}

// -- The captured-channel table -------------------------------------------------

// remember stores the channel an open captured, under the fid. Caller holds the
// lock. False when the table is full.
@(private)
remember :: proc "contextless" (t: ^Fd_Tree, fid: vectra9.Fid, c: ^vfs.Chan) -> bool #no_bounds_check {
	for i in 0 ..< FD_MAX_FIDS {
		if !t.opens[i].used {
			t.opens[i] = Open_Fd{used = true, fid = fid, chan = c}
			return true
		}
	}
	return false
}

// borrow answers the channel a fid captured, with a fresh reference the caller
// closes when done -- so a read may run without the lock, and a clunk between
// the two frees the capture without freeing it under the read. Caller holds the
// lock; the incref is under it.
@(private)
borrow :: proc "contextless" (t: ^Fd_Tree, fid: vectra9.Fid) -> ^vfs.Chan #no_bounds_check {
	for i in 0 ..< FD_MAX_FIDS {
		if t.opens[i].used && t.opens[i].fid == fid {
			return vfs.chan_incref(t.opens[i].chan)
		}
	}
	return nil
}

// forget takes a fid's captured channel out of the table and answers it, for the
// caller to close outside the lock. Caller holds the lock.
@(private)
forget :: proc "contextless" (t: ^Fd_Tree, fid: vectra9.Fid) -> ^vfs.Chan #no_bounds_check {
	for i in 0 ..< FD_MAX_FIDS {
		if t.opens[i].used && t.opens[i].fid == fid {
			c := t.opens[i].chan
			t.opens[i] = {}
			return c
		}
	}
	return nil
}

// -- The walk -------------------------------------------------------------------

@(private)
qid_of_id :: proc "contextless" (id: i32) -> vectra9.Qid {
	kind: vectra9.Qid_Flags
	if id == ROOT_ID {
		kind = {.Dir}
	}
	return vectra9.Qid{kind = kind, path = u64(id)}
}

@(private)
walk_qid :: proc "contextless" (ctx: rawptr, node: i32) -> vectra9.Qid {
	_ = ctx
	return qid_of_id(node)
}

// step walks one name. From the root, a decimal `n` in range names descriptor
// `n`, node `n + 1`. A descriptor is a file, and nothing walks out of one.
@(private)
step :: proc "contextless" (ctx: rawptr, from: i32, name: string) -> i32 {
	_ = ctx
	switch name {
	case ".":
		return from
	case "..":
		return ROOT_ID
	}
	if from != ROOT_ID {
		return -1
	}
	n, ok := parse_fd(name)
	if !ok {
		return -1
	}
	return i32(n) + 1
}

// parse_fd reads a plain decimal in `[0, MAX_FD)`. No sign, no space, no empty.
@(private)
parse_fd :: proc "contextless" (s: string) -> (int, bool) #no_bounds_check {
	if len(s) == 0 {
		return 0, false
	}
	n := 0
	for i in 0 ..< len(s) {
		if s[i] < '0' || s[i] > '9' {
			return 0, false
		}
		n = n * 10 + int(s[i] - '0')
		if n >= MAX_FD {
			return 0, false
		}
	}
	return n, true
}

// -- The handler ----------------------------------------------------------------

@(private)
fd_handler :: proc "contextless" (
	server: rawptr,
	s: ^vectra9.Session,
	tag: vectra9.Tag,
	request: ^vectra9.Msg,
	reply: ^vectra9.Msg,
	buf: []u8,
) {
	_ = s
	_ = tag
	t := cast(^Fd_Tree)server
	if t == nil {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}
	// A context, because two arms touch chans and chan bookkeeping is context
	// code. The reads and writes below build it too, after the lock is dropped.
	context = mem.kernel_context()

	reply^ = vectra9.error_reply(vectra9.EOPNOTSUPP)

	#partial switch m in request^ {
	case vectra9.Tversion:
		vectra9.version_reply(m, reply)

	case vectra9.Tattach:
		g := sync.acquire(&t.lock)
		bound := vfs.fidtab_bind(&t.fids, m.fid, ROOT_ID)
		sync.release(&t.lock, g)
		if !bound {
			reply^ = vectra9.error_reply(vectra9.ENFILE)
			return
		}
		reply^ = vectra9.Rattach{qid = qid_of_id(ROOT_ID)}

	case vectra9.Twalk:
		g := sync.acquire(&t.lock)
		vfs.fidtab_walk(&t.fids, m, reply, t, step, walk_qid)
		sync.release(&t.lock, g)

	case vectra9.Tlopen:
		fd_open(t, m, reply)

	case vectra9.Tread:
		fd_read(t, m, reply, buf)

	case vectra9.Twrite:
		fd_write(t, m, reply)

	case vectra9.Tgetattr:
		g := sync.acquire(&t.lock)
		node := vfs.fidtab_node(&t.fids, m.fid)
		sync.release(&t.lock, g)
		if node < 0 {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		dir := node == ROOT_ID
		reply^ = vectra9.Rgetattr {
			valid   = m.request_mask & vfs.GETATTR_BASIC,
			qid     = qid_of_id(node),
			mode    = dir ? vectra9.S_IFDIR | 0o555 : vectra9.S_IFREG | 0o600,
			nlink   = dir ? 2 : 1,
			blksize = 512,
		}

	case vectra9.Treaddir:
		// The listing is empty: `cpu` reaches a descriptor by name, not by
		// reading the directory, and a process's live descriptors are not a
		// list this device keeps. A read of a descriptor's file is the point.
		reply^ = vectra9.Rreaddir{data = nil}

	case vectra9.Tclunk:
		g := sync.acquire(&t.lock)
		_ = vfs.fidtab_release(&t.fids, m.fid)
		gone := forget(t, m.fid)
		sync.release(&t.lock, g)
		if gone != nil {
			vfs.chan_close(gone)
		}
		reply^ = vectra9.Rclunk{}

	case vectra9.Tflush:
		reply^ = vectra9.Rflush{}
	}
}

// fd_open captures the descriptor's channel now, on the calling process's own
// thread, so the number is judged against that process's table.
@(private)
fd_open :: proc (t: ^Fd_Tree, m: vectra9.Tlopen, reply: ^vectra9.Msg) {
	g := sync.acquire(&t.lock)
	node := vfs.fidtab_node(&t.fids, m.fid)
	sync.release(&t.lock, g)
	if node < 0 {
		reply^ = vectra9.error_reply(vectra9.EBADF)
		return
	}
	if node == ROOT_ID {
		if m.flags & 0o3 != vfs.O_RDONLY {
			reply^ = vectra9.error_reply(vectra9.EISDIR)
			return
		}
		g2 := sync.acquire(&t.lock)
		vfs.fidtab_set_open(&t.fids, m.fid, true)
		sync.release(&t.lock, g2)
		reply^ = vectra9.Rlopen{qid = qid_of_id(node)}
		return
	}
	if fd_resolver == nil {
		reply^ = vectra9.error_reply(vectra9.EBADF)
		return
	}
	c, _ := fd_resolver(int(node - 1))
	if c == nil {
		reply^ = vectra9.error_reply(vectra9.EBADF)
		return
	}
	g3 := sync.acquire(&t.lock)
	kept := remember(t, m.fid, c)
	if kept {
		vfs.fidtab_set_open(&t.fids, m.fid, true)
	}
	sync.release(&t.lock, g3)
	if !kept {
		vfs.chan_close(c)
		reply^ = vectra9.error_reply(vectra9.ENFILE)
		return
	}
	reply^ = vectra9.Rlopen{qid = qid_of_id(node)}
}

// fd_read reads the captured channel. The channel is borrowed under the lock and
// read without it, because a descriptor on a console parks until a key and must
// park no other client's request.
@(private)
fd_read :: proc (t: ^Fd_Tree, m: vectra9.Tread, reply: ^vectra9.Msg, buf: []u8) {
	g := sync.acquire(&t.lock)
	if !vfs.fidtab_is_open(&t.fids, m.fid) {
		sync.release(&t.lock, g)
		reply^ = vectra9.error_reply(vectra9.EINVAL)
		return
	}
	c := borrow(t, m.fid)
	sync.release(&t.lock, g)
	if c == nil {
		// The root directory, or a fid clunked out from under this read.
		reply^ = vectra9.Rread{data = nil}
		return
	}
	room := min(len(buf), int(m.count))
	n, err := vfs.chan_read(c, m.offset, buf[:room])
	vfs.chan_close(c)
	if err != vfs.OK {
		reply^ = vectra9.error_reply(err)
		return
	}
	reply^ = vectra9.Rread{data = buf[:n]}
}

// fd_write writes the captured channel, borrowed the same way.
@(private)
fd_write :: proc (t: ^Fd_Tree, m: vectra9.Twrite, reply: ^vectra9.Msg) {
	g := sync.acquire(&t.lock)
	if !vfs.fidtab_is_open(&t.fids, m.fid) {
		sync.release(&t.lock, g)
		reply^ = vectra9.error_reply(vectra9.EINVAL)
		return
	}
	c := borrow(t, m.fid)
	sync.release(&t.lock, g)
	if c == nil {
		reply^ = vectra9.error_reply(vectra9.EINVAL)
		return
	}
	n, err := vfs.chan_write(c, m.offset, m.data)
	vfs.chan_close(c)
	if err != vfs.OK {
		reply^ = vectra9.error_reply(err)
		return
	}
	reply^ = vectra9.Rwrite{count = u32(n)}
}
