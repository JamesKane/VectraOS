// libvx.c: libvx.a for the native target's sysroot (M6 step 6e2b, ADR-0033
// §1, os-requirements R7): vx-rt and vx-ns as one object, and the hooks the
// C library (llvm-libc's baremetal layer, LLVM patch 0004) calls the system
// through. A C program's start is vx-rt's (crt1.o, start.c), its main
// called by vx_main below; the C library's own functions never make a
// system call.
//
// First-party code: no hosted header. What the hooks share with the C
// library, its errno numbers and struct timespec, is spelled out here from
// llvm-libc's generic headers.
//
//   __llvm_libc_stdio_write/read  standard output and error through vx-rt's
//                                 buffered writers, standard input through
//                                 vx_read (6e2c's File back end replaces them)
//   __llvm_libc_exit              vx_exit: .fini_array, then n in decimal
//   __llvm_libc_errno             a thread_local word
//   __llvm_libc_heap_*            the process heap (vx_heap_process)
//   __llvm_libc_getenv            /env/NAME (ADR-0044), else the spawn's env=
//   __llvm_libc_remove, _rename   the namespace's files, 0 or an errno value
//   __llvm_libc_timespec_get_*    UTC, and the process's CPU time (clock)
//   __llvm_libc_futex_wait/wake   the kernel's futexes, for the C library's
//                                 mutex (LLVM patch 0006, 6e2c1)
//   __llvm_libc_thread_*          <threads.h> (LLVM patch 0008, 6e2c3): vx-rt
//                                 threads, a detached one freed once it ends
//   __llvm_libc_file_*            FILE streams (LLVM patch 0007, 6e2c2):
//                                 handles 0-2 the standard streams, the rest
//                                 files of the namespace (vx-ns)

#define VX_RT_LIBC // the C library has memcpy and the rest (rt.c)
#include "rt.c"
#include "../vx-ns/file.c"
#include "../vx-ns/proc.c"
#include "../vx-ns/spawn.c"

#include "libvx.h"

// --- The program ---
//
// vx_main, C's main and then exit, is the sysroot's crt1.o's (start.c), in
// the program with main and the C library's exit, whether libvx is linked
// statically or is libvx.so (6f1b1).

// Swift's CommandLine.arguments (Swift patch 0007): vx-rt's argv, which
// main has too.
char **__swift_vectraos_argv(int *argc) {
  *argc = vx_argc();
  return vx_argv();
}

// Swift's global executor: a worker thread per CPU this program may use
// (6e3b, Swift patch 0012).
unsigned __swift_vectraos_cpu_count(void) { return vx_cpu_count(); }

// Swift's #available(VectraOS n, *) (Swift patch 0020, ADR-0048): VectraOS's
// version is the vx-abi level.
unsigned long __swift_vectraos_abi_level(void) { return vx_abi_level(); }

// Foundation's ProcessInfo (6e3c): the process's id and user (the host's
// name is below, with the namespace). The name is cut to fit and terminated,
// and its whole length returned.
uint64_t __swift_vectraos_pid(void) { return vx_pid(); }

size_t __swift_vectraos_user_name(char *buf, size_t cap) {
  vx_str u = vx_user_name();
  if (cap) {
    size_t n = u.len < cap - 1 ? u.len : cap - 1;
    memcpy(buf, u.ptr, n);
    buf[n] = 0;
  }
  return u.len;
}

[[noreturn]] void __llvm_libc_exit(int status) { vx_exit(status); }

// --- errno: the C library's numbers (llvm-libc's generic ones) ---

enum : int {
  LIBVX_EPERM = 1,
  LIBVX_ENOENT = 2,
  LIBVX_EIO = 5,
  LIBVX_EBADF = 9,
  LIBVX_ENOMEM = 12,
  LIBVX_EACCES = 13,
  LIBVX_EEXIST = 17,
  LIBVX_EXDEV = 18,
  LIBVX_EINVAL = 22,
  LIBVX_ENOSPC = 28,
  LIBVX_ESPIPE = 29,
  LIBVX_EMFILE = 24,
};

