// sysfs: /sys (02 §5), posted as /srv/sys. M4 serves its clock:
//
//   /sys/clock/info   the cycle counter the one clock is made from, as the
//                     kernel calibrated it (clock_read's vx_clock_info):
//                       tsc.hz=3187200000 tsc.invariant tsc.user source=tsc
//                       cntfrq.hz=24000000 cntvct.invariant cntvct.user source=cntvct
//                     so a program timing itself with rdtsc or cntvct_el0
//                     (vx_cycles, vx-prof's zones) need not calibrate (05 §9)
//   /sys/clock/now    monotonic=NS realtime=NS: realtime is UTC, ns since
//                     1970, once a clock driver has set the kernel's wall
//                     clock (ADR-0031); from boot until then
//
// cpu/, mem/, power/ and the rest of 02 §5.1 come with what measures them.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-9p/ring_server.c"

enum : uint64_t { ROOT = 1, CLOCK, INFO, NOW, NODES };
static const vx_str NAMES[NODES] = {{}, VX_STR("/"), VX_STR("clock"), VX_STR("info"), VX_STR("now")};
static const uint64_t PARENT[NODES] = {0, ROOT, ROOT, CLOCK, CLOCK};

static vx_status fs_attach(void *ctx, vx_str aname, uint64_t *root) {
  (void)ctx;
  if (aname.len) return VX_ERR_NOT_FOUND;
  *root = ROOT;
  return VX_OK;
}

static vx_status fs_walk(void *ctx, uint64_t dir, vx_str name, uint64_t *child) {
  (void)ctx;
  for (uint64_t n = CLOCK; n < NODES; n++)
    if (PARENT[n] == dir && NAMES[n].len == name.len && memcmp(NAMES[n].ptr, name.ptr, name.len) == 0) {
      *child = n;
      return VX_OK;
    }
  return VX_ERR_NOT_FOUND;
}

static vx_status fs_parent(void *ctx, uint64_t n, uint64_t *parent) {
  (void)ctx;
  *parent = n < NODES && PARENT[n] ? PARENT[n] : ROOT;
  return VX_OK;
}

static bool is_dir(uint64_t n) { return n == ROOT || n == CLOCK; }

static vx_status fs_stat(void *ctx, uint64_t n, p9_stat *out) {
  (void)ctx;
  if (n == 0 || n >= NODES) return VX_ERR_NOT_FOUND;
  *out = (p9_stat){.qid = {is_dir(n) ? P9_QTDIR : P9_QTFILE, 0, n},
                   .mode = is_dir(n) ? P9_DMDIR | 0555 : 0444,
                   .name = NAMES[n],
                   .uid = VX_STR("sys"),
                   .gid = VX_STR("sys"),
                   .muid = VX_STR("sys")};
  return VX_OK;
}

static vx_status fs_open(void *ctx, uint64_t n, uint8_t mode) {
  (void)ctx, (void)n;
  return (mode & 3) == P9_OREAD ? VX_OK : VX_ERR_ACCESS;
}

static void put(vx_ndb_writer *w, const char *prefix, const char *suffix, uint64_t value, bool number) {
  char key[32];
  vx_str p = vx_cstr(prefix), s = vx_cstr(suffix);
  memcpy(key, p.ptr, p.len), memcpy(key + p.len, s.ptr, s.len + 1);
  if (number)
    vx_ndb_put_u64(w, key, value);
  else
    vx_ndb_flag(w, key);
}

static vx_status fs_read(void *ctx, uint64_t n, uint64_t offset, uint8_t *buf, uint32_t *count) {
  (void)ctx;
  char text[256];
  vx_ndb_writer w = {.buf = text, .cap = sizeof text};
  vx_clock_info info = {};
  vx_instant now = vx_clock_read();
  if (n == INFO && vx_clock_info_read(&info) == VX_OK) {
    bool tsc = info.flags & VX_CLOCK_TSC;
    put(&w, tsc ? "tsc" : "cntfrq", ".hz", info.counter_hz, true);
    if (info.flags & VX_CLOCK_INVARIANT) put(&w, tsc ? "tsc" : "cntvct", ".invariant", 0, false);
    if (info.flags & VX_CLOCK_USER) put(&w, tsc ? "tsc" : "cntvct", ".user", 0, false);
    vx_ndb_put(&w, "source", tsc ? VX_STR("tsc") : VX_STR("cntvct"));
    vx_ndb_end(&w);
  } else if (n == NOW) {
    vx_ndb_put_u64(&w, "monotonic", (uint64_t)now);
    vx_ndb_put_u64(&w, "realtime", (uint64_t)vx_clock_utc());
    vx_ndb_end(&w);
  } else if (is_dir(n)) {
    return VX_ERR_INVALID; // read as a directory, through readdir
  }
  size_t len = w.failed ? 0 : w.len;
  uint64_t left = offset < len ? len - offset : 0;
  if (*count > left) *count = (uint32_t)left;
  memcpy(buf, text + offset * (*count != 0), *count);
  return VX_OK;
}

static vx_status fs_readdir(void *ctx, uint64_t dir, uint32_t index, uint64_t *child) {
  (void)ctx;
  for (uint64_t n = CLOCK, seen = 0; n < NODES; n++)
    if (PARENT[n] == dir && seen++ == index) {
      *child = n;
      return VX_OK;
    }
  return VX_ERR_NOT_FOUND;
}

static p9_ring_server server = {
    .fs = {.attach = fs_attach,
           .walk = fs_walk,
           .parent = fs_parent,
           .stat = fs_stat,
           .open = fs_open,
           .read = fs_read,
           .readdir = fs_readdir},
    .name = VX_STR("sysfs"),
    .supported = P9_EXT_XATTR, // Tgetattr, for stat
};

const char *vx_main(void) {
  server.listen = vx_spawn_take("listen");
  if (!server.listen) {
    vx_print(VX_STR("sysfs: no listen channel\n"));
    return "no listen channel";
  }
  vx_print(VX_STR("sysfs: serving /srv/sys\n"));
  return p9_ring_serve(&server) == VX_OK ? nullptr : "cannot serve";
}
