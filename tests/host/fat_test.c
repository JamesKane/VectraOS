// fat_test.c: lib/vx-fat against FAT12, FAT16 and FAT32 images that mtools
// made (./build's make_fat_fixtures, out/host/fat*.img), so the format is
// checked against another implementation's: the type and label; short and
// long names, UTF-8 (past the BMP patched in), case-insensitive lookup by long name and
// by 8.3 alias; a deleted entry not seen; a file of many clusters read
// whole and in pieces; a directory spanning clusters; nodes found again and
// their parents; a known time. Then damage: a truncated device, a FAT loop,
// a boot sector that is not FAT. (A loop is bounded by the file's size and
// the volume's cluster count, not found: that wants a visited set.)

#include <stdlib.h>
#include <string.h>

#include "check.h"
#include "../../lib/vx-fat/fat.c"

typedef struct image {
  uint8_t *bytes;
  size_t len;
} image;

static bool image_read(void *ctx, uint64_t off, uint32_t len, uint8_t *buf) {
  const image *m = ctx;
  if (off > m->len || len > m->len - off) return false;
  memcpy(buf, m->bytes + off, len);
  return true;
}

static bool image_write(void *ctx, uint64_t off, uint32_t len, const uint8_t *buf) {
  image *m = ctx;
  if (off > m->len || len > m->len - off) return false;
  memcpy(m->bytes + off, buf, len);
  return true;
}

static int writes_left = -1; // >= 0: the device fails once this many more writes are done

static bool image_write_failing(void *ctx, uint64_t off, uint32_t len, const uint8_t *buf) {
  if (writes_left == 0) return false;
  if (writes_left > 0) writes_left--;
  return image_write(ctx, off, len, buf);
}

static image load(const char *path) {
  image m = {};
  FILE *f = fopen(path, "rb");
  if (!f) return m;
  fseek(f, 0, SEEK_END);
  m.len = (size_t)ftell(f);
  fseek(f, 0, SEEK_SET);
  m.bytes = malloc(m.len);
  if (fread(m.bytes, 1, m.len, f) != m.len) m.len = 0;
  fclose(f);
  return m;
}

static fat_vol vol;

static bool walk(const char *path, fat_entry *e) {
  fat_root_entry(&vol, e);
  while (*path) {
    while (*path == '/') path++;
    size_t n = strcspn(path, "/");
    if (!n) break;
    fat_entry d = *e;
    if (fat_lookup(&vol, &d, path, n, e) != VX_OK) return false;
    path += n;
  }
  return true;
}

static bool reads(const char *path, const char *want) {
  fat_entry e;
  static uint8_t buf[512];
  uint32_t n = sizeof buf;
  return walk(path, &e) && fat_read(&vol, &e, 0, buf, &n) == VX_OK && n == strlen(want) &&
         memcmp(buf, want, n) == 0;
}

static uint8_t big_byte(size_t i) { return (uint8_t)((i * 7 + i / 251) & 0xff); }

