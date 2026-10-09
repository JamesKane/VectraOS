// trace: the kernel's trace (20 §7, ADR-0049), as 9front's trace(1) shows
// its own: a capture, and records as text.
//
//   trace -c CATS [-t DURATION] [-o FILE]   start, wait (ms, s or m; 1s), stop, save the events
//   trace -p [FILE]                         the events (live, or a saved FILE) as ndb, one a line
//   trace -s [-n N] [FILE]                  a summary (20 §5): the N slowest flows (10), each with
//                                           its parts, and the N longest blocks and what woke them

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
  vx_printf("time=%llu cpu=%u task=%u thread=%u", (unsigned long long)r->time, r->cpu, r->tid >> 12,
            r->tid & 0xfff);
  if (r->kind != VX_TK_SPAN) vx_printf(" kind=%s", *kind ? kind : "unknown");
  if (r->kind == VX_TK_MARK) {
    char text[17] = {};
    memcpy(text, &r->a, 16);
    vx_printf(" text=\"%s\"\n", text);
  } else if (r->kind == VX_TK_SPAN) { // a process's (20 §5): task is its pid
    vx_printf(" kind=span flow=0x%llx type=%u cycles=%llu\n", (unsigned long long)r->a,
              (uint32_t)(r->b >> 48), (unsigned long long)(r->b & 0xffff'ffff'ffff));
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

// --- The summary (-s) ---

// Every record of path, into a: *n of them.
static const vx_trace_record *load(vx_str path, vx_arena *a, size_t *n) {
  vx_fd fd = vx_open(path, VX_OREAD);
  if (fd < 0) return nullptr;
  size_t cap = 1 << 20, have = 0; // records; the arena's reservation is lazy
  vx_trace_record *r = vx_push(a, cap * sizeof *r, alignof(vx_trace_record));
  int64_t got = 0;
  while (r && have < cap * sizeof *r &&
         (got = vx_read(fd, (vx_bytes){(uint8_t *)r + have, cap * sizeof *r - have})) > 0)
    have += (size_t)got;
  vx_close(fd);
  *n = have / sizeof *r;
  return got < 0 ? nullptr : r;
}

// The cycle counter's frequency, from /proc/trace/status: 0 if it cannot say.
static uint64_t counter_hz(void) {
  static char buf[4096];
  vx_fd fd = vx_open(VX_STR("/proc/trace/status"), VX_OREAD);
  int64_t n = fd >= 0 ? vx_read(fd, (vx_bytes){(uint8_t *)buf, sizeof buf - 1}) : -1;
  if (fd >= 0) vx_close(fd);
  uint64_t hz = 0;
  for (int64_t i = 0; i + 3 < n && !hz; i++)
    if ((i == 0 || buf[i - 1] == ' ' || buf[i - 1] == '\n') && !memcmp(buf + i, "hz=", 3)) {
      size_t j = (size_t)i + 3;
      while (j < (size_t)n && buf[j] >= '0' && buf[j] <= '9') hz = hz * 10 + (uint64_t)(buf[j++] - '0');
    }
  return hz;
}

static uint64_t hz;

// A length in cycles, as key.us=N: microseconds if the frequency is known,
// key.cycles=N if not.
static void print_length(const char *key, uint64_t cycles) {
  if (hz)
    vx_printf(" %s.us=%llu", key, (unsigned long long)(cycles / (hz / 1'000'000 ? hz / 1'000'000 : 1)));
  else
    vx_printf(" %s.cycles=%llu", key, (unsigned long long)cycles);
}

// Sorts idx[0..n) by less, stably, through tmp (n more).
static void sort(uint32_t *idx, uint32_t *tmp, size_t n, bool (*less)(const void *, uint32_t, uint32_t),
                 const void *ctx) {
  for (size_t width = 1; width < n; width *= 2) {
    for (size_t lo = 0; lo < n; lo += 2 * width) {
      size_t mid = lo + width < n ? lo + width : n, hi = lo + 2 * width < n ? lo + 2 * width : n;
      size_t i = lo, j = mid, k = lo;
      while (i < mid && j < hi) tmp[k++] = less(ctx, idx[j], idx[i]) ? idx[j++] : idx[i++];
      while (i < mid) tmp[k++] = idx[i++];
      while (j < hi) tmp[k++] = idx[j++];
    }
    memcpy(idx, tmp, n * sizeof *idx);
  }
}

// A part of a flow: a span, or a call or its reply.
typedef struct part {
  uint64_t flow, start, end;
  uint32_t tid;
  uint16_t kind, type;
} part;

static bool by_flow(const void *ctx, uint32_t x, uint32_t y) {
  const part *p = ctx;
  return p[x].flow < p[y].flow || (p[x].flow == p[y].flow && p[x].start < p[y].start);
}

// A flow: its parts, idx[first..first+count), and how long it took.
typedef struct flow {
  uint32_t first, count;
  uint64_t start, end;
} flow;

static bool by_length(const void *ctx, uint32_t x, uint32_t y) { // longest first
  const flow *f = ctx;
  return f[x].end - f[x].start > f[y].end - f[y].start;
}

static void slowest_flows(const vx_trace_record *r, size_t n, vx_arena *a, size_t top) {
  part *p = vx_push(a, n * sizeof *p, alignof(part));
  size_t np = 0;
  for (size_t i = 0; p && i < n; i++) {
    if (r[i].kind == VX_TK_SPAN && r[i].a)
      p[np++] = (part){r[i].a,   r[i].time,  r[i].time + (r[i].b & 0xffff'ffff'ffff),
                       r[i].tid, VX_TK_SPAN, (uint16_t)(r[i].b >> 48)};
    else if ((r[i].kind == VX_TK_CALL || r[i].kind == VX_TK_REPLY) && r[i].b)
      p[np++] = (part){r[i].b, r[i].time, r[i].time, r[i].tid, r[i].kind, 0};
  }
  uint32_t *idx = vx_push(a, 2 * (np + 1) * sizeof *idx, alignof(uint32_t));
  flow *f = vx_push(a, (np + 1) * sizeof *f, alignof(flow));
  uint32_t *fidx = vx_push(a, 2 * (np + 1) * sizeof *fidx, alignof(uint32_t));
  if (!idx || !f || !fidx) return;
  for (uint32_t i = 0; i < np; i++) idx[i] = i;
  sort(idx, idx + np, np, by_flow, p);
  size_t nf = 0;
  for (uint32_t i = 0; i < np; i++) {
    const part *q = &p[idx[i]];
    if (!nf || p[idx[f[nf - 1].first]].flow != q->flow) f[nf++] = (flow){i, 0, q->start, q->end};
    flow *g = &f[nf - 1];
    g->count++;
    if (q->start < g->start) g->start = q->start;
    if (q->end > g->end) g->end = q->end;
  }
  for (uint32_t i = 0; i < nf; i++) fidx[i] = i;
  sort(fidx, fidx + nf, nf, by_length, f);
  for (size_t i = 0; i < nf && i < top; i++) {
    const flow *g = &f[fidx[i]];
    vx_printf("slowest=flow flow=0x%llx parts=%u", (unsigned long long)p[idx[g->first]].flow, g->count);
    print_length("length", g->end - g->start);
    vx_printf("\n");
    for (uint32_t j = 0; j < g->count; j++) {
      const part *q = &p[idx[g->first + j]];
      vx_printf("part task=%u thread=%u kind=%s", q->tid >> 12, q->tid & 0xfff,
                q->kind == VX_TK_SPAN ? "span" : KINDS[q->kind]);
      if (q->kind == VX_TK_SPAN) vx_printf(" type=%u", q->type);
      print_length("at", q->start - g->start);
      if (q->kind == VX_TK_SPAN) print_length("length", q->end - q->start);
      vx_printf("\n");
    }
  }
}

// A block: from a thread's BLOCK to the WAKE that ended it.
typedef struct block {
  uint64_t start, end, object;
  uint32_t tid, waker, why;
} block;

static bool by_block_length(const void *ctx, uint32_t x, uint32_t y) { // longest first
  const block *b = ctx;
  return b[x].end - b[x].start > b[y].end - b[y].start;
}

static const char *const WHY[] = {"", "port", "futex", "channel", "pager", "exception", "sleep"};

static void longest_blocks(const vx_trace_record *r, size_t n, vx_arena *a, size_t top) {
  size_t slots = 1;
  while (slots < 2 * n + 2) slots *= 2;
  uint32_t *open = vx_push(a, slots * sizeof *open, alignof(uint32_t)); // a thread's BLOCK: its index + 1
  uint32_t *tids = vx_push(a, slots * sizeof *tids, alignof(uint32_t));
  block *b = vx_push(a, (n + 1) * sizeof *b, alignof(block));
  uint32_t *idx = vx_push(a, 2 * (n + 1) * sizeof *idx, alignof(uint32_t));
  if (!open || !tids || !b || !idx) return;
  size_t nb = 0;
  for (size_t i = 0; i < n; i++) {
    uint32_t tid = 0;
    if (r[i].kind == VX_TK_BLOCK)
      tid = r[i].tid;
    else if (r[i].kind == VX_TK_WAKE)
      tid = (uint32_t)r[i].a;
    if (!tid) continue;
    size_t h = ((size_t)tid * 0x9e37'79b9u) & (slots - 1);
    while (tids[h] && tids[h] != tid) h = (h + 1) & (slots - 1);
    tids[h] = tid;
    if (r[i].kind == VX_TK_BLOCK) {
      open[h] = (uint32_t)i + 1;
    } else if (open[h]) {
      const vx_trace_record *s = &r[open[h] - 1];
      b[nb++] = (block){s->time, r[i].time, s->b, tid, (uint32_t)r[i].b, (uint32_t)s->a};
      open[h] = 0;
    }
  }
  for (uint32_t i = 0; i < nb; i++) idx[i] = i;
  sort(idx, idx + nb, nb, by_block_length, b);
  for (size_t i = 0; i < nb && i < top; i++) {
    const block *k = &b[idx[i]];
    vx_printf("longest=block task=%u thread=%u why=%s object=0x%llx", k->tid >> 12, k->tid & 0xfff,
              k->why < sizeof WHY / sizeof WHY[0] && k->why ? WHY[k->why] : "unknown",
              (unsigned long long)k->object);
    print_length("length", k->end - k->start);
    if (k->waker)
      vx_printf(" waker.task=%u waker.thread=%u\n", k->waker >> 12, k->waker & 0xfff);
    else
      vx_printf(" waker=kernel\n");
  }
}

static const char *summary(vx_str path, size_t top) {
  vx_arena *a = vx_arena_new(240ull << 20); // a million records and the summary's tables: one VMO's most
  if (vx_arena_error(a) != VX_OK) return fail("arena", path);
  size_t n = 0;
  const vx_trace_record *r = load(path, a, &n);
  if (!r) return fail("read", path);
  hz = counter_hz();
  slowest_flows(r, n, a, top);
  longest_blocks(r, n, a, top);
  return nullptr;
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
  bool p = false, s = false;
  uint64_t top = 10;
  for (size_t i = 1; i < args.len; i++) {
    vx_str a = args.ptr[i];
    if (vx_str_eq(a, VX_STR("-p")) || vx_str_eq(a, VX_STR("-s"))) {
      *(a.ptr[1] == 'p' ? &p : &s) = true;
    } else if (vx_str_eq(a, VX_STR("-n")) && i + 1 < args.len) {
      if (!vx_str_u64(args.ptr[++i], &top) || !top) return "usage";
    } else if ((p || s) && a.len && a.ptr[0] != '-') {
      file = a;
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
  if (s) return summary(file, top);
  if (!cats.len) {
    vx_eprintf("%s\n", VX_USAGE);
    return "usage";
  }
  return capture(cats, wait, out);
}
