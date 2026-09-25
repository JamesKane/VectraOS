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

`vectra9.In_Process` runs the handler on the caller's own stack and returns. A
client behind it cannot have two requests outstanding, and nothing can
interrupt it in the middle of one. It therefore has nothing to flush, and no
way to send the flush if it did.

`Tflush` is not a feature of the protocol layer. It is a feature of a transport
that can leave a request pending. Vectra had no such transport until the
scheduler and the sleep queue existed. `docs/VECTRA9.md` section 7.3 said as
much, and left the question open on exactly those grounds.

## The tag is the slot

A `Tflush` names a request by its tag, so the server has to be able to find one
by tag. So the pool *is* the tag space. Slot `i` has tag `i`, in chunks that
grow as clients need them, `pool.odin`.

A tag that names no slot names no request. The protocol requires an answer
for that case rather than an error.

The upper half of the tag space is reserved. Tag `i + FLUSH_TAG` is the flush
slot of request `i` and belongs to whoever owns `i`. That is not a
micro-optimisation. It is the only thing between this design and a deadlock.

A client whose request is stuck has to be able to send a `Tflush`. If that
flush had to compete for an ordinary slot, a full pool of stuck requests would
leave nobody able to unstick anything.

## What the states mean

    Free      nobody owns it
    Queued    a client owns it, and it is on the work queue, or about to be
    Running   a worker has it and is inside the handler
    Done      the reply is written, and the client may take it and free it

Only the client ever moves a slot back to `Free`, including when the request
was flushed. That is the protocol's rule rather than a convenience. The tag is
not free until `Rflush` arrives. The only thread that knows when something may
reuse it is the one that asked for the flush.

## Locking

`Conn.lock` is a spinlock. It covers the pool states, the work queue and the
flush partner link. Each is a handful of instructions. It is never held across
a handler, and never held across a wait. Every sleep in this package happens
outside it, which is the rule `sync.can_sleep` checks.

Waiting is a `sync.Rendez` per slot rather than a flag and a spin. The
condition is the slot's own state, so a wake that lands before the wait is not
lost: `sync.sleep` tests before it parks. That property is what lets the client
release the lock between the moment it fills the slot in and the moment it
waits on it. That in turn is what keeps the lock short.

## A payload buffer per slot

A reply that borrows the server's storage is unsafe here beyond one worker.
`Rread.data` and `Rreaddir.data` used to point into whatever the handler had
lying about. `Valid until that server's next message` was a rule that held
because `kernel/vfs` held the session across the whole exchange. With several
workers, the next message is already in progress.

So each request slot owns a buffer, and the handler is given it. The handler
builds its payload there and the reply points into it. Nothing is shared, so
there is nothing to overwrite.

**The buffer has to reach the handler, and not the reply.** A transport that
copied the payload out after the handler returned would look correct and would
not be. Another handler is inside the server's storage by then. There is no
instant, after a handler returns, at which its borrow is still good. The only
fix is that the borrow never points at shared storage in the first place.

**The slot outlives the client's interest in it, which is what makes the buffer
safe.** A client that gives up sends `Tflush` and waits for `Rflush`, and only
then is the slot free. A stubborn server therefore goes on writing into a
buffer whose client walked away, and writes into a slot nothing else may claim.
That is the same rule `Tflush` already needed for the tag. The buffer simply
rides on it.

**The client gets its own copy, and asks for it by size.** `call` copies the
payload out of the slot into storage the caller named, before the slot goes
back. One copy, and it is the copy the caller was going to make anyway.

**The buffer size is the msize.** `init` sets `Session.msize` to what one slot
can carry. A client that sizes a read by msize therefore has room for whatever
comes back. A payload that does not fit is then a server bug rather than an
overrun, and `call` reports `Short_Buffer` for it.

## What this does not yet solve

**A reply string still borrows the server's storage.** `Rreadlink.target` and
`Rgetlock.client_id` are the two, and no server here returns either. They land
in the slot buffer the moment one does, because `deliver` copies whatever lies
inside the slot and leaves alone whatever does not.

**The worker pool has to be bigger than the number of requests that can block
at once.** A worker inside a blocked handler is a worker not serving anything,
including the `Tflush` that would unblock it. Plan 9 avoids the question with a
thread per request. This counts them instead, and `serve_start` says so.
*/
package mnt

