# The asynchronous 9P transport, Tflush, and the payload buffer

`kernel/mnt/` — `mnt.odin`, `serve.odin`, `wire.odin`

`kernel/mnt` is Milestone 9. It is Plan 9's `devmnt`, the client half of a
mounted connection, plus the server loop that lib9p provides on the other side.
Both halves are in one package, because both halves of `Tflush` are one
mechanism. A split would mean the ordering rule written down twice.

```
client thread ──▶ [ tag pool ] ──▶ work queue ──▶ worker ──▶ handler
      ▲              │  buffer                                 │
      │              └───────────────────────────────────────▶ ┘
      └──────────────── reply, by tag ─────────────────────────┘
```

Each slot in that pool owns a payload buffer, and the handler is handed it. That
is the second half of the milestone, and section 3 is why it could not be a copy
taken afterwards.

## Tflush, and the transport underneath it

**The thing `Tflush` was waiting for was never the protocol.** The message and
its codec sat in `sys/vectra9` from Milestone 3 onward. What was missing was a
transport that can leave a request *pending*. `vectra9.In_Process` runs the
handler on the caller's own stack and returns. A client behind it therefore has
nothing outstanding to flush, and no way to send the flush if it did.

A pending request needs a thread to be pending on, and a way to park and wake
that thread. That is why this milestone is exactly two milestones after the
scheduler, and one after the sleep queue.

**The tag is the pool slot.** A `Tflush` names a request by tag. The server must
therefore be able to find one by tag, so the pool *is* the tag space. A tag that
is not an index into it names no request, and the protocol requires an answer
for that rather than an error.

The session's own `alloc_tag` counter goes unused here. That is the honest
arrangement rather than a layering slip. Tags have to be unique among the
requests actually in flight, so they belong to whoever tracks those.

**Each request's flush slot is preallocated above it.** Slot `i + MAX_REQUESTS`
belongs to slot `i`. That is not a micro-optimisation. It is the only thing
between this design and a deadlock that a client reaches while it does nothing
wrong. A client whose request is stuck has to be able to send `Tflush`. If the
flush competed for an ordinary slot, a full pool of stuck requests would leave
nobody able to unstick anything.

The self-test fills the pool exactly and
flushes every slot in it. The negative control that makes the flush queue like
everything else deadlocks the boot.

**Whoever finishes the original writes the Rflush.** The worker that received
the Tflush does not. The rule is that Rflush comes *after* the flushed request's
fate is decided. The obvious way to honour it is to mark the request, prod the
server, then wait. That parks the worker that holds the flush, and `n` such
flushes then empty a pool of `n` workers.

So the wait is turned inside out. The `Tflush` records itself as the original's
`partner` and returns, and the code that finishes the original writes the
`Rflush` as it leaves. The ordering stops being a wait, and becomes the fact
that no other code path writes it.

**A server may refuse to abandon the work, and that is legal.** `Conn.abort` is
optional. A connection without one still obeys the protocol. It simply makes
`Rflush` wait for the request to finish on its own.

Both kinds are in the self-test, and the stubborn one is what the test is built
around. A server that always aborts makes `after the fate is decided` and
`immediately` the same instant, so an implementation that sent `Rflush` first
would pass. Against a stubborn server the boot thread holds the work open for
forty ticks, watches the client stay parked, and only then lets it finish. The
client then gets a real answer to the request it tried to cancel. That is the
case the protocol obliges a client to tolerate, and the one nobody remembers to
test.

The same rule is checked from the other end. The *client* increments
`Stats.unsettled` whenever an `Rflush` arrives while its request is still
running, and the self-test asserts that count is zero.

**Handlers now receive their tag.** `vectra9.Handler` grew one field. It reads
as redundant for exactly as long as a transport can only have one request in
flight. A server that implements `Tflush` has to be able to say which of its
in-flight requests an `oldtag` names. A handler that cannot name its own request
cannot take part in that.

**The worker pool has to outnumber the requests that can block at once.** A
worker inside a stuck handler is a worker that is not serving the `Tflush` that
would unstick it. Plan 9 avoids the question with a thread per
request. This counts them instead, and both `serve_start` and the self-test say
where the number came from.

