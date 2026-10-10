// dbg's timeline (05 §9, 20 §7; M7 step 7g1b2): `dbg -t [FILE]`, a window
// over a trace, the live /proc/trace/events or a save (trace -c -o, trace
// -f). Included by dbg.c.
//
// A track per CPU, with what ran on it (a colour a process) and its
// interrupts; then a track per thread, what ran above and its process's
// spans below (9Px requests, and frames: DRAW, LATCH, COMPOSE, 7g1b1), its
// faults and its samples as ticks. Parts of one flow (a request's client
// and server spans, a call and its reply, a frame's DRAW and its LATCH) are
// joined by lines. The wheel zooms about the pointer, a drag pans, the
// arrows pan and scroll, + and - zoom, 0 shows it all; what is under the
// pointer, and a click's choice, are told in the status line.

static constexpr uint32_t TL_PX = 12, TL_LABEL_W = 168, TL_RULER_H = 22, TL_STATUS_H = 20, TL_CPU_H = 16,
                          TL_THREAD_H = 22, TL_MAX_TRACKS = 1024;
static constexpr char TL_FONT[] = "/lib/font/Inter-Regular.ttf";

enum : uint8_t { TL_CPU, TL_THREAD };
enum : uint8_t { TL_RUN, TL_IRQ, TL_SPAN, TL_FAULT, TL_SAMPLE, TL_CALL, TL_REPLY };

typedef struct tl_item {
  uint64_t t0, t1;
  uint64_t flow; // 0: none
  uint32_t tid;  // a run's thread; a span's, fault's or sample's
  uint16_t track;
  uint8_t kind;
  uint16_t type; // a span's message type
} tl_item;

typedef struct tl_track {
  uint8_t kind;
  uint32_t id; // the CPU, or the thread (task << 12 | thread)
  char label[48];
} tl_track;

static struct {
  vx_trace_record *r;
  size_t n;
  uint64_t hz, first, last;
  tl_item *items;
  size_t nitems;
  uint32_t *by_flow; // items with a flow, by flow then time
  size_t nflow;
  tl_track tracks[TL_MAX_TRACKS];
  uint32_t ntracks;
  uint32_t ncpus, nthreads, nspans, flows;
  // the view
  double t0, per_px; // the time at the left edge, and cycles a pixel
  int32_t scroll;    // pixels of tracks scrolled up
  uint32_t w, h;
  float px, py;
  uint32_t buttons;
  float drag_x, drag_y;
  int64_t chosen; // an item clicked, or -1
  vx_font font;
  vx_atlas atlas;
  int32_t ascent;
} tlm = {.chosen = -1};

static uint32_t tl_colour_of(uint32_t task) {
  static const uint32_t hues[] = {0x9dbbe6, 0xa5d1a7, 0xe3cd7f, 0xd8aad8, 0x96d3cb,
                                  0xf0a597, 0xb8b0ea, 0xcdb894, 0x93c8d4, 0xdcaac0}; // pale: spans are dark
  return hues[(task * 2654435761u >> 16) % (sizeof hues / sizeof hues[0])];
}

static uint32_t tl_span_colour(uint16_t type) {
  switch (type) {
  case VX_SPAN_FRAME_DRAW: return 0x1b5e20;
  case VX_SPAN_FRAME_LATCH: return 0x6a1b9a;
  case VX_SPAN_FRAME_COMPOSE: return 0x00695c;
  default: return 0x1f4f9a;
  }
}

static const char *tl_span_name(uint16_t type) {
  switch (type) {
  case VX_SPAN_FRAME_DRAW: return "frame draw";
  case VX_SPAN_FRAME_LATCH: return "frame latch";
  case VX_SPAN_FRAME_COMPOSE: return "frame compose";
  default: return "span";
  }
}

// --- Loading ---

