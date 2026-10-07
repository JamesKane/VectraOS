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
#include <stdarg.h>
#include <stdatomic.h>
#include <stdckdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
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
  case VX_ERR_IO: return -EIO;
  case VX_ERR_NO_SPACE: return -ENOSPC;
  case VX_ERR_NOT_FOUND: return -ENOENT;
  case VX_ERR_EXISTS: return -EEXIST;
  default: return -EIO;
  }
}

// --- Threads (M6 step 6d2a) ---
//
// The back end's state is the process's, so its threads take turns at it: a
// lock, held through each call, recursive within a thread (the back end calls
// musl, which may call it again), and let go of wherever a call waits (a
// pipe, a sleep, a futex, sigsuspend), so the thread that would end the wait
// can come in. A 9P call holds it through the server's answer: the client is
// one thread's at a time until 6d4.
//
// A thread's own state is thread_local, but musl calls in before its first
// thread's TLS is set (set_thread_area, set_tid_address): until then it is a
// static copy, moved to TLS at set_tid_address, musl's last step of it.
typedef struct be_thread {
  uint32_t depth;           // holds of be_lock
  int sig_depth;            // inside __vx_syscall: delivery waits for its return (signal.c)
  long tid;                 // gettid's: the process's id for the first thread
  volatile int *ctid;       // CLONE_CHILD_CLEARTID's (and set_tid_address's): cleared and woken at its end
  uint64_t pending;         // signals aimed at this thread (pthread_kill), delivered on it alone (signal.c)
  uint64_t mask;            // its blocked signals: a new thread starts with its creator's
  bool restarting;          // its call is being made again after a signal, its deadline kept
  vx_instant call_deadline; // its sleep's or poll's (start.c, poll.c)
  uint64_t alt_base, alt_size;      // sigaltstack's; size 0: none
  uint32_t slot;                    // in be_threads, plus 1; 0: not there
  uint32_t handlers_ran, eintr_ran; // signal.c's: the handlers run on it, and those not SA_RESTART
  uint64_t robust;                  // set_robust_list's head
  vx_handle ring_port;              // what a 9P call of its sleeps on now (6d4b): a signal's handler ends
  _Atomic uint32_t *ring_word;      // the sleep, as it would not end a wait it came just before
} be_thread;

static vx_mutex be_lock;
static be_thread be_early;
static thread_local be_thread be_tl;
static bool be_tls;                  // be_tl usable: set_tid_address has come
static _Atomic uint32_t be_live = 1; // threads alive, the first among them

static be_thread *be_me(void) { return be_tls ? &be_tl : &be_early; }

static void be_enter(void) {
  if (be_me()->depth++ == 0) vx_mutex_lock(&be_lock);
}

static void be_leave(void) {
  if (--be_me()->depth == 0) vx_mutex_unlock(&be_lock);
}

// Around a wait: all of this thread's holds let go, then taken back.
static uint32_t be_wait_begin(void) {
  uint32_t d = be_me()->depth;
  if (d) be_me()->depth = 0, vx_mutex_unlock(&be_lock);
  return d;
}

static void be_wait_end(uint32_t d) {
  if (d) vx_mutex_lock(&be_lock), be_me()->depth = d;
}

[[noreturn]] static void be_thread_exit(int code); // below, with __clone
static long be_thread_kill(long tid, int sig);

// A signal's note, marked for the one thread it is posted to (be_thread_kill,
// be_forward): kept pending there, not taken as the process's.
static constexpr char BE_DIRECTED[] = " thread";

// --- The process's threads (6d2b) ---
//
// Each live thread in a slot, with its kernel id: slot 0 the first thread's,
// 1 to 255 pthread_create's. A thread's id (gettid, and the owner in musl's
// lock words) is its slot shifted left 22, plus the pid: 30 bits, unique
// across processes while pids stay under 2^22 (ADR-0037). tkill finds the
// kernel thread through it, and be_forward passes a signal from another
// process, that the thread whose note it came in blocks, to one that does
// not. A reader counts itself in before it looks at a thread's record, which
// be_unregister waits out, so the record (in that thread's TLS) is not gone
// from under it.
static constexpr uint32_t BE_THREADS = 256;
static constexpr uint32_t BE_TID_SHIFT = 22;
static constexpr long BE_PID_MASK = (1L << BE_TID_SHIFT) - 1;
static constexpr uint32_t BE_SLOT_TAKEN = UINT32_MAX; // reserved by __clone; its thread not made yet
static struct be_slot {
  _Atomic uint32_t id;      // its kernel thread id; 0: free
  _Atomic uint32_t readers; // be_forwards looking at t
  be_thread *_Atomic t;
} be_threads[BE_THREADS];