static void check_image(const char *path, uint32_t type, const char *label) {
  image m = load(path);
  CHECK(m.len > 0);
  if (!m.len) return;
  CHECK(fat_mount(&vol, (fat_dev){.ctx = &m, .read = image_read}) == VX_OK);
  CHECK(vol.type == type);
  CHECK(strcmp(vol.label, label) == 0);

  // Names.
  CHECK(reads("SHORT.TXT", "hello\n"));
  CHECK(reads("short.txt", "hello\n")); // FAT ignores case
  CHECK(reads("lower.txt", "lower\n"));
  CHECK(reads("A Long Directory Name/\xc3\x9cn\xc3\xaf"
              "code file name with spaces.txt",
              "unicode\n"));
  CHECK(reads("a long directory name/sub dir/deep.txt", "deep\n"));
  CHECK(reads("ALONGD~1/sub dir/DEEP.TXT", "deep\n")); // by the 8.3 alias
  fat_entry e;
  CHECK(!walk("gone.txt", &e)); // deleted
  CHECK(!walk("SHORT.TXT/x", &e));
  CHECK(!walk("nothing", &e));

  // The root's listing: what mcopy put there, and no more.
  fat_entry root, d;
  fat_root_entry(&vol, &root);
  fat_iter it;
  CHECK(fat_open_dir(&vol, &root, &it) == VX_OK);
  int count = 0;
  bool saw_long = false, saw_lower = false;
  while (fat_dir_next(&vol, &it, &d) == VX_OK) {
    count++;
    saw_long = saw_long || strcmp(d.name, "A Long Directory Name") == 0;
    saw_lower = saw_lower || strcmp(d.name, "lower.txt") == 0;
  }
  CHECK(count == 5); // SHORT.TXT lower.txt "A Long Directory Name" big.bin many
  CHECK(saw_long && saw_lower);

  // A directory of 100 entries, more than one cluster's on FAT16 and FAT32.
  fat_entry many;
  CHECK(walk("many", &many) && (many.attr & FAT_DIRECTORY));
  CHECK(fat_open_dir(&vol, &many, &it) == VX_OK);
  count = 0;
  while (fat_dir_next(&vol, &it, &d) == VX_OK) count++;
  CHECK(count == 100);
  CHECK(reads("many/f099.txt", "f099\n"));

  // A file of many clusters: whole, and in odd pieces across clusters.
  fat_entry big;
  CHECK(walk("big.bin", &big) && big.size == 300'000);
  static uint8_t buf[300'000 + 100];
  uint32_t n = sizeof buf;
  CHECK(fat_read(&vol, &big, 0, buf, &n) == VX_OK && n == 300'000);
  bool same = true;
  for (size_t i = 0; i < 300'000; i++) same = same && buf[i] == big_byte(i);
  CHECK(same);
  same = true;
  for (uint64_t off = 0; off < 300'000; off += 7919) {
    n = 3001;
    if (fat_read(&vol, &big, off, buf, &n) != VX_OK) same = false;
    for (uint32_t i = 0; i < n; i++) same = same && buf[i] == big_byte(off + i);
  }
  CHECK(same);
  n = 10;
  CHECK(fat_read(&vol, &big, 300'000, buf, &n) == VX_OK && n == 0);

  // Nodes: found again by node, and their parents.
  fat_entry deep, again, sub, top;
  CHECK(walk("A Long Directory Name/sub dir/deep.txt", &deep));
  CHECK(fat_get(&vol, deep.node, &again) == VX_OK && strcmp(again.name, "deep.txt") == 0);
  CHECK(walk("A Long Directory Name/sub dir", &sub) && walk("A Long Directory Name", &top));
  uint64_t p = 0;
  CHECK(fat_parent(&vol, deep.node, &p) == VX_OK && p == sub.node);
  CHECK(fat_parent(&vol, sub.node, &p) == VX_OK && p == top.node);
  CHECK(fat_parent(&vol, top.node, &p) == VX_OK && p == FAT_ROOT);
  CHECK(fat_get(&vol, top.node, &again) == VX_OK && strcmp(again.name, "A Long Directory Name") == 0);
  CHECK(fat_get(&vol, FAT_ROOT, &again) == VX_OK && (again.attr & FAT_DIRECTORY));

  // A known time.
  fat_entry s;
  CHECK(walk("SHORT.TXT", &s) && s.mtime == 981'173'106); // 2001-02-03 04:05:06

  // A device cut short: reads past it fail as IO, not garbage.
  image cut = {m.bytes, m.len / 2};
  fat_vol *v2 = malloc(sizeof *v2);
  if (fat_mount(v2, (fat_dev){.ctx = &cut, .read = image_read}) == VX_OK) {
    fat_entry b2 = {};
    fat_root_entry(v2, &root);
    if (fat_lookup(v2, &root, "big.bin", 7, &b2) == VX_OK) {
      n = sizeof buf;
      vx_status st = fat_read(v2, &b2, 0, buf, &n);
      CHECK(st == VX_OK || st == VX_ERR_IO);
    }
  }
  free(v2);
  free(m.bytes);
}

// Names past the BMP, which mtools cannot write: "A Long Directory Name"'s
// first long-name slot patched to start with U+1F600 (a surrogate pair in
// place of "A "), then with a lone high surrogate.
static void check_surrogates(void) {
  image m = load("out/host/fat16.img");
  if (!m.len) return;
  CHECK(fat_mount(&vol, (fat_dev){.ctx = &m, .read = image_read}) == VX_OK);
  uint8_t *slot = nullptr;
  for (uint32_t i = 0; i < vol.root_entries && !slot; i++) {
    uint8_t *s = m.bytes + (uint64_t)vol.root_start * vol.bps + (uint64_t)i * 32;
    if (s[11] == FAT_LONG_NAME && (s[0] & 0x1f) == 1 && s[1] == 'A' && s[3] == ' ' && s[5] == 'L') slot = s;
  }
  CHECK(slot != nullptr);
  if (!slot) return;
  slot[1] = 0x3d, slot[2] = 0xd8, slot[3] = 0x00, slot[4] = 0xde; // U+1F600
  fat_entry e;
  CHECK(fat_mount(&vol, (fat_dev){.ctx = &m, .read = image_read}) == VX_OK);
  CHECK(walk("\xf0\x9f\x98\x80Long Directory Name/sub dir/deep.txt", &e));
  slot[3] = ' ', slot[4] = 0; // the high surrogate alone, then the space
  CHECK(fat_mount(&vol, (fat_dev){.ctx = &m, .read = image_read}) == VX_OK);
  CHECK(walk("\xef\xbf\xbd Long Directory Name", &e)); // U+FFFD
  free(m.bytes);
}

// A chain that loops, and a boot sector that is not FAT.
static void check_damage(void) {
  image m = load("out/host/fat16.img");
  if (!m.len) return;
  CHECK(fat_mount(&vol, (fat_dev){.ctx = &m, .read = image_read}) == VX_OK);
  fat_entry big;
  CHECK(walk("big.bin", &big));
  // big.bin's second cluster points back at its first.
  uint32_t next = 0;
  CHECK(fat_next(&vol, big.cluster, &next) == VX_OK && next);
  uint64_t at = (uint64_t)vol.fat_start * vol.bps + (uint64_t)next * 2;
  m.bytes[at] = (uint8_t)big.cluster, m.bytes[at + 1] = (uint8_t)(big.cluster >> 8);
  CHECK(fat_mount(&vol, (fat_dev){.ctx = &m, .read = image_read}) == VX_OK);
  static uint8_t buf[300'000];
  uint32_t n = sizeof buf;
  CHECK(walk("big.bin", &big));
  vx_status st = fat_read(&vol, &big, 0, buf, &n); // round the loop, but never past the file's size
  CHECK(st == VX_OK || st == VX_ERR_IO);
  m.bytes[510] = 0;
  CHECK(fat_mount(&vol, (fat_dev){.ctx = &m, .read = image_read}) == VX_ERR_INVALID);
  m.bytes[510] = 0x55;
  m.bytes[13] = 3; // sectors per cluster not a power of two
  CHECK(fat_mount(&vol, (fat_dev){.ctx = &m, .read = image_read}) == VX_ERR_INVALID);
  free(m.bytes);
}

// --- Writing (step 8b) ---

static fat_dev writable(image *m) {
  return (fat_dev){.ctx = m, .read = image_read, .write = image_write_failing};
}

static bool make(const char *path, uint8_t attr, fat_entry *out) {
  const char *slash = strrchr(path, '/');
  fat_entry dir;
  if (slash) {
    char parent[512];
    memcpy(parent, path, (size_t)(slash - path));
    parent[slash - path] = 0;
    if (!walk(parent, &dir)) return false;
  } else {
    fat_root_entry(&vol, &dir);
  }
  const char *name = slash ? slash + 1 : path;
  return fat_create(&vol, &dir, name, strlen(name), attr, out) == VX_OK;
}

static bool put(const char *path, uint64_t off, const void *buf, uint32_t n) {
  fat_entry e;
  return walk(path, &e) && fat_write(&vol, &e, off, buf, n) == VX_OK;
}

static uint32_t free_clusters(void) {
  uint32_t n = 0;
  for (uint32_t c = 2; c <= vol.clusters + 1; c++) {
    uint32_t e = 1;
    fat_raw(&vol, c, &e);
    n += e == 0;
  }
  return n;
}

static void check_writes(const char *path, const char *out) {
  image m = load(path);
  if (!m.len) return;
  CHECK(fat_mount(&vol, writable(&m)) == VX_OK);
  vol.now = 1'893'553'445; // 2030-01-02 03:04:05
  uint32_t free_before = free_clusters();
  fat_entry e, d;

  // New files: an 8.3 name, a lower-case one (no long name: NT's flags), a
  // long one, one past the BMP, and a directory with a file in it.
  CHECK(make("NEW.TXT", 0, &e) && strcmp(e.name, "NEW.TXT") == 0 && strcmp(e.alias, "NEW.TXT") == 0);
  CHECK(make("small.txt", 0, &e) && strcmp(e.name, "small.txt") == 0 && strcmp(e.alias, "SMALL.TXT") == 0);
  CHECK(make("A new file with a long name.text", 0, &e) && strcmp(e.alias, "ANEWFI~1.TEX") == 0);
  CHECK(make("A new file with a long name.texts", 0, &e) && strcmp(e.alias, "ANEWFI~2.TEX") == 0);
  CHECK(make("\xf0\x9f\x98\x80 new", 0, &e) && strcmp(e.name, "\xf0\x9f\x98\x80 new") == 0);
  CHECK(make("New Directory", FAT_DIRECTORY, &d) && (d.attr & FAT_DIRECTORY) && d.cluster);
  CHECK(make("New Directory/inside.txt", 0, &e));
  CHECK(!make("new.txt", 0, &e)); // taken, in another case
  CHECK(!make("bad:name", 0, &e) && !make("trailing.", 0, &e) && !make("..", 0, &e));
  CHECK(e.mtime == 1'893'553'444); // FAT keeps even seconds

  // Writing: a little, a lot (many clusters), at an offset past the end
  // (zeros between), appended to in pieces.
  CHECK(put("NEW.TXT", 0, "new\n", 4));
  static uint8_t big[200'000], back[200'100];
  for (size_t i = 0; i < sizeof big; i++) big[i] = (uint8_t)(i * 13 + i / 509);
  CHECK(put("A new file with a long name.text", 0, big, sizeof big));
  CHECK(put("small.txt", 10'000, "end", 3));
  for (uint32_t off = 0; off < 30'000; off += 1000)
    CHECK(put("New Directory/inside.txt", off, big + off, 1000));

  // Remount: everything is on the device.
  CHECK(fat_mount(&vol, writable(&m)) == VX_OK);
  CHECK(reads("new.txt", "new\n"));
  uint32_t n = sizeof back;
  CHECK(walk("a new file with a long name.text", &e) && e.size == sizeof big);
  CHECK(fat_read(&vol, &e, 0, back, &n) == VX_OK && n == sizeof big && memcmp(back, big, sizeof big) == 0);
  n = sizeof back;
  CHECK(walk("small.txt", &e) && e.size == 10'003 && fat_read(&vol, &e, 0, back, &n) == VX_OK && n == 10'003);
  bool zeros = true;
  for (uint32_t i = 0; i < 10'000; i++) zeros = zeros && back[i] == 0;
  CHECK(zeros && memcmp(back + 10'000, "end", 3) == 0);
  n = sizeof back;
  CHECK(walk("New Directory/inside.txt", &e) && fat_read(&vol, &e, 0, back, &n) == VX_OK && n == 30'000 &&
        memcmp(back, big, 30'000) == 0);
  CHECK(walk("SHORT.TXT", &e) && e.mtime == 981'173'106); // untouched
  vol.now = 1'893'553'445;

  // Truncating: shorter, to nothing, longer.
  CHECK(walk("a new file with a long name.text", &e) && fat_truncate(&vol, &e, 5000) == VX_OK);
  n = sizeof back;
  CHECK(walk("a new file with a long name.text", &e) && e.size == 5000 &&
        fat_read(&vol, &e, 0, back, &n) == VX_OK && n == 5000 && memcmp(back, big, 5000) == 0);
  CHECK(fat_truncate(&vol, &e, 0) == VX_OK && e.cluster == 0);
  CHECK(fat_truncate(&vol, &e, 3) == VX_OK);
  n = sizeof back;
  CHECK(walk("a new file with a long name.text", &e) && e.size == 3 &&
        fat_read(&vol, &e, 0, back, &n) == VX_OK && n == 3 && !back[0] && !back[1] && !back[2]);

  // Renaming: in place to another case, to another directory, over a file;
  // a directory, whose ".." then names its new parent.
  CHECK(walk("NEW.TXT", &e) && walk("", &d));
  fat_entry moved;
  CHECK(fat_rename(&vol, &e, &d, "New.txt", 7, &moved) == VX_OK && strcmp(moved.name, "New.txt") == 0);
  CHECK(reads("New.txt", "new\n"));
  CHECK(walk("New.txt", &e) && walk("New Directory", &d));
  CHECK(fat_rename(&vol, &e, &d, "moved here.txt", 14, &moved) == VX_OK && !walk("New.txt", &e));
  CHECK(reads("New Directory/moved here.txt", "new\n"));
  CHECK(walk("small.txt", &e) && walk("New Directory", &d));
  CHECK(fat_rename(&vol, &e, &d, "inside.txt", 10, &moved) == VX_OK); // replaces it
  CHECK(walk("New Directory/inside.txt", &e) && e.size == 10'003);
  CHECK(walk("New Directory", &e) && walk("A Long Directory Name", &d));
  CHECK(fat_rename(&vol, &e, &d, "Moved Directory", 15, &moved) == VX_OK);
  uint64_t parent = 0;
  CHECK(walk("A Long Directory Name/Moved Directory/moved here.txt", &e) &&
        fat_parent(&vol, e.node, &parent) == VX_OK && parent == moved.node);
  CHECK(fat_parent(&vol, moved.node, &parent) == VX_OK && walk("A Long Directory Name", &d) &&
        parent == d.node);
  CHECK(walk("A Long Directory Name", &e) && walk("A Long Directory Name/Moved Directory", &d) &&
        fat_rename(&vol, &e, &d, "loop", 4, &moved) == VX_ERR_INVALID); // into itself

  // Removing: a file, a directory only when empty.
  CHECK(walk("A Long Directory Name/Moved Directory", &d) && fat_remove(&vol, &d) == VX_ERR_EXISTS);
  CHECK(walk("A Long Directory Name/Moved Directory/moved here.txt", &e) && fat_remove(&vol, &e) == VX_OK);
  CHECK(walk("A Long Directory Name/Moved Directory/inside.txt", &e) && fat_remove(&vol, &e) == VX_OK);
  CHECK(walk("A Long Directory Name/Moved Directory", &d) && fat_remove(&vol, &d) == VX_OK);
  CHECK(!walk("A Long Directory Name/Moved Directory", &d));

  // A directory grown past a cluster by many entries.
  CHECK(make("grown", FAT_DIRECTORY, &d));
  bool all = true;
  for (int i = 0; i < 300; i++) {
    char name[40];
    snprintf(name, sizeof name, "grown/a rather long file name %03d", i);
    all = all && make(name, 0, &e);
  }
  CHECK(all && reads("grown/A RATHER LONG FILE NAME 299", ""));

  // The volume full: NO_SPACE, and what was written before it stays.
  CHECK(make("filler", 0, &e));
  static uint8_t chunk[65536];
  vx_status st = VX_OK;
  for (uint64_t off = 0; st == VX_OK && off < 64ull << 20; off += sizeof chunk)
    st = fat_write(&vol, &e, off, chunk, sizeof chunk);
  CHECK(st == VX_ERR_NO_SPACE);
  CHECK(walk("filler", &e) && e.size > 0 && e.size % sizeof chunk == 0);
  CHECK(fat_remove(&vol, &e) == VX_OK);
  CHECK(fat_flush(&vol) == VX_OK);
  CHECK(free_clusters() == vol.free_count);
  CHECK(free_clusters() < free_before); // what is left: the new files and directories

  FILE *f = fopen(out, "wb"); // for ./build check's fsck.fat -n
  if (f) {
    fwrite(m.bytes, 1, m.len, f);
    fclose(f);
  }
  // A device that fails part way through a create: an error, not a crash.
  // (It leaves orphaned long-name slots, which fsck.fat removes: so after the
  // image is saved.)
  writes_left = 3;
  CHECK(!make("failing with a long name.txt", 0, &e));
  writes_left = -1;

  free(m.bytes);
}

// fat_format's FAT32, as install makes the ESP: mounted, written to as
// install writes it (directories, a file of many clusters), read back, and
// saved for ./build check's fsck.fat -n; one too small refused.
static void check_format(void) {
  image m = {.len = (size_t)64 << 20};
  m.bytes = calloc(1, m.len);
  fat_dev dev = {.ctx = &m, .read = image_read, .write = image_write};
  CHECK(fat_format(dev, m.len / 512, 2048, "VECTRA", 0x1234'5678) == VX_OK);
  CHECK(fat_mount(&vol, dev) == VX_OK && vol.type == 32 && strcmp(vol.label, "VECTRA") == 0);
  vol.now = 1'893'553'445;
  fat_entry e, d;
  CHECK(make("EFI", FAT_DIRECTORY, &d) && make("EFI/BOOT", FAT_DIRECTORY, &d) &&
        make("EFI/vectra", FAT_DIRECTORY, &d));
  CHECK(make("EFI/vectra/a", FAT_DIRECTORY, &d) && make("EFI/vectra/a/kernel.elf", 0, &e));
  static uint8_t big[300'000], back[300'000];
  for (size_t i = 0; i < sizeof big; i++) big[i] = (uint8_t)(i * 3 + i / 1021);
  CHECK(put("EFI/vectra/a/kernel.elf", 0, big, sizeof big));
  CHECK(fat_flush(&vol) == VX_OK);
  CHECK(fat_mount(&vol, dev) == VX_OK);
  uint32_t n = sizeof back;
  CHECK(walk("EFI/vectra/a/kernel.elf", &e) && fat_read(&vol, &e, 0, back, &n) == VX_OK && n == sizeof big &&
        memcmp(back, big, n) == 0);
  FILE *f = fopen("out/host/fat32-formatted.img", "wb");
  if (f) {
    fwrite(m.bytes, 1, m.len, f);
    fclose(f);
  }
  CHECK(fat_format(dev, 60'000, 0, "SMALL", 1) == VX_ERR_INVALID); // under 65525 clusters
  free(m.bytes);
}

int main(void) {
  check_format();
  check_image("out/host/fat12.img", 12, "SMALL");
  check_image("out/host/fat16.img", 16, "MIDDLE");
  check_image("out/host/fat32.img", 32, "LARGE");
  check_surrogates();
  check_writes("out/host/fat12.img", "out/host/fat12-written.img");
  check_writes("out/host/fat16.img", "out/host/fat16-written.img");
  check_writes("out/host/fat32.img", "out/host/fat32-written.img");
  check_damage();
  return check_result();
}