static uint64_t tl_status_hz(void) {
  static char buf[4096];
  vx_fd fd = vx_open(VX_STR("/proc/trace/status"), VX_OREAD);
  int64_t n = fd >= 0 ? vx_read(fd, (vx_bytes){(uint8_t *)buf, sizeof buf - 1}) : -1;
  if (fd >= 0) vx_close(fd);
  uint64_t hz = 0;
  for (int64_t i = 0; i + 3 < n && !hz; i++)
    if ((i == 0 || buf[i - 1] == ' ' || buf[i - 1] == '\n') && !memcmp(buf + i, "hz=", 3))
      for (size_t j = (size_t)i + 3; j < (size_t)n && buf[j] >= '0' && buf[j] <= '9'; j++)
        hz = hz * 10 + (uint64_t)(buf[j] - '0');
  if (!hz) { // the cycle counter's, as /sys/clock/info gives it
    vx_clock_info c = {};
    vx_clock_info_read(&c);
    hz = c.counter_hz;
  }
  return hz;
}

// A thread's track, made the first time it is seen.
static int32_t tl_thread_track(uint32_t tid) {
  for (uint32_t i = 0; i < tlm.ntracks; i++)
    if (tlm.tracks[i].kind == TL_THREAD && tlm.tracks[i].id == tid) return (int32_t)i;
  if (tlm.ntracks == TL_MAX_TRACKS) return -1;
  tl_track *t = &tlm.tracks[tlm.ntracks];
  *t = (tl_track){.kind = TL_THREAD, .id = tid};
  char name[32] = {}, path[40];
  static char status[512];
  size_t plen = vx_bfmt((vx_bytes){(uint8_t *)path, sizeof path}, "/proc/%u/status", tid >> 12);
  vx_fd fd = vx_open((vx_str){path, plen}, VX_OREAD);
  int64_t n = fd >= 0 ? vx_read(fd, (vx_bytes){(uint8_t *)status, sizeof status - 1}) : -1;
  if (fd >= 0) vx_close(fd);
  for (int64_t i = 0; i + 5 < n; i++)
    if ((i == 0 || status[i - 1] == ' ') && !memcmp(status + i, "name=", 5)) {
      size_t k = 0;
      for (int64_t j = i + 5; j < n && status[j] != ' ' && status[j] != '\n' && k + 1 < sizeof name; j++)
        name[k++] = status[j];
      break;
    }
  vx_bfmt((vx_bytes){(uint8_t *)t->label, sizeof t->label}, "%s%s%u.%u", name, *name ? " " : "task ",
          tid >> 12, tid & 0xfff);
  tlm.nthreads++;
  return (int32_t)tlm.ntracks++;
}

static int32_t tl_cpu_track(uint32_t cpu) {
  for (uint32_t i = 0; i < tlm.ntracks; i++)
    if (tlm.tracks[i].kind == TL_CPU && tlm.tracks[i].id == cpu) return (int32_t)i;
  if (tlm.ntracks == TL_MAX_TRACKS) return -1;
  tl_track *t = &tlm.tracks[tlm.ntracks];
  *t = (tl_track){.kind = TL_CPU, .id = cpu};
  vx_bfmt((vx_bytes){(uint8_t *)t->label, sizeof t->label}, "cpu %u", cpu);
  tlm.ncpus++;
  return (int32_t)tlm.ntracks++;
}

static void tl_add(int32_t track, uint8_t kind, uint64_t t0, uint64_t t1, uint32_t tid, uint64_t flow,
                   uint16_t type) {
  if (track < 0) return;
  tlm.items[tlm.nitems++] = (tl_item){
      .t0 = t0, .t1 = t1, .flow = flow, .tid = tid, .track = (uint16_t)track, .kind = kind, .type = type};
}

static bool tl_flow_less(uint32_t x, uint32_t y) {
  const tl_item *a = &tlm.items[x], *b = &tlm.items[y];
  return a->flow < b->flow || (a->flow == b->flow && a->t0 < b->t0);
}

