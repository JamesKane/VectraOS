# ADR-0044: Environment groups

Status: proposed, 2026-10-07. M6 step 6e1c (split in three: 6e1c1 `/env`, 6e1c2 the temporary directory, 6e1c3 identity). Decided the same day: `/env` as 9front's environment groups; a per-user temporary directory as 9front's; user ids from users(6). This ADR is the first: it adds envd, the `envgroup=` spawn record and the `srv:env` connector to the spawn message's conventions (`abi/vx/abi.h`'s spawn records), and `/env` to every process that has a connector to envd.

## Context

A program's environment was the spawn message's `env=` records alone: a copy each child got at start, never shared. 9front keeps an environment group (`Egrp`) for each process group in the kernel (`sys/src/9/port/devenv.c`), bound on `/env` from `#e` (`lib/namespace`): a child shares its parent's unless it asks for a copy (`rfork e`) or an empty one (`rfork E`), and its rc writes the shell's variables there before each exec (`Updenv`, `sys/src/cmd/rc/plan9.c`). VectraOS's rc had no `/env`, so `rfork e` and `E` did nothing (a known gap, moved here by 6d7c).

An environment group is per process, apart from the namespace: `rfork e` without `rfork n` changes the one and not the other. VectraOS's namespaces are shared by namespace group through nsd (ADR-0009), so `/env` cannot be an ordinary mount in that table.

## Decision

1. **envd** serves the groups, posted as `/srv/env`. A group is a directory of variables, each a file holding its value. An attach names one: `new` (empty), `+TOKEN` (a copy: `rfork e`), or `TOKEN` (that group). Its token, the root's qid path, is 64 random bits from the entropy envd's manifest gives: knowing it is the authority, as a handle is, never a small number to guess. A group goes with its last fid. No permissions: the token is the capability.
2. **`/env` is the process's own.** vx-ns keeps a connection to envd apart from the namespace's (`VX_NS_ENV_CONN`, a slot no mount and no group table names) and resolves `/env` and the names below it on that connection's attach root before the table, attaching on first use. A process with no connector to envd has no such `/env`: the table decides.
3. **Children share it.** `vx_ns_spawn_records` gives each child the group's token (`envgroup=TOKEN`) and a duplicate of envd's connector (`srv:env`); a process attaches to the group its parent named, and after a POSIX fork to its parent's. A process with no group to join (one svcd started; one whose parent's group went before it attached) starts a new one filled from its `env=` records. `connect=env` in a manifest gives a service the connector.
4. **`env=` records stay.** They are still a program's environment at start (`getenv`, `environ`): `/env` is the shared store beside them, as 9front's APE reads `/env` once at start.
5. **rc** writes each variable and function that changed since its last spawn to `/env` as it starts a program (9front's `Updenv`); `rfork e` gives the shell a copy of its group, `rfork E` an empty one.

## Consequences

- `cat /env/NAME`, `ls /env` and `echo value > /env/NAME` work for native and POSIX programs alike; a child's write is its parent's and siblings' to read; rc's `rfork e` and `E` mean what they mean in 9front.
- A process that starts children costs one connection and attach to envd; one that never touches `/env` and starts none costs nothing.
- A child whose parent exits before the child first uses `/env` finds the group gone and starts its own; rc writes variables at spawns, not at assignments, and does not remove one it deletes.
- envd holds groups in memory: they go with it, and a restarted envd starts empty.
