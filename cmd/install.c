// install: the system from an install medium onto a disk (docs/06 §8, M5
// step 9c). The medium's objects are the store image (the store.tar module,
// its manifest's storeimage): the release's record (records/*.ndb) and every
// object of its base tree. install
//
// 1. checks the whole tree in the image: each directory, file index and block
//    against its name, as the live system's check of its own medium;
// 2. writes a GPT on the disk: an ESP (FAT32, 512 MiB, or -e MIB) and the
//    system volume (the rest);
// 3. writes slot a on the ESP (06 §7): Limine at the firmware's fallback path,
//    the slot's kernel, bootfs and modules under \EFI\vectra\a, the slot
//    table (\EFI\vectra\slots.ndb) and Limine's configuration made from it
//    (lib/vx-slots): each file with its BLAKE2b hash, which Limine checks;
//    vx.system vx.slot=a, with the live command line's other words;
// 4. makes the system volume (vx-fs): its branches store, cfg, home and adm,
//    the users adm, none and vectra (vectra owning home), and the release's
//    objects and record copied into store, where distd finds them.
//
//   install [-y] [-p] [-e mib]       the disk is the one connect= names; see install(8)
//
// Without -y it only checks the medium and says what it would do: the disk
// is erased only when asked to be. -p: power off when done (through
// /srv/acpi, connect=acpi). No UEFI boot entry is made: Limine at the
// fallback path is what the firmware boots (decided 2026-10-04).

#include "../lib/vx-rt/rt.c"
#include "../lib/vx-rt/spawn.c"
#include "../lib/vx-driver/blkclient.c"
#include "../lib/vx-gpt/gpt.c"
#include "../lib/vx-fat/fat.c"
#include "../lib/vx-fs/file.c"
#include "../lib/vx-store/store.c"
#include "../lib/vx-tar/tar.c"
#include "../lib/vx-acpi/mint.h"
#include "../lib/vx-slots/slots.c"

#ifdef __x86_64__
static const char ARCH[] = "x86_64";
#else
static const char ARCH[] = "aarch64";
#endif

[[noreturn]] static void fail(const char *what, vx_status st) {
  vx_print(VX_STR("install: FAILED: "));
  vx_print(vx_cstr(what));
  if (st != VX_OK) {
    vx_print(VX_STR(": "));
    vx_print(p9_error_text(st));
  }
  vx_print(VX_STR("\n"));
  vx_exits(what);
}

static void say(const char *a, vx_str b) {
  vx_print(VX_STR("install: "));
  vx_print(vx_cstr(a));
  vx_print(b);
  vx_print(VX_STR("\n"));
}

// a then b into out, NUL-terminated, cut to fit.
static void join(char *out, size_t cap, const char *a, const char *b) {
  size_t n = 0;
  for (const char *p = a; *p && n + 1 < cap; p++) out[n++] = *p;
  for (const char *p = b; *p && n + 1 < cap; p++) out[n++] = *p;
  out[n] = 0;
}

// --- The medium ---

static const uint8_t *image;
static size_t image_size;

// An object of the image: nullptr if it has none of that name.
static const uint8_t *object(const vx_hash *h, size_t *len) {
  char path[71];
  vx_store_path(h, path);
  vx_tar_entry e;
  if (vx_tar_find(image, image_size, (vx_str){path, 70}, &e) != VX_OK || e.dir) return nullptr;
  *len = e.size;
  return e.data;
}

static uint64_t objects, file_bytes;

