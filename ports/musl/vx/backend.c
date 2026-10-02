// backend.c: musl's VectraOS back end (ADR-0007, docs/01 §9), one unity
// build that goes into libc.a.
//
// musl asks for kernel services by Linux system-call number, through
// __vx_syscall (syscall_arch.h). This file answers each one with VectraOS's
// own calls and servers: files through the process's namespace (vx-ns, over
// 9Px rings), standard input and output through the console or the pipes a
// spawn message names, memory through VMOs. The file descriptor table lives
// here, in the process (as Fuchsia's fdio). What VectraOS does not do yet
// answers -ENOSYS, and is reported to the kernel log once per number.
//
// Numbers, structures and results are Linux's, as musl's headers give them:
// that is the POSIX personality, the one exception to rule 13, and it stays
// inside the C library.
//
// This is first-party code under the house rules; only its includes are
// musl's. It uses vx-rt's base and stdio, which define no external symbol,
// so they cannot collide with musl's.

#define _GNU_SOURCE // musl's AT_EMPTY_PATH, MAP_FIXED_NOREPLACE and the rest

#include <dirent.h>
#include <elf.h>
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <setjmp.h>
#include <signal.h>
#include <spawn.h>
#include <limits.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <stdckdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/uio.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>

#include "vx.h"
#include "../../../lib/vx-rt/stdio.c"
#include "../../../lib/vx-rt/note.c"
#include "../../../lib/vx-ns/spawn.c"
#include "../../../lib/vx-rt/spawn.c"
#include "../../../lib/vx-posix/posix.h"
#include "../../../lib/vx-rand/drbg.c"
#include "../../../third_party/musl/src/process/fdop.h" // posix_spawn's file actions, as musl keeps them

// A vx_status as a negated errno. Statuses from 9P servers arrive already
// mapped from their error texts (vx-9p).
static long vx_errno(vx_status st) {
  switch (st) {
  case VX_OK: return 0;
  case VX_ERR_BAD_HANDLE: return -EBADF;
  case VX_ERR_ACCESS: return -EACCES;
  case VX_ERR_INVALID: return -EINVAL;
  case VX_ERR_RANGE: return -ERANGE;
  case VX_ERR_NO_MEMORY: return -ENOMEM;
  case VX_ERR_SHOULD_WAIT: return -EAGAIN;
  case VX_ERR_TIMED_OUT: return -ETIMEDOUT;
  case VX_ERR_PEER_CLOSED: return -EPIPE;
  case VX_ERR_REFUSED: return -EPERM;
  case VX_ERR_UNSUPPORTED: return -ENOTSUP;
  case VX_ERR_TOO_SMALL: return -ERANGE;
  case VX_ERR_KILLED:
  case VX_ERR_INTERRUPTED: return -EINTR;
  case VX_ERR_NO_CHILD: return -ECHILD;
  case VX_ERR_NOT_FOUND: return -ENOENT;
  case VX_ERR_EXISTS: return -EEXIST;
  default: return -EIO;
  }
}

#include "fd.c"
#include "memory.c"
#include "start.c"
#include "process.c"
#include "signal.c"
#include "poll.c"
#include "socket.c"

// The calls VectraOS does not do yet: -ENOSYS, and one line in the kernel log
// the first time each is asked for, so a port that needs one says so.
static long vx_unimplemented(long n) {
  static uint64_t told[8]; // 512 numbers
  if (n >= 0 && n < 512 && !(told[n / 64] >> (n % 64) & 1)) {
    told[n / 64] |= 1ull << (n % 64);
    static const char head[] = "vx-musl: system call ", tail[] = " is not implemented\n";
    char line[sizeof head + 8 + sizeof tail];
    size_t len = sizeof head - 1;
    memcpy(line, head, sizeof head);
    char digits[8];
    size_t d = 0;
    for (long v = n; d == 0 || v; v /= 10) digits[d++] = (char)('0' + v % 10);
    while (d) line[len++] = digits[--d];
    memcpy(line + len, tail, sizeof tail);
    vx_debug_write((vx_str){line, len + sizeof tail - 1});
  }
  return -ENOSYS;
}

static bool sig_restarting; // the call is being made again after a signal (time_sleep keeps its deadline)

