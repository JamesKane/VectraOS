// displayd: the display coordinator (M7 step 7b3, docs/21 §2 item 4,
// ADR-0026 item 1). It holds a session of the display engine protocol
// (docs/proto/display.md) with one back end, the one it is given as a
// connector (svcd's connect=: simplefb now, virtio-gpu in 7b4), and serves
// its outputs on /srv/outputs, which winsrv shows as /wsys/outputs:
//
//   /NAME/info  the output as an ndb record: its name, mode, refresh, the
//               formats its layer takes (refresh in millihertz), adopted=firmware while it shows the
//               mode the firmware left, the stamp on screen, and on or off
//   /NAME/ctl   commands, one a write: pattern (a test card, every edge and
//               channel of the screen), blank (black), on, off
//
// Policy is displayd's and registers are the back end's: displayd keeps the
// output's state and its vblank Counter, which rises once a vblank, and
// releases a buffer's timeline once a vblank shows a newer stamp than the
// one that used it. Its one client from 7c is winsrv.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-9p/ring_server.c"
#include "../../lib/vx-driver/displayproto.h"

static constexpr uint64_t KEY_SESSION = P9_KEY_USER | 1;

enum : uint64_t { ROOT = 1, OUT, INFO, CTL, NODES };

static vx_handle session;
static vx_display_info engine;

// The one output (version 1 of the protocol has one).
static struct {
  bool added, on;
  vx_display_mode mode;
  vx_handle vblank;      // a Counter: the vblanks seen
  uint64_t stamp, shown; // the newest APPLY sent; the newest on screen
  vx_buffer card;        // the test card, made on first use
  int64_t card_id;       // its id at the back end
  uint64_t card_stamp;   // the stamp that showed it last; released past it
} out = {.on = true};

static vx_handle server_port(void);

static void log_status(const char *what, vx_status st) { vx_printf("displayd: %s: %d\n", what, (int)st); }

