# D58. One synchronization mechanism: Loinnir tracks hazards (2026-10-16, proposed)

todhchai planned three: Loinnir's layout tracking, a separate render-graph
and barrier library (its F-106), and raw Vulkan barriers. That breaks
principle 1. v0's tracking also issues every transition as
`ALL_COMMANDS -> ALL_COMMANDS`, and doesn't track buffer write-then-read
hazards at all.
- **Tracked by default,** as Metal's resources are. Every draw and
  dispatch names what it reads through its root pointer and what it
  writes through its targets, so Loinnir knows each resource's last
  writer and inserts the narrowest barrier and layout change itself.
- **Untracked as the fast path:** a resource made untracked is the
  program's to order, with `barrier(before:after:)` taking pipeline
  stages only (no access masks, no layouts), after Aaltonen.
- **F-106 is not lifted.** Loinnir is the barrier library. Raw Vulkan
  programs bring their own, as tier 1 code.
- **Budget, with its check and milestone (V6):** `loinnir.encode_ratio_x10`,
  tracked encode time per draw over untracked, on a fixed scene of 10,000
  draws; limit 20 (2x). It is reported by Loinnir's bench program and
  enforced like the other budgets.
- **Tests:** a write then a read of the same buffer, and of the same
  image, with no barrier from the program, read back correct; the
  barriers recorded for each are the narrow ones, not `ALL_COMMANDS`.
