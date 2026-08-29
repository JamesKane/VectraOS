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

		if is_remove {
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
*/
Mux_Slot :: struct {
	frame:   []u8,
	out:     []u8,
	payload: []u8,
	busy:    u32,
}

/*
Everything `serve_mux` needs, filled in by the caller.

The buffers are the caller's, in shared bss, because their size is the
server's msize and only the server knows it. `blocks` is the one piece of
server knowledge the loop cannot supply: whether a request might park. A
request it flags true for is handed to a worker. Every other is answered
inline, exactly as `serve` does. `wlock` serialises the pipe writes, so a
worker's reply and the main loop's never interleave on the wire.
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
nothing else waits on this process. Encode the reply into the slot, and write
it under the lock so it cannot interleave with another reply. Then free the
slot and exit. The kernel collects the exit, because the fork was `RFNOWAIT`.
*/
@(private = "file")
mux_worker :: proc "contextless" (m: ^Mux, s: ^Mux_Slot, size: int) -> ! {
	session: vectra9.Session
	tag, request, derr := vectra9.decode(s.frame[:size])
	if derr != .None {
		intrinsics.atomic_store(&s.busy, 0)
		exit(0)
	}

	reply: vectra9.Msg
	m.handler(m.state, &session, tag, &request, &reply, s.payload)

	n, eerr := vectra9.encode(s.out, tag, reply)
	if eerr == .None {
		_ = mux_write(m, s.out[:n])
	}
	intrinsics.atomic_store(&s.busy, 0)
	exit(0)
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
