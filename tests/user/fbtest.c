// fbtest: the boot framebuffer as a physical VMO, mapped write-combining
// (ADR-0051, M7 step 7b1c; the fb scenario's): its cache policy set before
// its first mapping and refused after, then eight colour bars drawn across
// it from its channels' masks, which the scenario matches by screenshot.

#include "../../lib/vx-rt/rt.c"

static uint32_t checks, failures;

static void check_at(bool ok, const char *what, int line) {
  checks++;
  if (ok) return;
  failures++;
  vx_printf("fbtest: FAILED line %d: %s\n", line, what);
}

#define CHECK(cond) check_at((cond), #cond, __LINE__)

// A channel's field: an 8-bit value scaled to its size, at its shift (shift << 8 | size).
static uint32_t channel(uint64_t field, uint8_t v) {
  uint32_t size = (uint32_t)(field & 0xff), shift = (uint32_t)(field >> 8 & 0xff);
  return size ? (uint32_t)(v >> (8 - (size < 8 ? size : 8))) << shift : 0;
}

const char *vx_main(void) {
  vx_handle fb = vx_spawn_take("framebuffer");
  vx_ndb_record rec;
  uint64_t offset = 0, width = 0, height = 0, pitch = 0, bpp = 0, red = 0, green = 0, blue = 0;
  bool have = fb && vx_spawn_record("framebuffer", &rec) && vx_ndb_get_u64(&rec, "offset", &offset) &&
              vx_ndb_get_u64(&rec, "width", &width) && vx_ndb_get_u64(&rec, "height", &height) &&
              vx_ndb_get_u64(&rec, "pitch", &pitch) && vx_ndb_get_u64(&rec, "bpp", &bpp) &&
              vx_ndb_get_u64(&rec, "red", &red) && vx_ndb_get_u64(&rec, "green", &green) &&
              vx_ndb_get_u64(&rec, "blue", &blue);
  CHECK(have && bpp == 32 && width && height && pitch >= width * 4);
  if (!have) {
    vx_printf("fbtest: %u checks, %u failed\n", checks, failures);
    return "no framebuffer";
  }
  uint64_t size = (offset + pitch * height + 4095) & ~4095ull, at = 0;
  CHECK(vx_vmo_cache(fb, VX_CACHE_WC) == VX_OK); // before its first mapping
  CHECK(vx_as_map(vx_self, fb, 0, size, VX_MAP_WRITE, &at) == VX_OK && at);
  CHECK(vx_vmo_cache(fb, VX_CACHE_DEVICE) == VX_ERR_BAD_STATE); // mapped: fixed
  // Eight bars: white, yellow, cyan, green, magenta, red, blue, black.
  static const uint8_t BARS[8][3] = {{255, 255, 255}, {255, 255, 0}, {0, 255, 255}, {0, 255, 0},
                                     {255, 0, 255},   {255, 0, 0},   {0, 0, 255},   {0, 0, 0}};
  for (uint64_t y = 0; at && y < height; y++) {
    uint32_t *row = (uint32_t *)(at + offset + y * pitch);
    for (uint64_t x = 0; x < width; x++) {
      const uint8_t *c = BARS[x * 8 / width];
      row[x] = channel(red, c[0]) | channel(green, c[1]) | channel(blue, c[2]);
    }
  }
  vx_printf("fbtest: bars on %llux%llu\n", (unsigned long long)width, (unsigned long long)height);
  vx_printf("fbtest: %u checks, %u failed\n", checks, failures);
  return failures ? "failed" : nullptr;
}
