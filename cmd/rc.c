// rc: the shell, Plan 9's rc (docs/04 §5; M2, its language since M4 step 7,
// named gsh until M6 step 6a4, made 9front's in step 6a6). Its language is
// lib/vx-rc's; this is the host it runs on, and its start.
//
//   rc [-srdiIlxebpvV] [-c command] [-m initial] [file [arg ...]]
//
// As 9front's rc, it reads its flags, sets $pid, $rcname and $cflag, and runs
// `. -bq /rc/lib/rcmain $*` (-m names another rcmain), which sets $home,
// $prompt and $path and then runs the command, the file, or standard input,
// interactively with -i, or when there is no file and standard input is the
// console (never with -I). It exits with $status's first word.
//
// A command is a program found through $path in the shell's namespace (a name
// that starts / ./ ../ or # as written). It is loaded by the shell and spawned
// with a copy of the namespace, the console, and its standard input, output
// and error: the shell's own, a pipe, or a channel the shell copies to or from
// a file, a here document or `{...}'s capture. The shell waits for a
// pipeline's commands, unless it ends with &, and $status is each one's wait
// message (name pid: exit string) joined as rc's concstatus (ADR-0010).
// Without fork, a pipeline's stages and & must be programs (lib/vx-rc/rc.h);
// descriptors past 2 are not given to programs yet.

#include "../lib/vx-rt/rt.c"
#include "../lib/vx-rt/spawn.c"
#include "../lib/vx-ns/spawn.c"
#include "../lib/vx-rc/rc.c"

static constexpr uint32_t MAX_STAGES = 16, MAX_FILES = 16, MAX_BACKGROUND = 16;
// Each stage's output and error, and the pipeline's input and output.
static constexpr uint32_t MAX_RELAYS = 2 * MAX_STAGES + 2;
// Port keys: a stage's exit is its number; a relay's readable and peer-closed
// packets are its number past these, in ranges of their own.
static constexpr uint64_t KEY_READABLE = MAX_STAGES, KEY_CLOSED = KEY_READABLE + MAX_RELAYS;

static vx_ns ns;
static rc *sh;

static void write_out(void *ctx, const rc_fd *fd, uint32_t which, const char *s, size_t n);

// Where the shell's own messages go: a builtin's descriptor 2 while one runs
// (its >[2] and >[2=1] followed), else the shell's standard error.
static const rc_fd *errors_to;

static void err(vx_str s) {
  if (errors_to)
    write_out(nullptr, errors_to, 2, s.ptr, s.len);
  else
    vx_eprint(s);
}

static void say(const char *a, vx_str b, const char *c) {
  err(vx_cstr(a));
  err(b);
  err(vx_cstr(c));
}

static vx_str word_str(const rc_word *w) { return (vx_str){w->s, w->len}; }

static bool word_is(const rc_word *w, const char *s) {
  vx_str t = vx_cstr(s);
  return w->len == t.len && memcmp(w->s, t.ptr, t.len) == 0;
}

// $status: cut, at a rune boundary, to what an exit string holds (ADR-0013).
static void set_status(vx_str s) {
  if (!s.len) return rc_set_status(sh, "", 0); // success
  rc_set_status(sh, s.ptr, vx_utf_cut(s.ptr, s.len, VX_ERRMAX));
}

// --- Builtins: the namespace's ---

static uint8_t bind_flags(vx_str f) {
  uint8_t flags = 0;
  for (size_t i = 1; i < f.len; i++) {
    if (f.ptr[i] == 'a')
      flags |= VX_NS_AFTER;
    else if (f.ptr[i] == 'b')
      flags |= VX_NS_BEFORE;
    else if (f.ptr[i] == 'c')
      flags |= VX_NS_CREATE;
    else
      return 0xff;
  }
  return flags;
}

// A builtin's outcome: $status, and on a failure, a message.
static void report(const char *what, vx_status st) {
  if (st == VX_OK) {
    set_status((vx_str){});
    return;
  }
  say("rc: ", vx_cstr(what), ": ");
  err(p9_error_text(st));
  err(VX_STR("\n"));
  set_status(p9_error_text(st));
}

static void usage(const char *text) { // a builtin's, from rc(1)'s usage fence
  err(vx_cstr(text));
  err(VX_STR("\n"));
  set_status(VX_STR("usage"));
}

static bool builtin_run(const rc_word *argv, uint32_t argc);

// rc_host's builtin: true if argv[0] was one, which then ran, its messages
// to its own descriptor 2.
static bool exec_builtin(const rc_word *argv, const rc_fd *fds);
static bool wait_builtin(const rc_word *argv, uint32_t argc);

static bool builtin(void *ctx, rc *r, const rc_word *argv, uint32_t argc, const rc_fd *fds) {
  (void)ctx, (void)r;
  if (word_is(argv, "exec")) return exec_builtin(argv, fds);
  if (word_is(argv, "wait")) return wait_builtin(argv, argc);
  errors_to = &fds[2];
  bool was = builtin_run(argv, argc);
  errors_to = nullptr;
  return was;
}

