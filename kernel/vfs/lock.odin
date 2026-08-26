/*
What this package locks, and the one rule that is not obvious.

Preemption is what made any of this reachable. Before the scheduler there was
one thread, so a reference count was a plain increment and the mount table was
never half-modified. Both of those stopped being true the day a timer could
land between two instructions.

There are two kinds of lock here and they have opposite rules, which is the
part worth reading:

  **Bookkeeping locks** -- `Namespace.lock` and `object_lock` below -- are
  `sync.Spinlock`s. They guard pointers and counts, are held for a handful of
  instructions, and are never held across a 9P message. See `rpc`.

  **The session lock** -- `Server.lock` -- is a `sync.Mutex`, and is held
  *across* a message. It has to be: it is what makes "one request in flight per
  session" true, and that is what makes a borrowed reply safe. See the borrow
  rule below.

The difference is not a matter of degree. A spinlock here *is* the interrupt
flag. Held across a message, one would make every message unpreemptible, and
would hang the machine outright the day a reply arrives on an interrupt. A
mutex parks its loser, which costs a context switch and buys both.

## Who guards what

    Namespace.lock    ns.root, ns.mounts[], ns.mount_count, ns.refs
    object_lock       Chan.refs, Mount_Point.refs, Mount_Point.members
    Server.lock       the session: fid and tag counters, one message in
                      flight, and the lifetime of a borrowed reply
    Static_Tree.lock  one server's own fid table and directory buffer
    device_lock       the `#name` table

Lock order has two rules. Among the spinlocks it is `Namespace.lock` ->
`object_lock`, and nothing takes a namespace lock while holding an object lock.
Across the two kinds it is `Server.lock` -> any spinlock, never the reverse.
The session may be held while something touches the heap or a mount table. A
spinlock may not be held while something asks for the session. `sync.can_sleep`
is that second rule, checked. See `rpc_begin`.

`object_lock` is global rather than per-object, and that is a decision about
what the state *is* rather than about contention. A `Chan` is shared across
namespaces, because `ns_fork` with `Copy` increfs every member. A `Mount_Point`
outlives the namespace that created it whenever a chan still names it through
`union_head`. The namespace they were found in cannot guard either one, because
a namespace that no longer exists can still reach them.

A word per chan would be a word per object, guarding a single integer. What
these counts actually want is an atomic increment. When there is a second CPU
that is what they should become, and this lock then covers only `members`.

Worth knowing about this one specifically: `kernel/verify_vfs.odin` cannot make
it fail, and it is not for want of preemption. Removed, it leaves a window two
instructions wide, between a count loaded and stored back. Only a timer can
land inside one, and there are a thousand of those a run whether or not the
layer around it blocks.

A hundred thousand voluntary parks per run do not help, because every one of
them is at a lock boundary and this window is not. It is here because on a
second CPU that window is not a matter of timing luck. The file says more.

## The borrow rule

`Rread.data` and `Rreaddir.data` point into the server's own storage. That is
the static server's `dirbuf`, or a node's string in `.rodata`. Both stay valid
until that server handles its next message.

That was safe when nothing could interrupt the caller between the reply and the
copy. It is not safe now. A timer between the return from `rpc` and the copy
lets another thread issue a Treaddir to the same server. The second thread then
overwrites the buffer the first is about to read.

What makes it safe now is the session lock rather than the interrupt flag, and
that is a real change of mechanism. The thread that copies a borrowed buffer
can be preempted, and is, thousands of times a run. It is safe because the
second thread cannot get a message onto that server to overwrite the buffer --
it parks in `rpc_begin` instead.

So `rpc` returns a guard and the reply is valid only until it is released:

    e, g := rpc(c.server, &request, &reply)
    defer rpc_end(g)

Every caller does this, including the ones whose replies borrow nothing. There
is therefore no second entry point to reach for, and no judgement to get wrong.

## What is deliberately not locked

A `Chan` is not internally synchronised for `chan_open`, `chan_read` or
`chan_write`. Whoever holds a reference owns the chan, exactly like a file
descriptor. Two threads that do I/O through one handle have an arrangement of
their own to make. The chans this package *does* share are the `mounted_over`
chain and the members in a mount table, and nothing ever writes those. A walk
from a member allocates its own fid rather than moves the member's.
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
