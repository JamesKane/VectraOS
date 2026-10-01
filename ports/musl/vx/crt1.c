// crt1.c: a musl program's entry point on VectraOS (ADR-0007), in place of
// musl's crt/crt1.c, which reads a Linux initial stack. The kernel enters
// _start as if called (thread_start, abi.h), with the bootstrap channel as
// the argument; the back end reads the spawn message from it and builds what
// musl's __libc_start_main expects (start.c).

#include "vx.h"

#ifdef __x86_64__
[[gnu::naked, noreturn]] void _start(void) {
  __asm__("endbr64\n\t"
          "xorl %ebp, %ebp\n\t"
          "andq $-16, %rsp\n\t"
          "leaq main(%rip), %rsi\n\t"
          "call __vx_start\n\t" // the bootstrap channel is already in rdi
          "ud2");
}
#else
[[gnu::naked, noreturn]] void _start(void) {
  __asm__("bti c\n\t"
          "mov x29, xzr\n\t"
          "mov x30, xzr\n\t"
          "adrp x1, main\n\t"
          "add x1, x1, :lo12:main\n\t"
          "bl __vx_start\n\t" // the bootstrap channel is already in x0
          "brk #0");
}
#endif
