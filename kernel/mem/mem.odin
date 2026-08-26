/*
Vectra memory management.

Three layers, each built on the one below and each usable on its own:

  - `pmm.odin`  -- a bitmap of every physical page, handing out page frames
  - `vmm.odin`  -- 4-level (or 3-, or 5-) page tables built from those frames
  - `heap.odin` -- slab allocator over the two, wired into `context.allocator`
                   so that ordinary Odin `new`/`make` start working

Nothing in this package knows about the boot protocol. `Boot_Memory` is the
whole of what the kernel has to tell it, and `kernel/main.odin` -- which is the
file that owns the Limine requests -- is what fills that in. Booting Vectra some
other way means writing a different translation there, not touching anything
here.

The physical and virtual distinction is load-bearing throughout, and the types
carry it. A `uintptr` in this package is always physical. A `rawptr`, or a
typed pointer, is always virtual. `phys_to_virt` is the only bridge, and it
goes through the HHDM, which under Limine base revision 6 does not cover
everything. `hhdm_mapped` is what says which regions it does.
*/
package mem

import "kernel:arch"

PAGE_SIZE :: arch.PAGE_SIZE
PAGE_MASK :: PAGE_SIZE - 1

// -- Alignment ---------------------------------------------------------------
//
// `align` is always a power of two here. A general version would need a
// divide, and every alignment in a memory manager is a page, a cache line or a
// size class.

align_down :: proc "contextless" (value: u64, align: u64) -> u64 {
	return value &~ (align - 1)
}

align_up :: proc "contextless" (value: u64, align: u64) -> u64 {
	return (value + align - 1) &~ (align - 1)
}

is_aligned :: proc "contextless" (value: u64, align: u64) -> bool {
	return value & (align - 1) == 0
}

// page_count returns how many pages a byte count spans, rounding up.
page_count :: proc "contextless" (bytes: u64) -> u64 {
	return align_up(bytes, PAGE_SIZE) / PAGE_SIZE
}

// -- What the bootloader handed us -------------------------------------------

/*
The kinds of physical memory the kernel distinguishes.

These are Limine's memory map types, minus the ones nothing can use. What
separates them is *what a caller may do to them*, rather than where they came
from:

  - Usable            free for the PMM to hand out
  - Reclaimable       bootloader structures, readable, and free once nothing
                      needs anything in them (see `pmm_reclaim`)
  - Executable        the kernel image and its modules, never allocatable
  - Framebuffer,
    ACPI_Reclaimable,
    ACPI_NVS,
    Reserved_Mapped   not allocatable, but HHDM-mapped and legal to read
  - Unmapped          reserved or bad, not allocatable, not mapped, and
                      undefined to dereference through the HHDM
*/
Region_Kind :: enum u8 {
	Usable,
	Reclaimable,
	Executable,
	Framebuffer,
	ACPI_Reclaimable,
	ACPI_NVS,
	Reserved_Mapped,
	Unmapped,
}

/*
hhdm_mapped reports whether the higher-half direct map covers this kind.

Base revision 6 tightened the HHDM from "all of physical memory" to exactly
this list. An error here is not a fault at map time. It is a fault much later,
in whatever code eventually dereferences the address, with nothing left to name
the bad assumption.
*/
hhdm_mapped :: proc "contextless" (kind: Region_Kind) -> bool {
	#partial switch kind {
	case .Unmapped:
		return false
	}
	return true
}

// allocatable reports whether the PMM may hand pages of this kind out. Note
// that Reclaimable is *not* allocatable until something explicitly reclaims
// it.
allocatable :: proc "contextless" (kind: Region_Kind) -> bool {
	return kind == .Usable
}

Region :: struct {
	base:   u64,
	length: u64,
	kind:   Region_Kind,
}

// A firmware memory map is a few dozen entries. 128 is slack enough that
// nothing has ever taken the overflow path below. It is also small enough to
// stay a static array in .bss, rather than the allocator's first customer.
MAX_REGIONS :: 128

Boot_Memory :: struct {
	regions:      [MAX_REGIONS]Region,
	region_count: int,
	dropped:      int, // Entries that did not fit; a hard error, not a warning

	hhdm:        u64,
	kernel_phys: u64,
	kernel_virt: u64,
}

// add_region appends one entry, counting rather than truncating silently if the
// map is bigger than MAX_REGIONS. Zero-length entries are dropped: they carry
// no information and would only complicate every loop that walks the map.
add_region :: proc "contextless" (b: ^Boot_Memory, base, length: u64, kind: Region_Kind) {
	if length == 0 {
		return
	}
	if b.region_count >= MAX_REGIONS {
		b.dropped += 1
		return
	}
	b.regions[b.region_count] = Region{base = base, length = length, kind = kind}
	b.region_count += 1
}

regions :: proc "contextless" (b: ^Boot_Memory) -> []Region {
	return b.regions[:b.region_count]
}

/*
covers reports whether one HHDM-mapped region already contains a whole range.

The caller is `kernel/main.odin`, checking whether the framebuffer needs adding
by hand. Base revision 6 guarantees the framebuffer *is* direct-mapped. It does
not guarantee the firmware described it as an entry in the map. The difference
between those two shows up only as a fault, on the first character drawn after
the address space switch.

Deliberately not a range-merging check: a range spanning two adjacent regions
answers false and gets added again. For the one caller there is, a false
negative costs a duplicate entry and a true negative costs the console.
*/
covers :: proc "contextless" (b: ^Boot_Memory, base, length: u64) -> bool {
	for r in regions(b) {
		if !hhdm_mapped(r.kind) {
			continue
		}
		if base >= r.base && base + length <= r.base + r.length {
			return true
		}
	}
	return false
}

// -- The higher-half direct map ----------------------------------------------

@(private)
hhdm_offset: u64

hhdm :: proc "contextless" () -> u64 {
	return hhdm_offset
}

/*
phys_to_virt maps a physical address into the direct map.

Valid only for addresses inside a region whose kind `hhdm_mapped` accepts.
There is no check here, because this is on the path of every page table write
and every slab carve. The discipline is that callers get their physical
addresses from the PMM, and the PMM only ever hands out mapped pages.
*/
phys_to_virt :: proc "contextless" (phys: uintptr) -> rawptr {
	return rawptr(uintptr(u64(phys) + hhdm_offset))
}

// virt_to_phys inverts phys_to_virt. Only valid for direct-map addresses --
// a kernel-image or future userland pointer needs a page table walk instead
// (`vmm_translate`).
virt_to_phys :: proc "contextless" (virt: rawptr) -> uintptr {
	return uintptr(u64(uintptr(virt)) - hhdm_offset)
}

// is_direct_map reports whether `virt` looks like an HHDM address, which is the
// precondition virt_to_phys cannot check for itself.
is_direct_map :: proc "contextless" (virt: rawptr) -> bool {
	return u64(uintptr(virt)) >= hhdm_offset
}

// -- Bring-up ----------------------------------------------------------------

Error :: enum {
	None,
	No_Usable_Memory,    // The map contained nothing the PMM could own
	Bitmap_Wont_Fit,     // No single usable region large enough for the bitmap
	Region_Map_Overflow, // More entries than MAX_REGIONS; the map is incomplete
	Out_Of_Memory,       // Ran dry -- no free frame for a page table or a slab
	Not_Canonical,       // A virtual address the CPU will not accept
	Mapping_Conflict,    // Something is already mapped over the requested range
}

// describe turns an Error into something a boot log can print, since there is
// no `fmt` down here and an enum prints as its ordinal.
describe :: proc "contextless" (err: Error) -> string {
	switch err {
	case .None:                return "no error"
	case .No_Usable_Memory:    return "memory map contains no usable region"
	case .Bitmap_Wont_Fit:     return "no usable region large enough for the page bitmap"
	case .Region_Map_Overflow: return "memory map has more entries than MAX_REGIONS"
	case .Out_Of_Memory:       return "out of physical memory"
	case .Not_Canonical:       return "non-canonical virtual address"
	case .Mapping_Conflict:    return "address range is already mapped"
	}
	return "unknown error"
}

/*
init brings up all three layers, in the only order that works.

The PMM has to exist before the VMM, because page tables are made of pages. The
VMM has to be live before the heap. A slab is a page reached through the direct
map, and the direct map is not ours until the kernel is on its own tables. And
the heap has to come last, because it is the only one of the three that may
fail gracefully. A failure in either of the other two means the kernel has
nowhere to live.

After this returns `.None`, `context.allocator` is real and ordinary Odin data
structures work.
*/
init :: proc "contextless" (b: ^Boot_Memory) -> Error {
	if b.dropped > 0 {
		return .Region_Map_Overflow
	}
	hhdm_offset = b.hhdm

	if err := pmm_init(b); err != .None {
		return err
	}
	if err := vmm_init(b); err != .None {
		return err
	}
	heap_init()
	return .None
}
