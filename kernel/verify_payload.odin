/*
A payload buffer per request slot, and the borrow rule it retires.

A 9P reply can carry bytes, and until now those bytes belonged to the server.
`Rread.data` and `Rreaddir.data` pointed into whatever storage the handler had,
and stayed good `until that server's next message`. One request at a time is
what made that a rule anybody could keep.

`kernel/mnt` runs eight. The server's next message is already in progress, so
there is no moment at which the rule is true. The fix is that each request slot
owns a buffer and the handler is handed it, which is what this checks.

**The buffer has to arrive before the handler, not after it.** A transport that
copied the payload out once the handler returned would look right. It would not
be. Another handler is inside the shared storage by then.

That is the claim worth a running control rather than a paragraph. The server
here can be told to answer the old way, out of one buffer of its own. The same
clients then run against it.

    per slot   every reader gets back the bytes it asked for
    shared     the readers overwrite each other, and the check says so

The control is not a negative control in the usual sense. Nobody has to revert
it or reason about it. It runs on every boot, immediately before the real
arrangement. A failure to corrupt is itself a failure, because it would mean
the test cannot see the bug it exists for.
*/
package kernel

import "base:intrinsics"

import "kernel:mnt"
import "kernel:sched"
import "kernel:sync"
import "kernel:vfs"
import "vsys:libodin"
import "vsys:vectra9"

// Payload bytes per request slot. Larger than `mnt.MIN_PAYLOAD` so a short
// buffer and a full one are different sizes rather than the same edge.
@(private = "file")
SLOT :: 1024

// One reader per request slot, so the pool is full and every handler is in the
// storage at the same time. That is the condition the control needs.
@(private = "file")
PAY_READERS :: mnt.MAX_REQUESTS

// One worker per reader. Fewer would serialise the handlers, and a control
// that cannot overlap cannot corrupt.
@(private = "file")
PAY_WORKERS :: mnt.MAX_REQUESTS

// What each reader asks for. Half a slot, so a reply that overran its buffer
// would have somewhere to overrun into.
@(private = "file")
COUNT :: 512

@(private = "file")
PAY_PATIENCE :: 400

// How long a handler waits at the barrier before it gives up on the others.
// Only reached when a reader thread failed to spawn, and a hung boot is a
// worse diagnostic than a failed check.
@(private = "file")
BARRIER_TICKS :: 100

// -- A server that fills a buffer with one byte --------------------------------

/*
The server under test.

`shared` is the whole control. When set, the handler ignores the buffer the
transport gave it and answers out of `own`, which is one buffer for the whole
server. That is precisely what a 9P server looked like before this milestone,
and `Rread.data` then points at storage the next request rewrites.

`barrier` holds every handler until every one of them arrives. The wait inside
each handler is enough to overlap them on this machine. The barrier is what
stops that from being a property of the scheduler. A control that corrupts
because of how threads happened to be ordered is a control that stops working
the day the ordering changes.
*/
@(private = "file")
Scribble :: struct {
	shared:  bool,
	barrier: bool,
	gate:    sync.Rendez,
	arrived: int,
	own:     [SLOT]u8,
}

@(private = "file")
scribble: Scribble

@(private = "file")
pay_conn: mnt.Conn

@(private = "file")
pay_arena: [mnt.MAX_REQUESTS * SLOT]u8

@(private = "file")
all_arrived :: proc "contextless" (arg: rawptr) -> bool {
	sv := cast(^Scribble)arg
	return intrinsics.volatile_load(&sv.arrived) >= PAY_READERS
}

