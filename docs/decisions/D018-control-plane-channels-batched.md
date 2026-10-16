# D18. The control plane stays on channels, and is batched (2026-10-15, decided)

The V1 audit (`docs/syscall-audit.md`) asked whether the Node protocol
should move to request and response rings, leaving channels to carry only
handles. It stays on channels:
- **`channel_call` is the latency path.** One syscall per call, a direct
  switch to the waiting server, and the caller's deadline donated to it.
  A ring pair needs two wakeups, about 3–4 µs against `channel_call`'s
  1.45 µs today (budget < 1 µs), and the kernel can't donate a deadline
  to a ring's server.
- **Node replies carry handles** (`walk`, `map`), which need a channel
  anyway.
- **Rings take everything with volume.** A service offers a ring as a
  node (architecture §4), and V2 moves todhchai's bulk Node traffic
  (32 KiB `read`/`write` calls, listing VMOs) onto rings.

**Batching is designed in, not added later** (principle 12: where there
is one, there will be many):
- **A Node message is a batch.** A request carries an array of
  operations, and its reply an array of results in the same order. A
  later operation may name an earlier one's result, as NFSv4's COMPOUND
  does, so walk, stat and open of one path are one call. The batch stops
  at the first failure and returns the results so far. A single
  operation is a batch of one.
- **Hot syscalls take arrays with counts** (audit §3): closing handles,
  binding event sources, ringing doorbells, reading and replying on many
  channels, mapping a program's segments and acknowledging interrupts.
  A server's loop is: drain its port ring, read every ready channel in
  one call, reply to all of them in one call.
- **No generic syscall batch.** A mixed submission queue, as in
  io_uring, would be a second way to make every call and a large attack
  surface. Each call takes an array of its own items instead.
