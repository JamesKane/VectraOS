/*
Tflush, and the ordering rule that is the whole of it.

`Tflush` has one requirement and everything else about it follows: **Rflush is
sent after the flushed request's fate is decided.** A client reads Rflush as
`that tag is mine again`. A server that sends it early therefore hands back a
slot something is still writing into. Nothing about that failure is visible at
the moment it happens. It surfaces later, as a reply that lands in the wrong
request.

Testing it needs a server that will not finish, and two kinds of them, because
the protocol permits both and they fail differently:

    abortable   the flush wakes the handler, which gives up and answers.
                Rflush is prompt. This is the case everyone implements.
    stubborn    the server will not abandon the work. Rflush must wait -- for
                as long as the work takes -- and the flushed request is then
                answered *for real*, which the client is obliged to tolerate.

The second is the one worth building the test around. A server that always
aborts makes "after the fate is decided" and "immediately" the same instant, so
an implementation that sends Rflush first would pass. Here the boot thread
holds the work open, watches the client stay parked, and only then lets it
finish. An early Rflush is therefore a check that fails, rather than a race
that might.

`kernel/mnt` counts the same thing from the other side. The client increments
`Stats.unsettled` whenever an Rflush arrives while its request is still
running, and a check asserts that count is zero. One rule, observed from both
ends.
*/
package kernel

import "base:intrinsics"

import "kernel:mnt"
import "kernel:sched"
import "kernel:sync"
import "kernel:vfs"
import "vsys:libodin"
import "vsys:vectra9"

// Long enough that a client is genuinely parked in the handler, short enough
// that the whole self-test is a fraction of a second.
@(private = "file")
GIVE_UP_TICKS :: 10

// How long the boot thread watches a stubborn flush stay unanswered before
// accepting that Rflush is genuinely waiting. Several times GIVE_UP_TICKS, so
// an implementation that answers early gets every chance to.
@(private = "file")
WATCH_TICKS :: 40

@(private = "file")
PATIENCE :: 400

/*
One worker per request that can be blocked at once, plus one.

`kernel/mnt` cannot check this and says so: a worker inside a stuck handler is
a worker not serving the `Tflush` that would unstick it. The spare is what
serves the flushes. It is exactly one, because a flush never blocks. It marks
the request, prods the server, and returns.

This number is also what makes the full-pool phase below mean anything. With
fewer workers the flushes would queue behind the reads, rather than run
alongside them. The phase would then test the queue rather than the pool.
*/
@(private = "file")
WORKERS :: mnt.MAX_REQUESTS + 1

// Fast requests issued while another is stuck, to show the connection is still
// a connection.
@(private = "file")
FAST_CALLS :: 20

// -- A server that will not finish -------------------------------------------

/*
The server under test.

`open` is what lets a blocked Tread complete. `stubborn` decides whether a
flush alone is enough. A stubborn server notes the flush and carries on.

That is a legal thing for a server to be, and it is the only configuration
where the ordering rule has room to break.
*/
@(private = "file")
Slow :: struct {
	gate:       sync.Rendez, // Where blocked handlers wait
	open:       bool,
	stubborn:   bool,

	blocked:    int, // Handlers parked right now
	fast:       int, // Requests answered without blocking
	answered:   int, // Blocked reads that produced a real answer
	abandoned:  int, // ...that gave up because they had been flushed
	aborts:     int, // Times the abort hook was called
	last_abort: int,

	flushed:    [mnt.MAX_REQUESTS]bool,
	waits:      [mnt.MAX_REQUESTS]Slow_Wait,
}

// One per tag, so the wait condition can name both the server and the request
// without a closure.
@(private = "file")
Slow_Wait :: struct {
	sv:  ^Slow,
	tag: int,
}

@(private = "file")
slow: Slow
@(private = "file")
conn: mnt.Conn

/*
The payload arena, which this test needs only to be allowed more than one
worker.

`slow_handler` answers with no payload at all -- it exists to block, not to
carry bytes. `serve_start` still refuses a second worker without an arena. It
cannot tell a server that carries nothing from one that carries bytes into
shared storage. The floor is `mnt.MIN_PAYLOAD` per slot, and the smallest arena
that clears it is what is here.

`kernel/verify_payload.odin` is where a payload is what is being tested.
*/
@(private = "file")
arena: [mnt.MAX_REQUESTS * mnt.MIN_PAYLOAD]u8

