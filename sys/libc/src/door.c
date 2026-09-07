/*
door.c -- the system call, one instruction per architecture.

`__vsyscall` is the whole of C's side of the door: the call number and six
arguments in the registers the kernel reads, the signed answer back. Each
port writes the same instruction `sys/libuser`'s `sys_<arch>.odin` writes,
in the same convention, so a C program and an Odin program make the same
call the same way.

amd64 is System V's `syscall`: the number in `rax`, the arguments in `rdi`,
`rsi`, `rdx`, `r10`, `r8`, `r9`, and `rcx` and `r11` clobbered by the
instruction. arm64 is `svc #0`: `x8` the number, `x0`..`x5` the arguments,
`x0` the answer. riscv64 is `ecall`: `a7` the number, `a0`..`a5` the
arguments, `a0` the answer.
*/
#include "vlibc.h"

#if defined(__x86_64__)

long __vsyscall(long nr, long a0, long a1, long a2, long a3, long a4, long a5)
{
	register long r10 __asm__("r10") = a3;
	register long r8 __asm__("r8") = a4;
	register long r9 __asm__("r9") = a5;
	long ret;
	__asm__ __volatile__("syscall"
		: "=a"(ret)
		: "a"(nr), "D"(a0), "S"(a1), "d"(a2), "r"(r10), "r"(r8), "r"(r9)
		: "rcx", "r11", "memory");
	return ret;
}

#elif defined(__aarch64__)

long __vsyscall(long nr, long a0, long a1, long a2, long a3, long a4, long a5)
{
	register long x8 __asm__("x8") = nr;
	register long x0 __asm__("x0") = a0;
	register long x1 __asm__("x1") = a1;
	register long x2 __asm__("x2") = a2;
	register long x3 __asm__("x3") = a3;
	register long x4 __asm__("x4") = a4;
	register long x5 __asm__("x5") = a5;
	__asm__ __volatile__("svc #0"
		: "+r"(x0)
		: "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5)
		: "memory");
	return x0;
}

#elif defined(__riscv)

long __vsyscall(long nr, long a0, long a1, long a2, long a3, long a4, long a5)
{
	register long a7 __asm__("a7") = nr;
	register long r0 __asm__("a0") = a0;
	register long r1 __asm__("a1") = a1;
	register long r2 __asm__("a2") = a2;
	register long r3 __asm__("a3") = a3;
	register long r4 __asm__("a4") = a4;
	register long r5 __asm__("a5") = a5;
	__asm__ __volatile__("ecall"
		: "+r"(r0)
		: "r"(a7), "r"(r1), "r"(r2), "r"(r3), "r"(r4), "r"(r5)
		: "memory");
	return r0;
}

#else
#error "no door for this architecture"
#endif