/*
The handler: fill the buffer with one byte, in two passes with a wait between.

The byte comes from the request rather than from a constant. A transport that
dropped the request and invented a reply would otherwise pass a test whose
expected answer did not depend on what was asked.

The two passes are what make a shared buffer visibly shared. One handler alone
leaves a uniform run either way. Two in the same storage leave a seam, because
the second wrote its first half while the first was waiting.
*/
@(private = "file")
scribble_handler :: proc "contextless" (
	server: rawptr,
	s: ^vectra9.Session,
	tag: vectra9.Tag,
	request: ^vectra9.Msg,
	reply: ^vectra9.Msg,
	buf: []u8,
) #no_bounds_check {
	_ = s
	_ = tag
	sv := cast(^Scribble)server

	reply^ = vectra9.error_reply(vectra9.EOPNOTSUPP)

	#partial switch m in request^ {
	case vectra9.Tversion:
		reply^ = vectra9.Rversion {
			msize   = min(m.msize, vectra9.MSIZE_DEFAULT),
			version = vectra9.VERSION,
		}

	case vectra9.Tread:
		out := buf
		if intrinsics.volatile_load(&sv.shared) || out == nil {
			out = sv.own[:]
		}
		n := min(len(out), int(m.count))
		mark := u8(m.fid)

		if intrinsics.volatile_load(&sv.barrier) {
			pay_bump(&sv.arrived)
			sync.wakeup_all(&sv.gate)
			sync.sleep_for(&sv.gate, all_arrived, sv, BARRIER_TICKS)
		}

		for i in 0 ..< n / 2 {
			out[i] = mark
		}
		sync.delay(1)
		for i in n / 2 ..< n {
			out[i] = mark
		}

		reply^ = vectra9.Rread{data = out[:n]}
	}
}

@(private = "file")
pay_bump :: proc "contextless" (p: ^int) {
	intrinsics.volatile_store(p, intrinsics.volatile_load(p) + 1)
}

// -- The readers ---------------------------------------------------------------

/*
One reading thread and everything it found.

`buf` is this reader's own storage, and it is what it hands `mnt.call`. On the
per-slot arrangement the reply comes back pointing into it. On the shared one
the reply points into the server's buffer instead, because `deliver` copies
only what lies inside the slot and that does not. Either way the check reads
`answer.data`, so one piece of code sees both worlds.
*/
@(private = "file")
Reader :: struct {
	buf:      [COUNT]u8,
	mark:     u8,
	got:      int,
	err:      vectra9.Error,
	clean:    bool, // Every byte returned was this reader's own
	returned: bool,
}

@(private = "file")
pay_readers: [PAY_READERS]Reader

@(private = "file")
pay_done: sync.Rendez

@(private = "file")
pay_returns: int

@(private = "file")
reader :: proc "contextless" (arg: rawptr) #no_bounds_check {
	i := int(uintptr(arg))
	rd := &pay_readers[i]

	request := vectra9.Msg(
		vectra9.Tread{fid = vectra9.Fid(rd.mark), offset = 0, count = COUNT},
	)
	reply: vectra9.Msg
	rd.err = mnt.call(&pay_conn, &request, &reply, rd.buf[:])

	rd.clean = false
	if answer, ok := reply.(vectra9.Rread); ok {
		rd.got = len(answer.data)
		rd.clean = rd.got == COUNT
		for b in answer.data {
			if b != rd.mark {
				rd.clean = false
			}
		}
	}

	intrinsics.volatile_store(&rd.returned, true)
	pay_bump(&pay_returns)
	sync.wakeup_all(&pay_done)
}

@(private = "file")
all_read :: proc "contextless" (arg: rawptr) -> bool {
	return intrinsics.volatile_load(&pay_returns) >= PAY_READERS
}

// -- Waiting, without competing ------------------------------------------------


/*
run_readers puts one reader on every slot and reports how many got their own
bytes back.

Returns -1 when a thread failed to spawn, or when the readers did not all come
back. A caller can then tell `the arrangement is wrong` from `the test did not
run`.
*/
@(private = "file")
run_readers :: proc() -> int #no_bounds_check {
	intrinsics.volatile_store(&scribble.arrived, 0)
	intrinsics.volatile_store(&pay_returns, 0)
	for i in 0 ..< PAY_READERS {
		rd := &pay_readers[i]
		rd.mark = u8(i + 1)
		rd.got = 0
		rd.clean = false
		rd.err = .None
		intrinsics.volatile_store(&rd.returned, false)
		for j in 0 ..< COUNT {
			rd.buf[j] = 0
		}
	}

	for i in 0 ..< PAY_READERS {
		if sched.spawn("9p-reader", reader, rawptr(uintptr(i))) == nil {
			return -1
		}
	}
	if !sync.await(all_read, nil, PAY_PATIENCE) {
		return -1
	}

	clean := 0
	for i in 0 ..< PAY_READERS {
		if pay_readers[i].clean {
			clean += 1
		}
	}
	return clean
}

