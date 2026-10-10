// term: the terminal (M7 step 7f1; term(1)): a vxui window running rc on a
// pseudo-terminal of ptyd(4). Its own thread reads the master and takes the
// output into a grid of cells, under the grid's lock, and wakes the window;
// the window draws the rows that changed, a frame at a time, however much
// output came between (refterm's lesson, 03 §6: the terminal is never the
// bottleneck). Keys go to the master: text as the server resolved it (its
// ime on, purpose terminal), commands as the control characters and escape
// sequences a VT100 sends. Output understands what rc and the POSIX
// programs write: UTF-8, CR, LF, BS, TAB, and the CSI sequences for the
// cursor, erasing and colours (SGR). Lines scrolled off are kept, and the
// wheel or shift and page up or down shows them.
//
// -m: measured (00 §8): each key's time to the frame showing its echo, on
// standard error.

#include <vxui.h>

static constexpr uint32_t PX = 14, PAD = 4, MAX_COLS = 256, MAX_ROWS = 128, HISTORY = 2048;
static constexpr char FONT[] = "/lib/font/JetBrainsMono-Regular.ttf";

typedef struct cell {
  uint32_t rune;
  uint8_t fg, bg, attr; // palette indices; attr: 1 bold, 2 inverse
} cell;

enum : uint8_t { BOLD = 1, INVERSE = 2, DEFAULT_FG = 16, DEFAULT_BG = 17 };

// For a light background: black, red, green, yellow, blue, magenta, cyan,
// white, their bright forms, then the default foreground and background.
static const uint32_t PALETTE[18] = {0x1c1c1c, 0xb3261e, 0x2e7d32, 0x8a6d00, 0x2f5fa8, 0x8e3b8e,
                                     0x00796b, 0xbdb8ae, 0x5c5c5c, 0xd84a3a, 0x43a047, 0xb08900,
                                     0x4a7fd0, 0xb05bb0, 0x26a69a, 0xf4f1ea, 0x1c1c1c, 0xf4f1ea};

// The grid: the lock's, shared by the reader (which writes it) and the
// window (which draws it).
static struct {
  vx_lock_t lock;
  cell lines[HISTORY][MAX_COLS]; // a ring: line n is lines[n % HISTORY]
  uint16_t len[HISTORY];         // its cells in use; those past it are blank
  uint64_t top;                  // the screen's first line
  uint32_t cols, rows;
  uint32_t cx, cy; // the cursor, on the screen; cx == cols: a wrap pending
  uint8_t fg, bg, attr;
  uint64_t dirty[MAX_ROWS / 64]; // screen rows changed since the last frame
  bool all;                      // every row (a scroll, a resize)
  // The parser's state between reads.
  uint32_t state, utf, utf_left, params[8], nparams;
  bool private_mode;

  bool output_new; // since the last frame: a key's echo, for -m
} g;

static vx_app *app;
static vx_window *win;
static vx_fd master = -1, typing = -1; // the master, read; and joined, written (vx_file_join)
static char ctl[40];                   // the slave's settings, /dev/pts/<n>.ctl
static bool measured, done;

static cell *line(uint64_t n) { return g.lines[n % HISTORY]; }

static int64_t clamp(int64_t v, int64_t lo, int64_t hi) {
  if (v < lo) return lo;
  return v > hi ? hi : v;
}

// The lines above the screen that the history still holds.
static uint32_t history_kept(void) { return (uint32_t)clamp((int64_t)g.top, 0, HISTORY - MAX_ROWS); }

static void dirty(uint32_t row) {
  if (row < MAX_ROWS) g.dirty[row / 64] |= 1ull << (row % 64);
}

// Screen row r's line's cells from..to blanked, in the colours now. Blank
// to the end in the default background is the line made shorter.
static void blank(uint32_t r, uint32_t from, uint32_t to) {
  uint64_t n = g.top + r;
  uint16_t *len = &g.len[n % HISTORY];
  if (to > MAX_COLS) to = MAX_COLS;
  if (to >= *len && g.bg == DEFAULT_BG && !(g.attr & INVERSE)) {
    if (from < *len) *len = (uint16_t)from;
  } else {
    cell *l = line(n);
    for (uint32_t c = from < *len ? from : *len; c < to; c++)
      l[c] = (cell){.rune = ' ', .fg = g.fg, .bg = g.bg};
    if (to > *len) *len = (uint16_t)to;
  }
  dirty(r);
}

