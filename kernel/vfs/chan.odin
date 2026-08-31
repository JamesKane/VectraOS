/*
Chan -- a handle on a file in a namespace.

A fid names a file within one session. A `Chan` names a file within one
*namespace*, which is a larger claim. It knows which server answers. It also
carries the two fields for a walk of `..` out of a mounted tree. That walk
lands somewhere the server it just left never heard of.

Chans are reference counted and shared. `chan_clone` is the one that costs a
message. It is a Twalk with no names, which is 9P's way to ask for a second
handle on the same file. `chan_incref` is the one that costs nothing. Use clone
when the copy will be opened or walked independently, incref when it will not.
*/
package vfs

import "kernel:sync"
import "vsys:vectra9"

Chan :: struct {
	server: ^Server, // Whose session `fid` lives in
	fid:    vectra9.Fid,
	qid:    vectra9.Qid, // What the server calls this file

	/*
	Namespace bookkeeping, for `..` across a mount point.

	`tree_root` is the qid this chan's tree is rooted at and `mounted_over` is the
	chan that tree was mounted onto. When a walk of `..` arrives at a chan whose
	qid matches its own `tree_root`, there is nothing above it this server can
	name. The walk continues from `mounted_over` instead. See docs/VECTRA9.md
	section 5.5 for why the server cannot answer this itself.
	*/
	mounted_over: ^Chan,
	tree_root:    vectra9.Qid,

	/*
	The mount point this chan was reached through, if it was reached through
	one.

	Not in the design sketch, and needed by exactly one caller. `readdir` has to
	concatenate every member of a union, and cannot find them from here otherwise.

	By the time a caller holds the chan, `cross_mounts` already substituted the
	*first* member. The key the mount point is filed under, the file that
	something mounted over, is therefore no longer reachable from `server` and
	`qid`. Plan 9 keeps the same pointer on `Chan.umh`.

	A counted reference, not a bare pointer. An `unmount` of `/dev` entirely,
	while something still holds a chan reached through it, would otherwise free
	the mount point out from under this field. That is reachable today with no
	threads at all, from one chan held across an `unmount`. A dissolved mount
	point survives with an empty member list, so the chan goes on working on the
	member it is already standing on.
	*/
	union_head: ^Mount_Point,
	refs:       int,
	opened:     bool,

	// The server's chunk bound from `Rlopen`/`Rlcreate`, or zero for "no
	// promise". `chan_iounit` folds it into what a bulk caller chunks by.
	iounit: u32,
}

// Linux open flags, as 9P2000.L carries them. Only the ones a Vectra server
// currently distinguishes are named. The rest pass through untouched.
O_RDONLY :: u32(0o0)
O_WRONLY :: u32(0o1)
O_RDWR :: u32(0o2)
O_CREAT :: u32(0o100)
O_TRUNC :: u32(0o1000)
O_APPEND :: u32(0o2000)
O_DIRECTORY :: u32(0o200000)

@(private)
chan_alloc :: proc(sv: ^Server, fid: vectra9.Fid, qid: vectra9.Qid) -> ^Chan {
	c := new(Chan)
	if c == nil {
		return nil
	}
	c.server = sv
	c.fid = fid
	c.qid = qid

	// Until something says otherwise, a chan is at the root of its own tree.
	// `walk` overwrites this from the chan it came from, and `bind` sets it on
	// the member it stores. The default only matters for a fresh attach, where it
	// is exactly right.
	c.tree_root = qid
	c.refs = 1

	// The server's side of the count. A released server is one no chan
	// names, so every chan is counted in and counted out. See `Server`.
	if sv != nil {
		g := sync.acquire(&object_lock)
		sv.chans += 1
		sync.release(&object_lock, g)
	}
	return c
}

// chan_incref takes another reference. Nil-safe, because `mounted_over` is
// usually nil and every caller would otherwise have to say so.
chan_incref :: proc "contextless" (c: ^Chan) -> ^Chan {
	if c == nil {
		return nil
	}
	g := sync.acquire(&object_lock)
	c.refs += 1
	sync.release(&object_lock, g)
	return c
}

