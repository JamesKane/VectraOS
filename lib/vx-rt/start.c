// start.c: where the kernel enters a native program, with the task's
// bootstrap channel in the first argument register; it calls vx-rt's
// vx_start (crt1.c), which never returns. crt1.c includes it for a
// first-party program; the native target's sysroot (M6 step 6e2b) compiles it
// alone as crt1.o, its vx_start in libvx.a. The calls name it in assembly,
// so it needs no declaration here.

// The native target's vx_main (the sysroot's crt1.o, built with VX_RT_CRT1):
// C's main with vx-rt's argv, then the C library's exit with its value. In
// the program, beside main and exit, as libvx.so cannot take them (6f1b1).
#ifdef VX_RT_CRT1
int main(int argc, char **argv);
[[noreturn]] void exit(int status);
[[gnu::weak]] void __llvm_libc_thread_main(void); // the C library's, if a program uses threads
char **__swift_vectraos_argv(int *argc);          // libvx's: vx-rt's argv

const char *vx_main(void) {
  if (__llvm_libc_thread_main)
    __llvm_libc_thread_main(); // the first thread's attributes, if <threads.h> is used
  int argc = 0;
  char **argv = __swift_vectraos_argv(&argc);
  exit(main(argc, argv));
}
#endif

#ifdef __x86_64__
[[gnu::naked, noreturn]] void _start(void) {
  __asm__("endbr64\n\t"
          "xorl %ebp, %ebp\n\t"
          "andq $-16, %rsp\n\t"
          "call vx_start\n\t" // the arguments are already in rdi and rsi (ADR-0047)
          "ud2");
}
#else
[[gnu::naked, noreturn]] void _start(void) {
  __asm__("hint #34\n\t" // bti c
          "mov x29, xzr\n\t"
          "mov x30, xzr\n\t"
          "bl vx_start\n\t" // the arguments are already in x0 and x1 (ADR-0047)
          "brk #0");
}
#endif
