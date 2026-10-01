// panic.c: console output, the kernel's symbol map, backtraces and panic.

// The kernel prints through kput. Each CPU builds its line in its own buffer and
// prints it whole, after a timestamp (time.c), under the console lock, so lines
// from different CPUs never interleave. A line longer than the buffer goes out
// in pieces. Kernel code never moves to another CPU halfway through a line.
//
// User threads print through debug_write (console_user_write), and they can
// move between CPUs between two calls, so each thread has a line buffer of its
// own, and a line goes out whole when it ends (or fills the buffer).
//
// Everything printed is kept in the kernel log, kmesg, a ring of the latest
// output. It also goes to the console device until a user-space driver is
// given that device (device.c); from then on the device is the driver's, and
// the kernel writes to it again only to report a panic.
static struct {
  char buf[512];
  size_t len;
} console_line[MAX_CPUS];

static spinlock console_lock;
static _Atomic bool panicking;
static bool console_handed_off; // a driver has the console's device (device.c)

static struct {
  char buf[16 * 1024];
  uint64_t written; // in all; the ring holds the last sizeof buf bytes
} kmesg;

// Writes to the log, and to the device while it is the kernel's. Called with
// the console lock held.
static void console_emit(vx_str s) {
  for (size_t i = 0; i < s.len; i++) kmesg.buf[kmesg.written++ % sizeof kmesg.buf] = s.ptr[i];
  if (!console_handed_off || atomic_load_explicit(&panicking, memory_order_relaxed)) arch_console_write(s);
}

static void console_flush(void) {
  typeof(console_line[0]) *line = &console_line[arch_cpu_index()];
  spin_lock(&console_lock);
  kput_stamp();
  console_emit((vx_str){line->buf, line->len});
  spin_unlock(&console_lock);
  line->len = 0;
}

static void kput(vx_str s) {
  typeof(console_line[0]) *line = &console_line[arch_cpu_index()];
  for (size_t i = 0; i < s.len; i++) {
    line->buf[line->len++] = s.ptr[i];
    if (s.ptr[i] == '\n' || line->len == sizeof line->buf) console_flush();
  }
}

// One debug_write call's bytes, into the writing thread's line buffer.
static void console_user_write(vx_str s, char *buf, size_t cap, uint8_t *len) {
  for (size_t i = 0; i < s.len; i++) {
    buf[(*len)++] = s.ptr[i];
    if (s.ptr[i] != '\n' && *len < cap) continue;
    spin_lock(&console_lock);
    kput_stamp();
    console_emit((vx_str){buf, *len});
    spin_unlock(&console_lock);
    *len = 0;
  }
}

static void kput_cstr(const char *s) {
  size_t n = 0;
  while (s[n]) n++;
  kput((vx_str){s, n});
}

static void kput_u64(uint64_t v) {
  char buf[20];
  size_t i = sizeof buf;
  do {
    buf[--i] = (char)('0' + v % 10);
    v /= 10;
  } while (v);
  kput((vx_str){buf + i, sizeof buf - i});
}

static void kput_hex(uint64_t v) {
  char buf[18] = {'0', 'x'};
  size_t n = 2;
  int shift = 60;
  while (shift > 0 && ((v >> shift) & 0xf) == 0) shift -= 4;
  for (; shift >= 0; shift -= 4) buf[n++] = "0123456789abcdef"[(v >> shift) & 0xf];
  kput((vx_str){buf, n});
}

// The symbol map, which build links into .rodata (05 §4): for each function, in
// address order, a little-endian u64 address and its NUL-terminated name, then
// an address of all ones. The entries are not aligned.
extern const uint8_t vx_symbols[];

static uint64_t read_u64_unaligned(const uint8_t *p) {
  uint64_t v = 0;
  for (int i = 7; i >= 0; i--) v = v << 8 | p[i];
  return v;
}

// The function containing pc, or a zero vx_str if there is none.
static vx_str symbol_for(uint64_t pc, uint64_t *offset) {
  vx_str best = {};
  for (const uint8_t *p = vx_symbols;;) {
    uint64_t addr = read_u64_unaligned(p);
    if (addr == UINT64_MAX || addr > pc) break;
    const char *name = (const char *)p + 8;
    size_t n = 0;
    while (name[n]) n++;
    best = (vx_str){name, n};
    *offset = pc - addr;
    p += 8 + n + 1;
  }
  return best;
}

static void kput_frame(int index, uint64_t pc, uint64_t lookup) {
  kput(VX_STR("  #"));
  kput_u64((uint64_t)index);
  kput(VX_STR(" "));
  kput_hex(pc);
  uint64_t offset = 0;
  vx_str name = symbol_for(lookup, &offset);
  if (name.len) {
    kput(VX_STR(" "));
    kput(name);
    kput(VX_STR("+"));
    kput_hex(offset + (pc - lookup));
  }
  kput(VX_STR("\n"));
}

// Walks the frame-pointer chain (05 §4). On both architectures a frame holds
// the caller's frame pointer, then the return address. The walk stops at a
// null, misaligned or lower-half pointer, or one that does not move up the stack.
static void backtrace(uint64_t pc, uint64_t fp) {
  int i = 0;
  if (pc) kput_frame(i++, pc, pc);
  for (; i < 32 && fp && !(fp & 7) && (int64_t)fp < 0; i++) {
    const uint64_t *frame = (const uint64_t *)fp;
    uint64_t ret = frame[1];
    if (!ret) break;
    kput_frame(i, ret, ret - 1); // ret - 1 is inside the call, even at a function's end
    if (frame[0] <= fp) break;
    fp = frame[0];
  }
}

// Starts a panic message: "vx: panic: " and whatever the caller adds with kput.
static void panic_start(void) {
  if (atomic_exchange(&panicking, true)) arch_halt(); // a fault inside a panic, or two CPUs at once: stop

  if (console_line[arch_cpu_index()].len) kput(VX_STR("\n"));
  kput(VX_STR("vx: panic: "));
}

// Ends the message, prints the backtrace from pc and fp, and stops this CPU.
[[noreturn]] static void panic_end(uint64_t pc, uint64_t fp) {
  kput(VX_STR("\n"));
  backtrace(pc, fp);
  arch_halt();
}

[[noreturn]] static void panic(vx_str why) {
  panic_start();
  kput(why);
  panic_end(0, (uint64_t)__builtin_frame_address(0));
}

[[noreturn]] void __stack_chk_fail(void) { panic(VX_STR("stack protector tripped")); }