static bool builtin_run(const rc_word *argv, uint32_t argc) {
  const rc_word *w[4] = {argv};
  for (uint32_t i = 1; i < 4 && i < argc; i++) w[i] = w[i - 1]->next;
  int n = (int)argc;
  bool flagged = n > 1 && w[1]->len && w[1]->s[0] == '-';
  uint8_t flags = flagged ? bind_flags(word_str(w[1])) : 0;
  int first = flagged ? 2 : 1;
  if (word_is(argv, "bind")) {
    if (flags == 0xff || n - first != 2)
      usage(VX_USAGE_bind);
    else
      report("bind", vx_ns_bind(&ns, word_str(w[first]), word_str(w[first + 1]), flags));
    return true;
  }
  // mount: a service this namespace has a connection from (/srv/NAME, as ns
  // prints it, so its output replays), or a 9P server over TCP, tcp!HOST!PORT
  // or 9p://HOST:PORT.
  if (word_is(argv, "mount")) {
    if (flags == 0xff || n - first < 2 || n - first > 3) {
      usage(VX_USAGE_mount);
      return true;
    }
    vx_str aname = n - first == 3 ? word_str(w[first + 2]) : (vx_str){};
    vx_str from = word_str(w[first]), old = word_str(w[first + 1]);
    vx_status st;
    if (from.len > 5 && memcmp(from.ptr, "/srv/", 5) == 0) {
      st = vx_ns_mount_srv(&ns, from, aname, old, flags);
    } else {
      p9_client *c;
      vx_str src;
      st = vx_ns_dial(&ns, from, &c, &src);
      if (st == VX_OK) st = vx_ns_mount(&ns, c, VX_HANDLE_NONE, src, aname, old, flags);
    }
    report("mount", st);
    return true;
  }
  if (word_is(argv, "unmount")) {
    if (n == 2)
      report("unmount", vx_ns_unmount(&ns, (vx_str){}, word_str(w[1])));
    else if (n == 3)
      report("unmount", vx_ns_unmount(&ns, word_str(w[1]), word_str(w[2])));
    else
      usage(VX_USAGE_unmount);
    return true;
  }
  return false;
}

// --- Files: redirections', globbing's and `.`'s ---

static vx_ns_file files[MAX_FILES];
static bool file_used[MAX_FILES];

static bool open_file(void *ctx, rc *r, const char *path, size_t len, uint8_t kind, uint32_t *handle) {
  (void)ctx, (void)r;
  uint32_t h = 0;
  while (h < MAX_FILES && file_used[h]) h++;
  if (h == MAX_FILES) {
    set_status(VX_STR("too many files open"));
    return false;
  }
  vx_str p = {path, len};
  vx_status st;
  if (kind == RC_FD_READ) {
    st = vx_ns_open(&ns, p, P9_OREAD, &files[h]);
  } else {
    // > truncates (devices ignore that) and makes the file if need be, as rc
    // does; >> writes at its end; <> reads and writes, and makes nothing.
    uint8_t mode = kind == RC_FD_RDWR ? P9_ORDWR : P9_OWRITE;
    st = vx_ns_open(&ns, p, kind == RC_FD_WRITE ? mode | P9_OTRUNC : mode, &files[h]);
    if (st == VX_ERR_NOT_FOUND && kind != RC_FD_RDWR) st = vx_ns_create(&ns, p, 0644, mode, &files[h]);
    if (st == VX_OK && kind == RC_FD_APPEND) {
      p9_stat s;
      if (p9c_stat(files[h].c, files[h].fid, &s, nullptr) == VX_OK) files[h].offset = s.length;
    }
  }
  if (st != VX_OK) {
    set_status(p9_error_text(st));
    return false;
  }
  file_used[h] = true;
  *handle = h;
  return true;
}

static void close_file(void *ctx, uint32_t handle) {
  (void)ctx;
  if (handle >= MAX_FILES || !file_used[handle]) return;
  vx_ns_close(&files[handle]);
  file_used[handle] = false;
}

static void write_file(uint32_t handle, const char *s, size_t n, bool *broken) {
  for (size_t done = 0; done < n && !*broken && handle < MAX_FILES && file_used[handle];) {
    int64_t w = vx_ns_write(&files[handle], s + done, (uint32_t)(n - done > 8192 ? 8192 : n - done));
    if (w <= 0)
      *broken = true;
    else
      done += (size_t)w;
  }
}

// rc_host's write: the shell's own output (whatis's), where fd goes.
static void write_out(void *ctx, const rc_fd *fd, uint32_t which, const char *s, size_t n) {
  (void)ctx, (void)which;
  bool broken = false;
  if (fd->kind == RC_FD_CAPTURE)
    rc_capture_write(sh, fd, s, n);
  else if (fd->kind == RC_FD_WRITE || fd->kind == RC_FD_APPEND || fd->kind == RC_FD_RDWR)
    write_file(fd->handle, s, n, &broken);
  else if (fd->kind == RC_FD_INHERIT && fd->dup == 2)
    vx_eprint((vx_str){s, n});
  else if (fd->kind == RC_FD_INHERIT)
    vx_print((vx_str){s, n});
}

// rc_host's exists: whether the path names something, for globbing.
static bool exists(void *ctx, const char *path, size_t len) {
  (void)ctx;
  p9_client *c;
  uint32_t fid;
  if (vx_ns_walk(&ns, (vx_str){path, len}, &c, &fid) != VX_OK) return false;
  p9c_clunk(c, fid);
  return true;
}

static bool read_dir(void *ctx, const char *path, size_t len, void (*each)(void *, const char *, size_t),
                     void *arg) {
  (void)ctx;
  vx_ns_file f;
  if (vx_ns_open(&ns, (vx_str){path, len}, P9_OREAD, &f) != VX_OK) return false;
  static uint8_t buf[4096];
  int64_t n;
  while ((n = vx_ns_read(&f, buf, sizeof buf)) > 0) {
    p9_stat entry;
    for (size_t off = 0; p9_dir_next(buf, (size_t)n, &off, &entry);)
      each(arg, entry.name.ptr, entry.name.len);
  }
  vx_ns_close(&f);
  return true;
}

