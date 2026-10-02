// nullfs: /dev's null, zero, random and urandom (02 §5), posted as /srv/null.
//
//   null      reads as empty; takes any write
//   zero      reads as zeros; takes any write
//   random    random bytes, from a generator (lib/vx-rand) seeded with the
//   urandom   entropy svcd gives it; the same generator, as on Linux since 5.6
//
// Without a seed from svcd, random and urandom refuse to be read rather than
// give bytes nobody should trust.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-9p/ring_server.c"
#include "../../lib/vx-rand/drbg.c"

enum : uint64_t { ROOT = 1, NUL, ZERO, RANDOM, URANDOM, NODES };
static const vx_str NAMES[NODES] = {
    {}, VX_STR("/"), VX_STR("null"), VX_STR("zero"), VX_STR("random"), VX_STR("urandom")};

static vx_drbg randomness;

static vx_status fs_attach(void *ctx, vx_str aname, uint64_t *root) {
  (void)ctx;
  if (aname.len) return VX_ERR_NOT_FOUND;
  *root = ROOT;
  return VX_OK;
}

static vx_status fs_walk(void *ctx, uint64_t dir, vx_str name, uint64_t *child) {
  (void)ctx;
  for (uint64_t n = NUL; dir == ROOT && n < NODES; n++)
    if (NAMES[n].len == name.len && memcmp(NAMES[n].ptr, name.ptr, name.len) == 0) {
      *child = n;
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
  *out = (p9_stat){.qid = {n == ROOT ? P9_QTDIR : P9_QTFILE, 0, n},
                   .mode = n == ROOT ? P9_DMDIR | 0555 : 0666,
                   .name = NAMES[n],
                   .uid = VX_STR("sys"),
                   .gid = VX_STR("sys"),
                   .muid = VX_STR("sys")};
  return VX_OK;
}

static vx_status fs_open(void *ctx, uint64_t n, uint8_t mode) {
  (void)ctx;
  if (n == ROOT && (mode & 3) != P9_OREAD) return VX_ERR_ACCESS;
  if ((n == RANDOM || n == URANDOM) && !randomness.seeded && (mode & 3) != P9_OWRITE) return VX_ERR_BAD_STATE;
  return VX_OK;
}

static vx_status fs_read(void *ctx, uint64_t n, uint64_t offset, uint8_t *buf, uint32_t *count) {
  (void)ctx, (void)offset;
  if (n == NUL)
    *count = 0;
  else if (n == ZERO)
    memset(buf, 0, *count);
  else
    vx_drbg_read(&randomness, buf, *count);
  return VX_OK;
}

// What is written to random or urandom is mixed in, as on Linux; it is not
// counted as a seed. All of it is taken (*count as it was).
// NOLINTNEXTLINE(readability-non-const-parameter): p9_fs's signature
static vx_status fs_write(void *ctx, uint64_t n, uint64_t offset, const uint8_t *buf, uint32_t *count) {
  (void)ctx, (void)offset;
  if (n == RANDOM || n == URANDOM) vx_drbg_mix(&randomness, buf, *count, false);
  return VX_OK;
}

static vx_status fs_readdir(void *ctx, uint64_t dir, uint32_t index, uint64_t *child) {
  (void)ctx;
  if (dir != ROOT || index >= NODES - NUL) return VX_ERR_NOT_FOUND;
  *child = NUL + index;
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
    .name = VX_STR("nullfs"),
    .supported = P9_EXT_XATTR, // Tgetattr, for stat; nothing can be changed
};

const char *vx_main(void) {
  server.listen = vx_spawn_take("listen");
  if (!server.listen) {
    vx_print(VX_STR("nullfs: no listen channel\n"));
    return "no listen channel";
  }
  vx_ndb_record rec;
  vx_str seed = vx_spawn_record("entropy", &rec) ? vx_ndb_get(&rec, "entropy") : (vx_str){};
  if (seed.len >= 16) vx_drbg_mix(&randomness, seed.ptr, seed.len, true);
  vx_print(randomness.seeded ? VX_STR("nullfs: serving /srv/null\n")
                             : VX_STR("nullfs: serving /srv/null, without entropy: random cannot be read\n"));
  return p9_ring_serve(&server) == VX_OK ? nullptr : "cannot serve";
}
