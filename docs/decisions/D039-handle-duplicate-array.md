# D39. handle_duplicate takes an array (2026-10-15, decided)

The first of V1's batched forms (`docs/syscall-audit.md` §3, roadmap V1
item 3). The count stays at 92: the array form replaces the single one.
- **handle_duplicate(items, count)** (11) takes up to 64
  `croi_handle_duplicate_item_t` (ipc.h, 24 bytes): handle, rights and
  options in; the new handle and a status out. It follows object_bind
  (D20), not handle_close (D33): in order, stopping at the first item
  that fails, each processed item's status written back, the count of
  successes returned. A bad pointer or count fails the call before any
  item is done, and nothing done is undone (audit §3). handle_close
  goes on past a bad handle because closing has nothing to leave half
  done; a duplicate's caller needs to know which handles it holds.
- **CONSUME is per item** (D34's replace): a batch can duplicate some
  handles and replace others.
- **A new handle whose value can't be written back is closed again.**
  Nobody could learn its value, so it would leak until the process went.
- **Callers:** `croi_handle_duplicate(handle, rights, &out, options)` in
  syscall.h is the one-item form, as `croi_handle_close` is D33's;
  usertest.c and the suites (`Sys.duplicate`) use it. Userboot
  duplicates the new process's process and thread handles in one call,
  the launcher case audit §3 names.
- **Tests:** the objects suite's `duplicateMany`.
