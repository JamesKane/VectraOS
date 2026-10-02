// p9_server_test.c: lib/vx-9p's server framework and client against a small
// in-memory tree, then the hostile-client conformance test (docs/02 §2, 04 §7):
// raw messages that try to leave the attach root, misuse fids, and lie about
// sizes and counts.
//
//   /           (node 1)
//   /docs/      (node 2)
//   /docs/a.txt (node 3)  "alpha"
//   /b.txt      (node 4)  "bravo"
//   /docs/sub/  (node 5)  attach name "docs" starts at /docs

#include <string.h>

#include "check.h"
#include "../../lib/vx-9p/server.c"
#include "../../lib/vx-9p/client.c"

typedef struct ram_node {
  uint64_t parent;
  const char *name;
  bool dir;
  char data[64];
  uint32_t len;
  bool removed;
} ram_node;

static ram_node ram[16] = {
    [1] = {.parent = 0, .name = "/", .dir = true},
    [2] = {.parent = 1, .name = "docs", .dir = true},
    [3] = {.parent = 2, .name = "a.txt", .data = "alpha", .len = 5},
    [4] = {.parent = 1, .name = "b.txt", .data = "bravo", .len = 5},
    [5] = {.parent = 2, .name = "sub", .dir = true},
};
static uint64_t ram_count = 6;

static bool ram_live(uint64_t n) { return n && n < ram_count && !ram[n].removed; }

static vx_status ram_attach(void *ctx, vx_str aname, uint64_t *root) {
  (void)ctx;
  if (aname.len == 0)
    *root = 1;
  else if (aname.len == 4 && memcmp(aname.ptr, "docs", 4) == 0)
    *root = 2;
  else
    return VX_ERR_NOT_FOUND;
  return VX_OK;
}

static vx_status ram_walk(void *ctx, uint64_t dir, vx_str name, uint64_t *child) {
  (void)ctx;
  for (uint64_t i = 1; i < ram_count; i++) {
    if (!ram_live(i) || ram[i].parent != dir) continue;
    if (strlen(ram[i].name) == name.len && memcmp(ram[i].name, name.ptr, name.len) == 0) {
      *child = i;
      return VX_OK;
    }
  }
  return VX_ERR_NOT_FOUND;
}

static vx_status ram_parent(void *ctx, uint64_t node, uint64_t *parent) {
  (void)ctx;
  if (!ram_live(node) || !ram[node].parent) return VX_ERR_NOT_FOUND;
  *parent = ram[node].parent;
  return VX_OK;
}

static vx_status ram_stat(void *ctx, uint64_t node, p9_stat *out) {
  (void)ctx;
  if (!ram_live(node)) return VX_ERR_NOT_FOUND;
  ram_node *n = &ram[node];
  *out = (p9_stat){.qid = {n->dir ? P9_QTDIR : P9_QTFILE, 0, node},
                   .mode = n->dir ? P9_DMDIR | 0755 : 0644,
                   .length = n->dir ? 0 : n->len,
                   .name = (vx_str){n->name, strlen(n->name)},
                   .uid = VX_STR("jk"),
                   .gid = VX_STR("jk"),
                   .muid = VX_STR("")};
  return VX_OK;
}

static bool ram_not_yet;      // reads and writes answer SHOULD_WAIT, as a console with nothing typed does
static uint64_t ram_clone_to; // opening /docs/a.txt moves the fid here, as a clone file does
static uint64_t ram_opened_clunks[8], ram_opened_clunk_count;

static vx_status ram_open(void *ctx, uint64_t node, uint8_t mode) {
  (void)ctx;
  if (mode & P9_OTRUNC) ram[node].len = 0;
  return VX_OK;
}

static vx_status ram_clone(void *ctx, uint64_t node, uint8_t mode, uint64_t *opened) {
  (void)ctx, (void)mode;
  if (node != 3 || !ram_clone_to) return VX_ERR_NOT_FOUND;
  if (ram_not_yet) return VX_ERR_SHOULD_WAIT; // a listen file before a call comes
  *opened = ram_clone_to;
  return VX_OK;
}