// The tree under dir checked whole: every object present and sound.
// NOLINTNEXTLINE(misc-no-recursion): as deep as the tree
static vx_status check_tree(const vx_hash *dir) {
  size_t len;
  const uint8_t *text = object(dir, &len);
  if (!text) return VX_ERR_NOT_FOUND;
  if (vx_store_dir_check(dir, text, len) != VX_OK) return VX_ERR_IO;
  objects++;
  static char scratch[1 << 16];
  vx_ndb_reader r = {.src = {(const char *)text, len}, .scratch = scratch, .scratch_cap = sizeof scratch};
  vx_ndb_record rec;
  while (vx_ndb_next(&r, &rec) == VX_NDB_RECORD) {
    r.scratch_used = 0;
    vx_store_entry e;
    if (vx_store_dir_entry(&rec, &e) != VX_OK) return VX_ERR_IO;
    if (vx_store_is_link(&e)) continue;
    vx_hash h = e.hash;
    if (vx_store_is_dir(&e)) {
      vx_status st = check_tree(&h);
      if (st != VX_OK) return st;
      continue;
    }
    size_t ilen;
    const uint8_t *idx = object(&h, &ilen);
    uint64_t size, n;
    const uint8_t *hashes;
    if (!idx) return VX_ERR_NOT_FOUND;
    if (vx_store_index_check(&h, idx, ilen, &size, &hashes, &n) != VX_OK || size != e.size) return VX_ERR_IO;
    objects++;
    for (uint64_t i = 0; i < n; i++) {
      vx_hash b;
      memcpy(b.b, hashes + i * VX_STORE_HASH, VX_STORE_HASH);
      size_t blen;
      const uint8_t *data = object(&b, &blen);
      if (!data) return VX_ERR_NOT_FOUND;
      if (vx_store_block_check(hashes, n, size, i, data, blen) != VX_OK) return VX_ERR_IO;
      objects++;
    }
    file_bytes += size;
  }
  return VX_OK;
}

// A file of the tree at path, its bytes into a buffer of its own (mapped
// memory): nullptr if there is none. *len its size.
static void *mem_alloc([[maybe_unused]] void *ctx, size_t n);

static uint8_t *tree_file(const vx_hash *tree, const char *path, size_t *len) {
  vx_store_entry e = {.mode = 040555, .hash = *tree};
  static char scratch[1 << 16];
  while (*path) {
    size_t n = 0;
    while (path[n] && path[n] != '/') n++;
    size_t dl;
    const uint8_t *text = object(&e.hash, &dl);
    if (!text || !vx_store_is_dir(&e) ||
        vx_store_dir_find(text, dl, (vx_str){path, n}, scratch, sizeof scratch, &e) != VX_OK)
      return nullptr;
    path += n + (path[n] == '/');
  }
  size_t ilen;
  const uint8_t *idx = object(&e.hash, &ilen);
  uint64_t size, nb;
  const uint8_t *hashes;
  if (!idx || vx_store_is_dir(&e) || vx_store_index_check(&e.hash, idx, ilen, &size, &hashes, &nb) != VX_OK)
    return nullptr;
  uint8_t *out = mem_alloc(nullptr, size ? size : 1);
  if (!out) return nullptr;
  for (uint64_t i = 0; i < nb; i++) {
    vx_hash b;
    memcpy(b.b, hashes + i * VX_STORE_HASH, VX_STORE_HASH);
    size_t blen;
    const uint8_t *data = object(&b, &blen);
    if (!data) return nullptr;
    memcpy(out + i * VX_STORE_BLOCK, data, blen);
  }
  *len = size;
  return out;
}

// --- Memory, for vx-fs and the files read whole ---

static uint64_t page_round(size_t n) { return (n + 4095) & ~(uint64_t)4095; }

static void *mem_alloc([[maybe_unused]] void *ctx, size_t n) {
  vx_handle vmo;
  uint64_t at = 0, size = page_round(n);
  if (vx_vmo_create(size, 0, &vmo) != VX_OK) return nullptr;
  vx_status st = vx_as_map(vx_self, vmo, 0, size, VX_MAP_WRITE, &at);
  vx_handle_close(vmo);
  return st == VX_OK ? (void *)at : nullptr;
}

static void mem_free([[maybe_unused]] void *ctx, void *p, size_t n) {
  vx_as_unmap(vx_self, (uint64_t)p, page_round(n));
}

// --- The disk: the whole of it, and its partitions as devices ---

static vx_blk disk;

static bool gpt_write(void *ctx, uint64_t lba, uint32_t count, const uint8_t *buf) {
  (void)ctx;
  return vx_blk_write(&disk, lba * disk.sector, buf, (uint64_t)count * disk.sector) == VX_OK;
}

typedef struct part_dev {
  uint64_t base; // bytes
} part_dev;

static part_dev esp, sys;

static bool esp_read(void *ctx, uint64_t off, uint32_t len, uint8_t *buf) {
  return vx_blk_read(&disk, ((part_dev *)ctx)->base + off, buf, len) == VX_OK;
}
static bool esp_write(void *ctx, uint64_t off, uint32_t len, const uint8_t *buf) {
  return vx_blk_write(&disk, ((part_dev *)ctx)->base + off, buf, len) == VX_OK;
}
static bool esp_flush(void *ctx) {
  (void)ctx;
  return vx_blk_flush(&disk) == VX_OK;
}

