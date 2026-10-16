# D29. The interrupt waits are cut (2026-10-15, decided)

The eighth of V1's cuts (`docs/syscall-audit.md` §2): three calls,
105 → 102.
- **interrupt_wait** (143). A bound port is the one way to wait for an
  interrupt, as for everything else. Ext 5's lent deadline and handed-off
  context (K14e) now ride the packet: the thread it wakes from the port
  gets them, as a counter's packet lends (D25).
- **interrupt_destroy** (144). Closing the last handle destroys. Its
  other use was waking an interrupt_wait thread CANCELED, which went
  with the wait.
- **interrupt_trigger** (145) and VIRTUAL interrupts. A counter is a
  virtual interrupt. Tests fire an interrupt object as its device would
  through a test hook (syscall 6, op 13), since a real device can't fire
  on demand everywhere (arm64's PL031 counts whole seconds).
- **Tests:** usertest.c's modes 11 (interrupts, MSI) and 16 (a
  handed-off context) moved to a Swift interrupts suite, which the
  kernel runs on its own where mode 11 ran, with the same checks around
  it (the RTC taken on CPU 1, nothing left behind). It needs device
  registers, so the runtime gained volatile MMIO accessors and amd64 port
  I/O as static inline C (`runtime.h`). Two direct users stayed in C:
  mode 17's idle-state check takes the RTC's interrupt object in place of
  a virtual one, and mode 18 dropped interrupt_destroy before a close.
- **`irq.wait_wake_median` keeps its name and limit.** It measured the
  interrupt_wait thread's wake; it now measures the port_wait's, the
  path drivers use.
- **Lost:** a thread can't wait on one interrupt without a port.
