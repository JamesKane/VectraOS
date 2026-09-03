/*
A 9P server, as a loop a program calls.

`/bin/niner` proved a program can answer 9P and built every reply by hand.
This file is what that proof buys the next server. It carries the posting,
the frame loop and the codec, so a program brings a `vectra9.Handler` and
nothing else. That signature is the load-bearing choice, because it is the
one every kernel server implements. A handler cannot tell whether it answers
from ring 0 behind a transport or from ring 3 behind a pipe. That is the
claim `sys/vectra9` opens with, now true across the privilege boundary.

The loop is the wire's mirror. The wire encodes requests and matches
replies. This side decodes requests and answers in order, one at a time,
which is the shape the borrow rule was born under. The handler may answer
out of its own storage, because nothing else is inside it.

## How a server stops

Two ways, both the caller's to see in the result:

  - **A `Tremove` is answered and then obeyed.** Removal of a file a server
    serves is the client saying stop, which is `/bin/niner`'s rule kept.
    The reply goes out first, so the remover hears yes.
  - **The pipe ends.** EOF means every client is gone, and a frame that lies
    about its size means the stream cannot be re-synchronised. Both end the
    loop, and the reason says which.
*/
package libuser

import "base:intrinsics"

import "vsys:abi"
import "vsys:vectra9"

// Why `serve` returned. `Removed` is the orderly stop. `Hangup` is a pipe
// that ended. `Broken` is a frame no loop can read past: a size beyond the
// buffer, or bytes that will not decode.
Serve_End :: enum {
	Removed,
	Hangup,
	Broken,
}

/*
post publishes one end of a fresh pipe under a name in `/srv`.

Plan 9's arc, made one call: pipe, create, write the digits, and give back
both spent descriptors. What returns is the serve end, ready for `serve`. On
any refusal along the way, everything opened is closed again. The answer is
then the kernel's errno, so a caller learns which step said no.
*/
post :: proc "contextless" (path: string) -> (serve_fd: int, err: i64) {
	packed := pipe()
	if packed < 0 {
		return -1, packed
	}
	end0, end1 := abi.pipe_ends(packed)

	cfd := create(path, abi.O_WRONLY, 0o600)
	if cfd < 0 {
		_ = close(end0)
		_ = close(end1)
		return -1, cfd
	}

	digits: [4]u8
	n := put_dec(digits[:], u64(end1))
	wrote := write(int(cfd), digits[:n])
	_ = close(int(cfd))
	if wrote != i64(n) {
		_ = close(end0)
		_ = close(end1)
		return -1, wrote < 0 ? wrote : -1
	}

	// The posting holds its own reference now, so the program's handle on
	// the posted end is spent the moment the write lands.
	_ = close(end1)
	return end0, 0
}

/*
serve answers requests from a descriptor until something ends the loop.

`frame` receives each request and `out` each reply, so both must hold a
whole message. Their size is the msize this server can honour, and the
handler's `Tversion` answer should say no more. `payload` is handed to the
handler for replies that carry bytes, which is the same contract every
kernel transport keeps with its handlers.

The handler runs with a session whose fields mean nothing here. It exists
because the signature carries one, and the signature is shared with servers
that need it.
*/
serve :: proc "contextless" (
	fd: int,
	handler: vectra9.Handler,
	state: rawptr,
	frame: []u8,
	out: []u8,
	payload: []u8,
	remove_stops := true, // a fixed tree stops on Tremove; a filesystem removes a file
) -> (served: u64, why: Serve_End) {
	session: vectra9.Session

	for {
		header := frame[:vectra9.HEADER_SIZE]
		if !read_full(fd, header) {
			return served, .Hangup
		}
		size := int(header[0]) | int(header[1]) << 8 | int(header[2]) << 16 | int(header[3]) << 24
		if size < vectra9.HEADER_SIZE || size > len(frame) {
			return served, .Broken
		}
		if !read_full(fd, frame[vectra9.HEADER_SIZE:size]) {
			return served, .Hangup
		}

		tag, request, derr := vectra9.decode(frame[:size])
		if derr != .None {
			return served, .Broken
		}
		_, is_remove := request.(vectra9.Tremove)

		reply: vectra9.Msg
		handler(state, &session, tag, &request, &reply, payload)

		n, eerr := vectra9.encode(out, tag, reply)
		if eerr != .None {
			return served, .Broken
		}
		if !write_full(fd, out[:n]) {
			return served, .Hangup
		}
		served += 1

		if is_remove && remove_stops {
			return served, .Removed
		}
	}
}

