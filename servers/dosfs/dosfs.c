// dosfs: FAT12, FAT16 and FAT32 over a block session (docs/11 §11), served
// as 9Px on its post: the EFI system partition, USB sticks, SD cards. After
// 9front's dossrv; the format is lib/vx-fat's. Read and write (M5 steps 8a
// and 8b), with the posix extension's renames and setattr; -r, or a disk
// that is read-only, serves it read-only.
//
//   service=dosfs program=/boot/bin/dosfs post=esp console
//   connect=disk0.esp
//   arg=-u
//   arg=vectra
//
// FAT has no owners and no permissions: every file is the -u user's (none
// if not given), 0644, and every directory 0755; an entry marked read-only
// is 0444, and chmod turning the owner's write bit off or on marks it or
// not. Changing owners is refused.
//
// Writes reach the disk as they are made (lib/vx-fat's cache is
// write-through); Tfsync, and a clunk of a file opened for writing, flush
// the disk and FAT32's FSInfo. A node is its entry's place, which a rename
// changes: the old node is remembered as moved, for fids that still hold it.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-9p/ring_server.c"
#include "../../lib/vx-driver/blkclient.c"
#include "../../lib/vx-fat/fat.c"

static vx_blk disk;
static vx_str disk_name, owner = VX_STR("none");
static bool read_only;
static fat_vol vol;
static uint8_t bounce[FAT_MAX_SECTOR];

[[noreturn]] static void fail(const char *what, vx_status st) {
  vx_print(VX_STR("dosfs: FAILED: "));
  vx_print(vx_cstr(what));
  if (st != VX_OK) {
    vx_print(VX_STR(": "));
    vx_print(p9_error_text(st));
  }
  vx_print(VX_STR("\n"));
  vx_exits(what);
}

// The volume's reads: whole disk sectors straight through, the boot
// sector's 512 bytes through a bounce buffer when the disk's are larger.
static bool dev_read(void *ctx, uint64_t off, uint32_t len, uint8_t *buf) {
  vx_blk *b = ctx;
  if (off % b->sector == 0 && len % b->sector == 0) return vx_blk_read(b, off, buf, len) == VX_OK;
  if (b->sector > sizeof bounce || off % b->sector + len > b->sector) return false;
  if (vx_blk_read(b, off / b->sector * b->sector, bounce, b->sector) != VX_OK) return false;
  memcpy(buf, bounce + off % b->sector, len);
  return true;
}

static bool dev_write(void *ctx, uint64_t off, uint32_t len, const uint8_t *buf) {
  vx_blk *b = ctx;
  return off % b->sector == 0 && len % b->sector == 0 && vx_blk_write(b, off, buf, len) == VX_OK;
}

static bool dev_flush(void *ctx) { return vx_blk_flush(ctx) == VX_OK; }

// --- Nodes ---

// Renamed entries' old nodes, and where they went: the last 64.
static struct {
  uint64_t from, to;
} moved[64];
static uint32_t nmoved;

static uint64_t resolve(uint64_t node) {
  for (uint32_t hops = 0; hops < 64; hops++) {
    bool found = false;
    for (uint32_t i = 0; i < 64 && !found; i++)
      if (moved[i].from == node && node) node = moved[i].to, found = true;
    if (!found) break;
  }
  return node;
}

static void forget_moves_to(uint64_t node) { // a new entry where an old one moved from
  for (uint32_t i = 0; i < 64; i++)
    if (moved[i].from == node) moved[i].from = 0;
}

static vx_status get(uint64_t node, fat_entry *e) { return fat_get(&vol, resolve(node), e); }

// The entry reads and writes use, kept: they usually go on with the same file.
static fat_entry current;

static fat_entry *use(uint64_t node, vx_status *st) {
  node = resolve(node);
  *st = VX_OK;
  if (current.node != node && (*st = fat_get(&vol, node, &current)) != VX_OK) {
    current.node = 0;
    return nullptr;
  }
  return &current;
}

// A listing goes index by index: the last one's place is kept, so the next
// index continues from it instead of reading the directory from its start.
static struct {
  uint64_t dir;
  uint32_t next; // the index the iterator is at
  fat_iter it;
} listing;

// After a change to a directory: what was kept of it read again.
static void changed(void) {
  current.node = 0;
  listing.dir = 0;
}

