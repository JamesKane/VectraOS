// SPDX-License-Identifier: BSD-3-Clause

// glibc's binary128 conversions for the long double tests (M6d), over raw
// bytes (IEEE binary128, little-endian), since Swift has no binary128 type:
// strtof128 and strfromf128 (whose format is only %[.precision]{a,e,f,g},
// with A, E, F, G).

#pragma once
#include <stddef.h>

void td_strtof128(const char *s, char **end, unsigned char out[16]);
int td_strfromf128(char *buffer, size_t size, const char *format, const unsigned char bits[16]);
