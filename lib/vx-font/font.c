// vx-font: text, from a font file to pixels (M7 step 7e1; docs/21 §2 item
// 10). Shaping is kb_text_shape's (ADR-0053): UTF-8 into runs of glyphs with
// their advances and offsets, ligatures and kerning applied. Rasterizing is
// stb_truetype's (ADR-0052): a glyph's outline into an 8-bit coverage
// bitmap at a size and a horizontal subpixel offset. Both are built as the
// font port (ports/font), which calls the hooks below in place of a C
// library.
//
// The glyph atlas is 03's and libdraw's (font.c:163-200): a fixed number of
// fixed-size cells, each holding one glyph rasterized at one size and one of
// four quarter-pixel offsets, keyed by font, glyph, size and offset, the
// oldest-used slot taken when it is full. Text is drawn from it by alpha
// blending its coverage over the destination in one colour.
//
// Hosted (tests, host tools) it uses the C library's malloc and math; in
// libvxui.so, as in a first-party program, libvx's heap and its own math.

#pragma once

#include <stddef.h>
#include <stdint.h>

#if __STDC_HOSTED__ && !defined(__vectraos__) // the host's: an SDK library (libvxui.so) takes the heap's way
#include <math.h>
#include <stdlib.h>
#include <string.h>
#endif

#include "stb_truetype.h"
#include "kb_text_shape.h"
#include "../../ports/font/hooks.h" // what the port calls, defined here

// --- The hooks the port calls (ports/font/hooks.h) ---

#if __STDC_HOSTED__ && !defined(__vectraos__)
void *vx_font_alloc(size_t n) { return malloc(n); }
void vx_font_free(void *p) { free(p); }
double vx_font_floor(double x) { return floor(x); }
double vx_font_ceil(double x) { return ceil(x); }
double vx_font_sqrt(double x) { return sqrt(x); }
double vx_font_pow(double x, double y) { return pow(x, y); }
double vx_font_fmod(double x, double y) { return fmod(x, y); }
double vx_font_cos(double x) { return cos(x); }
double vx_font_acos(double x) { return acos(x); }
double vx_font_fabs(double x) { return fabs(x); }
size_t vx_font_strlen(const char *s) { return strlen(s); }
#else
void *vx_font_alloc(size_t n) { return vx_heap_alloc(vx_heap_process(), n ? n : 1); }
void vx_font_free(void *p) {
  if (p) vx_heap_free(vx_heap_process(), p);
}
double vx_font_floor(double x) {
  if (x >= 9.0e15 || x <= -9.0e15) return x; // past 2^53: already whole
  double t = (double)(int64_t)x;
  return t > x ? t - 1 : t;
}
double vx_font_ceil(double x) {
  if (x >= 9.0e15 || x <= -9.0e15) return x;
  double t = (double)(int64_t)x;
  return t < x ? t + 1 : t;
}
double vx_font_sqrt(double x) { return __builtin_elementwise_sqrt(x); } // the instruction, never a call
size_t vx_font_strlen(const char *s) {
  size_t n = 0;
  while (s[n]) n++;
  return n;
}
double vx_font_fabs(double x) { return x < 0 ? -x : x; }
double vx_font_fmod(double x, double y) { return y == 0 ? 0 : x - y * (double)(int64_t)(x / y); }
// The signed-distance-field functions' alone; nothing calls those, and these
// are only good enough for them: cos by its series after reduction to
// [-pi, pi], acos by atan's identity, pow as a cube root (its one use).
double vx_font_cos(double x) {
  const double pi = 3.14159265358979323846;
  x = vx_font_fmod(x, 2 * pi);
  if (x > pi) x -= 2 * pi;
  if (x < -pi) x += 2 * pi;
  double x2 = x * x, term = 1, sum = 1;
  for (int k = 1; k < 12; k++) term *= -x2 / ((2 * k - 1) * (2 * k)), sum += term;
  return sum;
}
double vx_font_acos(double x) {
  if (x <= -1) return 3.14159265358979323846;
  if (x >= 1) return 0;
  double t = vx_font_sqrt(1 - x * x) / (1 + x), sum = 0, p = t; // acos x = 2 atan t
  if (t > 1) {                                                  // atan t = pi/2 - atan(1/t)
    double u = 1 / t, q = u;
    for (int k = 0; k < 40; k++) sum += (k % 2 ? -q : q) / (2 * k + 1), q *= u * u;
    return 2 * (1.57079632679489661923 - sum);
  }
  for (int k = 0; k < 40; k++) sum += (k % 2 ? -p : p) / (2 * k + 1), p *= t * t;
  return 2 * sum;
}
double vx_font_pow(double x, double y) { // x^(1/3), Newton's
  (void)y;
  if (x == 0) return 0;
  double r = x > 0 ? x : -x, g = r > 1 ? r / 3 : 1;
  for (int k = 0; k < 60; k++) g = (2 * g + r / (g * g)) / 3;
  return x > 0 ? g : -g;
}
#endif