// A free slot past the first's, reserved; -1 if none.
static int be_slot_take(void) {
  for (uint32_t i = 1; i < BE_THREADS; i++) {
    uint32_t free = 0;
    if (atomic_compare_exchange_strong(&be_threads[i].id, &free, BE_SLOT_TAKEN)) return (int)i;
  }
  return -1;
}

// Slot i is the thread whose record is t, kernel id id.
static void be_slot_set(uint32_t i, uint32_t id, be_thread *t) {
  atomic_store(&be_threads[i].id, id);
  atomic_store(&be_threads[i].t, t);
  t->slot = i + 1;
}

static void be_unregister(be_thread *t) {
  if (!t->slot) return;
  struct be_slot *s = &be_threads[t->slot - 1];
  atomic_store(&s->t, nullptr);
  while (atomic_load(&s->readers)) {} // a reader with t in hand: done in a few instructions
  atomic_store(&s->id, 0);
  t->slot = 0;
}

// The calling thread, as the kernel numbers it: the first of the task's when
// it is the only one (start-up, a forked child).
static uint32_t be_only_thread_id(void) {
  vx_thread_info ti = {};
  return vx_thread_state(vx_self, 0, VX_STATE_NEXT_THREAD, &ti, sizeof ti) == VX_OK ? ti.id : 0;
}

// The process's signal sig, which this thread blocks, posted to a thread
// that does not, marked as its own; false if none does (or none would take
// the note), and it stays the process's, pending.
static bool be_forward(int sig, vx_str note) {
  char buf[VX_ERRMAX];
  size_t dl = sizeof BE_DIRECTED - 1;
  if (note.len + dl > sizeof buf) return false;
  memcpy(buf, note.ptr, note.len);
  memcpy(buf + note.len, BE_DIRECTED, dl);
  const be_thread *me = be_me();
  uint64_t bit = 1ull << (sig - 1);
  for (uint32_t i = 0; i < BE_THREADS; i++) {
    struct be_slot *s = &be_threads[i];
    uint32_t id = atomic_load(&s->id);
    if (!id || id == BE_SLOT_TAKEN) continue;
    atomic_fetch_add(&s->readers, 1);
    const be_thread *t = atomic_load(&s->t);
    bool takes = t && t != me && !(__atomic_load_n(&t->mask, __ATOMIC_RELAXED) & bit);
    atomic_fetch_sub(&s->readers, 1);
    if (takes && vx_thread_interrupt(vx_self, id, (vx_str){buf, note.len + dl}) == VX_OK) return true;
  }
  return false;
}

// --- The alternate signal stack (6d2b) ---

// Whether the thread runs on its alternate stack now.
static bool be_on_alt(const be_thread *t) {
  uint64_t sp = (uint64_t)__builtin_frame_address(0);
  return t->alt_size && sp > t->alt_base && sp <= t->alt_base + t->alt_size;
}

// sigaltstack's flags for the thread's alternate stack, on it or not.
static int be_alt_flags(const be_thread *t, bool on) {
  if (!t->alt_size) return SS_DISABLE;
  return on ? SS_ONSTACK : 0;
}

