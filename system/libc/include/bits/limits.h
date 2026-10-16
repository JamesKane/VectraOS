// SPDX-License-Identifier: BSD-3-Clause

// POSIX's limits (M6g), in our libc's own module: <limits.h> is textual
// (clang's <limits.h> reaches it by #include_next, so our module can't own
// it), and a textual header's macros belong to whoever includes it, so
// Swift would never see them through VectraOSLibc. Here, they're ours.

#ifndef TD_BITS_LIMITS_H
#define TD_BITS_LIMITS_H

#define PATH_MAX 4096
#define NAME_MAX 255
#define SSIZE_MAX __LONG_MAX__

#endif