static void newline(void) {
  if (g.cy + 1 < g.rows) {
    g.cy++;
    return;
  }
  g.top++, g.all = true; // the screen scrolls: its first line goes to the history
  g.len[(g.top + g.rows - 1) % HISTORY] = 0;
}

// Where the cursor writes: its line, the cells before it filled if the line
// was shorter, the cursor wrapped first if it is past the end.
static cell *at_cursor(void) {
  if (g.cx >= g.cols) g.cx = 0, newline();
  uint16_t *len = &g.len[(g.top + g.cy) % HISTORY];
  cell *l = line(g.top + g.cy);
  for (; *len < g.cx; (*len)++) l[*len] = (cell){.rune = ' ', .fg = DEFAULT_FG, .bg = DEFAULT_BG};
  return l;
}

static void put(uint32_t rune) {
  cell *l = at_cursor();
  l[g.cx++] = (cell){.rune = rune, .fg = g.fg, .bg = g.bg, .attr = g.attr};
  uint16_t *len = &g.len[(g.top + g.cy) % HISTORY];
  if (g.cx > *len) *len = (uint16_t)g.cx;
  dirty(g.cy);
}

static uint32_t param(uint32_t i, uint32_t def) { return i < g.nparams && g.params[i] ? g.params[i] : def; }

static void sgr(void) {
  for (uint32_t i = 0; i < (g.nparams ? g.nparams : 1); i++) {
    uint32_t p = i < g.nparams ? g.params[i] : 0;
    if (p == 0)
      g.fg = DEFAULT_FG, g.bg = DEFAULT_BG, g.attr = 0;
    else if (p == 1)
      g.attr |= BOLD;
    else if (p == 22)
      g.attr &= (uint8_t)~BOLD;
    else if (p == 7)
      g.attr |= INVERSE;
    else if (p == 27)
      g.attr &= (uint8_t)~INVERSE;
    else if (p >= 30 && p <= 37)
      g.fg = (uint8_t)(p - 30);
    else if (p == 39)
      g.fg = DEFAULT_FG;
    else if (p >= 40 && p <= 47)
      g.bg = (uint8_t)(p - 40);
    else if (p == 49)
      g.bg = DEFAULT_BG;
    else if (p >= 90 && p <= 97)
      g.fg = (uint8_t)(p - 90 + 8);
    else if (p >= 100 && p <= 107)
      g.bg = (uint8_t)(p - 100 + 8);
  }
}

static void csi(uint8_t final) {
  uint32_t n = param(0, 1);
  switch (final) {
  case 'A': g.cy = n > g.cy ? 0 : g.cy - n; break;
  case 'B': g.cy = g.cy + n >= g.rows ? g.rows - 1 : g.cy + n; break;
  case 'C': g.cx = g.cx + n >= g.cols ? g.cols - 1 : g.cx + n; break;
  case 'D': g.cx = n > g.cx ? 0 : g.cx - n; break;
  case 'G': g.cx = n > g.cols ? g.cols - 1 : n - 1; break;
  case 'H':
  case 'f':
    g.cy = param(0, 1) > g.rows ? g.rows - 1 : param(0, 1) - 1;
    g.cx = param(1, 1) > g.cols ? g.cols - 1 : param(1, 1) - 1;
    break;
  case 'J': // 0: to the end, 1: from the start, 2 and 3: all
    if (param(0, 0) == 0) {
      blank(g.cy, g.cx, MAX_COLS);
      for (uint32_t r = g.cy + 1; r < g.rows; r++) blank(r, 0, MAX_COLS);
    } else if (param(0, 0) == 1) {
      for (uint32_t r = 0; r < g.cy; r++) blank(r, 0, MAX_COLS);
      blank(g.cy, 0, g.cx + 1);
    } else {
      for (uint32_t r = 0; r < g.rows; r++) blank(r, 0, MAX_COLS);
    }
    g.all = true;
    break;
  case 'K': // 0: to the end, 1: from the start, 2: the line
    if (param(0, 0) == 0)
      blank(g.cy, g.cx, MAX_COLS);
    else if (param(0, 0) == 1)
      blank(g.cy, 0, g.cx + 1);
    else
      blank(g.cy, 0, MAX_COLS);
    break;
  case 'm':
    if (!g.private_mode) sgr();
    break;
  default: break; // modes (?25h and the rest), scrolling regions: not yet
  }
  dirty(g.cy);
}

