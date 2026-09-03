/*
 * The ring 3 programs, as bytes in the kernel's text. Assembled by clang and
 * linked into the kernel; `program.odin` declares every start and end symbol
 * with `foreign` and says what each program is for.
 */
	.text
.balign 16
.globl vectra_user_spin
vectra_user_spin:
	movabsq $0x5350494E5350494E, %rax
	movq %rax, (%rdi)
	movq $400000000, %rcx
1:
	incq 8(%rdi)
	cmpq $0, 16(%rdi)
	jne 2f
	decq %rcx
	jnz 1b
2:
	ud2
.globl vectra_user_spin_end
vectra_user_spin_end:

.balign 16
.globl vectra_user_poke
vectra_user_poke:
	movabsq $0x504F4B45504F4B45, %rax
	movq %rax, (%rdi)
	movq $1, (%rsi)
	ud2
.globl vectra_user_poke_end
vectra_user_poke_end:

.balign 16
.globl vectra_user_peek
vectra_user_peek:
	movabsq $0x5045454B5045454B, %rax
	movq %rax, (%rdi)
	movq (%rsi), %rax
	movq %rax, 8(%rdi)
	ud2
.globl vectra_user_peek_end
vectra_user_peek_end:

.balign 16
.globl vectra_user_priv
vectra_user_priv:
	movabsq $0x5052495650524956, %rax
	movq %rax, (%rdi)
	cli
	ud2
.globl vectra_user_priv_end
vectra_user_priv_end:

.balign 16
.globl vectra_user_jump
vectra_user_jump:
	movabsq $0x4A554D504A554D50, %rax
	movq %rax, (%rdi)
	jmpq *%rsi
.globl vectra_user_jump_end
vectra_user_jump_end:

.balign 16
.globl vectra_user_hello
vectra_user_hello:
	movq %rdi, %rbx
	movq %rsi, %rbp
	movabsq $0x48454C4C48454C4C, %rax
	movq %rax, (%rbx)

	movq $1, %rdi
	leaq 128(%rbx), %rsi
	movq %rbp, %rdx
	movq $2, %rax
	syscall
	movq %rax, 8(%rbx)

	movq $0x2A, %rdi
	movq $4, %rax
	syscall
	ud2
.globl vectra_user_hello_end
vectra_user_hello_end:

.balign 16
.globl vectra_user_probe
vectra_user_probe:
	movq %rdi, %rbx
	movq %rsi, %rbp
	movabsq $0x50524F4250524F42, %rax
	movq %rax, (%rbx)

	xorl %edi, %edi
	movq $0, %rax
	syscall
	movq %rax, 8(%rbx)

	movq $1, %rdi
	movq $2, %rsi
	movq $4, %rdx
	movq $8, %r10
	movq $16, %r8
	movq $32, %r9
	movq $1, %rax
	syscall
	movq %rax, 16(%rbx)

	movq $9999, %rax
	syscall
	movq %rax, 24(%rbx)

	movq $1, %rdi
	movq %rbp, %rsi
	movq $8, %rdx
	movq $2, %rax
	syscall
	movq %rax, 32(%rbx)

	movq $4, %rdi
	movq $3, %rax
	syscall
	movq %rax, 40(%rbx)

	movq $0x1234, %r8
	movq $0x5678, %r12
	movq $0x9ABC, %rax
	movq %rax, %xmm0
	xorl %edi, %edi
	movq $0, %rax
	syscall
	movq %r8, 48(%rbx)
	movq %r12, 56(%rbx)
	movq %xmm0, %rax
	movq %rax, 64(%rbx)

	xorl %eax, %eax
	movq $20000000, %rcx
3:
	incq %rax
	decq %rcx
	jnz 3b
	movq %rax, 72(%rbx)

	xorl %edi, %edi
	movq $4, %rax
	syscall
	ud2
.globl vectra_user_probe_end
vectra_user_probe_end:

.balign 16
.globl vectra_user_shadow
vectra_user_shadow:
	movq %rdi, %rbx
	movabsq $0x5348414453484144, %rax
	movq %rax, (%rbx)
	movq $100000000, %rcx
1:
	movq 16(%rbx), %rsi
	testq %rsi, %rsi
	jnz 2f
	decq %rcx
	jnz 1b
	movq $1, %rdi
	movq $4, %rax
	syscall
	ud2
2:
	movq $1, %rdi
	movq $8, %rdx
	movq $2, %rax
	syscall
	movq %rax, 8(%rbx)
	xorl %edi, %edi
	movq $4, %rax
	syscall
	ud2
.globl vectra_user_shadow_end
vectra_user_shadow_end:

.balign 16
.globl vectra_user_namer
vectra_user_namer:
	movq %rdi, %rbx
	movq %rsi, %rbp
	movq %rdx, %r12
	movabsq $0x4E414D454E414D45, %rax
	movq %rax, (%rbx)

	leaq 128(%rbx), %rdi
	movq %rbp, %rsi
	movq $1, %rdx
	movq $5, %rax
	syscall
	movq %rax, 8(%rbx)
	movq %rax, %r13

	movq %r13, %rdi
	leaq 256(%rbx), %rsi
	movq %r12, %rdx
	movq $2, %rax
	syscall
	movq %rax, 16(%rbx)

	movq %r13, %rdi
	movq $6, %rax
	syscall
	movq %rax, 24(%rbx)

	movq %r13, %rdi
	leaq 256(%rbx), %rsi
	movq %r12, %rdx
	movq $2, %rax
	syscall
	movq %rax, 32(%rbx)

	leaq 320(%rbx), %rdi
	movq %rbp, %rsi
	xorl %edx, %edx
	movq $5, %rax
	syscall
	movq %rax, 40(%rbx)

	xorl %edi, %edi
	movq $4, %rax
	syscall
	ud2
