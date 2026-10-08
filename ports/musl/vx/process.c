// process.c: the process model, through /proc as 9front's APE builds it
// (ADR-0011), and posix_spawn. Part of backend.c.
//
// A process's pid is its task's id, which exec keeps (ADR-0012). Its parent,
// note group (POSIX's process group), session and children are procfs's, and
// are files in /proc/N: ppid, noteid, status (sid=), ctl, note, notepg and
// wait. A child is registered with procfs before it runs (lib/vx-proc).
// Without /proc in its namespace a process is alone: no parent, group or
// children, and its group and session are itself.

static bool proc_mounted; // /proc is in the namespace: procfs knows this process

static long posix_pid(void) { return (long)proc_kernel_id(); }

// "/proc/PID/FILE", in a buffer that lasts until the next call.
static vx_str proc_path(long pid, const char *file) {
  static char path[64];
  int n = snprintf(path, sizeof path, "/proc/%ld/%s", pid, file);
  return (vx_str){path, n > 0 && (size_t)n < sizeof path ? (size_t)n : 0};
}

// The errno for a /proc call that failed: a process that is not there is ESRCH.
static long proc_errno(vx_status st) {
  if (st == VX_ERR_NOT_FOUND) return -ESRCH;
  if (st == VX_ERR_ACCESS) return -EPERM;
  return vx_errno(st);
}

// Reads /proc/PID/FILE (one read) into buf, NUL-terminated: its length, or a negated errno.
static long proc_read(long pid, const char *file, char *buf, size_t cap) {
  if (!proc_mounted) return -ESRCH;
  vx_ns_file f;
  vx_status st = vx_ns_open(fd_namespace(), proc_path(pid, file), P9_OREAD, &f);
  if (st != VX_OK) return proc_errno(st);
  int64_t n = vx_ns_read(&f, buf, (uint32_t)(cap - 1));
  vx_ns_close(&f);
  if (n < 0) return proc_errno((vx_status)n);
  buf[n] = 0;
  return (long)n;
}

// proc_read for a file whose read may wait for long (a child's end): the
// back end let go for the read itself.
static long proc_read_unlocked(long pid, const char *file, char *buf, size_t cap) {
  if (!proc_mounted) return -ESRCH;
  vx_ns_file f;
  vx_status st = vx_ns_open(fd_namespace(), proc_path(pid, file), P9_OREAD, &f);
  if (st != VX_OK) return proc_errno(st);
  uint32_t held = be_wait_begin();
  int64_t n = p9c_read(f.c, f.fid, 0, buf, (uint32_t)(cap - 1));
  be_wait_end(held);
  vx_ns_close(&f);
  if (n < 0) return proc_errno((vx_status)n);
  buf[n] = 0;
  return (long)n;
}

static long proc_write(long pid, const char *file, const char *text) {
  if (!proc_mounted) return -ESRCH;
  vx_ns_file f;
  vx_status st = vx_ns_open(fd_namespace(), proc_path(pid, file), P9_OWRITE, &f);
  if (st != VX_OK) return proc_errno(st);
  int64_t n = vx_ns_write(&f, text, (uint32_t)strlen(text));
  vx_ns_close(&f);
  return n < 0 ? proc_errno((vx_status)n) : 0;
}

// A number in /proc/PID/FILE, or, with key, the value of key= in its record.
static long proc_number(long pid, const char *file, const char *key) {
  char buf[512];
  long n = proc_read(pid, file, buf, sizeof buf);
  if (n < 0) return n;
  const char *at = buf;
  if (key) {
    size_t k = strlen(key);
    for (at = buf; (at = strstr(at, key)); at += k)
      if ((at == buf || at[-1] == ' ') && at[k] == '=') break;
    if (!at) return -EINVAL;
    at += k + 1;
  }
  return strtol(at, nullptr, 10);
}

// Each POSIX process asks procfs for SIGCHLD and its children's stops.
static void posix_init(void) {
  proc_mounted = vx_ns_connector(fd_namespace(), VX_STR("/proc")) != VX_HANDLE_NONE;
  if (proc_mounted) proc_write(posix_pid(), "ctl", "childnotes");
}

