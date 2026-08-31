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

import "base:intrinsics"

/*
What a server presents to the world.

A handler always produces a reply, even when the answer is no. That is what
`Rlerror` is for, and it is why there is no error return here. A handler that
cannot answer has still answered.

`server` is the handler's own state, passed back to it rather than captured.
Odin closures would need an allocator, and this runs in a kernel that would
rather not.

`tag` names the request being answered. It looks redundant, because a
synchronous transport has exactly one request outstanding and the handler
stands in it. It stops being redundant the moment a transport lets a client
have two. A server that implements `Tflush` has to be able to say which of its
in-flight requests a given `oldtag` names. A handler that cannot name its own
request cannot take part in that. See `kernel/mnt`.

`buf` is storage this request owns, and it is where a reply that carries a
payload must build one. `Rread.data` and `Rreaddir.data` then point into it.

It is the answer to the ownership rule at the top of `proto.odin`. A decoded
message borrows its buffer. A reply the server built in storage of its own is
valid only until that server writes the next one.

One request at a time made that rule workable. Several make it false. No copy
the transport takes after the handler returns can repair that, because another
handler is already in the storage by then. The buffer therefore has to arrive
before the handler does.

A transport that has one request in flight may pass nil, and a handler that
gets nil may build its reply wherever it did before. That is the old rule,
which is still true on the transport it was true on. See `kernel/mnt`.
*/
Handler :: #type proc "contextless" (
	server: rawptr,
	s: ^Session,
	tag: Tag,
	request: ^Msg,
	reply: ^Msg,
	buf: []u8,
)

/*
How a request reaches a handler.

`call` is synchronous *from the caller's side*: it returns once `reply` is
filled in. That is not the same as the transport being synchronous underneath,
and the distinction is the whole of `Tflush`. `kernel/mnt` implements this
signature over a queue and a pool of server threads. Several clients really do
have requests outstanding at once. A caller that gives up holds a tag it must
get back before anything can reuse it.

`tag` is the transport's to interpret. A transport that can only ever have one
request in flight may ignore it. One that cannot must be able to find a request
by it.

That is why `kernel/mnt` indexes its pool by tag, and why the tag it uses is
its own rather than the session's. See `alloc_tag`.

`buf` is the caller's storage for whatever payload the reply carries. A
transport that keeps a request's payload in storage of its own copies it here
before it returns. The caller has no way to know when that storage stops being
its. A caller that asks for nothing larger than a message header may pass nil,
and a transport that never took a copy ignores it.

`call_for` is the same request with a deadline, and it is optional. A transport
that runs the handler on the caller's own stack has nothing to interrupt and
leaves it nil. `call_for` below then falls back to `call`, which is the honest
translation of `this transport cannot be interrupted`. A caller that must know
the difference asks `interruptible`.
*/
Transport :: struct {
	data:     rawptr,
	call:     proc "contextless" (
		data: rawptr,
		s: ^Session,
		tag: Tag,
		request: ^Msg,
		reply: ^Msg,
		buf: []u8,
	) -> Error,
	call_for: proc "contextless" (
		data: rawptr,
		s: ^Session,
		tag: Tag,
		request: ^Msg,
		reply: ^Msg,
		buf: []u8,
		ticks: u64,
	) -> Error,
}

Session :: struct {
	transport: Transport,
	msize:     u32,
	version:   string,

	/*
	Monotonic counters, and the two fields of a session that several threads
	write.

	A recycled fid needs a free list, which needs an allocator. Until a session
	outlives a few thousand opens this is enough, and `alloc_fid` says so where a
	reader will find it.

	Both move by an atomic increment, because a session is shared. `kernel/vfs`
	used to hold a lock across every message, which made these two counters
	incidentally safe. It no longer does. A lost update here hands two threads the
	same fid, and each then holds the other's file.
	*/
	next_tag:  Tag,
	next_fid:  Fid,
}

session_from :: proc "contextless" (transport: Transport) -> Session {
	return Session{transport = transport, msize = MSIZE_DEFAULT, version = VERSION}
}

/*
alloc_tag hands out the next request tag.

NOTAG is skipped because it is reserved for Tversion. A wrap is not an error. A
tag only has to be unique among *outstanding* requests, and a synchronous
transport never has more than one.

A transport that tracks its outstanding requests takes its tags from whatever
structure does the tracking, and not from here.

`kernel/mnt` uses the index of the pool slot. A tag that is not an index into
the pool cannot be found when a `Tflush` names it. This counter is then unused,
which is the honest state of affairs rather than a layering violation. The tag
space belongs to whoever has to keep tags unique among the requests actually in
flight.
*/
alloc_tag :: proc "contextless" (s: ^Session) -> Tag {
	for {
		next := Tag(intrinsics.atomic_add(cast(^u16)&s.next_tag, 1)) + 1
		if next != NOTAG {
			return next
		}
	}
}

/*
alloc_fid hands out the next fid.

Monotonic, and therefore finite: this runs out after four billion opens without
ever reusing one. That is a real limit, and a wider counter is the wrong fix. A
session should hand fids back on `Tclunk`, and take them from a free list.
Deferred until there is a client that opens enough files to care.

A fid stays a *number* on both transports. That includes the in-process one,
where there is no wire, and a pointer to the server's file object would be
faster. Two reasons, and the first is the one that matters. A fid is a
capability, and the lookup against the server's own table is what makes it one.

A number can only name files that server chose to give out. A pointer skips the
check entirely, and a client that can forge one can name anything. The second
reason is that it would make the two transports observably different. That is
precisely what the comment at the top of this file says they are not.

See docs/VECTRA9.md section 7.1.
*/
alloc_fid :: proc "contextless" (s: ^Session) -> Fid {
	for {
		next := Fid(intrinsics.atomic_add(cast(^u32)&s.next_fid, 1)) + 1
		if next != NOFID {
			return next
		}
	}
}

