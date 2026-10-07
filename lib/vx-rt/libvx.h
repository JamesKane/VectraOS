// libvx.h: what the native target's C library calls libvx.a by name (M6
// step 6e2b): llvm-libc's baremetal hooks (LLVM patch 0004), the C++ ABI's
// __cxa_finalize, and the program's main. libvx.c defines them; nothing
// else includes this file.

#pragma once

#include <stddef.h>

typedef struct libvx_timespec libvx_timespec;
struct __llvm_libc_stdio_cookie {
  int fd;
};
extern struct __llvm_libc_stdio_cookie __llvm_libc_stdin_cookie, __llvm_libc_stdout_cookie,
    __llvm_libc_stderr_cookie;
void __cxa_finalize(void *dso);
[[noreturn]] void __llvm_libc_exit(int status);
int *__llvm_libc_errno(void);
long __llvm_libc_stdio_write(void *cookie, const char *buf, size_t size);
long __llvm_libc_stdio_read(void *cookie, char *buf, size_t size);
void *__llvm_libc_heap_allocate(size_t size, size_t alignment);
void __llvm_libc_heap_free(void *p);
size_t __llvm_libc_heap_usable_size(void *p);
int __llvm_libc_remove(const char *path);
int __llvm_libc_rename(const char *from, const char *to);
char *__llvm_libc_getenv(const char *name);
bool __llvm_libc_timespec_get_utc(libvx_timespec *ts);
bool __llvm_libc_timespec_get_active(libvx_timespec *ts);
int main(int argc, char **argv);
[[noreturn]] void exit(int status); // the C library's: its handlers, then __llvm_libc_exit
