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

static long posix_pid(void) {
  static long pid; // never changes
  if (!pid) pid = posix_id(0, (long)proc_kernel_id());
  return pid;
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
  int64_t args[2] = {pid, options & WNOHANG ? POSIX_WNOHANG : 0};
  posix_msg rep;
  long r = posix_call(posix_chan, POSIX_WAIT, args, 2, VX_HANDLE_NONE, &rep, nullptr);
  if (r < 0) return r;
  if (rep.arg[0] && status) *status = (int)rep.arg[1];
  return (long)rep.arg[0];
}

// --- posix_spawn ---
//
// It replaces musl's, whose child is a clone sharing the parent's memory that
// then calls execve: here the parent builds the child (vx-rt's spawn.c) from
// the program's file, gives it the namespace, the console, an environment and
// its arguments, and registers it with posixd before it runs.
//
// The child's descriptors are the console's until descriptors can be passed
// (M4 step 3c): file actions are refused. Signal attributes do nothing yet
// (step 3d).

typedef struct spawn_ctx {
  int64_t pgid; // -1 to inherit
  bool setsid;
  int64_t pid;
  long error;
} spawn_ctx;

static vx_status spawn_prepare(void *ctx, vx_handle task, vx_handle *handle, vx_str *name) {
  spawn_ctx *s = ctx;
  vx_task_summary info;
  if (!posix_chan) { // alone: the child is too, and its pid is the kernel's
    s->pid = vx_task_info(task, &info) == VX_OK ? (int64_t)info.id : 0;
    return VX_OK;
  }
  vx_handle dup;
  vx_status st = vx_handle_dup(task, VX_RIGHTS_SAME, &dup);
  if (st != VX_OK) return st;
  int64_t args[2] = {s->pgid, s->setsid};
  posix_msg rep;
  s->error = posix_call(posix_chan, POSIX_CHILD, args, 2, dup, &rep, handle);
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

static long spawn_records(vx_ndb_writer *w, char *const argv[], char *const envp[], vx_handle *handles,
                          vx_str *names, uint32_t *count) {
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
  if (w->failed) return -E2BIG;
  // The child's namespace is this one; one handle is left for "posix".
  vx_status st = vx_ns_spawn_records(fd_namespace(), w, handles, names, count, VX_CHANNEL_MAX_HANDLES - 4);
  if (st != VX_OK) return vx_errno(st);
  if (vx_console.connector && vx_handle_dup(vx_console.connector, VX_RIGHTS_SAME, &handles[*count]) == VX_OK)
    names[(*count)++] = VX_STR("console");
  return w->failed ? -E2BIG : 0;
}

int posix_spawn(pid_t *restrict pid, const char *restrict path, const posix_spawn_file_actions_t *fa,
                const posix_spawnattr_t *restrict attr, char *const argv[restrict],
                char *const envp[restrict]) {
  if (fa && fa->__actions) return ENOTSUP; // M4 step 3c
  int flags = attr ? attr->__flags : 0;
  spawn_ctx ctx = {.pgid = -1, .setsid = flags & POSIX_SPAWN_SETSID};
  if (flags & POSIX_SPAWN_SETPGROUP) ctx.pgid = attr->__pgrp;

  long fd = spawn_open(path, attr && attr->__fn); // posix_spawnp sets __fn
  if (fd < 0) return (int)-fd;
  struct stat st;
  long r = fd_fstat((int)fd, &st);
  long image = r == 0 && st.st_size > 0 ? mem_map(0, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, (int)fd, 0)
                                        : -ENOEXEC;
  fd_close((int)fd);
  if (image < 0) return (int)-image;

  static char records[32 * 1024];
  vx_ndb_writer w = {.buf = records, .cap = sizeof records};
  vx_handle handles[VX_CHANNEL_MAX_HANDLES];
  vx_str names[VX_CHANNEL_MAX_HANDLES];
  uint32_t count = 0;
  r = spawn_records(&w, argv, envp, handles, names, &count);
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
                       .ctx = &ctx};
    vx_status vst = vx_spawn_elf(&a, &task);
    if (vst == VX_ERR_INVALID)
      r = -ENOEXEC; // not an image for this machine
    else if (vst != VX_OK)
      r = vx_errno(vst);
    if (ctx.error) r = ctx.error; // posixd's refusal
  } else {
    for (uint32_t i = 0; i < count; i++) vx_handle_close(handles[i]);
  }
  mem_unmap(image, (size_t)st.st_size);
  if (r < 0) return (int)-r;
  vx_handle_close(task); // posixd has its own, and tells of its end
  if (pid) *pid = (pid_t)ctx.pid;
  return 0;
}