/*
A spinlock for ring 3, which is the primitive `serve_mux` needed and the
comment in `servers/consrv` said did not exist yet.

The word is a `u32` in memory two processes share -- `RFMEM`'s bss. `lock`
takes it with `lock cmpxchg`, the one instruction ring 3 runs to make a
read-modify-write atomic. It yields the core between tries rather than
spinning hot. `unlock` publishes zero with a release store, so a byte written
under the lock is visible to the next holder.

It may not be held across a blocking call. A worker parked in a device read
with the write lock held would stop every other worker's reply. The rule is
`kernel/sync`'s, kept by hand where there is no `can_sleep` to check it. Take
it for the length of a copy, never a wait.
*/
Spin :: u32

lock :: proc "contextless" (l: ^Spin) {
	for {
		if _, ok := intrinsics.atomic_compare_exchange_strong(l, 0, 1); ok {
			return
		}
		// A yield, not a hot spin. The holder runs on another core or another
		// slice, and burning this one only delays it.
		_ = sleep(0)
	}
}

unlock :: proc "contextless" (l: ^Spin) {
	intrinsics.atomic_store(l, 0)
}

/*
try_claim takes a slot's busy flag, or reports it taken.

The worker pool's allocator. A slot goes from free to busy in one atomic
step, so two main-loop passes cannot hand the same slot to two workers.
Freed by `atomic_store` when the worker is done, the mirror of `lock` and
`unlock` on a per-slot flag.
*/
@(private = "file")
try_claim :: proc "contextless" (busy: ^u32) -> bool {
	_, ok := intrinsics.atomic_compare_exchange_strong(busy, 0, 1)
	return ok
}

/*
One worker's storage, in memory the fork shares.

A request that blocks is copied into a slot, and a worker forked to own it.
The main loop may then overwrite its own frame with the next request at once.
The slot carries everything the worker touches that the parent also touches:
the request bytes, the reply bytes, and the payload a read fills. `busy` is
the claim, taken by `try_claim` and released when the worker exits.

The last three fields are the flush. `tag` names the request the worker
holds, so a `Tflush` can find it. `flushed` is what the worker's handler polls
through `flushed` below, and it is the cancel reaching the worker. `partner`
is the flush's own tag, kept so the worker can answer the `Rflush` itself as
it leaves. See `serve_mux` for why the worker answers it rather than the loop.
*/
Mux_Slot :: struct {
	frame:   []u8,
	out:     []u8,
	payload: []u8,
	busy:    u32,
	tag:     vectra9.Tag,
	flushed: bool,
	partner: vectra9.Tag,
}

/*
Everything `serve_mux` needs, filled in by the caller.

The buffers are the caller's, in shared bss, because their size is the
server's msize and only the server knows it. `blocks` is the one piece of
server knowledge the loop cannot supply: whether a request might park. A
request it flags true for is handed to a worker. Every other is answered
inline, exactly as `serve` does. `wlock` serialises the pipe writes, so a
worker's reply and the main loop's never interleave on the wire.

A `Mux` lives in the server's shared bss rather than on `_start`'s stack,
because a worker's handler asks `flushed` through it, and a worker's stack
is its own copy.
*/
Mux :: struct {
	fd:      int,
	handler: vectra9.Handler,
	blocks:  proc "contextless" (state: rawptr, request: ^vectra9.Msg) -> bool,
	state:   rawptr,
	frame:   []u8,
	out:     []u8,
	payload: []u8,
	wlock:   ^Spin,
	slots:   []Mux_Slot,
}

