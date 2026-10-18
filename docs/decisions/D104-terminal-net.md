# D104. The terminal serves its /net, and rc binds it: a cpu session dials out through the dev machine (2026-10-18, proposed; extends D77, D79)

D79 says a cpu session can bind the terminal's `/mnt/term/net` over its
own, as Plan 9's `import -a` does, and V3's exit asks for it: "a cpu
session dials out through the terminal's `/net`". Neither half exists.
The terminal's tree (`tools/cpu/lib/Files.swift`, the tree `vx cpu`
serves the node at `/mnt/term`) has `dev/cons`, `dev/cpunote` and
`root/`, and no `net/`. rc has no `bind`, and no command does
(roadmap, V2's commands: `bind` and `mount` are among those missing).
What it is for: a node reaching hosts that only the dev machine can reach
(its own `localhost`, its LAN, its VPN), from a board whose own network
is a cable to the bench, or none.

So this decision adds no mechanism: Plan 9's `/net` files, served by
the terminal from its own sockets, and Plan 9's `bind`.

- **The terminal serves `net/`**, as ip(3) lays it out, for TCP:
  `net/tcp/clone`, and per conversation `N/ctl`, `data`, `local`,
  `remote` and `status`; and `net/cs`, the connection server, which
  answers a dial string with `/net/tcp/clone ADDRESS!PORT` lines from
  the dev machine's own lookup (getaddrinfo, getservbyname), as ndb(8)'s
  cs does on the node. Opening `clone` makes a conversation and reads as
  its number; ctl takes `connect ADDRESS!PORT` (and `hangup`); `data`'s
  reads wait for bytes (one recv each, at most what is asked) and are
  empty at the end; writes send all they are given. The conversation
  ends when its last fid is clunked, as on the node (ip(4)).
- **Not yet:** UDP, `announce` and `listen` (a node taking calls on the
  dev machine's ports), `ipifc` and `iproute`. They answer
  `operation not supported`, and come when something needs them.
- **The terminal's server waits off its loop.** A read of `data` and a
  `connect` run on a thread of their own, as a read of `dev/cons` does
  now (Server.swift), so a session's other requests go on. A flush
  forgets the request; the socket stays until its conversation ends,
  and a clunk's `shutdown` ends a read still waiting in it.
- **rc gets `bind`**, Plan 9's: `bind [-b|-a|-c...] NEW OLD`, a builtin,
  since it changes rc's own namespace (Sys's Namespace), which the
  programs it starts inherit (it gives them its whole namespace). It
  is the namespace's own `bind`, with `-b` and `-a` its unions' before
  and after and `-c` the create mark. `mount` (a service's channel at a
  path) is left out: nothing in a session needs it yet.
- **Who binds, and where.** Nothing binds by default: a session's
  `/net` stays the node's. `bind -b /mnt/term/net /net` puts the
  terminal's before it: dial(2) then finds the terminal's cs and
  clone first, and every call goes out through the dev machine (as in
  Plan 9; `-a` would leave the node's first, and the terminal's
  unused). A program that wants both binds each where it looks. cpu(8)
  and rc(1) say so.

**Checks.** CpuTests: the terminal's tree dials a listener on the dev
machine through `net/cs` and `net/tcp/clone`, reads and writes its
data, ends the conversation at the last clunk, and refuses `announce`.
RcTests: `bind` and its flags, over a hosted namespace. boot-cpu: a
session binds `/mnt/term/net` before its `/net` and dials, by hand as
in Plan 9 (no command dials yet): `clone` held open on a descriptor
(`<>[3]`), its number read, `connect 127.0.0.1!PORT` written to it,
then `data` read. PORT is the dev machine's own forwarded port to the
node's cpu server: an address the node's own stack can't reach (it has
no loopback, ip(4)), so the call reaching the server (its console's
`cpu: session from`) is the terminal's. The node's own `/net` answers
as before.

Rejected: a dial-out service on the node that tunnels connections over
the cpu link (a second way to reach the network; `/net` is the one).
Rejected: binding the terminal's `/net` in every session (a node's own
network is what its programs expect; the terminal's is asked for).
Rejected: `vx cpu` forwarding ports, as ssh's `-L` (a port is not a
file; it reaches one address, chosen before the session).