**34 checks in `kernel/verify_flush.odin`, and five of six mutations caught:**

| Mutation | Result |
|---|---|
| answer `Rflush` on receipt | caught — four failures, first is the ordering check |
| never tell the server a request was flushed | caught — seven failures |
| trust the client's `oldtag` as a pool index | caught — `#PF`, from one crafted message |
| the flush queues for an ordinary slot | caught — deadlocks the boot on a full pool |
| the original never answers the flush waiting on it | caught — hangs the boot |
| a claimed slot is not marked as claimed | **not caught** |

The last is the same shape as `kernel/vfs`'s two uncaught races, and for the
same reason. Nothing marks the slot between the moment `take` returns it and the
moment a worker claims it. Two clients can therefore receive the same slot. That
needs a timer inside that window, and eight client threads that each run for a
few microseconds do not reliably produce one. It is a real bug, and only a
second CPU makes it easy to find.

**What `kernel/vfs` could not do with this** was the thing left over, and the
payload buffer is what settled it. Section 3 is that story.

A single-worker `Conn` needs none of it, which is what the transparency check
uses. `static_handler`, unmodified, sits behind a queue and a thread, and
answers `Tattach` and `Twalk` exactly as it does behind `In_Process`.

## A payload buffer per request slot

A reply can borrow the server's storage. `Rread.data` points into a node's
`.rodata`, and `Rreaddir.data` used to point into the server's one `dirbuf`.
That was safe because the session lock spanned the whole exchange. With several
requests in flight it is not, and *the borrow rule is a property of the
transport rather than of the protocol*.

**The buffer has to arrive before the handler, not after it.** This is the
finding, and it is the one that is easy to get wrong. The obvious repair is for
the worker to copy the payload out of the server's storage the moment the
handler returns. That looks correct and is not. There is no instant, after a
handler returns, at which its borrow is still good — another handler is already
inside the shared storage.

So the direction reverses. Each request slot owns a buffer, `vectra9.Handler`
grew a `buf` parameter, and the handler builds its payload there. Nothing is
shared, so there is nothing to overwrite. A transport with one request in flight
passes nil, and a handler that gets nil answers where it always did.

**The slot outlives the client, which is what makes the buffer safe.** A client
that gives up sends `Tflush` and waits for `Rflush`, and only then is the slot
free. A stubborn server therefore goes on writing into a buffer whose client
walked away — into a slot nothing else may claim. That is the rule `Tflush`
already needed for the tag, and the buffer rides on it for free.

**The buffer size is the msize.** `init` sets `Session.msize` from what one slot
holds, so a client that sizes a read by msize has room for whatever comes back.
A payload that does not fit is then a server bug rather than an overrun.
`call` reports `Short_Buffer` and replaces the reply. The reply that did not fit
is the one still pointing into a slot about to be released.

**A connection with no arena is held to one worker.** `serve_start` refuses the
second. The alternative is a comment. The failure it would guard against
produces correct replies every time until the timing changes, and then hands one
thread's directory listing to another.

**23 checks in `kernel/verify_payload.odin`, and a control that runs on every
boot.** The server under test can be told to answer the old way, out of one
buffer of its own. Eight readers then run against it, and the check is that the
readers corrupt each other:

| Arrangement | Readers that got their own bytes back |
|---|---|
| one buffer for the whole server | 1 of 8 |
| one buffer per request slot | 8 of 8 |

A failure to corrupt is itself a failure. Nobody has to revert the control or
reason about it, which is the difference between this and the mutation tables
elsewhere in these documents.

**Four mutations, three caught:**

| Mutation | Result |
|---|---|
| every slot points at the same buffer | caught — `every one of them got its own bytes back` |
| the payload is never copied out of the slot | caught — four failures |
| `serve_start` allows many workers with no arena | caught — `is then refused a second worker` |
| remove the barrier that overlaps the handlers | **not caught** — the control still spoiled 7 of 8 |

The last one is worth keeping anyway, and its result is the reason. The
tick-long wait inside each handler already overlaps them on this machine, so the
barrier changes nothing today. What it buys is that the control corrupts by
construction rather than by how the scheduler happened to order eight threads. A
control that works by accident stops working the day the accident does.

