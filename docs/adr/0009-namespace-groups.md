# ADR-0009: Namespace groups, and mounts found by identity

Status: accepted, 2026-10-01. Amends D4 (00 §4) and 02 §2.

## Context

VectraOS is Plan 9 evolved, in standard C (00 §1). Plan 9's namespace is a kernel `Pgrp`. A process shares its parent's unless it asks for a copy (`rfork(RFNAMEG)`) or a clean one (`RFCNAMEG`). So a `bind` in a script changes the namespace of the shell that ran it, and `rfork n` is how a script keeps its changes to itself. The kernel finds a mount by the identity of the file it was mounted on: at every step of a walk, `findmount` compares the channel's qid (`port/chan.c`). So a mount shows through every name that reaches that directory.

D4 moved the namespace into user space, so the kernel has no path walker, mount table or cache. That reason still holds. But the code went further than D4 needed, in two ways:

- **Copy-only.** Each process has its own table (`lib/vx-ns/ns.c`). A child gets a copy at spawn, and nothing it binds ever reaches its parent. 02 §2 sketched a shared group served by `nsd`, but deferred it to M8 (02 §8, question 3).
- **Found by path.** The longest matching prefix wins. After `bind /n/a /n/b; mount X /n/a/m`, the name `/n/b/m` is not `X`.

Both break the mental model Plan 9 scripts depend on.

## Decision

- **The kernel still has no paths.** D4's reason stands. What changes is who owns a table, and how a mount is matched.
- **Every process belongs to a namespace group, which owns one mount table.** As with `rfork`, a spawn chooses one of three:
  - **share** (the default): the child joins its parent's group;
  - **copy** (`RFNAMEG`): a new group starting from a copy of the parent's table;
  - **clean** (`RFCNAMEG`): a new, empty group, which the spawner fills from a template (`svcd`'s sandboxes, 02 §7).
- **`nsd` holds every group's table, one `nsd` per node.**
  - It publishes each table to the group's members as a read-only VMO with a sequence counter.
  - Members resolve names from that VMO with no round trip, and read it again when the counter moves.
  - `bind`, `mount` and `unmount` are channel calls to `nsd`, one round trip each.
  - A group with one member keeps its table private, as today, and is handed to `nsd` when a second member joins. So a process that never shares never talks to `nsd`.
- **Connections stay per process.** A ring has one producer (01 §4.3). So a table entry names a *connector*, not a connection. Each member opens its own connection on first use, through a duplicate of the connector handle that it gets from `nsd`. Inherited descriptors still need `Tshare`/`Tjoin` (docs/proto/posix.md), because a fid belongs to one connection.
- **A mount is found by the identity of its mount point:** the connection and the qid path of the directory it was mounted on, as 9front's `findmount` matches the channel at every walk step.
  - Resolution walks from the root. A `Twalk` already returns one qid per name walked. libns checks each against the table, and on a hit it continues from the mount's union with the remaining names.
  - A mount on a new name in a directory (`/n/host`, which Plan 9's mntgen would provide) is found by that directory and the name. In a union directory, the directory is its first member.
  - A `bind` or `mount` onto any name for a mount point joins that same union, as `cmount` finds its mount head by what it is mounted on. A union bound onto another directory is copied whole, in order.
  - A create in a union goes to the first member bound with `-c`, or fails, as 9front's `createdir` does.
  - So crossing a mount costs no extra round trip, and pipelining (02 §3.3) is unchanged.
  - `..` is still resolved lexically before walking.
  - The path a user typed is kept beside each entry, for `ns`.
- **`bind` still confines nothing** (rule 3). Confinement is still a connection attached at a restricted root.
- **There is no `RFNOMNT` flag.** In Plan 9 it stops a sandbox mounting `#` devices and `/srv` entries. Here a process can mount only what it holds handles for, so a template that leaves out `/srv` and `/net` has the same effect, and the server enforces it.
- **Namespace files are namespace(6).**
  - `/lib/ns/*` are scripts of `mount`, `bind`, `unmount`, `cd`, `clear` and `. file` lines, with rc-style quotes and `$var`, read by `newns` in `vx-ns` (`lib/vx-ns/newns.c`).
  - `ns` prints the same lines, quoted where it must, and `/proc/N/ns` serves them, so `ns` output replays through `newns` or the shell. A `mount` of `/srv/NAME` replays through a connection the namespace already has from that service.
  - A namespace file is a script, not data, so D14's ndb rule does not cover it. The `ns=` manifest key names a file under `/lib/ns`, and `boot/ns/*.ndb` goes away. A template holds only the namespace: the environment it carried moves to the manifest.

## Consequences

- `vx-ns` matches mounts by qid, not by prefix, and gains the group protocol. `nsd` is a new server of a few hundred lines. The spawn message carries the group: a handle to it for share, or the table's records for copy and clean.
- Shells behave like Plan 9's. A script's `bind` reaches its caller unless the script runs in a copied group (rc's `rfork n`).
- 02 §8's question 3 is closed. Groups arrive before M4's sockets, not at M8.
- **Open: `nsd` restarting.** Members keep the last published table and go on resolving with it. Until `nsd` is back, binds fail, and so do spawns that share.
