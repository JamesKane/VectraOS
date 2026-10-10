// vxui.c: vxui v0's implementation (vxui.h; M7 step 7e2). An app is a port
// and its windows; a window is its channel on winsrv (docs/proto/wsys.md),
// made by opening /wsys/new (the app's attach, aname `self`), with two
// vx-buffers drawn in turn. vx_wait turns the window records into events,
// and owes a window a VX_FRAME when it asked to draw and holds a credit.

#pragma once

#include "../vx-wsys/wsysproto.h"
#include "../vx-input/keymap.h"
#include "../vx-font/font.c"
#ifdef __vectraos__
#include <string.h> // memcpy and the rest: the C library's, where vx-rt's are not compiled in
#endif

static constexpr uint32_t VXUI_WINDOWS = 8, VXUI_QUEUE = 32, VXUI_NODES = 128, VXUI_WAKE_KEY = 1000;
static constexpr uint32_t VXUI_REPLAY_EVENTS = 1u << 16, VXUI_REPLAY_TEXT = 4u << 20, VXUI_SCAN = 64u << 10;

// A widget as one frame has it: what is compared with the last frame's to
// find the damage, and kept, by id, as the cache.
typedef struct vxui_node {
  uint64_t id;
  uint8_t kind; // 1 label, 2 button
  uint8_t pressed;
  char text[48];
  int32_t x, y, w, h;
} vxui_node;

typedef struct vxui_buffer {
  vx_buffer buf;
  uint8_t *px;
  uint64_t point;     // its timeline's newest: its release point once presented
  uint64_t presented; // the window's present count when it was last shown; 0: never
  bool attached;
} vxui_buffer;

struct vx_window {
  bool used, closed;
  vx_app *app;
  uint32_t id; // in /wsys
  vx_handle ch;
  vx_wsys_configure cfg;
  uint32_t credits;
  bool redraw, animate, owed; // owed: a VX_FRAME handed out and not yet presented
  uint64_t presents;
  uint64_t span; // the frame's DRAW span (7g1b1), from its handing out; 0: none
  vx_instant prev_presented, last_frame;
  vxui_buffer b[2];
  uint32_t next; // the buffer to draw next
  // The UI's (7e2b): the pointer as the window last saw it, a click's ends,
  // and the last frame's nodes (the cache: rectangles, pressed states).
  bool has_ui;
  int32_t px, py;
  uint32_t buttons;
  bool down_seen, up_seen; // since the last UI frame
  int32_t down_x, down_y, up_x, up_y;
  vxui_node last[VXUI_NODES];
  uint32_t nlast;
  int32_t last_damage[4]; // x0 y0 x1 y1, the last frame's
};

struct vx_canvas {
  vx_window *win;
  vx_pixels px;
};

struct vx_voice {
  vx_sound sound;
};

// Looped playback's (7g2c): the storage as it was at the start, and the
// events vx_wait returned since, each at its time.
typedef struct vxui_replay {
  uint8_t state; // VXUI_OFF, VXUI_RECORDING, VXUI_PLAYING
  vx_app_memory *mem;
  vx_handle snap;        // a lazy VMO: the storage's pages that were not zero, each at its offset
  uint64_t *made;        // which those were, a bit a page
  uint64_t pages;        // the storage's
  uint8_t *buf;          // VXUI_SCAN bytes for copying between the two
  vx_event *events;      // the recording, in a lazy mapping made once
  char *text;            // its VX_TEXTs' bytes, after the events
  uint32_t count, next;  // events recorded; the next to play
  uint32_t frames, used; // VX_FRAMEs among them; text bytes
  vx_instant t0, from;   // the recording's start; this playing's
  vx_duration length;    // how long it recorded
} vxui_replay;

enum : uint8_t { VXUI_OFF, VXUI_RECORDING, VXUI_PLAYING };

struct vx_app {
  char id[64];
  const char *error; // sticky
  vx_handle port;
  vx_window win[VXUI_WINDOWS];
  vx_event queue[VXUI_QUEUE];
  uint32_t head, count;
  vx_canvas canvas;
  vx_voice voice;
  char text[VXUI_QUEUE][VX_WSYS_TEXT + 1]; // each queued VX_TEXT's, by its slot in the queue
  vx_handle wake;                          // a counter: vx_app_wake signals it past wakes_seen
  _Atomic uint64_t wakes;
  uint64_t wakes_seen;
  vxui_replay replay;
};

static vx_app vxui_the_app;

static void vxui_fail(vx_app *app, const char *why) {
  if (!app->error) app->error = why;
}

static void vxui_push(vx_app *app, const vx_event *ev) {
  if (app->count == VXUI_QUEUE) return; // full: the oldest are kept, the newest dropped
  app->queue[(app->head + app->count++) % VXUI_QUEUE] = *ev;
}

// --- The app ---

VXUI_API vx_app *vx_app_open(const char *id) {
  vx_app *app = &vxui_the_app;
  *app = (vx_app){};
  vx_str s = vx_cstr(id);
  memcpy(app->id, s.ptr, s.len < sizeof app->id - 1 ? s.len : sizeof app->id - 1);
  if (vx_port_create(0, &app->port) != VX_OK || vx_counter_create(0, &app->wake) != VX_OK)
    vxui_fail(app, "no port");
  return app;
}

VXUI_API const char *vx_app_error(const vx_app *app) { return app->error; }

VXUI_API void vx_app_wake(vx_app *app) { vx_counter_signal(app->wake, ++app->wakes); }

// --- Windows ---

