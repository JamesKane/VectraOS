/*
 * The supervisor trap entry and the tail that follows it. Assembled by
 * clang and linked into the kernel; `traps.odin` declares `vectra_vectors`
 * with `foreign`, writes it into `stvec` in direct mode, and explains the
 * frame beside it.
 *
 * One entry, because `stvec` in direct mode names one address for every
 * trap, and `scause` says which. The tail saves every register, calls into
 * Odin, and restores whichever frame Odin hands back. A handler that returns
 * the frame it was given produces an ordinary trap return. One that returns
 * another thread's produces a context switch.
 *
 * The frame, from the lowest address up (see `Trap_Frame` in traps.odin):
 *
 *     0     x0 .. x31, eight bytes each. x0 is hardwired zero and its slot
 *           is spare; x2 is the interrupted sp, x4 the interrupted tp.
 *     256   sepc, where to resume
 *     264   sstatus, the interrupted mode and interrupt state
 *     272   scause, why
 *     280   stval, where, for a fault
 *     288   the vector, which the dispatcher fills in
 *     296   spare, so the frame stays a multiple of sixteen
 *
 * Below the frame, 272 bytes hold f0..f31 and fcsr, saved here rather than
 * in Odin because the dispatcher may use them before it could save them.
 * Below that, sixteen bytes take the dispatcher's answer.
 *
 * ## The two stacks, and the register that tells them apart
 *
 * A trap from user mode arrives with the program's sp, and the kernel has
 * to find its own with no register to trust. `sscratch` is that register:
 * it holds this core's per-CPU record while a program runs, and zero while
 * the kernel does. The first instruction swaps it with `tp`. A kernel trap
 * then sees zero in `tp`, swaps back, and stays on the stack it is on. A
 * user trap sees the record, takes the kernel stack out of it, and keeps
 * the program's sp and tp in the frame. On the way out the same dance in
 * reverse: a return to user mode puts the record back in `sscratch` and the
 * program's tp back in `tp`. A return to the kernel restores neither,
 * because `tp` is this core's and a thread may be on a different one now.
 *
 * `t0` is the one scratch register the entry needs before the frame is
 * open, so each path saves it first.
 */
	.text
	.balign 16
	.globl vectra_vectors
vectra_vectors:
	csrrw tp, sscratch, tp
	bnez tp, 1f
	/* From supervisor mode. */
	csrrw tp, sscratch, tp
	addi sp, sp, -304
	sd x5, 40(sp)
	addi t0, sp, 304
	sd t0, 16(sp)
	sd x4, 32(sp)
	j 2f
1:	/* From user mode. */
	sd sp, 16(tp)
	ld sp, 8(tp)
	addi sp, sp, -304
	sd x5, 40(sp)
	ld t0, 16(tp)
	sd t0, 16(sp)
	csrr t0, sscratch
	sd t0, 32(sp)
	csrw sscratch, zero
