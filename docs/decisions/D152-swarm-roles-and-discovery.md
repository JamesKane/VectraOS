# D152. The swarm's roles and discovery: each node its own key, one swarm file of members, names resolved by ndb (2026-10-30, decided by the owner; D148 §4, V7 step 6; amends the owner's 2026-10-30 choice for cpu's callers)

D148 put the swarm's node roles (terminal, CPU, file, auth; NeoVectra's
docs/02 §6) and how nodes find each other in V7, its pools and leases in
V8. This is that design, cut to what V7's nodes need.

## What stands

- **Identity.** A node's identity is factotum's `proto=noise-ik` key
  (D75). factotum makes one from the CPRNG when none is there, so it
  lasts one boot; a cpu image carries one in bootfs, and every image vx
  builds carries the same one (vx's node key): two dev nodes are one
  identity (found 2026-10-30, cpu -h's run).
- **Trust.** Two lists, kept two ways: 9gate's `trust` lines, until it
  restarts; cpu's `lib/cpu/terminal`, fixed when the image is built
  (the owner's choice for cpu, 2026-10-30).
- **Finding a node.** Nothing: `cpu -h` and 9gate's `import` take an
  address and a key, typed.
- **Roles.** Implicit: a node is a CPU server if its image runs `cpu -R`,
  a file server if someone wrote `listen` to its 9gate.

## Proposed

### 1. Each node its own key, kept on its volume

factotum makes the node's key once, on first boot, and keeps it on the
node's volume (`/data/lib/factotum/node`, readable by factotum alone,
through its manifest's own mount), so it survives reboots and warm
boots. A cpu image's bootfs no longer carries a node key: vx learns a
node's key the first time it reaches it (it is printed, and vx keeps it
by the node's name, as ssh's known_hosts does). The key is on disk in
plain until Taisce's S2 encrypts the volume (V7 step 7); on a board with
a TPM, sealing it is later work.

### 2. One swarm file: membership is trust

A swarm is the nodes listed in one file, `/lib/ndb/swarm` in ndb's form
(ndb(6)), the same on every member:

    sys=board  key=d468c6c6…  roles=cpu,file  ip=192.168.0.24
    sys=node1  key=f8cd75c5…  roles=cpu       ip=192.168.0.25
    sys=dev    key=33e88a6f…  roles=terminal

- Being in it is what lets a node in: 9gate takes a call from any key
  the file lists (its `trust` lines become this), and cpu's server
  answers any member whose entry has `roles` with `terminal` (cpu's own
  pinned `lib/cpu/terminal` stays, for the dev machine and the bring-up
  link).
- It lives on each node's volume, not in bootfs: it is the one thing a
  node is told at runtime about its swarm. The owner changes it from a
  terminal, in a cpu session, and a `swarm push` copies it to every
  member over 9gate; a node takes a new copy only from a member.
- Signed membership (an owner key signing node certificates, NeoVectra
  §6.2) is the next step when a swarm has nodes the owner doesn't
  reach directly; not V7's.

### 3. Names resolved by ndb

cs already reads ndb (ndb(8)): with the swarm file in its database,
`cpu -h board` and 9gate's `import board ...` resolve the name to its
address and its `key`, so neither takes `-k` for a member, and the
address can change (DHCP moved the board twice in V7) by editing one
line. No discovery protocol in V7: a node announcing itself on the LAN
(NeoVectra's DNS-SD on trusted networks) waits until a swarm has more
nodes than its owner types in.

### 4. Roles: what a node's entry says, what it serves

| Role | It serves | To |
|---|---|---|
| terminal | a screen and input; `/mnt/term` to the sessions it starts (cpu -h) | — |
| cpu | `cpu -R`, rc for a terminal | members with `terminal` |
| file | 9gate's exports, the trees its entry names (`export=/data`) | members |
| auth | factotum's keys for others (a multi-user swarm) | waits: one user per swarm in V7 |

A node starts the listeners its own entry's roles name (a `swarm`
service reading the file at boot: 9gate's `listen` for `file`, cpu's
server for `cpu`); `/swarm/nodes/<sys>/` serves each member's entry and
whether it answers, for `cpu -h` and a desk's view of the swarm.

## Not chosen

DNS-SD or a broadcast beacon now (no V7 node needs to be found that its
owner can't name); owner-signed certificates now (one owner, nodes he
reaches); keeping identities in images (two nodes from one build are one
node); a swarm file in bootfs (an address change would need a new image).

## Decided (the owner, 2026-10-30)

§1, §2 and §3 as proposed: each node's key made on first boot and kept
on its volume; the swarm file is trust, for 9gate and for cpu (members
with `terminal`), besides cpu's image-pinned dev machine; names resolved
from the swarm file only, no LAN discovery in V7.

## Built in this order

1. factotum's node key kept on the volume (first boot makes it); cpu
   images without a node key; vx keeping a node's key by name. Done
   (5d2a70f).
2. The swarm file in cs's database: `cpu -h NAME` and 9gate's `import`
   by a member's name, its key from its entry. Done (5d678c7).
3. Membership as trust: 9gate and cpu's server answering members. Done:
   each asks cs (`!key=… sys=*`) at each call, so an edit counts once
   cs rereads the file; cpu's server takes a member whose roles have
   `terminal`.
4. `swarm push`, and the `swarm` service: a node's roles starting its
   listeners, `/swarm/nodes`.

Each is tested on QEMU nodes (two or three bridged amd64 nodes, each its
own key) while the board is in other use.
