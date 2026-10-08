// dbg: the debugger's command line, `dbg -c` (docs/05 §7), for serial
// consoles and bring-up before the desktop exists. It does everything through
// /proc's debug files (05 §3), as acid did, and lib/vx-debug's index and
// evaluator (ADR-0017): the program's ELF is read and indexed when dbg starts.
//
//   dbg -c [-x FILE] PROGRAM [ARG ...]   launch PROGRAM at `run`
//   dbg -c [-x FILE] -p PID              attach to a running process
//   dbg -c [-x FILE] /tmp/crash/NAME.PID open a crash directory (05 §5)
//
// Commands come from the console, or (-x) from FILE, each echoed:
//
//   break FUNC | FILE:LINE | 0xADDR    a breakpoint (before `run`, kept until then)
//   run                                start the program, and wait for an event
//   cont, step                         resume, or step one instruction, and wait
//   bt                                 the call stack, by frame pointers (05 §4)
//   frame N                            choose frame N for print
//   print EXPR                         a C expression at that frame (05 §6.2)
//   regs, info                         the thread's registers; the process's maps and images
//   threads                            every thread: its state, why it stopped, where (M6 step 6d6a)
//   thread N                           make thread N the one commands act on
//   xregs                              the thread's FP/SIMD state: x86_64's XSAVE image, PKRU
//                                      among it; aarch64's V registers
//   kill, quit
//
// When a thread stops with an event, procfs stops the program's other threads
// too, and starts them again with it (all-stop, procfs's debug.c).
//
// A launched program that crashes leaves a crash directory (procfs saves it,
// 05 §5); dbg then turns to it, so bt and print go on working on the dead
// program, with the same code a live one uses.

#include "../lib/vx-rt/rt.c"
#include "../lib/vx-rt/spawn.c"
#include "../lib/vx-ns/spawn.c"
#include "../lib/vx-debug/eval.c"

static vx_ns ns;
static uint8_t image[8 << 20]; // the program's ELF
static size_t image_size;
static uint8_t interp[8 << 20];     // a dynamic program's interpreter (PT_INTERP, ADR-0047), read at run
static uint8_t arena_mem[24 << 20]; // its index is built here
static vxdi ix;
static vxd_elf elf;

static char program[128]; // its path
static size_t program_len;
static vx_str args[16];
static uint32_t nargs;

static uint64_t pid, me;
static char crash_dir[96]; // the crash directory, once the target is one
static bool live, launched;
static uint32_t thread = 1; // the thread commands act on

static vx_regs regs; // the thread's, as it stopped
static bool have_regs;
static vxd_frame frames[64];
static uint32_t nframes, frame;

static uint64_t breaks[32];
static uint32_t nbreaks;

// --- Output ---

static void say(const char *s) { vx_print(vx_cstr(s)); }
static void say_str(vx_str s) { vx_print(s); }
static size_t hex_text_dbg(uint64_t v, char *out);
static void say_hex(uint64_t v) {
  char buf[18];
  vx_print((vx_str){buf, hex_text_dbg(v, buf)});
}

// --- Files ---

// Appends s to the path in buf (len bytes so far), within cap.
static void append(char *buf, size_t *len, size_t cap, vx_str s) {
  for (size_t i = 0; i < s.len && *len + 1 < cap; i++) buf[(*len)++] = s.ptr[i];
  buf[*len] = 0;
}

static void append_u64(char *buf, size_t *len, size_t cap, uint64_t v) {
  char digits[20];
  size_t n = sizeof digits;
  do digits[--n] = (char)('0' + v % 10);
  while (v /= 10);
  append(buf, len, cap, (vx_str){digits + n, sizeof digits - n});
}

// "/proc/PID/file", or the crash directory's file, in a buffer that lasts until the next call.
static vx_str target_path(const char *file) {
  static char path[160];
  size_t len = 0;
  vx_str f = vx_cstr(file);
  if (crash_dir[0]) {
    append(path, &len, sizeof path, vx_cstr(crash_dir));
  } else {
    append(path, &len, sizeof path, VX_STR("/proc/"));
    append_u64(path, &len, sizeof path, pid);
  }
  append(path, &len, sizeof path, VX_STR("/"));
  append(path, &len, sizeof path, f);
  return (vx_str){path, len};
}

static int64_t read_file(vx_str path, void *buf, uint32_t cap) {
  vx_ns_file f;
  vx_status st = vx_ns_open(&ns, path, P9_OREAD, &f);
  if (st != VX_OK) return st;
  int64_t n = vx_ns_read(&f, buf, cap);
  vx_ns_close(&f);
  return n;
}

