# D33. handle_close takes an array (2026-10-15, decided)

The second of V1's merges: one call, 99 → 98.
- **handle_close(handles, count)** (10) is what handle_close_many (211)
  was: 0 skipped, a bad value BAD_HANDLE with the rest still closed, 64
  copied in at a time. Where there is one handle there will be many
  (principle 12), so the batch is the call and one handle is an array
  of one.
- **croi_handle_close(handle)** in `croi/syscall.h` is the one-handle
  form for C and Swift callers; usertest.c's 216 closes, the runtime's,
  userboot's, m2's and the Swift suites' go through it.
- **Tests:** the Swift `objects` suite's handle_close_many checks moved
  to the merged call.
