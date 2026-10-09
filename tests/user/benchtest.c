// benchtest: ./build bench's measurements (00 §8, 20 §8, M7 step 7a5), the
// bench and benchslow scenarios'. Each budget is the time between two of the
// kernel trace's MARK records, which this writes itself with the trace's
// Resource (svcd's `trace`): one syscall each, not a round trip through
// procfs. It runs each workload some times, reads /proc/trace/events,
// pairs the marks, and judges each budget by its median:
//
//   bench: NAME runs=N median.us=M max.us=X budget.us=B ok|OVER BUDGET
//   bench: all within budget | bench: N over budget
//
// bench.slow=NAME on the command line slows that workload by 100 µs inside
// its marks, so a budget is seen to fail (benchslow); bench.slow=flight
// slows every spawn while the flight recorder runs, so its cost does.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-ns/nsapi.c"

static vx_handle trace;   // the trace's Resource, MARK only
static bool recording;    // the flight recorder's categories are on: bench.slow=flight's
static vx_str slow;       // bench.slow=NAME
static uint32_t failures; // setup that failed: a bench that measured nothing proves nothing

static void mark(char side, const char *name) {
  char text[16] = {side, ':'};
  for (size_t i = 0; name[i] && i < 14; i++) text[2 + i] = name[i];
  vx_trace_configure(trace, VX_TRACE_MARK, text, sizeof text);
}

static void spin_us(uint64_t us) {
  vx_instant until = vx_now() + (vx_instant)us * 1000;
  while (vx_now() < until) {}
}

static void slowed(const char *name) {
  if (vx_str_eq(slow, vx_cstr(name)) || (recording && vx_str_eq(slow, VX_STR("flight")))) spin_us(100);
}

static void need(bool ok, const char *what) {
  if (ok) return;
  failures++;
  vx_printf("bench: FAILED to set up: %s\n", what);
}

// --- The workloads ---

// A static program spawned until its main runs: the child marks its end.
static void spawn_once(void) {
  vx_str args[] = {VX_STR("benchtest"), VX_STR("child")};
  vx_str names[] = {VX_STR("trace")};
  vx_handle give = VX_HANDLE_NONE;
  need(vx_handle_dup(trace, VX_RIGHTS_SAME, &give) == VX_OK, "a trace handle for the child");
  vx_spawn_req req = {
      .path = vx_exe_path(), .args = {args, 2}, .handles = &give, .handle_names = names, .nhandles = 1};
  vx_proc kid = {};
  mark('<', "spawn");
  slowed("spawn");
  need(vx_proc_spawn(&req, &kid) == VX_OK, "spawn");
  static vx_arena *a;
  if (!a) a = vx_arena_new(1 << 16);
  vx_proc_wait(kid, VX_INFINITE, a, nullptr);
}

// A 4 KiB file already in fsd's cache: opened, read whole, closed.
static void read_once(void) {
  static uint8_t buf[4096];
  mark('<', "read");
  slowed("read");
  vx_fd f = vx_open(VX_STR("/n/adm/bench4k"), VX_OREAD);
  int64_t n = f >= 0 ? vx_read(f, (vx_bytes){buf, sizeof buf}) : -1;
  vx_close(f);
  mark('>', "read");
  need(n == sizeof buf, "the 4 KiB read");
}