// fn(a0, a1, a2) on the stack whose top is top; back on this one after.
[[gnu::visibility("hidden")]] void be_on_stack(uint64_t top, uintptr_t fn, long a0, void *a1, void *a2);
#ifdef __x86_64__
__asm__(".text\n"
        ".global be_on_stack\n"
        ".hidden be_on_stack\n"
        ".type be_on_stack, @function\n"
        "be_on_stack:\n"
        "  endbr64\n"
        "  pushq %rbp\n"
        "  movq %rsp, %rbp\n"
        "  movq %rsi, %rax\n"
        "  andq $-16, %rdi\n"
        "  movq %rdi, %rsp\n"
        "  movq %rdx, %rdi\n"
        "  movq %rcx, %rsi\n"
        "  movq %r8, %rdx\n"
        "  call *%rax\n"
        "  movq %rbp, %rsp\n"
        "  popq %rbp\n"
        "  ret\n");
#else
__asm__(".text\n"
        ".global be_on_stack\n"
        ".hidden be_on_stack\n"
        ".type be_on_stack, %function\n"
        "be_on_stack:\n"
        "  bti c\n"
        "  stp x29, x30, [sp, #-16]!\n"
        "  mov x29, sp\n"
        "  and x9, x0, #~15\n"
        "  mov sp, x9\n"
        "  mov x9, x1\n"
        "  mov x0, x2\n"
        "  mov x1, x3\n"
        "  mov x2, x4\n"
        "  blr x9\n"
        "  mov sp, x29\n"
        "  ldp x29, x30, [sp], #16\n"
        "  ret\n");
#endif

// A handler called: on the alternate stack for SA_ONSTACK, unless the thread
// is on it already (the kernel diverted it there, or a handler runs there).
static void sig_call(unsigned long flags, uintptr_t h, int sig, siginfo_t *info, void *uc) {
  const be_thread *me = be_me();
  if ((flags & SA_ONSTACK) && me->alt_size && !be_on_alt(me))
    be_on_stack(me->alt_base + me->alt_size, h, sig, info, uc);
  else if (flags & SA_SIGINFO)
    ((void (*)(int, siginfo_t *, void *))h)(sig, info, uc);
  else
    ((void (*)(int))h)(sig);
}

// sigaltstack: the stack is the thread's note stack too (ADR-0036), where the
// kernel diverts it for a note or a fault, so an overflow's SIGSEGV has room.
static long be_altstack(const stack_t *ss, stack_t *old) {
  be_thread *me = be_me();
  bool on = be_on_alt(me);
  if (old)
    *old =
        (stack_t){.ss_sp = (void *)me->alt_base, .ss_size = me->alt_size, .ss_flags = be_alt_flags(me, on)};
  if (!ss) return 0;
  if (on) return -EPERM;
  if (ss->ss_flags & ~SS_DISABLE) return -EINVAL; // SS_AUTODISARM: not yet
  vx_note_stack ns = {};
  if (!(ss->ss_flags & SS_DISABLE)) {
    if (ss->ss_size < MINSIGSTKSZ) return -ENOMEM;
    ns = (vx_note_stack){(uint64_t)ss->ss_sp, ss->ss_size};
  }
  if (vx_thread_state(vx_self, 0, VX_STATE_SET_NOTE_STACK, &ns, sizeof ns) != VX_OK) return -EINVAL;
  me->alt_base = ns.base, me->alt_size = ns.size;
  return 0;
}

// The call's state, the thread's own: a sleep in one thread keeps no other's deadline.
#define sig_restarting    (be_me()->restarting)
#define sig_call_deadline (be_me()->call_deadline)

#include "fd.c"
#include "memory.c"
#include "start.c"
#include "process.c"
#include "signal.c"
#include "poll.c"
#include "socket.c"

// A thread's id: the pid for the first thread, until set_tid_address says so too.
static long gettid_of(const be_thread *t) { return t->tid ? t->tid : posix_pid(); }

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
  case SYS_dup3: // a target that cannot be one is EBADF, not dup's lowest free
    if ((int)a2 < 0) return -EBADF;
    return a1 == a2 ? -EINVAL : fd_dup((int)a1, (int)a2, (int)a3);
  case SYS_faccessat:
  case SYS_faccessat2: return fd_faccessat((int)a1, (const char *)a2, (int)a3); // flags: no effective ids
  case SYS_flock: return fd_flock((int)a1, (int)a2);
  case SYS_sync:
  case SYS_syncfs: vx_ns_sync(fd_namespace()); return 0;
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
  case SYS_umask: return fd_set_umask((mode_t)a1);