// -- A real server, with several workers on it ---------------------------------

@(private = "file")
dir_conn: mnt.Conn

@(private = "file")
dir_tree: vfs.Static_Tree

@(private = "file")
dir_arena: [mnt.MAX_REQUESTS * SLOT]u8

@(private = "file")
DIR_NODES := [?]vfs.Static_Node {
	{name = "", parent = -1, dir = true},
	{name = "alpha", parent = 0, data = "a"},
	{name = "bravo", parent = 0, data = "b"},
	{name = "charlie", parent = 0, data = "c"},
	{name = "delta", parent = 0, data = "d"},
	{name = "echo", parent = 0, data = "e"},
}

// Every node but the root, which is what a listing of the root should hold.
@(private = "file")
DIR_ENTRIES :: len(DIR_NODES) - 1

@(private = "file")
LISTERS :: 4

@(private = "file")
Lister :: struct {
	buf:      [SLOT]u8,
	entries:  int,
	err:      vectra9.Errno,
	returned: bool,
}

@(private = "file")
listers: [LISTERS]Lister

@(private = "file")
lister_returns: int

@(private = "file")
all_listed :: proc "contextless" (arg: rawptr) -> bool {
	return intrinsics.volatile_load(&lister_returns) >= LISTERS
}

/*
One thread that attaches, lists the root, and counts what came back.

Each takes a fid of its own, because a fid is per client and this is four
clients. Each check reads the names rather than the length. A payload that
another thread half-overwrote decodes into entries whose names are not in the
tree, and a count alone would not notice that.
*/
@(private = "file")
lister :: proc "contextless" (arg: rawptr) #no_bounds_check {
	i := int(uintptr(arg))
	ls := &listers[i]
	fid := vectra9.Fid(i + 1)

	attach := vectra9.Msg(
		vectra9.Tattach{fid = fid, afid = vectra9.NOFID, uname = "boot", aname = ""},
	)
	reply: vectra9.Msg
	if mnt.call(&dir_conn, &attach, &reply, nil) != .None {
		ls.err = vectra9.EIO
		intrinsics.volatile_store(&ls.returned, true)
		pay_bump(&lister_returns)
		sync.wakeup_all(&pay_done)
		return
	}

	request := vectra9.Msg(
		vectra9.Treaddir{fid = fid, offset = 0, count = u32(len(ls.buf))},
	)
	if mnt.call(&dir_conn, &request, &reply, ls.buf[:]) != .None {
		ls.err = vectra9.EIO
		intrinsics.volatile_store(&ls.returned, true)
		pay_bump(&lister_returns)
		sync.wakeup_all(&pay_done)
		return
	}

	if answer, ok := reply.(vectra9.Rreaddir); ok {
		c := vectra9.cursor_from(answer.data)
		for {
			e, more := vectra9.next_dirent(&c)
			if !more {
				break
			}
			if !known_name(e.name) {
				ls.err = vectra9.EPROTO
				break
			}
			ls.entries += 1
		}
	} else {
		ls.err = vectra9.EPROTO
	}

	intrinsics.volatile_store(&ls.returned, true)
	pay_bump(&lister_returns)
	sync.wakeup_all(&pay_done)
}

@(private = "file")
known_name :: proc "contextless" (name: string) -> bool #no_bounds_check {
	for i in 1 ..< len(DIR_NODES) {
		if DIR_NODES[i].name == name {
			return true
		}
	}
	return false
}

// -- The self-test --------------------------------------------------------------

@(private = "file")
Payload_Result :: struct {
	using tally:   libodin.Tally,
	corrupted:     int, // Readers the shared buffer spoiled, in the control
	bytes:         u64, // Payload copied out of slots into clients
	listings:      int, // Concurrent directory listings that came back whole
}

@(private = "file")
pcheck :: proc "contextless" (r: ^Payload_Result, ok: bool, what: string) -> bool {
	return libodin.tally(&r.tally, ok, what)
}

