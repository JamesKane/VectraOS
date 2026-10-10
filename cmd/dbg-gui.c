// dbg's window (05 §6, §12's GUI v0; M7 step 7g1b3): dbg without -c, on a
// program to launch, a process (-p) or a crash directory. Included by dbg.c,
// after its commands, which it runs: what the window shows is what those
// commands say, captured (said), so the two faces never disagree.
//
// Along the top, Run (Continue once the program runs), Step and Kill, and
// what the last command said. On the left the source of the selected frame,
// held in lib/vx-text, from the path its debug information names (/src/...,
// 05 §4): line numbers, a red dot for each breakpoint (a click in the margin
// sets or clears one), the frame's line marked. On the right the threads,
// the call stack (a click selects a frame) and the selected frame's locals.
// What each command says goes to standard output too, as with -c. A
// command that waits for the program (run, cont, step, kill) runs on a
// thread of its own; until it returns the window says so and takes no
// command, and then it reads the program's state again on its own thread,
// so only one thread ever drives the debugger.

#include "../lib/vx-text/text.c"

static constexpr uint32_t GUI_PX = 13, GUI_MAX_LINES = 48;
static constexpr int32_t GUI_TOOL_H = 32, GUI_HEAD_H = 20, GUI_RIGHT_W = 330, GUI_GUTTER_W = 52;
static constexpr char GUI_UI_FONT[] = "/lib/font/Inter-Regular.ttf",
                      GUI_MONO_FONT[] = "/lib/font/JetBrainsMono-Regular.ttf";

typedef struct gui_lines {
  char buf[4096];
  vx_str line[GUI_MAX_LINES];
  uint32_t n;
} gui_lines;

static struct {
  vx_app *app;
  vx_window *win;
  uint32_t w, h;
  vx_font ui, mono;
  vx_atlas atlas;
  int32_t ui_ascent, mono_ascent, line_h, cell_w64; // cell_w64: the mono font's advance, in 1/64 pixels
  vx_lock_t lock;
  bool busy; // a command runs on the worker: the lock's
  char cmd[96];
  char out[2048]; // what the worker's command said
  // what the window shows, read on the window's thread
  char status[160];
  gui_lines threads, stack, locals;
  char file[192]; // the source shown: its path
  vx_text *text;
  char *bytes;
  uint32_t line; // the selected frame's, from 1; 0: none
  int64_t top;   // the first line shown, from 0
  float px, py;
  uint32_t buttons;
} gui;

// --- The program's state, as the commands say it ---

static void gui_split(gui_lines *l) {
  l->n = 0;
  for (char *p = l->buf; *p && l->n < GUI_MAX_LINES;) {
    char *e = p;
    while (*e && *e != '\n') e++;
    if (e > p) l->line[l->n++] = (vx_str){p, (size_t)(e - p)};
    p = *e ? e + 1 : e;
  }
}

static void gui_capture_begin(char *buf, size_t cap) {
  said.buf = buf, said.len = 0, said.cap = cap;
  buf[0] = 0;
}
static void gui_capture_end(void) { said.buf = nullptr; }

// The status: the last thing a command said, its "dbg: " dropped.
static void gui_set_status(const char *text) {
  const char *last = text;
  for (const char *p = text; *p; p++)
    if (p[0] == '\n' && p[1]) last = p + 1;
  if (last[0] == 'd' && last[1] == 'b' && last[2] == 'g' && last[3] == ':' && last[4] == ' ') last += 5;
  size_t n = 0;
  while (last[n] && last[n] != '\n' && n + 1 < sizeof gui.status) gui.status[n] = last[n], n++;
  gui.status[n] = 0;
}

