// relaytest: the relay (M6 step 6d4d2b), run in the relay scenario
// (tests/qemu/relay.ndb) against u9fs over TCP. It spawns a relay for
// tcp!10.0.2.101!564 and connects to it twice: one TCP conversation for
// both; both clients number their fids alike; a file made through one is
// read through the other; threads on both connections at once; a flushed
// read, a hundred times over, leaks nothing; an error comes through; a
// client gone leaves the other working; and the relay goes once nothing can
// reach it. Each check prints a line only when it fails; the last line
// counts them.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-rt/spawn.c"
#include "../../lib/vx-ns/spawn.c"

static uint32_t checks, failures;

static void check_at(bool ok, const char *what, int line) {
  checks++;
  if (ok) return;
  failures++;
  vx_print(VX_STR("relaytest: FAILED line "));
  vx_print_u64((uint64_t)line);
  vx_print(VX_STR(": "));
  vx_print(vx_cstr(what));
  vx_print(VX_STR("\n"));
}

#define CHECK(cond) check_at((cond), #cond, __LINE__)

static constexpr char ADDRESS[] = "tcp!10.0.2.101!564";
static vx_ns ns;
static uint8_t image[1 << 20];
static size_t image_size;

static bool has(const char *buf, size_t len, const char *s) {
  size_t n = vx_cstr(s).len;
  for (size_t i = 0; i + n <= len; i++)
    if (!memcmp(buf + i, s, n)) return true;
  return false;
}

// TCP conversations established with u9fs.
static uint32_t conversations(void) {
  uint32_t n = 0;
  for (uint32_t i = 0; i < 64; i++) {
    char path[32] = "/net/tcp/", buf[128];
    size_t len = 9;
    if (i >= 10) path[len++] = (char)('0' + i / 10);
    path[len++] = (char)('0' + i % 10);
    size_t got = 0, rgot = 0;
    memcpy(path + len, "/status", 8);
    if (vx_ns_read_all(&ns, vx_cstr(path), buf, sizeof buf, &got) != VX_OK || !has(buf, got, "Established"))
      continue;
    memcpy(path + len, "/remote", 8);
    if (vx_ns_read_all(&ns, vx_cstr(path), buf, sizeof buf, &rgot) == VX_OK &&
        has(buf, rgot, "10.0.2.101!564"))
      n++;
  }
  return n;
}

// Starts a relay for ADDRESS: its task, and a connector to it in *connector.
static vx_handle spawn_relay(vx_handle *connector) {
  vx_handle handles[VX_CHANNEL_MAX_HANDLES - 1], ch[2], task = VX_HANDLE_NONE;
  vx_str names[VX_CHANNEL_MAX_HANDLES - 1];
  uint32_t count = 0;
  static char records[8 * 1024];
  vx_ndb_writer rec = {.buf = records, .cap = sizeof records};
  vx_ndb_put(&rec, "arg", vx_cstr(ADDRESS));
  vx_ndb_end(&rec);
  if (vx_channel_create(0, ch) != VX_OK) return VX_HANDLE_NONE;
  if (vx_ns_spawn_records(&ns, &rec, handles, names, &count, VX_CHANNEL_MAX_HANDLES - 4) != VX_OK)
    return VX_HANDLE_NONE;
  handles[count] = ch[1], names[count++] = VX_STR("listen");
  if (vx_console.connector && vx_handle_dup(vx_console.connector, VX_RIGHTS_SAME, &handles[count]) == VX_OK)
    names[count++] = VX_STR("console");
  vx_spawn_args a = {.name = VX_STR("relay"),
                     .image = image,
                     .image_size = image_size,
                     .handles = handles,
                     .handle_names = names,
                     .handle_count = count,
                     .records = {records, rec.len}};
  if (vx_spawn_elf(&a, &task) != VX_OK) return VX_HANDLE_NONE;
  *connector = ch[0];
  return task;
}

// The whole of the file at path from root on c, into buf; its length, or a negative status.
static int64_t read_file(p9_client *c, uint32_t root, const char *path, uint8_t *buf, uint32_t cap) {
  uint32_t fid;
  vx_status st = p9c_walk(c, root, vx_cstr(path), &fid);
  if (st != VX_OK) return st;
  st = p9c_open(c, fid, P9_OREAD);
  int64_t n = st != VX_OK ? st : p9c_read(c, fid, 0, buf, cap);
  p9c_clunk(c, fid);
  return n;
}

static p9_conn a, b;
static uint32_t aroot, broot;

typedef struct worker {
  p9_client *c;
  uint32_t root, good;
} worker;

static void work(void *arg) {
  worker *w = arg;
  for (int i = 0; i < 50; i++) {
    uint8_t buf[64];
    int64_t n = read_file(w->c, w->root, "hello.txt", buf, sizeof buf);
    if (n == 20 && !memcmp(buf, "hello from the host\n", 20)) w->good++;
  }
}

