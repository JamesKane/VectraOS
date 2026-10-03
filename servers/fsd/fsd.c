// fsd: the system volume's file server (docs/11 §7). It mounts a vx-fs
// volume on a block session (its manifest's connect=, as "srv:NAME": a
// partition partd serves, say) and serves its branches over 9Px, with the
// posix and xattr extensions, through vx-9p's framework as tmpfs is:
//
//   service=fsd program=/boot/bin/fsd post=fsd console entropy
//   connect=disk1.vectra
//
// (entropy: the seed the framework's open-file tokens need, which a
// forked child joins its parent's open files with.)
//
// The attach name is the branch: `mount /srv/fsd /home home`.
//
// A node id is the branch's slot in its high byte, the attaching user's
// index in the users table in the next, and the entry's qid below them: a
// fid finds its entry by the qid's Kup (lib/vx-fs/file.c) whatever it walked
// through, and every call knows who makes it. A file removed while it is
// open is an orphan until its last open fid goes (its data then cleared); a
// crash leaves orphans that the branch's next opening reaps.
//
// Users are /adm/users, in users(6)'s format, id:name:leader:members, read
// from the adm branch (again whenever that file is written and closed);
// without one, adm and none. Permissions are Plan 9's, as gefs checks them:
// a class's bits grant what they allow (owner, group, then other), none gets
// only other's, a directory's x is search, a new entry takes its directory's
// group and no more of its bits, and owners are adm's to give. They are
// advisory until keyd (M10): a client names who it attaches as (Tattach's
// uname), and can name anyone (docs/11 §9).
//
// Changes are committed every 5 s, and by Tfsync, which is answered once
// its commit is durable (11 §6). Single-threaded: one loop, which waits for
// the disk. The adm files and the dump view are M5 step 4b2 and 4b3's.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-driver/blkclient.c"
#include "../../lib/vx-9p/ring_server.c"
#include "../../lib/vx-fs/file.c"

static constexpr vx_duration COMMIT_EVERY = 5'000'000'000;
static constexpr uint32_t CACHE_BLOCKS = 1024; // 16 MiB of tree nodes and data
static constexpr uint32_t MAX_OPEN = 512;      // distinct nodes open at once
static constexpr int SLOT_SHIFT = 56, USER_SHIFT = 48;
static constexpr uint32_t MAX_USERS = 255, MAX_MEMBERS = 32;
static constexpr uint32_t NONE_ID = 0xffff'fffe; // none's id when the users file has no none

static vx_blk disk;
static vxfs_vol vol;
static vx_str disk_name;
static bool dirty;
static vx_instant next_commit;
static bool reaped[VXFS_MAXBRANCH];

[[noreturn]] static void fail(const char *what, vx_status st) {
  vx_print(VX_STR("fsd: FAILED: "));
  vx_print(vx_cstr(what));
  if (st != VX_OK) {
    vx_print(VX_STR(": "));
    vx_print(p9_error_text(st));
  }
  vx_print(VX_STR("\n"));
  vx_exits(what);
}

// --- The volume's device and memory ---

static vx_status dev_read(void *ctx, uint64_t addr, void *buf) {
  return vx_blk_read(ctx, addr, buf, VXFS_BLKSZ);
}
static vx_status dev_write(void *ctx, uint64_t addr, const void *buf) {
  return vx_blk_write(ctx, addr, buf, VXFS_BLKSZ);
}
static vx_status dev_barrier(void *ctx) { return vx_blk_flush(ctx); }

static uint64_t page_round(size_t n) { return (n + 4095) & ~(uint64_t)4095; }

static void *mem_alloc([[maybe_unused]] void *ctx, size_t n) {
  vx_handle vmo;
  uint64_t at = 0, size = page_round(n);
  if (vx_vmo_create(size, 0, &vmo) != VX_OK) return nullptr;
  vx_status st = vx_as_map(vx_self, vmo, 0, size, VX_MAP_WRITE, &at);
  vx_handle_close(vmo); // the mapping keeps it
  return st == VX_OK ? (void *)at : nullptr;
}

static void mem_free([[maybe_unused]] void *ctx, void *p, size_t n) {
  vx_as_unmap(vx_self, (uint64_t)p, page_round(n));
}

// --- Nodes ---