enum : uint32_t { NORMAL, ESC, CSI, OSC, OSC_ESC };

// Output taken into the grid, under its lock.
static void take(const uint8_t *p, size_t n) {
  for (size_t i = 0; i < n; i++) {
    uint8_t b = p[i];
    if (g.state == NORMAL && b >= 0x20 && b < 0x7f && !g.utf_left) { // the common case: a run of ASCII
      size_t k = i;
      while (k < n && p[k] >= 0x20 && p[k] < 0x7f) { // as much of it as the line has room for, at once
        cell *l = at_cursor();
        uint32_t room = g.cols - g.cx, m = 0;
        for (; m < room && k + m < n && p[k + m] >= 0x20 && p[k + m] < 0x7f; m++)
          l[g.cx + m] = (cell){.rune = p[k + m], .fg = g.fg, .bg = g.bg, .attr = g.attr};
        g.cx += m, k += m;
        uint16_t *len = &g.len[(g.top + g.cy) % HISTORY];
        if (g.cx > *len) *len = (uint16_t)g.cx;
        dirty(g.cy);
      }
      i = k - 1;
      continue;
    }
    switch (g.state) {
    case NORMAL:
      if (g.utf_left) { // a rune's continuation
        if ((b & 0xc0) == 0x80) {
          g.utf = g.utf << 6 | (b & 0x3f);
          if (--g.utf_left == 0) put(g.utf);
          continue;
        }
        g.utf_left = 0, put(0xfffd); // broken: shown as such, and b taken afresh
      }
      if (b >= 0xc0 && b < 0xf8) {
        g.utf_left = 1 + (b >= 0xe0) + (b >= 0xf0);
        g.utf = b & (0x3f >> g.utf_left);
      } else if (b >= 0x80) {
        put(0xfffd);
      } else if (b == '\r') {
        g.cx = 0;
      } else if (b == '\n' || b == '\v' || b == '\f') {
        newline();
        dirty(g.cy);
      } else if (b == '\b') {
        if (g.cx) g.cx--;
        dirty(g.cy);
      } else if (b == '\t') {
        uint32_t to = (g.cx / 8 + 1) * 8;
        while (g.cx < to && g.cx < g.cols) put(' ');
      } else if (b == 0x1b) {
        g.state = ESC;
      }
      break;
    case ESC:
      g.state = NORMAL;
      if (b == '[' || b == ']') g.state = b == '[' ? CSI : OSC;
      g.nparams = 0, g.params[0] = 0, g.private_mode = false;
      break;
    case CSI:
      if (b >= '0' && b <= '9') {
        if (!g.nparams) g.nparams = 1;
        g.params[g.nparams - 1] = g.params[g.nparams - 1] * 10 + (b - '0');
      } else if (b == ';') {
        if (!g.nparams) g.nparams = 1;
        if (g.nparams < 8) g.params[g.nparams++] = 0;
      } else if (b == '?' || b == '>' || b == '=') {
        g.private_mode = true;
      } else if (b >= 0x40 && b <= 0x7e) {
        csi(b), g.state = NORMAL;
      }
      break;
    case OSC: // a title and the like: skipped, to BEL or ST
      if (b == 7 || b == 0x1b) g.state = b == 7 ? NORMAL : OSC_ESC;
      break;
    case OSC_ESC: g.state = NORMAL; break;
    default: g.state = NORMAL;
    }
  }
  g.output_new = true;
}

// The reader: the master's output into the grid, the window woken.
static const char *reader(void *arg) {
  (void)arg;
  static uint8_t buf[65536];
  for (int64_t n; (n = vx_read(master, (vx_bytes){buf, sizeof buf})) > 0;) {
    vx_lock(&g.lock);
    take(buf, (size_t)n);
    vx_unlock(&g.lock);
    vx_app_wake(app);
  }
  return nullptr;
}

