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

What is deliberately absent, because the scheduler is what unblocks it:

  - locking. One CPU, no preemption, no concurrent walkers. Every mount-table
    mutation here is a place a lock goes, and they are marked.
  - a current directory. `resolve` takes absolute paths and `#name` specs only,
    because a relative path needs a process to be relative to.
  - Tflush. Section 7.3 pins the shape; serving it needs a thread to wake.
*/
package vfs

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
	if sv == nil || device_count >= MAX_DEVICES {
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

find_device :: proc "contextless" (name: string) -> ^Server #no_bounds_check {
	for i in 0 ..< device_count {
		if devices[i].name == name {
			return devices[i]
		}
	}
	return nil
}

// -- Talking to a server -----------------------------------------------------

/*
rpc sends one request and unwraps the answer.

Two failure kinds collapse to one return here, and the collapse is deliberate
in this direction only: a transport failure becomes EIO because there is
nothing a path-layer caller could do differently about it. The distinction that
matters -- `vectra9.Error` versus `Errno`, bytes wrong versus answer no -- is
kept where it is actionable, at the codec. See `sys/vectra9/errors.odin`.
*/
@(private)
rpc :: proc "contextless" (sv: ^Server, request: ^vectra9.Msg, reply: ^vectra9.Msg) -> Errno {
	if sv == nil {
		return vectra9.EIO
	}
	if err := vectra9.call(&sv.session, request, reply); err != .None {
		return vectra9.EIO
	}
	if e, is_error := reply.(vectra9.Rlerror); is_error {
		// A server that answers Rlerror with zero has said "the answer is no"
		// and named no reason; EIO is closer to the truth than success.
		return e.ecode == 0 ? vectra9.EIO : Errno(e.ecode)
	}
	return OK
}
