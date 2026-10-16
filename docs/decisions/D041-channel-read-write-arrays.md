# D41. channel_read and channel_write take arrays (2026-10-15, decided)

The third family of V1's batched forms (`docs/syscall-audit.md` §3,
roadmap V1 item 3). The count stays at 92. channel_call keeps one
channel: its batch is the Node operations in its message (D18, V2).
- **channel_write(items, count)** (81) takes up to 64
  `croi_channel_write_item_t` (ipc.h, 40 bytes: channel, options, bytes,
  handles, their counts; a status out), and **channel_read(items,
  count)** (82) up to 64 `croi_channel_read_item_t` (48 bytes: channel,
  options, buffers, capacities; the actual sizes and a status out). The
  packed capacities and actuals of K7b go: each is a field of its own.
- **Both go on past an item that fails**, as counter_add and
  interrupt_ack do (D40): one client gone (PEER_CLOSED) or one channel
  with nothing to read (SHOULD_WAIT) is a server's ordinary case, and
  shouldn't keep the rest of its replies or reads back. Each item's
  status is written back, and a read item's actual sizes on success and
  on BUFFER_TOO_SMALL; the call returns how many succeeded.
- **A write item's handles are consumed whether it succeeds or not**, as
  Zircon's are. A bad pointer or count fails the call before any item and
  consumes nothing, since the handles can't be known (channel_call's rule
  for unreadable arguments).
- **Callers:** syscall.h's `croi_channel_read` and `croi_channel_write`
  are the one-message forms; usertest.c, the C runtime's bootstrap read,
  m2 and userboot use them, and the suites `Sys.readChannel` and
  `Sys.writeChannel`. V2: Sys takes the arrays (`Channel.read(&items)`,
  `Channel.write(&items)`, any count, CROI_CHANNEL_MAX_ITEMS to a call),
  and the IPC dispatcher reads its ready channels and writes their
  replies and events with them, a round at a time.
- **Tests:** the channel suite's `batches`: three writes, the middle one
  to a channel whose peer is gone (two done, PEER_CLOSED, its handle
  consumed); three reads (one message, one too small with the size it
  needs, one SHOULD_WAIT); counts 0 and 65.