static vx_proc shell;

// The shell's end: the terminal's.
static const char *watcher(void *arg) {
  (void)arg;
  vx_str why = {};
  vx_proc_wait(shell, VX_INFINITE, vx_scratch(nullptr, 0), &why);
  if (why.len) vx_eprintf("term: the shell exited: %.*s\n", VX_FMT(why));
  done = true;
  vx_app_wake(app);
  return nullptr;
}

// --- Drawing ---

static vx_font font;
static vx_atlas atlas;
static int32_t cell_w64, cell_h, ascent; // cell_w64 in 1/64 pixels

static void fill(vx_pixels *px, int32_t x0, int32_t y0, int32_t x1, int32_t y1, uint32_t c) {
  if (x1 > (int32_t)px->w) x1 = (int32_t)px->w;
  if (y1 > (int32_t)px->h) y1 = (int32_t)px->h;
  for (int32_t y = y0 < 0 ? 0 : y0; y < y1; y++) {
    uint32_t *row = (uint32_t *)(px->data + (size_t)y * px->stride);
    for (int32_t x = x0 < 0 ? 0 : x0; x < x1; x++) row[x] = c;
  }
}

static uint32_t glyph_of(uint32_t rune) {
  static uint32_t ascii[128];
  if (rune < 128) {
    if (!ascii[rune]) ascii[rune] = vx_font_glyph(&font, rune) | 1u << 31;
    return ascii[rune] & ~(1u << 31);
  }
  return vx_font_glyph(&font, rune);
}

static int32_t col_x(uint32_t c) { return (int32_t)PAD + (int32_t)(((int64_t)c * cell_w64) / 64); }

static void draw_row(vx_pixels *px, vx_font_target *t, uint32_t r, uint64_t n, int32_t cursor) {
  const cell *l = line(n), none = {.rune = ' ', .fg = DEFAULT_FG, .bg = DEFAULT_BG};
  uint32_t len = g.len[n % HISTORY];
  int32_t y = (int32_t)PAD + (int32_t)r * cell_h;
  fill(px, 0, y, (int32_t)px->w, y + cell_h, PALETTE[DEFAULT_BG]);
  if (r == 0) fill(px, 0, 0, (int32_t)px->w, PAD, PALETTE[DEFAULT_BG]);
  uint32_t last = len > g.cols ? g.cols : len;
  if (cursor >= 0 && (uint32_t)cursor >= last) last = (uint32_t)cursor + 1; // a cursor past the text
  for (uint32_t c = 0; c < last; c++) {
    const cell *e = c < len ? &l[c] : &none;
    uint32_t fg = PALETTE[e->fg], bg = PALETTE[e->bg];
    if (e->attr & BOLD && e->fg < 8) fg = PALETTE[e->fg + 8];
    if (e->attr & INVERSE || (int32_t)c == cursor) {
      uint32_t s = fg;
      fg = bg, bg = s;
    }
    if (bg != PALETTE[DEFAULT_BG]) fill(px, col_x(c), y, col_x(c + 1), y + cell_h, bg);
    if (e->rune > ' ')
      vx_glyph_draw(t, &atlas, &font, PX, glyph_of(e->rune), (int64_t)PAD * 64 + (int64_t)c * cell_w64,
                    y + ascent, fg);
  }
}

// The window's size in cells, the grid made to fit it, and the pty told.
static void fit(uint32_t w, uint32_t h) {
  uint32_t cols = cell_w64 ? (uint32_t)(((int64_t)(w > 2 * PAD ? w - 2 * PAD : 0) * 64) / cell_w64) : 80;
  uint32_t rows = cell_h ? (h > 2 * PAD ? h - 2 * PAD : 0) / (uint32_t)cell_h : 24;
  if (cols < 1) cols = 1;
  if (rows < 1) rows = 1;
  if (cols > MAX_COLS) cols = MAX_COLS;
  if (rows > MAX_ROWS) rows = MAX_ROWS;
  vx_lock(&g.lock);
  bool changed = cols != g.cols || rows != g.rows;
  if (rows < g.rows && g.cy >= rows) g.top += g.cy - rows + 1, g.cy = rows - 1; // the cursor stays on screen
  for (uint32_t r = g.rows; r < rows; r++) g.len[(g.top + r) % HISTORY] = 0;
  g.cols = cols, g.rows = rows, g.all = true;
  if (g.cx > cols) g.cx = cols;
  vx_unlock(&g.lock);
  if (changed && master >= 0) vx_ctl(vx_cstr(ctl), "rows=%u cols=%u", rows, cols);
}

