/*
Chan -- a handle on a file in a namespace.

A fid names a file within one session. A `Chan` names a file within one
*namespace*, which is a larger claim: it knows which server is answering, and
it carries the two fields that let a walk of `..` leave a mounted tree and land
somewhere the server it just left has never heard of.

Chans are reference counted and shared. `chan_clone` is the one that costs a
message -- it is a Twalk with no names, 9P's way of asking for a second handle
on the same file -- and `chan_incref` is the one that does not. Use clone when
the copy will be opened or walked independently, incref when it will not.
*/
package vfs

import "vsys:vectra9"

Chan :: struct {
	server: ^Server, // Whose session `fid` lives in
	fid:    vectra9.Fid,
	qid:    vectra9.Qid, // What the server calls this file

	/*
	Namespace bookkeeping, for `..` across a mount point.

	`tree_root` is the qid this chan's tree is rooted at and `mounted_over` is
	the chan that tree was mounted onto. When a walk of `..` arrives at a chan
	whose qid matches its own `tree_root`, there is nothing above it that this
	server can name, and the walk continues from `mounted_over` instead. See
	docs/VECTRA9.md section 5.5 for why the server cannot answer this itself.
	*/
	mounted_over: ^Chan,
	tree_root:    vectra9.Qid,

	/*
	The mount point this chan was reached through, if it was reached through
	one.

	Not in the design sketch, and needed by exactly one caller: `readdir`, which
	has to concatenate every member of a union and cannot find them from here
	otherwise. By the time a caller holds the chan, `cross_mounts` has already
	substituted the *first* member -- so the key the mount point is filed under,
	the file that was mounted over, is no longer reachable from `server` and
	`qid`. Plan 9 keeps the same pointer on `Chan.umh`.

	A counted reference, not a bare pointer. Unmounting `/dev` entirely while
	something still holds a chan reached through it would otherwise free the
	mount point out from under this field -- reachable today with no threads at
	all, just a chan held across an `unmount`. A dissolved mount point survives
	with an empty member list, so the chan goes on working on the member it is
	already standing on.
	*/
	union_head: ^Mount_Point,
	refs:       int,
	opened:     bool,
}

// Linux open flags, as 9P2000.L carries them. Only the ones a Vectra server
// currently distinguishes are named; the rest pass through untouched.
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
	// the member it stores; the default only matters for a fresh attach, where
	// it is exactly right.
	c.tree_root = qid
	c.refs = 1
	return c
}

// chan_incref takes another reference. Nil-safe, because `mounted_over` is
// usually nil and every caller would otherwise have to say so.
chan_incref :: proc(c: ^Chan) -> ^Chan {
	if c == nil {
		return nil
	}
	g := vlock(&object_lock)
	c.refs += 1
	vunlock(&object_lock, g)
	return c
}

/*
chan_close drops a reference and clunks the fid when the last one goes.

Tclunk's reply is ignored on purpose. There is nothing to do about a server
that fails to release a fid, the fid is gone from our side either way, and a
close path that can fail is a close path callers get wrong.

The `mounted_over` chain is released here rather than by whoever built it: a
mounted tree's parent has to outlive every chan inside that tree, and reference
counting is the only thing that knows when the last one is gone.
*/
chan_close :: proc(c: ^Chan) {
	c := c
	for c != nil {
		// The count comes down under the lock and the teardown happens
		// outside it, because the teardown sends a message. Whoever drives
		// the count to zero owns the object outright -- nobody else can find
		// it, so nothing below here needs the lock back.
		g := vlock(&object_lock)
		c.refs -= 1
		last := c.refs <= 0
		vunlock(&object_lock, g)
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
			_, rg := rpc(c.server, &request, &reply)
			rpc_end(rg)
		}

		// Loop rather than recurse: mount nesting is unbounded and this runs
		// on a 16 KiB fault stack's worth of assumptions about depth.
		parent := c.mounted_over
		free(c)
		c = parent
	}
}

// -- File operations ---------------------------------------------------------

/*
chan_open marks a chan open for reading or writing.

`iounit` is discarded because nothing chunks by it yet. When a transport exists
that can fragment a large write, this is the number it must chunk by -- not
msize, which bounds the message rather than the operation.
*/
chan_open :: proc(c: ^Chan, flags: u32) -> Errno {
	if c == nil {
		return vectra9.EBADF
	}
	request := vectra9.Msg(vectra9.Tlopen{fid = c.fid, flags = flags})
	reply: vectra9.Msg
	e, g := rpc(c.server, &request, &reply)
	defer rpc_end(g)
	if e != OK {
		return e
	}
	answer, ok := reply.(vectra9.Rlopen)
	if !ok {
		return vectra9.EPROTO
	}
	c.qid = answer.qid
	c.opened = true
	return OK
}

/*
chan_read copies at most len(buf) bytes from `offset`.

The copy is here and not further down because `Rread.data` borrows the reply
buffer -- on the in-process transport, that is the server's own storage, and it
is valid only until the next message. A caller that wanted to avoid the copy
would have to hold that promise, and no caller does.

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

	count := u32(min(len(buf), int(c.server.session.msize) - vectra9.HEADER_SIZE - 4))
	request := vectra9.Msg(vectra9.Tread{fid = c.fid, offset = offset, count = count})
	reply: vectra9.Msg

	// The guard runs to the end of the procedure, which is what makes the copy
	// below safe: `answer.data` is the server's storage until it is released.
	e, g := rpc(c.server, &request, &reply)
	defer rpc_end(g)
	if e != OK {
		return 0, e
	}
	answer, ok := reply.(vectra9.Rread)
	if !ok {
		return 0, vectra9.EPROTO
	}

	n = min(len(answer.data), len(buf))
	copy(buf[:n], answer.data[:n])
	return n, OK
}

chan_write :: proc(c: ^Chan, offset: u64, data: []u8) -> (n: int, err: Errno) {
	if c == nil {
		return 0, vectra9.EBADF
	}
	request := vectra9.Msg(vectra9.Twrite{fid = c.fid, offset = offset, data = data})
	reply: vectra9.Msg
	e, g := rpc(c.server, &request, &reply)
	defer rpc_end(g)
	if e != OK {
		return 0, e
	}
	answer, ok := reply.(vectra9.Rwrite)
	if !ok {
		return 0, vectra9.EPROTO
	}
	return int(answer.count), OK
}

// The Tgetattr request masks a client can ask for. `BASIC` is what stat(2)
// needs and what every Vectra server answers; asking for more is legal and
// gets whatever the server chose to fill in, which is what `valid` reports.
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
	e, g := rpc(c.server, &request, &reply)
	defer rpc_end(g)
	if e != OK {
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
not check permissions, and returns no qids. The namespace fields are carried
over by hand rather than copied wholesale -- `refs` and `opened` belong to the
new handle, and an open fid is not clonable-as-open in 9P.
*/
chan_clone :: proc(c: ^Chan) -> (^Chan, Errno) {
	if c == nil {
		return nil, vectra9.EBADF
	}

	g, e := rpc_begin(c.server)
	defer rpc_end(g)
	if e != OK {
		return nil, e
	}

	// The fid is allocated and used without letting go of the session --
	// see `rpc_begin` for why that is not just tidiness.
	newfid := vectra9.alloc_fid(&c.server.session)
	request := vectra9.Msg(vectra9.Twalk{fid = c.fid, newfid = newfid, count = 0})
	reply: vectra9.Msg
	if e = rpc_under(g, &request, &reply); e != OK {
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
