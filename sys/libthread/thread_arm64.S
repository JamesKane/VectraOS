/*
 * The two things a thread library cannot do in Odin, for arm64. See
 * thread_amd64.S for what each does and why the fork switches stacks first.
 *
 * The callee-saved set is x19..x28, the frame pointer, the link register,
 * the stack pointer, and the low halves of d8..d15. The link register is
 * what the switch returns through, so a label built for a new thread names
 * its first procedure there. The kernel keeps every register but x0 across
 * the door.
 */
	.text
	.globl vectra_thread_switch
vectra_thread_switch:
	stp x19, x20, [x0, #0]
	stp x21, x22, [x0, #16]
	stp x23, x24, [x0, #32]
	stp x25, x26, [x0, #48]
	stp x27, x28, [x0, #64]
	stp x29, x30, [x0, #80]
	mov x9, sp
	str x9, [x0, #96]
	stp d8, d9, [x0, #104]
	stp d10, d11, [x0, #120]
	stp d12, d13, [x0, #136]
	stp d14, d15, [x0, #152]
	ldp x19, x20, [x1, #0]
	ldp x21, x22, [x1, #16]
	ldp x23, x24, [x1, #32]
	ldp x25, x26, [x1, #48]
	ldp x27, x28, [x1, #64]
	ldp x29, x30, [x1, #80]
	ldr x9, [x1, #96]
	mov sp, x9
	ldp d8, d9, [x1, #104]
	ldp d10, d11, [x1, #120]
	ldp d12, d13, [x1, #136]
	ldp d14, d15, [x1, #152]
	ret

	.globl vectra_proc_fork
vectra_proc_fork:
	mov x8, x0
	mov x0, x1
	svc #0
	cbnz x0, 1f
	mov sp, x2
	mov x0, x4
	mov x29, xzr
	mov x30, xzr
	blr x3
	brk #0
1:	ret