// A command to one of the window's files in /wsys.
static void vxui_file(vx_window *win, const char *file, const char *cmd) {
  char path[48] = "/wsys/";
  size_t n = 6, d = 0;
  char digits[10];
  uint32_t v = win->id;
  do digits[d++] = (char)('0' + v % 10), v /= 10;
  while (v);
  while (d) path[n++] = digits[--d];
  path[n++] = '/';
  vx_str f = vx_cstr(file);
  memcpy(path + n, f.ptr, f.len), path[n + f.len] = 0;
  vx_fd fd = vx_open(vx_cstr(path), VX_OWRITE);
  if (fd < 0) return;
  vx_write(fd, vx_cstr(cmd));
  vx_close(fd);
}

static void vxui_ctl(vx_window *win, const char *cmd) { vxui_file(win, "ctl", cmd); }

// The window's records, as events; false once its channel has gone.
static bool vxui_drain(vx_window *win) {
  vx_app *app = win->app;
  for (;;) {
    alignas(vx_wsys_configure) uint8_t m[256];
    vx_msg_size size;
    vx_status st = vx_channel_read(win->ch, m, sizeof m, nullptr, 0, &size);
    if (st == VX_ERR_SHOULD_WAIT) return true;
    if (st != VX_OK) return false;
    const vx_msg_header *h = (const vx_msg_header *)m;
    vx_event ev = {.source = (uint64_t)(uintptr_t)win, .time = vx_now()};
    if (h->ordinal == VX_WSYS_CONFIGURE && size.bytes == sizeof(vx_wsys_configure)) {
      const vx_wsys_configure *c = (const vx_wsys_configure *)m;
      bool resized = c->pwidth != win->cfg.pwidth || c->pheight != win->cfg.pheight;
      win->cfg = *c, win->id = c->window;
      ev.kind = VX_CONFIGURE;
      ev.configure.width = c->width, ev.configure.height = c->height,
      ev.configure.focused = c->flags & VX_WSYS_FOCUSED;
      vxui_push(app, &ev);
      if (resized) win->redraw = true;
    } else if (h->ordinal == VX_WSYS_FRAME && size.bytes == sizeof(vx_wsys_frame)) {
      const vx_wsys_frame *f = (const vx_wsys_frame *)m;
      win->credits += f->credits;
      win->prev_presented = (vx_instant)f->prev_presented;
    } else if (h->ordinal == VX_WSYS_KEY && size.bytes == sizeof(vx_wsys_key)) {
      const vx_wsys_key *k = (const vx_wsys_key *)m;
      ev.kind = VX_KEY;
      ev.keyboard.usage = k->key.usage, ev.keyboard.rune = k->rune, ev.keyboard.mods = k->key.mods;
      ev.keyboard.down = k->key.action != VX_KEY_UP, ev.keyboard.repeat = k->key.action == VX_KEY_REPEAT;
      vxui_push(app, &ev);
    } else if (h->ordinal == VX_WSYS_POINTER && size.bytes == sizeof(vx_wsys_pointer)) {
      const vx_wsys_pointer *p = (const vx_wsys_pointer *)m;
      ev.kind = VX_POINTER;
      ev.pointer.x = (float)p->x, ev.pointer.y = (float)p->y, ev.pointer.buttons = p->buttons;
      ev.pointer.wheel = p->wheel;
      vxui_push(app, &ev); // the UI sees it when vx_wait returns it (vxui_seen)
    } else if (h->ordinal == VX_WSYS_COMMIT && size.bytes == sizeof(vx_wsys_commit)) {
      const vx_wsys_commit *c = (const vx_wsys_commit *)m;
      uint32_t len = c->len <= VX_WSYS_TEXT ? c->len : 0;
      char *t = app->text[(app->head + app->count) % VXUI_QUEUE]; // the slot vxui_push puts it in
      memcpy(t, c->text, len), t[len] = 0;
      ev.kind = VX_TEXT, ev.text.text = (vx_str){t, len};
      vxui_push(app, &ev);
    }
  }
}

VXUI_API vx_window *vx_window_open(vx_app *app, const char *title, uint32_t width, uint32_t height) {
  if (app->error) return nullptr;
  vx_window *win = nullptr;
  for (uint32_t i = 0; i < VXUI_WINDOWS && !win; i++)
    if (!app->win[i].used) win = &app->win[i];
  if (!win) {
    vxui_fail(app, "too many windows");
    return nullptr;
  }
  *win = (vx_window){.used = true, .app = app, .redraw = true};
  if (vx_open_post(VX_STR("/wsys/new"), &win->ch) != VX_OK) {
    *win = (vx_window){};
    vxui_fail(app, "no window server: /wsys/new"); // a manifest gives it: mount=/wsys srv=wsys aname=self
    return nullptr;
  }
  for (vx_instant deadline = vx_now() + 5'000'000'000; !win->cfg.seq && vx_now() < deadline;) {
    if (!vxui_drain(win)) break;
    vx_packet pk;
    vx_port_bind(app->port, win->ch, VX_TRIGGER_READABLE, (uint64_t)(win - app->win), 0);
    vx_port_wait(app->port, vx_now() + 100'000'000, 0, &pk, 1);
  }
  if (!win->cfg.seq) {
    vxui_fail(app, "the window server did not answer");
    return nullptr;
  }
  app->count = 0; // the first CONFIGURE is the open's, not news
  vx_window_title(win, title);
  char cmd[40] = "resize ";
  size_t n = 7;
  for (uint32_t v = 0, k = 0; k < 2; k++, n += v) {
    char digits[10];
    uint32_t x = k ? height : width, d = 0;
    do digits[d++] = (char)('0' + x % 10), x /= 10;
    while (x);
    for (v = 0; d; v++) cmd[n + v] = digits[--d];
    if (!k) cmd[n + v++] = ' ';
  }
  cmd[n] = 0;
  vxui_ctl(win, cmd);
  vxui_drain(win); // its CONFIGURE, sent before the write returned (03 §5.1): the first frame its size
  app->count = 0;  // the open's CONFIGUREs, as one: the window's size and focus as it starts
  vx_event ev = {.kind = VX_CONFIGURE, .source = (uint64_t)(uintptr_t)win, .time = vx_now()};
  ev.configure.width = win->cfg.width, ev.configure.height = win->cfg.height;
  ev.configure.focused = win->cfg.flags & VX_WSYS_FOCUSED;
  vxui_push(app, &ev);
  return win;
}