// --- Fonts ---

typedef struct vx_font {
  stbtt_fontinfo tt;
  kbts_font kb;
  kbts_shape_context *shape;
  const uint8_t *data;
  uint32_t id; // the atlas's key for it
  int units_per_em;
  int ascent, descent, line_gap; // in font units
} vx_font;

// A font from a TrueType file's bytes, which must outlive it. false: not one
// stb_truetype and kb_text_shape both read. Only the system's own fonts
// (/lib/font, from the boot image): neither library is safe on a hostile
// file (ADR-0052, 0053), and a font an app supplies waits for a validating
// loader.
[[maybe_unused]] static bool vx_font_init(vx_font *f, const uint8_t *data, size_t size, uint32_t id) {
  *f = (vx_font){.data = data, .id = id};
  if (size > INT32_MAX || !stbtt_InitFont(&f->tt, data, stbtt_GetFontOffsetForIndex(data, 0))) return false;
  f->kb = kbts_FontFromMemory((void *)data, (int)size, 0, nullptr, nullptr);
  if (!kbts_FontIsValid(&f->kb)) return false;
  f->shape = kbts_CreateShapeContext(nullptr, nullptr);
  if (!f->shape || !kbts_ShapePushFont(f->shape, &f->kb)) return false;
  stbtt_GetFontVMetrics(&f->tt, &f->ascent, &f->descent, &f->line_gap);
  const uint8_t *head = f->tt.data + f->tt.head; // its 'head' table: unitsPerEm at 18, big-endian
  f->units_per_em = head[18] << 8 | head[19];
  return f->units_per_em != 0;
}

// What a font holds, let go; its file's bytes are the caller's.
[[maybe_unused]] static void vx_font_fini(vx_font *f) {
  if (f->shape) kbts_DestroyShapeContext(f->shape);
  kbts_FreeFont(&f->kb);
  *f = (vx_font){};
}

// Font units to 1/64 pixels at px pixels to the em.
[[maybe_unused]] static int32_t vx_font_to64(const vx_font *f, int32_t units, uint32_t px) {
  return (int32_t)((int64_t)units * px * 64 / f->units_per_em);
}

typedef struct vx_glyph_at {
  uint32_t glyph;
  int32_t x, y; // where it goes, in font units from the run's start
} vx_glyph_at;

// The glyphs of UTF-8 text, shaped in order (left to right; a mixed-
// direction paragraph is a later step's), at most cap of them; their count.
// *advance is the run's width in font units.
[[maybe_unused]] static uint32_t vx_font_shape(vx_font *f, const char *text, size_t len, vx_glyph_at *out,
                                               uint32_t cap, int32_t *advance) {
  uint32_t n = 0;
  int32_t x = 0;
  kbts_ShapeBegin(f->shape, KBTS_DIRECTION_DONT_KNOW, KBTS_LANGUAGE_DONT_KNOW);
  kbts_ShapeUtf8(f->shape, text, (int)len, KBTS_USER_ID_GENERATION_MODE_CODEPOINT_INDEX);
  kbts_ShapeEnd(f->shape);
  kbts_run run;
  while (kbts_ShapeRun(f->shape, &run)) {
    kbts_glyph *g;
    while (kbts_GlyphIteratorNext(&run.Glyphs, &g)) {
      if (n < cap) out[n++] = (vx_glyph_at){.glyph = g->Id, .x = x + g->OffsetX, .y = g->OffsetY};
      x += g->AdvanceX;
    }
  }
  if (advance) *advance = x;
  return n;
}

