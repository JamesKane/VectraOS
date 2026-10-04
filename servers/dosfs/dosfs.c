// dosfs: FAT12, FAT16 and FAT32 over a block session (docs/11 §11), served
// as 9Px on its post: the EFI system partition, USB sticks, SD cards. After
// 9front's dossrv; the format is lib/vx-fat's. Read-only so far (M5 step
// 8a); writing comes with step 8b.
//
//   service=dosfs program=/boot/bin/dosfs post=esp console
//   connect=disk0.esp
//   arg=-u
//   arg=vectra
//
// FAT has no owners and no permissions: every file is the -u user's (none
// if not given), 0444, and every directory 0555; with writing, the owner's
// write bit, unless the entry is marked read-only.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-9p/ring_server.c"
#include "../../lib/vx-driver/blkclient.c"
#include "../../lib/vx-fat/fat.c"

static vx_blk disk;
static vx_str disk_name, owner = VX_STR("none");
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
  vx_status st = fat_get(&vol, dir, &d);
  if (st == VX_OK) st = fat_lookup(&vol, &d, name.ptr, name.len, &e);
  if (st == VX_OK) *child = e.node;
  return st == VX_ERR_INVALID ? VX_ERR_NOT_FOUND : st;
}

static vx_status fs_parent(void *ctx, uint64_t node, uint64_t *parent) {
  (void)ctx;
  return fat_parent(&vol, node, parent);
}

static vx_status fs_stat(void *ctx, uint64_t node, p9_stat *out) {
  (void)ctx;
  vx_status st = fat_get(&vol, node, &scratch);
  if (st != VX_OK) return st;
  bool dir = scratch.attr & FAT_DIRECTORY;
  *out = (p9_stat){.qid = {dir ? P9_QTDIR : P9_QTFILE, 0, node},
                   .mode = dir ? P9_DMDIR | 0555 : 0444,
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
  (void)ctx, (void)node;
  return (mode & 3) == P9_OREAD && !(mode & P9_OTRUNC) ? VX_OK : VX_ERR_ACCESS; // read-only until step 8b
}

// The last file read, kept: a read is usually the next part of the same file.
static fat_entry reading;

static vx_status fs_read(void *ctx, uint64_t node, uint64_t offset, uint8_t *buf, uint32_t *count) {
  (void)ctx;
  if (reading.node != node) {
    vx_status st = fat_get(&vol, node, &reading);
    if (st != VX_OK) {
      reading.node = 0;
      return st;
    }
  }
  if (reading.attr & FAT_DIRECTORY) return VX_ERR_INVALID; // read as a directory, through readdir
  return fat_read(&vol, &reading, offset, buf, count);
}

// A listing goes index by index: the last one's place is kept, so the next
// index continues from it instead of reading the directory from its start.
static struct {
  uint64_t dir;
  uint32_t next; // the index the iterator is at
  fat_iter it;
} listing;

static vx_status fs_readdir(void *ctx, uint64_t dir, uint32_t index, uint64_t *child) {
  (void)ctx;
  if (listing.dir != dir || index < listing.next || !listing.it.index) {
    fat_entry d;
    vx_status st = fat_get(&vol, dir, &d);
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
           .readdir = fs_readdir},
    .name = VX_STR("dosfs"),
    .supported = P9_EXT_XATTR, // Tgetattr, for stat
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
    else
      fail("usage: dosfs [-u user]", VX_OK);
  }
  server.listen = vx_spawn_take("listen");
  if (!server.listen) fail("no listen channel (post=)", VX_OK);
  vx_status st = vx_blk_open(&disk, find_disk(), 0);
  if (st != VX_OK) fail("cannot open a session on the disk", st);
  if ((st = fat_mount(&vol, (fat_dev){&disk, dev_read})) != VX_OK) fail("no FAT volume on the disk", st);
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
  vx_print(VX_STR(" bytes, read-only\n"));
  return p9_ring_serve(&server) == VX_OK ? nullptr : "cannot serve";
}