int *__llvm_libc_errno(void) {
  static thread_local int e;
  return &e;
}

static int libvx_errno(vx_status st) {
  switch (st) {
  case VX_OK: return 0;
  case VX_ERR_NOT_FOUND: return LIBVX_ENOENT;
  case VX_ERR_ACCESS: return LIBVX_EACCES;
  case VX_ERR_EXISTS: return LIBVX_EEXIST;
  case VX_ERR_INVALID: return LIBVX_EINVAL;
  case VX_ERR_NO_MEMORY: return LIBVX_ENOMEM;
  case VX_ERR_NO_SPACE: return LIBVX_ENOSPC;
  case VX_ERR_UNSUPPORTED:
  case VX_ERR_REFUSED: return LIBVX_EPERM;
  default: return LIBVX_EIO;
  }
}

// The same for Foundation's errors (6e3c): the errno a vx_status reads as.
int __swift_vectraos_errno(int status) { return libvx_errno((vx_status)status); }

// --- Futexes, for the C library's locks ---

// Blocks while *word is expected, until a wake or the deadline (ns on the
// monotonic clock, -1 for none): 0, or -1 at the deadline.
int __llvm_libc_futex_wait(const uint32_t *word, uint32_t expected, int64_t deadline) {
  vx_status st =
      vx_futex_wait((const _Atomic uint32_t *)word, expected, deadline < 0 ? VX_INFINITE : deadline);
  return st == VX_ERR_TIMED_OUT ? -1 : 0;
}

void __llvm_libc_futex_wake(const uint32_t *word, uint32_t count) {
  vx_futex_wake((const _Atomic uint32_t *)word, count);
}

// --- Threads: the C library's <threads.h> (LLVM patch 0008) ---
//
// A C library thread is a vx-rt thread. Its joiner frees it; a detached one
// is kept on a list and freed by the next create or join after it has ended,
// as nothing can unmap a thread's stack while it runs on it.

typedef struct libvx_thread {
  vx_worker t;
  struct libvx_thread *next;
} libvx_thread;

static libvx_thread *libvx_detached;
static vx_lock_t libvx_threads_lock;

// The detached threads that have ended, freed.
static void libvx_reap(void) {
  vx_lock(&libvx_threads_lock);
  for (libvx_thread **p = &libvx_detached; *p;) {
    libvx_thread *lt = *p;
    if (atomic_load(&lt->t.tcb->running)) {
      p = &lt->next;
      continue;
    }
    *p = lt->next;
    vx_worker_join(&lt->t);
    vx_heap_free(vx_heap_process(), lt);
  }
  vx_unlock(&libvx_threads_lock);
}

int __llvm_libc_thread_create(void (*entry)(void *), void *arg, size_t stacksize, void **handle) {
  libvx_reap();
  libvx_thread *lt = vx_heap_alloc(vx_heap_process(), sizeof *lt);
  if (!lt) return LIBVX_ENOMEM;
  *lt = (libvx_thread){};
  static constexpr size_t LEAST = 256ull * 1024;
  uint64_t stack = stacksize > LEAST ? stacksize : LEAST; // vx-rt's least: C11 asks for 64 KiB
  vx_status st = vx_worker_start(&lt->t, entry, arg, stack);
  if (st != VX_OK) {
    vx_heap_free(vx_heap_process(), lt);
    return st == VX_ERR_NO_MEMORY ? LIBVX_ENOMEM : libvx_errno(st);
  }
  *handle = lt;
  return 0;
}

int __llvm_libc_thread_join(void *handle) {
  libvx_thread *lt = handle;
  vx_worker_join(&lt->t);
  vx_heap_free(vx_heap_process(), lt);
  libvx_reap();
  return 0;
}

void __llvm_libc_thread_detach(void *handle) {
  libvx_thread *lt = handle;
  vx_lock(&libvx_threads_lock);
  lt->next = libvx_detached;
  libvx_detached = lt;
  vx_unlock(&libvx_threads_lock);
}