static vx_status write_file(vx_str path, const char *text) {
  vx_ns_file f;
  vx_status st = vx_ns_open(&ns, path, P9_OWRITE, &f);
  if (st != VX_OK) return st;
  vx_str t = vx_cstr(text);
  int64_t n = vx_ns_write(&f, t.ptr, (uint32_t)t.len);
  vx_ns_close(&f);
  return n < 0 ? (vx_status)n : VX_OK;
}

static vx_status ctl(const char *text) { return write_file(target_path("ctl"), text); }

// A value of key in an ndb record's text (key=value, value perhaps quoted).
static vx_str field(vx_str rec, const char *key) {
  vx_str k = vx_cstr(key);
  for (size_t i = 0; i + k.len < rec.len; i++) {
    if ((i && rec.ptr[i - 1] != ' ') || memcmp(rec.ptr + i, k.ptr, k.len) != 0 || rec.ptr[i + k.len] != '=')
      continue;
    size_t s = i + k.len + 1, e = s;
    if (s < rec.len && rec.ptr[s] == '"') {
      e = ++s;
      while (e < rec.len && rec.ptr[e] != '"') e++;
    } else {
      while (e < rec.len && rec.ptr[e] != ' ' && rec.ptr[e] != '\n') e++;
    }
    return (vx_str){rec.ptr + s, e - s};
  }
  return (vx_str){};
}

// A number, the whole of s: decimal, or 0x and up to 16 hex digits; 0 for
// anything else, which callers take as none (`break 0x40102g` set a
// breakpoint at a wrong address, and said so: the Rust port's finding).
static uint64_t parse_num(vx_str s) {
  bool hex = s.len > 2 && s.ptr[0] == '0' && s.ptr[1] == 'x';
  if (!s.len || (hex && s.len > 18)) return 0;
  uint64_t v = 0;
  for (size_t i = hex ? 2 : 0; i < s.len; i++) {
    uint64_t d = 16;
    if (hex) d = hex_digit_value(s.ptr[i]);
    if (!hex && s.ptr[i] >= '0' && s.ptr[i] <= '9') d = (uint64_t)(s.ptr[i] - '0');
    if (d >= (hex ? 16u : 10u) || (!hex && v > (UINT64_MAX - d) / 10)) return 0;
    v = hex ? v << 4 | d : v * 10 + d;
  }
  return v;
}

// --- The program's memory ---

static size_t hex_text_dbg(uint64_t v, char *out) {
  char d[16];
  size_t n = 0;
  do d[n++] = "0123456789abcdef"[v & 15];
  while (v >>= 4);
  out[0] = '0', out[1] = 'x';
  for (size_t i = 0; i < n; i++) out[2 + i] = d[n - 1 - i];
  return n + 2;
}

static vx_ns_file mem_file;
static bool mem_open;

// Read-only bytes from the ELF image, by its program headers: what a crash
// directory leaves out (05 §5).
static bool read_image(uint64_t addr, void *buf, size_t n) {
  if (image_size < 64) return false;
  uint64_t phoff = elf_u64(image + 32);
  uint16_t phentsize = elf_u16(image + 54), phnum = elf_u16(image + 56);
  for (uint16_t i = 0; i < phnum; i++) {
    uint64_t at;
    if (ckd_add(&at, phoff, (uint64_t)i * phentsize) || at > image_size || image_size - at < 56 ||
        elf_u32(image + at) != 1)
      continue; // PT_LOAD
    uint64_t off = elf_u64(image + at + 8), vaddr = elf_u64(image + at + 16),
             filesz = elf_u64(image + at + 32);
    // All as differences, which cannot wrap: the image and the address may be anything.
    if (off > image_size || filesz > image_size - off || addr < vaddr || addr - vaddr > filesz ||
        n > filesz - (addr - vaddr))
      continue;
    memcpy(buf, image + off + (addr - vaddr), n);
    return true;
  }
  return false;
}

