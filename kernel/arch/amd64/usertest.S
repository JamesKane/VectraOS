// The boot self-test's user program (user.h), amd64. Assembly: it runs in
// user mode before there is a user-space toolchain or loader (K8). Copied
// into a VMO, so it must be position independent. rdi selects what it does:
//   0: checks registers survive 1000 null syscalls, exits 0x600D (m2's
//      syscall.null times them: V1 cut the clock syscall, D26);
//   1: loads from an unmapped address (the kernel kills it);
//   2: spins without syscalls for a while, then exits 0x5917 (preemption
//      from user mode);
//   3: executes a privileged instruction (killed).
// Syscalls: 0 null, 2 exit(code).

.section .rodata.user_test, "a", @progbits
.balign 16
.globl croi_user_test_start
croi_user_test_start:
    cmp     $1, %rdi
    je      .Lfault
    cmp     $2, %rdi
    je      .Lspin
    cmp     $3, %rdi
    je      .Lprivileged

    mov     $0x1111, %rbx
    mov     $0x2222, %rbp
    mov     $0x3333, %r12
    mov     $0x4444, %r13
    mov     $0x5555, %r14
    mov     $1000, %ecx
.Lloop:
    push    %rcx
    xor     %eax, %eax              // null
    syscall
    pop     %rcx
    dec     %ecx
    jnz     .Lloop
    cmp     $0x1111, %rbx
    jne     .Lclobbered
    cmp     $0x2222, %rbp
    jne     .Lclobbered
    cmp     $0x3333, %r12
    jne     .Lclobbered
    cmp     $0x4444, %r13
    jne     .Lclobbered
    cmp     $0x5555, %r14
    jne     .Lclobbered
    mov     $0x600d, %edi
    jmp     .Lexit
.Lclobbered:
    mov     $0xbad, %edi
.Lexit:
    mov     $2, %eax
    syscall
    ud2

.Lfault:
    mov     0x10, %rax              // nothing is mapped below 2 MiB
    ud2

.Lspin:
    mov     $400000000, %rcx
1:  dec     %rcx
    jnz     1b
    mov     $0x5917, %edi
    jmp     .Lexit

.Lprivileged:
    hlt
    ud2

.globl croi_user_test_end
croi_user_test_end:
