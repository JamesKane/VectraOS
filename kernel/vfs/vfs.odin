/*
The namespace layer -- Vectra9 section 5, built.

Everything above this file names files with paths. Everything below it names
them with fids. `kernel/vfs` is the translation. It is also the only place in
the kernel that knows a path can cross from one server to another halfway
through.

Three types carry the whole idea:

    Server      a handler plus the session a client talks to it through
    Chan        a handle on a file *in a namespace*, as opposed to in a session
    Namespace   a private mapping from names to files -- root plus a mount table

There is no global tree. `resolve` starts at a namespace's root and asks each
server in turn. It consults the mount table between every element. Two
processes can therefore each have a `/dev/mouse`, and the two can be different
files. That is the design in `docs/VECTRA9.md` section 5 and this is the code
for it.

The locking is in `kernel/vfs/lock.odin`. That file says what guards what, in
what order, and states the one rule that is not obvious. A bookkeeping lock is
never held across a 9P message. The session lock always is.

What is deliberately absent:

  - a current directory. `resolve` takes absolute paths and `#name` specs only,
    because a relative path needs a process to be relative to.
  - a global tree, and any lock that would imply one.

A server here sits on one of two transports and does not know which. The
synchronous one runs the handler on the caller's own stack. The asynchronous
one is `kernel/mnt`: a queue, a pool of worker threads, several requests in
flight, and `Tflush` under a caller that gives up. `server_start` is the move
between them, and nothing above it changes.

That is the claim `docs/VECTRA9.md` opens with, and it is now checked rather
than asserted. `kernel/verify_vfs.odin` runs the same namespace over both.
*/
package vfs

import "kernel:mnt"
import "kernel:sync"
import "vsys:vectra9"

/*
The protocol's error vocabulary, used unchanged.

A path layer has no errors of its own worth inventing. Every failure here is
one a server could equally produce.

A caller that has to tell `the mount table says no` apart from `the server says
no` is a caller with a bug. Zero is success -- Rlerror cannot carry it, so the
value is free.
*/
Errno :: vectra9.Errno
OK :: Errno(0)

// -- Servers -----------------------------------------------------------------

/*
One server, and the session a client reaches it through.

A `Server` must not move once registered. The session's transport holds a
pointer into it. `Chan` and the mount table both use its address as the
identity half of a mount key. Allocate it, or make it a global, but do not
build one on the stack and hand it out.

One session per server, not one per attach. Fids are unique within a session,
and that is the only uniqueness 9P requires. A second session would buy nothing
but a second fid space to keep straight.
*/
Server :: struct {
	name:      string, // The `#name` this is attached by, without the '#'
	session:   vectra9.Session,

	/*
	The synchronous transport, used when this server has no workers of its own.

	The handler runs on the caller's own stack. That is one indirect call and no
	copy of anything. It is the right shape for a tree that lives in kernel memory
	and answers without waiting. The root device is one. So is anything registered
	before the scheduler exists, because workers are threads.
	*/
	direct:    vectra9.In_Process,

	/*
	The asynchronous transport, when this server has workers.

	Non-nil means requests go on a queue and come back by tag, several at once.
	A caller with a deadline can then give up and flush. That is what a server
	which waits for hardware, or which lives in another address space, has to sit
	behind. `server_start` builds it and `server_stop` takes it down.

	`arena` is the payload storage it divides among its request slots. It stays
	this server's for as long as the connection does. See `docs/TRANSPORT.md`.
	*/
	conn:      ^mnt.Conn,
	arena:     []u8,

	/*
	The counted release, for a server that can come down.

	`chans` is how many live chans name this server, kept by `chan_alloc`
	and `chan_close` under the chan lock. `pins` is every stake that is not
	a chan: a `/srv` name holding a connection, and a mount still being
	built. When both reach zero and `release` is set, the release runs once,
	on the thread that dropped the last piece. That thread is in a context
	where a message may park.

	Nil `release` is a kernel server, which is never released, and for
	which the counts are bookkeeping nobody reads. `releasing` is the
	once-guard: set with the decision to fire, cleared by
	`server_release_confirm` if something took a new stake in between.
	*/
	chans:     int,
	pins:      int,
	releasing: bool,
	release:   proc(sv: ^Server),

	/*
	What physical memory a file *is*, for the one kind of file that is memory
	rather than a stream.

	**Not a 9P message, and that is the whole point.** `docs/VECTRA9.md` opens
	with the rule that nothing is added to the wire. A mapping cannot be a
	message, because no reply carries an address space. So this is a second
	thing a server may offer the *kernel*, beside `release` above, and no
	client can reach it.

	`kernel/devfs` sets it and answers for `/dev/fb` alone. Every other server
	leaves it nil, which is the honest answer to `this file is a stream`. The
	qid is what says which file, because one server serves several and only one
	of them is memory.

	See `docs/DRAW.md` section 7, which itemised this a milestone before it
	existed.
	*/
	device:    proc "contextless" (sv: ^Server, qid: vectra9.Qid) -> (phys: uintptr, bytes: u64, ok: bool),
}

