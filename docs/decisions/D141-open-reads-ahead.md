# D141. A read-only open brings the file's first bytes: Node's openAhead, close-to-open consistency (2026-10-26, decided)

D127's small_read (open, read 128 bytes of a 64-byte file, close) was
~52 µs on the Orange Pi 6 Plus, against 1.9 µs on Ubuntu and 2.3 on
FreeBSD. A trace (bench/peers/2026-10-25-vectraos/NOTES.md, finding 7)
showed no one cost to remove: the client and fs take turns, and each of
an iteration's three round trips (the open's batch, the read, the close)
costs both sides kernel and user time and two cross-CPU wakes. An idle
CPU polling instead of halting cut the wakes' cost (`ipc_rtt_cross` 7.4
to 5.6 µs) but not small_read. What is left to cut is round trips.

The read is the one a protocol can fold into the open: NFSv4's COMPOUND
does OPEN and READ in one, and node(5)'s batch already runs a read after
the walk and stat. But a batch's read can't be sent blind with every
open: on a directory it fails the batch, and on a stream, a device or a
generated file (a Plan 9 clone file) it waits, or changes what it reads.
Only the server knows which of its nodes read freely.

**The owner's choice (2026-10-26):** the open brings the bytes, with
NFS's close-to-open consistency for them:
- Node version 5 gains `openAhead(ops, max)`: the batch with `open`, and
  up to `max` bytes of the opened node from its start, given only by a
  server whose reads change nothing and wait for nothing (D54: a new
  method, not a new case of `Op`). fs gives a file's; NodeTree, the
  block class and 9gate's imports give none. A tree forwarding the
  batch to a mounted service answers as `openAhead`, without bytes.
- fdio's read-only opens (no `O_DIRECTORY`) ask for 4096 bytes. The
  reads that reach them take them without a round trip, each byte once;
  a read that finds the file ended within them returns what is left.
- The bytes are the file as it was opened: a first read after another
  process writes it may miss the write, as NFS allows. The process's
  own writes and cuts, through any descriptor, drop every description's
  bytes, so a process always reads what it wrote.

**Measured** (the board, six runs after a warm boot): small_read
34.1–42.4 µs (from 47.8–55.6); tree_walk 1.64–1.83 µs/entry and read_4k
1.43–1.62 µs unchanged.

**Next** (the owner's order): a file opened as a channel of its own costs
fs a channel made, bound and torn down per open, and the client a close
that wakes fs; Plan 9 keeps files as fids on one connection. That is a
redesign of node(5) with its own decision.
