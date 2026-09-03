/*
 * vectra_fpu_hold(value, flag, out, counter): fill d0..d3 from *value, spin
 * until *flag while counting in *counter, then sum the four into *out. The
 * scheduler's preemption self-test holds live vector state across every
 * preemption it takes with this; `fpu.odin` says why it is assembly.
 */
	.text
	.balign 16
	.globl vectra_fpu_hold
vectra_fpu_hold:
	ldr d0, [x0]
	fadd d1, d0, d0
	fadd d2, d1, d0
	fadd d3, d2, d0
1:	ldr x4, [x3]
	add x4, x4, #1
	str x4, [x3]
	ldrb w5, [x1]
	cbz w5, 1b
	fadd d0, d0, d1
	fadd d2, d2, d3
	fadd d0, d0, d2
	str d0, [x2]
	ret