**The payoff, against a server nothing was changed for.** Four threads list one
directory at once through `vfs.static_handler`. It builds its `Rreaddir` payload
in whatever buffer the transport names. Behind `In_Process` that is still its
own `dirbuf`, and behind this connection it is the slot's. Before the buffer,
that arrangement was the one `serve_start` had to refuse.

The larger payoff is one layer up. `kernel/vfs` sits on this now, so a read from
a path can be given up on. `kernel/verify_vfs_mnt.odin` is that, and
`docs/NAMESPACE.md` is what it cost the namespace to get there -- which was a
lock, and only a lock.

## The wire: the same client, over bytes

`wire.odin` is Milestone 15, and it is the transport the handoff promised: a
9P connection whose far side is a process. `Conn` hands a request to a
handler it can call. A process is a handler nothing in the kernel can call,
so what crosses is bytes, and the wire is the client half of that:

    client thread ──▶ [ tag pool ] ── encode ──▶ io.write ──▶ ...a process
          ▲                                                       │
          └── settle, by tag ── decode ◀── reader thread ◀── io.read

The pool is `Conn`'s pool, kept for the same three reasons. The tag is the
slot, so a `Tflush` names something findable. The upper half is reserved for
the flushes, so a full pool of stuck requests cannot strand the client that
would unstick them. The self-test fills the pool and proves it. And each
request slot owns the buffer its reply lands in. The reader copies a frame
into the slot it is for and decodes it there, so the reply borrows storage
the request already owns.

`Wire_IO` is two calls and a pointer, so this package still does not know
what a pipe is. `kernel/pipe` supplies the calls and owns the glue that
builds a wire from a posted pipe end — see `docs/PIPE.md`.

**What moved, when the server stopped being trusted.** `Conn` makes the
protocol's rules true structurally, because both halves are its code. The
wire's server is a program this kernel did not write, so the rules become
things the wire *verifies*:

  - A frame larger than the msize, or one that will not decode, **poisons the
  connection**. The frame boundary is gone, and nothing knows where the next
  message starts. Every request in flight fails as a transport failure, and
  so does every request after. A mount over a poisoned wire answers EIO,
  which is what a dead server should look like from a namespace. The size
  check runs before the tag is even read. A drain sized by a lie would park
  the reader on bytes that are never coming.
- A reply naming no request in flight is **drained, counted and survived**.
  The frame was whole, so the connection is still usable.
- The byte stream ending is a hangup: the same poisoning, flagged as the
  orderly kind. A server that dies fails its clients at once rather than
  parks them.

**`Tflush` needs no partner mechanism here.** The flush is a frame sent from
its reserved slot, and the *server* orders its answers. What the client does
on `Rflush` is what the protocol always meant. The tag is its own again,
whether or not the original was ever answered. A server that discards a
flushed request is legal, so an unanswered original is not an error. It is
`discards`, a counter, because a count that should sit still is the cheapest
check there is.

**One exception is interned.** Every reply string from a wire borrows the
slot, and `negotiate` passes no buffer. Kernel servers never made it need
one, because their version strings live in `.rodata`. The one string a
handshake accepts is the dialect this tree speaks, so an `Rversion` that
matches becomes the constant and borrows nothing. A mismatch stays borrowed,
and is a refusal before anything reads it twice.

**46 checks in `kernel/verify_wire.odin`**, against a scripted server that
touches the wire exactly as a process does. Frames come off a pipe end and go
back down it, and nothing is shared with the kernel but the bytes. The
handshake crosses under NOTAG, and a payload lands in the caller's own
buffer. Two requests answered in the wrong order come back to the right
callers. A full pool of sat-on requests flushes out through the reserved
slots. A stale reply is dropped, a hangup fails a request in flight, and a
junk frame poisons a second wire on purpose.

**Three mutations, all caught, two of them found as real bugs while the suite
was being built:**

| Mutation | Result |
|---|---|
| the size check runs after the tag routing | caught — the junk-frame check hangs the boot, with the reader parked in a drain sized by the lie |
| the version string is not interned | caught — `Tversion crosses the pipe and back` |
| the flush queues for an ordinary slot | caught — deadlocks the boot on the full-pool check, nothing having sent an illegal message |

