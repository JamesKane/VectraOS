// SPDX-License-Identifier: BSD-3-Clause

// errno (ISO C §7.5: "a modifiable lvalue that has type int and thread
// local storage duration"), natively (M5k): C, since Swift has no
// thread-local variables. <errno.h> reads it through __errno_location, as
// glibc's and musl's do, so their objects link against ours.

static _Thread_local int td_errno;

int *__errno_location(void) { return &td_errno; }
