// font1x: 03's 1x check (M7 step 7e1, docs/21 §2 item 10): small text at
// terminal sizes as vx-font draws it (stb_truetype's rasterizer, ADR-0052)
// against FreeType's, the reference, unhinted and with light hinting (most
// Linux desktops' setting). Each glyph is rasterized by both at the same pen
// position and quarter-pixel offset, and the mean difference in coverage is
// printed for each size; the strings, drawn each way, go to a PPM to look at.
// A host tool, run by hand; FreeType is the host's, never vendored:
//
//   clang -std=c23 -O2 -o out/host/font1x host/font1x/font1x.c ports/font/stbtt.c ports/font/kbts.c \
//     -Iports/font -isystem third_party/stb_truetype -isystem third_party/kb_text_shape \
//     $(pkg-config --cflags --libs freetype2) -lm
//   out/host/font1x third_party/inter/extras/ttf/Inter-Regular.ttf out/host/font1x.ppm

#include <ft2build.h>
#include FT_FREETYPE_H
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../../lib/vx-font/font.c"

static const char SAMPLE[] = "The quick brown fox jumps over the lazy dog 0123456789 (){}[]";
static const uint32_t SIZES[] = {11, 12, 13, 14, 16};
static constexpr int W = 520, LINE = 22, ROWS = 3 * 5;

static uint8_t canvas[ROWS * LINE][W]; // coverage, 0 to 255

static void put(int row, int x0, int y0, const uint8_t *bm, int w, int h, int pitch) {
  for (int y = 0; y < h; y++)
    for (int x = 0; x < w; x++) {
      int cx = x0 + x, cy = row * LINE + y0 + y;
      if (cx < 0 || cx >= W || cy < row * LINE || cy >= (row + 1) * LINE) continue;
      int v = canvas[cy][cx] + bm[y * pitch + x];
      canvas[cy][cx] = (uint8_t)(v > 255 ? 255 : v);
    }
}

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: font1x FONT.ttf OUT.ppm\n");
    return 2;
  }
  FILE *fp = fopen(argv[1], "rb");
  if (!fp) return 1;
  fseek(fp, 0, SEEK_END);
  long n = ftell(fp);
  fseek(fp, 0, SEEK_SET);
  uint8_t *ttf = malloc((size_t)n);
  if (fread(ttf, 1, (size_t)n, fp) != (size_t)n) return 1;
  fclose(fp);
  vx_font f;
  if (!vx_font_init(&f, ttf, (size_t)n, 1)) return 1;
  FT_Library lib;
  FT_Face face;
  if (FT_Init_FreeType(&lib) || FT_New_Memory_Face(lib, ttf, n, 0, &face)) return 1;

  printf("size  vs unhinted  vs light-hinted  (mean |coverage difference|, %% of full)\n");
  for (size_t si = 0; si < sizeof SIZES / sizeof SIZES[0]; si++) {
    uint32_t px = SIZES[si];
    FT_Set_Pixel_Sizes(face, 0, px);
    vx_glyph_at g[128];
    int32_t adv;
    uint32_t count = vx_font_shape(&f, SAMPLE, sizeof SAMPLE - 1, g, 128, &adv);
    double diff[2] = {}, pixels[2] = {};
    for (uint32_t i = 0; i < count; i++) {
      int64_t pen64 = 4 * 64 + vx_font_to64(&f, g[i].x, px);
      int whole = (int)(pen64 / 64), sub = (int)(pen64 % 64 / 16);
      // stb's, through the atlas's cell.
      float scale = stbtt_ScaleForMappingEmToPixels(&f.tt, (float)px);
      int x0, y0, x1, y1;
      stbtt_GetGlyphBitmapBoxSubpixel(&f.tt, (int)g[i].glyph, scale, scale, sub / 4.0f, 0, &x0, &y0, &x1,
                                      &y1);
      int sw = x1 - x0, sh = y1 - y0;
      static uint8_t sbm[64 * 64];
      memset(sbm, 0, sizeof sbm);
      if (sw > 0 && sh > 0 && sw <= 64 && sh <= 64)
        stbtt_MakeGlyphBitmapSubpixel(&f.tt, sbm, sw, sh, 64, scale, scale, sub / 4.0f, 0, (int)g[i].glyph);
      int base = 16;
      put((int)si * 3, whole + x0, base + y0, sbm, sw, sh, 64);
      // FreeType's, unhinted then light-hinted, at the same quarter pixel.
      for (int mode = 0; mode < 2; mode++) {
        FT_Int32 load = mode == 0 ? FT_LOAD_NO_HINTING : FT_LOAD_TARGET_LIGHT;
        FT_Vector delta = {sub * 16, 0};
        FT_Set_Transform(face, nullptr, &delta);
        if (FT_Load_Glyph(face, g[i].glyph, load) || FT_Render_Glyph(face->glyph, FT_RENDER_MODE_NORMAL))
          continue;
        FT_Bitmap *b = &face->glyph->bitmap;
        int fx = whole + face->glyph->bitmap_left, fy = base - face->glyph->bitmap_top;
        put((int)si * 3 + 1 + mode, fx, fy, b->buffer, (int)b->width, (int)b->rows, b->pitch);
        // The difference over the union of the two boxes, both placed on the pen.
        int ux0 = whole + x0 < fx ? whole + x0 : fx, uy0 = base + y0 < fy ? base + y0 : fy;
        int ux1 = whole + x1 > fx + (int)b->width ? whole + x1 : fx + (int)b->width;
        int uy1 = base + y1 > fy + (int)b->rows ? base + y1 : fy + (int)b->rows;
        for (int y = uy0; y < uy1; y++)
          for (int x = ux0; x < ux1; x++) {
            int sx = x - whole - x0, sy = y - base - y0, bx = x - fx, by = y - fy;
            int a = sx >= 0 && sy >= 0 && sx < sw && sy < sh ? sbm[sy * 64 + sx] : 0;
            int c = bx >= 0 && by >= 0 && bx < (int)b->width && by < (int)b->rows
                        ? b->buffer[by * b->pitch + bx]
                        : 0;
            if (a || c) diff[mode] += abs(a - c), pixels[mode]++;
          }
      }
    }
    printf("%4u  %10.1f%%  %14.1f%%\n", px, 100 * diff[0] / (pixels[0] * 255),
           100 * diff[1] / (pixels[1] * 255));
  }
  FILE *out = fopen(argv[2], "wb");
  fprintf(out, "P5 %d %d 255\n", W, ROWS * LINE);
  for (int y = 0; y < ROWS * LINE; y++)
    for (int x = 0; x < W; x++) fputc(255 - canvas[y][x], out);
  fclose(out);
  return 0;
}
