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

`kernel/vfs/lock.odin` is the whole discipline in one file. Five locks, and they
divide into two kinds with opposite rules:

| Lock | Guards | Held across a 9P message? |
|---|---|---|
| `Namespace.lock` | `root`, the mount table, `refs` | spinlock — **never** |
| `object_lock` (global) | `Chan.refs`, `Mount_Point.refs`, `Mount_Point.members` | spinlock — **never** |
| `Server.lock` | the session: fid and tag counters, one message in flight, a borrowed reply's lifetime | **mutex — always** |
| `Static_Tree.lock` | one server's own fid table and directory buffer | spinlock (server side) |
| `device_lock` (global) | the `#name` table | spinlock — never |

**The session lock has to be held across the message. The bookkeeping locks must
never be.** That is not a style preference. `Rread.data` and `Rreaddir.data`
point into the server's own storage. That storage is the static server's
`dirbuf`, or a node's string in `.rodata`.

`valid until the server's next message` used to be safe, because nothing could
interrupt the caller between the reply and the copy. Preemption ended that. So
`rpc` returns a guard, and the reply is only valid until it is released:

```odin
e, g := rpc(c.server, &request, &reply)
defer rpc_end(g)
```

Every caller takes the guard, including the ones whose replies borrow nothing.
There is therefore no second entry point to reach for, and no judgement about
which replies borrow.

The same lock is what makes a fid mean something. `alloc_fid` is a plain
increment. Two threads that both read the counter before either writes it both
walk to `newfid`.

The other direction is enforced rather than documented. A `sync.Spinlock` *is*
the interrupt flag. A bookkeeping lock held while the session is asked for
therefore means a park with interrupts masked, and that is a machine that stops.
`rpc` refuses with `EDEADLK` if `sync.can_sleep()` is false.

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
whole union search. It can do that, because its locks sleep. Vectra's cannot.
The counter replaces the lock. A search that finds nothing counts only if the
list is the same one it started on.

## Known gaps

- **`Mount_Point.generation` exists because a read lock could not be held across
  a union search.** Plan 9 holds one, because its locks sleep. Vectra's can now
  too. The retry loop in `walk1_ex` could become a read lock, and the
  generation counter could go. See `docs/SYNC.md` for what is missing.
- **No `Tflush` here.** It exists in `docs/TRANSPORT.md`, over a transport that
  can have several requests in flight. This package still speaks
  `vectra9.In_Process`, and the borrow rule above is why. A reply's payload used
  to live in the server's own storage, which only a session lock spanning the
  whole exchange made safe.

  That is no longer the arrangement. A request slot in `kernel/mnt` owns a
  buffer, and the handler builds its payload there. `Server.lock` can therefore
  go back to meaning `the fid counter is mine`. `rpc` grows a buffer parameter,
  and
  `chan.odin` and `readdir.odin` pass the one they were going to copy into
  anyway. See `docs/HANDOFF.md` section 6.
- **No current directory.** `resolve` takes absolute paths and `#name` specs
  only, because a relative path needs a process to be relative to.

## See also

- `docs/VECTRA9.md` — the protocol, and sections 5 and 7 for the namespace design.
- `docs/SYNC.md` — the two lock types, and the checked rule between them.
- `docs/TESTING.md` — how the five-thread concurrency run is kept honest.
