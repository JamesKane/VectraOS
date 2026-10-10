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
// Decorations (7d2a, 03 §5.1, §9.1) are the server's: a bevelled frame
// around each window's client area, a title strip (the focused window's in
// the active colour), a close gadget at the title's left and notches at the
// bottom-right corner, all from the theme's tokens (/wsys/theme, 03 §5.4:
// vx-magic, Indigo Magic's warm grey, and vx-next, NeXT's charcoal with the
// key window's title black). Hit-testing stays in the server: a press on the
// title moves the window, on the corner resizes it (an outline while held,
// applied when let go), on the gadget closes it when let go there; the app
// sees none of it. Title text comes with fonts (7e1).
//
// Text (7d2b, 03 §5): with a window's IME on (its ime file's `enable`), its
// keys' text comes as COMMIT, before each key as a KEY marked IMEPASS. What
// is still being composed comes as PREEDIT: a dead key's accent in the
// us-intl layout, or the compose key's sequence of two (lib/vx-input/
// keymap.h). An input method that holds /wsys/ime takes the built-in
// composer's place: each DOWN and repeat goes to it, and its answer says
// what to delete, commit and preedit, and whether the key passes on. Key
// repeat is winsrv's: a key held half a second repeats 30 times a second,
// flagged REPEAT, until it is let go or focus moves; a device's own repeats
// are dropped. /wsys/keymap names the layout, and a change is a KEYMAP
// record to every window.
//
// Policy is wm's (7d2c, 03 §5.2-5.3), a Lua program over the whole tree.
// winsrv keeps the key bindings it is given in /wsys/keys and matches them
// in the input path, so shortcuts work while wm is busy: a bound key never
// reaches a window. A binding's verb for a window (close, raise, move,
// resize) or the focus (focus next, focus prev) winsrv does itself; any
// other (layout tile, spawn term) goes to wm on /wsys/events, the desktop's
// events as lines: `new N`, `gone N`, `focus N`, `do N VERB...` (N the
// focused window, 0 for none).
//
// The trusted prompt (7d2d, 03 §5.7, §9.5): a question asked on
// /wsys/prompt (a grant of the whole tree) is a panel winsrv draws over
// every window, in a layer no client can make or cover: a black title strip
// (03 §9.1 reserves it for system panels), the seal only winsrv draws, and
// Allow and Deny. Only physical input answers it: a click on a button, half
// a second at least after the panel shows (a click meant for what was
// there before does not land on it), or escape for Deny; while it shows,
// every other key and click is swallowed, bindings too, and nothing written
// to a file can answer it. Questions wait in turn. Its text comes with
// fonts (7e1).
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
                          KEY_IME = P9_KEY_USER | 3, KEY_WINDOW = P9_KEY_USER | 0x100;
static constexpr uint32_t MAX_WINDOWS = 16;
static constexpr uint32_t BACKGROUND = 0xd8d8d8; // a window before its first present

static vx_handle disp;   // the session with displayd
static vx_handle ime_ch; // the input method's channel, while it holds /wsys/ime
static p9_ring_server server;
static void event_line(const char *word, uint32_t id, vx_str rest);

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

static bool inside(vx_display_rect r, int32_t x, int32_t y) {
  return x >= r.x && y >= r.y && x < r.x + (int64_t)r.width && y < r.y + (int64_t)r.height;
}

static vx_display_rect screen_rect(void) { return (vx_display_rect){0, 0, out.mode.width, out.mode.height}; }

// The screen damaged here, in every buffer that has not drawn it since.
static void damage(vx_display_rect r) {
  r = meet(r, screen_rect());
  if (empty(r)) return;
  out.dirty = unite(out.dirty, r);
  for (int i = 0; i < 2; i++) out.b[i].damage = unite(out.b[i].damage, r);
}

// --- The theme ---

// A theme's tokens (03 §9.1's families): the desk's gradient, the chrome's
// face, light and shade from one light source at the top left, its edge,
// and the title strips.
typedef struct theme {
  char name[16];
  uint32_t desk_top, desk_bottom;
  uint32_t face, light, shade, edge;
  uint32_t title_active, title_inactive;
} theme;

static const theme THEMES[] = {
    {"vx-magic", 0x1c2a4a, 0x465a6e, 0xbdb8ae, 0xece8df, 0x7d786f, 0x2b2926, 0x7f93ad, 0xbdb8ae},
    {"vx-next", 0x1e1e1e, 0x4a4a4a, 0x555555, 0x8c8c8c, 0x2a2a2a, 0x000000, 0x000000, 0xa8a8a8},
};
static theme tok = THEMES[0];

typedef struct token {
  const char *name;
  uint32_t *at;
} token;
static const token TOKENS[] = {
    {"desk.top", &tok.desk_top},         {"desk.bottom", &tok.desk_bottom},
    {"chrome.face", &tok.face},          {"chrome.light", &tok.light},
    {"chrome.shade", &tok.shade},        {"chrome.edge", &tok.edge},
    {"title.active", &tok.title_active}, {"title.inactive", &tok.title_inactive},
};

// A frame's parts: the border all round, the title strip above the client
// area, the close gadget in it, the corner that resizes.
static constexpr int32_t BORDER = 4, TITLE = 20, GADGET = 14, CORNER = 20;

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
  bool ime_on;                         // its ime file's enable: text as COMMIT
  char purpose[12];                    // what its text field holds: text, password, ...
  uint32_t dead;                       // a dead key's accent, waiting for the next key
  uint8_t compose;                     // 1: the compose key pressed; 2: its first rune taken
  uint32_t compose_first;
} window;

static window wins[MAX_WINDOWS];
static uint32_t stack[MAX_WINDOWS], nstack; // indices, bottom first

// A window's frame: its client area with the border and the title strip.
static vx_display_rect frame_rect(const window *w) {
  return (vx_display_rect){w->r.x - BORDER, w->r.y - BORDER - TITLE, w->r.width + 2 * BORDER,
                           w->r.height + 2 * BORDER + TITLE};
}
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
  // A drag the server runs (7d2a): from a press on a window's decoration.
  enum { DRAG_NONE, DRAG_MOVE, DRAG_RESIZE, DRAG_CLOSE } drag;
  int dragged;
  int32_t from_x, from_y;  // where the press was
  vx_display_rect start;   // the window's client area then
  vx_display_rect outline; // a resize's, while held; empty if none
} ptr = {.latch = -1, .focus = -1, .dragged = -1};

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
  if ((uint64_t)x + width + BORDER > sw) x = (int32_t)sw - (int32_t)width - BORDER;
  if ((uint64_t)y + height + BORDER > sh) y = (int32_t)sh - (int32_t)height - BORDER;
  if (x < BORDER) x = BORDER;
  if (y < BORDER + TITLE) y = BORDER + TITLE;
  *w = (window){.used = true, .id = next_id, .r = {x, y, 0, 0}, .config_seq = 1, .credits = 1};
  if (make_backing(w, width, height) != VX_OK) {
    *w = (window){};
    return nullptr;
  }
  next_id++;
  w->r.width = width, w->r.height = height;
  stack[nstack++] = i;
  damage(frame_rect(w));
  vx_printf("winsrv: window %u, %ux%u at %d,%d\n", w->id, width, height, x, y);
  event_line("new", w->id, (vx_str){});
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
  if (ptr.dragged == slot) ptr.drag = DRAG_NONE, ptr.dragged = -1, ptr.outline = (vx_display_rect){};
  channel_end(w);
  damage(frame_rect(w));
  uint32_t i = (uint32_t)(w - wins), j = 0;
  for (uint32_t k = 0; k < nstack; k++)
    if (stack[k] != i) stack[j++] = stack[k];
  nstack = j;
  vx_as_unmap(vx_self, (uint64_t)w->backing, ((uint64_t)w->r.width * w->r.height * 4 + 4095) & ~4095ull);
  vx_handle_close(w->backing_vmo);
  vx_printf("winsrv: window %u closed\n", w->id);
  event_line("gone", w->id, (vx_str){});
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
  damage(frame_rect(w));
}