import "base:intrinsics"

import "kernel:sched"
import "kernel:sync"
import "vsys:vectra9"

/*
The requests a pool's first chunk holds, and each chunk after it. A pool
grows a chunk at a time up to the tag space, `pool.odin`, so this is not a
limit on requests in flight. A caller's arena covers the first chunk.

It was the limit once. Eight was more than the whole kernel had threads to
fill, until a ring 3 server held reads open: every window on the draw server
keeps two parked. A desktop filled eight, then sixteen, and the next request
from anyone parked for ever. `docs/LIMITS.md` has the account.
*/
MAX_REQUESTS :: 16

/*
The smallest payload buffer a slot may have.

9P caps a file name at 255 bytes and a directory entry carries 24 bytes of
fixed fields around it. A slot that cannot hold one entry cannot list a
directory at all. Every call returns nothing, and the client reads that as the
end of the listing. A floor here turns it into a refusal at `init`, where a
reader can see it.

Only the request half of the pool gets a buffer. `Rflush` has no body.
*/
MIN_PAYLOAD :: 512

Rpc_State :: enum u32 {
	Free,
	Queued,
	Running,
	Done,
}

/*
One request, in flight.

`request` and `reply` are copies rather than pointers into the caller's frame.
The caller is parked for the whole exchange, so a pointer would in fact be
valid. The copy is still right.

A `Msg` is a stack value by design. The copy removes a lifetime question from
the one place in the kernel where two threads look at the same message. And the
borrow rule above is quite enough lifetime for one file.
*/
Rpc :: struct {
	tag:     vectra9.Tag,
	request: vectra9.Msg,
	reply:   vectra9.Msg,
	err:     vectra9.Error,

	state:   Rpc_State,
	flushed: bool, // A Tflush named this tag while it was in flight

	// The thread that submitted this request, set where it takes the slot
	// and cleared where it gives the slot back. A handler on a worker asks
	// `requester` for it, which is how a served write learns who wrote.
	// Nil on the flush half of the pool. `docs/SMMU.md` section 7.
	client:  ^sched.Thread,

	// The Tflush waiting on this request, if any. Whoever finishes this
	// request answers that flush, which is how "Rflush comes after the
	// original's fate is decided" becomes structural rather than a wait.
	partner: ^Rpc,

	/*
	Storage this request owns, handed to the handler to build its payload in.

	Nil on the flush half of the pool, and nil throughout a connection that was
	given no arena. Both mean the same thing. This request answers with no
	payload, or the transport has one request in flight and the old borrow rule
	holds. See the file comment.

	Live from the moment `take` claims the slot to the moment `give_back`
	releases it. That span covers a stubborn handler still writing after its
	client gave up, because the client cannot release the slot until `Rflush`.
	*/
	payload: []u8,

	settled: sync.Rendez, // Woken when `state` becomes Done
	next:    ^Rpc, // Work queue link, or the pool's free list
	// This request's own flush slot, tagged `FLUSH_TAG` above it. A flush
	// never competes for a slot a stuck request holds. See `pool.odin`.
	own_flush: ^Rpc,
}

/*
Counters, for the self-test and for anyone wondering what a connection did.

`unsettled` is the one to look at, and it should never be anything but zero. It
counts flushes whose `Rflush` came back while the request it named was still
running. That is the single ordering rule `Tflush` has.

The check is on the side a violation would harm, rather than an assertion on
the side that implements it.
*/
Stats :: struct {
	requests:  u64,
	flushes:   u64, // Tflush messages served
	aborted:   u64, // ...of which found a request still in flight and marked it
	stale:     u64, // ...of which named a tag that was not in flight
	unsettled: u64, // Rflush that arrived too early. Always zero.
	waited:    u64, // Clients that had to park for a free slot
	payload:   u64, // Bytes copied out of a slot into a client's own storage
	oversize:  u64, // Replies whose payload did not fit the client's buffer
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
	pool:    Pool, // The slots, in chunks that grow, `pool.odin`
	head:    ^Rpc, // Work queue, oldest first
	tail:    ^Rpc,

	// Bytes of payload per request slot, or zero for a connection with no
	// arena. `serve_start` reads it: zero is what limits a connection to one
	// worker.
	per:     int,

	work:    sync.Rendez, // Workers wait here for something to do
	free:    sync.Rendez, // Clients wait here for a slot
	quiet:   sync.Rendez, // `serve_stop` waits here for the workers to leave

	workers: int,
	live:    int,
	stop:    bool,

	// The worker threads, as each starts, for a report of where they are.
	threads:  [64]^sched.Thread,
	nthreads: int,

	/*
	Workers on demand, for a server whose reads park in the handler: a
	console, a mouse, an interrupt stream. Each parked read holds its worker,
	so a fixed number of workers was a ceiling on parked reads. With `grow`
	set, a client that queues work finds the queue longer than the idle
	workers and starts one more, Plan 9's thread per request. `queued` and
	`idle` are under `lock`.
	*/
	grow:    bool,
	queued:  int,
	idle:    int,

	stats:   Stats,
}

// -- Bring-up ----------------------------------------------------------------

/*
init prepares a connection. It does not start to serve. `serve_start` does
that.

Split because the workers are threads and threads want an allocator, while
everything here is arithmetic over storage the caller already owns. A `Conn`
must not move once started -- the session's transport holds a pointer into it,
and so does every parked client.

`payload` is that storage, divided evenly among the request slots. It stays the
caller's, and it has to outlive the connection. The caller chooses the size,
because the caller knows what its server answers with. That size becomes the
session's msize. See the file comment.

A connection given none is a connection that answers with no payload, and
`serve_start` will only put one worker on it. Reports whether the arena was
large enough to divide.
*/
init :: proc "contextless" (
	c: ^Conn,
	handler: vectra9.Handler,
	server: rawptr,
	abort: proc "contextless" (server: rawptr, tag: vectra9.Tag) = nil,
	payload: []u8 = nil,
) -> bool #no_bounds_check {
	c.handler = handler
	c.server = server
	c.abort = abort
	c.head = nil
	c.tail = nil
	c.stop = false
	c.live = 0
	c.stats = {}

	c.per = 0
	if payload != nil {
		c.per = len(payload) / MAX_REQUESTS
		if c.per < MIN_PAYLOAD {
			c.per = 0
			return false
		}
	}

	// The first chunk's payloads are the caller's arena, and a chunk the
	// pool grows allocates its own.
	if !pool_init(&c.pool, c.per, c.per > 0 ? payload[:MAX_REQUESTS * c.per] : nil) {
		return false
	}

	c.session = vectra9.session_from(transport(c))
	if c.per > 0 {
		// A slot holds one payload. The msize is that plus the header a data
		// message reserves -- `IOHDRSZ`, which covers a Twrite's fid and
		// offset as well as its count. A client sizes a read or a write by
		// `msize - IOHDRSZ`. It then asks for exactly what one slot holds, and
		// no correct message serialises past the frame.
		c.session.msize = min(
			vectra9.MSIZE_DEFAULT,
			u32(vectra9.IOHDRSZ + c.per),
		)
	}
	return true
}

/*
transport presents this connection as something a `vectra9.Session` can sit on.
The session's own tag counter goes unused. See `alloc_tag`.

`call_for` is filled in, which is the whole point of this package. A session on
this transport answers true to `vectra9.interruptible`, and a caller with a
deadline gets one honoured rather than accepted and ignored.
*/
/*
A `Conn` fills in `call` and `call_for` but not `call_noted`. Its clients are
local devices -- a console, a disk -- reached with no mount between. A note that
must end a read of one of those is delivered by the deadline poll `call_for`
already carries; parking a local read until a note, the way a read across a
mount now does, changed how the console hands a cooked line to two readers at
once and is left to the transport that needed it. See `wire_call_noted`.
*/
transport :: proc "contextless" (c: ^Conn) -> vectra9.Transport {
	return vectra9.Transport{data = c, call = transport_call, call_for = transport_call_for}
}

// session is the connection's own session, for a client that wants to speak to
// it directly rather than through `kernel/vfs`.
session :: proc "contextless" (c: ^Conn) -> ^vectra9.Session {
	return &c.session
}

stats :: proc "contextless" (c: ^Conn) -> Stats {
	return c.stats
}

// payload_size reports what one request slot can carry, or zero for a
// connection with no arena. `msize` is this plus a header and a count prefix.
payload_size :: proc "contextless" (c: ^Conn) -> int {
	return c.per
}