// From a crash directory's mem/0xBASE files: the writable mappings.
static bool read_crash(uint64_t addr, void *buf, size_t n) {
  static struct {
    uint64_t base, size;
  } maps[32];
  static uint32_t nmaps;
  static bool listed;
  if (!listed) { // the mem directory's entries, once
    listed = true;
    vx_ns_file dir;
    static uint8_t ents[4096];
    if (vx_ns_open(&ns, target_path("mem"), P9_OREAD, &dir) == VX_OK) {
      int64_t got = vx_ns_read(&dir, ents, sizeof ents);
      p9_stat e;
      for (size_t off = 0; got > 0 && nmaps < 32 && p9_dir_next(ents, (size_t)got, &off, &e);)
        maps[nmaps].base = parse_num(e.name), maps[nmaps++].size = e.length;
      vx_ns_close(&dir);
    }
  }
  for (uint32_t i = 0; i < nmaps; i++) {
    if (addr < maps[i].base || addr - maps[i].base > maps[i].size || n > maps[i].size - (addr - maps[i].base))
      continue;
    char name[32] = "mem/";
    size_t len = 4 + hex_text_dbg(maps[i].base, name + 4);
    name[len] = 0;
    vx_ns_file f;
    if (vx_ns_open(&ns, target_path(name), P9_OREAD, &f) != VX_OK) return false;
    f.offset = addr - maps[i].base;
    int64_t got = vx_ns_read(&f, buf, (uint32_t)n);
    vx_ns_close(&f);
    return got == (int64_t)n;
  }
  return false;
}

static bool target_read(void *ctx, uint64_t addr, void *buf, size_t n) {
  (void)ctx;
  if (crash_dir[0]) return read_crash(addr, buf, n) || read_image(addr, buf, n);
  if (!mem_open) mem_open = vx_ns_open(&ns, target_path("mem"), P9_OREAD, &mem_file) == VX_OK;
  if (!mem_open) return false;
  mem_file.offset = addr;
  return vx_ns_read(&mem_file, buf, (uint32_t)n) == (int64_t)n;
}

// The innermost frame's registers, by DWARF number.
static bool target_reg(void *ctx, uint32_t dwarf, uint64_t *v) {
  (void)ctx;
  if (!have_regs) return false;
#ifdef __x86_64__
  static const uint8_t ORDER[17] = {0, 3,  2,  1,  4,  5,  6,  7, 8,
                                    9, 10, 11, 12, 13, 14, 15, 16}; // DWARF to vx_regs
  if (dwarf > 16) return false;
  *v = ((const uint64_t *)&regs)[ORDER[dwarf]];
#else
  if (dwarf > 31) return false;
  *v = dwarf == 31 ? regs.sp : regs.x[dwarf];
#endif
  return true;
}

static vxd_target target = {.read = target_read, .reg = target_reg};

// --- Where it is ---

// "FUNC (FILE:LINE)" for a pc.
static void say_where(uint64_t pc) {
  const vxdi_func *f = vxdi_func_at(&ix, pc);
  const vxdi_sym *s = f ? nullptr : vxdi_sym_at(&ix, pc);
  if (f)
    say(vxdi_str(&ix, f->name));
  else
    say(s ? vxdi_str(&ix, s->name) : "??");
  const vxdi_line *l = vxdi_line_at(&ix, pc);
  if (!l) return;
  const char *file = vxdi_file(&ix, l->file);
  if (file[0] == '/' && file[1] == 's' && file[2] == 'r' && file[3] == 'c' && file[4] == '/')
    file += 5; // -ffile-prefix-map's
  say(" (");
  say(file);
  say(":");
  vx_print_u64(l->line);
  say(")");
}

// threads/N/file, N the thread commands act on: the one the last event named.
static const char *thread_file(const char *file) {
  static char path[48];
  size_t len = 0;
  append(path, &len, sizeof path - 1, VX_STR("threads/"));
  append_u64(path, &len, sizeof path - 1, thread);
  append(path, &len, sizeof path - 1, VX_STR("/"));
  append(path, &len, sizeof path - 1, vx_cstr(file));
  path[len] = 0;
  return path;
}

static uint64_t regs_pc(void) {
#ifdef __x86_64__
  return regs.rip;
#else
  return regs.pc;
#endif
}

// The thread's registers and the call stack, as it stopped.
static void fault_thread(void); // below, with the threads

static void refresh(void) {
  nframes = frame = 0;
  have_regs = read_file(target_path(thread_file("regs")), &regs, sizeof regs) == (int64_t)sizeof regs;
  if (!have_regs) return;
#ifdef __x86_64__
  nframes = vxd_unwind(&ix, &target, regs.rip, regs.rsp, regs.rbp, frames, 64);
#else
  nframes = vxd_unwind(&ix, &target, regs.pc, regs.sp, regs.x[29], frames, 64);
#endif
}

// --- Events ---