static uint64_t node_of(uint32_t slot, uint32_t user, uint64_t qid) {
  return (uint64_t)slot << SLOT_SHIFT | (uint64_t)user << USER_SHIFT | qid;
}
static uint32_t slot_of(uint64_t node) { return (uint32_t)(node >> SLOT_SHIFT); }
static uint32_t user_of(uint64_t node) { return (uint32_t)(node >> USER_SHIFT) & 0xff; }
static uint64_t qid_of(uint64_t node) { return node & ((1ull << USER_SHIFT) - 1); }

static vxfs_tree *tree_of(uint64_t node) {
  uint32_t s = slot_of(node);
  return s < VXFS_MAXBRANCH && vol.br[s].open ? &vol.br[s].t : nullptr;
}

static vx_status file_of(uint64_t node, vxfs_file *f) {
  vxfs_tree *t = tree_of(node);
  if (!t) return VX_ERR_NOT_FOUND;
  return vxfs_file_by_qid(&vol, t, qid_of(node), f);
}

// The node of entry f, found from dir: in its branch, for its user.
static uint64_t node_in(uint64_t dir, const vxfs_file *f) {
  return node_of(slot_of(dir), user_of(dir), f->d.qid_path);
}

static bool is_branch(uint64_t node, const char *name) {
  uint32_t s = slot_of(node);
  uint16_t n = vxfs_namelen(name, VXFS_LABELMAX);
  return s < VXFS_MAXBRANCH && vol.br[s].open && vol.br[s].nname == n && !memcmp(vol.br[s].name, name, n);
}

// Times, in ns: from boot until there is a wall clock, as sysfs's realtime is.
static int64_t now_ns(void) { return (int64_t)vx_clock_read(); }

static void changed(void) {
  if (!dirty) next_commit = vx_clock_read() + COMMIT_EVERY;
  dirty = true;
}

static vx_status commit(void) {
  if (!dirty) return VX_OK;
  vx_status st = vxfs_commit(&vol);
  if (st != VX_OK) {
    vx_print(VX_STR("fsd: the commit failed, and the volume is read-only now: "));
    vx_print(p9_error_text(st));
    vx_print(VX_STR("\n"));
    return st;
  }
  dirty = false;
  return VX_OK;
}

// Open fids, counted by node: an orphan's data goes with its last.
typedef struct opened {
  uint64_t node;
  uint32_t count;
} opened;
static opened opens[MAX_OPEN];

static opened *open_slot(uint64_t node, bool make) {
  opened *free = nullptr;
  for (uint32_t i = 0; i < MAX_OPEN; i++) {
    if (opens[i].count && opens[i].node == node) return &opens[i];
    if (!opens[i].count && !free) free = &opens[i];
  }
  if (!make || !free) return nullptr;
  *free = (opened){.node = node};
  return free;
}

// --- Users (/adm/users) ---

typedef struct user {
  uint32_t id, lead; // lead: the group's leader's id, or ~0 for none
  char name[32];
  uint8_t nname;
  uint32_t memb[MAX_MEMBERS];
  uint32_t nmemb;
} user;

static user users[MAX_USERS];
static uint32_t nusers, none_user; // none_user: none's index

static uint32_t user_named(vx_str name) {
  for (uint32_t i = 0; i < nusers; i++)
    if (users[i].nname == name.len && memcmp(users[i].name, name.ptr, name.len) == 0) return i;
  return none_user;
}

static const user *user_by_id(uint32_t id) {
  for (uint32_t i = 0; i < nusers; i++)
    if (users[i].id == id) return &users[i];
  return nullptr;
}

static bool in_group(uint32_t uid, uint32_t gid) {
  const user *g = user_by_id(gid);
  if (!g) return false;
  if (g->id == uid) return true;
  for (uint32_t i = 0; i < g->nmemb; i++)
    if (g->memb[i] == uid) return true;
  return false;
}

static bool leads(uint32_t uid, uint32_t gid) {
  const user *g = user_by_id(gid);
  if (!g) return false;
  if (g->lead != ~0u) return g->lead == uid;
  return in_group(uid, gid); // no leader: every member leads
}

