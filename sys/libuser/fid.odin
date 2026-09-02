/*
The fid table a userland 9P server binds names into, and the walk over it.

Five servers wrote this file before it existed, and four of them wrote it
identically. Each of `consrv`, `eiafs`, `kbdfs`, `ramfs` and `intuition` carried
a `Fid_Slot`, a linear `fid_lookup`, a `fid_bind` that reuses before it
allocates, and a `fid_release`. Three carried a `walk` that was byte-for-byte
the same.

`kernel/vfs/fidtab.odin` is the same table on the other side of the privilege
boundary, extracted for the same reason one milestone earlier. Neither can
import the other, so there are two of them. That is the one duplication the
layout forces, and it is worth saying out loud rather than leaving for somebody
to find.

## What a server still writes for itself

The tree. A fid binds an `i32` node number, and what a node number *means* is
the server's business. `step` turns a node and a name into another node, and
`qid_of` turns a node into a qid. Both arrive as procedures, because they are
the only two things the walk below needs to know and the only two that differ.

`readdir` is not here for the same reason and a stronger one. Every server's
directory holds different files, and the cookie question -- whether an ordinal
names the same file twice -- has a different answer in each. `docs/SRV.md` is
about a directory where it does not.
*/
package libuser

import "vsys:vectra9"

/*
How many fids one server may hold open at once.

Sixteen, and fixed. The argument is the one `srv.MAX_SERVICES` and
`mem.MAX_SPACES` make. A table a client can grow is a table a client can exhaust
the machine through. A server is exactly what a client talks to.
*/
MAX_FIDS :: 16

Fid_Slot :: struct {
	fid:  vectra9.Fid,
	node: i32,
	used: bool,

	// Whether the client opened this fid. 9P forbids a walk on an open fid and
	// a read on an unopened one, and this is what a server checks to enforce
	// it. `kernel/vfs/fidtab.odin` carries the same flag on the other side of
	// the boundary. See `walk`, `fid_open`, and `open_node`.
	open: bool,
}

/*
A table, and the lock that guards it.

**The lock is unconditional, and two of the five servers did not have one.**
`ramfs` and `intuition` answer one request at a time, so nothing could race
them. That was true of `consrv` too, right up until it grew `serve_mux` and
started answering concurrently.

A lock nothing contends costs one uncontended compare-and-exchange. A table
that needs one and has not got one costs a fid handed to two clients. The
second price is not worth the first saving, and a server that becomes
concurrent should not have to remember this file.
*/
Fid_Table :: struct {
	slots: [MAX_FIDS]Fid_Slot,
	lock:  Spin,
}

// fid_lookup reports which node a fid is bound to, or -1 for a fid this server
// never saw. A linear scan over sixteen slots, which is cheaper than anything
// with a hash in it at this size.
fid_lookup :: proc "contextless" (t: ^Fid_Table, fid: vectra9.Fid) -> i32 #no_bounds_check {
	lock(&t.lock)
	defer unlock(&t.lock)
	for i in 0 ..< MAX_FIDS {
		if t.slots[i].used && t.slots[i].fid == fid {
			return t.slots[i].node
		}
	}
	return -1
}

/*
fid_bind points a fid at a node, and reuses a slot before it takes a new one.

The reuse is not an optimisation. 9P lets a client walk a fid onto itself, so
`newfid == fid` is an ordinary request rather than an error. A bind that always
allocated would answer it with two slots naming one fid, and the second
`Tclunk` would find the first.
*/
fid_bind :: proc "contextless" (t: ^Fid_Table, fid: vectra9.Fid, node: i32) -> bool #no_bounds_check {
	lock(&t.lock)
	defer unlock(&t.lock)
	for i in 0 ..< MAX_FIDS {
		if t.slots[i].used && t.slots[i].fid == fid {
			// A rebind is a fresh binding. Whatever the fid was open on, it
			// is not open on this. A server that enforces the walk rule never
			// reaches a rebind with `open` set. Clearing it keeps the flag
			// honest for a server that has not adopted the check yet.
			t.slots[i].node = node
			t.slots[i].open = false
			return true
		}
	}
	for i in 0 ..< MAX_FIDS {
		if !t.slots[i].used {
			t.slots[i] = Fid_Slot{fid = fid, node = node, used = true}
			return true
		}
	}
	return false
}

// fid_open records that a client opened this fid, so a later `walk` on it is
// refused and a `read` of it is allowed. `open_node` is the read side. Answers
// false for a fid this server never bound.
fid_open :: proc "contextless" (t: ^Fid_Table, fid: vectra9.Fid) -> bool #no_bounds_check {
	lock(&t.lock)
	defer unlock(&t.lock)
	for i in 0 ..< MAX_FIDS {
		if t.slots[i].used && t.slots[i].fid == fid {
			t.slots[i].open = true
			return true
		}
	}
	return false
}

// fid_is_open reports whether a client opened this fid. False for one this
// server never bound, which is the answer a caller wants either way.
fid_is_open :: proc "contextless" (t: ^Fid_Table, fid: vectra9.Fid) -> bool #no_bounds_check {
	lock(&t.lock)
	defer unlock(&t.lock)
	for i in 0 ..< MAX_FIDS {
		if t.slots[i].used && t.slots[i].fid == fid {
			return t.slots[i].open
		}
	}
	return false
}