static long posix_getppid(void) {
  long r = proc_number(posix_pid(), "ppid", nullptr);
  return r < 0 ? 0 : r;
}

static long posix_getpgid(long pid) {
  if (pid == 0) pid = posix_pid();
  if (!proc_mounted) return pid == posix_pid() ? pid : -ESRCH;
  return proc_number(pid, "noteid", nullptr);
}

static long posix_getsid(long pid) {
  if (pid == 0) pid = posix_pid();
  if (!proc_mounted) return pid == posix_pid() ? pid : -ESRCH;
  return proc_number(pid, "status", "sid");
}

// setpgid writes the group to noteid, as APE does; procfs lets a process join
// a group in its session, or start one named by its own pid.
static long posix_setpgid(long pid, long pgid) {
  if (pid < 0 || pgid < 0) return -EINVAL;
  if (pid == 0) pid = posix_pid();
  if (pgid == 0) pgid = pid;
  if (!proc_mounted) return pid == posix_pid() && pgid == pid ? 0 : -EPERM;
  char text[24];
  snprintf(text, sizeof text, "%ld", pgid);
  return proc_write(pid, "noteid", text);
}

static long posix_setsid(void) {
  if (!proc_mounted) return -EPERM;
  long r = proc_write(posix_pid(), "ctl", "setsid");
  return r < 0 ? r : posix_pid();
}

// --- wait ---
//
// Each read of /proc/PID/wait is one child's record, as APE's waitpid reads
// them: one for a child it was not asked about is kept here for a later call.
// WNOHANG reads only while the file's length (records queued) says a read will
// not wait.

typedef struct waited {
  long pid, group;
  int status; // as wait4 reports it
  bool stopped, continued;
  vx_duration user, sys; // its CPU time and its waited children's (procfs's user= and sys=, ms)
} waited;

// The CPU time of the children waited for, as 9front's TCUser and TCSys:
// times' cutime and cstime, getrusage's RUSAGE_CHILDREN.
static vx_duration child_user, child_sys;

static waited wait_kept[128]; // as many as procfs keeps for one parent
static uint32_t wait_kept_count;

// A wait record (procfs's ndb) as wait4 reports it.
static bool wait_parse(const char *text, size_t len, waited *w) {
  char scratch[VX_ERRMAX + 64];
  vx_ndb_reader r = {.src = {text, len}, .scratch = scratch, .scratch_cap = sizeof scratch};
  vx_ndb_record rec;
  uint64_t pid = 0, group = 0, sig = 0;
  if (vx_ndb_next(&r, &rec) != VX_NDB_RECORD || !vx_ndb_get_u64(&rec, "pid", &pid) || !pid) return false;
  vx_ndb_get_u64(&rec, "noteid", &group);
  *w = (waited){.pid = (long)pid, .group = (long)group};
  uint64_t ms = 0;
  if (vx_ndb_get_u64(&rec, "user", &ms)) w->user = (vx_duration)ms * 1'000'000;
  if (vx_ndb_get_u64(&rec, "sys", &ms)) w->sys = (vx_duration)ms * 1'000'000;
  if (vx_ndb_get_u64(&rec, "stopped", &sig)) {
    w->stopped = true;
    w->status = (int)(sig << 8 | 0x7f);
  } else if (vx_ndb_has(&rec, "continued")) {
    w->continued = true;
    w->status = 0xffff;
  } else {
    w->status = (int)posix_wait_status(vx_ndb_get(&rec, "status"));
  }
  return true;
}

// Whether a record answers wait4(pid, options).
static bool wait_matches(const waited *w, long pid, int options) {
  if (w->stopped && !(options & WUNTRACED)) return false;
  if (w->continued && !(options & WCONTINUED)) return false;
  if (pid > 0) return w->pid == pid;
  if (pid == -1) return true;
  return w->group == (pid == 0 ? posix_getpgid(0) : -pid);
}

