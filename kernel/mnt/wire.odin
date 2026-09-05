/*
The wire -- the client half of a 9P connection whose server is somewhere else.

`Conn` in this package hands a request to a handler it can call. A process
is a handler nothing in the kernel can call. What crosses to one is bytes,
so this file is the transport `sys/vectra9`'s encoded loopback was the
skeleton for. Encode the request, send the frame, and match the reply that
eventually comes back by its tag.

    client thread ──▶ [ tag pool ] ── encode ──▶ io.write ──▶ ...a process
          ▲                                                       │
          └── settle, by tag ── decode ◀── reader thread ◀── io.read

The pool is `Conn`'s pool, kept for the same reasons. The tag is the slot, so
a `Tflush` can name a request something can find. The upper half is reserved
for the flushes, so a full pool of stuck requests cannot strand the client
that would unstick them. Each request slot owns the buffer its reply lands in,
so nothing shared is ever borrowed.

What is different is where the server's obligations live. `Conn` enforces the
`Rflush` ordering structurally, because both halves are its code. Here the
server is a program this kernel did not write, so the rules become things the
wire *verifies* rather than things it makes true:

  - A reply names a request in flight, or it is dropped and counted.
  - A frame is a well-formed message no larger than the msize, or the
    connection is poisoned.
  - The byte stream ends, and every waiter fails rather than parks for ever.

Poisoning is the honest translation of `this server broke the protocol`. The
frame boundary is gone, and there is no way to know where the next message
starts. Every request in flight fails as a transport failure, and so does
every request after it. A mount over a poisoned wire answers EIO, which is
what a dead server should look like from a namespace.

## One reader, and whose thread it is

Replies arrive whenever the far side writes, which is no thread this package
owns. So each wire has exactly one reader thread, and it does the only two
things a demultiplexer may. It routes bytes into the slot the tag names, and
wakes the client parked there. A frame for no slot is drained and dropped.
The reader never takes the write path, so a stalled writer cannot stop
replies.

`Tflush` needs no partner mechanism here. The flush is a frame like any
other, sent from its reserved slot, and the *server* decides the order of
its answers. What the client does on `Rflush` is what the protocol always
meant. The tag is the client's own again, whether or not the original was
ever answered. A server that discards a flushed request is legal, so an
original still unanswered at that point is not an error. It is counted,
because a count that should stay put is the cheapest kind of check.
*/
package mnt

import "base:intrinsics"
import "base:runtime"

import "kernel:mem"
import "kernel:sched"
import "kernel:sync"
import "vsys:vectra9"

/*
How the wire moves bytes.

Two calls and a pointer, so this package does not know what a pipe is. `read`
parks until at least one byte arrives and returns zero or less when the far
side is gone for good. `write` moves the whole slice or reports that it could
not, and it may park. Both are called from threads that hold no lock of this
package's.
*/
Wire_IO :: struct {
	data:  rawptr,
	read:  proc "contextless" (data: rawptr, buf: []u8) -> int,
	write: proc "contextless" (data: rawptr, frame: []u8) -> bool,
}

// Bytes a flush slot's frame buffer holds. An Rflush is seven bytes, and a
// server that sends more under a flush tag is answering a question nobody
// asked. The size check poisons the wire before this bound matters.
@(private = "file")
FLUSH_FRAME :: 32

Wire_Stats :: struct {
	requests: u64,
	flushes:  u64, // Tflush frames sent
	discards: u64, // Rflush that arrived with the original still unanswered
	stale:    u64, // Replies naming no request in flight, drained and dropped
	payload:  u64, // Bytes copied out of a slot into a client's own storage
	oversize: u64, // Replies whose payload did not fit the client's buffer
	waited:   u64, // Clients that had to park for a free slot
	poisoned: bool,
	hangup:   bool, // The poison was an orderly end of the byte stream
}

Wire :: struct {
	io:          Wire_IO,
	session:     vectra9.Session,

	lock:        sync.Spinlock,
	pool:        [POOL]Rpc,
	flush_store: [MAX_REQUESTS][FLUSH_FRAME]u8,
	per:         int,

	/*
	One frame on the wire at a time, whoever is sending it.

	A mutex rather than the spinlock, because `io.write` may park on a full
	pipe. A frame interleaved with another frame is not late, it is garbage.
	The far side cannot even say so, because it no longer knows where a message
	starts.
	*/
	wlock:       sync.Mutex,
	xmit:        []u8,

	// The slot waiting for the NOTAG answer to a Tversion, or nil. Tversion
	// is the one message the protocol obliges to carry NOTAG, so its reply
	// cannot name its slot and the routing needs this one exception.
	version:     ^Rpc,

	free:        sync.Rendez, // Clients wait here for a slot
	quiet:       sync.Rendez, // `wire_join` waits here for the reader to leave

	broken:      bool,
	reader_live: bool,

	stats:       Wire_Stats,
}

