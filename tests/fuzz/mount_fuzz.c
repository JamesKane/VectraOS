// mount_fuzz.c: hostile volumes, mounted and walked whole (M6 step 6d10),
// beside vxfs_fuzz's single blocks. An input is a format and a list of byte
// edits to a real image of it: vx-fs made by vxfs_mkfs and the file layer,
// FAT32 by fat_format and vx-fat's writer, FAT12 and FAT16 as mtools made
// them and ISO 9660 with Rock Ridge and Joliet as ./build's write_iso made it
// (out/host, which ./build check's host tests make before the fuzzers). The
// edited image is mounted, every directory listed and every file read through
// the file layer (bounded: a loop in a damaged volume must end), a file made
// and written where the format is writable, and vx-fs's checker run. Nothing
// may fault, and the image is put back as it was for the next input.
//
// An edit is two bytes choosing one of the image's 512-byte chunks that are
// not all zero (where its structures and data are), two bytes an offset in
// it, a byte n, and n % 16 + 1 bytes to write there.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../../lib/vx-fat/fat.c"
#include "../../lib/vx-fs/check.c"
#include "../../lib/vx-fs/file.c"
#include "../../lib/vx-iso/iso.c"

// --- Images, edited and put back ---

typedef struct image {
  uint8_t *bytes;
  size_t len;
  uint32_t *hot; // the chunks not all zero
  uint32_t nhot;
} image;

// What was there before an edit or a write, to put back.
typedef struct undo {
  size_t off, len;
  uint8_t *was;
} undo;

static undo *undos;
static uint32_t nundo, capundo;

static void save(image *m, size_t off, size_t len) {
  if (nundo == capundo) {
    capundo = capundo ? capundo * 2 : 256;
    undo *more = realloc(undos, capundo * sizeof *undos);
    if (!more) abort();
    undos = more;
  }
  uint8_t *was = malloc(len);
  if (!was) abort();
  memcpy(was, m->bytes + off, len);
  undos[nundo++] = (undo){off, len, was};
}

static void put_back(image *m) {
  while (nundo) {
    undo *u = &undos[--nundo];
    memcpy(m->bytes + u->off, u->was, u->len);
    free(u->was);
  }
}

static void find_hot(image *m) {
  m->hot = malloc((m->len / 512 + 1) * sizeof *m->hot);
  if (!m->hot) abort();
  for (size_t c = 0; c * 512 < m->len; c++) {
    const uint8_t *p = m->bytes + c * 512;
    size_t n = m->len - c * 512 < 512 ? m->len - c * 512 : 512;
    bool zero = true;
    for (size_t i = 0; i < n && zero; i++) zero = p[i] == 0;
    if (!zero) m->hot[m->nhot++] = (uint32_t)c;
  }
}

static void load(image *m, const char *path) {
  FILE *f = fopen(path, "rb");
  if (!f) {
    fprintf(stderr, "mount_fuzz: no %s (./build check's host tests make it)\n", path);
    abort();
  }
  fseek(f, 0, SEEK_END);
  m->len = (size_t)ftell(f);
  fseek(f, 0, SEEK_SET);
  m->bytes = malloc(m->len);
  if (!m->bytes || fread(m->bytes, 1, m->len, f) != m->len) abort();
  fclose(f);
}

// The input's edits, each saved first.
static void edit(image *m, const uint8_t *data, size_t size) {
  for (size_t at = 0; at + 5 <= size && m->nhot;) {
    uint32_t chunk = m->hot[(data[at] | (uint32_t)data[at + 1] << 8) % m->nhot];
    size_t off = (size_t)chunk * 512 + (data[at + 2] | (uint32_t)data[at + 3] << 8) % 512;
    size_t n = data[at + 4] % 16 + 1;
    at += 5;
    if (at + n > size) n = size - at;
    if (off + n > m->len) n = m->len - off;
    save(m, off, n);
    memcpy(m->bytes + off, data + at, n);
    at += n;
  }
}

