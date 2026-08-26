# Physical memory, page tables, and the heap

`kernel/mem/` — `mem.odin`, `pmm.odin`, `vmm.odin`, `heap.odin`

Three layers. Each one can be written with no knowledge of the internals of the
layer below it:

- a bitmap frame allocator over the firmware's memory map
- a page table walker that owns the kernel's address space
- a slab allocator behind `context.allocator`

`kernel/arch` owns the page table *encoding*. This package owns the *walk*. That
split is what makes the other two architectures a matter of blanks to fill in.

Nothing here allocates after boot except the heap, which is why `pmm.odin` has
no lock and the heap has one.

## Decisions, and what would reverse them

- **Base revision 6's HHDM is restrictive** — only usable,
  bootloader-reclaimable, executable, framebuffer, reserved-mapped, ACPI
  reclaimable and ACPI NVS regions are mapped. **The VMM must respect this.**
  `check_base_revision()` currently only *warns* on a mismatch. Make it a hard
  stop as soon as anything dereferences an HHDM address.
- **`arch` owns the page table *encoding*. `kernel/mem` owns the *walk*.** This
  is where the "only CPU-facing import" rule landed for paging. `arch` supplies
  `table_index`, `level_size`, `leaf_encode`, `branch_encode`, `entry_flags` and
  friends. `vmm.odin` implements the descend-and-allocate loop once against
  them. The walk genuinely is not amd64-specific. aarch64's stage-1 tables and
  riscv64's Sv39/Sv48 are the same radix tree, nine bits at a stride. A port
  therefore supplies an encoding rather than a second walker.
- **Bitmap PMM, not a free list.** A free list has to live in the pages it
  tracks, so one stray write corrupts the allocator itself. Contiguous
  multi-page allocation is a run search over a bitmap, against a linear walk
  over a list. Page tables and large heap blocks both need it. The cost is a
  scan. A rotating hint bounds it, and so does a skip over fully-taken bytes,
  eight frames at a time.
- **The bitmap indexes from physical zero**, holes included, so `phys /
  PAGE_SIZE` is the index with nothing to subtract. Hole frames are born taken
  and never freed. It is 15 KiB on this machine.
- **Frame 0 is reserved forever.** Base revision 6 lets the firmware call the
  page at physical zero usable. The kernel never hands it to a caller, because
  that costs the one thing that makes a null dereference announce itself.
- **Bootloader-reclaimable memory is *not* reclaimed.** It is 39 MiB and worth
  the effort. But at the end of `mem.init` the kernel still stands on three
  things inside it. Those are the stack `kmain` runs on, every Limine response,
  and the memory map itself. `pmm_reclaim` is written and ready. It becomes
  callable once two things are true. The scheduler must stand on a kernel stack
  of its own, and anything the kernel wants from the responses must already sit
  somewhere else.
- **All 256 higher-half top-level entries are pre-populated** at VMM init. A
  kernel mapping made after a user address space is created must appear in that
  address space too. If the top-level entry did not exist at copy time, it never
  will. It costs 1 MiB, paid once. In return, nothing ever has to propagate a
  kernel mapping by hand. This is most of the `269 tables` in the boot log.
- **The kernel image is mapped a segment at a time**, with the permissions the
  linker script implies. Text is read-execute, rodata is read-only, and data is
  read-write and no-execute. `CR0.WP` is set, so they bind on supervisor writes
  too. The check reads the entries back out of the live tables, rather than
  trust the code that wrote them.
- **The direct map rounds outward. The PMM rounds inward.** The jobs are
  different. The PMM must never hand a caller a frame that is partly somebody
  else's. The direct map must never fail to map a page that a structure
  straddles.
- **NX, global pages and 1 GiB leaves are all detected, not assumed.**
  `enable_paging_features` reads CPUID and records what took. `leaf_encode`
  silently drops a bit whose feature is off, so callers can ask unconditionally.
  On `-cpu qemu64` NX and PGE are present and 1 GiB pages are not, hence the
  2 MiB largest leaf in the boot log.
- **The framebuffer is added to the region list by hand if the map omitted it.**
  Base revision 6 guarantees the framebuffer is direct-mapped. It does not
  guarantee the firmware described it as a memory map entry. An error there
  kills the machine on the first character drawn after the CR3 switch. The
  console is the thing that would have reported it.
- **Slab classes are 16 B … 2 KiB, powers of two**, one page per slab, free
  objects threaded through their own first eight bytes. Every allocation carries
  a 16-byte header immediately below the returned pointer. The header holds a
  magic, the class (or `large`), the page count, and the offset back to the
  block start.
  That header is what makes `free` a constant-time dispatch with no lookup
  structure, and what makes over-aligned allocation possible at all.
- **`free` checks the magic and clears it.** A pointer that did not come from
  `alloc` is ignored rather than acted on. A double free fails the check.
  Without that check, the same object would go on a free list twice. A leak is
  the cheaper outcome.
- **`-default-to-nil-allocator` stays in the build.** `context.allocator` is
  installed at the very end of `kmain`. An accidental allocation during early
  boot therefore still returns nil, and fails at its use. It does not quietly
  succeed against a heap that does not exist yet.

## Known warts

- **The PMM has no lock.** The heap does. That lock is a `sync.Spinlock`, taken
  by `alloc`, `free` and `resize`. `pmm.odin`'s bitmap does not, because nothing
  allocates frames after boot. It needs one before the first AP starts, or
  before the first interrupt handler allocates.
- **Slabs are never returned to the PMM.** A reclaim of one means proof that
  every object in it is free. That means per-slab occupancy counts, and a
  partial/full/empty chain per class. The fix belongs in `slab_grow` and
  `slab_free`, not in the callers.
- **`map_at` refuses to map over an existing mapping**, rather than split a
  large page. Nothing yet needs to. The error means that when something does
  need to, it says so, rather than silently do the wrong half of it.
- **The framebuffer is mapped write-back, not write-combining.** That needs PAT
  setup. It will matter to the compositor and does not matter yet.
- **1 MiB goes to higher-half page tables** at boot, most of it never touched.
  Deliberate — see the decision above — but it is the largest single line item in
  the kernel's own footprint.

## See also

- `docs/BOOT.md` — where the memory map and the HHDM come from.
- `docs/SYNC.md` — the heap's lock, and the rule about holding it across a wait.
