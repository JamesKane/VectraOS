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

    .text
    .p2align 11
    .globl aarch64_vectors
aarch64_vectors:
    ENTRY 0     // current EL, SP0: synchronous
    ENTRY 1     //                  IRQ
    ENTRY 2     //                  FIQ
    ENTRY 3     //                  SError
    ENTRY 4     // current EL, SPx: synchronous
    ENTRY 5     //                  IRQ
    ENTRY 6     //                  FIQ
    ENTRY 7     //                  SError
    ENTRY 8     // lower EL, AArch64: synchronous
    ENTRY 9     //                    IRQ
    ENTRY 10    //                    FIQ
    ENTRY 11    //                    SError
    ENTRY 12    // lower EL, AArch32 (never used)
    ENTRY 13
    ENTRY 14
    ENTRY 15

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
