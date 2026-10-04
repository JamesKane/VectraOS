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
// The adm branch's root has two files fsd makes (11 §9): status, an ndb
// text of the volume (its commit, space, the last check, every label), and
// ctl, which takes one command a write, adm's to give, a failure the
// write's. An attach name of %BRANCH is the branch without permissions, for
// adm's members (gefs's permissive attach).
//
// An attach name that labels a snapshot, not a branch, is that snapshot,
// read-only. `dump` is the dump view (11 §5): /YYYY/MMDD/BRANCH for every
// label named BRANCH@YYYY-MM-DD, each BRANCH that snapshot, read-only. Up to
// RO_SLOTS snapshots are open at once; deleting a label closes its snapshot,
// and fids on it find nothing from then on.
//
// Changes are committed every 5 s, and by Tfsync, which is answered once
// its commit is durable (11 §6). Single-threaded: one loop, which waits for
// the disk.
//
// fsd is the system's pager (11 §8), when its manifest gives it `pager`:
// Tmap answers with a pager-backed VMO for the whole file, one per file
// however many map it, which the kernel asks fsd to fill a page at a time.
// Pages written through mappings are written back before each commit, and
// before a Tread of the file, so reads see them; a Twrite goes to the pages
// there as well as to the volume. An entry stays until nothing but fsd
// refers to its VMO, and keeps its file open until then, as a mapping keeps
// a removed file's data in POSIX.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-driver/blkclient.c"
#include "../../lib/vx-9p/ring_server.c"
#include "../../lib/vx-fs/check.c"
#include "../../lib/vx-fs/file.c"

static constexpr vx_duration COMMIT_EVERY = 5'000'000'000;
static constexpr uint32_t CACHE_BLOCKS = 1024; // 16 MiB of tree nodes and data
static constexpr uint32_t MAX_OPEN = 512;      // distinct nodes open at once
static constexpr int SLOT_SHIFT = 56, USER_SHIFT = 48;
static constexpr uint32_t MAX_USERS = 127, MAX_MEMBERS = 32; // a user index is 7 bits of the node id
static constexpr uint64_t PERMISSIVE = 1ull << 55;           // the node's attach was %BRANCH
static constexpr uint64_t CTL_QID = (1ull << 48) - 2, STATUS_QID = (1ull << 48) - 3; // adm's, made up
static constexpr uint32_t NONE_ID = 0xffff'fffe; // none's id when the users file has no none

static vx_blk disk;
static vxfs_vol vol;
static vx_str disk_name;
static bool dirty;
static vx_instant next_commit;
static bool reaped[VXFS_MAXBRANCH];
static bool halted; // ctl's halt: committed, and no more changes

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

// Times, in ns: UTC once there is a wall clock (ADR-0031), from boot before,
// as sysfs's realtime is.
static int64_t now_ns(void) { return vx_clock_utc(); }

static uint64_t node_of(uint32_t slot, uint32_t user, uint64_t qid) {
  return (uint64_t)slot << SLOT_SHIFT | (uint64_t)user << USER_SHIFT | qid;
}
static uint32_t slot_of(uint64_t node) { return (uint32_t)(node >> SLOT_SHIFT); }
static uint32_t user_of(uint64_t node) { return (uint32_t)(node >> USER_SHIFT) & 0x7f; }
static bool permissive(uint64_t node) { return node & PERMISSIVE; }
static uint64_t qid_of(uint64_t node) { return node & ((1ull << USER_SHIFT) - 1); }
// The file a node is, whoever reaches it and however: its slot and qid.
static uint64_t file_key(uint64_t node) { return (uint64_t)slot_of(node) << SLOT_SHIFT | qid_of(node); }

// --- Read-only snapshots, and the dump view (11 §5) ---

static constexpr uint32_t RO_FIRST = 16, RO_SLOTS = 32, DUMP_SLOT = 0x7f; // node slots past the branches'

typedef struct snapro {
  bool used;
  char name[VXFS_LABELMAX + 1];
  uint16_t nname;
  vxfs_tree t;
  uint64_t root;       // its root's qid
  uint32_t year, mmdd; // a dated label's, its place in the dump view; else 0
} snapro;
static snapro ro[RO_SLOTS];

static bool digits(const char *p, uint32_t n, uint32_t *v) {
  *v = 0;
  for (uint32_t i = 0; i < n; i++) {
    if (p[i] < '0' || p[i] > '9') return false;
    *v = *v * 10 + (uint32_t)(p[i] - '0');
  }
  return true;
}

// A label named BRANCH@YYYY-MM-DD: its date, and the branch's length.
static bool dated(const char *label, uint16_t n, uint32_t *year, uint32_t *mmdd, uint16_t *nbranch) {
  if (n < 12 || label[n - 11] != '@' || label[n - 6] != '-' || label[n - 3] != '-') return false;
  uint32_t mm, dd;
  if (!digits(label + n - 10, 4, year) || !digits(label + n - 5, 2, &mm) || !digits(label + n - 2, 2, &dd) ||
      !mm || mm > 12 || !dd || dd > 31 || !*year)
    return false;
  *mmdd = mm * 100 + dd, *nbranch = (uint16_t)(n - 11);
  return true;
}

// Snapshot `name` open read-only, in *slot (of ro[]).
static vx_status ro_open(const char *name, uint32_t *slot) {
  uint16_t n = vxfs_namelen(name, VXFS_LABELMAX);
  uint32_t free = RO_SLOTS;
  for (uint32_t i = 0; i < RO_SLOTS; i++) {
    if (ro[i].used && ro[i].nname == n && !memcmp(ro[i].name, name, n)) {
      *slot = i;
      return VX_OK;
    }
    if (!ro[i].used && free == RO_SLOTS) free = i;
  }
  if (free == RO_SLOTS) return VX_ERR_NO_MEMORY;
  snapro *r = &ro[free];
  *r = (snapro){.nname = n};
  memcpy(r->name, name, n);
  vx_status st = vxfs_snap_open(&vol, name, &r->t);
  vxfs_file root;
  if (st == VX_OK) st = vxfs_root(&vol, &r->t, &root);
  if (st != VX_OK) return st;
  uint16_t nb;
  if (!dated(name, n, &r->year, &r->mmdd, &nb)) r->year = r->mmdd = 0;
  r->root = root.d.qid_path, r->used = true;
  *slot = free;
  return VX_OK;
}

static void pcache_forget(uint32_t slot, bool dead);

