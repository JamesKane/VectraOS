/*
A 9P connection with more than one request in flight, and the tag pool that
makes `Tflush` mean something.

This is Plan 9's `devmnt` — the client half of a mounted connection — plus the
server loop lib9p provides on the other side. Both halves are here because both
halves of `Tflush` are one mechanism and splitting them across packages would
mean describing the ordering rule twice.

    client thread ──▶ [ tag pool ] ──▶ work queue ──▶ worker ──▶ handler
          ▲                                                        │
          └──────────────── reply, by tag ─────────────────────────┘

## Why this had to exist before Tflush could

`vectra9.In_Process` runs the handler on the caller's own stack and returns.
A client behind it cannot have two requests outstanding, cannot be interrupted
in the middle of one, and therefore has nothing to flush and no way to send the
flush if it did. `Tflush` is not a feature of the protocol layer; it is a
feature of a transport that can leave a request pending, and Vectra had no such
transport until the scheduler and the sleep queue existed. `docs/VECTRA9.md`
section 7.3 said as much and left the question open on exactly those grounds.

## The tag is the slot

A `Tflush` names a request by its tag, so the server has to be able to find one
by tag. The cheapest structure that does that is an array, so the pool *is* the
tag space: slot `i` has tag `i`, and a tag that is not an index into the pool is
a tag naming no request — which is a case the protocol requires an answer for
rather than an error.

The upper half of the pool is reserved. Slot `i + MAX_REQUESTS` is the flush
partner of slot `i` and belongs to whoever owns `i`. That is not a
micro-optimisation, it is the only thing standing between this design and a
deadlock: a client whose request is stuck has to be able to send a `Tflush`, and
if the flush had to compete for an ordinary slot then a full pool of stuck
requests would leave nobody able to unstick anything.

## What the states mean

    Free      nobody owns it
    Queued    a client owns it; it is on the work queue, or about to be
    Running   a worker has it and is inside the handler
    Done      the reply is written; the client may take it and free the slot

Only the client ever moves a slot back to `Free`, including when the request
was flushed. That is the protocol's rule rather than a convenience: the tag is
not free until `Rflush` arrives, so the only thread that knows when it may be
reused is the one that asked for the flush.

## Locking

`Conn.lock` is a spinlock and covers the pool states, the work queue and the
flush partner link — a handful of instructions each, never held across a
handler and never held across a wait. Every sleep in this package happens
outside it, which is the rule `sync.can_sleep` checks.

Waiting is a `sync.Rendez` per slot rather than a flag and a spin. The
condition is the slot's own state, so a wake that lands before the wait is not
lost: `sync.sleep` tests before it parks. That property is what lets the client
release the lock between filling the slot in and waiting on it, which in turn
is what keeps the lock short.

## What this does not yet solve

**A reply that borrows the server's storage is unsafe here beyond one worker.**
`Rread.data` and `Rreaddir.data` point into whatever the handler had lying
about, and "valid until that server's next message" was a rule that held
because `kernel/vfs` held the session across the whole exchange. With several
workers, the next message is already in progress. The borrow rule is a property
of the transport and not of the protocol, and settling it -- a payload buffer
per slot, most likely -- is what `kernel/vfs` is waiting for before it can sit
on this. Until then a server behind a multi-worker `Conn` must reply out of
storage it does not reuse.

**The worker pool has to be bigger than the number of requests that can block
at once.** A worker inside a blocked handler is a worker not serving anything,
including the `Tflush` that would unblock it. Plan 9 avoids the question with a
thread per request; this counts them instead, and `serve_start` says so.
*/
package mnt

import "base:intrinsics"

import "kernel:sync"
import "vsys:vectra9"

/*
How many requests may be outstanding at once, and therefore how large the tag
space is.

Small on purpose. A tag pool is a server resource and a client that can grow
one without bound is a client that can exhaust the machine through a legal
sequence of legal messages -- the same argument that fixes the static server's
fid table. Eight is more than the whole kernel currently has threads to fill.
*/
MAX_REQUESTS :: 8

// Requests occupy the lower half; each one's flush partner sits directly above
// it. See the file comment for why the flush cannot be allowed to queue.
POOL :: 2 * MAX_REQUESTS

Rpc_State :: enum u32 {
	Free,
	Queued,
	Running,
	Done,
}

/*
One request, in flight.

`request` and `reply` are copies rather than pointers into the caller's frame.
The caller is parked for the whole exchange so a pointer would in fact be
valid, and copying is still right: a `Msg` is a stack value by design, the
copy removes a lifetime question from the one place in the kernel where two
threads look at the same message, and the borrow rule above is quite enough
lifetime for one file.
*/
Rpc :: struct {
	tag:     vectra9.Tag,
	request: vectra9.Msg,
	reply:   vectra9.Msg,
	err:     vectra9.Error,

	state:   Rpc_State,
	flushed: bool, // A Tflush named this tag while it was in flight

	// The Tflush waiting on this request, if any. Whoever finishes this
	// request answers that flush, which is how "Rflush comes after the
	// original's fate is decided" becomes structural rather than a wait.
	partner: ^Rpc,

	settled: sync.Rendez, // Woken when `state` becomes Done
	next:    ^Rpc, // Work queue link
}

/*
Counters, for the self-test and for anyone wondering what a connection did.

`unsettled` is the one to look at, and it should never be anything but zero. It
counts flushes whose `Rflush` came back while the request it named was still
running -- which is the single ordering rule `Tflush` has, checked from the
side that would be harmed by breaking it rather than asserted on the side that
implements it.
*/
Stats :: struct {
	requests:  u64,
	flushes:   u64, // Tflush messages served
	aborted:   u64, // ...of which found a request still in flight and marked it
	stale:     u64, // ...of which named a tag that was not in flight
	unsettled: u64, // Rflush that arrived too early. Always zero.
	waited:    u64, // Clients that had to park for a free slot
}

Conn :: struct {
	handler: vectra9.Handler,
	server:  rawptr,

	/*
	What the server does when a request of its is flushed.

	Optional, and a connection without one is still correct -- it simply
	cannot abandon anything, so `Rflush` waits for the request to finish on
	its own. That is a legal server: the protocol requires the ordering, not
	the abandonment.

	Called with no lock of this package held, because unsticking a request
	means waking a thread and this package has no business dictating how.
	*/
	abort:   proc "contextless" (server: rawptr, tag: vectra9.Tag),

	session: vectra9.Session,

	lock:    sync.Spinlock,
	pool:    [POOL]Rpc,
	head:    ^Rpc, // Work queue, oldest first
	tail:    ^Rpc,

	work:    sync.Rendez, // Workers wait here for something to do
	free:    sync.Rendez, // Clients wait here for a slot
	quiet:   sync.Rendez, // `serve_stop` waits here for the workers to leave

	workers: int,
	live:    int,
	stop:    bool,

	stats:   Stats,
}

// -- Bring-up ----------------------------------------------------------------

/*
init prepares a connection. It does not start serving; `serve_start` does.

Split because the workers are threads and threads want an allocator, while
everything here is arithmetic over storage the caller already owns. A `Conn`
must not move once started -- the session's transport holds a pointer into it,
and so does every parked client.
*/
init :: proc "contextless" (
	c: ^Conn,
	handler: vectra9.Handler,
	server: rawptr,
	abort: proc "contextless" (server: rawptr, tag: vectra9.Tag) = nil,
) #no_bounds_check {
	c.handler = handler
	c.server = server
	c.abort = abort
	c.head = nil
	c.tail = nil
	c.stop = false
	c.live = 0
	c.stats = {}

	for i in 0 ..< POOL {
		r := &c.pool[i]
		r.tag = vectra9.Tag(i)
		r.state = .Free
		r.partner = nil
		r.next = nil
		r.flushed = false
	}

	c.session = vectra9.session_from(transport(c))
}

// transport presents this connection as something a `vectra9.Session` can sit
// on. The session's own tag counter goes unused; see `alloc_tag`.
transport :: proc "contextless" (c: ^Conn) -> vectra9.Transport {
	return vectra9.Transport{data = c, call = transport_call}
}

// session is the connection's own session, for a client that wants to speak to
// it directly rather than through `kernel/vfs`.
session :: proc "contextless" (c: ^Conn) -> ^vectra9.Session {
	return &c.session
}

stats :: proc "contextless" (c: ^Conn) -> Stats {
	return c.stats
}

@(private = "file")
transport_call :: proc "contextless" (
	data: rawptr,
	s: ^vectra9.Session,
	tag: vectra9.Tag,
	request: ^vectra9.Msg,
	reply: ^vectra9.Msg,
) -> vectra9.Error {
	// The session's tag is discarded. This transport has to be able to find a
	// request by tag when a Tflush names one, so the tag has to be the slot.
	_ = s
	_ = tag
	return call(cast(^Conn)data, request, reply)
}

// -- The pool ----------------------------------------------------------------

@(private)
is_request_tag :: proc "contextless" (t: vectra9.Tag) -> bool {
	return int(t) < MAX_REQUESTS
}

@(private)
flush_partner :: proc "contextless" (c: ^Conn, r: ^Rpc) -> ^Rpc #no_bounds_check {
	return &c.pool[int(r.tag) + MAX_REQUESTS]
}

@(private = "file")
state_of :: proc "contextless" (r: ^Rpc) -> Rpc_State {
	return intrinsics.volatile_load(&r.state)
}

// enqueue puts a filled-in slot on the work queue. The lock is the caller's.
@(private = "file")
enqueue :: proc "contextless" (c: ^Conn, r: ^Rpc) {
	r.next = nil
	if c.tail == nil {
		c.head = r
	} else {
		c.tail.next = r
	}
	c.tail = r
}

@(private)
dequeue :: proc "contextless" (c: ^Conn) -> ^Rpc {
	r := c.head
	if r == nil {
		return nil
	}
	c.head = r.next
	if c.head == nil {
		c.tail = nil
	}
	r.next = nil
	return r
}

@(private = "file")
slot_free :: proc "contextless" (arg: rawptr) -> bool #no_bounds_check {
	c := cast(^Conn)arg
	if intrinsics.volatile_load(&c.stop) {
		return true
	}
	for i in 0 ..< MAX_REQUESTS {
		if intrinsics.volatile_load(&c.pool[i].state) == .Free {
			return true
		}
	}
	return false
}

/*
take claims a request slot, waiting for one if the pool is full.

Claimed by moving it to `Queued` under the lock, before the request is filled
in: the state is what reserves it, and the work queue is what makes a worker
look at it. The two are deliberately separate so that filling a 320-byte
message in happens with the lock down.
*/
@(private = "file")
take :: proc "contextless" (c: ^Conn) -> ^Rpc #no_bounds_check {
	for {
		guard := sync.acquire(&c.lock)
		if !c.stop {
			for i in 0 ..< MAX_REQUESTS {
				r := &c.pool[i]
				if r.state == .Free {
					r.state = .Queued
					r.flushed = false
					r.partner = nil
					sync.release(&c.lock, guard)
					return r
				}
			}
		}
		stopped := c.stop
		c.stats.waited += 1
		sync.release(&c.lock, guard)

		if stopped {
			return nil
		}
		sync.sleep(&c.free, slot_free, c)
	}
}

@(private = "file")
give_back :: proc "contextless" (c: ^Conn, r: ^Rpc) {
	guard := sync.acquire(&c.lock)
	r.state = .Free
	r.partner = nil
	r.flushed = false
	sync.release(&c.lock, guard)

	sync.wakeup(&c.free)
}

