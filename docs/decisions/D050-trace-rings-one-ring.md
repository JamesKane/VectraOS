# D50. Trace rings on the one ring (2026-10-15, decided)

croi's kernel writes a trace ring per CPU and todhchai's `Trace` a ring
per thread in a region, both in the trace format's own layout
(`croi_trace_ring_t`'s `head`, records at a page or a 128-byte header):
a second ring format beside the one ring (D43), which D44 said the trace
rings would join at V2. They join it now, as the trace session lands.
- **A trace ring** is a 128-byte trace header, then a one ring at +128.
  The header keeps what the ring doesn't: the counter's frequency, the
  session, the drops (count, first, last), the mode, the CPU and the
  thread id. The ring is OVERWRITE (D44's rule: each slot starts with
  its u64 sequence, readers keep their cursors to themselves), its slots
  40 bytes: the sequence, then the 32-byte record, unchanged (D10). Its
  format descriptor names trace records, version 2.
- **The modes are the producer's.** CIRCULAR overwrites the oldest;
  ONESHOT stops once its cursor reaches the slot count and counts what
  it drops. A reader treats both alike, reading back from the cursor
  (lapped readers skip and count, as for the debuglog).
- **One code path each way.** The kernel writes through `Ring.swift`
  (`write(from:)`), as the debuglog does; user space's `Trace` does the
  same per thread. Readers (the kernel's self-tests, m2, the session,
  `TraceReader`) read through `Ring.read(to:dropped:)`.
- **Sizes don't change.** `trace_configure`'s `pages` still means
  `pages × 128` records a CPU; the ring VMO is bigger by the slots'
  sequences.
- **The format document goes to version 2** (`docs/trace-format.md`): the
  region header and string table are as before; each ring is a trace
  ring as above.
- **Rejected:** keeping the trace layout and calling it a ring (a second
  format); slots of 32 bytes with the sequence in the record's `time`
  (it changes the record D10 fixed, and every reader with it).
