# D38. The debuglog becomes a read-only ring; debuglog_read is cut (2026-10-15, decided)

V1's last cut (`docs/syscall-audit.md` §2, roadmap V1 item 5): one call,
92 → 91, the audit's target. It lands after the one ring (item 4): the
debuglog is the first ring the kernel produces, so it uses that ring's
layout, not one of its own.
- **One ring, overwrite mode.** Architecture §3's ring is SPSC, and its
  producer waits for the consumer cursor. The debuglog's producer is the
  kernel, which never waits; its readers are any number of processes,
  mapping it read only. So the one ring gains a header flag, OVERWRITE:
  the producer ignores the consumer cursor (offset 128 stays zero), and
  each slot begins with its u64 sequence number, which the producer sets
  to all ones before it writes the slot and to the sequence after,
  each with release order, then advances the producer cursor. A reader
  keeps its cursor to itself: it skips to `producer - count` if it fell
  behind (the gap is its drop count), copies a slot, and keeps it only
  if the slot's sequence read the same, and equal to its cursor, before
  and after the copy. This is a format rule, so item 4's Swift ring,
  `ring.h` and the model checker cover it. The trace rings' CIRCULAR
  mode is the same idea; they move onto the ring at V2 (audit §4).
- **The slots** are today's: 512 of 256 bytes, each a `croi_log_record_t`
  and its text. The format descriptor names log records. The ring lives
  in a contiguous VMO mapped into the kernel, as the trace rings do. The
  kernel writes it through Ring.swift, and its dumper is a reader like
  any other (`DebugLog.reader`). A record's bytes past its text are zero.
- **The doorbell** is a counter the kernel owns, made at boot. Its value
  is the producer cursor: each record adds one, after the cursor's
  release. A reader that has caught up binds a VALUE trigger at its
  cursor plus one, which is how it declares that it is waiting (§3); one
  that wants a packet per record binds CHANGE. This is the first counter
  the kernel adds to; `Counters.add` is already a plain locked call.
- **Delivery, as D31's root account.** Userboot gets the ring as
  CROI_PA_VMO_DEBUGLOG (READ | MAP | GET_PROPERTY, no WRITE) and the
  counter as CROI_PA_DEBUGLOG_COUNTER (READ only: readable and bindable,
  not addable), and passes them on with the boot data to whoever reads
  the log: at V2 todhchai's console service, at V3 `log -f`. The
  kernel's self-tests get them from the kernel. Holding
  the handles is the right to read; the debuglog system resource
  (base 12) has no other use and goes with it.
- **debuglog_create loses READABLE.** Every log object only writes, so
  it takes no resource: `debuglog_create(0, 0, out)`. A log object's
  reader position, its READABLE signal and the readers list go.
  CROI_INFO_DEBUGLOG (written, printed) stays: m2 paces its trace export
  by it.
- **Callers:** the Swift boot test's round trip (`user/test/swift/Main.swift`)
  moves to a Swift `debuglog` suite, which reads through the mapping; the
  kernel checks the boot program's stdout through a reader of its own.
  usertest.c's record search (`log_has`) stays a helper: the checks that
  call it need the stub IOMMU and VT-d, so it reads the ring through
  `ring.h`, from the VMO its startup block now carries. todhchai's console
  service (`services/console/Main.swift`) and `Debuglog.reader` in its
  `sys` move to the ring when V2 lifts them.
- **Tests:** the suite checks that a record written comes back with its
  pid, tid, severity and text; that a caught-up reader's VALUE binding
  fires on the next write; that a reader lapped by more than 512 records
  resynchronises and counts its drops; and that the VMO and counter
  handles refuse WRITE, a writable mapping and counter_add. The model
  checker covers torn slots.
- **Lost:** per-reader positions kept by the kernel (a reader keeps its
  own), and READABLE as a signal (the counter replaces it). Reading needs
  a 132 KiB mapping where it needed a 256-byte buffer.
- **Rejected:** a READABLE log object that hands out the VMO and counter
  (two handles from one call, and a second way to gate reading); a
  separate overwrite ring format (principle 6); a counter add only when
  a reader is bound (the add is cheap, and a VALUE binding already
  fires at once on a value it has passed).
