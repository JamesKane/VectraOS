/*
What this package locks, and the one rule that is not obvious.

Preemption is what made any of this reachable. Before the scheduler there was
one thread, so a reference count was a plain increment and the mount table was
never half-modified. Both of those stopped being true the day a timer could
land between two instructions.

There are two kinds of lock here and they have opposite rules, which is the
part worth reading:

  **Bookkeeping locks** -- `Namespace.lock` and `object_lock` below -- guard
  pointers and counts. They are held for a handful of instructions and are
  never held across a 9P message. See `rpc`.

  **The session lock** -- `Server.lock` -- is held *across* a message, and has
  to be: it is what makes "one request in flight per session" true, and that is
  what makes a borrowed reply safe. See the borrow rule below.

## Who guards what

    Namespace.lock    ns.root, ns.mounts[], ns.mount_count, ns.refs
    object_lock       Chan.refs, Mount_Point.refs, Mount_Point.members
    Server.lock       the session: fid and tag counters, one message in
                      flight, and the lifetime of a borrowed reply
    Static_Tree.lock  one server's own fid table and directory buffer
    device_lock       the `#name` table

Lock order is `Namespace.lock` -> `object_lock`, and nothing takes a namespace
lock while holding an object lock. The heap takes its own lock underneath both,
which is fine because the heap never reaches back up here.

`object_lock` is global rather than per-object, and that is a decision about
what the state *is* rather than about contention. A `Chan` is shared across
namespaces -- `ns_fork` with `Copy` increfs every member -- and a `Mount_Point`
outlives the namespace that created it whenever a chan still names it through
`union_head`. Neither can be guarded by the namespace they were found in,
because they can be reached from a namespace that no longer exists. A word per
chan would be a word per object guarding a single integer; what these counts
actually want is an atomic increment, and when there is a second CPU that is
what they should become, at which point this lock covers only `members`.

Worth knowing about this one specifically: `kernel/verify_vfs.odin` cannot make
it fail. Removing it leaves a window a few instructions wide, and a uniprocessor
holding the interrupt flag as its only lock does not land a timer inside one --
sixty thousand namespace operations did not find it. It is here because on a
second CPU that window is not a matter of timing luck. The file says more.

## The borrow rule

`Rread.data` and `Rreaddir.data` point into the server's own storage -- the
static server's `dirbuf`, or a node's string in `.rodata` -- and are valid
until that server handles its next message. That was safe when nothing could
interrupt the caller between the reply and the copy. It is not safe now: a
timer between `rpc` returning and `copy` landing lets another thread issue a
Treaddir to the same server and overwrite the buffer the first thread is about
to read.

So `rpc` returns a guard and the reply is valid only until it is released:

    e, g := rpc(c.server, &request, &reply)
    defer rpc_end(g)

Every caller does this, including the ones whose replies borrow nothing, so
there is no second entry point to reach for and no judgement to get wrong.

## What is deliberately not locked

A `Chan` is not internally synchronised for `chan_open`, `chan_read` or
`chan_write`. A chan is owned by whoever holds a reference, exactly like a file
descriptor, and two threads doing I/O through one handle is their arrangement
to make. The chans this package *does* share -- the `mounted_over` chain and
the members in a mount table -- are only ever read: a walk from a member
allocates its own fid rather than moving the member's.
*/
package vfs

import "kernel:sync"

/*
The shared object graph: reference counts, and the member lists that join
mount points to chans.

Global on purpose -- see the file comment. The name is the scope: everything it
guards can be reached from more than one namespace.
*/
@(private)
object_lock: sync.Spinlock

// The `#name` table. Written once at boot, read on every device attach.
@(private)
device_lock: sync.Spinlock

/*
How deep in bookkeeping locks this CPU is.

Exists to make "no bookkeeping lock is held across a 9P message" a checked
invariant rather than a comment. `rpc` refuses with EDEADLK if this is not
zero, which turns a rule that would otherwise be broken silently -- and then
found months later as a hang the first time a transport blocks -- into a
failed operation with a name on it.

One counter rather than one per CPU because there is one CPU. It becomes
per-CPU state at the same moment `Spinlock` grows a word, and for the same
reason.
*/
@(private)
lock_depth: int

@(private)
vlock :: proc "contextless" (l: ^sync.Spinlock) -> sync.Guard {
	g := sync.acquire(l)
	lock_depth += 1
	return g
}

@(private)
vunlock :: proc "contextless" (l: ^sync.Spinlock, g: sync.Guard) {
	lock_depth -= 1
	sync.release(l, g)
}
