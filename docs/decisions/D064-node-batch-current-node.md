# D64. Node's batch: operations on a current node (2026-10-16, decided)

D18 makes a Node message a batch. This is its shape, as V2 lifts the
protocol from todhchai.
- **One call, `batch(ops, open)`, and the `changed` event.** The eight
  methods (walk, stat, readdir, read, write, watch, create, remove)
  become the cases of a union of operations (D54), at most 32 to a batch.
  A single operation is a batch of one, and the client's helpers each
  make one batch of a path and what to do there.
- **A current node, as NFSv4's COMPOUND has.** It starts at the channel's
  node; `walk` and `create` move it, and every other operation acts on
  it. So a later operation uses an earlier one's result: walking to a
  file, stat-ing it and reading it is one `channel_call`. The channel
  itself never moves.
- **The first failure ends the batch.** The reply carries the results of
  the operations before it and which one failed (an index and the
  NodeError's code; the count of operations means the open). A walk
  succeeds whole or fails: todhchai's walk that stopped early is gone.
- **One handle at most, beside the results.** With `open`, a batch that
  finished returns a channel to the node it ended at (for a service node,
  one that speaks its protocol). No other operation makes a channel, so
  results stay copyable (unions carry no handles, D54).
- **A mount takes the rest of the batch.** A walk that reaches another
  service's node forwards the names left and the operations after them
  as one batch there, and joins the reply: a path through a mount is one
  call from the client and one per service crossed.
- **Watches name their node.** `watch` registers for the current node,
  and its events come on the channel the batch was sent on, so `Change`
  gains the node's path to tell several apart.
- **Left behind:** todhchai's delegated directories (`NodeTree.delegate`),
  until a volume service needs them; they would take the forwarded rest
  of a batch as a mount does.
- **Tests:** NodeTests and NamespaceTests hosted (batches on a current
  node, failures and their index, the operation limit, service nodes, a
  mount taking the rest of a batch and going with its service, watches
  set by a batch); bin/node-test (boot-node) natively on each arch.
