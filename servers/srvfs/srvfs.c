// srvfs: /srv as a file tree (M6 step 6d4d2a), as 9front's srv(3) has it,
// posted as /srv/srv and mounted on /srv by the namespace templates.
//
// Each file is a post: a connector (a listen channel's client end) under a
// name, owned by whoever made it, with permissions. Posting is two steps,
// as 9front's: create /srv/NAME (anyone may: the directory is 0777), then
// write it with the connector beside the message (9Px's srv extension,
// docs/proto/srv.md). Opening a post gives a duplicate of its connector
// beside the Ropen, which the opener connects through and mounts; the mode
// is checked against the owner's bits or the others' (there are no groups
// here). Removing a post, its owner's to do, drops the connector: the
// server behind it goes on for whoever is connected already. A post made
// with ORCLOSE goes when its maker's fid does.
//
// svcd lists here the manifest posts that say srvmode= (owned by sys); the
// rest stay reachable only by the grants manifests give (01 §2).

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-9p/ring_server.c"

static constexpr uint32_t SRV_POSTS = 64, SRV_USERS = 64, SRV_NAME = 64;

typedef struct post {
  bool used;
  char name[SRV_NAME];
  uint8_t name_len;
  uint32_t owner; // a user's index
  uint32_t mode;  // its permission bits
  uint32_t gen;   // the qid's version: a name made again is another file
  vx_handle connector;
} post;

static post posts[SRV_POSTS];
static char users[SRV_USERS][32];
static uint8_t user_len[SRV_USERS];
static uint32_t nusers;

// A node: the user who reached it, in the high half; the post's index plus
// 1 in the low half, 0 for the directory.
static uint64_t node_of(uint32_t user, uint32_t index) { return (uint64_t)user << 32 | index; }
static uint32_t user_of(uint64_t node) { return (uint32_t)(node >> 32); }
static uint32_t index_of(uint64_t node) { return (uint32_t)node; }

static post *post_of(uint64_t node) {
  uint32_t i = index_of(node);
  return i && i <= SRV_POSTS && posts[i - 1].used ? &posts[i - 1] : nullptr;
}

static vx_status fs_attach_as(void *ctx, vx_str aname, vx_str uname, uint64_t *root) {
  (void)ctx;
  if (aname.len) return VX_ERR_NOT_FOUND;
  if (!uname.len || uname.len >= sizeof users[0]) uname = VX_STR("none");
  uint32_t u = 0;
  while (u < nusers && !(user_len[u] == uname.len && !memcmp(users[u], uname.ptr, uname.len))) u++;
  if (u == nusers) {
    if (nusers == SRV_USERS) return VX_ERR_NO_MEMORY;
    memcpy(users[u], uname.ptr, uname.len);
    user_len[u] = (uint8_t)uname.len;
    nusers++;
  }
  *root = node_of(u, 0);
  return VX_OK;
}

static vx_status fs_attach(void *ctx, vx_str aname, uint64_t *root) {
  return fs_attach_as(ctx, aname, VX_STR("none"), root);
}

static vx_status fs_walk(void *ctx, uint64_t dir, vx_str name, uint64_t *child) {
  (void)ctx;
  if (index_of(dir)) return VX_ERR_NOT_FOUND;
  for (uint32_t i = 0; i < SRV_POSTS; i++)
    if (posts[i].used && posts[i].name_len == name.len && !memcmp(posts[i].name, name.ptr, name.len)) {
      *child = node_of(user_of(dir), i + 1);
      return VX_OK;
    }
  return VX_ERR_NOT_FOUND;
}

static vx_status fs_parent(void *ctx, uint64_t node, uint64_t *parent) {
  (void)ctx;
  *parent = node_of(user_of(node), 0);
  return VX_OK;
}

static vx_status fs_stat(void *ctx, uint64_t node, p9_stat *out) {
  (void)ctx;
  if (!index_of(node)) {
    *out = (p9_stat){.qid = {P9_QTDIR, 0, 0},
                     .mode = P9_DMDIR | 0777,
                     .name = VX_STR("/"),
                     .uid = VX_STR("sys"),
                     .gid = VX_STR("sys"),
                     .muid = VX_STR("sys")};
    return VX_OK;
  }
  const post *p = post_of(node);
  if (!p) return VX_ERR_NOT_FOUND;
  vx_str owner = {users[p->owner], user_len[p->owner]};
  *out = (p9_stat){.qid = {P9_QTFILE, p->gen, index_of(node)},
                   .mode = p->mode,
                   .name = {p->name, p->name_len},
                   .uid = owner,
                   .gid = owner,
                   .muid = owner};
  return VX_OK;
}

// Whether the user may open the post so: the owner's bits or the others'.
static bool may(const post *p, uint32_t user, uint8_t mode) {
  uint32_t bits = user == p->owner ? (p->mode >> 6) & 7 : p->mode & 7;
  bool r = (mode & 3) == P9_OREAD || (mode & 3) == P9_ORDWR,
       w = (mode & 3) == P9_OWRITE || (mode & 3) == P9_ORDWR;
  return (!r || (bits & 4)) && (!w || (bits & 2));
}

