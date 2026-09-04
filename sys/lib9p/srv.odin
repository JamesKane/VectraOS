/*
lib9p -- a 9P server on `sys/libthread`, answered from whoever has the
answer.

`libuser.serve` answers one request at a time on the caller's stack, so a
read that must wait holds every other client. `serve_mux` fixed that with
slots in shared memory, a write lock, and a reader process that answered
held requests through them. `docs/PROCS.md` step 1 records what it cost.
Step 4 is this file, the same loop in Plan 9's shape.

## The shape

    the reader   a proc of its own, parked in `read` on the pipe. Each
                 frame it reads becomes a `Req` on the heap, decoded, and
                 goes down a channel.
    the loop     a thread in the program's own proc, `serve`. It takes a
                 `Req` off the channel, calls the handler, and writes the
                 reply. A handler that cannot answer yet calls `hold`, and
                 the loop keeps the record on a list and takes the next.
    the answer   `respond`, from any thread of the same proc, when
                 whatever the request waited for arrives. The thread
                 that reads the keyboard is the usual caller.

**Nothing here is locked, and that is the point.** The handler, the held
list, the reply buffer and the server's own state all belong to one proc.
A thread of that proc runs until it blocks. A read of a device parks a
proc, so a proc of its own reads the device. What it reads comes over a
channel, which is the one place two procs meet. The reader of the pipe
is the same arrangement for the pipe.

The write of a reply is the one call the loop's proc makes into the
kernel, and a pipe write copies and returns.

A server whose handler must also watch a channel of its own takes the
request channel by `requests`. It then calls `handle` per request from an
`alt` of its own. `serve` is that loop with one arm.

## The flush

`Tflush` never reaches the handler. A flush that names a held request
drops it, its reply never written, and answers `Rflush`. One that names
nothing held was answered already, and is answered at once. `Rflush` goes
out after the flushed request's fate is decided, which `kernel/mnt`
requires. Here the decision and the answer are one step, because nothing
runs on a held request's behalf.

## Ending

The loop ends when the pipe does, when a frame will not decode, or when a
`Tremove` is answered. The reader proc is still parked in `read` then.
`libthread.threadexitsall` is what takes it down. A server calls that
after `respond_all` answers whatever it still held.
*/
package lib9p

import "vsys:libthread"
import "vsys:libuser"
import "vsys:vectra9"

Serve_End :: libuser.Serve_End

/*
One request, on the heap, from the reader proc's frame to the reply.

`frame` is the request's bytes and `msg` is decoded out of it, so a
`Twrite`'s data and a `Twalk`'s names point into the record itself.
`payload` is where a reply's bytes are built: a read's data, a listing.
`respond` frees the record, and so does a flush that drops it.
*/
Req :: struct {
	srv:     ^Srv,
	tag:     vectra9.Tag,
	msg:     vectra9.Msg,
	frame:   []u8,
	payload: []u8,
	next:    ^Req, // The held list, oldest first
}

/*
Everything a server fills in, and what the library keeps beside it.

`msize` is the largest frame the server honours, and its `Tversion`
answer should say no more. `keep_on_remove` is for a filesystem, where a
`Tremove` removes a file. A fixed tree stops on one, which is the default.
*/
Srv :: struct {
	fd:             int,
	handler:        vectra9.Handler,
	state:          rawptr,
	msize:          int,
	keep_on_remove: bool,

	// The library's.
	out:            []u8, // Where a reply is encoded before the write
	reqs:           ^libthread.Chan, // `^Req` from the reader; nil is the end
	held:           ^Req,
	held_tail:      ^Req,
	current:        ^Req, // The request the handler is answering
	hold:           bool, // Set by `hold`, read by the loop after the handler
	why:            Serve_End, // Written by the reader before it sends nil
	served:         u64,
	session:        vectra9.Session,
	started:        bool,
}

// How many requests the reader may run ahead of the loop. The kernel's
// wire has eight in flight at most.
REQ_BACKLOG :: 8

@(private = "file")
HEADER :: vectra9.HEADER_SIZE

/*
start makes the reply buffer and the channel, and forks the reader proc.
False when there was no memory for them, or no proc. A caller that alts
over the request channel calls this and then `handle`. `serve` calls it
itself.
*/
start :: proc "contextless" (srv: ^Srv) -> bool {
	if srv.started {
		return true
	}
	if srv.msize < HEADER {
		return false
	}
	out := libuser.heap_alloc(srv.msize)
	if out == nil {
		return false
	}
	srv.out = ([^]u8)(out)[:srv.msize]
	srv.reqs = libthread.chancreate(size_of(rawptr), REQ_BACKLOG)
	if srv.reqs == nil {
		return false
	}
	if libthread.proccreate(reader, srv) < 0 {
		return false
	}
	srv.started = true
	return true
}

// requests is the channel the reader sends on, for a server that alts
// over it and channels of its own. Each element is a `^Req`, or nil when
// the reader stopped, and then `srv.why` says why.
requests :: proc "contextless" (srv: ^Srv) -> ^libthread.Chan {
	return srv.reqs
}

/*
serve is the loop: a request off the channel, the handler, the reply,
until the reader stops or a remove is answered. What it answers is why.
*/
serve :: proc "contextless" (srv: ^Srv) -> (served: u64, why: Serve_End) {
	if !start(srv) {
		return 0, .Broken
	}
	for {
		req := (^Req)(libthread.recvp(srv.reqs))
		if req == nil {
			return srv.served, srv.why
		}
		if handle(srv, req) {
			return srv.served, srv.why
		}
	}
}

