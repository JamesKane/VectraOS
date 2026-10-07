// envd: environment groups (M6 step 6e1c1, ADR-0044), as 9front's devenv
// (sys/src/9/port/devenv.c) keeps an Egrp for each process group, posted as
// /srv/env.
//
// A group is a directory of variables, each a file whose bytes are its
// value. A process reaches its group through a connection of its own, not
// its namespace (vx-ns's /env, which a namespace group does not share): it
// attaches with the aname "new" (an empty group), "+TOKEN" (a copy of the
// group TOKEN names: rfork e) or "TOKEN" (that group: what a child shares
// with its parent). A group's token is the root's qid path, 64 random bits:
// knowing it is the authority to reach the group, as a handle is, so it is
// never a small number another process could guess. A group lives while any
// fid holds one of its files (the framework's fid_node), and goes with the
// last.
//
// A variable is created with Tcreate, written (from offset 0 after an
// open with OTRUNC, as 9front's putenv writes), read, listed and removed.
// There are no permissions: whoever holds the token holds the group.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-9p/ring_server.c"

static constexpr uint32_t ENV_GROUPS = 128, ENV_VARS = 1024, ENV_NAME = 128;
static constexpr uint64_t ENV_MAX_VALUE = 1u << 20, ENV_MAX_BYTES = 32u << 20;

typedef struct group {
  bool used;
  uint64_t token; // the root's qid path: its name, unguessable
  int64_t fids;   // fids on its files, the framework's count: none, and it goes
} group;

typedef struct var {
  uint32_t group; // its group's index plus 1; 0: the slot is free
  uint32_t gen;   // its slot's generation, bumped as it is freed: a qid's version
  char name[ENV_NAME];
  uint8_t name_len;
  uint8_t *data; // a mapping of its own, cap bytes
  uint64_t size, cap;
} var;

static group groups[ENV_GROUPS];
static var vars[ENV_VARS];
static uint64_t bytes_used;

static p9_ring_server server;

// A node: the group's index plus 1, then its variable's plus 1 (0 for the root).
static uint64_t node_of(uint32_t g, uint32_t v) { return (uint64_t)(g + 1) << 32 | v; }
static group *group_of(uint64_t node) {
  uint32_t g = (uint32_t)(node >> 32);
  return g && g <= ENV_GROUPS && groups[g - 1].used ? &groups[g - 1] : nullptr;
}
static var *var_of(uint64_t node) {
  uint32_t v = (uint32_t)node;
  if (!v || v > ENV_VARS || vars[v - 1].group != (uint32_t)(node >> 32)) return nullptr;
  return &vars[v - 1];
}

static void var_free(var *x) {
  if (x->data) vx_as_unmap(vx_self, (uint64_t)x->data, x->cap);
  bytes_used -= x->cap;
  uint32_t gen = x->gen;
  *x = (var){.gen = gen + 1};
}

// Room for size bytes: a mapping twice as large as before, the old copied (tmpfs's way).
static vx_status reserve(var *x, uint64_t size) {
  if (size <= x->cap) return VX_OK;
  if (size > ENV_MAX_VALUE) return VX_ERR_NO_MEMORY;
  uint64_t cap = x->cap ? x->cap : 4096;
  while (cap < size) cap *= 2;
  if (bytes_used - x->cap + cap > ENV_MAX_BYTES) return VX_ERR_NO_MEMORY;
  vx_handle vmo;
  uint64_t at = 0;
  vx_status st = vx_vmo_create(cap, 0, &vmo);
  if (st == VX_OK) {
    st = vx_as_map(vx_self, vmo, 0, cap, VX_MAP_WRITE, &at);
    vx_handle_close(vmo); // the mapping keeps it
  }
  if (st != VX_OK) return st;
  if (x->data) memcpy((void *)at, x->data, x->size), vx_as_unmap(vx_self, (uint64_t)x->data, x->cap);
  bytes_used += cap - x->cap;
  x->data = (uint8_t *)at, x->cap = cap;
  return VX_OK;
}

static var *var_new(uint32_t g, vx_str name) {
  for (uint32_t i = 0; i < ENV_VARS; i++)
    if (!vars[i].group) {
      var *x = &vars[i];
      x->group = g + 1;
      memcpy(x->name, name.ptr, name.len), x->name_len = (uint8_t)name.len;
      return x;
    }
  return nullptr;
}

static var *var_named(uint32_t g, vx_str name) {
  for (uint32_t i = 0; i < ENV_VARS; i++)
    if (vars[i].group == g + 1 && vars[i].name_len == name.len && !memcmp(vars[i].name, name.ptr, name.len))
      return &vars[i];
  return nullptr;
}