static bool wait_take_kept(long pid, int options, waited *out) {
  for (uint32_t i = 0; i < wait_kept_count; i++) {
    if (!wait_matches(&wait_kept[i], pid, options)) continue;
    *out = wait_kept[i];
    memmove(&wait_kept[i], &wait_kept[i + 1], (wait_kept_count - i - 1) * sizeof wait_kept[0]);
    wait_kept_count--;
    return true;
  }
  return false;
}

static void wait_keep(const waited *w) {
  if (wait_kept_count == sizeof wait_kept / sizeof wait_kept[0]) // full: the oldest goes
    memmove(&wait_kept[0], &wait_kept[1], --wait_kept_count * sizeof wait_kept[0]);
  wait_kept[wait_kept_count++] = *w;
}

static struct timeval tv_of(vx_duration d) {
  return (struct timeval){d / 1'000'000'000, d % 1'000'000'000 / 1000};
}

// wait4: rusage has the child's CPU times, nothing else.
static long posix_wait4(long pid, int *status, int options, struct rusage *ru) {
  if (ru) *ru = (struct rusage){};
  waited w;
  bool found = wait_take_kept(pid, options, &w);
  // A process that is there and not a child: nothing to wait for (an ended
  // child's entry is gone, its record still queued).
  if (!found && pid > 0 && proc_mounted) {
    long parent = proc_number(pid, "ppid", nullptr);
    if (parent >= 0 && parent != posix_pid()) return -ECHILD;
  }
  while (!found) {
    if (!proc_mounted) return -ECHILD;
    if (options & WNOHANG) { // only what is queued: the file's length
      vx_ns_file f;
      p9_stat st;
      vx_status e = vx_ns_open(fd_namespace(), proc_path(posix_pid(), "wait"), P9_OREAD, &f);
      if (e == VX_OK) {
        e = p9c_stat(f.c, f.fid, &st, nullptr);
        vx_ns_close(&f);
      }
      if (e != VX_OK) return proc_errno(e);
      if (st.length == 0) return 0; // nothing yet, as APE's waitpid answers
    }
    char buf[512] = {}; // the analyzer cannot follow proc_read's result to it
    long n = proc_read_unlocked(posix_pid(), "wait", buf, sizeof buf); // until a child ends: others go on
    if (n == -ESRCH) return -ECHILD;
    if (n < 0) return n; // ECHILD (no living children), EINTR (a signal ended it)
    if (!wait_parse(buf, (size_t)n, &w)) continue;
    found = wait_matches(&w, pid, options);
    if (!found) wait_keep(&w);
  }
  if (status) *status = w.status;
  if (!w.stopped && !w.continued) child_user += w.user, child_sys += w.sys;
  if (ru) ru->ru_utime = tv_of(w.user), ru->ru_stime = tv_of(w.sys);
  return w.pid;
}

// --- CPU time (ADR-0041) ---
//
// The kernel samples each thread's user and system time every 10 ms tick of a
// CPU running it (thread_state's GET_TIMES); with thread 0, the task's.

static vx_cpu_times cpu_times(bool thread) {
  vx_cpu_times t = {};
  uint32_t slot = be_me()->slot, id = 0; // the kernel's number for this thread: its slot's
  if (thread) id = slot ? atomic_load(&be_threads[slot - 1].id) : be_only_thread_id();
  vx_thread_state(vx_self, id, VX_STATE_GET_TIMES, &t, sizeof t);
  return t;
}

// times: in clock ticks, sysconf(_SC_CLK_TCK)'s 100 a second, and the
// monotonic clock in them, as Linux's.
static long posix_times(struct tms *out) {
  constexpr vx_duration tick = 1'000'000'000 / 100;
  vx_cpu_times me = cpu_times(false);
  if (out)
    *out = (struct tms){.tms_utime = (clock_t)(me.user / tick),
                        .tms_stime = (clock_t)(me.sys / tick),
                        .tms_cutime = (clock_t)(child_user / tick),
                        .tms_cstime = (clock_t)(child_sys / tick)};
  return (long)(vx_clock_read() / tick);
}

