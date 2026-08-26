# The asynchronous 9P transport, and Tflush

`kernel/mnt/` — `mnt.odin`, `serve.odin`

`kernel/mnt` is Milestone 9. It is Plan 9's `devmnt`, the client half of a
mounted connection, plus the server loop that lib9p provides on the other side.
Both halves are in one package, because both halves of `Tflush` are one
mechanism. A split would mean the ordering rule written down twice.

```
client thread ──▶ [ tag pool ] ──▶ work queue ──▶ worker ──▶ handler
      ▲                                                        │
      └──────────────── reply, by tag ─────────────────────────┘
```

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

**What `kernel/vfs` still cannot do with this.** A reply can borrow the server's
storage. `Rread.data` points into a node's `.rodata`, and `Rreaddir.data` points
into the server's `dirbuf`. That was safe because the session lock spanned the
whole exchange. With several requests in flight it is not, and *the borrow rule
is a property of the transport rather than of the protocol*.

A single-worker `Conn` still honours it, which is what the transparency check
uses. `static_handler`, unmodified, sits behind a queue and a thread, and
answers `Tattach` and `Twalk` exactly as it does behind `In_Process`. Anything
more needs a payload buffer per slot, and that is the next step rather than this
one.

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

## Known warts

- **The two transports in `sys/vectra9` are synchronous, and `kernel/vfs` uses
  one of them.** `In_Process` and `Encoded_Loopback` both run the handler on
  the caller's own stack. A client behind either can therefore never have two
  requests outstanding. `kernel/mnt` is the asynchronous one, and it lives in
  the kernel
  because it needs threads. What keeps `kernel/vfs` on the synchronous side is
  the borrow rule, not the interface. See `docs/HANDOFF.md` section 6.
- **A reply's payload has no owner on an asynchronous transport.** `Rread.data`
  points into the server's storage, and is valid until that server's next
  message. That was a workable rule while the session lock spanned the whole
  exchange. It is not one when eight exchanges are in flight. A `Conn` with one
  worker still honours it. Anything more needs the payload copied into the
  request's own slot, and nothing does that yet.

## See also

- `docs/VECTRA9.md` section 7.3 — the design this implements, and Plan 9's.
- `docs/SYNC.md` — `Rendez` and `sleep_for`, which every wait here is.
- `docs/NAMESPACE.md` — the client that cannot use this yet, and why.
