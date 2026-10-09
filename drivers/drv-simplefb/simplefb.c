// drv-simplefb: the display engine protocol's first back end (M7 step 7b3,
// docs/proto/display.md, ADR-0026): the framebuffer the firmware left (x86's
// GOP, aarch64's ramfb), handed on by svcd as a physical VMO and mapped
// write-combining (ADR-0051). It has one output in the firmware's mode and
// one layer, and it copies: an APPLY's image is copied into the framebuffer
// at the next vblank, its damage only. A framebuffer has no vblank, so it is
// a timer at the output's refresh (60 Hz: a GOP does not say).
//
// It adopts what the firmware left (ADR-0026 item 3): the screen is saved
// when a session opens and put back when it ends, so a displayd that dies
// leaves the boot console showing, as it found it.
//
// The session and the vblank are lib/vx-driver/engine.c's.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-driver/engine.c"

static constexpr uint32_t MAX_IMAGES = 8;

// The framebuffer: its pixels at fb + offset, rows pitch bytes apart, and
// each channel's field (shift << 8 | size) from the firmware's record.
static uint8_t *fb, *saved;
static uint64_t offset, width, height, pitch, red, green, blue, fb_size;
static bool native; // 32 bits, red at 16, green at 8, blue at 0: rows copy as they are

typedef struct image {
  bool used;
  vx_buffer buf;
  uint8_t *at;
} image;
static image images[MAX_IMAGES];

[[noreturn]] static void fail(const char *why) {
  vx_printf("simplefb: %s\n", why);
  vx_exits(why);
}

static uint32_t channel(uint64_t field, uint32_t v) {
  uint32_t size = (uint32_t)(field & 0xff), shift = (uint32_t)(field >> 8 & 0xff);
  return size ? (v >> (8 - (size < 8 ? size : 8))) << shift : 0;
}

static uint32_t convert(uint32_t xrgb) {
  return channel(red, xrgb >> 16 & 0xff) | channel(green, xrgb >> 8 & 0xff) | channel(blue, xrgb & 0xff);
}

static uint32_t *fb_row(uint64_t y) { return (uint32_t *)(fb + offset + y * pitch); }

static image *image_of(uint64_t id) {
  return id && id <= MAX_IMAGES && images[id - 1].used ? &images[id - 1] : nullptr;
}

// One rectangle of a layer onto the screen: r is in the screen's coordinates,
// inside the layer's destination.
static void copy_rect(const vx_display_layer *l, vx_display_rect r) {
  if (l->kind == VX_DISPLAY_LAYER_COLOR) {
    uint32_t c = convert(l->color);
    for (uint32_t y = 0; y < r.height; y++) {
      uint32_t *to = fb_row((uint64_t)r.y + y) + r.x;
      for (uint32_t x = 0; x < r.width; x++) to[x] = c;
    }
    return;
  }
  image *im = image_of(l->image);
  if (!im) return;
  const vx_buffer_plane *p = &im->buf.desc.plane[0];
  for (uint32_t y = 0; y < r.height; y++) {
    uint64_t sy = (uint64_t)l->src.y + (uint64_t)(r.y - l->dst.y) + y,
             sx = (uint64_t)l->src.x + (uint64_t)(r.x - l->dst.x);
    const uint32_t *from = (const uint32_t *)(im->at + p->offset + sy * p->stride) + sx;
    uint32_t *to = fb_row((uint64_t)r.y + y) + r.x;
    if (native) {
      memcpy(to, from, (size_t)r.width * 4);
    } else {
      for (uint32_t x = 0; x < r.width; x++) to[x] = convert(from[x]);
    }
  }
}

// --- The engine's operations ---

static void fb_info(vx_display_info *i) {
  i->nformats = 2;
  i->formats[0] = VX_FORMAT_XRGB8888, i->formats[1] = VX_FORMAT_ARGB8888;
  i->align = 4;
}

static int64_t fb_import(vx_buffer *b) {
  if (b->desc.format != VX_FORMAT_XRGB8888 && b->desc.format != VX_FORMAT_ARGB8888) return VX_ERR_INVALID;
  uint32_t i = 0;
  while (i < MAX_IMAGES && images[i].used) i++;
  if (i == MAX_IMAGES) return VX_ERR_NO_MEMORY;
  uint8_t *at = nullptr;
  vx_status st = vx_buffer_map(b, false, &at);
  if (st != VX_OK) return st;
  images[i] = (image){.used = true, .buf = *b, .at = at};
  return i + 1;
}

// One on screen stays there: it was copied, so its bytes are not needed.
static vx_status fb_release(uint64_t id) {
  image *im = image_of(id);
  if (!im) return VX_ERR_NOT_FOUND;
  vx_buffer_unmap(&im->buf, im->at);
  vx_buffer_close(&im->buf);
  *im = (image){};
  return VX_OK;
}

