// SPDX-License-Identifier: BSD-3-Clause

// <strings.h> (POSIX XBD): comparisons ignoring case, the C locale's
// (system/libc/string, M6g).

#pragma once
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

int strcasecmp(const char *s1, const char *s2);
int strncasecmp(const char *s1, const char *s2, size_t n);

#ifdef __cplusplus
}
#endif