/*
wire_init prepares a wire over `io`. It does not start the reader --
`wire_start` does, because the reader is a thread.

`arena` is divided into one reply buffer per request slot plus one transmit
buffer, and each must hold a whole frame. What one slot holds becomes the
msize, so no correct server can send a frame the reader has nowhere to put.
Reports whether the arena was large enough to divide.

A `Wire` must not move once started. The transport, the reader and every
parked client hold pointers into it.
*/
wire_init :: proc "contextless" (w: ^Wire, io: Wire_IO, arena: []u8) -> bool #no_bounds_check {
	w.io = io
	w.broken = false
	w.reader_live = false
	w.version = nil
	w.stats = {}

	w.per = len(arena) / (MAX_REQUESTS + 1)
	if w.per < MIN_PAYLOAD {
		w.per = 0
		return false
	}

	for i in 0 ..< POOL {
		r := &w.pool[i]
		r.tag = vectra9.Tag(i)
		r.state = .Free
		r.partner = nil
		r.next = nil
		r.flushed = false
		if i < MAX_REQUESTS {
			r.payload = arena[i * w.per:][:w.per]
		} else {
			r.payload = w.flush_store[i - MAX_REQUESTS][:]
		}
	}
	w.xmit = arena[MAX_REQUESTS * w.per:][:w.per]

	w.session = vectra9.session_from(wire_transport(w))
	w.session.msize = min(vectra9.MSIZE_DEFAULT, u32(w.per))
	return true
}

// wire_start puts the reader thread on the wire.
wire_start :: proc(w: ^Wire) -> bool {
	if w == nil || w.per == 0 || w.reader_live {
		return false
	}
	if sched.spawn("9p-wire", reader, w) == nil {
		return false
	}
	w.reader_live = true
	return true
}

// wire_session is the wire's own session, for a client that speaks to it
// directly rather than through `kernel/vfs`.
wire_session :: proc "contextless" (w: ^Wire) -> ^vectra9.Session {
	return &w.session
}

wire_stats :: proc "contextless" (w: ^Wire) -> Wire_Stats {
	g := sync.acquire(&w.lock)
	defer sync.release(&w.lock, g)
	return w.stats
}

// wire_broken reports whether the connection is past saving. Every call on a
// broken wire fails at once rather than parks.
wire_broken :: proc "contextless" (w: ^Wire) -> bool {
	return intrinsics.volatile_load(&w.broken)
}

/*
wire_join waits for the reader thread to leave.

The reader leaves when the byte stream ends or a frame poisons the wire. The
caller's job is to make one of those happen first, and closing the far end
is the usual way. For the self-test, which must not free a pipe a thread
still reads.
*/
wire_join :: proc "contextless" (w: ^Wire) {
	sync.sleep(&w.quiet, reader_gone, w)
}

/*
wire_join_for is `wire_join` with a bound, and reports whether the reader left.

For a caller that cannot make the stream end. A wire poisoned by its own
patience -- a flush the far side never answered -- has a reader still parked
in a read of a pipe whose far end is open, and that reader leaves only when
the far side does. Waiting on it without a bound is a self-test that hangs
where a server wedged, and a self-test that hangs says nothing.
*/
wire_join_for :: proc "contextless" (w: ^Wire, ticks: u64) -> bool {
	return sync.sleep_for(&w.quiet, reader_gone, w, ticks)
}

@(private = "file")
reader_gone :: proc "contextless" (arg: rawptr) -> bool {
	return !intrinsics.volatile_load(&(cast(^Wire)arg).reader_live)
}

wire_transport :: proc "contextless" (w: ^Wire) -> vectra9.Transport {
	return vectra9.Transport{data = w, call = wire_call_t, call_for = wire_call_for_t}
}

@(private = "file")
wire_call_t :: proc "contextless" (
	data: rawptr,
	s: ^vectra9.Session,
	tag: vectra9.Tag,
	request: ^vectra9.Msg,
	reply: ^vectra9.Msg,
	buf: []u8,
) -> vectra9.Error {
	_ = s
	_ = tag
	return wire_call(cast(^Wire)data, request, reply, buf)
}