// server_pin takes a non-chan stake on a server: a name that holds it, or a
// mount partway through being built. `server_unpin` is the other half.
server_pin :: proc "contextless" (sv: ^Server) {
	if sv == nil {
		return
	}
	g := sync.acquire(&object_lock)
	sv.pins += 1
	sync.release(&object_lock, g)
}

// server_unpin releases one stake, and fires the release when nothing else
// holds the server. May park: the release tears a connection down.
server_unpin :: proc(sv: ^Server) {
	if sv == nil {
		return
	}
	g := sync.acquire(&object_lock)
	sv.pins -= 1
	fire := server_should_release(sv)
	release := sv.release
	sync.release(&object_lock, g)
	if fire {
		release(sv)
	}
}

/*
server_release_confirm is the release's second look, taken under its own
serialisation.

Between the decision to fire and the release's lock, a new mount can pin
the server back to life. The release calls this once it holds whatever
excludes new stakes. True keeps the decision. False means something revived
the server: the once-guard clears, the release walks away, and a later
last-drop decides again.
*/
server_release_confirm :: proc "contextless" (sv: ^Server) -> bool {
	g := sync.acquire(&object_lock)
	defer sync.release(&object_lock, g)
	if sv.chans <= 0 && sv.pins <= 0 {
		return true
	}
	sv.releasing = false
	return false
}

// server_should_release is the fire decision, made under `object_lock` by
// whoever dropped the last chan or the last pin. The caller runs the hook
// outside the lock.
@(private)
server_should_release :: proc "contextless" (sv: ^Server) -> bool {
	if sv.chans > 0 || sv.pins > 0 || sv.release == nil || sv.releasing {
		return false
	}
	sv.releasing = true
	return true
}

/*
server_init wires a handler up as a server and performs the Tversion handshake.

The handshake is not ceremony even in-process. It is the one message that
establishes msize. A server that answers a version other than 9P2000.L is a
server that refuses. Better to find that out here than at the first Twalk.

Synchronous, because workers are threads and this runs before there are any.
`server_start` is how a server gets them, and it is a separate call for that
reason rather than for tidiness.
*/
server_init :: proc "contextless" (
	sv: ^Server,
	name: string,
	handler: vectra9.Handler,
	state: rawptr,
) -> vectra9.Error {
	sv.name = name
	sv.conn = nil
	sv.arena = nil
	sv.direct = vectra9.In_Process {
		handler = handler,
		server  = state,
	}
	sv.session = vectra9.session_from(vectra9.in_process_transport(&sv.direct))
	return vectra9.negotiate(&sv.session)
}

/*
server_start moves a server onto `kernel/mnt`, with `workers` threads on it.

The server keeps its handler and its state. What changes is that requests reach
it through a queue rather than through the caller's stack, several at once. A
caller with a deadline can then give up on one, which is what makes `Tflush`
reachable from a path.

**Two things a handler must already be, and one it need not be.** It must be
safe against several threads inside it at once, because there now are. It must
build any payload it answers with in the `buf` it is handed. The storage it used
to borrow is shared, and several requests now use it. What a handler need not be
is aware of any of this. `vfs.static_handler` moved with no change at all.

`payload` is the bytes each request slot gets, and it becomes the session's
msize. Zero asks for `DEFAULT_PAYLOAD`.

`abort` is what a server does when one of its requests is flushed, and it is
optional. A server without one is still correct. It simply cannot abandon work,
so `Rflush` waits for the request to finish on its own. A caller's deadline then
buys nothing but a name for what happened. See `docs/TRANSPORT.md`.

Fails, and leaves the server on its synchronous transport, if the heap has no
room or no worker would start. A server that half-moved would be worse than one
that did not move: the session's transport is what every existing chan reaches
it through.
*/
DEFAULT_PAYLOAD :: 4096