/*
serve_mux answers requests concurrently: a worker per request that would
park, and the rest inline.

This is the concurrent serve loop the handoff named. `serve` answers one
request at a time, so a read that parks holds every other client.

This loop reads a request. If `blocks` says it might park, the loop forks a
worker to own it -- `RFNOWAIT`, so the kernel reaps the worker with no `wait`
required. The main loop reads the next request at once. A request that does
not park is answered inline. A pool with no free slot falls back to inline
too. That bounds the workers the way `kernel/devfs`'s threads bound its
parked readers -- raised by adding a slot rather than a thread.

`Tremove` is always inline, because it is the stop: its reply goes out and
the loop returns `.Removed`. A worker never sees it, so the stop cannot race
a deferral.

## The flush, and who answers it

`Tflush` never reaches the handler here. The loop owns the workers, so the
loop is the only thing that can say whether the request a flush names is
still running, and the handler has no in-flight requests of its own on the
inline path. A server's own `Tflush` case still serves `serve`, where nothing
is ever pending.

The rule is `kernel/mnt`'s: **Rflush is sent after the flushed request's fate
is decided.** A client reads Rflush as `that tag is mine again`, and a server
that sends it while a worker will still write under that tag hands the client
a reply to whatever it asks next. The kernel's wire drops such a reply and
counts it. A client that reused the tag first would not.

So the loop does not answer the flush of a live request. It marks the slot,
records the flush's tag as the slot's `partner`, and reads the next request.
The worker's handler sees the mark at its next poll, gives up, and the
worker writes `Rflush` in place of the reply it would have sent -- the one
code path that knows the original is finished with. A flush naming no live
slot is answered at once, because the request it names was either answered
already or never deferred. Both decisions are under `wlock`, which the
worker also holds across its own decision and write, so `still running` and
`become its partner` are one step rather than two.

**The tag goes back before the Rflush goes out.** A worker that has been
flushed releases its slot, and with it the tag, before it writes the Rflush
that lets the client reuse that tag. A new request under the old tag can
therefore never find the old slot still claiming it. That ordering is what
makes asking `flushed` by tag safe.

A request the pool had no room for was answered inline, and a flush cannot
reach it: the loop that would serve the flush is the loop parked in the
handler. That is the pool being full, and a slot is the fix.
*/
serve_mux :: proc "contextless" (m: ^Mux) -> (served: u64, why: Serve_End) #no_bounds_check {
	session: vectra9.Session

	for {
		header := m.frame[:vectra9.HEADER_SIZE]
		if !read_full(m.fd, header) {
			return served, .Hangup
		}
		size := int(header[0]) | int(header[1]) << 8 | int(header[2]) << 16 | int(header[3]) << 24
		if size < vectra9.HEADER_SIZE || size > len(m.frame) {
			return served, .Broken
		}
		if !read_full(m.fd, m.frame[vectra9.HEADER_SIZE:size]) {
			return served, .Hangup
		}

		tag, request, derr := vectra9.decode(m.frame[:size])
		if derr != .None {
			return served, .Broken
		}
		_, is_remove := request.(vectra9.Tremove)

		// A flush is the loop's to answer, or the flushed worker's. Never
		// the handler's.
		if f, is_flush := request.(vectra9.Tflush); is_flush {
			if !mux_flush(m, tag, f.oldtag) {
				return served, .Hangup
			}
			served += 1
			continue
		}

		// A request that might park goes to a worker, unless the pool is full.
		if !is_remove && m.blocks != nil && m.blocks(m.state, &request) {
			if mux_defer(m, m.frame[:size]) {
				served += 1
				continue
			}
		}

		reply: vectra9.Msg
		m.handler(m.state, &session, tag, &request, &reply, m.payload)

		n, eerr := vectra9.encode(m.out, tag, reply)
		if eerr != .None {
			return served, .Broken
		}
		if !mux_write(m, m.out[:n]) {
			return served, .Hangup
		}
		served += 1

		if is_remove {
			return served, .Removed
		}
	}
}

