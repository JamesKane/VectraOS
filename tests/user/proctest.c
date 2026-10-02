// proctest: the one process table (ADR-0011), run as a service in the proc
// scenario (tests/qemu/proc.ndb). It spawns copies of itself, registered with
// procfs as its children, and checks /proc: status, ppid, wait records (the
// child's exit string, or the note that ended it), note, notepg, noteid, ctl,
// and a note ending a wait read. Each check prints a line only when it fails;
// the last line counts them.
//
// Run as a child (its first argument), it is:
//   exit      ends at once, with the exit string "child done"
//   sleep     waits for ever, so a note ends it, with the note
//   poke      waits a little, posts the note "poke" to its parent, then sleeps

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-rt/spawn.c"
#include "../../lib/vx-ns/spawn.c"

static uint32_t checks, failures;
static vx_ns ns;
static uint64_t me;

static void check_at(bool ok, const char *what, int line) {
  checks++;
  if (ok) return;
  failures++;
  vx_print(VX_STR("proctest: FAILED line "));
  vx_print_u64((uint64_t)line);
  vx_print(VX_STR(": "));
  vx_print(vx_cstr(what));
  vx_print(VX_STR("\n"));
}

#define CHECK(cond) check_at((cond), #cond, __LINE__)

static bool has(vx_str s, const char *want) {
  vx_str w = vx_cstr(want);
  for (size_t i = 0; i + w.len <= s.len; i++)
    if (memcmp(s.ptr + i, w.ptr, w.len) == 0) return true;
  return false;
}

static void nap(int64_t ms) {
  static _Atomic uint32_t never;
  vx_futex_wait(&never, 0, vx_clock_read() + ms * 1'000'000);
}

// "/proc/N/file", in a buffer that lasts until the next call.
static vx_str proc_path(uint64_t pid, const char *file) {
  static char path[64];
  char digits[20];
  size_t n = sizeof digits;
  do digits[--n] = (char)('0' + pid % 10);
  while (pid /= 10);
  static const char prefix[6] = {'/', 'p', 'r', 'o', 'c', '/'}; // a path piece, not a C string
  size_t len = sizeof prefix;
  memcpy(path, prefix, sizeof prefix);
  memcpy(path + len, digits + n, sizeof digits - n), len += sizeof digits - n;
  path[len++] = '/';
  vx_str f = vx_cstr(file);
  memcpy(path + len, f.ptr, f.len), len += f.len;
  return (vx_str){path, len};
}

// A /proc file's contents (one read), or a negative status.
static int64_t read_file(uint64_t pid, const char *file, char *buf, uint32_t cap) {
  vx_ns_file f;
  vx_status st = vx_ns_open(&ns, proc_path(pid, file), P9_OREAD, &f);
  if (st != VX_OK) return st;
  int64_t n = vx_ns_read(&f, buf, cap);
  vx_ns_close(&f);
  return n;
}

static vx_status write_file(uint64_t pid, const char *file, const char *text) {
  vx_ns_file f;
  vx_status st = vx_ns_open(&ns, proc_path(pid, file), P9_OWRITE, &f);
  if (st != VX_OK) return st;
  vx_str t = vx_cstr(text);
  int64_t n = vx_ns_write(&f, t.ptr, (uint32_t)t.len);
  vx_ns_close(&f);
  return n < 0 ? (vx_status)n : VX_OK;
}

static uint64_t number(const char *buf, int64_t n) {
  uint64_t v = 0;
  for (int64_t i = 0; i < n && buf[i] >= '0' && buf[i] <= '9'; i++) v = v * 10 + (uint64_t)(buf[i] - '0');
  return v;
}

static uint8_t image[1 << 20];
static size_t image_size;

// Spawns a copy of this program as a child, registered with procfs, in mode
// `what`. Returns its pid, or 0.
static uint64_t spawn(const char *what) {
  vx_handle handles[VX_CHANNEL_MAX_HANDLES - 1];
  vx_str names[VX_CHANNEL_MAX_HANDLES - 1];
  uint32_t count = 0;
  static char records[8 * 1024];
  vx_ndb_writer rec = {.buf = records, .cap = sizeof records};
  vx_ndb_put(&rec, "arg", vx_cstr(what));
  vx_ndb_end(&rec);
  if (vx_ns_spawn_records(&ns, &rec, handles, names, &count, VX_CHANNEL_MAX_HANDLES - 4) != VX_OK) return 0;
  if (vx_console.connector && vx_handle_dup(vx_console.connector, VX_RIGHTS_SAME, &handles[count]) == VX_OK)
    names[count++] = VX_STR("console");
  vx_spawn_args a = {.name = VX_STR("proctest"),
                     .image = image,
                     .image_size = image_size,
                     .handles = handles,
                     .handle_names = names,
                     .handle_count = count,
                     .records = {records, rec.len},
                     .proc = vx_ns_connector(&ns, VX_STR("/proc"))};
  vx_handle task;
  if (vx_spawn_elf(&a, &task) != VX_OK) return 0;
  vx_task_summary info;
  uint64_t pid = vx_task_info(task, &info) == VX_OK ? info.id : 0;
  vx_handle_close(task); // procfs watches it; this test waits through /proc
  return pid;
}

// The next wait record, into buf; its length, or a negative status.
static int64_t wait_record(char *buf, uint32_t cap) { return read_file(me, "wait", buf, cap); }

static uint32_t notes_seen;
static vx_noted on_note(vx_exception *e, vx_str note) {
  (void)e;
  if (!has(note, "group") && !has(note, "poke")) return VX_NDFLT;
  notes_seen++;
  return VX_NCONT;
}