server_start :: proc(
	sv: ^Server,
	workers: int = 2,
	payload: int = 0,
	abort: proc "contextless" (server: rawptr, tag: vectra9.Tag) = nil,
) -> bool {
	if sv == nil || sv.conn != nil || workers <= 0 {
		return false
	}
	per := payload if payload > 0 else DEFAULT_PAYLOAD
	if per < mnt.MIN_PAYLOAD {
		return false
	}

	arena := make([]u8, per * mnt.MAX_REQUESTS)
	if arena == nil {
		return false
	}
	conn := new(mnt.Conn)
	if conn == nil {
		delete(arena)
		return false
	}

	if !mnt.init(conn, sv.direct.handler, sv.direct.server, abort, arena) {
		free(conn)
		delete(arena)
		return false
	}
	if !mnt.serve_start(conn, workers) {
		// Whatever started has to come down. `serve_stop` waits for it, which
		// is the only way to know the threads are off this connection before
		// the memory under them goes.
		mnt.serve_stop(conn)
		free(conn)
		delete(arena)
		return false
	}

	/*
	The session is rebuilt rather than edited, because msize comes from the new
	transport and the fid space does not.

	A fid the old session handed out is still bound on the server, and every
	live `Chan` still names it. Carrying the counter over is what stops the next
	`alloc_fid` from handing out one that is already in use.
	*/
	next_fid := sv.session.next_fid
	sv.conn = conn
	sv.arena = arena
	sv.session = mnt.session(conn)^
	sv.session.next_fid = next_fid

	if vectra9.negotiate(&sv.session) != .None {
		return false
	}
	return true
}

/*
server_stop takes the workers off a server and puts it back on its own stack.

Waits for the workers, because the next thing to happen is that their arena is
freed. Requests in flight fail as transport failures, which is what a
connection that goes away looks like from the outside.

Deliberately reversible. A server that stops is still a server, and a chan that
survives the change still names a fid its handler knows. The self-tests need
that, and so does anything that ever moves a service in or out of a thread.
*/
server_stop :: proc(sv: ^Server) {
	if sv == nil || sv.conn == nil {
		return
	}
	mnt.serve_stop(sv.conn)

	next_fid := sv.session.next_fid
	free(sv.conn)
	delete(sv.arena)
	sv.conn = nil
	sv.arena = nil

	sv.session = vectra9.session_from(vectra9.in_process_transport(&sv.direct))
	sv.session.next_fid = next_fid
	_ = vectra9.negotiate(&sv.session)
}

// server_interruptible reports whether a request to this server can be given up
// on. False on the synchronous transport, where there is nothing to give up.
server_interruptible :: proc "contextless" (sv: ^Server) -> bool {
	return sv != nil && vectra9.interruptible(&sv.session)
}

/*
server_flushed reports whether a Tflush named this request's tag.

The other half of the abort hook, and the half a handler needs. The hook is the
wake. This is the reason, and a handler that can abandon its work asks here
before it decides to.

Authoritative in a way a flag of the server's own could not be. The bit lives on
the request slot, and `kernel/mnt` clears it when the slot is claimed. A server
keeping its own copy would have to clear it at that same moment, which is a
moment no server can see. See `kernel/devfs`.

False on the synchronous transport, where nothing is ever pending and therefore
nothing was ever flushed.
*/
server_flushed :: proc "contextless" (sv: ^Server, tag: vectra9.Tag) -> bool {
	return sv != nil && sv.conn != nil && mnt.flushed(sv.conn, tag)
}

// server_msize is the largest message this server's transport carries. It
// changes when a server moves between transports, because it is a property of
// the buffer underneath rather than of the server. See `server_start`.
server_msize :: proc "contextless" (sv: ^Server) -> u32 {
	return sv == nil ? 0 : sv.session.msize
}