// Its end: the wait record procfs left for dbg, its parent; and, for a
// crash, its crash directory.
static void ended(void) {
  live = false;
  nframes = frame = 0; // the last stop's stack is no more; a crash's comes from its directory
  have_regs = false;
  if (mem_open) vx_ns_close(&mem_file), mem_open = false; // the pid may be another's soon
  static char rec[512];
  char path[48];
  size_t len = 0;
  append(path, &len, sizeof path, VX_STR("/proc/"));
  append_u64(path, &len, sizeof path, me);
  append(path, &len, sizeof path, VX_STR("/wait"));
  int64_t n = read_file((vx_str){path, len}, rec, sizeof rec - 1);
  vx_str r = {rec, n > 0 ? (size_t)n : 0}, status = field(r, "status"), name = field(r, "name");
  say("dbg: ");
  say_str(name);
  say(" exited");
  if (status.len) say(": "), say_str(status);
  say("\n");
  if (status.len < 9 || memcmp(status.ptr, "sys: trap", 9) != 0) return;
  // A crash: procfs saved it (05 §5).
  char dir[sizeof crash_dir];
  len = 0;
  append(dir, &len, sizeof dir, VX_STR("/tmp/crash/"));
  append(dir, &len, sizeof dir, name);
  append(dir, &len, sizeof dir, VX_STR("."));
  append_u64(dir, &len, sizeof dir, pid);
  memcpy(crash_dir, dir, len + 1);
  char note[128];
  int64_t got = read_file(target_path("note"), note, sizeof note);
  if (got <= 0) {
    crash_dir[0] = 0;
    return;
  }
  say("dbg: crash directory ");
  say(crash_dir);
  say("\n");
  fault_thread();
  refresh();
}

// Waits for the next debug event, and says where it stopped.
static void wait_event(void) {
  static char rec[256];
  int64_t n = read_file(target_path("events"), rec, sizeof rec - 1);
  if (n <= 0) { // the process has gone
    if (mem_open) vx_ns_close(&mem_file), mem_open = false;
    ended();
    return;
  }
  vx_str r = {rec, (size_t)n}, kind = field(r, "event"), pc = field(r, "pc"), addr = field(r, "addr");
  thread = (uint32_t)parse_num(field(r, "thread"));
  if (!thread) thread = 1;
  say("dbg: stopped: ");
  say_str(kind);
  if (addr.len) say(" addr="), say_str(addr);
  say(" at ");
  say_where(parse_num(pc));
  say("\n");
  refresh();
}

// --- Commands ---

// A breakpoint's address: a function's body, a file:line's first statement, or a number.
static uint64_t resolve(vx_str spec) {
  char text[96];
  if (!spec.len || spec.len >= sizeof text) return 0;
  memcpy(text, spec.ptr, spec.len), text[spec.len] = 0;
  if (text[0] >= '0' && text[0] <= '9') return parse_num(spec);
  for (size_t i = 0; i < spec.len; i++)
    if (text[i] == ':') {
      text[i] = 0;
      return vxdi_line_addr(&ix, text, (uint32_t)parse_num((vx_str){text + i + 1, spec.len - i - 1}));
    }
  const vxdi_func *f = vxdi_func_named(&ix, text);
  return f ? f->body : 0;
}

static vx_status set_break(uint64_t addr) {
  char cmd[32] = "break ";
  size_t n = 6 + hex_text_dbg(addr, cmd + 6);
  cmd[n] = 0;
  return ctl(cmd);
}

static vx_status set_breaks(void *ctx, uint64_t child) { // vx_spawn_args.registered
  (void)ctx;
  pid = child;
  for (uint32_t i = 0; i < nbreaks; i++) {
    vx_status st = set_break(breaks[i]);
    if (st != VX_OK) return st;
  }
  return VX_OK;
}