static long vx_dispatch(long n, long a1, long a2, long a3, long a4, long a5, long a6) {
  switch (n) {
  // Files and descriptors (fd.c)
  case SYS_read: return fd_read((int)a1, (void *)a2, (size_t)a3);
  case SYS_write: return fd_write((int)a1, (const void *)a2, (size_t)a3);
  case SYS_readv: return fd_readv((int)a1, (const struct iovec *)a2, (int)a3);
  case SYS_writev: return fd_writev((int)a1, (const struct iovec *)a2, (int)a3);
  case SYS_pread64: return fd_pread((int)a1, (void *)a2, (size_t)a3, a4);
  case SYS_pwrite64: return fd_pwrite((int)a1, (const void *)a2, (size_t)a3, a4);
  case SYS_preadv2: return fd_prw2((int)a1, (const struct iovec *)a2, (int)a3, a4, (int)a6, false);
  case SYS_pwritev2: return fd_prw2((int)a1, (const struct iovec *)a2, (int)a3, a4, (int)a6, true);
  case SYS_lseek: return fd_lseek((int)a1, a2, (int)a3);
  case SYS_close: return fd_close((int)a1);
  case SYS_openat: return fd_openat((int)a1, (const char *)a2, (int)a3, (mode_t)a4);
  case SYS_fstat: return fd_fstat((int)a1, (struct stat *)a2);
  case SYS_newfstatat: return fd_fstatat((int)a1, (const char *)a2, (struct stat *)a3, (int)a4);
  case SYS_getdents64: return fd_getdents((int)a1, (void *)a2, (size_t)a3);
  case SYS_ioctl: return fd_ioctl((int)a1, (unsigned long)a2, (void *)a3);
  case SYS_fcntl: return fd_fcntl((int)a1, (int)a2, a3);
  case SYS_dup: return fd_dup((int)a1, -1, 0);
  case SYS_dup3: return a1 == a2 ? -EINVAL : fd_dup((int)a1, (int)a2, (int)a3);
  case SYS_faccessat: return fd_faccessat((int)a1, (const char *)a2);
  case SYS_mkdirat: return fd_mkdirat((int)a1, (const char *)a2, (mode_t)a3);
  case SYS_unlinkat: return fd_unlinkat((int)a1, (const char *)a2, (int)a3);
  case SYS_getcwd: return fd_getcwd((char *)a1, (size_t)a2);
  case SYS_chdir: return fd_chdir((const char *)a1);
  case SYS_readlinkat: return fd_readlinkat((int)a1, (const char *)a2, (char *)a3, (size_t)a4);
  case SYS_renameat: return fd_renameat((int)a1, (const char *)a2, (int)a3, (const char *)a4, 0);
  case SYS_renameat2: return fd_renameat((int)a1, (const char *)a2, (int)a3, (const char *)a4, (unsigned)a5);
  case SYS_symlinkat: return fd_symlinkat((const char *)a1, (int)a2, (const char *)a3);
  case SYS_linkat: return -EPERM; // no server has hard links
  case SYS_fchmod: return fd_chmod((int)a1, AT_FDCWD, nullptr, (mode_t)a2);
  case SYS_fchmodat: return fd_chmod(-1, (int)a1, (const char *)a2, (mode_t)a3);
  case SYS_fchown: return fd_chown((int)a1, AT_FDCWD, nullptr, (uid_t)a2, (gid_t)a3, true);
  case SYS_fchownat:
    return fd_chown(-1, (int)a1, (const char *)a2, (uid_t)a3, (gid_t)a4, !(a5 & AT_SYMLINK_NOFOLLOW));
  case SYS_truncate: return fd_truncate(-1, (const char *)a1, a2);
  case SYS_ftruncate: return fd_truncate((int)a1, nullptr, a2);
  case SYS_utimensat: return fd_utimens((int)a1, (const char *)a2, (const struct timespec *)a3, (int)a4);
  case SYS_fsync:
  case SYS_fdatasync: return fd_fsync((int)a1);
  case SYS_umask: return 022;
#ifdef SYS_open // x86_64's calls that aarch64 has only as their *at forms
  case SYS_open: return fd_openat(AT_FDCWD, (const char *)a1, (int)a2, (mode_t)a3);
  case SYS_stat: return fd_fstatat(AT_FDCWD, (const char *)a1, (struct stat *)a2, 0);
  case SYS_lstat: return fd_fstatat(AT_FDCWD, (const char *)a1, (struct stat *)a2, AT_SYMLINK_NOFOLLOW);
  case SYS_access: return fd_faccessat(AT_FDCWD, (const char *)a1);
  case SYS_mkdir: return fd_mkdirat(AT_FDCWD, (const char *)a1, (mode_t)a2);
  case SYS_unlink: return fd_unlinkat(AT_FDCWD, (const char *)a1, 0);
  case SYS_rmdir: return fd_unlinkat(AT_FDCWD, (const char *)a1, AT_REMOVEDIR);
  case SYS_dup2: return fd_dup2((int)a1, (int)a2);
  case SYS_readlink: return fd_readlinkat(AT_FDCWD, (const char *)a1, (char *)a2, (size_t)a3);
  case SYS_rename: return fd_renameat(AT_FDCWD, (const char *)a1, AT_FDCWD, (const char *)a2, 0);
  case SYS_symlink: return fd_symlinkat((const char *)a1, AT_FDCWD, (const char *)a2);
  case SYS_link: return -EPERM;
  case SYS_chmod: return fd_chmod(-1, AT_FDCWD, (const char *)a1, (mode_t)a2);
  case SYS_chown: return fd_chown(-1, AT_FDCWD, (const char *)a1, (uid_t)a2, (gid_t)a3, true);
  case SYS_lchown: return fd_chown(-1, AT_FDCWD, (const char *)a1, (uid_t)a2, (gid_t)a3, false);
  case SYS_pause: return sig_suspend(sig_mask);
  case SYS_poll: return sys_poll((struct pollfd *)a1, (nfds_t)a2, (int)a3);
  case SYS_select: {
    const struct timeval *tv = (const struct timeval *)a5;
    struct timespec ts = tv ? (struct timespec){tv->tv_sec, tv->tv_usec * 1000} : (struct timespec){};
    return sys_select((int)a1, (fd_set *)a2, (fd_set *)a3, (fd_set *)a4, tv ? &ts : nullptr, nullptr);
  }
  case SYS_fork:
  case SYS_vfork: return proc_fork();
  case SYS_pipe: return fd_pipe2((int *)a1, 0);
#endif

  // Memory (memory.c)
  case SYS_mmap: return mem_map(a1, (size_t)a2, (int)a3, (int)a4, (int)a5, a6);
  case SYS_munmap: return mem_unmap(a1, (size_t)a2);
  case SYS_mremap: return mem_remap(a1, (size_t)a2, (size_t)a3, (int)a4);
  case SYS_mprotect: return mem_protect((int)a3);
  case SYS_madvise: // advice
  case SYS_brk:     // no break: musl's malloc maps instead
    return 0;

  // The process (start.c)
  case SYS_exit:
  case SYS_exit_group: proc_exit((int)a1);
  case SYS_getpid:
  case SYS_gettid: // one thread, whose id is the process's
  case SYS_set_tid_address: return posix_pid();
  case SYS_getppid: return posix_getppid();
  case SYS_getpgid: return posix_getpgid(a1);
  case SYS_getsid: return posix_getsid(a1);
  case SYS_setpgid: return posix_setpgid(a1, a2);
  case SYS_setsid: return posix_setsid();
  case SYS_wait4: return posix_wait4(a1, (int *)a2, (int)a3, (struct rusage *)a4);
  case SYS_execve: return proc_execve((const char *)a1, (char *const *)a2, (char *const *)a3);
  case SYS_clone: // musl's _Fork and vfork, where there is no SYS_fork; threads wait (docs/milestones.md)
    return a1 == SIGCHLD && !a2 ? proc_fork() : -ENOSYS;
  case SYS_pipe2: return fd_pipe2((int *)a1, (int)a2);
  case SYS_getuid:
  case SYS_geteuid:
  case SYS_getgid:
  case SYS_getegid: return 0;
  case SYS_uname: return proc_uname((struct utsname *)a1);
  case SYS_getrandom: return proc_getrandom((void *)a1, (size_t)a2);
  // Signals (signal.c)
  case SYS_tkill:
  case SYS_tgkill: return sig_kill(posix_pid(), (int)(n == SYS_tkill ? a2 : a3)); // one thread: the process
  case SYS_kill: return sig_kill(a1, (int)a2);
  case SYS_rt_sigaction: return sig_action((int)a1, (const k_sigaction *)a2, (k_sigaction *)a3);
  case SYS_rt_sigprocmask: return sig_procmask((int)a1, (const uint64_t *)a2, (uint64_t *)a3);
  case SYS_rt_sigpending: return *(uint64_t *)a1 = sig_pending, 0;
  case SYS_rt_sigsuspend: return sig_suspend(*(const uint64_t *)a1);
  case SYS_sigaltstack: // accepted, and not used: handlers run on the thread's stack
    if (a2) *(stack_t *)a2 = (stack_t){.ss_flags = SS_DISABLE};
    return 0;
  case SYS_prlimit64: return proc_prlimit((struct rlimit *)a4);
#ifdef SYS_set_thread_area
  case SYS_set_thread_area: return proc_set_tls((uint64_t)a1); // x86_64's
#endif

  // Time and waiting (start.c)
  case SYS_clock_gettime: return time_get((clockid_t)a1, (struct timespec *)a2);
  case SYS_clock_getres: return time_res((struct timespec *)a2);
  case SYS_nanosleep:
    return time_sleep(CLOCK_MONOTONIC, 0, (const struct timespec *)a1, (struct timespec *)a2);
  case SYS_clock_nanosleep:
    return time_sleep((clockid_t)a1, (int)a2, (const struct timespec *)a3, (struct timespec *)a4);
  case SYS_ppoll: // and pause(), where there is no SYS_pause
    if (a1 == 0 && a2 == 0 && a3 == 0) return sig_suspend(a4 ? *(const uint64_t *)a4 : sig_mask);
    return poll_masked((struct pollfd *)a1, (nfds_t)a2, (const struct timespec *)a3, (const uint64_t *)a4);
  case SYS_pselect6: {
    const uintptr_t *data = (const uintptr_t *)a6; // {sigset, size}, as musl passes it
    return sys_select((int)a1, (fd_set *)a2, (fd_set *)a3, (fd_set *)a4, (const struct timespec *)a5,
                      data ? (const uint64_t *)data[0] : nullptr);
  }
  // Sockets (socket.c)
  case SYS_socket: return sock_socket((int)a1, (int)a2, (int)a3);
  case SYS_bind: return sock_bind((int)a1, (const void *)a2, (socklen_t)a3);
  case SYS_listen: return sock_listen((int)a1, (int)a2);
  case SYS_accept: return sock_accept((int)a1, (void *)a2, (socklen_t *)a3, 0);
  case SYS_accept4: return sock_accept((int)a1, (void *)a2, (socklen_t *)a3, (int)a4);
  case SYS_connect: return sock_connect((int)a1, (const void *)a2, (socklen_t)a3);
  case SYS_getsockname: return sock_name((int)a1, (void *)a2, (socklen_t *)a3, false);
  case SYS_getpeername: return sock_name((int)a1, (void *)a2, (socklen_t *)a3, true);
  case SYS_sendto:
    return sock_sendto((int)a1, (const void *)a2, (size_t)a3, (int)a4, (const void *)a5, (socklen_t)a6);
  case SYS_recvfrom:
    return sock_recvfrom((int)a1, (void *)a2, (size_t)a3, (int)a4, (void *)a5, (socklen_t *)a6);
  case SYS_sendmsg: return sock_sendmsg((int)a1, (const struct msghdr *)a2, (int)a3);
  case SYS_recvmsg: return sock_recvmsg((int)a1, (struct msghdr *)a2, (int)a3);
  case SYS_shutdown: return sock_shutdown((int)a1, (int)a2);
  case SYS_setsockopt: return sock_setsockopt((int)a1, (int)a2, (int)a3, (const void *)a4, (socklen_t)a5);
  case SYS_getsockopt: return sock_getsockopt((int)a1, (int)a2, (int)a3, (void *)a4, (socklen_t *)a5);
  case SYS_socketpair: return -EAFNOSUPPORT; // AF_UNIX: not yet (docs/milestones.md)

  case SYS_sched_yield: return 0;
  case SYS_futex: return time_futex((uint32_t *)a1, (int)a2, (uint32_t)a3, (const struct timespec *)a4);

  default: return vx_unimplemented(n);
  }
}