@(private = "file")
slow_ready :: proc "contextless" (arg: rawptr) -> bool #no_bounds_check {
	w := cast(^Slow_Wait)arg
	if intrinsics.volatile_load(&w.sv.open) {
		return true
	}
	if intrinsics.volatile_load(&w.sv.stubborn) {
		return false
	}
	return intrinsics.volatile_load(&w.sv.flushed[w.tag])
}

/*
The abort hook: what `kernel/mnt` calls when a Tflush names a live request.

Recording and waking is all it does. Whether the handler acts on it is the
server's policy, and `slow_ready` above is where that policy lives. The two
kept apart is what makes a stubborn server expressible at all.
*/
@(private = "file")
slow_abort :: proc "contextless" (server: rawptr, tag: vectra9.Tag) #no_bounds_check {
	sv := cast(^Slow)server
	if int(tag) < mnt.MAX_REQUESTS {
		intrinsics.volatile_store(&sv.flushed[int(tag)], true)
	}
	intrinsics.volatile_store(&sv.last_abort, int(tag))
	intrinsics.volatile_store(&sv.aborts, intrinsics.volatile_load(&sv.aborts) + 1)
	sync.wakeup_all(&sv.gate)
}

@(private = "file")
slow_handler :: proc "contextless" (
	server: rawptr,
	s: ^vectra9.Session,
	tag: vectra9.Tag,
	request: ^vectra9.Msg,
	reply: ^vectra9.Msg,
	buf: []u8,
) #no_bounds_check {
	_ = s
	_ = buf
	sv := cast(^Slow)server

	reply^ = vectra9.error_reply(vectra9.EOPNOTSUPP)

	#partial switch m in request^ {
	case vectra9.Tversion:
		reply^ = vectra9.Rversion {
			msize   = min(m.msize, vectra9.MSIZE_DEFAULT),
			version = vectra9.VERSION,
		}

	case vectra9.Tclunk:
		// The fast request. Nothing here blocks, which is what makes it worth
		// issuing while something else is stuck.
		intrinsics.volatile_store(&sv.fast, intrinsics.volatile_load(&sv.fast) + 1)
		reply^ = vectra9.Rclunk{}

	case vectra9.Tread:
		if int(tag) >= mnt.MAX_REQUESTS {
			reply^ = vectra9.error_reply(vectra9.EIO)
			return
		}
		w := &sv.waits[int(tag)]
		w.sv = sv
		w.tag = int(tag)

		bump(&sv.blocked)
		sync.sleep(&sv.gate, slow_ready, w)
		unbump(&sv.blocked)

		if intrinsics.volatile_load(&sv.open) {
			// Answered for real, whether or not a Tflush named this tag. The
			// protocol allows exactly this and the client has to cope.
			intrinsics.volatile_store(
				&sv.answered,
				intrinsics.volatile_load(&sv.answered) + 1,
			)
			reply^ = vectra9.Rread{data = nil}
			return
		}

		intrinsics.volatile_store(&sv.abandoned, intrinsics.volatile_load(&sv.abandoned) + 1)
		reply^ = vectra9.error_reply(vectra9.EINTR)
	}
}

@(private = "file")
bump :: proc "contextless" (p: ^int) {
	intrinsics.volatile_store(p, intrinsics.volatile_load(p) + 1)
}

@(private = "file")
unbump :: proc "contextless" (p: ^int) {
	intrinsics.volatile_store(p, intrinsics.volatile_load(p) - 1)
}

// -- The clients -------------------------------------------------------------

// Enough to fill the request half of the pool exactly.
@(private = "file")
CLIENTS :: mnt.MAX_REQUESTS

@(private = "file")
Client :: struct {
	err:      vectra9.Error,
	returned: bool,
	reply:    vectra9.Msg,
}

@(private = "file")
clients: [CLIENTS]Client
@(private = "file")
client_done: sync.Rendez
@(private = "file")
returns: int
@(private = "file")
expected: int
@(private = "file")
abort_base: int

