// process.c: the process model, through posixd (lib/vx-posix/posix.h), and
// posix_spawn. Part of backend.c.
//
// A process gets its own channel to posixd as "posix" in its spawn message
// from a POSIX parent, or connects through a connector to /srv/posixd
// ("srv:posixd") given by svcd. Without either it is alone: its pid is the
// kernel's id for its task, and it has no parent, group or children to wait
// for.

static vx_handle posix_chan; // this process's channel to posixd, or none

static long posix_errno(uint32_t error) {
  switch (error) {
  case POSIX_OK: return 0;
  case POSIX_ESRCH: return -ESRCH;
  case POSIX_EPERM: return -EPERM;
  case POSIX_ECHILD: return -ECHILD;
  case POSIX_EAGAIN: return -EAGAIN;
  case POSIX_EINTR: return -EINTR;
  default: return -EINVAL;
  }
}

// One call; *out gets the reply's values, *got a handle it carried. Returns 0
// or a negated errno.
static long posix_call(vx_handle ch, uint32_t call, const int64_t *args, uint32_t count, vx_handle give,
                       posix_msg *out, vx_handle *got) {
  posix_msg req = {.h = {.ordinal = call}};
  for (uint32_t i = 0; i < count; i++) req.arg[i] = args[i];
  *out = (posix_msg){};
  vx_handle reply_handle = VX_HANDLE_NONE;
  vx_call c = {.wr_bytes = &req,
               .wr_len = sizeof req,
               .wr_handles = give ? &give : nullptr,
               .wr_count = give ? 1 : 0,
               .rd_bytes = out,
               .rd_cap = sizeof *out,
               .rd_handles = &reply_handle,
               .rd_count_cap = 1};
  vx_status st = vx_channel_call(ch, &c, VX_INFINITE);
  if (got)
    *got = reply_handle;
  else if (reply_handle)
    vx_handle_close(reply_handle);
  if (st != VX_OK) return vx_errno(st);
  if (c.actual.bytes < sizeof *out) return -EIO;
  return posix_errno(out->h.flags);
}

static void posix_init(void) {
  posix_chan = vx_spawn_take("posix");
  if (posix_chan) return;
  vx_handle connector = vx_spawn_take("srv:posixd");
  vx_handle me = VX_HANDLE_NONE;
  if (!connector || !vx_self || vx_handle_dup(vx_self, VX_RIGHTS_SAME, &me) != VX_OK) return;
  posix_msg rep;
  if (posix_call(connector, POSIX_CONNECT, nullptr, 0, me, &rep, &posix_chan) != 0 && posix_chan) {
    vx_handle_close(posix_chan);
    posix_chan = VX_HANDLE_NONE;
  }
  vx_handle_close(connector);
}

// IDS' field i (pid, ppid, pgid, sid), or the alone answer.
static long posix_id(int i, long alone) {
  posix_msg rep;
  if (!posix_chan || posix_call(posix_chan, POSIX_IDS, nullptr, 0, VX_HANDLE_NONE, &rep, nullptr) != 0)
    return alone;
  return (long)rep.arg[i];
}

static long posix_pid_cache; // never changes, but in a forked child

static long posix_pid(void) {
  if (!posix_pid_cache) posix_pid_cache = posix_id(0, (long)proc_kernel_id());
  return posix_pid_cache;
}

static long posix_simple(uint32_t call, long a0, long a1, long result_alone) {
  if (!posix_chan) return result_alone;
  int64_t args[2] = {a0, a1};
  posix_msg rep;
  long r = posix_call(posix_chan, call, args, 2, VX_HANDLE_NONE, &rep, nullptr);
  return r < 0 ? r : (long)rep.arg[0];
}

static long posix_getpgid(long pid) {
  return posix_simple(POSIX_GETPGID, pid, 0, pid == 0 || pid == posix_pid() ? posix_pid() : -ESRCH);
}
static long posix_getsid(long pid) {
  return posix_simple(POSIX_GETSID, pid, 0, pid == 0 || pid == posix_pid() ? posix_pid() : -ESRCH);
}
static long posix_setpgid(long pid, long pgid) {
  long r = posix_simple(POSIX_SETPGID, pid, pgid, -EPERM);
  return r < 0 ? r : 0;
}
static long posix_setsid(void) { return posix_simple(POSIX_SETSID, 0, 0, -EPERM); }

// wait4: rusage is not kept, and reads as zero.
static long posix_wait4(long pid, int *status, int options, struct rusage *ru) {
  if (ru) *ru = (struct rusage){};
  if (!posix_chan) return -ECHILD;
  int64_t args[2] = {pid, options & (WNOHANG | WUNTRACED | WCONTINUED)}; // Linux's numbers, posixd's
  posix_msg rep;
  long r = posix_call(posix_chan, POSIX_WAIT, args, 2, VX_HANDLE_NONE, &rep, nullptr);
  if (r < 0) return r;
  if (rep.arg[0] && status) *status = (int)rep.arg[1];
  return (long)rep.arg[0];
}

