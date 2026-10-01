// entry.S (x86_64): exception, interrupt and syscall entry, and the context switch.
//
// Each of the 256 vectors has a stub that pushes a zero error code if the CPU
// did not push one, then the vector number. trap_entry swaps GS if the trap
// came from user mode, then trap_save pushes the general registers so the
// stack holds a trap_frame (arch.c) and calls x86_trap. trap_restore undoes it.
// SYSCALL builds the same frame by hand, with vector 0x100.
//
// Per-CPU data (cpu_local in arch.c) is at %gs while in the kernel:
//   %gs:0  the kernel stack top for the current thread
//   %gs:8  scratch for the user stack pointer during SYSCALL

#define HAS_ERROR_CODE(v) ((v) == 8 || ((v) >= 10 && (v) <= 14) || (v) == 17 || (v) == 21 || (v) == 29 || (v) == 30)
#define SEL_USER_DATA 0x1b
#define SEL_USER_CODE 0x23
#define VECTOR_SYSCALL 0x100

.altmacro

.macro STUB v
    .p2align 4
vector_\v:
    endbr64
    .if !HAS_ERROR_CODE(\v)
    pushq $0
    .endif
    pushq $\v
    jmp trap_entry
.endm

.macro TABLE_ENTRY v
    .quad vector_\v
.endm

    .text
trap_entry:
    testb $3, 24(%rsp)     // the saved CS: was the CPU in user mode?
    jz trap_save
    swapgs
trap_save:
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
    movq %rsp, %rdi        // 22 quadwords on a 16-byte aligned stack keep it aligned
    call x86_trap
    .globl trap_restore
trap_restore:
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
    testb $3, 8(%rsp)      // returning to user mode?
    jz 1f
    swapgs
1:  iretq

// SYSCALL: rip in rcx, rflags in r11, interrupts masked by FMASK, still on the
// user stack. Build a trap_frame on the kernel stack and join the common path.
    .p2align 4
    .globl syscall_entry
syscall_entry:
    endbr64
    swapgs
    movq %rsp, %gs:8
    movq %gs:0, %rsp
    pushq $SEL_USER_DATA   // ss
    pushq %gs:8            // rsp
    pushq %r11             // rflags
    pushq $SEL_USER_CODE   // cs
    pushq %rcx             // rip
    pushq $0               // error code
    pushq $VECTOR_SYSCALL
    jmp trap_save

// void arch_context_switch(uint64_t *save_sp, uint64_t load_sp)
// Saves the callee-saved registers on this stack, switches stacks, and
// restores the other thread's. A new thread's stack is set up
// (arch_thread_initial_sp) so this "returns" into thread_trampoline.
    .globl arch_context_switch
arch_context_switch:
    endbr64
    pushq %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    movq %rsp, (%rdi)
    movq %rsi, %rsp
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    ret

// A new thread's first stop: its thread pointer is in r12.
    .globl thread_trampoline
thread_trampoline:
    movq %r12, %rdi
    xorl %ebp, %ebp
    call thread_entry
    ud2

// [[noreturn]] void arch_enter_frame(trap_frame *f): return through a frame
// built in memory, for a thread's first entry into user mode.
    .globl arch_enter_frame
arch_enter_frame:
    movq %rdi, %rsp
    jmp trap_restore

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

// size_t arch_user_copy(void *dst, const void *src, size_t n): copies to or
// from user memory. A fault inside resumes at arch_user_copy_fault (arch.c,
// x86_trap), which returns the bytes not copied: 0 means it all was.
    .text
    .globl arch_user_copy, arch_user_copy_fault, arch_user_copy_end
arch_user_copy:
    endbr64
    mov %rdx, %rcx
    rep movsb
    xor %eax, %eax
    ret
arch_user_copy_fault:
    mov %rcx, %rax // rep movsb counts down as it goes: what is left
    ret
arch_user_copy_end:

// bool arch_user_load32(const uint32_t *src, uint32_t *dst): one aligned 32-bit
// load from user memory (a futex word), whole. A fault returns false.
    .globl arch_user_load32, arch_user_load32_fault
arch_user_load32:
    endbr64
    movl (%rdi), %eax
    movl %eax, (%rsi)
    movl $1, %eax
    ret
arch_user_load32_fault:
    xorl %eax, %eax
    ret