@(private = "file")
transport_call :: proc "contextless" (
	data: rawptr,
	s: ^vectra9.Session,
	tag: vectra9.Tag,
	request: ^vectra9.Msg,
	reply: ^vectra9.Msg,
	buf: []u8,
) -> vectra9.Error {
	// The session's tag is discarded. This transport has to be able to find a
	// request by tag when a Tflush names one, so the tag has to be the slot.
	_ = s
	_ = tag
	return call(cast(^Conn)data, request, reply, buf)
}

@(private = "file")
transport_call_for :: proc "contextless" (
	data: rawptr,
	s: ^vectra9.Session,
	tag: vectra9.Tag,
	request: ^vectra9.Msg,
	reply: ^vectra9.Msg,
	buf: []u8,
	ticks: u64,
) -> vectra9.Error {
	_ = s
	_ = tag
	return call_for(cast(^Conn)data, request, reply, ticks, buf)
}

// -- The pool ----------------------------------------------------------------

// release gives back what `init` and growth allocated, after `serve_stop`.
// The arena stays the caller's.
release :: proc "contextless" (c: ^Conn) {
	pool_free(&c.pool)
}

@(private)
is_request_tag :: proc "contextless" (t: vectra9.Tag) -> bool {
	return int(t) < FLUSH_TAG
}

// enqueue puts a filled-in slot on the work queue. The lock is the caller's.
@(private = "file")
enqueue :: proc "contextless" (c: ^Conn, r: ^Rpc) -> (more: bool) {
	c.queued += 1
	r.next = nil
	if c.tail == nil {
		c.head = r
	} else {
		c.tail.next = r
	}
	c.tail = r
	return c.grow && !c.stop && c.queued > c.idle
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
	c.queued -= 1
	return r
}

@(private = "file")
slot_free :: proc "contextless" (arg: rawptr) -> bool #no_bounds_check {
	c := cast(^Conn)arg
	return intrinsics.volatile_load(&c.stop) || pool_ready(&c.pool)
}

/*
take claims a request slot, from the free list, or from a chunk it grows when
the list is empty, `pool.odin`. It waits only while another client grows, or
when the whole tag space is in flight.

Claimed by a move to `Queued` under the lock, before anything fills the request
in. The state is what reserves it, and the work queue is what makes a worker
look at it. The two are deliberately separate so that filling a 320-byte
message in happens with the lock down.
*/
@(private = "file")
take :: proc "contextless" (c: ^Conn) -> ^Rpc #no_bounds_check {
	for {
		guard := sync.acquire(&c.lock)
		if c.stop {
			sync.release(&c.lock, guard)
			return nil
		}
		if r := pool_pop(&c.pool); r != nil {
			r.state = .Queued
			r.flushed = false
			r.partner = nil
			sync.release(&c.lock, guard)
			return r
		}
		if pool_can_grow(&c.pool) {
			c.pool.growing = true
			sync.release(&c.lock, guard)
			made := pool_grow(&c.pool, &c.lock)
			sync.wakeup_all(&c.free)
			if !made {
				return nil
			}
			continue
		}
		c.stats.waited += 1
		sync.release(&c.lock, guard)
		sync.sleep(&c.free, slot_free, c)
	}
}

@(private = "file")
give_back :: proc "contextless" (c: ^Conn, r: ^Rpc) {
	guard := sync.acquire(&c.lock)
	r.state = .Free
	r.partner = nil
	r.flushed = false
	r.client = nil
	pool_push(&c.pool, r)
	sync.release(&c.lock, guard)

	sync.wakeup(&c.free)
}

@(private)
is_done :: proc "contextless" (arg: rawptr) -> bool {
	return intrinsics.volatile_load(&(cast(^Rpc)arg).state) == .Done
}

// -- Handing the payload over -------------------------------------------------

/*
in_slot reports whether a region of the reply lies in this request's buffer.

That is the whole test for `does this need copying`. A handler that built its
payload in the buffer it was given points here. The client has to have those
bytes before the slot goes back.

A handler that answered out of `.rodata`, or out of storage of its own, points
somewhere else. Nothing copies that. A copy would be work, and would say
something untrue about who owns the bytes.
*/
@(private = "file")
in_slot :: proc "contextless" (r: ^Rpc, p: rawptr, n: int) -> bool {
	if r.payload == nil || p == nil {
		return false
	}
	lo := uintptr(raw_data(r.payload))
	a := uintptr(p)
	return a >= lo && a + uintptr(n) <= lo + uintptr(len(r.payload))
}

