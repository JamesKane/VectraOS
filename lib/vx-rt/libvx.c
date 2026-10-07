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
//   __cxa_finalize               nothing yet: atexit comes with 6e2c

#define VX_RT_LIBC // the C library has memcpy and the rest (rt.c)
#include "rt.c"
#include "../vx-ns/spawn.c"

#include "libvx.h"

// --- The program ---

const char *vx_main(void) { exit(main(vx_argc(), vx_argv())); }

// The C library's exit calls it to run atexit's and static destructors'
// handlers; those come with 6e2c's atexit.
void __cxa_finalize(void *dso) { (void)dso; }

[[noreturn]] void __llvm_libc_exit(int status) { vx_exit(status); }

// --- errno: the C library's numbers (llvm-libc's generic ones) ---

enum : int {
  LIBVX_EPERM = 1,
  LIBVX_ENOENT = 2,
  LIBVX_EIO = 5,
  LIBVX_ENOMEM = 12,
  LIBVX_EACCES = 13,
  LIBVX_EEXIST = 17,
  LIBVX_EXDEV = 18,
  LIBVX_EINVAL = 22,
  LIBVX_ENOSPC = 28,
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
