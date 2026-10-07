// libvx.h: what the native target's C library calls libvx.a by name (M6
// step 6e2b): llvm-libc's baremetal hooks (LLVM patches 0004 and 0006 to 0008),
// and the program's main. libvx.c defines them; nothing
// else includes this file.

#pragma once

#include <stddef.h>
#include <stdint.h>

typedef struct libvx_timespec libvx_timespec;
struct __llvm_libc_stdio_cookie {
  int fd;
};
extern struct __llvm_libc_stdio_cookie __llvm_libc_stdin_cookie, __llvm_libc_stdout_cookie,
    __llvm_libc_stderr_cookie;
[[noreturn]] void __llvm_libc_exit(int status);
int *__llvm_libc_errno(void);
long __llvm_libc_stdio_write(void *cookie, const char *buf, size_t size);
long __llvm_libc_stdio_read(void *cookie, char *buf, size_t size);
void *__llvm_libc_heap_allocate(size_t size, size_t alignment);
void __llvm_libc_heap_free(void *p);
size_t __llvm_libc_heap_usable_size(void *p);
int __llvm_libc_futex_wait(const uint32_t *word, uint32_t expected, int64_t deadline);
void __llvm_libc_futex_wake(const uint32_t *word, uint32_t count);
int __llvm_libc_thread_create(void (*entry)(void *), void *arg, size_t stacksize, void **handle);
int __llvm_libc_thread_join(void *handle);
void __llvm_libc_thread_detach(void *handle);
[[noreturn]] void __llvm_libc_thread_exit(void);
uint32_t __llvm_libc_thread_id(void);
int64_t __llvm_libc_clock_monotonic(void);
[[gnu::weak]] void __llvm_libc_thread_main(void); // the C library's, if a program uses threads
int __llvm_libc_remove(const char *path);
long __llvm_libc_file_open(const char *path, int flags);
long __llvm_libc_file_read(long handle, void *buf, size_t size);
long __llvm_libc_file_write(long handle, const void *buf, size_t size);
long long __llvm_libc_file_seek(long handle, long long offset, int whence);
int __llvm_libc_file_close(long handle);
int __llvm_libc_rename(const char *from, const char *to);
char *__llvm_libc_getenv(const char *name);
bool __llvm_libc_timespec_get_utc(libvx_timespec *ts);
bool __llvm_libc_timespec_get_active(libvx_timespec *ts);
int main(int argc, char **argv);
[[noreturn]] void exit(int status); // the C library's: its handlers, then __llvm_libc_exit