// Every call musl makes. A signal that arrives during one is delivered as it
// returns (signal.c); the call is made again if no handler that wants EINTR
// ran, as for SA_RESTART and ignored signals. sigsuspend and pause always
// return EINTR.
long __vx_syscall(long n, long a1, long a2, long a3, long a4, long a5, long a6) {
  sig_depth = sig_depth + 1;
  long r = vx_dispatch(n, a1, a2, a3, a4, a5, a6);
  sig_depth = sig_depth - 1;
  while (sig_depth == 0 && (sig_pending & ~sig_mask)) {
    uint32_t ran = sig_handlers_ran;
    bool eintr = sig_deliver_pending();
    // poll and select end with EINTR once any handler has run, SA_RESTART
    // or not, as Linux's do; any call is made again when none has.
    bool waits = n == SYS_ppoll || n == SYS_pselect6;
#ifdef SYS_poll
    waits = waits || n == SYS_poll || n == SYS_select;
#endif
    if (waits && ran != sig_handlers_ran) eintr = true;
    bool again = r == -EINTR && !eintr && n != SYS_rt_sigsuspend && !(n == SYS_ppoll && a1 == 0 && a2 == 0);
#ifdef SYS_pause
    again = again && n != SYS_pause;
#endif
    if (!again) break;
    sig_restarting = true;
    sig_depth = sig_depth + 1;
    r = vx_dispatch(n, a1, a2, a3, a4, a5, a6);
    sig_depth = sig_depth - 1;
    sig_restarting = false;
  }
  return r;
}

