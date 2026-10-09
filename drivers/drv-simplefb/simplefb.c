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
// One thread, one port: the listen channel, the session, and the vblank
// timer as the port's deadline.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-driver/displayproto.h"

enum : uint64_t { KEY_LISTEN = 1, KEY_SESSION = 2 };
static constexpr uint32_t MAX_IMAGES = 8;
static constexpr vx_duration REFRESH_NS = 16'666'667; // 60 Hz
static constexpr uint32_t REFRESH_MHZ = 60'000;

static vx_handle port, listen, session;

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

// The configuration applied, and the one waiting for the next vblank.
static vx_display_apply shown, pending;
static bool have_pending, on = true;
static uint64_t stamp_shown;

[[noreturn]] static void fail(const char *why) {
  vx_printf("simplefb: %s\n", why);
  vx_exits(why);
}

// A CONNECT refused: its reply with the status and no handle.
static void refuse(const vx_msg_header *req, vx_status why) {
  vx_msg_header rep = {.txid = req->txid, .ordinal = req->ordinal, .flags = (uint32_t)(int32_t)why};
  vx_channel_write(listen, &rep, sizeof rep, nullptr, 0);
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

// a ∩ b; its width 0 if they do not meet.
static vx_display_rect intersect(vx_display_rect a, vx_display_rect b) {
  int64_t x0 = a.x > b.x ? a.x : b.x, y0 = a.y > b.y ? a.y : b.y;
  int64_t x1 = (int64_t)a.x + a.width, y1 = (int64_t)a.y + a.height;
  int64_t bx1 = (int64_t)b.x + b.width, by1 = (int64_t)b.y + b.height;
  if (bx1 < x1) x1 = bx1;
  if (by1 < y1) y1 = by1;
  if (x1 <= x0 || y1 <= y0) return (vx_display_rect){};
  return (vx_display_rect){(int32_t)x0, (int32_t)y0, (uint32_t)(x1 - x0), (uint32_t)(y1 - y0)};
}

// The pending configuration onto the screen, its damage only (all of it if none).
static void show(void) {
  const vx_display_apply *a = &pending;
  vx_display_rect screen = {0, 0, (uint32_t)width, (uint32_t)height};
  uint32_t n = a->ndamage ? a->ndamage : 1;
  for (uint32_t d = 0; d < n; d++) {
    vx_display_rect area = a->ndamage ? intersect(a->damage[d], screen) : screen;
    for (uint32_t i = 0; area.width && i < a->cfg.nlayers; i++) {
      vx_display_rect r = intersect(area, a->cfg.layer[i].dst);
      if (r.width) copy_rect(&a->cfg.layer[i], r);
    }
  }
  shown = pending, stamp_shown = pending.stamp, have_pending = false;
}

// CHECK's rules: the firmware's mode, one layer, an image (an imported one,
// the source inside it, no scaling) or a colour, the destination on screen,
// opaque and upright. The layer that fails, or -1 for the mode; -2 for none.
static int64_t check(const vx_display_cfg *c, vx_status *why) {
  *why = VX_ERR_UNSUPPORTED;
  if (c->output != 0 || c->mode.width != width || c->mode.height != height ||
      (c->mode.refresh_mhz && c->mode.refresh_mhz != REFRESH_MHZ))
    return -1;
  if (c->nlayers > 1) return 1;
  for (uint32_t i = 0; i < c->nlayers; i++) {
    const vx_display_layer *l = &c->layer[i];
    const vx_display_rect *d = &l->dst;
    *why = VX_ERR_INVALID;
    if (l->alpha != 255 || l->rotation || d->x < 0 || d->y < 0 || (uint64_t)d->x + d->width > width ||
        (uint64_t)d->y + d->height > height)
      return i;
    if (l->kind == VX_DISPLAY_LAYER_COLOR) continue;
    image *im = l->kind == VX_DISPLAY_LAYER_IMAGE ? image_of(l->image) : nullptr;
    *why = VX_ERR_NOT_FOUND;
    if (!im) return i;
    *why = VX_ERR_INVALID;
    if (l->src.width != d->width || l->src.height != d->height || l->src.x < 0 || l->src.y < 0 ||
        (uint64_t)l->src.x + l->src.width > im->buf.desc.width ||
        (uint64_t)l->src.y + l->src.height > im->buf.desc.height)
      return i;
  }
  *why = VX_OK;
  return -2;
}

static void reply(const vx_msg_header *req, vx_status st, int64_t a0) {
  vx_display_msg r = {.h = {.txid = req->txid, .ordinal = req->ordinal, .flags = (uint32_t)(int32_t)st},
                      .arg = {a0}};
  vx_channel_write(session, &r, sizeof r, nullptr, 0);
}

static void end_session(void) {
  for (uint32_t i = 0; i < MAX_IMAGES; i++)
    if (images[i].used) vx_buffer_unmap(&images[i].buf, images[i].at), vx_buffer_close(&images[i].buf);
  memset(images, 0, sizeof images);
  vx_handle_close(session);
  session = VX_HANDLE_NONE, have_pending = false, on = true;
  memcpy(fb, saved, fb_size); // the firmware's picture, back
}

static void import(const vx_display_import *m, uint32_t len, vx_handle h[2], uint32_t nh) {
  if (nh != 2) {
    for (uint32_t i = 0; i < nh; i++) vx_handle_close(h[i]);
    reply(&m->h, VX_ERR_INVALID, 0);
    return;
  }
  uint32_t i = 0;
  while (i < MAX_IMAGES && images[i].used) i++;
  vx_buffer b;
  vx_status st = vx_buffer_take(&b, &m->desc, len - (uint32_t)sizeof m->h, h);
  if (st == VX_OK && b.desc.format != VX_FORMAT_XRGB8888 && b.desc.format != VX_FORMAT_ARGB8888)
    st = VX_ERR_INVALID, vx_buffer_close(&b);
  if (st == VX_OK && i == MAX_IMAGES) st = VX_ERR_NO_MEMORY, vx_buffer_close(&b);
  uint8_t *at = nullptr;
  if (st == VX_OK && (st = vx_buffer_map(&b, false, &at)) != VX_OK) vx_buffer_close(&b);
  if (st == VX_OK) images[i] = (image){.used = true, .buf = b, .at = at};
  reply(&m->h, st, st == VX_OK ? i + 1 : 0);
}

static void release(const vx_display_msg *m) {
  image *im = image_of((uint64_t)m->arg[0]);
  if (!im) {
    reply(&m->h, VX_ERR_NOT_FOUND, 0);
    return;
  }
  // One on screen stays there: it was copied, so its bytes are not needed.
  vx_buffer_unmap(&im->buf, im->at);
  vx_buffer_close(&im->buf);
  *im = (image){};
  reply(&m->h, VX_OK, 0);
}

static void added(void) {
  vx_display_mode mode = {(uint32_t)width, (uint32_t)height, REFRESH_MHZ, VX_DISPLAY_FIRMWARE};
  vx_display_added a = {.h = {.ordinal = VX_DISPLAY_ADDED}, .output = 0, .preferred = mode, .current = mode};
  vx_channel_write(session, &a, sizeof a, nullptr, 0);
}

// Every message waiting on the session; false once it has gone.
static bool serve(void) {
  static union {
    vx_msg_header h;
    vx_display_msg msg;
    vx_display_import import;
    vx_display_check check;
    vx_display_apply apply;
    vx_display_power power;
    uint8_t bytes[1024];
  } m;
  for (;;) {
    vx_handle h[VX_CHANNEL_MAX_HANDLES];
    vx_msg_size size;
    vx_status st = vx_channel_read(session, &m, sizeof m, h, VX_CHANNEL_MAX_HANDLES, &size);
    if (st == VX_ERR_SHOULD_WAIT) return true;
    if (st != VX_OK) return false; // gone, or a message too large: a protocol error
    uint32_t want = 0;
    switch (m.h.ordinal) {
    case VX_DISPLAY_INFO: want = sizeof m.h; break;
    case VX_DISPLAY_IMPORT: want = sizeof m.import; break;
    case VX_DISPLAY_RELEASE: want = sizeof m.msg; break;
    case VX_DISPLAY_CHECK: want = sizeof m.check; break;
    case VX_DISPLAY_APPLY: want = sizeof m.apply; break;
    case VX_DISPLAY_POWER: want = sizeof m.power; break;
    default: break;
    }
    if (m.h.ordinal != VX_DISPLAY_IMPORT)
      for (uint32_t i = 0; i < size.handles; i++) vx_handle_close(h[i]);
    if (!want || size.bytes != want) {
      if (m.h.ordinal == VX_DISPLAY_IMPORT)
        for (uint32_t i = 0; i < size.handles; i++) vx_handle_close(h[i]);
      if (m.h.ordinal == VX_DISPLAY_APPLY || size.bytes < sizeof m.h) return false;
      reply(&m.h, VX_ERR_INVALID, 0);
      continue;
    }
    vx_status why;
    int64_t bad;
    switch (m.h.ordinal) {
    case VX_DISPLAY_INFO: {
      vx_display_info i = {.h = {.txid = m.h.txid, .ordinal = m.h.ordinal},
                           .version = VX_DISPLAY_VERSION,
                           .outputs = 1,
                           .layers = 1,
                           .nformats = 2,
                           .formats = {VX_FORMAT_XRGB8888, VX_FORMAT_ARGB8888},
                           .align = 4};
      vx_channel_write(session, &i, sizeof i, nullptr, 0);
      break;
    }
    case VX_DISPLAY_IMPORT: import(&m.import, size.bytes, h, size.handles); break;
    case VX_DISPLAY_RELEASE: release(&m.msg); break;
    case VX_DISPLAY_CHECK:
      bad = check(&m.check.cfg, &why);
      reply(&m.h, why, bad == -2 ? 0 : bad);
      break;
    case VX_DISPLAY_APPLY:
      // Stamps rise, and only what CHECK passes is applied: else the session ends.
      if (m.apply.stamp <= (have_pending ? pending.stamp : stamp_shown) ||
          m.apply.ndamage > VX_DISPLAY_DAMAGE || check(&m.apply.cfg, &why) != -2)
        return false;
      pending = m.apply, have_pending = true;
      break;
    case VX_DISPLAY_POWER:
      if (m.power.output != 0) {
        reply(&m.h, VX_ERR_NOT_FOUND, 0);
        break;
      }
      on = m.power.on != 0;
      if (!on) memset(fb + offset, 0, pitch * height);
      reply(&m.h, VX_OK, 0);
      break;
    default: break;
    }
  }
}

static void accept(void) {
  for (;;) {
    vx_msg_header req;
    vx_msg_size size;
    vx_handle junk[VX_CHANNEL_MAX_HANDLES];
    vx_status st = vx_channel_read(listen, &req, sizeof req, junk, VX_CHANNEL_MAX_HANDLES, &size);
    if (st == VX_ERR_SHOULD_WAIT) return;
    if (st == VX_ERR_PEER_CLOSED) fail("the listen channel is gone");
    if (st != VX_OK) continue; // too large: not this protocol's
    for (uint32_t i = 0; i < size.handles; i++) vx_handle_close(junk[i]);
    if (size.bytes != sizeof req || req.ordinal != VX_DISPLAY_CONNECT) {
      refuse(&req, VX_ERR_INVALID);
      continue;
    }
    if (session) {
      refuse(&req, VX_ERR_BAD_STATE);
      continue;
    }
    vx_handle ends[2];
    if (vx_channel_create(0, ends) != VX_OK) {
      refuse(&req, VX_ERR_NO_MEMORY);
      continue;
    }
    vx_msg_header rep = {.txid = req.txid, .ordinal = req.ordinal};
    if (vx_channel_write(listen, &rep, sizeof rep, &ends[1], 1) != VX_OK) {
      vx_handle_close(ends[0]), vx_handle_close(ends[1]);
      continue;
    }
    session = ends[0];
    memcpy(saved, fb, fb_size); // the firmware's picture, to put back
    stamp_shown = 0;
    added();
    vx_port_bind(port, session, VX_TRIGGER_READABLE, KEY_SESSION, 0);
  }
}

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
  listen = vx_spawn_take("listen");
  if (!listen || vx_port_create(0, &port) != VX_OK) fail("no listen channel");
  vx_port_bind(port, listen, VX_TRIGGER_READABLE, KEY_LISTEN, 0);
  vx_printf("simplefb: %llux%llu at 60 Hz, %s\n", (unsigned long long)width, (unsigned long long)height,
            native ? "XRGB8888" : "converted");
  vx_instant next = vx_now() + REFRESH_NS;
  for (;;) {
    vx_packet pk[4];
    int64_t n = vx_port_wait(port, session ? next : VX_INFINITE, REFRESH_NS / 16, pk, 4);
    for (int64_t i = 0; i < n; i++) {
      if (pk[i].key == KEY_LISTEN) {
        accept();
        vx_port_bind(port, listen, VX_TRIGGER_READABLE, KEY_LISTEN, 0);
      } else if (pk[i].key == KEY_SESSION && session) {
        if (serve())
          vx_port_bind(port, session, VX_TRIGGER_READABLE, KEY_SESSION, 0);
        else
          end_session();
      }
    }
    vx_instant now = vx_now();
    if (!session) {
      next = now + REFRESH_NS;
      continue;
    }
    if (now < next) continue;
    // A vblank: what is pending goes on screen, and displayd is told.
    if (have_pending && on) show();
    while (next <= now) next += REFRESH_NS;
    if (on) {
      vx_display_vblank v = {
          .h = {.ordinal = VX_DISPLAY_VBLANK}, .output = 0, .time = (uint64_t)now, .stamp = stamp_shown};
      vx_channel_write(session, &v, sizeof v, nullptr, 0);
    }
  }
}