static int64_t read_whole(void *ctx, const char *path, size_t len, char *buf, size_t cap) {
  (void)ctx;
  vx_ns_file f;
  if (vx_ns_open(&ns, (vx_str){path, len}, P9_OREAD, &f) != VX_OK) return -1;
  size_t size = 0;
  int64_t n = 0;
  while (size < cap &&
         (n = vx_ns_read(&f, buf + size, (uint32_t)(cap - size > 8192 ? 8192 : cap - size))) > 0)
    size += (size_t)n;
  char more;
  if (n >= 0 && size == cap && vx_ns_read(&f, &more, 1) > 0) n = -1; // too long: refused, not cut short
  vx_ns_close(&f);
  return n < 0 ? -1 : (int64_t)size;
}

// --- Running programs ---

static uint8_t image[4 << 20];

// The bytes of an ELF image a spawn reads: through the end of its last
// loadable segment (and its program headers), not the symbols and debugging
// sections after them. 0 if it is not ELF; SIZE_MAX if they do not fit in image.
static size_t elf_needs(size_t have) {
  vx_elf_header eh;
  if (have < sizeof eh || memcmp(image,
                                 "\x7f"
                                 "ELF",
                                 4) != 0)
    return 0;
  memcpy(&eh, image, sizeof eh);
  uint64_t end = eh.phoff + (uint64_t)eh.phnum * sizeof(vx_elf_phdr);
  if (eh.phentsize != sizeof(vx_elf_phdr) || end > sizeof image) return SIZE_MAX;
  if (end > have) return (size_t)end; // the headers first
  for (uint16_t i = 0; i < eh.phnum; i++) {
    vx_elf_phdr ph;
    memcpy(&ph, image + eh.phoff + (uint64_t)i * sizeof ph, sizeof ph);
    if (ph.type == VX_PT_LOAD && ph.offset + ph.filesz > end) end = ph.offset + ph.filesz;
  }
  return end > sizeof image ? SIZE_MAX : (size_t)end;
}

// Loads a program through the namespace, found as rc's searchpath finds it:
// a name that starts / ./ ../ or # as written, any other in each of $path's
// directories ("" and . meaning as written). Returns its size (what a spawn
// needs of it), or 0.
static size_t load(vx_str name) {
  bool here = (name.len && (name.ptr[0] == '/' || name.ptr[0] == '#')) ||
              (name.len > 1 && name.ptr[0] == '.' && name.ptr[1] == '/') ||
              (name.len > 2 && name.ptr[0] == '.' && name.ptr[1] == '.' && name.ptr[2] == '/');
  const rc_word *dirs = here ? nullptr : rc_getvar(sh, "path");
  rc_word as_is = {.len = 0};
  if (!dirs) dirs = &as_is;
  for (const rc_word *d = dirs; d; d = d->next) {
    char path[256];
    size_t n = 0;
    if (d->len && !(d->len == 1 && d->s[0] == '.')) {
      if (d->len + 1 > sizeof path) continue;
      memcpy(path, d->s, d->len), n = d->len;
      if (path[n - 1] != '/') path[n++] = '/';
    }
    if (n + name.len > sizeof path) continue;
    memcpy(path + n, name.ptr, name.len);
    vx_ns_file f;
    if (vx_ns_open(&ns, (vx_str){path, n + name.len}, P9_OREAD, &f) != VX_OK) continue;
    size_t size = 0, need = 4096;
    int64_t got = 1;
    while (got > 0 && size < need) { // the headers, then as much as they say
      got = vx_ns_read(&f, image + size, (uint32_t)(need - size > 65536 ? 65536 : need - size));
      if (got > 0) size += (size_t)got;
      size_t want = elf_needs(size);
      if (want == 0 || want == SIZE_MAX) break;
      need = want > need ? want : need;
    }
    vx_ns_close(&f);
    size_t want = elf_needs(size);
    if (want && want != SIZE_MAX && size >= want) return size;
  }
  return 0;
}

// The variables, exported as rc does: NAME=WORDS, the words of a list
// separated by \x01; but not $* or $0 and the like, nor names a POSIX program
// could not read.
static uint32_t exported; // env= records, this spawn's

static void export_var(void *arg, const char *name, const rc_word *val) {
  vx_ndb_writer *rec = arg;
  bool plain = name[0] != 0 && !(name[0] >= '0' && name[0] <= '9');
  for (const char *c = name; *c && plain; c++)
    plain = (*c >= 'a' && *c <= 'z') || (*c >= 'A' && *c <= 'Z') || (*c >= '0' && *c <= '9') || *c == '_';
  if (!plain) return;
  static char env[32 * 1024];
  size_t n = 0, len = rc_strlen(name);
  if (len + 1 > sizeof env) {
    rec->failed = true; // too long to pass: the spawn is refused, not given less
    return;
  }
  memcpy(env, name, len), n = len, env[n++] = '=';
  for (const rc_word *w = val; w; w = w->next) {
    if (n + w->len + 1 > sizeof env) {
      rec->failed = true;
      return;
    }
    memcpy(env + n, w->s, w->len), n += w->len;
    if (w->next) env[n++] = '\x01';
  }
  vx_ndb_put(rec, "env", (vx_str){env, n});
  vx_ndb_end(rec);
  exported++;
}

// Each function, exported as rc does: fn#name, its text `fn name {body}`.
static void export_fn(void *arg, const char *name, const char *src) {
  vx_ndb_writer *rec = arg;
  static char env[32 * 1024];
  size_t n = 0, nl = rc_strlen(name), sl = rc_strlen(src);
  if (2 * nl + sl + 16 > sizeof env) {
    rec->failed = true;
    return;
  }
  for (const char *x = "fn#"; *x; x++) env[n++] = *x;
  for (size_t k = 0; k < nl; k++) env[n++] = name[k];
  for (const char *x = "=fn "; *x; x++) env[n++] = *x;
  for (size_t k = 0; k < nl; k++) env[n++] = name[k];
  env[n++] = ' ';
  for (size_t k = 0; k < sl; k++) env[n++] = src[k];
  vx_ndb_put(rec, "env", (vx_str){env, n});
  vx_ndb_end(rec);
  exported++;
}