// A label going: its snapshot, if open, closed first.
static void ro_drop(const char *name) {
  uint16_t n = vxfs_namelen(name, VXFS_LABELMAX);
  for (uint32_t i = 0; i < RO_SLOTS; i++)
    if (ro[i].used && ro[i].nname == n && !memcmp(ro[i].name, name, n)) {
      ro[i] = (snapro){};
      pcache_forget(RO_FIRST + i, true); // its slot may be another snapshot's next
    }
}

static bool is_dump(uint64_t node) { return slot_of(node) == DUMP_SLOT; }
static bool is_readonly(uint64_t node) { return slot_of(node) >= RO_FIRST; }

// A dump view directory: the root (level 0), a year (1), or a day (2).
static uint64_t dump_node(uint64_t from, uint32_t level, uint32_t year, uint32_t mmdd) {
  return node_of(DUMP_SLOT, user_of(from), (uint64_t)level << 40 | (uint64_t)year << 16 | mmdd) |
         (from & PERMISSIVE);
}
static uint32_t dump_level(uint64_t node) { return (uint32_t)(qid_of(node) >> 40); }
static uint32_t dump_year(uint64_t node) { return (uint32_t)(qid_of(node) >> 16) & 0xffff; }
static uint32_t dump_mmdd(uint64_t node) { return (uint32_t)qid_of(node) & 0xffff; }

// The dated labels, sorted by date then branch: what the dump view lists.
typedef struct dumped {
  uint32_t year, mmdd;
  char branch[VXFS_LABELMAX + 1];
  uint16_t nbranch;
} dumped;
static dumped dumps[256];
static uint32_t ndumps;

static int dump_cmp(const dumped *a, const dumped *b) {
  if (a->year != b->year) return a->year < b->year ? -1 : 1;
  if (a->mmdd != b->mmdd) return a->mmdd < b->mmdd ? -1 : 1;
  return vxfs_keycmp((const uint8_t *)a->branch, a->nbranch, (const uint8_t *)b->branch, b->nbranch);
}

static void scan_dumps(void) {
  ndumps = 0;
  uint8_t pfx = VXFS_KLABEL;
  vxfs_scan sc;
  vxfs_scan_start(&sc, &vol.snap, &pfx, 1);
  vxfs_kvp kv;
  while (ndumps < 256 && vxfs_scan_next(&vol.fs, &sc, &kv)) {
    dumped d = {};
    if (kv.nv != 12 || (vxfs_get32(kv.v + 8) & VXFS_LMUT) ||
        !dated((const char *)kv.k + 1, (uint16_t)(kv.nk - 1), &d.year, &d.mmdd, &d.nbranch))
      continue;
    memcpy(d.branch, kv.k + 1, d.nbranch);
    uint32_t at = ndumps;
    while (at && dump_cmp(&dumps[at - 1], &d) > 0) dumps[at] = dumps[at - 1], at--;
    dumps[at] = d, ndumps++;
  }
  vxfs_scan_end(&vol.fs, &sc);
}

static void put4(char *p, uint32_t v) {
  for (int i = 3; i >= 0; i--) p[i] = (char)('0' + v % 10), v /= 10;
}

// A dump view directory as an entry: a name to stat, no more.
static vx_status dump_file(uint64_t node, vxfs_file *f) {
  *f = (vxfs_file){.d = {.qid_path = qid_of(node), .qid_type = VXFS_QTDIR, .mode = VXFS_DMDIR | 0555}};
  char name[4];
  uint32_t level = dump_level(node);
  put4(name, level == 1 ? dump_year(node) : dump_mmdd(node));
  f->nkey = key_ent(f->key, 0, (const uint8_t *)name, level ? 4 : 0);
  return VX_OK;
}

static vxfs_tree *tree_of(uint64_t node) {
  uint32_t s = slot_of(node);
  if (s < VXFS_MAXBRANCH) return vol.br[s].open ? &vol.br[s].t : nullptr;
  if (s >= RO_FIRST && s < RO_FIRST + RO_SLOTS) return ro[s - RO_FIRST].used ? &ro[s - RO_FIRST].t : nullptr;
  return nullptr;
}

static bool is_branch(uint64_t node, const char *name) {
  uint32_t s = slot_of(node);
  uint16_t n = vxfs_namelen(name, VXFS_LABELMAX);
  return s < VXFS_MAXBRANCH && vol.br[s].open && vol.br[s].nname == n && !memcmp(vol.br[s].name, name, n);
}

static bool is_made_up(uint64_t node) {
  return is_branch(node, "adm") && (qid_of(node) == CTL_QID || qid_of(node) == STATUS_QID);
}

// ctl or status, as an entry in the adm branch's root.
static vx_status made_up(uint64_t node, vxfs_file *f) {
  vxfs_file root;
  vx_status st = vxfs_root(&vol, tree_of(node), &root);
  if (st != VX_OK) return st;
  bool ctl = qid_of(node) == CTL_QID;
  const char *name = ctl ? "ctl" : "status";
  *f = (vxfs_file){
      .d = {.qid_path = qid_of(node), .mode = ctl ? 0660 : 0444, .mtime = now_ns(), .atime = now_ns()}};
  f->nkey = key_ent(f->key, root.d.qid_path, (const uint8_t *)name, ctl ? 3 : 6);
  return VX_OK;
}

static vx_status file_of(uint64_t node, vxfs_file *f) {
  if (is_dump(node)) return dump_file(node, f);
  vxfs_tree *t = tree_of(node);
  if (!t) return VX_ERR_NOT_FOUND;
  if (is_made_up(node)) return made_up(node, f);
  return vxfs_file_by_qid(&vol, t, qid_of(node), f);
}

// The node of entry f, found from dir: in its branch, for its user, as permissive as dir.
static uint64_t node_in(uint64_t dir, const vxfs_file *f) {
  return node_of(slot_of(dir), user_of(dir), f->d.qid_path) | (dir & PERMISSIVE);
}

static void writeback_all(void);

static void changed(void) {
  if (!dirty) next_commit = vx_clock_read() + COMMIT_EVERY;
  dirty = true;
}

