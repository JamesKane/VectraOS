// isofs: ISO 9660 with Rock Ridge and Joliet over a block session (docs/11
// §11, M5 step 8c), served read-only as 9Px on its post: install media, CD
// images. After 9front's 9660srv; the format is lib/vx-iso's, which reads
// Rock Ridge if the volume has it, else Joliet, else plain ISO 9660; -r and
// -j avoid Rock Ridge and Joliet.
//
//   service=isofs program=/boot/bin/isofs post=cd console
//   connect=disk1
//   arg=-u
//   arg=vectra
//
// Every file is the -u user's (none if not given); its permissions are
// Rock Ridge's, or 0444 (directories 0555). Rock Ridge's symbolic links are
// served with the posix extension's Treadlink.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-9p/ring_server.c"
#include "../../lib/vx-driver/blkclient.c"
#include "../../lib/vx-iso/iso.c"

static vx_blk disk;
static vx_str disk_name, owner = VX_STR("none");
static iso_vol vol;

[[noreturn]] static void fail(const char *what, vx_status st) {
  vx_print(VX_STR("isofs: FAILED: "));
  vx_print(vx_cstr(what));
  if (st != VX_OK) {
    vx_print(VX_STR(": "));
    vx_print(p9_error_text(st));
  }
  vx_print(VX_STR("\n"));
  vx_exits(what);
}

static bool dev_read(void *ctx, uint64_t off, uint32_t len, uint8_t *buf) {
  return vx_blk_read(ctx, off, buf, len) == VX_OK; // 2048-byte sectors: whole disk sectors
}

// --- 9Px ---

static iso_entry scratch; // stat's strings live here until the next call
static iso_entry current; // the entry reads use, kept: they usually go on with the same file

static iso_entry *use(uint64_t node, vx_status *st) {
  *st = VX_OK;
  if (current.node != node && (*st = iso_get(&vol, node, &current)) != VX_OK) {
    current.node = 0;
    return nullptr;
  }
  return &current;
}

static vx_status fs_attach(void *ctx, vx_str aname, uint64_t *root) {
  (void)ctx;
  if (aname.len) return VX_ERR_NOT_FOUND;
  *root = ISO_ROOT;
  return VX_OK;
}

static vx_status fs_walk(void *ctx, uint64_t dir, vx_str name, uint64_t *child) {
  (void)ctx;
  iso_entry d, e;
  vx_status st = iso_get(&vol, dir, &d);
  if (st == VX_OK) st = iso_lookup(&vol, &d, name.ptr, name.len, &e);
  if (st == VX_OK) *child = e.node;
  return st == VX_ERR_INVALID ? VX_ERR_NOT_FOUND : st;
}

static vx_status fs_parent(void *ctx, uint64_t node, uint64_t *parent) {
  (void)ctx;
  return iso_parent(&vol, node, parent);
}

static vx_status fs_stat(void *ctx, uint64_t node, p9_stat *out) {
  (void)ctx;
  vx_status st = iso_get(&vol, node, &scratch);
  if (st != VX_OK) return st;
  uint32_t mode = scratch.mode & 0777;
  if (scratch.dir) mode |= P9_DMDIR;
  if (scratch.link) mode |= P9_DMSYMLINK;
  uint8_t type = scratch.dir ? P9_QTDIR : P9_QTFILE; // a link is P9_DMSYMLINK in its mode, as fsd's are
  *out = (p9_stat){.qid = {type, 0, node},
                   .mode = mode,
                   .atime = (uint32_t)scratch.mtime,
                   .mtime = (uint32_t)scratch.mtime,
                   .length = scratch.dir || scratch.link ? 0 : scratch.size,
                   .name = vx_cstr(scratch.name),
                   .uid = owner,
                   .gid = owner,
                   .muid = owner};
  return VX_OK;
}

static vx_status fs_open(void *ctx, uint64_t node, uint8_t mode) {
  (void)ctx, (void)node;
  return (mode & 3) == P9_OREAD && !(mode & (P9_OTRUNC | P9_ORCLOSE)) ? VX_OK : VX_ERR_ACCESS;
}