/*
handle answers one request, or holds it. True when the loop should stop,
with `srv.why` saying why: the pipe refused a reply, or a remove was
answered and obeyed.
*/
handle :: proc "contextless" (srv: ^Srv, req: ^Req) -> (stop: bool) {
	if f, is_flush := req.msg.(vectra9.Tflush); is_flush {
		return !flush(srv, req, f.oldtag)
	}
	_, is_remove := req.msg.(vectra9.Tremove)

	srv.current = req
	srv.hold = false
	reply: vectra9.Msg
	srv.handler(srv.state, &srv.session, req.tag, &req.msg, &reply, req.payload)
	srv.current = nil

	if srv.hold && !is_remove {
		req.next = nil
		if srv.held == nil {
			srv.held = req
		} else {
			srv.held_tail.next = req
		}
		srv.held_tail = req
		srv.served += 1
		return false
	}
	if !respond(req, reply) {
		srv.why = .Hangup
		return true
	}
	if is_remove && !srv.keep_on_remove {
		srv.why = .Removed
		return true
	}
	return false
}

// hold is the handler's word for "not yet": the loop keeps the request,
// and somebody answers it later through `respond`. The reply the handler
// leaves is ignored.
hold :: proc "contextless" (srv: ^Srv) {
	srv.hold = true
}

/*
held finds the oldest held request `wants` accepts. `wants` sees the
decoded request and the server's state. It says whether the caller has
what the request asks for: a read of the window it just typed a line
into, and not another's. The record's `payload` is where the answer goes,
and `respond` sends it.
*/
held :: proc "contextless" (
	srv: ^Srv,
	wants: proc "contextless" (state: rawptr, request: ^vectra9.Msg) -> bool,
) -> (req: ^Req, ok: bool) {
	for r := srv.held; r != nil; r = r.next {
		if wants(srv.state, &r.msg) {
			return r, true
		}
	}
	return nil, false
}

/*
respond answers a request and frees its record. From any thread of the
server's proc: the loop, for a request the handler answered, or whoever
has the answer to one that was held. The reply is encoded into the
server's buffer and written whole. A reply that will not encode frees
the record and sends nothing, which leaves the client waiting for a flush
it will send itself. False when the pipe refused the write.
*/
respond :: proc "contextless" (req: ^Req, reply: vectra9.Msg) -> bool {
	srv := req.srv
	unhold(srv, req)
	ok := false
	if n, err := vectra9.encode(srv.out, req.tag, reply); err == .None {
		ok = libuser.write_full(srv.fd, srv.out[:n])
	}
	srv.served += 1
	req_free(req)
	return ok
}

// respond_all answers every held request with `reply`. A server does
// this as it stops, so no client waits on a record nobody will fill.
respond_all :: proc "contextless" (srv: ^Srv, reply: vectra9.Msg) {
	for srv.held != nil {
		_ = respond(srv.held, reply)
	}
}

// flush serves a Tflush: a held request it names is dropped, and the
// flush answered either way. Reports whether the wire is still good.
@(private = "file")
flush :: proc "contextless" (srv: ^Srv, req: ^Req, oldtag: vectra9.Tag) -> bool {
	for r := srv.held; r != nil; r = r.next {
		if r.tag == oldtag {
			unhold(srv, r)
			req_free(r)
			break
		}
	}
	ok := respond(req, vectra9.Rflush{})
	if !ok {
		srv.why = .Hangup
	}
	return ok
}

// unhold takes a request off the held list, if it is on it.
@(private = "file")
unhold :: proc "contextless" (srv: ^Srv, req: ^Req) {
	prev: ^Req
	for r := srv.held; r != nil; r = r.next {
		if r == req {
			if prev == nil {
				srv.held = r.next
			} else {
				prev.next = r.next
			}
			if srv.held_tail == r {
				srv.held_tail = prev
			}
			r.next = nil
			return
		}
		prev = r
	}
}

// -- The reader proc -------------------------------------------------------------

/*
reader is the reader proc's whole life: a frame off the pipe, a record
for it, and the record down the channel. It stops when the pipe ends or
a frame cannot be read past, says why in `srv.why`, and sends nil.

A record is one block: the struct, the frame's bytes, and `msize` bytes
of payload after them. The body is read straight into the record, so a
frame is copied once, by the kernel.
*/
@(private = "file")
reader :: proc "contextless" (arg: rawptr) {
	srv := (^Srv)(arg)
	header: [HEADER]u8
	why := Serve_End.Hangup
	for {
		if !libuser.read_full(srv.fd, header[:]) {
			break
		}
		size := int(header[0]) | int(header[1]) << 8 | int(header[2]) << 16 | int(header[3]) << 24
		if size < HEADER || size > srv.msize {
			why = .Broken
			break
		}
		req := req_new(srv, size)
		if req == nil {
			why = .Broken
			break
		}
		copy(req.frame, header[:])
		if size > HEADER && !libuser.read_full(srv.fd, req.frame[HEADER:size]) {
			req_free(req)
			break
		}
		tag, msg, derr := vectra9.decode(req.frame)
		if derr != .None {
			req_free(req)
			why = .Broken
			break
		}
		req.tag = tag
		req.msg = msg
		libthread.sendp(srv.reqs, req)
	}
	srv.why = why
	libthread.sendp(srv.reqs, nil)
}

@(private = "file")
req_new :: proc "contextless" (srv: ^Srv, size: int) -> ^Req {
	block := libuser.heap_alloc(size_of(Req) + size + srv.msize)
	if block == nil {
		return nil
	}
	req := (^Req)(block)
	req^ = {}
	req.srv = srv
	bytes := ([^]u8)(uintptr(block) + size_of(Req))
	req.frame = bytes[:size]
	req.payload = bytes[size:size + srv.msize]
	return req
}

@(private = "file")
req_free :: proc "contextless" (req: ^Req) {
	libuser.heap_free(req)
}