/*
mux_defer copies a request into a free worker slot and forks the worker.

False when no slot is free, and the caller answers inline instead. The copy
happens before the fork, so the worker reads its slot, not the main loop's
frame -- which the next `read_full` is free to overwrite. The worker shares
this memory under `RFMEM`, so the slot it was handed holds the same bytes the
parent wrote.
*/
@(private = "file")
mux_defer :: proc "contextless" (m: ^Mux, request: []u8) -> bool #no_bounds_check {
	slot := -1
	for i in 0 ..< len(m.slots) {
		if try_claim(&m.slots[i].busy) {
			slot = i
			break
		}
	}
	if slot < 0 {
		return false
	}

	s := &m.slots[slot]
	for i in 0 ..< len(request) {
		s.frame[i] = request[i]
	}
	// The tag is bytes 5 and 6 of any frame, and it is what a Tflush names.
	// Written before the fork, with the flush state cleared, so a slot never
	// carries the last worker's mark into the next worker's life.
	s.tag = vectra9.Tag(u16(request[5]) | u16(request[6]) << 8)
	intrinsics.volatile_store(&s.flushed, false)
	s.partner = vectra9.NOTAG

	pid := rfork(abi.RFPROC | abi.RFMEM | abi.RFNOWAIT)
	if pid < 0 {
		// The child was never made. Free the slot and let the caller answer
		// inline, so a fork that failed is a request served rather than lost.
		intrinsics.atomic_store(&s.busy, 0)
		return false
	}
	if pid == 0 {
		mux_worker(m, s, len(request))
	}
	return true
}

/*
mux_worker is one deferred request, start to finish, in its own process.

Decode the slot's copy and call the handler, which may park now, because
nothing else waits on this process. Encode the reply into the slot, and hand
it to `mux_finish`, which decides under the lock whether that reply or an
`Rflush` goes out. The kernel collects the exit, because the fork was
`RFNOWAIT`.

A frame that will not decode is finished with no reply, which is what it
always was. It still goes through `mux_finish`, because a flush can name it
in the instant between the fork and the decode, and a flush recorded against
a slot nothing will ever look at again is an Rflush nobody sends.
*/
@(private = "file")
mux_worker :: proc "contextless" (m: ^Mux, s: ^Mux_Slot, size: int) -> ! {
	session: vectra9.Session
	tag, request, derr := vectra9.decode(s.frame[:size])
	if derr != .None {
		mux_finish(m, s, 0)
		exit(0)
	}

	reply: vectra9.Msg
	m.handler(m.state, &session, tag, &request, &reply, s.payload)

	n, eerr := vectra9.encode(s.out, tag, reply)
	if eerr != .None {
		n = 0
	}
	mux_finish(m, s, n)
	exit(0)
}

/*
mux_finish puts a worker's reply on the wire, or the Rflush that replaced it,
and frees the slot. One critical section for all of it.

Under `wlock`, because the decision and the write have to be one step. A
flush that arrives after the reply is on the wire finds the slot free and
answers itself. One that arrives before finds the slot busy and becomes its
partner, and this is the code that answers it. There is no third outcome,
and so no flush recorded against a request that has already replied.

`n` is the encoded reply's length, and zero is a request that produced no
frame to send.

A flushed worker frees its slot *before* it writes the Rflush, so the tag is
released before the client is told it may reuse it. Its reply is dropped
unsent, which is what the protocol asks: no reply under a flushed tag after
Rflush. The Rflush is built on this worker's own stack, because the slot is
no longer this worker's to write in. A reply that is sent frees the slot
after the write, because the slot's `out` is what is being written.
*/
@(private = "file")
mux_finish :: proc "contextless" (m: ^Mux, s: ^Mux_Slot, n: int) #no_bounds_check {
	lock(m.wlock)
	if intrinsics.volatile_load(&s.flushed) {
		rflush: [vectra9.HEADER_SIZE]u8
		partner := s.partner
		intrinsics.atomic_store(&s.busy, 0)
		if k, err := vectra9.encode(rflush[:], partner, vectra9.Rflush{}); err == .None {
			_ = write_full(m.fd, rflush[:k])
		}
		unlock(m.wlock)
		return
	}
	if n > 0 {
		_ = write_full(m.fd, s.out[:n])
	}
	intrinsics.atomic_store(&s.busy, 0)
	unlock(m.wlock)
}