const char *vx_main(void) {
  if (vx_ns_from_spawn(&ns) != VX_OK) return "no namespace";
  vx_ns_file f;
  if (vx_ns_open(&ns, VX_STR("/boot/bin/relay"), P9_OREAD, &f) == VX_OK) {
    int64_t n;
    while (image_size < sizeof image &&
           (n = vx_ns_read(&f, image + image_size, (uint32_t)(sizeof image - image_size))) > 0)
      image_size += (size_t)n;
    vx_ns_close(&f);
  }
  CHECK(image_size > 0);
  // The network up first: netd's address from DHCP.
  vx_handle port;
  vx_packet pk;
  CHECK(vx_port_create(0, &port) == VX_OK);
  for (int i = 0; i < 100; i++) {
    char st[512];
    size_t got = 0;
    if (vx_ns_read_all(&ns, VX_STR("/net/ipifc/0/status"), st, sizeof st, &got) == VX_OK &&
        has(st, got, "10.0.2.15"))
      break;
    vx_port_wait(port, vx_clock_read() + 100'000'000, 0, &pk, 1); // a pause: nothing is bound
  }
  uint32_t before = conversations();

  vx_handle connector = VX_HANDLE_NONE, relay = spawn_relay(&connector);
  CHECK(relay != VX_HANDLE_NONE);
  CHECK(p9_ring_connect(connector, &a) == VX_OK && a.c.dialect == P9_2000 && !a.c.extensions);
  CHECK(p9_ring_connect(connector, &b) == VX_OK && b.c.dialect == P9_2000);
  a.timeout = b.timeout = 5'000'000'000;
  CHECK(p9c_attach(&a.c, VX_STR(""), &aroot) == VX_OK);
  CHECK(p9c_attach(&b.c, VX_STR(""), &broot) == VX_OK);
  CHECK(aroot == broot);                // each client's own numbering: the same fids
  CHECK(conversations() == before + 1); // one session for both

  uint8_t buf[64] = {};
  CHECK(read_file(&a.c, aroot, "hello.txt", buf, sizeof buf) == 20 &&
        !memcmp(buf, "hello from the host\n", 20));
  CHECK(read_file(&b.c, broot, "hello.txt", buf, sizeof buf) == 20);
  CHECK(read_file(&b.c, broot, "nothing", buf, sizeof buf) == VX_ERR_NOT_FOUND);

  // Made through one, read through the other.
  uint32_t fid;
  CHECK(p9c_walk(&a.c, aroot, VX_STR(""), &fid) == VX_OK &&
        p9c_create(&a.c, fid, VX_STR("relay.txt"), 0644, P9_OWRITE) == VX_OK &&
        p9c_write(&a.c, fid, 0, "through the relay\n", 18) == 18);
  p9c_clunk(&a.c, fid);
  CHECK(read_file(&b.c, broot, "relay.txt", buf, sizeof buf) == 18 &&
        !memcmp(buf, "through the relay\n", 18));

  // Two threads on each connection, all at once.
  worker w[4] = {{&a.c, aroot, 0}, {&a.c, aroot, 0}, {&b.c, broot, 0}, {&b.c, broot, 0}};
  vx_thread t[4];
  for (int i = 0; i < 4; i++) CHECK(vx_thread_spawn(&t[i], work, &w[i], 0) == VX_OK);
  for (int i = 0; i < 4; i++) vx_thread_join(&t[i]);
  CHECK(w[0].good == 50 && w[1].good == 50 && w[2].good == 50 && w[3].good == 50);

  // Reads flushed as soon as they are sent: none of the relay's calls is
  // kept for them (it has 64), and the connection goes on.
  CHECK(p9c_walk(&a.c, aroot, VX_STR("hello.txt"), &fid) == VX_OK && p9c_open(&a.c, fid, P9_OREAD) == VX_OK);
  uint32_t sent = 0;
  for (int i = 0; i < 100; i++) {
    p9_msg r = {.type = P9_Tread, .fid = fid, .offset = 0, .count = 20};
    if (p9_ring_send(&a, &r, VX_HANDLE_NONE, 0) == VX_OK) sent++;
    p9_ring_cancel(&a, r.tag);
  }
  CHECK(sent == 100);
  CHECK(p9c_read(&a.c, fid, 0, buf, 20) == 20);
  p9c_clunk(&a.c, fid);
  CHECK(read_file(&b.c, broot, "hello.txt", buf, sizeof buf) == 20);

  // A client gone, its fids with it; the other goes on, and so does the
  // relay with its connector gone too, until its last client goes.
  CHECK(p9c_walk(&a.c, aroot, VX_STR("hello.txt"), &fid) == VX_OK);
  p9_ring_disconnect(&a);
  vx_handle_close(connector);
  CHECK(read_file(&b.c, broot, "hello.txt", buf, sizeof buf) == 20);
  CHECK(vx_port_bind(port, relay, VX_TRIGGER_EXIT, 1, 0) == VX_OK);
  CHECK(vx_port_wait(port, vx_clock_read() + 200'000'000, 0, &pk, 1) == VX_ERR_TIMED_OUT); // still there
  p9_ring_disconnect(&b);
  CHECK(vx_port_wait(port, vx_clock_read() + 5'000'000'000, 0, &pk, 1) == 1); // and gone
  CHECK(conversations() == before);

  vx_print(VX_STR("relaytest: "));
  vx_print_u64(checks);
  vx_print(VX_STR(" checks, "));
  vx_print_u64(failures);
  vx_print(VX_STR(" failed\n"));
  return nullptr;
}