// --- Keys ---

static void send(const char *s, size_t n) {
  if (typing >= 0 && n) vx_write(typing, (vx_str){s, n});
}

static void key(const vx_event *ev, uint32_t *scroll) {
  if (!ev->keyboard.down) return;
  uint32_t u = ev->keyboard.usage & 0xffff, m = ev->keyboard.mods;
  if (m & VX_MOD_SHIFT && (u == 0x4b || u == 0x4e)) { // shift and page up or down: the history
    int64_t page = g.rows > 1 ? g.rows - 1 : 1;
    *scroll = (uint32_t)clamp((int64_t)*scroll + (u == 0x4b ? page : -page), 0, history_kept());
    vx_lock(&g.lock), g.all = true, vx_unlock(&g.lock);
    return;
  }
  char c = 0;
  const char *seq = nullptr;
  uint32_t r = ev->keyboard.rune;
  if (m & VX_MOD_CTRL && ((r >= 'a' && r <= 'z') || (r >= '@' && r <= '_')))
    c = (char)(r & 0x1f);
  else if (u == 0x2a)
    c = 0x7f; // backspace
  else if (u == 0x29)
    c = 0x1b;
  else if (u == 0x52)
    seq = "\x1b[A";
  else if (u == 0x51)
    seq = "\x1b[B";
  else if (u == 0x4f)
    seq = "\x1b[C";
  else if (u == 0x50)
    seq = "\x1b[D";
  else if (u == 0x4a)
    seq = "\x1b[H";
  else if (u == 0x4d)
    seq = "\x1b[F";
  else if (u == 0x4c)
    seq = "\x1b[3~";
  if (c) send(&c, 1);
  if (seq) send(seq, vx_cstr(seq).len);
  if (c || seq) *scroll = 0;
}

static void text(vx_str t, uint32_t *scroll) {
  char buf[VX_WSYS_TEXT];
  size_t n = 0;
  for (size_t i = 0; i < t.len && n < sizeof buf; i++) buf[n++] = t.ptr[i] == '\n' ? '\r' : t.ptr[i];
  send(buf, n);
  *scroll = 0;
}

// --- The program ---

static bool load_font(void) {
  vx_fd fd = vx_open(VX_STR(FONT), VX_OREAD);
  if (fd < 0) return false;
  static constexpr size_t MAX = 2u << 20;
  uint8_t *buf = vx_font_alloc(MAX);
  size_t n = 0;
  for (int64_t r; buf && n < MAX && (r = vx_read(fd, (vx_bytes){buf + n, MAX - n})) > 0;) n += (size_t)r;
  vx_close(fd);
  if (!buf || !n || !vx_atlas_init(&atlas, 512) || !vx_font_init(&font, buf, n, 2)) return false;
  int adv = 0, lsb = 0;
  stbtt_GetCodepointHMetrics(&font.tt, 'M', &adv, &lsb);
  cell_w64 = vx_font_to64(&font, adv, PX);
  cell_h = (vx_font_to64(&font, font.ascent - font.descent + font.line_gap, PX) + 63) / 64;
  ascent = (vx_font_to64(&font, font.ascent, PX) + 32) / 64;
  return true;
}

// The slave relayed to rc, whose standard files are pipes (a native
// program's are: vx-rt's stdio), in both directions, each on a thread of its
// own: what is typed, as the line discipline gives it, into rc's stdin; what
// rc and its commands write, from their stdout and stderr, onto the slave.
static vx_fd slave_in = -1, slave_out = -1; // two opens: a read held on one fid holds up the next on it
static vx_handle to_shell, from_shell;      // our ends of rc's stdin and its stdout (stderr shares it)

