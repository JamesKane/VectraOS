// wintest: windows and the frame protocol (M7 step 7d1b, the windows
// scenario; docs/proto/wsys.md). Its manifest mounts /srv/wsys at /wsys
// with `new -dx 400 -dy 300`, a window of its own (/wsys is its
// /wsys/self); it makes a second, 300 by 200, by mounting the post again
// at /n, so it knows which came first. On the first window's channel:
// CONFIGURE and the first FRAME's credit, two buffers attached, a present
// shown (its FEEDBACK) and released (its timeline), a present without a
// credit dropped at once and released, and a last present whose damage is
// a box alone: its buffer also holds the first present's teal and a red
// square outside the damage, which a compositor that copies the damage only
// never shows. The second window is green, over the first. The scenario
// matches the screen: an orange window with a white box, a green one over
// its corner, no teal, no red.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-ns/nsapi.c"
#include "../../lib/vx-wsys/wsysproto.h"

static uint32_t checks, failures;

static void check_at(bool ok, const char *what, int line) {
  checks++;
  if (ok) return;
  failures++;
  vx_printf("wintest: FAILED line %d: %s\n", line, what);
}

#define CHECK(cond) check_at((cond), #cond, __LINE__)

typedef struct win {
  vx_handle ch;
  vx_wsys_configure cfg;
  uint32_t credits;
  vx_buffer b[2];
  uint8_t *px[2];
  uint64_t seq;
} win;

static alignas(vx_wsys_configure) uint8_t last[1024];

// The next record with this ordinal (the rest counted: FRAMEs' credits),
// or false at the deadline.
static bool next(win *w, uint32_t ordinal, void *out, uint32_t len) {
  vx_instant deadline = vx_now() + 5'000'000'000;
  for (;;) {
    vx_msg_size size;
    vx_status st = vx_channel_read(w->ch, last, sizeof last, nullptr, 0, &size);
    if (st == VX_OK) {
      const vx_msg_header *h = (const vx_msg_header *)last;
      if (h->ordinal == VX_WSYS_FRAME && size.bytes == sizeof(vx_wsys_frame))
        w->credits += ((const vx_wsys_frame *)last)->credits;
      if (h->ordinal == VX_WSYS_CONFIGURE && size.bytes == sizeof(vx_wsys_configure))
        memcpy(&w->cfg, last, sizeof w->cfg);
      if (h->ordinal == ordinal && size.bytes == len) {
        memcpy(out, last, len);
        return true;
      }
      continue;
    }
    if (st != VX_ERR_SHOULD_WAIT || vx_now() > deadline) return false;
    vx_handle port;
    vx_packet pk;
    vx_port_create(0, &port);
    vx_port_bind(port, w->ch, VX_TRIGGER_READABLE, 1, 0);
    vx_port_wait(port, deadline, 0, &pk, 1);
    vx_handle_close(port);
  }
}

// A credit to present with: at once, or from the next FRAME.
static bool credit(win *w) {
  vx_wsys_frame f;
  return w->credits || next(w, VX_WSYS_FRAME, &f, sizeof f);
}