// A bottom-up merge sort of the items with a flow, by flow then time.
static void tl_sort_flows(vx_arena *a) {
  uint32_t *tmp = vx_push(a, tlm.nflow * sizeof *tmp + 1, alignof(uint32_t));
  if (!tmp) return;
  for (size_t width = 1; width < tlm.nflow; width *= 2) {
    for (size_t lo = 0; lo < tlm.nflow; lo += 2 * width) {
      size_t mid = lo + width < tlm.nflow ? lo + width : tlm.nflow;
      size_t hi = lo + 2 * width < tlm.nflow ? lo + 2 * width : tlm.nflow, i = lo, j = mid, k = lo;
      while (i < mid && j < hi)
        tmp[k++] = tl_flow_less(tlm.by_flow[j], tlm.by_flow[i]) ? tlm.by_flow[j++] : tlm.by_flow[i++];
      while (i < mid) tmp[k++] = tlm.by_flow[i++];
      while (j < hi) tmp[k++] = tlm.by_flow[j++];
    }
    memcpy(tlm.by_flow, tmp, tlm.nflow * sizeof *tmp);
  }
}

static bool tl_load(vx_str path, vx_arena *a) {
  vx_fd fd = vx_open(path, VX_OREAD);
  if (fd < 0) return false;
  size_t cap = 1 << 20; // records; the arena's reservation is lazy
  tlm.r = vx_push(a, cap * sizeof *tlm.r, alignof(vx_trace_record));
  size_t have = 0;
  int64_t got = 0;
  while (tlm.r && have < cap * sizeof *tlm.r &&
         (got = vx_read(fd, (vx_bytes){(uint8_t *)tlm.r + have, cap * sizeof *tlm.r - have})) > 0)
    have += (size_t)got;
  vx_close(fd);
  if (!tlm.r || got < 0) return false;
  tlm.n = have / sizeof *tlm.r;
  tlm.hz = tl_status_hz();
  tlm.items = vx_push(a, (tlm.n + 64) * sizeof *tlm.items, alignof(tl_item));
  if (!tlm.items) return false;
  // The CPUs first, in order, so their tracks lead.
  uint32_t most_cpu = 0;
  for (size_t i = 0; i < tlm.n; i++)
    if (tlm.r[i].cpu != 0xffff && tlm.r[i].cpu + 1u > most_cpu) most_cpu = tlm.r[i].cpu + 1u;
  for (uint32_t c = 0; c < most_cpu && c < 256; c++) tl_cpu_track(c);
  static uint32_t running[256];
  static uint64_t since[256], irq_at[256];
  tlm.first = tlm.n ? tlm.r[0].time : 0, tlm.last = tlm.first;
  for (size_t i = 0; i < tlm.n; i++) {
    const vx_trace_record *r = &tlm.r[i];
    if (r->time < tlm.first) tlm.first = r->time;
    uint64_t end = r->kind == VX_TK_SPAN ? r->time + (r->b & 0xffff'ffff'ffff) : r->time;
    if (end > tlm.last) tlm.last = end;
    uint32_t cpu = r->cpu < 256 ? r->cpu : 0;
    switch (r->kind) {
    case VX_TK_SWITCH: {
      uint32_t out = (uint32_t)r->a, in = (uint32_t)r->b;
      if (out && since[cpu]) {
        tl_add((int32_t)cpu, TL_RUN, since[cpu], r->time, out, 0, 0);
        tl_add(tl_thread_track(out), TL_RUN, since[cpu], r->time, out, 0, 0);
      }
      running[cpu] = in, since[cpu] = r->time;
      break;
    }
    case VX_TK_IRQ_IN: irq_at[cpu] = r->time; break;
    case VX_TK_IRQ_OUT:
      if (irq_at[cpu]) tl_add((int32_t)cpu, TL_IRQ, irq_at[cpu], r->time, 0, 0, 0);
      irq_at[cpu] = 0;
      break;
    case VX_TK_FAULT:
      if (r->tid) tl_add(tl_thread_track(r->tid), TL_FAULT, r->time, r->time, r->tid, 0, 0);
      break;
    case VX_TK_SAMPLE:
      if (r->tid) tl_add(tl_thread_track(r->tid), TL_SAMPLE, r->time, r->time, r->tid, 0, 0);
      break;
    case VX_TK_CALL:
    case VX_TK_REPLY:
      if (r->tid)
        tl_add(tl_thread_track(r->tid), r->kind == VX_TK_CALL ? TL_CALL : TL_REPLY, r->time, r->time, r->tid,
               r->b, 0);
      break;
    case VX_TK_SPAN:
      tl_add(tl_thread_track(r->tid), TL_SPAN, r->time, end, r->tid, r->a, (uint16_t)(r->b >> 48));
      tlm.nspans++;
      break;
    default: break;
    }
  }
  for (uint32_t c = 0; c < most_cpu && c < 256; c++) // what still runs, to the end
    if (running[c] && since[c]) {
      tl_add((int32_t)c, TL_RUN, since[c], tlm.last, running[c], 0, 0);
      tl_add(tl_thread_track(running[c]), TL_RUN, since[c], tlm.last, running[c], 0, 0);
    }
  tlm.by_flow = vx_push(a, (tlm.nitems + 1) * sizeof *tlm.by_flow, alignof(uint32_t));
  if (!tlm.by_flow) return false;
  for (size_t i = 0; i < tlm.nitems; i++)
    if (tlm.items[i].flow) tlm.by_flow[tlm.nflow++] = (uint32_t)i;
  tl_sort_flows(a);
  for (size_t i = 0; i < tlm.nflow; i++)
    tlm.flows += (i == 0 || tlm.items[tlm.by_flow[i]].flow != tlm.items[tlm.by_flow[i - 1]].flow) &&
                 i + 1 < tlm.nflow && tlm.items[tlm.by_flow[i + 1]].flow == tlm.items[tlm.by_flow[i]].flow;
  return true;
}