// Where a copied region lands, and how much of the caller's buffer is gone. A
// reply carries at most one payload today, and a bump cursor costs nothing and
// stops that from being an assumption.
@(private = "file")
Landing :: struct {
	buf:  []u8,
	used: int,
}

@(private = "file")
land :: proc "contextless" (l: ^Landing, src: []u8) -> (dst: []u8, ok: bool) {
	if len(src) == 0 {
		return src, true
	}
	if l.used + len(src) > len(l.buf) {
		return nil, false
	}
	dst = l.buf[l.used:][:len(src)]
	copy(dst, src)
	l.used += len(src)
	return dst, true
}

/*
deliver moves whatever the reply borrows from the slot into the caller's own
storage, and repoints the reply at the copy.

Called before `give_back`, because after `give_back` the slot belongs to the
next client and its handler is entitled to write there.

Reports whether it all fitted. It always does for a client that sized its
buffer by `Session.msize`, which `init` set to what one slot holds. A refusal
therefore names a server that answered with more than it was told there was
room for. That is worth a failure rather than a truncation. A truncated
`Rreaddir` payload cuts an entry in half and hands the caller a cursor that
fails part-way through a name.
*/
@(private)
deliver :: proc "contextless" (r: ^Rpc, buf: []u8) -> (n: int, ok: bool) {
	if r.payload == nil {
		return 0, true
	}
	l := Landing {
		buf = buf,
	}

	if m, is := &r.reply.(vectra9.Rread); is && !land_bytes(&l, r, &m.data) {
		return 0, false
	}
	if m, is := &r.reply.(vectra9.Rreaddir); is && !land_bytes(&l, r, &m.data) {
		return 0, false
	}
	if m, is := &r.reply.(vectra9.Rreadlink); is && !land_string(&l, r, &m.target) {
		return 0, false
	}
	if m, is := &r.reply.(vectra9.Rversion); is && !land_string(&l, r, &m.version) {
		return 0, false
	}
	if m, is := &r.reply.(vectra9.Rgetlock); is && !land_string(&l, r, &m.client_id) {
		return 0, false
	}

	return l.used, true
}

// land_bytes moves one reply field out of the slot, when it lies there, and
// repoints the field at the copy. False when the copy did not fit.
@(private = "file")
land_bytes :: proc "contextless" (l: ^Landing, r: ^Rpc, b: ^[]u8) -> (ok: bool) {
	if !in_slot(r, raw_data(b^), len(b^)) {
		return true
	}
	b^, ok = land(l, b^)
	return ok
}

// land_string is `land_bytes` for a reply string. The string is left as it
// was when the copy did not fit.
@(private = "file")
land_string :: proc "contextless" (l: ^Landing, r: ^Rpc, s: ^string) -> bool {
	if !in_slot(r, raw_data(s^), len(s^)) {
		return true
	}
	copied, ok := land(l, transmute([]u8)s^)
	if !ok {
		return false
	}
	s^ = string(copied)
	return true
}

/*
settle copies the reply out and counts what happened. The reply is the caller's
afterwards, and borrows nothing of this connection's.

A refusal replaces the reply rather than passes it along. The reply that did
not fit still points into a slot this caller is about to release. To hand it
back would be the bug this whole file exists to remove. A `Short_Buffer` beside
it, saying not to look, would only add insult.

The lock and the two counters are the pool's, and a `Wire` has its own. So
this takes them by pointer rather than a `Conn`, and both pools share it.
*/
@(private)
settle :: proc "contextless" (
	lock: ^sync.Spinlock,
	payload: ^u64,
	oversize: ^u64,
	r: ^Rpc,
	buf: []u8,
) -> vectra9.Error {
	n, fitted := deliver(r, buf)

	guard := sync.acquire(lock)
	if fitted {
		payload^ += u64(n)
	} else {
		oversize^ += 1
	}
	sync.release(lock, guard)

	if !fitted {
		r.reply = vectra9.error_reply(vectra9.EPROTO)
		return .Short_Buffer
	}
	return r.err
}