static uint32_t group_new(void) {
  for (uint32_t g = 0; g < ENV_GROUPS; g++)
    if (!groups[g].used) {
      uint64_t token = 0;
      while (!token) vx_drbg_read(&server.shared.random, &token, sizeof token);
      groups[g] = (group){.used = true, .token = token};
      return g;
    }
  return ENV_GROUPS;
}

static void group_free(uint32_t g) {
  for (uint32_t i = 0; i < ENV_VARS; i++)
    if (vars[i].group == g + 1) var_free(&vars[i]);
  groups[g] = (group){};
}

// "TOKEN" or "+TOKEN" in hex: the group it names, or ENV_GROUPS.
static uint32_t group_by_token(vx_str hex) {
  uint64_t t = 0;
  if (!hex.len || hex.len > 16) return ENV_GROUPS;
  for (size_t i = 0; i < hex.len; i++) {
    char c = hex.ptr[i];
    uint64_t d = c >= '0' && c <= '9' ? (uint64_t)(c - '0') : 16;
    if (c >= 'a' && c <= 'f') d = (uint64_t)(c - 'a') + 10;
    if (d > 15) return ENV_GROUPS;
    t = t << 4 | d;
  }
  for (uint32_t g = 0; g < ENV_GROUPS; g++)
    if (groups[g].used && groups[g].token == t) return g;
  return ENV_GROUPS;
}

// A copy of group from as a new group: rfork e.
static vx_status group_copy(uint32_t from, uint32_t *out) {
  uint32_t g = group_new();
  if (g == ENV_GROUPS) return VX_ERR_NO_MEMORY;
  for (uint32_t i = 0; i < ENV_VARS; i++) {
    const var *s = &vars[i];
    if (s->group != from + 1) continue;
    var *x = var_new(g, (vx_str){s->name, s->name_len});
    vx_status st = x ? reserve(x, s->size) : VX_ERR_NO_MEMORY;
    if (st != VX_OK) {
      group_free(g);
      return st;
    }
    if (s->size) memcpy(x->data, s->data, s->size);
    x->size = s->size;
  }
  *out = g;
  return VX_OK;
}

// --- The file system ---

static vx_status fs_attach(void *ctx, vx_str aname, uint64_t *root) {
  (void)ctx;
  if (!server.shared.random.seeded) return VX_ERR_UNSUPPORTED; // no tokens to give without entropy
  uint32_t g = ENV_GROUPS;
  vx_status st = VX_OK;
  if (aname.len == 3 && !memcmp(aname.ptr, "new", 3)) {
    g = group_new();
    if (g == ENV_GROUPS) st = VX_ERR_NO_MEMORY;
  } else if (aname.len && aname.ptr[0] == '+') {
    uint32_t from = group_by_token((vx_str){aname.ptr + 1, aname.len - 1});
    st = from == ENV_GROUPS ? VX_ERR_NOT_FOUND : group_copy(from, &g);
  } else {
    g = group_by_token(aname);
    if (g == ENV_GROUPS) st = VX_ERR_NOT_FOUND;
  }
  if (st == VX_OK) *root = node_of(g, 0);
  return st;
}

// A group's fids, counted: the last one gone, the group goes. A group made
// by an attach that no fid took (a failed attach) has none from the start.
static void fs_fid_node(void *ctx, uint64_t node, int delta) {
  (void)ctx;
  group *g = group_of(node);
  if (!g) return;
  g->fids += delta;
  if (g->fids <= 0) group_free((uint32_t)(g - groups));
}

static vx_status fs_walk(void *ctx, uint64_t dir, vx_str name, uint64_t *child) {
  (void)ctx;
  if ((uint32_t)dir || !group_of(dir)) return VX_ERR_NOT_FOUND;
  uint32_t g = (uint32_t)(dir >> 32) - 1;
  const var *x = var_named(g, name);
  if (!x) return VX_ERR_NOT_FOUND;
  *child = node_of(g, (uint32_t)(x - vars) + 1);
  return VX_OK;
}

static vx_status fs_parent(void *ctx, uint64_t node, uint64_t *parent) {
  (void)ctx;
  *parent = node & ~(uint64_t)UINT32_MAX;
  return VX_OK;
}

