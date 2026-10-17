# D98. A ring's doorbell lends its ringer's profile, until the woken side blocks (2026-10-17, proposed)

A thread's intent reaches a server through one path today: `channel_call`
donation (objects.md, ext 2), which lends the caller's profile to the
thread that reads the call until it replies. A counter or an interrupt
lends a fixed deadline profile that its owner stored
(`object_set_profile`, K10c). Rings carry everything else: frames,
audio, input, blocks, the Node SQ/CQ (D67). A request on an SQ is
served at the server's own profile, so a `frame` client waiting on a
`background` server waits for as long as the background share takes.
Principle 11 stops at the first ring.

XNU had the same gap. Turnstiles and importance donation fixed
synchronous Mach IPC, and the asynchronous half (dispatch queues and
kevent workloops) needed QoS overrides of its own later. This decision
closes the asynchronous half here before V5's frame paths depend on
rings. It extends K10c's lending and adds no mechanism or syscall.

- **A doorbell may lend its ringer's profile.** `object_set_profile` on
  a counter with a new option, `CROI_PROFILE_FROM_RINGER` (no profile
  handle), makes each `counter_add` lend the adding thread's effective
  profile, fair or deadline, instead of a stored one. The side being
  woken sets it on its own doorbell, which needs WRITE: a server on its
  SQ's, never a client on its CQ's. The kernel's own rings (the debuglog,
  `CROI_PORT_RING`) lend nothing. The ceiling holds at 91.
- **Lends combine by K3b's rules**: fair weights add; deadline
  utilizations add with the tightest deadline. They are not admitted, as
  `channel_call` donation isn't. Each lend ends when the woken thread
  blocks, as K10c's do, so a server drains its ring at its clients'
  profile and returns to its own when it sleeps again.
- **An awake consumer is lent to as well.** When `counter_add` wakes no
  one, the lend goes to the thread that last took a packet from the port
  the counter is bound to (pinned, as `Processes.pinnedThread` pins), and
  ends when that thread blocks.
- **A producer that outranks its consumer rings once.** While both sides
  are busy, a ring makes no calls, so nothing would lend. The consumer's
  line in the ring's header (offset 140, beside its waiting word) gains
  its rank: one u32 that Ring.swift and `ring.h` derive from the
  thread's own profile (deadline before fair, then a shorter deadline or
  a larger weight). The consumer writes it when it starts to drain. A
  producer whose rank exceeds it rings once and doesn't ring again until
  the consumer next sleeps. Equal or lower ranks ring as they do now, so
  `ring_kicks = 0` holds wherever the two sides' intents agree. This is
  a change to the one ring, not a second format: the header's version
  goes up, and RingCheck checks the new rule on both implementations
  (D43).
- **What a client can do with it:** raise a server to its own profile,
  for as long as the server keeps draining. The time is charged to the
  server, as donated time is today. A server that doesn't want lending
  leaves the option unset.

**Checks and budget.** A new suite in `user/test/swift/` checks the
mechanism: the woken thread's effective profile includes the lend, the
lend ends when it blocks, an awake consumer is lent to, and a producer
whose rank isn't higher doesn't ring. A boot budget,
`ring.inversion_us`, measures how long a highest-priority client's request
takes to complete through a lowest-priority server while fair threads load
every CPU. It is reported from when the change lands, and its limit is set
together with V5's frame budgets, which depend on it. Its `docs/risk.tsv`
rows land with the suite.

**Pages.** When the change lands, object_set_profile(2) and
sys-profile(2) (`Profile.lend`) describe the option, and the ring's page
describes the rank word.

**Proposed placement:** the kernel's side and the ring's rank in V3,
before any V5 frame path uses a ring.

**Open:** whether the rank should come from the thread's effective
profile, which includes what it inherits, rather than its own. User
space can't see that without a call, and a lend chain (client → server →
driver) then crosses each ring by its own kick.

Rejected: an intent field in every slot. The server would choose work by
intent, which puts a scheduler in every server and scheduling into the
wire format. Rejected: a server thread per client, which multiplies
threads by clients and still needs a lend. Rejected: kernel-managed
work queues (GCD's), against principle 20.
