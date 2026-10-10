// vxui.c: vxui v0's implementation (vxui.h; M7 step 7e2). An app is a port
// and its windows; a window is its channel on winsrv (docs/proto/wsys.md),
// made by opening /wsys/new (the app's attach, aname `self`), with two
// vx-buffers drawn in turn. vx_wait turns the window records into events,
// and owes a window a VX_FRAME when it asked to draw and holds a credit.

#pragma once

static constexpr uint32_t VXUI_WINDOWS = 8, VXUI_QUEUE = 32;

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
  vx_instant prev_presented, last_frame;
  vxui_buffer b[2];
  uint32_t next; // the buffer to draw next
};

struct vx_canvas {
  vx_window *win;
  vx_pixels px;
};

struct vx_voice {
  vx_sound sound;
};

struct vx_app {
  char id[64];
  const char *error; // sticky
  vx_handle port;
  vx_window win[VXUI_WINDOWS];
  vx_event queue[VXUI_QUEUE];
  uint32_t head, count;
  vx_canvas canvas;
  vx_voice voice;
  char text[VX_WSYS_TEXT + 1]; // the last VX_TEXT's
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

static vx_app *vx_app_open(const char *id) {
  vx_app *app = &vxui_the_app;
  *app = (vx_app){};
  vx_str s = vx_cstr(id);
  memcpy(app->id, s.ptr, s.len < sizeof app->id - 1 ? s.len : sizeof app->id - 1);
  if (vx_port_create(0, &app->port) != VX_OK) vxui_fail(app, "no port");
  return app;
}

static const char *vx_app_error(const vx_app *app) { return app->error; }

// --- Windows ---

static void vxui_ctl(vx_window *win, const char *cmd) {
  char path[48] = "/wsys/";
  size_t n = 6, d = 0;
  char digits[10];
  uint32_t v = win->id;
  do digits[d++] = (char)('0' + v % 10), v /= 10;
  while (v);
  while (d) path[n++] = digits[--d];
  memcpy(path + n, "/ctl", 5);
  vx_fd fd = vx_open(vx_cstr(path), VX_OWRITE);
  if (fd < 0) return;
  vx_write(fd, vx_cstr(cmd));
  vx_close(fd);
}

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
      vxui_push(app, &ev);
    } else if (h->ordinal == VX_WSYS_COMMIT && size.bytes == sizeof(vx_wsys_commit)) {
      const vx_wsys_commit *c = (const vx_wsys_commit *)m;
      uint32_t len = c->len <= VX_WSYS_TEXT ? c->len : 0;
      memcpy(app->text, c->text, len), app->text[len] = 0;
      ev.kind = VX_TEXT, ev.text.text = (vx_str){app->text, len};
      vxui_push(app, &ev);
    }
  }
}

static vx_window *vx_window_open(vx_app *app, const char *title, uint32_t width, uint32_t height) {
  if (app->error) return nullptr;
  vx_window *win = nullptr;
  for (uint32_t i = 0; i < VXUI_WINDOWS && !win; i++)
    if (!app->win[i].used) win = &app->win[i];
  if (!win) {
    vxui_fail(app, "too many windows");
    return nullptr;
  }
  *win = (vx_window){.used = true, .app = app, .redraw = true};
  if (vx_ns_open_post(vx_ns_process(), VX_STR("/wsys/new"), &win->ch) != VX_OK) {
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
  app->count = 0;
  return win;
}

static void vx_window_title(vx_window *win, const char *title) {
  if (!win) return;
  char cmd[96] = "title ";
  vx_str t = vx_cstr(title);
  size_t n = t.len < sizeof cmd - 7 ? t.len : sizeof cmd - 7;
  memcpy(cmd + 6, t.ptr, n), cmd[6 + n] = 0;
  vxui_ctl(win, cmd);
}

static void vx_window_redraw(vx_window *win) {
  if (win) win->redraw = true;
}

static void vx_window_animate(vx_window *win, bool on) {
  if (win) win->animate = on, win->redraw |= on;
}

// --- The wait ---

static bool vx_wait(vx_app *app, vx_event *ev, vx_instant deadline) {
  for (;;) {
    if (app->error) return false;
    for (uint32_t i = 0; i < VXUI_WINDOWS; i++) { // a frame handed out and never presented is let go
      vx_window *w = &app->win[i];
      if (w->used && w->owed) w->owed = false;
    }
    if (app->count) {
      *ev = app->queue[app->head];
      app->head = (app->head + 1) % VXUI_QUEUE, app->count--;
      return true;
    }
    for (uint32_t i = 0; i < VXUI_WINDOWS; i++) { // a frame, to a window that asked and holds a credit
      vx_window *w = &app->win[i];
      if (!w->used || w->closed || !(w->redraw || w->animate) || !w->credits) continue;
      vx_instant now = vx_now();
      *ev = (vx_event){.kind = VX_FRAME, .source = (uint64_t)(uintptr_t)w, .time = now};
      ev->frame = (vx_frame_event){.seq = ++w->presents,
                                   .target = now + 16'666'667,
                                   .prev_presented = w->prev_presented,
                                   .dt = w->last_frame ? now - w->last_frame : 0};
      w->last_frame = now, w->redraw = false, w->owed = true;
      return true;
    }
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
    if (n <= 0) { // the deadline: nothing
      *ev = (vx_event){.kind = VX_NONE, .time = vx_now()};
      return true;
    }
    for (int64_t k = 0; k < n; k++) {
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
static vx_pixels vx_pixels_begin(vx_window *win, const vx_frame_event *frame) {
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

static void vx_pixels_present(vx_window *win, vx_pixels *px) {
  if (!win || win->closed || !px->data) return;
  vxui_buffer *b = &win->b[px->buffer];
  uint64_t acquire = ++b->point, release = ++b->point;
  vx_buffer_signal(&b->buf, acquire);
  vx_wsys_present p = {.h = {.ordinal = VX_WSYS_PRESENT},
                       .seq = win->presents,
                       .id = px->buffer + 1,
                       .acquire = acquire,
                       .release = release,
                       .config_seq = win->cfg.seq};
  if (vx_channel_write(win->ch, &p, sizeof p, nullptr, 0) == VX_OK && win->credits) win->credits--;
  b->presented = win->presents, win->owed = false, win->next ^= 1;
}

static vx_canvas *vx_canvas_begin(vx_window *win, const vx_frame_event *frame) {
  vx_canvas *c = &win->app->canvas;
  *c = (vx_canvas){.win = win, .px = vx_pixels_begin(win, frame)};
  return c;
}

static void vx_canvas_present(vx_canvas *c) { vx_pixels_present(c->win, &c->px); }

static void vx_fill_rect(vx_canvas *c, float x, float y, float w, float h, vx_color colour) {
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

static void vx_clear(vx_canvas *c, vx_color colour) {
  vx_fill_rect(c, 0, 0, (float)c->px.w, (float)c->px.h, colour);
}

// A disc, its edge antialiased: coverage by the distance of each pixel's centre from the rim.
static void vx_circle(vx_canvas *c, float x, float y, float r, vx_color colour) {
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

// --- Voices (sound with audiod, M13) ---

static vx_voice *vx_voice_open(vx_app *app, vx_sound sound) {
  app->voice = (vx_voice){.sound = sound};
  return &app->voice;
}

static void vx_voice_play(vx_voice *voice) { (void)voice; } // silent until audiod (M13)
