/*
The riscv64 page table format: Sv48.

Four levels of 512 entries, nine bits of address per level, leaves allowed
part-way up -- the same tree `kernel/mem/vmm.odin` walks on the other two
architectures, and it walks this one with no change. Level 4 is the root
`satp` names; level 1 is the table whose entries are 4 KiB pages.

An entry's low ten bits are its flags and the rest is the physical page
number, shifted down by two from where amd64 keeps an address. A leaf is any
entry with a read, write or execute permission; a branch has none. There is
no bit for `block` and no bit for `not executable`: the permissions say it
all, and an entry that permits nothing is a pointer to a table.

The halves are 47 bits each, exactly amd64's, and the bootloader's direct
map is at `0xffff_8000_0000_0000` plus a slide, which is entry 256 and up.
So `is_canonical` is amd64's rule and the higher-half pre-population covers
everything.
*/
package riscv64

import "kernel:arch/neutral"

PAGE_SHIFT :: neutral.PAGE_SHIFT
PAGE_SIZE :: neutral.PAGE_SIZE
TABLE_BITS :: neutral.TABLE_BITS
TABLE_ENTRIES :: neutral.TABLE_ENTRIES
TABLE_LEVELS :: neutral.TABLE_LEVELS

Page_Table_Entry :: neutral.Page_Table_Entry
Page_Table :: neutral.Page_Table
Page_Flag :: neutral.Page_Flag
Page_Flags :: neutral.Page_Flags

PTE_VALID :: u64(1) << 0
PTE_READ :: u64(1) << 1
PTE_WRITE :: u64(1) << 2
PTE_EXEC :: u64(1) << 3
PTE_USER :: u64(1) << 4
PTE_GLOBAL :: u64(1) << 5
PTE_ACCESSED :: u64(1) << 6
PTE_DIRTY :: u64(1) << 7
PTE_LEAF_MASK :: PTE_READ | PTE_WRITE | PTE_EXEC

// The physical page number: bits 53:10 of the entry, bits 55:12 of the
// address.
PTE_PPN_SHIFT :: 10
PTE_PPN_MASK :: u64(0x003F_FFFF_FFFF_FC00)
PHYS_MASK :: u64(0x00FF_FFFF_FFFF_F000)

// satp: the mode in the top four bits, the root's page number below.
SATP_SV48 :: u64(9) << 60
SATP_PPN_MASK :: u64(0x0FFF_FFFF_FFFF)

/*
enable_paging_features has nothing to enable.

Execute permission is a bit every entry has, there are no global-page or
large-page enables, and the caching attributes `No_Cache` and
`Write_Through` name are an extension (Svpbmt) this kernel does not assume.
A device page is therefore mapped like any other, and the platform's memory
attributes decide. QEMU's do the right thing for the devices this kernel
touches.
*/
enable_paging_features :: proc "contextless" () {
}

nx_available :: proc "contextless" () -> bool {
	return true
}

global_available :: proc "contextless" () -> bool {
	return true
}

// Level 3 is a 1 GiB leaf. Sv48 allows one at level 4 too, and the VMM
// never asks.
max_leaf_level :: proc "contextless" () -> int {
	return 3
}

table_index :: neutral.table_index
level_size :: neutral.level_size

// Bits 63..48 copy bit 47, as under amd64's 4-level paging.
is_canonical :: proc "contextless" (virt: uintptr) -> bool {
	top := u64(virt) >> 47
	return top == 0 || top == 0x1FFFF
}

@(private = "file")
ppn :: proc "contextless" (phys: uintptr) -> u64 {
	return (u64(phys) & PHYS_MASK) >> PAGE_SHIFT << PTE_PPN_SHIFT
}

/*
leaf_encode builds an entry that terminates a walk at `level`.

Accessed and dirty are set up front. A hart without hardware management of
either takes a page fault on the first access to an entry with the bit
clear, and this kernel does not handle that fault as anything but a fault.
Readable always: an entry that permits nothing would be a branch.
*/
leaf_encode :: proc "contextless" (phys: uintptr, flags: Page_Flags, level: int) -> Page_Table_Entry {
	_ = level
	e := ppn(phys) | PTE_VALID | PTE_READ | PTE_ACCESSED | PTE_DIRTY
	if .Write in flags {
		e |= PTE_WRITE
	}
	if .No_Execute not_in flags {
		e |= PTE_EXEC
	}
	if .User in flags {
		e |= PTE_USER
	}
	if .Global in flags {
		e |= PTE_GLOBAL
	}
	return Page_Table_Entry(e)
}

// branch_encode builds an entry pointing at the next table down: valid,
// with no permissions, which is what says so. The user bit means nothing on
// a branch and is left clear.
branch_encode :: proc "contextless" (phys: uintptr, flags: Page_Flags) -> Page_Table_Entry {
	_ = flags
	return Page_Table_Entry(ppn(phys) | PTE_VALID)
}

entry_present :: proc "contextless" (e: Page_Table_Entry) -> bool {
	return u64(e) & PTE_VALID != 0
}

entry_is_leaf :: proc "contextless" (e: Page_Table_Entry, level: int) -> bool {
	return level == 1 || u64(e) & PTE_LEAF_MASK != 0
}

entry_address :: proc "contextless" (e: Page_Table_Entry) -> uintptr {
	return uintptr((u64(e) & PTE_PPN_MASK) >> PTE_PPN_SHIFT << PAGE_SHIFT)
}

entry_flags :: proc "contextless" (e: Page_Table_Entry) -> Page_Flags {
	flags: Page_Flags
	v := u64(e)
	if v & PTE_WRITE != 0 {
		flags += {.Write}
	}
	if v & PTE_USER != 0 {
		flags += {.User}
	}
	if v & PTE_EXEC == 0 {
		flags += {.No_Execute}
	}
	if v & PTE_GLOBAL != 0 {
		flags += {.Global}
	}
	return flags
}

ENTRY_EMPTY :: Page_Table_Entry(0)

// -- Address space switching and TLB ----------------------------------------------

load_address_space :: proc "contextless" (root: uintptr) {
	write_satp(SATP_SV48 | u64(root) >> PAGE_SHIFT & SATP_PPN_MASK)
	sfence_all()
}

current_address_space :: proc "contextless" () -> uintptr {
	return uintptr(read_satp() & SATP_PPN_MASK << PAGE_SHIFT)
}

// read_cr3 and write_cr3 are the names `kernel/mem/space.odin` uses for the
// root register. Here they are `satp`.
read_cr3 :: proc "contextless" () -> u64 {
	return u64(current_address_space())
}

write_cr3 :: proc "contextless" (root: u64) {
	load_address_space(uintptr(root))
}

flush_page :: proc "contextless" (virt: uintptr) {
	sfence_page(virt)
}

flush_all :: proc "contextless" () {
	sfence_all()
}
