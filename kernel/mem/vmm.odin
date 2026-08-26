/*
The virtual memory manager: page tables, and the kernel address space built out
of them.

Limine hands the kernel a working set of page tables and then stops caring about
them; they live in bootloader-reclaimable memory, they map more than base
revision 6 promises on some machines and exactly what it promises on others, and
they are not ours to grow. So the first thing this file does is build a complete
replacement from scratch and switch to it. Everything the kernel is standing on
at that instant has to be in the new tables before CR3 is written -- the code
executing, the stack under it, the framebuffer, the Limine responses still being
read, and the page tables themselves -- which is what makes `vmm_init`'s order
the only one that works.

The walk is written once, against `arch`'s encoding primitives, and is not
amd64-specific: a radix tree of 512-entry tables indexed nine bits at a time,
with leaves permitted part-way up, describes aarch64's stage-1 tables and
riscv64's Sv39/Sv48 just as well.
*/
package mem

import "kernel:arch"

/*
Linker-defined bounds of the kernel image, one pair per loaded segment.

Taken from `kernel/link_amd64.ld` rather than restated here, because the whole
point is that the permissions installed below match the segment layout the
linker actually produced. `foreign` with no library: these have addresses and no
storage, and it is the address of each that is the value.
*/
foreign {
	__text_start: byte
	__text_end: byte
	__rodata_start: byte
	__rodata_end: byte
	__data_start: byte
	__data_end: byte
}

Address_Space :: struct {
	root: uintptr, // Physical address of the top-level table
}

@(private = "file") kernel_space: Address_Space
@(private = "file") table_frames: int
@(private = "file") mapped_bytes: u64

Vmm_Stats :: struct {
	root:         uintptr,
	table_frames: int, // Frames spent on the page tables themselves
	mapped_bytes: u64,
	nx:           bool,
	global:       bool,
	max_leaf:     int, // 1 = 4 KiB only, 2 = 2 MiB, 3 = 1 GiB
}

vmm_stats :: proc "contextless" () -> Vmm_Stats {
	return Vmm_Stats {
		root         = kernel_space.root,
		table_frames = table_frames,
		mapped_bytes = mapped_bytes,
		nx           = arch.nx_available(),
		global       = arch.global_available(),
		max_leaf     = arch.max_leaf_level(),
	}
}

// kernel_address_space is the one every kernel thread runs in, and the top half
// every future user address space will share.
kernel_address_space :: proc "contextless" () -> ^Address_Space {
	return &kernel_space
}

// -- Bring-up ----------------------------------------------------------------

/*
vmm_init builds the kernel address space and switches to it.

Order is the whole of the correctness argument:

  1. Turn on NX, global pages and CR0.WP *first*. Setting bit 63 of an entry
     before EFER.NXE is enabled makes it a reserved bit rather than a no-op, so
     every mapping installed would fault on first touch.
  2. Pre-populate all 256 higher-half top-level entries. A kernel mapping made
     after a user address space is created must appear in that address space
     too; if the top-level entry did not exist at copy time, it never will.
     256 pages is a megabyte, paid once, in exchange for never having to
     propagate a kernel mapping by hand.
  3. Map the kernel image a segment at a time, with the permissions the linker
     script implies -- text read-execute, rodata read-only, data read-write and
     no-execute. With CR0.WP now on, these are real.
  4. Map the direct map, covering exactly the region kinds base revision 6
     guarantees and nothing else.
  5. Only then write CR3.
*/
@(private)
vmm_init :: proc "contextless" (b: ^Boot_Memory) -> Error {
	arch.enable_paging_features()

	root, ok := alloc_page_zeroed()
	if !ok {
		return .Out_Of_Memory
	}
	table_frames += 1
	kernel_space.root = root

	if err := populate_higher_half(&kernel_space); err != .None {
		return err
	}
	if err := map_kernel_image(&kernel_space, b); err != .None {
		return err
	}
	if err := map_direct(&kernel_space, b); err != .None {
		return err
	}

	arch.load_address_space(kernel_space.root)
	return .None
}

/*
populate_higher_half gives every kernel top-level slot a table up front.

Indices TABLE_ENTRIES/2 and above are the higher half by definition of a
canonical address. Filling them now means creating a user address space is a
copy of those entries, and every kernel mapping made afterwards is shared
automatically rather than needing to be replayed into each address space.
*/
@(private = "file")
populate_higher_half :: proc "contextless" (space: ^Address_Space) -> Error {
	table := cast(^arch.Page_Table)phys_to_virt(space.root)
	for i in arch.TABLE_ENTRIES / 2 ..< arch.TABLE_ENTRIES {
		frame, ok := alloc_page_zeroed()
		if !ok {
			return .Out_Of_Memory
		}
		table_frames += 1
		// No `User` in the flags: these branches are kernel-only, and because
		// the hardware ANDs the user bit down the path, omitting it here seals
		// the whole higher half off from userland in one place.
		table[i] = arch.branch_encode(frame, {})
	}
	return .None
}

/*
map_kernel_image reproduces the mapping Limine made, with tighter permissions.

The image is contiguous in both spaces, so physical follows virtual by a fixed
displacement -- the difference between where the bootloader loaded us and where
we were linked to run. Each segment is mapped `Global`, because the kernel is
present in every address space and its translations should survive the CR3
reload of a context switch.
*/
@(private = "file")
map_kernel_image :: proc "contextless" (space: ^Address_Space, b: ^Boot_Memory) -> Error {
	slide := b.kernel_phys - b.kernel_virt

	segment :: proc "contextless" (
		space: ^Address_Space,
		slide: u64,
		start, end: ^byte,
		flags: arch.Page_Flags,
	) -> Error {
		first := align_down(u64(uintptr(start)), PAGE_SIZE)
		last := align_up(u64(uintptr(end)), PAGE_SIZE)
		if last <= first {
			return .None
		}
		return map_range(
			space,
			uintptr(first),
			uintptr(first + slide),
			last - first,
			flags + {.Global},
		)
	}

	// Read-execute. Not writable, which is the point of splitting the segments
	// at all: with CR0.WP set, a stray write through a kernel pointer into the
	// text lands as a fault instead of as self-modifying code.
	if err := segment(space, slide, &__text_start, &__text_end, {}); err != .None {
		return err
	}
	// Read-only, no execute. Carries .rela, which the bootloader has already
	// applied by the time we run.
	if err := segment(space, slide, &__rodata_start, &__rodata_end, {.No_Execute});
	   err != .None {
		return err
	}
	// Read-write, no execute. Includes .limine_requests, which the bootloader
	// wrote response pointers into and which must stay writable.
	if err := segment(space, slide, &__data_start, &__data_end, {.Write, .No_Execute});
	   err != .None {
		return err
	}
	return .None
}

/*
map_direct builds the higher-half direct map.

Every region the boot protocol guarantees is HHDM-mapped gets mapped, and
nothing else -- `hhdm_mapped` is the single place that list is written down. The
mapping is read-write and never executable: the direct map exists so the kernel
can reach physical memory as data, and an executable alias of the whole of RAM
would undo the segment permissions installed just above it.

Region bounds are rounded outward here, unlike in the PMM. The PMM rounds inward
because it must not hand out a frame that is partly somebody else's; the direct
map rounds outward because failing to map the page a structure straddles makes
that structure unreadable.
*/
@(private = "file")
map_direct :: proc "contextless" (space: ^Address_Space, b: ^Boot_Memory) -> Error {
	for r in regions(b) {
		if !hhdm_mapped(r.kind) {
			continue
		}
		first := align_down(r.base, PAGE_SIZE)
		last := align_up(r.base + r.length, PAGE_SIZE)
		err := map_range(
			space,
			uintptr(b.hhdm + first),
			uintptr(first),
			last - first,
			{.Write, .No_Execute, .Global},
		)
		if err != .None {
			return err
		}
	}
	return .None
}

/*
vmm_verify re-reads the kernel image's own mappings and checks they say what the
linker script meant them to say.

Worth doing because the alternative way to find out is to fault, and until
Vectra has an IDT a fault is a triple fault with nothing to show for it. It is
also the only check of `map_kernel_image` that is not circular: everything else
compares what was written against what the same code intended to write, whereas
this walks the tree the hardware will walk and reads the entry the hardware will
read.

Global is required where the CPU supports it. It is a correctness matter and not
a tuning one -- the kernel is present in every address space, so a kernel
mapping that is not global gets flushed and re-walked on every context switch
that will ever happen.
*/
vmm_verify :: proc "contextless" () -> bool {
	check :: proc "contextless" (byte_in_segment: ^byte, want, forbid: arch.Page_Flags) -> bool {
		flags, ok := permissions(&kernel_space, uintptr(byte_in_segment))
		if !ok {
			return false
		}
		return want <= flags && flags & forbid == {}
	}

	nx: arch.Page_Flags = arch.nx_available() ? {.No_Execute} : {}
	glob: arch.Page_Flags = arch.global_available() ? {.Global} : {}

	// Text: executable, and never writable. The pair is the point -- either one
	// alone is a mapping through which the kernel can rewrite itself.
	if !check(&__text_start, glob, {.Write, .No_Execute, .User}) {
		return false
	}
	// Rodata: neither writable nor executable.
	if !check(&__rodata_start, glob + nx, {.Write, .User}) {
		return false
	}
	// Data: writable, and never executable.
	if !check(&__data_start, glob + nx + {.Write}, {.User}) {
		return false
	}
	return true
}

// -- Mapping -----------------------------------------------------------------

/*
map_range maps `size` bytes, using the largest leaf that fits at each step.

Leaf size is chosen per step rather than once, so a range that begins misaligned
is mapped in 4 KiB pages until it reaches a 2 MiB boundary and in 2 MiB pages
after that. This is not an optimisation for its own sake: the direct map spans
the whole of physical memory, and at 4 KiB granularity the tables to describe it
would cost more memory than most of what they describe.
*/
map_range :: proc "contextless" (
	space: ^Address_Space,
	virt, phys: uintptr,
	size: u64,
	flags: arch.Page_Flags,
) -> Error {
	offset := u64(0)
	for offset < size {
		v := virt + uintptr(offset)
		p := phys + uintptr(offset)
		remaining := size - offset

		level := 1
		for l := arch.max_leaf_level(); l > 1; l -= 1 {
			span := u64(arch.level_size(l))
			if remaining >= span && is_aligned(u64(v), span) && is_aligned(u64(p), span) {
				level = l
				break
			}
		}

		if err := map_at(space, v, p, flags, level); err != .None {
			return err
		}
		offset += u64(arch.level_size(level))
	}
	mapped_bytes += size
	return .None
}

/*
map_at installs a single leaf of `level`'s size, growing the tree to reach it.

Walking down from the top, a missing branch is allocated and zeroed and an
existing leaf encountered above the target level is an error rather than
something to split: splitting a large page means allocating a table, filling in
512 entries and shooting down the TLB, and nothing in Vectra yet has a reason to
map over a range it already mapped. Making it an error means that when something
does, it says so.
*/
map_at :: proc "contextless" (
	space: ^Address_Space,
	virt, phys: uintptr,
	flags: arch.Page_Flags,
	level: int,
) -> Error {
	if !arch.is_canonical(virt) {
		return .Not_Canonical
	}

	table := cast(^arch.Page_Table)phys_to_virt(space.root)
	for l := arch.TABLE_LEVELS; l > level; l -= 1 {
		index := arch.table_index(virt, l)
		entry := table[index]

		if !arch.entry_present(entry) {
			frame, ok := alloc_page_zeroed()
			if !ok {
				return .Out_Of_Memory
			}
			table_frames += 1
			entry = arch.branch_encode(frame, flags)
			table[index] = entry
		} else if arch.entry_is_leaf(entry, l) {
			return .Mapping_Conflict
		}

		table = cast(^arch.Page_Table)phys_to_virt(arch.entry_address(entry))
	}

	index := arch.table_index(virt, level)
	if arch.entry_present(table[index]) {
		return .Mapping_Conflict
	}
	table[index] = arch.leaf_encode(phys, flags, level)
	return .None
}

