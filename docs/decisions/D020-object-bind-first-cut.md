# D20. object_bind, the first cut (2026-10-15, decided)

Step 1 of V1 (`docs/syscall-audit.md` §1). `object_bind(port, items,
count)` is the one way an event source reports to a port, and it takes a
batch (D18). It replaces five calls: `object_wait_async`,
`interrupt_bind`, `counter_wait_async`, `thread_bind_overrun_port` and
`account_bind_pressure_port`. The syscall count goes from 154 to 150, and
the ceiling with it.
- **Bindings are ONCE or PERSISTENT.** A persistent binding owns one
  packet. It is queued at an event and only counts further events while
  it waits to be read, so a busy source costs nothing per event once
  bound.
- **A counter's CHANGE binding is the ring doorbell** (architecture §3).
  Every add or write rings it.
- **`port_cancel` unbinds every kind,** interrupts included. That replaces
  interrupt_bind's UNBIND.
- **`port_wait` takes a leeway** (principle 10), so that sleeps coalesce
  once timers are cut.

Two consequences:
- **`vx todhchai-check` is retired.** todhchai's binaries use the old
  calls. From here on the ABI is VectraOS's, and V2 lifts the userland
  onto it.
- **New tests are Embedded Swift suites** (`user/test/swift/`, one file
  per subsystem, named checks, run by the kernel's
  `ProgramSelfTest.runSuites`), not additions to croi's monolithic
  `usertest.c`. That file shrinks as the calls it tests are cut, and is
  only edited to keep its remaining tests compiling.