static vx_status fs_open(void *ctx, uint64_t node, uint8_t mode) {
  (void)ctx;
  if (!index_of(node)) return (mode & 3) == P9_OREAD ? VX_OK : VX_ERR_ACCESS;
  const post *p = post_of(node);
  if (!p) return VX_ERR_NOT_FOUND;
  if (mode & P9_OTRUNC) return VX_ERR_ACCESS;
  return may(p, user_of(node), mode) ? VX_OK : VX_ERR_ACCESS;
}

// The connector, duplicated, beside the Ropen: what a mount connects through.
static vx_status fs_open_handle(void *ctx, uint64_t node, uint8_t mode, vx_handle *out) {
  (void)ctx, (void)mode;
  if (!index_of(node)) return VX_OK; // the directory: nothing beside its Ropen
  const post *p = post_of(node);
  if (!p) return VX_ERR_NOT_FOUND;
  if (!p->connector) return VX_ERR_BAD_STATE; // made, not posted yet
  return vx_handle_dup(p->connector, VX_RIGHTS_SAME, out);
}

static vx_status fs_create(void *ctx, uint64_t dir, vx_str name, uint32_t perm, uint8_t mode, uint64_t *out) {
  (void)ctx, (void)mode;
  if (index_of(dir)) return VX_ERR_INVALID;
  if (perm & ~0777u) return VX_ERR_UNSUPPORTED; // a post is a file
  if (name.len >= SRV_NAME) return VX_ERR_RANGE;
  uint64_t there;
  if (fs_walk(ctx, dir, name, &there) == VX_OK) return VX_ERR_EXISTS;
  for (uint32_t i = 0; i < SRV_POSTS; i++) {
    post *p = &posts[i];
    if (p->used) continue;
    uint32_t gen = p->gen + 1;
    *p = (post){.used = true, .name_len = (uint8_t)name.len, .owner = user_of(dir), .mode = perm, .gen = gen};
    memcpy(p->name, name.ptr, name.len);
    *out = node_of(user_of(dir), i + 1);
    return VX_OK;
  }
  return VX_ERR_NO_MEMORY;
}

// The post itself: the connector beside the write, once.
static vx_status fs_write_handle(void *ctx, uint64_t node, vx_handle h) {
  (void)ctx;
  post *p = post_of(node);
  vx_status e = VX_OK;
  if (!p) e = VX_ERR_NOT_FOUND;
  if (p && p->connector) e = VX_ERR_BAD_STATE; // posted already
  if (e != VX_OK) {
    vx_handle_close(h);
    return e;
  }
  p->connector = h;
  return VX_OK;
}

// A write without a connector posts nothing.
// NOLINTNEXTLINE(readability-non-const-parameter): p9_fs's signature
static vx_status fs_write(void *ctx, uint64_t node, uint64_t offset, const uint8_t *buf, uint32_t *count) {
  (void)ctx, (void)node, (void)offset, (void)buf, (void)count;
  return VX_ERR_INVALID;
}

// NOLINTNEXTLINE(readability-non-const-parameter): p9_fs's signature
static vx_status fs_read(void *ctx, uint64_t node, uint64_t offset, uint8_t *buf, uint32_t *count) {
  (void)ctx, (void)node, (void)offset, (void)buf;
  *count = 0;
  return VX_OK;
}

static vx_status fs_remove(void *ctx, uint64_t node) {
  (void)ctx;
  post *p = post_of(node);
  if (!p) return VX_ERR_NOT_FOUND;
  if (p->owner != user_of(node)) return VX_ERR_ACCESS; // the owner's to take back
  if (p->connector) vx_handle_close(p->connector);
  uint32_t gen = p->gen;
  *p = (post){.gen = gen};
  return VX_OK;
}

static vx_status fs_readdir(void *ctx, uint64_t dir, uint32_t index, uint64_t *child) {
  (void)ctx;
  if (index_of(dir)) return VX_ERR_NOT_FOUND;
  for (uint32_t i = 0, n = 0; i < SRV_POSTS; i++)
    if (posts[i].used && n++ == index) {
      *child = node_of(user_of(dir), i + 1);
      return VX_OK;
    }
  return VX_ERR_NOT_FOUND;
}

static p9_ring_server server = {
    .fs = {.attach = fs_attach,
           .attach_as = fs_attach_as,
           .walk = fs_walk,
           .parent = fs_parent,
           .stat = fs_stat,
           .open = fs_open,
           .read = fs_read,
           .readdir = fs_readdir,
           .write = fs_write,
           .create = fs_create,
           .remove = fs_remove,
           .open_handle = fs_open_handle,
           .write_handle = fs_write_handle},
    .name = VX_STR("srvfs"),
    .supported = P9_EXT_XATTR | P9_EXT_SRV | P9_EXT_NOTIFY,
};

const char *vx_main(void) {
  server.listen = vx_spawn_take("listen");
  if (!server.listen) {
    vx_print(VX_STR("srvfs: no listen channel\n"));
    return "no listen channel";
  }
  vx_print(VX_STR("srvfs: serving /srv/srv\n"));
  return p9_ring_serve(&server) == VX_OK ? nullptr : "cannot serve";
}