@(private = "file")
wire_call_for_t :: proc "contextless" (
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
	return wire_call_for(cast(^Wire)data, request, reply, ticks, buf)
}

// -- The pool, again ----------------------------------------------------------

@(private = "file")
wire_slot_free :: proc "contextless" (arg: rawptr) -> bool #no_bounds_check {
	w := cast(^Wire)arg
	if intrinsics.volatile_load(&w.broken) {
		return true
	}
	for i in 0 ..< MAX_REQUESTS {
		if intrinsics.volatile_load(&w.pool[i].state) == .Free {
			return true
		}
	}
	return false
}

@(private = "file")
wire_take :: proc "contextless" (w: ^Wire) -> ^Rpc #no_bounds_check {
	for {
		g := sync.acquire(&w.lock)
		if !w.broken {
			for i in 0 ..< MAX_REQUESTS {
				r := &w.pool[i]
				if r.state == .Free {
					r.state = .Queued
					r.err = .None
					r.reply = {}
					sync.release(&w.lock, g)
					return r
				}
			}
		}
		broken := w.broken
		w.stats.waited += 1
		sync.release(&w.lock, g)

		if broken {
			return nil
		}
		sync.sleep(&w.free, wire_slot_free, w)
	}
}

@(private = "file")
wire_give_back :: proc "contextless" (w: ^Wire, r: ^Rpc) {
	g := sync.acquire(&w.lock)
	r.state = .Free
	sync.release(&w.lock, g)
	sync.wakeup(&w.free)
}

// -- Sending ------------------------------------------------------------------

/*
submit claims a slot, encodes the request and puts the frame on the wire.

The slot is `Queued` before the frame leaves, so a reply racing back cannot
find its tag unclaimed. Tversion goes out under NOTAG, as the protocol
demands, and registers itself as the one slot a NOTAG reply may settle.
*/
@(private = "file")
wire_submit :: proc "contextless" (w: ^Wire, request: ^vectra9.Msg) -> (^Rpc, vectra9.Error) {
	r := wire_take(w)
	if r == nil {
		return nil, .Transport_Failed
	}

	tag := r.tag
	_, is_version := request.(vectra9.Tversion)
	if is_version {
		tag = vectra9.NOTAG
	}

	sync.mutex_lock(&w.wlock)
	if intrinsics.volatile_load(&w.broken) {
		sync.mutex_unlock(&w.wlock)
		wire_give_back(w, r)
		return nil, .Transport_Failed
	}
	if is_version {
		g := sync.acquire(&w.lock)
		w.version = r
		sync.release(&w.lock, g)
	}

	n, err := vectra9.encode(w.xmit, tag, request^)
	if err != .None {
		sync.mutex_unlock(&w.wlock)
		wire_give_back(w, r)
		return nil, err
	}

	g := sync.acquire(&w.lock)
	w.stats.requests += 1
	sync.release(&w.lock, g)

	ok := w.io.write(w.io.data, w.xmit[:n])
	sync.mutex_unlock(&w.wlock)

	if !ok {
		poison(w, false)
		wire_give_back(w, r)
		return nil, .Transport_Failed
	}
	return r, .None
}

@(private = "file")
wire_settle :: proc "contextless" (w: ^Wire, r: ^Rpc, buf: []u8) -> vectra9.Error {
	n, fitted := deliver(r, buf)

	g := sync.acquire(&w.lock)
	if fitted {
		w.stats.payload += u64(n)
	} else {
		w.stats.oversize += 1
	}
	sync.release(&w.lock, g)

	if !fitted {
		r.reply = vectra9.error_reply(vectra9.EPROTO)
		return .Short_Buffer
	}
	return r.err
}

/*
wire_call sends one request and waits for its reply, however long that is.

`buf` is where the reply's payload lands, sized by `Session.msize`. The reply
borrows nothing of the wire's when this returns.
*/
wire_call :: proc "contextless" (
	w: ^Wire,
	request: ^vectra9.Msg,
	reply: ^vectra9.Msg,
	buf: []u8 = nil,
) -> vectra9.Error {
	r, err := wire_submit(w, request)
	if r == nil {
		return err
	}

	sync.sleep(&r.settled, is_done, r)

	err = wire_settle(w, r, buf)
	reply^ = r.reply
	wire_give_back(w, r)
	return err
}

