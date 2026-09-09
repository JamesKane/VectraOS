/*
The arm64 half of the walker. The context descriptor is the CPU's own
translation control said again, and the barrier is the one a device's read is
ordered behind. `docs/SMMU.md` section 2.
*/
#+build arm64
package smmu

import "kernel:arch/arm64"

// Word 0 of a context descriptor, the fields section 2 lists.
@(private) CD0_T0SZ :: arm64.TCR_T0SZ // bits 5:0
@(private) CD0_TG0_4K :: u64(0) << 6
@(private) CD0_IR0_WB :: u64(1) << 8
@(private) CD0_OR0_WB :: u64(1) << 10
@(private) CD0_SH0_INNER :: u64(3) << 12
@(private) CD0_EPD1 :: u64(1) << 30
@(private) CD0_VALID :: u64(1) << 31
@(private) CD0_IPS_SHIFT :: 32
@(private) CD0_AA64 :: u64(1) << 41
@(private) CD0_R :: u64(1) << 45 // record faults
@(private) CD0_A :: u64(1) << 46 // report an access flag fault
@(private) CD0_ASET :: u64(1) << 47 // the ASID is this descriptor's own
@(private) CD0_ASID_SHIFT :: 48
@(private) CD1_TTB0_MASK :: u64(0x000F_FFFF_FFFF_FFF0) // bits 51:4

/*
cd_fill writes a descriptor for a space. `T0SZ` 17 and the 4 KiB granule are
what the CPU programs. The walks are write-back and inner shareable. `TTBR1`
is disabled because the kernel half was never named. `MAIR` is the one
constant both sides share, and the ASID is the attach's. The physical address
size is the smaller of the CPU's and the part's, in the same code both use.
*/
@(private)
cd_fill :: proc "contextless" (cd: ^[8]u64, root: uintptr, asid: u16, ips: u32) {
	cd[0] = 0
	barrier()
	cd[1] = u64(root) & CD1_TTB0_MASK
	cd[2] = 0
	cd[3] = arm64.MAIR_VALUE
	cd[4] = 0
	cd[5] = 0
	cd[6] = 0
	cd[7] = 0
	barrier()
	cd[0] = CD0_T0SZ | CD0_TG0_4K | CD0_IR0_WB | CD0_OR0_WB | CD0_SH0_INNER | CD0_EPD1 | CD0_VALID | u64(ips) << CD0_IPS_SHIFT | CD0_AA64 | CD0_R | CD0_A | CD0_ASET | u64(asid) << CD0_ASID_SHIFT
	barrier()
}

// ips_code is the physical address size the descriptors carry. It is the
// CPU's `PARange`, capped at 48 bits as `paging.odin` caps it, and no larger
// than the part's own output size.
@(private)
ips_code :: proc "contextless" (oas: u32) -> u32 {
	ips := u32(arm64.read_mmfr0() & 0xF)
	if ips > 5 {
		ips = 5
	}
	if oas < ips {
		ips = oas
	}
	return ips
}

// barrier: every write before it reaches memory before the part is told to
// read it. A data synchronisation barrier, the full kind, because the part is
// not a core.
@(private)
barrier :: proc "contextless" () {
	arm64.dsb_sy()
}