// --- Drawing ---

static int32_t tl_track_y(uint32_t i) { // its top, scrolled
  int32_t y = (int32_t)TL_RULER_H - tlm.scroll;
  for (uint32_t k = 0; k < i; k++) y += tlm.tracks[k].kind == TL_CPU ? TL_CPU_H : TL_THREAD_H;
  return y;
}

static uint32_t tl_track_h(uint32_t i) { return tlm.tracks[i].kind == TL_CPU ? TL_CPU_H : TL_THREAD_H; }

static double tl_x(uint64_t t) { return TL_LABEL_W + ((double)t - tlm.t0) / tlm.per_px; }

static void tl_fill(vx_pixels *px, int32_t x0, int32_t y0, int32_t x1, int32_t y1, int32_t cx0, int32_t cy0,
                    int32_t cy1, uint32_t c) {
  if (x0 < cx0) x0 = cx0;
  if (y0 < cy0) y0 = cy0;
  if (x1 > (int32_t)px->w) x1 = (int32_t)px->w;
  if (y1 > cy1) y1 = cy1;
  for (int32_t y = y0; y < y1; y++) {
    uint32_t *row = (uint32_t *)(px->data + (size_t)y * px->stride);
    for (int32_t x = x0; x < x1; x++) row[x] = c;
  }
}

// A line, clipped to the tracks' area (Bresenham's).
static void tl_line(vx_pixels *px, int32_t x0, int32_t y0, int32_t x1, int32_t y1, int32_t cy0, int32_t cy1,
                    uint32_t c) {
  int32_t dx = x1 > x0 ? x1 - x0 : x0 - x1, dy = y1 > y0 ? y0 - y1 : y1 - y0;
  int32_t sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1, err = dx + dy;
  for (uint32_t steps = 0; steps < 8192; steps++) {
    if (x0 >= (int32_t)TL_LABEL_W && x0 < (int32_t)px->w && y0 >= cy0 && y0 < cy1)
      ((uint32_t *)(px->data + (size_t)y0 * px->stride))[x0] = c;
    if (x0 == x1 && y0 == y1) break;
    int32_t e2 = 2 * err;
    if (e2 >= dy) err += dy, x0 += sx;
    if (e2 <= dx) err += dx, y0 += sy;
  }
}

static void tl_text(vx_pixels *px, int32_t x, int32_t y, int32_t clip_x1, uint32_t colour, const char *s,
                    size_t n) {
  vx_font_target t = {.px = (uint32_t *)px->data,
                      .stride = px->stride / 4,
                      .clip_x0 = x > 0 ? x : 0,
                      .clip_y0 = 0,
                      .clip_x1 = clip_x1,
                      .clip_y1 = (int32_t)px->h};
  vx_text_draw(&t, &tlm.atlas, &tlm.font, TL_PX, x, y + tlm.ascent, colour, s, n);
}

