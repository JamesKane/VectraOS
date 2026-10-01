// tar_test.c: lib/vx-tar. Archives the writer makes read back entry for
// entry; long paths split into prefix and name; and the reader refuses bad
// checksums, bad octal, unsafe paths, links, and files that run past the image.

#include <string.h>

#include "check.h"
#include "../../lib/vx-tar/tar.c"

static uint8_t image[64 * 1024];

static size_t build(void) {
  vx_tar_writer w = {.buf = image, .cap = sizeof image};
  vx_tar_add(&w, VX_STR("boot"), true, 0755, nullptr, 0);
  vx_tar_add(&w, VX_STR("boot/svc"), true, 0755, nullptr, 0);
  vx_tar_add(&w, VX_STR("boot/svc/bootfs.ndb"), false, 0644, "service=bootfs\n", 15);
  vx_tar_add(&w, VX_STR("empty"), false, 0644, "", 0);
  char big[1000];
  memset(big, 'x', sizeof big);
  vx_tar_add(&w, VX_STR("big"), false, 0755, big, sizeof big);
  // 150 bytes of path: a prefix and a name.
  vx_tar_add(&w,
             VX_STR("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/"
                    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
             false, 0644, "long", 4);
  return vx_tar_end(&w);
}

static void test_round_trip(void) {
  size_t n = build();
  CHECK(n == VX_TAR_BLOCK * (1 + 1 + 2 + 1 + 3 + 2 + 2)); // dirs, files with their data, the end
  vx_tar t = vx_tar_open(image, n);
  vx_tar_entry e;
  CHECK(vx_tar_next(&t, &e) == VX_OK && e.dir && e.path.len == 4 && e.mode == 0755);
  CHECK(vx_tar_next(&t, &e) == VX_OK && e.dir && e.path.len == 8);
  CHECK(vx_tar_next(&t, &e) == VX_OK && !e.dir && e.size == 15 &&
        memcmp(e.data, "service=bootfs\n", 15) == 0);
  CHECK(vx_tar_next(&t, &e) == VX_OK && e.size == 0 && e.data);
  CHECK(vx_tar_next(&t, &e) == VX_OK && e.size == 1000 && e.data[999] == 'x' && e.mode == 0755);
  CHECK(vx_tar_next(&t, &e) == VX_OK && e.path.len == 150 && e.path.ptr[80] == '/' &&
        memcmp(e.data, "long", 4) == 0);
  CHECK(vx_tar_next(&t, &e) == VX_ERR_NOT_FOUND);
  CHECK(vx_tar_next(&t, &e) == VX_ERR_NOT_FOUND);

  CHECK(vx_tar_find(image, n, VX_STR("boot/svc/bootfs.ndb"), &e) == VX_OK && e.size == 15);
  CHECK(vx_tar_find(image, n, VX_STR("boot/svc"), &e) == VX_OK && e.dir);
  CHECK(vx_tar_find(image, n, VX_STR("boot/sv"), &e) == VX_ERR_NOT_FOUND);
  CHECK(vx_tar_find(image, n - 1024, VX_STR("big"), &e) == VX_OK); // no end blocks: still fine

  // The writer refuses what the reader would.
  uint8_t small[2048];
  vx_tar_writer w = {.buf = small, .cap = sizeof small};
  vx_tar_add(&w, VX_STR("../etc"), false, 0644, "x", 1);
  CHECK(w.failed);
  w = (vx_tar_writer){.buf = small, .cap = sizeof small};
  vx_tar_add(&w, VX_STR("f"), false, 0644, image, 1024); // header + 2 blocks + end > 2048
  CHECK(!w.failed && vx_tar_end(&w) == 0);
}

// Rewrites the checksum of the header at `at` after a change.
static void reseal(size_t at) {
  vx_tar_header *h = (vx_tar_header *)(image + at);
  tar_put_octal(h->chksum, 7, tar_checksum(h));
  h->chksum[7] = ' ';
}

static vx_status first_entry(size_t n) {
  vx_tar t = vx_tar_open(image, n);
  vx_tar_entry e;
  return vx_tar_next(&t, &e);
}

static void test_hostile(void) {
  static const char *const bad_names[] = {"/abs", "a//b", "./a", "a/../b", "..", "a/.", "tab\there"};
  for (size_t i = 0; i < sizeof bad_names / sizeof bad_names[0]; i++) {
    size_t n = build();
    vx_tar_header *h = (vx_tar_header *)image;
    memset(h->name, 0, sizeof h->name);
    memcpy(h->name, bad_names[i], strlen(bad_names[i]));
    reseal(0);
    CHECK(first_entry(n) == VX_ERR_INVALID);
  }
  size_t n = build();
  vx_tar_header *h = (vx_tar_header *)image;
  image[3] ^= 1; // a name byte, with the checksum left alone
  CHECK(first_entry(n) == VX_ERR_INVALID);

  n = build();
  h->typeflag = '2'; // a symlink
  reseal(0);
  CHECK(first_entry(n) == VX_ERR_INVALID);

  n = build();
  memcpy(h->mode, "07x5\0\0\0", 8); // not octal
  reseal(0);
  CHECK(first_entry(n) == VX_ERR_INVALID);

  n = build();
  h->name[99] = 'z'; // a name that fills its field is fine...
  memset(h->name + 4, 'q', 95);
  reseal(0);
  CHECK(first_entry(n) == VX_OK);
  h->magic[0] = 'x'; // ...but not without the ustar magic
  reseal(0);
  CHECK(first_entry(n) == VX_ERR_INVALID);

  // A file whose size runs past the image, at the third header.
  n = build();
  vx_tar_header *f = (vx_tar_header *)(image + 1024);
  tar_put_octal(f->size, sizeof f->size, 1u << 30);
  reseal(1024);
  vx_tar t = vx_tar_open(image, n);
  vx_tar_entry e;
  CHECK(vx_tar_next(&t, &e) == VX_OK && vx_tar_next(&t, &e) == VX_OK);
  CHECK(vx_tar_next(&t, &e) == VX_ERR_INVALID);
  CHECK(vx_tar_next(&t, &e) == VX_ERR_INVALID); // and it stays ended
  CHECK(vx_tar_find(image, n, VX_STR("big"), &e) == VX_ERR_INVALID);

  // Truncated mid-header and mid-file.
  n = build();
  CHECK(first_entry(511) == VX_ERR_NOT_FOUND);
  vx_tar t2 = vx_tar_open(image, 1024 + 512 + 8);
  CHECK(vx_tar_next(&t2, &e) == VX_OK && vx_tar_next(&t2, &e) == VX_OK &&
        vx_tar_next(&t2, &e) == VX_ERR_INVALID);
}

int main(void) {
  test_round_trip();
  test_hostile();
  return check_result();
}