static void run(void) {
  if (live) return say("dbg: already running\n");
  vx_handle handles[VX_CHANNEL_MAX_HANDLES - 1];
  vx_str names[VX_CHANNEL_MAX_HANDLES - 1];
  uint32_t count = 0;
  static char records[8 * 1024];
  vx_ndb_writer rec = {.buf = records, .cap = sizeof records};
  for (uint32_t i = 0; i < nargs; i++) {
    vx_ndb_put(&rec, "arg", args[i]);
    vx_ndb_end(&rec);
  }
  if (vx_ns_spawn_records(&ns, &rec, handles, names, &count, VX_CHANNEL_MAX_HANDLES - 4) != VX_OK)
    return say("dbg: cannot give the program a namespace\n");
  if (vx_console.connector && vx_handle_dup(vx_console.connector, VX_RIGHTS_SAME, &handles[count]) == VX_OK)
    names[count++] = VX_STR("console");
  vx_str ip = {};
  size_t ip_len = 0;
  if (vx_elf_interp(image, image_size, &ip) &&
      (vx_ns_read_all(&ns, ip, interp, sizeof interp, &ip_len) != VX_OK || !ip_len)) {
    for (uint32_t i = 0; i < count; i++) vx_handle_close(handles[i]);
    return say("dbg: cannot read the program's interpreter\n");
  }
  vx_str base = {program, program_len};
  for (size_t i = base.len; i-- > 0;)
    if (base.ptr[i] == '/') base = (vx_str){base.ptr + i + 1, base.len - i - 1};
  vx_spawn_args a = {.name = {base.ptr, vx_utf_cut(base.ptr, base.len, 23)},
                     .image = image,
                     .image_size = image_size,
                     .interp = ip_len ? interp : nullptr,
                     .interp_size = ip_len,
                     .handles = handles,
                     .handle_names = names,
                     .handle_count = count,
                     .records = {records, rec.len},
                     .proc =
                         vx_ns_connector(&ns, VX_STR("/proc")), // dbg is its parent: it gets the wait record
                     .registered = set_breaks};
  vx_handle task;
  if (vx_spawn_elf(&a, &task) != VX_OK) { // set_breaks may have named it: not a program, then
    pid = 0;
    return say("dbg: cannot start the program\n");
  }
  vx_handle_close(task); // procfs watches it
  live = launched = true;
  // Opening events makes procfs its debugger: faults stop it with an event.
  wait_event();
}

static void bt(void) {
  if (!nframes) return say("dbg: no stack\n");
  for (uint32_t i = 0; i < nframes; i++) {
    say(i == frame ? "*#" : " #");
    vx_print_u64(i);
    say(" ");
    say_hex(frames[i].pc);
    say(" in ");
    say_where(vxd_frame_lookup_pc(&frames[i]));
    say("\n");
  }
}

static void print(vx_str expr) {
  if (!nframes) return say("dbg: not stopped\n");
  char text[256];
  if (expr.len >= sizeof text) return say("dbg: too long\n");
  memcpy(text, expr.ptr, expr.len), text[expr.len] = 0;
  vxd_session s;
  vxd_begin(&s, &ix, &target, &frames[frame]);
  vxd_value v;
  if (!vxd_eval(&s, text, &v)) {
    say("dbg: ");
    say(s.err ? s.err : "cannot evaluate");
    say("\n");
    return;
  }
  static char out[512];
  vxd_format(&s, &v, out, sizeof out);
  say("= ");
  say(out);
  say("\n");
}

// threads/N/status's record, for thread n, into buf: its length, or 0.
static size_t thread_status(uint64_t n, char *buf, uint32_t cap) {
  char path[48];
  size_t len = 0;
  append(path, &len, sizeof path - 1, VX_STR("threads/"));
  append_u64(path, &len, sizeof path - 1, n);
  append(path, &len, sizeof path - 1, VX_STR("/status"));
  path[len] = 0;
  int64_t got = read_file(target_path(path), buf, cap);
  return got > 0 ? (size_t)got : 0;
}

// The thread that faulted, in a crash directory (its status's reason=fault),
// for the commands to act on, not thread 1 (the Rust port's finding).
static void fault_thread(void) {
  vx_ns_file d;
  if (vx_ns_open(&ns, target_path("threads"), P9_OREAD, &d) != VX_OK) return;
  static uint8_t dir[8192];
  for (int64_t n; (n = vx_ns_read(&d, dir, sizeof dir)) > 0;) {
    p9_stat st;
    for (size_t at = 0; p9_dir_next(dir, (size_t)n, &at, &st);) {
      uint64_t tid = parse_num(st.name);
      char rec[256];
      vx_str reason = field((vx_str){rec, thread_status(tid, rec, sizeof rec)}, "reason");
      if (tid && reason.len == 5 && !memcmp(reason.ptr, "fault", 5)) thread = (uint32_t)tid;
    }
  }
  vx_ns_close(&d);
}