static long posix_getrusage(int who, struct rusage *ru) {
  vx_cpu_times t = {};
  if (who == RUSAGE_SELF || who == RUSAGE_THREAD)
    t = cpu_times(who == RUSAGE_THREAD);
  else if (who == RUSAGE_CHILDREN)
    t = (vx_cpu_times){child_user, child_sys};
  else
    return -EINVAL;
  *ru = (struct rusage){.ru_utime = tv_of(t.user), .ru_stime = tv_of(t.sys)};
  return 0;
}

// getpriority and setpriority: VectraOS has no nice values (a thread's
// intent, sched_ctx(2), is its priority), so every process's is 0, as the
// raw call's 20 says, and any other is refused (6d9b: honestly, not ignored).
static long posix_getpriority(int which, long who) {
  if (which != PRIO_PROCESS && which != PRIO_PGRP && which != PRIO_USER) return -EINVAL;
  (void)who;
  return 20; // 20 - nice
}

static long posix_setpriority(int which, long who, int prio) {
  if (which != PRIO_PROCESS && which != PRIO_PGRP && which != PRIO_USER) return -EINVAL;
  (void)who;
  return prio == 0 ? 0 : -EPERM;
}

// --- posix_spawn and execve ---
//
// The parent builds the child (vx-rt's spawn.c) from the program's file: it
// gives it the namespace, the console, its arguments and environment, its
// descriptors (fd.c's fd= records) and working directory (vx-ns's cwd=, ADR-0039), and
// registers it with procfs before it runs (posix_spawn), in the group or
// session posix_spawn's attributes ask for; execve goes on in this task
// (ADR-0012). musl's posix_spawn, whose child is a clone that calls execve,
// is left out of the build.

typedef struct spawn_ctx {
  int64_t pgid; // -1 to inherit
  bool setsid, exec;
  int64_t pid;
  long error;
  // The signals the child keeps: what is ignored stays ignored (but those in
  // sig_default), and the mask is this one's (or blocked, if has_mask), as
  // POSIX has it for exec and posix_spawn.
  uint64_t sig_default, blocked;
  bool has_mask;
} spawn_ctx;

static void sig_records(vx_ndb_writer *w, const spawn_ctx *ctx); // signal.c
static void fd_quiet_reads(void);                                // poll.c
static bool sig_deliver_pending(void);                           // signal.c
static void sig_forget_pending(uint64_t which);                  // signal.c
static volatile int sig_depth;                                   // signal.c
static _Atomic uint64_t sig_pending;                             // signal.c

// NOLINTNEXTLINE(readability-non-const-parameter): vx_spawn_args' prepare
static vx_status spawn_prepare(void *ctx, vx_handle task, vx_handle *handle, vx_str *name) {
  (void)handle, (void)name;
  spawn_ctx *s = ctx;
  vx_task_summary info;
  if (s->exec)
    s->pid = posix_pid(); // the same task, so the same process (ADR-0012)
  else
    s->pid = vx_task_info(task, &info) == VX_OK ? (int64_t)info.id : 0;
  return VX_OK;
}

// path, or for posix_spawnp a name with no '/', searched for in PATH.
static long spawn_open(const char *path, bool search) {
  if (!search || strchr(path, '/')) return fd_openat(AT_FDCWD, path, O_RDONLY, 0);
  const char *dirs = getenv("PATH");
  if (!dirs) dirs = "/usr/local/bin:/bin:/usr/bin";
  long fd = -ENOENT;
  size_t len = strlen(path);
  while (fd < 0 && *dirs) {
    size_t n = strcspn(dirs, ":");
    char full[VX_NS_MAX_PATH];
    if (n + 1 + len < sizeof full) {
      memcpy(full, dirs, n);
      full[n] = '/';
      memcpy(full + n + 1, path, len + 1);
      fd = fd_openat(AT_FDCWD, full, O_RDONLY, 0);
    }
    dirs += n + (dirs[n] == ':');
  }
  return fd;
}

