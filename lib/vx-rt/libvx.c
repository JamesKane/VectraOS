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
//   __llvm_libc_file_*            FILE streams (LLVM patch 0007, 6e2c2):
//                                 handles 0-2 the standard streams, the rest
//                                 files of the namespace (vx-ns)

#define VX_RT_LIBC // the C library has memcpy and the rest (rt.c)
#include "rt.c"
#include "../vx-ns/spawn.c"

#include "libvx.h"

// --- The program ---

const char *vx_main(void) { exit(main(vx_argc(), vx_argv())); }

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
  int64_t n = vx_read(buf, size > UINT32_MAX ? UINT32_MAX : (uint32_t)size);
  return n < 0 ? -1 : (long)n;
}

// --- The heap ---

void *__llvm_libc_heap_allocate(size_t size, size_t alignment) {
  return vx_heap_alloc_aligned(vx_heap_process(), size, alignment < 16 ? 16 : alignment);
}

void __llvm_libc_heap_free(void *p) { vx_heap_free(vx_heap_process(), p); }

size_t __llvm_libc_heap_usable_size(void *p) { return vx_heap_usable(vx_heap_process(), p); }

// --- Files and the environment, through the process's namespace ---

static vx_ns libvx_ns;
static vx_mutex libvx_ns_lock; // the namespace's, and getenv's table
static bool libvx_ns_tried;

// The namespace, made from the spawn message at first use; under the lock.
static vx_ns *libvx_namespace(void) {
  if (!libvx_ns_tried) {
    libvx_ns_tried = true;
    vx_ns_from_spawn(&libvx_ns);
  }
  return &libvx_ns;
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
  vx_mutex_lock(&libvx_ns_lock);
  vx_status st = vx_ns_walk(libvx_namespace(), vx_cstr(path), &c, &fid);
  if (st == VX_OK) st = p9c_remove(c, fid); // which clunks it
  vx_mutex_unlock(&libvx_ns_lock);
  return libvx_errno(st);
}

// Within one server: by Trenameat where it has it, else by Twstat within one
// directory, what is there removed first, as musl's back end does.
static vx_status libvx_rename(p9_client *c, uint32_t f1, vx_str n1, uint32_t f2, vx_str n2, bool same_dir) {
  if ((c->extensions & P9_EXT_POSIX) || c->dialect == P9_2000L) return p9c_renameat(c, f1, n1, f2, n2);
  if (!same_dir) return VX_ERR_UNSUPPORTED;
  vx_status st = p9c_rename_wstat(c, f1, n1, n2);
  uint32_t there = 0;
  if (st == VX_ERR_EXISTS && p9c_walk(c, f1, n2, &there) == VX_OK && p9c_remove(c, there) == VX_OK)
    st = p9c_rename_wstat(c, f1, n1, n2);
  return st;
}

int __llvm_libc_rename(const char *from, const char *to) {
  p9_client *c1 = nullptr, *c2 = nullptr;
  uint32_t f1 = 0, f2 = 0;
  vx_str n1 = {}, n2 = {};
  vx_mutex_lock(&libvx_ns_lock);
  vx_status st = libvx_parent(from, &c1, &f1, &n1);
  vx_status st2 = st == VX_OK ? libvx_parent(to, &c2, &f2, &n2) : st;
  bool same_dir = st2 == VX_OK && n1.ptr - from == n2.ptr - to && !memcmp(from, to, (size_t)(n1.ptr - from));
  int e = libvx_errno(st2);
  if (st2 == VX_OK) e = c1 == c2 ? libvx_errno(libvx_rename(c1, f1, n1, f2, n2, same_dir)) : LIBVX_EXDEV;
  if (st == VX_OK) p9c_clunk(c1, f1);
  if (st2 == VX_OK) p9c_clunk(c2, f2);
  vx_mutex_unlock(&libvx_ns_lock);
  return e;
}

// --- Files: the C library's FILE streams (LLVM patch 0007) ---
//
// A handle is 0, 1 or 2, the standard streams through vx-rt, or a file of
// the namespace, at 3 and up. Opening and closing take the namespace's lock;
// a file's reads and writes are its stream's, which the C library locks.

enum : int { FILE_READ = 1, FILE_WRITE = 2, FILE_CREATE = 4, FILE_TRUNCATE = 8, FILE_APPEND = 16 };

static constexpr uint32_t LIBVX_FILES = 64;
static struct {
  bool used, append;
  vx_ns_file f;
} libvx_files[LIBVX_FILES];

// A namespace file's handle, or nullptr.
static vx_ns_file *libvx_file(long h) {
  return h >= 3 && h < 3 + (long)LIBVX_FILES && libvx_files[h - 3].used ? &libvx_files[h - 3].f : nullptr;
}

// A file's length, from the server: -errno if it cannot say.
static int64_t libvx_file_length(vx_ns_file *f) {
  p9_stat s = {};
  vx_status st = f->c ? p9c_stat(f->c, f->fid, &s, nullptr) : VX_ERR_UNSUPPORTED;
  return st == VX_OK ? (int64_t)s.length : -LIBVX_ESPIPE;
}

