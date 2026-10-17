# D84. A Node read may wait: streams, answered when they have bytes (2026-10-17, decided)

Plan 9's `/dev/cons`, `/dev/kbd` (D83) and `/net`'s `listen` (D79) are
files whose reads wait until there is something to read. A Node read
was always answered at once. The owner's direction (2026-10-17): reads
may wait, the server holding the call.

- **Calls can be answered later.** A handler holds the call it is serving
  (`IPCDeferral.hold()`, set on the server's connection); the generated
  server sends no reply for it, and the handler answers it later with
  the method's generated reply encoder (`_reply_<Protocol>_<method>`) and
  the connection's `send`, on the server's own thread (a dispatcher's
  `wake`), so a reply never goes to a channel closed meanwhile. A client
  that gave up first drops the late reply; nothing else in the wire
  format (D6) changes: the reply echoes the call's txid as ever.
- **NodeTree's streams** (`tree.stream(path, NodeStream)`): a read takes
  what the stream has; with nothing there it is held until the service
  says `ready(node)`, and an empty read means the stream ended. Writes go
  to the stream's `write`, and the stream hears each channel opened at
  it come and go (`opened`, `closed`), as Plan 9's device files do
  (`rawon` lasts while consctl is open).
- **Only a read that begins a batch at the channel's own node waits**,
  which is how an opened file reads. One later in a batch, after walks,
  may have come through a mount whose service forwards batches on its
  own thread, so it answers with what is there, maybe nothing. Each
  opened file is a channel of its own, so only its reader waits.
- One mechanism: the only one that waits for a peer's data without a
  ring. Readers that move many bytes still attach the one ring (D67).

Not chosen: a plain read that returns at once, waiting only through the
attached ring (a plain `cat /dev/kbd` from rc wouldn't wait, which isn't
Plan 9's); a waiting read anywhere in a batch (it would stall a
forwarding service's dispatcher).