static vx_status sys_read(void *ctx, uint64_t addr, void *buf) {
  return vx_blk_read(&disk, ((part_dev *)ctx)->base + addr, buf, VXFS_BLKSZ);
}
static vx_status sys_write(void *ctx, uint64_t addr, const void *buf) {
  return vx_blk_write(&disk, ((part_dev *)ctx)->base + addr, buf, VXFS_BLKSZ);
}
static vx_status sys_barrier(void *ctx) {
  (void)ctx;
  return vx_blk_flush(&disk);
}

// --- The ESP ---

static fat_vol fat;

static vx_status fat_path(const char *path, uint8_t attr, fat_entry *out) {
  fat_entry d;
  fat_root_entry(&fat, &d);
  for (;;) {
    size_t n = 0;
    while (path[n] && path[n] != '/') n++;
    bool last = !path[n];
    vx_status st = fat_lookup(&fat, &d, path, n, out);
    if (st == VX_ERR_NOT_FOUND) st = fat_create(&fat, &d, path, n, last ? attr : FAT_DIRECTORY, out);
    if (st != VX_OK || last) return st;
    d = *out;
    path += n + 1;
  }
}

static vx_status fat_put_file(const char *path, const uint8_t *data, size_t len) {
  fat_entry e;
  vx_status st = fat_path(path, 0, &e);
  for (size_t at = 0; st == VX_OK && at < len;) {
    uint32_t n = len - at > (1u << 20) ? 1u << 20 : (uint32_t)(len - at);
    st = fat_write(&fat, &e, at, data + at, n);
    at += n;
  }
  return st;
}

static void hex_into(const uint8_t *b, size_t n, char *out) {
  for (size_t i = 0; i < n; i++)
    out[2 * i] = "0123456789abcdef"[b[i] >> 4], out[2 * i + 1] = "0123456789abcdef"[b[i] & 15];
  out[2 * n] = 0;
}

// A file of the tree onto the ESP; its BLAKE2b-512 hash in hex, for Limine.
static vx_status slot_file(const vx_hash *tree, const char *from, const char *to, char hash[129]) {
  size_t len;
  uint8_t *data = tree_file(tree, from, &len);
  if (!data) return VX_ERR_NOT_FOUND;
  uint8_t h[64];
  crypto_blake2b(h, 64, data, len);
  if (hash) hex_into(h, 64, hash);
  vx_status st = fat_put_file(to, data, len);
  mem_free(nullptr, data, len ? len : 1);
  return st;
}

// Limine's configuration, made from the slot table.
static char conf[4096];
static size_t conf_len;

// --- The system volume ---

static vxfs_vol vol;
static vxfs_branch *store;
static int64_t now;

static vx_status vol_dir(vxfs_file *dir, const char *name, vxfs_file *out) {
  vx_status st = vxfs_walk(&vol, &store->t, dir, name, out);
  if (st == VX_ERR_NOT_FOUND) st = vxfs_create(&vol, &store->t, dir, name, VXFS_DMDIR | 0755, 0, 0, now, out);
  return st;
}

static vx_status vol_file(vxfs_file *dir, const char *name, const uint8_t *data, size_t len) {
  vxfs_file f;
  vx_status st = vxfs_walk(&vol, &store->t, dir, name, &f);
  if (st == VX_OK) return VX_OK; // an object shared by two files: there already
  st = vxfs_create(&vol, &store->t, dir, name, 0444, 0, 0, now, &f);
  if (st == VX_OK && len) st = vxfs_write(&vol, &store->t, &f, 0, data, len, now, 0);
  return st;
}

static uint64_t copied;

// Every object of the image into the store branch, as b2/xx/<hex>.
static vx_status copy_objects(void) {
  vxfs_file root, b2;
  vx_status st = vxfs_root(&vol, &store->t, &root);
  if (st == VX_OK) st = vol_dir(&root, "b2", &b2);
  vx_tar t = vx_tar_open(image, image_size);
  vx_tar_entry e;
  while (st == VX_OK && (st = vx_tar_next(&t, &e)) == VX_OK) {
    if (e.dir || e.path.len != 70 || memcmp(e.path.ptr, "b2/", 3) != 0) continue;
    char sub[3] = {e.path.ptr[3], e.path.ptr[4], 0}, name[65];
    memcpy(name, e.path.ptr + 6, 64);
    name[64] = 0;
    vxfs_file d;
    if ((st = vol_dir(&b2, sub, &d)) == VX_OK) st = vol_file(&d, name, e.data, e.size);
    copied++;
    if (copied % 1024 == 0 && st == VX_OK) st = vxfs_commit(&vol); // the log stays small
  }
  return st == VX_ERR_NOT_FOUND ? VX_OK : st; // the archive's end
}