long __llvm_libc_file_open(const char *path, int flags) {
  uint8_t mode = P9_OREAD;
  if ((flags & FILE_READ) && (flags & FILE_WRITE))
    mode = P9_ORDWR;
  else if (flags & FILE_WRITE)
    mode = P9_OWRITE;
  vx_mutex_lock(&libvx_ns_lock);
  uint32_t slot = 0;
  while (slot < LIBVX_FILES && libvx_files[slot].used) slot++;
  vx_status st = slot < LIBVX_FILES ? VX_OK : VX_ERR_NO_MEMORY;
  vx_ns_file f = {};
  vx_str p = vx_cstr(path);
  if (st == VX_OK) st = vx_ns_open(libvx_namespace(), p, mode | (flags & FILE_TRUNCATE ? P9_OTRUNC : 0), &f);
  if (st == VX_ERR_NOT_FOUND && (flags & FILE_CREATE))
    st = vx_ns_create(libvx_namespace(), p, 0666, mode, &f);
  if (st == VX_OK)
    libvx_files[slot] = (typeof(libvx_files[0])){.used = true, .append = flags & FILE_APPEND, .f = f};
  vx_mutex_unlock(&libvx_ns_lock);
  if (slot == LIBVX_FILES) return -LIBVX_EMFILE;
  return st == VX_OK ? (long)slot + 3 : -libvx_errno(st);
}

long __llvm_libc_file_read(long h, void *buf, size_t size) {
  uint32_t n = size > 65536 ? 65536 : (uint32_t)size;
  if (h == 0) {
    int64_t got = vx_read(buf, n);
    return got < 0 ? -LIBVX_EIO : (long)got;
  }
  vx_ns_file *f = libvx_file(h);
  if (!f) return -LIBVX_EBADF;
  int64_t got = vx_ns_read(f, buf, n);
  return got < 0 ? -libvx_errno((vx_status)got) : (long)got;
}

long __llvm_libc_file_write(long h, const void *buf, size_t size) {
  if (h == 1 || h == 2) {
    __llvm_libc_stdio_write(h == 2 ? &__llvm_libc_stderr_cookie : &__llvm_libc_stdout_cookie, buf, size);
    return (long)size;
  }
  vx_ns_file *f = libvx_file(h);
  if (!f) return -LIBVX_EBADF;
  if (libvx_files[h - 3].append) { // each write at the end, wherever the end is now
    int64_t end = libvx_file_length(f);
    if (end < 0) return (long)end;
    f->offset = (uint64_t)end;
  }
  size_t done = 0;
  while (done < size) {
    uint32_t n = size - done > 65536 ? 65536 : (uint32_t)(size - done);
    int64_t put = vx_ns_write(f, (const uint8_t *)buf + done, n);
    vx_status st = put < 0 ? (vx_status)put : VX_ERR_IO; // a write of nothing: an I/O error
    if (put <= 0) return done ? (long)done : -libvx_errno(st);
    done += (size_t)put;
  }
  return (long)done;
}

long long __llvm_libc_file_seek(long h, long long offset, int whence) {
  vx_ns_file *f = libvx_file(h);
  if (!f) return h >= 0 && h <= 2 ? -LIBVX_ESPIPE : -LIBVX_EBADF;
  int64_t base = 0; // SEEK_SET
  if (whence == 1) base = (int64_t)f->offset;
  if (whence == 2) base = libvx_file_length(f);
  if (base < 0 || whence < 0 || whence > 2) return base < 0 ? base : -LIBVX_EINVAL;
  if (offset < -base) return -LIBVX_EINVAL;
  f->offset = (uint64_t)(base + offset);
  return (long long)f->offset;
}

int __llvm_libc_file_close(long h) {
  if (h >= 0 && h <= 2) return 0; // the standard streams stay
  vx_mutex_lock(&libvx_ns_lock);
  vx_ns_file *f = libvx_file(h);
  if (f) vx_ns_close(f), libvx_files[h - 3].used = false;
  vx_mutex_unlock(&libvx_ns_lock);
  return f ? 0 : LIBVX_EBADF;
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
static int64_t libvx_env_read(vx_str name, char *buf, uint32_t cap) {
  char path[80] = "/env/";
  memcpy(path + 5, name.ptr, name.len);
  vx_ns_file f;
  vx_status st = vx_ns_open(libvx_namespace(), (vx_str){path, 5 + name.len}, P9_OREAD, &f);
  if (st != VX_OK) {
    p9_client *c = nullptr;
    uint32_t fid = 0;
    bool env = vx_ns_walk(libvx_namespace(), VX_STR("/env"), &c, &fid) == VX_OK;
    if (env) p9c_clunk(c, fid);
    return env ? -1 : -2;
  }
  int64_t n = 0;
  while (n < cap) {
    int64_t got = vx_ns_read(&f, buf + n, cap - (uint32_t)n);
    if (got <= 0) break;
    n += got;
  }
  vx_ns_close(&f);
  return n;
}

char *__llvm_libc_getenv(const char *cname) {
  static char buf[16 * 1024];
  vx_str name = vx_cstr(cname);
  bool slash = false;
  for (size_t i = 0; i < name.len; i++) slash = slash || name.ptr[i] == '/';
  if (!name.len || name.len >= sizeof libvx_env[0].name || slash) return nullptr;
  vx_mutex_lock(&libvx_ns_lock);
  int64_t n = libvx_env_read(name, buf, sizeof buf - 1);
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
  vx_mutex_unlock(&libvx_ns_lock);
  return value;
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
  libvx_timespec_of(vx_clock_utc(), ts);
  return true;
}

// clock's: the CPU time the whole process has had (ADR-0041).
bool __llvm_libc_timespec_get_active(libvx_timespec *ts) {
  vx_cpu_times t = {};
  if (vx_thread_state(vx_self, 0, VX_STATE_GET_TIMES, &t, sizeof t) != VX_OK) return false;
  libvx_timespec_of(t.user + t.sys, ts);
  return true;
}
