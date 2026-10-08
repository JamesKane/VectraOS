// trace: the kernel's trace (20 §7, ADR-0049), as 9front's trace(1) shows
// its own: a capture, and records as text.
//
//   trace -c CATS [-t DURATION] [-o FILE]   start, wait (ms, s or m; 1s), stop, save the events
//   trace -p [FILE]                         the events (live, or a saved FILE) as ndb, one a line

#include "../lib/vx-rt/rt.c"
#include "../lib/vx-ns/nsapi.c"

static const char *const KINDS[] = {
    "",           "switch",      "wake",    "block",   "call",  "reply",      "donate",
    "return",     "irq_in",      "irq_out", "timer",   "fault", "pager_wait", "pager_done",
    "futex_wait", "futex_woken", "sys_in",  "sys_out", "mark"};

static const char *fail(const char *what, vx_str path) {
  vx_eprintf("trace: %s %.*s: %.*s\n", what, VX_FMT(path), VX_FMT(vx_errstr()));
  return what;
}

// A duration: digits, then ms, s (the default) or m.
static bool duration(vx_str s, vx_duration *out) {
  uint64_t mult = 1'000'000'000;
  if (vx_str_suffix(s, VX_STR("ms")))
    mult = 1'000'000, s.len -= 2;
  else if (vx_str_suffix(s, VX_STR("s")))
    s.len -= 1;
  else if (vx_str_suffix(s, VX_STR("m")))
    mult = 60'000'000'000, s.len -= 1;
  uint64_t n;
  if (!vx_str_u64(s, &n)) return false;
  *out = (vx_duration)(n * mult);
  return true;
}

static void print_record(const vx_trace_record *r) {
  const char *kind = r->kind < sizeof KINDS / sizeof KINDS[0] ? KINDS[r->kind] : "";
  vx_printf("time=%llu cpu=%u task=%u thread=%u kind=%s", (unsigned long long)r->time, r->cpu, r->tid >> 12,
            r->tid & 0xfff, *kind ? kind : "unknown");
  if (r->kind == VX_TK_MARK) {
    char text[17] = {};
    memcpy(text, &r->a, 16);
    vx_printf(" text=\"%s\"\n", text);
  } else if (r->kind == VX_TK_SWITCH || r->kind == VX_TK_WAKE || r->kind == VX_TK_DONATE) {
    vx_printf(" a.task=%u a.thread=%u", (uint32_t)r->a >> 12, (uint32_t)r->a & 0xfff);
    if (r->kind == VX_TK_SWITCH) vx_printf(" state=%u", (uint32_t)(r->a >> 32));
    vx_printf(" b.task=%u b.thread=%u\n", (uint32_t)r->b >> 12, (uint32_t)r->b & 0xfff);
  } else {
    vx_printf(" a=0x%llx b=0x%llx\n", (unsigned long long)r->a, (unsigned long long)r->b);
  }
}

static const char *print(vx_str path) {
  vx_fd fd = vx_open(path, VX_OREAD);
  if (fd < 0) return fail("open", path);
  alignas(vx_trace_record) static uint8_t buf[64 * 1024]; // records are read in place
  size_t have = 0;
  int64_t n;
  while ((n = vx_read(fd, (vx_bytes){buf + have, sizeof buf - have})) > 0) {
    have += (size_t)n;
    size_t whole = have / sizeof(vx_trace_record) * sizeof(vx_trace_record);
    for (size_t at = 0; at < whole; at += sizeof(vx_trace_record))
      print_record((const vx_trace_record *)(buf + at));
    memmove(buf, buf + whole, have - whole);
    have -= whole;
  }
  vx_close(fd);
  return n < 0 ? fail("read", path) : nullptr;
}

static const char *capture(vx_str cats, vx_duration wait, vx_str out) {
  if (vx_ctl(VX_STR("/proc/trace/ctl"), "start %.*s", VX_FMT(cats)) != VX_OK) return fail("start", cats);
  vx_sleep_until(vx_now() + wait, wait / 100);
  if (vx_ctl(VX_STR("/proc/trace/ctl"), "stop") != VX_OK) return fail("stop", VX_STR("/proc/trace/ctl"));
  vx_fd in = vx_open(VX_STR("/proc/trace/events"), VX_OREAD);
  if (in < 0) return fail("open", VX_STR("/proc/trace/events"));
  vx_fd fd = vx_create(out, VX_OWRITE, 0644);
  if (fd < 0) return fail("create", out);
  static uint8_t buf[64 * 1024];
  int64_t n, total = 0;
  while ((n = vx_read(in, (vx_bytes){buf, sizeof buf})) > 0) {
    if (vx_write(fd, (vx_str){(const char *)buf, (size_t)n}) != n) return fail("write", out);
    total += n;
  }
  vx_close(fd);
  vx_close(in);
  vx_eprintf("trace: %lld records in %.*s\n", (long long)(total / (int64_t)sizeof(vx_trace_record)),
             VX_FMT(out));
  return n < 0 ? fail("read", VX_STR("/proc/trace/events")) : nullptr;
}

const char *vx_main(void) {
  vx_strs args = vx_args();
  vx_str cats = {}, out = VX_STR("trace.out"), file = VX_STR("/proc/trace/events");
  vx_duration wait = 1'000'000'000;
  bool p = false;
  for (size_t i = 1; i < args.len; i++) {
    vx_str a = args.ptr[i];
    if (vx_str_eq(a, VX_STR("-p"))) {
      p = true;
      if (i + 1 < args.len) file = args.ptr[++i];
    } else if (vx_str_eq(a, VX_STR("-c")) && i + 1 < args.len) {
      cats = args.ptr[++i];
    } else if (vx_str_eq(a, VX_STR("-t")) && i + 1 < args.len) {
      if (!duration(args.ptr[++i], &wait)) return "usage";
    } else if (vx_str_eq(a, VX_STR("-o")) && i + 1 < args.len) {
      out = args.ptr[++i];
    } else {
      vx_eprintf("%s\n", VX_USAGE);
      return "usage";
    }
  }
  if (p) return print(file);
  if (!cats.len) {
    vx_eprintf("%s\n", VX_USAGE);
    return "usage";
  }
  return capture(cats, wait, out);
}
