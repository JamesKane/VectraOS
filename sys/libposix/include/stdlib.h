/*
stdlib.h -- memory, exit, and number conversion, the subset a tool uses.

`malloc` and `free` are the bump heap over `segbrk`, as `sys/libc`'s are.
`exit` runs the destructors nothing registers yet and calls `exits` with
the number as text, so a parent's `waitpid` reads it back.
*/
#ifndef STDLIB_H
#define STDLIB_H

#include <sys/types.h>

void *malloc(size_t n);
void *calloc(size_t n, size_t size);
void *realloc(void *p, size_t n);
void free(void *p);
void exit(int code) __attribute__((noreturn));
void abort(void) __attribute__((noreturn));
int atoi(const char *s);
long atol(const char *s);
long strtol(const char *s, char **end, int base);
char *getenv(const char *name);
int setenv(const char *name, const char *value, int overwrite);
int unsetenv(const char *name);
int putenv(char *nameval);

#endif