/*
call sends one request and waits for its reply, allocating a tag for it.

`buf` is where the reply's payload lands, and it must outlive every use of
`reply`. Size it by `s.msize` less `HEADER_SIZE` and the count prefix, which is
the largest payload the negotiation permits. A caller that sends nothing which
answers with a payload may pass nil.
*/
call :: proc "contextless" (s: ^Session, request: ^Msg, reply: ^Msg, buf: []u8 = nil) -> Error {
	if s.transport.call == nil {
		return .Transport_Failed
	}
	return s.transport.call(s.transport.data, s, alloc_tag(s), request, reply, buf)
}

/*
call_for is the same request with a deadline.

Returns `.Interrupted` when the deadline passed first. The request is then
flushed and its tag is free, which is the only reason a caller may walk away
from a request at all. See `kernel/mnt`.

A transport with nothing to interrupt answers this exactly as `call` does, and
`interruptible` is how a caller finds that out in advance. Falling back is the
honest translation rather than a convenience. A synchronous transport runs the
handler on the caller's own stack, so there is no other thread to give up on.
Refusing would leave every caller with a fallback path to write.
*/
call_for :: proc "contextless" (
	s: ^Session,
	request: ^Msg,
	reply: ^Msg,
	ticks: u64,
	buf: []u8 = nil,
) -> Error {
	if s.transport.call_for == nil {
		return call(s, request, reply, buf)
	}
	return s.transport.call_for(s.transport.data, s, alloc_tag(s), request, reply, buf, ticks)
}

// interruptible reports whether `call_for` on this session can actually give
// up. False means a deadline is accepted and ignored.
interruptible :: proc "contextless" (s: ^Session) -> bool {
	return s.transport.call_for != nil
}

/*
negotiate performs the Tversion handshake.

Both sides clamp msize downward and the client is obliged to accept the
server's answer, so this takes the smaller of the two. A server that answers
with a version string other than the one asked for is a server that refuses.
That is 9P's way to say `not that dialect`, and the only correct response is to
stop.

The session's own msize is a third clamp, and it is the transport's. `kernel/mnt`
carries a payload in a fixed buffer per request slot, and the size of that
buffer is the largest message it can carry. A transport that says so in
`msize` cannot then be talked above it by either side.
*/
negotiate :: proc "contextless" (s: ^Session, msize: u32 = MSIZE_DEFAULT) -> Error {
	request := Msg(Tversion{msize = msize, version = VERSION})
	reply: Msg

	// Tversion is the one message that must carry NOTAG: the tag space is not
	// established until it succeeds.
	if s.transport.call == nil {
		return .Transport_Failed
	}
	if err := s.transport.call(s.transport.data, s, NOTAG, &request, &reply, nil); err != .None {
		return err
	}

	answer, ok := reply.(Rversion)
	if !ok || answer.version != VERSION {
		return .Unknown_Kind
	}

	s.msize = min(msize, answer.msize, s.msize)
	s.version = answer.version
	return .None
}

// -- In-process transport ----------------------------------------------------

/*
version_reply answers a `Tversion` the way every server in this tree answers it.

The server half of `negotiate` above, and the two belong together because they
are one exchange. Eight servers wrote this out, three in the kernel and five in
ring 3. The wording of a refusal is the part that must not drift.

**A refused dialect is a different version string, never an `Rlerror`.** That is
what a client checks, and it is what lets a client that speaks two versions try
the other one. An error reply would end the session over something that is not
an error.

`msize` is the server's own ceiling, and the answer is the smaller of that and
what the client offered. A server that answered with more than it can hold
would be inviting a frame it has nowhere to put.
*/
version_reply :: proc "contextless" (m: Tversion, reply: ^Msg, msize: u32 = MSIZE_DEFAULT) {
	if m.version != VERSION {
		reply^ = Rversion{msize = m.msize, version = "unknown"}
		return
	}
	reply^ = Rversion{msize = min(m.msize, msize), version = VERSION}
}

/*
The fast path: no encoding at all.

The request struct is handed to the handler by pointer and the reply comes back
the same way. A devfs read of /dev/cons costs one indirect call and no copy of
the payload. That is the reason this design beat a marshal of everything.
Thread state here is a file, and a read of it is a read of a file.

The caller's `buf` reaches the handler untouched, and the handler may fill it.
Nothing copies it afterwards, because there is nothing to copy it out of: the
caller stands on its own stack for the whole exchange.
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
	buf: []u8,
) -> Error {
	p := cast(^In_Process)data
	if p.handler == nil {
		return .Transport_Failed
	}
	p.handler(p.server, s, tag, request, reply, buf)
	return .None
}

// -- Encoded loopback --------------------------------------------------------

/*
The slow path, with no pipe at the end of it.

Encodes the request, decodes it, calls the handler, encodes the reply, decodes
that, and hands it back. Every step a real out-of-process transport would take
except the part that crosses an address space.

Two uses. It is the skeleton a pipe or network transport is written against.
That transport is then a matter of two memory copies replaced with reads and
writes. And it is how the boot self-test proves the claim this file opens with.
The same handler, behind this rather than `In_Process`, must produce the same
answers.

Both buffers are the caller's, and the reply borrows `reply_buf` -- so that
buffer has to outlive the reply, like every other borrowed message in Vectra9.

The caller's `buf` reaches the handler, and is then irrelevant. Whatever the
handler builds there is encoded and decoded on the way back, so the reply the
caller receives points into `reply_buf` either way.
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
	buf: []u8,
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
	p.handler(p.server, s, sent_tag, &decoded, &answer, buf)

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