// The functions the shell was given (fn#name), defined, as rcmain's loop over
// /env/fn#* does; not with -p.
static void import_fns(void) {
  for (uint32_t i = 0; i < vx_spawn.envc; i++) {
    vx_str e = vx_spawn.envs[i];
    size_t eq = 0;
    while (eq < e.len && e.ptr[eq] != '=') eq++;
    if (eq < 4 || eq == e.len || memcmp(e.ptr, "fn#", 3) != 0) continue;
    rc_word *status = rc_copywords(sh, rc_getvar(sh, "status"));
    rc_run(sh, e.ptr + eq + 1, e.len - eq - 1);
    rc_setvar(sh, "status", 6, status);
  }
}

// The environment the shell was given, as variables (rc's lists, split at \x01).
static void import_env(void) {
  static const char *words[VX_SPAWN_MAX_ARGS];
  static size_t lens[VX_SPAWN_MAX_ARGS];
  static char name[64];
  for (uint32_t i = 0; i < vx_spawn.envc; i++) {
    vx_str e = vx_spawn.envs[i];
    size_t eq = 0;
    while (eq < e.len && e.ptr[eq] != '=') eq++;
    if (eq == e.len || eq == 0 || eq >= sizeof name) continue;
    if (eq > 3 && memcmp(e.ptr, "fn#", 3) == 0) continue; // a function: import_fns's
    memcpy(name, e.ptr, eq);
    name[eq] = 0;
    uint32_t n = 0;
    for (size_t at = eq + 1; at <= e.len && n < VX_SPAWN_MAX_ARGS;) {
      size_t end = at;
      while (end < e.len && e.ptr[end] != '\x01') end++;
      words[n] = e.ptr + at, lens[n++] = end - at;
      at = end + 1;
    }
    rc_set(sh, name, words, lens, n);
  }
}

// Spawns one program with its standard input, output and error (channel ends,
// or VX_HANDLE_NONE for the console), which are given away.
static vx_status spawn(const rc_word *argv, const vx_handle io[3], vx_handle *task, bool exec) {
  static const char *const IO[3] = {"stdin", "stdout", "stderr"};
  vx_handle handles[VX_CHANNEL_MAX_HANDLES - 1];
  vx_str names[VX_CHANNEL_MAX_HANDLES - 1];
  uint32_t count = 0;
  static char records[VX_CHANNEL_MAX_BYTES - 4096]; // room left for spawn's own records
  vx_ndb_writer rec = {.buf = records, .cap = sizeof records};
  size_t size = load(word_str(argv));
  vx_status st = size ? VX_OK : VX_ERR_NOT_FOUND;
  uint32_t args = 0;
  exported = 0;
  for (const rc_word *a = argv->next; st == VX_OK && a; a = a->next, args++) {
    vx_ndb_put(&rec, "arg", word_str(a));
    vx_ndb_end(&rec);
  }
  if (st == VX_OK) rc_each_var(sh, export_var, &rec);
  if (st == VX_OK) rc_each_fn(sh, export_fn, &rec);
  // More than a spawn message holds, or than the child takes: refused whole,
  // never run with a list cut short.
  if (st == VX_OK && (rec.failed || args > VX_SPAWN_MAX_ARGS || exported > VX_SPAWN_MAX_ARGS))
    st = VX_ERR_RANGE;
  if (st == VX_OK) st = vx_ns_spawn_records(&ns, &rec, handles, names, &count, VX_CHANNEL_MAX_HANDLES - 5);
  if (st == VX_OK && vx_console.connector &&
      vx_handle_dup(vx_console.connector, VX_RIGHTS_SAME, &handles[count]) == VX_OK)
    names[count++] = VX_STR("console");
  for (int i = 0; i < 3; i++)
    if (io[i]) handles[count] = io[i], names[count++] = vx_cstr(IO[i]);
  if (st != VX_OK) {
    for (uint32_t i = 0; i < count; i++) vx_handle_close(handles[i]);
    return st;
  }
  vx_str base = word_str(argv); // the task's name: the program's, without its directory
  for (size_t i = base.len; i-- > 0;)
    if (base.ptr[i] == '/') base = (vx_str){base.ptr + i + 1, base.len - i - 1};
  vx_spawn_args a = {.name = {base.ptr, vx_utf_cut(base.ptr, base.len, 23)}, // whole runes (ADR-0013)
                     .image = image,
                     .image_size = size,
                     .handles = handles,
                     .handle_names = names,
                     .handle_count = count,
                     .records = {records, rec.len},
                     // Registered with whatever serves /proc (ADR-0011); the shell
                     // watches each command's end itself, so no wait record.
                     .proc = vx_ns_connector(&ns, VX_STR("/proc")),
                     .proc_flags = PROC_NOWAIT,
                     .exec = exec}; // exec: the program takes this task's place (task_exec, ADR-0012)
  return vx_spawn_elf(&a, task);
}

// A channel the shell copies from (a program's output, into a file or a
// capture) or into (a file, as a program's input).
typedef struct relay {
  vx_handle end; // the shell's end
  rc_fd to;      // a file's, a here document's, or a capture's
  bool feed;     // into the channel, from the file or the here document
  bool armed;
  size_t off; // a here document's: what has been fed
} relay;

static relay relays[MAX_RELAYS];
static uint32_t nrelays;

