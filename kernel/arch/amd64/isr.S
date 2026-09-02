/*
 * The interrupt entry stubs and the tail they share. Assembled by clang and
 * linked into the kernel; the Odin side declares the two symbols with
 * `foreign` and explains the sequence beside them in `idt.odin`.
 */
	.text
.balign 16
.globl vectra_isr_common
vectra_isr_common:
	cld
	testb $3, 24(%rsp)
	jz 1f
	swapgs
1:
	pushq %rax
	pushq %rbx
	pushq %rcx
	pushq %rdx
	pushq %rsi
	pushq %rdi
	pushq %rbp
	pushq %r8
	pushq %r9
	pushq %r10
	pushq %r11
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15

	movq %rsp, %rdi
	subq $528, %rsp
	andq $-16, %rsp
	fxsave (%rsp)
	movq %rsp, %rsi

	subq $16, %rsp
	movq %rsp, %rdx
	movq %rsp, %r12
	call vectra_trap_dispatch

	/*
	 * The switch, and the hook after it. Both halves of the Resume are read
	 * into callee-saved registers first, because the hook lets go of the
	 * scheduler lock, and after that another core may run the thread whose
	 * stack %r12 points into. Nothing below reads that stack again.
	 *
	 * The hook runs on the incoming thread's stack, below both the frame
	 * and the FXSAVE area, whichever is lower. An interrupted thread has its
	 * FXSAVE area below its frame, and a fresh one has it above, and the
	 * hook's own frame must land under both: fxrstor reads the area after
	 * the hook returns, and the hook is Odin, which may use SSE and does
	 * use the stack. What is below both is the dead space the dispatch call
	 * stood on, or a fresh thread's unused stack.
	 */
	movq 8(%r12), %rbx
	movq 0(%r12), %rbp
	movq %rbx, %rsp
	cmpq %rbp, %rsp
	cmovaq %rbp, %rsp
	subq $16, %rsp
	andq $-16, %rsp
	call vectra_switch_done
	movq %rbp, %rsp
	fxrstor (%rbx)

	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %r11
	popq %r10
	popq %r9
	popq %r8
	popq %rbp
	popq %rdi
	popq %rsi
	popq %rdx
	popq %rcx
	popq %rbx
	popq %rax
	addq $16, %rsp
	testb $3, 8(%rsp)
	jz 2f
	swapgs
2:
	iretq

.balign 16
.globl vectra_isr_stubs
vectra_isr_stubs:
.set vector, 0
.rept 256
	.balign 16
	.if (vector==8)||(vector==10)||(vector==11)||(vector==12)||(vector==13)||(vector==14)||(vector==17)||(vector==21)||(vector==29)||(vector==30)
	.else
	pushq $0
	.endif
	pushq $vector
	jmp vectra_isr_common
.set vector, vector + 1
.endr
