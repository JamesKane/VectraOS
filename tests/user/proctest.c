// proctest: the one process table (ADR-0011), run as a service in the proc
// scenario (tests/qemu/proc.ndb). It spawns copies of itself, registered with
// procfs as its children, and checks /proc: status, ppid, wait records (the
// child's exit string, or the note that ended it), note, notepg, noteid, ctl,
// and a note ending a wait read. Each check prints a line only when it fails;
// the last line counts them. It checks namespace groups too: a child's bind
// reaches its parent, and /proc/N/ns says so.
//
// Run as a child (its first argument), it is:
//   exit      ends at once, with the exit string "child done"
//   sleep     waits for ever, so a note ends it, with the note
//   poke      waits a little, posts the note "poke" to its parent, then sleeps
//   bind      binds /boot on /n, in the namespace group it shares with its
//             parent (ADR-0009), and ends
//   loop      calls target(0), target(1), ... every 10 ms, and ends at 20:
//             what the debug files (05 §3) stop at a breakpoint
//   fault     waits a little, then reads address 16, which nothing maps
//   zones     gives procfs a profiling ring, then times a zone of work every
//             few milliseconds, for ever (05 §9)

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-rt/spawn.c"
#include "../../lib/vx-ns/spawn.c"
#include "../../lib/vx-prof/prof.h"

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
// A busy thread timing zones, 50 of them (6d6b).
static void zones_thread(void *arg) {
  (void)arg;
  static vx_prof_zone tick = {.name = "tick"};
  for (int i = 0; i < 50; i++) {
    uint64_t t = vx_prof_begin(&tick);
    for (volatile int k = 0; k < 2000; k++) {}
    vx_prof_end(&tick, t);
  }
}

static vx_noted on_note(vx_exception *e, vx_str note, void *fp) {
  (void)fp;
  (void)e;
  if (!has(note, "group") && !has(note, "poke")) return VX_NDFLT;
  notes_seen++;
  return VX_NCONT;
}

// What the debug test stops in: noinline, so it is a call with its argument
// in the first argument register.
static volatile uint64_t counter;
[[gnu::noinline]] static void target(uint64_t n) { counter = counter + n; }

static volatile uintptr_t fault_at = 16; // nothing maps it; volatile, so the analyzer does not know it

