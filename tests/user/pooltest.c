// pooltest: worker threads in the ring server (M6 step 6d5a), against
// pooltestd (tests/user/pooltestd.c), in the pool scenario
// (tests/qemu/pool.ndb). While a read waits with the server let go, the
// server answers others, on other connections and on the same one; slow
// reads on three connections wait at once; a Tflush of a busy read waits
// for its reply; a connection that goes while a read of
// its is busy is closed after it, and the server goes on. Each check prints
// a line only when it fails; the last line counts them.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-ns/spawn.c"

static uint32_t checks, failures;

static void check_at(bool ok, const char *what, int line) {
  checks++;
  if (ok) return;
  failures++;
  vx_print(VX_STR("pooltest: FAILED line "));
  vx_print_u64((uint64_t)line);
  vx_print(VX_STR(": "));
  vx_print(vx_cstr(what));
  vx_print(VX_STR("\n"));
}

#define CHECK(cond) check_at((cond), #cond, __LINE__)

static vx_ns ns;
static p9_conn conns[4];
static uint32_t roots[4];

// The file's first line, read whole on connection k: its length, or a negative status.
static int64_t read_file(int k, const char *name, char *buf, uint32_t cap) {
  uint32_t fid;
  vx_status st = p9c_walk(&conns[k].c, roots[k], vx_cstr(name), &fid);
  if (st != VX_OK) return st;
  st = p9c_open(&conns[k].c, fid, P9_OREAD);
  int64_t n = st != VX_OK ? st : p9c_read(&conns[k].c, fid, 0, buf, cap);
  p9c_clunk(&conns[k].c, fid);
  return n;
}

static bool is(const char *buf, int64_t n, const char *want) {
  return n == (int64_t)vx_cstr(want).len && !memcmp(buf, want, (size_t)n);
}

static void open_gate(void) {
  uint32_t fid;
  if (p9c_walk(&conns[1].c, roots[1], VX_STR("open"), &fid) != VX_OK) return;
  if (p9c_open(&conns[1].c, fid, P9_OWRITE) == VX_OK) p9c_write(&conns[1].c, fid, 0, "x", 1);
  p9c_clunk(&conns[1].c, fid);
}

static void pause_ms(int64_t ms) {
  static _Atomic uint32_t never;
  vx_instant until = vx_clock_read() + ms * 1'000'000;
  while (vx_clock_read() < until) vx_futex_wait(&never, 0, until);
}

typedef struct job {
  int conn;
  const char *file;
  _Atomic bool done;
  int64_t n;
  char buf[16];
} job;

static void run(void *arg) {
  job *j = arg;
  j->n = read_file(j->conn, j->file, j->buf, sizeof j->buf);
  atomic_store(&j->done, true);
}

static void cancel_job(void *arg) { // a gate read sent and flushed at once: the flush waits for it
  job *j = arg;
  uint32_t fid;
  if (p9c_walk(&conns[0].c, roots[0], VX_STR("gate"), &fid) == VX_OK &&
      p9c_open(&conns[0].c, fid, P9_OREAD) == VX_OK) {
    p9_msg r = {.type = P9_Tread, .fid = fid, .count = 16};
    if (p9_ring_send(&conns[0], &r, VX_HANDLE_NONE, 0) == VX_OK) {
      pause_ms(50); // served, and let go, before the flush comes
      p9_ring_cancel(&conns[0], r.tag);
      j->n = 1;
    }
    p9c_clunk(&conns[0].c, fid);
  }
  atomic_store(&j->done, true);
}

const char *vx_main(void) {
  if (vx_ns_from_spawn(&ns) != VX_OK) return "no namespace";
  vx_handle connector = vx_ns_connector(&ns, VX_STR("/n/pool"));
  CHECK(connector != VX_HANDLE_NONE);
  for (int k = 0; k < 4; k++) {
    CHECK(p9_ring_connect(connector, &conns[k]) == VX_OK &&
          p9c_attach(&conns[k].c, VX_STR(""), &roots[k]) == VX_OK);
    conns[k].timeout = 10'000'000'000;
  }
  char buf[16];

  // A gate read let go: the others are answered meanwhile, on its own connection too.
  job g = {.conn = 0, .file = "gate"};
  vx_thread t, u[3];
  CHECK(vx_thread_spawn(&t, run, &g, 0) == VX_OK);
  pause_ms(50);
  bool fast = true;
  for (int i = 0; i < 10; i++) fast = fast && is(buf, read_file(1, "fast", buf, sizeof buf), "fast\n");
  CHECK(fast);
  CHECK(is(buf, read_file(0, "fast", buf, sizeof buf), "fast\n"));
  CHECK(!atomic_load(&g.done));
  open_gate();
  vx_thread_join(&t);
  CHECK(is(g.buf, g.n, "gate\n"));

  // Three slow reads at once, each let go: all three wait together.
  job sl[3] = {{.conn = 0, .file = "slow"}, {.conn = 1, .file = "slow"}, {.conn = 2, .file = "slow"}};
  vx_instant start = vx_clock_read();
  for (int i = 0; i < 3; i++) CHECK(vx_thread_spawn(&u[i], run, &sl[i], 0) == VX_OK);
  for (int i = 0; i < 3; i++) vx_thread_join(&u[i]);
  vx_duration took = vx_clock_read() - start;
  CHECK(is(sl[0].buf, sl[0].n, "slow\n") && is(sl[1].buf, sl[1].n, "slow\n") &&
        is(sl[2].buf, sl[2].n, "slow\n"));
  CHECK(is(buf, read_file(3, "peak", buf, sizeof buf), "3\n"));
  CHECK(took < 850'000'000); // not one after another (900 ms)

  // A Tflush of a busy read waits for it: the flusher is not done until the
  // gate opens.
  job f = {};
  CHECK(vx_thread_spawn(&t, cancel_job, &f, 0) == VX_OK);
  pause_ms(200);
  CHECK(!atomic_load(&f.done));
  open_gate();
  vx_thread_join(&t);
  CHECK(f.n == 1);
  CHECK(is(buf, read_file(0, "fast", buf, sizeof buf), "fast\n"));

  // A connection that goes while a read of its is busy: closed after it.
  uint32_t fid;
  CHECK(p9c_walk(&conns[2].c, roots[2], VX_STR("gate"), &fid) == VX_OK &&
        p9c_open(&conns[2].c, fid, P9_OREAD) == VX_OK);
  p9_msg r = {.type = P9_Tread, .fid = fid, .count = 16};
  CHECK(p9_ring_send(&conns[2], &r, VX_HANDLE_NONE, 0) == VX_OK);
  pause_ms(50);
  p9_ring_disconnect(&conns[2]);
  pause_ms(50);
  CHECK(is(buf, read_file(1, "fast", buf, sizeof buf), "fast\n"));
  open_gate();
  pause_ms(50);
  CHECK(is(buf, read_file(1, "fast", buf, sizeof buf), "fast\n"));
  CHECK(is(buf, read_file(3, "fast", buf, sizeof buf), "fast\n"));
  static p9_conn again;
  uint32_t aroot;
  CHECK(p9_ring_connect(connector, &again) == VX_OK && p9c_attach(&again.c, VX_STR(""), &aroot) == VX_OK);

  vx_print(VX_STR("pooltest: "));
  vx_print_u64(checks);
  vx_print(VX_STR(" checks, "));
  vx_print_u64(failures);
  vx_print(VX_STR(" failed\n"));
  return nullptr;
}