static long spawn_records(vx_ndb_writer *w, char *const argv[], char *const envp[], const fd_slot *table,
                          const spawn_ctx *ctx, vx_handle *handles, vx_str *names, uint32_t *count) {
  size_t args = 0, envs = 0;
  while (argv && argv[args]) args++;
  while (envp && envp[envs]) envs++;
  if (args > VX_SPAWN_MAX_ARGS || envs > VX_SPAWN_MAX_ARGS) return -E2BIG; // the child would refuse them
  if (argv && argv[0]) {
    vx_ndb_put(w, "argv0", (vx_str){argv[0], strlen(argv[0])});
    vx_ndb_end(w);
    for (int i = 1; argv[i]; i++) {
      vx_ndb_put(w, "arg", (vx_str){argv[i], strlen(argv[i])});
      vx_ndb_end(w);
    }
  }
  for (int i = 0; envp && envp[i]; i++) {
    vx_ndb_put(w, "env", (vx_str){envp[i], strlen(envp[i])});
    vx_ndb_end(w);
  }
  sig_records(w, ctx);
  if (proc_entropy.seeded) { // a seed of its own, from this process's generator
    uint8_t seed[32];
    vx_drbg_read(&proc_entropy, seed, sizeof seed);
    vx_ndb_put(w, "entropy", (vx_str){(const char *)seed, sizeof seed});
    vx_ndb_end(w);
  }
  // Handles: the descriptors' pipes and the namespace's connections, leaving
  // room for the console, "posix" and "self".
  uint32_t cap = VX_CHANNEL_MAX_HANDLES - 3;
  fd_records(table, w, handles, names, count, cap);
  if (w->failed) return -E2BIG;
  vx_status st = vx_ns_spawn_records(fd_namespace(), w, handles, names, count, cap);
  if (st != VX_OK) return vx_errno(st);
  if (vx_console.connector && vx_handle_dup(vx_console.connector, VX_RIGHTS_SAME, &handles[*count]) == VX_OK)
    names[(*count)++] = VX_STR("console");
  return w->failed ? -E2BIG : 0;
}

// A file of the namespace mapped whole and read-only: a program's image or
// its interpreter. Returns its address, or a negated errno; *size its size.
static long spawn_map(long fd, size_t *size) {
  if (fd < 0) return fd;
  struct stat st = {};
  long r = fd_fstat((int)fd, &st);
  long image = -ENOEXEC;
  if (r == 0 && S_ISREG(st.st_mode) && st.st_size > 0)
    image = mem_map(0, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, (int)fd, 0);
  fd_close((int)fd);
  if (image < 0) return S_ISDIR(st.st_mode) ? -EACCES : image;
  *size = (size_t)st.st_size;
  return image;
}