/*
wire_call_for is the same request with a deadline.

The shape is `Conn.call_for`'s. On expiry the caller flushes rather than
walks away, because the tag and the buffer are not the caller's again until
`Rflush` says so. The flush frame goes out from the request's reserved
partner slot, so a full pool cannot stop it.

The one new case is a server that never answers the flush either. On
`Conn` that wait is uninterruptible, and a kernel server always answers.
Here the far side is a program, and one that never reads holds the flush as
long as it held the request. `wire_flush` gives it `FLUSH_TICKS` and then
poisons the wire, which settles every slot at once. A server that neither
answers nor hangs up left the protocol, and a poisoned wire is what that
is called. The mounting thread that found this parked in the flush for
ever, holding the pipe table's build lock. That was the second of the three
parks `docs/PIPE.md` records.
*/
wire_call_for :: proc "contextless" (
	w: ^Wire,
	request: ^vectra9.Msg,
	reply: ^vectra9.Msg,
	ticks: u64,
	buf: []u8 = nil,
) -> vectra9.Error {
	r, err := wire_submit(w, request)
	if r == nil {
		return err
	}

	if sync.sleep_for(&r.settled, is_done, r, ticks) {
		err = wire_settle(w, r, buf)
		reply^ = r.reply
		wire_give_back(w, r)
		return err
	}

	wire_flush(w, r)
	// The reply may have won the race with the flush. It landed while the
	// Tflush was in flight, before the flush reached the server. Plan 9's
	// `mntflushfree` keeps such a reply, marking only a still-unanswered
	// request as flushed. Keep it too, rather than lose an answer that
	// arrived to a caller that asked again.
	if intrinsics.volatile_load(&r.state) == .Done {
		err = wire_settle(w, r, buf)
		reply^ = r.reply
		wire_give_back(w, r)
		return err
	}
	wire_give_back(w, r)
	return .Interrupted
}

// Ticks a Tflush answer may take before the wire is declared broken. A
// server that is there has only to read seven bytes and echo a tag. So this
// is generous, and it is the whole bound on a caller that flushes.
FLUSH_TICKS :: 200

/*
wire_flush sends Tflush for an abandoned request and waits for the answer,
with a bound.

When it returns, the server has spoken for the tag -- or the wire has broken,
which speaks for every tag at once. Either way nothing will write into the
slot again, and the caller may release it. A flush nobody answers inside
`FLUSH_TICKS` breaks the wire itself. A server that answers neither a
request nor its flush is not one this wire can wait for.
*/
@(private = "file")
wire_flush :: proc "contextless" (w: ^Wire, r: ^Rpc) #no_bounds_check {
	f := &w.pool[int(r.tag) + MAX_REQUESTS]

	g := sync.acquire(&w.lock)
	f.state = .Queued
	f.err = .None
	f.reply = {}
	w.stats.flushes += 1
	sync.release(&w.lock, g)

	request := vectra9.Msg(vectra9.Tflush{oldtag = r.tag})

	sync.mutex_lock(&w.wlock)
	sent := false
	if !intrinsics.volatile_load(&w.broken) {
		if n, err := vectra9.encode(w.xmit, f.tag, request); err == .None {
			sent = w.io.write(w.io.data, w.xmit[:n])
		}
	}
	sync.mutex_unlock(&w.wlock)

	if !sent {
		poison(w, false)
	}
	if !sync.sleep_for(&f.settled, is_done, f, FLUSH_TICKS) {
		poison(w, false)
		sync.sleep(&f.settled, is_done, f)
	}

	g2 := sync.acquire(&w.lock)
	if r.state != .Done {
		// The server discarded the flushed request rather than answered it.
		// Legal, and worth counting: a wire whose servers always answer
		// should report zero here.
		w.stats.discards += 1
	}
	f.state = .Free
	sync.release(&w.lock, g2)
}

// -- The reader ---------------------------------------------------------------

/*
poison marks the wire dead and fails everything in flight.

Every slot that waits for a reply is settled as a transport failure and its
sleeper woken. `hangup` says which kind of death this was: the stream ending
is a server that left, and anything else is a server that broke framing.
*/
@(private = "file")
poison :: proc "contextless" (w: ^Wire, hangup: bool) #no_bounds_check {
	g := sync.acquire(&w.lock)
	if w.broken {
		sync.release(&w.lock, g)
		return
	}
	w.broken = true
	w.stats.poisoned = true
	w.stats.hangup = hangup
	w.version = nil
	for i in 0 ..< POOL {
		r := &w.pool[i]
		if r.state == .Queued || r.state == .Running {
			r.err = .Transport_Failed
			r.state = .Done
		}
	}
	sync.release(&w.lock, g)

	for i in 0 ..< POOL {
		sync.wakeup_all(&w.pool[i].settled)
	}
	sync.wakeup_all(&w.free)
}