static const char *child(vx_str mode) {
  if (mode.len == 4 && memcmp(mode.ptr, "exit", 4) == 0) return "child done";
  if (mode.len == 4 && memcmp(mode.ptr, "poke", 4) == 0) {
    nap(100); // the parent is in its wait read by now
    char buf[24] = {};
    vx_task_summary info;
    vx_task_info(vx_self, &info);
    int64_t n = read_file(info.id, "ppid", buf, sizeof buf);
    write_file(number(buf, n), "note", "poke");
  }
  for (;;) nap(1000); // a note ends it
}

const char *vx_main(void) {
  if (vx_ns_from_spawn(&ns) != VX_OK) return "no namespace";
  if (vx_spawn.argc) return child(vx_spawn.args[0]);
  vx_task_summary info;
  CHECK(vx_task_info(vx_self, &info) == VX_OK);
  me = info.id;
  vx_ns_file f;
  if (vx_ns_open(&ns, VX_STR("/boot/bin/proctest"), P9_OREAD, &f) == VX_OK) {
    int64_t n;
    while (image_size < sizeof image &&
           (n = vx_ns_read(&f, image + image_size, (uint32_t)(sizeof image - image_size))) > 0)
      image_size += (size_t)n;
    vx_ns_close(&f);
  }
  CHECK(image_size > 0);
  char buf[512] = {};

  // Its own entry: pid = its task id; its parent is svcd.
  int64_t n = read_file(me, "status", buf, sizeof buf);
  CHECK(n > 0 && has((vx_str){buf, (size_t)n}, "name=proctest") && has((vx_str){buf, (size_t)n}, "pid="));
  n = read_file(me, "ppid", buf, sizeof buf);
  CHECK(n > 0 && number(buf, n) == 1);
  CHECK(wait_record(buf, sizeof buf) == VX_ERR_NO_CHILD); // no children yet

  // A child's end leaves a record with its exit string.
  uint64_t c = spawn("exit");
  CHECK(c != 0);
  n = wait_record(buf, sizeof buf);
  CHECK(n > 0 && has((vx_str){buf, (size_t)n}, "status=\"child done\"") &&
        has((vx_str){buf, (size_t)n}, "name=proctest"));

  // A note ends a child with no handler, with the note as its exit string.
  c = spawn("sleep");
  n = read_file(c, "ppid", buf, sizeof buf);
  CHECK(n > 0 && number(buf, n) == me);
  CHECK(write_file(c, "note", "hello") == VX_OK);
  n = wait_record(buf, sizeof buf);
  CHECK(n > 0 && has((vx_str){buf, (size_t)n}, "status=hello"));

  // Children are in their parent's note group: notepg reaches them all, and the writer.
  CHECK(vx_notify(on_note) == VX_OK);
  uint64_t a = spawn("sleep"), b = spawn("sleep");
  n = read_file(a, "noteid", buf, sizeof buf);
  uint64_t group = number(buf, n);
  n = read_file(me, "noteid", buf, sizeof buf);
  CHECK(group && b && number(buf, n) == group);
  CHECK(write_file(me, "notepg", "group") == VX_OK);
  CHECK(notes_seen == 1);
  for (int i = 0; i < 2; i++) {
    n = wait_record(buf, sizeof buf);
    CHECK(n > 0 && has((vx_str){buf, (size_t)n}, "status=group"));
  }

  // noteid: a group of its own, by its own pid; not one that does not exist.
  c = spawn("sleep");
  CHECK(write_file(c, "noteid", "999999") == VX_ERR_ACCESS);
  char pid[24];
  size_t pl = 0;
  for (uint64_t v = c; v; v /= 10) pid[pl++] = (char)('0' + v % 10);
  for (size_t i = 0; i < pl / 2; i++) {
    char t = pid[i];
    pid[i] = pid[pl - 1 - i], pid[pl - 1 - i] = t;
  }
  pid[pl] = 0;
  CHECK(write_file(c, "noteid", pid) == VX_OK);
  n = read_file(c, "noteid", buf, sizeof buf);
  CHECK(n > 0 && number(buf, n) == c);

  // ctl: stop and start, then kill: its record says "killed".
  CHECK(write_file(c, "ctl", "stop") == VX_OK);
  n = read_file(c, "status", buf, sizeof buf);
  CHECK(n > 0 && has((vx_str){buf, (size_t)n}, "state=stopped"));
  CHECK(write_file(c, "ctl", "start") == VX_OK);
  CHECK(write_file(c, "ctl", "bogus") == VX_ERR_INVALID);
  CHECK(write_file(c, "ctl", "kill") == VX_OK);
  n = wait_record(buf, sizeof buf);
  CHECK(n > 0 && has((vx_str){buf, (size_t)n}, "status=killed"));

  // A note to a process waiting in a wait read ends the read, after the note.
  c = spawn("poke");
  notes_seen = 0;
  CHECK(wait_record(buf, sizeof buf) == VX_ERR_INTERRUPTED && notes_seen == 1);
  CHECK(write_file(c, "ctl", "kill") == VX_OK);
  n = wait_record(buf, sizeof buf);
  CHECK(n > 0 && has((vx_str){buf, (size_t)n}, "status=killed"));
  CHECK(wait_record(buf, sizeof buf) == VX_ERR_NO_CHILD);

  vx_print(VX_STR("proctest: "));
  vx_print_u64(checks);
  vx_print(VX_STR(" checks, "));
  vx_print_u64(failures);
  vx_print(VX_STR(" failed\n"));
  return failures ? "failed" : nullptr;
}
