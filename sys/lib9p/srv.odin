/*
lib9p -- a 9P server on `sys/libthread`, answered from whoever has the
answer.

`libuser.serve` answers one request at a time on the caller's stack, so a
read that must wait holds every other client. `serve_mux` fixed that with
slots in shared memory, a write lock, and a reader process that answered
held requests through them. `docs/PROCS.md` step 1 records what it cost.
Step 4 is this file, the same loop in Plan 9's shape.

## The shape

    the loop     `serve`, a thread in the program's own proc. It reads a
                 frame through an io proc, so the thread parks and the
                 proc does not, decodes the frame into a `Req` on the
                 heap, calls the handler, and writes the reply. A handler
                 that cannot answer yet calls `hold`, and the loop keeps
                 the record on a list and reads the next frame.
    the answer   `respond`, from any thread of the same proc, when
                 whatever the request waited for arrives. The thread that
                 reads the keyboard is the usual caller, and
                 `answer_reads` is the loop it makes.

**Nothing here is locked, and that is the point.** The handler, the held
list, the reply buffer and the server's own state all belong to one proc.
A thread of that proc runs until it blocks. A read of the pipe would park
the proc, so an io proc makes it, `libthread.ioread`, and the loop's
thread parks on a channel instead. The write of a reply is the one call
the loop's proc makes into the kernel, and a pipe write copies and
returns.

## The flush

`Tflush` never reaches the handler. A flush that names a held request
drops it, its reply never written, and answers `Rflush`. One that names
nothing held was answered already, and is answered at once. `Rflush` goes
out after the flushed request's fate is decided, which `kernel/mnt`
requires. Here the decision and the answer are one step, because nothing
runs on a held request's behalf.

## Ending

The loop ends when the pipe does, when a frame will not decode, or when a
`Tremove` is answered. The io proc is still parked in `read` then.
`libthread.threadexitsall` is what takes it down. A server calls that
after `respond_all` answers whatever it still held.
*/
package lib9p

import "vsys:libthread"
import "vsys:libuser"
import "vsys:vectra9"

Serve_End :: libuser.Serve_End

/*
One request, on the heap, from the frame to the reply.

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
	held:    bool,
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
	io:             ^libthread.Ioproc,
	out:            []u8, // Where a reply is encoded before the write
	held:           ^Req,
	hold:           bool, // Set by `hold`, read by the loop after the handler
	served:         u64,
	session:        vectra9.Session,
}

// What a caller of `held` and `answer_reads` supplies: whether a held
// request is one it can answer, and the bytes for the answer.
Wants :: #type proc "contextless" (arg: rawptr, request: ^vectra9.Msg) -> bool
Drain :: #type proc "contextless" (arg: rawptr, buf: []u8) -> int

@(private = "file")
HEADER :: vectra9.HEADER_SIZE

/*
serve is the loop: a frame off the pipe, the handler, the reply. It ends
when the pipe ends, a frame will not decode, or a remove is answered, and
what it answers is why.
*/
serve :: proc "contextless" (srv: ^Srv) -> (served: u64, why: Serve_End) {
	if srv.msize < HEADER {
		return 0, .Broken
	}
	out := libuser.heap_alloc(srv.msize)
	if out == nil {
		return 0, .Broken
	}
	srv.out = ([^]u8)(out)[:srv.msize]
	srv.io = libthread.ioproc()
	if srv.io == nil {
		return 0, .Broken
	}

	header: [HEADER]u8
	for {
		if !libthread.ioread_full(srv.io, srv.fd, header[:]) {
			return srv.served, .Hangup
		}
		declared, sane := vectra9.message_size(header[:])
		size := int(declared)
		if !sane || size > srv.msize {
			return srv.served, .Broken
		}
		req := req_new(srv, size)
		if req == nil {
			return srv.served, .Broken
		}
		copy(req.frame, header[:])
		if size > HEADER && !libthread.ioread_full(srv.io, srv.fd, req.frame[HEADER:]) {
			req_free(req)
			return srv.served, .Hangup
		}
		tag, msg, derr := vectra9.decode(req.frame)
		if derr != .None {
			req_free(req)
			return srv.served, .Broken
		}
		req.tag = tag
		req.msg = msg
		if stop, end := handle(srv, req); stop {
			return srv.served, end
		}
	}
}

/*
handle answers one request, or holds it. `stop` when the loop should end,
with `why` saying whether the pipe refused a reply or a remove was
answered and obeyed.
*/
@(private = "file")
handle :: proc "contextless" (srv: ^Srv, req: ^Req) -> (stop: bool, why: Serve_End) {
	if f, is_flush := req.msg.(vectra9.Tflush); is_flush {
		for r := srv.held; r != nil; r = r.next {
			if r.tag == f.oldtag {
				unhold(srv, r)
				req_free(r)
				break
			}
		}
		return !respond(req, vectra9.Rflush{}), .Hangup
	}
	_, is_remove := req.msg.(vectra9.Tremove)

	srv.hold = false
	reply: vectra9.Msg
	srv.handler(srv.state, &srv.session, req.tag, &req.msg, &reply, req.payload)

	if srv.hold && !is_remove {
		req.held = true
		req.next = nil
		if srv.held == nil {
			srv.held = req
		} else {
			last := srv.held
			for last.next != nil {
				last = last.next
			}
			last.next = req
		}
		srv.served += 1
		return false, .Hangup
	}
	if !respond(req, reply) {
		return true, .Hangup
	}
	if is_remove && !srv.keep_on_remove {
		return true, .Removed
	}
	return false, .Hangup
}

// hold is the handler's word for "not yet": the loop keeps the request,
// and somebody answers it later through `respond`. The reply the handler
// leaves is ignored.
hold :: proc "contextless" (srv: ^Srv) {
	srv.hold = true
}

// held finds the oldest held request `wants(arg, request)` accepts: a read
// of the window a line was just typed into, and not another's. The
// record's `payload` is where the answer goes, and `respond` sends it.
held :: proc "contextless" (srv: ^Srv, arg: rawptr, wants: Wants) -> (req: ^Req, ok: bool) {
	for r := srv.held; r != nil; r = r.next {
		if wants(arg, &r.msg) {
			return r, true
		}
	}
	return nil, false
}

/*
answer_reads gives held reads what `drain` has for them, oldest first,
until a read is answered with nothing or none is left. Every server does
this when its device delivers. `wants` is the read of the file the bytes
are for, and `drain` takes them out of the ring for it.
*/
answer_reads :: proc "contextless" (srv: ^Srv, arg: rawptr, wants: Wants, drain: Drain) {
	for {
		req, ok := held(srv, arg, wants)
		if !ok {
			return
		}
		m := req.msg.(vectra9.Tread)
		room := min(len(req.payload), int(m.count))
		got := drain(arg, req.payload[:room])
		if got == 0 {
			return
		}
		_ = respond(req, vectra9.Rread{data = req.payload[:got]})
	}
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
	if req.held {
		unhold(srv, req)
	}
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

// unhold takes a request off the held list.
@(private = "file")
unhold :: proc "contextless" (srv: ^Srv, req: ^Req) {
	req.held = false
	if srv.held == req {
		srv.held = req.next
		req.next = nil
		return
	}
	for r := srv.held; r != nil; r = r.next {
		if r.next == req {
			r.next = req.next
			req.next = nil
			return
		}
	}
}

// A record is one block: the struct, the frame's bytes, and `msize` bytes
// of payload after them.
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