// read_full loops until `buf` is filled. False means the stream ended first.
@(private = "file")
read_full :: proc "contextless" (w: ^Wire, buf: []u8) -> bool {
	got := 0
	for got < len(buf) {
		n := w.io.read(w.io.data, buf[got:])
		if n <= 0 {
			return false
		}
		got += n
	}
	return true
}

// drain consumes `n` bytes nothing wants, keeping the frame boundary intact.
@(private = "file")
drain :: proc "contextless" (w: ^Wire, n: int) -> bool {
	scratch: [64]u8
	left := n
	for left > 0 {
		k := w.io.read(w.io.data, scratch[:min(left, len(scratch))])
		if k <= 0 {
			return false
		}
		left -= k
	}
	return true
}

/*
route finds the request a reply's tag names and claims it, or nil.

NOTAG goes to the slot that sent Tversion, if one is waiting. Everything
else is an index into the pool, valid only while that slot is `Queued`. The
claim -- `Queued` to `Running` -- is what makes the body read below safe. A
slot in `Running` is the reader's until it is `Done`, and `wire_take` skips
both.
*/
@(private = "file")
route :: proc "contextless" (w: ^Wire, tag: vectra9.Tag) -> ^Rpc #no_bounds_check {
	g := sync.acquire(&w.lock)
	defer sync.release(&w.lock, g)

	r: ^Rpc
	if tag == vectra9.NOTAG {
		r = w.version
	} else if int(tag) < POOL {
		r = &w.pool[int(tag)]
	}
	if r == nil || r.state != .Queued {
		return nil
	}
	r.state = .Running
	return r
}

@(private = "file")
reader :: proc "contextless" (arg: rawptr) {
	w := cast(^Wire)arg

	// The reader decodes and copies and never allocates, but it runs library
	// code on this stack, and library code is entitled to a context.
	ctx := runtime.default_context()
	ctx.allocator = mem.allocator()
	context = ctx

	header: [vectra9.HEADER_SIZE]u8
	for {
		if !read_full(w, header[:]) {
			poison(w, true)
			break
		}

		size := int(header[0]) | int(header[1]) << 8 | int(header[2]) << 16 | int(header[3]) << 24
		tag := vectra9.Tag(u16(header[5]) | u16(header[6]) << 8)

		if size < vectra9.HEADER_SIZE || size > w.per {
			// Checked before the tag is even looked at. A frame beyond the msize is
			// broken framing, whoever it claims to be for. A drain sized by a lie
			// would park this thread on bytes that are never coming.
			poison(w, false)
			break
		}
		body := size - vectra9.HEADER_SIZE

		r := route(w, tag)
		if r == nil {
			// A reply for nothing in flight. The protocol was kept -- the
			// frame is whole -- so the connection survives it.
			g := sync.acquire(&w.lock)
			w.stats.stale += 1
			sync.release(&w.lock, g)
			if !drain(w, body) {
				poison(w, true)
				break
			}
			continue
		}

		if size > len(r.payload) {
			// Larger than the msize this wire announced. The server is
			// answering a protocol of its own.
			poison(w, false)
			break
		}
		copy(r.payload[:vectra9.HEADER_SIZE], header[:])
		if !read_full(w, r.payload[vectra9.HEADER_SIZE:size]) {
			poison(w, true)
			break
		}

		_, msg, derr := vectra9.decode(r.payload[:size])
		if derr != .None {
			poison(w, false)
			break
		}

		if v, is_version := &msg.(vectra9.Rversion); is_version {
			/*
			The version string is interned. Every reply string from a wire borrows
			the slot, and `negotiate` passes no buffer to copy one into. Kernel
			servers never made it need one, because their version lives in `.rodata`.
			The one string a handshake accepts is the dialect this tree speaks, so a
			match becomes the constant and borrows nothing. A mismatch stays
			borrowed, and is a refusal before anything reads it twice.
			*/
			if v.version == vectra9.VERSION {
				v.version = vectra9.VERSION
			}
		}

		g := sync.acquire(&w.lock)
		r.reply = msg
		r.err = .None
		r.state = .Done
		if w.version == r {
			w.version = nil
		}
		sync.release(&w.lock, g)
		sync.wakeup_all(&r.settled)
	}

	intrinsics.volatile_store(&w.reader_live, false)
	sync.wakeup_all(&w.quiet)
}