static void *m_alloc([[maybe_unused]] void *ctx, size_t n) { return malloc(n); }
static void m_free([[maybe_unused]] void *ctx, void *p, [[maybe_unused]] size_t n) { free(p); }
static const vxfs_mem MEM = {.alloc = m_alloc, .free = m_free};

static uint8_t buf[65536];
static constexpr uint32_t MAX_NODES = 512; // a walk's bound: a damaged volume may loop

// --- vx-fs ---

static image vxfs_img;

static vx_status vd_read(void *ctx, uint64_t addr, void *b) {
  const image *m = ctx;
  if (addr > m->len || VXFS_BLKSZ > m->len - addr) return VX_ERR_IO;
  memcpy(b, m->bytes + addr, VXFS_BLKSZ);
  return VX_OK;
}
static vx_status vd_write(void *ctx, uint64_t addr, const void *b) {
  image *m = ctx;
  if (addr > m->len || VXFS_BLKSZ > m->len - addr) return VX_ERR_IO;
  if (m->hot) save(m, addr, VXFS_BLKSZ); // once made, every write is put back
  memcpy(m->bytes + addr, b, VXFS_BLKSZ);
  return VX_OK;
}
static vx_status vd_barrier([[maybe_unused]] void *ctx) { return VX_OK; }
static vxfs_dev vdev(void) {
  return (vxfs_dev){
      .ctx = &vxfs_img, .read = vd_read, .write = vd_write, .barrier = vd_barrier, .size = vxfs_img.len};
}