static bool gui_open_source(const char *path) {
  if (gui.text && vx_str_eq(vx_cstr(path), vx_cstr(gui.file))) return true;
  vx_text_free(gui.text), vx_font_free(gui.bytes);
  gui.text = nullptr, gui.bytes = nullptr, gui.file[0] = 0;
  vx_fd fd = vx_open(vx_cstr(path), VX_OREAD);
  if (fd < 0) return false;
  static constexpr size_t MAX = 4u << 20;
  gui.bytes = vx_font_alloc(MAX);
  size_t n = 0;
  for (int64_t r;
       gui.bytes && n < MAX && (r = vx_read(fd, (vx_bytes){(uint8_t *)gui.bytes + n, MAX - n})) > 0;)
    n += (size_t)r;
  vx_close(fd);
  if (!gui.bytes || !(gui.text = vx_text_new(gui.bytes, n))) return false;
  size_t k = 0;
  while (path[k] && k + 1 < sizeof gui.file) gui.file[k] = path[k], k++;
  gui.file[k] = 0;
  return true;
}

// The source line of pc, its file opened and the view moved to show it.
static void gui_show(uint64_t pc) {
  const vxdi_line *l = vxdi_line_at(&ix, pc);
  if (!l) return;
  if (!gui_open_source(vxdi_file(&ix, l->file))) {
    gui.line = 0;
    return;
  }
  gui.line = l->line;
  int64_t rows = gui.line_h ? ((int64_t)gui.h - GUI_TOOL_H - GUI_HEAD_H) / gui.line_h : 20;
  if ((int64_t)gui.line - 1 < gui.top || (int64_t)gui.line - 1 >= gui.top + rows - 2)
    gui.top = (int64_t)gui.line - 1 - rows / 3 > 0 ? (int64_t)gui.line - 1 - rows / 3 : 0;
}

// The selected frame's locals: each variable of its function in scope at
// its pc, by print's own words.
static void gui_locals(void) {
  gui.locals.buf[0] = 0;
  gui.locals.n = 0;
  if (!nframes) return;
  uint64_t pc = vxd_frame_lookup_pc(&frames[frame]);
  const vxdi_func *f = vxdi_func_at(&ix, pc);
  size_t len = 0, cap = sizeof gui.locals.buf;
  for (uint32_t i = 0; f && i < f->var_count && f->first_var + i < ix.h->vars.count; i++) {
    const vxdi_var *v = &ix.vars[f->first_var + i];
    if (v->scope_high && (pc < v->scope_low || pc >= v->scope_high)) continue;
    const char *name = vxdi_str(&ix, v->name);
    char value[256];
    gui_capture_begin(value, sizeof value);
    print(vx_cstr(name));
    gui_capture_end();
    for (const char *p = name; *p && len + 1 < cap; p++) gui.locals.buf[len++] = *p;
    if (len + 1 < cap) gui.locals.buf[len++] = ' '; // then print's "= value", or its complaint
    for (const char *p = value; *p && len + 1 < cap; p++) gui.locals.buf[len++] = *p;
  }
  gui.locals.buf[len] = 0;
  gui_split(&gui.locals);
}

// Everything shown read again from the debugger: the window's thread only.
static void gui_refresh(void) {
  gui_capture_begin(gui.threads.buf, sizeof gui.threads.buf);
  if (live || crash_dir[0]) threads();
  gui_capture_end();
  gui_split(&gui.threads);
  if (gui.threads.n && gui.threads.line[gui.threads.n - 1].len > 5 &&
      !memcmp(gui.threads.line[gui.threads.n - 1].ptr, "dbg: ", 5))
    gui.threads.n--; // the count, not a thread
  gui_capture_begin(gui.stack.buf, sizeof gui.stack.buf);
  if (nframes) bt();
  gui_capture_end();
  gui_split(&gui.stack);
  gui_locals();
  if (nframes) gui_show(vxd_frame_lookup_pc(&frames[frame]));
}

// Runs a command that does not wait, on the window's thread.
static void gui_command(const char *cmd) {
  static char out[1024];
  gui_capture_begin(out, sizeof out);
  command(vx_cstr(cmd));
  gui_capture_end();
  vx_print(vx_cstr(out)); // on standard output too, as dbg -c says it
  gui_set_status(out);
  gui_refresh();
}

static const char *gui_worker(void *arg) {
  (void)arg;
  gui_capture_begin(gui.out, sizeof gui.out);
  command(vx_cstr(gui.cmd));
  gui_capture_end();
  vx_lock(&gui.lock);
  gui.busy = false;
  vx_unlock(&gui.lock);
  vx_app_wake(gui.app);
  return nullptr;
}