/*
The device table -- Vectra9 section 5.8's first escape.

`#name` reaches a kernel-served tree through no namespace at all, which is what
makes a `Clean` namespace recoverable rather than a dead end. A process with an
empty mount table has no path to anything, and `#c` is how it gets one. Access
to this table is therefore a privilege, and the day there are processes it
stops being a free function and starts being a check.

Small and fixed because it is a boot-time registry. A driver that wants a name
registers during init or does not exist.
*/
MAX_DEVICES :: 16

@(private)
devices: [MAX_DEVICES]^Server
@(private)
device_count: int

/*
register_device publishes a server under a `#name`.

Duplicate names are refused rather than shadowed. Two drivers that both want
`#c` is a build-order bug. A silent win for the second one would make it a bug
that reproduces only sometimes.
*/
register_device :: proc "contextless" (sv: ^Server) -> bool #no_bounds_check {
	if sv == nil {
		return false
	}
	g := sync.acquire(&device_lock)
	defer sync.release(&device_lock, g)

	if device_count >= MAX_DEVICES {
		return false
	}
	for i in 0 ..< device_count {
		if devices[i].name == sv.name {
			return false
		}
	}
	devices[device_count] = sv
	device_count += 1
	return true
}

/*
find_device looks a `#name` up.

Locked even though the table is append-only and registration is over before the
first lookup. A read that races a write of `device_count` sees a slot nothing
filled in yet. The cost to rule that out is one lookup per attach. It is not
per walk, and not per read. Cheap enough that being sure is worth more than
being clever.
*/
find_device :: proc "contextless" (name: string) -> ^Server #no_bounds_check {
	g := sync.acquire(&device_lock)
	defer sync.release(&device_lock, g)

	for i in 0 ..< device_count {
		if devices[i].name == name {
			return devices[i]
		}
	}
	return nil
}

// -- Talking to a server -----------------------------------------------------

/*
rpc sends one request and waits for its reply.

    e := rpc(c.server, &request, &reply, buf)

`buf` is where a reply that carries a payload lands, and it is the caller's.
`Rread.data` and `Rreaddir.data` point into it when this returns, and they stay
good for as long as the caller's own storage does. A request that answers with
no payload passes nil.

**That is a change of ownership, and it is what let the session lock go.** The
payload used to live in the server's storage and stay valid only while something
held the session. Every caller therefore took a guard and released it when it
was done reading. A request slot in `kernel/mnt` now owns a buffer, the handler
builds its reply there, and `mnt.call` copies it here before the slot goes back.
See `docs/TRANSPORT.md`.

Two failure kinds collapse to one return, and the collapse is deliberate in
this direction only. A transport failure becomes EIO, because there is nothing
a path-layer caller could do differently about it. The distinction that matters
-- `vectra9.Error` versus `Errno`, bytes wrong versus answer no -- is kept
where it is actionable, at the codec. See `sys/vectra9/errors.odin`.
*/
@(private)
rpc :: proc "contextless" (
	sv: ^Server,
	request: ^vectra9.Msg,
	reply: ^vectra9.Msg,
	buf: []u8 = nil,
) -> Errno {
	if e := rpc_ready(sv); e != OK {
		return e
	}
	return rpc_answer(vectra9.call(&sv.session, request, reply, buf), reply)
}

/*
rpc_for is the same request with a deadline, and it is why this package moved.

Returns EINTR when the deadline passed. The request was flushed, so the tag is
free and nothing will write into `buf` afterwards. That is the guarantee
`Tflush` exists to provide and the only reason a caller may walk away.

On a server with no workers there is nothing to interrupt, and this answers
exactly as `rpc` does. `server_interruptible` is how a caller finds that out in
advance rather than by waiting.
*/
@(private)
rpc_for :: proc "contextless" (
	sv: ^Server,
	request: ^vectra9.Msg,
	reply: ^vectra9.Msg,
	ticks: u64,
	buf: []u8 = nil,
) -> Errno {
	if e := rpc_ready(sv); e != OK {
		return e
	}
	return rpc_answer(vectra9.call_for(&sv.session, request, reply, ticks, buf), reply)
}