// A client that reads with a deadline and therefore flushes when it expires.
@(private = "file")
give_up_client :: proc "contextless" (arg: rawptr) #no_bounds_check {
	slot := int(uintptr(arg))
	cl := &clients[slot]

	request := vectra9.Msg(vectra9.Tread{fid = 1, offset = 0, count = 16})
	cl.err = mnt.call_for(&conn, &request, &cl.reply, GIVE_UP_TICKS)

	intrinsics.volatile_store(&cl.returned, true)
	intrinsics.volatile_store(&returns, intrinsics.volatile_load(&returns) + 1)
	sync.wakeup_all(&client_done)
}

// A client with no deadline, which waits however long the server takes.
@(private = "file")
patient_client :: proc "contextless" (arg: rawptr) #no_bounds_check {
	slot := int(uintptr(arg))
	cl := &clients[slot]

	request := vectra9.Msg(vectra9.Tread{fid = 2, offset = 0, count = 16})
	cl.err = mnt.call(&conn, &request, &cl.reply)

	intrinsics.volatile_store(&cl.returned, true)
	intrinsics.volatile_store(&returns, intrinsics.volatile_load(&returns) + 1)
	sync.wakeup_all(&client_done)
}

// -- Waiting, without competing ----------------------------------------------

@(private = "file")
Flush_Result :: struct {
	checks:        int,
	failures:      int,
	first_failure: string,
	flushes:       u64,
	aborted:       u64,
	stale:         u64,
	requests:      u64,
	held_ticks:    u64, // How long a stubborn flush kept its client parked
}

@(private = "file")
fcheck :: proc "contextless" (r: ^Flush_Result, ok: bool, what: string) -> bool {
	r.checks += 1
	if !ok {
		r.failures += 1
		if r.first_failure == "" {
			r.first_failure = what
		}
	}
	return ok
}

@(private = "file")
returned_0 :: proc "contextless" (arg: rawptr) -> bool #no_bounds_check {
	return intrinsics.volatile_load(&clients[0].returned)
}

@(private = "file")
returned_1 :: proc "contextless" (arg: rawptr) -> bool #no_bounds_check {
	return intrinsics.volatile_load(&clients[1].returned)
}

@(private = "file")
returned_2 :: proc "contextless" (arg: rawptr) -> bool #no_bounds_check {
	return intrinsics.volatile_load(&clients[2].returned)
}

// spin_down waits for a condition by sleeping between looks, so the threads it
// is waiting for have the core to themselves. See `verify_vfs.odin`'s PATIENCE
// for why the boot thread must never be the one spinning.
@(private = "file")
watch_for :: proc "contextless" (cond: sync.Condition, arg: rawptr) -> bool {
	for _ in 0 ..< PATIENCE {
		if cond(arg) {
			return true
		}
		sync.delay(1)
	}
	return false
}

@(private = "file")
one_blocked :: proc "contextless" (arg: rawptr) -> bool {
	return intrinsics.volatile_load(&slow.blocked) >= 1
}

@(private = "file")
one_aborted :: proc "contextless" (arg: rawptr) -> bool {
	return intrinsics.volatile_load(&slow.aborts) >= 1
}

// -- The self-test ------------------------------------------------------------

