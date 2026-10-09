// wmtest: three windows under wm (M7 step 7d2c, the wm scenario). Its
// manifest's /wsys is the first; the second and third are mounted at /n and
// /home. Each draws itself in its colour at every CONFIGURE's size, so wm's
// tiling shows; it notes the keys it is given, which must never be the bound
// ones (super+t, super+j, super+q: winsrv takes them in its input path), and
// says when one's channel closes (super+q).

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-ns/nsapi.c"
#include "../../lib/vx-wsys/wsysproto.h"

static uint32_t checks, failures;

static void check_at(bool ok, const char *what, int line) {
  checks++;
  if (ok) return;
  failures++;
  vx_printf("wmtest: FAILED line %d: %s\n", line, what);
}

#define CHECK(cond) check_at((cond), #cond, __LINE__)

typedef struct win {
  vx_handle ch;
  uint32_t colour;
  vx_wsys_configure cfg;
  uint64_t drawn_seq;           // the configure its last present was drawn for
  uint32_t credits, buffer, id; // id: the next buffer id, 1 to 4 in turn
  vx_buffer b[2];
  bool closed, focused;
  uint32_t bound_keys; // keys of a binding it was given: never
} win;

static win wins[3];

static uint32_t K(uint32_t id) { return VX_HID_KEYBOARD | id; }

// A buffer the configure's size, in the window's colour, attached and presented.
static void draw(win *w) {
  if (!w->credits || w->drawn_seq == w->cfg.seq) return;
  vx_buffer *b = &w->b[w->buffer];
  if (b->memory) { // the last one this slot held: detached, and let go
    vx_wsys_detach d = {.h = {.ordinal = VX_WSYS_DETACH}, .id = w->buffer + 1};
    vx_wsys_reply r = {};
    vx_call c = {.wr_bytes = &d, .wr_len = sizeof d, .rd_bytes = &r, .rd_cap = sizeof r};
    vx_channel_call(w->ch, &c, vx_now() + 5'000'000'000);
    vx_buffer_close(b);
  }
  uint8_t *px = nullptr;
  if (vx_buffer_alloc(b, w->cfg.pwidth, w->cfg.pheight, VX_FORMAT_XRGB8888) != VX_OK ||
      vx_buffer_map(b, true, &px) != VX_OK)
    return;
  for (uint32_t y = 0; y < w->cfg.pheight; y++)
    for (uint32_t x = 0; x < w->cfg.pwidth; x++)
      ((uint32_t *)(px + (size_t)y * b->desc.plane[0].stride))[x] = w->colour;
  vx_buffer_unmap(b, px);
  vx_wsys_attach at = {.h = {.ordinal = VX_WSYS_ATTACH}, .id = w->buffer + 1};
  vx_handle h[2];
  if (vx_buffer_put(b, false, &at.desc, h) != VX_OK) return;
  vx_wsys_reply r = {};
  vx_call c = {.wr_bytes = &at,
               .wr_handles = h,
               .wr_len = sizeof at,
               .wr_count = 2,
               .rd_bytes = &r,
               .rd_cap = sizeof r};
  if (vx_channel_call(w->ch, &c, vx_now() + 5'000'000'000) != VX_OK || r.h.flags) return;
  vx_buffer_signal(b, 1);
  vx_wsys_present p = {.h = {.ordinal = VX_WSYS_PRESENT},
                       .seq = w->cfg.seq,
                       .id = w->buffer + 1,
                       .acquire = 1,
                       .release = 2,
                       .config_seq = w->cfg.seq};
  vx_channel_write(w->ch, &p, sizeof p, nullptr, 0);
  w->credits--, w->drawn_seq = w->cfg.seq, w->buffer ^= 1;
}

static void serve(win *w) {
  for (;;) {
    alignas(vx_wsys_configure) uint8_t m[256];
    vx_msg_size size;
    vx_status st = vx_channel_read(w->ch, m, sizeof m, nullptr, 0, &size);
    if (st == VX_ERR_PEER_CLOSED && !w->closed) {
      static const char *const AT[3] = {"/wsys", "/n", "/home"};
      w->closed = true;
      vx_printf("wmtest: window %u closed\n", (unsigned)(w - wins) + 1);
      vx_handle_close(w->ch);
      CHECK(vx_unmount(VX_STR(""), vx_cstr(AT[w - wins])) == VX_OK); // its last fid: the window goes
    }
    if (st != VX_OK) break;
    const vx_msg_header *hd = (const vx_msg_header *)m;
    if (hd->ordinal == VX_WSYS_CONFIGURE && size.bytes == sizeof(vx_wsys_configure)) {
      memcpy(&w->cfg, m, sizeof w->cfg);
      w->focused = w->cfg.flags & VX_WSYS_FOCUSED;
    } else if (hd->ordinal == VX_WSYS_FRAME && size.bytes == sizeof(vx_wsys_frame)) {
      w->credits += ((const vx_wsys_frame *)m)->credits;
    } else if (hd->ordinal == VX_WSYS_KEY && size.bytes == sizeof(vx_wsys_key)) {
      uint32_t u = ((const vx_wsys_key *)m)->key.usage;
      if (u == K(0x17) || u == K(0x0d) || u == K(0x14)) w->bound_keys++; // t, j, q
    }
  }
  if (!w->closed) draw(w);
}

const char *vx_main(void) {
  static const char *const SURFACES[3] = {"/wsys/surface", "/n/surface", "/home/surface"};
  static const uint32_t COLOURS[3] = {0x3f6fb0, 0xb0603f, 0x4f9f4f};
  CHECK(vx_mount(VX_STR("/srv/wsys"), VX_STR("new -dx 300 -dy 200"), VX_STR("/n"), 0) == VX_OK);
  CHECK(vx_mount(VX_STR("/srv/wsys"), VX_STR("new -dx 300 -dy 200"), VX_STR("/home"), 0) == VX_OK);
  for (int i = 0; i < 3; i++) {
    wins[i].colour = COLOURS[i];
    CHECK(vx_ns_open_post(vx_ns_process(), vx_cstr(SURFACES[i]), &wins[i].ch) == VX_OK);
  }
  vx_print(VX_STR("wmtest: 3 windows\n"));
  bool tiled = false, said_two = false;
  for (;;) {
    vx_handle port;
    vx_packet pk;
    vx_port_create(0, &port);
    for (int i = 0; i < 3; i++)
      if (!wins[i].closed) vx_port_bind(port, wins[i].ch, VX_TRIGGER_READABLE, (uint64_t)i, 0);
    vx_port_wait(port, vx_now() + 100'000'000, 0, &pk, 1);
    vx_handle_close(port);
    for (int i = 0; i < 3; i++) serve(&wins[i]);
    // Tiled: each drawn for a configure past its first, wm's.
    if (!tiled && wins[0].drawn_seq > 1 && wins[1].drawn_seq > 1 && wins[2].drawn_seq > 1) {
      tiled = true;
      CHECK(wins[0].cfg.pheight > wins[1].cfg.pheight); // the master is the full height, the stack's halves
      vx_printf("wmtest: tiled, the master %ux%u\n", wins[0].cfg.pwidth, wins[0].cfg.pheight);
    }
    uint32_t open = 0, bound = 0;
    for (int i = 0; i < 3; i++) open += !wins[i].closed, bound += wins[i].bound_keys;
    if (!said_two && open == 2) {
      said_two = true;
      CHECK(bound == 0); // no window ever saw a bound key
      vx_printf("wmtest: %u checks, %u failed\n", checks, failures);
    }
  }
}
