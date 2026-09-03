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
A held request's storage, in memory the reader child shares.

A request the handler cannot answer yet is copied into a slot and held
there: the main loop goes on to the next frame, and whichever process has
the answer -- the reader child that just pushed a byte -- answers it from
the slot. The slot carries the request bytes, the reply bytes, and the
payload a read fills. `busy` is the claim; `seq` says which held request is
the oldest, so a producer answers in the order the reads arrived.

`tag` is what a `Tflush` names. A flush of a held request drops it and
answers itself: the request's fate is decided the moment the flush arrives,
because nothing is running on its behalf.
*/
Mux_Slot :: struct {
	frame:   []u8,
	out:     []u8,
	payload: []u8,
	busy:    u32,
	seq:     u64,
	size:    int,
	tag:     vectra9.Tag,
}

/*
Everything `serve_mux` needs, filled in by the caller.

The buffers are the caller's, in shared bss, because their size is the
server's msize and only the server knows it. `wlock` serialises every write
to the pipe and every change to the slots, so a reply from the loop and one
from a producer never interleave on the wire, and a hold and a flush never
race. `hold` is set by the handler through `hold` below, and read by the
loop after the handler returns.

A `Mux` lives in the server's shared bss rather than on `_start`'s stack,
because a producer answers through it, and a producer's stack is its own.
*/
Mux :: struct {
	fd:       int,
	handler:  vectra9.Handler,
	state:    rawptr,
	frame:    []u8,
	out:      []u8,
	payload:  []u8,
	wlock:    ^Spin,
	slots:    []Mux_Slot,
	hold:     bool,
	next_seq: u64,
}

/*
serve_mux answers requests as they come, and holds the ones that cannot be
answered yet for whoever can.

This is `lib9p`'s shape. `serve` answers one request at a time on the
caller's stack, so a read that must wait holds every other client. This
loop reads a request and calls the handler under `wlock`. A handler that
has the answer replies, and the loop writes it. A handler that does not --
a read of a keyboard nobody has typed at -- calls `hold`, and the loop
copies the request into a free slot and reads the next frame. Nothing is
forked, and nothing parks. The reader child that later pushes the byte
looks at the held slots, drains into the oldest one that wants what it
has, and writes the reply itself through `respond`.

**The handler runs under `wlock`.** That is what makes "the ring was empty,
hold me" one decision with the producer's "a byte arrived, answer the held
reads": either the handler saw the byte, or the producer sees the held
slot. A handler may take the server's own state lock inside; a producer
takes `wlock` first and the state lock inside, so the order is the same on
both sides.

A hold with no free slot is answered `EAGAIN`: the client should try again,
and a slot is the fix. `Tremove` is always answered inline and ends the
loop with `.Removed`; a server drains what it still holds with
`respond_all` before it goes.

## The flush

`Tflush` never reaches the handler. A flush naming a held slot frees the
slot and answers `Rflush`, in one step under `wlock`: the held request is
dropped, its reply never written, and the client's tag is its own again.
A flush naming nothing held was answered already or never held, and is
answered at once. `Rflush` goes out only after the flushed request's fate is
decided, which `kernel/mnt` requires; here the decision and the answer are
the same instruction.
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

		if f, is_flush := request.(vectra9.Tflush); is_flush {
			if !mux_flush(m, tag, f.oldtag) {
				return served, .Hangup
			}
			served += 1
			continue
		}

		lock(m.wlock)
		m.hold = false
		reply: vectra9.Msg
		m.handler(m.state, &session, tag, &request, &reply, m.payload)

		if m.hold && !is_remove {
			if mux_hold(m, m.frame[:size], tag) {
				unlock(m.wlock)
				served += 1
				continue
			}
			reply = vectra9.error_reply(vectra9.EAGAIN)
		}

		n, eerr := vectra9.encode(m.out, tag, reply)
		if eerr != .None {
			unlock(m.wlock)
			return served, .Broken
		}
		ok := write_full(m.fd, m.out[:n])
		unlock(m.wlock)
		if !ok {
			return served, .Hangup
		}
		served += 1

		if is_remove {
			return served, .Removed
		}
	}
}

// hold is the handler's word for "not yet": the loop keeps the request and
// somebody answers it later through `respond`. The reply the handler leaves
// is ignored.
hold :: proc "contextless" (m: ^Mux) {
	m.hold = true
}

// mux_hold copies a request into a free slot. Caller holds `wlock`. False
// when every slot is taken.
@(private = "file")
mux_hold :: proc "contextless" (m: ^Mux, request: []u8, tag: vectra9.Tag) -> bool #no_bounds_check {
	for i in 0 ..< len(m.slots) {
		s := &m.slots[i]
		if !try_claim(&s.busy) {
			continue
		}
		for k in 0 ..< len(request) {
			s.frame[k] = request[k]
		}
		s.size = len(request)
		s.tag = tag
		m.next_seq += 1
		s.seq = m.next_seq
		return true
	}
	return false
}

/*
held finds the oldest held request `wants` accepts, decoded. Caller holds
`wlock`. The slot's `payload` is where a read's answer is built, and
`respond` sends it. `wants` sees the decoded request and the caller's
state, and says whether this producer has what it asks for -- a read of the
window it just typed a line into, and not another's.
*/
held :: proc "contextless" (
	m: ^Mux,
	wants: proc "contextless" (state: rawptr, request: ^vectra9.Msg) -> bool,
) -> (slot: int, tag: vectra9.Tag, request: vectra9.Msg, ok: bool) #no_bounds_check {
	best := -1
	for i in 0 ..< len(m.slots) {
		s := &m.slots[i]
		if intrinsics.atomic_load(&s.busy) == 0 {
			continue
		}
		t, r, derr := vectra9.decode(s.frame[:s.size])
		if derr != .None {
			continue
		}
		if !wants(m.state, &r) {
			continue
		}
		if best < 0 || s.seq < m.slots[best].seq {
			best = i
			tag = t
			request = r
		}
	}
	if best < 0 {
		return -1, vectra9.NOTAG, {}, false
	}
	return best, tag, request, true
}