/*
mux_flush serves a Tflush: answers it now, or hands it to the worker it names.

Reports whether the wire is still good, because the only way this fails is
a write that could not land.

Under `wlock`, which is what makes `still running` and `become its partner`
one decision. A busy slot whose tag is `oldtag` and which no flush has yet
named is marked, and the worker answers the flush as it leaves -- see
`mux_finish`. Anything else is answered at once: a tag naming no slot was
answered already or never deferred, and both mean the tag is the client's
again.

A second flush of a tag already flushed is answered at once too. Strictly
the protocol wants it after the first, and this loop keeps one partner per
slot rather than a list. The kernel's wire sends one flush per deadline and
never a second, so the case has no client here yet.

A `Tflush` cannot be answered with an error, so the reply is an `Rflush` in
every case, encoded into the loop's own `out`. The loop is the only writer of
that buffer.
*/
@(private = "file")
mux_flush :: proc "contextless" (m: ^Mux, tag: vectra9.Tag, oldtag: vectra9.Tag) -> bool #no_bounds_check {
	lock(m.wlock)
	for i in 0 ..< len(m.slots) {
		s := &m.slots[i]
		if intrinsics.atomic_load(&s.busy) == 0 || s.tag != oldtag {
			continue
		}
		if intrinsics.volatile_load(&s.flushed) {
			break
		}
		s.partner = tag
		intrinsics.volatile_store(&s.flushed, true)
		unlock(m.wlock)
		return true
	}
	ok := false
	if n, err := vectra9.encode(m.out, tag, vectra9.Rflush{}); err == .None {
		ok = write_full(m.fd, m.out[:n])
	}
	unlock(m.wlock)
	return ok
}

/*
flushed reports whether a Tflush named the request a worker is serving.

The handler's half of the cancel, asked by the tag it was handed, and the
mirror of `vfs.server_flushed` in ring 0. A handler that parks polls this
before each look at whatever it waits on, and answers when it is true. The
answer itself is never sent -- `mux_finish` writes the Rflush instead -- so
`EINTR` is the honest one and any reply would do.

**Ask before the drain, not after.** A flushed request's reply is dropped,
so a drain into one consumes bytes and hands them to nobody. The mark is set
before the worker can see it, so checking first leaves the bytes for the read
that follows. `kernel/devfs` has the long form beside its own loop.

By tag, which is safe because a slot releases its tag before the Rflush that
lets the client reuse it goes out. A worker asking about tag `t` therefore
finds at most one busy slot holding `t`, and it is its own. Inline, a request
holds no slot and this is false, which is the honest answer: nothing can
flush a request the loop itself is parked in.
*/
flushed :: proc "contextless" (m: ^Mux, tag: vectra9.Tag) -> bool #no_bounds_check {
	for i in 0 ..< len(m.slots) {
		s := &m.slots[i]
		if intrinsics.atomic_load(&s.busy) != 0 && s.tag == tag {
			return intrinsics.volatile_load(&s.flushed)
		}
	}
	return false
}

// mux_write puts one whole reply frame on the wire under the write lock, so
// two writers never interleave a frame. Held for the length of the write and
// no longer, which is the spinlock rule.
@(private = "file")
mux_write :: proc "contextless" (m: ^Mux, frame: []u8) -> bool {
	lock(m.wlock)
	ok := write_full(m.fd, frame)
	unlock(m.wlock)
	return ok
}

// put_dec writes a number as decimal digits and reports how many. For the
// descriptor a posting writes, so the bound is small.
put_dec :: proc "contextless" (buf: []u8, v: u64) -> int #no_bounds_check {
	digits: [20]u8
	d := 0
	v := v
	for {
		digits[d] = '0' + u8(v % 10)
		d += 1
		v /= 10
		if v == 0 {
			break
		}
	}
	if d > len(buf) {
		return 0
	}
	n := 0
	for d > 0 {
		d -= 1
		buf[n] = digits[d]
		n += 1
	}
	return n
}
