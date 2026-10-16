# D10. Performance contracts from todhchai (2026-10-15, decided)

- `Judge` (`todhchai/tools/bench/lib/Judge.swift`) decides pass or fail:
  median of the last 5 runs plus a tolerance and a floor, and an optional
  hard limit.
- Budgets are reported on the console as `budget name=… value=… unit=…
  limit=…` lines and kept in a per-host history.
- The tracer uses one 32-byte record, shared by kernel and user space.

These carry over unchanged. See performance.md.