.globl vectra_user_namer_end
vectra_user_namer_end:

.balign 16
.globl vectra_user_reader
vectra_user_reader:
	movq %rdi, %rbx
	movq %rsi, %rbp
	movabsq $0x5245414452454144, %rax
	movq %rax, (%rbx)
	movq $-1, %rax
	movq %rax, 64(%rbx)

	leaq 128(%rbx), %rdi
	movq %rbp, %rsi
	xorl %edx, %edx
	movq $5, %rax
	syscall
	movq %rax, 8(%rbx)
	movq %rax, %r13

	movq %r13, %rdi
	leaq 64(%rbx), %rsi
	movq $8, %rdx
	movq $7, %rax
	syscall
	movq %rax, 16(%rbx)

	movq %r13, %rdi
	movq $0x400000, %rsi
	movq $8, %rdx
	movq $7, %rax
	syscall
	movq %rax, 24(%rbx)

	movq %r13, %rdi
	movq $6, %rax
	syscall
	movq %rax, 32(%rbx)

	xorl %edi, %edi
	movq $4, %rax
	syscall
	ud2
.globl vectra_user_reader_end
vectra_user_reader_end:

.balign 16
.globl vectra_user_binder
vectra_user_binder:
	movq %rdi, %rbx
	movq %rsi, %rbp
	movq %rdx, %r12
	movabsq $0x42494E4442494E44, %rax
	movq %rax, (%rbx)

	leaq 128(%rbx), %rdi
	movq %rbp, %rsi
	leaq 192(%rbx), %rdx
	movq %rbp, %r10
	xorl %r8d, %r8d
	movq $8, %rax
	syscall
	movq %rax, 8(%rbx)

	leaq 192(%rbx), %rdi
	movq %rbp, %rsi
	movq $1, %rdx
	movq $5, %rax
	syscall
	movq %rax, 16(%rbx)
	movq %rax, %r13

	movq %r13, %rdi
	leaq 256(%rbx), %rsi
	movq %r12, %rdx
	movq $2, %rax
	syscall
	movq %rax, 24(%rbx)

	movq %r13, %rdi
	movq $6, %rax
	syscall
	movq %rax, 32(%rbx)

	movq $1, %rdi
	leaq 256(%rbx), %rsi
	movq %r12, %rdx
	movq $2, %rax
	syscall
	movq %rax, 40(%rbx)

	xorl %edi, %edi
	movq $4, %rax
	syscall
	ud2
.globl vectra_user_binder_end
vectra_user_binder_end:

.balign 16
.globl vectra_user_parent
vectra_user_parent:
	movq %rdi, %rbx
	movabsq $0x50524E5450524E54, %rax
	movq %rax, (%rbx)

	leaq 4f(%rip), %rdi
	movq $10, %rsi
	movq $1, %rdx
	movq $10, %rax
	syscall
	movq %rax, 8(%rbx)
	movq %rax, %r13

	movq %r13, %rdi
	movq $11, %rax
	syscall
	movq %rax, 16(%rbx)

	movq %r13, %rdi
	movq $11, %rax
	syscall
	movq %rax, 24(%rbx)

	leaq 5f(%rip), %rdi
	movq $9, %rsi
	leaq 6f(%rip), %rdx
	movq $9, %r10
	xorl %r8d, %r8d
	movq $8, %rax
	syscall
	movq %rax, 32(%rbx)

	leaq 4f(%rip), %rdi
	movq $10, %rsi
	movq $1, %rdx
	movq $10, %rax
	syscall
	movq %rax, 40(%rbx)
	movq %rax, %r13

	movq %r13, %rdi
	movq $11, %rax
	syscall
	movq %rax, 48(%rbx)

	leaq 7f(%rip), %rdi
	movq $12, %rsi
	movq $1, %rdx
	movq $10, %rax
	syscall
	movq %rax, 56(%rbx)

	xorl %edi, %edi
	movq $4, %rax
	syscall
	ud2
4:
	.ascii "/bin/child"
5:
	.ascii "/dev/null"
6:
	.ascii "/dev/cons"
7:
	.ascii "/bin/no-such"
.globl vectra_user_parent_end
vectra_user_parent_end:

.balign 16
.globl vectra_user_child
vectra_user_child:
	movq %rdi, %rbx
	movabsq $0x43484C4443484C44, %rax
	movq %rax, (%rbx)

	leaq 8f(%rip), %rdi
	movq $9, %rsi
	movq $1, %rdx
	movq $5, %rax
	syscall
	movq %rax, 8(%rbx)
	movq %rax, %r13

	movq %r13, %rdi
	leaq 9f(%rip), %rsi
	movq $29, %rdx
	movq $2, %rax
	syscall
	movq %rax, 16(%rbx)

	movq %r13, %rdi
	movq $6, %rax
	syscall
	movq %rax, 24(%rbx)

	movq %r13, %rdi
	shlq $8, %rdi
	orq 16(%rbx), %rdi
	movq $4, %rax
	syscall
	ud2
8:
	.ascii "/dev/cons"
9:
	.ascii "-- a process started this one"
.globl vectra_user_child_end
vectra_user_child_end:

.balign 16
.globl vectra_user_poster
vectra_user_poster:
	movq %rdi, %rbx
	movabsq $0x504F5354504F5354, %rax
	movq %rax, (%rbx)

	leaq 10f(%rip), %rdi
	movq $9, %rsi
	movq $1, %rdx
	movq $5, %rax
	syscall
	movq %rax, 8(%rbx)

	leaq 11f(%rip), %rdi
	movq $10, %rsi
	movq $1, %rdx
	movq $384, %r10
	movq $12, %rax
	syscall
	movq %rax, 16(%rbx)
	movq %rax, %r14

	movq %r14, %rdi
	leaq 14f(%rip), %rsi
	movq $1, %rdx
	movq $2, %rax
	syscall
	movq %rax, 24(%rbx)

	movq %r14, %rdi
	leaq 14f(%rip), %rsi
	movq $1, %rdx
	movq $2, %rax
	syscall
	movq %rax, 32(%rbx)

	movq %r14, %rdi
	movq $6, %rax
	syscall
	movq %rax, 40(%rbx)

	leaq 11f(%rip), %rdi
	movq $10, %rsi
	leaq 12f(%rip), %rdx
	movq $4, %r10
	xorl %r8d, %r8d
	movq $13, %rax
	syscall
	movq %rax, 48(%rbx)

	leaq 13f(%rip), %rdi
	movq $9, %rsi
	movq $1, %rdx
	movq $5, %rax
	syscall
	movq %rax, 56(%rbx)
	movq %rax, %r15

	movq %r15, %rdi
	leaq 15f(%rip), %rsi
	movq $42, %rdx
	movq $2, %rax
	syscall
	movq %rax, 64(%rbx)

	leaq 11f(%rip), %rdi
	movq $10, %rsi
	movq $14, %rax
	syscall
	movq %rax, 72(%rbx)

	leaq 11f(%rip), %rdi
	movq $10, %rsi
	movq $1, %rdx
	movq $5, %rax
	syscall
	movq %rax, 80(%rbx)

	leaq 16f(%rip), %rdi
	movq $9, %rsi
	movq $1, %rdx
	movq $5, %rax
	syscall
	movq %rax, 88(%rbx)
	movq %rax, %rdi
	leaq 15f(%rip), %rsi
	movq $42, %rdx
	movq $2, %rax
	syscall
	movq %rax, 96(%rbx)

	xorl %edi, %edi
	movq $4, %rax
	syscall
	ud2
10:
	.ascii "/dev/cons"
11:
	.ascii "/srv/cons2"
12:
	.ascii "/mnt"
13:
	.ascii "/mnt/cons"
14:
	.ascii "3"
15:
	.ascii "-- this line went through a posted service"
16:
	.ascii "/mnt/null"
.globl vectra_user_poster_end
vectra_user_poster_end:

/*
niner -- the first 9P server that is a program.

It makes a pipe, posts the client end in /srv, and then answers requests it
reads off the serve end. It answers version, attach, walk and open, and
forwards a write's payload to the console. It answers a read from its own
text, and the remove tells it to stop. The replies are built byte by byte
over the request, because a program this small carries no codec. The frame
layout is the 9P2000.L wire format, and docs/VECTRA9.md is the reference.

Register roles, for reading the loop:

    rbx    the data page
    r12    the frame buffer, at rbx+256
    r13    the serve descriptor
    r14    the current frame's size
    r15    the served count
    rbp    the read cursor, and then the stop flag
    r8/r9  the send cursor and length, in registers a system call preserves
*/
.balign 16
.globl vectra_user_niner
vectra_user_niner:
	movq %rdi, %rbx
	movabsq $0x4E494E454E494E45, %rax
	movq %rax, (%rbx)
	leaq 256(%rbx), %r12

	movq $15, %rax
	syscall
	movq %rax, 8(%rbx)
	movq %rax, %r13
	andq $255, %r13
	movq 8(%rbx), %r14
	shrq $8, %r14
	andq $255, %r14

	leaq 20f(%rip), %rdi
	movq $10, %rsi
	movq $1, %rdx
	movq $384, %r10
	movq $12, %rax
	syscall
	movq %rax, 16(%rbx)
	movq %rax, %r15

	movq %r15, %rdi
	leaq 21f(%rip), %rsi
	movq $1, %rdx
	movq $2, %rax
	syscall
	movq %rax, 24(%rbx)

	movq %r15, %rdi
	movq $6, %rax
	syscall
	movq %rax, 32(%rbx)

	movq %r14, %rdi
	movq $6, %rax
	syscall
	movq %rax, 40(%rbx)

	xorl %r15d, %r15d
23:
	xorl %ebp, %ebp
24:
	movq %r13, %rdi
	leaq (%r12,%rbp), %rsi
	movq $7, %rdx
	subq %rbp, %rdx
	movq $7, %rax
	syscall
	testq %rax, %rax
	jle 38f
	addq %rax, %rbp
	cmpq $7, %rbp
	jb 24b

	movl (%r12), %r14d
	cmpq $256, %r14
	ja 38f
	cmpq $7, %r14
	jb 38f
25:
	cmpq %r14, %rbp
	jae 26f
	movq %r13, %rdi
	leaq (%r12,%rbp), %rsi
	movq %r14, %rdx
	subq %rbp, %rdx
	movq $7, %rax
	syscall
	testq %rax, %rax
	jle 38f
	addq %rax, %rbp
	jmp 25b
