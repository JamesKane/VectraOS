// SPDX-License-Identifier: BSD-3-Clause

// A native process's first instructions, and what else Swift can't emit
// (see amd64.S for why these are assembly).

.section .text._start, "ax"
.globl _start
_start:
  mov x29, #0
  mov x30, #0
  bl td_start
  brk #0

// td_thread_block() and td_set_thread_pointer(tp): TPIDR_EL0, which croi
// keeps per thread; the block is the 64 bytes below it (ELF TLS, variant
// I, is above it: Thread.swift).
.section .text.td_thread_block, "ax"
.globl td_thread_block
td_thread_block:
  mrs x0, tpidr_el0
  sub x0, x0, #64
  ret

// td_image_header(): the program's ELF header, mapped with its first segment.
.section .text.td_image_header, "ax"
.globl td_image_header
td_image_header:
  adrp x0, __ehdr_start
  add x0, x0, :lo12:__ehdr_start
  ret

.section .text.td_set_thread_pointer, "ax"
.globl td_set_thread_pointer
td_set_thread_pointer:
  msr tpidr_el0, x0
  ret
