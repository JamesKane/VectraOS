// winsrv: the window server (M7 step 7d1, docs/21 §2, 03 §4-5). 7d1a is its
// footing: it holds displayd's output (a session of the display engine
// protocol, docs/proto/display.md, which displayd gives its one client) and
// composites the screen on the CPU into two buffers of its own, flipping one
// in by APPLY while the other is drawn, damage only. The output's frame
// clock is displayd's VBLANK: each one says which stamp is on screen, and
// the clock's Counter rises with it, so what draws to it waits on one thing.
// Windows, /wsys's tree and the frame protocol are 7d1b's.
//
// It serves /srv/wsys, which a namespace mounts at /wsys:
//
//   /info      the protocol's version and the output: an ndb record
//   /outputs/  where displayd's tree is mounted (/wsys/outputs)

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-9p/ring_server.c"
#include "../../lib/vx-driver/displayproto.h"

static constexpr uint64_t KEY_DISPLAY = P9_KEY_USER | 1;
static constexpr uint32_t WSYS_VERSION = 1;

static vx_handle disp; // the session with displayd
static p9_ring_server server;

// The screen: two buffers, each the output's size; the one a stamp put on
// screen is busy until a vblank shows a newer one (the release rule: 21 §2
// item 3, displayd's).
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
  uint64_t frames;
  vx_display_rect dirty; // damage waiting for the next composite
  bool reported;
} out;

static vx_status call(void *req, uint32_t len, const vx_handle *h, uint32_t nh, void *rep, uint32_t cap) {
  vx_call c = {
      .wr_bytes = req, .wr_handles = h, .wr_len = len, .wr_count = nh, .rd_bytes = rep, .rd_cap = cap};
  vx_status st = vx_channel_call(disp, &c, vx_now() + 5'000'000'000);
  return st == VX_OK ? (vx_status)(int32_t)((vx_msg_header *)rep)->flags : st;
}

// --- Damage ---

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

static void damage(vx_display_rect r) {
  out.dirty = unite(out.dirty, r);
  for (int i = 0; i < 2; i++) out.b[i].damage = unite(out.b[i].damage, r);
}

// --- Composition ---

// The desk: a vertical gradient, deep blue to slate, under every window.
static uint32_t desk(uint32_t y) {
  uint32_t t = out.mode.height > 1 ? y * 255 / (out.mode.height - 1) : 0;
  uint32_t r = 0x1c + (0x46 - 0x1c) * t / 255, g = 0x2a + (0x5a - 0x2a) * t / 255,
           b = 0x4a + (0x6e - 0x4a) * t / 255;
  return r << 16 | g << 8 | b;
}

static void composite(screen_buffer *s, vx_display_rect r) {
  uint32_t stride = s->buf.desc.plane[0].stride;
  for (uint32_t y = 0; y < r.height; y++) {
    uint32_t *row = (uint32_t *)(s->px + (size_t)(r.y + y) * stride) + r.x;
    uint32_t c = desk((uint32_t)r.y + y);
    for (uint32_t x = 0; x < r.width; x++) row[x] = c;
  }
}

// At a vblank, with damage waiting and a buffer free: draw it and flip it in.
static void frame(void) {
  if (empty(out.dirty)) return;
  uint32_t back = out.front ^ 1;
  screen_buffer *s = &out.b[back];
  if (s->stamp && s->stamp >= out.shown) return; // no newer stamp on screen yet: still the back end's
  vx_display_rect screen = {0, 0, out.mode.width, out.mode.height};
  composite(s, s->damage);
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
  if (vx_channel_write(disp, &a, sizeof a, nullptr, 0) != VX_OK) return;
  s->stamp = a.stamp, s->damage = (vx_display_rect){}, out.front = back, out.dirty = (vx_display_rect){};
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
    frame();
  }
  vx_port_bind(server.port, disp, VX_TRIGGER_READABLE, KEY_DISPLAY, 0);
}