26:
	xorl %ebp, %ebp
	movzbl 4(%r12), %eax
	cmpl $100, %eax
	je 27f
	cmpl $104, %eax
	je 28f
	cmpl $110, %eax
	je 29f
	cmpl $12, %eax
	je 31f
	cmpl $118, %eax
	je 32f
	cmpl $116, %eax
	je 33f
	cmpl $120, %eax
	je 35f
	cmpl $122, %eax
	je 36f
	movl $11, (%r12)
	movb $7, 4(%r12)
	movl $95, 7(%r12)
	movq $11, %rdx
	jmp 37f
27:
	movb $101, 4(%r12)
	movq %r14, %rdx
	jmp 37f
28:
	movl $20, (%r12)
	movb $105, 4(%r12)
	movb $0x80, 7(%r12)
	movl $0, 8(%r12)
	movq $1, 12(%r12)
	movq $20, %rdx
	jmp 37f
29:
	movzwl 15(%r12), %ecx
	movb $111, 4(%r12)
	movw %cx, 7(%r12)
	leaq 9(%r12), %rsi
30:
	testl %ecx, %ecx
	jz 39f
	movb $0, (%rsi)
	movl $0, 1(%rsi)
	movq $2, 5(%rsi)
	addq $13, %rsi
	decl %ecx
	jmp 30b
39:
	movzwl 7(%r12), %eax
	imull $13, %eax, %eax
	addl $9, %eax
	movl %eax, (%r12)
	movl %eax, %edx
	jmp 37f
31:
	movl $24, (%r12)
	movb $13, 4(%r12)
	movb $0, 7(%r12)
	movl $0, 8(%r12)
	movq $2, 12(%r12)
	movl $0, 20(%r12)
	movq $24, %rdx
	jmp 37f
32:
	movl 19(%r12), %edx
	movq $1, %rdi
	leaq 23(%r12), %rsi
	movq $2, %rax
	syscall
	movl 19(%r12), %eax
	movl %eax, 7(%r12)
	movl $11, (%r12)
	movb $119, 4(%r12)
	movq $11, %rdx
	jmp 37f
33:
	movl $39, (%r12)
	movb $117, 4(%r12)
	movl $28, 7(%r12)
	leaq 22f(%rip), %rsi
	leaq 11(%r12), %rdi
	movq $28, %rcx
34:
	movb (%rsi), %al
	movb %al, (%rdi)
	incq %rsi
	incq %rdi
	decq %rcx
	jnz 34b
	movq $39, %rdx
	jmp 37f
35:
	movl $7, (%r12)
	movb $121, 4(%r12)
	movq $7, %rdx
	jmp 37f
36:
	movl $7, (%r12)
	movb $123, 4(%r12)
	movq $7, %rdx
	movq $1, %rbp
37:
	incq %r15
	movq %r15, 48(%rbx)
	movq %rdx, %r9
	xorl %r8d, %r8d
40:
	movq %r13, %rdi
	leaq (%r12,%r8), %rsi
	movq %r9, %rdx
	subq %r8, %rdx
	movq $2, %rax
	syscall
	testq %rax, %rax
	jle 38f
	addq %rax, %r8
	cmpq %r9, %r8
	jb 40b
	testq %rbp, %rbp
	jnz 41f
	jmp 23b
38:
	movq $0x77, %rdi
	movq $4, %rax
	syscall
	ud2
41:
	xorl %edi, %edi
	movq $4, %rax
	syscall
	ud2
20:
	.ascii "/srv/niner"
21:
	.ascii "4"
22:
	.ascii "these bytes came from ring 3"
.globl vectra_user_niner_end
vectra_user_niner_end:

/*
noter -- a process that ends another one.

Spawn /bin/spin, which never makes a system call and never stops on its
own. Note it, and wait: the answer is -EINTR, the kernel's word for a note
that ended a child. Then note pid 9999, which is nobody's child, and record
the ECHILD. Each answer lands in its cell, in call order, as always.
*/
.balign 16
.globl vectra_user_noter
vectra_user_noter:
	movq %rdi, %rbx
	movabsq $0x4E4F54524E4F5452, %rax
	movq %rax, (%rbx)

	leaq 24f(%rip), %rdi
	movq $9, %rsi
	movq $1, %rdx
	movq $10, %rax
	syscall
	movq %rax, 8(%rbx)
	movq %rax, %r13

	movq %r13, %rdi
	leaq 25f(%rip), %rsi
	movq $4, %rdx
	movq $16, %rax
	syscall
	movq %rax, 16(%rbx)

	movq %r13, %rdi
	movq $11, %rax
	syscall
	movq %rax, 24(%rbx)

	movq $9999, %rdi
	leaq 25f(%rip), %rsi
	movq $4, %rdx
	movq $16, %rax
	syscall
	movq %rax, 32(%rbx)

	xorl %edi, %edi
	movq $4, %rax
	syscall
	ud2
24:
	.ascii "/bin/spin"
25:
	.ascii "stop"
.globl vectra_user_noter_end
vectra_user_noter_end:

.balign 16
.globl vectra_user_grouper
vectra_user_grouper:
	movq %rdi, %rbx
	movabsq $0x4752555047525550, %rax
	movq %rax, (%rbx)

	movq $0x30, %rdi
	movq $17, %rax
	syscall
	testq %rax, %rax
	jnz 60f
	movq $400000000, %rcx
61:
	incq 64(%rbx)
	decq %rcx
	jnz 61b
	movq $0x7C, %rdi
	movq $4, %rax
	syscall
	ud2
60:
	movq %rax, 8(%rbx)
	movq %rax, %r12

	movq $0x38, %rdi
	movq $17, %rax
	syscall
	testq %rax, %rax
	jnz 62f
	movq $400000000, %rcx
