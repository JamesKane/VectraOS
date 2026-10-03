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
// A node id is the branch's slot in the high byte and the entry's qid below
// it, so a fid finds its entry by the qid's Kup (lib/vx-fs/file.c) whatever
// it walked through. A file removed while it is open is an orphan until its
// last open fid goes (its data then cleared); a crash leaves orphans that the
// branch's next opening reaps.
//
// Changes are committed every 5 s, and by Tfsync, which is answered once
// its commit is durable (11 §6). Single-threaded: one loop, which waits for
// the disk. M5 step 4a: users, permissions, the adm files and the dump view
// come in 4b; until then every file is uid 0's and no permission is checked.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-driver/blkclient.c"
#include "../../lib/vx-9p/ring_server.c"
#include "../../lib/vx-fs/file.c"

static constexpr vx_duration COMMIT_EVERY = 5'000'000'000;
static constexpr uint32_t CACHE_BLOCKS = 1024; // 16 MiB of tree nodes and data
static constexpr uint32_t MAX_OPEN = 512;      // distinct nodes open at once
static constexpr int SLOT_SHIFT = 56;

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

static uint64_t node_of(uint32_t slot, uint64_t qid) { return (uint64_t)slot << SLOT_SHIFT | qid; }
static uint32_t slot_of(uint64_t node) { return (uint32_t)(node >> SLOT_SHIFT); }
static uint64_t qid_of(uint64_t node) { return node & ((1ull << SLOT_SHIFT) - 1); }

static vxfs_tree *tree_of(uint64_t node) {
  uint32_t s = slot_of(node);
  return s < VXFS_MAXBRANCH && vol.br[s].open ? &vol.br[s].t : nullptr;
}

static vx_status file_of(uint64_t node, vxfs_file *f) {
  vxfs_tree *t = tree_of(node);
  if (!t) return VX_ERR_NOT_FOUND;
  return vxfs_file_by_qid(&vol, t, qid_of(node), f);
}

static vx_status node_in(uint64_t dir, const vxfs_file *f, uint64_t *node) {
  *node = node_of(slot_of(dir), f->d.qid_path);
  return VX_OK;
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

// --- The 9P side ---

static vx_status fs_attach([[maybe_unused]] void *ctx, vx_str aname, uint64_t *root) {
  char name[VXFS_LABELMAX + 1];
  if (!aname.len || aname.len > VXFS_LABELMAX) return VX_ERR_NOT_FOUND;
  memcpy(name, aname.ptr, aname.len);
  name[aname.len] = 0;
  vxfs_branch *br;
  vx_status st = vxfs_branch_open(&vol, name, &br);
  if (st != VX_OK) return st == VX_ERR_ACCESS ? VX_ERR_ACCESS : VX_ERR_NOT_FOUND; // 4b: snapshots, read-only
  uint32_t slot = (uint32_t)(br - vol.br);
  if (!reaped[slot]) { // what a crash left of files removed while open
    uint32_t n = 0;
    if ((st = vxfs_reap_all(&vol, &br->t, &n)) != VX_OK) return st;
    if (n) changed();
    reaped[slot] = true;
  }
  vxfs_file f;
  if ((st = vxfs_root(&vol, &br->t, &f)) != VX_OK) return st;
  return node_in(node_of(slot, 0), &f, root);
}

static vx_status fs_walk([[maybe_unused]] void *ctx, uint64_t dir, vx_str name, uint64_t *child) {
  char nm[VXFS_NAMEMAX + 1];
  if (name.len > VXFS_NAMEMAX) return VX_ERR_RANGE;
  memcpy(nm, name.ptr, name.len);
  nm[name.len] = 0;
  vxfs_file d, f;
  vx_status st = file_of(dir, &d);
  if (st == VX_OK) st = vxfs_walk(&vol, tree_of(dir), &d, nm, &f);
  if (st == VX_ERR_INVALID) st = VX_ERR_NOT_FOUND; // through a file
  return st == VX_OK ? node_in(dir, &f, child) : st;
}

static vx_status fs_parent([[maybe_unused]] void *ctx, uint64_t node, uint64_t *parent) {
  vxfs_file f, p;
  vx_status st = file_of(node, &f);
  if (st == VX_OK && vxfs_is_orphan(&f)) st = VX_ERR_NOT_FOUND;
  if (st == VX_OK) st = vxfs_walk(&vol, tree_of(node), &f, "..", &p);
  return st == VX_OK ? node_in(node, &p, parent) : st;
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
                .uid = decimal(uidbuf[0], d->uid),
                .gid = decimal(uidbuf[1], d->gid),
                .muid = decimal(uidbuf[2], d->muid)};
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
  if (file_of(node, &f) == VX_OK && vxfs_is_orphan(&f)) { // the last of a removed file
    if (vxfs_reap(&vol, tree_of(node), qid_of(node)) == VX_OK) changed();
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
  st = vxfs_write(&vol, tree_of(node), &f, offset, buf, *count, now_ns(), 0);
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
    *child = node_of(slot_of(dir), vxfs_unpackdir(kv.v).qid_path);
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
  st = vxfs_create(&vol, tree_of(dir), &d, nm, (perm & P9_DMDIR ? VXFS_DMDIR : 0) | (perm & 0777), 0, 0,
                   now_ns(), &f);
  if (st != VX_OK) return st;
  changed();
  node_in(dir, &f, out);
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

static vx_status fs_setattr([[maybe_unused]] void *ctx, uint64_t node, const p9_setattr *a) {
  vxfs_file f;
  vx_status st = file_of(node, &f);
  if (st != VX_OK) return st;
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
  if (st == VX_OK) st = vxfs_symlink(&vol, tree_of(dir), &d, nm, tgt, 0, 0, now_ns(), &f);
  if (st != VX_OK) return st;
  changed();
  return node_in(dir, &f, out);
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
  vx_print(VX_STR("fsd: /srv/"));
  vx_print(disk_name);
  vx_print(VX_STR(": commit "));
  vx_print_u64(vol.sb.commit);
  vx_print(VX_STR(", "));
  vx_print_u64(vol.fs.narenas);
  vx_print(VX_STR(" arenas\n"));
  vx_print(VX_STR("fsd: serving /srv/fsd\n"));
  return p9_ring_serve(&server) == VX_OK ? nullptr : "cannot serve";
}
