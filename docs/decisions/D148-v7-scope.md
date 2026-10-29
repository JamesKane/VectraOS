# D148. V7's scope: measured first, a plain 9P2000 listener for Linux and 9front, pjdfstest for conformance, the swarm without its pool, and Taisce's S2 whole (2026-10-29, decided by the owner; amends D78's budget, D105)

V6 closed with the boards after it (V6b, V6c) set aside for now, and V7
scoped next. What stood: 9gate's 9P2000 core serves every message, its
export and import run over Noise IK and carry the cpu link daily; a
node has cpu's server but no client; nothing of `9P2000.vx`, the swarm
or Taisce's snapshots exists. V7 needs neither V6b nor V6c: its two
nodes are the Orange Pi 6 Plus and a QEMU node, and its PC is the dev
machine.

## Decided

### 1. The order

1. The LAN budgets defined and measured, on a two-node harness, before
   anything changes.
2. 9gate toward Linux and 9front (§2), then `v9fs`'s conformance (§3).
3. `cpu -h NODE` between VectraOS nodes (D75).
4. The export on rings (D103's open item), judged against step 1.
5. The `9P2000.vx` extensions (D78): attributes and queries, leases and
   notifications, ring bridging; one design, then built.
6. Swarm node roles and discovery (§4).
7. Taisce's S2 (§5).

### 2. Foreign peers: a plain 9P2000 listener

Every 9gate connection is sealed by Noise IK, which Linux `v9fs` and
9front can't speak. 9gate gains a plain 9P2000 listener:
- opened only by an explicit line in its `ctl`, never by default;
- bound to the address it names, and taking only callers from the
  addresses or prefixes that line allows;
- with no authentication: `Tauth` is refused as it is now, so 9front
  mounts with `-n`, and `v9fs` with `trans=tcp`. A caller's `Tattach`
  name is recorded, not trusted.

`p9any`/`dp9ik` (an auth server) and a tunnel instead were considered and
not chosen. Noise IK stays the only transport between VectraOS nodes.

### 3. Conformance: pjdfstest over `v9fs`

The budget "passes the 9P2000.L conformance suite in `tests/net`" names
a suite that doesn't exist and puts `.L` first, against D78. It becomes:
pjdfstest, a third-party suite run on the host (D4 allows host tools),
over a Linux `v9fs` mount of a VectraOS export with `version=9p2000`.
Its failures decide which `.L` messages the translator speaks toward
Linux (D78), and those are recorded with their failures. Tests that ask
for what 9P2000 has no word for (numeric ids, devices) are listed as
outside it, not failed silently.

### 4. The swarm without its pool

V7 does node roles (terminal, CPU, file, auth; NeoVectra's docs/02 §6)
and how nodes find each other, designed in its step. `/swarm/pool`'s
leases and remote `/dev/accel` move to V8, with the accelerators they
lease.

### 5. Taisce's S2 whole

Snapshots as dated directories, a volume's changes sent to another
node's over 9gate, and per-volume AES-XTS encryption (moved out of V6
by the owner, 2026-10-29), designed together in V7: what is sent is
what the volume holds, encrypted or not.

## The budgets

- 9gate's "local loopback 4 KiB Tread < 50 µs" becomes node to node:
  `net` has no loopback. Its limit stands until step 1 measures it.
- "LAN 1 GbE bulk read ≥ 90% of line rate", the Orange Pi 6 Plus to the
  dev machine.