// The calling thread ends, as if its function had returned; the first
// thread, which vx-rt did not start, just ends.
[[noreturn]] void __llvm_libc_thread_exit(void) {
  vx_tcb *t = vx_tcb_get();
  if (t && t->id != 1) vx_thread_finish(&t->running);
  vx_thread_exit();
}

uint32_t __llvm_libc_thread_id(void) { return vx_thread_self_id(); }

// std::random_device's bytes: the process's generator, seeded from the
// kernel's entropy (LLVM patch 0012).
void __llvm_libcxx_random_bytes(void *buf, size_t n) { vx_random_bytes(buf, n); }

// Where C++ exceptions' unwind tables are (6f2a, LLVM patch 0021): the
// loaded object with a segment holding pc, that segment's start, and the
// object's .eh_frame_hdr; 0 if one is found. A dynamic program's objects are
// the loader's (ADR-0047), a static program's its own headers. libvx itself
// has no unwind tables, so an exception that would unwind through one of its
// frames, a callback's caller, finds none and ends in std::terminate.
static bool vx_eh_object(uint64_t base, const vx_elf_phdr *ph, uint32_t n, uintptr_t pc, uintptr_t *segment,
                         uintptr_t *hdr, size_t *size) {
  bool holds = false;
  for (uint32_t i = 0; i < n && !holds; i++)
    if (ph[i].type == VX_PT_LOAD && pc - (base + ph[i].vaddr) < ph[i].memsz)
      holds = true, *segment = (uintptr_t)(base + ph[i].vaddr);
  for (uint32_t i = 0; holds && i < n; i++)
    if (ph[i].type == VX_PT_GNU_EH_FRAME) {
      *hdr = (uintptr_t)(base + ph[i].vaddr), *size = (size_t)ph[i].memsz;
      return true;
    }
  return false;
}

int __llvm_libunwind_find_eh_frame_hdr(uintptr_t pc, uintptr_t *segment, uintptr_t *hdr, size_t *size) {
  if (vx_dl) {
    for (uint32_t i = 0; i < vx_dl->object_count; i++) {
      const vx_dl_object *o = &vx_dl->objects[i];
      if (vx_eh_object(o->base, (const vx_elf_phdr *)o->phdr, o->phnum, pc, segment, hdr, size)) return 0;
    }
    return -1;
  }
  const vx_elf_phdr *ph = (const vx_elf_phdr *)((const uint8_t *)&__ehdr_start + __ehdr_start.phoff);
  return vx_eh_object(0, ph, __ehdr_start.phnum, pc, segment, hdr, size) ? 0 : -1;
}

// The monotonic clock, for the C library's timed waits (LLVM patch 0009).
int64_t __llvm_libc_clock_monotonic(void) { return vx_now(); }

// --- Standard streams ---

struct __llvm_libc_stdio_cookie __llvm_libc_stdin_cookie = {0}, __llvm_libc_stdout_cookie = {1},
                                __llvm_libc_stderr_cookie = {2};

long __llvm_libc_stdio_write(void *cookie, const char *buf, size_t size) {
  vx_str s = {buf, size};
  if (((struct __llvm_libc_stdio_cookie *)cookie)->fd == 2)
    vx_eprint(s);
  else
    vx_print(s);
  return (long)size;
}

long __llvm_libc_stdio_read(void *cookie, char *buf, size_t size) {
  (void)cookie;
  int64_t n = vx_stdin_read(buf, size > UINT32_MAX ? UINT32_MAX : (uint32_t)size);
  return n < 0 ? -1 : (long)n;
}

// --- The heap ---

void *__llvm_libc_heap_allocate(size_t size, size_t alignment) {
  return vx_heap_alloc_aligned(vx_heap_process(), size, alignment < 16 ? 16 : alignment);
}

void __llvm_libc_heap_free(void *p) { vx_heap_free(vx_heap_process(), p); }

size_t __llvm_libc_heap_usable_size(void *p) { return vx_heap_usable(vx_heap_process(), p); }

// --- Files and the environment, through the process's namespace ---

// The process's namespace (vx-ns's), under its lock, which also keeps
// getenv's table.
static vx_ns *libvx_namespace(void) { return vx_ns_process(); }

