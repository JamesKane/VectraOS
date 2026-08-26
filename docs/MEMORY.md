# Physical memory, page tables, and the heap

`kernel/mem/` — `mem.odin`, `pmm.odin`, `vmm.odin`, `heap.odin`

Three layers, each of which the one above it can be written without knowing the
internals of: a bitmap frame allocator over the firmware's memory map, a page
table walker that owns the kernel's address space, and a slab allocator behind
`context.allocator`. `kernel/arch` owns the page table *encoding*; this package
owns the *walk*, and that split is what makes the other two architectures a
matter of filling in blanks.

Nothing here allocates after boot except the heap, which is why `pmm.odin` has
no lock and the heap has one.

## Decisions, and what would reverse them

- **Base revision 6's HHDM is restrictive** — only usable,
  bootloader-reclaimable, executable, framebuffer, reserved-mapped, ACPI
  reclaimable and ACPI NVS regions are mapped. **The VMM must respect this.**
  `check_base_revision()` currently only *warns* on a mismatch; make it a hard
  stop as soon as anything dereferences an HHDM address.
- **`arch` owns the page table *encoding*; `kernel/mem` owns the *walk*.** This
  is where the "only CPU-facing import" rule landed for paging. `arch` supplies
  `table_index`, `level_size`, `leaf_encode`, `branch_encode`, `entry_flags` and
  friends; `vmm.odin` implements the descend-and-allocate loop once against
  them. The walk genuinely is not amd64-specific — aarch64's stage-1 tables and
  riscv64's Sv39/Sv48 are the same radix tree, nine bits at a stride — so a port
  supplies an encoding rather than a second walker.
- **Bitmap PMM, not a free list.** A free list has to live in the pages it
  tracks, so one stray write corrupts the allocator itself; and contiguous
  multi-page allocation, which page tables and large heap blocks both need, is a
  run search over a bitmap versus a linear walk over a list. The cost is a scan,
  bounded by a rotating hint and by skipping fully-taken bytes eight frames at a
  time.
- **The bitmap indexes from physical zero**, holes included, so `phys /
  PAGE_SIZE` is the index with nothing to subtract. Hole frames are born taken
  and never freed. It is 15 KiB on this machine.
- **Frame 0 is reserved forever.** Base revision 6 lets the firmware call the
  page at physical zero usable. Handing it out costs the one thing that makes a
  null dereference announce itself.
- **Bootloader-reclaimable memory is *not* reclaimed.** It is 39 MiB and worth
  having, but at the end of `mem.init` the kernel is still standing on three
  things inside it: the stack `kmain` is running on, every Limine response, and
  the memory map itself. `pmm_reclaim` is written and ready; it becomes callable
  once the scheduler is on a kernel stack of its own and anything wanted from
  the responses has been copied out.
- **All 256 higher-half top-level entries are pre-populated** at VMM init. A
  kernel mapping made after a user address space is created must appear in that
  address space too, and if the top-level entry did not exist at copy time it
  never will. Costs 1 MiB, paid once; buys never having to propagate a kernel
  mapping by hand. This is most of the "269 tables" in the boot log.
- **The kernel image is mapped a segment at a time**, with the permissions the
  linker script implies — text read-execute, rodata read-only, data read-write
  and no-execute — and `CR0.WP` is set, so they bind on supervisor writes too.
  Verified by reading the entries back out of the live tables, not by trusting
  the code that wrote them.
- **The direct map rounds outward; the PMM rounds inward.** Different jobs: the
  PMM must never hand out a frame that is partly somebody else's, and the direct
  map must never fail to map a page a structure straddles.
- **NX, global pages and 1 GiB leaves are all detected, not assumed.**
  `enable_paging_features` reads CPUID and records what took; `leaf_encode`
  silently drops a bit whose feature is off, so callers can ask unconditionally.
  On `-cpu qemu64` NX and PGE are present and 1 GiB pages are not, hence the
  2 MiB largest leaf in the boot log.
- **The framebuffer is added to the region list by hand if the map omitted it.**
  Base revision 6 guarantees the framebuffer is direct-mapped; it does not
  guarantee the firmware described it as a memory map entry. Getting that wrong
  kills the machine on the first character drawn after the CR3 switch — with the
  console being the thing that would have reported it.
- **Slab classes are 16 B … 2 KiB, powers of two**, one page per slab, free
  objects threaded through their own first eight bytes. Every allocation carries
  a 16-byte header immediately below the returned pointer holding a magic, the
  class (or "large"), the page count and the offset back to the block start.
  That header is what makes `free` a constant-time dispatch with no lookup
  structure, and what makes over-aligned allocation possible at all.
- **`free` checks the magic and clears it.** A pointer that did not come from
  `alloc` is ignored rather than acted on, and a double free fails the check
  instead of putting the same object on a free list twice. Leaking is the
  cheaper outcome.
- **`-default-to-nil-allocator` stays in the build.** `context.allocator` is
  installed at the very end of `kmain`, so an accidental allocation during early
  boot still returns nil and fails at its use, rather than quietly succeeding
  against a heap that does not exist yet.

## Known warts

- **The PMM has no lock.** The heap does — `sync.Spinlock`, taken by `alloc`,
  `free` and `resize` — but `pmm.odin`'s bitmap does not, because nothing
  allocates frames after boot. It needs one before the first AP comes up or the
  first interrupt handler allocates.
- **Slabs are never returned to the PMM.** Reclaiming one means proving every
  object in it is free, which means per-slab occupancy counts and a
  partial/full/empty chain per class. The fix belongs in `slab_grow`/`slab_free`,
  not in the callers.
- **`map_at` refuses to map over an existing mapping** rather than splitting a
  large page. Nothing yet needs to, and making it an error means that when
  something does, it says so instead of silently doing the wrong half of it.
- **The framebuffer is mapped write-back, not write-combining.** That needs PAT
  setup. It will matter to the compositor and does not matter yet.
- **1 MiB goes to higher-half page tables** at boot, most of it never touched.
  Deliberate — see the decision above — but it is the largest single line item in
  the kernel's own footprint.

## See also

- `docs/BOOT.md` — where the memory map and the HHDM come from.
- `docs/SYNC.md` — the heap's lock, and the rule about holding it across a wait.