static vx_status commit(void) {
  writeback_all(); // what mappings wrote, into the volume first
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

// Open fids, counted by file (file_key: every user's, through any attach,
// together): an orphan's data goes with the last.
typedef struct opened {
  uint64_t node; // one of them, to find the file by
  uint32_t count;
} opened;
static opened opens[MAX_OPEN];

static opened *open_slot(uint64_t node, bool make) {
  opened *free = nullptr;
  for (uint32_t i = 0; i < MAX_OPEN; i++) {
    if (opens[i].count && file_key(opens[i].node) == file_key(node)) return &opens[i];
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

static user users[MAX_USERS + 1];  // and none, whether the file names it or not: index 127 fits 7 bits
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
  if (permissive(node)) return true;
  if (!is_none(node)) {
    uint32_t me = uid_of(node);
    if (me == d->uid && ((d->mode >> 6) & want) == want) return true;
    if (in_group(me, d->gid) && ((d->mode >> 3) & want) == want) return true;
  }
  return (d->mode & want) == want;
}

static bool is_adm(uint64_t node) {
  return permissive(node) || (!is_none(node) && in_group(uid_of(node), 0));
}

// A change, which a halted volume refuses.
static vx_status mutable(uint64_t node) {
  if (halted) return VX_ERR_BAD_STATE;
  if (is_made_up(node) || is_readonly(node)) return VX_ERR_ACCESS; // a snapshot, or the dump view
  return VX_OK;
}

// The dump view's names: a year, a day in it, a branch's snapshot that day.
static vx_status dump_walk(uint64_t dir, vx_str name, uint64_t *child) {
  uint32_t level = dump_level(dir), v;
  scan_dumps();
  if (level < 2) {
    if (name.len != 4 || !digits(name.ptr, 4, &v)) return VX_ERR_NOT_FOUND;
    for (uint32_t i = 0; i < ndumps; i++)
      if (level == 0 ? dumps[i].year == v : dumps[i].year == dump_year(dir) && dumps[i].mmdd == v) {
        *child = level == 0 ? dump_node(dir, 1, v, 0) : dump_node(dir, 2, dump_year(dir), v);
        return VX_OK;
      }
    return VX_ERR_NOT_FOUND;
  }
  for (uint32_t i = 0; i < ndumps; i++) {
    const dumped *d = &dumps[i];
    if (d->year != dump_year(dir) || d->mmdd != dump_mmdd(dir) || d->nbranch != name.len ||
        memcmp(d->branch, name.ptr, name.len) != 0)
      continue;
    char label[VXFS_LABELMAX + 1];
    memcpy(label, d->branch, d->nbranch);
    label[d->nbranch] = '@';
    put4(label + d->nbranch + 1, d->year);
    label[d->nbranch + 5] = '-';
    label[d->nbranch + 6] = (char)('0' + d->mmdd / 1000),
                       label[d->nbranch + 7] = (char)('0' + d->mmdd / 100 % 10);
    label[d->nbranch + 8] = '-';
    label[d->nbranch + 9] = (char)('0' + d->mmdd / 10 % 10),
                       label[d->nbranch + 10] = (char)('0' + d->mmdd % 10);
    label[d->nbranch + 11] = 0;
    uint32_t r;
    vx_status st = ro_open(label, &r);
    if (st != VX_OK) return st;
    *child = node_of(RO_FIRST + r, user_of(dir), ro[r].root) | (dir & PERMISSIVE);
    return VX_OK;
  }
  return VX_ERR_NOT_FOUND;
}

// The index-th of a dump view directory's entries.
static vx_status dump_readdir(uint64_t dir, uint32_t index, uint64_t *child) {
  uint32_t level = dump_level(dir), n = 0;
  scan_dumps();
  for (uint32_t i = 0; i < ndumps; i++) {
    const dumped *d = &dumps[i];
    bool in = level == 0 || d->year == dump_year(dir);
    if (level == 2) in = in && d->mmdd == dump_mmdd(dir);
    bool first = true; // the first of its year (level 0) or day (level 1); a day's branches each
    if (i && level == 0) first = dumps[i - 1].year != d->year;
    if (i && level == 1) first = dumps[i - 1].year != d->year || dumps[i - 1].mmdd != d->mmdd;
    if (!in || !first || n++ != index) continue;
    if (level < 2) {
      *child = level == 0 ? dump_node(dir, 1, d->year, 0) : dump_node(dir, 2, d->year, d->mmdd);
      return VX_OK;
    }
    return dump_walk(dir, (vx_str){d->branch, d->nbranch}, child);
  }
  return VX_ERR_NOT_FOUND;
}

// --- The 9P side ---

static vx_status fs_attach([[maybe_unused]] void *ctx, vx_str aname, vx_str uname, uint64_t *root) {
  char name[VXFS_LABELMAX + 1];
  bool all = aname.len && aname.ptr[0] == '%'; // permissive: adm's members only
  if (all) aname.ptr++, aname.len--;
  uint32_t who = user_named(uname);
  if (all && (who == none_user || !in_group(users[who].id, 0))) return VX_ERR_ACCESS;
  if (!aname.len || aname.len > VXFS_LABELMAX) return VX_ERR_NOT_FOUND;
  memcpy(name, aname.ptr, aname.len);
  name[aname.len] = 0;
  uint64_t base = node_of(0, who, 0) | (all ? PERMISSIVE : 0);
  if (aname.len == 4 && !memcmp(name, "dump", 4)) {
    *root = dump_node(base, 0, 0, 0);
    return VX_OK;
  }
  vxfs_branch *br;
  vx_status st = vxfs_branch_open(&vol, name, &br);
  if (st == VX_ERR_ACCESS) { // a snapshot's label: the snapshot, read-only
    uint32_t r;
    if ((st = ro_open(name, &r)) != VX_OK) return st;
    *root = node_of(RO_FIRST + r, who, ro[r].root) | (all ? PERMISSIVE : 0);
    return VX_OK;
  }
  if (st != VX_OK) return VX_ERR_NOT_FOUND;
  uint32_t slot = (uint32_t)(br - vol.br);
  if (!reaped[slot]) { // what a crash left of files removed while open
    uint32_t n = 0;
    if ((st = vxfs_reap_all(&vol, &br->t, &n)) != VX_OK) return st;
    if (n) changed();
    reaped[slot] = true;
  }
  vxfs_file f;
  if ((st = vxfs_root(&vol, &br->t, &f)) != VX_OK) return st;
  *root = node_of(slot, who, f.d.qid_path) | (all ? PERMISSIVE : 0);
  return VX_OK;
}

static vx_status fs_walk([[maybe_unused]] void *ctx, uint64_t dir, vx_str name, uint64_t *child) {
  char nm[VXFS_NAMEMAX + 1];
  if (name.len > VXFS_NAMEMAX) return VX_ERR_RANGE;
  memcpy(nm, name.ptr, name.len);
  nm[name.len] = 0;
  if (is_dump(dir)) return dump_walk(dir, name, child);
  vxfs_file d, f;
  vx_status st = file_of(dir, &d);
  if (st == VX_OK && (d.d.mode & VXFS_DMDIR) && !may(dir, &d.d, MAY_X)) st = VX_ERR_ACCESS;
  bool ctl = name.len == 3 && !memcmp(nm, "ctl", 3), status = name.len == 6 && !memcmp(nm, "status", 6);
  if (st == VX_OK && is_branch(dir, "adm") && d.nkey == 9 && (ctl || status)) {
    *child = node_of(slot_of(dir), user_of(dir), ctl ? CTL_QID : STATUS_QID) | (dir & PERMISSIVE);
    return VX_OK;
  }
  if (st == VX_OK) st = vxfs_walk(&vol, tree_of(dir), &d, nm, &f);
  if (st == VX_ERR_INVALID) st = VX_ERR_NOT_FOUND; // through a file
  if (st == VX_OK) *child = node_in(dir, &f);
  return st;
}

static vx_status fs_parent([[maybe_unused]] void *ctx, uint64_t node, uint64_t *parent) {
  if (is_dump(node)) { // a day's year, a year's root
    uint32_t level = dump_level(node);
    *parent = dump_node(node, level ? level - 1 : 0, level == 2 ? dump_year(node) : 0, 0);
    return VX_OK;
  }
  uint32_t s = slot_of(node);
  if (is_readonly(node) && s < RO_FIRST + RO_SLOTS && ro[s - RO_FIRST].used && ro[s - RO_FIRST].year &&
      qid_of(node) == ro[s - RO_FIRST].root) { // a dated snapshot's root: its day, in the dump view
    *parent = dump_node(node, 2, ro[s - RO_FIRST].year, ro[s - RO_FIRST].mmdd);
    return VX_OK;
  }
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

// A root's name: a dated snapshot's is its branch's, as the dump view lists it; others are /.
static vx_str root_name(uint64_t node) {
  uint32_t s = slot_of(node);
  if (is_readonly(node) && s < RO_FIRST + RO_SLOTS && ro[s - RO_FIRST].used && ro[s - RO_FIRST].year) {
    const snapro *r = &ro[s - RO_FIRST];
    return (vx_str){r->name, r->nname - 11u};
  }
  return VX_STR("/");
}

static vxfs_file stat_file; // the name in a stat lives until the next call

static vx_status fs_stat([[maybe_unused]] void *ctx, uint64_t node, p9_stat *out) {
  vx_status st = file_of(node, &stat_file);
  if (st != VX_OK) return st;
  const vxfs_dir *d = &stat_file.d;
  bool dir = d->mode & VXFS_DMDIR, root = stat_file.nkey == 9 && !vxfs_is_orphan(&stat_file);
  uint8_t qtype = dir ? P9_QTDIR : P9_QTFILE;
  *out = (p9_stat){.qid = {qtype, d->qid_vers, node},
                   .mode = d->mode,
                   .atime = (uint32_t)(d->atime / 1'000'000'000),
                   .mtime = (uint32_t)(d->mtime / 1'000'000'000),
                   .length = dir ? 0 : d->length,
                   .name = root ? root_name(node)
                                : (vx_str){(const char *)stat_file.key + 9, stat_file.nkey - 9u},
                   .uid = user_name(uidbuf[0], d->uid),
                   .gid = user_name(uidbuf[1], d->gid),
                   .muid = user_name(uidbuf[2], d->muid)};
  return VX_OK;
}

// --- The adm files (11 §9) ---

static char status_text[16 * 1024];
static uint32_t status_len;
static char check_said[160] = "unchecked"; // the last check's verdict

static void sput(const char *s, size_t n) {
  if (status_len + n > sizeof status_text) n = sizeof status_text - status_len;
  memcpy(status_text + status_len, s, n);
  status_len += (uint32_t)n;
}
static void sputs(const char *s) { sput(s, vx_cstr(s).len); }
static void sputn(uint64_t v) {
  char buf[24];
  uint32_t n = 0;
  do buf[sizeof buf - 1 - n++] = (char)('0' + v % 10), v /= 10;
  while (v);
  sput(buf + sizeof buf - n, n);
}

// status: one ndb record for the volume, then one for each label.
static vx_status make_status(void) {
  status_len = 0;
  uint64_t used = 0, size = 0;
  for (uint32_t i = 0; i < vol.fs.narenas; i++) used += vol.fs.arenas[i].used, size += vol.fs.arenas[i].size;
  sputs("volume commit="), sputn(vol.sb.commit), sputs(" arenas="), sputn(vol.fs.narenas);
  sputs(" used="), sputn(used), sputs(" size="), sputn(size), sputs(" users="), sputn(nusers);
  sputs(" check="), sputs(check_said), sputs(halted ? " halted\n" : "\n");
  uint8_t pfx = VXFS_KLABEL;
  vxfs_scan sc;
  vxfs_scan_start(&sc, &vol.snap, &pfx, 1);
  vxfs_kvp kv;
  while (vxfs_scan_next(&vol.fs, &sc, &kv)) {
    if (kv.nv != 12) continue;
    sputs("label="), sput((const char *)kv.k + 1, kv.nk - 1u);
    sputs(" snapshot="), sputn(vxfs_get64(kv.v));
    sputs(vxfs_get32(kv.v + 8) & VXFS_LMUT ? " branch\n" : "\n");
  }
  vxfs_scan_end(&vol.fs, &sc);
  return vol.fs.err;
}

// The words of a ctl command, at most 4, each NUL-terminated in buf; 0 if
// they do not fit it (an over-long word is refused, not cut, so the command
// that runs is never one that was not written).
static uint32_t words(vx_str cmd, char *buf, size_t cap, const char **w) {
  uint32_t n = 0;
  size_t at = 0;
  for (size_t i = 0; i < cmd.len && n < 4;) {
    while (i < cmd.len && (cmd.ptr[i] == ' ' || cmd.ptr[i] == '\t' || cmd.ptr[i] == '\n')) i++;
    if (i == cmd.len) break;
    w[n++] = buf + at;
    for (; i < cmd.len && cmd.ptr[i] != ' ' && cmd.ptr[i] != '\t' && cmd.ptr[i] != '\n'; i++) {
      if (at + 2 > cap) return 0; // the character and the word's NUL
      buf[at++] = cmd.ptr[i];
    }
    if (at + 1 > cap) return 0;
    buf[at++] = 0;
  }
  return n;
}

static bool is(const char *a, const char *b) {
  while (*a && *a == *b) a++, b++;
  return *a == *b;
}

// The branch named, if fsd has it open.
static vxfs_branch *open_branch(const char *name) {
  uint16_t n = vxfs_namelen(name, VXFS_LABELMAX);
  for (uint32_t i = 0; i < VXFS_MAXBRANCH; i++)
    if (vol.br[i].open && vol.br[i].nname == n && !memcmp(vol.br[i].name, name, n)) return &vol.br[i];
  return nullptr;
}

static vx_status run_check(void) {
  vxfs_check c;
  vx_status st = vxfs_check_volume(&vol, &c);
  char *p = check_said;
  size_t at = 0;
  const char *head = st == VX_OK ? "clean" : "NOT-CLEAN";
  while (*head) p[at++] = *head++;
  if (st != VX_OK) {
    const char *what[] = {",leaked=", ",unallocated=", ",damaged=", ",bad-snapshots=", ",bad-deadlists="};
    uint64_t n[] = {c.leaked, c.unallocated, c.damaged, c.bad_snaps, c.bad_lists};
    for (int i = 0; i < 5; i++) {
      for (const char *q = what[i]; *q && at + 1 < sizeof check_said; q++) p[at++] = *q;
      char d[24];
      uint32_t k = 0;
      uint64_t v = n[i];
      do d[k++] = (char)('0' + v % 10), v /= 10;
      while (v);
      while (k && at + 1 < sizeof check_said) p[at++] = d[--k];
    }
  }
  p[at] = 0;
  return st;
}

// One ctl command (11 §9). Its failure is the write's.
static vx_status ctl_command(uint64_t node, vx_str cmd) {
  if (!is_adm(node)) return VX_ERR_ACCESS;
  char buf[3 * (VXFS_LABELMAX + 1) + 16];
  const char *w[4];
  uint32_t n = words(cmd, buf, sizeof buf, w);
  if (!n) return VX_ERR_INVALID;
  vx_status st;
  if (is(w[0], "sync") && n == 1) return commit();
  if (is(w[0], "check") && n == 1) {
    if ((st = commit()) != VX_OK) return st;
    run_check();
    return VX_OK; // the verdict is status's to say
  }
  if (is(w[0], "halt") && n == 1) {
    st = commit();
    halted = true;
    return st;
  }
  if (halted) return VX_ERR_BAD_STATE;
  if (is(w[0], "snap") && n == 3) { // snap BRANCH LABEL: its state now, labelled
    if ((st = commit()) != VX_OK) return st;
    st = vxfs_label(&vol, w[1], w[2], 0);
  } else if (is(w[0], "fork") && n == 3) { // fork LABEL BRANCH
    if ((st = commit()) != VX_OK) return st;
    st = vxfs_label(&vol, w[1], w[2], VXFS_LMUT);
  } else if (is(w[0], "del") && n == 2) { // del LABEL: not a branch in use, nor adm
    if (is(w[1], "adm")) return VX_ERR_ACCESS;
    if (open_branch(w[1])) return VX_ERR_BAD_STATE;
    ro_drop(w[1]); // its snapshot, if open: fids on it find nothing now
    st = vxfs_unlabel(&vol, w[1]);
  } else if (is(w[0], "rollback") && n == 3) { // rollback BRANCH LABEL, the old head kept as BRANCH@before-N
    if (is(w[1], "adm")) return VX_ERR_ACCESS;
    if ((st = commit()) != VX_OK) return st;
    char keep[VXFS_LABELMAX + 1];
    size_t k = 0;
    for (const char *q = w[1]; *q && k + 32 < sizeof keep; q++) keep[k++] = *q;
    for (const char *q = "@before-"; *q; q++) keep[k++] = *q;
    char d[24];
    uint32_t nd = 0;
    uint64_t c = vol.sb.commit;
    do d[nd++] = (char)('0' + c % 10), c /= 10;
    while (c);
    while (nd) keep[k++] = d[--nd];
    keep[k] = 0;
    st = vxfs_label(&vol, w[1], keep, 0);
    vxfs_branch *br = open_branch(w[1]);
    if (st == VX_OK) st = br ? vxfs_branch_rollback(&vol, br, w[2]) : vxfs_rollback(&vol, w[1], w[2]);
    if (st == VX_OK && br) pcache_forget((uint32_t)(br - vol.br), false); // its files' pages, as they are now
  } else {
    return VX_ERR_INVALID;
  }
  // Durable once ctl's write returns: a rollback, say, must outlive a power
  // cut right after it (distd's rollback by hand, M5 step 9d).
  if (st == VX_OK) changed(), st = commit();
  return st;
}

// --- The page cache (11 §8) ---

static void fs_clunk_node(uint64_t node);

static constexpr uint32_t MAX_CACHED = 64;                     // files mapped at once
static constexpr vx_duration SUPPLY_DEADLINE = 10'000'000'000; // longer than any commit takes
static constexpr uint64_t PAGER_KEY = P9_KEY_USER | 1;

typedef struct cached {
  bool used, dead; // dead: its snapshot has gone, and its pages are zeros from now on
  uint64_t key;    // slot << SLOT_SHIFT | qid: the file, whoever maps it
  uint64_t node;   // a node of it, which the entry keeps open
  uint64_t size;   // the VMO's
  vx_handle vmo;
} cached;
static cached pcache[MAX_CACHED];
static vx_handle pager, scratch; // scratch: the anonymous page supplies are copied from
static uint8_t page_buf[4096];

static uint64_t pcache_key(uint64_t node) { return file_key(node); }

static cached *pcache_find(uint64_t node) {
  if (!pager) return nullptr;
  uint64_t key = pcache_key(node);
  for (uint32_t i = 0; i < MAX_CACHED; i++)
    if (pcache[i].used && !pcache[i].dead && pcache[i].key == key) return &pcache[i];
  return nullptr;
}

// Pages the mappings wrote, into the volume: each dirty range cleaned
// first, then read, so a write after the clean is dirty for next time.
// Only what lies within the file: past its end, a write is lost.
static void writeback_ranges(cached *c, vxfs_file *f, const vx_pager_range *ranges, int64_t n);

static void writeback(cached *c) {
  if (c->dead || halted) return;
  vxfs_file f;
  if (file_of(c->node, &f) != VX_OK) return;
  // DIRTY answers 64 ranges at most: asked again until it has none, each
  // set cleaned before the next is asked for. Bounded, as a writer could
  // keep dirtying pages: what is left is the next writeback's.
  for (uint32_t round = 0; round < 4096; round++) {
    vx_pager_range ranges[VX_PAGER_RANGES];
    int64_t n = vx_pager_op(pager, c->vmo, VX_PAGER_DIRTY, 0, c->size, ranges);
    if (n <= 0) return;
    writeback_ranges(c, &f, ranges, n);
  }
}

static void writeback_ranges(cached *c, vxfs_file *f, const vx_pager_range *ranges, int64_t n) {
  for (int64_t i = 0; i < n; i++) {
    vx_pager_op(pager, c->vmo, VX_PAGER_CLEAN, ranges[i].offset, ranges[i].size, nullptr);
    for (uint64_t at = ranges[i].offset; at < ranges[i].offset + ranges[i].size && at < f->d.length;
         at += 4096) {
      uint64_t len = f->d.length - at < 4096 ? f->d.length - at : 4096;
      if (vx_vmo_rw(c->vmo, VX_VMO_READ, at, page_buf, len) != VX_OK) continue;
      if (vxfs_write(&vol, tree_of(c->node), f, at, page_buf, (uint32_t)len, now_ns(), uid_of(c->node)) ==
          VX_OK)
        changed();
    }
  }
}

static void pcache_drop(cached *c) {
  vx_handle_close(c->vmo);
  uint64_t node = c->node;
  *c = (cached){};
  fs_clunk_node(node); // the open it kept
}

// Every entry written back, and those nothing else refers to now let go.
static void writeback_all(void) {
  for (uint32_t i = 0; pager && i < MAX_CACHED; i++) {
    if (!pcache[i].used) continue;
    // Idle first: then nothing can write it between its writeback and its
    // going (only fsd could hand it out again, and fsd is here).
    bool idle = vx_pager_op(pager, pcache[i].vmo, VX_PAGER_IDLE, 0, 0, nullptr) == 1;
    writeback(&pcache[i]);
    if (idle) pcache_drop(&pcache[i]);
  }
}

// A slot's files changed under their mappings (a rollback), or went (dead):
// their clean pages out, to be asked for again.
static void pcache_forget(uint32_t slot, bool dead) {
  for (uint32_t i = 0; pager && i < MAX_CACHED; i++) {
    cached *c = &pcache[i];
    if (!c->used || slot_of(c->node) != slot) continue;
    if (dead) c->dead = true;
    vx_pager_op(pager, c->vmo, VX_PAGER_CLEAN, 0, c->size, nullptr); // what was written since: dropped
    vx_pager_op(pager, c->vmo, VX_PAGER_EVICT, 0, c->size, nullptr);
  }
}

// The kernel asks for pages: each read from the file (zeros past its end,
// or if the file has gone), and supplied.
static void supply(const vx_packet *pk) {
  uint32_t i = (uint32_t)pk->source;
  if (i >= MAX_CACHED || !pcache[i].used) return;
  cached *c = &pcache[i];
  vxfs_file f;
  bool there = !c->dead && file_of(c->node, &f) == VX_OK;
  uint64_t first = vx_pager_offset(pk->value);
  for (uint64_t p = 0; p < vx_pager_pages(pk->value); p++) {
    uint64_t at = first + p * 4096, got = 0;
    if (there && at < f.d.length) vxfs_read(&vol, tree_of(c->node), &f, at, page_buf, 4096, &got);
    memset(page_buf + got, 0, 4096 - got);
    if (vx_vmo_rw(scratch, VX_VMO_WRITE, 0, page_buf, 4096) == VX_OK)
      vx_pager_supply(pager, c->vmo, at, 4096, scratch, 0);
  }
}

static void on_event([[maybe_unused]] void *ctx, const vx_packet *pk) {
  if (pk->key == PAGER_KEY && pk->trigger == VX_TRIGGER_PAGER) supply(pk);
}

// A Twrite's bytes, into the pages the cache has of them too.
static void pcache_wrote(uint64_t node, uint64_t offset, const uint8_t *buf, uint32_t count) {
  cached *c = pcache_find(node);
  for (uint64_t done = 0; c && done < count && offset + done < c->size;) {
    uint64_t at = offset + done, n = 4096 - (at & 4095);
    if (n > count - done) n = count - done;
    if (n > c->size - at) n = c->size - at;
    memcpy(page_buf, buf + done, n);
    vx_vmo_rw(c->vmo, VX_VMO_WRITE, at, page_buf, n); // SHOULD_WAIT: not there, read from the volume later
    done += n;
  }
}

// A file's new size: the cache's pages past it zeroed or gone.
// A file's new size: its VMO's too (a page at least), pages past it gone
// and the last page's tail zeroed; or more pages, absent, if it grew.
static void pcache_truncated(uint64_t node, uint64_t size) {
  cached *c = pcache_find(node);
  if (!c) return;
  uint64_t keep = page_round(size) ? page_round(size) : 4096;
  if (keep != c->size && vx_pager_resize(pager, c->vmo, keep) == VX_OK) c->size = keep;
  memset(page_buf, 0, sizeof page_buf);
  if (size & 4095) vx_vmo_rw(c->vmo, VX_VMO_WRITE, size, page_buf, keep - size); // the last page's tail
  if (!size) vx_vmo_rw(c->vmo, VX_VMO_WRITE, 0, page_buf, 4096);
}

// The VMO is the file's size, in pages: a mapping past that is the
// client's to leave unmapped (Rmap says how much there is), so no one can
// grow a file's cache with pages of zeros (docs/proto/map.md).
static vx_status fs_map([[maybe_unused]] void *ctx, uint64_t node, uint64_t offset,
                        [[maybe_unused]] uint64_t length, uint32_t prot, vx_handle *out, uint64_t *vmo_offset,
                        uint64_t *avail) {
  if (!pager) return VX_ERR_UNSUPPORTED;
  if (is_made_up(node)) return VX_ERR_ACCESS;
  vx_status st = VX_OK;
  if ((prot & P9_PROT_WRITE) && (st = mutable(node)) != VX_OK) return st;
  vxfs_file f;
  if ((st = file_of(node, &f)) != VX_OK) return st;
  uint64_t want = page_round(f.d.length) ? page_round(f.d.length) : 4096;
  if (offset >= want) return VX_ERR_RANGE; // nothing of the file there
  cached *c = pcache_find(node);
  if (!c) { // a new entry: room made by letting go of those no one maps
    uint32_t i = 0;
    while (i < MAX_CACHED && pcache[i].used) i++;
    if (i == MAX_CACHED) writeback_all();
    for (i = 0; i < MAX_CACHED && pcache[i].used;) i++;
    if (i == MAX_CACHED) return VX_ERR_NO_MEMORY;
    opened *o = open_slot(node, true);
    if (!o) return VX_ERR_NO_MEMORY;
    if ((st = vx_vmo_create_pager(pager, i, want, &pcache[i].vmo)) != VX_OK) return st;
    o->count++;
    c = &pcache[i];
    c->used = true, c->key = pcache_key(node), c->node = node, c->size = want;
  } else if (want != c->size) { // the file grew (or shrank) by writes since
    if ((st = vx_pager_resize(pager, c->vmo, want)) != VX_OK) return st;
    c->size = want;
  }
  uint32_t rights = VX_RIGHT_READ | VX_RIGHT_MAP | VX_RIGHT_TRANSFER | VX_RIGHT_INSPECT;
  if (prot & P9_PROT_WRITE) rights |= VX_RIGHT_WRITE;
  if (prot & P9_PROT_EXEC) rights |= VX_RIGHT_EXEC;
  if ((st = vx_handle_dup(c->vmo, rights, out)) != VX_OK) return st;
  *vmo_offset = offset, *avail = c->size - offset;
  return VX_OK;
}

static vx_status truncate_to(uint64_t node, vxfs_file *f, uint64_t size) {
  vxfs_attr a = {.valid = VXFS_WSIZE | VXFS_WMTIME, .length = size, .mtime = now_ns()};
  vx_status st = vxfs_setattr(&vol, tree_of(node), f, &a, a.mtime);
  if (st == VX_OK) changed(), pcache_truncated(node, size);
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
  if (is_made_up(node)) { // ctl: adm's, to write; status: anyone's, to read
    bool ctl = qid_of(node) == CTL_QID;
    if (ctl ? (want & MAY_R) || !is_adm(node) : writes) return VX_ERR_ACCESS;
    if (!ctl && make_status() != VX_OK) return VX_ERR_NO_MEMORY;
    return VX_OK;
  }
  if (writes && is_readonly(node)) return VX_ERR_ACCESS;                  // a snapshot, or the dump view
  if (!(mode & P9_OJOIN) && !may(node, &f.d, want)) return VX_ERR_ACCESS; // a join has its open's rights
  if (halted && writes) return VX_ERR_BAD_STATE;
  opened *o = open_slot(node, true);
  if (!o) return VX_ERR_NO_MEMORY;
  if ((mode & P9_OTRUNC) && (st = truncate_to(node, &f, 0)) != VX_OK) return st;
  o->count++;
  return VX_OK;
}

static void fs_clunk([[maybe_unused]] void *ctx, uint64_t node, bool was_open) {
  if (was_open) fs_clunk_node(node);
}

// One open of node let go: a fid's, or a cache entry's.
static void fs_clunk_node(uint64_t node) {
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
  if (is_made_up(node)) { // status, as it was when opened (or read from the start)
    if (!offset) make_status();
    uint64_t left = offset < status_len ? status_len - offset : 0;
    if (*count > left) *count = (uint32_t)left;
    memcpy(buf, status_text + offset, *count);
    return VX_OK;
  }
  cached *c = pcache_find(node);
  if (c) writeback(c); // what its mappings wrote, read too
  vxfs_file f;
  vx_status st = file_of(node, &f);
  uint64_t got = 0;
  if (st == VX_OK) st = vxfs_read(&vol, tree_of(node), &f, offset, buf, *count, &got);
  *count = (uint32_t)got;
  return st;
}

static vx_status fs_write([[maybe_unused]] void *ctx, uint64_t node, uint64_t offset, const uint8_t *buf,
                          uint32_t *count) { // NOLINT(readability-non-const-parameter): p9_fs's signature
  if (is_made_up(node))
    return qid_of(node) == CTL_QID ? ctl_command(node, (vx_str){(const char *)buf, *count}) : VX_ERR_ACCESS;
  if (halted) return VX_ERR_BAD_STATE;
  vxfs_file f;
  vx_status st = file_of(node, &f);
  if (st != VX_OK) return st;
  if (f.d.mode & VXFS_DMDIR) return VX_ERR_ACCESS;
  st = vxfs_write(&vol, tree_of(node), &f, offset, buf, *count, now_ns(), uid_of(node));
  if (st == VX_OK) changed(), pcache_wrote(node, offset, buf, *count);
  return st;
}

// dref (docs/proto/dref.md): Tread and Twrite with the data in the
// client's VMO, through a bounce a chunk at a time, not by mapping it: a
// VMO of fsd's own page cache, mapped here, would fault to fsd itself.
static uint8_t ref_buf[64 * 1024];

static vx_status fs_read_ref([[maybe_unused]] void *ctx, uint64_t node, uint64_t offset, vx_handle vmo,
                             uint64_t roffset, uint32_t *count) {
  if (is_made_up(node)) return VX_ERR_ACCESS;
  cached *c = pcache_find(node);
  if (c) writeback(c);
  vxfs_file f;
  vx_status st = file_of(node, &f);
  uint32_t done = 0;
  while (st == VX_OK && done < *count) {
    uint64_t want = *count - done < sizeof ref_buf ? *count - done : sizeof ref_buf, got = 0;
    st = vxfs_read(&vol, tree_of(node), &f, offset + done, ref_buf, want, &got);
    if (st == VX_OK && got) st = vx_vmo_rw(vmo, VX_VMO_WRITE, roffset + done, ref_buf, got);
    if (st == VX_OK) done += (uint32_t)got;
    if (got < want) break; // the end of the file
  }
  *count = done;
  return done ? VX_OK : st; // what was read, if anything was, as a short read
}

static vx_status fs_write_ref([[maybe_unused]] void *ctx, uint64_t node, uint64_t offset, vx_handle vmo,
                              uint64_t roffset, uint32_t *count) {
  if (is_made_up(node)) return VX_ERR_ACCESS; // ctl takes a command a write, inline
  if (halted) return VX_ERR_BAD_STATE;
  vxfs_file f;
  vx_status st = file_of(node, &f);
  if (st != VX_OK) return st;
  if (f.d.mode & VXFS_DMDIR) return VX_ERR_ACCESS;
  uint32_t done = 0;
  while (st == VX_OK && done < *count) {
    uint32_t n = *count - done < sizeof ref_buf ? *count - done : (uint32_t)sizeof ref_buf;
    st = vx_vmo_rw(vmo, VX_VMO_READ, roffset + done, ref_buf, n);
    if (st == VX_OK)
      st = vxfs_write(&vol, tree_of(node), &f, offset + done, ref_buf, n, now_ns(), uid_of(node));
    if (st == VX_OK) changed(), pcache_wrote(node, offset + done, ref_buf, n), done += n;
  }
  *count = done;
  return done ? VX_OK : st;
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
  if (is_dump(dir)) return dump_readdir(dir, index, child);
  vxfs_file d;
  vx_status st = file_of(dir, &d);
  if (st != VX_OK) return st;
  if (!(d.d.mode & VXFS_DMDIR)) return VX_ERR_INVALID;
  if (is_branch(dir, "adm") && d.nkey == 9) { // ctl and status first
    if (index < 2) {
      *child = node_of(slot_of(dir), user_of(dir), index ? STATUS_QID : CTL_QID) | (dir & PERMISSIVE);
      return VX_OK;
    }
    index -= 2; // the entries after them, as the cursor counts them
  }
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
    *child = node_of(slot_of(dir), user_of(dir), vxfs_unpackdir(kv.v).qid_path) | (dir & PERMISSIVE);
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
  if ((st = mutable(dir)) != VX_OK) return st;
  if (!may(dir, &d.d, MAY_W)) return VX_ERR_ACCESS;
  if (is_branch(dir, "adm") && d.nkey == 9 &&
      ((name.len == 3 && !memcmp(nm, "ctl", 3)) || (name.len == 6 && !memcmp(nm, "status", 6))))
    return VX_ERR_EXISTS;
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
  vx_status st = mutable(node);
  if (st == VX_OK) st = file_of(node, &f);
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
  bool owner = !is_none(node) && me == d->uid;
  if (permissive(node)) return true; // %BRANCH: adm's members, without permissions (gefs's permit)
  if ((a->valid & P9_SETATTR_SIZE) && !may(node, d, MAY_W)) return false;
  if ((a->valid & P9_SETATTR_MODE) && !owner && !leads(me, d->gid)) return false;
  if ((a->valid & P9_SETATTR_UID) && a->uid != d->uid && !is_adm(node))
    return false; // owners are adm's to give
  if ((a->valid & P9_SETATTR_GID) && a->gid != d->gid &&
      !((owner && in_group(me, a->gid)) || (leads(me, d->gid) && leads(me, a->gid))))
    return false;
  if ((a->valid & (P9_SETATTR_ATIME_SET | P9_SETATTR_MTIME_SET)) && !owner) return false;
  if ((a->valid & (P9_SETATTR_ATIME | P9_SETATTR_MTIME)) && !owner && !may(node, d, MAY_W)) return false;
  return true;
}

static vx_status fs_setattr([[maybe_unused]] void *ctx, uint64_t node, const p9_setattr *a) {
  vxfs_file f;
  vx_status st = mutable(node);
  if (st == VX_OK) st = file_of(node, &f);
  if (st != VX_OK) return st;
  if (!may_setattr(node, &f.d, a)) return VX_ERR_ACCESS;
  cached *c = (a->valid & P9_SETATTR_SIZE) ? pcache_find(node) : nullptr;
  if (c) { // what its mappings wrote, in first; then the file as it was, for the rest
    writeback(c);
    if ((st = file_of(node, &f)) != VX_OK) return st;
  }
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
  if (st == VX_OK && (a->valid & P9_SETATTR_SIZE)) pcache_truncated(node, a->size);
  return st;
}

// Whether the file qid in slot *ctx is open (or mapped): a rename over it
// keeps it as an orphan, as POSIX does.
static bool open_qid(void *ctx, uint64_t qid) {
  return open_slot(node_of(*(const uint32_t *)ctx, 0, qid), false) != nullptr;
}

static vx_status fs_rename([[maybe_unused]] void *ctx, uint64_t olddir, vx_str oldname, uint64_t newdir,
                           vx_str newname) {
  char from[VXFS_NAMEMAX + 1], to[VXFS_NAMEMAX + 1];
  vxfs_file a, b;
  if (slot_of(olddir) != slot_of(newdir)) return VX_ERR_INVALID; // one branch: one tree
  vx_status st = mutable(olddir);
  if (st == VX_OK) st = name_of(oldname, from);
  if (st == VX_OK) st = name_of(newname, to);
  if (st == VX_OK) st = file_of(olddir, &a);
  if (st == VX_OK) st = file_of(newdir, &b);
  if (st == VX_OK && (!may(olddir, &a.d, MAY_W) || !may(newdir, &b.d, MAY_W))) st = VX_ERR_ACCESS;
  uint32_t slot = slot_of(olddir);
  if (st == VX_OK) st = vxfs_rename(&vol, tree_of(olddir), &a, from, &b, to, now_ns(), open_qid, &slot);
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
  vx_status st = mutable(dir);
  if (st == VX_OK) st = name_of(name, nm);
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

static vx_instant next_writeback = VX_INFINITE; // while files are mapped

static vx_instant tick([[maybe_unused]] void *ctx) {
  vx_instant now = vx_clock_read();
  bool mapped = false;
  for (uint32_t i = 0; i < MAX_CACHED && !mapped; i++) mapped = pcache[i].used;
  if (mapped && now >= next_writeback) writeback_all(), next_writeback = now + COMMIT_EVERY;
  if (!mapped) next_writeback = now + COMMIT_EVERY;
  if (dirty && now >= next_commit) commit();
  vx_instant at = dirty ? next_commit : VX_INFINITE;
  return mapped && next_writeback < at ? next_writeback : at;
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
           .fsync = fs_fsync,
           .map = fs_map,
           .read_ref = fs_read_ref,
           .write_ref = fs_write_ref},
    .name = VX_STR("fsd"),
    .supported = P9_EXT_POSIX | P9_EXT_XATTR | P9_EXT_MAP | P9_EXT_DREF,
    .event = on_event,
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
  // The pager, if the manifest makes fsd one (`pager`): Tmap without it is refused.
  vx_handle authority = vx_spawn_take("pager");
  if (authority) {
    if ((st = vx_port_create(0, &server.port)) != VX_OK) fail("no port", st);
    st = vx_pager_create(authority, server.port, PAGER_KEY, SUPPLY_DEADLINE, &pager);
    if (st == VX_OK) st = vx_vmo_create(4096, 0, &scratch);
    if (st != VX_OK) fail("cannot be a pager", st);
    vx_handle_close(authority);
  }
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
