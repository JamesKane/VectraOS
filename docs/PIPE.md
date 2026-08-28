# The pipe: two ends, and no opinion about the bytes

`kernel/pipe/` — `pipe.odin`, `serve9.odin`, `verify.odin`

`kernel/pipe` is Milestone 15's foundation. A pipe is two ends and a byte
ring per direction. Each end reads what the other wrote, in order, with no
message boundary. A read on an empty ring parks, and a write on a full ring
parks. That is the whole contract, on purpose. Framing, tags and flushes
belong to the wire above it, and `docs/TRANSPORT.md` owns that half of the
story.

What earns the pipe its own package is not the ring. It is the two boundaries
it sits on. An end is a *chan*, so it fits in a descriptor table, travels
through `spawn`, and closes by `Tclunk` like every other file. And a posted
end becomes a *service*, which is the step this milestone exists for.

## The ends are chans

`open_end` attaches to the package's own server and hands back an ordinary
`^vfs.Chan`. From there nothing about a pipe is special. `sys_pipe` puts both
ends in the calling process's table, and a child inherits them like any
descriptor. The last close of a chan is what closes its end.

The attach names the end in its aname — `id.end` — which is this package
talking to itself. The server is registered nowhere. It has no `#name` and no
place in a namespace. The only way an end reaches ring 3 is a descriptor the
kernel handed out. That is the same privilege boundary `/srv` posting already
enforces, kept rather than duplicated.

The handler is synchronous, and its reads and writes park on the caller's own
thread. That is legal for the reason `kernel/vfs/lock.odin` states. No vfs
lock is held across a message, so the thread that arrives holds nothing the
rest of the machine waits on. It is also the behaviour a process asks for
when it reads an empty pipe. The park *is* the feature.

## Close, and why each direction carries two flags

The two ends of one direction die differently, so one flag cannot say both:

    closed    the writing end has gone: drain what is buffered, then EOF
    dead      the reading end has gone: a write answers EPIPE

One `close_end` sets one of each, on opposite flows, and wakes everything
parked on the pipe so it can re-read them. When the second end closes and no
wire was built, the rings go back to the heap and the slot clears.

**A fid binds `id * 2 + end`, and the id is the identity.** Slots are reused
and ids are not, which is `kernel/srv`'s rule. A fid bound to a slot would
name whatever took it next.

## A posted end becomes a server, at mount time

`serve9.odin` is the glue, and the design is Plan 9's exactly. Posting in
`/srv` stores the *channel*. The 9P client over it — the wire — is built the
first time somebody mounts the name, which is when `devmnt` builds Plan 9's.
`srv.mount` asks `pipe.server_for` what server a posted chan is. For a pipe
end the answer is a `vfs.Server` whose session sits on a `mnt.Wire` driving
that end.

Three decisions in that glue, each with its reason:

- **The handshake has a deadline.** The far side is a program that may answer
  nothing, so `server_for` speaks Tversion with a bound where
  `vectra9.negotiate` has none. A server that misses it gets the connection
  torn down, and the mount fails with ENXIO. That is `/srv`'s sentence for a
  name whose service is not there. Everything built for the attempt goes back
  to the heap, because `wire_join` can wait for the reader to leave first.
- **One wire per pipe, built once, found by the loser of a race.** Two mounts
  of a fresh name can arrive together. A mutex serialises the build, and the
  second mount finds the first's wire rather than builds a second one over
  the same bytes. A pipe spoken for from one end refuses to be a server from
  the other.
- **A successful build pins the pipe, the wire, and one chan reference.** The
  reference is the load-bearing one. Removing a `/srv` name closes the
  entry's chan. Without the wire's own reference, that close would reach the
  pipe and poison the wire under every mount the removal was not allowed to
  stop. Plan 9's rule — removal ends the name, not the service — costs
  exactly one incref here.

The pin is a deliberate leak, and it is visible rather than absorbed. The pipe
stays in `count`, and the reader thread stays in the scheduler. The user
self-test measures the pin **to the object** — seven, named in
`kernel/user/verify.odin`. It comes back the day a posted service carries a
reference count, which `docs/SRV.md` already lists as the next lifetime step.

## The self-test, and its controls

`kernel/pipe/verify.odin` — 37 checks, in which bytes cross both ways and
wrap the ring. A reader with nothing to read parks, and the write is what
wakes it. The proof watches the helper *not* finish while the pipe is empty,
which is what separates a pipe from a poll. A writer with no room parks, and
the read wakes it. A close is EOF after the drain on one side, EPIPE on the
other, and wakes both. The ends work as chans, and a pipe both ends of which
closed gives its rings back, heap balanced.

Two mutations, run one at a time on a real boot:

| Mutation | Result |
|---|---|
| an empty pipe answers zero rather than parks | caught — `an empty pipe holds the reader`, then the boot hangs |
| the close wakes nobody | caught — `closing the far end wakes it`, then the wire suite hangs the boot |

Both partial catches end in a hang rather than a tidy count, and that is
recorded rather than smoothed over. A parked thread nothing will wake is what
these bugs *are*.

## Known warts

- **One chan per end is a contract, not a check.** `open_end` is kernel-only
  and mints each end once. A second attach of the same end would give two
  chans whose clunks each close the end, and nothing refuses it. The check
  arrives when anything but `sys_pipe` can reach the server.
- **Reclaim trusts its callers about parked threads.** The rings go back to
  the heap only after both ends close. A chan cannot close while a handler
  still runs on it, and that is what makes the free safe. Kernel code that
  reads a pipe directly, as the wire and the self-tests do, has to join its
  readers before the second close. `wire_join` exists for exactly that.
- **A pipe write inside a full ring parks with no deadline.** `chan_read_for`
  has no write twin, so a process writing to a pipe nobody drains parks until
  the reader returns or the far end closes. The note is what ends a process
  stuck that way, and there is no note yet.

## See also

- `docs/TRANSPORT.md` — the wire: framing, tags, the flush, and poisoning.
- `docs/SRV.md` — posting a descriptor, and what a posted chan is.
- `docs/USER.md` — `sys_pipe`, and `/bin/niner`, the program that serves one.
