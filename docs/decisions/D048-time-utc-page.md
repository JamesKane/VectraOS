# D48. Time: UTC in a page the time service writes (2026-10-15, decided)

V1 cut clock objects and vmar_map_clock (D26). todhchai's launcher makes
the UTC clock, hands it out as PA_CLOCK_UTC, and the floor maps its page
(`td_utc_install`).
- **The time service owns UTC.** It publishes it in a VMO it writes: a
  seqlock page (sequence, offset from monotonic time, and its error
  bound) that every other process maps read only.
- **Delivery is the launcher's:** each process gets the VMO at start
  (a processargs entry replacing PA_CLOCK_UTC), and the floor maps it
  where it mapped the clock page, so `clock_gettime(CLOCK_REALTIME)` stays
  a read with no syscall.
- **Monotonic time** stays the vDSO's.
- **Rejected:** a kernel UTC (the kernel knows no wall time, and clocks
  were cut for that reason).
