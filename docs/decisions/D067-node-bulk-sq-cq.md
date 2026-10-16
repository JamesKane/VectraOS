# D67. Bulk Node reads and writes: an SQ/CQ ring pair and a data VMO the client makes (2026-10-16, decided)

D18 moves Node's bulk traffic onto rings; a batch's `read` and `write`
stay for small amounts (32 KiB each). Architecture §3 already describes
how large payloads travel: by reference, a request/response service on a
pair of rings, SQ and CQ, with the bytes in a shared data VMO (sDDF's
available and free queues). This is that, for Node.
- **One VMO, made by the client:** an SQ ring at offset 0, a CQ ring after
  it, and a data area, with two doorbell counters (the server's, which the
  client rings, and the client's). The client pays for the memory, since
  the buffers are its own. It hands them to the node its channel is at in
  one call, Node's `attach` (version 2): a struct of handles, which a
  batch can't carry (D54, D64). Architecture §4's "a client opens `…/ring`
  and receives a VMO and a counter" is amended to this.
- **Entries:** an SQ entry is 40 bytes: the operation (read or write), a
  tag, the file offset, the length and the offset in the data area. A CQ
  entry is 16: the tag, a status (0, or a NodeError's code) and the bytes
  moved. The server checks every range against the data area; a
  hostile client breaks only its own ring (the ring marks itself broken).
- **Many in flight, no syscalls while busy:** doorbells ring only when the
  other side has said it sleeps (the one ring's protocol). The server
  drains the SQ on its dispatcher thread, watching its doorbell
  (`IPCDispatcher.watch`), and stops when the CQ is full until the client
  frees space.
- **One ring per channel, gone with it:** when the channel closes, the
  server unwatches its doorbell and unmaps the VMO.
- **NodeTree** serves bulk reads and writes of its files and text leaves,
  each up to the data area's size, through the same code as a batch's.
  A service with its own storage (Taisce, a block device) will serve
  `attach` over that.
- **Rejected:** a byte-stream ring per read or write (D46's mode is for
  stdio and pipes, and has no offsets: random access would need a stream
  per seek), and server-made rings, which a batch couldn't hand back with
  their doorbells in one reply.