// collect is what a client does with an answered slot: settle the reply into
// its own storage, take it, and give the slot back.
@(private = "file")
collect :: proc "contextless" (c: ^Conn, r: ^Rpc, reply: ^vectra9.Msg, buf: []u8) -> vectra9.Error {
	err := settle(&c.lock, &c.stats.payload, &c.stats.oversize, r, buf)
	reply^ = r.reply
	give_back(c, r)
	return err
}

// -- The client --------------------------------------------------------------

/*
call sends one request and waits for its reply.

Uninterruptible: it returns when the server answers, however long that is. Use
`call_for` where the caller has a deadline and something better to do than
wait. That is every real caller, and none of the boot-time ones.

`buf` is where the reply's payload lands. Size it by `Session.msize` less
`HEADER_SIZE` and the count prefix, or pass nil for a request that answers with
none. The reply borrows nothing of this connection's when this returns.
*/
call :: proc "contextless" (
	c: ^Conn,
	request: ^vectra9.Msg,
	reply: ^vectra9.Msg,
	buf: []u8 = nil,
) -> vectra9.Error {
	r := submit(c, request)
	if r == nil {
		return .Transport_Failed
	}

	sync.sleep(&r.settled, is_done, r)
	return collect(c, r, reply, buf)
}

/*
call_for is the same request with a deadline, and it is the reason this package
exists.

On expiry the caller does *not* simply walk away. A caller that walked away
would leave a tag the server still believes is in use, and a slot nobody may
reuse. So the caller flushes.

It sends `Tflush` naming its own tag, and waits for `Rflush`. The server sends
that only after the original request's fate is decided. Only then is the tag
free. That wait is not itself interruptible, because a flush of a flush has
nowhere to end.

Returns `.Interrupted` when it gave up, whether or not an answer to the
original request arrived in the meantime. The caller asked for a deadline, and
the deadline passed. Plan 9's `mountio` discards the late answer for the same
reason. The client's obligation under the protocol is to tolerate that answer,
and it is where a careless client corrupts itself.

The reply goes into a slot the client stopped looking at, and so does the
payload. The slot is only safe to reuse because the `Rflush` that just arrived
says the server finished writing.

That is what lets a slot's buffer be the one place a handler builds its
payload. The buffer is claimed for exactly as long as the tag is. A stubborn
server that writes into it long after its client left writes into storage
nothing else may take.

Nothing is copied out on the way through the deadline. The caller asked for an
answer by a time and did not get one, so there is no payload it is entitled to.
*/
call_for :: proc "contextless" (
	c: ^Conn,
	request: ^vectra9.Msg,
	reply: ^vectra9.Msg,
	ticks: u64,
	buf: []u8 = nil,
) -> vectra9.Error {
	r := submit(c, request)
	if r == nil {
		return .Transport_Failed
	}

	if sync.sleep_for(&r.settled, is_done, r, ticks) {
		return collect(c, r, reply, buf)
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
	r.client = sched.current()

	guard := sync.acquire(&c.lock)
	c.stats.requests += 1
	more := enqueue(c, r)
	sync.release(&c.lock, guard)

	if more {
		add_worker(c)
	}
	sync.wakeup(&c.work)
	return r
}

/*
flush sends `Tflush` for a request this caller abandoned, and waits.

The flush slot is `r`'s reserved partner, so this cannot fail to find one and
cannot queue behind ordinary traffic. When it returns, the server decided what
to do with `r` and said so. `r`'s tag is the caller's again.
*/
@(private = "file")
flush :: proc "contextless" (c: ^Conn, r: ^Rpc) {
	f := r.own_flush

	f.request = vectra9.Msg(vectra9.Tflush{oldtag = r.tag})
	f.reply = {}
	f.err = .None
	f.flushed = false
	f.partner = nil

	guard := sync.acquire(&c.lock)
	f.state = .Queued
	more := enqueue(c, f)
	sync.release(&c.lock, guard)

	if more {
		add_worker(c)
	}
	sync.wakeup(&c.work)
	sync.sleep(&f.settled, is_done, f)

	/*
	Rflush is here, so nothing is still using the request it named. That is true
	by definition. The only code that writes Rflush for a running request is the
	code that just stopped running it. Checking rather than trusting, because this
	is the invariant the caller is about to bet the slot on.
	*/
	guard2 := sync.acquire(&c.lock)
	if r.state != .Done {
		c.stats.unsettled += 1
	}
	f.state = .Free
	sync.release(&c.lock, guard2)
}