// --- The atlas ---

static constexpr uint32_t VX_ATLAS_CELL = 48; // pixels square: a glyph at up to about 36 pixels to the em

typedef struct vx_atlas_slot {
  uint64_t key; // 0: empty
  uint64_t used;
  int16_t x0, y0; // the bitmap's top left from the pen, in pixels (y down)
  uint8_t w, h;
} vx_atlas_slot;

typedef struct vx_atlas {
  uint32_t cells;
  uint8_t *pixels; // cells of VX_ATLAS_CELL squared bytes
  vx_atlas_slot *slots;
  uint64_t clock;
  uint64_t hits, misses;
} vx_atlas;

[[maybe_unused]] static bool vx_atlas_init(vx_atlas *a, uint32_t cells) {
  *a = (vx_atlas){.cells = cells};
  a->pixels = vx_font_alloc((size_t)cells * VX_ATLAS_CELL * VX_ATLAS_CELL);
  a->slots = vx_font_alloc(cells * sizeof *a->slots);
  if (!a->pixels || !a->slots) return false;
  for (uint32_t i = 0; i < cells; i++) a->slots[i] = (vx_atlas_slot){};
  return true;
}

[[maybe_unused]] static void vx_atlas_free(vx_atlas *a) {
  vx_font_free(a->pixels);
  vx_font_free(a->slots);
  *a = (vx_atlas){};
}

