// gsh: the shell (docs/04 §5, M2), small and in rc's manner.
//
//   ls /; cat /proc/1/status            commands, separated by ; or newlines
//   ns | tail -1                        pipes
//   echo kill > /proc/2/ctl             output into a file
//   pid=2; echo $pid 'a b'              variables, and quoting ('' is a quote)
//   bind -a /boot/bin /bin              builtins: bind, mount, unmount, exit [status]
//
// A command is a program found as given (a path) or in /bin, then /boot/bin,
// through the shell's namespace. It is loaded by the shell and spawned with a
// copy of the namespace, the console, its end of any pipe, and the shell's
// standard error if it has one. A pipe is a channel; output into a file goes
// through one too, and the shell copies it into the file. Commands exit by
// themselves; the shell waits for them all.
//
// $status is the last command's exit string, as in rc (ADR-0010): empty for
// success, else why it failed; a pipe's is its commands', joined by |. A
// builtin sets it too. At the end of its input the shell exits with it.

#include "../lib/vx-rt/rt.c"
#include "../lib/vx-rt/spawn.c"
#include "../lib/vx-ns/spawn.c"

static constexpr int MAX_WORDS = 64;
static constexpr int MAX_PIPELINE = 8;

static vx_ns ns;

// Errors go to standard error: the console, unless the shell has a pipe for it.
static void say(const char *a, vx_str b, const char *c) {
  vx_eprint(vx_cstr(a));
  vx_eprint(b);
  vx_eprint(vx_cstr(c));
}

// --- Variables ---

static struct {
  char name[32], value[256];
  size_t name_len, value_len;
} vars[32];

static vx_str var_get(vx_str name) {
  for (size_t i = 0; i < sizeof vars / sizeof vars[0]; i++)
    if (vars[i].name_len == name.len && memcmp(vars[i].name, name.ptr, name.len) == 0)
      return (vx_str){vars[i].value, vars[i].value_len};
  return (vx_str){};
}

static void var_set(vx_str name, vx_str value) {
  size_t slot = sizeof vars / sizeof vars[0];
  for (size_t i = 0; i < sizeof vars / sizeof vars[0]; i++) {
    bool same = vars[i].name_len == name.len && memcmp(vars[i].name, name.ptr, name.len) == 0;
    if (same || (slot == sizeof vars / sizeof vars[0] && !vars[i].name_len)) slot = i;
  }
  if (slot == sizeof vars / sizeof vars[0] || name.len > sizeof vars[0].name ||
      value.len > sizeof vars[0].value) {
    vx_eprint(VX_STR("gsh: too many variables, or too long\n"));
    return;
  }
  memcpy(vars[slot].name, name.ptr, name.len);
  memcpy(vars[slot].value, value.ptr, value.len);
  vars[slot].name_len = name.len;
  vars[slot].value_len = value.len;
}

static const char *find(vx_str s, char c) {
  for (size_t i = 0; i < s.len; i++)
    if (s.ptr[i] == c) return s.ptr + i;
  return nullptr;
}

static bool is_name_char(char c) {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
}

// --- Words ---
//
// A line becomes words and the operators ; | >. A word is unquoted text, with
// $name replaced by the variable's value, and 'quoted' text taken as it is.

typedef struct word {
  vx_str text;
  char op; // ';', '|' or '>' for an operator; 0 for a word
} word;

static char word_pool[4096];

static int split(vx_str line, word *words) {
  int count = 0;
  size_t used = 0, i = 0;
  while (i < line.len) {
    char c = line.ptr[i];
    if (c == ' ' || c == '\t' || c == '\n') {
      i++;
      continue;
    }
    if (c == '#') break;
    if (count == MAX_WORDS) return -1;
    if (c == ';' || c == '|' || c == '>') {
      words[count++] = (word){.op = c};
      i++;
      continue;
    }
    size_t start = used;
    while (i < line.len) {
      c = line.ptr[i];
      if (c == ' ' || c == '\t' || c == '\n' || c == ';' || c == '|' || c == '>' || c == '#') break;
      if (c == '\'') { // to the closing quote; '' inside is one quote
        for (i++; i < line.len; i++) {
          if (line.ptr[i] == '\'' && (i + 1 >= line.len || line.ptr[i + 1] != '\'')) break;
          if (line.ptr[i] == '\'') i++;
          if (used == sizeof word_pool) return -1;
          word_pool[used++] = line.ptr[i];
        }
        if (i == line.len) return -2; // unterminated
        i++;
      } else if (c == '$' && i + 1 < line.len && is_name_char(line.ptr[i + 1])) {
        size_t n = i + 1;
        while (n < line.len && is_name_char(line.ptr[n])) n++;
        vx_str v = var_get((vx_str){line.ptr + i + 1, n - i - 1});
        if (v.len > sizeof word_pool - used) return -1;
        memcpy(word_pool + used, v.ptr, v.len);
        used += v.len;
        i = n;
      } else {
        if (used == sizeof word_pool) return -1;
        word_pool[used++] = c;
        i++;
      }
    }
    words[count++] = (word){.text = {word_pool + start, used - start}};
  }
  return count;
}