#ifdef SYS_open // x86_64's calls that aarch64 has only as their *at forms
  case SYS_open: return fd_openat(AT_FDCWD, (const char *)a1, (int)a2, (mode_t)a3);
  case SYS_stat: return fd_fstatat(AT_FDCWD, (const char *)a1, (struct stat *)a2, 0);
  case SYS_lstat: return fd_fstatat(AT_FDCWD, (const char *)a1, (struct stat *)a2, AT_SYMLINK_NOFOLLOW);
  case SYS_access: return fd_faccessat(AT_FDCWD, (const char *)a1, (int)a2);
  case SYS_mkdir: return fd_mkdirat(AT_FDCWD, (const char *)a1, (mode_t)a2);
  case SYS_unlink: return fd_unlinkat(AT_FDCWD, (const char *)a1, 0);
  case SYS_rmdir: return fd_unlinkat(AT_FDCWD, (const char *)a1, AT_REMOVEDIR);
  case SYS_dup2: return (int)a2 < 0 ? -EBADF : fd_dup2((int)a1, (int)a2);
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
    struct timespec ts = {};
    if (tv && (tv->tv_sec < 0 || tv->tv_usec < 0)) return -EINVAL;
    if (tv) // microseconds past a second carried into the seconds, as Linux does
      ts = (struct timespec){tv->tv_sec + tv->tv_usec / 1'000'000, tv->tv_usec % 1'000'000 * 1000};
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
  // Mapped files' writes reach fsd's page cache at once, and the volume
  // within 10 s or at the file's next fsync: msync has nothing to start, and
  // MS_SYNC does not yet wait (docs/milestones.md).
  case SYS_msync:
  case SYS_madvise: // advice
  case SYS_brk:     // no break: musl's malloc maps instead
    return 0;

  // The process (start.c)
  case SYS_exit: be_thread_exit((int)a1); // the thread; the process, if it was the last
  case SYS_exit_group: proc_exit((int)a1);
  case SYS_getpid: return posix_pid();
  case SYS_gettid: return gettid_of(be_me());
  case SYS_set_tid_address: // musl's last step setting up the first thread (its TLS is there now), and _Fork's
    if (!be_tls) be_tl = be_early, be_tls = true, be_slot_set(0, be_only_thread_id(), &be_tl);
    be_tl.ctid = (volatile int *)a1, be_tl.tid = posix_pid();
    return be_tl.tid;
  case SYS_getppid: return posix_getppid();
  case SYS_getpgid: return posix_getpgid(a1);
  case SYS_getsid: return posix_getsid(a1);
  case SYS_setpgid: return posix_setpgid(a1, a2);
  case SYS_setsid: return posix_setsid();
  case SYS_wait4: return posix_wait4(a1, (int *)a2, (int)a3, (struct rusage *)a4);
  case SYS_execve: return proc_execve((const char *)a1, (char *const *)a2, (char *const *)a3);
  case SYS_clone: // musl's _Fork and vfork, where there is no SYS_fork; threads come through __clone
    return a1 == SIGCHLD && !a2 ? proc_fork() : -ENOSYS;
  case SYS_pipe2: return fd_pipe2((int *)a1, (int)a2);
  case SYS_getuid:
  case SYS_geteuid:
  case SYS_getgid:
  case SYS_getegid: return 0;
  case SYS_uname: return proc_uname((struct utsname *)a1);
  case SYS_getrandom: return proc_getrandom((void *)a1, (size_t)a2);
  // Signals (signal.c)
  case SYS_tkill: return be_thread_kill(a1, (int)a2);
  case SYS_tgkill: return a1 == posix_pid() ? be_thread_kill(a2, (int)a3) : -ESRCH;
  case SYS_set_robust_list: // musl's robust mutexes: the kernel marks them OWNER_DIED as the thread ends
    if (a2 != 24) return -EINVAL;
    if (vx_thread_set_robust((const void *)a1, (uint64_t)a2, (uint32_t)gettid_of(be_me())) != VX_OK)
      return -EINVAL;
    be_me()->robust = (uint64_t)a1;
    return 0;
  case SYS_get_robust_list: // musl asks it once, to see robust mutexes work
    if (a1 && a1 != gettid_of(be_me())) return -EPERM;
    *(void **)a2 = (void *)be_me()->robust, *(size_t *)a3 = 24;
    return 0;
  case SYS_kill: return sig_kill(a1, (int)a2);
  case SYS_rt_sigaction: return sig_action((int)a1, (const k_sigaction *)a2, (k_sigaction *)a3);
  case SYS_rt_sigprocmask: return sig_procmask((int)a1, (const uint64_t *)a2, (uint64_t *)a3);
  case SYS_rt_sigpending:
    return *(uint64_t *)a1 = sig_pending | be_me()->pending, 0; // the process's and the thread's
  case SYS_rt_sigsuspend: return sig_suspend(*(const uint64_t *)a1);
  case SYS_sigaltstack: return be_altstack((const stack_t *)a1, (stack_t *)a2);
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