// A glyph's cell: found, or rasterized into the oldest slot. sub is the
// pen's quarter-pixel offset, 0 to 3.
[[maybe_unused]] static const vx_atlas_slot *vx_atlas_get(vx_atlas *a, vx_font *f, uint32_t glyph,
                                                          uint32_t px, uint32_t sub, const uint8_t **bitmap) {
  uint64_t key = (uint64_t)(f->id & 0xffff) << 46 | (uint64_t)(px & 0x3ff) << 36 | (uint64_t)(sub & 3) << 34 |
                 (uint64_t)(glyph & 0xffff) << 2 | 1; // never 0
  uint32_t start = (uint32_t)((key * 0x9e37'79b9'7f4a'7c15ull) >> 40) % a->cells, oldest = start;
  for (uint32_t k = 0; k < a->cells; k++) { // probed in order from its hash; empty ends the search
    uint32_t i = (start + k) % a->cells;
    if (a->slots[i].key == key) {
      a->slots[i].used = ++a->clock, a->hits++;
      *bitmap = a->pixels + (size_t)i * VX_ATLAS_CELL * VX_ATLAS_CELL;
      return &a->slots[i];
    }
    if (!a->slots[i].key) {
      oldest = i;
      break;
    }
    if (a->slots[i].used < a->slots[oldest].used) oldest = i;
  }
  vx_atlas_slot *s = &a->slots[oldest];
  uint8_t *cell = a->pixels + (size_t)oldest * VX_ATLAS_CELL * VX_ATLAS_CELL;
  float scale = stbtt_ScaleForMappingEmToPixels(&f->tt, (float)px), shift = (float)sub / 4;
  int x0, y0, x1, y1;
  stbtt_GetGlyphBitmapBoxSubpixel(&f->tt, (int)glyph, scale, scale, shift, 0, &x0, &y0, &x1, &y1);
  int w = x1 - x0, h = y1 - y0;
  if (w > (int)VX_ATLAS_CELL) w = VX_ATLAS_CELL; // too big for a cell: clipped
  if (h > (int)VX_ATLAS_CELL) h = VX_ATLAS_CELL;
  if (w < 0) w = 0;
  if (h < 0) h = 0;
  for (size_t i = 0; i < (size_t)VX_ATLAS_CELL * VX_ATLAS_CELL; i++) cell[i] = 0;
  if (w && h)
    stbtt_MakeGlyphBitmapSubpixel(&f->tt, cell, w, h, VX_ATLAS_CELL, scale, scale, shift, 0, (int)glyph);
  *s = (vx_atlas_slot){
      .key = key, .used = ++a->clock, .x0 = (int16_t)x0, .y0 = (int16_t)y0, .w = (uint8_t)w, .h = (uint8_t)h};
  a->misses++;
  *bitmap = cell;
  return s;
}

// --- Drawing ---

typedef struct vx_font_target {
  uint32_t *px;                               // XRGB8888
  uint32_t stride;                            // in pixels
  int32_t clip_x0, clip_y0, clip_x1, clip_y1; // what may be drawn, x1 and y1 exclusive
} vx_font_target;

// c over d at coverage a of 255.
static uint32_t vx_font_blend(uint32_t d, uint32_t c, uint32_t a) {
  uint32_t out = 0;
  for (int s = 0; s < 24; s += 8) {
    uint32_t cd = d >> s & 0xff, cc = c >> s & 0xff;
    out |= ((cc * a + cd * (255 - a) + 127) / 255) << s;
  }
  return out;
}

// A rune's glyph in f, unshaped (a terminal's cells); 0, the missing glyph,
// for one it lacks.
[[maybe_unused]] static uint32_t vx_font_glyph(vx_font *f, uint32_t rune) {
  return (uint32_t)stbtt_FindGlyphIndex(&f->tt, (int)rune);
}

// One glyph drawn with its origin at x64 (1/64 pixels) and its baseline at y.
static void vx_glyph_draw(vx_font_target *cv, vx_atlas *a, vx_font *f, uint32_t px, uint32_t glyph,
                          int64_t x64, int32_t y, uint32_t colour) {
  int64_t whole = x64 >= 0 ? x64 / 64 : -((-x64 + 63) / 64);
  uint32_t sub = (uint32_t)((x64 - whole * 64) / 16); // the quarter pixel
  const uint8_t *bm;
  const vx_atlas_slot *s = vx_atlas_get(a, f, glyph, px, sub, &bm);
  int32_t ox = (int32_t)whole + s->x0, oy = y + s->y0;
  for (int32_t r = 0; r < s->h; r++) {
    int32_t yy = oy + r;
    if (yy < cv->clip_y0 || yy >= cv->clip_y1) continue;
    uint32_t *row = &cv->px[(size_t)yy * cv->stride];
    for (int32_t c = 0; c < s->w; c++) {
      int32_t xx = ox + c;
      uint32_t cover = bm[(size_t)r * VX_ATLAS_CELL + (size_t)c];
      if (!cover || xx < cv->clip_x0 || xx >= cv->clip_x1) continue;
      row[xx] = cover == 255 ? colour : vx_font_blend(row[xx], colour, cover);
    }
  }
}

// UTF-8 text drawn with its pen starting at x and its baseline at y, in
// colour, px pixels to the em; the pen's end (its x).
[[maybe_unused]] static int32_t vx_text_draw(vx_font_target *cv, vx_atlas *a, vx_font *f, uint32_t px,
                                             int32_t x, int32_t y, uint32_t colour, const char *text,
                                             size_t len) {
  vx_glyph_at glyphs[256];
  int32_t advance = 0;
  uint32_t n = vx_font_shape(f, text, len, glyphs, 256, &advance);
  int64_t pen64 = (int64_t)x * 64;
  for (uint32_t i = 0; i < n; i++)
    vx_glyph_draw(cv, a, f, px, glyphs[i].glyph, pen64 + vx_font_to64(f, glyphs[i].x, px),
                  y - vx_font_to64(f, glyphs[i].y, px) / 64, colour);
  return x + (int32_t)(vx_font_to64(f, advance, px) / 64);
}