// Builds and starts the program at path, with the descriptors in table.
// Returns 0 or a negated errno.
static long spawn_image(const char *path, bool search, char *const argv[], char *const envp[],
                        const fd_slot *table, spawn_ctx *ctx) {
  fd_quiet_reads(); // the child's terminal input is the child's
  size_t size = 0, interp_size = 0;
  long image = spawn_map(spawn_open(path, search), &size);
  if (image < 0) return image;
  // A dynamic program's interpreter (PT_INTERP: libc.so, 6f1b2, or ld-vx),
  // from this process's namespace, as a spawn's caller gives it.
  vx_str ip;
  long interp = 0;
  if (vx_elf_interp((const uint8_t *)image, size, &ip)) {
    char name[256];
    if (ip.len >= sizeof name) {
      interp = -ENOEXEC;
    } else {
      memcpy(name, ip.ptr, ip.len), name[ip.len] = 0;
      interp = spawn_map(fd_openat(AT_FDCWD, name, O_RDONLY, 0), &interp_size);
    }
    if (interp < 0) {
      mem_unmap(image, size);
      return interp; // ENOENT for a missing one, as Linux says
    }
  }

  static char records[32 * 1024];
  vx_ndb_writer w = {.buf = records, .cap = sizeof records};
  vx_handle handles[VX_CHANNEL_MAX_HANDLES];
  vx_str names[VX_CHANNEL_MAX_HANDLES];
  uint32_t count = 0;
  long r = spawn_records(&w, argv, envp, table, ctx, handles, names, &count);
  vx_str base = {path, strlen(path)}; // the task's name: the file's, without its directory
  const char *slash = strrchr(path, '/');
  if (slash) base = (vx_str){slash + 1, strlen(slash + 1)};
  base.len = vx_utf_cut(base.ptr, base.len, 23); // whole runes (ADR-0013)
  vx_handle task = VX_HANDLE_NONE;
  uint32_t proc_flags = 0;
  if (ctx->setsid)
    proc_flags = PROC_SETSID;
  else if (ctx->pgid == 0)
    proc_flags = PROC_NOTEG; // a group of its own
  if (r == 0) {
    vx_spawn_args a = {.name = base,
                       .path = {path, strlen(path)},
                       .image = (const uint8_t *)image,
                       .image_size = size,
                       .interp = interp ? (const uint8_t *)interp : nullptr,
                       .interp_size = interp_size,
                       .handles = handles,
                       .handle_names = names,
                       .handle_count = count,
                       .records = {records, w.len},
                       .prepare = spawn_prepare,
                       .ctx = ctx,
                       .exec = ctx->exec,
                       // Registered before it runs (ADR-0011), in the group or
                       // session posix_spawn's attributes ask for.
                       .proc = vx_ns_connector(fd_namespace(), VX_STR("/proc")),
                       .proc_flags = proc_flags,
                       .proc_group = ctx->pgid > 0 ? (uint64_t)ctx->pgid : 0};
    vx_status vst = vx_spawn_elf(&a, &task);
    if (vst == VX_ERR_INVALID)
      r = -ENOEXEC; // not an image for this machine
    else if (vst == VX_ERR_ACCESS)
      r = -EPERM; // procfs refused the group
    else if (vst != VX_OK)
      r = vx_errno(vst);
  } else {
    for (uint32_t i = 0; i < count; i++) vx_handle_close(handles[i]);
  }
  mem_unmap(image, size);
  if (interp) mem_unmap(interp, interp_size);
  if (task) vx_handle_close(task); // procfs has its own, and tells of its end
  return r;
}

// The child's table: this one, with the file actions applied in order. A
// chdir among them changes this process's working directory until the
// child is built (*restore says to what).
static long spawn_actions(const posix_spawn_file_actions_t *fa, fd_slot *vt, char *restore,
                          size_t *restore_len) {
  for (int i = 0; i < FD_MAX; i++)
    if ((vt[i] = fd_table[i]).o) vt[i].o->refs++;
  *restore_len = vx_getwd(restore, VX_WD_MAX);
  if (!fa || !fa->__actions) return 0;
  const struct fdop *op = fa->__actions; // newest first: applied from the oldest
  while (op->next) op = op->next;
  for (; op; op = op->prev) {
    long r = 0;
    if ((op->cmd == FDOP_CLOSE || op->cmd == FDOP_DUP2 || op->cmd == FDOP_OPEN) &&
        (op->fd < 0 || op->fd >= FD_MAX))
      return -EBADF;
    switch (op->cmd) {
    case FDOP_CLOSE:
      if (vt[op->fd].o) ofd_release(vt[op->fd].o);
      vt[op->fd].o = nullptr;
      break;
    case FDOP_DUP2:
      if (op->srcfd < 0 || op->srcfd >= FD_MAX || !vt[op->srcfd].o) return -EBADF;
      if (op->srcfd != op->fd) {
        vt[op->srcfd].o->refs++;
        if (vt[op->fd].o) ofd_release(vt[op->fd].o);
        vt[op->fd].o = vt[op->srcfd].o;
      }
      vt[op->fd].cloexec = false;
      break;
    case FDOP_OPEN: {
      long fd = fd_openat(AT_FDCWD, op->path, op->oflag, op->mode);
      if (fd < 0) return fd;
      if (vt[op->fd].o) ofd_release(vt[op->fd].o);
      vt[op->fd] = (fd_slot){fd_table[fd].o, false}; // moved from this table to the child's
      fd_table[fd].o = nullptr;
      break;
    }
    case FDOP_CHDIR: r = fd_chdir(op->path); break;
    case FDOP_FCHDIR: {
      const ofd *d = op->fd >= 0 && op->fd < FD_MAX ? vt[op->fd].o : nullptr;
      if (!d) return -EBADF;
      if (d->kind != OFD_FILE || !d->dir) return -ENOTDIR;
      if (!vx_wd_set((vx_str){d->path, d->path_len})) return -ENAMETOOLONG;
      break;
    }
    default: r = -EINVAL; break;
    }
    if (r < 0) return r;
  }
  return 0;
}