// The entry to a cancellation point (musl's pthread_cancel.c), as
// arch/*/syscall_cp.s are on Linux: the thread's cancel flag checked, then the
// call. Cancellation by a signal arriving inside [__cp_begin, __cp_end) waits
// for signals (M4 step 3).
#ifdef __x86_64__
__asm__(".text\n"
        ".global __cp_begin, __cp_end, __cp_cancel, __syscall_cp_asm\n"
        ".hidden __cp_begin, __cp_end, __cp_cancel, __syscall_cp_asm\n"
        ".type __syscall_cp_asm, @function\n"
        "__syscall_cp_asm:\n"
        "__cp_begin:\n"
        "  endbr64\n"
        "  movl (%rdi), %eax\n"
        "  testl %eax, %eax\n"
        "  jnz __cp_cancel\n"
        "  movq %rsi, %rdi\n" // (cancel, nr, u, v, w, x, y, z) to (nr, u, v, w, x, y, z)
        "  movq %rdx, %rsi\n"
        "  movq %rcx, %rdx\n"
        "  movq %r8, %rcx\n"
        "  movq %r9, %r8\n"
        "  movq 8(%rsp), %r9\n"
        "  pushq 16(%rsp)\n"
        "  call __vx_syscall\n"
        "  addq $8, %rsp\n"
        "__cp_end:\n"
        "  ret\n"
        "__cp_cancel:\n"
        "  jmp __cancel\n");
#else
__asm__(".text\n"
        ".global __cp_begin, __cp_end, __cp_cancel, __syscall_cp_asm\n"
        ".hidden __cp_begin, __cp_end, __cp_cancel, __syscall_cp_asm\n"
        ".type __syscall_cp_asm, %function\n"
        "__syscall_cp_asm:\n"
        "__cp_begin:\n"
        "  bti c\n"
        "  ldr w9, [x0]\n"
        "  cbnz w9, __cp_cancel\n"
        "  mov x0, x1\n" // (cancel, nr, u, v, w, x, y, z) to (nr, u, v, w, x, y, z)
        "  mov x1, x2\n"
        "  mov x2, x3\n"
        "  mov x3, x4\n"
        "  mov x4, x5\n"
        "  mov x5, x6\n"
        "  mov x6, x7\n"
        "  b __vx_syscall\n"
        "__cp_end:\n"
        "__cp_cancel:\n"
        "  b __cancel\n");
#endif
