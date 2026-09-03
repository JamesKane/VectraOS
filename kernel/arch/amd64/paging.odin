/*
The amd64 page table format.

This file knows the shape of an x86-64 page table and nothing about policy.
Which regions get mapped, where the tables come from, and what the kernel
address space looks like are all `kernel/mem`'s business.

What a present bit is, and which nine bits of a virtual address select an entry
at level 3, are this file's.

The split matters because the walk itself is not architecture-specific. amd64's
4-level tables, aarch64's 4-level stage-1 tables and riscv64's Sv39/Sv48 are
all the same shape. Each is a radix tree of 512 entries, indexed nine bits at a
time, with leaves allowed part-way up. `kernel/mem/vmm.odin` implements that
loop once against the primitives below, so a port supplies an encoding rather
than a second walker.

Level numbering runs downward, so `level` is also the count of translation
steps remaining. 4 is the PML4. 1 is the PT whose entries are 4 KiB pages.
*/
package amd64

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

// -- Entry bits --------------------------------------------------------------

PTE_PRESENT  :: u64(1) << 0
PTE_WRITE    :: u64(1) << 1
PTE_USER     :: u64(1) << 2
PTE_PWT      :: u64(1) << 3
PTE_PCD      :: u64(1) << 4
PTE_ACCESSED :: u64(1) << 5
PTE_DIRTY    :: u64(1) << 6
PTE_LARGE    :: u64(1) << 7 // At levels 3 and 2 only; means "leaf, stop here"
PTE_GLOBAL   :: u64(1) << 8
PTE_NX       :: u64(1) << 63

// Bits 12..51. The reserved bits above the physical address width fault if set,
// so masking rather than trusting the caller is not paranoia.
PTE_ADDR_MASK :: u64(0x000F_FFFF_FFFF_F000)

// -- Optional features -------------------------------------------------------
//
// NX and PGE are enables, not just capabilities. Bit 63 of an entry, set
// before EFER.NXE is on, is a *reserved* bit. The mapping then faults on first
// use, with a reserved-bit page fault, rather than ignores it. The encoder
// below drops both bits unless the corresponding enable actually took, so the
// VMM can ask for them unconditionally.

@(private = "file") nx_enabled: bool
@(private = "file") global_enabled: bool
@(private = "file") gigabyte_pages: bool

/*
enable_paging_features turns on everything the mapper wants and records what it
got.

Must run before the first entry is encoded. Limine base revision 5 and above
hands over a CPU with every cr0, cr4 and EFER bit the protocol does not require
cleared. None of these can be assumed on.

CR0.WP is included. Without it the kernel can happily write through a read-only
mapping, and the .rodata protection the VMM installed is decorative.
*/
enable_paging_features :: proc "contextless" () {
	cr0 := read_cr0()
	cr0 |= CR0_WP
	write_cr0(cr0)

	if has_feature(CPUID_EXT_FEATURES, .EDX, 20) {
		write_efer(read_efer() | EFER_NXE)
		nx_enabled = true
	}
	if has_feature(CPUID_FEATURES, .EDX, 13) {
		write_cr4(read_cr4() | CR4_PGE)
		global_enabled = true
	}
	gigabyte_pages = has_feature(CPUID_EXT_FEATURES, .EDX, 26)
}

nx_available :: proc "contextless" () -> bool {
	return nx_enabled
}

global_available :: proc "contextless" () -> bool {
	return global_enabled
}

/*
max_leaf_level reports the highest level at which a leaf may be installed.

Level 1 (4 KiB) and level 2 (2 MiB) are architectural in long mode. Level 3 (1
GiB) is a feature bit. This is what lets the HHDM cost thirteen tables instead
of three thousand.
*/
max_leaf_level :: proc "contextless" () -> int {
	return gigabyte_pages ? 3 : 2
}

// -- Address arithmetic ------------------------------------------------------

table_index :: neutral.table_index
level_size :: neutral.level_size

/*
is_canonical reports whether `virt` is a form the CPU will accept.

Under 4-level paging, bits 63..48 must all copy bit 47. Anything else raises a
general protection fault on use, rather than a page fault. That is a far less
informative way to find out. The VMM checks before mapping so the complaint
names the address.
*/
is_canonical :: proc "contextless" (virt: uintptr) -> bool {
	top := u64(virt) >> 47
	return top == 0 || top == 0x1FFFF
}

// -- Entry encoding ----------------------------------------------------------

