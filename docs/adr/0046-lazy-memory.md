# ADR-0046: Lazy anonymous memory and decommit

Status: proposed, 2026-10-07. M6 step 6e1e2 (split in two: 6e1e2a the kernel's part, 6e1e2b `vx_heap`). Decided the same day: a `VX_VMO_LAZY` create option, and a decommit operation. This ADR adds `VX_VMO_LAZY` to `vmo_create`'s options and `VX_VMO_DECOMMIT` to `vmo_op` (`abi/vx/abi.h`).

## Context

An anonymous VMO's pages were all allocated and zeroed when it was made: commit, never overcommit, so a task learned it was out of memory from a failed call and never from a fault (`kernel/obj/vmo.c`). Nothing could give pages back but unmapping the whole VMO, or shrinking a resizable one from its end (ADR-0042). A task holds at most 85 mappings.

The process heap (`vx_heap`, 09 §10 question 5, os-requirements R6) needs a large range it uses a little at a time, inside few mappings, and to give back the pages of large blocks and empty slabs it frees. Eager VMOs make a heap's reserve cost its whole size in RAM.

Fuchsia commits a VMO's pages at first touch unless asked (`ZX_VMO_OP_COMMIT`), and frees a range with `ZX_VMO_OP_DECOMMIT`, which scudo, its C library's allocator, uses to return memory. 9front's segments are demand-zero, and its `segfree` gives pages back.

## Decision

1. **`VX_VMO_LAZY`** (alone, or with `VX_VMO_RESIZABLE`; not with `VX_VMO_PHYSICAL` or `VX_VMO_PAGER`) makes an anonymous VMO with no pages. A touch through a mapping, read or write, allocates the page zeroed and maps it. If no page can be had, the fault stands: the task sees an ordinary page fault at that address. This is the one place a task meets running out of memory at a touch, and only for memory it asked to be lazy.
   - `vmo_rw` reads an absent page as zeros without allocating it, and allocates one it writes (`NO_MEMORY` if it cannot).
   - A debugger's `task_mem_rw` does the same.
   - A resizable lazy VMO's added pages are absent, not zero-filled.
2. **`vmo_op(vmo, VX_VMO_DECOMMIT, offset, size)`,** with `WRITE`, frees a lazy VMO's pages in a page-aligned range. The pages leave every mapping and every TLB first, as a pager's eviction does, then are freed. A later touch reads zeros again. Other VMOs get `UNSUPPORTED`; an unaligned range is `INVALID`, one past the end `RANGE`, a sealed VMO `ACCESS`.
3. **Limits.**
   - A lazy VMO is not leased: its page list changes, and a lease shares its parent's (ADR-0043).
   - It is not given to `dma_map`, whose device would keep pages a decommit frees.
   - Its size limit is anonymous memory's, 256 MiB.
4. **Copies stay lazy.** A fork's copy of a private mapping of a lazy VMO is lazy, with only the pages present copied; so is a debugger's private copy (`mapping_privatize`).

## Consequences

- A process heap reserves address space and pays only for pages it touches; freed large blocks and empty slabs go back to the system.
- Running out of memory under a lazy VMO is a fault at a touch, which kills a program that does not handle it, rather than a failed call. Eager VMOs are unchanged.
- A decommit costs a pass over every task's mappings (as eviction and shrinking do); the heap batches its decommits.