// --- pthread_create's thread (6d2a) ---

typedef struct be_clone {
  int (*fn)(void *);
  void *arg;
  uint64_t tls;
  long tid;
  uint32_t slot;
  volatile int *ctid;
  uint64_t mask;
} be_clone;

// The new thread's first steps: its thread pointer (musl's TLS) before
// anything, then its own state, then musl's start, which ends in SYS_exit.
[[noreturn]] static void be_clone_entry(vx_handle unused, uint64_t at) {
  (void)unused;
  const be_clone *c = (const be_clone *)at;
  uint64_t tls = c->tls;
#ifdef __x86_64__
  vx_thread_state(vx_self, 0, VX_STATE_SET_TLS, &tls, sizeof tls);
#else
  __asm__ volatile("msr tpidr_el0, %0" : : "r"(tls));
#endif
  be_tl = (be_thread){.tid = c->tid, .ctid = c->ctid, .mask = c->mask, .slot = c->slot + 1};
  atomic_store(&be_threads[c->slot].t, &be_tl); // __clone gave the slot its kernel id
  int code = c->fn(c->arg);
  __vx_syscall(SYS_exit, code, 0, 0, 0, 0, 0);
  __builtin_unreachable();
}

// musl's __clone (src/thread/clone.c, whose -ENOSYS this replaces), as
// pthread_create calls it: a thread of this task on stack, its TLS tls, its
// id written to *ptid, *ctid cleared and woken at its end.
// musl's pthread_create calls it (pthread_impl.h, hidden there)
// NOLINTNEXTLINE(misc-use-internal-linkage)
int __clone(int (*fn)(void *), void *stack, int flags, void *arg, ...);
int __clone(int (*fn)(void *), void *stack, int flags, void *arg, ...) {
  constexpr int need = CLONE_VM | CLONE_THREAD | CLONE_SETTLS;
  if ((flags & need) != need) return -ENOSYS; // fork comes through SYS_clone
  va_list ap;
  va_start(ap, arg);
  int *ptid = va_arg(ap, int *);
  void *tls = va_arg(ap, void *);
  int *ctid = va_arg(ap, int *);
  va_end(ap);
  // The record on the top of the new thread's own stack, which it reads first.
  uintptr_t top = ((uintptr_t)stack - sizeof(be_clone)) & ~(uintptr_t)15;
  be_clone *c = (be_clone *)top;
  *c = (be_clone){.fn = fn,
                  .arg = arg,
                  .tls = (uint64_t)tls,
                  .ctid = flags & CLONE_CHILD_CLEARTID ? ctid : nullptr,
                  .mask = be_me()->mask};
  int slot = posix_pid() <= BE_PID_MASK ? be_slot_take() : -1;
  if (slot < 0) return -EAGAIN; // 255 threads besides the first, or a pid past 2^22: no id fits (ADR-0037)
  vx_handle th;
  uint32_t id = 0;
  vx_status st = vx_thread_create_id(vx_self, &th, &id);
  if (st != VX_OK) {
    atomic_store(&be_threads[slot].id, 0);
    return (int)vx_errno(st);
  }
  c->slot = (uint32_t)slot;
  c->tid = (long)slot << BE_TID_SHIFT | posix_pid();
  atomic_store(&be_threads[slot].id, id);
  if (flags & CLONE_PARENT_SETTID) *ptid = (int)c->tid;
  atomic_fetch_add(&be_live, 1);
  st = vx_thread_start(th, (uint64_t)be_clone_entry, top, VX_HANDLE_NONE, top);
  vx_handle_close(th); // the thread goes on without it
  if (st != VX_OK) {
    atomic_fetch_sub(&be_live, 1);
    atomic_store(&be_threads[slot].id, 0);
    return (int)vx_errno(st);
  }
  return (int)c->tid;
}