The third is `Conn`'s own control, run again here. The wire has its own copy
of the mechanism, and a copy is a thing that can drift.

## Decisions, and what would reverse them

- **The tag space belongs to whatever tracks the requests in flight.**
  `kernel/mnt` indexes its pool by tag and hands out slot indices. A `Tflush`
  names a request by tag, and a tag nothing can look up is a request nothing can
  flush. `Session.next_tag` is then unused on that transport. The
  alternative is a session-wide counter and a map from tag to slot. That buys
  nothing but a data structure. The pool is small by design, and a bounded pool
  is what stops a client from exhausting the server.
- **A request's `Tflush` slot is reserved, not allocated.** A client whose
  request is stuck must be able to flush it. The flush therefore cannot queue
  for the resource the stuck requests hold. A reversal here makes a deadlock
  reachable through a legal sequence of legal messages. The negative control
  demonstrates that, and hangs the boot.
- **The code that finishes the flushed request writes the `Rflush`.** The
  protocol's one ordering rule stops being something to remember, and becomes
  the fact that no other code path writes it. The alternative is that the
  flush's worker waits for the original. That is correct, and it parks a worker,
  and `n` such flushes empty a pool of `n` workers.
- **`vectra9.Handler` takes the tag it is answering.** That is redundant on a
  transport that can only have one request outstanding. It is load-bearing on
  any transport that cannot. A server that implements `Tflush` must be able to
  say which of its in-flight requests an `oldtag` names.
- **`vectra9.Handler` also takes the storage its reply borrows.** Same shape,
  same reason, one milestone later. A copy taken after the handler returns is
  the alternative, and it is wrong rather than slower. Reversing this puts the
  connection back to one worker, which is `In_Process` with extra steps.
- **The payload arena is the caller's, and its size becomes the msize.** `init`
  divides what it is handed among the request slots and says so in
  `Session.msize`. The alternative is a fixed array inside `Conn`, which makes
  every connection pay the largest payload any server might send. A caller knows
  what its own server answers with, and msize is the field that exists to say
  it.

## Known warts

- **The two transports in `sys/vectra9` are synchronous, and a server may sit
  on either.** `In_Process` and `Encoded_Loopback` both run the handler on the
  caller's own stack, so a client behind either can never have two requests
  outstanding. `kernel/mnt` is the asynchronous one, and it lives in the kernel
  because it needs threads.

  `kernel/vfs` uses both. `vfs.server_start` moves a server here and
  `vfs.server_stop` moves it back. The root device stays synchronous, because it
  is a tree in kernel memory that answers without waiting. What used
  to keep the whole namespace on the synchronous side was the borrow rule, and
  that is what the payload buffer removed.
- **A reply *string* still borrows the server's storage.** `Rreadlink.target`
  and `Rgetlock.client_id` are the two, and no server in the tree returns
  either. Neither needs a special case when one does. `deliver` copies whatever
  lies inside the slot and leaves alone whatever does not. A handler that builds
  a symlink target in `buf` is therefore already handled.
- **Only `Tread` has a deadline above this package.** `mnt.call_for` takes any
  message and `vfs.rpc_for` passes any message down, but `vfs.chan_read_for` is
  the one caller. A walk or a listing against a server that never answers still
  waits. See `docs/NAMESPACE.md`.
  - **A wire's server can hold a client for ever without breaking a rule the
  wire checks.** Half a frame and then silence, or a request simply never
  answered, parks the caller with nothing to poison over. The wire punishes a
  *lie*. It cannot punish silence, because silence is what a slow server also
  looks like. The teardown order in `kernel/user/verify.odin` shows the safe
  shape — let the death land, then close — and the note is the real answer.

## See also

- `docs/VECTRA9.md` section 7.3 — the design this implements, and Plan 9's.
- `docs/SYNC.md` — `Rendez` and `sleep_for`, which every wait here is.
- `docs/NAMESPACE.md` — the client that cannot use this yet, and why.
- `docs/PIPE.md` — the bytes under the wire, and the glue that builds one
  from a posted pipe end.
