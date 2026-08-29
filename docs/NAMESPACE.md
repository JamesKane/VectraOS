# The namespace

`kernel/vfs/` — `vfs.odin`, `chan.odin`, `mount.odin`, `namespace.odin`,
`walk.odin`, `readdir.odin`, `static.odin`, `root.odin`, `lock.odin`

Everything above this package names files with paths. Everything below it names
them with fids. `kernel/vfs` is the translation, and the only place in the
kernel that knows a path can cross from one server to another halfway through.

Three types carry the whole idea:

    Server      a handler plus the session a client talks to it through
    Chan        a handle on a file *in a namespace*, as opposed to in a session
    Namespace   a private mapping from names to files -- root plus a mount table

There is no global tree. `resolve` starts at a namespace's root and asks each
server in turn. It consults the mount table between every element. Two processes
can therefore each have a `/dev/mouse`, and the two can be different files.
**The design is `docs/VECTRA9.md` section 5. This document is what the
implementation learned that the design did not say.**

## Locking the namespace

`kernel/vfs/lock.odin` is the whole discipline in one file. Four locks, and
every one of them is a spinlock held for a handful of instructions:

| Lock | Guards | Held across a 9P message? |
|---|---|---|
| `Namespace.lock` | `root`, the mount table, `refs` | **never** |
| `object_lock` (global) | `Chan.refs`, `Mount_Point.refs`, `Mount_Point.members` | **never** |
| `Static_Tree.lock` | one server's own fid table | never (server side) |
| `device_lock` (global) | the `#name` table | never |

**There used to be a fifth, and losing it is the change worth reading about.**
`Server.lock` was a `sync.Mutex` held across the whole of every message, and it
was load-bearing twice over.

It made `one request in flight per session` true, which is what made a borrowed
reply safe. `Rread.data` and `Rreaddir.data` pointed into the server's own
storage: the static server's `dirbuf`, or a node's string in `.rodata`. `Valid
until the server's next message` only means anything while no other thread can
send that next message. So `rpc` returned a guard, and the reply was valid until
it was released.

And it made a fid mean something. `alloc_fid` was a plain increment. Two threads
that both read the counter before either wrote it both walk to `newfid`, and one
then silently holds the other's file.

Both reasons are gone, and nothing was loosened to remove either one:

- **A reply no longer borrows the server.** A request slot in `kernel/mnt` owns
  a payload buffer, and the handler is handed it. `rpc` passes the *caller's*
  storage down, so a reply points at memory the caller already owns and stays
  good for as long as that does. `docs/TRANSPORT.md` has the mechanism.
- **`alloc_fid` is an atomic increment.** The number is this thread's the moment
  it comes back, so nothing has to be held around the message that carries it.

What is left of `rpc` is the rule that was always the important one, and it is
enforced rather than documented. A `sync.Spinlock` *is* the interrupt flag. A
message can park the calling thread, and on `kernel/mnt` it always does until a
worker answers. A park with interrupts masked is a machine that stops. `rpc`
refuses with `EDEADLK` if `sync.can_sleep()` is false.

The rule did not change. Its reason got better. It used to be about this
package's own mutex, and it is now about the transport, which holds whether or
not this package locks anything.

**A server now has to protect itself.** Nothing serialises two threads inside
one handler any more, and `Static_Tree.lock` is what makes that safe for the one
server in the tree. A server protects itself rather than trusts each client to
serialise first, which was always the stated position here. It stopped being a
redundancy the day the session lock went.

## One namespace, two transports

A `Server` sits on one of two transports and nothing above it knows which:

| | Handler runs on | Requests in flight | A caller may give up |
|---|---|---|---|
| `vectra9.In_Process` | the caller's own stack | one | no |
| `kernel/mnt` | a worker thread | up to `MAX_REQUESTS` | yes, by `Tflush` |

`server_init` gives a server the first. `server_start` moves it to the second
and `server_stop` moves it back. Both are reversible on a live server. A `Chan`
taken before a move still names its file after it, because the fid space carries
over while the msize does not.

The root device stays synchronous, and that is a decision rather than an
oversight. It is a tree in kernel memory that answers without waiting, so a
thread hop per read would be pure cost. `init_namespace` also runs before the
scheduler exists, and workers are threads.

What the move buys is `chan_read_for`, a read with a deadline. It sends `Tflush`
when the deadline passes, and waits for `Rflush` before it lets the fid go. That
is the only safe way to walk away from a request. It is also what a read from a
device that may never answer needs. `chan_interruptible` reports whether a given
chan has it, before a caller waits rather than after.

That check used to be a counter `vfs` kept for itself. It is now a property of
the CPU that `sync` maintains in `acquire` and `release`. The rule therefore
covers the heap lock
and the scheduler lock as well, and both are equally fatal to hold across a
wait. A negative control that moves one clone inside the namespace lock fails
four checks immediately.

**This work found two bugs that predate threads.** `Chan.union_head` was a bare
pointer to a `Mount_Point`, and an unmount freed it. One thread was enough to
reach the freed pointer, with a directory held open across an `unmount`.