2:	sd x1, 8(sp)
	sd x3, 24(sp)
	sd x6, 48(sp)
	sd x7, 56(sp)
	sd x8, 64(sp)
	sd x9, 72(sp)
	sd x10, 80(sp)
	sd x11, 88(sp)
	sd x12, 96(sp)
	sd x13, 104(sp)
	sd x14, 112(sp)
	sd x15, 120(sp)
	sd x16, 128(sp)
	sd x17, 136(sp)
	sd x18, 144(sp)
	sd x19, 152(sp)
	sd x20, 160(sp)
	sd x21, 168(sp)
	sd x22, 176(sp)
	sd x23, 184(sp)
	sd x24, 192(sp)
	sd x25, 200(sp)
	sd x26, 208(sp)
	sd x27, 216(sp)
	sd x28, 224(sp)
	sd x29, 232(sp)
	sd x30, 240(sp)
	sd x31, 248(sp)
	csrr t0, sepc
	sd t0, 256(sp)
	csrr t0, sstatus
	sd t0, 264(sp)
	csrr t0, scause
	sd t0, 272(sp)
	csrr t0, stval
	sd t0, 280(sp)
	sd zero, 288(sp)
	sd zero, 296(sp)

	mv s1, sp
	addi sp, sp, -272
	mv s2, sp
	fsd f0, 0(s2)
	fsd f1, 8(s2)
	fsd f2, 16(s2)
	fsd f3, 24(s2)
	fsd f4, 32(s2)
	fsd f5, 40(s2)
	fsd f6, 48(s2)
	fsd f7, 56(s2)
	fsd f8, 64(s2)
	fsd f9, 72(s2)
	fsd f10, 80(s2)
	fsd f11, 88(s2)
	fsd f12, 96(s2)
	fsd f13, 104(s2)
	fsd f14, 112(s2)
	fsd f15, 120(s2)
	fsd f16, 128(s2)
	fsd f17, 136(s2)
	fsd f18, 144(s2)
	fsd f19, 152(s2)
	fsd f20, 160(s2)
	fsd f21, 168(s2)
	fsd f22, 176(s2)
	fsd f23, 184(s2)
	fsd f24, 192(s2)
	fsd f25, 200(s2)
	fsd f26, 208(s2)
	fsd f27, 216(s2)
	fsd f28, 224(s2)
	fsd f29, 232(s2)
	fsd f30, 240(s2)
	fsd f31, 248(s2)
	frcsr t0
	sd t0, 256(s2)

	addi sp, sp, -16
	mv s3, sp
	mv a0, s1
	mv a1, s2
	mv a2, s3
	call vectra_trap_dispatch

	/*
	 * The switch, and the hook after it. Both halves of the answer go to
	 * callee-saved registers first, because the hook lets go of the
	 * scheduler lock, and after that another core may run the thread whose
	 * stack s3 points into. The hook runs on the incoming thread's stack,
	 * below both its frame and its float image, whichever is lower.
	 */
	ld s1, 0(s3)
	ld s2, 8(s3)
	mv t0, s1
	bltu s1, s2, 4f
	mv t0, s2
4:	addi t0, t0, -16
	andi t0, t0, -16
	mv sp, t0
	call vectra_switch_done

	ld t0, 256(s2)
	fscsr t0
	fld f0, 0(s2)
	fld f1, 8(s2)
	fld f2, 16(s2)
	fld f3, 24(s2)
	fld f4, 32(s2)
	fld f5, 40(s2)
	fld f6, 48(s2)
	fld f7, 56(s2)
	fld f8, 64(s2)
	fld f9, 72(s2)
	fld f10, 80(s2)
	fld f11, 88(s2)
	fld f12, 96(s2)
	fld f13, 104(s2)
	fld f14, 112(s2)
	fld f15, 120(s2)
	fld f16, 128(s2)
	fld f17, 136(s2)
	fld f18, 144(s2)
	fld f19, 152(s2)
	fld f20, 160(s2)
	fld f21, 168(s2)
	fld f22, 176(s2)
	fld f23, 184(s2)
	fld f24, 192(s2)
	fld f25, 200(s2)
	fld f26, 208(s2)
	fld f27, 216(s2)
	fld f28, 224(s2)
	fld f29, 232(s2)
	fld f30, 240(s2)
	fld f31, 248(s2)

	mv sp, s1
	ld t0, 256(sp)
	csrw sepc, t0
	ld t0, 264(sp)
	csrw sstatus, t0
	ld x1, 8(sp)
	ld x3, 24(sp)
	ld x6, 48(sp)
	ld x7, 56(sp)
	ld x8, 64(sp)
	ld x9, 72(sp)
	ld x10, 80(sp)
	ld x11, 88(sp)
	ld x12, 96(sp)
	ld x13, 104(sp)
	ld x14, 112(sp)
	ld x15, 120(sp)
	ld x16, 128(sp)
	ld x17, 136(sp)
	ld x18, 144(sp)
	ld x19, 152(sp)
	ld x20, 160(sp)
	ld x21, 168(sp)
	ld x22, 176(sp)
	ld x23, 184(sp)
	ld x24, 192(sp)
	ld x25, 200(sp)
	ld x26, 208(sp)
	ld x27, 216(sp)
	ld x28, 224(sp)
	ld x29, 232(sp)
	ld x30, 240(sp)
	ld x31, 248(sp)
	andi t0, t0, 0x100
	bnez t0, 5f
	/* Back to user mode: the record into sscratch, the program's tp into
	 * tp, the program's sp into sp. */
	csrw sscratch, tp
	ld tp, 32(sp)
	ld t0, 40(sp)
	ld sp, 16(sp)
	sret
5:	ld t0, 40(sp)
	addi sp, sp, 304
	sret