static bool word_is(word w, const char *s) {
  vx_str t = vx_cstr(s);
  return !w.op && w.text.len == t.len && memcmp(w.text.ptr, t.ptr, t.len) == 0;
}

// --- Builtins ---

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

static void set_status(vx_str s) { var_set(VX_STR("status"), s); }

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

// True if words[0] was a builtin, which then ran.
static bool builtin(word *w, int n) {
  if (word_is(w[0], "bind")) {
    uint8_t flags = n > 1 && w[1].text.len && w[1].text.ptr[0] == '-' ? bind_flags(w[1].text) : 0;
    int first = n > 1 && w[1].text.len && w[1].text.ptr[0] == '-' ? 2 : 1;
    if (flags == 0xff || n - first != 2)
      usage("usage: bind [-abc] new old\n");
    else
      report("bind", vx_ns_bind(&ns, w[first].text, w[first + 1].text, flags));
    return true;
  }
  // mount: a service this namespace has a connection from (/srv/NAME, as ns
  // prints it, so its output replays), or a 9P server over TCP, tcp!HOST!PORT
  // or 9p://HOST:PORT.
  if (word_is(w[0], "mount")) {
    uint8_t flags = n > 1 && w[1].text.len && w[1].text.ptr[0] == '-' ? bind_flags(w[1].text) : 0;
    int first = n > 1 && w[1].text.len && w[1].text.ptr[0] == '-' ? 2 : 1;
    if (flags == 0xff || n - first < 2 || n - first > 3) {
      usage("usage: mount [-abc] /srv/name|tcp!host!port old [aname]\n");
      return true;
    }
    vx_str aname = n - first == 3 ? w[first + 2].text : (vx_str){};
    vx_str from = w[first].text;
    vx_status st;
    if (from.len > 5 && memcmp(from.ptr, "/srv/", 5) == 0) {
      st = vx_ns_mount_srv(&ns, from, aname, w[first + 1].text, flags);
    } else {
      p9_client *c;
      vx_str src;
      st = vx_ns_dial(&ns, from, &c, &src);
      if (st == VX_OK) st = vx_ns_mount(&ns, c, VX_HANDLE_NONE, src, aname, w[first + 1].text, flags);
    }
    report("mount", st);
    return true;
  }
  if (word_is(w[0], "unmount")) {
    if (n == 2)
      report("unmount", vx_ns_unmount(&ns, (vx_str){}, w[1].text));
    else if (n == 3)
      report("unmount", vx_ns_unmount(&ns, w[1].text, w[2].text));
    else
      usage("usage: unmount [new] old\n");
    return true;
  }
  if (word_is(w[0], "exit")) vx_exit_str(n > 1 ? w[1].text : (vx_str){}); // as rc's exit: the string given
  return false;
}

// --- Running programs ---

static uint8_t image[1 << 20];

