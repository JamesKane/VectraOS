// SPDX-License-Identifier: BSD-3-Clause

// <stdlib.h> for C programs on croi (M4e; M6d for C++): what our libc has
// so far (system/libc/stdlib, the floor for getenv, the heap, abort and
// exit), from C23 §7.24. Hosted programs use the host's.

#pragma once
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define EXIT_SUCCESS 0
#define EXIT_FAILURE 1

typedef struct { int quot, rem; } div_t;
typedef struct { long quot, rem; } ldiv_t;
typedef struct { long long quot, rem; } lldiv_t;

// Numeric conversions (C23 §7.24.1).
long strtol(const char *__restrict nptr, char **__restrict endptr, int base);
long long strtoll(const char *__restrict nptr, char **__restrict endptr, int base);
unsigned long strtoul(const char *__restrict nptr, char **__restrict endptr, int base);
unsigned long long strtoull(const char *__restrict nptr, char **__restrict endptr, int base);
double strtod(const char *__restrict nptr, char **__restrict endptr);
float strtof(const char *__restrict nptr, char **__restrict endptr);
long double strtold(const char *__restrict nptr, char **__restrict endptr);
double atof(const char *nptr);
int atoi(const char *nptr);
long atol(const char *nptr);
long long atoll(const char *nptr);

// The heap (C23 §7.24.3, POSIX's posix_memalign): the floor's
// (system/sys/floor/Heap.swift).
void *malloc(size_t size);
void *calloc(size_t count, size_t size);
void *realloc(void *p, size_t size);
void free(void *p);
void *aligned_alloc(size_t alignment, size_t size);
int posix_memalign(void **p, size_t alignment, size_t size);
size_t malloc_usable_size(void *p);  // glibc's: the block's whole size

// The environment (C23 §7.24.4).
__attribute__((__noreturn__)) void abort(void);
__attribute__((__noreturn__)) void exit(int status);
__attribute__((__noreturn__)) void _Exit(int status);
int atexit(void (*f)(void));
char *getenv(const char *name);

// Paths (POSIX XSH): fdio's, in tier 1 (M6g).
char *realpath(const char *__restrict path, char *__restrict resolved);
// A name not yet in use, made from `template`'s trailing XXXXXX (POSIX
// XSH, fdio's): the template's NUL-terminated string changed in place.
char *mktemp(char *template_);
int mkstemp(char *template_);

// Searching and sorting (C23 §7.24.5).
void *bsearch(const void *key, const void *base, size_t n, size_t size, int (*compare)(const void *, const void *));
void qsort(void *base, size_t n, size_t size, int (*compare)(const void *, const void *));

// Integer arithmetic (C23 §7.24.6).
int abs(int j);
long labs(long j);
long long llabs(long long j);
div_t div(int numer, int denom);
ldiv_t ldiv(long numer, long denom);
lldiv_t lldiv(long long numer, long long denom);

#ifdef __cplusplus
}
#endif
