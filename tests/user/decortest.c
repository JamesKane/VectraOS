// decortest: winsrv's decorations (M7 step 7d2a, the decor scenario). Two
// windows, A (300 by 200, client area at 60,60: its manifest's /wsys) and B
// (300 by 200 at 460,60, mounted at /n). The scenario clicks A, drags its
// title (A moves; the app sees none of the drag), drags its frame's corner
// (A is resized: a CONFIGURE), switches the theme from rc, and clicks B's
// close gadget (B's channel closes). Each milestone is a line; winsrv's moves
// send no record, so A's position is read from its info as it changes.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-ns/nsapi.c"
#include "../../lib/vx-wsys/wsysproto.h"

static uint32_t checks, failures;

static void check_at(bool ok, const char *what, int line) {
  checks++;
  if (ok) return;
  failures++;
  vx_printf("decortest: FAILED line %d: %s\n", line, what);
}

#define CHECK(cond) check_at((cond), #cond, __LINE__)

typedef struct win {
  vx_handle ch;
  vx_wsys_configure cfg;
  vx_buffer b;
  uint8_t *px;
  bool focused, closed;
  uint32_t pointers; // records with a button held, since the count was last reset
  uint32_t buttons;  // held, as its last pointer record said
  bool released;     // the last record had none held
} win;

static win a, b;

static void ctl(const char *path, const char *cmd) {
  vx_fd fd = vx_open(vx_cstr(path), VX_OWRITE);
  CHECK(fd >= 0 && vx_write(fd, vx_cstr(cmd)) > 0);
  if (fd >= 0) vx_close(fd);
}

static void on_record(win *w, const uint8_t *m, uint32_t len) {
  const vx_msg_header *h = (const vx_msg_header *)m;
  if (h->ordinal == VX_WSYS_CONFIGURE && len == sizeof(vx_wsys_configure)) {
    memcpy(&w->cfg, m, sizeof w->cfg);
    w->focused = w->cfg.flags & VX_WSYS_FOCUSED;
  } else if (h->ordinal == VX_WSYS_POINTER && len == sizeof(vx_wsys_pointer)) {
    w->buttons = ((const vx_wsys_pointer *)m)->buttons, w->released = !w->buttons;
    if (w->buttons) w->pointers++; // a drag's would hold the button
  }
}

// Every record waiting on w's channel; its end noted.
static void drain(win *w) {
  for (;;) {
    alignas(vx_wsys_configure) uint8_t m[256];
    vx_msg_size size;
    vx_status st = vx_channel_read(w->ch, m, sizeof m, nullptr, 0, &size);
    if (st == VX_ERR_PEER_CLOSED) w->closed = true;
    if (st != VX_OK) return;
    on_record(w, m, size.bytes);
  }
}

