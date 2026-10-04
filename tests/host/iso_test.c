// iso_test.c: lib/vx-iso against the ISO ./build's write_iso makes
// (out/host/test.iso, make_test_iso), read each of the three ways: Rock
// Ridge (real names, a name continued in a continuation area, UTF-8 past
// the BMP, case kept and matched exactly, symbolic links, modes, a deep
// directory and its parents, a file of many sectors); Joliet with Rock Ridge
// avoided (UTF-16, names cut at 64 units, no links, case ignored); and ISO
// 9660 alone (lower-cased 8.3-ish names, the ~1 made for a case clash).
// Then damage: a descriptor that is not ISO 9660, a record that overruns
// its sector, a continuation pointing past the volume. ./build check also
// lists the image with 7z, another reader.

#include <stdlib.h>
#include <string.h>

#include "check.h"
#include "../../lib/vx-iso/iso.c"

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

static iso_vol vol;

static bool walk(const char *path, iso_entry *e) {
  iso_root_entry(&vol, e);
  while (*path) {
    while (*path == '/') path++;
    size_t n = strcspn(path, "/");
    if (!n) break;
    iso_entry d = *e;
    if (iso_lookup(&vol, &d, path, n, e) != VX_OK) return false;
    path += n;
  }
  return true;
}

static bool reads(const char *path, const char *want) {
  iso_entry e;
  static uint8_t buf[512];
  uint32_t n = sizeof buf;
  return walk(path, &e) && iso_read(&vol, &e, 0, buf, &n) == VX_OK && n == strlen(want) &&
         memcmp(buf, want, n) == 0;
}

static const char LONG[] =
    "A Long Mixed-Case Name That Goes On And On, Past What One Directory Record Can Hold, So Its Rock "
    "Ridge NM Entry Has To Continue In The Directory's Continuation Area, Which Is The Point Of It.txt";

static int listed(const char *path) {
  iso_entry d, e;
  iso_iter it;
  int n = 0;
  if (!walk(path, &d) || iso_open_dir(&vol, &d, &it) != VX_OK) return -1;
  while (iso_dir_next(&vol, &it, &e) == VX_OK) n++;
  return n;
}

