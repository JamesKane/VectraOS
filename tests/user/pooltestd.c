// pooltestd: a file server whose reads wait with the server let go (M6
// step 6d5a), for pooltest (tests/user/pooltest.c), posted as /srv/pooltest
// with four threads:
//   fast  answers at once
//   slow  waits 300 ms, let go
//   gate  waits, let go, until open is written
//   open  a write opens the gate (and shuts it again for the next read)
//   peak  how many reads were let go at once, at most

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-9p/ring_server.c"

enum : uint64_t { ROOT, FAST, SLOW, GATE, OPEN, PEAK, NFILES };
static const char *const NAMES[NFILES] = {"/", "fast", "slow", "gate", "open", "peak"};

static _Atomic uint32_t gate;  // its generation: a write moves it on
static uint32_t waiting, peak; // the server's lock held for these

static vx_status fs_attach(void *ctx, vx_str aname, uint64_t *root) {
  (void)ctx, (void)aname;
  *root = ROOT;
  return VX_OK;
}

static vx_status fs_walk(void *ctx, uint64_t dir, vx_str name, uint64_t *child) {
  (void)ctx;
  if (dir != ROOT) return VX_ERR_NOT_FOUND;
  for (uint64_t i = 1; i < NFILES; i++)
    if (name.len == vx_cstr(NAMES[i]).len && !memcmp(name.ptr, NAMES[i], name.len)) {
      *child = i;
      return VX_OK;
    }
  return VX_ERR_NOT_FOUND;
}

static vx_status fs_parent(void *ctx, uint64_t n, uint64_t *parent) {
  (void)ctx, (void)n;
  *parent = ROOT;
  return VX_OK;
}

static vx_status fs_stat(void *ctx, uint64_t n, p9_stat *out) {
  (void)ctx;
  if (n >= NFILES) return VX_ERR_NOT_FOUND;
  *out = (p9_stat){.qid = {n == ROOT ? P9_QTDIR : P9_QTFILE, 0, n},
                   .mode = n == ROOT ? P9_DMDIR | 0555 : 0666,
                   .name = vx_cstr(NAMES[n]),
                   .uid = VX_STR("sys"),
                   .gid = VX_STR("sys"),
                   .muid = VX_STR("sys")};
  return VX_OK;
}

static vx_status fs_open(void *ctx, uint64_t n, uint8_t mode) {
  (void)ctx, (void)mode;
  return n < NFILES ? VX_OK : VX_ERR_NOT_FOUND;
}

static vx_status fs_readdir(void *ctx, uint64_t dir, uint32_t index, uint64_t *child) {
  (void)ctx;
  if (dir != ROOT || index + 1 >= NFILES) return VX_ERR_NOT_FOUND;
  *child = index + 1;
  return VX_OK;
}

// Waits let go: until the deadline, or until the gate moves on from `from`.
static void wait_released(vx_instant deadline, bool gated, uint32_t from) {
  if (++waiting > peak) peak = waiting;
  p9_release();
  if (gated) {
    while (atomic_load(&gate) == from) vx_futex_wait(&gate, from, VX_INFINITE);
  } else {
    static thread_local _Atomic uint32_t never;
    while (vx_clock_read() < deadline) vx_futex_wait(&never, 0, deadline);
  }
  p9_acquire();
  waiting--;
}

static vx_status fs_read(void *ctx, uint64_t n, uint64_t offset, uint8_t *buf, uint32_t *count) {
  (void)ctx;
  char text[32];
  size_t len = 0;
  if (n == SLOW) wait_released(vx_clock_read() + 300'000'000, false, 0);
  if (n == GATE) wait_released(VX_INFINITE, true, atomic_load(&gate));
  if (n == PEAK) {
    text[len++] = (char)('0' + peak % 10); // never past 9: four threads
    text[len++] = '\n';
  } else if (n != ROOT) {
    len = vx_cstr(NAMES[n]).len;
    memcpy(text, NAMES[n], len);
    text[len++] = '\n';
  }
  size_t got = offset < len ? len - offset : 0;
  if (got > *count) got = *count;
  memcpy(buf, text + offset, got);
  *count = (uint32_t)got;
  return VX_OK;
}

// NOLINTNEXTLINE(readability-non-const-parameter): p9_fs's signature
static vx_status fs_write(void *ctx, uint64_t n, uint64_t offset, const uint8_t *buf, uint32_t *count) {
  (void)ctx, (void)offset, (void)buf;
  if (n != OPEN) return VX_ERR_ACCESS;
  atomic_fetch_add(&gate, 1);
  vx_futex_wake(&gate, UINT32_MAX);
  (void)count; // all of it
  return VX_OK;
}

static p9_ring_server server = {
    .fs = {.attach = fs_attach,
           .walk = fs_walk,
           .parent = fs_parent,
           .stat = fs_stat,
           .open = fs_open,
           .read = fs_read,
           .readdir = fs_readdir,
           .write = fs_write},
    .name = VX_STR("pooltestd"),
    .max_threads = 4,
};

const char *vx_main(void) {
  server.listen = vx_spawn_take("listen");
  if (!server.listen) return "no listen channel";
  vx_print(VX_STR("pooltestd: serving /srv/pooltest\n"));
  return p9_ring_serve(&server) == VX_OK ? nullptr : "cannot serve";
}