static const char *child(vx_str mode) {
  if (mode.len == 4 && memcmp(mode.ptr, "loop", 4) == 0) {
    for (uint64_t i = 0; i < 20; i++) {
      target(i);
      nap(10);
    }
    return "looped";
  }
  if (mode.len == 5 && memcmp(mode.ptr, "zones", 5) == 0) {
    if (vx_prof_init(vx_ns_connector(&ns, VX_STR("/proc"))) != VX_OK) return "no ring";
    static vx_prof_zone work = {.name = "work"};
    for (;;) {
      uint64_t t = vx_prof_begin(&work);
      for (volatile int i = 0; i < 10000; i++) {}
      vx_prof_end(&work, t);
      nap(2);
    }
  }
  if (mode.len == 5 && memcmp(mode.ptr, "fault", 5) == 0) {
    nap(100);
    return *(volatile const char *)fault_at ? "read" : "zero";
  }
  if (mode.len == 4 && memcmp(mode.ptr, "exit", 4) == 0) return "child done";
  if (mode.len == 4 && memcmp(mode.ptr, "bind", 4) == 0)
    return vx_ns_bind(&ns, VX_STR("/boot"), VX_STR("/n"), 0) == VX_OK ? nullptr : "cannot bind";
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

// "0x..." for an address.
static const char *hex(uint64_t v) {
  static char buf[19];
  size_t n = 0;
  char digits[16];
  do digits[n++] = "0123456789abcdef"[v & 15];
  while (v >>= 4);
  buf[0] = '0', buf[1] = 'x';
  for (size_t i = 0; i < n; i++) buf[2 + i] = digits[n - 1 - i];
  buf[2 + n] = 0;
  return buf;
}

// The debug files (05 §3): a breakpoint with a condition, its event, the
// thread's status and registers, memory, a step, the maps and image, and a
// fault seen as an event and then passed on.
static void test_debug(void) {
  char buf[1024] = {}, cmd[96];
  uint64_t c = spawn("loop");
  CHECK(c != 0);
  vx_str at = vx_cstr(hex((uint64_t)target));
#ifdef __x86_64__
  const char *cond = " if rdi==3", *arg = "rdi=0x3";
#else
  const char *cond = " if x0==3", *arg = "x0=0x3";
#endif
  size_t len = 0;
  const char *parts[] = {"break ", at.ptr, cond};
  for (size_t i = 0; i < sizeof parts / sizeof parts[0]; i++) {
    vx_str s = vx_cstr(parts[i]);
    memcpy(cmd + len, s.ptr, s.len), len += s.len;
  }
  cmd[len] = 0;
  CHECK(write_file(c, "ctl", cmd) == VX_OK);
  int64_t n = read_file(c, "events", buf, sizeof buf); // waits for the hit
  vx_str ev = {buf, n > 0 ? (size_t)n : 0};
  CHECK(has(ev, "event=break") && has(ev, "thread=1") && has(ev, at.ptr));
  n = read_file(c, "threads/1/status", buf, sizeof buf);
  CHECK(n > 0 && has((vx_str){buf, (size_t)n}, "state=stopped") &&
        has((vx_str){buf, (size_t)n}, "reason=break"));
  n = read_file(c, "threads/1/regs.ndb", buf, sizeof buf);
  CHECK(n > 0 && has((vx_str){buf, (size_t)n}, arg));
  // Its memory: counter is 0 + 1 + 2 when target(3) is called.
  vx_ns_file f;
  uint64_t value = 0;
  CHECK(vx_ns_open(&ns, proc_path(c, "mem"), P9_OREAD, &f) == VX_OK);
  f.offset = (uint64_t)&counter;
  CHECK(vx_ns_read(&f, &value, sizeof value) == sizeof value && value == 3);
  vx_ns_close(&f);
  vx_regs regs;
  CHECK(vx_ns_open(&ns, proc_path(c, "threads/1/regs"), P9_OREAD, &f) == VX_OK);
  CHECK(vx_ns_read(&f, &regs, sizeof regs) == sizeof regs);
  vx_ns_close(&f);
#ifdef __x86_64__
  CHECK(regs.rip == (uint64_t)target && regs.rdi == 3);
#else
  CHECK(regs.pc == (uint64_t)target && regs.x[0] == 3);
#endif
  vx_fpregs fp;
  CHECK(vx_ns_open(&ns, proc_path(c, "threads/1/fpregs"), P9_OREAD, &f) == VX_OK);
  CHECK(vx_ns_read(&f, &fp, sizeof fp) == sizeof fp);
  vx_ns_close(&f);
  // One step: past the breakpoint's instruction.
  CHECK(write_file(c, "threads/1/ctl", "step") == VX_OK);
  n = read_file(c, "events", buf, sizeof buf);
  ev = (vx_str){buf, n > 0 ? (size_t)n : 0};
  CHECK(has(ev, "event=step") && !has(ev, at.ptr));
  n = read_file(c, "maps", buf, sizeof buf);
  CHECK(n > 0 && has((vx_str){buf, (size_t)n}, "prot=r-x"));
  n = read_file(c, "images", buf, sizeof buf);
  CHECK(n > 0 && has((vx_str){buf, (size_t)n}, "name=proctest") &&
        has((vx_str){buf, (size_t)n}, "build-id="));
  n = read_file(c, "threads", buf, sizeof buf); // a directory: its one thread
  CHECK(n > 0);
  n = read_file(c, "info", buf, sizeof buf);
  CHECK(n > 0 && has((vx_str){buf, (size_t)n}, "watchpoints=") &&
        has((vx_str){buf, (size_t)n}, "breakpoints=32"));
  // The breakpoint out; a watchpoint on counter: the next write stops it.
  memcpy(cmd, "unbreak ", 8), memcpy(cmd + 8, at.ptr, at.len + 1);
  CHECK(write_file(c, "ctl", cmd) == VX_OK);
  vx_str watched = vx_cstr(hex((uint64_t)&counter));
  len = 0;
  const char *wparts[] = {"watch ", watched.ptr, " 8 write"};
  for (size_t i = 0; i < sizeof wparts / sizeof wparts[0]; i++) {
    vx_str s = vx_cstr(wparts[i]);
    memcpy(cmd + len, s.ptr, s.len), len += s.len;
  }
  cmd[len] = 0;
  CHECK(write_file(c, "ctl", cmd) == VX_OK);
  CHECK(write_file(c, "ctl", "watch 0x1001 8 write") == VX_ERR_INVALID); // not aligned
  CHECK(write_file(c, "ctl", "start") == VX_OK);
  n = read_file(c, "events", buf, sizeof buf);
  ev = (vx_str){buf, n > 0 ? (size_t)n : 0};
  CHECK(has(ev, "event=watch") && has(ev, watched.ptr) && has(ev, "access=write"));
  n = read_file(c, "threads/1/status", buf, sizeof buf);
  CHECK(n > 0 && has((vx_str){buf, (size_t)n}, "reason=watch"));
  // Stepped past it, it stops again at the next write: then out, and on.
  CHECK(write_file(c, "ctl", "start") == VX_OK);
  n = read_file(c, "events", buf, sizeof buf);
  ev = (vx_str){buf, n > 0 ? (size_t)n : 0};
  CHECK(has(ev, "event=watch"));
  memcpy(cmd, "unwatch ", 8), memcpy(cmd + 8, watched.ptr, watched.len + 1);
  CHECK(write_file(c, "ctl", cmd) == VX_OK && write_file(c, "ctl", "start") == VX_OK);
  n = wait_record(buf, sizeof buf);
  CHECK(n > 0 && has((vx_str){buf, (size_t)n}, "status=looped"));

  // A fault, seen by the debugger first, then passed on: it ends the child.
  c = spawn("fault");
  CHECK(c != 0);
  CHECK(vx_ns_open(&ns, proc_path(c, "events"), P9_OREAD, &f) == VX_OK); // opened: procfs is its debugger
  n = vx_ns_read(&f, buf, sizeof buf);
  vx_ns_close(&f);
  ev = (vx_str){buf, n > 0 ? (size_t)n : 0};
  CHECK(has(ev, "event=fault") && has(ev, "addr=0x10") && has(ev, "access=read"));
  CHECK(write_file(c, "ctl", "start") == VX_OK);
  n = wait_record(buf, sizeof buf);
  CHECK(n > 0 && has((vx_str){buf, (size_t)n}, "sys: trap: fault read addr=0x10"));
  // Its crash directory (05 §5), shaped like /proc/N.
  char dir[48] = "/tmp/crash/proctest.";
  size_t dl = 20;
  char digits[20];
  size_t nd = sizeof digits;
  for (uint64_t v = c; v || nd == sizeof digits; v /= 10) digits[--nd] = (char)('0' + v % 10);
  memcpy(dir + dl, digits + nd, sizeof digits - nd), dl += sizeof digits - nd;
  static const char *const files[] = {"/note",          "/maps", "/images", "/info", "/threads/1/regs.ndb",
                                      "/threads/1/regs"};
  for (size_t i = 0; i < sizeof files / sizeof files[0]; i++) {
    char path[96];
    vx_str fname = vx_cstr(files[i]);
    memcpy(path, dir, dl), memcpy(path + dl, fname.ptr, fname.len);
    n = -1;
    if (vx_ns_open(&ns, (vx_str){path, dl + fname.len}, P9_OREAD, &f) == VX_OK) {
      n = vx_ns_read(&f, buf, sizeof buf);
      vx_ns_close(&f);
    }
    CHECK(n > 0);
    if (i == 0) CHECK(n > 0 && has((vx_str){buf, (size_t)n}, "sys: trap: fault read addr=0x10"));
    if (i == 4)
      CHECK(n > 0 && has((vx_str){buf, (size_t)n}, "rsp=") != has((vx_str){buf, (size_t)n}, "x29="));
  }
  static const char mem_dir[4] = {'/', 'm', 'e', 'm'}; // a path piece, not a C string
  memcpy(dir + dl, mem_dir, sizeof mem_dir);
  CHECK(vx_ns_open(&ns, (vx_str){dir, dl + 4}, P9_OREAD, &f) == VX_OK); // the writable mappings
  n = vx_ns_read(&f, buf, sizeof buf);
  vx_ns_close(&f);
  CHECK(n > 0); // at least one entry
}

// /sys/clock (02 §5.1), and profiling zones (05 §9): a child times a zone;
// with zones on, /proc/N/prof/zones has its records, named, in cycles.
static void test_prof(void) {
  char buf[256] = {};
  vx_ns_file f;
  int64_t n = -1;
  if (vx_ns_open(&ns, VX_STR("/sys/clock/info"), P9_OREAD, &f) == VX_OK) {
    n = vx_ns_read(&f, buf, sizeof buf);
    vx_ns_close(&f);
  }
  vx_str info = {buf, n > 0 ? (size_t)n : 0};
  CHECK(has(info, ".hz=") && has(info, ".user") && has(info, "source="));
  if (vx_ns_open(&ns, VX_STR("/sys/clock/now"), P9_OREAD, &f) == VX_OK) {
    n = vx_ns_read(&f, buf, sizeof buf);
    vx_ns_close(&f);
  }
  CHECK(n > 0 && has((vx_str){buf, (size_t)n}, "monotonic="));
  n = -1; // /sys/cpu/topology: a record a CPU online, none reserved (ADR-0045)
  if (vx_ns_open(&ns, VX_STR("/sys/cpu/topology"), P9_OREAD, &f) == VX_OK) {
    n = vx_ns_read(&f, buf, sizeof buf);
    vx_ns_close(&f);
  }
  vx_str topo = {buf, n > 0 ? (size_t)n : 0};
  uint32_t lines = 0;
  for (size_t i = 0; i < topo.len; i++) lines += topo.ptr[i] == '\n';
  CHECK(has(topo, "cpu=cpu0\n") && !has(topo, "reserved") && lines == vx_cpu_count());
  vx_clock_info clock = {};
  CHECK(vx_clock_info_read(&clock) == VX_OK && clock.counter_hz > 1'000'000);
  uint64_t c0 = vx_cycles();
  nap(10);
  uint64_t c1 = vx_cycles();
  CHECK(c1 > c0 && (c1 - c0) * 1000 / clock.counter_hz >= 9); // 10 ms of cycles, read in user mode

  uint64_t c = spawn("zones");
  CHECK(c != 0);
  vx_status st = VX_ERR_NOT_FOUND;
  for (int tries = 0; tries < 100 && st != VX_OK; tries++) { // until it has given procfs its ring
    st = write_file(c, "prof/ctl", "zones on");
    if (st != VX_OK) nap(5);
  }
  CHECK(st == VX_OK);
  CHECK(write_file(c, "prof/ctl", "zones sideways") == VX_ERR_INVALID);
  nap(100);
  alignas(vx_prof_header) static uint8_t ring[VX_PROF_RING];
  size_t got = 0;
  if (vx_ns_open(&ns, proc_path(c, "prof/zones"), P9_OREAD, &f) == VX_OK) {
    while (got < sizeof ring && (n = vx_ns_read(&f, ring + got, (uint32_t)(sizeof ring - got))) > 0)
      got += (size_t)n;
    vx_ns_close(&f);
  }
  const vx_prof_header *h = (const vx_prof_header *)ring;
  CHECK(got >= sizeof *h && h->magic == VX_PROF_MAGIC && h->counter_hz == clock.counter_hz && h->nzones == 1);
  CHECK(got >= sizeof *h && memcmp(h->names[0], "work", 5) == 0);
  size_t records = got > sizeof *h ? (got - sizeof *h) / sizeof(vx_prof_record) : 0;
  CHECK(records >= 5);
  bool ordered = true;
  const vx_prof_record *r = (const vx_prof_record *)(ring + sizeof *h);
  for (size_t i = 0; i < records; i++)
    ordered = ordered && r[i].zone == 1 && r[i].end > r[i].start && (!i || r[i].start >= r[i - 1].start);
  CHECK(ordered);
  // A ring given in another's name: procfs's challenge does not show in
  // that process's memory, whatever the giver wrote in the ring.
  vx_handle vmo = VX_HANDLE_NONE, given = VX_HANDLE_NONE;
  uint64_t at = 0;
  CHECK(vx_vmo_create(VX_PROF_RING, 0, &vmo) == VX_OK &&
        vx_as_map(vx_self, vmo, 0, VX_PROF_RING, VX_MAP_WRITE, &at) == VX_OK &&
        vx_handle_dup(vmo, VX_RIGHTS_SAME, &given) == VX_OK);
  vx_handle_close(vmo);
  vx_prof_header *forged = (vx_prof_header *)at;
  if (forged) forged->magic = VX_PROF_MAGIC, forged->cap = 16;
  proc_msg req = {.h = {.ordinal = PROC_PROF}, .arg = {(int64_t)c, 4096}}, rep = {};
  vx_call call = {.wr_bytes = &req,
                  .wr_len = sizeof req,
                  .wr_handles = &given,
                  .wr_count = 1,
                  .rd_bytes = &rep,
                  .rd_cap = sizeof rep};
  CHECK(vx_channel_call(vx_ns_connector(&ns, VX_STR("/proc")), &call, vx_clock_read() + 2'000'000'000) ==
            VX_OK &&
        (vx_status)(int32_t)rep.h.flags == VX_ERR_ACCESS);
  if (at) vx_as_unmap(vx_self, at, VX_PROF_RING);
  CHECK(write_file(c, "prof/ctl", "zones off") == VX_OK); // its own ring is still the one

  // A ring per thread (M6 step 6d6b): four busy threads of this process's
  // own, each one's records in a ring it claimed, carrying its id; the file
  // has all four, merged by their ends.
  CHECK(vx_prof_init(vx_ns_connector(&ns, VX_STR("/proc"))) == VX_OK);
  CHECK(write_file(me, "prof/ctl", "zones on") == VX_OK);
  static vx_worker busy[4];
  for (int i = 0; i < 4; i++) CHECK(vx_worker_start(&busy[i], zones_thread, nullptr, 0) == VX_OK);
  for (int i = 0; i < 4; i++) vx_worker_join(&busy[i]);
  uint32_t owners[4] = {}, owned = 0;
  bool own = true;
  for (uint32_t i = 1; vx_prof && i <= VX_PROF_THREADS; i++) {
    vx_prof_ring *rg = vx_prof_ring_at(vx_prof, i);
    uint32_t who = atomic_load(&rg->thread);
    uint64_t head = atomic_load(&rg->head);
    if (!who || !head) continue;
    if (owned < 4) owners[owned] = who;
    owned++;
    for (uint64_t k = 0; k < head && k < VX_PROF_CAP; k++)
      own = own && vx_prof_ring_records(rg)[k].thread == who;
    own = own && head >= 50;
  }
  CHECK(owned == 4 && own && owners[0] != owners[1] && owners[2] != owners[3] && owners[0] != owners[3]);
  CHECK(atomic_load(&vx_prof_ring_at(vx_prof, 0)->head) == 0); // none shared
  CHECK(write_file(me, "prof/ctl", "zones off") == VX_OK);
  static uint8_t merged[VX_PROF_RING];
  got = 0;
  if (vx_ns_open(&ns, proc_path(me, "prof/zones"), P9_OREAD, &f) == VX_OK) {
    while (got < sizeof merged && (n = vx_ns_read(&f, merged + got, (uint32_t)(sizeof merged - got))) > 0)
      got += (size_t)n;
    vx_ns_close(&f);
  }
  const vx_prof_record *m = (const vx_prof_record *)(merged + sizeof(vx_prof_header));
  size_t nm = got > sizeof(vx_prof_header) ? (got - sizeof(vx_prof_header)) / sizeof *m : 0;
  bool by_end = nm >= 200;
  uint32_t seen = 0;
  for (size_t i = 0; i < nm; i++) {
    by_end = by_end && (!i || m[i].end >= m[i - 1].end);
    for (uint32_t k = 0; k < 4; k++)
      if (m[i].thread == owners[k]) seen |= 1u << k;
  }
  CHECK(by_end && seen == 0xf);

  // A ring whose header lies about its size: procfs reads it within its own.
  if (vx_prof) {
    vx_prof->cap = 0xffff'ffff;
    atomic_store(&vx_prof->head, 1ull << 40);
  }
  got = 0;
  if (vx_ns_open(&ns, proc_path(me, "prof/zones"), P9_OREAD, &f) == VX_OK) {
    while (got < sizeof ring && (n = vx_ns_read(&f, ring + got, (uint32_t)(sizeof ring - got))) > 0)
      got += (size_t)n;
    vx_ns_close(&f);
  }
  CHECK(got >= sizeof *h && got <= VX_PROF_RING);
  n = read_file(me, "status", buf, sizeof buf); // procfs is still there
  CHECK(n > 0 && has((vx_str){buf, (size_t)n}, "name=proctest"));

  CHECK(write_file(c, "note", "done") == VX_OK);
  n = wait_record(buf, sizeof buf);
  CHECK(n > 0 && has((vx_str){buf, (size_t)n}, "status=done"));
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

  // Identity (6e1c3): its pid, the path svcd ran it from, its user, the
  // machine's name, and its environment.
  char host[64];
  CHECK(vx_pid() == me);
  CHECK(vx_exe_path().len == 18 && !memcmp(vx_exe_path().ptr, "/boot/bin/proctest", 18));
  CHECK(vx_user_name().len == 4 && !memcmp(vx_user_name().ptr, "none", 4));
  CHECK(vx_hostname(&ns, host, sizeof host) == 6 && !memcmp(host, "vectra", 6));
  CHECK(!vx_getenv(VX_STR("NO_SUCH_VARIABLE")).ptr);

  // Its own entry: pid = its task id; its parent is svcd.
  int64_t n = read_file(me, "status", buf, sizeof buf);
  CHECK(n > 0 && has((vx_str){buf, (size_t)n}, "name=proctest") && has((vx_str){buf, (size_t)n}, "pid="));
  n = read_file(me, "ppid", buf, sizeof buf);
  CHECK(n > 0 && number(buf, n) == 1);
  CHECK(wait_record(buf, sizeof buf) == VX_ERR_NO_CHILD);     // no children yet
  CHECK(write_file(1, "note", "hangup") == VX_ERR_ACCESS);    // svcd takes no notes: one would end it
  CHECK(write_file(1, "ctl", "childnotes") == VX_ERR_ACCESS); // nor a child's SIGCHLD, by childnotes
  // procfs itself is as untouchable (the Rust port's finding): stopped, every
  // /proc call after would hang.
  uint64_t procfs = 0;
  for (uint64_t pid = 2; pid < 64 && !procfs; pid++) {
    int64_t k = read_file(pid, "status", buf, sizeof buf);
    if (k > 0 && has((vx_str){buf, (size_t)k}, "name=procfs ")) procfs = pid;
  }
  CHECK(procfs != 0);
  CHECK(write_file(procfs, "ctl", "stop") == VX_ERR_ACCESS &&
        write_file(procfs, "ctl", "kill") == VX_ERR_ACCESS &&
        write_file(procfs, "note", "hangup") == VX_ERR_ACCESS &&
        write_file(procfs, "ctl", "childnotes") == VX_ERR_ACCESS);
  CHECK(read_file(me, "status", buf, sizeof buf) > 0); // and /proc still answers

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

  // A namespace group (ADR-0009): a child shares its parent's, so its bind
  // reaches the parent, whose /proc/N/ns says so, and stays after it has gone.
  p9_client *pc;
  uint32_t fid;
  CHECK(vx_ns_walk(&ns, VX_STR("/n/bin"), &pc, &fid) == VX_ERR_NOT_FOUND); // /n is empty
  CHECK(spawn("bind") != 0);
  n = wait_record(buf, sizeof buf);
  CHECK(n > 0 && has((vx_str){buf, (size_t)n}, "status=\"\""));
  CHECK(vx_ns_walk(&ns, VX_STR("/n/bin"), &pc, &fid) == VX_OK);
  if (pc) p9c_clunk(pc, fid);
  n = read_file(me, "ns", buf, sizeof buf);
  CHECK(n > 0 && has((vx_str){buf, (size_t)n}, "bind /boot /n"));

  test_debug();
  test_prof();
  vx_print(VX_STR("proctest: "));
  vx_print_u64(checks);
  vx_print(VX_STR(" checks, "));
  vx_print_u64(failures);
  vx_print(VX_STR(" failed\n"));
  return failures ? "failed" : nullptr;
}
