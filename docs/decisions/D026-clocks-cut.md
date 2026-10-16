# D26. Clocks are cut (2026-10-15, decided)

The fifth family of V1's cuts (`docs/syscall-audit.md` §2): six calls,
117 → 111.
- **clock_create, clock_read, clock_get_details, clock_update,
  vmar_map_clock** (216–219, 77). Clock objects and their mapped page,
  the INFO_CLOCK_MAPPED_SIZE topic and the PA_CLOCK_UTC startup handle
  (nothing handed one out) went. UTC will be the time service's: a
  read-only seqlock VMO it hands each process at start (audit §4). No
  UTC source exists yet, so nothing is lost.
- **clock_monotonic** (3). The vDSO's clock is the one way to read
  monotonic time; the runtime's `croi_clock_monotonic` calls it. m2,
  userboot and the suites use it.
- **A futex_wait with no owner, and futex_wake, need no handle table.**
  Futexes are keyed by address space; only an owner is a handle. So a
  thread with no handles can sleep: the kernel-launched self-tests'
  modes 2 and 3 do.
- **usertest.c reads the vDSO.** It has no writable data, so a process
  mode finds the vDSO's base in its startup block (word 8) and a child
  in its start argument. Mode 3's sleeps had still called nanosleep by
  number since D25, so they had stopped sleeping; they are futex_wait
  timeouts now, 300 µs steps from a vDSO reading. Mode 4 spins until
  the kernel sets a word on its stack: a sample in the vDSO would count
  as foreign.
- **m2 keeps its budgets.** Interleaved against D25 under KVM (5 boots
  each), nothing rose past its noise. `process.spawn_to_main` 73.5 µs
  against 99.4 and `timer.wake_error_p99` 16.5 µs against 29.2: both
  ends now read the clock without a kernel entry. With the 1 ms steps
  measured then, `boot.userboot_start_selftests` was 3.547 s against
  3.425 (within its spread); mode 3's steps went back to the 300 µs it
  slept before D25.
- **Tests:** a Swift `time` suite: the vDSO clock never goes back, and
  a CHANGE packet's kernel timestamp falls between two vDSO readings,
  which was mode 2's check against the syscall. Mode 2 now checks the
  vDSO clock against a futex_wait deadline: never behind it. Mode 17's
  `clocks` went with the clock objects.
- **Lost:** nothing that still has a mechanism. The checks of clock
  objects themselves (rates, backstops, the mapped page's transform,
  STARTED and UPDATED) went with them, and the bench's syscall clock
  timing in mode 2.
