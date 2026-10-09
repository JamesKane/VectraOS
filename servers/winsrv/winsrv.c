// winsrv: the window server (M7 step 7d1, docs/21 §2, 03 §4-5).
//
// It holds displayd's output (a session of the display engine protocol,
// docs/proto/display.md §1a, which displayd gives its one client) and
// composites the screen on the CPU into two buffers of its own, flipping one
// in by APPLY while the other is drawn, damage only (7d1a). The output's
// frame clock is displayd's VBLANK: each one says which stamp is on screen,
// and the clock's Counter rises with it.
//
// Windows (7d1b, docs/proto/wsys.md): attaching to /srv/wsys with the aname
// `new -dx W -dy H` (rio's attach spec, rio/xfid.c:168-243) makes a window,
// and the attach's root is its directory, the app's /wsys/self; an empty
// aname is the whole tree. Opening a window's surface (9Px's srv extension)
// gives its channel, on which the app attaches vx-buffers and presents them
// with the frame protocol: a present costs a credit, each FRAME gives back
// what was composited, and a FEEDBACK says when it reached the screen.
// Release is at composite (21 §2 item 3): at a vblank, a present whose
// acquire point has come is latched, its damage copied into the window's
// backing, and its release point signalled at once, so an app that
// double-buffers never waits. The screen is composited from the backings,
// bottom to top, over the desk.
//
// The tree, at /wsys:
//
//   /info               the protocol's version and the output
//   /outputs/           where displayd's tree is mounted
//   /windows/N/ctl      move X Y · resize W H · title TEXT · raise · close
//   /windows/N/info     the window: id, title, position, size, config, counts
//   /windows/N/frame    its last FRAME and FEEDBACK, as text
//   /windows/N/surface  opened (srv extension): its channel, one at a time
//
// A window lives while a fid holds a node of it or its channel is open.
//
// Input (7d1c, 21 §2 items 6-7): winsrv holds inputd's records (a session
// on /srv/input, docs/proto/input.md §3a), so the console gets no keys
// while it runs. Pointers move one pointer, drawn as a cursor over
// everything. A press focuses and raises the window under it and latches
// the pointer stream there until every button is up (Fuchsia's
// mouse_system, mouse_system.cc:80-121; rio's, rio.c:560-639); without a
// press, pointer records go to the window under the pointer. Keys go to the
// focused window, which gets a key's UP only after its DOWN; a window
// losing focus gets an UP for each key it still holds.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-9p/ring_server.c"
#include "../../lib/vx-driver/displayproto.h"
#include "../../lib/vx-wsys/wsysproto.h"
#include "../../lib/vx-input/keymap.h"

static constexpr uint64_t KEY_DISPLAY = P9_KEY_USER | 1, KEY_INPUT = P9_KEY_USER | 2,
                          KEY_WINDOW = P9_KEY_USER | 0x100;
static constexpr uint32_t MAX_WINDOWS = 16;
static constexpr uint32_t BACKGROUND = 0xd8d8d8; // a window before its first present

static vx_handle disp; // the session with displayd
static p9_ring_server server;

// --- The screen ---

// Two buffers, each the output's size; the one a stamp put on screen is
// busy until a vblank shows a newer one (displayd's release rule).
typedef struct screen_buffer {
  vx_buffer buf;
  uint8_t *px;
  int64_t id;             // displayd's
  uint64_t stamp;         // the newest APPLY that showed it
  vx_display_rect damage; // what changed since it was last drawn: its age's
} screen_buffer;

static struct {
  vx_display_mode mode;
  screen_buffer b[2];
  uint32_t front;  // the one applied last
  uint64_t stamp;  // the newest APPLY
  uint64_t shown;  // the newest on screen
  vx_handle clock; // a Counter: the output's frames, one a vblank
  uint64_t frames, refresh;
  vx_display_rect dirty; // damage waiting for the next composite
  bool reported;
} out;

