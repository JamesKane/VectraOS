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
  CHECK(fat_mount(&vol, (fat_dev){&m, image_read}) == VX_OK);
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
  if (fat_mount(v2, (fat_dev){&cut, image_read}) == VX_OK) {
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
  CHECK(fat_mount(&vol, (fat_dev){&m, image_read}) == VX_OK);
  uint8_t *slot = nullptr;
  for (uint32_t i = 0; i < vol.root_entries && !slot; i++) {
    uint8_t *s = m.bytes + (uint64_t)vol.root_start * vol.bps + (uint64_t)i * 32;
    if (s[11] == FAT_LONG_NAME && (s[0] & 0x1f) == 1 && s[1] == 'A' && s[3] == ' ' && s[5] == 'L') slot = s;
  }
  CHECK(slot != nullptr);
  if (!slot) return;
  slot[1] = 0x3d, slot[2] = 0xd8, slot[3] = 0x00, slot[4] = 0xde; // U+1F600
  fat_entry e;
  CHECK(fat_mount(&vol, (fat_dev){&m, image_read}) == VX_OK);
  CHECK(walk("\xf0\x9f\x98\x80Long Directory Name/sub dir/deep.txt", &e));
  slot[3] = ' ', slot[4] = 0; // the high surrogate alone, then the space
  CHECK(fat_mount(&vol, (fat_dev){&m, image_read}) == VX_OK);
  CHECK(walk("\xef\xbf\xbd Long Directory Name", &e)); // U+FFFD
  free(m.bytes);
}

// A chain that loops, and a boot sector that is not FAT.
static void check_damage(void) {
  image m = load("out/host/fat16.img");
  if (!m.len) return;
  CHECK(fat_mount(&vol, (fat_dev){&m, image_read}) == VX_OK);
  fat_entry big;
  CHECK(walk("big.bin", &big));
  // big.bin's second cluster points back at its first.
  uint32_t next = 0;
  CHECK(fat_next(&vol, big.cluster, &next) == VX_OK && next);
  uint64_t at = (uint64_t)vol.fat_start * vol.bps + (uint64_t)next * 2;
  m.bytes[at] = (uint8_t)big.cluster, m.bytes[at + 1] = (uint8_t)(big.cluster >> 8);
  CHECK(fat_mount(&vol, (fat_dev){&m, image_read}) == VX_OK);
  static uint8_t buf[300'000];
  uint32_t n = sizeof buf;
  CHECK(walk("big.bin", &big));
  vx_status st = fat_read(&vol, &big, 0, buf, &n); // round the loop, but never past the file's size
  CHECK(st == VX_OK || st == VX_ERR_IO);
  m.bytes[510] = 0;
  CHECK(fat_mount(&vol, (fat_dev){&m, image_read}) == VX_ERR_INVALID);
  m.bytes[510] = 0x55;
  m.bytes[13] = 3; // sectors per cluster not a power of two
  CHECK(fat_mount(&vol, (fat_dev){&m, image_read}) == VX_ERR_INVALID);
  free(m.bytes);
}

int main(void) {
  check_image("out/host/fat12.img", 12, "SMALL");
  check_image("out/host/fat16.img", 16, "MIDDLE");
  check_image("out/host/fat32.img", 32, "LARGE");
  check_surrogates();
  check_damage();
  return check_result();
}
