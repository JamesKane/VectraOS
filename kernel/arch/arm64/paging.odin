/*
The arm64 page table format: 4-level, 4 KiB granule, 48-bit addresses.

This file knows the shape of a stage 1 translation table and nothing about
policy. `kernel/mem/vmm.odin` owns the walk and calls through these to encode
what it decides. The walk is the same radix tree amd64 has: 512 entries of
eight bytes, nine bits of address per level, leaves allowed part-way up.
Level numbering runs downward as it does there, so level 4 is the L0 table
the base registers name, and level 1 is the L3 table whose entries are
4 KiB pages.

## Two base registers, and how one root serves both

The architecture splits the address space in two, with a translation table
base register for each half: `TTBR0_EL1` for addresses whose top bits are
zero, `TTBR1_EL1` for those whose top bits are one. The portable VMM has one
root table per address space, and it puts the kernel half in entries 256 and
up. Both are satisfied at once:

    TTBR1_EL1   the kernel space's root, always. `T1SZ` is 16, so a kernel
                address indexes all 512 entries of it; the higher half's
                entries 256..511 are where the VMM puts the kernel image,
                and the bootloader's direct map lands in the lower 256,
                which no user address can reach because...
    TTBR0_EL1   a user space's root, with `T0SZ` 17. A user address has
                47 bits, and indexes only entries 0..255 of the table it
                names. Entries 256..511 of a user root are the copy the
                VMM makes of the kernel's, and nothing walks them here.

So a context switch writes TTBR0, and TTBR1 is written once. A kernel
mapping made after a process exists is visible to that process without any
copy, which is one better than amd64. What a kernel thread gets in TTBR0 is
the early window `early.odin` built: one device page and nothing else, so a
null dereference in the kernel still faults.

## The bootloader's direct map

Limine's higher-half direct map starts at `0xffff_0000_0000_0000` on this
architecture, plus a randomised slide of up to a quarter of the half. That
is the *low* quarter of the TTBR1 table -- entries 0..127 -- and it is why
`is_canonical` accepts a 48-bit kernel address rather than the 47-bit form
amd64 does. The VMM's higher-half pre-population covers entries 256 and up;
the direct map's tables below that are made on demand, in the kernel root,
and TTBR1 is the kernel root everywhere, so nothing is lost.
*/
package arm64

PAGE_SHIFT :: 12
PAGE_SIZE :: 1 << PAGE_SHIFT

TABLE_BITS :: 9
TABLE_ENTRIES :: 1 << TABLE_BITS
TABLE_LEVELS :: 4

Page_Table_Entry :: distinct u64
Page_Table :: [TABLE_ENTRIES]Page_Table_Entry

// The neutral flags, the same six on every architecture. See the amd64 file
// for why `No_Execute` is spelt as a restriction.
Page_Flag :: enum u8 {
	Write,
	User,
	No_Execute,
	Global,
	No_Cache,
	Write_Through,
}

Page_Flags :: bit_set[Page_Flag; u8]

// -- Descriptor bits ----------------------------------------------------------

PTE_VALID    :: u64(1) << 0
PTE_TABLE    :: u64(1) << 1 // Above level 1: next table, not a block. At level 1: a page.
PTE_ATTR_SHIFT :: 2         // MAIR index, bits 4:2
PTE_AP_EL0   :: u64(1) << 6 // Accessible from EL0
PTE_AP_RO    :: u64(1) << 7 // Read-only, at every level that may read it
PTE_SH_INNER :: u64(3) << 8 // Inner shareable, which is every core
PTE_AF       :: u64(1) << 10 // Access flag: set, or the first touch faults
PTE_NG       :: u64(1) << 11 // Not global: an ASID-tagged translation
PTE_PXN      :: u64(1) << 53 // Privileged execute-never
PTE_UXN      :: u64(1) << 54 // Unprivileged execute-never

PTE_ADDR_MASK :: u64(0x0000_FFFF_FFFF_F000)

/*
The memory attribute indirection register, and the four indices this kernel
uses. Normal write-back is index 0, which is also what the bootloader put
there, so its tables and ours agree on the one attribute both use.
`Write_Through` maps to normal non-cacheable, the nearest thing the
architecture has for a framebuffer. `No_Cache` is device memory, with early
write acknowledgement, which is what a register file wants.
*/
MAIR_NORMAL_WB :: u64(0xFF)
MAIR_NORMAL_NC :: u64(0x44)
MAIR_DEVICE    :: u64(0x04) // Device-nGnRE

