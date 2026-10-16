# D32. port_cancel_key merges into port_cancel (2026-10-15, decided)

The first of V1's merges (`docs/syscall-audit.md` §2): one call, 100 →
99.
- **port_cancel(port, source, key)** with source 0 cancels the key from
  every source, as port_cancel_key (212) did: each binding to the port
  with the key, and each queued packet with it, user packets included.
  NOT_FOUND if there were none. No handle is 0, so the two forms can't
  be confused.
- **The options argument goes.** port_cancel_key took one and refused
  any bit; nothing used it.
- **Tests:** the Swift `objects` suite's check moved to the merged call.