// Loads a program through the namespace: the path as given, or /bin/NAME,
// then /boot/bin/NAME. Returns its size, or 0.
static size_t load(vx_str name) {
  static const char *const DIRS[] = {"", "/bin/", "/boot/bin/"};
  for (size_t d = 0; d < sizeof DIRS / sizeof DIRS[0]; d++) {
    bool has_slash = find(name, '/') != nullptr;
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

// Spawns one command with its own end of the pipes: in and out are channel
// ends (VX_HANDLE_NONE for the console), and are given away.
static vx_status spawn(const word *w, int n, vx_handle in, vx_handle out, vx_handle *task) {
  vx_handle handles[VX_CHANNEL_MAX_HANDLES - 1];
  vx_str names[VX_CHANNEL_MAX_HANDLES - 1];
  uint32_t count = 0;
  static char records[16 * 1024];
  vx_ndb_writer rec = {.buf = records, .cap = sizeof records};
  size_t size = load(w[0].text);
  vx_status st = size ? VX_OK : VX_ERR_NOT_FOUND;
  for (int i = 1; st == VX_OK && i < n; i++) {
    vx_ndb_put(&rec, "arg", w[i].text);
    vx_ndb_end(&rec);
  }
  if (st == VX_OK) st = vx_ns_spawn_records(&ns, &rec, handles, names, &count, VX_CHANNEL_MAX_HANDLES - 4);
  if (st == VX_OK && vx_console.connector &&
      vx_handle_dup(vx_console.connector, VX_RIGHTS_SAME, &handles[count]) == VX_OK)
    names[count++] = VX_STR("console");
  if (in) handles[count] = in, names[count++] = VX_STR("stdin");
  if (out) handles[count] = out, names[count++] = VX_STR("stdout");
  if (st == VX_OK && vx_stdio.err && vx_handle_dup(vx_stdio.err, VX_RIGHTS_SAME, &handles[count]) == VX_OK)
    names[count++] = VX_STR("stderr");
  if (st != VX_OK) {
    for (uint32_t i = 0; i < count; i++) vx_handle_close(handles[i]);
    return st;
  }
  vx_str base = w[0].text; // the task's name: the program's, without its directory
  for (size_t i = base.len; i-- > 0;)
    if (base.ptr[i] == '/') base = (vx_str){base.ptr + i + 1, base.len - i - 1};
  vx_spawn_args a = {.name = base.len < 24 ? base : (vx_str){base.ptr, 23},
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

// Copies what is waiting on the channel into the file. False once the writer
// has gone and everything it wrote has been copied.
static bool relay(vx_handle ch, vx_ns_file *f, bool *broken) {
  static uint8_t msg[sizeof(vx_msg_header) + 4096];
  for (;;) {
    vx_msg_size size;
    vx_status st = vx_channel_read(ch, msg, sizeof msg, nullptr, 0, &size);
    if (st == VX_ERR_SHOULD_WAIT) return true;
    if (st != VX_OK) return false;
    for (uint32_t done = sizeof(vx_msg_header); done < size.bytes && !*broken;) {
      int64_t w = vx_ns_write(f, msg + done, size.bytes - done);
      if (w <= 0)
        *broken = true;
      else
        done += (uint32_t)w;
    }
  }
}

// Runs one pipeline: commands joined by |, the last perhaps into a file.
static void pipeline(word *w, int n) {
  int starts[MAX_PIPELINE + 1], stages = 0;
  vx_str into = {};
  for (int i = 0; i < n; i++) {
    if (w[i].op == '>' && i + 2 == n && !w[i + 1].op) {
      into = w[i + 1].text;
      n = i;
      break;
    }
    if (w[i].op && w[i].op != '|') {
      say("gsh: syntax error", (vx_str){}, "\n");
      set_status(VX_STR("syntax error"));
      return;
    }
  }
  starts[stages++] = 0;
  for (int i = 0; i < n; i++) {
    if (w[i].op != '|') continue;
    if (stages == MAX_PIPELINE) {
      say("gsh: too many commands in a pipe", (vx_str){}, "\n");
      set_status(VX_STR("too many commands"));
      return;
    }
    starts[stages++] = i + 1;
  }
  starts[stages] = n + 1;
  for (int s = 0; s < stages; s++)
    if (starts[s + 1] - 1 == starts[s]) {
      say("gsh: syntax error", (vx_str){}, "\n");
      set_status(VX_STR("syntax error"));
      return;
    }
  if (stages == 1 && builtin(w, n)) return;

  vx_ns_file file = {};
  if (into.len) {
    // Truncated if it exists (devices ignore that), and made if it does not, as rc does.
    vx_status st = vx_ns_open(&ns, into, P9_OWRITE | P9_OTRUNC, &file);
    if (st == VX_ERR_NOT_FOUND) st = vx_ns_create(&ns, into, 0644, P9_OWRITE, &file);
    if (st != VX_OK) {
      report("cannot open the file", st);
      return;
    }
  }
  // Each command's exit string, for $status.
  static char ends[MAX_PIPELINE][VX_ERRMAX];
  size_t end_len[MAX_PIPELINE] = {};
  vx_handle tasks[MAX_PIPELINE] = {}, prev = VX_HANDLE_NONE, sink = VX_HANDLE_NONE, port;
  if (vx_port_create(0, &port) != VX_OK) return;
  for (int s = 0; s < stages; s++) {
    vx_handle out = VX_HANDLE_NONE, ch[2];
    if (s + 1 < stages || into.len) {
      if (vx_channel_create(0, ch) != VX_OK) break;
      out = ch[0];
    }
    vx_status st = spawn(&w[starts[s]], starts[s + 1] - 1 - starts[s], prev, out, &tasks[s]);
    prev = out ? ch[1] : VX_HANDLE_NONE;
    if (st != VX_OK) {
      say("gsh: ", w[starts[s]].text, st == VX_ERR_NOT_FOUND ? ": not found\n" : ": cannot run it\n");
      vx_str why = st == VX_ERR_NOT_FOUND ? VX_STR("not found") : VX_STR("cannot run it");
      memcpy(ends[s], why.ptr, why.len);
      end_len[s] = why.len;
      continue;
    }
    vx_port_bind(port, tasks[s], VX_TRIGGER_EXIT, (uint64_t)s, 0);
  }
  if (into.len)
    sink = prev; // the last command's output, for the file
  else if (prev)
    vx_handle_close(prev);
  if (sink) vx_port_bind(port, sink, VX_TRIGGER_PEER_CLOSED, 101, 0);

  // Wait for every command; meanwhile copy the last one's output into the file.
  int running = 0;
  for (int s = 0; s < stages; s++) running += tasks[s] != VX_HANDLE_NONE;
  bool broken = false, sink_armed = false;
  while (running || sink) {
    if (sink && !sink_armed) sink_armed = vx_port_bind(port, sink, VX_TRIGGER_READABLE, 100, 0) == VX_OK;
    vx_packet pk[8];
    int64_t got = vx_port_wait(port, VX_INFINITE, 0, pk, 8);
    for (int64_t i = 0; i < got; i++) {
      if (pk[i].trigger == VX_TRIGGER_EXIT) {
        running--;
        vx_task_summary info;
        uint64_t s = pk[i].key;
        if (s < (uint64_t)stages && pk[i].value && vx_task_info(tasks[s], &info) == VX_OK) {
          memcpy(ends[s], info.exit, info.exit_len);
          end_len[s] = info.exit_len;
        }
      } else if (sink && pk[i].key == 100) { // output to copy
        sink_armed = false;
        if (!relay(sink, &file, &broken)) {
          vx_handle_close(sink);
          sink = VX_HANDLE_NONE;
        }
      } else if (sink && pk[i].key == 101 && !relay(sink, &file, &broken)) { // the writer is done
        vx_handle_close(sink);
        sink = VX_HANDLE_NONE;
      }
    }
  }
  if (broken) say("gsh: write error", (vx_str){}, "\n");
  char status[MAX_PIPELINE * (VX_ERRMAX + 1)]; // the commands' exit strings, joined by |, as rc's $status
  size_t len = 0;
  for (int s = 0; s < stages; s++) {
    if (s) status[len++] = '|';
    memcpy(status + len, ends[s], end_len[s]);
    len += end_len[s];
  }
  set_status((vx_str){status, len});
  for (int s = 0; s < stages; s++)
    if (tasks[s]) vx_handle_close(tasks[s]);
  vx_handle_close(port);
  if (into.len) vx_ns_close(&file);
}

// Runs one command, or pipeline, of a line: its words are expanded now, so a
// variable set earlier in the line is seen.
static void run_command(vx_str text) {
  word w[MAX_WORDS];
  int n = split(text, w);
  if (n < 0) {
    vx_eprint(n == -2 ? VX_STR("gsh: unterminated quote\n") : VX_STR("gsh: line too long\n"));
    return;
  }
  if (n == 0) return;
  // name=value alone sets a variable.
  vx_str t = w[0].text;
  const char *eq = n == 1 && !w[0].op ? find(t, '=') : nullptr;
  if (eq && eq > t.ptr)
    var_set((vx_str){t.ptr, (size_t)(eq - t.ptr)}, (vx_str){eq + 1, t.len - (size_t)(eq - t.ptr) - 1});
  else
    pipeline(w, n);
}

// Runs a line's commands in turn: it splits at each ; outside quotes and
// before a comment.
static void run_line(vx_str line) {
  size_t start = 0;
  bool quoted = false;
  for (size_t i = 0; i <= line.len; i++) {
    char c = i < line.len ? line.ptr[i] : ';';
    if (c == '\'') quoted = !quoted; // '' inside quotes toggles twice: still quoted
    if (quoted && i < line.len) continue;
    if (c == '#') c = ';', i = line.len; // the rest is a comment
    if (c != ';') continue;
    run_command((vx_str){line.ptr + start, i - start});
    start = i + 1;
  }
}

const char *vx_main(void) {
  if (vx_ns_from_spawn(&ns) != VX_OK) vx_eprint(VX_STR("gsh: the namespace is incomplete\n"));
  char line[512];
  for (;;) {
    vx_print(VX_STR("vx% "));
    size_t len = 0;
    int64_t n;
    while ((n = vx_read(line + len, (uint32_t)(sizeof line - len))) > 0) {
      len += (size_t)n;
      if (line[len - 1] == '\n' || len == sizeof line) break;
    }
    if (n <= 0 && len == 0) break; // the end of the input
    run_line((vx_str){line, len});
  }
  vx_print(VX_STR("\n"));
  static char status[VX_ERRMAX + 1]; // the last $status, as rc exits with it
  vx_str last = var_get(VX_STR("status"));
  size_t len = last.len < VX_ERRMAX ? last.len : VX_ERRMAX;
  memcpy(status, last.ptr, len);
  status[len] = 0;
  return status;
}