/*
leaf_encode builds an entry that terminates a walk at `level`.

Permissions are taken literally, because this is the entry the CPU checks last.

On amd64 the effective permission is the AND of `Write` and `User` down the
whole path, and the OR of `No_Execute`. Restrictions therefore belong here, and
permissiveness belongs in `branch_encode`.
*/
leaf_encode :: proc "contextless" (phys: uintptr, flags: Page_Flags, level: int) -> Page_Table_Entry {
	e := (u64(phys) & PTE_ADDR_MASK) | PTE_PRESENT

	if .Write in flags {
		e |= PTE_WRITE
	}
	if .User in flags {
		e |= PTE_USER
	}
	if .Write_Through in flags {
		e |= PTE_PWT
	}
	if .No_Cache in flags {
		e |= PTE_PCD
	}
	if .Global in flags && global_enabled {
		e |= PTE_GLOBAL
	}
	if .No_Execute in flags && nx_enabled {
		e |= PTE_NX
	}
	if level > 1 {
		e |= PTE_LARGE
	}
	return Page_Table_Entry(e)
}

/*
branch_encode builds an entry pointing at the next table down.

Always writable and always executable, because the hardware ANDs write
permission and ORs no-execute along the path. A read-only branch would make
every leaf beneath it read-only too. `User` is the exception, because the
hardware ANDs it as well. A branch that omits it seals the whole subtree from
userland. That is what a kernel mapping wants, and it is why this propagates
the bit rather than assumes it.
*/
branch_encode :: proc "contextless" (phys: uintptr, flags: Page_Flags) -> Page_Table_Entry {
	e := (u64(phys) & PTE_ADDR_MASK) | PTE_PRESENT | PTE_WRITE
	if .User in flags {
		e |= PTE_USER
	}
	return Page_Table_Entry(e)
}

entry_present :: proc "contextless" (e: Page_Table_Entry) -> bool {
	return u64(e) & PTE_PRESENT != 0
}

// entry_is_leaf reports whether a walk stops at this entry. Level 1 entries
// are always leaves. Above that it takes the large-page bit.
entry_is_leaf :: proc "contextless" (e: Page_Table_Entry, level: int) -> bool {
	return level == 1 || u64(e) & PTE_LARGE != 0
}

entry_address :: proc "contextless" (e: Page_Table_Entry) -> uintptr {
	return uintptr(u64(e) & PTE_ADDR_MASK)
}

/*
entry_flags decodes an entry back into the neutral flags.

The inverse of `leaf_encode`, and not merely a debugging convenience. A page
fault handler has to know what the mapping it faulted on permits. Only then can
it tell a protection violation from a missing page.

Anything that reports the address space to userland also reads it through here.

`No_Execute` and `Global` are reported as the entry holds them. If nothing ever
enabled the corresponding feature, `leaf_encode` never set the bit, so this
reads back false. That is the truth about the mapping, whatever the caller
asked for.
*/
entry_flags :: proc "contextless" (e: Page_Table_Entry) -> Page_Flags {
	flags: Page_Flags
	v := u64(e)

	if v & PTE_WRITE != 0 {
		flags += {.Write}
	}
	if v & PTE_USER != 0 {
		flags += {.User}
	}
	if v & PTE_PWT != 0 {
		flags += {.Write_Through}
	}
	if v & PTE_PCD != 0 {
		flags += {.No_Cache}
	}
	if v & PTE_GLOBAL != 0 {
		flags += {.Global}
	}
	if v & PTE_NX != 0 {
		flags += {.No_Execute}
	}
	return flags
}

ENTRY_EMPTY :: Page_Table_Entry(0)

// -- Address space switching and TLB -----------------------------------------

load_address_space :: proc "contextless" (root: uintptr) {
	write_cr3(u64(root))
}

current_address_space :: proc "contextless" () -> uintptr {
	return uintptr(read_cr3() & PTE_ADDR_MASK)
}

// flush_page drops one page's translation. The memory clobber keeps the
// compiler from moving the stores that changed the entry past it.
flush_page :: proc "contextless" (virt: uintptr) {
	asm(v: uintptr) [#volatile, #clobber memory] { invlpg [v] }(virt)
}

/*
flush_all drops every translation, global entries included.

A plain CR3 reload leaves global pages behind by design, and that is what makes
them worth having for kernel mappings. CR4.PGE cleared and put back is the only
way to reach them. Expensive, and only needed after changing a mapping that was
installed as global.
*/
flush_all :: proc "contextless" () {
	if global_enabled {
		cr4 := read_cr4()
		write_cr4(cr4 &~ CR4_PGE)
		write_cr4(cr4)
		return
	}
	write_cr3(read_cr3())
}

// read_cr2 returns the faulting address recorded by the last page fault. Only
// meaningful inside a #PF handler, and only before interrupts are re-enabled.
read_cr2 :: proc "contextless" () -> uintptr {
	return uintptr(asm() -> (r: u64) [#volatile] { mov r, %cr2 }())
}
