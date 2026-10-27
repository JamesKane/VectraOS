# D144. A namespace is handed to a child by clones sent without waiting (2026-10-27, decided)

A spawn (posix_spawn, rc's start) gives the child the caller's
namespace whole (`Startup.mount`, `Namespace.clone`): for each member of
each mount, a new channel to the same node. Each was a `batch` with no
operations and `open`, a round trip to the member's server, and another
to the launcher for each forwarder: ~34 a spawn on the board's cpu
image, ~35 µs each traced, servers woken one after another while the
spawner waited. A member over the network waited much longer: from a
cpu session, `/mnt/term`'s open made every spawn ~42 ms (NOTES.md,
finding 8).

Fuchsia's `fdio_spawn` hands its namespace over the same way, entry by
entry, but with `fuchsia.io`'s Clone: the client makes the channel,
sends one end with a one-way message, and uses the other at once; its
requests wait in the channel until the server has it. Plan 9's rfork
copies a namespace in the kernel, where there is no server to ask.

**The owner's choice (2026-10-27):** Fuchsia's.
- Node version 7 gains `clone(node)`, one-way: the server serves Node on
  the channel it is given, at its channel's node and with that
  channel's rights, as `batch([], open: true)` would. Nothing is
  answered; a server that can't serve it closes it, which its peer sees
  as a closed channel on its first request.
- NodeTree, fs and the block class serve it at once; 9gate's imports
  walk a new 9P fid first, on a thread as their batches do, the
  channel's requests waiting meanwhile.
- `Startup.mount(namespace)` and `Namespace.clone` clone every member
  and forwarder. A member whose channel has closed reconnects and clones
  again, as its other calls do; a clone that fails later is found when
  the child first uses that mount.

**Not changed:** opening a node by path (a walk, then `open`: the reply
says whether the node exists and what it is), the launcher's mounts, and
`openFid` (D142).

**Measured** (the board, six runs after a warm boot, unpinned, from a
cpu session with `/mnt/term` bound to `/data`): spawn_exit_static
0.50–0.55 ms (from 1.20–1.23), spawn_exit_linked 3.46–3.85 ms (from
4.2–4.46). With `/mnt/term` the terminal's, as a cpu session has it,
0.52–0.58 and 3.57–3.82 ms (from ~42 and ~46): the spawner no longer
waits for 9gate's walk over the network.
