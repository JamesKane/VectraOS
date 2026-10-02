// gsh: the shell (docs/04 §5, M2; rc's language since M4 step 7). Its
// language is rc's, from lib/vx-rc: lists, quoting, ^, $#x and $x(n), if, if
// not, for, while, switch, ~, fn, !, && and ||, pipes, redirections, `{...},
// globbing, $status, $*:
//
//   ls /; cat /proc/1/status            commands, separated by ; or newlines
//   ns | tail -1                        pipes
//   echo kill > /proc/2/ctl             redirections: > >> < >[2=1] >[2]
//   for(p in `{ls /proc}) echo $p       command substitution
//   bind -a /boot/bin /bin              builtins: bind, mount, unmount, and rc's
//   gsh script.rc a b                   a script, its arguments in $*
//
// A command is a program found as given (a path) or in /bin, then /boot/bin,
// through the shell's namespace. It is loaded by the shell and spawned with a
// copy of the namespace, the console, and its standard input, output and
// error: the shell's own, a pipe, or a channel the shell copies to or from a
// file (or into `{...}'s capture). The shell waits for a pipeline's commands,
// unless it ends with &, and $status is their exit strings, joined by |, as
// rc's (ADR-0010). Without fork, a pipeline's stages and & must be programs
// (lib/vx-rc/rc.h); descriptors past 2 are not given to programs yet.
//
// With no arguments the shell reads commands from its input, prompting; a
// construct left open (a brace, an if's condition) continues on the next line.
// At the end of its input, or of a script, or at exit, it exits with $status.

#include "../lib/vx-rt/rt.c"
#include "../lib/vx-rt/spawn.c"
#include "../lib/vx-ns/spawn.c"
#include "../lib/vx-rc/rc.c"

static constexpr uint32_t MAX_STAGES = 16, MAX_FILES = 16, MAX_BACKGROUND = 16;
// Port keys: a stage's exit is its number; a relay's readable and peer-closed
// packets are its number past these.
static constexpr uint64_t KEY_READABLE = MAX_STAGES, KEY_CLOSED = 2ull * MAX_STAGES;

static vx_ns ns;
static rc *sh;

static void say(const char *a, vx_str b, const char *c) {
  vx_eprint(vx_cstr(a));
  vx_eprint(b);
  vx_eprint(vx_cstr(c));
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
  say("gsh: ", vx_cstr(what), ": ");
  vx_eprint(p9_error_text(st));
  vx_eprint(VX_STR("\n"));
  set_status(p9_error_text(st));
}

static void usage(const char *text) {
  vx_eprint(vx_cstr(text));
  set_status(VX_STR("usage"));
}