static void threads(void) {
  vx_ns_file d;
  if (vx_ns_open(&ns, target_path("threads"), P9_OREAD, &d) != VX_OK) return say("dbg: no threads\n");
  static uint8_t dir[8192];
  uint32_t all = 0, stopped = 0;
  for (int64_t n; (n = vx_ns_read(&d, dir, sizeof dir)) > 0;) {
    p9_stat st;
    for (size_t at = 0; p9_dir_next(dir, (size_t)n, &at, &st);) {
      uint64_t tid = parse_num(st.name);
      char rec[256];
      size_t len = thread_status(tid, rec, sizeof rec);
      vx_str r = {rec, len}, state = field(r, "state"), reason = field(r, "reason");
      all++;
      bool still = (state.len == 7 && !memcmp(state.ptr, "stopped", 7)) ||
                   (state.len == 6 && !memcmp(state.ptr, "frozen", 6));
      stopped += still;
      say(tid == thread ? " *" : "  ");
      vx_print_u64(tid);
      say(" ");
      say_str(state);
      if (reason.len) say(" "), say_str(reason);
      uint64_t pc = parse_num(field(r, "pc"));
      if (pc) say(" at "), say_where(pc);
      say("\n");
    }
  }
  vx_ns_close(&d);
  say("dbg: ");
  vx_print_u64(all);
  say(" threads, ");
  vx_print_u64(stopped);
  say(" stopped\n");
}

static void say_bytes(const uint8_t *p, size_t n) { // as one number, the last byte first
  static const char HEX[] = "0123456789abcdef";
  char out[130];
  size_t k = 0;
  for (size_t i = n; i-- > 0 && k + 2 < sizeof out;) out[k++] = HEX[p[i] >> 4], out[k++] = HEX[p[i] & 15];
  say("0x"), say_str((vx_str){out, k});
}

static void say_reg(const char *name, uint32_t i, const uint8_t *p, size_t n) {
  say(name);
  if (i != UINT32_MAX) vx_print_u64(i);
  say("=");
  say_bytes(p, n);
  say("\n");
}

#ifdef __x86_64__
// Where XSAVE's standard image keeps component c (CPUID leaf 0xD).
static uint32_t xsave_offset(uint32_t c) {
  uint32_t a = 0xd, b, cx = c, d;
  __asm__ volatile("cpuid" : "+a"(a), "=b"(b), "+c"(cx), "=d"(d));
  return b;
}
#endif

// The thread's whole FP/SIMD state (threads/N/xregs, ADR-0035).
static void xregs(void) {
  static uint8_t x[64 * 1024];
  int64_t n = read_file(target_path(thread_file("xregs")), x, sizeof x);
  if (n <= 0) return say("dbg: no state: is the thread stopped?\n");
#ifdef __x86_64__
  if (n < 576) return say("dbg: a short XSAVE image\n");
  uint32_t mxcsr;
  uint64_t bv, features = vx_cpu()->xfeatures;
  memcpy(&mxcsr, x + 24, 4), memcpy(&bv, x + 512, 8);
  say("mxcsr="), say_hex(mxcsr), say(" xstate_bv="), say_hex(bv), say(" xcr0="), say_hex(features), say("\n");
  uint32_t ymm = features & 4 ? xsave_offset(2) : 0;
  for (uint32_t i = 0; i < 16; i++) {
    uint8_t v[32];
    memcpy(v, x + 160 + (size_t)16 * i, 16);
    if (ymm && ymm + 16 * (i + 1) <= (uint64_t)n) memcpy(v + 16, x + ymm + (size_t)16 * i, 16);
    say_reg(ymm ? "ymm" : "xmm", i, v, ymm ? 32 : 16);
  }
  if (features & 0x20) { // AVX-512's opmasks
    uint32_t k = xsave_offset(5);
    for (uint32_t i = 0; i < 8 && k + 8 * (i + 1) <= (uint64_t)n; i++)
      say_reg("k", i, x + k + (size_t)8 * i, 8);
  }
  if (features & 0x200) { // PKRU: the thread's protection-key rights (ADR-0035)
    uint32_t at = xsave_offset(9), pkru = 0;
    if ((bv & 0x200) && at + 4 <= (uint64_t)n) memcpy(&pkru, x + at, 4); // not in use: its first value, 0
    say("pkru="), say_hex(pkru), say("\n");
  } else {
    say("pkru: none (no protection keys)\n");
  }
#else
  if ((size_t)n < sizeof(vx_fpregs)) return say("dbg: a short state\n");
  const vx_fpregs *f = (const vx_fpregs *)x;
  say("fpcr="), say_hex(f->fpcr), say(" fpsr="), say_hex(f->fpsr), say("\n");
  for (uint32_t i = 0; i < 32; i++) say_reg("v", i, f->v[i], 16);
  say("por_el0: none (no protection keys)\n");
#endif
}