@(private = "file")
is_done :: proc "contextless" (arg: rawptr) -> bool {
	return intrinsics.volatile_load(&(cast(^Rpc)arg).state) == .Done
}

// -- The client --------------------------------------------------------------

/*
call sends one request and waits for its reply.

Uninterruptible: it returns when the server answers, however long that is. Use
`call_for` where the caller has a deadline and something better to do than
wait, which is every real caller and none of the boot-time ones.
*/
call :: proc "contextless" (
	c: ^Conn,
	request: ^vectra9.Msg,
	reply: ^vectra9.Msg,
) -> vectra9.Error {
	r := submit(c, request)
	if r == nil {
		return .Transport_Failed
	}

	sync.sleep(&r.settled, is_done, r)

	reply^ = r.reply
	err := r.err
	give_back(c, r)
	return err
}

/*
call_for is the same request with a deadline, and it is the reason this package
exists.

On expiry the caller does *not* simply walk away. Walking away would leave a
tag the server still believes is in use and a slot nobody may reuse, so the
caller flushes: it sends `Tflush` naming its own tag and waits for `Rflush`,
which the server sends only after the original request's fate is decided. Only
then is the tag free. That wait is not itself interruptible, because a flush of
a flush has nowhere to end.

Returns `.Interrupted` when it gave up, whether or not the original request was
answered in the meantime -- the caller asked for a deadline and the deadline
passed, and Plan 9's `mountio` discards the late answer for the same reason.
Tolerating that answer is the client's obligation under the protocol and it is
where a careless client corrupts itself: the reply is written into a slot the
client has stopped looking at, and the slot is only safe to reuse because the
`Rflush` that just arrived says the writing is over.
*/
call_for :: proc "contextless" (
	c: ^Conn,
	request: ^vectra9.Msg,
	reply: ^vectra9.Msg,
	ticks: u64,
) -> vectra9.Error {
	r := submit(c, request)
	if r == nil {
		return .Transport_Failed
	}

	if sync.sleep_for(&r.settled, is_done, r, ticks) {
		reply^ = r.reply
		err := r.err
		give_back(c, r)
		return err
	}

	flush(c, r)
	give_back(c, r)
	return .Interrupted
}

@(private = "file")
submit :: proc "contextless" (c: ^Conn, request: ^vectra9.Msg) -> ^Rpc {
	r := take(c)
	if r == nil {
		return nil
	}

	r.request = request^
	r.reply = {}
	r.err = .None

	guard := sync.acquire(&c.lock)
	c.stats.requests += 1
	enqueue(c, r)
	sync.release(&c.lock, guard)

	sync.wakeup(&c.work)
	return r
}

/*
flush sends `Tflush` for a request this caller has given up on, and waits.

The flush slot is `r`'s reserved partner, so this cannot fail to find one and
cannot queue behind ordinary traffic. When it returns, the server has decided
what to do with `r` and said so, and `r`'s tag is the caller's again.
*/
@(private = "file")
flush :: proc "contextless" (c: ^Conn, r: ^Rpc) {
	f := flush_partner(c, r)

	f.request = vectra9.Msg(vectra9.Tflush{oldtag = r.tag})
	f.reply = {}
	f.err = .None
	f.flushed = false
	f.partner = nil

	guard := sync.acquire(&c.lock)
	f.state = .Queued
	enqueue(c, f)
	sync.release(&c.lock, guard)

	sync.wakeup(&c.work)
	sync.sleep(&f.settled, is_done, f)

	/*
	Rflush is here, so the request it named is finished with -- by definition,
	because the only code that writes Rflush for a running request is the code
	that has just stopped running it. Checking rather than trusting, because
	this is the invariant the caller is about to bet the slot on.
	*/
	guard2 := sync.acquire(&c.lock)
	if r.state != .Done {
		c.stats.unsettled += 1
	}
	f.state = .Free
	sync.release(&c.lock, guard2)
}
