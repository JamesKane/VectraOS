// SPDX-License-Identifier: BSD-3-Clause

// <wchar.h> (ISO C §7.31): its types only so far (M6d), which C++'s
// <iosfwd> needs (std::fpos<mbstate_t>). No wide-character functions: our
// libc++ is built without them.

#pragma once
#include <stddef.h>

typedef struct { unsigned __state[2]; } mbstate_t;
typedef unsigned wint_t;
#define WEOF ((wint_t)-1)
