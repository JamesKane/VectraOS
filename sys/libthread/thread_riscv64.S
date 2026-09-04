/*
 * The two things a thread library cannot do in Odin, for riscv64. See
 * thread_amd64.S for what each does and why the fork switches stacks first.
 *
 * The callee-saved set is s0..s11, the return address, the stack pointer,
 * and fs0..fs11. The return address is what the switch returns through, so
 * a label built for a new thread names its first procedure there. The
 * kernel keeps every register but a0 across the door.
 */
	.text
	.globl vectra_thread_switch
vectra_thread_switch:
	sd s0, 0(a0)
	sd s1, 8(a0)
	sd s2, 16(a0)
	sd s3, 24(a0)
	sd s4, 32(a0)
	sd s5, 40(a0)
	sd s6, 48(a0)
	sd s7, 56(a0)
	sd s8, 64(a0)
	sd s9, 72(a0)
	sd s10, 80(a0)
	sd s11, 88(a0)
	sd ra, 96(a0)
	sd sp, 104(a0)
	fsd fs0, 112(a0)
	fsd fs1, 120(a0)
	fsd fs2, 128(a0)
	fsd fs3, 136(a0)
	fsd fs4, 144(a0)
	fsd fs5, 152(a0)
	fsd fs6, 160(a0)
	fsd fs7, 168(a0)
	fsd fs8, 176(a0)
	fsd fs9, 184(a0)
	fsd fs10, 192(a0)
	fsd fs11, 200(a0)
	ld s0, 0(a1)
	ld s1, 8(a1)
	ld s2, 16(a1)
	ld s3, 24(a1)
	ld s4, 32(a1)
	ld s5, 40(a1)
	ld s6, 48(a1)
	ld s7, 56(a1)
	ld s8, 64(a1)
	ld s9, 72(a1)
	ld s10, 80(a1)
	ld s11, 88(a1)
	ld ra, 96(a1)
	ld sp, 104(a1)
	fld fs0, 112(a1)
	fld fs1, 120(a1)
	fld fs2, 128(a1)
	fld fs3, 136(a1)
	fld fs4, 144(a1)
	fld fs5, 152(a1)
	fld fs6, 160(a1)
	fld fs7, 168(a1)
	fld fs8, 176(a1)
	fld fs9, 184(a1)
	fld fs10, 192(a1)
	fld fs11, 200(a1)
	ret

	.globl vectra_proc_fork
vectra_proc_fork:
	mv a7, a0
	mv a0, a1
	ecall
	bnez a0, 1f
	mv sp, a2
	mv a0, a4
	mv s0, zero
	mv ra, zero
	jalr a3
	ebreak
1:	ret
