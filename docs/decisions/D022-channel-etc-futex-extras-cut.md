# D22. The channel _etc forms and the futex extras are cut (2026-10-15, decided)

The second family of V1's cuts (`docs/syscall-audit.md` §2): six calls,
135 → 129.
- **channel_write_etc, channel_read_etc, channel_call_etc** (213–215).
  One form per job: a handle's rights are narrowed with
  `handle_duplicate` before it is sent, and a reader that needs a
  handle's type or rights asks `object_get_info`. channel_read keeps what
  K13e gave it: unknown options are NOT_SUPPORTED, and MAY_DISCARD drops
  a message that doesn't fit.
- **futex_requeue, futex_wake_single_owner, futex_get_owner** (92–94).
  todhchai's Lock and pthreads use wait and wake only. futex_wait still
  names an owner, which inherits its waiters' profiles, and futex_wake
  clears it. With no requeue, a waiter's futex record is the one it
  blocked on, so `Thread.futex` and the scheduler's `moveWaiters` and
  `wakeFirst` went too.
- **Tests:** the futex checks of `usertest.c`'s mode 8 moved to a Swift
  `futex` suite, and the channel checks of `small_calls` that survive
  (MAY_DISCARD, and narrowed rights arriving narrowed) to a `channel`
  suite. `runSuites` now lends `test_profile` a deadline context, and
  fails if a futex record is left after the suites.
- **Lost:** the direct check that a wake clears the owner (get_owner read
  it back). It is checked indirectly: an owned record is never retired,
  so a cleared owner is what lets `runSuites` find no record left.
