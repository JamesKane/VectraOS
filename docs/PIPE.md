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

## The counted release

The pin was a deliberate leak for two milestones, measured to the object —
seven — and it is a lifetime now. `vfs.Server` counts every live chan that
names it, and carries `pins` for the two stakes that are not chans. The
`/srv` name's stake is taken at the build, and `unpost` releases it when
the name goes. A mount's stake is `server_for`'s caller's, held until its
attach owns chans. When both counts are zero, `wire_release` runs on
whichever thread dropped the last piece. The last mount and the name are
both gone, which is the only sentence that means nobody can ever reach the
connection again.

**The release is a hang-up through the front door.** It closes the pinned
chan, the posted end clunks, and both flows end. The far process's next
read answers zero bytes, and `libuser.serve` returns `.Hangup`. A healthy
server ends without a note — the first server Vectra stops by releasing it.
The wire's reader sees the same EOF, and `wire_join` collects it. All seven
objects go back: the arena, the `Wire`, the `Server`, the `Wire_End`, the
chan reference, and the pipe's two rings on the final close.

**Closing an end now hands EOF to that end's own readers**, and the first
boot of the release is what demanded it. `read` answered EOF only when the
*peer* closed. A wire reader parked on the end being clunked therefore
parked for ever, and the release hung the machine behind it. `close_end`
marks the closing end's own flow closed too. Bytes already in the ring
still drain first — EOF stays something a reader reaches.

**And the slot stays until the reader has been joined.** The rings and the
slot go back on the last close, and when the far process is already gone
the last close is the release's own. That close wakes the reader, and the
reader learns why only when it next runs, by re-reading the flow's flags.
Zeroing the slot in between wiped those flags, so a reader that ran late
parked again on a pipe that no longer existed, with `wire_join` parked
behind it for ever — one boot in forty, at the draw server's teardown. The
wire's pin, `server9`, therefore outlives the close: `close_end` leaves a
pinned slot standing, and `wire_release` reclaims it through `unpin` after
the join, when nothing parked is left to wake.

One edge is accepted and named: two `/srv` names can post one chan, and the
connection carries one name-stake. The first removal spends it, so the
second name can outlive the connection, and a mount of it rebuilds the wire
with a fresh handshake.

### The release's controls

Four mutations, one at a time, each observed on a real boot:

| Mutation | Result |
|---|---|
| a removal keeps the name's stake | 12 checks, first `and everything the wire pinned comes back, to the object` |
| a mount keeps its caller stake | the same 12, from the same first check |
| `chan_close` never tells the server a chan left | the same again — three ways to hold a stake, one sentence when any is held for ever |
| the release skips `server_release_confirm` | **not caught** — the revival needs a mount to land between the fire decision and the release's lock, and a single-core boot never schedules one there. The window is closed by the confirm's reasoning, the same family as the voluntary-switch rule in `docs/TESTING.md` |

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

## The three parks, reached and closed

`docs/HANDOFF.md` carried three parks with no bound in the posted end's
teardown, found by review and never reproduced. Each wanted a self-test that
reached it before a fix. `kernel/verify_wire.odin`'s posted scenes are those
tests. A pipe's far side is a scripted kernel thread. The end is posted
under a `/srv` name by `srv.post_chan`, and every wait runs on a watched
thread with a bound.

**The removal.** A name removed after its last mount fires the connection's
release on the removing thread, and that thread still held the entry's own
chan. The release's hang-up
closes the pinned chan, and that close is the last one on the posted end
only if the remover's reference is gone.
It was not, so the end stayed open, the wire's reader stayed parked on it,
and `wire_join` parked for ever holding `Pipe_Table.build`. The first run of
the scene stopped the boot in the user tests, behind that lock, which is the
review's prediction. `unpost` hands the server back now, the
remover closes its chan, and only then drops the stake.

**The deaf side.** A far side that never reads times the handshake out, and
the flush that follows waited for `Rflush` with no bound. `wire_flush` gives
it `FLUSH_TICKS` and then poisons the wire, which settles every slot. The
mount comes back with `ENXIO`, which the doc always claimed and `srv.mount`
now says itself. The pipe device behind an unwired end answered `ENOENT`,
and a caller could not tell a missing service from a missing file.

**The dialect.** A far side that answers the wrong version has the posted
end closed under the chans that still hold it. The review feared the reclaim
could zero a slot the posting side was parked on, and the scene reaches that
path and finds no park. Lookups are by id, so a chan naming a reclaimed slot
finds nothing rather than a stranger. The reclaim waits for the far end's
own close.

A second mount of the name after the failure is refused again rather than
parked. That one was a review false alarm, and the scene is what says so.

| Mutation | Result |
|---|---|
| the stake drops before the remover's close | 2 checks, first `and the removal comes back, which fires the connection's release` |
| the flush waits with no bound | 2 checks, first `and comes back inside the handshake's deadline and the flush's` |
| a pipe end with no wire falls through to its device | 3 checks, first `with /srv's sentence for a service that is not there` |

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
- **A pipe wait ends three ways now.** Bytes, a closed far end, or a note:
  the flows wait with `sync.sleep_noted`, so a process parked on a pipe is a
  process a note can reach. What remains true is that nothing here has a
  deadline. A wait that should give up on time is the caller's loop to write.
  The wire's flush is how the kernel's own clients write it.

## See also

- `docs/TRANSPORT.md` — the wire: framing, tags, the flush, and poisoning.
- `docs/SRV.md` — posting a descriptor, and what a posted chan is.
- `docs/USER.md` — `sys_pipe`, and `/bin/niner`, the program that serves one.