verify_payload :: proc() #no_bounds_check {
	r: Payload_Result

	// -- Sizing, and what init refuses ---------------------------------------

	{
		// One byte short of the floor per slot, which is the arithmetic `init`
		// does rather than a size it is handed.
		tiny: mnt.Conn
		pcheck(
			&r,
			!mnt.init(&tiny, scribble_handler, &scribble, nil, pay_arena[:mnt.MAX_REQUESTS * mnt.MIN_PAYLOAD - 1]),
			"an arena too small to give every slot a dirent is refused",
		)
		pcheck(&r, mnt.payload_size(&tiny) == 0, "and leaves the connection carrying nothing")
	}

	{
		// No arena at all is legal, and is what limits a connection to the one
		// worker the old borrow rule needs.
		bare: mnt.Conn
		pcheck(&r, mnt.init(&bare, scribble_handler, &scribble), "a connection may take no arena")
		pcheck(&r, !mnt.serve_start(&bare, 2), "and is then refused a second worker")
		if pcheck(&r, mnt.serve_start(&bare, 1), "while one worker is still allowed") {
			mnt.serve_stop(&bare)
		}
	}

	if !pcheck(
		&r,
		mnt.init(&pay_conn, scribble_handler, &scribble, nil, pay_arena[:]),
		"the connection divided its arena among the request slots",
	) {
		report_payload(&r)
		return
	}

	pcheck(&r, mnt.payload_size(&pay_conn) == SLOT, "each slot carries its share of it")
	pcheck(
		&r,
		mnt.session(&pay_conn).msize == u32(SLOT + vectra9.IOHDRSZ),
		"and the session's msize is that share plus a header",
	)

	if !pcheck(&r, mnt.serve_start(&pay_conn, PAY_WORKERS), "the connection started serving") {
		report_payload(&r)
		return
	}

	pcheck(
		&r,
		vectra9.negotiate(mnt.session(&pay_conn)) == .None,
		"Tversion round-trips",
	)
	pcheck(
		&r,
		mnt.session(&pay_conn).msize == u32(SLOT + vectra9.IOHDRSZ),
		"and negotiation did not talk msize above what a slot holds",
	)

	// -- The control: one buffer for the whole server ------------------------

	intrinsics.volatile_store(&scribble.barrier, true)
	intrinsics.volatile_store(&scribble.shared, true)

	clean := run_readers()
	if pcheck(&r, clean >= 0, "every reader in the control came back") {
		r.corrupted = PAY_READERS - clean
		pcheck(
			&r,
			r.corrupted > 0,
			"a server answering out of one shared buffer corrupts a reader",
		)
	}

	// -- The arrangement: one buffer per slot --------------------------------

	intrinsics.volatile_store(&scribble.shared, false)

	before := mnt.stats(&pay_conn)
	clean = run_readers()
	if pcheck(&r, clean >= 0, "every reader came back") {
		pcheck(&r, clean == PAY_READERS, "and every one of them got its own bytes back")
	}

	after := mnt.stats(&pay_conn)
	r.bytes = after.payload - before.payload
	pcheck(
		&r,
		r.bytes == u64(PAY_READERS * COUNT),
		"the payload each of them asked for was copied out of its slot",
	)
	pcheck(&r, after.oversize == before.oversize, "and none of it had to be refused")

	// -- A reply larger than the client's buffer -----------------------------

	/*
	Unreachable for a client that sizes its buffer by msize, which is what
	`init` set from the slot. This covers a server that answers with more than
	it was told there was room for. A truncation would be the wrong answer to
	that. A half-copied Rreaddir payload hands the caller a cursor that fails
	part-way through a name.
	*/
	intrinsics.volatile_store(&scribble.barrier, false)
	{
		small: [COUNT]u8
		for i in 0 ..< COUNT {
			small[i] = 0xAA
		}
		room := 64

		oversize_before := mnt.stats(&pay_conn).oversize
		request := vectra9.Msg(vectra9.Tread{fid = 1, offset = 0, count = COUNT})
		reply: vectra9.Msg
		err := mnt.call(&pay_conn, &request, &reply, small[:room])

		pcheck(&r, err == .Short_Buffer, "a payload that does not fit is a short buffer")
		pcheck(
			&r,
			mnt.stats(&pay_conn).oversize == oversize_before + 1,
			"and is counted where a server's author would see it",
		)

		untouched := true
		for i in 0 ..< COUNT {
			if small[i] != 0xAA {
				untouched = false
			}
		}
		pcheck(&r, untouched, "nothing was copied, rather than as much as fitted")

		// The reply that did not fit is the one still pointing into the slot,
		// and the slot goes back the instant this call returns. Handing it over
		// would be the bug the whole milestone removes.
		_, still_borrowing := reply.(vectra9.Rread)
		pcheck(&r, !still_borrowing, "and the refused reply was not handed back borrowing the slot")
	}

	// -- A request that answers with no payload at all -----------------------

	{
		request := vectra9.Msg(vectra9.Tclunk{fid = 1})
		reply: vectra9.Msg
		err := mnt.call(&pay_conn, &request, &reply, nil)
		_, is_error := reply.(vectra9.Rlerror)
		pcheck(
			&r,
			err == .None && is_error,
			"a client that expects no payload may pass no buffer",
		)
	}

	mnt.serve_stop(&pay_conn)

	// -- A real server, listed by four threads at once -----------------------

	pcheck(&r, verify_concurrent_listing(&r), "four threads listed one directory at once")

	sched.reap()
	report_payload(&r)
}

