// SPDX-License-Identifier: BSD-3-Clause

// setjmp and longjmp (C23 §7.13) on rv64: what no compiled language can
// say, saving and restoring the callee-saved registers (ra, sp, s0 to s11,
// and fs0 to fs11 under a hard-float ABI; user code is lp64, soft-float,
// so far) in a jmp_buf (<setjmp.h>, 32 words). longjmp's value is 1 when
// given 0.

.section .text.setjmp, "ax"
.globl setjmp
.type setjmp, @function
.globl _setjmp
.type _setjmp, @function
setjmp:
_setjmp:
  sd ra, 0(a0)
  sd sp, 8(a0)
  sd s0, 16(a0)
  sd s1, 24(a0)
  sd s2, 32(a0)
  sd s3, 40(a0)
  sd s4, 48(a0)
  sd s5, 56(a0)
  sd s6, 64(a0)
  sd s7, 72(a0)
  sd s8, 80(a0)
  sd s9, 88(a0)
  sd s10, 96(a0)
  sd s11, 104(a0)
#ifdef __riscv_float_abi_double
  fsd fs0, 112(a0)
  fsd fs1, 120(a0)
  fsd fs2, 128(a0)
  fsd fs3, 136(a0)
  fsd fs4, 144(a0)
  fsd fs5, 152(a0)
  fsd fs6, 160(a0)
  fsd fs7, 168(a0)
  fsd fs8, 176(a0)
  fsd fs9, 184(a0)
  fsd fs10, 192(a0)
  fsd fs11, 200(a0)
#endif
  li a0, 0
  ret
.size setjmp, . - setjmp

.section .text.longjmp, "ax"
.globl longjmp
.type longjmp, @function
.globl _longjmp
.type _longjmp, @function
longjmp:
_longjmp:
  ld ra, 0(a0)
  ld sp, 8(a0)
  ld s0, 16(a0)
  ld s1, 24(a0)
  ld s2, 32(a0)
  ld s3, 40(a0)
  ld s4, 48(a0)
  ld s5, 56(a0)
  ld s6, 64(a0)
  ld s7, 72(a0)
  ld s8, 80(a0)
  ld s9, 88(a0)
  ld s10, 96(a0)
  ld s11, 104(a0)
#ifdef __riscv_float_abi_double
  fld fs0, 112(a0)
  fld fs1, 120(a0)
  fld fs2, 128(a0)
  fld fs3, 136(a0)
  fld fs4, 144(a0)
  fld fs5, 152(a0)
  fld fs6, 160(a0)
  fld fs7, 168(a0)
  fld fs8, 176(a0)
  fld fs9, 184(a0)
  fld fs10, 192(a0)
  fld fs11, 200(a0)
#endif
  seqz a0, a1
  add a0, a0, a1
  ret
.size longjmp, . - longjmp
