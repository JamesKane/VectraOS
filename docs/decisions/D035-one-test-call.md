# D35. One test call (2026-10-15, decided)

The fourth of V1's merges: one call, 97 → 96.
- **CROI_SYS_TEST (6)**, test_profile until now, takes test_report's
  job as op 14, CROI_TEST_REPORT(value): the value the kernel's side of
  a self-test reads. The other ops are TestHooks' as before.
- **test_report is gated now.** It was open to every process; like the
  hooks, it answers NOT_SUPPORTED unless `croi.test=1` or
  `croi.debug_syscalls=on`. Every boot that runs the self-tests has
  `croi.test=1`.
- **Tests:** the callers (usertest.c's four, the interrupts suite's
  latency report) moved to the op; the self-tests that read the values
  are the check.