/*
rpc_ready refuses a message this thread is not allowed to send.

Fails with EDEADLK if a bookkeeping lock is held -- see `lock.odin`.

A spinlock held here is the interrupt flag held here, and a message can park
this thread. On `kernel/mnt` it always does: the caller sleeps until a worker
answers. That would take the thread off the CPU with interrupts masked, and
nothing left to turn them back on.

The rule used to be about the session mutex, which was the thing that could
park. It is now about the transport, which is a better reason for the same rule.
It holds whether or not this package locks anything. It also holds for every
caller, rather than for the ones that happen to take a lock.

Every caller turns a refusal into a failed open or a failed walk, with a name
on it, at the call that broke the rule. That beats a fault months later
somewhere else.

`sync.can_sleep` counts every spinlock on the CPU, not just this package's.
That is wider than the old rule and correctly so. The heap lock and the
scheduler lock are just as fatal to hold across a wait.
*/
@(private)
rpc_ready :: proc "contextless" (sv: ^Server) -> Errno {
	if sv == nil {
		return vectra9.EIO
	}
	if !sync.can_sleep() {
		return vectra9.EDEADLK
	}
	return OK
}

@(private)
rpc_answer :: proc "contextless" (err: vectra9.Error, reply: ^vectra9.Msg) -> Errno {
	#partial switch err {
	case .None:
	case .Interrupted:
		// The caller's own deadline, not a server's refusal. It is the one
		// transport error a path-layer caller can act on, so it keeps its name.
		return vectra9.EINTR
	case:
		return vectra9.EIO
	}
	if e, is_error := reply.(vectra9.Rlerror); is_error {
		// A server that answers Rlerror with zero said `the answer is no` and named
		// no reason. EIO is closer to the truth than success.
		return e.ecode == 0 ? vectra9.EIO : Errno(e.ecode)
	}
	return OK
}

/*
new_fid takes the next fid on a server's session.

Separate from the message that uses it, which it did not used to be. The old
arrangement allocated a fid and sent the request without letting go of the
session. `alloc_fid` was a plain increment, and two threads could read the
counter before either wrote it.

`alloc_fid` is an atomic compare-and-swap now, so the number is this thread's
the moment it comes back. Nothing has to be held around the message that carries
it. It returns `NOFID` when the session's fid space is spent. Every caller turns
that into `EMFILE` rather than sending a message with no fid in it. See
`sys/vectra9/session.odin`.
*/
@(private)
new_fid :: proc "contextless" (sv: ^Server) -> vectra9.Fid {
	return vectra9.alloc_fid(&sv.session)
}

/*
take_payload reports how many bytes of a reply's payload are in `buf`, and
copies them there only when they are not already.

They usually are. `rpc` hands the server the caller's own storage, so a handler
that built its payload where it was told to wrote it in place. On the
synchronous transport that is a read with no copy anywhere in it, which is the
property `docs/VECTRA9.md` opens by claiming.

A server may still answer out of storage of its own. A file whose contents are
a string in `.rodata` has no reason to copy them somewhere first. That reply is
valid because the storage is, and this is where it lands instead.
*/
@(private)
take_payload :: proc "contextless" (buf: []u8, data: []u8) -> int {
	n := min(len(data), len(buf))
	if n <= 0 {
		return 0
	}
	if raw_data(data) == raw_data(buf) {
		return n
	}
	copy(buf[:n], data[:n])
	return n
}

/*
max_payload is the largest payload this server may carry in a single
request. That is its msize less the room a data message reserves for its
header -- `vectra9.IOHDRSZ`, Plan 9's number.

A caller sizes its own buffer by this, and clamps a read or a write to it,
the way 9front clamps to `msize - IOHDRSZ`. Reserving only a header and a
count, as this did before, forgot a `Twrite`'s fid and offset. So a
full-payload write serialised twelve bytes past the frame. The overshoot
was latent behind the ring 3 copy bound and came due with the bulk path.
*/
@(private)
max_payload :: proc "contextless" (sv: ^Server) -> int {
	return int(sv.session.msize) - vectra9.IOHDRSZ
}
