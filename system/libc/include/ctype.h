// SPDX-License-Identifier: BSD-3-Clause

// <ctype.h> (C23 §7.4), in the "C" locale, the only one (system/libc/ctype,
// M6d): classification of an unsigned char's value or EOF, and case
// mapping.

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

int isalnum(int c);
int isalpha(int c);
int isblank(int c);
int iscntrl(int c);
int isdigit(int c);
int isgraph(int c);
int islower(int c);
int isprint(int c);
int ispunct(int c);
int isspace(int c);
int isupper(int c);
int isxdigit(int c);
int tolower(int c);
int toupper(int c);

#ifdef __cplusplus
}
#endif