VXUI_API void vx_window_title(vx_window *win, const char *title) {
  if (!win) return;
  char cmd[96] = "title ";
  vx_str t = vx_cstr(title);
  size_t n = t.len < sizeof cmd - 7 ? t.len : sizeof cmd - 7;
  memcpy(cmd + 6, t.ptr, n), cmd[6 + n] = 0;
  vxui_ctl(win, cmd);
}

VXUI_API void vx_window_text_input(vx_window *win, const char *purpose) {
  if (!win) return;
  if (!purpose) {
    vxui_file(win, "ime", "disable");
    return;
  }
  char cmd[32] = "purpose ";
  vx_str p = vx_cstr(purpose);
  size_t n = p.len < sizeof cmd - 9 ? p.len : sizeof cmd - 9;
  memcpy(cmd + 8, p.ptr, n), cmd[8 + n] = 0;
  vxui_file(win, "ime", cmd);
  vxui_file(win, "ime", "enable");
}

VXUI_API void vx_window_redraw(vx_window *win) {
  if (win) win->redraw = true;
}

VXUI_API void vx_window_animate(vx_window *win, bool on) {
  if (win) win->animate = on, win->redraw |= on;
}

// --- The wait ---

typedef enum vxui_got { VXUI_ERROR, VXUI_EVENT, VXUI_NOTHING } vxui_got;

// The next live event, frames among them only when frames; VXUI_NOTHING at
// the deadline, or as soon as want holds a credit or is closed.
static vxui_got vxui_live(vx_app *app, vx_event *ev, vx_instant deadline, bool frames,
                          const vx_window *want) {
  for (;;) {
    if (app->error) return VXUI_ERROR;
    for (uint32_t i = 0; i < VXUI_WINDOWS; i++) { // a frame handed out and never presented is let go
      vx_window *w = &app->win[i];
      if (w->used && w->owed) w->owed = false, w->span = 0;
    }
    if (app->count) {
      *ev = app->queue[app->head];
      app->head = (app->head + 1) % VXUI_QUEUE, app->count--;
      return VXUI_EVENT;
    }
    for (uint32_t i = 0; frames && i < VXUI_WINDOWS;
         i++) { // a frame, to a window that asked and holds a credit
      vx_window *w = &app->win[i];
      if (!w->used || w->closed || !(w->redraw || w->animate) || !w->credits) continue;
      vx_instant now = vx_now();
      *ev = (vx_event){.kind = VX_FRAME, .source = (uint64_t)(uintptr_t)w, .time = now};
      ev->frame = (vx_frame_event){.seq = ++w->presents,
                                   .target = now + 16'666'667,
                                   .prev_presented = w->prev_presented,
                                   .dt = w->last_frame ? now - w->last_frame : 0};
      w->last_frame = now, w->redraw = false, w->owed = true;
      w->span = vx_span_begin();
      return VXUI_EVENT;
    }
    uint64_t wakes = app->wakes;
    if (wakes != app->wakes_seen) { // woken by another thread
      app->wakes_seen = wakes;
      *ev = (vx_event){.kind = VX_WAKE, .source = (uint64_t)(uintptr_t)app, .time = vx_now()};
      return VXUI_EVENT;
    }
    if (want && (want->credits || want->closed)) return VXUI_NOTHING;
    vx_port_bind(app->port, app->wake, VX_TRIGGER_COUNTER_GE, VXUI_WAKE_KEY, wakes + 1);
    bool any = false;
    for (uint32_t i = 0; i < VXUI_WINDOWS; i++) {
      vx_window *w = &app->win[i];
      if (!w->used || w->closed) continue;
      vx_port_bind(app->port, w->ch, VX_TRIGGER_READABLE, i, 0);
      vx_port_bind(app->port, w->ch, VX_TRIGGER_PEER_CLOSED, i, 0); // closed: its VX_CLOSE
      any = true;
    }
    vx_packet pk[8];
    int64_t n = any || deadline != VX_INFINITE ? vx_port_wait(app->port, deadline, 0, pk, 8) : 0;
    if (n <= 0 && !any) {
      vxui_fail(app, "no windows to wait on");
      continue;
    }
    if (n <= 0) return VXUI_NOTHING; // the deadline
    for (int64_t k = 0; k < n; k++) {
      if (pk[k].key == VXUI_WAKE_KEY) continue; // seen by the loop's next turn
      vx_window *w = &app->win[pk[k].key % VXUI_WINDOWS];
      if (w->used && !w->closed && !vxui_drain(w)) {
        w->closed = true;
        vx_handle_close(w->ch);
        vx_event close = {.kind = VX_CLOSE, .source = (uint64_t)(uintptr_t)w, .time = vx_now()};
        vxui_push(app, &close);
      }
    }
  }
}

