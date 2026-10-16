# D25. Sleeps, timers and the counter waits are cut (2026-10-15, decided)

The fourth family of V1's cuts (`docs/syscall-audit.md` §2): six calls,
123 → 117.
- **nanosleep, timer_create, timer_set, timer_cancel** (4, 95–97). A
  sleep is a `port_wait` with a deadline on a port nothing is bound to; a
  timer is the deadline an event loop passes to its `port_wait`, the
  earliest it has. port_wait's leeway (principle 10) runs late, never
  early, and a deadline thread gets none, as timer objects' slack did.
  Timer objects, their slack policies and the NEW_TIMER policy condition
  went. `Objects.lastHandleClosed`, their hook, stays for ports.
- **counter_write, counter_wait** (163, 164). A value is set by adding
  the difference; a wait at a value is an object_bind VALUE binding. The
  thread waits behind counter_wait went with it (`WaitState`,
  `Observer.Kind.wait`, `Thread.waitState`): every observer is now a
  binding.
- **A counter's lent deadline moves to the port** (K10c, ext 5). A
  counter or timeline with a deadline profile lends it to the thread its
  packet wakes in `port_wait` (`Scheduler.wakeOne(lending:)`), where it
  lent it to counter_wait's threads. Interrupts keep lending to their
  interrupt_wait thread until that call is cut.
- **m2 keeps its budgets.** `counter.wake` now runs from `counter_add` to
  the `port_wait` a CHANGE binding (the doorbell) ends, where it ran to
  counter_wait's exit; the timeline wake waits with a VALUE binding; the
  sleeps and `timer.wake_error` sleep through `port_wait`; the exit test
  waits for a counter's value, then to a deadline, where it set a timer.
  Interleaved against D24 under KVM (5 boots each): `counter.wake`
  median 1.0 µs against 969 ns, `timer.wake_error_p99` 26.2 µs against
  27.3; nothing rose past its noise.
- **Tests:** mode 14 (counters) and mode 16's lending check moved to a
  `counters` suite; mode 8's zero slack for a deadline thread moved to
  the bind suite's leeway check, and the rest of mode 8 (timers) went.
  usertest.c sleeps through `sleep_until` (a port of its own each time,
  since the program has no writable data) and waits at a value through
  `wait_value` (a VALUE binding on its own port).
- **Lost:** nothing that still has a mechanism. The checks of timer
  objects themselves (slack policies, set and cancel clearing SIGNALED,
  two threads setting one timer, handle_replace keeping one armed) went
  with them. Many timers on one CPU is still checked by the kernel's
  timer self-test, which arms 200 nodes on one CPU.