// A relay for fd: the shell's end kept, the program's in *theirs.
static vx_status relay_for(const rc_fd *fd, bool feed, vx_handle *theirs) {
  if (nrelays == sizeof relays / sizeof relays[0]) return VX_ERR_NO_MEMORY;
  vx_handle ch[2];
  vx_status st = vx_channel_create(0, ch);
  if (st != VX_OK) return st;
  relays[nrelays++] = (relay){.end = ch[1], .to = *fd, .feed = feed};
  *theirs = ch[0];
  return VX_OK;
}

// Copies what is waiting on a relay. False once it is done: the writer gone
// and all it wrote copied, or the file all fed.
static bool relay_run(relay *rl, bool *broken) {
  static alignas(vx_msg_header) uint8_t msg[sizeof(vx_msg_header) + 4096];
  if (rl->feed) {
    for (;;) {
      int64_t n = 0;
      if (rl->to.kind == RC_FD_HERE) { // from the here document's text
        n = (int64_t)(rl->to.path_len - rl->off > 4096 ? 4096 : rl->to.path_len - rl->off);
        if (n) memcpy(msg + sizeof(vx_msg_header), rl->to.path + rl->off, (size_t)n), rl->off += (size_t)n;
      } else if (file_used[rl->to.handle]) {
        n = vx_ns_read(&files[rl->to.handle], msg + sizeof(vx_msg_header), 4096);
      }
      if (n <= 0) return false;
      *(vx_msg_header *)msg = (vx_msg_header){};
      vx_status st =
          vx_channel_write(rl->end, msg, (uint32_t)(sizeof(vx_msg_header) + (size_t)n), nullptr, 0);
      if (st == VX_ERR_SHOULD_WAIT) { // full: the rest later, from where this left off
        if (rl->to.kind == RC_FD_HERE)
          rl->off -= (size_t)n;
        else
          files[rl->to.handle].offset -= (uint64_t)n;
        return true;
      }
      if (st != VX_OK) return false; // the reader has gone
    }
  }
  for (;;) {
    vx_msg_size size;
    vx_status st = vx_channel_read(rl->end, msg, sizeof msg, nullptr, 0, &size);
    if (st == VX_ERR_SHOULD_WAIT) return true;
    if (st != VX_OK) return false;
    const char *s = (const char *)msg + sizeof(vx_msg_header);
    size_t n = size.bytes > sizeof(vx_msg_header) ? size.bytes - sizeof(vx_msg_header) : 0;
    if (rl->to.kind == RC_FD_CAPTURE)
      rc_capture_write(sh, &rl->to, s, n);
    else
      write_file(rl->to.handle, s, n, broken);
  }
}

static vx_handle background[MAX_BACKGROUND];

// Lets go of commands run with & that have ended.
static void reap(void) {
  for (uint32_t i = 0; i < MAX_BACKGROUND; i++) {
    vx_task_summary info;
    if (background[i] && vx_task_info(background[i], &info) == VX_OK && info.state == VX_TASK_EXITED) {
      vx_handle_close(background[i]);
      background[i] = VX_HANDLE_NONE;
    }
  }
}

// Where a command's descriptor i goes, its copies followed.
static const rc_fd *resolve(const rc_command *c, int i) {
  const rc_fd *fd = &c->fds[i];
  for (uint32_t guard = 0; fd->kind == RC_FD_DUP && fd->dup < RC_FDS && guard < RC_FDS; guard++)
    fd = &c->fds[fd->dup];
  return fd;
}

static vx_handle own_fd(uint8_t which) {
  if (which == 0) return vx_stdio.in;
  if (which == 1) return vx_stdio.out;
  return which == 2 ? vx_stdio.err : VX_HANDLE_NONE;
}

// A stage's standard descriptor i: the program's channel end (or none, for
// the console), making relays and joining pipes as need be.
static vx_status stage_io(const rc_fd *fd, int i, vx_handle pipe_in, vx_handle pipe_out, vx_handle *io) {
  *io = VX_HANDLE_NONE;
  vx_handle share = VX_HANDLE_NONE;
  switch (fd->kind) {
  case RC_FD_INHERIT: share = own_fd(fd->dup); break;
  case RC_FD_PIPE_IN: share = pipe_in; break;
  case RC_FD_PIPE_OUT: share = pipe_out; break;
  case RC_FD_HERE: // a here document is read; on an output it is no file, as 9front's read-only one takes no writes
    if (i == 0) return relay_for(fd, true, io);
    [[fallthrough]];
  case RC_FD_CLOSED: { // a channel no one is at the other end of
    vx_handle ch[2];
    vx_status st = vx_channel_create(0, ch);
    if (st == VX_OK) vx_handle_close(ch[1]), *io = ch[0];
    return st;
  }
  default: return relay_for(fd, i == 0, io); // a file, or a capture
  }
  return share ? vx_handle_dup(share, VX_RIGHTS_SAME, io) : VX_OK;
}