// What the UI keeps of a pointer event the app is given: where it is, and a
// click's ends.
static void vxui_seen(const vx_event *ev) {
  if (ev->kind != VX_POINTER) return;
  vx_window *win = (vx_window *)(uintptr_t)ev->source;
  int32_t x = (int32_t)ev->pointer.x, y = (int32_t)ev->pointer.y;
  uint32_t buttons = ev->pointer.buttons;
  if (buttons && !win->buttons) win->down_seen = true, win->down_x = x, win->down_y = y;
  if (!buttons && win->buttons) win->up_seen = true, win->up_x = x, win->up_y = y;
  win->px = x, win->py = y, win->buttons = buttons;
  if (win->has_ui) win->redraw = true; // its buttons may look or answer otherwise
}

static void vxui_record(vxui_replay *r, const vx_event *ev) {
  if (ev->kind == VX_WAKE || ev->kind == VX_CLOSE || r->count == VXUI_REPLAY_EVENTS) return;
  vx_event *e = &r->events[r->count++];
  *e = *ev;
  if (ev->kind == VX_FRAME) r->frames++;
  if (ev->kind != VX_TEXT) return;
  size_t n = r->used + ev->text.text.len <= VXUI_REPLAY_TEXT ? ev->text.text.len : 0; // full: kept empty
  memcpy(r->text + r->used, ev->text.text.ptr, n);
  e->text.text = (vx_str){r->text + r->used, n};
  r->used += (uint32_t)n;
}

static bool vxui_made(const vxui_replay *r, uint64_t page) { return r->made[page / 64] >> (page % 64) & 1; }

// The storage as the snapshot has it: its pages that were zero given back,
// the others copied in.
static void vxui_restore(vxui_replay *r) {
  vx_app_memory *m = r->mem;
  for (uint64_t p = 0, q = 0; p < r->pages; p = q) {
    bool made = vxui_made(r, p);
    for (q = p + 1; q < r->pages && vxui_made(r, q) == made; q++) {}
    if (!made) {
      vx_vmo_decommit(m->vmo, m->offset + p * 4096, (q - p) * 4096);
      continue;
    }
    for (uint64_t off = p * 4096; off < q * 4096; off += VXUI_SCAN) {
      uint64_t n = q * 4096 - off < VXUI_SCAN ? q * 4096 - off : VXUI_SCAN;
      if (vx_vmo_rw(r->snap, VX_VMO_READ, off, r->buf, n) == VX_OK)
        vx_vmo_rw(m->vmo, VX_VMO_WRITE, m->offset + off, r->buf, n);
    }
  }
}

// The recording's next event when its time comes (a frame when its window
// also holds a credit), or a live one first: the host's; VXUI_NOTHING when
// the window it draws in has closed, live again.
static vxui_got vxui_play(vx_app *app, vx_event *ev, vx_instant deadline) {
  vxui_replay *r = &app->replay;
  for (;;) {
    vx_instant now = vx_now(), until = deadline;
    vx_window *want = nullptr;
    if (r->next == r->count) { // its end: from the snapshot again, as long after the start as it recorded
      if (now >= r->from + r->length) {
        vxui_restore(r);
        r->next = 0, r->from = now;
        continue;
      }
      if (r->from + r->length < until) until = r->from + r->length;
    } else {
      const vx_event *e = &r->events[r->next];
      vx_instant due = r->from + (e->time - r->t0);
      vx_window *w = e->kind == VX_FRAME ? (vx_window *)(uintptr_t)e->source : nullptr;
      if (w && w->closed) { // nothing more to see
        r->state = VXUI_OFF;
        return VXUI_NOTHING;
      }
      if (now >= due && (!w || w->credits)) {
        *ev = *e;
        ev->flags |= VX_REPLAYED;
        r->next++;
        if (w) {
          ev->frame.seq = ++w->presents; // the present's: the rest is the recording's
          w->last_frame = now, w->owed = true;
          w->span = vx_span_begin();
        }
        vxui_seen(ev);
        return VXUI_EVENT;
      }
      if (now < due && due < until) until = due;
      if (now >= due) want = w;
    }
    vxui_got got = vxui_live(app, ev, until, false, want);
    if (got != VXUI_NOTHING) return got; // an event is live, not recorded and not the app's: the host's
    if (vx_now() >= deadline) {
      *ev = (vx_event){.kind = VX_NONE, .time = vx_now()};
      return VXUI_EVENT;
    }
  }
}

VXUI_API bool vx_wait(vx_app *app, vx_event *ev, vx_instant deadline) {
  vxui_got played = app->replay.state == VXUI_PLAYING ? vxui_play(app, ev, deadline) : VXUI_NOTHING;
  if (played != VXUI_NOTHING) return played == VXUI_EVENT;
  vxui_got got = vxui_live(app, ev, deadline, true, nullptr);
  if (got == VXUI_ERROR) return false;
  if (got == VXUI_NOTHING) *ev = (vx_event){.kind = VX_NONE, .time = vx_now()};
  vxui_seen(ev);
  if (app->replay.state == VXUI_RECORDING) vxui_record(&app->replay, ev);
  return true;
}

// --- Looped playback (03 §6.1; 7g2c) ---

static bool vxui_zero(const uint8_t *page) {
  const uint64_t *w = (const uint64_t *)page;
  for (uint32_t i = 0; i < 4096 / 8; i++)
    if (w[i]) return false;
  return true;
}

VXUI_API void vx_replay_stop(vx_app *app) {
  vxui_replay *r = &app->replay;
  if (r->state == VXUI_RECORDING) r->length = vx_now() - r->t0;
  if (r->state == VXUI_PLAYING)
    for (uint32_t i = 0; i < VXUI_WINDOWS; i++) app->win[i].redraw = true; // live again: drawn as it is now
  r->state = VXUI_OFF;
}

