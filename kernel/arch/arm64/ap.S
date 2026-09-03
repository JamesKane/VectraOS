/*
 * The stack switch an application processor makes once, on its way from the
 * bootloader's world into the kernel's. Assembled by clang and linked into
 * the kernel; `context.odin` declares it with `foreign` and explains the
 * sequence beside it. The page tables were switched by Odin a moment before,
 * which works because the bootloader's stack is in memory both sets of
 * tables map.
 *
 *   x0  the top of the core's own kernel stack
 *   x1  where to go, a procedure that never returns
 *   x2  its one argument
 *
 * A cleared frame pointer ends the frame chain here, and the call rather
 * than a jump keeps the ABI's promise about the link register for the Odin
 * on the other side.
 */
	.text
	.balign 16
	.globl vectra_ap_switch
vectra_ap_switch:
	mov sp, x0
	mov x0, x2
	mov x29, xzr
	blr x1
1:	msr daifset, #0xf
	wfi
	b 1b
