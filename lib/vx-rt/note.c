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
// The handler runs on the thread's own stack, below where it was diverted
// from. FP/SIMD registers, which the kernel does not put in a vx_exception,
// are saved by vx_note_entry before any C runs and loaded again after.

#pragma once

#include "base.c"
#include "../vx-note/note.c"

typedef enum vx_noted : uint32_t { VX_NCONT = 0, VX_NDFLT = 1 } vx_noted;
typedef vx_noted vx_note_handler(vx_exception *e, vx_str note);

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

[[gnu::used]] static void vx_note_dispatch(vx_exception *e) {
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
  if (!h || h(e, note) != VX_NCONT) vx_note_default(note);
}

// Resumes the thread where it was diverted from, with the registers it has.
[[gnu::used, noreturn]] static void vx_note_resume(vx_exception *e) {
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
        "  subq $528, %rsp\n"
        "  andq $-64, %rsp\n"
        "  fxsave64 (%rsp)\n"
        "  call vx_note_dispatch\n"
        "  fxrstor64 (%rsp)\n"
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
