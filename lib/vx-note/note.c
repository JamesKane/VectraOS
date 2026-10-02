// vx-note: notes and exit strings in Plan 9's words (ADR-0010). The kernel,
// which ends a task on a fault no one handled, and vx-rt, which hands a fault
// to a program's note handler, both include this file. It defines no external
// symbol and needs nothing but abi.h.

#pragma once

#include "../../abi/vx/abi.h"

// A string under construction in a fixed buffer, cut off at its capacity.
typedef struct vx_note_buf {
  char *p;
  size_t len, cap;
} vx_note_buf;

[[maybe_unused]] static void vx_note_put(vx_note_buf *b, vx_str s) {
  for (size_t i = 0; i < s.len && b->len < b->cap; i++) b->p[b->len++] = s.ptr[i];
}

[[maybe_unused]] static void vx_note_hex(vx_note_buf *b, uint64_t v) {
  char digits[18] = "0x";
  int n = 2;
  for (int shift = 60; shift >= 0; shift -= 4)
    if (v >> shift || shift == 0 || n > 2) digits[n++] = "0123456789abcdef"[(v >> shift) & 15];
  vx_note_put(b, (vx_str){digits, (size_t)n});
}

[[maybe_unused]] static void vx_note_dec(vx_note_buf *b, uint64_t v) {
  char digits[20];
  int n = sizeof digits;
  do digits[--n] = (char)('0' + v % 10);
  while (v /= 10);
  vx_note_put(b, (vx_str){digits + n, sizeof digits - (size_t)n});
}

// The note for a trap, as Plan 9 words it: "sys: trap: fault read addr=0x0
// pc=0x401000", "sys: trap: illegal instruction pc=0x401000", "sys:
// breakpoint pc=…". Returns its length, at most VX_ERRMAX.
[[maybe_unused]] static size_t vx_trap_note(uint32_t kind, uint32_t code, uint64_t address, uint64_t pc,
                                            char out[VX_ERRMAX]) {
  vx_note_buf b = {out, 0, VX_ERRMAX};
  bool has_address = false;
  switch (kind) {
  case VX_EXCEPTION_PAGE_FAULT:
    vx_note_put(&b, VX_STR("sys: trap: fault "));
    if (code == 1)
      vx_note_put(&b, VX_STR("write"));
    else if (code == 2)
      vx_note_put(&b, VX_STR("exec"));
    else
      vx_note_put(&b, VX_STR("read"));
    has_address = true;
    break;
  case VX_EXCEPTION_ILLEGAL: vx_note_put(&b, VX_STR("sys: trap: illegal instruction")); break;
  case VX_EXCEPTION_BREAKPOINT: vx_note_put(&b, VX_STR("sys: breakpoint")); break;
  case VX_EXCEPTION_ARITHMETIC: vx_note_put(&b, VX_STR("sys: trap: arithmetic")); break;
  case VX_EXCEPTION_ALIGNMENT:
    vx_note_put(&b, VX_STR("sys: trap: misaligned"));
    has_address = true;
    break;
  case VX_EXCEPTION_FP_DISABLED: vx_note_put(&b, VX_STR("sys: trap: fp disabled")); break;
  case VX_EXCEPTION_STEP: vx_note_put(&b, VX_STR("sys: trap: step")); break;
  default: vx_note_put(&b, VX_STR("sys: trap: general fault")); break;
  }
  if (has_address) {
    vx_note_put(&b, VX_STR(" addr="));
    vx_note_hex(&b, address);
  }
  vx_note_put(&b, VX_STR(" pc="));
  vx_note_hex(&b, pc);
  return b.len;
}

// Whether s begins with prefix.
[[maybe_unused]] static bool vx_note_prefix(vx_str s, vx_str prefix) {
  if (s.len < prefix.len) return false;
  for (size_t i = 0; i < prefix.len; i++)
    if (s.ptr[i] != prefix.ptr[i]) return false;
  return true;
}
