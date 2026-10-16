// SPDX-License-Identifier: BSD-3-Clause

// <assert.h> (ISO C §7.2): assert, which reports the expression, file,
// line and function on stderr and aborts (system/libc/native/stdio.c). Not
// guarded: each inclusion follows NDEBUG anew, as the standard asks.

#undef assert
#ifdef NDEBUG
#define assert(...) ((void)0)
#else
#ifdef __cplusplus
extern "C"
#endif
__attribute__((__noreturn__)) void __td_assert_fail(const char *expression, const char *file, int line,
                                                    const char *function);
#define assert(...) ((__VA_ARGS__) ? (void)0 : __td_assert_fail(#__VA_ARGS__, __FILE__, __LINE__, __func__))
#endif

#if !defined(__cplusplus) && (!defined(__STDC_VERSION__) || __STDC_VERSION__ < 202311L)
#define static_assert _Static_assert
#endif