static vx_status attach(win *w, uint32_t id, const vx_buffer *b) {
  vx_wsys_attach m = {.h = {.ordinal = VX_WSYS_ATTACH}, .id = id};
  vx_handle h[2];
  vx_status st = vx_buffer_put(b, false, &m.desc, h);
  if (st != VX_OK) return st;
  vx_wsys_reply r = {};
  vx_call c = {
      .wr_bytes = &m, .wr_handles = h, .wr_len = sizeof m, .wr_count = 2, .rd_bytes = &r, .rd_cap = sizeof r};
  st = vx_channel_call(w->ch, &c, vx_now() + 5'000'000'000);
  return st == VX_OK ? (vx_status)(int32_t)r.h.flags : st;
}

static void fill(win *w, int i, vx_wsys_rect r, uint32_t c) {
  if (!w->px[i]) return; // its buffer never mapped: a check has failed already
  uint32_t stride = w->b[i].desc.plane[0].stride;
  for (uint32_t y = 0; y < r.height; y++)
    for (uint32_t x = 0; x < r.width; x++) ((uint32_t *)(w->px[i] + (size_t)(r.y + y) * stride))[r.x + x] = c;
}

static void present(win *w, int i, uint64_t acquire, const vx_wsys_rect *damage) {
  vx_wsys_present p = {.h = {.ordinal = VX_WSYS_PRESENT},
                       .seq = ++w->seq,
                       .id = (uint32_t)i + 1,
                       .ndamage = damage ? 1 : 0,
                       .acquire = acquire,
                       .release = acquire + 1,
                       .config_seq = w->cfg.seq};
  if (damage) p.damage[0] = *damage;
  vx_buffer_signal(&w->b[i], acquire); // drawn
  if (w->credits) w->credits--;
  vx_channel_write(w->ch, &p, sizeof p, nullptr, 0);
}

// A window's channel, its CONFIGURE and first credit, and two buffers of its size.
static bool open_window(win *w, const char *surface) {
  *w = (win){};
  if (vx_ns_open_post(vx_ns_process(), vx_cstr(surface), &w->ch) != VX_OK) return false;
  vx_wsys_frame f;
  if (!next(w, VX_WSYS_FRAME, &f, sizeof f) || !w->cfg.seq) return false;
  for (int i = 0; i < 2; i++) {
    if (vx_buffer_alloc(&w->b[i], w->cfg.pwidth, w->cfg.pheight, VX_FORMAT_XRGB8888) != VX_OK ||
        vx_buffer_map(&w->b[i], true, &w->px[i]) != VX_OK || attach(w, (uint32_t)i + 1, &w->b[i]) != VX_OK)
      return false;
  }
  return true;
}

static vx_str read_file(const char *path, char *buf, size_t cap) {
  vx_fd fd = vx_open(vx_cstr(path), VX_OREAD);
  int64_t n = fd >= 0 ? vx_read(fd, (vx_bytes){(uint8_t *)buf, cap - 1}) : -1;
  if (fd >= 0) vx_close(fd);
  return (vx_str){buf, n > 0 ? (size_t)n : 0};
}

static bool contains(vx_str s, const char *what) {
  vx_str w = vx_cstr(what);
  for (size_t i = 0; i + w.len <= s.len; i++)
    if (memcmp(s.ptr + i, w.ptr, w.len) == 0) return true;
  return false;
}

const char *vx_main(void) {
  static win a, b;
  CHECK(open_window(&a, "/wsys/surface"));
  CHECK(a.cfg.pwidth == 400 && a.cfg.pheight == 300 && a.cfg.scale == 120 && a.credits == 1);
  vx_wsys_rect all = {0, 0, a.cfg.pwidth, a.cfg.pheight};

  // Shown, then released: teal, the whole window.
  fill(&a, 0, all, 0x008080);
  present(&a, 0, 1, nullptr);
  vx_wsys_feedback fb = {};
  CHECK(next(&a, VX_WSYS_FEEDBACK, &fb, sizeof fb) && fb.seq == 1 && fb.actual && !fb.dropped);
  CHECK(vx_buffer_wait(&a.b[0], 2, vx_now() + 1'000'000'000) == VX_OK); // released at composite
  CHECK(credit(&a) && a.credits == 1);

  // Orange in the other buffer, and at once a present with no credit left: dropped, released.
  fill(&a, 1, all, 0xff8000);
  present(&a, 1, 1, nullptr);
  present(&a, 0, 3, nullptr);
  CHECK(next(&a, VX_WSYS_FEEDBACK, &fb, sizeof fb) && fb.seq == 3 && fb.dropped && !fb.actual);
  CHECK(vx_buffer_wait(&a.b[0], 4, vx_now() + 1'000'000'000) == VX_OK);
  CHECK(next(&a, VX_WSYS_FEEDBACK, &fb, sizeof fb) && fb.seq == 2 && fb.actual && !fb.dropped);
  CHECK(credit(&a));

  // The box, its damage alone; the buffer still teal, with a red square outside it.
  vx_wsys_rect box = {100, 75, 200, 150}, red = {10, 10, 40, 40};
  fill(&a, 0, box, 0xffffff);
  fill(&a, 0, red, 0xff0000);
  present(&a, 0, 5, &box);
  CHECK(next(&a, VX_WSYS_FEEDBACK, &fb, sizeof fb) && fb.seq == 4 && fb.actual && !fb.dropped);

  // The window's files: its title set, its counts.
  vx_fd ctl = vx_open(VX_STR("/wsys/ctl"), VX_OWRITE);
  CHECK(ctl >= 0 && vx_write(ctl, VX_STR("title wintest")) > 0);
  if (ctl >= 0) vx_close(ctl);
  char text[512];
  vx_str info = read_file("/wsys/info", text, sizeof text);
  CHECK(contains(info, "title=wintest") && contains(info, "presented=3 dropped=1"));
  CHECK(contains(info, "width=400 height=300"));

  // The second window, over the first: green.
  CHECK(vx_mount(VX_STR("/srv/wsys"), VX_STR("new -dx 300 -dy 200"), VX_STR("/n"), 0) == VX_OK);
  CHECK(open_window(&b, "/n/surface"));
  CHECK(b.cfg.pwidth == 300 && b.cfg.pheight == 200);
  ctl = vx_open(VX_STR("/n/ctl"), VX_OWRITE); // over the first's corner, not its box
  CHECK(ctl >= 0 && vx_write(ctl, VX_STR("move 320 240")) > 0);
  if (ctl >= 0) vx_close(ctl);
  fill(&b, 0, (vx_wsys_rect){0, 0, 300, 200}, 0x30c030);
  present(&b, 0, 1, nullptr);
  CHECK(next(&b, VX_WSYS_FEEDBACK, &fb, sizeof fb) && fb.seq == 1 && fb.actual);
  // A second open of a surface is refused while the first is held.
  vx_handle again = VX_HANDLE_NONE;
  CHECK(vx_ns_open_post(vx_ns_process(), VX_STR("/n/surface"), &again) != VX_OK && !again);

  vx_printf("wintest: %u checks, %u failed\n", checks, failures);
  vx_printf("wintest: holding the windows\n");
  vx_handle port;
  vx_packet pk;
  vx_port_create(0, &port);
  vx_port_wait(port, VX_INFINITE, 0, &pk, 1);
  return nullptr;
}
