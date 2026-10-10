// font_test.c: lib/vx-font (M7 step 7e1) with Inter (ADR-0054): a font
// loaded for shaping and rasterizing, kerning applied by the shaper, text
// drawn through the atlas at a terminal size, the atlas's hits and its
// eviction of the oldest slot. (A file that is no font is not tried: neither
// library is safe on untrusted fonts, ADR-0052 and 0053, and vx-font loads
// only the system's own.)
// host-links: font

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "check.h"
#include "../../lib/vx-font/font.c"

static uint8_t *slurp(const char *path, size_t *len) {
  FILE *f = fopen(path, "rb");
  if (!f) return nullptr;
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  uint8_t *b = malloc((size_t)n);
  *len = fread(b, 1, (size_t)n, f);
  fclose(f);
  return b;
}

static int32_t width_of(vx_font *f, const char *s) {
  vx_glyph_at g[64];
  int32_t adv = 0;
  vx_font_shape(f, s, strlen(s), g, 64, &adv);
  return adv;
}

int main(void) {
  size_t len = 0;
  uint8_t *ttf = slurp("third_party/inter/extras/ttf/Inter-Regular.ttf", &len);
  CHECK(ttf && len > 100000);
  if (!ttf) return check_result();
  vx_font f;
  CHECK(vx_font_init(&f, ttf, len, 1));
  CHECK(f.units_per_em == 2048 && f.ascent > 0 && f.descent < 0);

  // Shaping: one glyph a letter here, and "AV" kerned tighter than its letters apart.
  vx_glyph_at g[64];
  int32_t adv = 0;
  CHECK(vx_font_shape(&f, "Hamburgefonstiv", 15, g, 64, &adv) == 15 && adv > 0);
  CHECK(g[0].glyph != 0 && g[1].x > g[0].x);
  CHECK(width_of(&f, "AV") < width_of(&f, "A") + width_of(&f, "V"));
  CHECK(width_of(&f, "\xc3\xa9t\xc3\xa9") > 0); // été: non-ASCII shaped

  // Drawing at 13 pixels to the em: ink inside the line, none outside it.
  static uint32_t px[200 * 32];
  for (size_t i = 0; i < sizeof px / sizeof px[0]; i++) px[i] = 0xffffff;
  vx_font_target cv = {.px = px, .stride = 200, .clip_x0 = 0, .clip_y0 = 0, .clip_x1 = 200, .clip_y1 = 32};
  vx_atlas a;
  CHECK(vx_atlas_init(&a, 64));
  int32_t end = vx_text_draw(&cv, &a, &f, 13, 4, 20, 0x000000, "Hamburgefonstiv", 15);
  CHECK(end > 60 && end < 160);
  uint32_t ink = 0, outside = 0;
  for (int y = 0; y < 32; y++)
    for (int x = 0; x < 200; x++) {
      bool dark = (px[y * 200 + x] & 0xff) < 0x80;
      ink += dark;
      if (dark && (y < 6 || y > 24 || x >= end + 2)) outside++;
    }
  CHECK(ink > 100 && outside == 0);
  CHECK(a.misses > 10 && a.misses <= 15 && a.hits == 15 - a.misses); // the repeated letters hit

  // Eviction: four cells, six glyphs; the oldest slots go, the newest stay.
  vx_atlas tiny;
  CHECK(vx_atlas_init(&tiny, 4));
  const uint8_t *bm;
  for (uint32_t gl = 10; gl < 16; gl++) vx_atlas_get(&tiny, &f, gl, 13, 0, &bm);
  CHECK(tiny.misses == 6 && tiny.hits == 0);
  vx_atlas_get(&tiny, &f, 15, 13, 0, &bm); // the newest: there
  vx_atlas_get(&tiny, &f, 12, 13, 0, &bm); // the fourth newest: there
  CHECK(tiny.hits == 2 && tiny.misses == 6);
  vx_atlas_get(&tiny, &f, 10, 13, 0, &bm); // the oldest: gone
  vx_atlas_get(&tiny, &f, 15, 13, 1, &bm); // the same glyph at another quarter pixel: another key
  CHECK(tiny.misses == 8);
  vx_atlas_free(&tiny);
  vx_atlas_free(&a);
  vx_font_fini(&f);
  free(ttf);
  return check_result();
}