static vx_status fs_read(void *ctx, uint64_t node, uint64_t offset, uint8_t *buf, uint32_t *count) {
  (void)ctx;
  vx_status st;
  iso_entry *e = use(node, &st);
  if (!e) return st;
  if (e->dir) return VX_ERR_INVALID; // read as a directory, through readdir
  return iso_read(&vol, e, offset, buf, count);
}

static vx_status fs_readlink(void *ctx, uint64_t node, vx_str *target) {
  (void)ctx;
  vx_status st;
  iso_entry *e = use(node, &st);
  if (!e) return st;
  if (!e->link) return VX_ERR_INVALID;
  *target = vx_cstr(e->target);
  return VX_OK;
}

// A listing goes index by index: the last one's place is kept.
static struct {
  uint64_t dir;
  uint32_t next;
  bool open;
  iso_iter it;
} listing;

static vx_status fs_readdir(void *ctx, uint64_t dir, uint32_t index, uint64_t *child) {
  (void)ctx;
  if (!listing.open || listing.dir != dir || index < listing.next) {
    iso_entry d;
    vx_status st = iso_get(&vol, dir, &d);
    if (st == VX_OK) st = iso_open_dir(&vol, &d, &listing.it);
    if (st != VX_OK) {
      listing.open = false;
      return st;
    }
    listing.dir = dir, listing.next = 0, listing.open = true;
  }
  iso_entry e;
  vx_status st = VX_OK;
  while (st == VX_OK && listing.next <= index) {
    st = iso_dir_next(&vol, &listing.it, &e);
    listing.next++;
  }
  if (st != VX_OK) {
    listing.open = false;
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
           .readlink = fs_readlink},
    .name = VX_STR("isofs"),
    .supported = P9_EXT_POSIX | P9_EXT_XATTR, // Treadlink; Tgetattr, for stat
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
  uint32_t avoid = 0;
  for (uint32_t i = 0; i < vx_spawn.argc; i++) {
    vx_str a = vx_spawn.args[i];
    if (a.len == 2 && memcmp(a.ptr, "-u", 2) == 0 && i + 1 < vx_spawn.argc && vx_spawn.args[i + 1].len)
      owner = vx_spawn.args[++i];
    else if (a.len == 2 && memcmp(a.ptr, "-r", 2) == 0)
      avoid |= ISO_ROCK;
    else if (a.len == 2 && memcmp(a.ptr, "-j", 2) == 0)
      avoid |= ISO_JOLIET;
    else
      fail(VX_USAGE, VX_OK);
  }
  server.listen = vx_spawn_take("listen");
  if (!server.listen) fail("no listen channel (post=)", VX_OK);
  vx_status st = vx_blk_open(&disk, find_disk(), 0);
  if (st != VX_OK) fail("cannot open a session on the disk", st);
  if (ISO_SECTOR % disk.sector) fail("the disk's sectors do not divide 2048", VX_OK);
  if ((st = iso_mount(&vol, (iso_dev){.ctx = &disk, .read = dev_read}, avoid)) != VX_OK)
    fail("no ISO 9660 volume on the disk", st);
  vx_print(VX_STR("isofs: /srv/"));
  vx_print(disk_name);
  vx_print(VX_STR(": ISO 9660"));
  if (vol.kind == ISO_ROCK) vx_print(VX_STR(" with Rock Ridge"));
  if (vol.kind == ISO_JOLIET) vx_print(VX_STR(" with Joliet"));
  if (vol.label[0]) {
    vx_print(VX_STR(" \""));
    vx_print(vx_cstr(vol.label));
    vx_print(VX_STR("\""));
  }
  vx_print(VX_STR(", "));
  vx_print_u64(vol.sectors);
  vx_print(VX_STR(" sectors\n"));
  return p9_ring_serve(&server) == VX_OK ? nullptr : "cannot serve";
}
