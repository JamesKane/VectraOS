// vx-rt notes (ADR-0010): Plan 9's notify, in standard C. Defines one external
// symbol, vx_note_entry, the in-task exception handler (hidden: the kernel
// reaches it by address).
//
// A note is a string: one another process posted (thread_interrupt), or a
// fault in Plan 9's words ("sys: trap: fault read addr=0x0 pc=0x401000"). A
// program that calls vx_notify(handler) has each one handed to handler, with
// the vx_exception it came in. The handler answers VX_NCONT, to go on where
// the thread was diverted from, with the registers in the vx_exception
// (perhaps changed), or VX_NDFLT, to end the program with the note as its
// exit string. A program that has not called vx_notify ends with the note at
// once: the kernel sees to that.
//
// A fault that no handler takes is not ended here, though: vx_note_crash
// takes the handler away and runs the instruction again, so it faults with
// nothing in the task to catch it, and goes where any unhandled fault goes:
// the task's exception port (procfs, which saves a crash directory, 05 §5),
// then the kernel's default, which ends the task with the trap's words.
//
// The handler runs on the thread's own stack, below where it was diverted
// from, or on its note stack (ADR-0036). FP/SIMD registers, which the kernel
// does not put in a vx_exception, are saved by vx_note_entry before any C
// runs and loaded again after; the handler is given them as fp, in the
// architecture's image (x86_64's XSAVE standard format, aarch64's vx_fpregs),
// and what it changes there is what the thread goes on with.

#pragma once

#include "base.c"
#include "../vx-note/note.c"

typedef enum vx_noted : uint32_t { VX_NCONT = 0, VX_NDFLT = 1 } vx_noted;
typedef vx_noted vx_note_handler(vx_exception *e, vx_str note, void *fp);

[[gnu::visibility("hidden")]] void vx_note_entry(void);

static vx_note_handler *vx_note_fn;
// How VX_NDFLT ends the program: rt.c's exit, which flushes output first, or
// the musl back end's. Without one, the task just ends.
static void (*vx_note_exit)(vx_str note);

[[noreturn]] static void vx_note_default(vx_str note) {
  if (vx_note_exit) vx_note_exit(note);
  vx_task_kill(vx_self, note);
  vx_thread_exit();
}

// The fault in e again, with no in-task handler: x86_64's int3 reports the
// instruction after it, so the pc goes back to it; every other fault reports
// the instruction itself.
[[noreturn]] static void vx_note_crash(vx_exception *e) {
  vx_exception_bind(vx_self, VX_HANDLE_NONE, 0, VX_EXCEPTION_IN_TASK);
#ifdef __x86_64__
  if (e->kind == VX_EXCEPTION_BREAKPOINT) e->regs.rip--;
#endif
  vx_exception_resume(vx_self, 0, VX_RESUME_CONTINUE, &e->regs);
  __builtin_trap(); // exception_resume does not return
}

[[gnu::used]] static void vx_note_dispatch(vx_exception *e, void *fp) {
  char text[VX_ERRMAX];
  vx_str note;
  if (e->kind == VX_EXCEPTION_INTERRUPT) {
    note = (vx_str){e->note, e->code < VX_ERRMAX ? e->code : VX_ERRMAX};
  } else {
#ifdef __x86_64__
    uint64_t pc = e->regs.rip;
#else
    uint64_t pc = e->regs.pc;
#endif
    note = (vx_str){text, vx_trap_note(e->kind, e->code, e->address, pc, text)};
  }
  vx_note_handler *h = vx_note_fn;
  if (h && h(e, note, fp) == VX_NCONT) return;
  if (e->kind != VX_EXCEPTION_INTERRUPT) vx_note_crash(e); // a fault: where unhandled faults go
  vx_note_default(note);
}

// Resumes the thread where it was diverted from, with the registers it has.
// The protection-key rights the kernel opened key 0 from go back first (ADR-0035).
[[gnu::used, noreturn]] static void vx_note_resume(vx_exception *e) {
  vx_rights_set(e->rights);
  vx_exception_resume(vx_self, 0, VX_RESUME_CONTINUE, &e->regs);
  __builtin_trap(); // exception_resume does not return
}