// rc_host's run: a pipeline's programs, each spawned with its descriptors;
// then, unless async, the relays served until they and the programs are done.
static bool run(void *ctx, rc *r, const rc_command *stages, uint32_t n, bool async, uint64_t *pid) {
  (void)ctx, (void)r;
  reap();
  if (n > MAX_STAGES) {
    say("rc: too many commands in a pipe", (vx_str){}, "\n");
    set_status(VX_STR("too many commands"));
    return false;
  }
  static char ends[MAX_STAGES][VX_ERRMAX]; // each command's exit string, for $status
  size_t end_len[MAX_STAGES] = {};
  vx_handle tasks[MAX_STAGES] = {}, pipe_in = VX_HANDLE_NONE, port;
  if (vx_port_create(0, &port) != VX_OK) return false;
  nrelays = 0;
  for (uint32_t s = 0; s < n; s++) {
    const rc_command *c = &stages[s];
    vx_handle pipe[2] = {}, io[3] = {};
    vx_status st = VX_OK;
    if (s + 1 < n) st = vx_channel_create(0, pipe);
    const rc_fd *fd[3] = {resolve(c, 0), resolve(c, 1), resolve(c, 2)};
    static const rc_fd nothing = {.kind = RC_FD_CLOSED};
    if (async && fd[0]->kind == RC_FD_INHERIT && fd[0]->dup == 0)
      fd[0] = &nothing; // & reads nothing, as rc's /dev/null
    for (int i = 0; i < 3 && st == VX_OK; i++) {
      bool same_as_1 = i == 2 && fd[2]->kind == fd[1]->kind && fd[2]->kind >= RC_FD_WRITE &&
                       fd[2]->kind != RC_FD_DUP && fd[2]->kind != RC_FD_CLOSED &&
                       fd[2]->handle == fd[1]->handle && fd[2]->dup == fd[1]->dup && io[1];
      if (same_as_1) // >[2=1] into a file or a capture: the 1's channel
        st = vx_handle_dup(io[1], VX_RIGHTS_SAME, &io[2]);
      else
        st = stage_io(fd[i], i, pipe_in, pipe[0], &io[i]);
    }
    if (pipe_in) vx_handle_close(pipe_in);
    if (pipe[0]) vx_handle_close(pipe[0]);
    pipe_in = pipe[1]; // the next stage's
    if (st == VX_OK)
      st = spawn(c->argv, io, &tasks[s], false);
    else
      for (int i = 0; i < 3; i++)
        if (io[i]) vx_handle_close(io[i]);
    if (st != VX_OK) {
      vx_str why = p9_error_text(st); // as rc's: the command's name and why, which is its status
      if (st == VX_ERR_RANGE) why = VX_STR("argument list too long");
      // Where the command's own errors would go, as rc writes them.
      rc_fd err = *fd[2];
      if (err.kind == RC_FD_PIPE_OUT || err.kind == RC_FD_PIPE_IN || err.kind == RC_FD_READ)
        err = (rc_fd){.dup = 2};
      write_out(nullptr, &err, 2, c->argv->s, c->argv->len);
      write_out(nullptr, &err, 2, ": ", 2);
      write_out(nullptr, &err, 2, why.ptr, why.len);
      write_out(nullptr, &err, 2, "\n", 1);
      memcpy(ends[s], why.ptr, why.len);
      end_len[s] = why.len;
      tasks[s] = VX_HANDLE_NONE;
      continue;
    }
    vx_port_bind(port, tasks[s], VX_TRIGGER_EXIT, (uint64_t)s, 0);
  }
  if (pipe_in) vx_handle_close(pipe_in);

  if (async) { // not waited for: its relays are not served (rc.h's gaps), so it gets none
    for (uint32_t i = 0; i < nrelays; i++) vx_handle_close(relays[i].end);
    nrelays = 0;
    for (uint32_t s = 0; s < n; s++) {
      if (!tasks[s]) continue;
      vx_task_summary info;
      if (s + 1 == n && vx_task_info(tasks[s], &info) == VX_OK) *pid = info.id;
      uint32_t slot = 0;
      while (slot < MAX_BACKGROUND && background[slot]) slot++;
      if (slot < MAX_BACKGROUND)
        background[slot] = tasks[s];
      else
        vx_handle_close(tasks[s]);
    }
    vx_handle_close(port);
    return true; // $status as it was, as rc's
  }

  // Wait for every command; meanwhile serve the relays.
  uint32_t running = 0, live = nrelays;
  for (uint32_t s = 0; s < n; s++) running += tasks[s] != VX_HANDLE_NONE;
  bool broken = false;
  for (uint32_t i = 0; i < nrelays; i++)
    if (!relays[i].feed) vx_port_bind(port, relays[i].end, VX_TRIGGER_PEER_CLOSED, KEY_CLOSED + i, 0);
  while (running || live) {
    bool feeding = false;
    for (uint32_t i = 0; i < nrelays; i++) {
      relay *rl = &relays[i];
      if (!rl->end) continue;
      if (rl->feed) { // as much as the channel takes; the rest after a moment
        if (relay_run(rl, &broken)) {
          feeding = true;
        } else {
          vx_handle_close(rl->end);
          rl->end = VX_HANDLE_NONE;
          live--;
        }
      } else if (!rl->armed) {
        rl->armed = vx_port_bind(port, rl->end, VX_TRIGGER_READABLE, KEY_READABLE + i, 0) == VX_OK;
      }
    }
    if (!running && !live) break;
    vx_packet pk[8];
    int64_t got = vx_port_wait(port, feeding ? vx_clock_read() + 1'000'000 : VX_INFINITE, 0, pk, 8);
    for (int64_t k = 0; k < got; k++) {
      uint64_t key = pk[k].key;
      if (pk[k].trigger == VX_TRIGGER_EXIT && key < n) {
        running--;
        vx_task_summary info;
        if (pk[k].value && vx_task_info(tasks[key], &info) == VX_OK && info.exit_len) {
          // As the wait message rc's status comes from: name pid: exit string.
          size_t m = 0, nl = 0;
          while (nl < sizeof info.name && info.name[nl]) nl++;
          char id[24];
          size_t d = sizeof id;
          uint64_t v = info.id;
          do id[--d] = (char)('0' + v % 10);
          while (v /= 10);
          for (size_t q = 0; q < nl && m < VX_ERRMAX; q++) ends[key][m++] = info.name[q];
          if (m < VX_ERRMAX) ends[key][m++] = ' ';
          for (size_t q = d; q < sizeof id && m < VX_ERRMAX; q++) ends[key][m++] = id[q];
          for (const char *q = ": "; *q && m < VX_ERRMAX; q++) ends[key][m++] = *q;
          size_t take = vx_utf_cut(info.exit, info.exit_len, VX_ERRMAX - m);
          memcpy(ends[key] + m, info.exit, take);
          end_len[key] = m + take;
        }
        continue;
      }
      uint64_t i = key >= KEY_CLOSED ? key - KEY_CLOSED : key - KEY_READABLE;
      if (key < KEY_READABLE || i >= nrelays || !relays[i].end) continue;
      relays[i].armed = false;
      bool more = relay_run(&relays[i], &broken);
      if (!more || key >= KEY_CLOSED) { // done, or the writer has gone and all it wrote is copied
        if (more) relay_run(&relays[i], &broken);
        vx_handle_close(relays[i].end);
        relays[i].end = VX_HANDLE_NONE;
        live--;
      }
    }
  }
  if (broken) say("rc: write error", (vx_str){}, "\n");
  char status[MAX_STAGES * (VX_ERRMAX + 1)]; // the commands' statuses, as rc's concstatus joins them
  size_t len = 0;
  for (uint32_t s = 0; s < n; s++) rc_concstatus(status, &len, sizeof status, ends[s], end_len[s]);
  rc_set_status(sh, status, len);
  for (uint32_t s = 0; s < n; s++)
    if (tasks[s]) vx_handle_close(tasks[s]);
  vx_handle_close(port);
  return true;
}