63:
	incq 72(%rbx)
	decq %rcx
	jnz 63b
	movq $0x7D, %rdi
	movq $4, %rax
	syscall
	ud2
62:
	movq %rax, 16(%rbx)
	movq %rax, %r13

	movq $2, %rdi
	movq $3, %rax
	syscall

	xorl %edi, %edi
	leaq 64f(%rip), %rsi
	movq $3, %rdx
	movq $25, %rax
	syscall
	movq %rax, 24(%rbx)

	movq %r12, %rdi
	movq $11, %rax
	syscall
	movq %rax, 32(%rbx)

	movq 72(%rbx), %r14
	movq $2, %rdi
	movq $3, %rax
	syscall
	movq 72(%rbx), %r15
	subq %r14, %r15
	movq %r15, 40(%rbx)

	movq %r13, %rdi
	leaq 64f(%rip), %rsi
	movq $3, %rdx
	movq $16, %rax
	syscall
	movq %rax, 48(%rbx)

	movq %r13, %rdi
	movq $11, %rax
	syscall
	movq %rax, 56(%rbx)

	xorl %edi, %edi
	movq $4, %rax
	syscall
	ud2
64:
	.ascii "die"
.globl vectra_user_grouper_end
vectra_user_grouper_end:

.balign 16
.globl vectra_user_forker
vectra_user_forker:
	movq %rdi, %rbx
	movabsq $0x464F524B464F524B, %rax
	movq %rax, (%rbx)

	movq $10, 32(%rbx)

	movq $0x10, %rdi
	movq $17, %rax
	syscall
	testq %rax, %rax
	jnz 26f

	incq 32(%rbx)
	movq 32(%rbx), %rdi
	movq $4, %rax
	syscall
	ud2
26:
	movq %rax, 8(%rbx)
	movq %rax, %rdi
	movq $11, %rax
	syscall
	movq %rax, 24(%rbx)

	xorl %edi, %edi
	movq $4, %rax
	syscall
	ud2
.globl vectra_user_forker_end
vectra_user_forker_end:

.balign 16
.globl vectra_user_memfork
vectra_user_memfork:
	movq %rdi, %rbx
	movabsq $0x4D454D464D454D46, %rax
	movq %rax, (%rbx)

	movq $0x30, %rdi
	movq $17, %rax
	syscall
	testq %rax, %rax
	jnz 27f

	movabsq $0xC0FFEEC0FFEE, %rax
	movq %rax, 16(%rbx)
	movq $400000000, %rcx
28:
	movq 24(%rbx), %rax
	testq %rax, %rax
	jnz 29f
	decq %rcx
	jnz 28b
	movq $0x99, %rdi
	movq $4, %rax
	syscall
29:
	xorl %edi, %edi
	movq $4, %rax
	syscall
	ud2
27:
	movq %rax, 8(%rbx)
	movq $42, %rdi
	movq $4, %rax
	syscall
	ud2
.globl vectra_user_memfork_end
vectra_user_memfork_end:

.balign 16
.globl vectra_user_fdforker
vectra_user_fdforker:
	movq %rdi, %rbx
	movabsq $0x4644464B4644464B, %rax
	movq %rax, (%rbx)

	movq %rsi, %rdi
	movq $17, %rax
	syscall
	testq %rax, %rax
	jnz 30f

	movq $1, %rdi
	movq $6, %rax
	syscall
	xorl %edi, %edi
	movq $4, %rax
	syscall
	ud2
30:
	movq %rax, %rdi
	movq $11, %rax
	syscall
	movq %rax, 16(%rbx)

	movq $1, %rdi
	movq $6, %rax
	syscall
	movq %rax, 24(%rbx)

	xorl %edi, %edi
	movq $4, %rax
	syscall
	ud2
.globl vectra_user_fdforker_end
vectra_user_fdforker_end:

.balign 16
.globl vectra_user_refuser
vectra_user_refuser:
	movq %rdi, %rbx
	movabsq $0x5245465552454655, %rax
	movq %rax, (%rbx)

	movq $0x2, %rdi
	movq $17, %rax
	syscall
	movq %rax, 8(%rbx)

	movq $0x40, %rdi
	movq $17, %rax
	syscall
	movq %rax, 16(%rbx)

	movq $0x20, %rdi
	movq $17, %rax
	syscall
	movq %rax, 24(%rbx)

	movq $0x1014, %rdi
	movq $17, %rax
	syscall
	movq %rax, 32(%rbx)

	movq $0x4000, %rdi
	movq $17, %rax
	syscall
	movq %rax, 40(%rbx)

	xorl %edi, %edi
	movq $17, %rax
	syscall
	movq %rax, 48(%rbx)

	movq $0x8, %rdi
	movq $17, %rax
	syscall
	movq %rax, 56(%rbx)

	xorl %edi, %edi
	movq $4, %rax
	syscall
	ud2
.globl vectra_user_refuser_end
vectra_user_refuser_end:

.balign 16
.globl vectra_user_painter
vectra_user_painter:
	movq %rdi, %rbx
	movq %rsi, %rbp
	movq %rdx, %r12
	movabsq $0x5041494E5041494E, %rax
	movq %rax, (%rbx)

	leaq 128(%rbx), %rdi
	movq %rbp, %rsi
	movq $2, %rdx
	movq $5, %rax
	syscall
	movq %rax, 8(%rbx)
	movq %rax, %r13

	movq 192(%rbx), %r14
	movq %r13, %rdi
	movq %r14, %rsi
	movq $9, %rax
	syscall
	movq %rax, 16(%rbx)

	movq %r13, %rdi
	leaq 256(%rbx), %rsi
	movq %r12, %rdx
	movq $2, %rax
	syscall
	movq %rax, 24(%rbx)

	movq %r13, %rdi
	leaq 256(%rbx), %rsi
	movq %r12, %rdx
	movq $2, %rax
	syscall
	movq %rax, 32(%rbx)

	movq %r13, %rdi
	movq %r14, %rsi
	movq $9, %rax
	syscall
	movq %rax, 40(%rbx)

	movq %r13, %rdi
	leaq 320(%rbx), %rsi
	movq %r12, %rdx
	movq $7, %rax
	syscall
	movq %rax, 48(%rbx)

	movq %r13, %rdi
	movq $6, %rax
	syscall
	movq %rax, 56(%rbx)

	xorl %edi, %edi
	movq $4, %rax
	syscall
	ud2
.globl vectra_user_painter_end
vectra_user_painter_end:

.balign 16
.globl vectra_user_catcher
vectra_user_catcher:
	movq %rdi, %rbx
	movabsq $0x4354434843544348, %rax
	movq %rax, (%rbx)

	movq $1, %rdi
	movq $19, %rax
	syscall
	movq %rax, 8(%rbx)

	leaq 45f(%rip), %rdi
	movq $18, %rax
	syscall
	movq %rax, 16(%rbx)

	movabsq $0x13C0FFEE13C0FFEE, %r13
	movq $400000000, %rcx
43:
	incq 24(%rbx)
	cmpq $1, 32(%rbx)
	jae 44f
	decq %rcx
	jnz 43b
	movq $0x7A, %rdi
	movq $4, %rax
	syscall
	ud2
44:
	movq $2000, %rcx
46:
	cmpq $2, 32(%rbx)
	jae 47f
	movq $1, %rdi
	movq $3, %rax
	syscall
	decq %rcx
	jnz 46b
	movq $0x7B, %rdi
	movq $4, %rax
	syscall
	ud2
47:
	movq %r13, 48(%rbx)
	xorl %edi, %edi
	movq $4, %rax
	syscall
	ud2
45:
	incq 32(%rbx)
	movq (%rsi), %rax
	movq %rax, 40(%rbx)
	xorq %r13, %r13
	movq $1, %rdi
	movq $19, %rax
	syscall
	ud2
.globl vectra_user_catcher_end
vectra_user_catcher_end:

.balign 16
.globl vectra_user_dfltnote
vectra_user_dfltnote:
	movq %rdi, %rbx
	movabsq $0x44464C5444464C54, %rax
	movq %rax, (%rbx)

	leaq 49f(%rip), %rdi
	movq $18, %rax
	syscall
	movq %rax, 8(%rbx)

	movq $400000000, %rcx
48:
	incq 16(%rbx)
	decq %rcx
	jnz 48b
	movq $0x7A, %rdi
	movq $4, %rax
	syscall
	ud2
49:
	incq 24(%rbx)
	movq $2, %rdi
	movq $19, %rax
	syscall
	ud2
.globl vectra_user_dfltnote_end
vectra_user_dfltnote_end:

.balign 16
.globl vectra_user_execer
vectra_user_execer:
	movq %rdi, %rbx
	movabsq $0x4558454345584543, %rax
	movq %rax, (%rbx)

	leaq 50f(%rip), %rdi
	movq $10, %rsi
	movq $20, %rax
	syscall

	movq %rax, 8(%rbx)
	movq $0x66, %rdi
	movq $4, %rax
	syscall
	ud2
50:
	.ascii "/bin/child"
.globl vectra_user_execer_end
vectra_user_execer_end:

.balign 16
.globl vectra_user_nowaiter
vectra_user_nowaiter:
	movq %rdi, %rbx
	movabsq $0x4E4F57414E4F5741, %rax
	movq %rax, (%rbx)

	movq $0x50, %rdi
	movq $17, %rax
	syscall
	testq %rax, %rax
	jnz 51f

	movq $1, 64(%rbx)
	movq $400000000, %rcx
56:
	cmpq $0, 72(%rbx)
	jne 57f
	decq %rcx
	jnz 56b
57:
	movq $0x5A, %rdi
	movq $4, %rax
	syscall
	ud2
51:
	movq %rax, 8(%rbx)
	movq %rax, %rdi
	movq $11, %rax
	syscall
	movq %rax, 16(%rbx)
	xorl %edi, %edi
	movq $4, %rax
	syscall
	ud2
.globl vectra_user_nowaiter_end
vectra_user_nowaiter_end:

.balign 16
.globl vectra_user_bulkio
vectra_user_bulkio:
	movq %rdi, %rbx
	movq %rsi, %rbp
	movq %rdx, %r12
	movabsq $0x42554C4B42554C4B, %rax
	movq %rax, (%rbx)

	leaq 32(%rbx), %rdi
	movq %rbp, %rsi
	movq $2, %rdx
	movq $5, %rax
	syscall
	movq %rax, 8(%rbx)
	movq %rax, %r13

	movq %r13, %rdi
	movq %r12, %rsi
	movq $9, %rax
	syscall

	movq %r13, %rdi
	leaq 96(%rbx), %rsi
	movq $4000, %rdx
	movq $2, %rax
	syscall
	movq %rax, 16(%rbx)

	movq %r13, %rdi
	movq %r12, %rsi
	movq $9, %rax
	syscall

	movq %r13, %rdi
	leaq 96(%rbx), %rsi
	movq $4000, %rdx
	movq $7, %rax
	syscall
	movq %rax, 24(%rbx)

	movq %r13, %rdi
	movq $6, %rax
	syscall

	xorl %edi, %edi
	movq $4, %rax
	syscall
	ud2