verify_flush :: proc() #no_bounds_check {
	r: Flush_Result

	fcheck(
		&r,
		mnt.init(&conn, slow_handler, &slow, slow_abort, arena[:]),
		"the connection took a payload arena it could divide",
	)
	if !fcheck(&r, mnt.serve_start(&conn, WORKERS), "the connection started serving") {
		report_flush(&r)
		return
	}

	// -- It is a working transport first -------------------------------------

	fcheck(
		&r,
		vectra9.negotiate(mnt.session(&conn)) == .None,
		"Tversion round-trips over a queue and two threads",
	)

	{
		request := vectra9.Msg(vectra9.Tclunk{fid = 7})
		reply: vectra9.Msg
		err := mnt.call(&conn, &request, &reply)
		_, is_rclunk := reply.(vectra9.Rclunk)
		fcheck(&r, err == .None && is_rclunk, "an ordinary request gets an ordinary reply")
	}

	// -- An abortable server: the flush is prompt ----------------------------

	intrinsics.volatile_store(&slow.open, false)
	intrinsics.volatile_store(&slow.stubborn, false)
	reset_clients(1)
	before := mnt.stats(&conn)

	if fcheck(
		&r,
		sched.spawn("9p-giveup", give_up_client, rawptr(uintptr(0))) != nil,
		"the first client spawned",
	) {
		fcheck(&r, watch_for(returned_0, nil), "a client whose deadline passes comes back")
		fcheck(&r, clients[0].err == .Interrupted, "and says it was interrupted")

		after := mnt.stats(&conn)
		fcheck(&r, after.flushes > before.flushes, "it got there by sending Tflush")
		fcheck(&r, after.aborted > before.aborted, "which found its request still in flight")
		fcheck(
			&r,
			intrinsics.volatile_load(&slow.aborts) > 0,
			"and the server was told which tag to abandon",
		)
		fcheck(
			&r,
			intrinsics.volatile_load(&slow.abandoned) > 0,
			"so the handler gave up rather than finishing",
		)
		fcheck(&r, watch_for(no_one_blocked, nil), "and left no handler parked behind it")
	}

	// -- A stubborn server: the flush has to wait ----------------------------

	/*
	The ordering rule, made observable.

	The server will not abandon this read, so `Rflush` cannot be sent until
	something else finishes it. The client is therefore still inside its flush
	long after the flush arrived, and that is the check. An implementation that
	answered Rflush on receipt would have this client back within a tick or two.
	*/
	intrinsics.volatile_store(&slow.open, false)
	intrinsics.volatile_store(&slow.stubborn, true)
	reset_clients(1)
	answered_before := intrinsics.volatile_load(&slow.answered)

	if fcheck(
		&r,
		sched.spawn("9p-stubborn", give_up_client, rawptr(uintptr(1))) != nil,
		"the second client spawned",
	) {
		fcheck(&r, watch_for(one_blocked, nil), "its read reached the server and stopped there")
		fcheck(&r, watch_for(one_aborted, nil), "and the deadline sent a Tflush after it")

		started := sched.ticks()
		sync.delay(WATCH_TICKS)
		r.held_ticks = sched.ticks() - started
		fcheck(
			&r,
			!intrinsics.volatile_load(&clients[1].returned),
			"Rflush did not arrive while the request was still running",
		)

		// Let it finish. The server answers the read for real, and only then
		// is the flush answered.
		intrinsics.volatile_store(&slow.open, true)
		sync.wakeup_all(&slow.gate)

		fcheck(&r, watch_for(returned_1, nil), "and did arrive once it was not")
		fcheck(&r, clients[1].err == .Interrupted, "the client still reports interrupted")
		fcheck(
			&r,
			intrinsics.volatile_load(&slow.answered) > answered_before,
			"even though the server answered the flushed request for real",
		)
	}

	// -- A full pool can still be flushed ------------------------------------

	/*
	The reason a flush does not queue for a slot like everything else.

	Every request slot is occupied here, and every one of them is stuck. A
	`Tflush` that had to claim an ordinary slot would wait for one of the requests
	it was sent to unstick. Nothing would ever move again, and the deadlock would
	be reachable by a client doing nothing wrong. Each request's flush partner is
	reserved above it in the pool for exactly this, and this is the phase where
	that stops being an assertion.
	*/
	intrinsics.volatile_store(&slow.open, false)
	intrinsics.volatile_store(&slow.stubborn, true)
	reset_clients(CLIENTS)
	intrinsics.volatile_store(&abort_base, intrinsics.volatile_load(&slow.aborts))

	spawned := 0
	for i in 0 ..< CLIENTS {
		if sched.spawn("9p-crowd", give_up_client, rawptr(uintptr(i))) != nil {
			spawned += 1
		}
	}
	if fcheck(&r, spawned == CLIENTS, "a client for every slot in the pool") {
		fcheck(&r, watch_for(all_blocked, nil), "all of them stuck in the server at once")
		fcheck(
			&r,
			watch_for(all_flushed, nil),
			"and every Tflush got through a pool with nothing free in it",
		)

		// Every one of them is now parked waiting for an Rflush the server
		// owes it, and the server is stubborn. Nothing else can free them.
		intrinsics.volatile_store(&slow.open, true)
		sync.wakeup_all(&slow.gate)

		fcheck(&r, watch_for(all_returned, nil), "and every one of them got its tag back")

		all_interrupted := true
		for i in 0 ..< CLIENTS {
			if clients[i].err != .Interrupted {
				all_interrupted = false
			}
		}
		fcheck(&r, all_interrupted, "each reporting the deadline it actually missed")
	}

	// -- Tflush of a tag that names nothing ----------------------------------

	{
		stale_before := mnt.stats(&conn).stale

		request := vectra9.Msg(vectra9.Tflush{oldtag = vectra9.NOTAG})
		reply: vectra9.Msg
		err := mnt.call(&conn, &request, &reply)
		_, is_rflush := reply.(vectra9.Rflush)
		fcheck(&r, err == .None && is_rflush, "a Tflush naming no request still gets Rflush")

		_, is_error := reply.(vectra9.Rlerror)
		fcheck(&r, !is_error, "and never an Rlerror -- Tflush has no failure reply")
		fcheck(&r, mnt.stats(&conn).stale > stale_before, "and was counted as naming nothing")
	}

	// -- One stuck request does not stop the connection ----------------------

	intrinsics.volatile_store(&slow.open, false)
	intrinsics.volatile_store(&slow.stubborn, true)
	reset_clients(1)

	if fcheck(
		&r,
		sched.spawn("9p-patient", patient_client, rawptr(uintptr(2))) != nil,
		"the third client spawned",
	) {
		fcheck(&r, watch_for(one_blocked, nil), "and stopped in the server with no deadline")

		fast_before := intrinsics.volatile_load(&slow.fast)
		ok := true
		for _ in 0 ..< FAST_CALLS {
			request := vectra9.Msg(vectra9.Tclunk{fid = 3})
			reply: vectra9.Msg
			if mnt.call(&conn, &request, &reply) != .None {
				ok = false
			}
		}
		fcheck(&r, ok, "other requests were served while it was stuck")
		fcheck(
			&r,
			intrinsics.volatile_load(&slow.fast) - fast_before == FAST_CALLS,
			"all of them, and by the server rather than by the transport",
		)

		intrinsics.volatile_store(&slow.open, true)
		sync.wakeup_all(&slow.gate)
		fcheck(&r, watch_for(returned_2, nil), "and the stuck one finished when it could")
		fcheck(&r, clients[2].err == .None, "with no deadline to interrupt it")
	}

	// -- The rule, from the client's side ------------------------------------

	final := mnt.stats(&conn)
	r.flushes = final.flushes
	r.aborted = final.aborted
	r.stale = final.stale
	r.requests = final.requests
	fcheck(&r, final.unsettled == 0, "no Rflush ever arrived before its request was settled")

	mnt.serve_stop(&conn)
	fcheck(&r, verify_transparency(&r), "a real server behind a queue answers as it always did")

	// Last, and after every `serve_stop` returns. Whoever runs next frees a
	// worker's stack, and not the worker that stands on it.
	//
	// A reap taken before the final connection stops therefore leaves that
	// connection's threads for the next self-test to find. `verify_vfs.odin` does
	// find them, as a heap that shrank underneath its own bracket.
	sched.reap()

	report_flush(&r)
}

@(private = "file")
no_one_blocked :: proc "contextless" (arg: rawptr) -> bool {
	return intrinsics.volatile_load(&slow.blocked) == 0
}

@(private = "file")
reset_clients :: proc "contextless" (want: int = 0) #no_bounds_check {
	for i in 0 ..< CLIENTS {
		intrinsics.volatile_store(&clients[i].returned, false)
		clients[i].err = .None
	}
	intrinsics.volatile_store(&returns, 0)
	intrinsics.volatile_store(&expected, want)
}

@(private = "file")
all_returned :: proc "contextless" (arg: rawptr) -> bool {
	return intrinsics.volatile_load(&returns) >= intrinsics.volatile_load(&expected)
}

@(private = "file")
all_blocked :: proc "contextless" (arg: rawptr) -> bool {
	return intrinsics.volatile_load(&slow.blocked) >= intrinsics.volatile_load(&expected)
}

// Every client not only stopped in the server. It also gave up on it, and its
// Tflush arrived. A wait for this, rather than for `all_blocked`, is what
// makes the phase about the pool. A client released while its deadline still
// runs gets its answer, and that proves nothing about a flush.
@(private = "file")
all_flushed :: proc "contextless" (arg: rawptr) -> bool {
	seen := intrinsics.volatile_load(&slow.aborts) - intrinsics.volatile_load(&abort_base)
	return seen >= intrinsics.volatile_load(&expected)
}

// -- Transport transparency ---------------------------------------------------

@(private = "file")
plain_conn: mnt.Conn
@(private = "file")
plain_tree: vfs.Static_Tree

@(private = "file")
PLAIN_NODES := [?]vfs.Static_Node {
	{name = "", parent = -1, dir = true},
	{name = "hello", parent = 0, data = "world"},
}

/*
The claim the whole design rests on, checked against a third transport.

Nothing modifies `static_handler` for any of this. One worker is what keeps its
reply-borrows-my-storage rule true.

With a single thread to serve it, a queued connection has exactly one request
in flight. That is what `In_Process` had. That restriction is the honest state
of things and `mnt.odin` says why.
*/
@(private = "file")
verify_transparency :: proc(r: ^Flush_Result) -> bool #no_bounds_check {
	if !vfs.static_init(&plain_tree, "plain", PLAIN_NODES[:]) {
		return false
	}
	defer vfs.static_destroy(&plain_tree)

	// No arena, and therefore one worker. That is the pairing `serve_start`
	// enforces, and it is the shape this check is about.
	if !mnt.init(&plain_conn, vfs.static_handler, &plain_tree) {
		return false
	}
	if !mnt.serve_start(&plain_conn, 1) {
		return false
	}
	defer mnt.serve_stop(&plain_conn)

	s := mnt.session(&plain_conn)
	if vectra9.negotiate(s) != .None {
		return false
	}

	attach := vectra9.Msg(
		vectra9.Tattach{fid = 1, afid = vectra9.NOFID, uname = "boot", aname = ""},
	)
	reply: vectra9.Msg
	if vectra9.call(s, &attach, &reply) != .None {
		return false
	}
	root, attached := reply.(vectra9.Rattach)
	if !attached || .Dir not_in root.qid.kind {
		return false
	}

	walk := vectra9.Msg(vectra9.Twalk{fid = 1, newfid = 2, count = 1})
	if w, is_walk := &walk.(vectra9.Twalk); is_walk {
		w.names[0] = "hello"
	}
	if vectra9.call(s, &walk, &reply) != .None {
		return false
	}
	got, walked := reply.(vectra9.Rwalk)
	return walked && got.count == 1 && .Dir not_in got.qids[0].kind
}

@(private = "file")
report_flush :: proc(r: ^Flush_Result) {
	sink := begin(&klog)
	libodin.put_str(&sink, "9p ")
	libodin.put_uint(&sink, u64(r.checks))
	if r.failures == 0 && r.checks > 0 {
		libodin.put_str(&sink, " Tflush checks passed -- ")
		libodin.put_uint(&sink, r.requests)
		libodin.put_str(&sink, " requests, ")
		libodin.put_uint(&sink, r.flushes)
		libodin.put_str(&sink, " flushed (")
		libodin.put_uint(&sink, r.aborted)
		libodin.put_str(&sink, " in flight, ")
		libodin.put_uint(&sink, r.stale)
		libodin.put_str(&sink, " stale), Rflush held ")
		libodin.put_uint(&sink, r.held_ticks)
		libodin.put_str(&sink, " ticks for a stubborn server")
		emit(&klog, .Ok, &sink)
		return
	}

	libodin.put_str(&sink, " Tflush checks, ")
	libodin.put_uint(&sink, u64(r.failures))
	libodin.put_str(&sink, " FAILED -- first: ")
	libodin.put_str(&sink, r.first_failure)
	emit(&klog, .Fault, &sink)
}
