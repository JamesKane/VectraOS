/*
Sessions and transports -- the boundary where bytes become optional.

A `Session` is one client's conversation with one server: a negotiated msize, a
fid space, a tag space, and a transport. A `Handler` is what a server presents.
A `Transport` is what connects them, and it is the only thing in Vectra9 that
knows whether serialisation happens.

    in-kernel:   caller ── Msg ─────────────────────────▶ handler
    to userland: caller ── Msg ──▶ encode ──[bytes]──▶ decode ──▶ handler

Neither the caller nor the handler can tell which one it has. That is the whole
claim of the design, and `Encoded_Loopback` below exists to make it a testable
one rather than an assertion.
*/
package vectra9

/*
What a server presents to the world.

A handler always produces a reply, even when the answer is no -- that is what
`Rlerror` is for, and it is why there is no error return here. A handler that
cannot answer has still answered.

`server` is the handler's own state, passed back to it rather than captured,
because Odin closures would need an allocator and this runs in a kernel that
would rather not.
*/
Handler :: #type proc "contextless" (server: rawptr, s: ^Session, request: ^Msg, reply: ^Msg)

/*
How a request reaches a handler.

`call` is synchronous: it returns once `reply` is filled in. An asynchronous
transport -- one that lets a client have several requests outstanding, which is
what tags are for -- will need a second entry point, and it will need the
scheduler to exist first.
*/
Transport :: struct {
	data: rawptr,
	call: proc "contextless" (data: rawptr, s: ^Session, tag: Tag, request: ^Msg, reply: ^Msg) -> Error,
}

Session :: struct {
	transport: Transport,
	msize:     u32,
	version:   string,

	// Monotonic counters. Recycling fids needs a free list, which needs an
	// allocator; until a session outlives a few thousand opens this is enough,
	// and `alloc_fid` says so where it will be read.
	next_tag:  Tag,
	next_fid:  Fid,
}

session_from :: proc "contextless" (transport: Transport) -> Session {
	return Session{transport = transport, msize = MSIZE_DEFAULT, version = VERSION}
}

/*
alloc_tag hands out the next request tag.

NOTAG is skipped because it is reserved for Tversion. Wrapping is not an error:
a tag only has to be unique among *outstanding* requests, and with a synchronous
transport there is never more than one.
*/
alloc_tag :: proc "contextless" (s: ^Session) -> Tag {
	s.next_tag += 1
	if s.next_tag == NOTAG {
		s.next_tag = 0
	}
	return s.next_tag
}

/*
alloc_fid hands out the next fid.

Monotonic, and therefore finite: this runs out after four billion opens without
ever reusing one. That is a real limit and the wrong fix is to make the counter
wider -- a session should hand fids back on `Tclunk` and take them from a free
list. Deferred until there is a client that opens enough files to care.
*/
alloc_fid :: proc "contextless" (s: ^Session) -> Fid {
	s.next_fid += 1
	if s.next_fid == NOFID {
		s.next_fid = 0
	}
	return s.next_fid
}

// call sends one request and waits for its reply, allocating a tag for it.
call :: proc "contextless" (s: ^Session, request: ^Msg, reply: ^Msg) -> Error {
	if s.transport.call == nil {
		return .Transport_Failed
	}
	return s.transport.call(s.transport.data, s, alloc_tag(s), request, reply)
}

/*
negotiate performs the Tversion handshake.

Both sides clamp msize downward and the client is obliged to accept the
server's answer, so this takes the smaller of the two. A server that answers
with a version string other than the one asked for is refusing -- 9P's way of
saying "not that dialect" -- and the only correct response is to stop.
*/
negotiate :: proc "contextless" (s: ^Session, msize: u32 = MSIZE_DEFAULT) -> Error {
	request := Msg(Tversion{msize = msize, version = VERSION})
	reply: Msg

	// Tversion is the one message that must carry NOTAG: the tag space is not
	// established until it succeeds.
	if s.transport.call == nil {
		return .Transport_Failed
	}
	if err := s.transport.call(s.transport.data, s, NOTAG, &request, &reply); err != .None {
		return err
	}

	answer, ok := reply.(Rversion)
	if !ok || answer.version != VERSION {
		return .Unknown_Kind
	}

	s.msize = min(msize, answer.msize)
	s.version = answer.version
	return .None
}

// -- In-process transport ----------------------------------------------------

/*
The fast path: no encoding at all.

The request struct is handed to the handler by pointer and the reply comes back
the same way. A devfs read of /dev/cons costs one indirect call and no copy of
the payload -- which is the reason this design was chosen over marshalling
everything, in a system where reading thread state is reading a file.
*/
In_Process :: struct {
	handler: Handler,
	server:  rawptr,
}

in_process_transport :: proc "contextless" (p: ^In_Process) -> Transport {
	return Transport{data = p, call = in_process_call}
}

@(private = "file")
in_process_call :: proc "contextless" (
	data: rawptr,
	s: ^Session,
	tag: Tag,
	request: ^Msg,
	reply: ^Msg,
) -> Error {
	// The tag is meaningless here -- it exists to identify an outstanding
	// request, and a synchronous in-process call has exactly one.
	_ = tag

	p := cast(^In_Process)data
	if p.handler == nil {
		return .Transport_Failed
	}
	p.handler(p.server, s, request, reply)
	return .None
}

// -- Encoded loopback --------------------------------------------------------

/*
The slow path, with no pipe at the end of it.

Encodes the request, decodes it, calls the handler, encodes the reply, decodes
that, and hands it back. Every step a real out-of-process transport would take
except the part that crosses an address space.

Two uses. It is the skeleton a pipe or network transport is written against, so
that transport is a matter of replacing two memory copies with reads and writes.
And it is how the boot self-test proves the claim this file opens with: the same
handler, behind this instead of `In_Process`, must produce the same answers.

Both buffers are the caller's, and the reply borrows `reply_buf` -- so that
buffer has to outlive the reply, like every other borrowed message in Vectra9.
*/
Encoded_Loopback :: struct {
	handler:     Handler,
	server:      rawptr,
	request_buf: []u8,
	reply_buf:   []u8,
}

encoded_loopback_transport :: proc "contextless" (p: ^Encoded_Loopback) -> Transport {
	return Transport{data = p, call = encoded_loopback_call}
}

@(private = "file")
encoded_loopback_call :: proc "contextless" (
	data: rawptr,
	s: ^Session,
	tag: Tag,
	request: ^Msg,
	reply: ^Msg,
) -> Error {
	p := cast(^Encoded_Loopback)data
	if p.handler == nil {
		return .Transport_Failed
	}

	n, err := encode(p.request_buf, tag, request^)
	if err != .None {
		return err
	}

	sent_tag, decoded, derr := decode(p.request_buf[:n])
	if derr != .None {
		return derr
	}

	answer: Msg
	p.handler(p.server, s, &decoded, &answer)

	// The reply carries the request's tag back. A transport that lost this
	// would work perfectly against a synchronous client and fail the moment
	// anything had two requests in flight.
	rn, rerr := encode(p.reply_buf, sent_tag, answer)
	if rerr != .None {
		return rerr
	}

	_, out, oerr := decode(p.reply_buf[:rn])
	if oerr != .None {
		return oerr
	}

	reply^ = out
	return .None
}
