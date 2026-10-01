// p9_server_fuzz.c: arbitrary 9P sessions against vx-9p's server framework.
// The input is a run of messages, each framed by its own size[4]; each goes
// to p9_serve on a fresh server over a small read-only tree. Every reply must
// decode and answer the same tag, and no walk may ever reach a node outside the
// attach root: while every attach in the session is at "docs", nodes 1 and 4
// must stay out of reach, and the framework must never ask for the parent of
// /docs.

#include <stdlib.h>
#include <string.h>

#include "../../lib/vx-9p/server.c"

//   1 /   2 /docs   3 /docs/a.txt   4 /b.txt   5 /docs/sub
static const struct {
  uint64_t parent;
  const char *name;
  bool dir;
} tree[] = {{0, "", false},      {0, "/", true},      {1, "docs", true},
            {2, "a.txt", false}, {1, "b.txt", false}, {2, "sub", true}};
static constexpr uint64_t NODES = sizeof tree / sizeof tree[0];
static bool attached_whole; // some fid was attached at /

static vx_status fs_attach(void *ctx, vx_str aname, uint64_t *root) {
  (void)ctx;
  *root = aname.len ? 2 : 1;
  if (*root == 1) attached_whole = true;
  return VX_OK;
}

static vx_status fs_walk(void *ctx, uint64_t dir, vx_str name, uint64_t *child) {
  (void)ctx;
  for (uint64_t i = 1; i < NODES; i++)
    if (tree[i].parent == dir && strlen(tree[i].name) == name.len &&
        memcmp(tree[i].name, name.ptr, name.len) == 0) {
      *child = i;
      return VX_OK;
    }
  return VX_ERR_NOT_FOUND;
}

static vx_status fs_parent(void *ctx, uint64_t node, uint64_t *parent) {
  (void)ctx;
  if (node == 2 && !attached_whole) abort(); // the framework must never ask past the root
  if (!tree[node].parent) return VX_ERR_NOT_FOUND;
  *parent = tree[node].parent;
  return VX_OK;
}

static vx_status fs_stat(void *ctx, uint64_t node, p9_stat *out) {
  (void)ctx;
  if (!attached_whole && (node == 1 || node == 4)) abort(); // escaped the root
  *out = (p9_stat){.qid = {tree[node].dir ? P9_QTDIR : P9_QTFILE, 0, node},
                   .mode = tree[node].dir ? P9_DMDIR | 0755 : 0644,
                   .length = tree[node].dir ? 0 : 5,
                   .name = (vx_str){tree[node].name, strlen(tree[node].name)}};
  return VX_OK;
}

static vx_status fs_open(void *ctx, uint64_t node, uint8_t mode) {
  (void)ctx, (void)node;
  return (mode & 3) == P9_OREAD ? VX_OK : VX_ERR_ACCESS;
}

static vx_status fs_read(void *ctx, uint64_t node, uint64_t offset, uint8_t *buf, uint32_t *count) {
  (void)ctx, (void)node;
  uint32_t n = offset >= 5 ? 0 : 5 - (uint32_t)offset;
  if (n > *count) n = *count;
  memset(buf, 'x', n);
  *count = n;
  return VX_OK;
}

static vx_status fs_readdir(void *ctx, uint64_t dir, uint32_t index, uint64_t *child) {
  (void)ctx;
  for (uint64_t i = 1; i < NODES; i++)
    if (tree[i].parent == dir && index-- == 0) {
      *child = i;
      return VX_OK;
    }
  return VX_ERR_NOT_FOUND;
}

// libFuzzer calls it by name, so it cannot be static.
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size); // NOLINT(misc-use-internal-linkage)

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  static p9_server s;
  static uint8_t resp[8192];
  s = (p9_server){.fs = {.attach = fs_attach,
                         .walk = fs_walk,
                         .parent = fs_parent,
                         .stat = fs_stat,
                         .open = fs_open,
                         .read = fs_read,
                         .readdir = fs_readdir},
                  .max_msize = 8192,
                  .supported = P9_EXT_DREF};
  attached_whole = false;
  for (size_t pos = 0; size - pos >= 4;) {
    uint32_t n = data[pos] | (uint32_t)data[pos + 1] << 8 | (uint32_t)data[pos + 2] << 16 |
                 (uint32_t)data[pos + 3] << 24;
    if (n < 4 || n > size - pos) break;
    size_t rn = p9_serve(&s, data + pos, n, resp, sizeof resp);
    if (rn) {
      p9_msg r;
      if (p9_decode(resp, rn, &r) != VX_OK) abort();
      if (r.tag != (uint16_t)(data[pos + 5] | data[pos + 6] << 8)) abort();
    }
    pos += n;
  }
  return 0;
}
