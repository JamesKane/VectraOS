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
void __llvm_libcxx_random_bytes(void *buf, size_t n);
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

// std::filesystem's (libvx-fs.c, LLVM patch 0013).
// What libc++ reads of a file: its kind, permissions, identity, size, link
// count and times. libc++'s side declares the same layout.
typedef struct libvx_fs_stat {
  uint32_t type; // LIBVX_FS_*
  uint32_t perms;
  uint64_t dev, ino, size, nlink;
  int64_t mtime_sec, mtime_nsec, atime_sec, atime_nsec;
} libvx_fs_stat;

enum : uint32_t { LIBVX_FS_REGULAR = 1, LIBVX_FS_DIRECTORY = 2, LIBVX_FS_SYMLINK = 3, LIBVX_FS_OTHER = 4 };

int __llvm_libcxx_fs_stat(const char *path, int follow, libvx_fs_stat *st);
int __llvm_libcxx_fs_fstat(long handle, libvx_fs_stat *st);
int __llvm_libcxx_fs_mkdir(const char *path, uint32_t perms);
int __llvm_libcxx_fs_remove(const char *path);
int __llvm_libcxx_fs_rename(const char *from, const char *to);
int __llvm_libcxx_fs_symlink(const char *target, const char *path);
int64_t __llvm_libcxx_fs_readlink(const char *path, char *buf, size_t cap);
int __llvm_libcxx_fs_truncate(const char *path, uint64_t size);
int __llvm_libcxx_fs_ftruncate(long handle, uint64_t size);
int __llvm_libcxx_fs_chmod(const char *path, uint32_t perms, int follow);
int __llvm_libcxx_fs_fchmod(long handle, uint32_t perms);
int __llvm_libcxx_fs_set_times(const char *path, int64_t mtime_sec, int64_t mtime_nsec);
int64_t __llvm_libcxx_fs_getcwd(char *buf, size_t cap);
int __llvm_libcxx_fs_chdir(const char *path);
int64_t __llvm_libcxx_fs_realpath(const char *path, char *buf, size_t cap);
int64_t __llvm_libcxx_fs_opendir(const char *path);
int __llvm_libcxx_fs_readdir(int64_t dir, char *name, size_t cap, uint32_t *type);
void __llvm_libcxx_fs_closedir(int64_t dir);