// Foundation's host name (6e3c): /sys/name, cut to fit and terminated.
size_t __swift_vectraos_hostname(char *buf, size_t cap) {
  if (!cap) return 0;
  vx_lock(&vx_ns_proc_lock);
  size_t n = vx_hostname(libvx_namespace(), buf, cap - 1);
  vx_unlock(&vx_ns_proc_lock);
  buf[n] = 0;
  return n;
}

// path's parent walked, and its last name: a status.
static vx_status libvx_parent(const char *path, p9_client **c, uint32_t *fid, vx_str *name) {
  vx_str p = vx_cstr(path);
  size_t slash = p.len;
  while (slash > 0 && p.ptr[slash - 1] != '/') slash--;
  *name = (vx_str){p.ptr + slash, p.len - slash};
  if (!name->len) return VX_ERR_INVALID;
  vx_str dir = VX_STR("."); // a name alone: in the current directory
  if (slash) dir = (vx_str){p.ptr, slash > 1 ? slash - 1 : 1};
  return vx_ns_walk(libvx_namespace(), dir, c, fid);
}

int __llvm_libc_remove(const char *path) {
  p9_client *c = nullptr;
  uint32_t fid = 0;
  vx_lock(&vx_ns_proc_lock);
  vx_status st = vx_ns_walk(libvx_namespace(), vx_cstr(path), &c, &fid);
  if (st == VX_OK) st = p9c_remove(c, fid); // which clunks it
  vx_unlock(&vx_ns_proc_lock);
  return libvx_errno(st);
}

int __llvm_libc_rename(const char *from, const char *to) {
  vx_status e = vx_rename(vx_cstr(from), vx_cstr(to));
  return e == VX_ERR_UNSUPPORTED ? LIBVX_EXDEV : libvx_errno(e);
}

// --- Files: the C library's FILE streams (LLVM patch 0007) ---
//
// A handle is 0, 1 or 2, the standard streams through vx-rt, or a file of
// the namespace, at 3 and up. Opening and closing take the namespace's lock;
// a file's reads and writes are its stream's, which the C library locks.

// FILE_EXCLUSIVE creates the file or fails, EEXIST if it is there (Swift's
// Foundation's atomic writes, 6e3c).
enum : int {
  FILE_READ = 1,
  FILE_WRITE = 2,
  FILE_CREATE = 4,
  FILE_TRUNCATE = 8,
  FILE_APPEND = 16,
  FILE_EXCLUSIVE = 32
};

// A handle is a vx_fd (M6 step 6e4d1): 0, 1 and 2 the standard streams, as
// the C library has them, and a file of the namespace's table (file.c).

// A namespace file's open file, or nullptr; as the C library's stream
// locks it, the table's slot lock is not held.
static vx_ns_file *libvx_file(long h) {
  if (h < 0 || h > INT32_MAX) return nullptr;
  vx_file_slot *s = vx_file_get((vx_fd)h);
  if (!s) return nullptr;
  vx_unlock(&s->lock);
  return &s->f;
}

// errno for a file call's result: the call's status is the negative value.
static long libvx_file_errno(int64_t r) { return r < 0 ? -libvx_errno((vx_status)r) : (long)r; }

long __llvm_libc_file_open(const char *path, int flags) {
  vx_mode mode = VX_OREAD;
  if ((flags & FILE_READ) && (flags & FILE_WRITE))
    mode = VX_ORDWR;
  else if (flags & FILE_WRITE)
    mode = VX_OWRITE;
  if (flags & FILE_APPEND) mode |= VX_OAPPEND;
  vx_str p = vx_cstr(path);
  vx_fd fd;
  if (flags & FILE_EXCLUSIVE)
    fd = vx_create(p, mode | VX_OEXCL, 0666);
  else
    fd = vx_open(p, mode | (flags & FILE_TRUNCATE ? VX_OTRUNC : 0));
  if (fd == VX_ERR_NOT_FOUND && (flags & FILE_CREATE) && !(flags & FILE_EXCLUSIVE))
    fd = vx_create(p, mode, 0666);
  if (fd == VX_ERR_NO_MEMORY) return -LIBVX_EMFILE; // the table is full
  return libvx_file_errno(fd);
}