#ifdef __x86_64__
__asm__(".text\n"
        ".global vx_note_entry\n"
        ".hidden vx_note_entry\n"
        ".type vx_note_entry, @function\n"
        "vx_note_entry:\n"
        "  endbr64\n"
        "  movq %rdi, %rbx\n" // the vx_exception, kept across the calls
        // Every component XCR0 enables, in XSAVE's standard image: at most a
        // page (the kernel's limit, ADR-0035), 64-aligned, its header zeroed
        // by general registers, as XRSTOR wants it and nothing vector may be
        // touched before it is saved.
        "  subq $4160, %rsp\n"
        "  andq $-64, %rsp\n"
        "  movq $0, 512(%rsp)\n  movq $0, 520(%rsp)\n  movq $0, 528(%rsp)\n  movq $0, 536(%rsp)\n"
        "  movq $0, 544(%rsp)\n  movq $0, 552(%rsp)\n  movq $0, 560(%rsp)\n  movq $0, 568(%rsp)\n"
        "  movl $-1, %eax\n  movl $-1, %edx\n"
        "  xsave64 (%rsp)\n"
        "  movq %rbx, %rdi\n"
        "  movq %rsp, %rsi\n" // the saved state, the handler's fp
        "  call vx_note_dispatch\n"
        "  movl $-1, %eax\n  movl $-1, %edx\n"
        "  xrstor64 (%rsp)\n"
        "  movq %rbx, %rdi\n"
        "  call vx_note_resume\n"
        "  ud2\n");
#else
__asm__(".text\n"
        ".global vx_note_entry\n"
        ".hidden vx_note_entry\n"
        ".type vx_note_entry, %function\n"
        "vx_note_entry:\n"
        "  bti c\n"
        "  mov x19, x0\n" // the vx_exception, kept across the calls
        "  sub sp, sp, #528\n"
        "  stp q0, q1, [sp, #0]\n  stp q2, q3, [sp, #32]\n  stp q4, q5, [sp, #64]\n  stp q6, q7, [sp, #96]\n"
        "  stp q8, q9, [sp, #128]\n  stp q10, q11, [sp, #160]\n  stp q12, q13, [sp, #192]\n"
        "  stp q14, q15, [sp, #224]\n  stp q16, q17, [sp, #256]\n  stp q18, q19, [sp, #288]\n"
        "  stp q20, q21, [sp, #320]\n  stp q22, q23, [sp, #352]\n  stp q24, q25, [sp, #384]\n"
        "  stp q26, q27, [sp, #416]\n  stp q28, q29, [sp, #448]\n  stp q30, q31, [sp, #480]\n"
        "  mrs x9, fpcr\n  mrs x10, fpsr\n  add x11, sp, #512\n  stp x9, x10, [x11]\n"
        "  mov x0, x19\n"
        "  mov x1, sp\n" // the saved state, a vx_fpregs: the handler's fp
        "  bl vx_note_dispatch\n"
        "  ldp q0, q1, [sp, #0]\n  ldp q2, q3, [sp, #32]\n  ldp q4, q5, [sp, #64]\n  ldp q6, q7, [sp, #96]\n"
        "  ldp q8, q9, [sp, #128]\n  ldp q10, q11, [sp, #160]\n  ldp q12, q13, [sp, #192]\n"
        "  ldp q14, q15, [sp, #224]\n  ldp q16, q17, [sp, #256]\n  ldp q18, q19, [sp, #288]\n"
        "  ldp q20, q21, [sp, #320]\n  ldp q22, q23, [sp, #352]\n  ldp q24, q25, [sp, #384]\n"
        "  ldp q26, q27, [sp, #416]\n  ldp q28, q29, [sp, #448]\n  ldp q30, q31, [sp, #480]\n"
        "  add x11, sp, #512\n  ldp x9, x10, [x11]\n  msr fpcr, x9\n  msr fpsr, x10\n"
        "  mov x0, x19\n"
        "  bl vx_note_resume\n"
        "  brk #0\n");
#endif

// Hands every note to handler from now on; nullptr goes back to ending the
// program at the first one.
[[maybe_unused]] static vx_status vx_notify(vx_note_handler *handler) {
  vx_note_fn = handler;
  return vx_exception_bind(vx_self, VX_HANDLE_NONE, handler ? (uint64_t)vx_note_entry : 0,
                           VX_EXCEPTION_IN_TASK);
}
