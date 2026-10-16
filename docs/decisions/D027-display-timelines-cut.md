# D27. Display timelines are cut (2026-10-15, decided)

The sixth family of V1's cuts (`docs/syscall-audit.md` §2): four calls,
111 → 107.
- **timeline_create, timeline_advance, timeline_set_period,
  timeline_get_page** (170–173). Timeline objects (type 48), their
  vblank page and the display system resource's use (slot 16 stays
  empty) went. A driven display's vblank is a counter its IRQ thread
  adds to; a synthetic one is Radharc's own deadline thread sleeping to
  the vblank time it computes.
- **ALIGN_TIMELINE (Todhchai ext 10) goes with them.** It started a
  deadline thread's periods on a timeline's vblanks. Both replacements
  start the period at the wakeup instead: a counter's lent deadline
  starts its period when its packet wakes the thread (K10c), and a
  deadline thread that wakes from a `port_wait` deadline (no leeway)
  starts a new period there. todhchai's Radharc uses the option; V2
  lifts it onto the counter and its own thread. A thread's profile now
  takes no options (HANDOFF is an interrupt's).
- **The `timeline.wake` budgets go with their bench.** They measured
  the deadline thread waking at a synthetic vblank. With the vblank
  computed in user space, that is a deadline thread waking at its
  `port_wait` deadline, which `timer.wake_error_p99` measures, under the
  same 100 µs limit. The judge only checks budgets a run reports, so the
  history's old rows don't matter.
- **Tests:** mode 15 (timelines) went, and mode 16's alignment checks
  (385–388). Nothing in them tests a surviving mechanism: counters,
  VALUE bindings and lending are the counters suite's.
- **Lost:** nothing that still has a mechanism.