static vx_str field(vx_str *line, char sep) {
  size_t n = 0;
  while (n < line->len && line->ptr[n] != sep) n++;
  vx_str f = {line->ptr, n};
  size_t skip = n < line->len ? n + 1 : n;
  line->ptr += skip, line->len -= skip;
  return f;
}

static bool number(vx_str s, uint32_t *v) {
  uint64_t n = 0;
  if (!s.len) return false;
  for (size_t i = 0; i < s.len; i++) {
    if (s.ptr[i] < '0' || s.ptr[i] > '9') return false;
    n = n * 10 + (uint64_t)(s.ptr[i] - '0');
    if (n > 0xffff'ffff) return false;
  }
  *v = (uint32_t)n;
  return true;
}

static uint32_t index_named(const user *t, uint32_t n, vx_str name) {
  uint32_t k = 0;
  while (k < n && !(t[k].nname == name.len && !memcmp(t[k].name, name.ptr, name.len))) k++;
  return k;
}

// The table from users(6) text. False if it is malformed: a field missing,
// an id that is no number, a leader or member who is no user; the table is
// then left as it was.
static bool parse_users(vx_str text) {
  static user next[MAX_USERS];
  uint32_t n = 0;
  for (int pass = 0; pass < 2; pass++) { // names first, so leaders and members may come later
    vx_str rest = text;
    uint32_t i = 0;
    while (rest.len) {
      vx_str line = field(&rest, '\n');
      if (!line.len || line.ptr[0] == '#') continue;
      vx_str id = field(&line, ':'), name = field(&line, ':'), lead = field(&line, ':'), memb = line;
      if (pass == 0) {
        if (n == MAX_USERS || !name.len || name.len > sizeof next[0].name || !number(id, &next[n].id))
          return false;
        memcpy(next[n].name, name.ptr, name.len);
        next[n].nname = (uint8_t)name.len, next[n].lead = ~0u, next[n].nmemb = 0;
        n++;
        continue;
      }
      user *u = &next[i++];
      if (lead.len) {
        uint32_t k = index_named(next, n, lead);
        if (k == n) return false;
        u->lead = next[k].id;
      }
      while (memb.len) {
        vx_str m = field(&memb, ',');
        if (!m.len) continue;
        uint32_t k = index_named(next, n, m);
        if (k == n || u->nmemb == MAX_MEMBERS) return false;
        u->memb[u->nmemb++] = next[k].id;
      }
    }
  }
  memcpy(users, next, n * sizeof *users);
  nusers = n;
  none_user = index_named(users, nusers, VX_STR("none"));
  if (none_user == nusers) { // none, whether the file says so or not
    users[nusers] = (user){.id = NONE_ID, .lead = ~0u, .name = "none", .nname = 4};
    none_user = nusers++;
  }
  return true;
}

static const char DEFAULT_USERS[] = "0:adm:adm:\n1:none::\n";

// The users table from the adm branch's /users, or the default.
static void load_users(void) {
  static char text[64 * 1024];
  vxfs_branch *br;
  vxfs_file root, f;
  uint64_t got = 0;
  bool ok = vxfs_branch_open(&vol, "adm", &br) == VX_OK && vxfs_root(&vol, &br->t, &root) == VX_OK &&
            vxfs_walk(&vol, &br->t, &root, "users", &f) == VX_OK && f.d.length < sizeof text &&
            vxfs_read(&vol, &br->t, &f, 0, text, sizeof text, &got) == VX_OK &&
            parse_users((vx_str){text, got});
  if (ok) return;
  if (nusers) {
    vx_print(VX_STR("fsd: /adm/users is malformed: the users stay as they were\n"));
    return;
  }
  parse_users(VX_STR(DEFAULT_USERS));
  vx_print(VX_STR("fsd: no /adm/users it can read: adm and none only\n"));
}

// What node's user may do to an entry: MAY_R, MAY_W, MAY_X, or-ed.
enum : uint32_t { MAY_X = 1, MAY_W = 2, MAY_R = 4 };

static uint32_t uid_of(uint64_t node) {
  uint32_t u = user_of(node);
  return u < nusers ? users[u].id : NONE_ID;
}

static bool is_none(uint64_t node) { return user_of(node) == none_user || user_of(node) >= nusers; }

static bool may(uint64_t node, const vxfs_dir *d, uint32_t want) {
  if (!is_none(node)) {
    uint32_t me = uid_of(node);
    if (me == d->uid && ((d->mode >> 6) & want) == want) return true;
    if (in_group(me, d->gid) && ((d->mode >> 3) & want) == want) return true;
  }
  return (d->mode & want) == want;
}

static bool is_adm(uint64_t node) { return !is_none(node) && in_group(uid_of(node), 0); }

// --- The 9P side ---

static vx_status fs_attach([[maybe_unused]] void *ctx, vx_str aname, vx_str uname, uint64_t *root) {
  char name[VXFS_LABELMAX + 1];
  if (!aname.len || aname.len > VXFS_LABELMAX) return VX_ERR_NOT_FOUND;
  memcpy(name, aname.ptr, aname.len);
  name[aname.len] = 0;
  vxfs_branch *br;
  vx_status st = vxfs_branch_open(&vol, name, &br);
  if (st != VX_OK) return st == VX_ERR_ACCESS ? VX_ERR_ACCESS : VX_ERR_NOT_FOUND; // 4b3: snapshots, read-only
  uint32_t slot = (uint32_t)(br - vol.br);
  if (!reaped[slot]) { // what a crash left of files removed while open
    uint32_t n = 0;
    if ((st = vxfs_reap_all(&vol, &br->t, &n)) != VX_OK) return st;
    if (n) changed();
    reaped[slot] = true;
  }
  vxfs_file f;
  if ((st = vxfs_root(&vol, &br->t, &f)) != VX_OK) return st;
  *root = node_of(slot, user_named(uname), f.d.qid_path);
  return VX_OK;
}

static vx_status fs_walk([[maybe_unused]] void *ctx, uint64_t dir, vx_str name, uint64_t *child) {
  char nm[VXFS_NAMEMAX + 1];
  if (name.len > VXFS_NAMEMAX) return VX_ERR_RANGE;
  memcpy(nm, name.ptr, name.len);
  nm[name.len] = 0;
  vxfs_file d, f;
  vx_status st = file_of(dir, &d);
  if (st == VX_OK && (d.d.mode & VXFS_DMDIR) && !may(dir, &d.d, MAY_X)) st = VX_ERR_ACCESS;
  if (st == VX_OK) st = vxfs_walk(&vol, tree_of(dir), &d, nm, &f);
  if (st == VX_ERR_INVALID) st = VX_ERR_NOT_FOUND; // through a file
  if (st == VX_OK) *child = node_in(dir, &f);
  return st;
}

static vx_status fs_parent([[maybe_unused]] void *ctx, uint64_t node, uint64_t *parent) {
  vxfs_file f, p;
  vx_status st = file_of(node, &f);
  if (st == VX_OK && vxfs_is_orphan(&f)) st = VX_ERR_NOT_FOUND;
  if (st == VX_OK) st = vxfs_walk(&vol, tree_of(node), &f, "..", &p);
  if (st == VX_OK) *parent = node_in(node, &p);
  return st;
}

static char uidbuf[3][12];

static vx_str decimal(char *buf, uint32_t v) {
  char tmp[12];
  uint32_t n = 0;
  do tmp[n++] = (char)('0' + v % 10), v /= 10;
  while (v);
  for (uint32_t i = 0; i < n; i++) buf[i] = tmp[n - 1 - i];
  return (vx_str){buf, n};
}

static vx_str user_name(char *buf, uint32_t id) {
  const user *u = user_by_id(id);
  return u ? (vx_str){u->name, u->nname} : decimal(buf, id);
}

static vxfs_file stat_file; // the name in a stat lives until the next call

static vx_status fs_stat([[maybe_unused]] void *ctx, uint64_t node, p9_stat *out) {
  vx_status st = file_of(node, &stat_file);
  if (st != VX_OK) return st;
  const vxfs_dir *d = &stat_file.d;
  bool dir = d->mode & VXFS_DMDIR, root = stat_file.nkey == 9 && !vxfs_is_orphan(&stat_file);
  uint8_t qtype = dir ? P9_QTDIR : P9_QTFILE;
  *out =
      (p9_stat){.qid = {qtype, d->qid_vers, node},
                .mode = d->mode,
                .atime = (uint32_t)(d->atime / 1'000'000'000),
                .mtime = (uint32_t)(d->mtime / 1'000'000'000),
                .length = dir ? 0 : d->length,
                .name = root ? VX_STR("/") : (vx_str){(const char *)stat_file.key + 9, stat_file.nkey - 9u},
                .uid = user_name(uidbuf[0], d->uid),
                .gid = user_name(uidbuf[1], d->gid),
                .muid = user_name(uidbuf[2], d->muid)};
  return VX_OK;
}

static vx_status truncate_to(uint64_t node, vxfs_file *f, uint64_t size) {
  vxfs_attr a = {.valid = VXFS_WSIZE | VXFS_WMTIME, .length = size, .mtime = now_ns()};
  vx_status st = vxfs_setattr(&vol, tree_of(node), f, &a, a.mtime);
  if (st == VX_OK) changed();
  return st;
}

static vx_status fs_open([[maybe_unused]] void *ctx, uint64_t node, uint8_t mode) {
  vxfs_file f;
  vx_status st = file_of(node, &f);
  if (st != VX_OK) return st;
  bool writes = (mode & 3) == P9_OWRITE || (mode & 3) == P9_ORDWR || (mode & P9_OTRUNC);
  if ((f.d.mode & VXFS_DMDIR) && writes) return VX_ERR_ACCESS;
  uint32_t want = 0;
  if ((mode & 3) == P9_OREAD || (mode & 3) == P9_ORDWR) want |= MAY_R;
  if (writes) want |= MAY_W;
  if ((mode & 3) == P9_OEXEC) want |= MAY_X;
  if (!(mode & P9_OJOIN) && !may(node, &f.d, want)) return VX_ERR_ACCESS; // a join has its open's rights
  opened *o = open_slot(node, true);
  if (!o) return VX_ERR_NO_MEMORY;
  if ((mode & P9_OTRUNC) && (st = truncate_to(node, &f, 0)) != VX_OK) return st;
  o->count++;
  return VX_OK;
}

static void fs_clunk([[maybe_unused]] void *ctx, uint64_t node, bool was_open) {
  if (!was_open) return;
  opened *o = open_slot(node, false);
  if (!o || --o->count) return;
  vxfs_file f;
  if (file_of(node, &f) != VX_OK) return;
  if (vxfs_is_orphan(&f)) { // the last of a removed file
    if (vxfs_reap(&vol, tree_of(node), qid_of(node)) == VX_OK) changed();
  } else if (is_branch(node, "adm") && f.nkey == 9 + 5 && !memcmp(f.key + 9, "users", 5)) {
    load_users(); // /adm/users, as it is now
  }
}

static vx_status fs_read([[maybe_unused]] void *ctx, uint64_t node, uint64_t offset, uint8_t *buf,
                         uint32_t *count) {
  vxfs_file f;
  vx_status st = file_of(node, &f);
  uint64_t got = 0;
  if (st == VX_OK) st = vxfs_read(&vol, tree_of(node), &f, offset, buf, *count, &got);
  *count = (uint32_t)got;
  return st;
}

static vx_status fs_write([[maybe_unused]] void *ctx, uint64_t node, uint64_t offset, const uint8_t *buf,
                          uint32_t *count) { // NOLINT(readability-non-const-parameter): p9_fs's signature
  vxfs_file f;
  vx_status st = file_of(node, &f);
  if (st != VX_OK) return st;
  if (f.d.mode & VXFS_DMDIR) return VX_ERR_ACCESS;
  st = vxfs_write(&vol, tree_of(node), &f, offset, buf, *count, now_ns(), uid_of(node));
  if (st == VX_OK) changed();
  return st;
}

// Listing: the entry after the last one given, when the next index is
// asked for in turn; otherwise from the start.
static struct {
  uint64_t dir;
  uint32_t next;
  uint8_t key[VXFS_KEYMAX];
  uint16_t nkey;
} cursor;

static vx_status fs_readdir([[maybe_unused]] void *ctx, uint64_t dir, uint32_t index, uint64_t *child) {
  vxfs_file d;
  vx_status st = file_of(dir, &d);
  if (st != VX_OK) return st;
  if (!(d.d.mode & VXFS_DMDIR)) return VX_ERR_INVALID;
  vxfs_tree *t = tree_of(dir);
  uint8_t pfx[9] = {VXFS_KENT};
  vxfs_kput64(pfx + 1, d.d.qid_path);
  bool resume = index && cursor.dir == dir && cursor.next == index;
  vxfs_scan s;
  if (resume)
    vxfs_scan_from(&s, t, pfx, 9, cursor.key, cursor.nkey);
  else
    vxfs_scan_start(&s, t, pfx, 9);
  vxfs_kvp kv;
  uint32_t skip = resume ? 0 : index;
  st = VX_ERR_NOT_FOUND;
  while (vxfs_scan_next(&vol.fs, &s, &kv)) {
    if (resume && kv.nk == cursor.nkey && memcmp(kv.k, cursor.key, kv.nk) == 0)
      continue; // the last one given
    if (skip) {
      skip--;
      continue;
    }
    if (kv.nv != VXFS_DIRSZ) {
      st = VX_ERR_INVALID;
      break;
    }
    *child = node_of(slot_of(dir), user_of(dir), vxfs_unpackdir(kv.v).qid_path);
    cursor.dir = dir, cursor.next = index + 1, cursor.nkey = kv.nk;
    memcpy(cursor.key, kv.k, kv.nk);
    st = VX_OK;
    break;
  }
  vxfs_scan_end(&vol.fs, &s);
  return vol.fs.err != VX_OK ? vol.fs.err : st;
}

static vx_status name_of(vx_str s, char *out) {
  if (!s.len || s.len > VXFS_NAMEMAX) return VX_ERR_RANGE;
  memcpy(out, s.ptr, s.len);
  out[s.len] = 0;
  return VX_OK;
}

static vx_status fs_create([[maybe_unused]] void *ctx, uint64_t dir, vx_str name, uint32_t perm, uint8_t mode,
                           uint64_t *out) {
  char nm[VXFS_NAMEMAX + 1];
  vxfs_file d, f;
  vx_status st = name_of(name, nm);
  if (st == VX_OK) st = file_of(dir, &d);
  if (st != VX_OK) return st;
  if ((perm & P9_DMDIR) && (mode & 3) != P9_OREAD) return VX_ERR_ACCESS;
  if (!may(dir, &d.d, MAY_W)) return VX_ERR_ACCESS;
  // Plan 9's: no more of the directory's bits, and in its group.
  bool isdir = perm & P9_DMDIR;
  uint32_t bits = isdir ? perm & (d.d.mode & 0777) : perm & (~0666u | (d.d.mode & 0666));
  st = vxfs_create(&vol, tree_of(dir), &d, nm, (isdir ? VXFS_DMDIR : 0) | (bits & 0777), uid_of(dir), d.d.gid,
                   now_ns(), &f);
  if (st != VX_OK) return st;
  changed();
  *out = node_in(dir, &f);
  opened *slot = open_slot(*out, true); // create opens it
  if (slot) slot->count++;
  return VX_OK;
}

static vx_status fs_remove([[maybe_unused]] void *ctx, uint64_t node) {
  vxfs_file f, d;
  vx_status st = file_of(node, &f);
  if (st != VX_OK) return st;
  if (vxfs_is_orphan(&f)) return VX_ERR_NOT_FOUND;
  if (f.nkey == 9) return VX_ERR_ACCESS; // the root
  vxfs_tree *t = tree_of(node);
  if ((st = vxfs_file_by_qid(&vol, t, vxfs_kget64(f.key + 1), &d)) != VX_OK) return st;
  if (!may(node, &d.d, MAY_W)) return VX_ERR_ACCESS;
  char nm[VXFS_NAMEMAX + 1];
  memcpy(nm, f.key + 9, f.nkey - 9u);
  nm[f.nkey - 9] = 0;
  const opened *o = open_slot(node, false);
  if (o && !(f.d.mode & VXFS_DMDIR))
    st = vxfs_orphan(&vol, t, &d, nm, now_ns()); // open still: kept until its last fid goes
  else
    st = vxfs_remove(&vol, t, &d, nm, now_ns());
  if (st == VX_OK) changed();
  return st;
}

// Who may change what (gefs's rules): the size, with write permission;
// the mode, the owner or the group's leader; the owner, adm only; the
// group, the owner to a group they are in, or a leader of both; the times
// as given, the owner; the times to now, the owner or a writer.
static bool may_setattr(uint64_t node, const vxfs_dir *d, const p9_setattr *a) {
  uint32_t me = uid_of(node);
  bool owner = !is_none(node) && me == d->uid, adm = is_adm(node);
  if (adm) return true;
  if ((a->valid & P9_SETATTR_SIZE) && !may(node, d, MAY_W)) return false;
  if ((a->valid & P9_SETATTR_MODE) && !owner && !leads(me, d->gid)) return false;
  if ((a->valid & P9_SETATTR_UID) && a->uid != d->uid) return false;
  if ((a->valid & P9_SETATTR_GID) && a->gid != d->gid &&
      !((owner && in_group(me, a->gid)) || (leads(me, d->gid) && leads(me, a->gid))))
    return false;
  if ((a->valid & (P9_SETATTR_ATIME_SET | P9_SETATTR_MTIME_SET)) && !owner) return false;
  if ((a->valid & (P9_SETATTR_ATIME | P9_SETATTR_MTIME)) && !owner && !may(node, d, MAY_W)) return false;
  return true;
}

static vx_status fs_setattr([[maybe_unused]] void *ctx, uint64_t node, const p9_setattr *a) {
  vxfs_file f;
  vx_status st = file_of(node, &f);
  if (st != VX_OK) return st;
  if (!may_setattr(node, &f.d, a)) return VX_ERR_ACCESS;
  int64_t now = now_ns();
  vxfs_attr x = {};
  if (a->valid & P9_SETATTR_SIZE) x.valid |= VXFS_WSIZE, x.length = a->size;
  if (a->valid & P9_SETATTR_MODE) x.valid |= VXFS_WMODE, x.mode = a->mode & 07777;
  if (a->valid & P9_SETATTR_UID) x.valid |= VXFS_WUID, x.uid = a->uid;
  if (a->valid & P9_SETATTR_GID) x.valid |= VXFS_WGID, x.gid = a->gid;
  if (a->valid & P9_SETATTR_ATIME) {
    x.valid |= VXFS_WATIME;
    x.atime = a->valid & P9_SETATTR_ATIME_SET ? (int64_t)(a->atime_sec * 1'000'000'000 + a->atime_nsec) : now;
  }
  if (a->valid & (P9_SETATTR_MTIME | P9_SETATTR_SIZE)) {
    x.valid |= VXFS_WMTIME;
    x.mtime = a->valid & P9_SETATTR_MTIME_SET ? (int64_t)(a->mtime_sec * 1'000'000'000 + a->mtime_nsec) : now;
  }
  st = vxfs_setattr(&vol, tree_of(node), &f, &x, now);
  if (st == VX_OK) changed();
  return st;
}

static vx_status fs_rename([[maybe_unused]] void *ctx, uint64_t olddir, vx_str oldname, uint64_t newdir,
                           vx_str newname) {
  char from[VXFS_NAMEMAX + 1], to[VXFS_NAMEMAX + 1];
  vxfs_file a, b;
  if (slot_of(olddir) != slot_of(newdir)) return VX_ERR_INVALID; // one branch: one tree
  vx_status st = name_of(oldname, from);
  if (st == VX_OK) st = name_of(newname, to);
  if (st == VX_OK) st = file_of(olddir, &a);
  if (st == VX_OK) st = file_of(newdir, &b);
  if (st == VX_OK && (!may(olddir, &a.d, MAY_W) || !may(newdir, &b.d, MAY_W))) st = VX_ERR_ACCESS;
  if (st == VX_OK) st = vxfs_rename(&vol, tree_of(olddir), &a, from, &b, to, now_ns());
  if (st == VX_OK) changed();
  return st;
}

static vx_status fs_symlink([[maybe_unused]] void *ctx, uint64_t dir, vx_str name, vx_str target,
                            uint64_t *out) {
  char nm[VXFS_NAMEMAX + 1], tgt[4097];
  vxfs_file d, f;
  if (!target.len || target.len >= sizeof tgt) return VX_ERR_INVALID;
  memcpy(tgt, target.ptr, target.len);
  tgt[target.len] = 0;
  vx_status st = name_of(name, nm);
  if (st == VX_OK) st = file_of(dir, &d);
  if (st == VX_OK && !may(dir, &d.d, MAY_W)) st = VX_ERR_ACCESS;
  if (st == VX_OK) st = vxfs_symlink(&vol, tree_of(dir), &d, nm, tgt, uid_of(dir), d.d.gid, now_ns(), &f);
  if (st != VX_OK) return st;
  changed();
  *out = node_in(dir, &f);
  return VX_OK;
}

static char link_target[4097];

static vx_status fs_readlink([[maybe_unused]] void *ctx, uint64_t node, vx_str *target) {
  vxfs_file f;
  vx_status st = file_of(node, &f);
  if (st != VX_OK) return st;
  if (!(f.d.mode & VXFS_DMSYMLINK)) return VX_ERR_INVALID;
  uint64_t got = 0;
  st = vxfs_read(&vol, tree_of(node), &f, 0, link_target, sizeof link_target - 1, &got);
  *target = (vx_str){link_target, got};
  return st;
}

static vx_status fs_fsync([[maybe_unused]] void *ctx, [[maybe_unused]] uint64_t node) { return commit(); }

static vx_instant tick([[maybe_unused]] void *ctx) {
  if (dirty && vx_clock_read() >= next_commit) commit();
  return dirty ? next_commit : VX_INFINITE;
}

static p9_ring_server server = {
    .fs = {.attach_as = fs_attach,
           .walk = fs_walk,
           .parent = fs_parent,
           .stat = fs_stat,
           .open = fs_open,
           .read = fs_read,
           .readdir = fs_readdir,
           .write = fs_write,
           .create = fs_create,
           .remove = fs_remove,
           .clunk = fs_clunk,
           .setattr = fs_setattr,
           .rename = fs_rename,
           .symlink = fs_symlink,
           .readlink = fs_readlink,
           .fsync = fs_fsync},
    .name = VX_STR("fsd"),
    .supported = P9_EXT_POSIX | P9_EXT_XATTR,
    .tick = tick,
};

// --- Starting ---

// The disk's connector: the one handle named srv:NAME.
static vx_handle find_disk(void) {
  for (uint32_t i = 0; i < vx_spawn.handle_count; i++) {
    vx_str n = vx_spawn.handle_names[i];
    if (n.len > 4 && memcmp(n.ptr, "srv:", 4) == 0 && vx_spawn.handles[i]) {
      disk_name = (vx_str){n.ptr + 4, n.len - 4};
      vx_handle h = vx_spawn.handles[i];
      vx_spawn.handles[i] = VX_HANDLE_NONE;
      return h;
    }
  }
  fail("no connector to a disk (connect=)", VX_OK);
}

const char *vx_main(void) {
  server.listen = vx_spawn_take("listen");
  if (!server.listen) fail("no listen channel (post=)", VX_OK);
  vx_handle connector = find_disk();
  vx_status st = vx_blk_open(&disk, connector, 0);
  if (st != VX_OK) fail("cannot open a session on the disk", st);
  if (disk.flags & VX_BLOCK_INFO_READONLY) fail("the disk is read-only", VX_OK);
  if (VXFS_BLKSZ % disk.sector) fail("the disk's sectors do not divide a block", VX_OK);
  vxfs_dev dev = {.ctx = &disk,
                  .read = dev_read,
                  .write = dev_write,
                  .barrier = dev_barrier,
                  .size = disk.sectors * disk.sector / VXFS_BLKSZ * VXFS_BLKSZ};
  if ((st = vxfs_mount(&vol, dev, (vxfs_mem){.alloc = mem_alloc, .free = mem_free}, CACHE_BLOCKS)) != VX_OK)
    fail("no volume it can mount", st);
  load_users();
  vx_print(VX_STR("fsd: /srv/"));
  vx_print(disk_name);
  vx_print(VX_STR(": commit "));
  vx_print_u64(vol.sb.commit);
  vx_print(VX_STR(", "));
  vx_print_u64(vol.fs.narenas);
  vx_print(VX_STR(" arenas, "));
  vx_print_u64(nusers);
  vx_print(VX_STR(" users\n"));
  vx_print(VX_STR("fsd: serving /srv/fsd\n"));
  return p9_ring_serve(&server) == VX_OK ? nullptr : "cannot serve";
}
