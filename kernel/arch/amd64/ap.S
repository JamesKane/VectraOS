/*
 * The stack and page-table switch an application processor makes once, on
 * its way from the bootloader's world into the kernel's. Assembled by
 * clang and linked into the kernel; `context.odin` declares it with
 * `foreign` and explains the sequence beside it.
 *
 *   rdi  the top of the core's own kernel stack
 *   rsi  the kernel's page-table root, for cr3
 *   rdx  where to go, a procedure that never returns
 *   rcx  its one argument
 *
 * The stack moves first and cr3 second, so the last instruction that
 * touches the bootloader's stack runs while the bootloader's tables still
 * map it. The kernel's image is mapped at the same address by both sets of
 * tables, which is what lets the instruction after the cr3 write fetch at
 * all. A cleared rbp ends the frame chain here, and the call rather than a
 * jump keeps the ABI's alignment promise for the Odin on the other side.
 */
	.text
.balign 16
.globl vectra_ap_switch
vectra_ap_switch:
	movq %rdi, %rsp
	movq %rsi, %cr3
	movq %rcx, %rdi
	xorq %rbp, %rbp
	call *%rdx
1:
	cli
	hlt
	jmp 1b
