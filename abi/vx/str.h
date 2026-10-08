// vx/str.h: slices (09 §5.3, ADR-0004 libvx v0). A vx_str is UTF-8 text
// that carries its length and is never NUL-terminated (<vx/abi.h>). Offsets
// are in bytes. All pure.

#pragma once

#include "api.h"

typedef struct vx_arena vx_arena;

// A NUL-terminated string as a slice: for argv, and C's own strings.
VX_API vx_str vx_cstr(const char *s);
VX_API bool vx_str_eq(vx_str a, vx_str b);
VX_API bool vx_str_prefix(vx_str s, vx_str prefix);
VX_API bool vx_str_suffix(vx_str s, vx_str suffix);
// The bytes from..to of s, each clamped to its length.
VX_API vx_str vx_str_cut(vx_str s, size_t from, size_t to);
// Where needle first starts in s, or -1. An empty needle is at 0.
VX_API int64_t vx_str_find(vx_str s, vx_str needle);
// The next field of *s up to sep, into *field, and *s past it; false once
// *s is used up. "a,b," gives "a", "b" and "": a field after each sep, and an
// empty slice ("" rather than the zero slice) gives one empty field.
//   for (vx_str f; vx_str_split(&rest, VX_STR(","), &f);) ...
VX_API bool vx_str_split(vx_str *s, vx_str sep, vx_str *field);
// s as a number: decimal digits, or 0x and hex digits; vx_str_i64 also takes
// a sign. False, *out unchanged, for anything else, or one that does not fit.
VX_API bool vx_str_u64(vx_str s, uint64_t *out);
VX_API bool vx_str_i64(vx_str s, int64_t *out);
// The n parts one after the other, in a, followed by a NUL that len does not
// count; the zero slice if a is full. VX_STR_CAT(a, x, y, ...) for a list.
VX_API vx_str vx_str_cat(vx_arena *a, const vx_str *parts, size_t n);
#define VX_STR_CAT(a, ...)                                                                                   \
  vx_str_cat((a), (const vx_str[]){__VA_ARGS__}, sizeof((const vx_str[]){__VA_ARGS__}) / sizeof(vx_str))