// The firmware's mode, one layer, an image (an imported one, the source
// inside it, no scaling) or a colour, the destination on screen, opaque and
// upright.
static int64_t fb_check(const vx_display_cfg *c, vx_status *why) {
  *why = VX_ERR_UNSUPPORTED;
  if (c->output != 0 || c->mode.width != width || c->mode.height != height ||
      (c->mode.refresh_mhz && c->mode.refresh_mhz != 60'000))
    return -1;
  if (c->nlayers > 1) return 1;
  for (uint32_t i = 0; i < c->nlayers; i++) {
    const vx_display_layer *l = &c->layer[i];
    *why = VX_ERR_INVALID;
    if (l->alpha != 255 || l->rotation || !vx_display_inside(l->dst, width, height)) return i;
    if (l->kind == VX_DISPLAY_LAYER_COLOR) continue;
    image *im = l->kind == VX_DISPLAY_LAYER_IMAGE ? image_of(l->image) : nullptr;
    *why = VX_ERR_NOT_FOUND;
    if (!im) return i;
    *why = VX_ERR_INVALID;
    if (l->src.width != l->dst.width || l->src.height != l->dst.height ||
        !vx_display_inside(l->src, im->buf.desc.width, im->buf.desc.height))
      return i;
  }
  *why = VX_OK;
  return -2;
}

// Its damage only (all of it if none).
static void fb_show(const vx_display_apply *a) {
  vx_display_rect screen = {0, 0, (uint32_t)width, (uint32_t)height};
  uint32_t n = a->ndamage ? a->ndamage : 1;
  for (uint32_t d = 0; d < n; d++) {
    vx_display_rect area = a->ndamage ? vx_display_intersect(a->damage[d], screen) : screen;
    for (uint32_t i = 0; area.width && i < a->cfg.nlayers; i++) {
      vx_display_rect r = vx_display_intersect(area, a->cfg.layer[i].dst);
      if (r.width) copy_rect(&a->cfg.layer[i], r);
    }
  }
}

static vx_status fb_power(bool on) {
  if (!on) memset(fb + offset, 0, pitch * height);
  return VX_OK;
}

static void fb_opened(void) { memcpy(saved, fb, fb_size); } // the firmware's picture, to put back

static void fb_closed(void) {
  for (uint32_t i = 0; i < MAX_IMAGES; i++)
    if (images[i].used) fb_release(i + 1);
  memcpy(fb, saved, fb_size); // the firmware's picture, back
}

static const vx_engine_ops OPS = {.info = fb_info,
                                  .import = fb_import,
                                  .release = fb_release,
                                  .check = fb_check,
                                  .show = fb_show,
                                  .power = fb_power,
                                  .opened = fb_opened,
                                  .closed = fb_closed};

const char *vx_main(void) {
  vx_handle vmo = vx_spawn_take("framebuffer");
  vx_ndb_record rec;
  uint64_t bpp = 0;
  if (!vmo || !vx_spawn_record("framebuffer", &rec) || !vx_ndb_get_u64(&rec, "offset", &offset) ||
      !vx_ndb_get_u64(&rec, "width", &width) || !vx_ndb_get_u64(&rec, "height", &height) ||
      !vx_ndb_get_u64(&rec, "pitch", &pitch) || !vx_ndb_get_u64(&rec, "bpp", &bpp) ||
      !vx_ndb_get_u64(&rec, "red", &red) || !vx_ndb_get_u64(&rec, "green", &green) ||
      !vx_ndb_get_u64(&rec, "blue", &blue))
    fail("no framebuffer");
  if (bpp != 32 || !width || !height || pitch < width * 4) fail("a framebuffer it cannot draw (not 32 bits)");
  native = red == (16 << 8 | 8) && green == (8 << 8 | 8) && blue == 8;
  fb_size = offset + pitch * height;
  uint64_t map = (fb_size + 4095) & ~4095ull, at = 0;
  if (vx_vmo_cache(vmo, VX_CACHE_WC) != VX_OK || vx_as_map(vx_self, vmo, 0, map, VX_MAP_WRITE, &at) != VX_OK)
    fail("cannot map the framebuffer");
  fb = (uint8_t *)at;
  vx_handle copy;
  uint64_t sat = 0;
  if (vx_vmo_create(map, VX_VMO_LAZY, &copy) != VX_OK ||
      vx_as_map(vx_self, copy, 0, map, VX_MAP_WRITE, &sat) != VX_OK)
    fail("no memory for the saved screen");
  saved = (uint8_t *)sat;
  static vx_engine e = {.ops = &OPS, .name = "simplefb"};
  e.listen = vx_spawn_take("listen");
  if (!e.listen) fail("no listen channel");
  // A firmware's framebuffer gives no refresh: 60 Hz.
  e.mode = (vx_display_mode){(uint32_t)width, (uint32_t)height, 60'000, VX_DISPLAY_FIRMWARE};
  vx_printf("simplefb: %llux%llu at 60 Hz, %s\n", (unsigned long long)width, (unsigned long long)height,
            native ? "XRGB8888" : "converted");
  vx_engine_serve(&e);
}
