// vectors.S (aarch64): the exception vector table (VBAR_EL1).
//
// Each of the 16 entries reserves a trap_frame (arch.c) on the stack, saves x0
// and x1, puts its own index in x1 and branches to trap_common. That saves the
// rest of the registers, the exception syndrome and the user stack pointer
// (SP_EL0), and calls aarch64_trap(frame, index); trap_restore undoes it.
// Exceptions from user mode arrive on SP_EL1, which is the top of the current
// thread's kernel stack. With VHE at EL2, the _el1 names reach the EL2
// registers, so the same code serves both. The file also holds the context
// switch, the new-thread trampoline and arch_enter_frame.

#define FRAME_SIZE 288

.macro ENTRY index
    .p2align 7
    sub sp, sp, #FRAME_SIZE
    stp x0, x1, [sp, #0]
    mov x1, #\index
    b trap_common
.endm

// An exception taken in the kernel checks its stack before pushing anything: a
// kernel stack is the top half of a 32 KiB slot (mm/kstack.c), so a stack
// pointer in it has bit 14 set, and one that has overflowed into the guard
// below has it clear. Pushing there would fault again, for ever. The check
// trades x0 against sp to have a register free, and trades back if all is well.
.macro ENTRY_KERNEL index
    .p2align 7
    sub sp, sp, #FRAME_SIZE
    add sp, sp, x0          // sp = sp' + x0
    sub x0, sp, x0          // x0 = sp'
    tbz x0, #14, kernel_stack_overflow
    sub x0, sp, x0          // x0 = x0 again
    sub sp, sp, x0          // sp = sp' again
    stp x0, x1, [sp, #0]
    mov x1, #\index
    b trap_common
.endm

    .text
    .p2align 11
    .globl aarch64_vectors
aarch64_vectors:
    ENTRY 0     // current EL, SP0: synchronous
    ENTRY 1     //                  IRQ
    ENTRY 2     //                  FIQ
    ENTRY 3     //                  SError
    ENTRY_KERNEL 4 // current EL, SPx: synchronous
    ENTRY_KERNEL 5 //                  IRQ
    ENTRY_KERNEL 6 //                  FIQ
    ENTRY_KERNEL 7 //                  SError
    ENTRY 8     // lower EL, AArch64: synchronous
    ENTRY 9     //                    IRQ
    ENTRY 10    //                    FIQ
    ENTRY 11    //                    SError
    ENTRY 12    // lower EL, AArch32 (never used)
    ENTRY 13
    ENTRY 14
    ENTRY 15

// x0: the stack pointer the frame would have gone to. On a stack of its own,
// the kernel says what happened and stops (arch.c).
kernel_stack_overflow:
    adrp x1, overflow_stack_top
    add x1, x1, :lo12:overflow_stack_top
    mov sp, x1
    bl aarch64_kernel_stack_fault
    brk #0

trap_common:
    stp x2, x3, [sp, #16]
    stp x4, x5, [sp, #32]
    stp x6, x7, [sp, #48]
    stp x8, x9, [sp, #64]
    stp x10, x11, [sp, #80]
    stp x12, x13, [sp, #96]
    stp x14, x15, [sp, #112]
    stp x16, x17, [sp, #128]
    stp x18, x19, [sp, #144]
    stp x20, x21, [sp, #160]
    stp x22, x23, [sp, #176]
    stp x24, x25, [sp, #192]
    stp x26, x27, [sp, #208]
    stp x28, x29, [sp, #224]
    str x30, [sp, #240]
    mrs x2, elr_el1
    mrs x3, spsr_el1
    stp x2, x3, [sp, #248]
    mrs x2, esr_el1
    mrs x3, far_el1
    stp x2, x3, [sp, #264]
    mrs x2, sp_el0
    str x2, [sp, #280]
    mov x0, sp
    bl aarch64_trap
    .globl trap_restore
trap_restore:
    ldr x2, [sp, #280]
    msr sp_el0, x2
    ldp x2, x3, [sp, #248]
    msr elr_el1, x2
    msr spsr_el1, x3
    ldp x2, x3, [sp, #16]
    ldp x4, x5, [sp, #32]
    ldp x6, x7, [sp, #48]
    ldp x8, x9, [sp, #64]
    ldp x10, x11, [sp, #80]
    ldp x12, x13, [sp, #96]
    ldp x14, x15, [sp, #112]
    ldp x16, x17, [sp, #128]
    ldp x18, x19, [sp, #144]
    ldp x20, x21, [sp, #160]
    ldp x22, x23, [sp, #176]
    ldp x24, x25, [sp, #192]
    ldp x26, x27, [sp, #208]
    ldp x28, x29, [sp, #224]
    ldr x30, [sp, #240]
    ldp x0, x1, [sp, #0]
    add sp, sp, #FRAME_SIZE
    eret

// void arch_context_switch(uint64_t *save_sp, uint64_t load_sp)
// Saves the callee-saved registers on this stack, switches stacks, and
// restores the other thread's. A new thread's stack is set up
// (arch_thread_initial_sp) so this "returns" into thread_trampoline.
    .globl arch_context_switch
arch_context_switch:
    hint #34               // bti c
    stp x19, x20, [sp, #-96]!
    stp x21, x22, [sp, #16]
    stp x23, x24, [sp, #32]
    stp x25, x26, [sp, #48]
    stp x27, x28, [sp, #64]
    stp x29, x30, [sp, #80]
    mov x9, sp
    str x9, [x0]
    mov sp, x1
    ldp x21, x22, [sp, #16]
    ldp x23, x24, [sp, #32]
    ldp x25, x26, [sp, #48]
    ldp x27, x28, [sp, #64]
    ldp x29, x30, [sp, #80]
    ldp x19, x20, [sp], #96
    ret

// A new thread's first stop: its thread pointer is in x19.
    .globl thread_trampoline
thread_trampoline:
    hint #36               // bti j: reached by ret, but cheap to mark
    mov x0, x19
    mov x29, xzr
    bl thread_entry
    brk #0

// [[noreturn]] void arch_enter_frame(trap_frame *f): return through a frame
// built in memory, for a thread's first entry into user mode.
    .globl arch_enter_frame
arch_enter_frame:
    hint #34
    mov sp, x0
    b trap_restore

// size_t arch_user_copy(void *dst, const void *src, size_t n): copies to or
// from user memory. A fault inside resumes at arch_user_copy_fault (arch.c,
// aarch64_trap), which returns the bytes not copied: 0 means it all was.
// Eight bytes at a time where dst and src share their alignment (M6 step
// 6c2), bytes otherwise and at the edges; x2 drops only once a load and its
// store are both done, so a fault leaves it exact. Scalar: the unprivileged
// loads and stores 6c5 moves to have no SIMD form (ADR-0035).
    .globl arch_user_copy, arch_user_copy_fault, arch_user_copy_end
arch_user_copy:
    hint #34
    cbz x2, 2f
    eor x3, x0, x1
    tst x3, #7
    b.ne 1f            // not co-aligned: bytes
3:  tst x0, #7         // bytes up to the alignment
    b.eq 4f
    ldrb w3, [x1], #1
    strb w3, [x0], #1
    subs x2, x2, #1
    b.eq 2f
    b 3b
4:  cmp x2, #8
    b.lo 1f
5:  ldr x3, [x1]
    str x3, [x0]
    add x1, x1, #8
    add x0, x0, #8
    sub x2, x2, #8
    cmp x2, #8
    b.hs 5b
    cbz x2, 2f
1:  ldrb w3, [x1], #1  // the rest, a byte at a time
    strb w3, [x0], #1
    subs x2, x2, #1
    b.ne 1b
2:  mov x0, #0
    ret
arch_user_copy_fault:
    mov x0, x2 // counts down as it goes: what is left
    ret
arch_user_copy_end:


// bool arch_user_load32(const uint32_t *src, uint32_t *dst): one aligned 32-bit
// load from user memory (a futex word), whole. A fault returns false.
    .globl arch_user_load32, arch_user_load32_fault
arch_user_load32:
    hint #34
    ldar w2, [x0]
    str w2, [x1]
    mov x0, #1
    ret
arch_user_load32_fault:
    mov x0, #0
    ret

    .bss
    .p2align 4
overflow_stack:
    .skip 8192
overflow_stack_top:
