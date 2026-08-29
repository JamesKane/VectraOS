# `/srv`: services published by name

`kernel/srv/` — `#s` bound at `/srv`.

Everything in `/srv` is a running service that something posted while the
machine was up, and anything that can name it can mount it. That is the step
between *a server the kernel was built with* and *a server somebody started*.

Vectra already had one way to reach a service: `#name`, the device table in
`kernel/vfs/vfs.odin`. `/srv` is not a second copy of it, and the four
differences are the whole reason it exists.

| `#name` | `/srv` |
|---|---|
| fixed at boot, sixteen slots | posted and removed while the machine runs |
| outside every namespace | inside one, so a bind or a fork can hide it |
| invisible | a directory somebody can list |
| permanent | a name that goes when nothing wants it |

**The second is the one that matters most.** `#name` deliberately bypasses the
namespace, because a process with an empty mount table needs some way to name a
console. That makes access to the device table a privilege, and
`docs/VECTRA9.md` section 5.8 says so. `/srv` is an ordinary part of a
namespace. Publishing there is a deliberate act, and a namespace that never
bound `#s` cannot see any of it.

## The phrase that turned out to be stale

`docs/HANDOFF.md` said for four milestones that `/srv` "needs a thread on each
side of a transport and therefore needed the scheduler". That was true when it
was written and it stopped being true two milestones ago.

`kernel/mnt` gave a server worker threads. `kernel/devfs` put four of them
behind `#c`, with an ordinary caller's thread on the other side. A thread has
sat on each side of a transport since then.

So `/srv` today is not about threads at all. It is about **naming and
lifetime**. Which service a name reaches, who may reach it, and what happens to
a mount when the name goes away.

## What a posted service is

Two kinds now, and the difference is who implements the answers.

A kernel post, through `srv.post`, is a `^vfs.Server`: a handler plus the
session a client reaches it through. That type already hides which transport
is underneath. Posting one is therefore the same operation whether the
service is a table in kernel memory or four threads.

A descriptor post — the file-operation kind — is a **connection**: the
`^vfs.Chan` behind the written descriptor, referenced so it outlives the
descriptor and the process both. Which server that connection means is
decided at *mount* time, which is Plan 9's arrangement exactly. `devsrv`
stores the channel, and `devmnt` builds the client from it when somebody
mounts. For a chan on a kernel device, the answer is that device — posting a
descriptor on `/dev/cons` publishes the whole of `#c`. For a chan on a pipe
end, the answer is a `mnt.Wire` over that pipe, with a program answering the
far side. That last case is Milestone 15, and `docs/PIPE.md` owns the glue.

**A kernel `Server` belongs to whoever posted it, and must outlive every
mount of it.** That is the same rule `vfs.register_device` already carries,
for the same reason — a `Chan` holds a `^Server` directly. Removing a name
does not stop a service. A posted *connection* keeps the same promise with a
reference. The entry's chan is referenced at the write and released at the
removal, and a wire built from it holds a reference of its own.

The name is copied rather than borrowed. A kernel caller hands over a string in
`.rodata` and is right. The first caller that is not the kernel would hand over
a message buffer and be wrong. A copy costs 32 bytes a slot and removes the
question.

## Posting is a file operation, in two steps

Plan 9 posts a service by creating a file in `/srv` and writing a file
descriptor number into it. The kernel takes the channel from that descriptor.
Vectra now does the same, and the two steps are worth keeping apart, because
each can fail alone.

**`Tlcreate` reserves a name.** The entry it makes is *pending*: named,
listed, counted, removable -- and not a service. Its read says `pending`, a
mount of it answers ENXIO, and `lookup` answers nil. A pending entry is what
a name looks like between a creator's two calls. It is also what one looks
like for ever, if the creator dies in between. `Tremove` reclaims it either
way.

**`Twrite` of a decimal number completes it.** The number is a descriptor,
and a descriptor is an index into one process's table. So the write is
judged against the process that sent it. `#s` is synchronous, so the handler
runs on the writing thread. `srv.Fd_Resolver` -- registered by
`kernel/user`, the owner of descriptor tables -- answers for whoever is
current.

What it hands back is the chan itself, which `/srv` then references. The chan
rather than the server behind it, because those are different capabilities. A
pipe end's server is only the pipe device, and the service the posting means
is whatever answers the pipe. A caller with no process gets EBADF, because a
number from nowhere names nothing.

**That is the confused deputy again**, settled the way `copy_in` settled it:
the kernel consults the caller's own table and nobody else's. It is also the
one place in `/srv` that leans on the transport being synchronous. The day
`#s` grows workers, the write arrives on a worker's thread and `current()`
answers the wrong question. The resolver hook is where that day's fix goes,
which is a caller identity carried with the message. The comment on
`Fd_Resolver` says so where it will be found.

**A completed entry refuses a second write, with EPERM.** A posted name is a
capability, and other processes may already hold mounts of it. Swapping the
service underneath them would make a mount mean something its holder never
opened.