static vx_status resize(window *w, uint32_t width, uint32_t height) {
  if (width < 16 || height < 16 || width > out.mode.width || height > out.mode.height) return VX_ERR_RANGE;
  damage(frame_rect(w));
  vx_status st = make_backing(w, width, height);
  if (st != VX_OK) return st;
  w->r.width = width, w->r.height = height, w->config_seq++;
  damage(frame_rect(w));
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

// --- The trusted prompt (7d2d) ---

static constexpr uint32_t PROMPTS = 8;
static constexpr vx_duration PROMPT_ARMING = 500'000'000;
static constexpr int32_t PROMPT_W = 360, PROMPT_H = 160, BUTTON_W = 100, BUTTON_H = 32;

typedef struct prompt_req {
  bool used, asked, answered;
  bool allow;
  uint64_t seq; // asked in this order
  char question[128];
} prompt_req;
static prompt_req prompts[PROMPTS];
static uint64_t prompt_seq;
static struct {
  int showing; // the request on screen, -1: none
  vx_instant since;
  int pressed; // 0: none, 1: Allow, 2: Deny, pressed and not yet let go
} prompt = {.showing = -1};

static vx_display_rect prompt_rect(void) {
  return (vx_display_rect){((int32_t)out.mode.width - PROMPT_W) / 2,
                           ((int32_t)out.mode.height - PROMPT_H) / 2, PROMPT_W, PROMPT_H};
}

// Its buttons: 1 Allow (the right), 2 Deny.
static vx_display_rect prompt_button(int which) {
  vx_display_rect p = prompt_rect();
  int32_t x = p.x + PROMPT_W - 16 - BUTTON_W - (which == 2 ? BUTTON_W + 12 : 0);
  return (vx_display_rect){x, p.y + PROMPT_H - 16 - BUTTON_H, BUTTON_W, BUTTON_H};
}

// The oldest question asked and not answered, on screen.
static void prompt_next(void) {
  int best = -1;
  for (int i = 0; i < (int)PROMPTS; i++)
    if (prompts[i].used && prompts[i].asked && !prompts[i].answered &&
        (best < 0 || prompts[i].seq < prompts[best].seq))
      best = i;
  if (best != prompt.showing) damage(prompt_rect());
  prompt.showing = best, prompt.since = vx_now(), prompt.pressed = 0;
  if (best >= 0) vx_print(VX_STR("winsrv: a prompt is up\n"));
}

static void prompt_answer(bool allow) {
  prompt_req *r = &prompts[prompt.showing];
  r->answered = true, r->allow = allow;
  vx_printf("winsrv: the prompt was answered: %s\n", allow ? "allow" : "deny");
  server.again = true; // its read may go on
  prompt_next();
}

// --- Composition ---

static const char *const ARROW[17] = {
    "X          ", "XX         ", "X.X        ", "X..X       ", "X...X      ", "X....X     ",
    "X.....X    ", "X......X   ", "X.......X  ", "X........X ", "X.....XXXXX", "X..X..X    ",
    "X.X X..X   ", "XX  X..X   ", "X    X..X  ", "     X..X  ", "      XX   ",
};

static vx_display_rect cursor_rect(void) { return (vx_display_rect){ptr.x, ptr.y, 11, 17}; }

// The desk: a vertical gradient, the theme's desk.top to desk.bottom, under every window.
static uint32_t mix(uint32_t a, uint32_t b, uint32_t t) { // t of 255 from a to b
  uint32_t m = 0;
  for (int s = 0; s < 24; s += 8) {
    int32_t ca = (int32_t)(a >> s & 0xff), cb = (int32_t)(b >> s & 0xff);
    m |= (uint32_t)(ca + (cb - ca) * (int32_t)t / 255) << s;
  }
  return m;
}

static uint32_t desk(uint32_t y) {
  return mix(tok.desk_top, tok.desk_bottom, out.mode.height > 1 ? y * 255 / (out.mode.height - 1) : 0);
}

// A frame's pixel at (fx, fy) in a frame fw by fh, not in the client area:
// an edge, a bevel lit from the top left, the title strip with its own
// bevel and the close gadget, and the corner's notches.
static uint32_t frame_pixel(int32_t fx, int32_t fy, int32_t fw, int32_t fh, bool active) {
  if (fx == 0 || fy == 0 || fx == fw - 1 || fy == fh - 1) return tok.edge;
  if (fx == 1 || fy == 1) return tok.light;
  if (fx == fw - 2 || fy == fh - 2) return tok.shade;
  if (fy >= BORDER && fy < BORDER + TITLE && fx >= BORDER && fx < fw - BORDER) {
    int32_t gx = fx - BORDER - 3, gy = fy - BORDER - 3;
    if (gx >= 0 && gy >= 0 && gx < GADGET && gy < GADGET) { // the close gadget: raised, a sunken well in it
      if (gx == 0 || gy == 0 || gx == GADGET - 1 || gy == GADGET - 1) return tok.edge;
      if (gx == 1 || gy == 1) return tok.light;
      if (gx == GADGET - 2 || gy == GADGET - 2) return tok.shade;
      if (gx >= 4 && gy >= 4 && gx < GADGET - 4 && gy < GADGET - 4) {
        if (gx == 4 || gy == 4) return tok.shade;
        if (gx == GADGET - 5 || gy == GADGET - 5) return tok.light;
      }
      return tok.face;
    }
    if (fy == BORDER || fx == BORDER) return tok.light;
    if (fy == BORDER + TITLE - 1 || fx == fw - BORDER - 1) return tok.shade;
    return active ? tok.title_active : tok.title_inactive;
  }
  // The corner's notches, across the bottom and right borders.
  bool bottom = fy >= fh - BORDER, right = fx >= fw - BORDER;
  if (bottom && fx == fw - CORNER) return tok.shade;
  if (bottom && fx == fw - CORNER + 1) return tok.light;
  if (right && fy == fh - CORNER) return tok.shade;
  if (right && fy == fh - CORNER + 1) return tok.light;
  return tok.face;
}

// The seal at (cx, cy): a gunmetal disc lit from the top left, in a dark
// ring with twelve teeth; only winsrv draws it, in the prompt's layer.
static bool seal_pixel(int32_t dx, int32_t dy, uint32_t *c) {
  int32_t r2 = dx * dx + dy * dy;
  if (r2 > 30 * 30) return false;
  // The teeth: the ring's outer edge stands out where |dx|, |dy| or the diagonals line up.
  bool tooth =
      dx * dy == 0 || dx == dy || dx == -dy || 2 * dx == dy || dx == 2 * dy || 2 * dx == -dy || dx == -2 * dy;
  if (r2 > 27 * 27) {
    if (!tooth && r2 > 28 * 28) return false;
    *c = 0x2a2e33;
    return true;
  }
  if (r2 > 24 * 24) {
    *c = 0x3a3f44; // the ring
    return true;
  }
  int32_t lit = 0x68 - (dx + dy) * 2; // brighter to the top left
  if (lit < 0x40) lit = 0x40;
  if (lit > 0x90) lit = 0x90;
  if (r2 < 9 * 9) lit -= 0x14; // a sunken centre
  *c = (uint32_t)lit << 16 | (uint32_t)(lit + 6) << 8 | (uint32_t)(lit + 12);
  return true;
}

// Whether (x, y) is within a pixel and a half of the segment from (x0, y0) to (x1, y1).
static bool near_segment(int32_t x, int32_t y, int32_t x0, int32_t y0, int32_t x1, int32_t y1) {
  int64_t dx = x1 - x0, dy = y1 - y0, len2 = dx * dx + dy * dy;
  int64_t t = (x - x0) * dx + (y - y0) * dy; // the projection, times len2
  if (t < 0 || t > len2) return false;
  int64_t cross = (x - x0) * dy - (y - y0) * dx; // the distance, times its length
  return cross * cross * 4 <= len2 * 9;          // within 1.5
}

static void draw_prompt(screen_buffer *s, vx_display_rect area) {
  uint32_t stride = s->buf.desc.plane[0].stride;
  vx_display_rect p = prompt_rect(), a = meet(area, p);
  vx_display_rect allow = prompt_button(1), deny = prompt_button(2);
  for (uint32_t y = 0; y < a.height; y++) {
    uint32_t *row = (uint32_t *)(s->px + (size_t)(a.y + y) * stride);
    for (uint32_t x = 0; x < a.width; x++) {
      int32_t sx = a.x + (int32_t)x, sy = a.y + (int32_t)y, fx = sx - p.x, fy = sy - p.y;
      uint32_t c = tok.face;
      if (fx == 0 || fy == 0 || fx == PROMPT_W - 1 || fy == PROMPT_H - 1)
        c = 0;
      else if (fy < 24)
        c = fy == 1 ? 0x3c3c3c : 0x000000; // the black strip of a system panel
      else if (fx == 1 || fy == 24)
        c = tok.light;
      else if (fx == PROMPT_W - 2 || fy == PROMPT_H - 2)
        c = tok.shade;
      uint32_t seal;
      if (seal_pixel(fx - 50, fy - 72, &seal)) c = seal;
      for (int b = 1; b <= 2; b++) { // the buttons: raised, a glyph in each
        vx_display_rect r = b == 1 ? allow : deny;
        if (!inside(r, sx, sy)) continue;
        int32_t bx = sx - r.x, by = sy - r.y;
        bool down = prompt.pressed == b;
        c = tok.face;
        if (bx == 0 || by == 0 || bx == BUTTON_W - 1 || by == BUTTON_H - 1)
          c = tok.edge;
        else if (bx == 1 || by == 1)
          c = down ? tok.shade : tok.light;
        else if (bx == BUTTON_W - 2 || by == BUTTON_H - 2)
          c = down ? tok.light : tok.shade;
        int32_t gx = bx - BUTTON_W / 2, gy = by - BUTTON_H / 2;
        if (b == 1 && (near_segment(gx, gy, -7, 0, -2, 5) || near_segment(gx, gy, -2, 5, 7, -6)))
          c = 0x2e8b3a; // a check, green
        if (b == 2 && (near_segment(gx, gy, -6, -6, 6, 6) || near_segment(gx, gy, -6, 6, 6, -6)))
          c = 0xa83232; // a cross, red
      }
      row[sx] = c;
    }
  }
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
    vx_display_rect f = frame_rect(w), fa = meet(area, f);
    bool active = ptr.focus == (int)stack[k];
    for (uint32_t y = 0; y < fa.height; y++) {
      uint32_t *row = (uint32_t *)(s->px + (size_t)(fa.y + y) * stride);
      int32_t sy = fa.y + (int32_t)y;
      bool in_rows = sy >= w->r.y && sy < w->r.y + (int32_t)w->r.height;
      for (uint32_t x = 0; x < fa.width; x++) {
        int32_t sx = fa.x + (int32_t)x;
        if (in_rows && sx >= w->r.x && sx < w->r.x + (int32_t)w->r.width) continue; // the client's
        row[sx] = frame_pixel(sx - f.x, sy - f.y, (int32_t)f.width, (int32_t)f.height, active);
      }
    }
    vx_display_rect r = meet(area, w->r);
    for (uint32_t y = 0; y < r.height; y++) {
      const uint32_t *from = w->backing + (size_t)(r.y - w->r.y + y) * w->r.width + (r.x - w->r.x);
      memcpy((uint32_t *)(s->px + (size_t)(r.y + y) * stride) + r.x, from, (size_t)r.width * 4);
    }
  }
  // The prompt, over every window: then only the cursor is above it.
  if (prompt.showing >= 0) draw_prompt(s, area);
  // A resize's outline, two pixels of the edge colour, then the cursor over everything.
  if (!empty(ptr.outline)) {
    vx_display_rect o = ptr.outline;
    for (uint32_t y = 0; y < o.height; y++)
      for (uint32_t x = 0; x < o.width; x++) {
        if (x >= 2 && y >= 2 && x + 2 < o.width && y + 2 < o.height) continue;
        int32_t sx = o.x + (int32_t)x, sy = o.y + (int32_t)y;
        if (inside(area, sx, sy)) ((uint32_t *)(s->px + (size_t)sy * stride))[sx] = tok.edge;
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
static void on_ime(void);

static void event(void *ctx, const vx_packet *pk) {
  (void)ctx;
  if (pk->key == KEY_DISPLAY) {
    on_display();
    return;
  }
  if (pk->key == KEY_IME && ime_ch) {
    on_ime();
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

// What a press at (x, y) would hit: the top window's frame there (-1: the
// desk), and which part of it.
enum part { PART_CLIENT, PART_TITLE, PART_GADGET, PART_CORNER, PART_BORDER };
static int window_at(int32_t x, int32_t y, enum part *part) {
  for (uint32_t k = nstack; k-- > 0;) {
    const window *w = &wins[stack[k]];
    vx_display_rect f = frame_rect(w);
    if (!inside(f, x, y)) continue;
    int32_t fx = x - f.x, fy = y - f.y;
    vx_display_rect gadget = {w->r.x + 3, w->r.y - TITLE + 3, GADGET, GADGET};
    vx_display_rect title = {w->r.x, w->r.y - TITLE, w->r.width, TITLE};
    if (inside(w->r, x, y))
      *part = PART_CLIENT;
    else if (inside(gadget, x, y))
      *part = PART_GADGET;
    else if (fx >= (int32_t)f.width - CORNER && fy >= (int32_t)f.height - CORNER)
      *part = PART_CORNER;
    else if (inside(title, x, y))
      *part = PART_TITLE;
    else
      *part = PART_BORDER;
    return (int)stack[k];
  }
  *part = PART_BORDER;
  return -1;
}

// A drag the server runs, as the pointer moves with the button held.
static void drag_to(void) {
  window *w = &wins[ptr.dragged];
  int32_t dx = ptr.x - ptr.from_x, dy = ptr.y - ptr.from_y;
  if (ptr.drag == DRAG_MOVE) {
    damage(frame_rect(w));
    w->r.x = ptr.start.x + dx, w->r.y = ptr.start.y + dy;
    damage(frame_rect(w));
  } else if (ptr.drag == DRAG_RESIZE) {
    damage(ptr.outline);
    int64_t width = (int64_t)ptr.start.width + dx, height = (int64_t)ptr.start.height + dy;
    if (width < 64) width = 64;
    if (height < 32) height = 32;
    window grown = *w;
    grown.r.width = (uint32_t)width, grown.r.height = (uint32_t)height;
    ptr.outline = frame_rect(&grown);
    damage(ptr.outline);
  }
}

// The button let go: a resize applied, a close done if it is still on the gadget.
static void drag_end(void) {
  window *w = &wins[ptr.dragged];
  if (ptr.drag == DRAG_RESIZE && !empty(ptr.outline)) {
    damage(ptr.outline);
    resize(w, ptr.outline.width - 2 * BORDER, ptr.outline.height - 2 * BORDER - TITLE);
  } else if (ptr.drag == DRAG_CLOSE) {
    enum part part;
    if (window_at(ptr.x, ptr.y, &part) == ptr.dragged && part == PART_GADGET) channel_end(w);
  }
  ptr.drag = DRAG_NONE, ptr.dragged = -1, ptr.outline = (vx_display_rect){};
}

static void send_key(window *w, const vx_input_key *k, uint32_t flags) {
  vx_wsys_key m = {
      .h = {.ordinal = VX_WSYS_KEY}, .key = *k, .rune = vx_keymap_rune(k->usage, 0), .flags = flags};
  send(w, &m, sizeof m);
}

// --- Events and bindings (7d2c) ---

static constexpr uint32_t EVENTS = 128, EVENT_OPENS = 16, BINDINGS = 64;

static char events[EVENTS][96];
static uint64_t events_next; // the next event's number; the oldest kept is events_next - EVENTS, at least 0

typedef struct event_open {
  bool used;
  uint64_t at; // the next event it reads
} event_open;
static event_open event_opens[EVENT_OPENS];

static void event_line(const char *word, uint32_t id, vx_str rest) {
  char *e = events[events_next++ % EVENTS];
  size_t n = 0;
  vx_str w = vx_cstr(word);
  memcpy(e, w.ptr, w.len), n = w.len;
  e[n++] = ' ';
  char digits[10];
  size_t d = 0;
  do digits[d++] = (char)('0' + id % 10), id /= 10;
  while (id);
  while (d) e[n++] = digits[--d];
  if (rest.len && rest.len < sizeof events[0] - n - 2)
    e[n++] = ' ', memcpy(e + n, rest.ptr, rest.len), n += rest.len;
  e[n++] = '\n', e[n] = 0;
  server.again = true; // held reads of /wsys/events may go on
}

typedef struct binding {
  uint32_t mods, usage;
  char verb[48];
} binding;
static binding bindings[BINDINGS];
static uint32_t nbindings;

// A key's name in a binding (super+shift+h): its modifiers and its usage; false if it is none.
static bool parse_key(vx_str s, uint32_t *mods, uint32_t *usage) {
  *mods = 0, *usage = 0;
  while (s.len) {
    size_t n = 0;
    while (n < s.len && s.ptr[n] != '+') n++;
    vx_str part = {s.ptr, n};
    s.ptr += n, s.len -= n;
    if (s.len) s.ptr++, s.len--; // the '+'
    if (vx_str_eq(part, VX_STR("super")) || vx_str_eq(part, VX_STR("meta"))) {
      *mods |= VX_MOD_META;
    } else if (vx_str_eq(part, VX_STR("shift"))) {
      *mods |= VX_MOD_SHIFT;
    } else if (vx_str_eq(part, VX_STR("ctrl"))) {
      *mods |= VX_MOD_CTRL;
    } else if (vx_str_eq(part, VX_STR("alt"))) {
      *mods |= VX_MOD_ALT;
    } else if (s.len) {
      return false; // a key before the last part
    } else if (part.len == 1 && part.ptr[0] >= 'a' && part.ptr[0] <= 'z') {
      *usage = VX_HID_KEYBOARD | (uint32_t)(0x04 + part.ptr[0] - 'a');
    } else if (part.len == 1 && part.ptr[0] >= '1' && part.ptr[0] <= '9') {
      *usage = VX_HID_KEYBOARD | (uint32_t)(0x1e + part.ptr[0] - '1');
    } else if (part.len == 1 && part.ptr[0] == '0') {
      *usage = VX_HID_KEYBOARD | 0x27;
    } else {
      static const struct {
        const char *name;
        uint32_t id;
      } NAMES[] = {{"enter", 0x28}, {"escape", 0x29}, {"backspace", 0x2a}, {"tab", 0x2b},  {"space", 0x2c},
                   {"minus", 0x2d}, {"equal", 0x2e},  {"right", 0x4f},     {"left", 0x50}, {"down", 0x51},
                   {"up", 0x52},    {"f1", 0x3a},     {"f2", 0x3b},        {"f3", 0x3c},   {"f4", 0x3d}};
      for (size_t i = 0; i < sizeof NAMES / sizeof NAMES[0]; i++)
        if (vx_str_eq(part, vx_cstr(NAMES[i].name))) *usage = VX_HID_KEYBOARD | NAMES[i].id;
    }
  }
  return *usage != 0;
}

// /wsys/keys written: its `bind key=… do=…` records replace the bindings.
static vx_status set_bindings(const uint8_t *buf, uint32_t len) {
  static char scratch[4096];
  vx_ndb_reader r = {.src = {(const char *)buf, len}, .scratch = scratch, .scratch_cap = sizeof scratch};
  vx_ndb_record rec;
  uint32_t n = 0;
  static binding next[BINDINGS];
  int got;
  while ((got = vx_ndb_next(&r, &rec)) == VX_NDB_RECORD) {
    if (!vx_ndb_has(&rec, "bind")) continue;
    vx_str key = vx_ndb_get(&rec, "key"), verb = vx_ndb_get(&rec, "do");
    if (n == BINDINGS || !verb.len || verb.len >= sizeof next[0].verb) return VX_ERR_RANGE;
    next[n] = (binding){};
    if (!parse_key(key, &next[n].mods, &next[n].usage)) return VX_ERR_INVALID;
    memcpy(next[n].verb, verb.ptr, verb.len);
    n++;
  }
  if (got != VX_NDB_END) return VX_ERR_INVALID;
  memcpy(bindings, next, sizeof next), nbindings = n;
  return VX_OK;
}

// --- Text ---

static enum vx_keymap_layout layout = VX_LAYOUT_US;
static constexpr uint32_t COMPOSE_KEY = VX_HID_KEYBOARD | 0x65; // the compose (application) key
static constexpr vx_duration REPEAT_DELAY = 500'000'000, REPEAT_EVERY = 33'333'333;

// The key repeating, while it is held in the focused window.
typedef struct repeat_state {
  bool on;
  vx_input_key key;
  vx_instant at; // the next repeat
} repeat_state;
static repeat_state repeating;

static void send_text(window *w, uint32_t ordinal, const char *text, uint32_t len, int32_t cursor) {
  if (len > VX_WSYS_TEXT) len = (uint32_t)vx_utf_cut(text, len, VX_WSYS_TEXT);
  if (ordinal == VX_WSYS_PREEDIT) {
    vx_wsys_preedit m = {.h = {.ordinal = ordinal}, .len = len, .cursor = cursor};
    memcpy(m.text, text, len);
    send(w, &m, sizeof m);
  } else {
    vx_wsys_commit m = {.h = {.ordinal = ordinal}, .len = len};
    memcpy(m.text, text, len);
    send(w, &m, sizeof m);
  }
}

static void send_rune(window *w, uint32_t ordinal, uint32_t r) {
  char b[4];
  size_t n = r ? vx_runetochar(b, r) : 0;
  send_text(w, ordinal, b, (uint32_t)n, (int32_t)n);
}

// Whether a rune is text to commit: printable, or a newline or a tab;
// control characters are commands, the KEY's.
static bool is_text(uint32_t r) { return r == '\n' || r == '\t' || (r >= 0x20 && r != 0x7f); }

// The built-in composer: a key's text as COMMIT and the key passed on, or
// the key taken into a dead key's or the compose key's sequence.
static void compose_key(window *w, const vx_input_key *k) {
  if (k->action == VX_KEY_UP) {
    send_key(w, k, VX_WSYS_IMEPASS);
    return;
  }
  if (k->usage == COMPOSE_KEY) { // a sequence of two follows
    w->compose = 1, w->dead = 0;
    return;
  }
  uint32_t r = vx_keymap_rune(k->usage, k->mods);
  if (!r) { // a modifier, a function key: no text
    send_key(w, k, VX_WSYS_IMEPASS);
    return;
  }
  if (w->compose == 1) {
    w->compose = is_text(r) ? 2 : 0, w->compose_first = r;
    send_rune(w, VX_WSYS_PREEDIT, w->compose ? r : 0);
    return;
  }
  if (w->compose == 2) { // a pair that makes nothing is dropped, as X11's compose drops it
    uint32_t made = vx_keymap_combine(w->compose_first, r);
    w->compose = 0;
    send_rune(w, VX_WSYS_PREEDIT, 0);
    if (made) send_rune(w, VX_WSYS_COMMIT, made);
    return;
  }
  if (w->dead) { // the accent on this key; with a space, the accent alone; else both
    uint32_t accent = w->dead, made = r == ' ' ? accent : vx_keymap_combine(accent, r);
    w->dead = 0;
    send_rune(w, VX_WSYS_PREEDIT, 0);
    if (made) {
      send_rune(w, VX_WSYS_COMMIT, made);
      return;
    }
    send_rune(w, VX_WSYS_COMMIT, accent);
  }
  uint32_t accent = vx_keymap_dead(layout, k->usage, k->mods);
  if (accent && k->action == VX_KEY_DOWN) {
    w->dead = accent;
    send_rune(w, VX_WSYS_PREEDIT, accent);
    return;
  }
  if (is_text(r)) send_rune(w, VX_WSYS_COMMIT, r);
  send_key(w, k, VX_WSYS_IMEPASS);
}

// --- The input method (/wsys/ime) ---

static constexpr uint32_t IME_QUEUE = 32;
static constexpr vx_duration IME_WAIT = 300'000'000; // an answer later than this: the key passes on

static struct {
  int slot; // the window's
  vx_input_key key;
  uint64_t seq;
  vx_instant sent; // 0: an UP, waiting its turn, never sent
} imeq[IME_QUEUE];
static uint32_t ime_head, ime_count;
static uint64_t ime_seq;

// The queue's head, if it can go on: an UP goes to its window at once, a
// key with an answer or past IME_WAIT as the answer said.
static void ime_flush(const vx_wsys_ime_answer *a);

static void ime_send(uint32_t at) {
  window *w = &wins[imeq[at].slot];
  vx_wsys_ime_key m = {
      .h = {.ordinal = VX_WSYS_IME_KEY}, .seq = imeq[at].seq, .window = w->id, .key = imeq[at].key};
  memcpy(m.purpose, w->purpose, sizeof m.purpose);
  imeq[at].sent = vx_now();
  if (vx_channel_write(ime_ch, &m, sizeof m, nullptr, 0) != VX_OK)
    imeq[at].sent = 1; // passes at the next tick
}

static void ime_key(int slot, const vx_input_key *k) {
  if (ime_count == IME_QUEUE) { // the IME is far behind: the key passes on
    send_key(&wins[slot], k, VX_WSYS_IMEPASS);
    return;
  }
  uint32_t at = (ime_head + ime_count++) % IME_QUEUE;
  imeq[at].slot = slot, imeq[at].key = *k, imeq[at].seq = ++ime_seq, imeq[at].sent = 0;
  if (k->action != VX_KEY_UP) ime_send(at);
  ime_flush(nullptr);
}

static void ime_apply(window *w, const vx_wsys_ime_answer *a, const vx_input_key *k) {
  uint32_t commit = a->commit_len <= VX_WSYS_TEXT ? a->commit_len : 0;
  uint32_t preedit = a->preedit_len <= VX_WSYS_TEXT ? a->preedit_len : 0; // an IME's word, bounded
  if (a->delete_before || a->delete_after) {
    vx_wsys_delete d = {
        .h = {.ordinal = VX_WSYS_DELETE_SURROUNDING}, .before = a->delete_before, .after = a->delete_after};
    send(w, &d, sizeof d);
  }
  if (commit && vx_utf_valid(a->text, commit)) send_text(w, VX_WSYS_COMMIT, a->text, commit, 0);
  if (vx_utf_valid(a->text + commit, preedit))
    send_text(w, VX_WSYS_PREEDIT, a->text + commit, preedit, a->cursor);
  if (a->flags & VX_WSYS_IME_PASS) send_key(w, k, VX_WSYS_IMEPASS);
}

static void ime_flush(const vx_wsys_ime_answer *a) {
  vx_instant now = vx_now();
  while (ime_count) {
    uint32_t at = ime_head;
    bool answered = a && imeq[at].sent && a->seq == imeq[at].seq;
    bool late = imeq[at].sent && now - imeq[at].sent > IME_WAIT;
    if (imeq[at].sent && !answered && !late) return; // waiting for the IME
    window *w = &wins[imeq[at].slot];
    if (w->used && answered)
      ime_apply(w, a, &imeq[at].key), a = nullptr;
    else if (w->used)
      send_key(w, &imeq[at].key, VX_WSYS_IMEPASS); // an UP, or the IME too slow: passed on
    ime_head = (ime_head + 1) % IME_QUEUE, ime_count--;
  }
}

static void ime_end(void) {
  vx_handle_close(ime_ch);
  ime_ch = VX_HANDLE_NONE;
  for (uint32_t i = 0; i < ime_count; i++) imeq[(ime_head + i) % IME_QUEUE].sent = 1; // all late now
  ime_flush(nullptr);
}

// A key for window w, by its IME: none (the KEY alone), an input method's,
// or the built-in composer.
static void deliver_key(window *w, const vx_input_key *k) {
  if (!w->ime_on)
    send_key(w, k, 0);
  else if (ime_ch || ime_count)
    ime_key((int)(w - wins), k);
  else
    compose_key(w, k);
}

// The input method's answers.
static void on_ime(void) {
  for (;;) {
    static vx_wsys_ime_answer a;
    vx_msg_size size;
    vx_handle h[VX_CHANNEL_MAX_HANDLES];
    vx_status st = vx_channel_read(ime_ch, &a, sizeof a, h, VX_CHANNEL_MAX_HANDLES, &size);
    if (st == VX_ERR_SHOULD_WAIT) break;
    if (st != VX_OK) {
      ime_end();
      return;
    }
    for (uint32_t i = 0; i < size.handles; i++) vx_handle_close(h[i]);
    if (size.bytes == sizeof a && a.h.ordinal == VX_WSYS_IME_ANSWER) ime_flush(&a);
  }
  vx_port_bind(server.port, ime_ch, VX_TRIGGER_READABLE, KEY_IME, 0);
}

// Focus to slot i (-1: none): the old window's held keys released, both
// told by CONFIGURE, the new one raised.
static void focus_window(int i) {
  if (ptr.focus == i) return;
  int old = ptr.focus;
  ptr.focus = i;
  if (old >= 0) {
    window *o = &wins[old];
    damage(frame_rect(o)); // its title, inactive
    for (uint32_t k = 0; k < o->nkeys; k++) {
      vx_input_key up = {.time = (uint64_t)vx_now(), .usage = o->keys[k], .action = VX_KEY_UP};
      send_key(o, &up, VX_WSYS_SYNTHETIC);
    }
    o->nkeys = 0, o->dead = 0, o->compose = 0;
    repeating.on = false;
    configure(o);
  }
  if (i >= 0) {
    raise_window(&wins[i]);
    configure(&wins[i]);
    event_line("focus", wins[i].id, (vx_str){});
  }
}

static vx_status window_ctl(window *w, vx_str cmd);
static vx_status root_ctl(vx_str cmd);
static bool take_word(vx_str *s, const char *word);

// A binding's verb: the focused window's, the focus's, or wm's.
static void bound(const binding *b) {
  vx_str verb = vx_cstr(b->verb), cmd = verb;
  window *w = ptr.focus >= 0 ? &wins[ptr.focus] : nullptr;
  static const char *const WINDOW_VERBS[] = {"close", "raise", "move", "resize"};
  for (size_t i = 0; i < sizeof WINDOW_VERBS / sizeof WINDOW_VERBS[0]; i++)
    if (take_word(&cmd, WINDOW_VERBS[i])) {
      if (w) window_ctl(w, verb);
      return;
    }
  if (take_word(&cmd, "focus")) {
    root_ctl(verb);
    return;
  }
  event_line("do", w ? w->id : 0, verb); // wm's
}

// Keys bound (their DOWNs; their UPs and repeats dropped too).
static uint32_t bound_keys[VX_INPUT_HELD], nbound_keys;

static bool binding_takes(const vx_input_key *k) {
  for (uint32_t i = 0; i < nbound_keys; i++)
    if (bound_keys[i] == k->usage) {
      if (k->action == VX_KEY_UP) bound_keys[i] = bound_keys[--nbound_keys];
      return true;
    }
  if (k->action != VX_KEY_DOWN) return false;
  uint32_t mods = k->mods & (VX_MOD_SHIFT | VX_MOD_CTRL | VX_MOD_ALT | VX_MOD_META);
  for (uint32_t i = 0; i < nbindings; i++)
    if (bindings[i].usage == k->usage && bindings[i].mods == mods) {
      if (nbound_keys < VX_INPUT_HELD) bound_keys[nbound_keys++] = k->usage;
      bound(&bindings[i]);
      return true;
    }
  return false;
}

static void on_key(const vx_input_key *k) {
  if (prompt.showing >= 0) { // the prompt takes every key: escape denies
    if (k->action == VX_KEY_DOWN && k->usage == (VX_HID_KEYBOARD | 0x29) &&
        vx_now() - prompt.since >= PROMPT_ARMING)
      prompt_answer(false);
    return;
  }
  if (k->action == VX_KEY_REPEAT || binding_takes(k)) return; // a device's own repeats: winsrv makes its own
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
  // Repeat: the newest key down that is not a modifier, until it is let go.
  bool modifier =
      (k->usage & 0xffff) >= 0xe0 || k->usage == (VX_HID_KEYBOARD | 0x39) || k->usage == COMPOSE_KEY;
  if (k->action == VX_KEY_DOWN && !modifier)
    repeating = (repeat_state){.on = true, .key = *k, .at = vx_now() + REPEAT_DELAY};
  if (k->action == VX_KEY_UP && repeating.on && repeating.key.usage == k->usage) repeating.on = false;
  deliver_key(w, k);
}

// The server's tick: repeats due, and an input method's late answers.
static vx_instant tick(void *ctx) {
  (void)ctx;
  vx_instant now = vx_now();
  if (repeating.on && ptr.focus >= 0 && now >= repeating.at) {
    vx_input_key k = repeating.key;
    k.action = VX_KEY_REPEAT, k.time = (uint64_t)now;
    deliver_key(&wins[ptr.focus], &k);
    repeating.at += REPEAT_EVERY;
    if (repeating.at < now) repeating.at = now + REPEAT_EVERY; // fallen behind: no burst of repeats
  }
  if (ime_count) ime_flush(nullptr);
  vx_instant next = repeating.on ? repeating.at : VX_INFINITE;
  if (ime_count && imeq[ime_head].sent && imeq[ime_head].sent + IME_WAIT < next)
    next = imeq[ime_head].sent + IME_WAIT;
  return next;
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
  if (prompt.showing >= 0) { // the prompt takes every click: a press and its release on one button answers
    d->buttons = p->buttons;
    uint32_t now_buttons = 0;
    for (uint32_t i = 0; i < IN_DEVICES; i++) now_buttons |= indev[i].buttons;
    int over = 0; // the button under the pointer
    if (inside(prompt_button(1), ptr.x, ptr.y)) over = 1;
    if (inside(prompt_button(2), ptr.x, ptr.y)) over = 2;
    if (!before && now_buttons) {
      prompt.pressed = vx_now() - prompt.since >= PROMPT_ARMING ? over : 0; // too soon: ignored
      if (!prompt.pressed) vx_print(VX_STR("winsrv: a click the prompt ignored\n"));
      damage(prompt_rect());
    } else if (before && !now_buttons) {
      int pressed = prompt.pressed;
      prompt.pressed = 0;
      damage(prompt_rect());
      if (pressed && pressed == over) prompt_answer(pressed == 1);
    }
    ptr.buttons = now_buttons;
    return;
  }
  d->buttons = p->buttons;
  ptr.buttons = 0;
  for (uint32_t i = 0; i < IN_DEVICES; i++) ptr.buttons |= indev[i].buttons;
  enum part part = PART_CLIENT;
  if (!before && ptr.buttons) { // a press: focus and raise the window under it; then latch it, or drag it
    int under = window_at(ptr.x, ptr.y, &part);
    focus_window(under);
    if (under >= 0 && part != PART_CLIENT && part != PART_BORDER) {
      if (part == PART_TITLE)
        ptr.drag = DRAG_MOVE;
      else if (part == PART_CORNER)
        ptr.drag = DRAG_RESIZE;
      else
        ptr.drag = DRAG_CLOSE;
      ptr.dragged = under, ptr.from_x = ptr.x, ptr.from_y = ptr.y, ptr.start = wins[under].r;
    }
    if (part == PART_CLIENT) ptr.latch = under;
  }
  if (ptr.dragged >= 0) { // the server's drag: the app sees none of it
    drag_to();
    if (!ptr.buttons) drag_end();
    return;
  }
  int to = ptr.latch;
  if (to < 0) {
    to = window_at(ptr.x, ptr.y, &part);
    if (part != PART_CLIENT) to = -1; // over a decoration or the desk: no app's
  }
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
enum : uint64_t {
  ROOT = 1,
  INFO,
  OUTPUTS,
  WINDOWS,
  THEME,
  T_ACTIVE,
  T_TOKENS,
  T_CTL,
  R_KEYMAP,
  R_IME,
  R_KEYS,
  R_EVENTS,
  R_CTL,
  R_PROMPT,
  R_OPENED, // and up: /wsys/events opened, one node each
};
static constexpr uint64_t P_OPENED = R_OPENED + 16; // and up: /wsys/prompt opened, one node each
static constexpr uint64_t WIN = 0x100;
enum : uint64_t { W_DIR = 0, W_CTL, W_INFO, W_FRAME, W_SURFACE, W_KEYMAP, W_IME, W_FILES };
static const vx_str W_NAMES[W_FILES] = {
    {}, VX_STR("ctl"), VX_STR("info"), VX_STR("frame"), VX_STR("surface"), VX_STR("keymap"), VX_STR("ime")};

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
    else if (vx_str_eq(name, VX_STR("theme")))
      *child = THEME;
    else if (vx_str_eq(name, VX_STR("keymap")))
      *child = R_KEYMAP;
    else if (vx_str_eq(name, VX_STR("ime")))
      *child = R_IME;
    else if (vx_str_eq(name, VX_STR("keys")))
      *child = R_KEYS;
    else if (vx_str_eq(name, VX_STR("events")))
      *child = R_EVENTS;
    else if (vx_str_eq(name, VX_STR("ctl")))
      *child = R_CTL;
    else if (vx_str_eq(name, VX_STR("prompt")))
      *child = R_PROMPT;
    else
      return VX_ERR_NOT_FOUND;
    return VX_OK;
  }
  if (dir == THEME) {
    if (vx_str_eq(name, VX_STR("active")))
      *child = T_ACTIVE;
    else if (vx_str_eq(name, VX_STR("tokens")))
      *child = T_TOKENS;
    else if (vx_str_eq(name, VX_STR("ctl")))
      *child = T_CTL;
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
  if (n == ROOT || n == INFO || n == OUTPUTS || n == WINDOWS || n == THEME || (n >= R_KEYMAP && n < WIN))
    *parent = ROOT;
  else if (n >= T_ACTIVE && n <= T_CTL)
    *parent = THEME;
  else if ((n - WIN) % 8 == W_DIR)
    *parent = WINDOWS;
  else
    *parent = n - (n - WIN) % 8;
  return VX_OK;
}

// A node's name, whether it is a directory, and its mode; empty if no such node.
static vx_str name_of(uint64_t n, bool *dir, uint32_t *mode) {
  static char name[12];
  *dir = n == ROOT || n == OUTPUTS || n == WINDOWS || n == THEME, *mode = 0444;
  if (n == ROOT) return VX_STR("/");
  if (n == INFO) return VX_STR("info");
  if (n == OUTPUTS) return VX_STR("outputs");
  if (n == WINDOWS) return VX_STR("windows");
  if (n == THEME) return VX_STR("theme");
  if (n == T_ACTIVE) return VX_STR("active");
  if (n == T_TOKENS) return VX_STR("tokens");
  if (n == T_CTL) return *mode = 0220, VX_STR("ctl");
  if (n == R_KEYMAP) return *mode = 0664, VX_STR("keymap");
  if (n == R_IME) return *mode = 0660, VX_STR("ime");
  if (n == R_KEYS) return *mode = 0664, VX_STR("keys");
  if (n == R_EVENTS || (n >= R_OPENED && n < R_OPENED + EVENT_OPENS)) return VX_STR("events");
  if (n == R_CTL) return *mode = 0220, VX_STR("ctl");
  if (n == R_PROMPT || (n >= P_OPENED && n < P_OPENED + PROMPTS)) return *mode = 0660, VX_STR("prompt");
  const window *w = window_of(n);
  if (!w) return (vx_str){};
  uint64_t f = (n - WIN) % 8;
  if (f == W_CTL) *mode = 0220;
  if (f == W_SURFACE || f == W_IME) *mode = 0660;
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
  if (f == W_CTL || n == T_CTL || n == R_CTL) return (mode & 3) == P9_OWRITE ? VX_OK : VX_ERR_ACCESS;
  if (n == R_KEYS) return (mode & 3) == P9_OREAD || (mode & 3) == P9_OWRITE ? VX_OK : VX_ERR_ACCESS;
  if (n == R_PROMPT) return (mode & 3) == P9_ORDWR ? VX_OK : VX_ERR_ACCESS;
  if (f == W_SURFACE || n == R_IME) return (mode & 3) == P9_ORDWR ? VX_OK : VX_ERR_ACCESS;
  if (f == W_IME || n == R_KEYMAP)
    return (mode & 3) == P9_OREAD || (mode & 3) == P9_OWRITE ? VX_OK : VX_ERR_ACCESS;
  return (mode & 3) == P9_OREAD ? VX_OK : VX_ERR_ACCESS;
}

// The surface opened: the window's channel, beside the Ropen; CONFIGURE and
// a FRAME (its first credit) on it at once.
static vx_status fs_open_handle(void *ctx, uint64_t n, uint8_t mode, vx_handle *out_handle) {
  (void)ctx, (void)mode;
  if (n == R_IME) { // an input method: its channel, one at a time
    if (ime_ch) return VX_ERR_BAD_STATE;
    vx_handle ends[2];
    vx_status st = vx_channel_create(0, ends);
    if (st != VX_OK) return st;
    ime_ch = ends[0], *out_handle = ends[1];
    vx_port_bind(server.port, ime_ch, VX_TRIGGER_READABLE, KEY_IME, 0);
    vx_print(VX_STR("winsrv: an input method holds /wsys/ime\n"));
    return VX_OK;
  }
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

// /wsys/events opened: a node of its own, reading from the oldest event kept.
static vx_status fs_clone(void *ctx, uint64_t n, uint8_t mode, uint64_t *opened) {
  (void)ctx, (void)mode;
  if (n == R_PROMPT) { // a question of its own
    for (uint32_t i = 0; i < PROMPTS; i++)
      if (!prompts[i].used) {
        prompts[i] = (prompt_req){.used = true};
        *opened = P_OPENED + i;
        return VX_OK;
      }
    return VX_ERR_NO_MEMORY;
  }
  if (n != R_EVENTS) return VX_ERR_NOT_FOUND;
  for (uint32_t i = 0; i < EVENT_OPENS; i++)
    if (!event_opens[i].used) {
      event_opens[i] = (event_open){.used = true, .at = events_next > EVENTS ? events_next - EVENTS : 0};
      *opened = R_OPENED + i;
      return VX_OK;
    }
  return VX_ERR_NO_MEMORY;
}

static void fs_clunk(void *ctx, uint64_t n, bool opened) {
  (void)ctx, (void)opened;
  if (n >= R_OPENED && n < R_OPENED + EVENT_OPENS) event_opens[n - R_OPENED] = (event_open){};
  if (n >= P_OPENED && n < P_OPENED + PROMPTS) { // a question let go: off the screen, if it was on it
    prompts[n - P_OPENED] = (prompt_req){};
    if (prompt.showing == (int)(n - P_OPENED)) prompt_next();
  }
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
  } else if (n >= P_OPENED && n < P_OPENED + PROMPTS) { // the answer, once there is one
    prompt_req *r = &prompts[n - P_OPENED];
    if (!r->asked) return VX_ERR_BAD_STATE;
    if (!r->answered) return VX_ERR_SHOULD_WAIT;
    vx_str a = r->allow ? VX_STR("allow\n") : VX_STR("deny\n");
    *count = *count < a.len ? *count : (uint32_t)a.len; // whatever the offset: its write moved it
    memcpy(buf, a.ptr, *count);
    return VX_OK;
  } else if (n == R_KEYS) {
    for (uint32_t i = 0; i < nbindings; i++) {
      vx_ndb_flag(&t, "bind");
      vx_ndb_put(&t, "do", vx_cstr(bindings[i].verb));
      vx_ndb_end(&t);
    }
  } else if (n >= R_OPENED && n < R_OPENED + EVENT_OPENS) { // whole lines from where it is; held if none
    event_open *o = &event_opens[n - R_OPENED];
    uint64_t oldest = events_next > EVENTS ? events_next - EVENTS : 0;
    if (o->at < oldest) o->at = oldest;
    uint32_t got = 0;
    for (; o->at < events_next; o->at++) {
      vx_str e = vx_cstr(events[o->at % EVENTS]);
      if (got + e.len > *count) break;
      memcpy(buf + got, e.ptr, e.len), got += (uint32_t)e.len;
    }
    if (!got) return VX_ERR_SHOULD_WAIT;
    *count = got;
    return VX_OK;
  } else if (n == R_KEYMAP || (w && (n - WIN) % 8 == W_KEYMAP)) {
    vx_str a = vx_cstr(VX_KEYMAP_NAMES[layout]);
    memcpy(text, a.ptr, a.len), text[a.len] = '\n', t.len = a.len + 1;
  } else if (w && (n - WIN) % 8 == W_IME) {
    vx_ndb_flag(&t, w->ime_on ? "enabled" : "disabled");
    vx_ndb_put(&t, "purpose", vx_cstr(w->purpose[0] ? w->purpose : "text"));
    vx_ndb_end(&t);
  } else if (n == T_ACTIVE) {
    vx_str a = vx_cstr(tok.name);
    memcpy(text, a.ptr, a.len), text[a.len] = '\n', t.len = a.len + 1;
  } else if (n == T_TOKENS) {
    for (size_t i = 0; i < sizeof TOKENS / sizeof TOKENS[0]; i++) {
      char hex[8];
      static const char DIGITS[] = "0123456789abcdef";
      hex[0] = '#';
      for (int k = 0; k < 6; k++) hex[1 + k] = DIGITS[*TOKENS[i].at >> (20 - 4 * k) & 15];
      vx_ndb_put(&t, TOKENS[i].name, (vx_str){hex, 7});
    }
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

// A window's ctl: move X Y · resize W H · title TEXT · raise · close.
static vx_status window_ctl(window *w, vx_str cmd) {
  vx_status st = VX_OK;
  if (take_word(&cmd, "move")) {
    int32_t x = (int32_t)parse_u32(&cmd), y = (int32_t)parse_u32(&cmd);
    damage(frame_rect(w));
    w->r.x = x, w->r.y = y;
    damage(frame_rect(w));
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
  return st;
}

// The root's ctl: focus N · focus next · focus prev (by stacking, from the focused window).
static vx_status root_ctl(vx_str cmd) {
  if (!take_word(&cmd, "focus")) return VX_ERR_INVALID;
  while (cmd.len && cmd.ptr[0] == ' ') cmd.ptr++, cmd.len--;
  if (!nstack) return VX_OK;
  bool next = vx_str_eq(cmd, VX_STR("next")), prev = vx_str_eq(cmd, VX_STR("prev"));
  if (next || prev) { // round the windows in the order they were made, by their slots
    int at = ptr.focus;
    for (uint32_t k = 0; k < MAX_WINDOWS; k++) {
      at = (int)(((uint32_t)(at + (int)MAX_WINDOWS) + (next ? 1u : MAX_WINDOWS - 1)) % MAX_WINDOWS);
      if (wins[at].used) break;
    }
    focus_window(at);
    return VX_OK;
  }
  uint32_t id = parse_u32(&cmd);
  window *w = cmd.len ? nullptr : window_of_id(id);
  if (!w) return VX_ERR_NOT_FOUND;
  focus_window((int)(w - wins));
  return VX_OK;
}

// The theme's ctl: `load NAME`, a shipped theme's tokens; `set TOKEN #rrggbb`.
static vx_status theme_ctl(vx_str cmd) {
  if (take_word(&cmd, "load")) {
    while (cmd.len && cmd.ptr[0] == ' ') cmd.ptr++, cmd.len--;
    for (size_t i = 0; i < sizeof THEMES / sizeof THEMES[0]; i++)
      if (vx_str_eq(cmd, vx_cstr(THEMES[i].name))) {
        tok = THEMES[i];
        damage(screen_rect()); // the whole screen repainted at the next frame
        return VX_OK;
      }
    return VX_ERR_NOT_FOUND;
  }
  if (!take_word(&cmd, "set")) return VX_ERR_INVALID;
  while (cmd.len && cmd.ptr[0] == ' ') cmd.ptr++, cmd.len--;
  size_t name_len = 0;
  while (name_len < cmd.len && cmd.ptr[name_len] != ' ') name_len++;
  vx_str name = {cmd.ptr, name_len}, value = {cmd.ptr + name_len, cmd.len - name_len};
  while (value.len && value.ptr[0] == ' ') value.ptr++, value.len--;
  if (value.len != 7 || value.ptr[0] != '#') return VX_ERR_INVALID;
  uint32_t v = 0;
  for (size_t k = 1; k < 7; k++) {
    char c = value.ptr[k];
    uint32_t d = 16;
    if (c >= '0' && c <= '9') d = (uint32_t)(c - '0');
    if (c >= 'a' && c <= 'f') d = (uint32_t)(c - 'a' + 10);
    if (d == 16) return VX_ERR_INVALID;
    v = v << 4 | d;
  }
  for (size_t i = 0; i < sizeof TOKENS / sizeof TOKENS[0]; i++)
    if (vx_str_eq(name, vx_cstr(TOKENS[i].name))) {
      *TOKENS[i].at = v;
      damage(screen_rect());
      return VX_OK;
    }
  return VX_ERR_NOT_FOUND;
}

// A window's ime file: enable · disable · purpose WORD · rect X Y W H ·
// surrounding TEXT CURSOR ANCHOR (the last two kept for an input method,
// 7d2b takes them and goes on).
static vx_status ime_ctl(window *w, vx_str cmd) {
  if (take_word(&cmd, "enable")) {
    w->ime_on = true;
  } else if (take_word(&cmd, "disable")) {
    w->ime_on = false, w->dead = 0, w->compose = 0;
    send_rune(w, VX_WSYS_PREEDIT, 0);
  } else if (take_word(&cmd, "purpose")) {
    while (cmd.len && cmd.ptr[0] == ' ') cmd.ptr++, cmd.len--;
    static const char *const PURPOSES[] = {"text", "password", "number", "url", "email", "terminal"};
    bool known = false;
    for (size_t i = 0; i < sizeof PURPOSES / sizeof PURPOSES[0]; i++)
      known |= vx_str_eq(cmd, vx_cstr(PURPOSES[i]));
    if (!known) return VX_ERR_INVALID;
    memset(w->purpose, 0, sizeof w->purpose);
    memcpy(w->purpose, cmd.ptr, cmd.len);
  } else if (!take_word(&cmd, "rect") && !take_word(&cmd, "surrounding")) {
    return VX_ERR_INVALID;
  }
  return VX_OK;
}

static vx_status fs_write(void *ctx, uint64_t n, uint64_t offset, const uint8_t *buf, uint32_t *count) {
  (void)ctx, (void)offset;
  if (n >= P_OPENED && n < P_OPENED + PROMPTS) { // `ask TEXT`, once; nothing written answers it
    prompt_req *r = &prompts[n - P_OPENED];
    vx_str cmd = {(const char *)buf, *count};
    while (cmd.len && (cmd.ptr[cmd.len - 1] == '\n' || cmd.ptr[cmd.len - 1] == ' ')) cmd.len--;
    if (!take_word(&cmd, "ask")) {
      *count = 0;
      return VX_ERR_ACCESS; // only a person answers, with the keyboard or the pointer
    }
    if (r->asked) {
      *count = 0;
      return VX_ERR_BAD_STATE;
    }
    while (cmd.len && cmd.ptr[0] == ' ') cmd.ptr++, cmd.len--;
    size_t len = cmd.len < sizeof r->question - 1 ? cmd.len : sizeof r->question - 1;
    memcpy(r->question, cmd.ptr, len), r->question[len] = 0;
    r->asked = true, r->seq = ++prompt_seq;
    if (prompt.showing < 0) prompt_next();
    return VX_OK;
  }
  if (n == R_KEYS) { // one write, the whole table: it replaces the bindings
    vx_status st = set_bindings(buf, *count);
    if (st != VX_OK) *count = 0;
    return st;
  }
  if (n == R_CTL) {
    vx_str cmd = {(const char *)buf, *count};
    while (cmd.len && (cmd.ptr[cmd.len - 1] == '\n' || cmd.ptr[cmd.len - 1] == ' ')) cmd.len--;
    vx_status st = root_ctl(cmd);
    if (st != VX_OK) *count = 0;
    return st;
  }
  if (n == R_KEYMAP) { // a layout by name: KEYMAP to every window
    vx_str cmd = {(const char *)buf, *count};
    while (cmd.len && (cmd.ptr[cmd.len - 1] == '\n' || cmd.ptr[cmd.len - 1] == ' ')) cmd.len--;
    for (uint32_t l = 0; l < VX_LAYOUTS; l++)
      if (vx_str_eq(cmd, vx_cstr(VX_KEYMAP_NAMES[l]))) {
        layout = (enum vx_keymap_layout)l;
        vx_wsys_keymap m = {.h = {.ordinal = VX_WSYS_KEYMAP}};
        memcpy(m.name, cmd.ptr, cmd.len);
        for (uint32_t i = 0; i < MAX_WINDOWS; i++)
          if (wins[i].used) wins[i].dead = 0, wins[i].compose = 0, send(&wins[i], &m, sizeof m);
        return VX_OK;
      }
    *count = 0;
    return VX_ERR_NOT_FOUND;
  }
  if (n == T_CTL) {
    vx_str cmd = {(const char *)buf, *count};
    while (cmd.len && (cmd.ptr[cmd.len - 1] == '\n' || cmd.ptr[cmd.len - 1] == ' ')) cmd.len--;
    vx_status st = theme_ctl(cmd);
    if (st != VX_OK) *count = 0;
    return st;
  }
  window *w = window_of(n);
  if (w && (n - WIN) % 8 == W_IME) {
    vx_str cmd = {(const char *)buf, *count};
    while (cmd.len && (cmd.ptr[cmd.len - 1] == '\n' || cmd.ptr[cmd.len - 1] == ' ')) cmd.len--;
    vx_status st = ime_ctl(w, cmd);
    if (st != VX_OK) *count = 0;
    return st;
  }
  if (!w || (n - WIN) % 8 != W_CTL) return VX_ERR_ACCESS;
  vx_str cmd = {(const char *)buf, *count};
  while (cmd.len && (cmd.ptr[cmd.len - 1] == '\n' || cmd.ptr[cmd.len - 1] == ' ')) cmd.len--;
  vx_status st = window_ctl(w, cmd);
  if (st != VX_OK) *count = 0;
  return st;
}

static vx_status fs_readdir(void *ctx, uint64_t dir, uint32_t index, uint64_t *child) {
  (void)ctx;
  if (dir == ROOT) {
    static const uint64_t ROOT_FILES[] = {INFO,  OUTPUTS, WINDOWS,  THEME, R_KEYMAP,
                                          R_IME, R_KEYS,  R_EVENTS, R_CTL, R_PROMPT};
    if (index >= sizeof ROOT_FILES / sizeof ROOT_FILES[0]) return VX_ERR_NOT_FOUND;
    *child = ROOT_FILES[index];
    return VX_OK;
  }
  if (dir == THEME) {
    if (index > 2) return VX_ERR_NOT_FOUND;
    *child = T_ACTIVE + index;
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
                      .clone = fs_clone,
                      .clunk = fs_clunk,
                      .read = fs_read,
                      .write = fs_write,
                      .readdir = fs_readdir};
  server.name = VX_STR("winsrv");
  server.supported = P9_EXT_XATTR | P9_EXT_SRV;
  server.event = event;
  server.tick = tick;
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