// ls of a directory of 10,000 entries: opened, every entry read, closed.
static void ls_once(vx_arena *a) {
  vx_dir *d = nullptr;
  mark('<', "ls");
  slowed("ls");
  vx_fd f = vx_open(VX_STR("/n/adm/bench10k"), VX_OREAD);
  int64_t n = 0, got;
  while (f >= 0 && (got = vx_dirread(f, a, &d)) > 0) n += got;
  vx_close(f);
  mark('>', "ls");
  need(n == 10'000, "the 10,000 entries");
}

static void setup(void) {
  vx_fd f = vx_create(VX_STR("/n/adm/bench4k"), VX_OWRITE, 0644);
  static uint8_t page[4096];
  memset(page, 'b', sizeof page);
  size_t put = 0;
  for (int64_t w = 1; f >= 0 && put < sizeof page && w > 0; put += w > 0 ? (size_t)w : 0)
    w = vx_write(f, (vx_str){(const char *)page + put, sizeof page - put});
  vx_close(f);
  need(put == sizeof page, "the 4 KiB file");
  vx_fd d = vx_create(VX_STR("/n/adm/bench10k"), VX_OREAD, VX_DMDIR | 0755);
  vx_close(d);
  vx_arena *a = vx_arena_new(1 << 20);
  vx_mark start = vx_arena_mark(a);
  bool made = d >= 0;
  for (uint32_t i = 0; i < 10'000 && made; i++) {
    vx_fd e = vx_create(vx_fmt(a, "/n/adm/bench10k/%05u", i), VX_OWRITE, 0644);
    made = e >= 0;
    vx_close(e);
    vx_arena_pop(a, start);
  }
  vx_arena_free(a);
  need(made, "the 10,000 files");
}

// Every workload, some times each: what one run of the bench is.
static void workloads(vx_arena *a) {
  for (int i = 0; i < 20; i++) spawn_once();
  for (int i = 0; i < 100; i++) read_once();
  for (int i = 0; i < 5; i++) ls_once(a);
}

// --- Reading the marks ---

typedef struct budget {
  const char *name;
  uint64_t us; // its target
  uint64_t took[128];
  uint32_t runs;
} budget;

static budget BUDGETS[] = {
    {.name = "spawn", .us = 200},   // a static program spawned until its main runs (M2)
    {.name = "read", .us = 5},      // open and read a 4 KiB file already in cache (M5)
    {.name = "ls", .us = 3000},     // ls of a directory with 10,000 entries (M5)
    {.name = "workloads", .us = 0}, // all of them, the flight recorder's cost judged on it (20 §8)
};
static constexpr size_t NBUDGETS = sizeof BUDGETS / sizeof BUDGETS[0];

static uint64_t counter_hz(vx_arena *a) {
  vx_str t = {};
  char buf[4096];
  vx_fd f = vx_open(VX_STR("/proc/trace/status"), VX_OREAD);
  int64_t n = f >= 0 ? vx_read(f, (vx_bytes){(uint8_t *)buf, sizeof buf}) : -1;
  vx_close(f);
  (void)a;
  t = (vx_str){buf, n > 0 ? (size_t)n : 0};
  int64_t at = vx_str_find(t, VX_STR(" hz="));
  uint64_t hz = 0;
  for (size_t k = (size_t)at + 4; at >= 0 && k < t.len && t.ptr[k] >= '0' && t.ptr[k] <= '9'; k++)
    hz = hz * 10 + (uint64_t)(t.ptr[k] - '0');
  return hz;
}

// The marks of the trace now stopped, paired in order by name: each budget's runs, in ns.
static void read_marks(vx_arena *a) {
  uint64_t hz = counter_hz(a);
  vx_fd f = vx_open(VX_STR("/proc/trace/events"), VX_OREAD);
  size_t cap = 16 << 20, got = 0;
  uint8_t *buf = vx_push(a, cap, 32);
  int64_t n;
  while (buf && f >= 0 && (n = vx_read(f, (vx_bytes){buf + got, cap - got})) > 0) got += (size_t)n;
  vx_close(f);
  need(hz != 0, "the counter's frequency");
  uint64_t begun[NBUDGETS] = {};
  for (size_t i = 0; hz && i + sizeof(vx_trace_record) <= got; i += sizeof(vx_trace_record)) {
    vx_trace_record r;
    memcpy(&r, buf + i, sizeof r);
    if (r.kind != VX_TK_MARK) continue;
    char text[17] = {};
    memcpy(text, &r.a, 16);
    for (size_t k = 0; k < NBUDGETS; k++) {
      if (!vx_str_eq(vx_cstr(text + 2), vx_cstr(BUDGETS[k].name))) continue;
      if (text[0] == '<') begun[k] = r.time;
      if (text[0] == '>' && begun[k] && BUDGETS[k].runs < 128)
        BUDGETS[k].took[BUDGETS[k].runs++] = (r.time - begun[k]) * 1'000'000'000 / hz, begun[k] = 0;
    }
  }
}

static uint64_t median(budget *b) {
  for (uint32_t i = 1; i < b->runs; i++) // insertion: few
    for (uint32_t j = i; j > 0 && b->took[j - 1] > b->took[j]; j--) {
      uint64_t t = b->took[j];
      b->took[j] = b->took[j - 1], b->took[j - 1] = t;
    }
  return b->runs ? b->took[b->runs / 2] : 0;
}

static vx_status ctl(const char *cmd) { return vx_ctl(VX_STR("/proc/trace/ctl"), "%s", cmd); }

// One run of every workload under a trace of these categories: its total, in ns.
static uint64_t run(const char *cats, vx_arena *a) {
  for (size_t k = 0; k < NBUDGETS; k++) BUDGETS[k].runs = 0;
  need(vx_ctl(VX_STR("/proc/trace/ctl"), "start %s size 4M", cats) == VX_OK, "the trace");
  mark('<', "workloads");
  workloads(a);
  mark('>', "workloads");
  need(ctl("stop") == VX_OK, "the trace's stop");
  read_marks(a);
  return BUDGETS[NBUDGETS - 1].runs ? BUDGETS[NBUDGETS - 1].took[0] : 0;
}

const char *vx_main(void) {
  trace = vx_spawn_take("trace");
  if (vx_str_eq(vx_arg(1), VX_STR("child"))) { // spawned: main runs
    mark('>', "spawn");
    return nullptr;
  }
  vx_str rest = vx_spawn.cmdline, w;
  while (vx_str_split(&rest, VX_STR(" "), &w))
    if (vx_str_prefix(w, VX_STR("bench.slow="))) slow = (vx_str){w.ptr + 11, w.len - 11};
  need(trace != VX_HANDLE_NONE, "the trace's Resource (svc(6)'s trace)");
  setup();
  vx_arena *a = vx_arena_new(64 << 20);
  vx_mark start = vx_arena_mark(a);
  read_once(); // into fsd's cache
  // The flight recorder's cost on these workloads: the best of three each, marks alone and the recorder's categories.
  uint64_t plain = UINT64_MAX, flight = UINT64_MAX;
  for (int i = 0; i < 3; i++) {
    vx_arena_pop(a, start);
    recording = true;
    uint64_t t = run("sched,ipc,irq,mark", a);
    recording = false;
    if (t && t < flight) flight = t;
    vx_arena_pop(a, start);
    t = run("mark", a); // last: its marks are the budgets judged
    if (t && t < plain) plain = t;
  }
  uint32_t over = 0;
  for (size_t k = 0; k + 1 < NBUDGETS; k++) {
    budget *b = &BUDGETS[k];
    uint64_t m = median(b), max = b->runs ? b->took[b->runs - 1] : 0;
    bool ok = b->runs && m <= b->us * 1000;
    over += !ok;
    vx_printf("bench: %s runs=%u median.us=%llu.%01llu max.us=%llu budget.us=%llu %s\n", b->name, b->runs,
              (unsigned long long)(m / 1000), (unsigned long long)(m % 1000 / 100),
              (unsigned long long)(max / 1000), (unsigned long long)b->us, ok ? "ok" : "OVER BUDGET");
  }
  int64_t permille =
      plain && plain != UINT64_MAX ? ((int64_t)flight - (int64_t)plain) * 1000 / (int64_t)plain : 0;
  bool flight_ok = permille <= 10;
  over += !flight_ok;
  vx_printf("bench: flight-recorder workloads.us=%llu with.us=%llu cost=%lld.%lld%% budget=1%% %s\n",
            (unsigned long long)(plain / 1000), (unsigned long long)(flight / 1000),
            (long long)(permille / 10), (long long)(permille < 0 ? -permille % 10 : permille % 10),
            flight_ok ? "ok" : "OVER BUDGET");
  if (failures)
    vx_printf("bench: FAILED: %u steps of its setup\n", failures);
  else if (over)
    vx_printf("bench: %u over budget\n", over);
  else
    vx_printf("bench: all within budget\n");
  return failures ? "setup failed" : nullptr;
}