static void vxfs_make(void) {
  vxfs_img.len = 512ull * VXFS_BLKSZ;
  vxfs_img.bytes = calloc(1, vxfs_img.len);
  static vxfs_vol v;
  vxfs_branch *br;
  vxfs_file root, d, f, l;
  const char *names[] = {"home"};
  if (!vxfs_img.bytes || vxfs_mkfs(&v, vdev(), MEM, 256, 1, names, 1, 0755, 0, 0, 1) != VX_OK ||
      vxfs_branch_open(&v, "home", &br) != VX_OK || vxfs_root(&v, &br->t, &root) != VX_OK)
    abort();
  for (uint32_t i = 0; i < sizeof buf; i++) buf[i] = (uint8_t)(i * 7);
  bool ok = vxfs_create(&v, &br->t, &root, "small", 0644, 0, 0, 1, &f) == VX_OK &&
            vxfs_write(&v, &br->t, &f, 0, "inline bytes", 12, 1, 0) == VX_OK;
  ok = ok && vxfs_create(&v, &br->t, &root, "dir", VXFS_DMDIR | 0755, 0, 0, 1, &d) == VX_OK;
  ok = ok && vxfs_create(&v, &br->t, &d, "large", 0644, 0, 0, 1, &f) == VX_OK &&
       vxfs_write(&v, &br->t, &f, 0, buf, sizeof buf, 1, 0) == VX_OK &&
       vxfs_write(&v, &br->t, &f, 200'000, buf, 100, 1, 0) == VX_OK; // sparse
  ok = ok && vxfs_symlink(&v, &br->t, &d, "link", "../small", 0, 0, 1, &l) == VX_OK;
  for (int i = 0; ok && i < 40; i++) { // a directory of many, past a leaf
    char name[16];
    snprintf(name, sizeof name, "n%02d", i);
    ok = vxfs_create(&v, &br->t, &d, name, 0644, 0, 0, 1, &f) == VX_OK &&
         vxfs_write(&v, &br->t, &f, 0, name, 3, 1, 0) == VX_OK;
  }
  if (!ok || vxfs_commit(&v) != VX_OK) abort();
  vxfs_unmount(&v);
}

typedef struct names {
  char name[64][VXFS_NAMEMAX + 1];
  uint32_t n;
} names;

static bool vxfs_listed(void *ctx, const char *name, uint16_t n, [[maybe_unused]] const vxfs_dir *d) {
  names *l = ctx;
  if (l->n == 64 || n > VXFS_NAMEMAX) return false;
  memcpy(l->name[l->n], name, n);
  l->name[l->n++][n] = 0;
  return true;
}

static void vxfs_try(void) {
  static vxfs_vol v;
  vxfs_branch *br;
  if (vxfs_mount(&v, vdev(), MEM, 64) != VX_OK) return;
  if (vxfs_branch_open(&v, "home", &br) != VX_OK) {
    vxfs_unmount(&v);
    return;
  }
  static vxfs_file stack[MAX_NODES];
  static names l;
  uint32_t top = 0, seen = 0;
  if (vxfs_root(&v, &br->t, &stack[top]) == VX_OK) top++;
  while (top && seen++ < MAX_NODES) {
    vxfs_file dir = stack[--top];
    l.n = 0;
    if (vxfs_readdir(&v, &br->t, &dir, vxfs_listed, &l) != VX_OK) continue;
    for (uint32_t i = 0; i < l.n; i++) {
      vxfs_file f;
      if (vxfs_walk(&v, &br->t, &dir, l.name[i], &f) != VX_OK) continue;
      uint64_t got = 0;
      if (is_dir(&f)) {
        if (top < MAX_NODES) stack[top++] = f;
      } else {
        vxfs_read(&v, &br->t, &f, 0, buf, sizeof buf, &got);
      }
    }
  }
  vxfs_file root, f;
  if (vxfs_root(&v, &br->t, &root) == VX_OK &&
      vxfs_create(&v, &br->t, &root, "fuzzed", 0644, 0, 0, 2, &f) == VX_OK)
    vxfs_write(&v, &br->t, &f, 0, buf, 5000, 2, 0);
  vxfs_commit(&v);
  vxfs_check c;
  vxfs_check_volume(&v, &c);
  vxfs_unmount(&v);
}

// --- FAT ---

static image fat_img[3]; // FAT12, FAT16 (mtools's), FAT32 (fat_format's)

static bool fd_read(void *ctx, uint64_t off, uint32_t len, uint8_t *b) {
  const image *m = ctx;
  if (off > m->len || len > m->len - off) return false;
  memcpy(b, m->bytes + off, len);
  return true;
}
static bool fd_write(void *ctx, uint64_t off, uint32_t len, const uint8_t *b) {
  image *m = ctx;
  if (off > m->len || len > m->len - off) return false;
  if (m->hot) save(m, off, len);
  memcpy(m->bytes + off, b, len);
  return true;
}
static bool fd_flush([[maybe_unused]] void *ctx) { return true; }
static fat_dev fdev(image *m) {
  return (fat_dev){.ctx = m, .read = fd_read, .write = fd_write, .flush = fd_flush};
}

static void fat_make(image *m) {
  m->len = 70'000ull * 512;
  m->bytes = calloc(1, m->len);
  static fat_vol v;
  fat_entry root, d, f;
  if (!m->bytes || fat_format(fdev(m), 70'000, 0, "FUZZ", 1) != VX_OK || fat_mount(&v, fdev(m)) != VX_OK)
    abort();
  fat_root_entry(&v, &root);
  bool ok = fat_create(&v, &root, "A long file name.txt", 20, 0, &f) == VX_OK &&
            fat_write(&v, &f, 0, buf, sizeof buf) == VX_OK;
  ok = ok && fat_create(&v, &root, "DIR", 3, FAT_DIRECTORY, &d) == VX_OK;
  for (int i = 0; ok && i < 40; i++) { // a directory past a cluster
    char name[32];
    int n = snprintf(name, sizeof name, "entry number %02d", i);
    ok = fat_create(&v, &d, name, (size_t)n, 0, &f) == VX_OK &&
         fat_write(&v, &f, 0, (uint8_t *)name, 3) == VX_OK;
  }
  if (!ok || fat_flush(&v) != VX_OK) abort();
}

static void fat_try(image *m) {
  static fat_vol v;
  if (fat_mount(&v, fdev(m)) != VX_OK) return;
  static fat_entry stack[MAX_NODES];
  uint32_t top = 0, seen = 0;
  fat_root_entry(&v, &stack[top++]);
  while (top && seen++ < MAX_NODES) {
    fat_entry dir = stack[--top];
    fat_iter it;
    fat_entry e;
    if (fat_open_dir(&v, &dir, &it) != VX_OK) continue;
    for (uint32_t i = 0; i < 256 && fat_dir_next(&v, &it, &e) == VX_OK; i++) {
      uint64_t parent;
      fat_parent(&v, e.node, &parent);
      if (e.attr & FAT_DIRECTORY) {
        if (top < MAX_NODES && strcmp(e.name, ".") != 0 && strcmp(e.name, "..") != 0) stack[top++] = e;
        continue;
      }
      uint32_t count = sizeof buf;
      fat_read(&v, &e, 0, buf, &count);
      fat_entry again;
      fat_lookup(&v, &dir, e.name, strlen(e.name), &again);
    }
  }
  fat_entry root, f;
  fat_root_entry(&v, &root);
  if (fat_create(&v, &root, "fuzzed", 6, 0, &f) == VX_OK) fat_write(&v, &f, 0, buf, 5000);
  fat_flush(&v);
}

// --- ISO 9660 ---

static image iso_img;

static bool id_read(void *ctx, uint64_t off, uint32_t len, uint8_t *b) {
  const image *m = ctx;
  if (off > m->len || len > m->len - off) return false;
  memcpy(b, m->bytes + off, len);
  return true;
}

static void iso_try(uint32_t avoid) {
  static iso_vol v;
  if (iso_mount(&v, (iso_dev){.ctx = &iso_img, .read = id_read}, avoid) != VX_OK) return;
  static iso_entry stack[MAX_NODES];
  uint32_t top = 0, seen = 0;
  iso_root_entry(&v, &stack[top++]);
  while (top && seen++ < MAX_NODES) {
    iso_entry dir = stack[--top];
    iso_iter it;
    iso_entry e;
    if (iso_open_dir(&v, &dir, &it) != VX_OK) continue;
    for (uint32_t i = 0; i < 256 && iso_dir_next(&v, &it, &e) == VX_OK; i++) {
      uint64_t parent;
      iso_parent(&v, e.node, &parent);
      if (e.dir) {
        if (top < MAX_NODES) stack[top++] = e;
        continue;
      }
      uint32_t count = sizeof buf;
      iso_read(&v, &e, 0, buf, &count);
      iso_entry again;
      iso_lookup(&v, &dir, e.name, strlen(e.name), &again);
    }
  }
}

// --- The target ---

static bool made;

static void make_all(void) {
  vxfs_make();
  find_hot(&vxfs_img);
  load(&fat_img[0], "out/host/fat12.img");
  load(&fat_img[1], "out/host/fat16.img");
  fat_make(&fat_img[2]);
  load(&iso_img, "out/host/test.iso");
  for (int i = 0; i < 3; i++) find_hot(&fat_img[i]);
  find_hot(&iso_img);
  made = true;
}

// libFuzzer calls it by name, so it cannot be static.
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size); // NOLINT(misc-use-internal-linkage)

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  if (!made) make_all();
  if (size < 1) return 0;
  uint8_t which = data[0] % 7;
  image *m = &iso_img;
  if (which == 0) m = &vxfs_img;
  if (which >= 1 && which <= 3) m = &fat_img[which - 1];
  edit(m, data + 1, size - 1);
  if (which == 0) vxfs_try();
  if (which >= 1 && which <= 3) fat_try(m);
  static const uint32_t AVOID[3] = {0, ISO_ROCK, ISO_ROCK | ISO_JOLIET}; // each way of reading it
  if (which >= 4) iso_try(AVOID[which - 4]);
  put_back(m);
  return 0;
}
