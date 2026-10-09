// routetest: input routed to windows (M7 step 7d1c, the focus scenario;
// docs/proto/wsys.md). Two windows side by side, A (300 by 200 at 48,48,
// its manifest's /wsys) and B (500 by 200 at 420,48, mounted at /n). The
// scenario clicks A and types "ab" (A focused, A's keys); holds shift and
// clicks B (focus moves: A is unfocused and its shift released, with the
// SYNTHETIC flag, and B never sees the shift's real UP); types "c" (B's);
// then drags from A across B (a press latches the pointer to A: A gets the
// motion outside itself, B none); and resizes A, whose old-size frame is
// then padded with what A showed before, never stretched. Each milestone is a line, printed once
// everything it needs has come, whatever order the two channels deliver in.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-ns/nsapi.c"
#include "../../lib/vx-wsys/wsysproto.h"

static uint32_t checks, failures;

static void check_at(bool ok, const char *what, int line) {
  checks++;
  if (ok) return;
  failures++;
  vx_printf("routetest: FAILED line %d: %s\n", line, what);
}

#define CHECK(cond) check_at((cond), #cond, __LINE__)

typedef struct win {
  const char *name;
  vx_handle ch;
  vx_wsys_configure cfg;
  vx_buffer b;
  uint8_t *px;
  bool focused;
  char typed[16]; // the runes of its keys' DOWNs
  uint32_t ntyped;
  bool shift_released; // a SYNTHETIC UP of shift
  uint32_t shift_records, pointers;
  bool pressed, outside; // in a drag: pressed, and moved outside itself while latched
  int32_t outside_x;
  bool resized_shown; // the present drawn for the old size, after the resize: shown
} win;

static win a = {.name = "A"}, b = {.name = "B"};
static uint32_t stage; // the milestones printed

static void ctl(const char *path, const char *cmd) {
  vx_fd fd = vx_open(vx_cstr(path), VX_OWRITE);
  CHECK(fd >= 0 && vx_write(fd, vx_cstr(cmd)) > 0);
  if (fd >= 0) vx_close(fd);
}

