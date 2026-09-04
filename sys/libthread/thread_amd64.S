/*
 * The two things a thread library cannot do in Odin: switch stacks, and
 * fork a process onto a stack of its own.
 *
 * vectra_thread_switch(from, to) saves the callee-saved registers and the
 * stack pointer into `from`, loads the same from `to`, and returns -- into
 * whatever `to` was doing when it was saved, or into a new thread's first
 * procedure if `to` was built by label_init. The caller-saved registers
 * need no saving: the compiler already assumes a call clobbers them.
 *
 * vectra_proc_fork(nr, flags, sp, entry, arg) is rfork with the child moved
 * onto `sp` before it touches anything. The caller runs on a thread's stack
 * in the heap, which RFMEM shares between the two processes; a child that
 * pushed one word there would push it under the parent. So the child's
 * first instruction after the door is the stack switch, and the parent's
 * is the return. The kernel keeps every register but rax, rcx and r11
 * across the door, which is what lets the child find its stack in rdx and
 * its argument in r8.
 */
	.text
	.globl vectra_thread_switch
vectra_thread_switch:
	movq %rbx, 0(%rdi)
	movq %rbp, 8(%rdi)
	movq %r12, 16(%rdi)
	movq %r13, 24(%rdi)
	movq %r14, 32(%rdi)
	movq %r15, 40(%rdi)
	movq %rsp, 48(%rdi)
	movq 0(%rsi), %rbx
	movq 8(%rsi), %rbp
	movq 16(%rsi), %r12
	movq 24(%rsi), %r13
	movq 32(%rsi), %r14
	movq 40(%rsi), %r15
	movq 48(%rsi), %rsp
	ret

	.globl vectra_proc_fork
vectra_proc_fork:
	movq %rdi, %rax
	movq %rsi, %rdi
	movq %rcx, %r9
	syscall
	testq %rax, %rax
	jnz 1f
	movq %rdx, %rsp
	movq %r8, %rdi
	xorl %ebp, %ebp
	call *%r9
	ud2
1:	ret