static double tl_ns(double cycles) { return tlm.hz ? cycles * 1e9 / (double)tlm.hz : cycles; }

// A length as text: ns, µs, ms or s (cycles if the frequency is unknown).
static size_t tl_length(char *buf, size_t cap, double cycles) {
  double ns = tl_ns(cycles);
  const char *unit = tlm.hz ? "ns" : "cycles";
  if (tlm.hz && ns >= 1e9)
    ns /= 1e9, unit = "s";
  else if (tlm.hz && ns >= 1e6)
    ns /= 1e6, unit = "ms";
  else if (tlm.hz && ns >= 1e3)
    ns /= 1e3, unit = "µs";
  if (ns < 0.5) return vx_bfmt((vx_bytes){(uint8_t *)buf, cap}, "0");
  const char *form = "%.0f %s";
  if (ns < 10)
    form = "%.2f %s";
  else if (ns < 100)
    form = "%.1f %s";
  return vx_bfmt((vx_bytes){(uint8_t *)buf, cap}, form, ns, unit);
}

static void tl_ruler(vx_pixels *px) {
  tl_fill(px, 0, 0, (int32_t)px->w, TL_RULER_H, 0, 0, (int32_t)px->h, 0xd8d3c8);
  tl_fill(px, 0, TL_RULER_H - 1, (int32_t)px->w, TL_RULER_H, 0, 0, (int32_t)px->h, 0x8a857c);
  // A tick at least each 100 pixels, a round time apart (1, 2 or 5 of a power of ten ns).
  double span = tl_ns(tlm.per_px * 100), step_ns = 1;
  while (step_ns * 10 <= span) step_ns *= 10;
  if (step_ns * 2 >= span)
    step_ns *= 2;
  else if (step_ns * 5 >= span)
    step_ns *= 5;
  else
    step_ns *= 10;
  double step = tlm.hz ? step_ns * (double)tlm.hz / 1e9 : step_ns;
  double first = tlm.t0 - (double)tlm.first;
  uint64_t k0 = first > 0 ? (uint64_t)(first / step) : 0;
  for (uint64_t k = k0; k < k0 + 1000; k++) {
    double t = (double)k * step;
    if (tl_x((uint64_t)(t + (double)tlm.first)) >= px->w) break;
    int32_t x = (int32_t)tl_x((uint64_t)(t + (double)tlm.first));
    if (x < (int32_t)TL_LABEL_W) continue;
    tl_fill(px, x, TL_RULER_H - 6, x + 1, TL_RULER_H, 0, 0, (int32_t)px->h, 0x5c5c5c);
    char buf[32];
    size_t n = tl_length(buf, sizeof buf, t);
    tl_text(px, x + 3, 4, (int32_t)px->w, 0x1c1c1c, buf, n);
  }
  tl_text(px, 6, 4, TL_LABEL_W, 0x1c1c1c, "dbg timeline", 12);
}