// Runs a command that waits for the program, on the worker.
static void gui_start(const char *cmd) {
  vx_lock(&gui.lock);
  bool busy = gui.busy;
  gui.busy = !busy;
  vx_unlock(&gui.lock);
  if (busy) return;
  size_t n = 0;
  while (cmd[n] && n + 1 < sizeof gui.cmd) gui.cmd[n] = cmd[n], n++;
  gui.cmd[n] = 0;
  gui_set_status("running");
  if (!vx_thread_spawn(gui_worker, nullptr, 0, 0)) {
    vx_lock(&gui.lock), gui.busy = false, vx_unlock(&gui.lock);
    gui_set_status("cannot start a thread");
  }
}

static bool gui_busy(void) {
  vx_lock(&gui.lock);
  bool b = gui.busy;
  vx_unlock(&gui.lock);
  return b;
}

// --- Drawing ---

typedef struct gui_button {
  const char *label;
  int32_t x, w;
  bool on;
} gui_button;

static bool gui_launchable(void) { return !live && !pid && !crash_dir[0]; }

static uint32_t gui_buttons(gui_button *b) {
  bool busy = gui_busy();
  b[0] = (gui_button){live ? "Continue" : "Run", 8, 84, !busy && (live || gui_launchable())};
  b[1] = (gui_button){"Step", 98, 64, !busy && live};
  b[2] = (gui_button){"Kill", 168, 64, !busy && live};
  return 3;
}

static void gui_fill(vx_pixels *px, int32_t x0, int32_t y0, int32_t x1, int32_t y1, uint32_t c) {
  if (x0 < 0) x0 = 0;
  if (y0 < 0) y0 = 0;
  if (x1 > (int32_t)px->w) x1 = (int32_t)px->w;
  if (y1 > (int32_t)px->h) y1 = (int32_t)px->h;
  for (int32_t y = y0; y < y1; y++) {
    uint32_t *row = (uint32_t *)(px->data + (size_t)y * px->stride);
    for (int32_t x = x0; x < x1; x++) row[x] = c;
  }
}

static void gui_text(vx_pixels *px, vx_font *f, int32_t ascent, int32_t x, int32_t y, int32_t x1, int32_t y1,
                     uint32_t colour, vx_str s) {
  vx_font_target t = {.px = (uint32_t *)px->data,
                      .stride = px->stride / 4,
                      .clip_x0 = x > 0 ? x : 0,
                      .clip_y0 = y > 0 ? y : 0,
                      .clip_x1 = x1 < (int32_t)px->w ? x1 : (int32_t)px->w,
                      .clip_y1 = y1 < (int32_t)px->h ? y1 : (int32_t)px->h};
  vx_text_draw(&t, &gui.atlas, f, GUI_PX, x, y + ascent, colour, s.ptr, s.len);
}

// Source text, a glyph a rune in fixed cells, unshaped: no ligatures, the
// columns the file's (the terminal's way, 7f1).
static void gui_mono(vx_pixels *px, int32_t x, int32_t y, int32_t x1, int32_t y1, uint32_t colour, vx_str s) {
  vx_font_target t = {.px = (uint32_t *)px->data,
                      .stride = px->stride / 4,
                      .clip_x0 = x > 0 ? x : 0,
                      .clip_y0 = y > 0 ? y : 0,
                      .clip_x1 = x1 < (int32_t)px->w ? x1 : (int32_t)px->w,
                      .clip_y1 = y1 < (int32_t)px->h ? y1 : (int32_t)px->h};
  int64_t pen = (int64_t)x * 64;
  for (size_t at = 0; at < s.len && pen / 64 < x1;) {
    vx_rune r;
    at += vx_chartorune(&r, s.ptr + at, s.len - at);
    if (r > ' ')
      vx_glyph_draw(&t, &gui.atlas, &gui.mono, GUI_PX, vx_font_glyph(&gui.mono, r), pen, y + gui.mono_ascent,
                    colour);
    pen += gui.cell_w64;
  }
}