static const char *typed(void *arg) {
  (void)arg;
  static alignas(vx_msg_header) uint8_t msg[sizeof(vx_msg_header) + 4096];
  for (int64_t n; (n = vx_read(slave_in, (vx_bytes){msg + sizeof(vx_msg_header), 4096})) > 0;) {
    *(vx_msg_header *)msg = (vx_msg_header){};
    while (vx_channel_write(to_shell, msg, (uint32_t)(sizeof(vx_msg_header) + (size_t)n), nullptr, 0) ==
           VX_ERR_SHOULD_WAIT) {
      static _Atomic uint32_t never;
      vx_futex_wait(&never, 0, vx_now() + 1'000'000); // rc is behind: its queue is full
    }
  }
  vx_handle_close(to_shell); // ^D on an empty line: the end of rc's input
  return nullptr;
}

static const char *output(void *arg) {
  (void)arg;
  static alignas(vx_msg_header) uint8_t msg[VX_CHANNEL_MAX_BYTES];
  static char out[65536];
  vx_handle port;
  if (vx_port_create(0, &port) != VX_OK) return nullptr;
  for (;;) {
    vx_msg_size size;
    vx_status st = vx_channel_read(from_shell, msg, sizeof msg, nullptr, 0, &size);
    if (st == VX_ERR_SHOULD_WAIT) {
      vx_packet pk;
      vx_port_bind(port, from_shell, VX_TRIGGER_READABLE, 0, 0);
      vx_port_bind(port, from_shell, VX_TRIGGER_PEER_CLOSED, 1, 0);
      vx_port_wait(port, VX_INFINITE, 0, &pk, 1);
      continue;
    }
    if (st != VX_OK) return nullptr; // every writer gone
    // What else is waiting, gathered behind it: one write to the slave.
    size_t n = size.bytes > sizeof(vx_msg_header) ? size.bytes - sizeof(vx_msg_header) : 0;
    memcpy(out, msg + sizeof(vx_msg_header), n);
    while (n + 4096 <= sizeof out &&
           vx_channel_read(from_shell, msg, sizeof msg, nullptr, 0, &size) == VX_OK) {
      size_t m = size.bytes > sizeof(vx_msg_header) ? size.bytes - sizeof(vx_msg_header) : 0;
      if (n + m > sizeof out) m = sizeof out - n; // more than vx-rt ever sends in one: cut
      memcpy(out + n, msg + sizeof(vx_msg_header), m), n += m;
    }
    for (size_t at = 0; at < n;) {
      int64_t w = vx_write(slave_out, (vx_str){out + at, n - at});
      if (w <= 0) return nullptr;
      at += (size_t)w;
    }
  }
}

// rc on a new pseudo-terminal, in a note group of its own, the terminal's
// foreground group, so ^C reaches it and what it runs.
static bool start_shell(void) {
  master = vx_open(VX_STR("/dev/ptmx"), VX_ORDWR);
  vx_dir d;
  vx_arena *a = vx_scratch(nullptr, 0);
  vx_mark mark = vx_arena_mark(a);
  if (master < 0 || (typing = vx_file_join(master)) < 0 || vx_fstat(master, a, &d) != VX_OK || d.name.len > 8)
    return false;
  char path[24];
  path[vx_bfmt((vx_bytes){(uint8_t *)path, sizeof path - 1}, "/dev/pts/%.*s", VX_FMT(d.name))] = 0;
  ctl[vx_bfmt((vx_bytes){(uint8_t *)ctl, sizeof ctl - 1}, "/dev/pts/%.*s.ctl", VX_FMT(d.name))] = 0;
  vx_arena_pop(a, mark);
  vx_ctl(vx_cstr(ctl), "rows=%u cols=%u", g.rows, g.cols);
  slave_in = vx_open(vx_cstr(path), VX_OREAD), slave_out = vx_open(vx_cstr(path), VX_OWRITE);
  vx_handle in[2], out[2], err;
  if (slave_in < 0 || slave_out < 0 || vx_channel_create(0, in) != VX_OK ||
      vx_channel_create(0, out) != VX_OK || vx_handle_dup(out[1], VX_RIGHTS_SAME, &err) != VX_OK)
    return false;
  to_shell = in[0], from_shell = out[0];
  vx_handle h[] = {in[1], out[1], err};
  vx_str names[] = {VX_STR("stdin"), VX_STR("stdout"), VX_STR("stderr")};
  vx_str args[] = {VX_STR("rc"), VX_STR("-i")};
  vx_spawn_req r = {.path = VX_STR("/boot/bin/rc"),
                    .args = {args, 2},
                    .handles = h,
                    .handle_names = names,
                    .nhandles = 3,
                    .flags = VX_PROC_NEWGROUP};
  if (vx_proc_spawn(&r, &shell) != VX_OK) return false;
  vx_ctl(vx_cstr(ctl), "pgrp=%llu", (unsigned long long)shell.pid);
  return vx_thread_spawn(reader, nullptr, 0, 0) && vx_thread_spawn(typed, nullptr, 0, 0) &&
         vx_thread_spawn(output, nullptr, 0, 0) && vx_thread_spawn(watcher, nullptr, 0, 0);
}