// fid_release forgets a fid. Silent about one it does not hold, because a
// double clunk is a client's mistake and not a reason to refuse the reply.
fid_release :: proc "contextless" (t: ^Fid_Table, fid: vectra9.Fid) #no_bounds_check {
	lock(&t.lock)
	defer unlock(&t.lock)
	for i in 0 ..< MAX_FIDS {
		if t.slots[i].used && t.slots[i].fid == fid {
			t.slots[i] = Fid_Slot{}
			return
		}
	}
}

// What the walk below has to ask a server about its own tree. `Step` takes a
// node and a name and answers with another node, or -1. `Qid_Of` names a node
// on the wire.
Step :: #type proc "contextless" (from: i32, name: string) -> i32
Qid_Of :: #type proc "contextless" (node: i32) -> vectra9.Qid

/*
walk answers a `Twalk` over one server's tree.

**A partial walk is a success, and that is the rule worth knowing.** 9P says a
walk that gets some of the way answers with the qids it managed and does not
bind the new fid. Only a walk that fails on the *first* name is an error, and
only a walk that arrives whole binds anything. A server that treated a short
walk as failure would break `..` out of a directory that moved under it.

The bind happens last, so a table that is full costs the client an error rather
than a fid it cannot name.
*/
walk :: proc "contextless" (
	t: ^Fid_Table,
	m: vectra9.Twalk,
	reply: ^vectra9.Msg,
	step: Step,
	qid_of: Qid_Of,
) #no_bounds_check {
	from := fid_lookup(t, m.fid)
	if from < 0 {
		reply^ = vectra9.error_reply(vectra9.EBADF)
		return
	}
	// 9P forbids a walk on an open fid: a fid opened for I/O is not a fid to
	// walk forward. `EBUSY` is Plan 9's `Ebadusefd` in this tree's error set.
	if fid_is_open(t, m.fid) {
		reply^ = vectra9.error_reply(vectra9.EBUSY)
		return
	}

	answer: vectra9.Rwalk
	cur := from
	for i in 0 ..< m.count {
		next := step(cur, m.names[i])
		if next < 0 {
			if i == 0 {
				reply^ = vectra9.error_reply(vectra9.ENOENT)
				return
			}
			break
		}
		cur = next
		answer.qids[answer.count] = qid_of(cur)
		answer.count += 1
	}

	if answer.count == m.count {
		if !fid_bind(t, m.newfid, cur) {
			reply^ = vectra9.error_reply(vectra9.ENFILE)
			return
		}
	}
	reply^ = answer
}

/*
attach binds a client's first fid to this server's root.

The one place a fid appears from nothing. Every other fid in a session comes
from a walk off one of these. That is why a table with no room answers `ENFILE`
here, rather than anything about the tree.

`root` is a node number rather than a constant, because a server that served
two trees would attach to a different one per `aname`. None does yet.
*/
attach :: proc "contextless" (
	t: ^Fid_Table,
	m: vectra9.Tattach,
	reply: ^vectra9.Msg,
	root: i32,
	qid_of: Qid_Of,
) {
	if !fid_bind(t, m.fid, root) {
		reply^ = vectra9.error_reply(vectra9.ENFILE)
		return
	}
	reply^ = vectra9.Rattach{qid = qid_of(root)}
}

/*
node_of resolves a fid and answers `EBADF` into `reply` when it cannot.

Twenty-five call sites wrote those four lines, and they all say one thing. A
message names a fid, and a fid this server never handed out is not an error
about the file.

    node, ok := libuser.node_of(&fids, m.fid, reply)
    if !ok {
        return
    }
*/
node_of :: proc "contextless" (t: ^Fid_Table, fid: vectra9.Fid, reply: ^vectra9.Msg) -> (i32, bool) {
	node := fid_lookup(t, fid)
	if node < 0 {
		reply^ = vectra9.error_reply(vectra9.EBADF)
		return -1, false
	}
	return node, true
}

/*
open_node is `node_of` for a message that requires the fid opened first: a
`Tread` or a `Treaddir`. 9P forbids reading a fid before `Tlopen`, and this is
where a server refuses it. `EINVAL` is the answer, because the fid is bound and
the request is the thing that is out of order.

    node, ok := libuser.open_node(&fids, m.fid, reply)
    if !ok {
        return
    }
*/
open_node :: proc "contextless" (t: ^Fid_Table, fid: vectra9.Fid, reply: ^vectra9.Msg) -> (i32, bool) {
	node, ok := node_of(t, fid, reply)
	if !ok {
		return -1, false
	}
	if !fid_is_open(t, fid) {
		reply^ = vectra9.error_reply(vectra9.EINVAL)
		return -1, false
	}
	return node, true
}

/*
default_reply sets the answer a handler gives when its switch says nothing, and
reports whether the switch should run at all.

Two facts every server in this tree shares, and five of them wrote both out.

**Nothing here creates files.** `consrv`, `kbdfs`, `eiafs`, `ramfs` and
`intuition` all serve a fixed tree, so a `Tlcreate` or a `Tmkdir` is `EPERM`
rather than a case nobody wrote. Saying so once is what stops the sixth server
from forgetting, and `kernel/vfs` has no `chan_create` to reach them with in
any case.

**A message a server does not answer is `EOPNOTSUPP`, not silence.** The reply
goes in before the switch rather than in a default arm, so a case that falls
through has already said something. A handler that returned with the reply
untouched would send whatever the last one left in the buffer.
*/
default_reply :: proc "contextless" (request: ^vectra9.Msg, reply: ^vectra9.Msg) -> bool {
	if vectra9.creates(vectra9.kind(request^)) {
		reply^ = vectra9.error_reply(vectra9.EPERM)
		return false
	}
	reply^ = vectra9.error_reply(vectra9.EOPNOTSUPP)
	return true
}