static vx_status fs_stat(void *ctx, uint64_t node, p9_stat *out) {
  (void)ctx;
  const group *g = group_of(node);
  if (!g) return VX_ERR_NOT_FOUND;
  if (!(uint32_t)node) {
    *out = (p9_stat){.qid = {P9_QTDIR, 0, g->token}, // the token: how a process learns its group's
                     .mode = P9_DMDIR | 0775,
                     .name = VX_STR("/"),
                     .uid = VX_STR("env"),
                     .gid = VX_STR("env"),
                     .muid = VX_STR("env")};
    return VX_OK;
  }
  const var *x = var_of(node);
  if (!x) return VX_ERR_NOT_FOUND;
  *out = (p9_stat){.qid = {P9_QTFILE, x->gen, node},
                   .mode = 0664,
                   .length = x->size,
                   .name = {x->name, x->name_len},
                   .uid = VX_STR("env"),
                   .gid = VX_STR("env"),
                   .muid = VX_STR("env")};
  return VX_OK;
}

static vx_status fs_open(void *ctx, uint64_t node, uint8_t mode) {
  (void)ctx;
  if (!(uint32_t)node) return (mode & 3) == P9_OREAD && group_of(node) ? VX_OK : VX_ERR_ACCESS;
  var *x = var_of(node);
  if (!x) return VX_ERR_NOT_FOUND;
  if (mode & P9_OTRUNC) x->size = 0; // a new value, as putenv writes it
  return VX_OK;
}

static vx_status fs_create(void *ctx, uint64_t dir, vx_str name, uint32_t perm, uint8_t mode, uint64_t *out) {
  (void)ctx, (void)mode;
  if ((uint32_t)dir || !group_of(dir)) return VX_ERR_NOT_FOUND;
  if (perm & P9_DMDIR) return VX_ERR_ACCESS; // variables only
  if (!name.len || name.len >= ENV_NAME) return VX_ERR_INVALID;
  for (size_t i = 0; i < name.len; i++)
    if (name.ptr[i] == '/') return VX_ERR_INVALID;
  uint32_t g = (uint32_t)(dir >> 32) - 1;
  var *x = var_named(g, name);
  if (x) { // as 9front's devenv: creating one that exists empties it
    x->size = 0;
  } else if (!(x = var_new(g, name))) {
    return VX_ERR_NO_MEMORY;
  }
  *out = node_of(g, (uint32_t)(x - vars) + 1);
  return VX_OK;
}

static vx_status fs_read(void *ctx, uint64_t node, uint64_t offset, uint8_t *buf, uint32_t *count) {
  (void)ctx;
  const var *x = var_of(node);
  if (!x) return VX_ERR_NOT_FOUND;
  uint64_t n = offset >= x->size ? 0 : x->size - offset;
  if (n > *count) n = *count;
  if (n) memcpy(buf, x->data + offset, n);
  *count = (uint32_t)n;
  return VX_OK;
}

// NOLINTNEXTLINE(readability-non-const-parameter): p9_fs's signature
static vx_status fs_write(void *ctx, uint64_t node, uint64_t offset, const uint8_t *buf, uint32_t *count) {
  (void)ctx;
  var *x = var_of(node);
  if (!x) return VX_ERR_ACCESS;
  uint64_t end;
  if (ckd_add(&end, offset, (uint64_t)*count)) return VX_ERR_RANGE;
  vx_status st = reserve(x, end);
  if (st != VX_OK) return st;
  if (offset > x->size) memset(x->data + x->size, 0, offset - x->size);
  memcpy(x->data + offset, buf, *count);
  if (end > x->size) x->size = end;
  return VX_OK;
}

static vx_status fs_remove(void *ctx, uint64_t node) {
  (void)ctx;
  var *x = var_of(node);
  if (!x) return (uint32_t)node ? VX_ERR_NOT_FOUND : VX_ERR_ACCESS; // a group goes with its fids, not by name
  var_free(x);
  return VX_OK;
}

static vx_status fs_readdir(void *ctx, uint64_t dir, uint32_t index, uint64_t *child) {
  (void)ctx;
  if ((uint32_t)dir || !group_of(dir)) return VX_ERR_NOT_FOUND;
  uint32_t g = (uint32_t)(dir >> 32);
  for (uint32_t i = 0; i < ENV_VARS; i++)
    if (vars[i].group == g && !index--) {
      *child = node_of(g - 1, i + 1);
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
           .readdir = fs_readdir,
           .write = fs_write,
           .create = fs_create,
           .remove = fs_remove,
           .fid_node = fs_fid_node},
    .name = VX_STR("envd"),
    .supported = P9_EXT_XATTR,
};

const char *vx_main(void) {
  server.listen = vx_spawn_take("listen");
  if (!server.listen) {
    vx_print(VX_STR("envd: no listen channel\n"));
    return "no listen channel";
  }
  vx_print(VX_STR("envd: serving /srv/env\n"));
  return p9_ring_serve(&server) == VX_OK ? nullptr : "cannot serve";
}