static void check_rock(image *m) {
  CHECK(iso_mount(&vol, (iso_dev){.ctx = m, .read = image_read}, 0) == VX_OK);
  CHECK(vol.kind == ISO_ROCK);
  CHECK(strcmp(vol.label, "VECTRAOS") == 0);
  CHECK(reads("README.txt", "readme\n"));
  CHECK(!reads("readme.txt", "readme\n")); // Rock Ridge names are matched exactly
  CHECK(reads(LONG, "long\n"));
  CHECK(reads("\xc3\x9cn\xc3\xaf"
              "code file.txt",
              "unicode\n"));
  CHECK(reads("\xf0\x9f\x98\x80 smile.txt", "smile\n"));
  CHECK(reads("dir with spaces/same name.txt", "lower\n"));
  CHECK(reads("dir with spaces/Same Name.txt", "upper\n"));
  CHECK(reads("deep/er/still/deeper/file.txt", "deep\n"));
  // The root: README, long, unicode, smile, two links, deep, "dir with
  // spaces", big.bin; boot.catalog and efiboot.img.
  CHECK(listed("") == 11);
  iso_entry e;
  CHECK(walk("link-to-readme", &e) && e.link && strcmp(e.target, "README.txt") == 0);
  CHECK(walk("abs-link", &e) && e.link && strcmp(e.target, "/boot/limine/limine.conf") == 0);
  CHECK(walk("deep/er/up-link", &e) && e.link &&
        strcmp(e.target, "../../dir with spaces/./same name.txt") == 0);
  CHECK(walk("README.txt", &e) && e.mode == 0444 && !e.dir && !e.link);
  CHECK(walk("deep", &e) && e.dir && e.mode == 0555);
  CHECK(e.mtime >= 315'532'800); // SOURCE_DATE_EPOCH's, 1980 or later

  // Many sectors, whole and in pieces.
  iso_entry big;
  CHECK(walk("big.bin", &big) && big.size == 300'000);
  static uint8_t buf[300'100];
  uint32_t n = sizeof buf;
  CHECK(iso_read(&vol, &big, 0, buf, &n) == VX_OK && n == 300'000);
  bool same = true;
  for (size_t i = 0; i < 300'000; i++) same = same && buf[i] == (uint8_t)((i * 7 + i / 251) & 0xff);
  for (uint64_t off = 0; off < 300'000; off += 7919) {
    n = 3001;
    if (iso_read(&vol, &big, off, buf, &n) != VX_OK) same = false;
    for (uint32_t i = 0; i < n; i++)
      same = same && buf[i] == (uint8_t)(((off + i) * 7 + (off + i) / 251) & 0xff);
  }
  CHECK(same);

  // Nodes: found again, and their parents, up to the root.
  iso_entry file, still, er, deep, again;
  CHECK(walk("deep/er/still/deeper/file.txt", &file) && walk("deep/er/still", &still) &&
        walk("deep/er", &er) && walk("deep", &deep));
  CHECK(iso_get(&vol, file.node, &again) == VX_OK && strcmp(again.name, "file.txt") == 0);
  CHECK(iso_get(&vol, still.node, &again) == VX_OK && strcmp(again.name, "still") == 0 && again.dir);
  uint64_t p = 0;
  iso_entry deeper;
  CHECK(walk("deep/er/still/deeper", &deeper));
  CHECK(iso_parent(&vol, file.node, &p) == VX_OK && p == deeper.node);
  CHECK(iso_parent(&vol, deeper.node, &p) == VX_OK && p == still.node);
  CHECK(iso_parent(&vol, er.node, &p) == VX_OK && p == deep.node);
  CHECK(iso_parent(&vol, deep.node, &p) == VX_OK && p == ISO_ROOT);
  CHECK(iso_get(&vol, iso_node(vol.root_lba, 3), &again) == VX_ERR_NOT_FOUND); // not a record's start
}

static void check_joliet(image *m) {
  CHECK(iso_mount(&vol, (iso_dev){.ctx = m, .read = image_read}, ISO_ROCK) == VX_OK);
  CHECK(vol.kind == ISO_JOLIET);
  CHECK(reads("readme.TXT", "readme\n")); // case ignored
  CHECK(reads("\xc3\x9cn\xc3\xaf"
              "code file.txt",
              "unicode\n"));
  CHECK(reads("\xf0\x9f\x98\x80 smile.txt", "smile\n")); // a surrogate pair
  char cut[65];
  memcpy(cut, LONG, 64);
  cut[64] = 0;
  CHECK(reads(cut, "long\n")); // 64 units
  iso_entry e;
  CHECK(!walk("link-to-readme", &e)); // Joliet has no links
  CHECK(reads("deep/er/still/deeper/file.txt", "deep\n"));
  CHECK(listed("") == 9); // the root's, without the two links
}

static void check_plain(image *m) {
  CHECK(iso_mount(&vol, (iso_dev){.ctx = m, .read = image_read}, ISO_ROCK | ISO_JOLIET) == VX_OK);
  CHECK(vol.kind == ISO_PLAIN);
  CHECK(reads("readme.txt", "readme\n"));
  CHECK(reads("README.TXT", "readme\n"));
  CHECK(reads("dir_with_spaces/same_name.txt", "upper\n") ||
        reads("dir_with_spaces/same_name.txt", "lower\n"));
  CHECK(reads("dir_with_spaces/same_name~1.txt", "upper\n") ||
        reads("dir_with_spaces/same_name~1.txt", "lower\n"));
  CHECK(reads("deep/er/still/deeper/file.txt", "deep\n"));
  iso_entry e;
  CHECK(walk("link_to_readme", &e) && !e.link && e.size == 0); // a link without Rock Ridge: an empty file
}

static void check_damage(image *m) {
  image c = {malloc(m->len), m->len};
  memcpy(c.bytes, m->bytes, m->len);
  // Not ISO 9660.
  c.bytes[16 * 2048 + 1] = 'X';
  CHECK(iso_mount(&vol, (iso_dev){.ctx = &c, .read = image_read}, 0) == VX_ERR_INVALID);
  memcpy(c.bytes, m->bytes, m->len);
  // The root's records: the first file record's length made to overrun its sector.
  CHECK(iso_mount(&vol, (iso_dev){.ctx = &c, .read = image_read}, 0) == VX_OK);
  uint8_t *dir = c.bytes + (size_t)vol.root_lba * 2048;
  uint32_t at = dir[0]; // past "."
  at += dir[at];        // past ".."
  dir[at] = 0xff; // 255 bytes from wherever it is: past the sector if near its end, else into the next record
  iso_entry root, e;
  iso_root_entry(&vol, &root);
  iso_iter it;
  iso_open_dir(&vol, &root, &it);
  vx_status st = VX_OK;
  for (int i = 0; i < 100 && st == VX_OK; i++) st = iso_dir_next(&vol, &it, &e); // ends: no loop, no overrun
  CHECK(st == VX_ERR_NOT_FOUND || st == VX_ERR_IO);
  memcpy(c.bytes, m->bytes, m->len);
  // A continuation past the volume: the CE in the long name's record (found
  // by its ISO 9660 name; its NM is all in the continuation area),
  // corrupted before the volume is read.
  CHECK(iso_mount(&vol, (iso_dev){.ctx = &c, .read = image_read}, 0) == VX_OK);
  size_t start = (size_t)vol.root_lba * 2048, end = start + vol.root_len;
  bool found = false;
  for (size_t i = start; i + 16 < end && !found; i++) {
    if (memcmp(c.bytes + i, "A_LONG_MIXED", 12) != 0) continue; // its ISO 9660 name
    for (size_t k = i; k + 28 < i + 255 && !found; k++)
      if (c.bytes[k] == 'C' && c.bytes[k + 1] == 'E' && c.bytes[k + 2] == 28 && c.bytes[k + 3] == 1) {
        c.bytes[k + 4] = c.bytes[k + 5] = c.bytes[k + 6] = 0x7f; // block 0x7f7f7f..: past the end
        found = true;
      }
  }
  CHECK(found);
  CHECK(iso_mount(&vol, (iso_dev){.ctx = &c, .read = image_read}, 0) == VX_OK && vol.kind == ISO_ROCK);
  CHECK(!reads(LONG, "long\n"));
  free(c.bytes);
}

int main(void) {
  image m = load("out/host/test.iso");
  CHECK(m.len > 0);
  if (!m.len) return check_result();
  check_rock(&m);
  check_joliet(&m);
  check_plain(&m);
  check_damage(&m);
  free(m.bytes);
  return check_result();
}