static void show(const char *file) {
  static char text[4096];
  int64_t n = read_file(target_path(file), text, sizeof text);
  if (n > 0) say_str((vx_str){text, (size_t)n});
}

static bool word_is(vx_str w, const char *s) {
  vx_str t = vx_cstr(s);
  return w.len == t.len && memcmp(w.ptr, t.ptr, t.len) == 0;
}

// One command; false to quit.
static bool command(vx_str line) {
  while (line.len && (line.ptr[line.len - 1] == '\n' || line.ptr[line.len - 1] == ' ')) line.len--;
  size_t i = 0;
  while (i < line.len && line.ptr[i] == ' ') i++;
  size_t w = i;
  while (w < line.len && line.ptr[w] != ' ') w++;
  vx_str verb = {line.ptr + i, w - i}, rest = {line.ptr + w, line.len - w};
  while (rest.len && rest.ptr[0] == ' ') rest.ptr++, rest.len--;
  if (!verb.len || verb.ptr[0] == '#') return true;
  if (word_is(verb, "quit")) return false;
  if (word_is(verb, "break")) {
    uint64_t addr = resolve(rest);
    if (!addr) return say("dbg: no such function or line\n"), true;
    if (live && set_break(addr) != VX_OK) return say("dbg: cannot set it\n"), true;
    if (!live && nbreaks == sizeof breaks / sizeof breaks[0])
      return say("dbg: too many breakpoints before run\n"), true;
    if (!live) breaks[nbreaks++] = addr;
    say("dbg: breakpoint at ");
    say_hex(addr);
    say(" in ");
    say_where(addr);
    say("\n");
  } else if (word_is(verb, "run")) {
    if (crash_dir[0] || pid)
      say("dbg: not a program to launch\n");
    else
      run();
  } else if (word_is(verb, "cont") || word_is(verb, "continue")) {
    if (!live) return say("dbg: not running\n"), true;
    ctl("start");
    wait_event();
  } else if (word_is(verb, "step")) {
    if (!live) return say("dbg: not running\n"), true;
    char path[32] = "threads/";
    size_t n = 8;
    char d[12];
    size_t k = sizeof d;
    uint64_t v = thread;
    do d[--k] = (char)('0' + v % 10);
    while (v /= 10);
    memcpy(path + n, d + k, sizeof d - k), n += sizeof d - k;
    memcpy(path + n, "/ctl", 5);
    write_file(target_path(path), "step");
    wait_event();
  } else if (word_is(verb, "bt") || word_is(verb, "where")) {
    bt();
  } else if (word_is(verb, "frame")) {
    uint32_t n = (uint32_t)parse_num(rest);
    if (n >= nframes) return say("dbg: no such frame\n"), true;
    frame = n;
    say(" #");
    vx_print_u64(n);
    say(" in ");
    say_where(vxd_frame_lookup_pc(&frames[n]));
    say("\n");
  } else if (word_is(verb, "print") || word_is(verb, "p")) {
    print(rest);
  } else if (word_is(verb, "regs")) {
    show(thread_file("regs.ndb"));
  } else if (word_is(verb, "xregs")) {
    xregs();
  } else if (word_is(verb, "threads")) {
    threads();
  } else if (word_is(verb, "thread")) {
    uint64_t n = parse_num(rest);
    char rec[256];
    if (!n || !thread_status(n, rec, sizeof rec)) return say("dbg: no such thread\n"), true;
    thread = (uint32_t)n;
    refresh();
    say("dbg: thread ");
    vx_print_u64(n);
    if (have_regs) say(" at "), say_where(regs_pc());
    say("\n");
  } else if (word_is(verb, "info")) {
    show("images");
    show("maps");
  } else if (word_is(verb, "kill")) {
    if (live) ctl("kill"), wait_event();
  } else {
    say("dbg: break, run, cont, step, bt, frame, print, regs, xregs, threads, thread, info, kill, quit\n");
  }
  return true;
}

