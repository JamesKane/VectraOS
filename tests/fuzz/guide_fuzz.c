// guide_fuzz.c: arbitrary text into lib/vx-guide as a page: the parser, the
// renderer (whole, at a width the input picks, and node by node) and the
// inline spans never read outside the page, never loop for ever, and give
// output that is UTF-8 whenever the page was accepted.

#include <stdlib.h>
#include <string.h>

#include "../../lib/vx-guide/guide.c"

static size_t written;
static bool utf_ok;

static void count(void *ctx, const char *s, size_t n) {
  (void)ctx;
  written += n;
  if (written > (64u << 20)) abort(); // output out of all proportion to a 4 KiB page: a loop
  utf_ok = utf_ok && vx_utf_valid(s, n);
}

// libFuzzer calls it by name, so it cannot be static.
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size); // NOLINT(misc-use-internal-linkage)

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  vx_str page = {(const char *)data, size};
  vx_guide_out o = {.write = count, .width = size ? 8 + data[0] % 120 : 80};
  const char *error;
  size_t line;
  written = 0, utf_ok = true;
  if (vx_guide_render(page, nullptr, &o, &error, &line) && !utf_ok) abort();
  static vx_guide g;
  if (!vx_guide_open(&g, page)) return 0;
  vx_guide_block b;
  for (int blocks = 0; vx_guide_next(&g, &b) > VX_GUIDE_END; blocks++) {
    if (blocks > 100000) abort();
    if (b.kind == VX_GUIDE_NODE) {
      char id[64];
      size_t n = b.node.len < sizeof id - 1 ? b.node.len : sizeof id - 1;
      memcpy(id, b.node.ptr, n);
      id[n] = 0;
      vx_guide_render(page, id, &o, &error, &line);
    }
    vx_guide_inline it = {.s = b.text};
    vx_guide_span sp;
    for (int spans = 0; vx_guide_span_next(&it, &sp) > VX_SPAN_END; spans++)
      if (spans > 100000) abort();
    if (b.kind == VX_GUIDE_ROW) {
      vx_str row = b.text, cell;
      for (int cells = 0; vx_guide_cell_next(&row, &cell); cells++)
        if (cells > 100000) abort();
    }
  }
  return 0;
}
