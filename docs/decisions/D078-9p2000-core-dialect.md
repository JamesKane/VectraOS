# D78. 9gate's core dialect is 9P2000, not 9P2000.L (2026-10-16, decided; amends D77)

D77 brought 9gate's core forward to V3 as "the 9P2000.L codec, one
dialect". 9P2000.L is Linux's dialect: numeric uids and gids, Linux's
open flags, `Tgetattr`/`Tsetattr`, xattrs, POSIX locks and `readdir`
offsets, Unix semantics carried in the protocol. 9front speaks none of
it, so architecture §5's "Linux `v9fs` and 9front mount it unchanged"
could not have held.

- **The core is Plan 9's 9P2000.** Between our nodes, with 9front, and
  for cpu (D75, D77). `stat`'s owner, group and last modifier are
  strings, as 9P2000's are; there are no numeric ids anywhere, and no
  root (factotum and capabilities say who may do what).
- **Our extensions are negotiated in the version string**, as `.u` and
  `.L` are: `Tversion "9P2000.vx"`, falling back to `"9P2000"` when the
  peer doesn't answer it. They are the ones V7 lists (attributes and
  queries, leases and notifications, ring bridging), as new message
  types, never changes to 9P2000's.
- **Linux gets 9P2000 first.** `v9fs` mounts 9P2000 (`version=9p2000`).
  The translator speaks `.L` toward Linux only where 9P2000 falls short
  of `v9fs`'s conformance tests, and V7 decides which messages that is.
  `.L` never reaches the core or another VectraOS node.
- **Node's owners and modes**, when Node gains them, are 9P2000's: string
  names and the nine permission bits plus `DMDIR`, `DMAPPEND`,
  `DMEXCL`, `DMTMP`.