// --- The shell ---

static alignas(16) uint8_t heap[4 << 20];

// The last $status, as rc exits with it: its first word, or nothing when it
// is true (0s and |s), as rc's Exit.
static const char *exit_status(void) {
  static char status[VX_ERRMAX + 1];
  const rc_word *w = rc_getvar(sh, "status");
  bool truth = true;
  for (size_t i = 0; w && i < w->len; i++) truth = truth && (w->s[i] == '0' || w->s[i] == '|');
  size_t len = w && !truth ? vx_utf_cut(w->s, w->len, VX_ERRMAX) : 0; // whole runes (ADR-0013)
  if (len) memcpy(status, w->s, len);
  status[len] = 0;
  return status;
}

// A task's end as rc's $status has it: the wait message, name pid: exit
// string, or nothing for success.
static size_t wait_message(const vx_task_summary *info, char *out, size_t cap) {
  if (!info->exit_len) return 0;
  size_t m = 0, nl = 0;
  while (nl < sizeof info->name && info->name[nl]) nl++;
  char id[24];
  size_t d = sizeof id;
  uint64_t v = info->id;
  do id[--d] = (char)('0' + v % 10);
  while (v /= 10);
  for (size_t q = 0; q < nl && m < cap; q++) out[m++] = info->name[q];
  if (m < cap) out[m++] = ' ';
  for (size_t q = d; q < sizeof id && m < cap; q++) out[m++] = id[q];
  for (const char *q = ": "; *q && m < cap; q++) out[m++] = *q;
  size_t take = vx_utf_cut(info->exit, info->exit_len, cap - m);
  memcpy(out + m, info->exit, take);
  return m + take;
}

// exec cmd ...: the program in this task's place, as rc's execexec. The
// shell relays files, here documents and captures, so a command with one of
// those redirected is refused until the program can be given the file itself.
static bool exec_builtin(const rc_word *argv, const rc_fd *fds) {
  vx_handle io[3] = {};
  vx_status st = VX_OK;
  for (int i = 0; i < 3 && st == VX_OK; i++) {
    const rc_fd *fd = &fds[i];
    for (uint32_t guard = 0; fd->kind == RC_FD_DUP && fd->dup < RC_FDS && guard < RC_FDS; guard++)
      fd = &fds[fd->dup];
    if (fd->kind != RC_FD_INHERIT && fd->kind != RC_FD_CLOSED) {
      say("rc: exec with a file, here document or capture redirected needs the shell to stay (for now)",
          (vx_str){}, "\n");
      set_status(VX_STR("exec redirection"));
      for (int k = 0; k < i; k++)
        if (io[k]) vx_handle_close(io[k]);
      return true;
    }
    st = stage_io(fd, i, VX_HANDLE_NONE, VX_HANDLE_NONE, &io[i]);
  }
  vx_handle task = VX_HANDLE_NONE;
  if (st == VX_OK) st = spawn(argv->next, io, &task, true); // returns only if it failed
  vx_str why = p9_error_text(st);
  say("", word_str(argv->next), ": ");
  say("", why, "\n");
  set_status(why);
  sh->exiting = true; // as rc's: it exits all the same
  return true;
}

// wait [pid]: for a command run with &, or for all of them; $status its wait
// message (rc's execwait).
static bool wait_builtin(const rc_word *argv, uint32_t argc) {
  if (argc > 2) {
    say("rc: Usage: wait [pid]", (vx_str){}, "\n");
    set_status(VX_STR("error"));
    return true;
  }
  uint64_t want = 0;
  if (argc == 2)
    for (size_t i = 0; i < argv->next->len && argv->next->s[i] >= '0' && argv->next->s[i] <= '9'; i++)
      want = want * 10 + (uint64_t)(argv->next->s[i] - '0');
  set_status((vx_str){});
  for (uint32_t i = 0; i < MAX_BACKGROUND; i++) {
    vx_task_summary info;
    if (!background[i] || vx_task_info(background[i], &info) != VX_OK || (want && info.id != want)) continue;
    vx_handle port;
    if (info.state != VX_TASK_EXITED && vx_port_create(0, &port) == VX_OK) {
      vx_packet pk;
      if (vx_port_bind(port, background[i], VX_TRIGGER_EXIT, 0, 0) == VX_OK)
        vx_port_wait(port, VX_INFINITE, 0, &pk, 1);
      vx_handle_close(port);
    }
    if (vx_task_info(background[i], &info) == VX_OK) {
      char msg[VX_ERRMAX + 64];
      set_status((vx_str){msg, wait_message(&info, msg, sizeof msg)});
    }
    vx_handle_close(background[i]);
    background[i] = VX_HANDLE_NONE;
  }
  return true;
}