/*
The point of the whole milestone, against a server nothing modified for it.

`static_handler` builds an Rreaddir payload wherever the transport tells it to.
Behind `In_Process` that is still its own `dirbuf`, because there is one
request in flight and one buffer is enough. Behind this connection it is the
slot's, and four threads can therefore list the same directory at the same
time.

Before the slot buffer this was the arrangement `serve_start` had to refuse.
*/
@(private = "file")
verify_concurrent_listing :: proc(r: ^Payload_Result) -> bool #no_bounds_check {
	if !vfs.static_init(&dir_tree, "payload", DIR_NODES[:]) {
		return false
	}
	defer vfs.static_destroy(&dir_tree)

	if !mnt.init(&dir_conn, vfs.static_handler, &dir_tree, nil, dir_arena[:]) {
		return false
	}
	if !mnt.serve_start(&dir_conn, LISTERS) {
		return false
	}
	defer mnt.serve_stop(&dir_conn)

	if vectra9.negotiate(mnt.session(&dir_conn)) != .None {
		return false
	}

	intrinsics.volatile_store(&lister_returns, 0)
	for i in 0 ..< LISTERS {
		listers[i].entries = 0
		listers[i].err = vfs.OK
		intrinsics.volatile_store(&listers[i].returned, false)
	}

	for i in 0 ..< LISTERS {
		if sched.spawn("9p-lister", lister, rawptr(uintptr(i))) == nil {
			return false
		}
	}
	if !sync.await(all_listed, nil, PAY_PATIENCE) {
		return false
	}

	whole := 0
	for i in 0 ..< LISTERS {
		if listers[i].err == vfs.OK && listers[i].entries == DIR_ENTRIES {
			whole += 1
		}
	}
	r.listings = whole
	return whole == LISTERS
}

@(private = "file")
report_payload :: proc(r: ^Payload_Result) {
	sink := begin(&klog)
	libodin.put_str(&sink, "9p ")
	libodin.put_uint(&sink, u64(r.checks))
	if libodin.passed(r.tally) {
		libodin.put_str(&sink, " payload checks passed -- ")
		libodin.put_uint(&sink, u64(SLOT))
		libodin.put_str(&sink, " bytes per slot, ")
		libodin.put_uint(&sink, r.bytes)
		libodin.put_str(&sink, " delivered to ")
		libodin.put_uint(&sink, u64(PAY_READERS))
		libodin.put_str(&sink, " readers, ")
		libodin.put_uint(&sink, u64(r.corrupted))
		libodin.put_str(&sink, " spoiled by a shared buffer, ")
		libodin.put_uint(&sink, u64(r.listings))
		libodin.put_str(&sink, " listings at once")
		emit(&klog, .Ok, &sink)
		return
	}

	libodin.put_str(&sink, " payload checks, ")
	libodin.put_uint(&sink, u64(r.failures))
	libodin.put_str(&sink, " FAILED -- first: ")
	libodin.put_str(&sink, r.first_failure)
	emit(&klog, .Fault, &sink)
}
