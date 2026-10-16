# D37. vmo_read and vmo_write are cut (2026-10-15, decided)

V1's cut of the two VMO copy calls: 94 → 92. Bytes go in and out of a
VMO through a mapping, the one way to reach its pages.
- **Callers:** userboot fills a misaligned segment and writes the
  relocations through a mapping of its own; m2 writes its exit test's VMO
  the same way. The tests' copies go through `vmo_get`/`vmo_set` in
  usertest.c, which map the pages a copy spans.
- **What a reader learns:** vmo_read returned why a page couldn't be
  had; a fault had no way to say. Now `UserAspaces.handleFault` throws
  the status and a user page fault's exception carries it as its
  `synth_code`, as Zircon's does: a pager's FAIL status, BAD_STATE once
  the pager detached, NOT_FOUND for a discarded VMO or no mapping,
  OUT_OF_RANGE past a shrunk end, ACCESS_DENIED for an access the
  mapping doesn't allow, NO_MEMORY.
- **Lost:** vmo_read's read-ahead. A read across two of a pager's pages
  was one request; through a mapping it is a fault and a request each.
  A pager that wants read-ahead supplies more than it was asked for
  (supply_pages takes any range). Reading an uncached or device VMO is now a
  mapping with that cache policy, not a refusal. vmo_read read a zero
  interval's zeros, and a child's parent, without committing; a read
  fault commits the page, so a child's first read takes its copy and a
  read inside a zero interval splits it (Zircon's "at least on write"
  allows both). Checks 413/414, 575, 670, 673 and 675 no longer read there.
- **Found:** a fault on a pager VMO whose page changed hands between its
  looks and the commit (a supply, ZERO, writeback) failed with NO_MEMORY,
  killing the thread; vmo_read's copy retried, which hid it until check
  740's stress read through a mapping. The fault now waits for the pager
  or retries, as the copy did.
- **Kept:** the kernel's page-locked copy (`VmoUserCopy`, K14h) stays
  for process_read_memory and process_write_memory.
- **Tests:** the bad-pointer checks and mode 0's copies went with the
  calls. The checks of vmo_read's statuses moved to the vmo suite's
  `faultStatuses`, which reads them from faults' exceptions; K14h's
  copy race moved there too, over process_read_memory.