const char *vx_main(void) {
  measured = vx_args().len > 1 && vx_str_eq(vx_arg(1), VX_STR("-m"));
  app = vx_app_open("org.vectraos.term");
  win = vx_window_open(app, "Terminal", 660, 400);
  if (!load_font()) return "term: no font";
  g.fg = DEFAULT_FG, g.bg = DEFAULT_BG;
  vx_window_text_input(win, "terminal");
  vx_event ev;
  bool started = false;
  uint32_t scroll = 0;
  uint64_t prev[MAX_ROWS / 64] = {}; // the last frame's dirty rows: the other buffer lacks them
  vx_instant key_at = 0;
  while (vx_wait(app, &ev, VX_INFINITE)) {
    switch (ev.kind) {
    case VX_CONFIGURE:
      fit(ev.configure.width, ev.configure.height);
      if (!started && !(started = start_shell())) return "term: no pseudo-terminal or shell";
      break;
    case VX_WAKE:
      if (done) return nullptr;
      vx_window_redraw(win);
      break;
    case VX_KEY:
      key(&ev, &scroll);
      if (ev.keyboard.down) key_at = ev.time;
      vx_window_redraw(win);
      break;
    case VX_TEXT:
      text(ev.text.text, &scroll);
      key_at = ev.time;
      break;
    case VX_POINTER:
      if (ev.pointer.wheel) {
        scroll = (uint32_t)clamp((int64_t)scroll + (int64_t)ev.pointer.wheel * 3, 0, history_kept());
        vx_lock(&g.lock), g.all = true, vx_unlock(&g.lock);
        vx_window_redraw(win);
      }
      break;
    case VX_CLOSE: return nullptr;
    case VX_FRAME: {
      vx_pixels px = vx_pixels_begin(win, &ev.frame);
      if (!px.data) break;
      vx_font_target t = {.px = (uint32_t *)px.data,
                          .stride = px.stride / 4,
                          .clip_x1 = (int32_t)px.w,
                          .clip_y1 = (int32_t)px.h};
      vx_lock(&g.lock);
      bool all = g.all || px.age != 2 || scroll;
      bool echo = g.output_new;
      g.output_new = false;
      if (all) fill(&px, 0, 0, (int32_t)px.w, (int32_t)px.h, PALETTE[DEFAULT_BG]);
      for (uint32_t r = 0; r < g.rows; r++) {
        bool now = g.dirty[r / 64] >> (r % 64) & 1, before = prev[r / 64] >> (r % 64) & 1;
        if (!all && !now && !before) continue;
        int32_t cursor = (int32_t)clamp(g.cx, 0, g.cols - 1);
        draw_row(&px, &t, r, g.top - scroll + r, !scroll && r == g.cy ? cursor : -1);
      }
      for (uint32_t k = 0; k < MAX_ROWS / 64; k++) prev[k] = all ? ~0ull : g.dirty[k], g.dirty[k] = 0;
      dirty(g.cy); // the cursor's row, drawn again in the next buffer
      g.all = false;
      vx_unlock(&g.lock);
      vx_pixels_present(win, &px);
      if (measured && echo && key_at) {
        vx_eprintf("term: key to frame %lld us\n", (long long)((vx_now() - key_at) / 1000));
        key_at = 0;
      }
    } break;
    default: break;
    }
  }
  return vx_app_error(app);
}
