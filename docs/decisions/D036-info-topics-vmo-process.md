# D36. vmo_get_size and process_info become info topics (2026-10-15, decided)

The fifth of V1's merges: two calls, 96 → 94.
- **vmo_get_size** (44) is object_get_info's VMO topic: `size_bytes`
  is the same size (a reference's is its root's, K14g) and needs no
  rights either. `croi_vmo_size(vmo, &size)` in `croi/syscall.h` wraps it
  for userboot, m2 and the tests.
- **process_info** (68), croi's own call, is CROI_INFO_PROCESS, which
  already held the return code and the STARTED and EXITED flags (and
  more). croi_process_info_t and its flags go.
- **Cost:** the VMO topic also counts what is committed, a walk of the
  VMO's pages. Its callers size a VMO once, before mapping it (bootfs,
  the boot data, trace rings), so none is on a hot path.
- **Tests:** the size checks (VmoSuite's, usertest.c's nine) and every
  exit code read go through the topics.