static void event(void *ctx, const vx_packet *pk) {
  (void)ctx;
  if (pk->key == KEY_DISPLAY) on_display();
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
  // The two screen buffers, imported; the whole screen damaged, so the first
  // vblank draws it.
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
  damage((vx_display_rect){0, 0, out.mode.width, out.mode.height});
  return vx_counter_create(0, &out.clock);
}

// --- The tree ---

enum : uint64_t { ROOT = 1, INFO, OUTPUTS, NODES };
static const vx_str NAMES[NODES] = {{}, VX_STR("/"), VX_STR("info"), VX_STR("outputs")};

static vx_status fs_attach(void *ctx, vx_str aname, uint64_t *root) {
  (void)ctx;
  if (aname.len) return VX_ERR_NOT_FOUND;
  *root = ROOT;
  return VX_OK;
}

static vx_status fs_walk(void *ctx, uint64_t dir, vx_str name, uint64_t *child) {
  (void)ctx;
  for (uint64_t n = INFO; n < NODES && dir == ROOT; n++)
    if (vx_str_eq(NAMES[n], name)) {
      *child = n;
      return VX_OK;
    }
  return VX_ERR_NOT_FOUND;
}

static vx_status fs_parent(void *ctx, uint64_t n, uint64_t *parent) {
  (void)ctx, (void)n;
  *parent = ROOT;
  return VX_OK;
}

static vx_status fs_stat(void *ctx, uint64_t n, p9_stat *st) {
  (void)ctx;
  if (n == 0 || n >= NODES) return VX_ERR_NOT_FOUND;
  bool dir = n == ROOT || n == OUTPUTS;
  *st = (p9_stat){.qid = {dir ? P9_QTDIR : P9_QTFILE, 0, n},
                  .mode = dir ? P9_DMDIR | 0555 : 0444,
                  .name = NAMES[n],
                  .uid = VX_STR("sys"),
                  .gid = VX_STR("sys"),
                  .muid = VX_STR("sys")};
  return VX_OK;
}

static vx_status fs_open(void *ctx, uint64_t n, uint8_t mode) {
  (void)ctx, (void)n;
  return (mode & 3) == P9_OREAD ? VX_OK : VX_ERR_ACCESS;
}

static vx_status fs_read(void *ctx, uint64_t n, uint64_t offset, uint8_t *buf, uint32_t *count) {
  (void)ctx;
  if (n != INFO) return VX_ERR_INVALID;
  char text[256];
  vx_ndb_writer w = {.buf = text, .cap = sizeof text};
  vx_ndb_put_u64(&w, "version", WSYS_VERSION);
  vx_ndb_put(&w, "output", VX_STR("fb0"));
  vx_ndb_put_u64(&w, "width", out.mode.width);
  vx_ndb_put_u64(&w, "height", out.mode.height);
  vx_ndb_put_u64(&w, "frames", out.frames);
  vx_ndb_end(&w);
  size_t have = w.failed ? 0 : w.len;
  uint64_t left = offset < have ? have - offset : 0;
  if (*count > left) *count = (uint32_t)left;
  memcpy(buf, text + offset * (*count != 0), *count);
  return VX_OK;
}

static vx_status fs_readdir(void *ctx, uint64_t dir, uint32_t index, uint64_t *child) {
  (void)ctx;
  if (dir != ROOT || index >= NODES - INFO) return VX_ERR_NOT_FOUND;
  *child = INFO + index;
  return VX_OK;
}

const char *vx_main(void) {
  server.fs = (p9_fs){.attach = fs_attach,
                      .walk = fs_walk,
                      .parent = fs_parent,
                      .stat = fs_stat,
                      .open = fs_open,
                      .read = fs_read,
                      .readdir = fs_readdir};
  server.name = VX_STR("winsrv");
  server.supported = P9_EXT_XATTR;
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
  frame(); // the first, at once: the desk
  vx_port_bind(server.port, disp, VX_TRIGGER_READABLE, KEY_DISPLAY, 0);
  vx_print(VX_STR("winsrv: serving /srv/wsys\n"));
  return p9_ring_serve(&server) == VX_OK ? nullptr : "cannot serve";
}
