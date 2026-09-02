/*
 * The `syscall` entry stub. Assembled by clang and linked into the kernel;
 * `syscall.odin` declares `vectra_syscall_entry` with `foreign` and explains
 * the sequence beside it.
 */
	.text
.balign 16
.globl vectra_syscall_entry
vectra_syscall_entry:
	swapgs
	movq %rsp, %gs:16
	movq %gs:8, %rsp

	pushq $0x23
	pushq %gs:16
	pushq %r11
	pushq $0x2B
	pushq %rcx
	pushq $0
	pushq $0x100

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

	subq $512, %rsp
	fxsave (%rsp)

	cld
	leaq 512(%rsp), %rdi
	sti
	call vectra_syscall_dispatch
	cli

	fxrstor (%rsp)
	addq $512, %rsp

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

	movq 16(%rsp), %rcx
	movq 32(%rsp), %r11
	movq 40(%rsp), %rsp
	swapgs
	sysretq