static vx_status call(void *req, uint32_t len, const vx_handle *h, uint32_t nh, void *rep, uint32_t cap) {
  vx_call c = {
      .wr_bytes = req, .wr_handles = h, .wr_len = len, .wr_count = nh, .rd_bytes = rep, .rd_cap = cap};
  vx_status st = vx_channel_call(session, &c, vx_now() + 5'000'000'000);
  return st == VX_OK ? (vx_status)(int32_t)((vx_msg_header *)rep)->flags : st;
}

// --- Events ---

static void on_event(const uint8_t *m, uint32_t len) {
  const vx_msg_header *h = (const vx_msg_header *)m;
  if (h->ordinal == VX_DISPLAY_ADDED && len >= sizeof(vx_display_added)) {
    const vx_display_added *a = (const vx_display_added *)m;
    if (a->output != 0) return;
    out.added = true, out.mode = a->current;
    vx_printf("displayd: fb0 %ux%u at %u.%03u Hz%s\n", a->current.width, a->current.height,
              a->current.refresh_mhz / 1000, a->current.refresh_mhz % 1000,
              a->current.flags & VX_DISPLAY_FIRMWARE ? ", adopted from the firmware" : "");
  } else if (h->ordinal == VX_DISPLAY_REMOVED) {
    out.added = false;
  } else if (h->ordinal == VX_DISPLAY_VBLANK && len == sizeof(vx_display_vblank)) {
    const vx_display_vblank *v = (const vx_display_vblank *)m;
    out.shown = v->stamp;
    vx_counter_signal(out.vblank, (uint64_t)vx_counter_read(out.vblank) + 1);
    // The card is the back end's no more once a newer stamp is on screen.
    if (out.card_stamp && v->stamp > out.card_stamp && out.card.timeline) {
      vx_buffer_signal(&out.card, out.card_stamp);
      out.card_stamp = 0;
    }
  }
}

static void drain(void) {
  for (;;) {
    uint8_t m[1024];
    vx_handle h[VX_CHANNEL_MAX_HANDLES];
    vx_msg_size size;
    vx_status st = vx_channel_read(session, m, sizeof m, h, VX_CHANNEL_MAX_HANDLES, &size);
    if (st == VX_ERR_PEER_CLOSED) {
      vx_print(VX_STR("displayd: the back end has gone\n"));
      vx_exits("the back end has gone");
    }
    if (st != VX_OK) return;
    for (uint32_t i = 0; i < size.handles; i++) vx_handle_close(h[i]);
    if (size.bytes >= sizeof(vx_msg_header)) on_event(m, size.bytes);
  }
}

static void event(void *ctx, const vx_packet *pk) {
  (void)ctx;
  if (pk->key != KEY_SESSION) return;
  drain();
  vx_port_bind(server_port(), session, VX_TRIGGER_READABLE, KEY_SESSION, 0);
}

// --- Configurations ---

// One layer the screen's size: the card, or a solid colour.
static vx_status apply(bool card, uint32_t color) {
  vx_display_rect all = {0, 0, out.mode.width, out.mode.height};
  vx_display_apply a = {.h = {.ordinal = VX_DISPLAY_APPLY},
                        .stamp = ++out.stamp,
                        .cfg = {.output = 0,
                                .nlayers = 1,
                                .mode = out.mode,
                                .layer = {{.kind = card ? VX_DISPLAY_LAYER_IMAGE : VX_DISPLAY_LAYER_COLOR,
                                           .color = color,
                                           .image = card ? (uint64_t)out.card_id : 0,
                                           .src = all,
                                           .dst = all,
                                           .alpha = 255}}}};
  vx_display_check c = {.h = {.ordinal = VX_DISPLAY_CHECK}, .cfg = a.cfg};
  vx_display_msg r = {};
  vx_status st = call(&c, sizeof c, nullptr, 0, &r, sizeof r);
  if (st != VX_OK) return st;
  if (card) out.card_stamp = a.stamp;
  return vx_channel_write(session, &a, sizeof a, nullptr, 0);
}

static uint32_t grey(uint32_t v) { return v << 16 | v << 8 | v; }

// The test card: a grey ramp of 16 steps across the bottom quarter, the
// eight colour bars above it, a white border a pixel wide on every edge,
// and a crosshair through the centre: every channel, and every edge and
// the middle of the mode, which a scaled, offset or clipped screen breaks.
static void draw_card(uint8_t *px, const vx_buffer *b) {
  static const uint32_t BARS[8] = {0xffffff, 0xffff00, 0x00ffff, 0x00ff00,
                                   0xff00ff, 0xff0000, 0x0000ff, 0x000000};
  uint32_t w = b->desc.width, h = b->desc.height, stride = b->desc.plane[0].stride;
  for (uint32_t y = 0; y < h; y++) {
    uint32_t *row = (uint32_t *)(px + (size_t)y * stride);
    for (uint32_t x = 0; x < w; x++) {
      uint32_t c = y < h * 3 / 4 ? BARS[(uint64_t)x * 8 / w] : grey((uint32_t)((uint64_t)x * 16 / w * 17));
      if (x == 0 || y == 0 || x == w - 1 || y == h - 1 || x == w / 2 || y == h / 2) c = 0xffffff;
      if ((x == w / 2 || y == h / 2) && y >= h * 3 / 4) c = 0x000000; // the crosshair, black on the ramp
      row[x] = c;
    }
  }
}

static vx_status show_card(void) {
  if (!out.card.memory) {
    vx_status st = vx_buffer_alloc(&out.card, out.mode.width, out.mode.height, VX_FORMAT_XRGB8888);
    if (st != VX_OK) return st;
    uint8_t *px = nullptr;
    if ((st = vx_buffer_map(&out.card, true, &px)) != VX_OK) return st;
    draw_card(px, &out.card);
    vx_buffer_unmap(&out.card, px);
    vx_display_import m = {.h = {.ordinal = VX_DISPLAY_IMPORT}};
    vx_handle h[2];
    if ((st = vx_buffer_put(&out.card, false, &m.desc, h)) != VX_OK) return st;
    vx_display_msg r = {};
    if ((st = call(&m, sizeof m, h, 2, &r, sizeof r)) != VX_OK) return st;
    out.card_id = r.arg[0];
  }
  return apply(true, 0);
}

static vx_status power(bool on) {
  vx_display_power m = {.h = {.ordinal = VX_DISPLAY_POWER}, .output = 0, .on = on};
  vx_display_msg r = {};
  vx_status st = call(&m, sizeof m, nullptr, 0, &r, sizeof r);
  if (st == VX_OK) out.on = on;
  return st;
}

// --- The tree ---

static const vx_str NAMES[NODES] = {{}, VX_STR("/"), VX_STR("fb0"), VX_STR("info"), VX_STR("ctl")};
static const uint64_t PARENT[NODES] = {0, ROOT, ROOT, OUT, OUT};

static bool is_dir(uint64_t n) { return n == ROOT || n == OUT; }

static vx_status fs_attach(void *ctx, vx_str aname, uint64_t *root) {
  (void)ctx;
  if (aname.len) return VX_ERR_NOT_FOUND;
  *root = ROOT;
  return VX_OK;
}

static vx_status fs_walk(void *ctx, uint64_t dir, vx_str name, uint64_t *child) {
  (void)ctx;
  for (uint64_t n = OUT; n < NODES; n++)
    if (PARENT[n] == dir && (n != OUT || out.added) && vx_str_eq(NAMES[n], name)) {
      *child = n;
      return VX_OK;
    }
  return VX_ERR_NOT_FOUND;
}

static vx_status fs_parent(void *ctx, uint64_t n, uint64_t *parent) {
  (void)ctx;
  *parent = n < NODES && PARENT[n] ? PARENT[n] : ROOT;
  return VX_OK;
}

static uint32_t mode_of(uint64_t n) {
  if (is_dir(n)) return P9_DMDIR | 0555;
  return n == CTL ? 0220 : 0444;
}

static vx_status fs_stat(void *ctx, uint64_t n, p9_stat *st) {
  (void)ctx;
  if (n == 0 || n >= NODES) return VX_ERR_NOT_FOUND;
  *st = (p9_stat){.qid = {is_dir(n) ? P9_QTDIR : P9_QTFILE, 0, n},
                  .mode = mode_of(n),
                  .name = NAMES[n],
                  .uid = VX_STR("sys"),
                  .gid = VX_STR("sys"),
                  .muid = VX_STR("sys")};
  return VX_OK;
}

static vx_status fs_open(void *ctx, uint64_t n, uint8_t mode) {
  (void)ctx;
  if (n == CTL) return (mode & 3) == P9_OWRITE ? VX_OK : VX_ERR_ACCESS;
  return (mode & 3) == P9_OREAD ? VX_OK : VX_ERR_ACCESS;
}

static vx_status fs_read(void *ctx, uint64_t n, uint64_t offset, uint8_t *buf, uint32_t *count) {
  (void)ctx;
  if (n != INFO) return VX_ERR_INVALID;
  drain(); // the stamp on screen, as of now
  char text[512];
  vx_ndb_writer w = {.buf = text, .cap = sizeof text};
  vx_ndb_put(&w, "output", VX_STR("fb0"));
  vx_ndb_put_u64(&w, "width", out.mode.width);
  vx_ndb_put_u64(&w, "height", out.mode.height);
  vx_ndb_put_u64(&w, "refresh_mhz", out.mode.refresh_mhz);
  vx_ndb_put(&w, "format", VX_STR("XRGB8888"));
  if (out.mode.flags & VX_DISPLAY_FIRMWARE) vx_ndb_put(&w, "adopted", VX_STR("firmware"));
  vx_ndb_put(&w, "power", out.on ? VX_STR("on") : VX_STR("off"));
  vx_ndb_put_u64(&w, "stamp", out.shown);
  vx_ndb_end(&w);
  size_t have = w.failed ? 0 : w.len;
  uint64_t left = offset < have ? have - offset : 0;
  if (*count > left) *count = (uint32_t)left;
  memcpy(buf, text + offset * (*count != 0), *count);
  return VX_OK;
}

static vx_status fs_write(void *ctx, uint64_t n, uint64_t offset, const uint8_t *buf, uint32_t *count) {
  (void)ctx, (void)offset;
  if (n != CTL) return VX_ERR_ACCESS;
  vx_str cmd = {(const char *)buf, *count};
  while (cmd.len && (cmd.ptr[cmd.len - 1] == '\n' || cmd.ptr[cmd.len - 1] == ' ')) cmd.len--;
  vx_status st;
  if (vx_str_eq(cmd, VX_STR("pattern")))
    st = show_card();
  else if (vx_str_eq(cmd, VX_STR("blank")))
    st = apply(false, 0);
  else if (vx_str_eq(cmd, VX_STR("on")) || vx_str_eq(cmd, VX_STR("off")))
    st = power(cmd.len == 2);
  else
    st = VX_ERR_INVALID;
  if (st != VX_OK) log_status("ctl", st), *count = 0; // nothing taken
  return st;
}

static vx_status fs_readdir(void *ctx, uint64_t dir, uint32_t index, uint64_t *child) {
  (void)ctx;
  for (uint64_t n = OUT, seen = 0; n < NODES; n++)
    if (PARENT[n] == dir && (n != OUT || out.added) && seen++ == index) {
      *child = n;
      return VX_OK;
    }
  return VX_ERR_NOT_FOUND;
}

static p9_ring_server server = {
    .fs = {.attach = fs_attach,
           .walk = fs_walk,
           .parent = fs_parent,
           .stat = fs_stat,
           .open = fs_open,
           .read = fs_read,
           .write = fs_write,
           .readdir = fs_readdir},
    .name = VX_STR("displayd"),
    .supported = P9_EXT_XATTR,
    .event = event,
};

static vx_handle server_port(void) { return server.port; }

// The back end: the first connector it was given.
static vx_handle back_end(void) {
  for (uint32_t i = 0; i < vx_spawn.handle_count; i++) {
    vx_str n = vx_spawn.handle_names[i];
    vx_handle h = vx_spawn.handles[i];
    if (n.len > 4 && memcmp(n.ptr, "srv:", 4) == 0 && h) {
      vx_spawn.handles[i] = VX_HANDLE_NONE;
      return h;
    }
  }
  return VX_HANDLE_NONE;
}

const char *vx_main(void) {
  vx_handle srv = back_end();
  server.listen = vx_spawn_take("listen");
  if (!srv || !server.listen) {
    vx_print(VX_STR("displayd: no back end, or no listen channel\n"));
    return "no back end";
  }
  vx_msg_header req = {.ordinal = VX_DISPLAY_CONNECT}, rep = {};
  vx_call c = {.wr_bytes = &req,
               .wr_len = sizeof req,
               .rd_bytes = &rep,
               .rd_cap = sizeof rep,
               .rd_handles = &session,
               .rd_count_cap = 1};
  vx_status st = vx_channel_call(srv, &c, vx_now() + 5'000'000'000);
  if (st == VX_OK) st = (vx_status)(int32_t)rep.flags;
  if (st != VX_OK || !session) {
    log_status("cannot connect to the back end", st);
    return "no session";
  }
  vx_msg_header ask = {.ordinal = VX_DISPLAY_INFO};
  if ((st = call(&ask, sizeof ask, nullptr, 0, &engine, sizeof engine)) != VX_OK ||
      engine.version != VX_DISPLAY_VERSION) {
    log_status("the back end's INFO", st);
    return "no INFO";
  }
  if (vx_counter_create(0, &out.vblank) != VX_OK || vx_port_create(0, &server.port) != VX_OK)
    return "no memory";
  drain(); // ADDED, which came before INFO's reply
  vx_port_bind(server.port, session, VX_TRIGGER_READABLE, KEY_SESSION, 0);
  vx_print(VX_STR("displayd: serving /srv/outputs\n"));
  return p9_ring_serve(&server) == VX_OK ? nullptr : "cannot serve";
}