// SYS_exit: the thread ends; the last one ends the process, as on Linux. It
// lets go of the back end first, then clears its ctid (musl's thread list
// lock, which a joiner waits on) and ends in registers alone, its stack being
// free to go from then on.
[[noreturn]] static void be_thread_exit(int code) {
  if (atomic_fetch_sub(&be_live, 1) == 1) proc_exit(code);
  be_thread *me = be_me();
  be_unregister(me);
  volatile int *ctid = me->ctid;
  if (me->depth) me->depth = 0, vx_mutex_unlock(&be_lock);
  if (ctid) vx_thread_finish((_Atomic uint32_t *)ctid);
  vx_thread_exit();
}

// musl's __unmapself (whose generic C this replaces): a detached thread's
// end, its stack and TLS unmapped while it runs. Everything that needs them
// first (the lock let go, the count); then, in registers alone: the unmap,
// ctid (musl's thread list lock, which is not on the stack) cleared and
// woken, the thread ended.
[[noreturn]] static void be_unmap_finish(vx_handle self, void *base, size_t size, const volatile int *ctid) {
#ifdef __x86_64__
  register uint64_t r10 __asm__("r10") = 0;
  __asm__ volatile(
      "mov %[self], %%rdi\n\t"
      "mov %[base], %%rsi\n\t"
      "mov %[size], %%rdx\n\t"
      "mov %[unmap], %%eax\n\t"
      "syscall\n\t" // as_unmap(self, base, size): the stack is gone from here
      "test %[ctid], %[ctid]\n\t"
      "jz 1f\n\t"
      "movl $0, (%[ctid])\n\t"
      "mov %[ctid], %%rdi\n\t"
      "mov $1, %%esi\n\t"
      "mov %[wake], %%eax\n\t"
      "syscall\n" // futex_wake(ctid, 1)
      "1:\n\t"
      "mov %[exit], %%eax\n\t"
      "syscall\n\t" // thread_exit()
      "ud2"
      :
      : [self] "r"((uint64_t)self), [base] "r"(base), [size] "r"(size), [ctid] "r"(ctid),
        "r"(r10), [unmap] "i"(VX_SYS_as_unmap), [wake] "i"(VX_SYS_futex_wake), [exit] "i"(VX_SYS_thread_exit)
      : "rax", "rdi", "rsi", "rdx", "rcx", "r11", "memory");
#else
  __asm__ volatile(
      "mov x9, %[ctid]\n\t"
      "mov x0, %[self]\n\t"
      "mov x1, %[base]\n\t"
      "mov x2, %[size]\n\t"
      "mov x8, %[unmap]\n\t"
      "svc #0\n\t" // as_unmap(self, base, size): the stack is gone from here
      "cbz x9, 1f\n\t"
      "stlr wzr, [x9]\n\t"
      "mov x0, x9\n\t"
      "mov x1, #1\n\t"
      "mov x8, %[wake]\n\t"
      "svc #0\n" // futex_wake(ctid, 1)
      "1:\n\t"
      "mov x8, %[exit]\n\t"
      "svc #0\n\t" // thread_exit()
      "brk #0"
      :
      : [self] "r"((uint64_t)self), [base] "r"(base), [size] "r"(size), [ctid] "r"(ctid),
        [unmap] "i"(VX_SYS_as_unmap), [wake] "i"(VX_SYS_futex_wake), [exit] "i"(VX_SYS_thread_exit)
      : "x0", "x1", "x2", "x8", "x9", "memory");
#endif
  __builtin_unreachable();
}