VXUI_API bool vx_replay_start(vx_app *app, vx_app_memory *mem) {
  vxui_replay *r = &app->replay;
  vx_replay_stop(app);
  r->count = r->next = r->frames = r->used = 0, r->length = 0;
  if (r->snap != VX_HANDLE_NONE) vx_handle_close(r->snap), r->snap = VX_HANDLE_NONE;
  if (r->made) vx_heap_free(vx_heap_process(), r->made), r->made = nullptr;
  if (!mem || !mem->size || mem->size % 4096 || mem->offset % 4096) return false;
  if (!r->events) { // the recording's mapping, once: lazy, its pages made as it fills
    uint64_t at = 0, size = VXUI_REPLAY_EVENTS * sizeof(vx_event) + VXUI_REPLAY_TEXT;
    vx_handle vmo = VX_HANDLE_NONE;
    if (vx_vmo_create(size, VX_VMO_LAZY, &vmo) != VX_OK) return false;
    vx_status st = vx_as_map(vx_task_self(), vmo, 0, size, VX_MAP_WRITE, &at);
    vx_handle_close(vmo);
    if (st != VX_OK) return false;
    r->events = (vx_event *)(uintptr_t)at, r->text = (char *)(r->events + VXUI_REPLAY_EVENTS);
  }
  if (!r->buf && !(r->buf = vx_heap_alloc(vx_heap_process(), VXUI_SCAN))) return false;
  memset(r->buf, 0, VXUI_SCAN); // its pages made: what vx_vmo_rw copies into
  r->pages = mem->size / 4096;
  size_t words = (r->pages + 63) / 64;
  r->made = vx_heap_alloc(vx_heap_process(), words * 8);
  if (!r->made || vx_vmo_create(mem->size, VX_VMO_LAZY, &r->snap) != VX_OK) return false;
  memset(r->made, 0, words * 8);
  // Read through the VMO, not the mapping: a page never touched reads as
  // zeros without being made, and is not copied.
  for (uint64_t off = 0; off < mem->size; off += VXUI_SCAN) {
    uint64_t n = mem->size - off < VXUI_SCAN ? mem->size - off : VXUI_SCAN;
    if (vx_vmo_rw(mem->vmo, VX_VMO_READ, mem->offset + off, r->buf, n) != VX_OK) return false;
    for (uint64_t p = 0; p < n; p += 4096) {
      if (vxui_zero(r->buf + p)) continue;
      uint64_t page = (off + p) / 4096;
      r->made[page / 64] |= 1ull << (page % 64);
      if (vx_vmo_rw(r->snap, VX_VMO_WRITE, off + p, r->buf + p, 4096) != VX_OK) return false;
    }
  }
  r->mem = mem, r->t0 = vx_now(), r->state = VXUI_RECORDING;
  return true;
}

VXUI_API bool vx_replay_play(vx_app *app) {
  vxui_replay *r = &app->replay;
  vx_replay_stop(app);
  if (!r->frames) return false; // nothing recorded to pace it, or nothing recorded at all
  vxui_restore(r);
  r->next = 0, r->from = vx_now(), r->state = VXUI_PLAYING;
  return true;
}

// --- Drawing ---

static vx_color vxui_colour(vx_color c) {
  switch (c) { // vx-magic's, until a window's theme reaches the app
  case VX_THEME_BG: return 0xe4e0d8;
  case VX_THEME_FG: return 0x1c1c1c;
  case VX_THEME_ACCENT: return 0x3f6fb0;
  case VX_THEME_FACE: return 0xbdb8ae;
  default: return c & 0xffffff;
  }
}