/*
chan_close drops a reference and clunks the fid when the last one goes.

Tclunk's reply is ignored on purpose. There is nothing to do about a server
that fails to release a fid. The fid is gone from our side either way, and a
close path that can fail is a close path callers get wrong.

The `mounted_over` chain is released here rather than by whoever built it. A
mounted tree's parent has to outlive every chan inside that tree, and only the
reference count knows when the last one is gone.
*/
chan_close :: proc(c: ^Chan) {
	c := c
	for c != nil {
		// The count comes down under the lock and the teardown happens
		// outside it, because the teardown sends a message. Whoever drives
		// the count to zero owns the object outright -- nobody else can find
		// it, so nothing below here needs the lock back.
		g := sync.acquire(&object_lock)
		c.refs -= 1
		last := c.refs <= 0
		sync.release(&object_lock, g)
		if !last {
			return
		}

		if c.union_head != nil {
			mount_point_release(c.union_head)
			c.union_head = nil
		}

		if c.fid != vectra9.NOFID {
			request := vectra9.Msg(vectra9.Tclunk{fid = c.fid})
			reply: vectra9.Msg
			_ = rpc(c.server, &request, &reply)
		}

		// Loop rather than recurse: mount nesting is unbounded and this runs
		// on a 16 KiB fault stack's worth of assumptions about depth.
		parent := c.mounted_over
		sv := c.server
		free(c)

		/*
		The server's count comes down after the clunk above went out, because
		the clunk still used the server's session. The last chan off a server
		nothing pins is what fires the release. It runs outside the lock,
		because a release tears a connection down, and that parks.
		*/
		if sv != nil {
			g2 := sync.acquire(&object_lock)
			sv.chans -= 1
			fire := server_should_release(sv)
			release := sv.release
			sync.release(&object_lock, g2)
			if fire {
				release(sv)
			}
		}
		c = parent
	}
}

// -- File operations ---------------------------------------------------------

/*
chan_open marks a chan open for reading or writing.

`iounit` is kept, because a bulk transfer chunks by it. It is the server's own
promise about one operation, not msize, which bounds the message. Zero means
the server made no promise, and `chan_iounit` answers with the frame bound
instead.
*/
chan_open :: proc(c: ^Chan, flags: u32) -> Errno {
	if c == nil {
		return vectra9.EBADF
	}
	request := vectra9.Msg(vectra9.Tlopen{fid = c.fid, flags = flags})
	reply: vectra9.Msg
	if e := rpc(c.server, &request, &reply); e != OK {
		return e
	}
	answer, ok := reply.(vectra9.Rlopen)
	if !ok {
		return vectra9.EPROTO
	}
	c.qid = answer.qid
	c.iounit = answer.iounit
	c.opened = true
	return OK
}

/*
chan_read reads at most len(buf) bytes from `offset` into `buf`.

`buf` is the storage the reply's payload is built in, rather than somewhere the
payload is copied to afterwards. A server that fills it in place is read with no
copy at all. One that answers out of its own `.rodata` is copied once, here,
which is the copy that always had to happen.

A short read is not an error and not the end of the file. Zero bytes is the end
of the file.
*/
chan_read :: proc(c: ^Chan, offset: u64, buf: []u8) -> (n: int, err: Errno) {
	if c == nil {
		return 0, vectra9.EBADF
	}
	if len(buf) == 0 {
		return 0, OK
	}

	count := u32(min(len(buf), max_payload(c.server)))
	request := vectra9.Msg(vectra9.Tread{fid = c.fid, offset = offset, count = count})
	reply: vectra9.Msg
	if e := rpc(c.server, &request, &reply, buf); e != OK {
		return 0, e
	}
	answer, ok := reply.(vectra9.Rread)
	if !ok {
		return 0, vectra9.EPROTO
	}
	return take_payload(buf, answer.data), OK
}