.globl vectra_user_bulkio_end
vectra_user_bulkio_end:

.balign 16
.globl vectra_user_mapper
vectra_user_mapper:
	movq %rdi, %rbx
	movq %rsi, %rbp
	movabsq $0x4D4150504D415050, %rax
	movq %rax, (%rbx)

	leaq 128(%rbx), %rdi
	movq $7, %rsi
	movq $1, %rdx
	movq $5, %rax
	syscall
	movq %rax, 8(%rbx)
	movq %rax, %r13

	movq %r13, %rdi
	movq $21, %rax
	syscall
	movq %rax, 16(%rbx)
	movq %rax, %r12

	movl $0x00FF00FF, (%r12,%rbp,1)

	movq %r13, %rdi
	movq $21, %rax
	syscall
	movq %rax, 24(%rbx)
	movq %rax, %r15

	leaq 0x2000(%r15), %rsi
	movq %r15, %rdi
	movq $23, %rax
	syscall
	movq %rax, 48(%rbx)

	movq %r15, %rdi
	movq $24, %rax
	syscall
	movq %rax, 56(%rbx)

	movq $99, %rdi
	movq $21, %rax
	syscall
	movq %rax, 32(%rbx)

	leaq 192(%rbx), %rdi
	movq $9, %rsi
	movq $1, %rdx
	movq $5, %rax
	syscall
	movq %rax, %r14

	movq %r14, %rdi
	movq $21, %rax
	syscall
	movq %rax, 40(%rbx)

	xorl %edi, %edi
	movq $4, %rax
	syscall
	ud2
.globl vectra_user_mapper_end
vectra_user_mapper_end:

.balign 16
.globl vectra_user_anon
vectra_user_anon:
	movq %rdi, %rbx
	movq %rsi, %rbp
	movabsq $0x414E4F4E414E4F4E, %rax
	movq %rax, (%rbx)

	movq %rbp, %rdi
	xorl %esi, %esi
	movq $22, %rax
	syscall
	movq %rax, 8(%rbx)
	movq %rax, %r12

	movq (%r12), %rax
	movq %rax, 16(%rbx)

	movabsq $0x57494E4457494E44, %rax
	movq %rbp, %rcx
	movq %rax, (%r12)
	movq %rax, -8(%r12,%rcx,1)
	movq -8(%r12,%rcx,1), %rax
	movq %rax, 24(%rbx)

	movq %rbp, %rdi
	xorl %esi, %esi
	movq $22, %rax
	syscall
	movq %rax, 32(%rbx)
	movq %rax, %r14

	movq $400000000, %rcx
54:
	cmpq $0, 96(%rbx)
	jne 55f
	decq %rcx
	jnz 54b
55:
	leaq 0x4000(%r14,%rbp,1), %rsi
	movq %r14, %rdi
	movq $23, %rax
	syscall
	movq %rax, 72(%rbx)

	leaq 0x4000(%r14,%rbp,1), %rcx
	movabsq $0x57494E4457494E44, %rax
	movq %rax, -8(%rcx)
	movq -8(%rcx), %rax
	movq %rax, 80(%rbx)

	leaq 0x2000(%r14,%rbp,1), %rsi
	movq %r14, %rdi
	movq $23, %rax
	syscall
	movq %rax, 88(%rbx)

	# A one-page run X, and a second one-page run Y just above it. r10 keeps X
	# and r15 keeps Y, across the syscalls that clobber only rax, rcx and r11.
	movq $0x1000, %rdi
	xorl %esi, %esi
	movq $22, %rax
	syscall
	movq %rax, 104(%rbx)
	movq %rax, %r10

	movq $0x1000, %rdi
	xorl %esi, %esi
	movq $22, %rax
	syscall
	movq %rax, %r15

	# Detach X, the lower of the two, and leave Y holding the ground above the
	# hole. A monotonic bump would step over Y and never come back for the hole.
	movq %r10, %rdi
	movq $24, %rax
	syscall
	movq %rax, 112(%rbx)

	# Ask again at the same size. First fit finds X's hole below Y and hands it
	# back, so ANON_REUSE equals ANON_THIRD. A bump would answer above Y.
	movq $0x1000, %rdi
	xorl %esi, %esi
	movq $22, %rax
	syscall
	movq %rax, 136(%rbx)
	movq %rax, %r10

	# Give Y and the reused run back, so the frame accounting below nets to zero.
	movq %r15, %rdi
	movq $24, %rax
	syscall
	movq %r10, %rdi
	movq $24, %rax
	syscall

	movq $0x400000, %rdi
	movq $24, %rax
	syscall
	movq %rax, 120(%rbx)

	movq $0x1000, %rdi
	movq $24, %rax
	syscall
	movq %rax, 128(%rbx)

	movq $0x40000000, %rdi
	xorl %esi, %esi
	movq $22, %rax
	syscall
	movq %rax, 40(%rbx)

	xorl %edi, %edi
	xorl %esi, %esi
	movq $22, %rax
	syscall
	movq %rax, 48(%rbx)

	movq $0x10, %rdi
	movq $17, %rax
	syscall
	testq %rax, %rax
	jnz 52f

	movq %rbp, %rdi
	xorl %esi, %esi
	movq $22, %rax
	syscall
	testq %rax, %rax
	js 53f
	movq %rax, %r13
	movabsq $0x0BAD0BAD0BAD0BAD, %rax
	movq %rax, (%r13)
	movabsq $0x57494E4457494E44, %rcx
	cmpq %rcx, (%r12)
	jne 53f
	movabsq $0x0BAD0BAD0BAD0BAD, %rax
	movq %rax, (%r12)
	movq $7, %rdi
	movq $4, %rax
	syscall
	ud2
