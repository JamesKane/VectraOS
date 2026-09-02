/*
 * vectra_fpu_hold(value, flag, out, counter): fill xmm0..xmm3 from *value,
 * spin until *flag while counting in *counter, then sum the four into *out.
 * The scheduler's preemption self-test holds live XMM state across every
 * preemption it takes with this; `fpu.odin` says why it is assembly.
 */
	.text
	.balign 16
	.globl vectra_fpu_hold
vectra_fpu_hold:
	movsd (%rdi), %xmm0
	movapd %xmm0, %xmm1
	addsd %xmm0, %xmm1
	movapd %xmm1, %xmm2
	addsd %xmm0, %xmm2
	movapd %xmm2, %xmm3
	addsd %xmm0, %xmm3
1:
	incq (%rcx)
	cmpb $0, (%rsi)
	je 1b
	addsd %xmm1, %xmm0
	addsd %xmm3, %xmm2
	addsd %xmm2, %xmm0
	movsd %xmm0, (%rdx)
	ret