static void gui_bevel(vx_pixels *px, int32_t x, int32_t y, int32_t w, int32_t h, bool on) {
  gui_fill(px, x, y, x + w, y + h, on ? 0xcfcac0 : 0xc4bfb5);
  gui_fill(px, x, y, x + w, y + 1, 0xf4f1ea);
  gui_fill(px, x, y, x + 1, y + h, 0xf4f1ea);
  gui_fill(px, x, y + h - 1, x + w, y + h, 0x6c6860);
  gui_fill(px, x + w - 1, y, x + w, y + h, 0x6c6860);
}

static void gui_header(vx_pixels *px, int32_t x0, int32_t x1, int32_t y, const char *title) {
  gui_fill(px, x0, y, x1, y + GUI_HEAD_H, 0xbdb8ae);
  gui_fill(px, x0, y + GUI_HEAD_H - 1, x1, y + GUI_HEAD_H, 0x8a857c);
  gui_text(px, &gui.ui, gui.ui_ascent, x0 + 6, y + 3, x1, y + GUI_HEAD_H, 0x1c1c1c, vx_cstr(title));
}

// Whether a breakpoint is set on line n of the file shown.
static bool gui_break_on(uint32_t n) {
  for (uint32_t i = 0; i < nbreaks; i++) {
    const vxdi_line *l = vxdi_line_at(&ix, breaks[i]);
    if (l && l->line == n && vx_str_eq(vx_cstr(vxdi_file(&ix, l->file)), vx_cstr(gui.file))) return true;
  }
  return false;
}

static void gui_source(vx_pixels *px, int32_t x1) {
  int32_t y0 = GUI_TOOL_H, top = y0 + GUI_HEAD_H, bottom = (int32_t)px->h;
  const char *shown = gui.file[0] ? gui.file : "no source";
  gui_header(px, 0, x1, y0, shown);
  gui_fill(px, 0, top, x1, bottom, 0xf4f1ea);
  gui_fill(px, 0, top, GUI_GUTTER_W, bottom, 0xe4e0d8);
  if (!gui.text) return;
  uint64_t lines = vx_text_lines(gui.text) + 1;
  for (int64_t row = 0; top + row * gui.line_h < bottom; row++) {
    uint64_t n = (uint64_t)(gui.top + row); // from 0
    if (n >= lines) break;
    int32_t y = top + (int32_t)row * gui.line_h;
    if (n + 1 == gui.line) gui_fill(px, GUI_GUTTER_W, y, x1, y + gui.line_h, 0xf2e3a6);
    char num[12];
    size_t k = vx_bfmt((vx_bytes){(uint8_t *)num, sizeof num}, "%4llu", (unsigned long long)n + 1);
    gui_mono(px, 4, y, GUI_GUTTER_W - 14, bottom, 0x8a857c, (vx_str){num, k});
    if (gui_break_on((uint32_t)n + 1)) {
      int32_t cx = GUI_GUTTER_W - 8, cy = y + gui.line_h / 2;
      for (int32_t dy = -4; dy <= 4; dy++)
        for (int32_t dx = -4; dx <= 4; dx++)
          if (dx * dx + dy * dy <= 16) gui_fill(px, cx + dx, cy + dy, cx + dx + 1, cy + dy + 1, 0xb3261e);
    }
    if (n + 1 == gui.line)
      gui_fill(px, GUI_GUTTER_W + 1, y + 2, GUI_GUTTER_W + 4, y + gui.line_h - 2, 0x1c1c1c);
    uint64_t a = vx_text_line_start(gui.text, n), b = vx_text_line_start(gui.text, n + 1);
    char text[512];
    uint64_t len = vx_text_read(gui.text, a, text, b - a < sizeof text ? b - a : sizeof text);
    while (len && (text[len - 1] == '\n' || text[len - 1] == '\r')) len--;
    for (uint64_t i = 0; i < len; i++)
      if (text[i] == '\t') text[i] = ' ';
    gui_mono(px, GUI_GUTTER_W + 8, y, x1 - 4, bottom, 0x1c1c1c, (vx_str){text, len});
  }
}

