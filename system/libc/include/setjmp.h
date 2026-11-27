// SPDX-License-Identifier: BSD-3-Clause

// <setjmp.h> (C23 §7.13): setjmp and longjmp, and their _setjmp and
// _longjmp names (system/libc/native/setjmp-<arch>.S). There are no
// signals, so no signal mask to save: sigsetjmp and siglongjmp are the
// same calls.

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// The callee-saved registers of the largest of the three machines (rv64's
// 26 words with its floating-point ones), and room.
typedef long jmp_buf[32];
typedef long sigjmp_buf[32];

int setjmp(jmp_buf env) __attribute__((__returns_twice__));
int _setjmp(jmp_buf env) __attribute__((__returns_twice__));
__attribute__((__noreturn__)) void longjmp(jmp_buf env, int value);
__attribute__((__noreturn__)) void _longjmp(jmp_buf env, int value);
#define sigsetjmp(env, save) setjmp(env)
#define siglongjmp(env, value) longjmp(env, value)

#ifdef __cplusplus
}
#endif