53:
	movq $8, %rdi
	movq $4, %rax
	syscall
	ud2
52:
	movq %rax, %rdi
	movq $11, %rax
	syscall
	movq %rax, 64(%rbx)

	movq (%r12), %rax
	movq %rax, 56(%rbx)

	xorl %edi, %edi
	movq $4, %rax
	syscall
	ud2
.globl vectra_user_anon_end
vectra_user_anon_end:

/*
 * sharer: a run shared under RFMEM, grown and then shrunk by the parent.
 *
 * The parent takes two pages, forks a sharer, grows the run to three pages,
 * writes a witness into the third, and raises a flag in the data page. The
 * child waits for the flag, reads the witness through its own tables, and
 * writes what it read. The parent then shrinks the run to one page and
 * raises a second flag. The child touches the third page again: a page
 * fault ends it if the shrink reached its tables, and a word in cell 6 says
 * the mapping survived if it did not. Cells are the data page's, shared.
 */
.balign 16
.globl vectra_user_sharer
vectra_user_sharer:
	movq %rdi, %rbx
	movabsq $0x5348415253484152, %rax
	movq %rax, (%rbx)

	movq $8192, %rdi
	xorl %esi, %esi
	movq $22, %rax
	syscall
	testq %rax, %rax
	js 39f
	movq %rax, %r12
	movq %rax, 8(%rbx)

	movq $0x30, %rdi
	movq $17, %rax
	syscall
	testq %rax, %rax
	jnz 35f

	movq $400000000, %rcx
31:
	cmpq $0, 16(%rbx)
	jne 32f
	decq %rcx
	jnz 31b
	movq $0x99, %rdi
	movq $4, %rax
	syscall
32:
	movq 4096(%r12), %rax
	movq %rax, 24(%rbx)
	movq $400000000, %rcx
33:
	cmpq $0, 32(%rbx)
	jne 34f
	decq %rcx
	jnz 33b
	movq $0x9A, %rdi
	movq $4, %rax
	syscall
34:
	movq 4096(%r12), %rax
	movq %rax, 48(%rbx)
	movq $0x9B, %rdi
	movq $4, %rax
	syscall
	ud2

35:
	js 39f
	movq %rax, 40(%rbx)
	movq %r12, %rdi
	leaq 12288(%r12), %rsi
	movq $23, %rax
	syscall
	testq %rax, %rax
	jnz 39f
	movq $0xBEEF, 4096(%r12)
	movq $1, 16(%rbx)
	movq $400000000, %rcx
36:
	cmpq $0, 24(%rbx)
	jne 37f
	decq %rcx
	jnz 36b
	movq $0x97, %rdi
	movq $4, %rax
	syscall
37:
	movq %r12, %rdi
	leaq 4096(%r12), %rsi
	movq $23, %rax
	syscall
	testq %rax, %rax
	jnz 39f
	movq $1, 32(%rbx)
	xorl %edi, %edi
	movq $4, %rax
	syscall
	ud2
39:
	movq $0x98, %rdi
	movq $4, %rax
	syscall
	ud2
.globl vectra_user_sharer_end
vectra_user_sharer_end:

/*
 * sharedseg: the shared class, across a fork without RFMEM and an exec.
 *
 * Two pages: one asked for with SEGSHARED, one without. Both seeded, then
 * a fork with RFPROC alone. The child writes a witness into each and exits.
 * The parent waits, reads both back into the shared page -- the data page
 * will not survive what comes next -- and execs /bin/child. What the kernel
 * finds in the shared page afterwards is the whole answer: the child's
 * witness in the first word, the parent's reading of it in the second, and
 * the private seed untouched in the third.
 */
.balign 16
.globl vectra_user_sharedseg
vectra_user_sharedseg:
	movq %rdi, %rbx

	movq $4096, %rdi
	movq $1, %rsi
	movq $22, %rax
	syscall
	testq %rax, %rax
	js 49f
	movq %rax, %r12

	movq $4096, %rdi
	xorl %esi, %esi
	movq $22, %rax
	syscall
	testq %rax, %rax
	js 49f
	movq %rax, %r13

	movq $0x11, (%r12)
	movq $0x22, (%r13)

	movq $0x10, %rdi
	movq $17, %rax
	syscall
	testq %rax, %rax
	js 49f
	jnz 45f

	movq $0x1111, (%r12)
	movq $0x2222, (%r13)
	xorl %edi, %edi
	movq $4, %rax
	syscall
	ud2

45:
	movq %rax, %rdi
	movq $11, %rax
	syscall
	movq (%r12), %rax
	movq %rax, 8(%r12)
	movq (%r13), %rax
	movq %rax, 16(%r12)

	leaq 50f(%rip), %rdi
	movq $10, %rsi
	movq $20, %rax
	syscall
49:
	movq $0x98, %rdi
	movq $4, %rax
	syscall
	ud2
50:
	.ascii "/bin/child"
.globl vectra_user_sharedseg_end
vectra_user_sharedseg_end:
