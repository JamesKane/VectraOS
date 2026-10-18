# D103. A file's data goes on its channel's ring: clients attach one when they move bytes in bulk (2026-10-18, decided; extends D67, D93, D94)

D67 gave Node an SQ/CQ ring pair for bulk reads and writes, and NodeTree
serves it for every file it holds; only net's streams use it (D93, D94).
Every other byte of file data moves as Node messages of at most 32 KiB
(`maxIO`) on the file's channel, a call and a reply each: `cp`, `cat`
and `man`, FDIO (so every tier-1 program's `read` and `write`),
`readAll`, the 9P export reading the node's files and the import serving
them, and fs(4) reading and writing its disk through ramdisk(4).
Measured under KVM (roadmap, "The link's throughput"): a copy between
two of the node's own memory files runs at about 100 MB/s, some 150 µs
for each 32 KiB read and write, of which copying the bytes is a few; the
cpu link's 32 MiB copy at about 65 MB/s is bound by the same, not by the
network. A board's NVMe disk would be too, under Taisce (V4).

The mechanism exists; what is missing is its use. So this decision adds
no ring and no wire format (D6, D43): it says who attaches the ring,
when, and what serves it.

- **The client attaches, lazily, through `NodeFile`.** A new client
  type in system/node (`NodeFile`, over an opened `NodeClient`) is what
  reads and writes a file's data: the commands, FDIO, `readAll`, the
  9P export and fs(4)'s device all go through it. Its first read or
  write is a message, as now. A second full-size one in the same
  direction (`maxIO` asked for and moved: the caller is moving bulk)
  attaches a ring (D67's `attach`) to the channel, and every read and
  write after goes through it, if the file's length covers the bytes
  moved so far: a stream (a pipe, `cons`, a conversation's `data`)
  reports no length, and stays on messages, which take what there is in
  the order asked. A small or one-off read never pays for a
  ring: `cat /svc/*/status` stays one message a file.
- **Sizes.** The client's ring: 16 entries, a 2 MiB data area, entries up
  to 128 KiB each, four times `maxIO`; the client splits a larger
  request. Fixed for now, and named constants in one place.
- **Reads go ahead, writes go behind.** On a file whose length the
  client knows (its stat), sequential reads keep up to the ring's
  entries asked for ahead of the reader (the import's read-ahead,
  where the ring makes it cheap). Writes are offered without waiting for
  their completions (`NodeBulkChannel.offer`); an error is reported at
  the next write, or by `NodeFile.finish`, which waits for all of them.
  Callers that write (cp, FDIO's `close` and `fsync`, the export's
  clunk, fs(4)'s commit) call `finish`, so no error is lost. A write or
  wstat at another offset, a truncate or a read of what is being written
  first waits for the writes behind (no reordering a reader can see).
- **A server that can't attach says so.** `attach` answering
  `unsupported` (or anything else) leaves the file on messages for good,
  silently: a client never fails for want of a ring. So every server
  keeps working as it is, and gains speed by serving `attach`.
- **The servers that carry file data serve it:** NodeTree (done, D67;
  its memory files copy straight between their VMO and the data area,
  with no array between), fs(4)'s sessions (Taisce's reads and writes,
  up to an entry's size), ramdisk(4) (already a NodeTree), and the 9P
  import, whose ring entries become 9P reads and writes, several in
  flight on the link (its read-ahead threads, now the ring's). A
  service's own sessions serve it through `NodeRing`: each entry started
  on the dispatcher's thread and answered when done, out of order (D93).
  The import's writes go one after another in their order (a server may
  refuse a write past a file's end, which one gone ahead would be); its
  reads all at once.
- **The export stays on messages** (amended at step 2): a 9P client's
  reads arrive together and out of order, which reading ahead would only
  drop, and each Twrite must say what it wrote, which writing behind
  can't. It isn't on the cpu link either (the dev machine serves its own
  files there). Node-to-node links (V7) measure it again.
- **A stream's bulk reader is on the ring too:** 9gate's `ByteStream.node`
  (a TCP conversation's `data`, the cpu link's transport) reads with
  `takeMany`, a read waiting in each entry; on messages it waited a round
  trip through net for each 32 KiB, which was the link's limit once the
  import was on its ring.
- **Through mounts.** A walk into a mounted node forwards the rest of
  its batch, the open with it, so the channel a client opens is the
  mounted service's own (NodeTree's `.remote`, the launcher's /svc
  forwarders, D100), and `attach` on it reaches the server that holds
  the file. Nothing in between needs to forward it.
- **Streams and text leaves stay as they are.** A stream's reader
  attaches when it moves many records (net's), as now; a text leaf is
  read whole and small, and never earns a ring.
- **A budget, with its check.** `node.file_copy`: 64 MiB copied between
  two memory files of one NodeTree through `NodeFile`, in launch-test
  (the services boot, which `vx bench` runs), in nanoseconds; target 64
  ms (1 GB/s), limit 256 ms (250 MB/s), judged by `vx bench`. And the cpu link's 100 MB/s, so far
  measured by hand, gets its running check: boot-cpu reports a 32 MiB
  copy from `/mnt/term` as `remote.copy`, advisory there (TCG), judged
  under KVM by `vx bench` once it boots a cpu node.

**Order.** NodeFile with the attach rule and NodeTree's copy without an
array, then cp, `readAll` and FDIO on it, with `node.file_copy`; then
the import and export, with `remote.copy`; then fs(4) and its device. Each step is measured
against the one before, under KVM.

**Checks.** NodeTests: a NodeFile's first read is a message and its
second full one attaches; a server that refuses keeps it on messages; a
write's error comes back at the next write or at finish; a read after
writes sees them; reads ahead stop at the file's end. The commands',
FDIO's and the gate's tests run as they do over both paths.

Rejected: raising `maxIO` (every message, batch and copy would grow,
and a 150 µs message cost scales with its bytes only in part; it would
also be a wire format change, D6). Rejected: `cp` mapping the source's
memory (`memory`): it works for memory files only, not fs(4) or 9P,
and is a second way to read a file. Rejected: attaching at every open
(a ring a file costs a VMO and two counters, and most opens read a
little once). Rejected: a new bulk protocol for the 9P link (9P's own
reads are its bulk path; the import pipelines them).
