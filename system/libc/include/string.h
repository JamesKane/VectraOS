// SPDX-License-Identifier: BSD-3-Clause

// <string.h> for C programs on croi: what our libc has so far
// (system/libc/string), from C23 §7.26, and POSIX's strerror_r.

#pragma once
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

void *memcpy(void *__restrict d, const void *__restrict s, size_t n);
void *memmove(void *d, const void *s, size_t n);
void *memset(void *s, int c, size_t n);
int memcmp(const void *a, const void *b, size_t n);
void *memchr(const void *s, int c, size_t n);
size_t strlen(const char *s);
size_t strnlen(const char *s, size_t n);
int strcmp(const char *a, const char *b);
int strncmp(const char *a, const char *b, size_t n);
char *strchr(const char *s, int c);
char *strrchr(const char *s, int c);
char *strcat(char *__restrict d, const char *__restrict s);
char *strncpy(char *__restrict d, const char *__restrict s, size_t n);
char *strdup(const char *s);
char *strndup(const char *s, size_t n);
char *strerror(int errnum);
int strerror_r(int errnum, char *buffer, size_t size);

#ifdef __cplusplus
}
#endif
