# ADR-0043: Seals and leases

Status: proposed, 2026-10-07. M6 step 6e1b (split in three: 6e1b1 seals and leases, 6e1b2 leases lent for one call, 6e1b3 `<vx/shared.h>` and the host and plugin scenario). Decided the same day: a revoked lease's touch is an exception of its own kind; sealing as Linux's `memfd`; leases one level deep. It gives `vmo_seal`, `vmo_lease` and `vmo_revoke` (01 §3, §6.6), reserved since M1, their meaning, and adds `VX_EXCEPTION_REVOKED`, `VX_ERR_REVOKED` and a `vx_call`'s lent handles to the ABI (`abi/vx/abi.h`, `abi/vx/status.def`). 01 §13 question 8 left two things to this ADR: how a handle is marked lent in a `vx_call`, and what a server sees when a lease ends while it reads.

## Context

01 §6.6 lets one process hand another a whole structure in a VMO to read in place: the writer publishes by sending, an untrusted writer seals before sending so the bytes cannot change under the reader's checks, and the host takes a view back when it replaces a plugin, or gets it back at the end of one call however the plugin fails. 01 §7 needs the same revocation for a restarted driver's memory.

Hubris (Oxide) lends memory for one message; the server reaches it only by copying through syscalls, which fail once the lease ends, so nothing is ever mapped. 01 §6.6 wants the structure read in place, so a lease here must be mappable, and its end must reach every mapping. Linux's `memfd` seals (`F_SEAL_WRITE`) refuse to seal while a writable shared mapping exists, and refuse every write afterwards.

## Decision

1. **`vmo_seal(vmo)`**, with `WRITE`: no one writes the VMO again, through any handle, mapping or lease of it: `vmo_rw` writes, `as_map` and `as_protect` with `VX_MAP_WRITE`, and a resize are refused (`ACCESS`). As `memfd`'s, it is refused (`BAD_STATE`) while any task maps the VMO or a lease of it writable; the kernel seals first and then looks, and a map checks the seal under its task's lock, which the look takes, so none slips between. Physical and pager-backed VMOs are not sealed; a lease is not (its parent is).
2. **`vmo_lease(vmo, &lease)`**: a VMO handle on the same pages, with the caller's rights and `MANAGE`. The holder gives readers duplicates without `MANAGE` and keeps the lease to revoke. Only a plain anonymous VMO is leased, as its page list never changes; a lease is not leased again (one level: a derivation tree waits for 01 §13 question 2).
3. **`vmo_revoke(lease)`**, with `MANAGE`: from then on nothing reaches the pages through the lease. Every mapping of it, in every task, loses its pages, and the next touch raises **`VX_EXCEPTION_REVOKED`** (code read 0, write 1, execute 2; POSIX's `SIGBUS`; unhandled, `sys: trap: lease revoked addr=...`), so a reader tells a revocation from a wild pointer and can unwind. `vmo_rw`, `as_map` and `vmo_clone` through it answer **`VX_ERR_REVOKED`**, checked page by page in a long copy. A forked task maps a lease's mapping as it is, never a copy, and a debugger's write never privatizes one, so no copy outlives a revoke. The parent's pages stay until the parent goes: a lease holds it.
4. **Lent for one call** (6e1b2): a `vx_call` carries `lent`, a bit for each of its request's handles. A lent handle must be a VMO; the caller keeps it, and the kernel sends the server a new lease of it instead, which it revokes when the reply comes, when the call's deadline passes, or when either side dies. The caller keeps no list of what to revoke.

## Consequences

- A host shares a structure read-only, seals a plugin's result before trusting its checks, and takes a view back whenever it chooses, or at the end of a call, with the reader's mappings emptied in every task.
- A reader of a lease is prepared for `VX_EXCEPTION_REVOKED` (an in-task handler, or `SIGBUS` with `siglongjmp`), or dies when its lease ends.
- A lease of a pager-backed, resizable or physical VMO (a mapped file, a driver's DMA buffer) is not there yet: 01 §7's driver restarts revoke DMA domains instead, until a lease follows a page list that changes.