/*
chan_read_for is a read the caller may give up on, and it is the reason this
package moved onto `kernel/mnt`.

Returns EINTR when `ticks` passed with no answer. The request was flushed
first, so the server knows the tag is finished with and nothing will write into
`buf` afterwards. Walking away without that is what corrupts a client, and
`Tflush` exists to make it unnecessary.

A server with no workers has nothing to interrupt, and this is then an ordinary
read with a number attached. `chan_interruptible` reports which a caller has,
before it waits rather than after.
*/
chan_read_for :: proc(c: ^Chan, offset: u64, buf: []u8, ticks: u64) -> (n: int, err: Errno) {
	if c == nil {
		return 0, vectra9.EBADF
	}
	if len(buf) == 0 {
		return 0, OK
	}

	count := u32(min(len(buf), max_payload(c.server)))
	request := vectra9.Msg(vectra9.Tread{fid = c.fid, offset = offset, count = count})
	reply: vectra9.Msg
	if e := rpc_for(c.server, &request, &reply, ticks, buf); e != OK {
		return 0, e
	}
	answer, ok := reply.(vectra9.Rread)
	if !ok {
		return 0, vectra9.EPROTO
	}
	return take_payload(buf, answer.data), OK
}

// chan_interruptible reports whether a deadline on this chan's server means
// anything. See `chan_read_for`.
chan_interruptible :: proc "contextless" (c: ^Chan) -> bool {
	return c != nil && server_interruptible(c.server)
}

// chan_write writes `data` at `offset`, one message's worth at most. A caller
// with more than `chan_iounit` sends it in pieces. A `Twrite` serialised past
// the msize is a frame the transport refuses. That loud refusal beats a
// silent short count for a caller that forgot to chunk.
chan_write :: proc(c: ^Chan, offset: u64, data: []u8) -> (n: int, err: Errno) {
	if c == nil {
		return 0, vectra9.EBADF
	}
	request := vectra9.Msg(vectra9.Twrite{fid = c.fid, offset = offset, data = data})
	reply: vectra9.Msg
	if e := rpc(c.server, &request, &reply); e != OK {
		return 0, e
	}
	answer, ok := reply.(vectra9.Rwrite)
	if !ok {
		return 0, vectra9.EPROTO
	}
	return int(answer.count), OK
}

// chan_iounit is the most data one read or write of this chan moves at once.
// That is the iounit the server promised at open. When it promised nothing,
// it is the msize less the header a data message reserves. A caller with
// more loops, a chunk at a time. This is what `kernel/user` chunks a bulk
// transfer by.
chan_iounit :: proc "contextless" (c: ^Chan) -> int {
	if c == nil {
		return 0
	}
	unit := max_payload(c.server)
	if c.iounit > 0 && int(c.iounit) < unit {
		unit = int(c.iounit)
	}
	return unit
}

/*
chan_create asks the server to create a file in the directory this chan names.

**The fid mutates.** Tlcreate takes a fid on a directory, and on success the
same fid names the new file, open under `flags`. The chan follows: its qid
becomes the new file's, and it is marked open. That is 9P's shape rather than
a shortcut, and it is why a caller that wants to keep its handle on the
directory clones first. `create_path` in `walk.odin` resolves a fresh chan
per call, so it never has to.

`gid` is zero because nothing here has a group. The field goes on the wire
because the message has it, not because anything reads it back.

`/srv` is the first server to answer this, and posting a service is the first
thing creation is for. See `docs/SRV.md`.
*/
chan_create :: proc(c: ^Chan, name: string, flags: u32, mode: u32) -> Errno {
	if c == nil {
		return vectra9.EBADF
	}
	request := vectra9.Msg(vectra9.Tlcreate{fid = c.fid, name = name, flags = flags, mode = mode})
	reply: vectra9.Msg
	if e := rpc(c.server, &request, &reply); e != OK {
		return e
	}
	answer, ok := reply.(vectra9.Rlcreate)
	if !ok {
		return vectra9.EPROTO
	}
	c.qid = answer.qid
	c.iounit = answer.iounit
	c.opened = true
	return OK
}

