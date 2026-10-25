# D135. A tree's forwarded batch doesn't hold up the tree (2026-10-25, decided; extends D84)

A NodeTree serves every channel on its dispatcher's one thread. When a
walk reaches a remote node (another service's tree mounted in it, as
devmgr mounts each driver's at `dev/` and `net/`), `Session.forward`
sends the rest of the batch with `Remote.batch` and waits for the reply
on that thread, with no limit. Until the other service answers, the
whole tree answers nothing, its own nodes included. boot-launch failed
once under load (2026-10-25) with `launcher: net.manifest:8: can't open
'devmgr/net'`: the launcher's 5 s limit on an open of devmgr's own `net`
directory ran out. Sixteen reruns, some on a starved host, didn't repeat
it; since then the launcher says why an open failed (timed out or not
found). A driver slow to answer under emulation, or one that hangs, can
stall devmgr this way, and with it every service that mounts its
directories.

- **A forwarded batch is held, as D84's waiting read is.** The session
  holds the call (`IPCDeferral.hold()`) and hands the batch to the
  remote's own forwarding thread; the dispatcher goes on serving. When
  the remote answers, the forwarding thread joins its reply to the walk
  so far, as `forward` does now, and the dispatcher sends it (`wake`),
  so a reply never goes to a channel closed meanwhile.
- **One forwarding thread a remote, made at its first forward.** A
  remote already takes one caller at a time (`Remote.batch`'s mutex), so
  its thread changes nothing for it; a slow remote delays only the
  batches that reach it. It ends with the remote (unmounted, or gone).
- **Order:** batches through one remote are answered in the order they
  came; one channel's next call follows its previous reply, as now.
  Replies on different channels may come in any order, as D84's held
  reads already do.
- **No limit is added.** A forward still waits as long as the other
  service takes: a timeout would cut legitimate long calls (a disk's
  large read, D84's reads that wait at the channel's own node), and a
  hung service is the launcher's to restart (its restart policy).
- One mechanism: the held call is D84's; nothing new in the wire format
  (D6) or the Node protocol.

Rejected: a deadline on `Remote.batch` (the reasons above); more threads
on the dispatcher (a NodeTree's nodes would need locking against
concurrent batches it doesn't have now); the launcher retrying or
waiting longer for a mount (hides the stall, and every other client of
the tree still waits); mounting drivers' trees in their clients'
namespaces directly instead of through devmgr (D82 makes devmgr's
`dev/` and `net/` the device directories).

Covers: system/node/lib/Tree.swift (`Session.forward`, `Remote`); node(5)
gains a note on forwarding. Tests: a Node host test whose remote
doesn't answer while the tree's own node does; boot-launch and the
boots that mount devmgr's directories (docs/risk.tsv's system/node/
row).