long __llvm_libc_file_read(long h, void *buf, size_t size) {
  if (h < 0 || h > INT32_MAX) return -LIBVX_EBADF;
  int64_t got = vx_read((vx_fd)h, (vx_bytes){buf, size > 65536 ? 65536 : size});
  if (got < 0 && h == 0) return -LIBVX_EIO;
  return libvx_file_errno(got);
}

long __llvm_libc_file_write(long h, const void *buf, size_t size) {
  if (h == 1 || h == 2) {
    __llvm_libc_stdio_write(h == 2 ? &__llvm_libc_stderr_cookie : &__llvm_libc_stdout_cookie, buf, size);
    return (long)size;
  }
  if (h < 0 || h > INT32_MAX) return -LIBVX_EBADF;
  size_t done = 0;
  while (done < size) {
    size_t n = size - done > 65536 ? 65536 : size - done;
    int64_t put = vx_write((vx_fd)h, (vx_str){(const char *)buf + done, n});
    vx_status st = put < 0 ? (vx_status)put : VX_ERR_IO; // a write of nothing: an I/O error
    if (put <= 0) return done ? (long)done : -libvx_errno(st);
    done += (size_t)put;
  }
  return (long)done;
}

long long __llvm_libc_file_seek(long h, long long offset, int whence) {
  if (h >= 0 && h <= 2) return -LIBVX_ESPIPE;
  if (h < 0 || h > INT32_MAX || whence < 0 || whence > 2) return h < 0 ? -LIBVX_EBADF : -LIBVX_EINVAL;
  int64_t at = vx_seek((vx_fd)h, offset, (uint32_t)whence);
  if (at == VX_ERR_UNSUPPORTED) return -LIBVX_ESPIPE;
  return libvx_file_errno(at);
}

int __llvm_libc_file_close(long h) {
  if (h >= 0 && h <= 2) return 0; // the standard streams stay
  if (h < 0 || h > INT32_MAX) return LIBVX_EBADF;
  return vx_close((vx_fd)h) == VX_OK ? 0 : LIBVX_EBADF;
}

// getenv's values, one a name: a value stays good until the next call for
// that name (os-requirements R16).
static constexpr uint32_t LIBVX_ENV_NAMES = 64;
static struct {
  char name[64];
  char *value;
} libvx_env[LIBVX_ENV_NAMES];

// name's slot in the table: its own, else a free one, else the first again.
static uint32_t libvx_env_slot(vx_str name) {
  uint32_t free = LIBVX_ENV_NAMES;
  for (uint32_t i = 0; i < LIBVX_ENV_NAMES; i++) {
    vx_str have = vx_cstr(libvx_env[i].name);
    if (have.len == name.len && !memcmp(have.ptr, name.ptr, name.len)) return i;
    if (!have.len && free == LIBVX_ENV_NAMES) free = i;
  }
  return free == LIBVX_ENV_NAMES ? 0 : free;
}

// /env/NAME's value into buf: its length, or -1 if it is not set there, or
// -2 if the process has no /env.
char *__llvm_libc_getenv(const char *cname) {
  static char buf[16 * 1024];
  vx_str name = vx_cstr(cname);
  bool slash = false;
  for (size_t i = 0; i < name.len; i++) slash = slash || name.ptr[i] == '/';
  if (!name.len || name.len >= sizeof libvx_env[0].name || slash) return nullptr;
  vx_lock(&vx_ns_proc_lock);
  int64_t n = vx_env_read(name, buf, sizeof buf - 1);
  vx_str v = {buf, n > 0 ? (size_t)n : 0};
  if (n == -2) v = vx_getenv(name); // no /env: what the spawn message gave
  char *value = nullptr;
  if (n != -1 && v.ptr) value = vx_heap_alloc(vx_heap_process(), v.len + 1);
  if (value) {
    memcpy(value, v.ptr, v.len);
    while (v.len && !value[v.len - 1]) v.len--; // rc's list: its words end in NUL,
    for (size_t i = 0; i < v.len; i++)          // given as one string, as 9front's APE does
      if (!value[i]) value[i] = ' ';
    value[v.len] = 0;
    uint32_t slot = libvx_env_slot(name);
    vx_heap_free(vx_heap_process(), libvx_env[slot].value);
    memcpy(libvx_env[slot].name, name.ptr, name.len);
    libvx_env[slot].name[name.len] = 0;
    libvx_env[slot].value = value;
  }
  vx_unlock(&vx_ns_proc_lock);
  return value;
}