// A window's channel, its CONFIGURE, a buffer attached, and one present of colour.
static bool open_window(win *w, const char *surface, uint32_t colour) {
  if (vx_ns_open_post(vx_ns_process(), vx_cstr(surface), &w->ch) != VX_OK) return false;
  alignas(vx_wsys_configure) uint8_t m[256];
  vx_msg_size size;
  for (vx_instant deadline = vx_now() + 5'000'000'000; !w->cfg.seq;) {
    vx_status st = vx_channel_read(w->ch, m, sizeof m, nullptr, 0, &size);
    if (st == VX_OK && ((vx_msg_header *)m)->ordinal == VX_WSYS_CONFIGURE) memcpy(&w->cfg, m, sizeof w->cfg);
    if (st == VX_ERR_SHOULD_WAIT) {
      if (vx_now() > deadline) return false;
      vx_handle port;
      vx_packet pk;
      vx_port_create(0, &port);
      vx_port_bind(port, w->ch, VX_TRIGGER_READABLE, 1, 0);
      vx_port_wait(port, deadline, 0, &pk, 1);
      vx_handle_close(port);
    } else if (st != VX_OK) {
      return false;
    }
  }
  if (vx_buffer_alloc(&w->b, w->cfg.pwidth, w->cfg.pheight, VX_FORMAT_XRGB8888) != VX_OK ||
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

static void on_record(win *w, const uint8_t *m, uint32_t len) {
  const vx_msg_header *h = (const vx_msg_header *)m;
  if (h->ordinal == VX_WSYS_CONFIGURE && len == sizeof(vx_wsys_configure)) {
    const vx_wsys_configure *c = (const vx_wsys_configure *)m;
    bool now = c->flags & VX_WSYS_FOCUSED;
    w->cfg = *c;
    if (now && !w->focused) vx_printf("routetest: %s focused\n", w->name);
    w->focused = now;
  } else if (h->ordinal == VX_WSYS_FEEDBACK && len == sizeof(vx_wsys_feedback)) {
    const vx_wsys_feedback *f = (const vx_wsys_feedback *)m;
    if (f->seq == 2) w->resized_shown = f->actual && !f->dropped;
  } else if (h->ordinal == VX_WSYS_KEY && len == sizeof(vx_wsys_key)) {
    const vx_wsys_key *k = (const vx_wsys_key *)m;
    if (k->key.usage == (VX_HID_KEYBOARD | 0xe1)) {
      w->shift_records++;
      if (k->key.action == VX_KEY_UP && k->flags & VX_WSYS_SYNTHETIC) w->shift_released = true;
    }
    if (k->key.action == VX_KEY_DOWN && k->rune > 0x20 && k->rune < 0x7f && w->ntyped < sizeof w->typed - 1)
      w->typed[w->ntyped++] = (char)k->rune;
  } else if (h->ordinal == VX_WSYS_POINTER && len == sizeof(vx_wsys_pointer)) {
    const vx_wsys_pointer *p = (const vx_wsys_pointer *)m;
    w->pointers++;
    if (stage >= 4 && p->buttons & 1) w->pressed = true;
    if (w->pressed && p->buttons & 1 && p->flags & VX_WSYS_LATCHED && p->x >= (int32_t)w->cfg.width)
      w->outside = true, w->outside_x = p->x;
    if (stage == 4 && w == &a && w->pressed && !(p->buttons & 1)) w->pressed = false, stage = 5; // let go
  }
}

// Prints each milestone once everything it needs has come.
static void milestones(void) {
  if (stage == 0 && a.focused && a.ntyped == 2 && memcmp(a.typed, "ab", 2) == 0) {
    vx_print(VX_STR("routetest: A typed ab\n"));
    stage = 1;
  }
  if (stage == 1 && b.focused && !a.focused && a.shift_released) {
    vx_print(VX_STR("routetest: focus moved to B; A's shift released\n"));
    stage = 2;
  }
  if (stage == 2 && b.ntyped == 1 && b.typed[0] == 'c') {
    vx_print(VX_STR("routetest: B typed c\n"));
    CHECK(a.ntyped == 2);        // A got nothing of it
    CHECK(b.shift_records == 0); // the shift's real UP, which B never saw go down, never reached it
    b.pointers = 0, stage = 4;   // the drag next
  }
  if (stage == 5) {
    CHECK(a.outside && a.outside_x >= (int32_t)a.cfg.width); // latched to A, outside it
    CHECK(b.pointers == 0);                                  // and B got none of the drag
    CHECK(a.focused && !b.focused);
    vx_printf("routetest: A held the drag to x=%d\n", a.outside_x);
    // Resized: a CONFIGURE with the new size; the buffer drawn for the old
    // one presented anyway, which is padded, never stretched (03 §4).
    ctl("/wsys/ctl", "resize 320 220");
    stage = 6;
  }
  if (stage == 6 && a.cfg.seq == 2) {
    CHECK(a.cfg.pwidth == 320 && a.cfg.pheight == 220 && a.focused);
    vx_buffer_signal(&a.b, 3);
    vx_wsys_present p = {
        .h = {.ordinal = VX_WSYS_PRESENT}, .seq = 2, .id = 1, .acquire = 3, .release = 4, .config_seq = 1};
    CHECK(vx_channel_write(a.ch, &p, sizeof p, nullptr, 0) == VX_OK);
    stage = 7;
  }
  if (stage == 7 && a.resized_shown) {
    vx_print(VX_STR("routetest: A resized, its old frame padded\n"));
    vx_printf("routetest: %u checks, %u failed\n", checks, failures);
    vx_print(VX_STR("routetest: holding\n"));
    stage = 8;
  }
}

const char *vx_main(void) {
  ctl("/wsys/ctl", "move 48 48");
  CHECK(open_window(&a, "/wsys/surface", 0x4060c0));
  CHECK(vx_mount(VX_STR("/srv/wsys"), VX_STR("new -dx 500 -dy 200"), VX_STR("/n"), 0) == VX_OK);
  ctl("/n/ctl", "move 420 48");
  CHECK(open_window(&b, "/n/surface", 0xc06040));
  vx_handle port;
  CHECK(vx_port_create(0, &port) == VX_OK);
  vx_print(VX_STR("routetest: ready\n"));
  win *both[2] = {&a, &b};
  for (int i = 0; i < 2; i++) vx_port_bind(port, both[i]->ch, VX_TRIGGER_READABLE, (uint64_t)i, 0);
  for (;;) {
    vx_packet pk[2];
    int64_t n = vx_port_wait(port, VX_INFINITE, 0, pk, 2);
    for (int64_t k = 0; k < n; k++) {
      win *w = both[pk[k].key & 1];
      for (;;) {
        alignas(vx_wsys_configure) uint8_t m[256];
        vx_msg_size size;
        if (vx_channel_read(w->ch, m, sizeof m, nullptr, 0, &size) != VX_OK) break;
        on_record(w, m, size.bytes);
        milestones();
      }
      vx_port_bind(port, w->ch, VX_TRIGGER_READABLE, pk[k].key, 0);
    }
  }
}