static int32_t gui_list(vx_pixels *px, int32_t x0, int32_t y, int32_t bottom, const char *title,
                        const gui_lines *l, uint32_t most) {
  gui_header(px, x0, (int32_t)px->w, y, title);
  y += GUI_HEAD_H;
  uint32_t rows = l->n < most ? l->n : most;
  if (!rows) rows = 1;
  int32_t end = y + (int32_t)rows * gui.line_h + 4;
  if (end > bottom) end = bottom;
  gui_fill(px, x0, y, (int32_t)px->w, end, 0xf4f1ea);
  for (uint32_t i = 0; i < l->n && i < most; i++) {
    vx_str s = l->line[i];
    bool mark = s.len && s.ptr[0] == '*';
    if (mark)
      gui_fill(px, x0, y + 2 + (int32_t)i * gui.line_h, (int32_t)px->w, y + 2 + (int32_t)(i + 1) * gui.line_h,
               0xdfe6f1);
    gui_mono(px, x0 + 4, y + 2 + (int32_t)i * gui.line_h, (int32_t)px->w - 2, end, 0x1c1c1c, s);
  }
  return end;
}

static void gui_draw(vx_pixels *px) {
  int32_t w = (int32_t)px->w, h = (int32_t)px->h, split = w - (int32_t)GUI_RIGHT_W;
  gui_fill(px, 0, 0, w, GUI_TOOL_H, 0xd8d3c8);
  gui_fill(px, 0, GUI_TOOL_H - 1, w, GUI_TOOL_H, 0x8a857c);
  gui_button b[3];
  uint32_t nb = gui_buttons(b);
  for (uint32_t i = 0; i < nb; i++) {
    gui_bevel(px, b[i].x, 5, b[i].w, 22, b[i].on);
    vx_str label = vx_cstr(b[i].label);
    int32_t adv = 0;
    vx_glyph_at g[32];
    vx_font_shape(&gui.ui, label.ptr, label.len, g, 32, &adv);
    int32_t tw = vx_font_to64(&gui.ui, adv, GUI_PX) / 64;
    gui_text(px, &gui.ui, gui.ui_ascent, b[i].x + (b[i].w - tw) / 2, 9, b[i].x + b[i].w, 27,
             b[i].on ? 0x1c1c1c : 0x8a857c, label);
  }
  gui_text(px, &gui.ui, gui.ui_ascent, 244, 9, w - 4, 27, 0x1c1c1c,
           vx_cstr(gui_busy() ? "running" : gui.status));
  gui_source(px, split - 1);
  gui_fill(px, split - 1, GUI_TOOL_H, split, h, 0x8a857c);
  int32_t y = gui_list(px, split, GUI_TOOL_H, h, "Threads", &gui.threads, 5);
  y = gui_list(px, split, y, h, "Call stack", &gui.stack, 10);
  y = gui_list(px, split, y, h, "Locals", &gui.locals, GUI_MAX_LINES);
  gui_fill(px, split, y, w, h, 0xe4e0d8);
}

// --- Input ---

enum : uint32_t { GUI_THREADS, GUI_STACK, GUI_LOCALS };

// Which line of list `which` a y falls on, given the lists' layout: -1 none.
static int32_t gui_list_row(float y, uint32_t which) {
  int32_t at = GUI_TOOL_H;
  const gui_lines *lists[3] = {&gui.threads, &gui.stack, &gui.locals};
  const uint32_t most[3] = {5, 10, GUI_MAX_LINES};
  for (uint32_t i = 0; i < 3; i++) {
    uint32_t rows = lists[i]->n < most[i] ? lists[i]->n : most[i];
    int32_t first = at + (int32_t)GUI_HEAD_H + 2;
    int32_t row = y >= (float)first ? (int32_t)((y - (float)first) / (float)gui.line_h) : -1;
    if (i == which) return row >= 0 && (uint32_t)row < rows ? row : -1;
    at += (int32_t)GUI_HEAD_H + (int32_t)(rows ? rows : 1) * gui.line_h + 4;
  }
  return -1;
}

