# D142. A file opened only to read is a fid on its mount's channel, not a channel of its own (2026-10-26, decided)

After D141, small_read (open, read, close of a 64-byte file) was
34–42 µs on the Orange Pi 6 Plus, against 1.9 on Ubuntu and 2.3 on
FreeBSD. The open's reply now brings the bytes, so an iteration is the
open's round trip and a close; but every open still has fs make a
channel, add a server for it to its dispatcher and count the file open,
and every close has the kernel tear the channel down and wake fs to drop
the server (D141's "Next").

Plan 9 keeps an open file as a fid: a number the client picks on the
one connection it already has to the server, which the server maps to
its file; Tclunk lets it go. NFSv4 does the same with its state ids on
one session. node(5) made each node a channel instead (Node.swift's
header: a channel to a node is like a fid), which is what a capability
system wants for a node handed to another process or speaking a
service's protocol, but costs a channel for a file a process just reads.

**The owner's choice (2026-10-26):** fids for what fdio opens only to
read, on a server that keeps them (fs), before any wider change to
node(5), which can come later on the same calls:
- Node version 6 gains `openFid(ops, fid, ahead, clunk)`: `openAhead`
  (D141), the node kept as the client's numbered fid on the channel the
  call came on, with that channel's rights; `fidBatch(fid, ops, open,
  clunk)`: a batch from a fid's node, and with `open`, a channel to it
  (a fid made a channel); `clunk(fids)`. A fid lives until it is
  clunked or its channel closes. fs keeps fids (each a session of its
  own, counted in `status`); NodeTree, the block class and 9gate's
  imports say `unsupported`, and the namespace member remembers it and
  opens channels there.
- Closes go with the next fid request on that member (each request
  carries the fids closed since), not one of their own: no wake of fs
  per close. (The default taken with the scope; the other way, a
  `clunk` per close, costs fs a wake each and frees the file at once.) A closed file stays open in fs until then or until the
  process ends; a removed one keeps its space that long (fcntl(2)'s
  BUGS).
- fdio's read-only opens are fids. A descriptor becomes a channel when
  it needs one: after two full reads (to move bulk on a ring, as
  NodeFileIO attaches) and for fsync. Opens for writing keep their
  channels: their writes go behind on rings, and O_TRUNC's resize
  speaks the fs protocol.
- A fid's calls share its member's channel, one at a time, with the
  member's other calls: fs serves one request at a time anyway.

**Not changed:** the namespace's own calls, walks, listings, creates and
removes (channels already, the member's), and every client that opens a
node to hand on or to speak its protocol. Renumbering fids after a
service restarts: the member's channel is made again and its fids fail
as a closed channel would.

**Measured** (the board, six runs after a warm boot): small_read
31.9–35.0 µs (from 34.1–42.4; one row 65.5); tree_walk 1.66–1.81
µs/entry and read_4k 1.53–1.60 µs unchanged. fs's work per small_read
fell from ~15 system calls (~21 µs in the kernel) to 4 (~7.6 µs); what
is left is user time on both sides (NOTES.md, finding 7).
