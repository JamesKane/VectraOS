# Node

The protocol every service serves, and the namespace.

## Node

`system/node/lib` is the Node protocol every service serves (architecture §4)
and `NodeTree`, the helper that publishes an in-memory tree with text
leaves (`status`, `ctl`). A service serves all its channels from one
thread with `IPCDispatcher` (system/ipc/runtime); change the tree from any
thread and watchers hear. A process's `Namespace` (system/node/lib) maps paths
to unions of Node channels, resolved in the client; `SrvBoard` is the
session's `/srv`. idlc's outputs for Node and the board are in
`system/node/idl`. A process reads its namespace from its Startup
(`Startup.swift`: `Namespace(startup)`, D65): PA_NS_DIR handles named in
processargs's names table, which a launcher adds with `mount`.

## Batches

A Node message is a batch (D18, D64): `batch(ops, open:)` runs operations
(`walk`, `stat`, `readdir`, `read`, `write`, `watch`, `create`, `remove`,
a union) in order on a current node that starts at the channel's, and
`walk` and `create` move it. It stops at the first failure, returning the
results before it and which operation failed; with `open`, a batch that
finished hands back a channel to the node it ended at. A walk into a
mounted node hands the rest of the batch to that service, so a path
through a mount is still one call from the client. The client's helpers
(`Client.swift`: `open`, `stat`, `read`, `readText`, `list`, `create`...)
each take a path and make one batch of it.

## Bulk

Past a batch's 32 KiB, a client attaches a ring pair to a node (D67,
`Bulk.swift`): one VMO it makes, holding an SQ ring, a CQ ring and a data
area, with a doorbell counter each way, handed over with Node's `attach`.
An SQ entry reads or writes a range of the node into or out of a range of
the data area; its CQ entry gives the status and bytes moved. NodeTree
serves it on its dispatcher (watching the doorbell), through the same
code as a batch's reads and writes; `NodeBulkChannel` splits a read or
write of any size into chunks, a slot's worth in flight.

## Memory

A file's contents can be had as a VMO (D71, Node's `memory`, version 3),
as Fuchsia's `GetBackingMemory`: to read or map, never to write, and with
`executable`, to start a process or load a library from, which only a
server whose files may run gives. NodeTree's memory files
(`tree.memory(path, vmo, size:, executable:)`) give their VMO; any other
file a copy that can't run. `Namespace.memory(path, executable:)` asks
for one: a program in /bin (the bootfs service's) starts so.

## wstat

A node can be changed as Plan 9's wstat changes one (D73, Node's
`wstat`, version 4): renamed in its directory, given a time, or a file
cut or grown, each field of `Wstat` given or left nil, all of it done or
none. NodeTree lets a client rename and time the nodes it made and size
the files it may write. `Namespace.wstat(path, change)` asks; the
shell's touch, mv and cp use it.

Names are compared and split as bytes (`NodeIPC.same`, `NodeIPC.names`):
String's `==` and `split` need Unicode tables tier 0 doesn't link.
todhchai's delegated directories (`NodeTree.delegate`) were left behind
until a volume service needs them.

## Tests

`swift test` runs `tests/` hosted; `bin/node-test` (`tests/native`, the
boot-node test) runs batches, mounts, watches, namespaces and `/srv` on
each arch.

## Streams

A file whose bytes come and go, as Plan 9's `/dev/cons` (D84):
`tree.stream(path, NodeStream(take:write:opened:closed:))`. A read
takes what is there; with nothing there, the server holds the call
(`IPCDeferral`) until the service calls `tree.ready(node)`, and an empty
read is the stream's end. Only a read that begins a batch at the
channel's own node waits (an opened file's); one after walks answers
with what is there. `StreamTests` checks both, and a held reader that
closes.