/*
map_mmio brings a device's register page into the direct map.

Mapped at its natural HHDM address rather than somewhere arbitrary, so
`phys_to_virt` keeps telling the truth about it and a driver holding a physical
address from a table can find its registers without a second lookup.

`.No_Cache` is not optional and neither is the flush. A cached mapping of a
device turns a status register into a value read once and remembered, and a
stale negative TLB entry from before this call turns the first access into a
fault -- both of which present as hardware that does not respond.

Always 4 KiB leaves: MMIO ranges are page-granular, rarely large, and a 2 MiB
leaf here would map whatever the firmware put next to the device.
*/
map_mmio :: proc "contextless" (phys: uintptr, size: u64) -> (rawptr, Error) {
	base := align_down(u64(phys), u64(arch.PAGE_SIZE))
	offset := u64(phys) - base
	pages := page_count(offset + size)

	virt := uintptr(phys_to_virt(uintptr(base)))
	flags := arch.Page_Flags{.Write, .No_Cache, .No_Execute}

	for i in 0 ..< pages {
		step := uintptr(i) * uintptr(arch.PAGE_SIZE)
		if err := map_at(&kernel_space, virt + step, uintptr(base) + step, flags, 1); err != .None {
			return nil, err
		}
		arch.flush_page(virt + step)
	}
	return rawptr(virt + uintptr(offset)), .None
}

/*
unmap_page clears one leaf and shoots down its translation.

The tables it walked through are left in place. Freeing an emptied table means
counting live entries on every unmap and re-checking every level above it, which
buys back one page at a time from a tree that is a rounding error against what
it maps; when Vectra tears down user address spaces it will free the whole tree
at once instead.
*/
unmap_page :: proc "contextless" (space: ^Address_Space, virt: uintptr) -> bool {
	table := cast(^arch.Page_Table)phys_to_virt(space.root)

	for l := arch.TABLE_LEVELS; l >= 1; l -= 1 {
		index := arch.table_index(virt, l)
		entry := table[index]
		if !arch.entry_present(entry) {
			return false
		}
		if arch.entry_is_leaf(entry, l) {
			table[index] = arch.ENTRY_EMPTY
			arch.flush_page(virt)
			return true
		}
		table = cast(^arch.Page_Table)phys_to_virt(arch.entry_address(entry))
	}
	return false
}

/*
translate resolves a virtual address the way the hardware would.

Stops at whichever level holds the leaf and adds the offset within it, so a
2 MiB mapping resolves an address 1 MiB into itself correctly. This is the
answer to "what is actually mapped here", which `virt_to_phys` -- a subtraction
that assumes the direct map -- is not.
*/
translate :: proc "contextless" (space: ^Address_Space, virt: uintptr) -> (phys: uintptr, ok: bool) {
	entry, level, found := lookup(space, virt)
	if !found {
		return 0, false
	}
	offset := u64(virt) & (u64(arch.level_size(level)) - 1)
	return arch.entry_address(entry) + uintptr(offset), true
}

/*
permissions reports what the mapping covering `virt` actually allows.

Reads the leaf rather than remembering what was asked for, which is the only
version worth having: it is what a page fault handler needs to tell a protection
violation from an absent page, and it is what makes "the kernel's text is not
writable" a fact that can be checked instead of a claim in a comment.

Note that this is the leaf's own permission, not the effective one. The hardware
ANDs `Write` and `User` down the whole path and ORs `No_Execute`, so a leaf can
be more permissive than the translation it belongs to. Everything Vectra builds
keeps its branches maximally permissive precisely so the leaf is the answer.
*/
permissions :: proc "contextless" (space: ^Address_Space, virt: uintptr) -> (arch.Page_Flags, bool) {
	entry, _, found := lookup(space, virt)
	if !found {
		return {}, false
	}
	return arch.entry_flags(entry), true
}

// lookup walks to whichever entry terminates `virt`'s translation, reporting
// the level it stopped at so the caller can size the page it found.
@(private = "file")
lookup :: proc "contextless" (
	space: ^Address_Space,
	virt: uintptr,
) -> (
	entry: arch.Page_Table_Entry,
	level: int,
	ok: bool,
) {
	table := cast(^arch.Page_Table)phys_to_virt(space.root)

	for l := arch.TABLE_LEVELS; l >= 1; l -= 1 {
		e := table[arch.table_index(virt, l)]
		if !arch.entry_present(e) {
			return {}, 0, false
		}
		if arch.entry_is_leaf(e, l) {
			return e, l, true
		}
		table = cast(^arch.Page_Table)phys_to_virt(arch.entry_address(e))
	}
	return {}, 0, false
}
