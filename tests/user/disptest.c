// disptest: the display engine protocol against a back end (M7 step 7b3, the
// engine scenario; docs/proto/display.md): a session and a second one
// refused, ADDED with the firmware's mode, INFO, IMPORT and its refusals,
// CHECK's verdicts, APPLY and the VBLANKs that report it, and RELEASE. It
// leaves colour bars on screen with a white box drawn by a second APPLY
// whose damage is the box alone: the second image also has a red square
// outside the damage, which a back end that copies the damage only never
// shows. The scenario matches that by screenshot. Written for simplefb; the
// same test runs on virtio-gpu (7b4).

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-driver/displayproto.h"

static uint32_t checks, failures;

static void check_at(bool ok, const char *what, int line) {
  checks++;
  if (ok) return;
  failures++;
  vx_printf("disptest: FAILED line %d: %s\n", line, what);
}

#define CHECK(cond) check_at((cond), #cond, __LINE__)

static vx_handle session;

static vx_status call(void *req, uint32_t len, const vx_handle *h, uint32_t nh, void *rep, uint32_t cap) {
  vx_call c = {
      .wr_bytes = req, .wr_handles = h, .wr_len = len, .wr_count = nh, .rd_bytes = rep, .rd_cap = cap};
  vx_status st = vx_channel_call(session, &c, vx_now() + 5'000'000'000);
  return st == VX_OK ? (vx_status)(int32_t)((vx_msg_header *)rep)->flags : st;
}

// The next event with this ordinal, the others before it dropped; false at the deadline.
static bool event(uint32_t ordinal, void *out, uint32_t len) {
  vx_instant deadline = vx_now() + 5'000'000'000;
  for (;;) {
    uint8_t m[256];
    vx_msg_size size;
    vx_status st = vx_channel_read(session, m, sizeof m, nullptr, 0, &size);
    if (st == VX_OK && ((vx_msg_header *)m)->ordinal == ordinal && size.bytes == len) {
      memcpy(out, m, len);
      return true;
    }
    if (st == VX_OK) continue;
    if (st != VX_ERR_SHOULD_WAIT || vx_now() > deadline) return false;
    vx_handle port;
    vx_packet pk;
    vx_port_create(0, &port);
    vx_port_bind(port, session, VX_TRIGGER_READABLE, 1, 0);
    vx_port_wait(port, deadline, 0, &pk, 1);
    vx_handle_close(port);
  }
}

// VBLANKs until one reports stamp, or one later.
static bool until(vx_display_vblank *v, uint64_t stamp) {
  bool ok;
  do ok = event(VX_DISPLAY_VBLANK, v, sizeof *v);
  while (ok && v->stamp < stamp);
  return ok && v->stamp == stamp;
}

static int64_t import(const vx_buffer *b, vx_buffer_desc *lie) {
  vx_display_import m = {.h = {.ordinal = VX_DISPLAY_IMPORT}};
  vx_handle h[2];
  if (vx_buffer_put(b, false, &m.desc, h) != VX_OK) return VX_ERR_NO_MEMORY;
  if (lie) m.desc = *lie;
  vx_display_msg r = {};
  vx_status st = call(&m, sizeof m, h, 2, &r, sizeof r);
  return st == VX_OK ? r.arg[0] : st;
}

static uint32_t *row(uint8_t *px, const vx_buffer *b, uint32_t y) {
  return (uint32_t *)(px + (size_t)y * b->desc.plane[0].stride);
}

// Eight bars: white, yellow, cyan, green, magenta, red, blue, black.
static void bars(uint8_t *px, const vx_buffer *b) {
  static const uint32_t BARS[8] = {0xffffff, 0xffff00, 0x00ffff, 0x00ff00,
                                   0xff00ff, 0xff0000, 0x0000ff, 0x000000};
  for (uint32_t y = 0; y < b->desc.height; y++)
    for (uint32_t x = 0; x < b->desc.width; x++) row(px, b, y)[x] = BARS[(uint64_t)x * 8 / b->desc.width];
}

static void fill(uint8_t *px, const vx_buffer *b, vx_display_rect r, uint32_t c) {
  for (uint32_t y = 0; y < r.height; y++)
    for (uint32_t x = 0; x < r.width; x++) row(px, b, (uint32_t)r.y + y)[(uint32_t)r.x + x] = c;
}

static vx_display_cfg config(vx_display_mode mode, uint64_t image) {
  vx_display_rect all = {0, 0, mode.width, mode.height};
  return (vx_display_cfg){
      .output = 0,
      .nlayers = 1,
      .mode = mode,
      .layer = {{.kind = VX_DISPLAY_LAYER_IMAGE, .image = image, .src = all, .dst = all, .alpha = 255}}};
}

static vx_status check_cfg(const vx_display_cfg *c, int64_t *bad) {
  vx_display_check m = {.h = {.ordinal = VX_DISPLAY_CHECK}, .cfg = *c};
  vx_display_msg r = {};
  vx_status st = call(&m, sizeof m, nullptr, 0, &r, sizeof r);
  *bad = r.arg[0];
  return st;
}

const char *vx_main(void) {
  vx_handle srv = vx_spawn_take("srv:simplefb");
  CHECK(srv != VX_HANDLE_NONE);
  // A session; a second while it is open, refused.
  vx_msg_header req = {.ordinal = VX_DISPLAY_CONNECT}, rep = {};
  vx_handle got = VX_HANDLE_NONE;
  vx_call c = {.wr_bytes = &req,
               .wr_len = sizeof req,
               .rd_bytes = &rep,
               .rd_cap = sizeof rep,
               .rd_handles = &got,
               .rd_count_cap = 1};
  CHECK(vx_channel_call(srv, &c, vx_now() + 5'000'000'000) == VX_OK && rep.flags == 0 && got);
  session = got;
  c.actual = (vx_msg_size){}, got = VX_HANDLE_NONE;
  CHECK(vx_channel_call(srv, &c, vx_now() + 5'000'000'000) == VX_OK &&
        (int32_t)rep.flags == VX_ERR_BAD_STATE && !got);

  // ADDED: the firmware's mode.
  vx_display_added added = {};
  CHECK(event(VX_DISPLAY_ADDED, &added, sizeof added));
  vx_display_mode mode = added.current;
  CHECK(mode.width && mode.height && mode.flags & VX_DISPLAY_FIRMWARE && mode.refresh_mhz);
  CHECK(added.edid_len == 0); // a framebuffer has none

  vx_display_info info = {};
  vx_msg_header ask = {.ordinal = VX_DISPLAY_INFO};
  CHECK(call(&ask, sizeof ask, nullptr, 0, &info, sizeof info) == VX_OK);
  CHECK(info.version == VX_DISPLAY_VERSION && info.outputs == 1 && info.layers >= 1);
  bool xrgb = false;
  for (uint32_t i = 0; i < info.nformats && i < VX_DISPLAY_FORMATS; i++)
    xrgb |= info.formats[i] == VX_FORMAT_XRGB8888;
  CHECK(xrgb);

  // Two images the screen's size: bars, and bars with the box and the red square.
  vx_buffer a, b;
  CHECK(vx_buffer_alloc(&a, mode.width, mode.height, VX_FORMAT_XRGB8888) == VX_OK);
  CHECK(vx_buffer_alloc(&b, mode.width, mode.height, VX_FORMAT_XRGB8888) == VX_OK);
  vx_display_rect box = {(int32_t)mode.width / 4, (int32_t)mode.height / 4, mode.width / 2, mode.height / 2};
  vx_display_rect red = {0, 0, mode.width / 8, mode.height / 8};
  uint8_t *pa = nullptr, *pb = nullptr;
  CHECK(vx_buffer_map(&a, true, &pa) == VX_OK && vx_buffer_map(&b, true, &pb) == VX_OK);
  if (pa && pb) {
    bars(pa, &a), bars(pb, &b);
    fill(pb, &b, box, 0xffffff);
    fill(pb, &b, red, 0xff0000);
  }

  // IMPORT's refusals: a descriptor past its VMO, a format it has not.
  vx_buffer_desc lie = a.desc;
  lie.height += 64, lie.size += 64ull * lie.plane[0].stride + 1'000'000;
  CHECK(import(&a, &lie) == VX_ERR_RANGE);
  lie = vx_buffer_layout(mode.width, mode.height, VX_FORMAT_RGB565);
  CHECK(import(&a, &lie) == VX_ERR_INVALID);
  int64_t ia = import(&a, nullptr), ib = import(&b, nullptr);
  CHECK(ia > 0 && ib > 0 && ia != ib);

  // CHECK: the wrong mode, a scaled layer, an image never imported; then yes.
  int64_t bad = 0;
  vx_display_cfg cfg = config(mode, (uint64_t)ia);
  cfg.mode.width++;
  CHECK(check_cfg(&cfg, &bad) != VX_OK && bad == -1);
  cfg = config(mode, (uint64_t)ia);
  cfg.layer[0].src.width /= 2;
  CHECK(check_cfg(&cfg, &bad) != VX_OK && bad == 0);
  cfg = config(mode, 999);
  CHECK(check_cfg(&cfg, &bad) == VX_ERR_NOT_FOUND && bad == 0);
  cfg = config(mode, (uint64_t)ia);
  CHECK(check_cfg(&cfg, &bad) == VX_OK);

  // APPLY the bars; the vblanks that follow report stamp 1, a refresh apart.
  vx_display_apply ap = {.h = {.ordinal = VX_DISPLAY_APPLY}, .stamp = 1, .cfg = cfg};
  CHECK(vx_channel_write(session, &ap, sizeof ap, nullptr, 0) == VX_OK);
  vx_display_vblank v = {};
  CHECK(until(&v, 1));
  uint64_t first = v.time;
  for (int i = 0; i < 10; i++) CHECK(event(VX_DISPLAY_VBLANK, &v, sizeof v) && v.stamp == 1);
  uint64_t period = (v.time - first) / 10, want = 1'000'000'000'000ull / mode.refresh_mhz;
  CHECK(period > want / 2 && period < want * 3); // loose: an emulator's timers lag
  // A flip to the second image, its damage the box: no new CHECK.
  ap.stamp = 2, ap.cfg = config(mode, (uint64_t)ib), ap.ndamage = 1, ap.damage[0] = box;
  CHECK(vx_channel_write(session, &ap, sizeof ap, nullptr, 0) == VX_OK);
  CHECK(until(&v, 2));

  // RELEASE: the first image; twice is not found.
  vx_display_msg rel = {.h = {.ordinal = VX_DISPLAY_RELEASE}, .arg = {ia}}, r = {};
  CHECK(call(&rel, sizeof rel, nullptr, 0, &r, sizeof r) == VX_OK);
  CHECK(call(&rel, sizeof rel, nullptr, 0, &r, sizeof r) == VX_ERR_NOT_FOUND);

  vx_printf("disptest: %ux%u at %u mHz, vblank every %llu us\n", mode.width, mode.height, mode.refresh_mhz,
            (unsigned long long)period / 1000);
  vx_printf("disptest: %u checks, %u failed\n", checks, failures);
  // The session stays open, so the screen stays as it was drawn.
  vx_printf("disptest: holding the screen\n");
  vx_handle port;
  vx_packet pk;
  vx_port_create(0, &port);
  vx_port_wait(port, VX_INFINITE, 0, &pk, 1);
  return nullptr;
}
