/*
 * vectra_fpu_hold(value, flag, out, counter): fill f0..f3 from *value, spin
 * until *flag while counting in *counter, then sum the four into *out. The
 * scheduler's preemption self-test holds live float state across every
 * preemption it takes with this; `fpu.odin` says why it is assembly.
 */
	.text
	.balign 16
	.globl vectra_fpu_hold
vectra_fpu_hold:
	fld f0, 0(a0)
	fadd.d f1, f0, f0
	fadd.d f2, f1, f0
	fadd.d f3, f2, f0
1:	ld t0, 0(a3)
	addi t0, t0, 1
	sd t0, 0(a3)
	lbu t1, 0(a1)
	beqz t1, 1b
	fadd.d f0, f0, f1
	fadd.d f2, f2, f3
	fadd.d f0, f0, f2
	fsd f0, 0(a2)
	ret