**Removal is a file operation too**, because it needs no descriptor.
`Tremove` on `/srv/foo` takes the name away, and `srv.remove` is the same
operation from inside the kernel. Both halves of a removal run outside the
table lock, because both may send a message. The entry's chan closes, and
`pipe.unpost` releases the name's stake on a wired connection.

The service does not stop with the name. But when the last mount is also
gone, the stake was the last hold on the wire, and the counted release
brings the connection down. `docs/PIPE.md` owns that design.

What a posting publishes is the *connection*, not the file the descriptor was
open on. A process that opens `/dev/cons` and posts descriptor 3 posts the
whole of `#c`. A mount of the name attaches fresh at the server's root. That
is Plan 9's semantics exactly: the channel is to the server, and the file it
happened to name is not part of the capability. That makes `/srv` the first
tree in Vectra a client may change, and `vfs.chan_remove` is Tremove's first
implementation on either side.

## Mounting

    srv.mount(ns, "/srv/cons", "/mnt/cons")

This is Plan 9's `mount(fd, ...)` with the descriptor taken out of it. There,
the client opens `/srv/foo`, gets a channel, and hands the kernel a descriptor
on it. The kernel never looks the name up again — it uses the channel it was
given.

Here the same two steps happen and the middle one is a kernel call. `path` is
resolved **in the namespace**, so a bind over `/srv`, or a fork that dropped it,
changes what this can reach. Then the qid on the resulting chan says which entry
it landed on, and the entry says which service that is.

For an entry holding a posted connection, this is also where the connection
becomes a server. `mount` asks `pipe.server_for` what the chan is, and a pipe
end answers with a wire. The wire is built once, on the first mount, with a
Tversion handshake the far process must pass under a deadline. Any other chan
falls back to the device behind it. The entry's chan is referenced across
that work, against a removal racing the mount.

**Refusing a path this server does not serve is what keeps that honest.**
Without the check, `mount` would be a second way to name a service that skipped
the namespace. That is the thing `/srv` exists not to be. A path
that resolves somewhere else, and the directory itself, both answer EINVAL.

## Two decisions the self-test had to earn

### A fid binds an id, not a slot

Every other server in this tree binds a fid to an index into a fixed table,
because those tables never change. This one does. A slot is reused the moment a
name is removed. A fid bound to a slot would name whatever took it next, which
is **a capability on a service its holder was never given.**

So each entry carries a monotonic `id`, a fid binds that, and a lookup is a scan
for a live entry carrying it. An entry that went is simply not found, and the
answer is ENOENT rather than somebody else's service.

The self-test holds a handle across a removal, posts a different service into
the freed slot, and checks the old handle still names nothing. With the fid
bound to a slot instead, that check fails and reads back the new occupant's
identity.

`id` is monotonic and therefore finite: two billion posts and it stops. That is
the same limit `vfs.alloc_fid` carries and names, with the same fix — a free
list of ids retires both.

### A listing cookie is an id, not a position

`/srv` is the first directory in Vectra whose contents change. Every other one
is a fixed table where an ordinal names the same file every time.

A name posted or removed between two Treaddir calls moves every position after
it. An ordinal cookie would then mean *resume after position three*, and
position three is a different file than it was. The client skips a name nobody
removed, and never learns that it did.

An id is monotonic and never reused. *Resume after id three* means the same
thing however the table moved underneath, and a removed entry is simply not
found on the way past.

**This is the treatment `docs/NAMESPACE.md` says a union listing could have if
it ever mattered.** Here it matters, so here it is. The union listing still uses
an index, and is still documented as undefined if something rebinds part-way
through.

The self-test paces a listing one entry at a time over six names, and removes
one in the middle. It removes a name the listing already passed. Six names
come back, each exactly once. With an ordinal cookie, a survivor is skipped
and the check says so.

Finding the next id is a scan of the table per entry emitted, which is quadratic
in a table of thirty-two. A directory of any real size wants its entries in a
sorted list. This one does not.

## What a read of `/srv/foo` says

    alpha direct

The `#name` the service is registered under, and whether it has worker threads.

Plan 9 answers an *open* of a posted service with the channel itself, and a read
of it is not a thing a client does. Vectra has no descriptor to hand over, so a
read reports identity instead. An error would have been the other option, and
worse. A file that cannot be read is a file with nothing to say about itself.

Both facts are what a person at a shell wants from `cat /srv/foo`. Neither is
something a client could work out from the namespace. An entry that was
created and never completed reads as `pending`, which is the third thing a
person would want to know.

## Why this server is synchronous

`#c` took four worker threads because a console read has to wait for a key.
Every message `#s` answers is a table lookup. Nothing in it waits, so there is
nothing for a worker to be doing while a caller blocks, and nothing for a
`Tflush` to abandon.

The whole handler therefore runs under one spinlock, the way
`vfs.static_handler` does. `mount` is the one path that does not. It reads the
`^vfs.Server` out under the lock and lets go before it attaches. An attach is a
message, and a message may park the caller.

## `/srv` starts empty

Plan 9's does, and the reason carries over. The kernel is not the thing that
decides which of its own services deserve a public name. Nothing in this boot
needs to mount another kernel service by one.

`#c` is reachable as `/dev/cons` because `devfs.init` binds it there, which is a
mount rather than a publication. If a console should also be `/srv/cons`, the
process that wants it that way is what posts it.

## The self-test, and its controls

`kernel/srv/verify.odin`, run at the end of the boot against the boot namespace
and the real mount at `/srv`. The fixtures are two ordinary `vfs.Static_Tree`
servers, because what is under test is the publishing rather than the service.

Neither fixture is in the device table, and the test checks that first.
`#alpha` names nothing, so the only way to reach either one is the name the test
is about to post.

### The controls

Thirteen mutations, one at a time, each observed on a real boot:

| Mutation | First failure |
|---|---|
| the ordinal cookie every fixed directory uses | `and returned every name that was there when it reached it` |
| a fid binds the slot index instead of the id | `and the old handle still names nothing, rather than whatever took the slot` |
| a duplicate name is allowed | `a second service may not take the same name` |
| mount does not check the chan belongs to this server | `a path that is not a /srv entry is refused` |
| a name is not validated | `a name with a slash is refused` |
| a removed slot keeps its identity | `and returned every name that was there when it reached it` |
| the root may be removed | `and refuses to be removed` |
| removing a name nobody posted reports success | `and a name already gone is not there twice` |
| the table accepts more than it has slots for | `the table fills to exactly its size` |
| `Tlcreate` skips the name validation | `a name with a slash in it is refused` |
| `parse_fd` accepts any bytes as descriptor zero | `a write that is not a decimal number is refused` |
| a completed entry accepts a second write | `a second write is refused -- a posted name is not a thing to swap` |
| `service_at` mounts a pending entry | `a pending name mounts nothing` |
| the posted chan is borrowed rather than referenced | caught in `kernel/user`'s suite -- five failures, first `and the name reads back as a posted pipe`, because the poster's own close freed the chan under the entry |

The last four arrived with posting as a file operation. The third of them
fails in `kernel/user`'s suite rather than this one. Only a process can
complete a posting and then try again, and `/bin/poster` does exactly that.

**The first two are the ones that were worth building the test around**, because
both are the design decisions above rather than ordinary bugs. Each has an
obvious simpler implementation that every other check in the file passes, and
one check apiece that it does not.

### One control came back clean, and it was the mutation that was wrong

`Service` used to carry a `used: bool` beside its id. The control removed the
`used` test from `slot_of`, and every check still passed.

`docs/TESTING.md` says to check that the mutation was the right one before
recording it as uncaught, and it was not. `remove` zeroes the whole `Service`,
so a removed slot carries `id == 0`, and no live service ever does. **Every test
of `used` was already a test of the id.** The mutation took out a redundancy
rather than a check.

So the fix was the field rather than the control. A slot is live exactly when
its id is not zero, and `used` is gone. The control that now means something
leaves the id in place on removal. That one fails two checks.

Two fields that must agree are two fields that can disagree. The one that can
be wrong is the one that is not the identity. That is the same shape as the
`Mount_Point` reference count in `docs/NAMESPACE.md`, found the same way.

### Nothing here is uncaught, and that is not a virtue

Nothing in `/srv` is concurrent. The whole handler is one critical section and
the table is small and flat. There is no window between a load and a store for a
second thread to be in. The uncaught controls elsewhere in this tree are almost
all exactly that shape — see `docs/TESTING.md`.

## What this leaves for next time

- **A service a process implements exists now.** `/bin/niner` posts a pipe
  end and answers 9P off the other, which was this list's first entry for
  two milestones. What it proved out is written up in `docs/PIPE.md` and
  `docs/TRANSPORT.md`, and what it opens is `servers/devfs` — a kernel
  service rebuilt as a program.
- **A caller identity that survives a queue.** The fd resolver answers for
  the *current* thread, which is right only while `#s` is synchronous. See
  `Fd_Resolver`.
- **Permissions that mean something.** An entry reports `0600` because a posted
  service is a capability, and there is nobody yet for it to be private *from*.
- **A free list of ids**, which retires the same limit `vfs.alloc_fid` has.

## See also

- `docs/VECTRA9.md` — section 5.8 on `#name`, and why bypassing the namespace is
  a privilege.
- `docs/NAMESPACE.md` — `bind`, `mount_device`, and the union listing that still
  uses an index.
- `docs/DEVFS.md` — the other device server, and why that one has workers.
- `docs/PIPE.md` — the pipe a posted descriptor can name, and the wire a
  mount builds from it.
- `docs/TESTING.md` — the self-test discipline, and what an uncaught control
  usually means.