// The whole environment as NAME=VALUE strings and a null, for Foundation's
// ProcessInfo.environment (6e3c): /env's names, each read as getenv reads
// it, or without /env the spawn message's env= records. The list stays good
// until the next call, which frees it.
static vx_lock_t libvx_environ_lock;
static char **libvx_environ;

static void libvx_environ_free(void) {
  for (char **e = libvx_environ; e && *e; e++) vx_heap_free(vx_heap_process(), *e);
  vx_heap_free(vx_heap_process(), libvx_environ);
  libvx_environ = nullptr;
}

static char *libvx_environ_entry(vx_str name, vx_str value) {
  char *e = vx_heap_alloc(vx_heap_process(), name.len + value.len + 2);
  if (!e) return nullptr;
  memcpy(e, name.ptr, name.len);
  e[name.len] = '=';
  memcpy(e + name.len + 1, value.ptr, value.len);
  e[name.len + 1 + value.len] = 0;
  return e;
}

char **__swift_vectraos_environ(void) {
  static constexpr uint32_t MAX = 256;
  vx_lock(&libvx_environ_lock);
  libvx_environ_free();
  libvx_environ = vx_heap_alloc(vx_heap_process(), (MAX + 1) * sizeof(char *));
  uint32_t n = 0;
  if (libvx_environ) {
    int64_t dir = __llvm_libcxx_fs_opendir("/env");
    if (dir >= 0) {
      char name[64];
      uint32_t type = 0;
      while (n < MAX && __llvm_libcxx_fs_readdir(dir, name, sizeof name, &type) == 1) {
        const char *value = __llvm_libc_getenv(name);
        if (value) {
          char *e = libvx_environ_entry(vx_cstr(name), vx_cstr(value));
          if (e) libvx_environ[n++] = e;
        }
      }
      __llvm_libcxx_fs_closedir(dir);
    } else {
      for (uint32_t i = 0; i < vx_spawn.envc && n < MAX; i++) {
        vx_str e = vx_spawn.envs[i];
        size_t eq = 0;
        while (eq < e.len && e.ptr[eq] != '=') eq++;
        if (eq == e.len) continue;
        char *s = libvx_environ_entry((vx_str){e.ptr, eq}, (vx_str){e.ptr + eq + 1, e.len - eq - 1});
        if (s) libvx_environ[n++] = s;
      }
    }
    libvx_environ[n] = nullptr;
  }
  char **list = libvx_environ;
  vx_unlock(&libvx_environ_lock);
  return list;
}

// --- Time ---

struct libvx_timespec { // the C library's struct timespec
  int64_t tv_sec;
  long tv_nsec;
};

static void libvx_timespec_of(int64_t ns, libvx_timespec *ts) {
  ts->tv_sec = ns / 1'000'000'000;
  ts->tv_nsec = (long)(ns % 1'000'000'000);
}

// TIME_UTC: the wall clock, in UTC.
bool __llvm_libc_timespec_get_utc(libvx_timespec *ts) {
  libvx_timespec_of(vx_wallclock(), ts);
  return true;
}

// clock's: the CPU time the whole process has had (ADR-0041).
bool __llvm_libc_timespec_get_active(libvx_timespec *ts) {
  vx_cpu_times t = {};
  if (vx_thread_state(vx_self, 0, VX_STATE_GET_TIMES, &t, sizeof t) != VX_OK) return false;
  libvx_timespec_of(t.user + t.sys, ts);
  return true;
}

// --- std::filesystem's, for libc++ (LLVM patch 0013, 6e2e2) ---

#include "libvx-fs.c"
