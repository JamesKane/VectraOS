// p9pipetest: the pipelined 9P client and ring server (M6 step 6d4a), run in
// the p9pipe scenario (tests/qemu/p9pipe.ndb), against ptyd, whose slave
// reads wait for input: requests the server holds. On one connection: a held
// read and a write that ends it, from two threads; threads making calls
// while one is held; a held read flushed by a note, and by a timeout, with
// the connection whole after; and the input that came after a flush read by
// the next read, not lost to the flushed one. Each check prints a line only
// when it fails; the last line counts them.

#include "../../lib/vx-rt/rt.c"

static _Atomic uint32_t checks, failures;

static void check_at(bool ok, const char *what, int line) {
  atomic_fetch_add(&checks, 1);
  if (ok) return;
  atomic_fetch_add(&failures, 1);
  vx_print(VX_STR("p9pipetest: FAILED line "));
  vx_print_u64((uint64_t)line);
  vx_print(VX_STR(": "));
  vx_print(vx_cstr(what));
  vx_print(VX_STR("\n"));
}

#define CHECK(cond) check_at((cond), #cond, __LINE__)

static p9_conn conn;
static uint32_t root, master, slave;
static _Atomic uint32_t never;

static void nap(int64_t ms) { vx_futex_wait(&never, 0, vx_clock_read() + ms * 1'000'000); }

// A slave read, on a thread of its own.
typedef struct reader {
  vx_thread t;
  char buf[64];
  _Atomic int64_t got; // bytes, or a negative status
  _Atomic bool done;
  _Atomic uint32_t id; // its kernel thread id, for a note
} reader;

static void read_slave(void *arg) {
  reader *r = arg;
  vx_thread_info ti;
  // The newest thread is the one with the highest id: this one, as it starts.
  for (uint32_t after = 0; vx_thread_state(vx_self, after, VX_STATE_NEXT_THREAD, &ti, sizeof ti) == VX_OK;)
    after = ti.id;
  atomic_store(&r->id, ti.id);
  atomic_store(&r->got, p9c_read(&conn.c, slave, P9_OFFSET_CURRENT, r->buf, sizeof r->buf));
  atomic_store(&r->done, true);
}

static bool type_at_master(const char *text) {
  size_t n = vx_cstr(text).len;
  return p9c_write(&conn.c, master, P9_OFFSET_CURRENT, text, (uint32_t)n) == (int64_t)n;
}

// Many calls from a thread while a read is held.
static _Atomic uint32_t busy_ok;

static void busy(void *arg) {
  (void)arg;
  bool ok = true;
  for (int i = 0; i < 100 && ok; i++) {
    p9_stat st;
    uint32_t fid = 0;
    ok = p9c_stat(&conn.c, master, &st, nullptr) == VX_OK &&
         p9c_walk(&conn.c, root, VX_STR("pts"), &fid) == VX_OK && p9c_clunk(&conn.c, fid) == VX_OK;
  }
  if (ok) atomic_fetch_add(&busy_ok, 1);
}

static bool flush_wanted(void *ctx) {
  (void)ctx;
  return true;
}

static vx_noted on_note(vx_exception *e, vx_str note, void *fp) {
  (void)e, (void)fp;
  return note.len == 8 && memcmp(note.ptr, "flush me", 8) == 0 ? VX_NCONT : VX_NDFLT;
}

static bool wait_done(reader *r, int64_t ms) {
  for (int64_t i = 0; i < ms && !atomic_load(&r->done); i++) nap(1);
  return atomic_load(&r->done);
}

const char *vx_main(void) {
  vx_handle connector = vx_spawn_take("srv:ptyd");
  CHECK(connector != VX_HANDLE_NONE);
  if (!connector) return "no connector to /srv/ptyd";
  CHECK(p9_ring_connect(connector, &conn) == VX_OK);
  CHECK(p9c_attach(&conn.c, VX_STR(""), &root) == VX_OK);
  CHECK(p9c_walk(&conn.c, root, VX_STR("ptmx"), &master) == VX_OK &&
        p9c_open(&conn.c, master, P9_ORDWR) == VX_OK);
  p9_stat st = {};
  p9_stat_text names;
  CHECK(p9c_stat(&conn.c, master, &st, &names) == VX_OK && st.name.len > 0 && st.name.len < 8);
  char path[16] = "pts/";
  memcpy(path + 4, st.name.ptr, st.name.len);
  CHECK(p9c_walk(&conn.c, root, (vx_str){path, 4 + st.name.len}, &slave) == VX_OK &&
        p9c_open(&conn.c, slave, P9_ORDWR) == VX_OK);

  // A read the server holds, and a write from another thread that ends it,
  // on the same connection; calls from more threads meanwhile.
  static reader r1;
  CHECK(vx_thread_spawn(&r1.t, read_slave, &r1, 0) == VX_OK);
  nap(30);
  CHECK(!atomic_load(&r1.done)); // held: no input yet
  vx_thread b[4];
  for (int i = 0; i < 4; i++) CHECK(vx_thread_spawn(&b[i], busy, nullptr, 0) == VX_OK);
  for (int i = 0; i < 4; i++) vx_thread_join(&b[i]);
  CHECK(atomic_load(&busy_ok) == 4 && !atomic_load(&r1.done));
  CHECK(type_at_master("hello\n"));
  CHECK(wait_done(&r1, 2000) && atomic_load(&r1.got) == 6 && memcmp(r1.buf, "hello\n", 6) == 0);
  vx_thread_join(&r1.t);

  // A held read flushed by a note: INTERRUPTED; then input reaches the next
  // read, not the flushed one.
  CHECK(vx_notify(on_note) == VX_OK);
  conn.interrupted = flush_wanted;
  static reader r2;
  CHECK(vx_thread_spawn(&r2.t, read_slave, &r2, 0) == VX_OK);
  nap(30);
  CHECK(!atomic_load(&r2.done) && atomic_load(&r2.id));
  CHECK(vx_thread_interrupt(vx_self, atomic_load(&r2.id), VX_STR("flush me")) == VX_OK);
  CHECK(wait_done(&r2, 2000) && atomic_load(&r2.got) == VX_ERR_INTERRUPTED);
  vx_thread_join(&r2.t);
  CHECK(!conn.dead && type_at_master("after\n"));
  char buf[64];
  CHECK(p9c_read(&conn.c, slave, P9_OFFSET_CURRENT, buf, sizeof buf) == 6 && memcmp(buf, "after\n", 6) == 0);
  conn.interrupted = nullptr;

  // A held read past its timeout: flushed, TIMED_OUT, the connection whole.
  conn.timeout = 100'000'000;
  vx_instant t0 = vx_clock_read();
  CHECK(p9c_read(&conn.c, slave, P9_OFFSET_CURRENT, buf, sizeof buf) == VX_ERR_TIMED_OUT);
  CHECK(vx_clock_read() - t0 < 2'000'000'000);
  conn.timeout = 0;
  CHECK(!conn.dead && type_at_master("again\n"));
  CHECK(p9c_read(&conn.c, slave, P9_OFFSET_CURRENT, buf, sizeof buf) == 6 && memcmp(buf, "again\n", 6) == 0);

  p9c_clunk(&conn.c, slave);
  p9c_clunk(&conn.c, master);
  p9c_clunk(&conn.c, root);
  p9_ring_disconnect(&conn);
  vx_print(VX_STR("p9pipetest: "));
  vx_print_u64(atomic_load(&checks));
  vx_print(VX_STR(" checks, "));
  vx_print_u64(atomic_load(&failures));
  vx_print(VX_STR(" failed\n"));
  return nullptr;
}
