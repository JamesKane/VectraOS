/*
The namespace layer -- Vectra9 section 5, built.

Everything above this file names files with paths; everything below it names
them with fids. `kernel/vfs` is the translation, and it is the only place in the
kernel that knows a path can cross from one server to another halfway through.

Three types carry the whole idea:

    Server      a handler plus the session a client talks to it through
    Chan        a handle on a file *in a namespace*, as opposed to in a session
    Namespace   a private mapping from names to files -- root plus a mount table

There is no global tree. `resolve` starts at a namespace's root and asks each
server in turn, consulting the mount table between every element, so two
processes can each have a `/dev/mouse` and they can be different files. That is
the design in `docs/VECTRA9.md` section 5 and this is the code for it.

Locking is in `kernel/vfs/lock.odin` -- what guards what, in what order, and
the one rule that is not obvious: a bookkeeping lock is never held across a 9P
message, and the session lock always is.

What is deliberately absent:

  - a current directory. `resolve` takes absolute paths and `#name` specs only,
    because a relative path needs a process to be relative to.
  - Tflush. Section 7.3 pins the shape; serving it needs a thread to wake.
*/
package vfs

import "kernel:sync"
import "vsys:vectra9"

/*
The protocol's error vocabulary, used unchanged.

A path layer has no errors of its own worth inventing: every failure here is
one a server could equally have produced, and a caller that has to distinguish
"the mount table says no" from "the server says no" is a caller with a bug.
Zero is success -- Rlerror cannot carry it, so the value is free.
*/
Errno :: vectra9.Errno
OK :: Errno(0)

// -- Servers -----------------------------------------------------------------

/*
One server, and the session a client reaches it through.

A `Server` must not move once registered: the session's transport holds a
pointer into it, and `Chan` and the mount table both use its address as the
identity half of a mount key. Allocate it, or make it a global, but do not
build one on the stack and hand it out.

One session per server, not one per attach. Fids are unique within a session
and that is the only uniqueness 9P requires, so a second session would buy
nothing but a second fid space to keep straight.
*/
Server :: struct {
	name:      string, // The `#name` this is attached by, without the '#'
	session:   vectra9.Session,
	transport: vectra9.In_Process,

	/*
	The session lock -- held across a whole message, unlike every other lock
	in this package.

	It is what makes "one request in flight per session" true, and that claim
	is load-bearing twice over: the fid and tag counters are handed out under
	it, and a reply that borrows the server's storage is valid only while it is
	held. See the borrow rule in `lock.odin`.

	A `sync.Mutex` rather than a `sync.Spinlock`, and that is the whole reason
	`kernel/sync/sleep.odin` exists. A spinlock is the interrupt flag: holding
	one across a message makes every message unpreemptible, which is why a
	uniprocessor doing file I/O used to be very nearly impossible to interrupt,
	and it becomes a hang outright the day a reply arrives *on* an interrupt.
	A mutex parks the thread that loses the race, so the session is exclusive
	without the machine being deaf while it is held, and an out-of-process
	transport can wait under it.
	*/
	lock:      sync.Mutex,
}

/*
server_init wires a handler up as a server and performs the Tversion handshake.

The handshake is not ceremony even in-process. It is the one message that
establishes msize, and a server that answers a version other than 9P2000.L is
refusing -- better to find that out here than at the first Twalk.
*/
server_init :: proc "contextless" (
	sv: ^Server,
	name: string,
	handler: vectra9.Handler,
	state: rawptr,
) -> vectra9.Error {
	sv.name = name
	sv.transport = vectra9.In_Process {
		handler = handler,
		server  = state,
	}
	sv.session = vectra9.session_from(vectra9.in_process_transport(&sv.transport))
	return vectra9.negotiate(&sv.session)
}