/*
chan_remove asks the server to remove the file this chan names.

**The fid is gone either way, and that is 9P's rule rather than a convenience.**
Tremove clunks the fid whether or not the removal succeeds. A caller that
retried on failure would retry with a fid the server already released.
The chan is left holding NOFID, so `chan_close` does not clunk it a second time.

Still returns the error, because the caller has to know whether the file went.
The chan must still be closed afterwards: it is a reference like any other, and
only the count knows when the last one goes.

`kernel/srv` is the first server to implement Tremove, and `/srv` is the first
tree in Vectra a client may change. See `docs/SRV.md`.
*/
chan_remove :: proc(c: ^Chan) -> Errno {
	if c == nil {
		return vectra9.EBADF
	}
	if c.fid == vectra9.NOFID {
		return vectra9.EBADF
	}

	request := vectra9.Msg(vectra9.Tremove{fid = c.fid})
	reply: vectra9.Msg
	err := rpc(c.server, &request, &reply)

	// Before the answer is examined, because the fid is spent on both paths.
	c.fid = vectra9.NOFID

	if err != OK {
		return err
	}
	if _, ok := reply.(vectra9.Rremove); !ok {
		return vectra9.EPROTO
	}
	return OK
}

// The Tgetattr request masks a client can ask for. `BASIC` is what stat(2)
// needs, and what every Vectra server answers. A request for more is legal,
// and gets whatever the server chose to fill in. `valid` reports which that
// was.
GETATTR_MODE :: u64(0x0000_0001)
GETATTR_NLINK :: u64(0x0000_0004)
GETATTR_SIZE :: u64(0x0000_0200)
GETATTR_BASIC :: u64(0x0000_07FF)

chan_stat :: proc(c: ^Chan, mask: u64 = GETATTR_BASIC) -> (attr: vectra9.Rgetattr, err: Errno) {
	if c == nil {
		return {}, vectra9.EBADF
	}
	request := vectra9.Msg(vectra9.Tgetattr{fid = c.fid, request_mask = mask})
	reply: vectra9.Msg
	if e := rpc(c.server, &request, &reply); e != OK {
		return {}, e
	}
	answer, ok := reply.(vectra9.Rgetattr)
	if !ok {
		return {}, vectra9.EPROTO
	}
	return answer, OK
}

// chan_is_dir reads the one qid bit that changes what a caller may do next.
chan_is_dir :: proc "contextless" (c: ^Chan) -> bool {
	return c != nil && .Dir in c.qid.kind
}

/*
chan_clone asks the server for a second handle on the same file.

A Twalk with no names, which is 9P's clone: it must not fail on a file, must
not check permissions, and returns no qids. The namespace fields carry over by
hand rather than wholesale. `refs` and `opened` belong to the new handle, and
9P cannot clone an open fid as open.
*/
chan_clone :: proc(c: ^Chan) -> (^Chan, Errno) {
	if c == nil {
		return nil, vectra9.EBADF
	}

	// Refused before a fid is spent rather than after, so a caller that broke
	// the locking rule has not also moved the counter. See `rpc_ready`.
	if e := rpc_ready(c.server); e != OK {
		return nil, e
	}

	newfid := new_fid(c.server)
	request := vectra9.Msg(vectra9.Twalk{fid = c.fid, newfid = newfid, count = 0})
	reply: vectra9.Msg
	if e := rpc(c.server, &request, &reply); e != OK {
		return nil, e
	}
	if _, ok := reply.(vectra9.Rwalk); !ok {
		return nil, vectra9.EPROTO
	}

	nc := chan_alloc(c.server, newfid, c.qid)
	if nc == nil {
		return nil, vectra9.ENOMEM
	}
	nc.tree_root = c.tree_root
	nc.mounted_over = chan_incref(c.mounted_over)
	nc.union_head = mount_point_incref(c.union_head)
	return nc, OK
}

/*
chan_device asks what physical memory this file is, and gets a refusal for
almost every file.

The kernel's half of `docs/DRAW.md` section 7. A caller with a chan learns
whether the thing behind it is memory, and where, without sending anything and
without knowing which server it holds.

**The namespace is what says yes.** A process that cannot open `/dev/fb` cannot
ask this, and a process whose namespace binds something else over `/dev/fb`
asks about that instead. That is the permission story, and it came free with
putting the question on a chan rather than on a name in a kernel table.
*/
chan_device :: proc "contextless" (c: ^Chan) -> (phys: uintptr, bytes: u64, ok: bool) {
	if c == nil || c.server == nil || c.server.device == nil {
		return 0, 0, false
	}
	return c.server.device(c.server, c.qid)
}