Mount points are reference counted now, and `unmount` dissolves rather than
deletes. The members go. The struct survives until the last chan releases it. A chan that
holds an empty mount point behaves like one that was never in a union.

The second is `Mount_Point.generation`, and it is the one the self-test found on
its own. Remove a member from the *front* of a union, and every later member
shifts down. A walker that resumes at index 1 then skips the entry that used to
be there, so a file that never moved comes back `ENOENT`.

Plan 9 does not have this problem, because it read-locks the mount head for the
whole union search. It can do that, because the lock it holds sleeps. The one
guarding a mount table here is a spinlock, and a spinlock held across a search
is the interrupt flag held across a search.

The counter replaces the lock. A search that finds nothing counts only if the
list is the same one it started on.

## A server that can come down

Every kernel server outlives every chan on it, so a `^Server` in a `Chan`
was a borrow that could not dangle. A posted pipe's server broke that: it is
built at mount time and deserves to die when nothing can reach it. So
`Server` carries a count now, and `chan_alloc` and `chan_close` keep it.
Every live chan is counted in and counted out, under the same lock as the
chan references themselves.

`pins` beside it holds the stakes that are not chans, and `release` is the
hook that runs when both reach zero. For every kernel server the hook is nil
and the counts are bookkeeping nobody reads. For a wired pipe they are the
lifetime, and `docs/PIPE.md` owns what the release does.
`server_release_confirm` is the second look that keeps the fire decision
safe against a mount that revives the server in between.

The decrement comes after the Tclunk goes out, because the clunk still uses
the server's session. The hook runs outside the lock, because a release
tears a connection down, and that parks.

## What the lock cost, measured

`kernel/verify_vfs.odin` runs five threads against two servers for a fixed
thousand ticks, so what it reports is throughput at a constant amount of
preemption. The same run, before and after:

    with Server.lock       13,087 namespace operations,  2,510 rebinds
    without it             60,410 namespace operations,  7,455 rebinds

Both numbers are from the optimised build, which is the one where the lock was
the limit rather than the code under it. Nothing else changed between them.

The point is not the ratio. A lock held across every message is a lock every
thread in the system queues behind. That queue was most of what the old run
measured.

## What the negative controls say

`kernel/verify_vfs_mnt.odin` is the namespace over a transport with workers, and
`kernel/verify_vfs.odin` is the five-thread run over the synchronous one. Six
mutations against the move, four caught:

| Mutation | Result |
|---|---|
| `server_start` drops the fid counter on the way over | caught — six checks, the readers first |
| `take_payload` never copies | caught — four here, one in the concurrency run |
| `chan_read_for` ignores its deadline | caught — `a read that outlives its deadline comes back at all` |
| `union_pass` leaves a member cookie unstamped | caught — by the union worker |
| remove `Static_Tree.lock` | **not caught** |
| remove `rpc`'s `can_sleep` refusal | **not caught**, and correctly so |

**The last row is the one worth explaining, because it looks alarming and is
not.** Removing the refusal changes nothing, because no correct caller holds a
spinlock across a message and there is therefore nothing to refuse. The control
that tests that rule is the opposite one: move a `chan_clone` inside
`object_lock` and watch `EDEADLK` come back. That fires.

Deleting a guard which only acts on already-broken code falsifies nothing.
Breaking the code it guards is the only thing that does.

**`Static_Tree.lock` used to be catchable and stopped being.** It guarded a fid
table and one shared directory buffer. The buffer moved into the request slot.
What is left under the lock is a slot read and a slot written, a few
instructions apart. That is the same shape as the two windows `verify_vfs.odin`
has never reached, and it wants a second CPU rather than a longer run.

**One of these mutations hung the boot rather than failing**, and that was a
defect in the test rather than a result. `chan_read_for` with its deadline
ignored never returns, and the check ran on the boot thread. It runs on a
watched thread now, so a read that does not come back is a check that fails.
`docs/TESTING.md` has the standing version of that lesson.

## Known gaps

- **`Mount_Point.generation` exists because a read lock could not be held across
  a union search.** Plan 9 holds one, because its locks sleep. Vectra's can now
  too. The retry loop in `walk1_ex` could become a read lock, and the
  generation counter could go. See `docs/SYNC.md` for what is missing.
- **Only a read can be given up on.** `chan_read_for` is the one operation with
  a deadline. A walk, an open or a listing against a server that never answers
  still waits forever. Nothing is missing to fix that, because `rpc_for` takes
  any message. What is missing is somewhere to put the answer to `which of the
  eight walks I just did was the one that hung`. That question belongs to a
  process, and there are none yet.
- **`readdir` over a union is still index-based**, and is still undefined if
  something rebinds the union part-way through. The cookie names a position in
  a list that moved. `walk` no longer has that property, thanks to
  `Mount_Point.generation`.
- **No current directory.** `resolve` takes absolute paths and `#name` specs
  only, because a relative path needs a process to be relative to.

## See also

- `docs/VECTRA9.md` — the protocol, and sections 5 and 7 for the namespace design.
- `docs/SYNC.md` — the two lock types, and the checked rule between them.
- `docs/TESTING.md` — how the five-thread concurrency run is kept honest.