static vx_status call(void *req, uint32_t len, const vx_handle *h, uint32_t nh, void *rep, uint32_t cap) {
  vx_call c = {
      .wr_bytes = req, .wr_handles = h, .wr_len = len, .wr_count = nh, .rd_bytes = rep, .rd_cap = cap};
  vx_status st = vx_channel_call(disp, &c, vx_now() + 5'000'000'000);
  return st == VX_OK ? (vx_status)(int32_t)((vx_msg_header *)rep)->flags : st;
}

// --- Rectangles ---

static bool empty(vx_display_rect r) { return !r.width || !r.height; }

// The smallest rectangle holding a and b.
static vx_display_rect unite(vx_display_rect a, vx_display_rect b) {
  if (empty(a)) return b;
  if (empty(b)) return a;
  int64_t x0 = a.x < b.x ? a.x : b.x, y0 = a.y < b.y ? a.y : b.y;
  int64_t x1 = (int64_t)a.x + a.width, y1 = (int64_t)a.y + a.height;
  int64_t bx1 = (int64_t)b.x + b.width, by1 = (int64_t)b.y + b.height;
  if (bx1 > x1) x1 = bx1;
  if (by1 > y1) y1 = by1;
  return (vx_display_rect){(int32_t)x0, (int32_t)y0, (uint32_t)(x1 - x0), (uint32_t)(y1 - y0)};
}

// a ∩ b; empty if they do not meet.
static vx_display_rect meet(vx_display_rect a, vx_display_rect b) {
  int64_t x0 = a.x > b.x ? a.x : b.x, y0 = a.y > b.y ? a.y : b.y;
  int64_t x1 = (int64_t)a.x + a.width, y1 = (int64_t)a.y + a.height;
  int64_t bx1 = (int64_t)b.x + b.width, by1 = (int64_t)b.y + b.height;
  if (bx1 < x1) x1 = bx1;
  if (by1 < y1) y1 = by1;
  if (x1 <= x0 || y1 <= y0) return (vx_display_rect){};
  return (vx_display_rect){(int32_t)x0, (int32_t)y0, (uint32_t)(x1 - x0), (uint32_t)(y1 - y0)};
}

static vx_display_rect screen_rect(void) { return (vx_display_rect){0, 0, out.mode.width, out.mode.height}; }

// The screen damaged here, in every buffer that has not drawn it since.
static void damage(vx_display_rect r) {
  r = meet(r, screen_rect());
  if (empty(r)) return;
  out.dirty = unite(out.dirty, r);
  for (int i = 0; i < 2; i++) out.b[i].damage = unite(out.b[i].damage, r);
}

// --- Windows ---

typedef struct app_buffer {
  bool used;
  vx_buffer buf;
  uint8_t *px;
} app_buffer;

typedef struct window {
  bool used;
  uint32_t id; // its number in /wsys/windows: from 1, never reused while winsrv lives
  char title[64];
  vx_display_rect r; // on screen
  uint64_t config_seq;
  uint32_t *backing; // r.width by r.height, rows packed
  vx_handle backing_vmo;
  uint32_t holds; // fids holding its nodes
  vx_handle ch;   // its channel, while open
  app_buffer bufs[VX_WSYS_BUFFERS];
  bool pending; // a present waiting for a vblank and its acquire point
  vx_wsys_present present;
  uint32_t credits;  // the app may present this many more
  uint32_t returned; // to give back with the next FRAME
  bool owe_frame;
  uint64_t fb_seq, fb_stamp; // a present latched: its FEEDBACK waits for fb_stamp on screen
  uint64_t last_actual, presented, dropped;
  vx_wsys_frame last_frame;
  vx_wsys_feedback last_feedback;
  uint32_t keys[VX_INPUT_HELD], nkeys; // keys whose DOWN it was given
} window;

static window wins[MAX_WINDOWS];
static uint32_t stack[MAX_WINDOWS], nstack; // indices, bottom first
static uint32_t next_id = 1;

// --- Input's state ---

typedef struct in_device {
  bool known;
  uint8_t kind, axes;
  uint32_t x_max, y_max;
  uint32_t buttons; // held on it
} in_device;

static constexpr uint32_t IN_DEVICES = 16;
static vx_handle inp; // the session with inputd
static in_device indev[IN_DEVICES];
static struct {
  int32_t x, y;     // the pointer, on the screen
  uint32_t buttons; // held on any pointer
  int latch, focus; // windows' slots; -1: none
} ptr = {.latch = -1, .focus = -1};

static void send(window *w, const void *m, uint32_t len) {
  if (w->ch) vx_channel_write(w->ch, m, len, nullptr, 0); // a full channel drops it: the next says more
}

static void configure(window *w) {
  bool focused = ptr.focus == (int)(w - wins);
  vx_wsys_configure c = {.h = {.ordinal = VX_WSYS_CONFIGURE},
                         .flags = focused ? VX_WSYS_FOCUSED : 0,
                         .seq = w->config_seq,
                         .width = w->r.width,
                         .height = w->r.height,
                         .pwidth = w->r.width,
                         .pheight = w->r.height,
                         .scale = 120,
                         .visibility = VX_WSYS_VISIBLE};
  send(w, &c, sizeof c);
}

static void feedback(window *w, uint64_t seq, uint64_t actual, bool dropped) {
  w->last_feedback = (vx_wsys_feedback){
      .h = {.ordinal = VX_WSYS_FEEDBACK}, .seq = seq, .actual = actual, .dropped = dropped};
  if (dropped) w->dropped++;
  send(w, &w->last_feedback, sizeof w->last_feedback);
}

// A backing of w's size, its old pixels kept where they still fit, the rest
// the background.
static vx_status make_backing(window *w, uint32_t width, uint32_t height) {
  uint64_t bytes = ((uint64_t)width * height * 4 + 4095) & ~4095ull, at = 0;
  vx_handle vmo;
  vx_status st = vx_vmo_create(bytes, VX_VMO_LAZY, &vmo);
  if (st == VX_OK) st = vx_as_map(vx_self, vmo, 0, bytes, VX_MAP_WRITE, &at);
  if (st != VX_OK) {
    if (vmo) vx_handle_close(vmo);
    return st;
  }
  uint32_t *px = (uint32_t *)at;
  for (uint32_t y = 0; y < height; y++)
    for (uint32_t x = 0; x < width; x++)
      px[(size_t)y * width + x] = w->backing && x < w->r.width && y < w->r.height
                                      ? w->backing[(size_t)y * w->r.width + x]
                                      : BACKGROUND;
  if (w->backing) {
    vx_as_unmap(vx_self, (uint64_t)w->backing, ((uint64_t)w->r.width * w->r.height * 4 + 4095) & ~4095ull);
    vx_handle_close(w->backing_vmo);
  }
  w->backing = px, w->backing_vmo = vmo;
  return VX_OK;
}

static window *window_new(uint32_t width, uint32_t height) {
  uint32_t i = 0;
  while (i < MAX_WINDOWS && wins[i].used) i++;
  if (i == MAX_WINDOWS) return nullptr;
  window *w = &wins[i];
  // Cascaded from the top left, inside the screen.
  uint32_t n = (next_id - 1) % 8, sw = out.mode.width, sh = out.mode.height;
  if (width > sw) width = sw;
  if (height > sh) height = sh;
  int32_t x = (int32_t)(48 + 40 * n), y = (int32_t)(48 + 40 * n);
  if ((uint64_t)x + width > sw) x = (int32_t)(sw - width);
  if ((uint64_t)y + height > sh) y = (int32_t)(sh - height);
  *w = (window){.used = true, .id = next_id, .r = {x, y, 0, 0}, .config_seq = 1, .credits = 1};
  if (make_backing(w, width, height) != VX_OK) {
    *w = (window){};
    return nullptr;
  }
  next_id++;
  w->r.width = width, w->r.height = height;
  stack[nstack++] = i;
  damage(w->r);
  vx_printf("winsrv: window %u, %ux%u at %d,%d\n", w->id, width, height, x, y);
  return w;
}

static void buffer_drop(app_buffer *b) {
  if (!b->used) return;
  vx_buffer_unmap(&b->buf, b->px);
  vx_buffer_close(&b->buf);
  *b = (app_buffer){};
}

// Its channel gone: its buffers let go, a waiting present's release point signalled.
static void channel_end(window *w) {
  if (w->pending && w->bufs[w->present.id - 1].used)
    vx_buffer_signal(&w->bufs[w->present.id - 1].buf, w->present.release);
  w->pending = false;
  for (uint32_t i = 0; i < VX_WSYS_BUFFERS; i++) buffer_drop(&w->bufs[i]);
  if (w->ch) vx_handle_close(w->ch);
  w->ch = VX_HANDLE_NONE;
}

static void window_free(window *w) {
  int slot = (int)(w - wins);
  if (ptr.focus == slot) ptr.focus = -1;
  if (ptr.latch == slot) ptr.latch = -1;
  channel_end(w);
  damage(w->r);
  uint32_t i = (uint32_t)(w - wins), j = 0;
  for (uint32_t k = 0; k < nstack; k++)
    if (stack[k] != i) stack[j++] = stack[k];
  nstack = j;
  vx_as_unmap(vx_self, (uint64_t)w->backing, ((uint64_t)w->r.width * w->r.height * 4 + 4095) & ~4095ull);
  vx_handle_close(w->backing_vmo);
  vx_printf("winsrv: window %u closed\n", w->id);
  *w = (window){};
}

static void window_check_gone(window *w) {
  if (w->used && !w->holds && !w->ch) window_free(w);
}

static window *window_of_id(uint32_t id) {
  for (uint32_t i = 0; i < MAX_WINDOWS; i++)
    if (wins[i].used && wins[i].id == id) return &wins[i];
  return nullptr;
}

static void raise_window(window *w) {
  uint32_t i = (uint32_t)(w - wins), j = 0;
  for (uint32_t k = 0; k < nstack; k++)
    if (stack[k] != i) stack[j++] = stack[k];
  stack[j] = i;
  damage(w->r);
}

static vx_status resize(window *w, uint32_t width, uint32_t height) {
  if (width < 16 || height < 16 || width > out.mode.width || height > out.mode.height) return VX_ERR_RANGE;
  damage(w->r);
  vx_status st = make_backing(w, width, height);
  if (st != VX_OK) return st;
  w->r.width = width, w->r.height = height, w->config_seq++;
  damage(w->r);
  configure(w);
  return VX_OK;
}

// --- The channel ---

static void reply(window *w, const vx_msg_header *req, vx_status st) {
  vx_wsys_reply r = {.h = {.txid = req->txid, .ordinal = req->ordinal, .flags = (uint32_t)(int32_t)st}};
  send(w, &r, sizeof r);
}

static vx_status attach_buffer(window *w, const vx_wsys_attach *m, uint32_t len, const vx_handle h[2]) {
  if (m->id < 1 || m->id > VX_WSYS_BUFFERS || w->bufs[m->id - 1].used) {
    vx_handle_close(h[0]), vx_handle_close(h[1]);
    return VX_ERR_INVALID;
  }
  app_buffer *b = &w->bufs[m->id - 1];
  vx_status st = vx_buffer_take(&b->buf, &m->desc, len - (uint32_t)offsetof(vx_wsys_attach, desc), h);
  if (st != VX_OK) return st;
  if (b->buf.desc.format != VX_FORMAT_XRGB8888 && b->buf.desc.format != VX_FORMAT_ARGB8888)
    st = VX_ERR_INVALID;
  if (st == VX_OK) st = vx_buffer_map(&b->buf, false, &b->px);
  if (st != VX_OK) {
    vx_buffer_close(&b->buf);
    return st;
  }
  b->used = true;
  return VX_OK;
}

static void present(window *w, const vx_wsys_present *p) {
  bool ok = p->id >= 1 && p->id <= VX_WSYS_BUFFERS && w->bufs[p->id - 1].used && p->ndamage <= VX_WSYS_DAMAGE;
  if (!ok || !w->credits) { // fails fast: dropped, its buffer free at once
    if (ok) vx_buffer_signal(&w->bufs[p->id - 1].buf, p->release);
    feedback(w, p->seq, 0, true);
    return;
  }
  w->credits--;
  if (w->pending) { // a newer present replaces one still waiting: that one is dropped, its credit given back
    vx_buffer_signal(&w->bufs[w->present.id - 1].buf, w->present.release);
    feedback(w, w->present.seq, 0, true);
    w->returned++;
  }
  w->present = *p, w->pending = true;
}

// Every message waiting on w's channel; false once it has gone or broken the protocol.
static bool serve_window(window *w) {
  static union {
    vx_msg_header h;
    vx_wsys_attach attach;
    vx_wsys_detach detach;
    vx_wsys_present present;
    uint8_t bytes[1024];
  } m;
  for (;;) {
    vx_handle h[VX_CHANNEL_MAX_HANDLES];
    vx_msg_size size;
    vx_status st = vx_channel_read(w->ch, &m, sizeof m, h, VX_CHANNEL_MAX_HANDLES, &size);
    if (st == VX_ERR_SHOULD_WAIT) return true;
    if (st != VX_OK || size.bytes < sizeof m.h) return false;
    bool two = m.h.ordinal == VX_WSYS_ATTACH && size.handles == 2 && size.bytes == sizeof m.attach;
    if (!two)
      for (uint32_t i = 0; i < size.handles; i++) vx_handle_close(h[i]);
    switch (m.h.ordinal) {
    case VX_WSYS_ATTACH:
      reply(w, &m.h, two ? attach_buffer(w, &m.attach, size.bytes, h) : VX_ERR_INVALID);
      break;
    case VX_WSYS_DETACH:
      if (size.bytes != sizeof m.detach || m.detach.id < 1 || m.detach.id > VX_WSYS_BUFFERS ||
          (w->pending && w->present.id == m.detach.id)) {
        reply(w, &m.h, VX_ERR_INVALID);
        break;
      }
      buffer_drop(&w->bufs[m.detach.id - 1]);
      reply(w, &m.h, VX_OK);
      break;
    case VX_WSYS_PRESENT:
      if (size.bytes != sizeof m.present) return false;
      present(w, &m.present);
      break;
    default: reply(w, &m.h, VX_ERR_UNSUPPORTED); break;
    }
  }
}

// --- Composition ---

static const char *const ARROW[17] = {
    "X          ", "XX         ", "X.X        ", "X..X       ", "X...X      ", "X....X     ",
    "X.....X    ", "X......X   ", "X.......X  ", "X........X ", "X.....XXXXX", "X..X..X    ",
    "X.X X..X   ", "XX  X..X   ", "X    X..X  ", "     X..X  ", "      XX   ",
};

static vx_display_rect cursor_rect(void) { return (vx_display_rect){ptr.x, ptr.y, 11, 17}; }

// The desk: a vertical gradient, deep blue to slate, under every window.
static uint32_t desk(uint32_t y) {
  uint32_t t = out.mode.height > 1 ? y * 255 / (out.mode.height - 1) : 0;
  uint32_t r = 0x1c + (0x46 - 0x1c) * t / 255, g = 0x2a + (0x5a - 0x2a) * t / 255,
           b = 0x4a + (0x6e - 0x4a) * t / 255;
  return r << 16 | g << 8 | b;
}

static void composite(screen_buffer *s, vx_display_rect area) {
  uint32_t stride = s->buf.desc.plane[0].stride;
  for (uint32_t y = 0; y < area.height; y++) {
    uint32_t *row = (uint32_t *)(s->px + (size_t)(area.y + y) * stride) + area.x;
    uint32_t c = desk((uint32_t)area.y + y);
    for (uint32_t x = 0; x < area.width; x++) row[x] = c;
  }
  for (uint32_t k = 0; k < nstack; k++) {
    const window *w = &wins[stack[k]];
    vx_display_rect r = meet(area, w->r);
    for (uint32_t y = 0; y < r.height; y++) {
      const uint32_t *from = w->backing + (size_t)(r.y - w->r.y + y) * w->r.width + (r.x - w->r.x);
      memcpy((uint32_t *)(s->px + (size_t)(r.y + y) * stride) + r.x, from, (size_t)r.width * 4);
    }
  }
  // The cursor, over everything: X black, . white, the rest clear.
  vx_display_rect c = meet(area, cursor_rect());
  for (uint32_t y = 0; y < c.height; y++)
    for (uint32_t x = 0; x < c.width; x++) {
      char p = ARROW[c.y - ptr.y + y][c.x - ptr.x + x];
      if (p != ' ') ((uint32_t *)(s->px + (size_t)(c.y + y) * stride))[c.x + x] = p == 'X' ? 0 : 0xffffff;
    }
}

// A present whose acquire point has come: its damage into the backing (what
// its buffer has of it: a buffer drawn for another size is clipped, and the
// rest stays as it was), its release point signalled, its credit given back.
static void latch(window *w) {
  app_buffer *b = &w->bufs[w->present.id - 1];
  int64_t now = vx_counter_read(b->buf.timeline);
  if (now < 0 || (uint64_t)now < w->present.acquire) return; // not drawn yet: next vblank
  const vx_wsys_present *p = &w->present;
  vx_display_rect bounds = meet((vx_display_rect){0, 0, w->r.width, w->r.height},
                                (vx_display_rect){0, 0, b->buf.desc.width, b->buf.desc.height});
  uint32_t n = p->ndamage ? p->ndamage : 1;
  const vx_buffer_plane *pl = &b->buf.desc.plane[0];
  for (uint32_t d = 0; d < n; d++) {
    vx_display_rect r =
        p->ndamage
            ? meet((vx_display_rect){p->damage[d].x, p->damage[d].y, p->damage[d].width, p->damage[d].height},
                   bounds)
            : bounds;
    for (uint32_t y = 0; y < r.height; y++)
      memcpy(w->backing + (size_t)(r.y + y) * w->r.width + r.x,
             b->px + pl->offset + (size_t)(r.y + y) * pl->stride + (size_t)r.x * 4, (size_t)r.width * 4);
    damage((vx_display_rect){w->r.x + r.x, w->r.y + r.y, r.width, r.height});
  }
  vx_buffer_signal(&b->buf, p->release); // copied: the app's again (release at composite)
  w->pending = false;
  w->presented++;
  w->returned++;
  w->owe_frame = true;
  w->fb_seq = p->seq, w->fb_stamp = out.stamp + 1; // the next APPLY shows it
}

// At a vblank: presents latched, and with damage and a buffer free, the
// screen drawn and flipped in; then the frames owed.
static void frame(void) {
  uint32_t back = out.front ^ 1;
  screen_buffer *s = &out.b[back];
  if (s->stamp && s->stamp >= out.shown) return; // no newer stamp on screen yet: still the back end's
  for (uint32_t i = 0; i < MAX_WINDOWS; i++)
    if (wins[i].used && wins[i].pending) latch(&wins[i]);
  if (!empty(out.dirty)) {
    composite(s, s->damage);
    vx_display_rect screen = screen_rect();
    vx_display_apply a = {.h = {.ordinal = VX_DISPLAY_APPLY},
                          .stamp = ++out.stamp,
                          .cfg = {.output = 0,
                                  .nlayers = 1,
                                  .mode = out.mode,
                                  .layer = {{.kind = VX_DISPLAY_LAYER_IMAGE,
                                             .image = (uint64_t)s->id,
                                             .src = screen,
                                             .dst = screen,
                                             .alpha = 255}}},
                          .ndamage = 1,
                          .damage = {out.dirty}};
    if (vx_channel_write(disp, &a, sizeof a, nullptr, 0) == VX_OK)
      s->stamp = a.stamp, s->damage = (vx_display_rect){}, out.front = back, out.dirty = (vx_display_rect){};
  }
  for (uint32_t i = 0; i < MAX_WINDOWS; i++) {
    window *w = &wins[i];
    if (!w->used || !w->owe_frame) continue;
    w->credits += w->returned;
    w->last_frame = (vx_wsys_frame){.h = {.ordinal = VX_WSYS_FRAME},
                                    .seq = out.frames,
                                    .target = (uint64_t)vx_now() + out.refresh,
                                    .prev_presented = w->last_actual,
                                    .refresh = out.refresh,
                                    .credits = w->returned};
    send(w, &w->last_frame, sizeof w->last_frame);
    w->returned = 0, w->owe_frame = false;
  }
}

static void on_display(void) {
  for (;;) {
    alignas(vx_display_vblank) uint8_t m[1100];
    vx_handle h[VX_CHANNEL_MAX_HANDLES];
    vx_msg_size size;
    vx_status st = vx_channel_read(disp, m, sizeof m, h, VX_CHANNEL_MAX_HANDLES, &size);
    if (st == VX_ERR_PEER_CLOSED) {
      vx_print(VX_STR("winsrv: displayd has gone\n"));
      vx_exits("displayd has gone");
    }
    if (st != VX_OK) break;
    for (uint32_t i = 0; i < size.handles; i++) vx_handle_close(h[i]);
    const vx_msg_header *hd = (const vx_msg_header *)m;
    if (hd->ordinal != VX_DISPLAY_VBLANK || size.bytes != sizeof(vx_display_vblank)) continue;
    const vx_display_vblank *v = (const vx_display_vblank *)m;
    if (v->stamp > out.shown) out.shown = v->stamp;
    vx_counter_signal(out.clock, ++out.frames);
    if (!out.reported && out.shown >= 1) {
      vx_printf("winsrv: the desktop is on screen, %ux%u\n", out.mode.width, out.mode.height);
      out.reported = true;
    }
    for (uint32_t i = 0; i < MAX_WINDOWS; i++) { // what this vblank showed
      window *w = &wins[i];
      if (!w->used || !w->fb_stamp || w->fb_stamp > out.shown) continue;
      w->last_actual = v->time, w->fb_stamp = 0;
      feedback(w, w->fb_seq, v->time, false);
    }
    frame();
  }
  vx_port_bind(server.port, disp, VX_TRIGGER_READABLE, KEY_DISPLAY, 0);
}

static void on_input(void);

static void event(void *ctx, const vx_packet *pk) {
  (void)ctx;
  if (pk->key == KEY_DISPLAY) {
    on_display();
    return;
  }
  if (pk->key == KEY_INPUT) {
    if (inp) on_input(); // what it damaged is drawn at the next vblank
    return;
  }
  uint32_t i = (uint32_t)(pk->key - KEY_WINDOW);
  if (pk->key < KEY_WINDOW || i >= MAX_WINDOWS || !wins[i].used || !wins[i].ch) return;
  window *w = &wins[i];
  if (serve_window(w)) {
    vx_port_bind(server.port, w->ch, VX_TRIGGER_READABLE, KEY_WINDOW + i, 0);
    return;
  }
  channel_end(w);
  window_check_gone(w);
}

// --- Input ---

// The top window at (x, y), or -1.
static int window_at(int32_t x, int32_t y) {
  for (uint32_t k = nstack; k-- > 0;) {
    const window *w = &wins[stack[k]];
    if (x >= w->r.x && y >= w->r.y && x < w->r.x + (int64_t)w->r.width && y < w->r.y + (int64_t)w->r.height)
      return (int)stack[k];
  }
  return -1;
}

static void send_key(window *w, const vx_input_key *k, uint32_t flags) {
  vx_wsys_key m = {
      .h = {.ordinal = VX_WSYS_KEY}, .key = *k, .rune = vx_keymap_rune(k->usage, 0), .flags = flags};
  send(w, &m, sizeof m);
}

// Focus to slot i (-1: none): the old window's held keys released, both
// told by CONFIGURE, the new one raised.
static void focus_window(int i) {
  if (ptr.focus == i) return;
  int old = ptr.focus;
  ptr.focus = i;
  if (old >= 0) {
    window *o = &wins[old];
    for (uint32_t k = 0; k < o->nkeys; k++) {
      vx_input_key up = {.time = (uint64_t)vx_now(), .usage = o->keys[k], .action = VX_KEY_UP};
      send_key(o, &up, VX_WSYS_SYNTHETIC);
    }
    o->nkeys = 0;
    configure(o);
  }
  if (i >= 0) {
    raise_window(&wins[i]);
    configure(&wins[i]);
  }
}

static void on_key(const vx_input_key *k) {
  if (ptr.focus < 0) return;
  window *w = &wins[ptr.focus];
  uint32_t at = w->nkeys;
  for (uint32_t i = 0; i < w->nkeys; i++)
    if (w->keys[i] == k->usage) at = i;
  if (k->action == VX_KEY_DOWN && at == w->nkeys && w->nkeys < VX_INPUT_HELD)
    w->keys[w->nkeys++] = k->usage;
  else if (k->action != VX_KEY_DOWN && at == w->nkeys)
    return; // an UP or a repeat of a key it never saw go down
  else if (k->action == VX_KEY_UP)
    w->keys[at] = w->keys[--w->nkeys];
  send_key(w, k, 0);
}

static void on_pointer(in_device *d, const vx_input_pointer *p) {
  damage(cursor_rect());
  if (d->axes & VX_INPUT_ABSOLUTE) {
    ptr.x = (int32_t)((int64_t)p->x * (out.mode.width - 1) / (d->x_max ? d->x_max : 1));
    ptr.y = (int32_t)((int64_t)p->y * (out.mode.height - 1) / (d->y_max ? d->y_max : 1));
  } else {
    ptr.x += p->dx, ptr.y += p->dy;
  }
  if (ptr.x < 0) ptr.x = 0;
  if (ptr.y < 0) ptr.y = 0;
  if (ptr.x >= (int32_t)out.mode.width) ptr.x = (int32_t)out.mode.width - 1;
  if (ptr.y >= (int32_t)out.mode.height) ptr.y = (int32_t)out.mode.height - 1;
  damage(cursor_rect());
  uint32_t before = ptr.buttons;
  d->buttons = p->buttons;
  ptr.buttons = 0;
  for (uint32_t i = 0; i < IN_DEVICES; i++) ptr.buttons |= indev[i].buttons;
  if (!before && ptr.buttons) { // a press: focus, raise and latch the window under it
    int under = window_at(ptr.x, ptr.y);
    focus_window(under);
    ptr.latch = under;
  }
  int to = ptr.latch >= 0 ? ptr.latch : window_at(ptr.x, ptr.y);
  if (to >= 0) {
    window *w = &wins[to];
    vx_wsys_pointer m = {.h = {.ordinal = VX_WSYS_POINTER},
                         .time = p->time,
                         .x = ptr.x - w->r.x,
                         .y = ptr.y - w->r.y,
                         .dx = p->dx,
                         .dy = p->dy,
                         .wheel = p->wheel,
                         .hwheel = p->hwheel,
                         .buttons = ptr.buttons,
                         .flags = ptr.latch >= 0 ? VX_WSYS_LATCHED : 0};
    send(w, &m, sizeof m);
  }
  if (!ptr.buttons) ptr.latch = -1;
}

static void on_input(void) {
  for (;;) {
    static union {
      vx_msg_header h;
      vx_input_device device;
      vx_input_events events;
    } m;
    vx_handle h[VX_CHANNEL_MAX_HANDLES];
    vx_msg_size size;
    vx_status st = vx_channel_read(inp, &m, sizeof m, h, VX_CHANNEL_MAX_HANDLES, &size);
    if (st == VX_ERR_PEER_CLOSED) { // inputd has gone: no more input until it is back
      vx_handle_close(inp);
      inp = VX_HANDLE_NONE;
      return;
    }
    if (st != VX_OK) break;
    for (uint32_t i = 0; i < size.handles; i++) vx_handle_close(h[i]);
    if (size.bytes < sizeof m.h || m.h.flags >= IN_DEVICES) continue;
    in_device *d = &indev[m.h.flags];
    if (m.h.ordinal == VX_INPUT_DEVICE && size.bytes == sizeof m.device) {
      *d = (in_device){.known = true,
                       .kind = m.device.kind,
                       .axes = m.device.axes,
                       .x_max = m.device.x_max,
                       .y_max = m.device.y_max};
    } else if (m.h.ordinal == VX_INPUT_GONE) {
      *d = (in_device){};
    } else if (m.h.ordinal == VX_INPUT_EVENTS && d->known && m.events.count <= VX_INPUT_BATCH &&
               size.bytes == vx_input_events_len(d->kind, m.events.count)) {
      for (uint32_t i = 0; i < m.events.count; i++)
        if (d->kind == VX_INPUT_KEYBOARD)
          on_key(&m.events.key[i]);
        else
          on_pointer(d, &m.events.pointer[i]);
    }
  }
  vx_port_bind(server.port, inp, VX_TRIGGER_READABLE, KEY_INPUT, 0);
}

static void take_input(vx_handle srv) {
  vx_msg_header req = {.ordinal = VX_INPUT_CONNECT}, rep = {};
  vx_call c = {.wr_bytes = &req,
               .wr_len = sizeof req,
               .rd_bytes = &rep,
               .rd_cap = sizeof rep,
               .rd_handles = &inp,
               .rd_count_cap = 1};
  vx_status st = vx_channel_call(srv, &c, vx_now() + 5'000'000'000);
  if (st == VX_OK) st = (vx_status)(int32_t)rep.flags;
  if (st != VX_OK || !inp) {
    vx_printf("winsrv: no input: %d\n", (int)st);
    inp = VX_HANDLE_NONE;
    return;
  }
  vx_port_bind(server.port, inp, VX_TRIGGER_READABLE, KEY_INPUT, 0);
}

// --- The output ---

static vx_status take_output(vx_handle srv) {
  vx_msg_header req = {.ordinal = VX_DISPLAY_CONNECT}, rep = {};
  vx_call c = {.wr_bytes = &req,
               .wr_len = sizeof req,
               .rd_bytes = &rep,
               .rd_cap = sizeof rep,
               .rd_handles = &disp,
               .rd_count_cap = 1};
  vx_status st = vx_channel_call(srv, &c, vx_now() + 10'000'000'000);
  if (st == VX_OK) st = (vx_status)(int32_t)rep.flags;
  if (st != VX_OK || !disp) return st != VX_OK ? st : VX_ERR_BAD_STATE;
  // ADDED comes first, unasked.
  for (vx_instant deadline = vx_now() + 5'000'000'000;;) {
    static struct {
      vx_display_added a;
      uint8_t edid[1024];
    } m;
    vx_msg_size size;
    st = vx_channel_read(disp, &m, sizeof m, nullptr, 0, &size);
    if (st == VX_OK && m.a.h.ordinal == VX_DISPLAY_ADDED && size.bytes >= sizeof m.a) {
      out.mode = m.a.current;
      break;
    }
    if (st != VX_ERR_SHOULD_WAIT || vx_now() > deadline) return VX_ERR_TIMED_OUT;
    vx_handle port;
    vx_packet pk;
    vx_port_create(0, &port);
    vx_port_bind(port, disp, VX_TRIGGER_READABLE, 1, 0);
    vx_port_wait(port, deadline, 0, &pk, 1);
    vx_handle_close(port);
  }
  out.refresh = 1'000'000'000'000ull / (out.mode.refresh_mhz ? out.mode.refresh_mhz : 60'000);
  // The two screen buffers, imported; the whole screen damaged, so the first
  // frame draws it.
  for (int i = 0; i < 2; i++) {
    screen_buffer *s = &out.b[i];
    if ((st = vx_buffer_alloc(&s->buf, out.mode.width, out.mode.height, VX_FORMAT_XRGB8888)) != VX_OK ||
        (st = vx_buffer_map(&s->buf, true, &s->px)) != VX_OK)
      return st;
    vx_display_import im = {.h = {.ordinal = VX_DISPLAY_IMPORT}};
    vx_handle h[2];
    if ((st = vx_buffer_put(&s->buf, false, &im.desc, h)) != VX_OK) return st;
    vx_display_msg r = {};
    if ((st = call(&im, sizeof im, h, 2, &r, sizeof r)) != VX_OK) return st;
    s->id = r.arg[0];
  }
  out.front = 1; // so the first frame draws buffer 0
  damage(screen_rect());
  return vx_counter_create(0, &out.clock);
}

// --- The tree ---

// Nodes: the root's files, then each window's (by its slot), WIN + slot * 8
// + one of W_*.
enum : uint64_t { ROOT = 1, INFO, OUTPUTS, WINDOWS };
static constexpr uint64_t WIN = 0x100;
enum : uint64_t { W_DIR = 0, W_CTL, W_INFO, W_FRAME, W_SURFACE, W_FILES };
static const vx_str W_NAMES[W_FILES] = {
    {}, VX_STR("ctl"), VX_STR("info"), VX_STR("frame"), VX_STR("surface")};

static window *window_of(uint64_t n) {
  if (n < WIN || n >= WIN + (uint64_t)MAX_WINDOWS * 8) return nullptr;
  window *w = &wins[(n - WIN) / 8];
  return w->used && (n - WIN) % 8 < W_FILES ? w : nullptr;
}

static uint64_t node_of(const window *w, uint64_t file) { return WIN + (uint64_t)(w - wins) * 8 + file; }

static uint32_t parse_u32(vx_str *s) {
  while (s->len && s->ptr[0] == ' ') s->ptr++, s->len--;
  uint32_t v = 0;
  while (s->len && s->ptr[0] >= '0' && s->ptr[0] <= '9')
    v = v * 10 + (uint32_t)(s->ptr[0] - '0'), s->ptr++, s->len--;
  return v;
}

static bool take_word(vx_str *s, const char *word) {
  while (s->len && s->ptr[0] == ' ') s->ptr++, s->len--;
  vx_str w = vx_cstr(word);
  if (s->len < w.len || memcmp(s->ptr, w.ptr, w.len) != 0 || (s->len > w.len && s->ptr[w.len] != ' '))
    return false;
  s->ptr += w.len, s->len -= w.len;
  return true;
}

// "" is the whole tree; "new [-dx W] [-dy H]" a new window, its directory the root.
static vx_status fs_attach(void *ctx, vx_str aname, uint64_t *root) {
  (void)ctx;
  if (!aname.len) {
    *root = ROOT;
    return VX_OK;
  }
  if (!take_word(&aname, "new")) return VX_ERR_NOT_FOUND;
  uint32_t width = 640, height = 480;
  for (;;) {
    if (take_word(&aname, "-dx"))
      width = parse_u32(&aname);
    else if (take_word(&aname, "-dy"))
      height = parse_u32(&aname);
    else
      break;
  }
  while (aname.len && aname.ptr[0] == ' ') aname.ptr++, aname.len--;
  if (aname.len || width < 16 || height < 16) return VX_ERR_INVALID;
  window *w = window_new(width, height);
  if (!w) return VX_ERR_NO_MEMORY;
  *root = node_of(w, W_DIR);
  return VX_OK;
}

static vx_status fs_walk(void *ctx, uint64_t dir, vx_str name, uint64_t *child) {
  (void)ctx;
  if (dir == ROOT) {
    if (vx_str_eq(name, VX_STR("info")))
      *child = INFO;
    else if (vx_str_eq(name, VX_STR("outputs")))
      *child = OUTPUTS;
    else if (vx_str_eq(name, VX_STR("windows")))
      *child = WINDOWS;
    else
      return VX_ERR_NOT_FOUND;
    return VX_OK;
  }
  if (dir == WINDOWS) {
    vx_str s = name;
    uint32_t id = parse_u32(&s);
    window *w = s.len ? nullptr : window_of_id(id);
    if (!w) return VX_ERR_NOT_FOUND;
    *child = node_of(w, W_DIR);
    return VX_OK;
  }
  window *w = window_of(dir);
  if (!w || (dir - WIN) % 8 != W_DIR) return VX_ERR_NOT_FOUND;
  for (uint64_t f = W_CTL; f < W_FILES; f++)
    if (vx_str_eq(W_NAMES[f], name)) {
      *child = node_of(w, f);
      return VX_OK;
    }
  return VX_ERR_NOT_FOUND;
}

static vx_status fs_parent(void *ctx, uint64_t n, uint64_t *parent) {
  (void)ctx;
  if (n == ROOT || n == INFO || n == OUTPUTS || n == WINDOWS)
    *parent = ROOT;
  else if ((n - WIN) % 8 == W_DIR)
    *parent = WINDOWS;
  else
    *parent = n - (n - WIN) % 8;
  return VX_OK;
}

// A node's name, whether it is a directory, and its mode; empty if no such node.
static vx_str name_of(uint64_t n, bool *dir, uint32_t *mode) {
  static char name[12];
  *dir = n == ROOT || n == OUTPUTS || n == WINDOWS, *mode = 0444;
  if (n == ROOT) return VX_STR("/");
  if (n == INFO) return VX_STR("info");
  if (n == OUTPUTS) return VX_STR("outputs");
  if (n == WINDOWS) return VX_STR("windows");
  const window *w = window_of(n);
  if (!w) return (vx_str){};
  uint64_t f = (n - WIN) % 8;
  if (f == W_CTL) *mode = 0220;
  if (f == W_SURFACE) *mode = 0660;
  if (f != W_DIR) return W_NAMES[f];
  *dir = true;
  size_t len = 0;
  char digits[10];
  for (uint32_t v = w->id; v; v /= 10) digits[len++] = (char)('0' + v % 10);
  for (size_t k = 0; k < len; k++) name[k] = digits[len - 1 - k];
  return (vx_str){name, len};
}

static vx_status fs_stat(void *ctx, uint64_t n, p9_stat *st) {
  (void)ctx;
  bool dir;
  uint32_t mode;
  vx_str s = name_of(n, &dir, &mode);
  if (!s.len) return VX_ERR_NOT_FOUND;
  *st = (p9_stat){.qid = {dir ? P9_QTDIR : P9_QTFILE, 0, n},
                  .mode = dir ? P9_DMDIR | 0555 : mode,
                  .name = s,
                  .uid = VX_STR("sys"),
                  .gid = VX_STR("sys"),
                  .muid = VX_STR("sys")};
  return VX_OK;
}

static vx_status fs_open(void *ctx, uint64_t n, uint8_t mode) {
  (void)ctx;
  window *w = window_of(n);
  uint64_t f = w ? (n - WIN) % 8 : W_DIR;
  if (f == W_CTL) return (mode & 3) == P9_OWRITE ? VX_OK : VX_ERR_ACCESS;
  if (f == W_SURFACE) return (mode & 3) == P9_ORDWR ? VX_OK : VX_ERR_ACCESS;
  return (mode & 3) == P9_OREAD ? VX_OK : VX_ERR_ACCESS;
}

// The surface opened: the window's channel, beside the Ropen; CONFIGURE and
// a FRAME (its first credit) on it at once.
static vx_status fs_open_handle(void *ctx, uint64_t n, uint8_t mode, vx_handle *out_handle) {
  (void)ctx, (void)mode;
  window *w = window_of(n);
  if (!w || (n - WIN) % 8 != W_SURFACE) return VX_OK; // no handle to give
  if (w->ch) return VX_ERR_BAD_STATE;                 // one app's at a time
  vx_handle ends[2];
  vx_status st = vx_channel_create(0, ends);
  if (st != VX_OK) return st;
  w->ch = ends[0], *out_handle = ends[1];
  w->credits = 1, w->returned = 0;
  configure(w);
  w->last_frame = (vx_wsys_frame){.h = {.ordinal = VX_WSYS_FRAME},
                                  .seq = out.frames,
                                  .target = (uint64_t)vx_now() + out.refresh,
                                  .refresh = out.refresh,
                                  .credits = 1};
  send(w, &w->last_frame, sizeof w->last_frame);
  vx_port_bind(server.port, w->ch, VX_TRIGGER_READABLE, KEY_WINDOW + (uint64_t)(w - wins), 0);
  return VX_OK;
}

static void fs_fid_node(void *ctx, uint64_t n, int delta) {
  (void)ctx;
  window *w = window_of(n);
  if (!w) return;
  w->holds = (uint32_t)((int64_t)w->holds + delta);
  window_check_gone(w);
}

static vx_status reply_text(const char *text, size_t have, uint64_t offset, uint8_t *buf, uint32_t *count) {
  uint64_t left = offset < have ? have - offset : 0;
  if (*count > left) *count = (uint32_t)left;
  memcpy(buf, text + offset * (*count != 0), *count);
  return VX_OK;
}

static vx_status fs_read(void *ctx, uint64_t n, uint64_t offset, uint8_t *buf, uint32_t *count) {
  (void)ctx;
  char text[512];
  vx_ndb_writer t = {.buf = text, .cap = sizeof text};
  window *w = window_of(n);
  if (n == INFO) {
    vx_ndb_put_u64(&t, "version", VX_WSYS_VERSION);
    vx_ndb_put(&t, "output", VX_STR("fb0"));
    vx_ndb_put_u64(&t, "width", out.mode.width);
    vx_ndb_put_u64(&t, "height", out.mode.height);
    vx_ndb_put_u64(&t, "frames", out.frames);
    vx_ndb_end(&t);
  } else if (w && (n - WIN) % 8 == W_INFO) {
    vx_ndb_put_u64(&t, "id", w->id);
    vx_ndb_put(&t, "title", vx_cstr(w->title));
    vx_ndb_put_i64(&t, "x", w->r.x);
    vx_ndb_put_i64(&t, "y", w->r.y);
    vx_ndb_put_u64(&t, "width", w->r.width);
    vx_ndb_put_u64(&t, "height", w->r.height);
    vx_ndb_put_u64(&t, "config", w->config_seq);
    vx_ndb_put_u64(&t, "presented", w->presented);
    vx_ndb_put_u64(&t, "dropped", w->dropped);
    vx_ndb_end(&t);
  } else if (w && (n - WIN) % 8 == W_FRAME) {
    vx_ndb_flag(&t, "frame");
    vx_ndb_put_u64(&t, "seq", w->last_frame.seq);
    vx_ndb_put_u64(&t, "target", w->last_frame.target);
    vx_ndb_put_u64(&t, "credits", w->credits);
    vx_ndb_end(&t);
    vx_ndb_flag(&t, "feedback");
    vx_ndb_put_u64(&t, "seq", w->last_feedback.seq);
    vx_ndb_put_u64(&t, "actual", w->last_feedback.actual);
    vx_ndb_put_u64(&t, "dropped", w->last_feedback.dropped);
    vx_ndb_end(&t);
  } else {
    return VX_ERR_INVALID;
  }
  return reply_text(text, t.failed ? 0 : t.len, offset, buf, count);
}

static vx_status fs_write(void *ctx, uint64_t n, uint64_t offset, const uint8_t *buf, uint32_t *count) {
  (void)ctx, (void)offset;
  window *w = window_of(n);
  if (!w || (n - WIN) % 8 != W_CTL) return VX_ERR_ACCESS;
  vx_str cmd = {(const char *)buf, *count};
  while (cmd.len && (cmd.ptr[cmd.len - 1] == '\n' || cmd.ptr[cmd.len - 1] == ' ')) cmd.len--;
  vx_status st = VX_OK;
  if (take_word(&cmd, "move")) {
    int32_t x = (int32_t)parse_u32(&cmd), y = (int32_t)parse_u32(&cmd);
    damage(w->r);
    w->r.x = x, w->r.y = y;
    damage(w->r);
  } else if (take_word(&cmd, "resize")) {
    uint32_t width = parse_u32(&cmd), height = parse_u32(&cmd);
    st = resize(w, width, height);
  } else if (take_word(&cmd, "title")) {
    while (cmd.len && cmd.ptr[0] == ' ') cmd.ptr++, cmd.len--;
    size_t len = cmd.len < sizeof w->title - 1 ? cmd.len : sizeof w->title - 1;
    memcpy(w->title, cmd.ptr, len), w->title[len] = 0;
    cmd.len = 0;
  } else if (take_word(&cmd, "raise")) {
    raise_window(w);
  } else if (take_word(&cmd, "close")) {
    channel_end(w); // the app sees its channel close; the window goes with its last fid
  } else {
    st = VX_ERR_INVALID;
  }
  if (st == VX_OK && cmd.len) st = VX_ERR_INVALID;
  if (st != VX_OK) *count = 0;
  return st;
}

static vx_status fs_readdir(void *ctx, uint64_t dir, uint32_t index, uint64_t *child) {
  (void)ctx;
  if (dir == ROOT) {
    if (index > 2) return VX_ERR_NOT_FOUND;
    *child = INFO + index;
    return VX_OK;
  }
  if (dir == WINDOWS) {
    for (uint32_t i = 0, seen = 0; i < MAX_WINDOWS; i++)
      if (wins[i].used && seen++ == index) {
        *child = node_of(&wins[i], W_DIR);
        return VX_OK;
      }
    return VX_ERR_NOT_FOUND;
  }
  window *w = window_of(dir);
  if (!w || index >= W_FILES - 1) return VX_ERR_NOT_FOUND;
  *child = node_of(w, W_CTL + index);
  return VX_OK;
}

const char *vx_main(void) {
  server.fs = (p9_fs){.attach = fs_attach,
                      .walk = fs_walk,
                      .parent = fs_parent,
                      .stat = fs_stat,
                      .open = fs_open,
                      .open_handle = fs_open_handle,
                      .fid_node = fs_fid_node,
                      .read = fs_read,
                      .write = fs_write,
                      .readdir = fs_readdir};
  server.name = VX_STR("winsrv");
  server.supported = P9_EXT_XATTR | P9_EXT_SRV;
  server.event = event;
  server.listen = vx_spawn_take("listen");
  vx_handle srv = vx_spawn_take("srv:outputs");
  if (!server.listen || !srv || vx_port_create(0, &server.port) != VX_OK) {
    vx_print(VX_STR("winsrv: no listen channel, or no displayd\n"));
    return "no displayd";
  }
  vx_status st = take_output(srv);
  if (st != VX_OK) {
    vx_printf("winsrv: cannot take the output: %d\n", (int)st);
    return "no output";
  }
  ptr.x = (int32_t)out.mode.width / 2, ptr.y = (int32_t)out.mode.height / 2;
  vx_handle input = vx_spawn_take("srv:input");
  if (input) take_input(input);
  frame(); // the first, at once: the desk
  vx_port_bind(server.port, disp, VX_TRIGGER_READABLE, KEY_DISPLAY, 0);
  vx_print(VX_STR("winsrv: serving /srv/wsys\n"));
  return p9_ring_serve(&server) == VX_OK ? nullptr : "cannot serve";
}
