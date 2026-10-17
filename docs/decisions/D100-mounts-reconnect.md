# D100. A service's mount reconnects through the launcher's forwarder (2026-10-17, decided; extends D65, enables D99)

A `mount` in a manifest gave the process a channel to the service's
instance running then. When that service restarted, the channel closed
and the mount failed until the process itself restarted; only `/svc`,
whose nodes the launcher points at each new instance, reached the new
one. fs(4)'s `/data` broke on every fs restart, and D99's on-demand
services, which end `idle` and start again, couldn't be mounted at all.

Sending every batch through `/svc`'s forwarder would fix it at the cost
of a launcher hop on every file operation, with a waiting read (a
`/dev/cons` line) holding the launcher's dispatcher. So the hot path
stays direct, and only reconnecting goes through the launcher.

- **A forwarder per mount.** For each `mount` of a service, the launcher
  keeps a node in a tree of the mounting service's, mounted on the
  service's directory and pointed at each new instance after a restart,
  as `/svc`'s are.
- **`CROI_PA_NS_RECONNECT`**, beside the mount's `PA_NS_DIR` with the
  same argument: a channel served at that node. The direct channel is
  used as before.
- **Namespace reconnects.** When a member's call fails because its
  channel closed, it asks the forwarder for a channel to the current
  instance (a batch of one empty walk, opened, which the node forwards)
  and sends the call once more. A forwarder clones itself for a child
  (an empty batch, opened, makes another channel at the node), so rc's
  programs and cpu's sessions reconnect too.
- What was open in the old instance stays closed, as a Plan 9 file's fid
  does when its server goes. A call in flight when the service ended is
  sent again, once, to the new instance.

One handle per mount is added to a Startup (64 at most in its message).
No kernel change; the syscall ceiling holds.

**Checks.** LaunchTests' `aMountReconnectsWhenItsServiceRestarts` (two
restarts; it fails with reconnecting off), and launch-test reads
`/data/kept` through its own mount after fs restarts.

Rejected: forwarding every batch through the launcher (above).
Rejected: the client reopening the mount by service name, which would
put the launcher's naming into every namespace.