static void ram_clunk(void *ctx, uint64_t node, bool opened) {
  (void)ctx;
  if (opened && ram_opened_clunk_count < 8) ram_opened_clunks[ram_opened_clunk_count++] = node;
}

static vx_status ram_read(void *ctx, uint64_t node, uint64_t offset, uint8_t *buf, uint32_t *count) {
  (void)ctx;
  if (ram_not_yet) return VX_ERR_SHOULD_WAIT;
  ram_node *n = &ram[node];
  uint32_t got = offset >= n->len ? 0 : n->len - (uint32_t)offset;
  if (got > *count) got = *count;
  memcpy(buf, n->data + offset * (got != 0), got);
  *count = got;
  return VX_OK;
}

static vx_status ram_readdir(void *ctx, uint64_t dir, uint32_t index, uint64_t *child) {
  (void)ctx;
  for (uint64_t i = 1; i < ram_count; i++) {
    if (!ram_live(i) || ram[i].parent != dir || i == dir) continue;
    if (index-- == 0) {
      *child = i;
      return VX_OK;
    }
  }
  return VX_ERR_NOT_FOUND;
}

static vx_status ram_write(void *ctx, uint64_t node, uint64_t offset, const uint8_t *buf, uint32_t *count) {
  (void)ctx;
  if (ram_not_yet) return VX_ERR_SHOULD_WAIT;
  ram_node *n = &ram[node];
  if (offset >= sizeof n->data) return VX_ERR_RANGE;
  if (*count > sizeof n->data - offset) *count = (uint32_t)(sizeof n->data - offset); // a short write
  memcpy(n->data + offset, buf, *count);
  if (offset + *count > n->len) n->len = (uint32_t)(offset + *count);
  return VX_OK;
}

static vx_status ram_create(void *ctx, uint64_t dir, vx_str name, uint32_t perm, uint8_t mode,
                            uint64_t *node) {
  (void)ctx, (void)mode;
  uint64_t existing;
  if (ram_walk(ctx, dir, name, &existing) == VX_OK) return VX_ERR_EXISTS;
  if (ram_count == 16 || name.len > 15) return VX_ERR_NO_MEMORY;
  static char names[16][16];
  memcpy(names[ram_count], name.ptr, name.len);
  ram[ram_count] = (ram_node){.parent = dir, .name = names[ram_count], .dir = (perm & P9_DMDIR) != 0};
  *node = ram_count++;
  return VX_OK;
}

static vx_status ram_remove(void *ctx, uint64_t node) {
  (void)ctx;
  uint64_t child;
  if (ram[node].dir && ram_readdir(ctx, node, 0, &child) == VX_OK) return VX_ERR_ACCESS; // not empty
  ram[node].removed = true;
  return VX_OK;
}

static p9_server server = {
    .fs = {.attach = ram_attach,
           .walk = ram_walk,
           .parent = ram_parent,
           .stat = ram_stat,
           .open = ram_open,
           .read = ram_read,
           .readdir = ram_readdir,
           .write = ram_write,
           .create = ram_create,
           .remove = ram_remove,
           .clone = ram_clone,
           .clunk = ram_clunk},
    .max_msize = 8192,
    .supported = P9_EXT_DREF | P9_EXT_NOTIFY,
};

static size_t loopback(void *ctx, const uint8_t *req, size_t len, uint8_t *resp, size_t cap) {
  return p9_serve(ctx, req, len, resp, cap);
}

