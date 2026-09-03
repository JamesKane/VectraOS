/*
 * The stack switch an application processor makes once, on its way from the
 * bootloader's world into the kernel's. Assembled by clang and linked into
 * the kernel; `context.odin` declares it with `foreign` and explains the
 * sequence beside it. The page tables were switched by Odin a moment
 * before, which works because the bootloader's stack is in memory both sets
 * of tables map.
 *
 *   a0  the top of the core's own kernel stack
 *   a1  where to go, a procedure that never returns
 *   a2  its one argument
 */
	.text
	.balign 16
	.globl vectra_ap_switch
vectra_ap_switch:
	mv sp, a0
	mv a0, a2
	mv fp, zero
	jalr a1
1:	csrci sstatus, 2
	wfi
	j 1b