/*
The device table -- Vectra9 section 5.8's first escape.

`#name` reaches a kernel-served tree without going through any namespace, which
is what makes a `Clean` namespace recoverable rather than a dead end: a process
with an empty mount table has no path to anything, and `#c` is how it gets one.
Access to this table is therefore a privilege, and the day there are processes
it stops being a free function and starts being a check.

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
`#c` is a build-order bug, and silently letting the second one win would make
it a bug that reproduces only sometimes.
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

Locked even though the table is append-only and registration is over before
the first lookup. A read that races a write of `device_count` sees a slot that
has not been filled in yet, and the cost of ruling that out is a lookup per
attach -- not per walk, not per read. Cheap enough that being sure is worth
more than being clever.
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

// What a reply is valid for. Opaque; `rpc_end` is the only thing that reads it.
@(private)
Rpc_Guard :: struct {
	server: ^Server,
	held:   bool,
}

/*
rpc_begin takes the session, and with it the right to allocate a fid.

Separate from `rpc` for the three callers that need a fid *in* the request they
are about to send -- attach, walk and clone. A fid handed out by one thread and
used by another is not a fid, it is a collision: `alloc_fid` is a plain
increment, and two threads that both read the counter before either writes it
both walk to `newfid` and one of them silently ends up holding the other's
file. Allocating under the session lock and sending without dropping it is what
makes the number mean something.

Fails with EDEADLK if a bookkeeping lock is held -- see `lock.odin`.
*/
@(private)
rpc_begin :: proc "contextless" (sv: ^Server) -> (Rpc_Guard, Errno) {
	if sv == nil {
		return {}, vectra9.EIO
	}

	/*
	The invariant `lock.odin` describes, checked rather than trusted.

	A spinlock held here is the interrupt flag held here, and taking the
	session mutex may park this thread -- which would deschedule it with
	interrupts masked and nothing left to turn them back on. `sync.Mutex`
	stops the machine and names the rule if it gets that far; this refuses
	first, and refusing is the better failure: every caller turns it into a
	failed open or a failed walk, with a name on it, at the call that broke
	the rule rather than months later somewhere else.

	`sync.can_sleep` counts every spinlock on the CPU, not just this
	package's. That is wider than the old rule and correctly so -- the heap
	lock and the scheduler lock are just as fatal to hold across a wait.
	*/
	if !sync.can_sleep() {
		return {}, vectra9.EDEADLK
	}

	sync.mutex_lock(&sv.lock)
	return Rpc_Guard{server = sv, held = true}, OK
}

/*
rpc_under sends one request on a session the caller already holds.

Two failure kinds collapse to one return here, and the collapse is deliberate
in this direction only: a transport failure becomes EIO because there is
nothing a path-layer caller could do differently about it. The distinction that
matters -- `vectra9.Error` versus `Errno`, bytes wrong versus answer no -- is
kept where it is actionable, at the codec. See `sys/vectra9/errors.odin`.
*/
@(private)
rpc_under :: proc "contextless" (
	g: Rpc_Guard,
	request: ^vectra9.Msg,
	reply: ^vectra9.Msg,
) -> Errno {
	if !g.held {
		return vectra9.EIO
	}
	if err := vectra9.call(&g.server.session, request, reply); err != .None {
		return vectra9.EIO
	}
	if e, is_error := reply.(vectra9.Rlerror); is_error {
		// A server that answers Rlerror with zero has said "the answer is no"
		// and named no reason; EIO is closer to the truth than success.
		return e.ecode == 0 ? vectra9.EIO : Errno(e.ecode)
	}
	return OK
}

/*
rpc is the common case: one request, one reply, no fid to allocate first.

    e, g := rpc(c.server, &request, &reply)
    defer rpc_end(g)

`reply` is valid until `rpc_end`, and not one instruction longer: `Rread.data`
and `Rreaddir.data` point into the server's own storage, which the server is
free to reuse for the next message. Holding the session until the caller is
done is what stops a second thread's Treaddir overwriting the buffer this one
is about to copy out of. Every caller takes the guard, including the ones whose
replies borrow nothing, so there is no second entry point to reach for and no
judgement about which replies borrow.
*/
@(private)
rpc :: proc "contextless" (
	sv: ^Server,
	request: ^vectra9.Msg,
	reply: ^vectra9.Msg,
) -> (Errno, Rpc_Guard) {
	g, e := rpc_begin(sv)
	if e != OK {
		return e, g
	}
	return rpc_under(g, request, reply), g
}

/*
rpc_end releases the session, and with it any storage the reply borrowed.

Safe on a guard from a call that never acquired one -- a nil server, or the
EDEADLK refusal -- so a caller can `defer` it on the line after `rpc` without
first checking whether the call got that far.
*/
@(private)
rpc_end :: proc "contextless" (g: Rpc_Guard) {
	if g.held {
		sync.mutex_unlock(&g.server.lock)
	}
}