// Notes, to rc's functions for them (rc's notifyf): what rc has a name for
// (rc_note_trap), sigint and the rest; any other, as the system does by default.
static vx_noted on_note(vx_exception *e, vx_str note, void *fp) {
  (void)fp;
  (void)e;
  uint32_t i = rc_note_trap(note);
  if (!i) return VX_NDFLT;
  rc_trap(sh, i);
  return VX_NCONT;
}

// rc_host's read_line: a line of the shell's standard input ('#d/0').
static int64_t read_line(void *ctx, char *buf, size_t cap) {
  (void)ctx;
  static char pending[4096]; // what a read gave past the line asked for
  static size_t npending;
  size_t n = 0;
  for (;;) {
    while (npending && n < cap) {
      char c = pending[0];
      memmove(pending, pending + 1, --npending);
      buf[n++] = c;
      if (c == '\n') return (int64_t)n;
    }
    if (n == cap) return (int64_t)n;
    int64_t got = vx_read(pending, sizeof pending);
    if (got <= 0) return n ? (int64_t)n : got;
    npending = (size_t)got;
  }
}

// Writes s into buf as an rc word, quoted.
static size_t quoted(char *buf, size_t at, size_t cap, vx_str s) {
  if (at < cap) buf[at++] = '\'';
  for (size_t i = 0; i < s.len && at + 2 < cap; i++) {
    if (s.ptr[i] == '\'') buf[at++] = '\'';
    buf[at++] = s.ptr[i];
  }
  if (at < cap) buf[at++] = '\'';
  return at;
}

const char *vx_main(void) {
  if (vx_ns_from_spawn(&ns) != VX_OK) vx_eprint(VX_STR("rc: the namespace is incomplete\n"));
  rc_host host = {.run = run,
                  .write = write_out,
                  .readdir = read_dir,
                  .builtin = builtin,
                  .read_file = read_whole,
                  .open = open_file,
                  .close = close_file,
                  .exists = exists,
                  .read_line = read_line};
  static const char *const HOST_BUILTINS[] = {"bind", "mount", "unmount", nullptr};
  host.builtin_names = HOST_BUILTINS;
  sh = rc_new(heap, sizeof heap, &host);
  if (!sh) return "no memory";
  import_env();
  vx_notify(on_note);

  // The flags, as rc's getflags("srdiIlxebpvVc:1m:1").
  vx_str cflag = {}, rcmain = VX_STR("/rc/lib/rcmain");
  uint32_t i = 0;
  for (; i < vx_spawn.argc; i++) {
    vx_str a = vx_spawn.args[i];
    if (a.len < 2 || a.ptr[0] != '-') break;
    if (a.len == 2 && a.ptr[1] == '-') {
      i++;
      break;
    }
    for (size_t k = 1; k < a.len; k++) {
      char f = a.ptr[k];
      if (f == 'c' || f == 'm') { // its argument: the rest of the word, or the next
        vx_str v = k + 1 < a.len ? (vx_str){a.ptr + k + 1, a.len - k - 1} : (vx_str){};
        if (!v.len && i + 1 < vx_spawn.argc) v = vx_spawn.args[++i];
        if (!v.len) return vx_eprint(vx_cstr(VX_USAGE)), vx_eprint(VX_STR("\n")), "usage";
        if (f == 'c')
          cflag = v;
        else
          rcmain = v;
        sh->flag[(unsigned char)f] = true;
        break;
      }
      bool known = false;
      for (const char *x = "srdiIlxebpvV"; *x; x++) known = known || *x == f;
      if (!known) return vx_eprint(vx_cstr(VX_USAGE)), vx_eprint(VX_STR("\n")), "usage";
      sh->flag[(unsigned char)f] = true;
    }
  }
  if (sh->flag['I'])
    sh->flag['i'] = false;
  else if (!sh->flag['i'] && i == vx_spawn.argc && !vx_stdio.in) // no file, and the console: interactive
    sh->flag['i'] = true;

  vx_task_summary me;
  char pid[24];
  size_t d = sizeof pid;
  uint64_t id = vx_self && vx_task_info(vx_self, &me) == VX_OK ? me.id : 0;
  do pid[--d] = (char)('0' + id % 10);
  while (id /= 10);
  const char *one[1] = {pid + d};
  size_t len1[1] = {sizeof pid - d};
  rc_set(sh, "pid", one, len1, 1);
  one[0] = "rc", len1[0] = 2;
  rc_set(sh, "rcname", one, len1, 1);
  if (cflag.len) one[0] = cflag.ptr, len1[0] = cflag.len, rc_set(sh, "cflag", one, len1, 1);
  static const char *words[VX_SPAWN_MAX_ARGS];
  static size_t lens[VX_SPAWN_MAX_ARGS];
  uint32_t n = 0;
  for (uint32_t k = i; k < vx_spawn.argc && n < VX_SPAWN_MAX_ARGS; k++, n++)
    words[n] = vx_spawn.args[k].ptr, lens[n] = vx_spawn.args[k].len;
  rc_set(sh, "*", words, lens, n);
  if (!sh->flag['p']) import_fns();

  // rc's bootstrap: . -bq rcmain $*, then exit.
  static char boot[512];
  size_t at = 0;
  for (const char *x = ". -bq "; *x; x++) boot[at++] = *x;
  at = quoted(boot, at, sizeof boot - 8, rcmain);
  for (const char *x = " $*\n"; *x; x++) boot[at++] = *x;
  rc_run(sh, boot, at);
  rc_sigexit(sh); // at the end of the input too, once
  return exit_status();
}