// --- posix_spawn and execve ---
//
// The parent builds the child (vx-rt's spawn.c) from the program's file: it
// gives it the namespace, the console, its arguments and environment, its
// descriptors and working directory (fd.c's fd= and cwd= records), and
// registers it with posixd before it runs: as a child (posix_spawn), or as
// this process going on in a new task (execve). musl's posix_spawn, whose
// child is a clone that calls execve, is left out of the build.
//
// Signal attributes do nothing yet (M4 step 3d).

typedef struct spawn_ctx {
  int64_t pgid; // -1 to inherit
  bool setsid, exec;
  int64_t pid;
  long error;
} spawn_ctx;

static vx_status spawn_prepare(void *ctx, vx_handle task, vx_handle *handle, vx_str *name) {
  spawn_ctx *s = ctx;
  vx_task_summary info;
  if (!posix_chan) { // alone: the child is too, and its pid is the kernel's
    s->pid = vx_task_info(task, &info) == VX_OK ? (int64_t)info.id : 0;
    if (s->exec) s->pid = posix_pid();
    return VX_OK;
  }
  vx_handle dup;
  vx_status st = vx_handle_dup(task, VX_RIGHTS_SAME, &dup);
  if (st != VX_OK) return st;
  int64_t args[2] = {s->pgid, s->setsid};
  posix_msg rep;
  s->error = posix_call(posix_chan, s->exec ? POSIX_EXEC : POSIX_CHILD, args, 2, dup, &rep, handle);
  if (s->error != 0) {
    if (*handle) vx_handle_close(*handle);
    *handle = VX_HANDLE_NONE;
    return VX_ERR_REFUSED;
  }
  s->pid = rep.arg[0];
  *name = VX_STR("posix");
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
                          vx_handle *handles, vx_str *names, uint32_t *count) {
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

// Builds and starts the program at path, with the descriptors in table.
// Returns 0 or a negated errno.
static long spawn_image(const char *path, bool search, char *const argv[], char *const envp[],
                        const fd_slot *table, spawn_ctx *ctx) {
  long fd = spawn_open(path, search);
  if (fd < 0) return fd;
  struct stat st = {};
  long r = fd_fstat((int)fd, &st);
  long image = -ENOEXEC;
  if (r == 0 && S_ISREG(st.st_mode) && st.st_size > 0)
    image = mem_map(0, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, (int)fd, 0);
  fd_close((int)fd);
  if (image < 0) return S_ISDIR(st.st_mode) ? -EACCES : image;

  static char records[32 * 1024];
  vx_ndb_writer w = {.buf = records, .cap = sizeof records};
  vx_handle handles[VX_CHANNEL_MAX_HANDLES];
  vx_str names[VX_CHANNEL_MAX_HANDLES];
  uint32_t count = 0;
  r = spawn_records(&w, argv, envp, table, handles, names, &count);
  vx_str base = {path, strlen(path)}; // the task's name: the file's, without its directory
  const char *slash = strrchr(path, '/');
  if (slash) base = (vx_str){slash + 1, strlen(slash + 1)};
  if (base.len > 23) base.len = 23;
  vx_handle task = VX_HANDLE_NONE;
  if (r == 0) {
    vx_spawn_args a = {.name = base,
                       .image = (const uint8_t *)image,
                       .image_size = (size_t)st.st_size,
                       .handles = handles,
                       .handle_names = names,
                       .handle_count = count,
                       .records = {records, w.len},
                       .prepare = spawn_prepare,
                       .ctx = ctx};
    vx_status vst = vx_spawn_elf(&a, &task);
    if (vst == VX_ERR_INVALID)
      r = -ENOEXEC; // not an image for this machine
    else if (vst != VX_OK)
      r = vx_errno(vst);
    if (ctx->error) r = ctx->error; // posixd's refusal
  } else {
    for (uint32_t i = 0; i < count; i++) vx_handle_close(handles[i]);
  }
  mem_unmap(image, (size_t)st.st_size);
  if (task) vx_handle_close(task); // posixd has its own, and tells of its end
  return r;
}

// The child's table: this one, with the file actions applied in order. A
// chdir among them changes this process's working directory until the
// child is built (*restore says to what).
static long spawn_actions(const posix_spawn_file_actions_t *fa, fd_slot *vt, char *restore,
                          size_t *restore_len) {
  for (int i = 0; i < FD_MAX; i++)
    if ((vt[i] = fd_table[i]).o) vt[i].o->refs++;
  memcpy(restore, fd_cwd, fd_cwd_len + 1);
  *restore_len = fd_cwd_len;
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
      memcpy(fd_cwd, d->path, d->path_len);
      fd_cwd[d->path_len] = 0;
      fd_cwd_len = d->path_len;
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
  static fd_slot vt[FD_MAX];
  char cwd[VX_NS_MAX_PATH];
  size_t cwd_len;
  long r = spawn_actions(fa, vt, cwd, &cwd_len);
  if (r == 0) r = spawn_image(path, attr && attr->__fn, argv, envp, vt, &ctx); // posix_spawnp sets __fn
  for (int i = 0; i < FD_MAX; i++)
    if (vt[i].o) ofd_release(vt[i].o);
  memcpy(fd_cwd, cwd, cwd_len + 1);
  fd_cwd_len = cwd_len;
  if (r < 0) return (int)-r;
  if (pid) *pid = (pid_t)ctx.pid;
  return 0;
}

// execve: the program goes on as this process (posixd keeps its pid, parent
// and children) in a new task, with this one's descriptors but those marked
// FD_CLOEXEC; this task then ends unseen. Only a failure returns.
static long proc_execve(const char *path, char *const argv[], char *const envp[]) {
  spawn_ctx ctx = {.pgid = -1, .exec = true};
  long r = spawn_image(path, false, argv, envp, fd_table, &ctx);
  if (r < 0) return r;
  fd_exit();
  vx_thread_exit(0);
}

// --- fork ---
//
// The kernel copies this task's memory and handles (task_create's FORK); the
// child's one thread starts on a small stack of its own at fork_entry, which
// sets its thread pointer and jumps back into the copy of proc_fork's frame
// that setjmp marked. There it lets go of what the copy cannot share (the
// parent's channel to posixd, the namespace's and the console's dead
// connections; fd.c) and returns 0.

static jmp_buf fork_jump;
static vx_handle fork_posix; // the child's channel to posixd, given at its start
static uint64_t fork_tls;
alignas(16) static uint8_t fork_stack[4096];

[[noreturn]] static void fork_entry(vx_handle posix, uint64_t unused) {
  (void)unused;
  fork_posix = posix;
#ifdef __x86_64__
  vx_thread_state(vx_self, 0, VX_STATE_SET_TLS, &fork_tls, sizeof fork_tls);
#else
  __asm__ volatile("msr tpidr_el0, %0" : : "r"(fork_tls));
#endif
  longjmp(fork_jump, 1);
}

static long fork_child(void) {
  if (posix_chan) vx_handle_close(posix_chan); // the parent's, which this task holds too
  posix_chan = fork_posix;
  posix_pid_cache = 0;
  vx_task_summary me;
  if (vx_task_info(vx_self, &me) == VX_OK) proc_kernel_task_id = me.id;
  // The generator was copied: the child's goes its own way from the parent's.
  static const char child_tag[] = "fork child";
  vx_drbg_mix(&proc_entropy, child_tag, sizeof child_tag, false);
  vx_drbg_mix(&proc_entropy, &proc_kernel_task_id, sizeof proc_kernel_task_id, false);
  fd_after_fork();
  return 0;
}

static long proc_fork(void) {
  if (vx_console.len) vx_console_flush(); // not twice, once from each
#ifdef __x86_64__
  vx_thread_state(vx_self, 0, VX_STATE_GET_TLS, &fork_tls, sizeof fork_tls);
#else
  __asm__ volatile("mrs %0, tpidr_el0" : "=r"(fork_tls));
#endif
  if (setjmp(fork_jump)) return fork_child();
  vx_task_summary me;
  vx_handle child = VX_HANDLE_NONE, thread = VX_HANDLE_NONE, posix = VX_HANDLE_NONE;
  spawn_ctx ctx = {.pgid = -1};
  vx_str name = VX_STR("forked");
  if (vx_task_info(vx_self, &me) == VX_OK) name = (vx_str){me.name, strnlen(me.name, sizeof me.name)};
  fd_before_fork(); // tokens for the child to join this process's open files with
  vx_status st = vx_task_fork(name, &child);
  fd_after_fork_parent();
  vx_str ignored;
  if (st == VX_OK) st = spawn_prepare(&ctx, child, &posix, &ignored);
  if (st == VX_OK) st = vx_thread_create(child, &thread);
  if (st == VX_OK)
    st = vx_thread_start(thread, (uint64_t)fork_entry, (uint64_t)(fork_stack + sizeof fork_stack), posix, 0);
  if (st == VX_OK) posix = VX_HANDLE_NONE; // the child's now
  if (posix) vx_handle_close(posix);
  if (thread) vx_handle_close(thread);
  if (st != VX_OK && child) vx_task_kill(child, -1);
  if (child) vx_handle_close(child);
  if (st != VX_OK) return ctx.error ? ctx.error : -EAGAIN;
  static const char parent_tag[] = "fork parent";
  vx_drbg_mix(&proc_entropy, parent_tag, sizeof parent_tag, false);
  return (long)ctx.pid;
}
