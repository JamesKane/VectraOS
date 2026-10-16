# D23. Events, signals and the thread waits are cut (2026-10-15, decided)

The third family of V1's cuts (`docs/syscall-audit.md` §2): six calls,
129 → 123.
- **object_wait_one, object_wait_many** (21, 210). A port is the one wait
  (architecture §2): bind the source with `object_bind`, then
  `port_wait`. `ObjectWait` went; the thread-wait observers stay for
  `counter_wait` until it is cut.
- **event_create, eventpair_create, object_signal, object_signal_peer**
  (30, 84, 20, 85). User signals were only ever eventpair kicks; a
  counter is the event a user drives, and a ring's peer death is its
  negotiating channel's PEER_CLOSED. The user signal bits, the
  SIGNAL_PEER right, the NEW_EVENT and NEW_EVENTPAIR policy conditions,
  the HANDLE_CLOSED signal and the BLOCKED_WAIT_MANY state went with
  them, and so did D21's leftovers: NEW_ANY's FIFO and socket
  conditions, and the stream reads in the restartable list.
- **Event objects stay, kernel-made,** until `system_get_event` is cut.
  The audit replaces it with a binding on the root account, and there is
  no root account object yet.
- **m2 keeps its budgets' paths.** `port.wake` binds ONCE to a counter's
  POSITIVE signal where it bound to an event's SIGNALED, and the waker's
  `counter_add` stands where `object_signal` stood. The `channel_call`
  server is now as V1's servers are: its channel bound PERSISTENT to its
  port, drained at each packet. Interleaved against D22 under KVM (5
  boots each): `ipc.channel_call` 1.1 µs against 1.2 µs, `port.wake`
  median 1.1 µs against 1.7 µs; nothing rose past its noise.
- **Tests:** moved where the cut calls were called directly. Modes 0 and
  7's event, signal, port and channel checks and all of `small_calls`
  moved to an `objects` suite and the `channel` suite. Tests that only
  waited went on through `usertest.c`'s `wait_for`, rewritten as a ONCE
  binding on a port of its own (D21's in-place edits move when a later
  cut touches them). A pending ONCE binding holds its port, so a waiter
  that gives up cancels it (`zircon-divergences.md`).
- **Lost:** the kernel's check that one signal wakes eight waiters on
  one object across CPUs (`notify` running many observers at once). Its
  V1 form is many bindings on one object, which nothing checks yet.
  Checks of the cut calls themselves (user signal bits, `wait_many`'s
  items, eventpairs) went with them.
