// SPDX-License-Identifier: BSD-3-Clause

// A native process's first instructions, and what else Swift can't emit
// (see amd64.S for why these are assembly).

.section .text._start, "ax"
.globl _start
.weak __global_pointer$
_start:
.option push
.option norelax
  lla gp, __global_pointer$
.option pop
  li fp, 0
  li ra, 0
  call td_start
  unimp

// td_thread_block() and td_set_thread_pointer(tp): tp, which croi keeps
// per thread; the block is the 64 bytes below it (ELF TLS, variant I, is
// above it: Thread.swift).
.section .text.td_thread_block, "ax"
.globl td_thread_block
td_thread_block:
  addi a0, tp, -64
  ret

// td_image_header(): the program's ELF header, mapped with its first segment.
.section .text.td_image_header, "ax"
.globl td_image_header
td_image_header:
  lla a0, __ehdr_start
  ret

.section .text.td_set_thread_pointer, "ax"
.globl td_set_thread_pointer
td_set_thread_pointer:
  mv tp, a0
  ret