static void tl_draw(vx_pixels *px) {
  int32_t top = TL_RULER_H, bottom = (int32_t)px->h - (int32_t)TL_STATUS_H, w = (int32_t)px->w;
  tl_fill(px, 0, 0, w, (int32_t)px->h, 0, 0, (int32_t)px->h, 0xe4e0d8);
  for (uint32_t i = 0; i < tlm.ntracks; i++) { // the tracks' backgrounds and labels
    int32_t y = tl_track_y(i), hgt = (int32_t)tl_track_h(i);
    if (y + hgt < top || y >= bottom) continue;
    tl_fill(px, 0, y, w, y + hgt, 0, top, bottom, i % 2 ? 0xe4e0d8 : 0xece8e0);
    tl_fill(px, 0, y, TL_LABEL_W, y + hgt, 0, top, bottom,
            tlm.tracks[i].kind == TL_CPU ? 0xc9c4b9 : 0xd3cec4);
    tl_fill(px, 0, y + hgt - 1, w, y + hgt, 0, top, bottom, 0xcbc6bb);
    if (y >= top - 2 && y + hgt <= bottom + 2)
      tl_text(px, 6, y + (hgt - (int32_t)TL_PX) / 2 - 1, TL_LABEL_W - 4, 0x1c1c1c, tlm.tracks[i].label,
              vx_cstr(tlm.tracks[i].label).len);
  }
  tl_fill(px, TL_LABEL_W - 1, top, TL_LABEL_W, bottom, 0, top, bottom, 0x8a857c);
  for (size_t i = 0; i < tlm.nitems; i++) { // what happened
    const tl_item *it = &tlm.items[i];
    double x0 = tl_x(it->t0), x1 = tl_x(it->t1);
    if (x1 < TL_LABEL_W - 1 || x0 > w) continue;
    int32_t y = tl_track_y(it->track), hgt = (int32_t)tl_track_h(it->track);
    if (y + hgt < top || y >= bottom) continue;
    int32_t a = (int32_t)x0, b = (int32_t)x1 > a ? (int32_t)x1 : a + 1;
    bool chosen =
        tlm.chosen == (int64_t)i || (it->flow && tlm.chosen >= 0 && it->flow == tlm.items[tlm.chosen].flow);
    switch (it->kind) {
    case TL_RUN:
      if (tlm.tracks[it->track].kind == TL_CPU)
        tl_fill(px, a, y + 2, b, y + hgt - 3, TL_LABEL_W, top, bottom, tl_colour_of(it->tid >> 12));
      else
        tl_fill(px, a, y + 2, b, y + 9, TL_LABEL_W, top, bottom, tl_colour_of(it->tid >> 12));
      break;
    case TL_IRQ: tl_fill(px, a, y, b, y + 4, TL_LABEL_W, top, bottom, 0xb3261e); break;
    case TL_SPAN:
      tl_fill(px, a, y + 11, b, y + hgt - 3, TL_LABEL_W, top, bottom,
              chosen ? 0xd84a3a : tl_span_colour(it->type));
      break;
    case TL_FAULT: tl_fill(px, a, y + 1, a + 2, y + hgt - 2, TL_LABEL_W, top, bottom, 0xc46a00); break;
    case TL_SAMPLE: tl_fill(px, a, y + 10, a + 1, y + 13, TL_LABEL_W, top, bottom, 0x3c3c3c); break;
    default:
      tl_fill(px, a, y + 9, a + 1, y + hgt - 2, TL_LABEL_W, top, bottom, 0x5c5c5c);
      break; // a call, a reply
    }
  }
  uint64_t chosen_flow = tlm.chosen >= 0 ? tlm.items[tlm.chosen].flow : 0;
  for (size_t k = 1; k < tlm.nflow; k++) { // a flow's parts joined, in time
    const tl_item *p = &tlm.items[tlm.by_flow[k - 1]], *q = &tlm.items[tlm.by_flow[k]];
    if (p->flow != q->flow || p->track == q->track) continue;
    double xa = tl_x(p->t0), xb = tl_x(q->t0);
    if ((xa < TL_LABEL_W && xb < TL_LABEL_W) || (xa > w && xb > w)) continue;
    int32_t ya = tl_track_y(p->track) + (int32_t)TL_THREAD_H - 6,
            yb = tl_track_y(q->track) + (int32_t)TL_THREAD_H - 6;
    tl_line(px, (int32_t)xa, ya, (int32_t)xb, yb, top, bottom, p->flow == chosen_flow ? 0xd84a3a : 0x6c6860);
  }
  tl_ruler(px);
  // the status line: what is chosen, or under the pointer, or the trace in all
  tl_fill(px, 0, bottom, w, (int32_t)px->h, 0, 0, (int32_t)px->h, 0xbdb8ae);
  tl_fill(px, 0, bottom, w, bottom + 1, 0, 0, (int32_t)px->h, 0x8a857c);
  char status[160];
  size_t n = 0;
  if (tlm.chosen >= 0) {
    const tl_item *it = &tlm.items[tlm.chosen];
    char len[32];
    tl_length(len, sizeof len, (double)(it->t1 - it->t0));
    const char *what = tl_span_name(it->type);
    n = vx_bfmt((vx_bytes){(uint8_t *)status, sizeof status}, "%s: %s, type %u, flow 0x%llx, %s",
                tlm.tracks[it->track].label, what, it->type, (unsigned long long)it->flow, len);
  } else {
    char len[32];
    tl_length(len, sizeof len, (double)(tlm.last - tlm.first));
    n = vx_bfmt((vx_bytes){(uint8_t *)status, sizeof status},
                "%zu records over %s: %u cpus, %u threads, %u spans, %u flows", tlm.n, len, tlm.ncpus,
                tlm.nthreads, tlm.nspans, tlm.flows);
  }
  tl_text(px, 6, bottom + 3, w, 0x1c1c1c, status, n);
}

