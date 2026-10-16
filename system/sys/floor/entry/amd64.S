// SPDX-License-Identifier: BSD-3-Clause

// A native process's first instructions, and what else Swift can't emit.
// Assembly because nothing else can be: _start is entered with no frame to
// return to (and amd64 C code expects to have been called). System calls
// are croi/syscall.h's inline assembly (D45); the stack guard is lib/rt's.

// _start(bootstrap channel, arg2, vDSO base): croi's first-thread registers.
.section .text._start, "ax"
.globl _start
_start:
  xor %ebp, %ebp
  call td_start
  ud2

// td_thread_block(): the calling thread's block (ThreadBlock, Thread.swift),
// whose first word points to itself: FS's base is set to it
// (object_set_property, CROI_PROP_REGISTER_FS), and %fs:0 reads it back.
.section .text.td_thread_block, "ax"
.globl td_thread_block
td_thread_block:
  mov %fs:0, %rax
  ret

// td_image_header(): the program's ELF header, mapped with its first segment.
.section .text.td_image_header, "ax"
.globl td_image_header
td_image_header:
  lea __ehdr_start(%rip), %rax
  ret

// td_set_thread_pointer(block): amd64 sets FS's base through croi
// (ThreadBlock.install), so this is unused here.
.section .text.td_set_thread_pointer, "ax"
.globl td_set_thread_pointer
td_set_thread_pointer:
  ud2

// td_port_in(port, width) and td_port_out(port, width, value): the I/O
// port instructions, for ports the process requested (ioports_request);
// width 1, 2 or 4.
.section .text.td_port_in, "ax"
.globl td_port_in
td_port_in:
  mov %edi, %edx
  xor %eax, %eax
  cmp $1, %esi
  je 1f
  cmp $2, %esi
  je 2f
  in %dx, %eax
  ret
1:in %dx, %al
  ret
2:in %dx, %ax
  ret

.section .text.td_port_out, "ax"
.globl td_port_out
td_port_out:
  mov %edx, %eax
  mov %edi, %edx
  cmp $1, %esi
  je 1f
  cmp $2, %esi
  je 2f
  out %eax, %dx
  ret
1:out %al, %dx
  ret
2:out %ax, %dx
  ret
