// imagetest: libvx level 2's calls (M7 step 7g2a, ADR-0056) from a native
// program, the image scenario's (tests/qemu/image.ndb), the first of level
// 2's behaviour suite. Code images (vx/image.h): libimage.so opened twice is
// two images, each bound to libvx.so, its constructor run, its state its
// own, the first's string still good; what is not exported not found; an
// image with TLS, one needing a library not loaded, a file that is not one
// and a path that is not there refused. A VMO's size (vx_vmo_size) and a
// span while spans are off (vx/trace.h). Each check prints a line only
// when it fails; the last line counts them.

#include <stdio.h>
#include <string.h>
#include <vx.h>

#include "imagetest.h"

static int checks, failures;

static void check_at(bool ok, const char *what, int line) {
  checks++;
  if (ok) return;
  failures++;
  printf("imagetest: FAILED line %d: %s\n", line, what);
}

#define CHECK(cond) check_at((cond), #cond, __LINE__)

static bool said(const char *words) {
  vx_str e = vx_errstr();
  size_t n = strlen(words);
  for (size_t i = 0; i + n <= e.len; i++)
    if (memcmp(e.ptr + i, words, n) == 0) return true;
  return false;
}

typedef typeof(&image_bump) int_fn;
typedef typeof(&image_hello) str_fn;
typedef typeof(&image_now) now_fn;

int main(void) {
  vx_image *a = nullptr, *b = nullptr, *bad = nullptr;
  CHECK(vx_image_open(VX_STR("/lib/libimage.so"), &a) == VX_OK && a);
  if (!a) {
    printf("imagetest: FAILED: no image: %.*s\n", VX_FMT(vx_errstr()));
    return 1;
  }
  int_fn inits = (int_fn)vx_image_symbol(a, "image_inits"), bump = (int_fn)vx_image_symbol(a, "image_bump");
  str_fn hello = (str_fn)vx_image_symbol(a, "image_hello");
  now_fn now = (now_fn)vx_image_symbol(a, "image_now");
  int *counter = vx_image_symbol(a, "image_counter");
  CHECK(inits && bump && hello && now && counter);
  if (!inits || !bump || !hello || !now || !counter) return 1;
  CHECK(inits() == 1);   // its constructor, once
  CHECK(*counter == 10); // which set its data
  CHECK(bump() == 11 && *counter == 11);
  CHECK(now() > 0); // its call into libvx.so bound
  const char *s = hello();
  CHECK(strcmp(s, "a string in an image") == 0);
  CHECK(vx_image_symbol(a, "image_hidden") == nullptr); // static: not exported
  CHECK(vx_image_symbol(a, "image_absent") == nullptr);
  CHECK(vx_image_symbol(a, "image_init") == nullptr);

  // Again: a fresh copy at a new address, its state its own, the first's kept.
  CHECK(vx_image_open(VX_STR("/lib/libimage.so"), &b) == VX_OK && b && b != a);
  int_fn bump2 = b ? (int_fn)vx_image_symbol(b, "image_bump") : nullptr;
  int *counter2 = b ? vx_image_symbol(b, "image_counter") : nullptr;
  int_fn inits2 = b ? (int_fn)vx_image_symbol(b, "image_inits") : nullptr;
  CHECK(bump2 && counter2 && inits2 && (void *)bump2 != (void *)bump && counter2 != counter);
  if (bump2 && counter2 && inits2) {
    CHECK(inits2() == 1 && *counter2 == 10);
    CHECK(bump2() == 11 && bump() == 12 && *counter == 12 && *counter2 == 11);
  }
  CHECK(strcmp(s, "a string in an image") == 0); // the old image's string, still mapped

  // Refused.
  CHECK(vx_image_open(VX_STR("/lib/libimagetls.so"), &bad) != VX_OK && !bad && said("TLS"));
  CHECK(vx_image_open(VX_STR("/lib/libimageneeds.so"), &bad) != VX_OK && !bad && said("libimage.so"));
  CHECK(vx_image_open(VX_STR("/boot/svc/imagetest.ndb"), &bad) != VX_OK && !bad && said("not a shared"));
  CHECK(vx_image_open(VX_STR("/lib/libnone.so"), &bad) != VX_OK && !bad);
  CHECK(bump() == 13); // a refusal leaves the open images as they were

  // A VMO's size through its handle; a duplicate's too.
  vx_handle vmo = VX_HANDLE_NONE, dup = VX_HANDLE_NONE;
  uint64_t size = 0;
  CHECK(vx_vmo_create(3ull * 4096, 0, &vmo) == VX_OK);
  CHECK(vx_vmo_size(vmo, &size) == VX_OK && size == 3ull * 4096);
  CHECK(vx_handle_dup(vmo, VX_RIGHTS_SAME, &dup) == VX_OK);
  size = 0;
  CHECK(vx_vmo_size(dup, &size) == VX_OK && size == 3ull * 4096);
  vx_handle_close(dup);
  vx_handle_close(vmo);
  CHECK(vx_vmo_size(vmo, &size) != VX_OK && size == 0);

  // Spans with the trace's spans off: nothing begun, and nothing to end.
  uint64_t span = vx_span_begin();
  CHECK(span == 0);
  vx_span_end(span, 0, 0);

  printf("imagetest: %d checks, %d failed\n", checks, failures);
  return failures ? 1 : 0;
}