// The first user (-u; vectra unless told otherwise): the system's, who owns
// home and leads adm, and the console shell's (vx.user, 6d8).
static vx_str first_user = VX_STR("vectra");
// The machine's name (-n; vectra unless told otherwise): vx.host=, which
// sysfs serves as /sys/name (6e1c3).
static vx_str host_name = VX_STR("vectra");

// Whether a name can be a user(6)'s: 1 to 31 bytes, none of its separators,
// and neither of the users the system has already.
static bool user_name_ok(vx_str u) {
  if (!u.len || u.len > 31 || (u.len == 3 && !memcmp(u.ptr, "adm", 3)) ||
      (u.len == 4 && !memcmp(u.ptr, "none", 4)))
    return false;
  for (size_t i = 0; i < u.len; i++)
    if (u.ptr[i] == ':' || u.ptr[i] == ',' || u.ptr[i] == ' ' || u.ptr[i] == '\n' || u.ptr[i] == '=')
      return false;
  return true;
}

// Puts s at buf's n, which the caller has made room for.
static void append(char *buf, size_t *n, vx_str s) {
  for (size_t i = 0; i < s.len; i++) buf[(*n)++] = s.ptr[i];
}

// users(6), as vxfs mkfs makes it: adm (the first user in its group), none,
// the first user.
static vx_status make_users(void) {
  vxfs_branch *br;
  vxfs_file root, f;
  static char text[160];
  vx_str u = first_user;
  size_t n = 0;
  append(text, &n, VX_STR("0:adm:adm:")), append(text, &n, u);
  append(text, &n, VX_STR("\n1:none::\n1000:")), append(text, &n, u);
  append(text, &n, VX_STR(":")), append(text, &n, u), append(text, &n, VX_STR(":\n"));
  vx_status st = vxfs_branch_open(&vol, "adm", &br);
  if (st == VX_OK) st = vxfs_root(&vol, &br->t, &root);
  if (st == VX_OK) st = vxfs_create(&vol, &br->t, &root, "users", 0664, 0, 0, now, &f);
  if (st == VX_OK) st = vxfs_write(&vol, &br->t, &f, 0, text, n, now, 0);
  if (st == VX_OK) st = vxfs_branch_open(&vol, "home", &br);
  vxfs_attr a = {.valid = VXFS_WUID | VXFS_WGID, .uid = 1000, .gid = 1000};
  if (st == VX_OK && (st = vxfs_root(&vol, &br->t, &root)) == VX_OK)
    st = vxfs_setattr(&vol, &br->t, &root, &a, now);
  // tmp, the first user's /tmp on disk (M6 step 6e1c2), as 9front's /usr/$user/tmp.
  if (st == VX_OK) st = vxfs_create(&vol, &br->t, &root, "tmp", VXFS_DMDIR | 0700, 1000, 1000, now, &f);
  return st;
}

// --- Power ---

static void power_off(void) {
  vx_handle c = vx_spawn_take("srv:acpi");
  if (!c) fail("-p, but no connector to /srv/acpi (connect=acpi)", VX_OK);
  vx_msg_header req = {.ordinal = VX_ACPI_POWER_OFF}, rep = {};
  vx_call call = {.wr_bytes = &req, .wr_len = sizeof req, .rd_bytes = &rep, .rd_cap = sizeof rep};
  vx_channel_call(c, &call, vx_clock_read() + 10'000'000'000);
  fail("the machine is still on", VX_OK);
}

// --- Starting ---

static vx_handle find_disk(vx_str *name) {
  for (uint32_t i = 0; i < vx_spawn.handle_count; i++) {
    vx_str n = vx_spawn.handle_names[i];
    if (n.len > 4 && memcmp(n.ptr, "srv:", 4) == 0 && !(n.len == 8 && memcmp(n.ptr, "srv:acpi", 8) == 0) &&
        vx_spawn.handles[i]) {
      *name = (vx_str){n.ptr + 4, n.len - 4};
      vx_handle h = vx_spawn.handles[i];
      vx_spawn.handles[i] = VX_HANDLE_NONE;
      return h;
    }
  }
  fail("no connector to a disk (connect=)", VX_OK);
}

static const char ESP_TYPE[] = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B";
static const char SYSTEM_TYPE[] = "7C6D3E1A-2B4F-4E0A-9C1D-56F2A8B90E35";

const char *vx_main(void) {
  bool yes = false, off = false;
  uint64_t esp_mib = 512;
  for (uint32_t i = 0; i < vx_spawn.argc; i++) {
    vx_str a = vx_spawn.args[i];
    if (a.len == 2 && a.ptr[0] == '-' && a.ptr[1] == 'y') {
      yes = true;
    } else if (a.len == 2 && a.ptr[0] == '-' && a.ptr[1] == 'p') {
      off = true;
    } else if (a.len == 2 && a.ptr[0] == '-' && a.ptr[1] == 'n' && i + 1 < vx_spawn.argc) {
      host_name = vx_spawn.args[++i];
      if (!user_name_ok(host_name)) fail("not a name for the machine", VX_ERR_INVALID); // a word, as a user's
    } else if (a.len == 2 && a.ptr[0] == '-' && a.ptr[1] == 'u' && i + 1 < vx_spawn.argc) {
      first_user = vx_spawn.args[++i];
      if (!user_name_ok(first_user)) fail("not a name for a user (users(6))", VX_ERR_INVALID);
    } else if (a.len == 2 && a.ptr[0] == '-' && a.ptr[1] == 'e' && i + 1 < vx_spawn.argc) {
      vx_str v = vx_spawn.args[++i];
      esp_mib = 0;
      for (size_t k = 0; k < v.len; k++) esp_mib = esp_mib * 10 + (uint64_t)(v.ptr[k] - '0');
    } else {
      fail(VX_USAGE, VX_OK);
    }
  }
  now = vx_wallclock();
  // The medium: the record, and the tree it names for this architecture.
  vx_handle vmo = vx_spawn_take("storeimage");
  vx_ndb_record rec;
  uint64_t size = 0, at = 0;
  if (!vmo || !vx_spawn_record("storeimage", &rec) || !vx_ndb_get_u64(&rec, "size", &size) ||
      vx_as_map(vx_self, vmo, 0, page_round(size), 0, &at) != VX_OK)
    fail("no store image (this is not an install medium)", VX_OK);
  image = (const uint8_t *)at, image_size = size;
  vx_tar t = vx_tar_open(image, image_size);
  vx_tar_entry e;
  vx_str record = {};
  static char rname[64]; // the record's name: e.path is e's own buffer, which the next entry reuses
  while (vx_tar_next(&t, &e) == VX_OK)
    if (e.path.len > 12 && e.path.len - 8 < sizeof rname && memcmp(e.path.ptr, "records/", 8) == 0) {
      record = (vx_str){(const char *)e.data, e.size};
      memcpy(rname, e.path.ptr + 8, e.path.len - 8);
      rname[e.path.len - 8] = 0;
    }
  if (!record.len) fail("no release record on the medium", VX_OK);
  vx_hash tree;
  bool have = false;
  uint64_t seq = 0;
  static char scratch[16384];
  vx_ndb_reader rd = {.src = record, .scratch = scratch, .scratch_cap = sizeof scratch};
  while (vx_ndb_next(&rd, &rec) == VX_NDB_RECORD) {
    rd.scratch_used = 0;
    if (!vx_release_known(&rec)) fail("the release record has a key release(6) does not name", VX_OK);
    if (vx_ndb_has(&rec, "release")) vx_ndb_get_u64(&rec, "release", &seq);
    vx_str set = vx_ndb_get(&rec, "set"), arch = vx_ndb_get(&rec, "arch");
    if (set.len == 4 && memcmp(set.ptr, "base", 4) == 0 && arch.len == sizeof ARCH - 1 &&
        memcmp(arch.ptr, ARCH, arch.len) == 0)
      have = vx_store_parse(vx_ndb_get(&rec, "tree"), &tree);
  }
  if (!have) fail("the record names no base tree for this architecture", VX_OK);
  vx_status st = check_tree(&tree);
  if (st != VX_OK) fail("the medium's tree is not whole and sound", st);
  vx_print(VX_STR("install: release "));
  vx_print_u64(seq);
  vx_print(VX_STR(" on the medium, checked: "));
  vx_print_u64(objects);
  vx_print(VX_STR(" objects, "));
  vx_print_u64(file_bytes >> 20);
  vx_print(VX_STR(" MiB of files\n"));

  // The disk.
  vx_str disk_name;
  if ((st = vx_blk_open(&disk, find_disk(&disk_name), 0)) != VX_OK)
    fail("cannot open a session on the disk", st);
  if (disk.sector != 512) fail("the disk's sectors are not 512 bytes (the ESP's FAT32 needs that)", VX_OK);
  uint64_t first = 2048, esp_sectors = esp_mib << 11, sys_first = first + esp_sectors;
  if (disk.sectors < sys_first + (64ull << 11) + 34)
    fail("the disk is too small: the ESP and 64 MiB at least", VX_OK);
  if (!yes) {
    say("would erase /srv/", disk_name);
    say("(-y to do it)", VX_STR(""));
    return nullptr;
  }
  say("erasing /srv/", disk_name);

  static vx_gpt g;
  g = (vx_gpt){.sector = 512, .sectors = disk.sectors, .count = 2};
  uint8_t seed[64];
  crypto_blake2b_ctx hc;
  crypto_blake2b_init(&hc, 64);
  crypto_blake2b_update(&hc, tree.b, sizeof tree.b);
  crypto_blake2b_update(&hc, (const uint8_t *)&now, sizeof now);
  crypto_blake2b_update(&hc, (const uint8_t *)&disk.sectors, sizeof disk.sectors);
  crypto_blake2b_final(&hc, seed);
  memcpy(g.disk_guid, seed, 16), memcpy(g.parts[0].guid, seed + 16, 16),
      memcpy(g.parts[1].guid, seed + 32, 16);
  for (int i = 0; i < 3; i++) { // version 4 GUIDs
    uint8_t *x = i == 0 ? g.disk_guid : g.parts[i - 1].guid;
    x[7] = (uint8_t)((x[7] & 0x0f) | 0x40), x[8] = (uint8_t)((x[8] & 0x3f) | 0x80);
  }
  vx_gpt_guid(ESP_TYPE, sizeof ESP_TYPE - 1, g.parts[0].type);
  vx_gpt_guid(SYSTEM_TYPE, sizeof SYSTEM_TYPE - 1, g.parts[1].type);
  g.parts[0].first = first, g.parts[0].last = sys_first - 1;
  g.parts[1].first = sys_first, g.parts[1].last = disk.sectors - 34;
  memcpy(g.parts[0].name, "EFI system partition", 21);
  memcpy(g.parts[1].name, "vectra", 7);
  if ((st = vx_gpt_write(&g, gpt_write, nullptr)) != VX_OK) fail("cannot write the partition table", st);

  // The ESP, and slot a in it.
  esp.base = first * 512, sys.base = sys_first * 512;
  fat_dev fd = {.ctx = &esp, .read = esp_read, .write = esp_write, .flush = esp_flush};
  if ((st = fat_format(fd, esp_sectors, first, "VECTRA",
                       (uint32_t)(seed[48] | seed[49] << 8 | seed[50] << 16 | (uint32_t)seed[51] << 24))) !=
      VX_OK)
    fail("cannot format the ESP", st);
  if ((st = fat_mount(&fat, fd)) != VX_OK) fail("cannot mount the new ESP", st);
  fat.now = now / 1'000'000'000;
#ifdef __x86_64__
  static const char loader[] = "BOOTX64.EFI";
#else
  static const char loader[] = "BOOTAA64.EFI";
#endif
  static char kernel_h[129], svcd_h[129], ktest_h[129], bootfs_h[129];
  char from[64], to[96];
  join(from, sizeof from, "boot/limine/", loader);
  join(to, sizeof to, "EFI/BOOT/", loader);
  st = slot_file(&tree, from, to, nullptr); // the firmware's fallback path: what it boots
  static const char *const files[] = {"kernel.elf", "svcd", "ktest", "bootfs.tar"};
  char *hashes[] = {kernel_h, svcd_h, ktest_h, bootfs_h};
  for (int i = 0; st == VX_OK && i < 4; i++) {
    join(from, sizeof from, "boot/vx/", files[i]);
    join(to, sizeof to, "EFI/vectra/a/", files[i]); // slot a's directory
    st = slot_file(&tree, from, to, hashes[i]);
  }
  if (st != VX_OK) fail("cannot write slot a", st);
  // The slot table, slot a booting, and Limine's configuration made from it
  // (lib/vx-slots): the live command line's words but vx.live go on.
  static vx_slots table;
  table = (vx_slots){.boot = 0, .previous = -1};
  vx_slot *sl = &table.slot[0];
  sl->used = true, sl->release = seq;
  vx_store_hex(&tree, sl->tree);
  for (int i = 0; i < VX_SLOT_FILES; i++) memcpy(sl->hash[i], hashes[i], VX_SLOT_HASH + 1);
  vx_str c = vx_spawn.cmdline;
  size_t cl = 0;
  for (size_t i = 0; i < c.len;) {
    size_t n = 0;
    while (i + n < c.len && c.ptr[i + n] != ' ') n++;
    bool dropped =
        (n == 7 && memcmp(c.ptr + i, "vx.live", 7) == 0) ||
        (n > 8 && (memcmp(c.ptr + i, "vx.user=", 8) == 0 || memcmp(c.ptr + i, "vx.host=", 8) == 0));
    if (n && !dropped && cl + n + 2 < sizeof table.cmdline) {
      if (cl) table.cmdline[cl++] = ' ';
      memcpy(table.cmdline + cl, c.ptr + i, n), cl += n;
    }
    i += n + 1;
  }
  // The first user, as plan9.ini's user=: the console shell runs as it (6d8).
  if (cl + 9 + first_user.len + 1 < sizeof table.cmdline) {
    if (cl) table.cmdline[cl++] = ' ';
    append(table.cmdline, &cl, VX_STR("vx.user=")), append(table.cmdline, &cl, first_user);
  }
  if (cl + 9 + host_name.len + 1 < sizeof table.cmdline) { // and the machine's name, as /sys/name (6e1c3)
    table.cmdline[cl++] = ' ';
    append(table.cmdline, &cl, VX_STR("vx.host=")), append(table.cmdline, &cl, host_name);
  }
  static char text[4096];
  vx_ndb_writer w = {.buf = text, .cap = sizeof text};
  if (!vx_slots_print(&table, &w) ||
      (st = fat_put_file("EFI/vectra/slots.ndb", (const uint8_t *)text, w.len)) != VX_OK)
    fail("cannot write the slot table", st);
  conf_len = vx_slots_limine(&table, conf, sizeof conf);
  if (!conf_len) fail("Limine's configuration does not fit", VX_OK);
  if ((st = fat_put_file("boot/limine/limine.conf", (const uint8_t *)conf, conf_len)) != VX_OK ||
      (st = fat_flush(&fat)) != VX_OK)
    fail("cannot write Limine's configuration", st);
  say("slot a written; the ESP is FAT32 \"VECTRA\"", VX_STR(""));

  // The system volume.
  vxfs_dev vd = {.ctx = &sys,
                 .read = sys_read,
                 .write = sys_write,
                 .barrier = sys_barrier,
                 .size = (g.parts[1].last - sys_first + 1) * 512 / VXFS_BLKSZ * VXFS_BLKSZ};
  static const char *const branches[] = {"store", "cfg", "home", "adm"};
  if ((st = vxfs_mkfs(&vol, vd, (vxfs_mem){.alloc = mem_alloc, .free = mem_free}, 1024, 0, branches, 4, 0755,
                      0, 0, now)) != VX_OK)
    fail("cannot make the system volume", st);
  if ((st = make_users()) != VX_OK || (st = vxfs_branch_open(&vol, "store", &store)) != VX_OK)
    fail("cannot make the volume's users", st);
  if ((st = copy_objects()) != VX_OK) fail("cannot copy the objects into the store", st);
  vxfs_file root, records;
  if ((st = vxfs_root(&vol, &store->t, &root)) == VX_OK &&
      (st = vol_dir(&root, "records", &records)) == VX_OK)
    st = vol_file(&records, rname, (const uint8_t *)record.ptr, record.len);
  if (st != VX_OK) fail("cannot write the release's record into the store", st);
  if ((st = vxfs_commit(&vol)) != VX_OK) fail("cannot commit the system volume", st);
  if ((st = vx_blk_flush(&disk)) != VX_OK) fail("cannot flush the disk", st);
  vx_print(VX_STR("install: done: "));
  vx_print_u64(copied);
  vx_print(VX_STR(" objects in the store, release "));
  vx_print_u64(seq);
  vx_print(VX_STR(" in slot a\n"));
  if (off) power_off();
  return nullptr;
}