static void test_client(void) {
  static uint8_t tbuf[16384], rbuf[16384];
  p9_client c = {.rpc = loopback, .ctx = &server, .tbuf = tbuf, .rbuf = rbuf, .bufsize = sizeof tbuf};
  CHECK(p9c_version(&c, 16384, P9_EXT_DREF | P9_EXT_MAP) == VX_OK);
  CHECK(c.msize == 8192 && c.dialect == P9_2000X && c.extensions == P9_EXT_DREF); // the intersection

  uint32_t root, f;
  CHECK(p9c_attach(&c, VX_STR(""), &root) == VX_OK);
  CHECK(p9c_walk(&c, root, VX_STR("docs/a.txt"), &f) == VX_OK);
  CHECK(p9c_open(&c, f, P9_OREAD) == VX_OK);
  char buf[64];
  CHECK(p9c_read(&c, f, 0, buf, sizeof buf) == 5 && memcmp(buf, "alpha", 5) == 0);
  CHECK(p9c_read(&c, f, 2, buf, 2) == 2 && memcmp(buf, "ph", 2) == 0);
  CHECK(p9c_read(&c, f, 5, buf, sizeof buf) == 0);
  CHECK(p9c_write(&c, f, 0, "x", 1) == VX_ERR_ACCESS); // opened for reading
  CHECK(p9c_clunk(&c, f) == VX_OK);
  CHECK(p9c_clunk(&c, f) == VX_ERR_BAD_HANDLE);

  // A directory reads as whole stat entries.
  CHECK(p9c_walk(&c, root, VX_STR(""), &f) == VX_OK);
  CHECK(p9c_open(&c, f, P9_OREAD) == VX_OK);
  uint8_t dir[512];
  int64_t n = p9c_read(&c, f, 0, dir, sizeof dir);
  int entries = 0;
  for (int64_t off = 0; off + 2 <= n;) {
    uint32_t len = dir[off] | (uint32_t)dir[off + 1] << 8;
    p9_stat st;
    CHECK(p9_stat_decode(dir + off, len + 2, &st) == VX_OK);
    off += len + 2;
    entries++;
  }
  CHECK(entries == 2); // docs and b.txt
  CHECK(p9c_read(&c, f, (uint64_t)n, dir, sizeof dir) == 0);
  CHECK(p9c_read(&c, f, 1, dir, sizeof dir) == VX_ERR_RANGE); // not where the last read ended
  p9c_clunk(&c, f);

  // Create, write, read back, stat, remove.
  CHECK(p9c_walk(&c, root, VX_STR("docs"), &f) == VX_OK);
  CHECK(p9c_create(&c, f, VX_STR("new.txt"), 0644, P9_ORDWR) == VX_OK);
  CHECK(p9c_write(&c, f, 0, "hello", 5) == 5);
  CHECK(p9c_read(&c, f, 0, buf, sizeof buf) == 5 && memcmp(buf, "hello", 5) == 0);
  p9_stat st;
  CHECK(p9c_stat(&c, f, &st) == VX_OK && st.length == 5 && st.name.len == 7);
  CHECK(p9c_remove(&c, f) == VX_OK);
  CHECK(p9c_walk(&c, root, VX_STR("docs/new.txt"), &f) == VX_ERR_NOT_FOUND);
  CHECK(p9c_walk(&c, root, VX_STR("docs/a.txt/../../b.txt"), &f) == VX_OK); // .. inside the root is fine
  CHECK(p9c_stat(&c, f, &st) == VX_OK && st.qid.path == 4);
  p9c_clunk(&c, f);
}

// --- The hostile client: raw messages, straight to p9_serve ---

static uint8_t resp[16384];
static p9_msg reply;

static vx_status raw(p9_msg t) {
  uint8_t req[2048];
  size_t n = p9_encode(&t, req, sizeof req);
  if (!n) return VX_ERR_TOO_SMALL;
  size_t reply_len = p9_serve(&server, req, n, resp, sizeof resp);
  if (!reply_len) return VX_ERR_PEER_CLOSED; // the server would hang up
  if (p9_decode(resp, reply_len, &reply) != VX_OK || reply.tag != t.tag) return VX_ERR_INVALID;
  return reply.type == P9_Rerror ? p9_error_status(reply.ename) : VX_OK;
}

