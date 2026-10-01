// tar_fuzz.c: arbitrary bytes into vx-tar's reader. Every entry it returns
// must lie inside the input and have a safe path; and the archive the writer
// makes from those entries must read back the same.

#include <stdlib.h>
#include <string.h>

#include "../../lib/vx-tar/tar.c"

// libFuzzer calls it by name, so it cannot be static.
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size); // NOLINT(misc-use-internal-linkage)

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  static uint8_t out[1 << 20];
  vx_tar_writer w = {.buf = out, .cap = sizeof out};
  vx_tar t = vx_tar_open(data, size);
  vx_tar_entry e;
  int count = 0;
  while (vx_tar_next(&t, &e) == VX_OK) {
    if (!tar_path_ok(e.path)) abort();
    if (!e.dir && (e.data < data || e.size > size || e.data + e.size > data + size)) abort();
    vx_tar_add(&w, e.path, e.dir, e.mode, e.data, e.size);
    count++;
  }
  size_t n = vx_tar_end(&w);
  if (!n) return 0; // a path the writer splits differently can fail to fit; that is fine
  vx_tar again = vx_tar_open(out, n);
  vx_tar_entry a;
  t = vx_tar_open(data, size);
  for (int i = 0; i < count; i++) {
    if (vx_tar_next(&again, &a) != VX_OK || vx_tar_next(&t, &e) != VX_OK) abort();
    if (a.path.len != e.path.len || memcmp(a.path.ptr, e.path.ptr, a.path.len) != 0 || a.size != e.size ||
        a.dir != e.dir || a.mode != e.mode || (a.size && memcmp(a.data, e.data, a.size) != 0))
      abort();
  }
  if (vx_tar_next(&again, &a) != VX_ERR_NOT_FOUND) abort();
  return 0;
}
