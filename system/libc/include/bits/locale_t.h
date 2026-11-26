// SPDX-License-Identifier: BSD-3-Clause

// locale_t (POSIX's <locale.h>), for the headers that declare the *_l
// functions (<ctype.h>, <stdlib.h>, <string.h>, <time.h>) without the rest
// of <locale.h>. There is one locale, "C" (system/libc/native/locale.c).

#pragma once

typedef struct td_locale *locale_t;