int posix_spawn(pid_t *restrict pid, const char *restrict path, const posix_spawn_file_actions_t *fa,
                const posix_spawnattr_t *restrict attr, char *const argv[restrict],
                char *const envp[restrict]) {
  int flags = attr ? attr->__flags : 0;
  spawn_ctx ctx = {.pgid = -1, .setsid = flags & POSIX_SPAWN_SETSID};
  if (flags & POSIX_SPAWN_SETPGROUP) ctx.pgid = attr->__pgrp;
  if (flags & POSIX_SPAWN_SETSIGDEF) memcpy(&ctx.sig_default, &attr->__def, sizeof ctx.sig_default);
  if (flags & POSIX_SPAWN_SETSIGMASK)
    memcpy(&ctx.blocked, &attr->__mask, sizeof ctx.blocked), ctx.has_mask = true;
  // Not through __vx_syscall: a signal now would run its handler in the middle
  // of the back end's work. It waits, as in a call, until the child is made.
  sig_depth = sig_depth + 1;
  static fd_slot vt[FD_MAX];
  char cwd[VX_WD_MAX];
  size_t cwd_len;
  long r = spawn_actions(fa, vt, cwd, &cwd_len);
  if (r == 0) r = spawn_image(path, attr && attr->__fn, argv, envp, vt, &ctx); // posix_spawnp sets __fn
  for (int i = 0; i < FD_MAX; i++)
    if (vt[i].o) ofd_release(vt[i].o);
  vx_wd_set((vx_str){cwd, cwd_len}); // as it was before the file actions
  sig_depth = sig_depth - 1;
  if (sig_depth == 0) sig_deliver_pending();
  if (r < 0) return (int)-r;
  if (pid) *pid = (pid_t)ctx.pid;
  return 0;
}

// execve: the program goes on in this task, so as this process, with its
// pid, parent and children (task_exec, ADR-0012), and with this one's
// descriptors but those marked FD_CLOEXEC. Only a failure returns.
static long proc_execve(const char *path, char *const argv[], char *const envp[]) {
  if (vx_console.len) vx_console_flush(); // what this program printed goes out before it is gone
  spawn_ctx ctx = {.pgid = -1, .exec = true};
  return spawn_image(path, false, argv, envp, fd_table, &ctx);
}

// --- fork ---
//
// The kernel copies this task's memory and handles (task_create's FORK); the
// child's one thread starts on a small stack of its own at fork_entry, which
// sets its thread pointer and jumps back into the copy of proc_fork's frame
// that setjmp marked. There it lets go of what the copy cannot share (the
// namespace's and the console's dead connections; fd.c) and returns 0. The
// parent registers the child with procfs before it runs (ADR-0011).

static jmp_buf fork_jump;
static uint64_t fork_tls, fork_rights; // its thread pointer, and its protection-key rights (ADR-0035: kept)
static uint64_t
    fork_pending; // the parent's pending signals as its memory was copied: the child has none of them (POSIX)
alignas(16) static uint8_t fork_stack[4096];

[[noreturn]] static void fork_entry(vx_handle unused, uint64_t unused2) {
  (void)unused, (void)unused2;
#ifdef __x86_64__
  vx_thread_state(vx_self, 0, VX_STATE_SET_TLS, &fork_tls, sizeof fork_tls);
#else
  __asm__ volatile("msr tpidr_el0, %0" : : "r"(fork_tls));
#endif
  vx_rights_set(fork_rights); // the child's first thread starts with key 0 alone
  longjmp(fork_jump, 1);
}

