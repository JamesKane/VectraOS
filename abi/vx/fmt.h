// vx/fmt.h: formatting (09 §5.3, ADR-0004 libvx v0). printf's verbs, so
// clang checks each format against its arguments; a slice prints as
// "%.*s", VX_FMT(s). fmt(3) has the verbs and where they differ from C's.

#pragma once

#include <stdarg.h>

#include "api.h"

typedef struct vx_arena vx_arena;

// Into a: the whole output, followed by a NUL that len does not count; the
// zero slice if a is full (pure).
[[gnu::format(printf, 2, 3)]] VX_API vx_str vx_fmt(vx_arena *a, const char *fmt, ...);
[[gnu::format(printf, 2, 0)]] VX_API vx_str vx_vfmt(vx_arena *a, const char *fmt, va_list ap);
// Into buf: as much as fits, cut at a rune's boundary, with no NUL; how many
// bytes that is (pure). To know whether it was cut, format into an arena.
[[gnu::format(printf, 2, 3)]] VX_API size_t vx_bfmt(vx_bytes buf, const char *fmt, ...);
[[gnu::format(printf, 2, 0)]] VX_API size_t vx_vbfmt(vx_bytes buf, const char *fmt, va_list ap);
// To standard output, or standard error, in one write: a program's threads
// do not interleave within one. How many bytes, or a negative vx_status.
[[gnu::format(printf, 1, 2)]] VX_API int64_t vx_printf(const char *fmt, ...);
[[gnu::format(printf, 1, 2)]] VX_API int64_t vx_eprintf(const char *fmt, ...);
