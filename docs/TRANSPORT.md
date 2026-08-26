# The asynchronous 9P transport, and Tflush

`kernel/mnt/` — `mnt.odin`, `serve.odin`

Plan 9's `devmnt` — the client half of a mounted connection — plus the server
loop lib9p provides on the other side. Both halves are in one package because
both halves of `Tflush` are one mechanism, and splitting them would mean
describing the ordering rule twice.

```
client thread ──▶ [ tag pool ] ──▶ work queue ──▶ worker ──▶ handler
      ▲                                                        │
      └──────────────── reply, by tag ─────────────────────────┘
```

## Tflush, and the transport underneath it

`kernel/mnt` is Milestone 9. It is Plan 9's `devmnt` — the client half of a
mounted connection — plus the server loop lib9p provides on the other side,
and both halves are in one package because both halves of `Tflush` are one
mechanism.

```
client thread ──▶ [ tag pool ] ──▶ work queue ──▶ worker ──▶ handler
      ▲                                                        │
      └──────────────── reply, by tag ─────────────────────────┘
```

**The thing `Tflush` was waiting for was never the protocol.** The message and
its codec have been in `sys/vectra9` since Milestone 3. What was missing was a
transport that can leave a request *pending*: `vectra9.In_Process` runs the
handler on the caller's own stack and returns, so a client behind it has
nothing outstanding to flush and no way to send the flush if it did. That needs
threads to leave a request pending on, and a way to park and wake them — which
is why this milestone is exactly two milestones after the scheduler and one
after the sleep queue.

**The tag is the pool slot.** A `Tflush` names a request by tag, so the server
must be able to find one by tag, so the pool *is* the tag space. A tag that is
not an index into it names no request — which the protocol requires an answer
for rather than an error. The session's own `alloc_tag` counter goes unused
here, and that is the honest arrangement rather than a layering slip: tags have
to be unique among the requests actually in flight, so they belong to whoever
tracks those.

**Each request's flush slot is preallocated above it.** Slot `i + MAX_REQUESTS`
belongs to slot `i`. That is not a micro-optimisation, it is the only thing
between this design and a deadlock reachable by a client doing nothing wrong: a
client whose request is stuck has to be able to send `Tflush`, and if the flush
competed for an ordinary slot then a full pool of stuck requests would leave
nobody able to unstick anything. The self-test fills the pool exactly and
flushes every slot in it; the negative control that makes the flush queue like
everything else deadlocks the boot.

**Rflush is written by whoever finishes the original, not by the worker that
received the Tflush.** The rule is that Rflush comes *after* the flushed
request's fate is decided, and the obvious way to honour it — mark the request,
prod the server, then wait — parks the worker that is holding the flush. A pool
of `n` workers is then emptied by `n` flushes of requests that are themselves
waiting. So the wait is turned inside out: the `Tflush` records itself as the
original's `partner` and returns, and the code that finishes the original
writes the `Rflush` on its way out. The ordering stops being a wait and becomes
the fact that there is no other code path that writes it.

**A server may refuse to abandon the work, and that is legal.** `Conn.abort` is
optional; a connection without one still obeys the protocol, it simply makes
`Rflush` wait for the request to finish on its own. Both kinds are in the
self-test and the stubborn one is what the test is built around — a server that
always aborts makes "after the fate is decided" and "immediately" the same
instant, so an implementation that sent `Rflush` first would pass. Against a
stubborn server the boot thread holds the work open for forty ticks, watches
the client stay parked, and only then lets it finish. The client then gets a
real answer to the request it asked to have cancelled, which is the case the
protocol obliges a client to tolerate and the one nobody remembers to test.

The same rule is checked from the other end: `Stats.unsettled` is incremented
by the *client* whenever an `Rflush` arrives while its request is still
running, and the self-test asserts it is zero.

**Handlers now receive their tag.** `vectra9.Handler` grew one field, and it
reads as redundant for exactly as long as a transport can only have one request
in flight. A server that implements `Tflush` has to be able to say which of its
in-flight requests an `oldtag` refers to, and a handler that cannot name its own
request cannot take part in that.

**The worker pool has to be bigger than the number of requests that can block
at once** — a worker inside a stuck handler is a worker not serving the
`Tflush` that would unstick it. Plan 9 avoids the question with a thread per
request; this counts them instead, and both `serve_start` and the self-test say
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

The last is the same shape as `kernel/vfs`'s two uncaught races and for the same
reason. Nothing marks the slot between `take` returning it and a worker picking
it up, so two clients can be handed the same one — but only if a timer lands in
that window, and eight client threads that each run for a few microseconds do
not reliably produce one. It is a real bug and only a second CPU makes it easy
to find.

**What `kernel/vfs` still cannot do with this.** A reply that borrows the
server's storage — `Rread.data` into a node's `.rodata`, `Rreaddir.data` into
the server's `dirbuf` — was safe because the session lock spanned the whole
exchange. With several requests in flight it is not, and *the borrow rule turns
out to be a property of the transport rather than of the protocol*. A single-
worker `Conn` still honours it, which is what the transparency check uses:
`static_handler`, unmodified, behind a queue and a thread, answering `Tattach`
and `Twalk` exactly as it does behind `In_Process`. Anything more needs a
payload buffer per slot, and that is the next step rather than this one.

## Decisions, and what would reverse them

- **The tag space belongs to whatever tracks the requests in flight.**
  `kernel/mnt` indexes its pool by tag and hands out slot indices, because a
  `Tflush` names a request by tag and a tag that cannot be looked up is a
  request that cannot be flushed. `Session.next_tag` is then unused on that
  transport. The alternative — a session-wide counter and a map from tag to
  slot — buys nothing but a data structure, since the pool is small by design
  and a bounded pool is what stops a client exhausting the server.
- **A request's `Tflush` slot is reserved, not allocated.** A client whose
  request is stuck must be able to flush it, so the flush cannot be allowed to
  queue for the resource the stuck requests are holding. Reversing this makes a
  deadlock reachable through a legal sequence of legal messages, which the
  negative control demonstrates by hanging the boot.
- **`Rflush` is written by the code that finishes the flushed request.** The
  protocol's one ordering rule stops being something to remember and becomes
  the fact that no other code path writes it. The alternative — the flush's
  worker waits for the original — is correct and parks a worker, and `n` such
  flushes empty a pool of `n` workers.
- **`vectra9.Handler` takes the tag it is answering.** Redundant on a transport
  that can only have one request outstanding, and load-bearing on any that
  cannot: a server implementing `Tflush` must be able to say which of its
  in-flight requests an `oldtag` names.

## Known warts

- **The two transports in `sys/vectra9` are synchronous, and `kernel/vfs` uses
  one of them.** `In_Process` and `Encoded_Loopback` both run the handler on
  the caller's own stack, so a client behind either can never have two requests
  outstanding. `kernel/mnt` is the asynchronous one and it lives in the kernel
  because it needs threads; what keeps `kernel/vfs` on the synchronous side is
  the borrow rule, not the interface. See `docs/HANDOFF.md` section 6.
- **A reply's payload has no owner on an asynchronous transport.** `Rread.data`
  points into the server's storage and is valid until that server's next
  message, which was a workable rule while the session lock spanned the whole
  exchange. It is not one when eight exchanges are in flight. A `Conn` with one
  worker still honours it; anything more needs the payload copied into the
  request's own slot, and nothing does that yet.

## See also

- `docs/VECTRA9.md` section 7.3 — the design this implements, and Plan 9's.
- `docs/SYNC.md` — `Rendez` and `sleep_for`, which every wait here is.
- `docs/NAMESPACE.md` — the client that cannot use this yet, and why.