// --- Input ---

static void tl_fit(void) {
  uint64_t len = tlm.last > tlm.first ? tlm.last - tlm.first : 1;
  uint32_t width = tlm.w > TL_LABEL_W + 20 ? tlm.w - TL_LABEL_W - 10 : 10;
  tlm.t0 = (double)tlm.first, tlm.per_px = (double)len / width, tlm.scroll = 0;
}

static void tl_zoom(double factor, float at_x) {
  double at = at_x > TL_LABEL_W ? at_x - TL_LABEL_W : 0;
  double t = tlm.t0 + at * tlm.per_px;
  tlm.per_px *= factor;
  if (tlm.per_px < 0.01) tlm.per_px = 0.01;
  tlm.t0 = t - at * tlm.per_px;
}

static int32_t tl_scroll_max(void) {
  int32_t all = tl_track_y(tlm.ntracks) + tlm.scroll - (int32_t)TL_RULER_H;
  int32_t room = (int32_t)tlm.h - (int32_t)TL_RULER_H - (int32_t)TL_STATUS_H;
  return all > room ? all - room : 0;
}

static void tl_scroll_by(int32_t dy) {
  tlm.scroll += dy;
  int32_t most = tl_scroll_max();
  if (tlm.scroll > most) tlm.scroll = most;
  if (tlm.scroll < 0) tlm.scroll = 0;
}

// The span under a point, or -1.
static int64_t tl_pick(float x, float y) {
  int64_t best = -1;
  for (size_t i = 0; i < tlm.nitems; i++) {
    const tl_item *it = &tlm.items[i];
    if (it->kind != TL_SPAN) continue;
    int32_t ty = tl_track_y(it->track);
    if (y < (float)(ty + 9) || y >= (float)(ty + (int32_t)TL_THREAD_H)) continue;
    double x0 = tl_x(it->t0) - 2, x1 = tl_x(it->t1) + 2;
    if (x >= x0 && x <= x1 && (best < 0 || it->t1 - it->t0 < tlm.items[best].t1 - tlm.items[best].t0))
      best = (int64_t)i;
  }
  return best;
}

static float tl_middle(void) { return (float)TL_LABEL_W + (float)(tlm.w - TL_LABEL_W) * 0.5f; }

