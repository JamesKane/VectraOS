/*
 * The exception vector table and the tail every entry shares. Assembled by
 * clang and linked into the kernel; `traps.odin` declares `vectra_vectors`
 * with `foreign`, installs it in VBAR_EL1, and explains the frame beside it.
 *
 * Sixteen entries of 128 bytes: four kinds (synchronous, IRQ, FIQ, SError)
 * for each of four sources (EL1 on SP_EL0, EL1 on SP_EL1, EL0 in AArch64,
 * EL0 in AArch32). Each entry opens the frame, saves the two registers it is
 * about to use, notes which entry it is, and branches to the tail. The tail
 * saves everything else, calls into Odin, and restores whichever frame Odin
 * hands back. A handler that returns the frame it was given produces an
 * ordinary exception return. One that returns another thread's produces a
 * context switch. The tail cannot tell the difference and does not need to.
 *
 * The frame, from the lowest address up (see `Trap_Frame` in traps.odin):
 *
 *     0     x0 .. x30, eight bytes each, through offset 240
 *     248   the interrupted sp: SP_EL0 for a program, the frame's own end
 *           for the kernel, because the kernel's frame is on the kernel's
 *           stack and that is where the stack was
 *     256   elr_el1, where to resume
 *     264   spsr_el1, the interrupted PSTATE
 *     272   esr_el1, why
 *     280   far_el1, where, for an abort
 *     288   the entry: kind << 2 | source, which the dispatcher decodes
 *     296   spare, so the frame stays a multiple of sixteen
 *
 * Below the frame, 528 bytes hold the vector registers q0..q31 and the two
 * floating-point control registers. Saved here rather than in Odin, because
 * the compiler uses vector registers for ordinary struct moves, so the first
 * line of the dispatcher would already destroy what this is trying to save.
 * Below that, sixteen bytes take the dispatcher's answer: the frame and the
 * vector image to resume from.
 *
 * `vectra_switch_done` runs on the incoming thread's stack, below both its
 * frame and its vector image, whichever is lower. It lets go of the scheduler
 * lock, after which another core may run the thread whose stack this core
 * just left. Nothing below reads the outgoing stack again.
 *
 * The stack pointer needs no explicit restore for the kernel: the frame was
 * opened at the interrupted sp, so closing it lands there. A program's sp is
 * SP_EL0, written back before the return, and only when the saved PSTATE
 * names EL0. Every kernel frame carries EL1h.
 */
	.text

.macro entry kind, source
	.balign 0x80
	sub sp, sp, #304
	stp x0, x1, [sp, #0]
	mov x0, #\kind
	mov x1, #\source
	b vectra_trap_common
.endm

	.balign 0x800
	.globl vectra_vectors
vectra_vectors:
	entry 0, 0
	entry 1, 0
	entry 2, 0
	entry 3, 0
	entry 0, 1
	entry 1, 1
	entry 2, 1
	entry 3, 1
	entry 0, 2
	entry 1, 2
	entry 2, 2
	entry 3, 2
	entry 0, 3
	entry 1, 3
	entry 2, 3
	entry 3, 3

	.balign 16
	.globl vectra_trap_common
vectra_trap_common:
	stp x2, x3, [sp, #16]
	stp x4, x5, [sp, #32]
	stp x6, x7, [sp, #48]
	stp x8, x9, [sp, #64]
	stp x10, x11, [sp, #80]
	stp x12, x13, [sp, #96]
	stp x14, x15, [sp, #112]
	stp x16, x17, [sp, #128]
	stp x18, x19, [sp, #144]
	stp x20, x21, [sp, #160]
	stp x22, x23, [sp, #176]
	stp x24, x25, [sp, #192]
	stp x26, x27, [sp, #208]
	stp x28, x29, [sp, #224]
	str x30, [sp, #240]

	lsl x0, x0, #2
	orr x0, x0, x1
	str x0, [sp, #288]
	str xzr, [sp, #296]

	mrs x2, elr_el1
	mrs x3, spsr_el1
	stp x2, x3, [sp, #256]
	mrs x2, esr_el1
	mrs x3, far_el1
	stp x2, x3, [sp, #272]

	mrs x3, spsr_el1
	and x3, x3, #0xf
	cbz x3, 1f
	add x2, sp, #304
	b 2f
1:	mrs x2, sp_el0
2:	str x2, [sp, #248]

	mov x19, sp
	sub sp, sp, #528
	mov x20, sp
	stp q0, q1, [x20, #0]
	stp q2, q3, [x20, #32]
	stp q4, q5, [x20, #64]
	stp q6, q7, [x20, #96]
	stp q8, q9, [x20, #128]
	stp q10, q11, [x20, #160]
	stp q12, q13, [x20, #192]
	stp q14, q15, [x20, #224]
	stp q16, q17, [x20, #256]
	stp q18, q19, [x20, #288]
	stp q20, q21, [x20, #320]
	stp q22, q23, [x20, #352]
	stp q24, q25, [x20, #384]
	stp q26, q27, [x20, #416]
	stp q28, q29, [x20, #448]
	stp q30, q31, [x20, #480]
	mrs x2, fpsr
	mrs x3, fpcr
	str x2, [x20, #512]
	str x3, [x20, #520]

	sub sp, sp, #16
	mov x21, sp
	mov x0, x19
	mov x1, x20
	mov x2, x21
	bl vectra_trap_dispatch

	ldp x19, x20, [x21]
	cmp x19, x20
	csel x2, x19, x20, lo
	sub x2, x2, #16
	and x2, x2, #-16
	mov sp, x2
	bl vectra_switch_done

	ldr x2, [x20, #512]
	ldr x3, [x20, #520]
	msr fpsr, x2
	msr fpcr, x3
	ldp q0, q1, [x20, #0]
	ldp q2, q3, [x20, #32]
	ldp q4, q5, [x20, #64]
	ldp q6, q7, [x20, #96]
	ldp q8, q9, [x20, #128]
	ldp q10, q11, [x20, #160]
	ldp q12, q13, [x20, #192]
	ldp q14, q15, [x20, #224]
	ldp q16, q17, [x20, #256]
	ldp q18, q19, [x20, #288]
	ldp q20, q21, [x20, #320]
	ldp q22, q23, [x20, #352]
	ldp q24, q25, [x20, #384]
	ldp q26, q27, [x20, #416]
	ldp q28, q29, [x20, #448]
	ldp q30, q31, [x20, #480]

	mov sp, x19
	ldp x2, x3, [sp, #256]
	msr elr_el1, x2
	msr spsr_el1, x3
	and x3, x3, #0xf
	cbnz x3, 3f
	ldr x2, [sp, #248]
	msr sp_el0, x2
3:	ldp x2, x3, [sp, #16]
	ldp x4, x5, [sp, #32]
	ldp x6, x7, [sp, #48]
	ldp x8, x9, [sp, #64]
	ldp x10, x11, [sp, #80]
	ldp x12, x13, [sp, #96]
	ldp x14, x15, [sp, #112]
	ldp x16, x17, [sp, #128]
	ldp x18, x19, [sp, #144]
	ldp x20, x21, [sp, #160]
	ldp x22, x23, [sp, #176]
	ldp x24, x25, [sp, #192]
	ldp x26, x27, [sp, #208]
	ldp x28, x29, [sp, #224]
	ldr x30, [sp, #240]
	ldp x0, x1, [sp, #0]
	add sp, sp, #304
	eret
