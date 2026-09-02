/*
What this package locks, and the one rule that is not obvious.

Preemption is what made any of this reachable. Before the scheduler there was
one thread, so a reference count was a plain increment and the mount table was
never half-modified. Both of those stopped being true the day a timer could
land between two instructions.

Two kinds of lock, and the split is Plan 9's. A `sync.Spinlock` guards a
pointer or a count, is held for a handful of instructions, and is **never**
held across a 9P message. A `sync.RW_Lock` sleeps, and is held across
messages on purpose. A union search reads a mount point for the whole of its
search, and a `bind` waits for every search in flight before it writes.

## Who guards what

    Namespace.lock    ns.root, ns.mounts[], ns.mount_count  -- read/write, sleeps
    Mount_Point.lock  Mount_Point.members                    -- read/write, sleeps
    object_lock       Chan.refs, Mount_Point.refs, Namespace.refs
    Static_Tree.lock  one server's own fid table
    device_lock       the `#name` table

Lock order is `Namespace.lock` -> `Mount_Point.lock` -> `object_lock`, which
is `chan.c`'s `pg->ns` -> `Mhead.lock` -> the counts. A read lock on one
mount point is never held while another is taken: `walk1_ex` lets go before
it crosses. Nothing takes a namespace lock while holding an object lock.

## The one rule

**No spinlock in this package may be held across a message.** A
`sync.Spinlock` is the interrupt flag, and a message can park the thread
that sends it. On `kernel/mnt` it always does, until a worker answers. A
thread that leaves the CPU with interrupts masked leaves nothing to turn
them back on. A read/write lock is the opposite case, and is held across a
message *because* it sleeps, which is what `docs/SYNC.md` argues.

`rpc_ready` checks that rather than trusts it, and refuses with `EDEADLK`. The
check is `sync.can_sleep`, which counts every spinlock on the CPU rather than
only this package's. That is wider than the rule needs and correctly so. The
heap lock and the scheduler lock are just as fatal to hold across a wait.

A caller turns the refusal into a failed open or a failed walk, with a name on
it, at the call that broke the rule. That beats a fault months later somewhere
else.

## The lock that used to be here

`Server.lock` was a `sync.Mutex` held across the whole of every message, and it
did two jobs.

It made `one request in flight per session` true. `Rread.data` and
`Rreaddir.data` pointed into the server's own storage, valid until that server
handled its next message. Holding the session is what stopped a second thread
from sending that next message. So `rpc` returned a guard, and the reply died
with it.

And it made `alloc_fid` mean something, because a plain increment two threads
read before either writes hands both of them the same fid.

Both jobs are gone. A request slot in `kernel/mnt` owns a payload buffer, so
`rpc` passes the caller's own storage down and the reply borrows the caller.
`alloc_fid` is an atomic increment. See `docs/NAMESPACE.md` for what that
changed, and `docs/TRANSPORT.md` for the buffer.

**What it leaves behind is a requirement on servers.** Nothing serialises two
threads inside one handler now. A server protects itself, which was always the
stated position here, and `Static_Tree.lock` is what makes that true for the
one server in the tree.

## What object_lock is, and why it is global

Global rather than per-object, and that is a decision about what the state *is*
rather than about contention. A `Chan` is shared across namespaces, because
`ns_fork` with `Copy` increfs every member. A `Mount_Point` outlives the
namespace that created it whenever a chan still names it through `union_head`.
The namespace they were found in cannot guard either one, because a namespace
that no longer exists can still reach them.

A word per chan would be a word per object, guarding a single integer. What
these counts actually want is an atomic increment. When there is a second CPU
that is what they should become, and this lock then covers only `members`.

Worth knowing about this one specifically: `kernel/verify_vfs.odin` cannot make
it fail, and it is not for want of preemption. Removed, it leaves a window two
instructions wide, between a count loaded and stored back. Only a timer can
land inside one, and there are a thousand of those a run whether or not the
layer around it blocks.

A hundred thousand voluntary parks per run did not help, because every one of
them was at a lock boundary and this window is not. It is here because on a
second CPU that window is not a matter of timing luck. `docs/NAMESPACE.md` says
more, including which other locks joined it.

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