static void gui_click(float x, float y) {
  if (gui_busy()) return;
  gui_button b[3];
  uint32_t nb = gui_buttons(b);
  if (y >= 5 && y < 27) {
    for (uint32_t i = 0; i < nb; i++) {
      if (!b[i].on || x < (float)b[i].x || x >= (float)(b[i].x + b[i].w)) continue;
      if (i == 0)
        gui_start(live ? "cont" : "run");
      else if (i == 1)
        gui_start("step");
      else
        gui_start("kill");
    }
    return;
  }
  int32_t split = (int32_t)gui.w - (int32_t)GUI_RIGHT_W;
  if (x < (float)GUI_GUTTER_W && y >= (float)(GUI_TOOL_H + GUI_HEAD_H) && gui.text &&
      gui.line_h) { // a breakpoint
    int64_t n = gui.top + (int64_t)((y - (float)(GUI_TOOL_H + GUI_HEAD_H)) / (float)gui.line_h) + 1;
    char cmd[256];
    vx_bfmt((vx_bytes){(uint8_t *)cmd, sizeof cmd}, "%s %s:%lld",
            gui_break_on((uint32_t)n) ? "unbreak" : "break", gui.file, (long long)n);
    gui_command(cmd);
    return;
  }
  if (x < (float)split) return;
  int32_t row = gui_list_row(y, GUI_STACK);
  if (row >= 0) {
    char cmd[32];
    vx_bfmt((vx_bytes){(uint8_t *)cmd, sizeof cmd}, "frame %d", row);
    gui_command(cmd);
    return;
  }
  row = gui_list_row(y, GUI_THREADS);
  if (row >= 0) {
    vx_str s = gui.threads.line[row];
    uint64_t tid = 0;
    for (size_t i = 0; i < s.len; i++) {
      if (s.ptr[i] >= '0' && s.ptr[i] <= '9')
        tid = tid * 10 + (uint64_t)(s.ptr[i] - '0');
      else if (tid)
        break;
    }
    char cmd[32];
    vx_bfmt((vx_bytes){(uint8_t *)cmd, sizeof cmd}, "thread %llu", (unsigned long long)tid);
    gui_command(cmd);
  }
}

static void gui_scroll(int64_t lines) {
  gui.top += lines;
  int64_t most = gui.text ? (int64_t)vx_text_lines(gui.text) : 0;
  if (gui.top > most) gui.top = most;
  if (gui.top < 0) gui.top = 0;
}

static bool gui_input(const vx_event *ev) {
  if (ev->kind == VX_POINTER) {
    bool down = ev->pointer.buttons & 1, was = gui.buttons & 1;
    gui.px = ev->pointer.x, gui.py = ev->pointer.y, gui.buttons = ev->pointer.buttons;
    if (ev->pointer.wheel && gui.px < (float)(gui.w - GUI_RIGHT_W)) {
      gui_scroll(ev->pointer.wheel > 0 ? -3 : 3);
      return true;
    }
    if (down && !was) {
      gui_click(gui.px, gui.py);
      return true;
    }
    return false;
  }
  if (ev->kind != VX_KEY || !ev->keyboard.down) return false;
  switch (ev->keyboard.usage & 0xffff) {
  case 0x3e: // F5
    if (!gui_busy() && (live || gui_launchable())) gui_start(live ? "cont" : "run");
    return true;
  case 0x44: // F11
    if (!gui_busy() && live) gui_start("step");
    return true;
  case 0x51: gui_scroll(1); return true;
  case 0x52: gui_scroll(-1); return true;
  case 0x4e: gui_scroll(20); return true;
  case 0x4b: gui_scroll(-20); return true;
  default: return false;
  }
}

static bool gui_font(vx_font *f, const char *path, uint32_t id) {
  vx_fd fd = vx_open(vx_cstr(path), VX_OREAD);
  if (fd < 0) return false;
  static constexpr size_t MAX = 2u << 20;
  uint8_t *buf = vx_font_alloc(MAX);
  size_t n = 0;
  for (int64_t r; buf && n < MAX && (r = vx_read(fd, (vx_bytes){buf + n, MAX - n})) > 0;) n += (size_t)r;
  vx_close(fd);
  return buf && n && vx_font_init(f, buf, n, id);
}