// The next buffer, the configure's size, free (its release point come), attached.
VXUI_API vx_pixels vx_pixels_begin(vx_window *win, const vx_frame_event *frame) {
  (void)frame;
  vx_pixels px = {};
  if (!win || win->closed) return px;
  uint32_t i = win->next;
  vxui_buffer *b = &win->b[i];
  if (b->attached && (b->buf.desc.width != win->cfg.pwidth || b->buf.desc.height != win->cfg.pheight)) {
    vx_buffer_wait(&b->buf, b->point, vx_now() + 1'000'000'000);
    vx_wsys_detach d = {.h = {.ordinal = VX_WSYS_DETACH}, .id = i + 1};
    vx_wsys_reply r = {};
    vx_call c = {.wr_bytes = &d, .wr_len = sizeof d, .rd_bytes = &r, .rd_cap = sizeof r};
    vx_channel_call(win->ch, &c, vx_now() + 5'000'000'000);
    vx_buffer_unmap(&b->buf, b->px);
    vx_buffer_close(&b->buf);
    *b = (vxui_buffer){};
  }
  if (!b->attached) {
    if (vx_buffer_alloc(&b->buf, win->cfg.pwidth, win->cfg.pheight, VX_FORMAT_XRGB8888) != VX_OK ||
        vx_buffer_map(&b->buf, true, &b->px) != VX_OK) {
      vxui_fail(win->app, "no memory for a window's buffer");
      return px;
    }
    vx_wsys_attach at = {.h = {.ordinal = VX_WSYS_ATTACH}, .id = i + 1};
    vx_handle h[2];
    vx_wsys_reply r = {};
    vx_call c = {.wr_bytes = &at,
                 .wr_handles = h,
                 .wr_len = sizeof at,
                 .wr_count = 2,
                 .rd_bytes = &r,
                 .rd_cap = sizeof r};
    if (vx_buffer_put(&b->buf, false, &at.desc, h) != VX_OK ||
        vx_channel_call(win->ch, &c, vx_now() + 5'000'000'000) != VX_OK || r.h.flags) {
      vxui_fail(win->app, "the window server refused a buffer");
      return px;
    }
    b->attached = true;
  }
  vx_buffer_wait(&b->buf, b->point, vx_now() + 1'000'000'000); // released: winsrv has copied it
  px = (vx_pixels){.data = b->px,
                   .w = b->buf.desc.width,
                   .h = b->buf.desc.height,
                   .stride = b->buf.desc.plane[0].stride,
                   .age = b->presented ? (uint32_t)(win->presents - b->presented) : 0,
                   .buffer = i};
  return px;
}

static void vxui_present(vx_window *win, vx_pixels *px, const vx_wsys_rect *damage, uint32_t ndamage);

VXUI_API void vx_pixels_present(vx_window *win, vx_pixels *px) { vxui_present(win, px, nullptr, 0); }

// A present, its damage given (none: all of it).
static void vxui_present(vx_window *win, vx_pixels *px, const vx_wsys_rect *damage, uint32_t ndamage) {
  if (!win || win->closed || !px->data) return;
  vxui_buffer *b = &win->b[px->buffer];
  uint64_t acquire = ++b->point, release = ++b->point;
  vx_buffer_signal(&b->buf, acquire);
  vx_wsys_present p = {.h = {.ordinal = VX_WSYS_PRESENT},
                       .seq = win->presents,
                       .id = px->buffer + 1,
                       .acquire = acquire,
                       .release = release,
                       .config_seq = win->cfg.seq,
                       .ndamage = ndamage <= VX_WSYS_DAMAGE ? ndamage : 0};
  for (uint32_t i = 0; i < p.ndamage; i++) p.damage[i] = damage[i];
  if (vx_channel_write(win->ch, &p, sizeof p, nullptr, 0) == VX_OK && win->credits) win->credits--;
  vx_span_end(win->span, VX_SPAN_FRAME_DRAW, vx_frame_flow(win->id, win->presents));
  b->presented = win->presents, win->owed = false, win->next ^= 1, win->span = 0;
}

VXUI_API vx_canvas *vx_canvas_begin(vx_window *win, const vx_frame_event *frame) {
  vx_canvas *c = &win->app->canvas;
  *c = (vx_canvas){.win = win, .px = vx_pixels_begin(win, frame)};
  return c;
}

VXUI_API void vx_canvas_present(vx_canvas *c) { vx_pixels_present(c->win, &c->px); }

VXUI_API void vx_fill_rect(vx_canvas *c, float x, float y, float w, float h, vx_color colour) {
  if (!c->px.data) return;
  uint32_t col = vxui_colour(colour);
  int32_t x0 = (int32_t)x, y0 = (int32_t)y, x1 = (int32_t)(x + w), y1 = (int32_t)(y + h);
  if (x0 < 0) x0 = 0;
  if (y0 < 0) y0 = 0;
  if (x1 > (int32_t)c->px.w) x1 = (int32_t)c->px.w;
  if (y1 > (int32_t)c->px.h) y1 = (int32_t)c->px.h;
  for (int32_t yy = y0; yy < y1; yy++)
    for (int32_t xx = x0; xx < x1; xx++) ((uint32_t *)(c->px.data + (size_t)yy * c->px.stride))[xx] = col;
}

VXUI_API void vx_clear(vx_canvas *c, vx_color colour) {
  vx_fill_rect(c, 0, 0, (float)c->px.w, (float)c->px.h, colour);
}

// A disc, its edge antialiased: coverage by the distance of each pixel's centre from the rim.
VXUI_API void vx_circle(vx_canvas *c, float x, float y, float r, vx_color colour) {
  if (!c->px.data || r <= 0) return;
  uint32_t col = vxui_colour(colour);
  int32_t x0 = (int32_t)(x - r - 1), y0 = (int32_t)(y - r - 1), x1 = (int32_t)(x + r + 2),
          y1 = (int32_t)(y + r + 2);
  if (x0 < 0) x0 = 0;
  if (y0 < 0) y0 = 0;
  if (x1 > (int32_t)c->px.w) x1 = (int32_t)c->px.w;
  if (y1 > (int32_t)c->px.h) y1 = (int32_t)c->px.h;
  for (int32_t yy = y0; yy < y1; yy++)
    for (int32_t xx = x0; xx < x1; xx++) {
      float dx = (float)xx + 0.5f - x, dy = (float)yy + 0.5f - y;
      float edge = r + 0.5f - __builtin_elementwise_sqrt(dx * dx + dy * dy);
      if (edge <= 0) continue;
      uint32_t a = edge >= 1 ? 255 : (uint32_t)(edge * 255);
      uint32_t *d = (uint32_t *)(c->px.data + (size_t)yy * c->px.stride) + xx, out = 0;
      for (int s = 0; s < 24; s += 8)
        out |= (((col >> s & 0xff) * a + (*d >> s & 0xff) * (255 - a) + 127) / 255) << s;
      *d = out;
    }
}

// --- Immediate-mode UI (7e2b) ---

static constexpr uint32_t UI_PX = 13, UI_PAD = 16, UI_GAP = 8, UI_BUTTON_H = 28;

struct vx_ui {
  vx_window *win;
  const vx_frame_event *frame;
  vxui_node nodes[VXUI_NODES];
  uint32_t n;
  uint64_t seed[8]; // the id stack
  uint32_t depth;
  vx_arena *arena; // the frame's: reset each frame
};

static vx_ui vxui_the_ui;
static vx_font vxui_font;
static vx_atlas vxui_atlas;
static int vxui_fonts; // 0 unknown, 1 loaded, -1 none

static void vxui_load_font(void) {
  if (vxui_fonts) return;
  vxui_fonts = -1;
  vx_fd fd = vx_open(VX_STR("/lib/font/Inter-Regular.ttf"), VX_OREAD);
  if (fd < 0) return;
  static constexpr size_t MAX = 4u << 20;
  uint8_t *buf = vx_font_alloc(MAX);
  size_t n = 0;
  for (int64_t r; buf && n < MAX && (r = vx_read(fd, (vx_bytes){buf + n, MAX - n})) > 0;) n += (size_t)r;
  vx_close(fd);
  if (buf && n && vx_atlas_init(&vxui_atlas, 256) && vx_font_init(&vxui_font, buf, n, 1)) vxui_fonts = 1;
}

// FNV-1a over a key, seeded.
static uint64_t vxui_hash(uint64_t seed, const char *s, size_t n) {
  uint64_t h = seed ^ 0xcbf2'9ce4'8422'2325ull;
  for (size_t i = 0; i < n; i++) h = (h ^ (uint8_t)s[i]) * 0x100'0000'01b3ull;
  return h ? h : 1;
}

static int32_t vxui_text_width(const char *text, size_t len) {
  if (vxui_fonts != 1 || !len) return (int32_t)len * 7;
  vx_glyph_at g[64];
  int32_t adv = 0;
  vx_font_shape(&vxui_font, text, len, g, 64, &adv);
  return vx_font_to64(&vxui_font, adv, UI_PX) / 64;
}

VXUI_API vx_ui *vx_ui_begin(vx_window *win, const vx_frame_event *frame) {
  vx_ui *ui = &vxui_the_ui;
  vx_arena *arena = ui->arena;
  *ui = (vx_ui){.win = win, .frame = frame, .arena = arena};
  if (!ui->arena) ui->arena = vx_arena_new(1 << 20);
  vx_arena_pop(ui->arena, (vx_mark){0}); // the frame's arena, empty again
  win->has_ui = true;
  vxui_load_font();
  return ui;
}

static vxui_node *vxui_add(vx_ui *ui, uint8_t kind, const char *label) {
  if (ui->n == VXUI_NODES) return nullptr;
  vx_str s = vx_cstr(label);
  size_t shown = s.len;
  for (size_t i = 0; i + 1 < s.len; i++)
    if (s.ptr[i] == '#' && s.ptr[i + 1] == '#') {
      shown = i;
      break;
    }
  vxui_node *n = &ui->nodes[ui->n++];
  *n = (vxui_node){.id = vxui_hash(ui->depth ? ui->seed[ui->depth - 1] : 0, s.ptr, s.len), .kind = kind};
  memcpy(n->text, s.ptr, shown < sizeof n->text - 1 ? shown : sizeof n->text - 1);
  return n;
}

static const vxui_node *vxui_cached(const vx_window *win, uint64_t id) {
  for (uint32_t i = 0; i < win->nlast; i++)
    if (win->last[i].id == id) return &win->last[i];
  return nullptr;
}

static bool vxui_in(const vxui_node *n, int32_t x, int32_t y) {
  return x >= n->x && y >= n->y && x < n->x + n->w && y < n->y + n->h;
}

VXUI_API void vx_label(vx_ui *ui, const char *text) { vxui_add(ui, 1, text); }

VXUI_API bool vx_button(vx_ui *ui, const char *label) {
  vxui_node *n = vxui_add(ui, 2, label);
  const vxui_node *was = n ? vxui_cached(ui->win, n->id) : nullptr;
  if (!was) return false; // new this frame: it has never been seen, so never clicked
  vx_window *w = ui->win;
  n->pressed = w->buttons && vxui_in(was, w->px, w->py) && vxui_in(was, w->down_x, w->down_y);
  return w->down_seen && w->up_seen && vxui_in(was, w->down_x, w->down_y) && vxui_in(was, w->up_x, w->up_y);
}

VXUI_API void vx_push_id(vx_ui *ui, uint64_t key) {
  if (ui->depth == 8) return;
  char k[8];
  memcpy(k, &key, 8);
  ui->seed[ui->depth] = vxui_hash(ui->depth ? ui->seed[ui->depth - 1] : 0, k, 8);
  ui->depth++;
}

VXUI_API void vx_pop_id(vx_ui *ui) {
  if (ui->depth) ui->depth--;
}

static bool vxui_same(const vxui_node *a, const vxui_node *b) {
  return a->id == b->id && a->kind == b->kind && a->pressed == b->pressed && a->x == b->x && a->y == b->y &&
         a->w == b->w && a->h == b->h && memcmp(a->text, b->text, sizeof a->text) == 0;
}

static void vxui_grow(int32_t d[4], const vxui_node *n) {
  if (n->x < d[0]) d[0] = n->x;
  if (n->y < d[1]) d[1] = n->y;
  if (n->x + n->w > d[2]) d[2] = n->x + n->w;
  if (n->y + n->h > d[3]) d[3] = n->y + n->h;
}

static void vxui_draw_node(vx_canvas *c, const vxui_node *n, vx_font_target *t) {
  int32_t baseline = n->y + (n->h + 13 * 3 / 4) / 2;
  if (n->kind == 2) { // a raised button, sunken while pressed: the frame's face, lit from the top left
    uint32_t light = n->pressed ? 0x7d786f : 0xece8df, shade = n->pressed ? 0xece8df : 0x7d786f;
    vx_fill_rect(c, (float)n->x, (float)n->y, (float)n->w, (float)n->h, 0x2b2926);
    vx_fill_rect(c, (float)n->x + 1, (float)n->y + 1, (float)n->w - 2, (float)n->h - 2, shade);
    vx_fill_rect(c, (float)n->x + 1, (float)n->y + 1, (float)n->w - 3, (float)n->h - 3, light);
    vx_fill_rect(c, (float)n->x + 2, (float)n->y + 2, (float)n->w - 4, (float)n->h - 4, VX_THEME_FACE);
  }
  if (vxui_fonts != 1) return;
  int32_t tw = vxui_text_width(n->text, vx_cstr(n->text).len);
  int32_t x = n->kind == 2 ? n->x + (n->w - tw) / 2 + (n->pressed ? 1 : 0) : n->x;
  vx_text_draw(t, &vxui_atlas, &vxui_font, UI_PX, x, baseline + (n->pressed ? 1 : 0), 0x1c1c1c, n->text,
               vx_cstr(n->text).len);
}

// Layout (a pass of its own: a column from the top left), then the damage
// (this frame's nodes against the last's), then drawing what it reaches.
VXUI_API void vx_ui_end(vx_ui *ui) {
  vx_window *w = ui->win;
  int32_t y = UI_PAD, line = 20;
  for (uint32_t i = 0; i < ui->n; i++) {
    vxui_node *n = &ui->nodes[i];
    int32_t tw = vxui_text_width(n->text, vx_cstr(n->text).len);
    n->x = UI_PAD, n->y = y;
    n->w = n->kind == 2 ? tw + 24 : tw, n->h = n->kind == 2 ? (int32_t)UI_BUTTON_H : line;
    y += n->h + (int32_t)UI_GAP;
  }
  int32_t d[4] = {INT32_MAX, INT32_MAX, INT32_MIN, INT32_MIN};
  bool all = w->nlast == 0;
  for (uint32_t i = 0; i < ui->n && !all; i++) { // changed or new
    const vxui_node *was = vxui_cached(w, ui->nodes[i].id);
    if (!was || !vxui_same(was, &ui->nodes[i])) {
      vxui_grow(d, &ui->nodes[i]);
      if (was) vxui_grow(d, was);
    }
  }
  for (uint32_t i = 0; i < w->nlast && !all; i++) { // gone
    bool kept = false;
    for (uint32_t k = 0; k < ui->n && !kept; k++) kept = ui->nodes[k].id == w->last[i].id;
    if (!kept) vxui_grow(d, &w->last[i]);
  }
  memcpy(w->last, ui->nodes, ui->n * sizeof ui->nodes[0]); // the cache, for the next frame: gone ones dropped
  w->nlast = ui->n;
  if (w->up_seen)
    w->down_seen = w->up_seen = false; // a click is answered once; a press waits for its release
  if (!all && d[0] > d[2]) {           // nothing changed: nothing presented
    w->owed = false;
    return;
  }
  vx_canvas *c = vx_canvas_begin(w, ui->frame);
  if (!c->px.data) return;
  int32_t paint[4] = {d[0], d[1], d[2], d[3]}; // this frame's, and the last's: the buffer is two frames old
  if (all || c->px.age != 2)
    paint[0] = 0, paint[1] = 0, paint[2] = (int32_t)c->px.w, paint[3] = (int32_t)c->px.h;
  for (int k = 0; k < 2 && !all; k++) {
    if (w->last_damage[k] < paint[k]) paint[k] = w->last_damage[k];
    if (w->last_damage[k + 2] > paint[k + 2]) paint[k + 2] = w->last_damage[k + 2];
  }
  if (paint[0] < 0) paint[0] = 0;
  if (paint[1] < 0) paint[1] = 0;
  if (paint[2] > (int32_t)c->px.w) paint[2] = (int32_t)c->px.w;
  if (paint[3] > (int32_t)c->px.h) paint[3] = (int32_t)c->px.h;
  vx_fill_rect(c, (float)paint[0], (float)paint[1], (float)(paint[2] - paint[0]),
               (float)(paint[3] - paint[1]), VX_THEME_BG);
  vx_font_target t = {.px = (uint32_t *)c->px.data,
                      .stride = c->px.stride / 4,
                      .clip_x0 = paint[0],
                      .clip_y0 = paint[1],
                      .clip_x1 = paint[2],
                      .clip_y1 = paint[3]};
  for (uint32_t i = 0; i < ui->n; i++) {
    const vxui_node *n = &ui->nodes[i];
    if (n->x < paint[2] && n->y < paint[3] && n->x + n->w > paint[0] && n->y + n->h > paint[1])
      vxui_draw_node(c, n, &t);
  }
  if (all) {
    vxui_present(w, &c->px, nullptr, 0);
    w->last_damage[0] = 0, w->last_damage[1] = 0, w->last_damage[2] = (int32_t)c->px.w,
    w->last_damage[3] = (int32_t)c->px.h;
  } else {
    vx_wsys_rect r = {d[0], d[1], (uint32_t)(d[2] - d[0]), (uint32_t)(d[3] - d[1])};
    vxui_present(w, &c->px, &r, 1);
    memcpy(w->last_damage, d, sizeof d);
  }
}

// --- Voices (sound with audiod, M13) ---

VXUI_API vx_voice *vx_voice_open(vx_app *app, vx_sound sound) {
  app->voice = (vx_voice){.sound = sound};
  return &app->voice;
}

VXUI_API void vx_voice_play(vx_voice *voice) { (void)voice; } // silent until audiod (M13)