// Whether the event changed the view.
static bool tl_input(const vx_event *ev) {
  if (ev->kind == VX_POINTER) {
    float x = ev->pointer.x, y = ev->pointer.y;
    bool changed = false;
    if (ev->pointer.wheel) {
      tl_zoom(ev->pointer.wheel > 0 ? 0.8 : 1.25, x);
      changed = true;
    }
    bool down = ev->pointer.buttons & 1, was = tlm.buttons & 1;
    if (down && was && (x != tlm.px || y != tlm.py)) { // a drag: pan
      tlm.t0 -= (double)(x - tlm.px) * tlm.per_px;
      tl_scroll_by((int32_t)(tlm.py - y));
      changed = true;
    }
    if (down && !was) tlm.drag_x = x, tlm.drag_y = y;
    if (!down && was && x - tlm.drag_x < 3 && tlm.drag_x - x < 3 && y - tlm.drag_y < 3 &&
        tlm.drag_y - y < 3) {
      tlm.chosen = tl_pick(x, y); // a click: choose what is under it
      changed = true;
    }
    tlm.px = x, tlm.py = y, tlm.buttons = ev->pointer.buttons;
    return changed;
  }
  if (ev->kind != VX_KEY || !ev->keyboard.down) return false;
  uint32_t usage = ev->keyboard.usage & 0xffff;
  double page = tlm.per_px * (tlm.w > TL_LABEL_W ? tlm.w - TL_LABEL_W : 1);
  switch (usage) {
  case 0x4f: tlm.t0 += page / 4; return true;                  // right
  case 0x50: tlm.t0 -= page / 4; return true;                  // left
  case 0x51: tl_scroll_by(TL_THREAD_H); return true;           // down
  case 0x52: tl_scroll_by(-(int32_t)TL_THREAD_H); return true; // up
  case 0x4e: tl_scroll_by((int32_t)tlm.h / 2); return true;    // page down
  case 0x4b: tl_scroll_by(-(int32_t)tlm.h / 2); return true;   // page up
  default: break;
  }
  switch (ev->keyboard.rune) {
  case '+':
  case '=': tl_zoom(0.5, tl_middle()); return true;
  case '-': tl_zoom(2, tl_middle()); return true;
  case '0': tl_fit(); return true;
  case 27: tlm.chosen = -1; return true;
  default: return false;
  }
}

static bool tl_font(void) {
  vx_fd fd = vx_open(VX_STR(TL_FONT), VX_OREAD);
  if (fd < 0) return false;
  static constexpr size_t MAX = 2u << 20;
  uint8_t *buf = vx_font_alloc(MAX);
  size_t n = 0;
  for (int64_t r; buf && n < MAX && (r = vx_read(fd, (vx_bytes){buf + n, MAX - n})) > 0;) n += (size_t)r;
  vx_close(fd);
  if (!buf || !n || !vx_atlas_init(&tlm.atlas, 256) || !vx_font_init(&tlm.font, buf, n, 3)) return false;
  tlm.ascent = (vx_font_to64(&tlm.font, tlm.font.ascent, TL_PX) + 32) / 64;
  return true;
}

// dbg -t [FILE]: the window, until it is closed.
static const char *timeline(vx_str path) {
  vx_arena *a = vx_arena_new(128 << 20); // a million records and their items
  if (!tl_load(path, a)) {
    vx_eprintf("dbg: cannot read the trace %.*s: %.*s\n", VX_FMT(path), VX_FMT(vx_errstr()));
    return "no trace";
  }
  vx_printf("dbg: timeline: %zu records, %u cpus, %u threads, %u spans, %u flows\n", tlm.n, tlm.ncpus,
            tlm.nthreads, tlm.nspans, tlm.flows);
  if (!tl_font()) {
    vx_eprintf("dbg: cannot load %s\n", TL_FONT);
    return "no font";
  }
  vx_app *app = vx_app_open("org.vectra.dbg");
  vx_window *win = vx_window_open(app, "Timeline", 720, 480);
  tlm.w = 720, tlm.h = 480;
  tl_fit();
  vx_event ev;
  while (vx_wait(app, &ev, VX_INFINITE)) {
    switch (ev.kind) {
    case VX_CLOSE: return nullptr;
    case VX_CONFIGURE:
      if (ev.configure.width != tlm.w) tlm.w = ev.configure.width, tlm.h = ev.configure.height, tl_fit();
      tlm.h = ev.configure.height;
      vx_window_redraw(win);
      break;
    case VX_FRAME: {
      vx_pixels px = vx_pixels_begin(win, &ev.frame);
      if (!px.data) break;
      tlm.w = px.w, tlm.h = px.h;
      tl_draw(&px);
      vx_pixels_present(win, &px);
      break;
    }
    default:
      if (tl_input(&ev)) vx_window_redraw(win);
      break;
    }
  }
  vx_eprintf("dbg: %s\n", vx_app_error(app) ? vx_app_error(app) : "the wait ended");
  return "error";
}