// The window, until it is closed; false if there is no window system (no
// /wsys/new), for dbg to fall back to its command line.
static bool gui_run(vx_str script) {
  vx_arena *scratch = vx_arena_new(1 << 16);
  vx_dir d;
  bool wsys = vx_stat(VX_STR("/wsys/new"), scratch, &d) == VX_OK;
  vx_arena_free(scratch);
  if (!wsys) return false;
  gui.app = vx_app_open("org.vectra.dbg");
  if (vx_app_error(gui.app)) return false;
  if (!vx_atlas_init(&gui.atlas, 512) || !gui_font(&gui.ui, GUI_UI_FONT, 4) ||
      !gui_font(&gui.mono, GUI_MONO_FONT, 5))
    return false;
  gui.ui_ascent = (vx_font_to64(&gui.ui, gui.ui.ascent, GUI_PX) + 32) / 64;
  gui.mono_ascent = (vx_font_to64(&gui.mono, gui.mono.ascent, GUI_PX) + 32) / 64;
  gui.line_h =
      (vx_font_to64(&gui.mono, gui.mono.ascent - gui.mono.descent + gui.mono.line_gap, GUI_PX) + 63) / 64;
  int adv = 0, lsb = 0;
  stbtt_GetCodepointHMetrics(&gui.mono.tt, 'M', &adv, &lsb);
  gui.cell_w64 = vx_font_to64(&gui.mono, adv, GUI_PX);
  char title[160];
  vx_bfmt((vx_bytes){(uint8_t *)title, sizeof title}, "dbg: %.*s", (int)program_len, program);
  gui.win = vx_window_open(gui.app, title, 760, 520);
  gui.w = 760, gui.h = 520;
  // The script's commands first (breakpoints, say), each said in the status.
  static char text[4096];
  size_t len = 0;
  vx_ns_file f;
  if (script.len && vx_ns_open(&ns, script, P9_OREAD, &f) == VX_OK) {
    for (int64_t n; len < sizeof text && (n = vx_ns_read(&f, text + len, (uint32_t)(sizeof text - len))) > 0;)
      len += (size_t)n;
    vx_ns_close(&f);
  }
  for (size_t at = 0; at < len;) {
    size_t e = at;
    while (e < len && text[e] != '\n') e++;
    char line[128];
    size_t k = e - at < sizeof line - 1 ? e - at : sizeof line - 1;
    memcpy(line, text + at, k), line[k] = 0;
    gui_command(line);
    at = e + 1;
  }
  gui_refresh();
  if (!nframes) { // not stopped: the program's entry, to set breakpoints in
    const vxdi_func *main = vxdi_func_named(&ix, "vx_main");
    if (!main) main = vxdi_func_named(&ix, "main");
    if (main) gui_show(main->body), gui.line = 0;
  }
  if (!gui.status[0] && crash_dir[0]) gui_set_status("a crash directory");
  if (!gui.status[0]) gui_set_status(live ? "attached" : "not started");
  vx_event ev;
  while (vx_wait(gui.app, &ev, VX_INFINITE)) {
    switch (ev.kind) {
    case VX_CLOSE: return true;
    case VX_CONFIGURE:
      gui.w = ev.configure.width, gui.h = ev.configure.height;
      vx_window_redraw(gui.win);
      break;
    case VX_WAKE: // the worker's command has returned
      if (!gui_busy()) vx_print(vx_cstr(gui.out)), gui_set_status(gui.out), gui_refresh();
      vx_window_redraw(gui.win);
      break;
    case VX_FRAME: {
      vx_pixels px = vx_pixels_begin(gui.win, &ev.frame);
      if (!px.data) break;
      gui.w = px.w, gui.h = px.h;
      gui_draw(&px);
      vx_pixels_present(gui.win, &px);
      break;
    }
    default:
      if (gui_input(&ev)) vx_window_redraw(gui.win);
      break;
    }
  }
  return true;
}
