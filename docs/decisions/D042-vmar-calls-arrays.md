# D42. vmar_map, vmar_unmap and vmar_protect take arrays (2026-10-15, decided)

The last family of V1's batched forms (`docs/syscall-audit.md` §3,
roadmap V1 item 3). The count stays at 92.
- **vmar_map(vmar, items, count)** (71) takes up to 64
  `croi_vmar_map_item_t` (task.h, 48 bytes: VMO, options, VMAR offset,
  VMO offset, length; the address and a status out), all into one VMAR.
  It **stops at the first item that fails**, as object_bind and
  handle_duplicate do: a program's segments are all or nothing, and its
  loader tears the process down on any failure, so mapping the rest is
  wasted work. What it mapped stays mapped (audit §3).
- **vmar_unmap and vmar_protect(vmar, ranges, count)** (72, 73) take up
  to 64 `croi_vmar_range_t` (24 bytes: address, length, options; a
  status out), unmap's with options 0, protect's with the permissions.
  They **go on past a range that fails**, as counter_add and the channel
  calls do (D40, D41): each range stands alone, and teardown should
  unmap the rest.
- Each call returns how many succeeded; a bad pointer or count fails it
  before any item. The packed `vmar | options << 32` first argument goes
  from these three; vmar_allocate and vmar_map_view keep it, and
  vmar_unmap_handle_close_thread_exit stays one range (it ends the
  thread).
- **Spawn maps a program's segments in one call:** userboot's `load`
  prepares each segment's item (the bootfs VMO for a read-only segment
  as it is, else a filled, relocated VMO of its own) and `mapSegments`
  maps them all at once; the segments' VMOs are closed after. This is
  the case audit §3 names for spawn → main < 200 µs.
- **Callers:** syscall.h's `croi_vmar_map`, `croi_vmar_unmap` and
  `croi_vmar_protect` are the one-item forms, in Zircon's argument
  order; usertest.c (71 sites, rewritten mechanically), the C runtime's
  malloc, the suites, m2 and userboot use them.
- **Tests:** the vmo suite's `vmarBatches`: four maps whose third names
  no handle (two mapped, BAD_HANDLE, the fourth untried), three protects
  and three unmaps whose middle range fails (two done each), counts 0
  and 65.
