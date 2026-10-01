// entry.S (x86_64): exception and interrupt entry.
//
// Each of the 256 vectors has a stub that pushes a zero error code if the CPU
// did not push one, then the vector number, and jumps to trap_common. That
// saves the general registers below them, so the stack holds a trap_frame
// (arch.c), and calls x86_trap with a pointer to it.

#define HAS_ERROR_CODE(v) ((v) == 8 || ((v) >= 10 && (v) <= 14) || (v) == 17 || (v) == 21 || (v) == 29 || (v) == 30)

.altmacro

.macro STUB v
    .p2align 4
vector_\v:
    endbr64
    .if !HAS_ERROR_CODE(\v)
    pushq $0
    .endif
    pushq $\v
    jmp trap_common
.endm

.macro TABLE_ENTRY v
    .quad vector_\v
.endm

    .text
trap_common:
    pushq %r15
    pushq %r14
    pushq %r13
    pushq %r12
    pushq %r11
    pushq %r10
    pushq %r9
    pushq %r8
    pushq %rbp
    pushq %rdi
    pushq %rsi
    pushq %rdx
    pushq %rcx
    pushq %rbx
    pushq %rax
    cld
    movq %rsp, %rdi        // the CPU aligned the stack to 16 bytes, and 22 pushes keep it aligned
    call x86_trap
    popq %rax
    popq %rbx
    popq %rcx
    popq %rdx
    popq %rsi
    popq %rdi
    popq %rbp
    popq %r8
    popq %r9
    popq %r10
    popq %r11
    popq %r12
    popq %r13
    popq %r14
    popq %r15
    addq $16, %rsp         // the vector number and error code
    iretq

    .set i, 0
    .rept 256
    STUB %i
    .set i, i + 1
    .endr

    .section .rodata
    .p2align 3
    .globl x86_vector_table
x86_vector_table:
    .set i, 0
    .rept 256
    TABLE_ENTRY %i
    .set i, i + 1
    .endr