ATTR_NORMAL :: u64(0)
ATTR_NORMAL_NC :: u64(1)
ATTR_DEVICE :: u64(2)

MAIR_VALUE :: MAIR_NORMAL_WB | MAIR_NORMAL_NC << 8 | MAIR_DEVICE << 16

// The translation control register, as `enable_paging_features` writes it.
// See the file comment for `T0SZ` and `T1SZ`. Both halves are 4 KiB granule,
// inner shareable, write-back allocate. `IPS` is filled in from what the CPU
// reports it can address.
TCR_T0SZ :: u64(17)
TCR_T1SZ :: u64(16) << 16
TCR_IRGN0_WB :: u64(1) << 8
TCR_ORGN0_WB :: u64(1) << 10
TCR_SH0_INNER :: u64(3) << 12
TCR_TG0_4K :: u64(0) << 14
TCR_IRGN1_WB :: u64(1) << 24
TCR_ORGN1_WB :: u64(1) << 26
TCR_SH1_INNER :: u64(3) << 28
TCR_TG1_4K :: u64(2) << 30
TCR_IPS_SHIFT :: 32
TCR_EPD0 :: u64(1) << 7

TCR_VALUE :: TCR_T0SZ | TCR_T1SZ | TCR_IRGN0_WB | TCR_ORGN0_WB | TCR_SH0_INNER | TCR_TG0_4K | TCR_IRGN1_WB | TCR_ORGN1_WB | TCR_SH1_INNER | TCR_TG1_4K

// The kernel space's root, learnt on the first `load_address_space`, which
// the VMM makes with the kernel's own space and makes first. Zero until then.
@(private = "file") kernel_root: uintptr

/*
enable_paging_features programs the attributes and the translation control
this file's encodings assume.

MAIR first, because an entry names an index into it. TCR next, and only
`T0SZ` changes from what the bootloader set -- the kernel half keeps its 48
bits, so the code running this line keeps translating. The physical address
size comes from `ID_AA64MMFR0_EL1.PARange`, capped at 48 bits, which is what
a 4-level table can name. Every feature this file encodes -- execute-never in
both privilege levels, non-global entries, 1 GiB blocks -- is architectural,
so there is nothing to detect.
*/
enable_paging_features :: proc "contextless" () {
	write_mair(MAIR_VALUE)
	ips := read_mmfr0() & 0xF
	if ips > 5 {
		ips = 5
	}
	write_tcr(TCR_VALUE | ips << TCR_IPS_SHIFT)
	isb()
	tlbi_all()
}

nx_available :: proc "contextless" () -> bool {
	return true
}

global_available :: proc "contextless" () -> bool {
	return true
}

// Level 3 is a 1 GiB block, which the 4 KiB granule allows at L1.
max_leaf_level :: proc "contextless" () -> int {
	return 3
}

// -- Address arithmetic -------------------------------------------------------

table_index :: proc "contextless" (virt: uintptr, level: int) -> int {
	shift := uint(PAGE_SHIFT + TABLE_BITS * (level - 1))
	return int((u64(virt) >> shift) & u64(TABLE_ENTRIES - 1))
}

level_size :: proc "contextless" (level: int) -> uintptr {
	return uintptr(1) << uint(PAGE_SHIFT + TABLE_BITS * (level - 1))
}

/*
is_canonical reports whether `virt` is a form the two base registers accept.

A user address has 47 bits, so bits 63..47 must be zero. A kernel address has
48, so bits 63..48 must be one. The gap between them is the hole, and
`0xffff_0000_...` is inside the kernel half here, which is where the
bootloader put the direct map. See the file comment.
*/
is_canonical :: proc "contextless" (virt: uintptr) -> bool {
	v := u64(virt)
	return v >> 47 == 0 || v >> 48 == 0xFFFF
}

// -- Entry encoding -----------------------------------------------------------

