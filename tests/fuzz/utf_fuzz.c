// utf_fuzz.c: arbitrary bytes into lib/vx-utf (ADR-0013). The decoder always
// moves on, by one byte at a bad one; what it decodes encodes back to the same
// bytes wherever the input was valid; a cut never splits a rune; and stepping
// back over the input finds the starts stepping forward found.

#include <stdlib.h>
#include <string.h>

#include "../../lib/vx-utf/utf.h"

// libFuzzer calls it by name, so it cannot be static.
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size); // NOLINT(misc-use-internal-linkage)

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  const char *s = (const char *)data;
  static size_t starts[4097];
  size_t count = 0, at = 0;
  bool valid = true;
  while (at < size) {
    vx_rune r;
    size_t len = vx_chartorune(&r, s + at, size - at);
    if (len < 1 || len > VX_UTFMAX || at + len > size) abort();
    if (r > VX_RUNEMAX || (r >= 0xd800 && r <= 0xdfff)) abort();
    if (r == VX_RUNEERROR && len != 3) {
      if (len != 1) abort();
      valid = false;
    } else {
      char buf[VX_UTFMAX];
      if (vx_runetochar(buf, r) != len || memcmp(buf, s + at, len) != 0) abort();
    }
    if (count < sizeof starts / sizeof starts[0]) starts[count++] = at;
    at += len;
  }
  if (vx_utf_valid(s, size) != valid) abort();
  for (size_t max = 0; max <= size && max < 64; max++) { // a cut is at a start, or the end
    size_t cut = vx_utf_cut(s, size, max);
    if (cut > max) abort();
    bool at_start = cut == size;
    for (size_t i = 0; i < count && !at_start; i++) at_start = starts[i] == cut;
    if (!at_start) abort();
  }
  if (valid && count < sizeof starts / sizeof starts[0]) // back over valid text: the starts, in reverse
    for (size_t i = count, pos = size; i-- > 0;) {
      pos = vx_utf_back(s, pos);
      if (pos != starts[i]) abort();
    }
  return 0;
}