// The program's ELF, read whole, and its index.
static bool load(vx_str path) {
  vx_ns_file f;
  if (vx_ns_open(&ns, path, P9_OREAD, &f) != VX_OK) return false;
  int64_t n;
  image_size = 0;
  while (image_size < sizeof image &&
         (n = vx_ns_read(&f, image + image_size, (uint32_t)(sizeof image - image_size))) > 0)
    image_size += (size_t)n;
  uint8_t more;
  bool whole = !(image_size == sizeof image && vx_ns_read(&f, &more, 1) > 0);
  vx_ns_close(&f);
  if (!whole) { // never indexed, or launched, cut short
    say("dbg: the program is larger than dbg can load (8 MiB)\n");
    return false;
  }
  vxd_arena arena = {.buf = arena_mem, .cap = sizeof arena_mem};
  const vxdi_header *h = vxd_elf_open(&elf, image, image_size) ? vxd_index(&elf, &arena) : nullptr;
  if (!h || !vxdi_open(&ix, h, h->size)) return false;
  target.machine = elf.machine;
  return true;
}

// The program's path, from a process's (or a crash directory's) images: its
// name, in /boot/bin.
static bool load_named(void) {
  char rec[256] = {};
  int64_t n = read_file(target_path("images"), rec, sizeof rec);
  vx_str name = field((vx_str){rec, n > 0 ? (size_t)n : 0}, "name");
  if (!name.len || name.len > 64) return false;
  program_len = 0;
  append(program, &program_len, sizeof program, VX_STR("/boot/bin/"));
  append(program, &program_len, sizeof program, name);
  return load((vx_str){program, program_len});
}

const char *vx_main(void) {
  if (vx_ns_from_spawn(&ns) != VX_OK) return "no namespace";
  vx_task_summary info;
  if (vx_task_info(vx_self, &info) == VX_OK) me = info.id;
  uint32_t a = 0;
  vx_str script = {};
  if (a < vx_spawn.argc && word_is(vx_spawn.args[a], "-c"))
    a++; // the command line: the only face dbg has yet
  if (a + 1 < vx_spawn.argc && word_is(vx_spawn.args[a], "-x")) script = vx_spawn.args[a + 1], a += 2;
  if (a >= vx_spawn.argc) {
    say(VX_USAGE), say("\n");
    return "usage";
  }
  vx_str target_arg = vx_spawn.args[a];
  bool ok;
  if (word_is(target_arg, "-p") && a + 1 < vx_spawn.argc) { // attach
    pid = parse_num(vx_spawn.args[a + 1]);
    live = true;
    ok = load_named();
  } else if (target_arg.len > 11 && memcmp(target_arg.ptr, "/tmp/crash/", 11) == 0) { // a crash directory
    if (target_arg.len >= sizeof crash_dir) return "path too long";
    memcpy(crash_dir, target_arg.ptr, target_arg.len);
    ok = load_named();
    if (ok) fault_thread(), refresh();
  } else { // a program to launch
    if (target_arg.len >= sizeof program) return "path too long";
    memcpy(program, target_arg.ptr, target_arg.len), program_len = target_arg.len;
    for (uint32_t i = a + 1; i < vx_spawn.argc && nargs < 16; i++) args[nargs++] = vx_spawn.args[i];
    ok = load((vx_str){program, program_len});
  }
  if (!ok) {
    say("dbg: cannot read the program's symbols\n");
    return "no symbols";
  }
  say("dbg: ");
  say_str((vx_str){program, program_len});
  say(": ");
  vx_print_u64(ix.h->funcs.count);
  say(" functions, ");
  vx_print_u64(ix.h->lines.count);
  say(" lines\n");
  // Commands: from the script, or the console.
  static char text[16 * 1024];
  size_t len = 0;
  vx_ns_file f;
  bool from_script = script.len && vx_ns_open(&ns, script, P9_OREAD, &f) == VX_OK;
  if (script.len && !from_script) return "cannot read the script";
  if (from_script) {
    int64_t n;
    while (len < sizeof text && (n = vx_ns_read(&f, text + len, (uint32_t)(sizeof text - len))) > 0)
      len += (size_t)n;
    vx_ns_close(&f);
    for (size_t at = 0; at < len;) {
      size_t e = at;
      while (e < len && text[e] != '\n') e++;
      say("(dbg) ");
      say_str((vx_str){text + at, e - at});
      say("\n");
      if (!command((vx_str){text + at, e - at})) break;
      at = e + 1;
    }
  } else {
    for (;;) {
      say("(dbg) ");
      int64_t n = vx_read(text, sizeof text);
      if (n <= 0 || !command((vx_str){text, (size_t)n})) break;
    }
  }
  if (live && launched)
    ctl("kill"); // what dbg launched does not outlive it
  else if (live)
    ctl("detach");
  return nullptr;
}