/*
leaf_encode builds an entry that terminates a walk at `level`.

A page at level 1 carries the table bit, a block above it does not; that is
the one place the architecture's descriptor format and the amd64 one
disagree about which bit means `stop here`. The access flag is set, because
an entry without it faults on first touch rather than being used.

Execute permission is two bits, one per privilege level, and the neutral
`No_Execute` sets both. Beyond that, a kernel page is never executable from
EL0 and a program's page is never executable from EL1, whatever the caller
asked, because there is no reason either should be and every reason neither
should. A program's page is also not global: it belongs to one address
space, and the translation says so.
*/
leaf_encode :: proc "contextless" (phys: uintptr, flags: Page_Flags, level: int) -> Page_Table_Entry {
	e := (u64(phys) & PTE_ADDR_MASK) | PTE_VALID | PTE_AF | PTE_SH_INNER
	if level == 1 {
		e |= PTE_TABLE
	}

	attr := ATTR_NORMAL
	if .No_Cache in flags {
		attr = ATTR_DEVICE
	} else if .Write_Through in flags {
		attr = ATTR_NORMAL_NC
	}
	e |= attr << PTE_ATTR_SHIFT

	if .Write not_in flags {
		e |= PTE_AP_RO
	}
	if .User in flags {
		e |= PTE_AP_EL0 | PTE_NG | PTE_PXN
	} else {
		e |= PTE_UXN
	}
	if .No_Execute in flags {
		e |= PTE_PXN | PTE_UXN
	}
	return Page_Table_Entry(e)
}

// branch_encode builds an entry pointing at the next table down. No
// hierarchical permission bits, so every restriction is at the leaf and a
// branch is as permissive as amd64's.
branch_encode :: proc "contextless" (phys: uintptr, flags: Page_Flags) -> Page_Table_Entry {
	_ = flags
	return Page_Table_Entry((u64(phys) & PTE_ADDR_MASK) | PTE_VALID | PTE_TABLE)
}

entry_present :: proc "contextless" (e: Page_Table_Entry) -> bool {
	return u64(e) & PTE_VALID != 0
}

// entry_is_leaf reports whether a walk stops at this entry. Level 1 entries
// are always leaves. Above that, a clear table bit means a block.
entry_is_leaf :: proc "contextless" (e: Page_Table_Entry, level: int) -> bool {
	return level == 1 || u64(e) & PTE_TABLE == 0
}

entry_address :: proc "contextless" (e: Page_Table_Entry) -> uintptr {
	return uintptr(u64(e) & PTE_ADDR_MASK)
}

/*
entry_flags decodes an entry back into the neutral flags, the inverse of
`leaf_encode`. `No_Execute` is answered for the level that owns the page: a
kernel page is executable when PXN is clear, a program's when UXN is.
*/
entry_flags :: proc "contextless" (e: Page_Table_Entry) -> Page_Flags {
	flags: Page_Flags
	v := u64(e)

	if v & PTE_AP_RO == 0 {
		flags += {.Write}
	}
	user := v & PTE_AP_EL0 != 0
	if user {
		flags += {.User}
	}
	if (user && v & PTE_UXN != 0) || (!user && v & PTE_PXN != 0) {
		flags += {.No_Execute}
	}
	if v & PTE_NG == 0 {
		flags += {.Global}
	}
	switch (v >> PTE_ATTR_SHIFT) & 7 {
	case ATTR_DEVICE:    flags += {.No_Cache}
	case ATTR_NORMAL_NC: flags += {.Write_Through}
	}
	return flags
}

ENTRY_EMPTY :: Page_Table_Entry(0)

// -- Address space switching and TLB --------------------------------------------

/*
load_address_space makes `root` the space the CPU translates through.

The first root loaded is the kernel's, and it goes into TTBR1 for good. Every
load writes TTBR0: a user root as itself, the kernel root as the early
window, so that a kernel thread's lower half holds one device page and
nothing a stray pointer could land on. See the file comment.
*/
load_address_space :: proc "contextless" (root: uintptr) {
	if kernel_root == 0 {
		kernel_root = root
	}
	low := root
	if root == kernel_root {
		low = early_window_root()
	}
	dsb_ish()
	write_ttbr0(u64(low))
	write_ttbr1(u64(kernel_root))
	isb()
	tlbi_all()
}

// current_address_space is the root the CPU is translating through, in the
// VMM's terms: the kernel's when TTBR0 holds the early window.
current_address_space :: proc "contextless" () -> uintptr {
	low := uintptr(read_ttbr0() & PTE_ADDR_MASK)
	if low == early_window_root() {
		return kernel_root
	}
	return low
}

// read_cr3 and write_cr3 are the names `kernel/mem/space.odin` uses for the
// root register. Here they are the two procedures above.
read_cr3 :: proc "contextless" () -> u64 {
	return u64(current_address_space())
}

write_cr3 :: proc "contextless" (root: u64) {
	load_address_space(uintptr(root))
}

flush_page :: proc "contextless" (virt: uintptr) {
	tlbi_page(virt)
}

flush_all :: proc "contextless" () {
	tlbi_all()
}