// musl's pthread_exit calls it (pthread_impl.h, hidden there)
// NOLINTNEXTLINE(misc-use-internal-linkage)
void __unmapself(void *base, size_t size);
void __unmapself(void *base, size_t size) {
  if (atomic_fetch_sub(&be_live, 1) == 1) proc_exit(0);
  be_thread *me = be_me();
  be_unregister(me);
  volatile int *ctid = me->ctid;
  if (me->depth) me->depth = 0, vx_mutex_unlock(&be_lock);
  be_unmap_finish(vx_self, base, (size + 4095) & ~(size_t)4095, ctid);
}

// tkill and tgkill: to this thread, its own, delivered as the call returns; to
// another, a note to its kernel thread (its id's slot says which), whose
// handler keeps it for that thread.
static long be_thread_kill(long tid, int sig) {
  if (sig < 0 || sig > SIG_MAX) return -EINVAL;
  long pid = posix_pid();
  uint64_t slot = (uint64_t)tid >> BE_TID_SHIFT;
  if (tid <= 0 || (tid & BE_PID_MASK) != pid || slot >= BE_THREADS) return -ESRCH;
  uint32_t id = atomic_load(&be_threads[slot].id);
  if (!id || id == BE_SLOT_TAKEN) return -ESRCH;
  if (!sig) return 0;
  if (be_me()->slot == slot + 1) {
    be_me()->pending |= sig_bit(sig), sig_sender[sig] = pid;
    return 0;
  }
  char note[VX_ERRMAX];
  size_t len = posix_note(sig, posix_pid(), note);
  if (len + sizeof BE_DIRECTED - 1 <= sizeof note) // its own: sig_note keeps it for that thread
    memcpy(note + len, BE_DIRECTED, sizeof BE_DIRECTED - 1), len += sizeof BE_DIRECTED - 1;
  vx_status st = vx_thread_interrupt(vx_self, id, (vx_str){note, len});
  return st == VX_ERR_NOT_FOUND ? -ESRCH : vx_errno(st);
}

// Every call musl makes. A signal that arrives during one is delivered as it
// returns (signal.c). A call that a signal interrupted is made again unless
// a handler that wants EINTR ran: SA_RESTART, an ignored signal, and a
// blocked one (the kernel ends a wait for any note) do not end it. poll,
// select and the sleeps end with EINTR once any handler has run on the
// thread, as Linux's do (signal(7)); sigsuspend and pause always do. Each
// time, a sleep's or poll's deadline is the first's.
long __vx_syscall(long n, long a1, long a2, long a3, long a4, long a5, long a6) {
  bool waits = n == SYS_ppoll || n == SYS_pselect6 || n == SYS_nanosleep || n == SYS_clock_nanosleep,
       pauses = n == SYS_rt_sigsuspend || (n == SYS_ppoll && a1 == 0 && a2 == 0);
#ifdef SYS_poll
  waits = waits || n == SYS_poll || n == SYS_select;
#endif
#ifdef SYS_pause
  pauses = pauses || n == SYS_pause;
#endif
  // The depth stays up until the call is done, made again or not: a signal
  // that comes between is pending, not run before the choice is made.
  if (n == SYS_exit) be_thread_exit((int)a1); // never returns: holds nothing
  be_enter();
  uint32_t ran = sig_handlers_ran, cut = sig_eintr_ran;
  bool outer = sig_depth == 0;
  sig_depth = sig_depth + 1;
  long r = vx_dispatch(n, a1, a2, a3, a4, a5, a6);
  while (outer) {
    sig_run_pending();
    bool eintr = sig_eintr_ran != cut || (waits && sig_handlers_ran != ran);
    if (r != -EINTR || eintr || pauses) break;
    sig_restarting = true;
    r = vx_dispatch(n, a1, a2, a3, a4, a5, a6);
    sig_restarting = false;
  }
  sig_depth = sig_depth - 1;
  if (outer) sig_run_pending(); // one that came after the choice: on the way out
  be_leave();
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
