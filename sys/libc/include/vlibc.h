/*
vlibc.h -- the native C library's one header, over this tree's calls.

A C program on Vectra links `sys/libc`, which is Plan 9's libc in shape:
the system calls under the names `sys/libuser` uses, `print` and `fprint`
for output, and the freestanding string and memory routines. It is not
POSIX. A program that wants `errno` and `O_CREAT` links `sys/libposix`
(docs/DEVTOOLS.md section 8), which is not this.

The call numbers come from `sys/abi/abi.h`, generated from the one Odin
file both sides of the door read, so a C program and the kernel cannot
drift. See `docs/DEVTOOLS.md` section 3.
*/
#ifndef VLIBC_H
#define VLIBC_H

#include "abi.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef unsigned long uintptr;
typedef unsigned long usize;
typedef long isize;
typedef unsigned char uchar;
typedef unsigned int uint;
typedef unsigned long uvlong;
typedef long vlong;

#ifndef NULL
#define NULL ((void *)0)
#endif

/* The most arguments a program is given, the kernel's cap in
   `kernel/user/args.odin`. `crt0` lays out at most this many. */
#define ARGV_MAX 64

/*
The arguments the kernel wrote onto the stack, `abi.Args` as C sees it. A
string is Odin's: a pointer and a length, not a NUL-terminated run. `crt0`
turns them into a C `argv` for `main`, so most programs never read this.
*/
typedef struct VString VString;
struct VString {
	char *data;
	isize len;
};

typedef struct Args Args;
struct Args {
	isize count;
	VString *strings;
};

/* The raw door: the call number and up to six arguments, the kernel's
   signed answer. Every wrapper below is one call to this. */
long __vsyscall(long nr, long a0, long a1, long a2, long a3, long a4, long a5);

/* -- The system calls, the answers the kernel's, `-errno` when negative -- */
long vwrite(int fd, const void *buf, long n);
long vread(int fd, void *buf, long n);
int vopen(const char *path, long mode);
int vclose(int fd);
long vseek(int fd, long off);
void vsleep(long ms);
long vgetpid(void);
void exits(const char *msg) __attribute__((noreturn));
void _exit(int code) __attribute__((noreturn));
long vtls(void *tp);

/* -- Output: Plan 9's print and fprint, a small subset -- */
int print(const char *fmt, ...);
int fprint(int fd, const char *fmt, ...);
int vfprint(int fd, const char *fmt, __builtin_va_list ap);

/* -- Strings and memory, the freestanding standard -- */
usize strlen(const char *s);
int strcmp(const char *a, const char *b);
char *strcpy(char *dst, const char *src);
void *memcpy(void *dst, const void *src, usize n);
void *memmove(void *dst, const void *src, usize n);
void *memset(void *dst, int c, usize n);
int memcmp(const void *a, const void *b, usize n);

/* -- The heap, a bump over one segment grown by `segbrk` -- */
void *malloc(usize n);
void free(void *p);

#ifdef __cplusplus
}
#endif

#endif
