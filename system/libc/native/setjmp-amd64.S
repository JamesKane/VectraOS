// SPDX-License-Identifier: BSD-3-Clause

// setjmp and longjmp (C23 §7.13) on amd64: what no compiled language can
// say, saving and restoring the System V ABI's callee-saved registers
// (rbx, rbp, r12 to r15), the stack pointer as the caller has it after the
// return, and the return address, in a jmp_buf (<setjmp.h>, 32 words).
// longjmp's value is 1 when given 0.

.section .text.setjmp, "ax"
.globl setjmp
.type setjmp, @function
.globl _setjmp
.type _setjmp, @function
setjmp:
_setjmp:
  mov %rbx, 0(%rdi)
  mov %rbp, 8(%rdi)
  mov %r12, 16(%rdi)
  mov %r13, 24(%rdi)
  mov %r14, 32(%rdi)
  mov %r15, 40(%rdi)
  lea 8(%rsp), %rdx
  mov %rdx, 48(%rdi)
  mov (%rsp), %rdx
  mov %rdx, 56(%rdi)
  xor %eax, %eax
  ret
.size setjmp, . - setjmp

.section .text.longjmp, "ax"
.globl longjmp
.type longjmp, @function
.globl _longjmp
.type _longjmp, @function
longjmp:
_longjmp:
  mov %esi, %eax
  test %eax, %eax
  jnz 1f
  inc %eax
1:
  mov 0(%rdi), %rbx
  mov 8(%rdi), %rbp
  mov 16(%rdi), %r12
  mov 24(%rdi), %r13
  mov 32(%rdi), %r14
  mov 40(%rdi), %r15
  mov 48(%rdi), %rsp
  jmp *56(%rdi)
.size longjmp, . - longjmp
