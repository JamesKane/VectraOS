// p9_decode_fuzz.c: arbitrary bytes into vx-9p's decoders. Whatever decodes
// must encode back to exactly the same bytes, so the decoder can neither crash
// nor accept something it would not have written.

#include <stdlib.h>
#include <string.h>

#include "../../lib/vx-9p/codec.c"

// libFuzzer calls it by name, so it cannot be static.
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size); // NOLINT(misc-use-internal-linkage)

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  static uint8_t again[1 << 16];
  p9_msg m;
  if (p9_decode(data, size, &m) == VX_OK) {
    size_t n = p9_encode(&m, again, sizeof again);
    if (n != size || memcmp(again, data, size) != 0) abort();
  }
  p9_stat s;
  if (p9_stat_decode(data, size, &s) == VX_OK) {
    size_t n = p9_stat_encode(&s, again, sizeof again);
    if (n != size || memcmp(again, data, size) != 0) abort();
  }
  uint32_t ext;
  p9_version_parse((vx_str){(const char *)data, size}, &ext);
  return 0;
}