static p9_msg walk(uint32_t fid, uint32_t newfid, uint16_t n, const char *const *names) {
  p9_msg t = {.type = P9_Twalk, .tag = 1, .fid = fid, .newfid = newfid, .nwname = n};
  for (uint16_t i = 0; i < n; i++) t.wname[i] = (vx_str){names[i], strlen(names[i])};
  return t;
}

static void test_hostile_client(void) {
  // A fresh session: nothing works before Tversion, and a tiny msize is refused.
  server.msize = 0;
  CHECK(raw((p9_msg){.type = P9_Tattach, .tag = 1, .fid = 1, .afid = P9_NOFID}) == VX_ERR_BAD_STATE);
  CHECK(raw((p9_msg){.type = P9_Tversion, .tag = P9_NOTAG, .msize = 100, .version = VX_STR("9P2000")}) !=
        VX_OK);
  CHECK(raw((p9_msg){.type = P9_Tversion, .tag = P9_NOTAG, .msize = 4096, .version = VX_STR("9P2000.L")}) ==
        VX_OK);
  CHECK(reply.msize == 4096 && reply.version.len == 6); // .L is answered with plain 9P2000

  // Attached at "docs": no walk may leave /docs.
  CHECK(raw((p9_msg){.type = P9_Tattach, .tag = 1, .fid = 1, .afid = P9_NOFID, .aname = VX_STR("docs")}) ==
        VX_OK);
  CHECK(raw((p9_msg){.type = P9_Tattach, .tag = 1, .fid = 1, .afid = P9_NOFID}) ==
        VX_ERR_BAD_STATE); // fid in use
  CHECK(raw((p9_msg){.type = P9_Tattach, .tag = 1, .fid = 9, .afid = 3}) ==
        VX_ERR_UNSUPPORTED); // no auth yet
  static const char *const up[] = {"..", "..", "..", "..", ".."};
  CHECK(raw(walk(1, 2, 5, up)) == VX_OK && reply.nwqid == 5 && reply.wqid[4].path == 2); // still /docs
  static const char *const around[] = {"sub", "..", "..", "..", "b.txt"};
  CHECK(raw(walk(1, 3, 5, around)) == VX_OK && reply.nwqid == 4); // b.txt is outside: not found
  CHECK(raw((p9_msg){.type = P9_Tstat, .tag = 1, .fid = 3}) ==
        VX_ERR_BAD_HANDLE); // the partial walk made no fid
  static const char *const sneaky[] = {"sub/../../b.txt"};
  CHECK(raw(walk(1, 3, 1, sneaky)) == VX_ERR_INVALID);
  static const char *const dot[] = {"."};
  CHECK(raw(walk(1, 3, 1, dot)) == VX_ERR_INVALID);
  static const char *const empty[] = {""};
  CHECK(raw(walk(1, 3, 1, empty)) == VX_ERR_INVALID);
  // Names are UTF-8 with no control characters (ADR-0013).
  static const char *const newline[] = {"a\nb"}, *const bad_utf8[] = {"\xc3"},
                           *const overlong[] = {"\xc0\xae"};
  CHECK(raw(walk(1, 3, 1, newline)) == VX_ERR_INVALID);
  CHECK(raw(walk(1, 3, 1, bad_utf8)) == VX_ERR_INVALID);
  CHECK(raw(walk(1, 3, 1, overlong)) == VX_ERR_INVALID);

  // Fids: unknown, taken, reserved, open, too many.
  static const char *const a[] = {"a.txt"};
  CHECK(raw(walk(77, 3, 1, a)) == VX_ERR_BAD_HANDLE);
  CHECK(raw(walk(1, 2, 1, a)) == VX_ERR_BAD_STATE); // newfid 2 is taken
  CHECK(raw(walk(1, P9_NOFID, 1, a)) == VX_ERR_BAD_STATE);
  CHECK(raw(walk(1, 3, 1, a)) == VX_OK);
  CHECK(raw((p9_msg){.type = P9_Tread, .tag = 1, .fid = 3, .count = 10}) == VX_ERR_ACCESS); // not open
  CHECK(raw((p9_msg){.type = P9_Topen, .tag = 1, .fid = 3, .mode = P9_OREAD}) == VX_OK);
  CHECK(raw((p9_msg){.type = P9_Topen, .tag = 1, .fid = 3, .mode = P9_OREAD}) == VX_ERR_BAD_STATE); // twice
  CHECK(raw(walk(3, 4, 0, nullptr)) == VX_ERR_BAD_STATE); // an open fid
  CHECK(raw((p9_msg){.type = P9_Twrite, .tag = 1, .fid = 3, .data = {(const uint8_t *)"x", 1}}) ==
        VX_ERR_ACCESS);
  CHECK(raw((p9_msg){.type = P9_Tread, .tag = 1, .fid = 3, .count = 0xffff'ffff}) == VX_OK);
  CHECK(reply.count == 5); // clamped: the read cannot run past msize or the file
  CHECK(raw((p9_msg){.type = P9_Topen, .tag = 1, .fid = 2, .mode = P9_OWRITE}) ==
        VX_ERR_ACCESS); // a directory
  CHECK(raw((p9_msg){.type = P9_Tcreate, .tag = 1, .fid = 2, .name = VX_STR(".."), .mode = P9_OREAD}) ==
        VX_ERR_INVALID);
  CHECK(raw((p9_msg){.type = P9_Tcreate, .tag = 1, .fid = 2, .name = VX_STR("a/b"), .mode = P9_OREAD}) ==
        VX_ERR_INVALID);
  CHECK(
      raw((p9_msg){.type = P9_Tcreate, .tag = 1, .fid = 2, .name = VX_STR("tab\there"), .mode = P9_OREAD}) ==
      VX_ERR_INVALID);
  uint32_t held = 0, made = 0;
  for (uint32_t i = 0; i < P9_MAX_FIDS; i++) held += server.fids[i].used;
  for (uint32_t fid = 100; fid < 100 + P9_MAX_FIDS; fid++)
    if (raw(walk(1, fid, 0, nullptr)) == VX_OK) made++;
  CHECK(held > 0 && made == P9_MAX_FIDS - held); // exactly the room there was, and no more
  CHECK(raw(walk(1, 999, 0, nullptr)) == VX_ERR_NO_MEMORY);

  // Messages that are not requests, or not messages at all, end the connection.
  CHECK(raw((p9_msg){.type = P9_Rclunk, .tag = 1}) == VX_ERR_PEER_CLOSED);
  uint8_t junk[16] = {16, 0, 0, 0, 120, 1, 0, 1, 2, 3};
  CHECK(p9_serve(&server, junk, sizeof junk, resp, sizeof resp) == 0);
  CHECK(raw((p9_msg){.type = P9_Twstat, .tag = 1, .fid = 1, .stat = {junk, 4}}) == VX_ERR_UNSUPPORTED);
}

// A read or write the file system cannot do yet is deferred, without a reply,
// and the same request served again later completes.
static void test_deferral(void) {
  server = (p9_server){.fs = server.fs, .max_msize = 8192};
  uint8_t req[256];
  size_t n;
  p9_msg m;
#define SERVE(...)                                                                                           \
  (n = p9_encode(&(p9_msg){__VA_ARGS__}, req, sizeof req), p9_serve(&server, req, n, resp, sizeof resp))
  CHECK(SERVE(.type = P9_Tversion, .tag = P9_NOTAG, .msize = 8192, .version = VX_STR("9P2000")) > 0);
  CHECK(SERVE(.type = P9_Tattach, .tag = 1, .fid = 1, .afid = P9_NOFID) > 0);
  CHECK(SERVE(.type = P9_Twalk, .tag = 1, .fid = 1, .newfid = 2, .nwname = 1, .wname = {VX_STR("b.txt")}) >
        0);
  CHECK(SERVE(.type = P9_Topen, .tag = 1, .fid = 2, .mode = P9_ORDWR) > 0);
  ram_not_yet = true;
  CHECK(SERVE(.type = P9_Tread, .tag = 9, .fid = 2, .count = 100) == P9_DEFER);
  uint8_t held[256];
  size_t held_len = n;
  memcpy(held, req, n);
  CHECK(SERVE(.type = P9_Twrite, .tag = 10, .fid = 2, .data = {(const uint8_t *)"zz", 2}) == P9_DEFER);
  CHECK(SERVE(.type = P9_Tstat, .tag = 11, .fid = 2) > 0); // everything else still completes
  ram_not_yet = false;
  n = p9_serve(&server, held, held_len, resp, sizeof resp);
  CHECK(n > 0 && p9_decode(resp, n, &m) == VX_OK && m.type == P9_Rread && m.tag == 9 && m.count == 5);
  size_t reply_len;
  // An open that must wait (a listen file) is held too, and the fid is not
  // open until it is made again and succeeds.
  ram_clone_to = 4;
  ram_not_yet = true;
  CHECK(SERVE(.type = P9_Twalk, .tag = 1, .fid = 1, .newfid = 3, .nwname = 2,
              .wname = {VX_STR("docs"), VX_STR("a.txt")}) > 0);
  CHECK(SERVE(.type = P9_Topen, .tag = 13, .fid = 3, .mode = P9_OREAD) == P9_DEFER);
  held_len = n;
  memcpy(held, req, n);
  reply_len = SERVE(.type = P9_Tread, .tag = 14, .fid = 3, .count = 10); // not open: an error, not a wait
  CHECK(reply_len > 0 && reply_len != P9_DEFER && p9_decode(resp, reply_len, &m) == VX_OK &&
        m.type == P9_Rerror);
  ram_not_yet = false;
  n = p9_serve(&server, held, held_len, resp, sizeof resp);
  CHECK(n > 0 && p9_decode(resp, n, &m) == VX_OK && m.type == P9_Ropen && m.tag == 13 && m.qid.path == 4);
  ram_clone_to = 0;
  // An unknown fid is an error, not a wait.
  reply_len = SERVE(.type = P9_Tread, .tag = 12, .fid = 77, .count = 1);
  CHECK(reply_len > 0 && reply_len != P9_DEFER && p9_decode(resp, reply_len, &m) == VX_OK &&
        m.type == P9_Rerror);
#undef SERVE
}

// An open may move its fid to another node (a clone file); the fid then reads,
// stats and clunks as that node, and clunk says which fids were open.
static void test_open_moves(void) {
  static uint8_t tbuf[16384], rbuf[16384];
  p9_server s = server;
  p9_client c = {.rpc = loopback, .ctx = &s, .tbuf = tbuf, .rbuf = rbuf, .bufsize = sizeof tbuf};
  uint32_t root = 0, f = 0, g = 0;
  CHECK(p9c_version(&c, 8192, 0) == VX_OK && p9c_attach(&c, VX_STR(""), &root) == VX_OK);
  ram_clone_to = 4;
  ram_opened_clunk_count = 0;
  CHECK(p9c_walk(&c, root, VX_STR("docs/a.txt"), &f) == VX_OK && p9c_open(&c, f, P9_OREAD) == VX_OK);
  char buf[16];
  CHECK(p9c_read(&c, f, 0, buf, sizeof buf) == 5 && memcmp(buf, "bravo", 5) == 0);
  p9_stat st;
  CHECK(p9c_stat(&c, f, &st) == VX_OK && st.qid.path == 4);
  CHECK(p9c_walk(&c, root, VX_STR("b.txt"), &g) == VX_OK);
  CHECK(p9c_clunk(&c, g) == VX_OK && ram_opened_clunk_count == 0); // never opened
  CHECK(p9c_clunk(&c, f) == VX_OK && ram_opened_clunk_count == 1 && ram_opened_clunks[0] == 4);
  ram_clone_to = 0;
}

int main(void) {
  test_client();
  test_open_moves();
  test_deferral();
  test_hostile_client();
  return check_result();
}