static void stamp(void) { vol.now = vx_wallclock() / 1'000'000'000; }

// --- 9Px ---

static fat_entry scratch; // stat's strings live here until the next call

static vx_status fs_attach(void *ctx, vx_str aname, uint64_t *root) {
  (void)ctx;
  if (aname.len) return VX_ERR_NOT_FOUND;
  *root = FAT_ROOT;
  return VX_OK;
}

static vx_status fs_walk(void *ctx, uint64_t dir, vx_str name, uint64_t *child) {
  (void)ctx;
  fat_entry d, e;
  vx_status st = get(dir, &d);
  if (st == VX_OK) st = fat_lookup(&vol, &d, name.ptr, name.len, &e);
  if (st == VX_OK) *child = e.node;
  return st == VX_ERR_INVALID ? VX_ERR_NOT_FOUND : st;
}

static vx_status fs_parent(void *ctx, uint64_t node, uint64_t *parent) {
  (void)ctx;
  return fat_parent(&vol, resolve(node), parent);
}

static vx_status fs_stat(void *ctx, uint64_t node, p9_stat *out) {
  (void)ctx;
  vx_status st = get(node, &scratch);
  if (st != VX_OK) return st;
  bool dir = scratch.attr & FAT_DIRECTORY;
  uint32_t perm = scratch.attr & FAT_READ_ONLY || read_only ? 0444 : 0644;
  if (dir) perm |= 0111;
  *out = (p9_stat){.qid = {dir ? P9_QTDIR : P9_QTFILE, (uint32_t)scratch.mtime, scratch.node},
                   .mode = dir ? P9_DMDIR | perm : perm,
                   .atime = (uint32_t)(scratch.atime > 0 ? scratch.atime : scratch.mtime),
                   .mtime = (uint32_t)scratch.mtime,
                   .length = scratch.size,
                   .name = vx_cstr(scratch.name),
                   .uid = owner,
                   .gid = owner,
                   .muid = owner};
  return VX_OK;
}

static vx_status fs_open(void *ctx, uint64_t node, uint8_t mode) {
  (void)ctx;
  vx_status st;
  fat_entry *e = use(node, &st);
  if (!e) return st;
  bool writing = (mode & 3) != P9_OREAD || (mode & (P9_OTRUNC | P9_ORCLOSE));
  if (!writing) return VX_OK;
  if (read_only || (e->attr & FAT_READ_ONLY) || ((e->attr & FAT_DIRECTORY) && (mode & 3) != P9_OREAD))
    return VX_ERR_ACCESS;
  if (mode & P9_OTRUNC && !(e->attr & FAT_DIRECTORY) && e->size) {
    stamp();
    return fat_truncate(&vol, e, 0);
  }
  return VX_OK;
}

static vx_status fs_read(void *ctx, uint64_t node, uint64_t offset, uint8_t *buf, uint32_t *count) {
  (void)ctx;
  vx_status st;
  fat_entry *e = use(node, &st);
  if (!e) return st;
  if (e->attr & FAT_DIRECTORY) return VX_ERR_INVALID; // read as a directory, through readdir
  return fat_read(&vol, e, offset, buf, count);
}

// NOLINTNEXTLINE(readability-non-const-parameter): p9_fs's write, whose count a short write lowers
static vx_status fs_write(void *ctx, uint64_t node, uint64_t offset, const uint8_t *buf, uint32_t *count) {
  (void)ctx;
  vx_status st;
  fat_entry *e = use(node, &st);
  if (!e) return st;
  if (read_only) return VX_ERR_ACCESS;
  stamp();
  st = fat_write(&vol, e, offset, buf, *count);
  if (st != VX_OK) current.node = 0; // what it holds may be part way
  return st;
}

static vx_status fs_create(void *ctx, uint64_t dir, vx_str name, uint32_t perm, uint8_t mode,
                           uint64_t *node) {
  (void)ctx, (void)mode;
  if (read_only) return VX_ERR_ACCESS;
  if (perm & ~(P9_DMDIR | 0777)) return VX_ERR_UNSUPPORTED; // no symlinks, devices or the like on FAT
  fat_entry d, e;
  vx_status st = get(dir, &d);
  if (st != VX_OK) return st;
  stamp();
  uint8_t attr = perm & P9_DMDIR ? FAT_DIRECTORY : 0;
  if (!(perm & 0200) && !(perm & P9_DMDIR)) attr |= FAT_READ_ONLY;
  st = fat_create(&vol, &d, name.ptr, name.len, attr, &e);
  changed();
  if (st != VX_OK) return st;
  forget_moves_to(e.node);
  *node = e.node;
  return VX_OK;
}

static vx_status fs_remove(void *ctx, uint64_t node) {
  (void)ctx;
  if (read_only) return VX_ERR_ACCESS;
  fat_entry e;
  vx_status st = get(node, &e);
  if (st == VX_OK) st = fat_remove(&vol, &e);
  changed();
  return st;
}

static vx_status fs_rename(void *ctx, uint64_t olddir, vx_str oldname, uint64_t newdir, vx_str newname) {
  (void)ctx;
  if (read_only) return VX_ERR_ACCESS;
  fat_entry from_dir, to_dir, e, out;
  vx_status st = get(olddir, &from_dir);
  if (st == VX_OK) st = fat_lookup(&vol, &from_dir, oldname.ptr, oldname.len, &e);
  if (st == VX_OK) st = get(newdir, &to_dir);
  if (st != VX_OK) return st;
  stamp();
  st = fat_rename(&vol, &e, &to_dir, newname.ptr, newname.len, &out);
  changed();
  if (st != VX_OK) return st;
  forget_moves_to(out.node);
  if (out.node != e.node) moved[nmoved++ % 64] = (typeof(moved[0])){e.node, out.node};
  return VX_OK;
}

static vx_status fs_setattr(void *ctx, uint64_t node, const p9_setattr *a) {
  (void)ctx;
  if (read_only) return VX_ERR_ACCESS;
  vx_status st;
  fat_entry *e = use(node, &st);
  if (!e) return st;
  if (a->valid & (P9_SETATTR_UID | P9_SETATTR_GID)) return VX_ERR_ACCESS; // FAT has no owners
  stamp();
  if (a->valid & P9_SETATTR_SIZE && (st = fat_truncate(&vol, e, a->size)) != VX_OK) return st;
  if (a->valid & P9_SETATTR_MODE)
    e->attr = (uint8_t)(a->mode & 0200 ? e->attr & ~FAT_READ_ONLY : e->attr | FAT_READ_ONLY);
  if (a->valid & P9_SETATTR_MTIME)
    e->mtime = a->valid & P9_SETATTR_MTIME_SET ? (int64_t)a->mtime_sec : vol.now;
  if (a->valid & P9_SETATTR_ATIME)
    e->atime = a->valid & P9_SETATTR_ATIME_SET ? (int64_t)a->atime_sec : vol.now;
  return fat_put_entry(&vol, e);
}

static vx_status fs_fsync(void *ctx, uint64_t node) {
  (void)ctx, (void)node;
  return fat_flush(&vol);
}

static void fs_clunk(void *ctx, uint64_t node, bool opened) {
  (void)ctx, (void)node;
  if (opened && !read_only) fat_flush(&vol); // cheap: FSInfo if it changed, and the disk's cache
}

static vx_status fs_readdir(void *ctx, uint64_t dir, uint32_t index, uint64_t *child) {
  (void)ctx;
  if (listing.dir != dir || index < listing.next || !listing.it.index) {
    fat_entry d;
    vx_status st = get(dir, &d);
    if (st == VX_OK) st = fat_open_dir(&vol, &d, &listing.it);
    if (st != VX_OK) {
      listing.dir = 0;
      return st;
    }
    listing.dir = dir, listing.next = 0;
  }
  fat_entry e;
  vx_status st = VX_OK;
  while (st == VX_OK && listing.next <= index) {
    st = fat_dir_next(&vol, &listing.it, &e);
    listing.next++;
  }
  if (st != VX_OK) {
    listing.dir = 0;
    return st;
  }
  *child = e.node;
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
           .write = fs_write,
           .create = fs_create,
           .remove = fs_remove,
           .clunk = fs_clunk,
           .setattr = fs_setattr,
           .rename = fs_rename,
           .fsync = fs_fsync},
    .name = VX_STR("dosfs"),
    .supported = P9_EXT_POSIX | P9_EXT_XATTR, // Trenameat and Tsetattr; Tgetattr, for stat
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
  for (uint32_t i = 0; i < vx_spawn.argc; i++) {
    vx_str a = vx_spawn.args[i];
    if (a.len == 2 && memcmp(a.ptr, "-u", 2) == 0 && i + 1 < vx_spawn.argc && vx_spawn.args[i + 1].len)
      owner = vx_spawn.args[++i];
    else if (a.len == 2 && memcmp(a.ptr, "-r", 2) == 0)
      read_only = true;
    else
      fail(VX_USAGE, VX_OK);
  }
  server.listen = vx_spawn_take("listen");
  if (!server.listen) fail("no listen channel (post=)", VX_OK);
  vx_status st = vx_blk_open(&disk, find_disk(), 0);
  if (st != VX_OK) fail("cannot open a session on the disk", st);
  read_only = read_only || (disk.flags & VX_BLOCK_INFO_READONLY);
  fat_dev dev = {.ctx = &disk, .read = dev_read};
  if (!read_only) dev.write = dev_write, dev.flush = dev_flush;
  if ((st = fat_mount(&vol, dev)) != VX_OK) fail("no FAT volume on the disk", st);
  if (vol.bps % disk.sector) fail("the volume's sectors are smaller than the disk's", VX_OK);
  vx_print(VX_STR("dosfs: /srv/"));
  vx_print(disk_name);
  vx_print(VX_STR(": FAT"));
  vx_print_u64(vol.type);
  if (vol.label[0]) {
    vx_print(VX_STR(" \""));
    vx_print(vx_cstr(vol.label));
    vx_print(VX_STR("\""));
  }
  vx_print(VX_STR(", "));
  vx_print_u64(vol.clusters);
  vx_print(VX_STR(" clusters of "));
  vx_print_u64(vol.cluster_bytes);
  vx_print(read_only ? VX_STR(" bytes, read-only\n") : VX_STR(" bytes\n"));
  return p9_ring_serve(&server) == VX_OK ? nullptr : "cannot serve";
}