// slot_payload is where a held read's bytes go before `respond` sends them.
slot_payload :: proc "contextless" (m: ^Mux, slot: int) -> []u8 #no_bounds_check {
	return m.slots[slot].payload
}

/*
respond answers a held request and frees its slot. Caller holds `wlock`.
The reply is encoded into the slot's own buffer and written whole; the
slot goes back after the write, because its buffer is what is being
written. A reply that will not encode frees the slot and sends nothing,
which leaves the client waiting for a flush it will send itself.
*/
respond :: proc "contextless" (m: ^Mux, slot: int, tag: vectra9.Tag, reply: vectra9.Msg) -> bool #no_bounds_check {
	s := &m.slots[slot]
	n, eerr := vectra9.encode(s.out, tag, reply)
	ok := false
	if eerr == .None {
		ok = write_full(m.fd, s.out[:n])
	}
	intrinsics.atomic_store(&s.busy, 0)
	return ok
}

// respond_all answers every held request with `reply`: what a server does
// as it stops, so no client is left waiting on a slot nobody will fill.
respond_all :: proc "contextless" (m: ^Mux, reply: vectra9.Msg) #no_bounds_check {
	lock(m.wlock)
	for i in 0 ..< len(m.slots) {
		s := &m.slots[i]
		if intrinsics.atomic_load(&s.busy) == 0 {
			continue
		}
		tag, _, derr := vectra9.decode(s.frame[:s.size])
		if derr != .None {
			intrinsics.atomic_store(&s.busy, 0)
			continue
		}
		_ = respond(m, i, tag, reply)
	}
	unlock(m.wlock)
}

/*
mux_flush serves a Tflush: a held request it names is dropped, and the
flush answered either way. Reports whether the wire is still good.

Under `wlock`, so a producer answering the same slot and this dropping it
cannot both happen: one of them finds the slot busy and the other does not.
*/
@(private = "file")
mux_flush :: proc "contextless" (m: ^Mux, tag: vectra9.Tag, oldtag: vectra9.Tag) -> bool #no_bounds_check {
	lock(m.wlock)
	for i in 0 ..< len(m.slots) {
		s := &m.slots[i]
		if intrinsics.atomic_load(&s.busy) != 0 && s.tag == oldtag {
			intrinsics.atomic_store(&s.busy, 0)
			break
		}
	}
	ok := false
	if n, err := vectra9.encode(m.out, tag, vectra9.Rflush{}); err == .None {
		ok = write_full(m.fd, m.out[:n])
	}
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
