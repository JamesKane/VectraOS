// notifytest: 9Px notify in a running system (M6 step 6e1d,
// docs/proto/notify.md), the notify scenario's (tests/qemu/notify.ndb): a
// watcher on one ring connection to tmpfs, a writer on another. The
// watcher's Tnotify waits, held by the server, until the writer's change on
// the other connection queues an event and wakes it. The writer pings until
// the watcher has heard one (its watch is made by its first Tnotify, which
// the writer cannot see), then creates, writes, renames and removes a file;
// the watcher must hear those in order. Each check prints a line only when
// it fails; the last line counts them.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-rt/thread.c"
#include "../../lib/vx-9p/ring.c"

static uint32_t checks, failures;

static void check_at(bool ok, const char *what, int line) {
  checks++;
  if (ok) return;
  failures++;
  vx_print(VX_STR("notifytest: FAILED line "));
  vx_print_u64((uint64_t)line);
  vx_print(VX_STR(": "));
  vx_print(vx_cstr(what));
  vx_print(VX_STR("\n"));
}

#define CHECK(cond) check_at((cond), #cond, __LINE__)

static p9_conn watcher, writer;
static uint32_t watched; // the watcher's fid on the directory
static char heard[4096]; // "kind:name " for each event, in order
static size_t heard_len;
static _Atomic uint32_t heard_any, done;

// Appends a batch of events (kind[1] name[s] each) to heard.
static void note_events(const uint8_t *b, int64_t n) {
  for (int64_t i = 0; i + 3 <= n;) {
    uint16_t len = (uint16_t)(b[i + 1] | b[i + 2] << 8);
    if (heard_len + len + 8 < sizeof heard) {
      uint8_t k = b[i]; // a kind, below 256: up to three digits
      if (k >= 100) heard[heard_len++] = (char)('0' + k / 100);
      if (k >= 10) heard[heard_len++] = (char)('0' + k / 10 % 10);
      heard[heard_len++] = (char)('0' + k % 10);
      heard[heard_len++] = ':';
      memcpy(heard + heard_len, b + i + 3, len), heard_len += len;
      heard[heard_len++] = ' ';
    }
    i += 3 + len;
  }
}

static bool heard_has(const char *s) {
  size_t n = vx_cstr(s).len;
  for (size_t i = 0; i + n <= heard_len; i++)
    if (!memcmp(heard + i, s, n)) return true;
  return false;
}

// The watcher: asks until it has heard the remove that ends the writer's turn.
static void watch(void *arg) {
  (void)arg;
  static uint8_t b[8192];
  while (!heard_has(" 2:g ")) { // a space first: "32:g " holds "2:g " too
    int64_t n = p9c_notify(&watcher.c, watched, 0x3f, b, sizeof b);
    if (n < 0) break;
    note_events(b, n);
    atomic_store(&heard_any, 1);
  }
  atomic_store(&done, 1);
  vx_futex_wake(&done, 1);
}

const char *vx_main(void) {
  vx_handle connector = vx_spawn_take("srv:tmpfs");
  CHECK(connector && p9_ring_connect(connector, &watcher) == VX_OK &&
        p9_ring_connect(connector, &writer) == VX_OK);
  CHECK((watcher.c.extensions & P9_EXT_NOTIFY) && (writer.c.extensions & P9_EXT_NOTIFY));
  uint32_t wroot = 0, root = 0, dir = 0, f = 0;
  CHECK(p9c_attach(&writer.c, VX_STR(""), &root) == VX_OK &&
        p9c_walk(&writer.c, root, (vx_str){}, &dir) == VX_OK);
  p9c_create(&writer.c, dir, VX_STR("notifytest"), P9_DMDIR | 0777, P9_OREAD);
  p9c_clunk(&writer.c, dir);
  CHECK(p9c_walk(&writer.c, root, VX_STR("notifytest"), &dir) == VX_OK);
  CHECK(p9c_attach(&watcher.c, VX_STR(""), &wroot) == VX_OK &&
        p9c_walk(&watcher.c, wroot, VX_STR("notifytest"), &watched) == VX_OK);
  vx_worker t;
  CHECK(vx_worker_start(&t, watch, nullptr, 64ull * 1024) == VX_OK);
  // Pings, until the watcher's watch exists and has heard one.
  for (int i = 0; i < 500 && !atomic_load(&heard_any); i++) {
    if (p9c_walk(&writer.c, dir, (vx_str){}, &f) == VX_OK &&
        p9c_create(&writer.c, f, VX_STR("ping"), 0644, P9_OWRITE) == VX_OK)
      p9c_remove(&writer.c, f); // which clunks it
    static const _Atomic uint32_t never;
    vx_futex_wait(&never, 0, vx_clock_read() + 10'000'000);
  }
  CHECK(atomic_load(&heard_any));
  // The change the watcher must hear, in order.
  CHECK(p9c_walk(&writer.c, dir, (vx_str){}, &f) == VX_OK &&
        p9c_create(&writer.c, f, VX_STR("f"), 0644, P9_OWRITE) == VX_OK);
  CHECK(p9c_write(&writer.c, f, 0, "hello", 5) == 5);
  CHECK(p9c_renameat(&writer.c, dir, VX_STR("f"), dir, VX_STR("g")) == VX_OK);
  CHECK(p9c_remove(&writer.c, f) == VX_OK);
  vx_instant end = vx_clock_read() + 5'000'000'000;
  while (!atomic_load(&done) && vx_clock_read() < end) vx_futex_wait(&done, 0, vx_clock_read() + 100'000'000);
  CHECK(atomic_load(&done));
  CHECK(heard_has(" 1:f 4:f 16:f 32:g 2:g "));
  if (atomic_load(&done)) vx_worker_join(&t);
  vx_print(VX_STR("notifytest: "));
  vx_print_u64(checks);
  vx_print(VX_STR(" checks, "));
  vx_print_u64(failures);
  vx_print(VX_STR(" failed\n"));
  return failures ? "FAILED" : nullptr;
}