static long fork_child(void) {
  vx_task_summary me;
  if (vx_task_info(vx_self, &me) == VX_OK) proc_kernel_task_id = me.id;
  // The generator was copied: the child's goes its own way from the parent's.
  static const char child_tag[] = "fork child";
  vx_drbg_mix(&proc_entropy, child_tag, sizeof child_tag, false);
  vx_drbg_mix(&proc_entropy, &proc_kernel_task_id, sizeof proc_kernel_task_id, false);
  fd_after_fork();
  child_user = child_sys = 0; // a new process has waited for no one
  atomic_store(&be_live, 1);  // the thread that forked, alone, numbered anew: slot 0, its record kept
  be_thread self = *be_me();  // its holds of the lock among them
  memset(be_threads, 0, sizeof be_threads);
  be_state[0] = self;
  atomic_store(&be_threads[0].tp, be_tp());
  be_me()->robust = 0;  // the child's thread is a new one, with no list (musl registers again)
  be_me()->pending = 0; // and none of the thread's signals pending
  be_slot_set(0, be_only_thread_id(), be_me());
  if (be_me()->alt_size) { // its alternate stack, copied with its memory
    vx_note_stack ns = {be_me()->alt_base, be_me()->alt_size};
    vx_thread_state(vx_self, 0, VX_STATE_SET_NOTE_STACK, &ns, sizeof ns);
  }
  wait_kept_count = 0;              // the parent's children's records are the parent's
  sig_forget_pending(fork_pending); // the parent's, copied with its memory; not those sent to the child since
  if (proc_mounted) proc_write(posix_pid(), "ctl", "childnotes");
  return 0;
}

static long proc_fork(void) {
  if (vx_console.len) vx_console_flush(); // not twice, once from each
#ifdef __x86_64__
  vx_thread_state(vx_self, 0, VX_STATE_GET_TLS, &fork_tls, sizeof fork_tls);
#else
  __asm__ volatile("mrs %0, tpidr_el0" : "=r"(fork_tls));
#endif
  fork_rights = vx_rights_get();
  if (setjmp(fork_jump)) return fork_child();
  vx_task_summary me;
  vx_handle child = VX_HANDLE_NONE, thread = VX_HANDLE_NONE;
  spawn_ctx ctx = {.pgid = -1};
  vx_str name = VX_STR("forked");
  if (vx_task_info(vx_self, &me) == VX_OK) name = (vx_str){me.name, strnlen(me.name, sizeof me.name)};
  fd_quiet_reads(); // input that comes next is for whichever reads it, not a read of this one's
  fd_before_fork(); // tokens for the child to join this process's open files with
  fork_pending = sig_pending;
  vx_status st = vx_task_fork(name, &child);
  fd_after_fork_parent();
  vx_str ignored;
  if (st == VX_OK) st = spawn_prepare(&ctx, child, nullptr, &ignored);
  vx_handle proc = vx_ns_connector(fd_namespace(), VX_STR("/proc"));
  if (st == VX_OK && proc) st = vx_proc_register(proc, child, 0, nullptr); // before it runs (ADR-0011)
  if (st == VX_OK) st = vx_thread_create(child, &thread);
  if (st == VX_OK)
    st = vx_thread_start(thread, (uint64_t)fork_entry, (uint64_t)(fork_stack + sizeof fork_stack), 0, 0);
  if (thread) vx_handle_close(thread);
  if (st != VX_OK && child) vx_task_kill(child, VX_STR("fork failed"));
  if (child) vx_handle_close(child);
  if (st != VX_OK) return ctx.error ? ctx.error : -EAGAIN;
  static const char parent_tag[] = "fork parent";
  vx_drbg_mix(&proc_entropy, parent_tag, sizeof parent_tag, false);
  return (long)ctx.pid;
}