// rc_host's builtin: true if argv[0] was one, which then ran.
static bool builtin(void *ctx, rc *r, const rc_word *argv, uint32_t argc, const rc_fd *fds) {
  (void)ctx, (void)r, (void)fds;
  const rc_word *w[4] = {argv};
  for (uint32_t i = 1; i < 4 && i < argc; i++) w[i] = w[i - 1]->next;
  int n = (int)argc;
  bool flagged = n > 1 && w[1]->len && w[1]->s[0] == '-';
  uint8_t flags = flagged ? bind_flags(word_str(w[1])) : 0;
  int first = flagged ? 2 : 1;
  if (word_is(argv, "bind")) {
    if (flags == 0xff || n - first != 2)
      usage("usage: bind [-abc] new old\n");
    else
      report("bind", vx_ns_bind(&ns, word_str(w[first]), word_str(w[first + 1]), flags));
    return true;
  }
  // mount: a service this namespace has a connection from (/srv/NAME, as ns
  // prints it, so its output replays), or a 9P server over TCP, tcp!HOST!PORT
  // or 9p://HOST:PORT.
  if (word_is(argv, "mount")) {
    if (flags == 0xff || n - first < 2 || n - first > 3) {
      usage("usage: mount [-abc] /srv/name|tcp!host!port old [aname]\n");
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
      usage("usage: unmount [new] old\n");
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
    // does; >> writes at its end; <> reads and writes.
    uint8_t mode = kind == RC_FD_RDWR ? P9_ORDWR : P9_OWRITE;
    st = vx_ns_open(&ns, p, kind == RC_FD_WRITE ? mode | P9_OTRUNC : mode, &files[h]);
    if (st == VX_ERR_NOT_FOUND) st = vx_ns_create(&ns, p, 0644, mode, &files[h]);
    if (st == VX_OK && kind == RC_FD_APPEND) {
      p9_stat s;
      if (p9c_stat(files[h].c, files[h].fid, &s) == VX_OK) files[h].offset = s.length;
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
  if (fd->kind == RC_FD_WRITE || fd->kind == RC_FD_APPEND || fd->kind == RC_FD_RDWR)
    write_file(fd->handle, s, n, &broken);
  else if (fd->kind == RC_FD_INHERIT && fd->dup == 2)
    vx_eprint((vx_str){s, n});
  else if (fd->kind == RC_FD_INHERIT)
    vx_print((vx_str){s, n});
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
  vx_ns_close(&f);
  return n < 0 ? -1 : (int64_t)size;
}

// --- Running programs ---

static uint8_t image[1 << 20];

// Loads a program through the namespace: the path as given, or /bin/NAME,
// then /boot/bin/NAME. Returns its size, or 0.
static size_t load(vx_str name) {
  static const char *const DIRS[] = {"", "/bin/", "/boot/bin/"};
  for (size_t d = 0; d < sizeof DIRS / sizeof DIRS[0]; d++) {
    bool has_slash = false;
    for (size_t i = 0; i < name.len; i++) has_slash = has_slash || name.ptr[i] == '/';
    if ((d == 0) != has_slash) continue;
    char path[256];
    vx_str dir = vx_cstr(DIRS[d]);
    if (dir.len + name.len > sizeof path) continue;
    memcpy(path, dir.ptr, dir.len);
    memcpy(path + dir.len, name.ptr, name.len);
    vx_ns_file f;
    if (vx_ns_open(&ns, (vx_str){path, dir.len + name.len}, P9_OREAD, &f) != VX_OK) continue;
    size_t size = 0;
    int64_t n;
    while (size < sizeof image && (n = vx_ns_read(&f, image + size, (uint32_t)(sizeof image - size))) > 0)
      size += (size_t)n;
    vx_ns_close(&f);
    if (size >= 4 && memcmp(image,
                            "\x7f"
                            "ELF",
                            4) == 0)
      return size;
  }
  return 0;
}

// Spawns one program with its standard input, output and error (channel ends,
// or VX_HANDLE_NONE for the console), which are given away.
static vx_status spawn(const rc_word *argv, const vx_handle io[3], vx_handle *task) {
  static const char *const IO[3] = {"stdin", "stdout", "stderr"};
  vx_handle handles[VX_CHANNEL_MAX_HANDLES - 1];
  vx_str names[VX_CHANNEL_MAX_HANDLES - 1];
  uint32_t count = 0;
  static char records[16 * 1024];
  vx_ndb_writer rec = {.buf = records, .cap = sizeof records};
  size_t size = load(word_str(argv));
  vx_status st = size ? VX_OK : VX_ERR_NOT_FOUND;
  for (const rc_word *a = argv->next; st == VX_OK && a; a = a->next) {
    vx_ndb_put(&rec, "arg", word_str(a));
    vx_ndb_end(&rec);
  }
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
                     .proc_flags = PROC_NOWAIT};
  return vx_spawn_elf(&a, task);
}

// A channel the shell copies from (a program's output, into a file or a
// capture) or into (a file, as a program's input).
typedef struct relay {
  vx_handle end; // the shell's end
  rc_fd to;      // a file's, or a capture's
  bool feed;     // into the channel, from the file
  bool armed;
} relay;

static relay relays[2 * MAX_STAGES + 2];
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
      int64_t n =
          file_used[rl->to.handle] ? vx_ns_read(&files[rl->to.handle], msg + sizeof(vx_msg_header), 4096) : 0;
      if (n <= 0) return false;
      *(vx_msg_header *)msg = (vx_msg_header){};
      vx_status st =
          vx_channel_write(rl->end, msg, (uint32_t)(sizeof(vx_msg_header) + (size_t)n), nullptr, 0);
      if (st == VX_ERR_SHOULD_WAIT) { // full: the rest later, from where this left off
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
    say("gsh: too many commands in a pipe", (vx_str){}, "\n");
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
      st = spawn(c->argv, io, &tasks[s]);
    else
      for (int i = 0; i < 3; i++)
        if (io[i]) vx_handle_close(io[i]);
    if (st != VX_OK) {
      vx_str why = st == VX_ERR_NOT_FOUND ? VX_STR("not found") : VX_STR("cannot run it");
      say("gsh: ", word_str(c->argv), st == VX_ERR_NOT_FOUND ? ": not found\n" : ": cannot run it\n");
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
    set_status((vx_str){});
    return true;
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
        if (pk[k].value && vx_task_info(tasks[key], &info) == VX_OK) {
          memcpy(ends[key], info.exit, info.exit_len);
          end_len[key] = info.exit_len;
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
  if (broken) say("gsh: write error", (vx_str){}, "\n");
  char status[MAX_STAGES * (VX_ERRMAX + 1)]; // the commands' exit strings, joined by |, as rc's $status
  size_t len = 0;
  for (uint32_t s = 0; s < n; s++) {
    if (s) status[len++] = '|';
    memcpy(status + len, ends[s], end_len[s]);
    len += end_len[s];
  }
  rc_set_status(sh, status, len);
  for (uint32_t s = 0; s < n; s++)
    if (tasks[s]) vx_handle_close(tasks[s]);
  vx_handle_close(port);
  return true;
}

// --- The shell ---

static alignas(16) uint8_t heap[4 << 20];
static char text[256 * 1024]; // a script's, or the lines of a construct still open

// The last $status, as rc exits with it.
static const char *exit_status(void) {
  static char status[VX_ERRMAX + 1];
  size_t len = 0;
  for (const rc_word *w = rc_getvar(sh, "status"); w; w = w->next) {
    size_t n = vx_utf_cut(w->s, w->len, VX_ERRMAX - len); // whole runes (ADR-0013)
    memcpy(status + len, w->s, n);
    len += n;
    if (w->next && len < VX_ERRMAX) status[len++] = ' ';
  }
  status[len] = 0;
  return status;
}

static void show_error(void) {
  vx_eprint(vx_cstr(rc_err(sh)));
  vx_eprint(VX_STR("\n"));
}

const char *vx_main(void) {
  if (vx_ns_from_spawn(&ns) != VX_OK) vx_eprint(VX_STR("gsh: the namespace is incomplete\n"));
  rc_host host = {.run = run,
                  .write = write_out,
                  .readdir = read_dir,
                  .builtin = builtin,
                  .read_file = read_whole,
                  .open = open_file,
                  .close = close_file};
  sh = rc_new(heap, sizeof heap, &host);
  if (!sh) return "no memory";

  if (vx_spawn.argc) { // gsh FILE ARG ...: a script, its arguments in $*, its name in $0
    static const char *words[64];
    static size_t lens[64];
    uint32_t n = 0;
    for (uint32_t i = 1; i < vx_spawn.argc && n < 64; i++, n++)
      words[n] = vx_spawn.args[i].ptr, lens[n] = vx_spawn.args[i].len;
    rc_set(sh, "*", words, lens, n);
    words[0] = vx_spawn.args[0].ptr, lens[0] = vx_spawn.args[0].len;
    rc_set(sh, "0", words, lens, 1);
    int64_t len = read_whole(nullptr, vx_spawn.args[0].ptr, vx_spawn.args[0].len, text, sizeof text);
    if (len < 0) {
      say("gsh: ", vx_spawn.args[0], ": cannot read it\n");
      return "cannot read the script";
    }
    rc_result res = rc_run(sh, text, (size_t)len);
    if (res == RC_SYNTAX || res == RC_INCOMPLETE || res == RC_FAILED) {
      if (res == RC_INCOMPLETE)
        vx_eprint(VX_STR("gsh: the script ends inside a construct\n"));
      else
        show_error();
      return res == RC_FAILED ? exit_status() : "syntax error";
    }
    return exit_status();
  }

  size_t len = 0; // of text: the lines of a construct still open
  for (;;) {
    vx_print(len ? VX_STR("\t") : VX_STR("vx% "));
    size_t start = len;
    int64_t n;
    while ((n = vx_read(text + len, (uint32_t)(sizeof text - len))) > 0) {
      len += (size_t)n;
      if (text[len - 1] == '\n' || len == sizeof text) break;
    }
    if (n <= 0 && len == start) break;                 // the end of the input
    if (len == sizeof text && text[len - 1] != '\n') { // too long: refused whole, never run in pieces
      char rest[64];
      while ((n = vx_read(rest, sizeof rest)) > 0 && rest[n - 1] != '\n') {}
      say("gsh: line too long", (vx_str){}, "\n");
      set_status(VX_STR("line too long"));
      len = 0;
      continue;
    }
    rc_result res = rc_run(sh, text, len);
    if (res == RC_INCOMPLETE) continue; // the next line continues it
    len = 0;
    if (res == RC_SYNTAX || res == RC_FAILED) show_error();
    if (res == RC_EXIT) return exit_status();
  }
  vx_print(VX_STR("\n"));
  return exit_status();
}