// A window's channel, its CONFIGURE, and one present of colour.
static bool open_window(win *w, const char *surface, uint32_t colour) {
  if (vx_ns_open_post(vx_ns_process(), vx_cstr(surface), &w->ch) != VX_OK) return false;
  for (vx_instant deadline = vx_now() + 5'000'000'000; !w->cfg.seq && vx_now() < deadline;) {
    drain(w);
    vx_handle port;
    vx_packet pk;
    vx_port_create(0, &port);
    vx_port_bind(port, w->ch, VX_TRIGGER_READABLE, 1, 0);
    vx_port_wait(port, vx_now() + 100'000'000, 0, &pk, 1);
    vx_handle_close(port);
  }
  if (!w->cfg.seq || vx_buffer_alloc(&w->b, w->cfg.pwidth, w->cfg.pheight, VX_FORMAT_XRGB8888) != VX_OK ||
      vx_buffer_map(&w->b, true, &w->px) != VX_OK)
    return false;
  for (uint32_t y = 0; y < w->cfg.pheight; y++)
    for (uint32_t x = 0; x < w->cfg.pwidth; x++)
      ((uint32_t *)(w->px + (size_t)y * w->b.desc.plane[0].stride))[x] = colour;
  vx_wsys_attach at = {.h = {.ordinal = VX_WSYS_ATTACH}, .id = 1};
  vx_handle h[2];
  if (vx_buffer_put(&w->b, false, &at.desc, h) != VX_OK) return false;
  vx_wsys_reply r = {};
  vx_call c = {.wr_bytes = &at,
               .wr_handles = h,
               .wr_len = sizeof at,
               .wr_count = 2,
               .rd_bytes = &r,
               .rd_cap = sizeof r};
  if (vx_channel_call(w->ch, &c, vx_now() + 5'000'000'000) != VX_OK || r.h.flags) return false;
  vx_buffer_signal(&w->b, 1);
  vx_wsys_present p = {.h = {.ordinal = VX_WSYS_PRESENT},
                       .seq = 1,
                       .id = 1,
                       .acquire = 1,
                       .release = 2,
                       .config_seq = w->cfg.seq};
  return vx_channel_write(w->ch, &p, sizeof p, nullptr, 0) == VX_OK;
}

static bool contains(vx_str s, const char *what) {
  vx_str w = vx_cstr(what);
  for (size_t i = 0; i + w.len <= s.len; i++)
    if (memcmp(s.ptr + i, w.ptr, w.len) == 0) return true;
  return false;
}

static bool info_has(const char *what) {
  char text[512];
  vx_fd fd = vx_open(VX_STR("/wsys/info"), VX_OREAD);
  int64_t n = fd >= 0 ? vx_read(fd, (vx_bytes){(uint8_t *)text, sizeof text - 1}) : -1;
  if (fd >= 0) vx_close(fd);
  return n > 0 && contains((vx_str){text, (size_t)n}, what);
}

const char *vx_main(void) {
  ctl("/wsys/ctl", "move 60 60");
  CHECK(open_window(&a, "/wsys/surface", 0xe8e4d0));
  CHECK(vx_mount(VX_STR("/srv/wsys"), VX_STR("new -dx 300 -dy 200"), VX_STR("/n"), 0) == VX_OK);
  ctl("/n/ctl", "move 460 60");
  CHECK(open_window(&b, "/n/surface", 0xd0dce8));
  vx_print(VX_STR("decortest: ready\n"));
  uint32_t stage = 0;
  for (;;) { // each tick, every record, then the milestones
    vx_handle port;
    vx_packet pk;
    vx_port_create(0, &port);
    vx_port_bind(port, a.ch, VX_TRIGGER_READABLE, 1, 0);
    if (!b.closed) vx_port_bind(port, b.ch, VX_TRIGGER_READABLE, 2, 0);
    vx_port_wait(port, vx_now() + 50'000'000, 0, &pk, 1);
    vx_handle_close(port);
    drain(&a);
    if (!b.closed) drain(&b);
    if (stage == 0 && a.focused && a.released) { // the click let go: QEMU's tablet and mouse are two drivers
      vx_print(VX_STR("decortest: A focused\n"));
      a.pointers = 0, stage = 1; // the drags next: the app sees none of them
    } else if (stage == 1 && info_has("x=110 y=110")) {
      CHECK(a.pointers == 0);
      vx_print(VX_STR("decortest: A moved by its title to 110,110\n"));
      stage = 2;
    } else if (stage == 2 && a.cfg.seq == 2) {
      CHECK(a.cfg.pwidth == 340 && a.cfg.pheight == 230 && a.pointers == 0);
      CHECK(info_has("x=110 y=110 width=340 height=230"));
      vx_print(VX_STR("decortest: A resized by its corner to 340x230\n"));
      stage = 3;
    } else if (stage == 3 && b.closed) {
      CHECK(b.focused); // the gadget's press focused it first
      vx_print(VX_STR("decortest: B closed by its gadget\n"));
      vx_handle_close(b.ch);
      CHECK(vx_unmount(VX_STR(""), VX_STR("/n")) == VX_OK); // its last fid: the window goes
      vx_printf("decortest: %u checks, %u failed\n", checks, failures);
      vx_print(VX_STR("decortest: holding\n"));
      stage = 4;
    }
  }
}
