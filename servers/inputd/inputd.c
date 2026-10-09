// inputd: the input devices, gathered (M7 step 7c1; docs/proto/input.md,
// 21 §2 item 6). It holds a session of the input class protocol with each
// input driver it is given a connector to (connect=input0 ... input3,
// devmgr's posts), and serves them as text on /srv/input, which a namespace
// unions into /dev:
//
//   /input/N/info    the device as an ndb record: its name, kind
//                    (keyboard or pointer), a pointer's axes and range
//   /input/N/events  its records, a line each
//   /input/keyboard  every keyboard's records, one stream
//   /input/pointer   every pointer's
//
// N is the post's number. An open of an events file starts at the oldest
// record inputd holds (it keeps the last 1024), and a read returns whole
// lines, waiting for the next if it has read them all:
//
//   key dev=0 t=4120391877 usage=7:4 down rune=a mods=shift held=7:e1,7:4
//   pointer dev=1 t=4130022113 x=16384 y=8192 dx=0 dy=0 wheel=0 hwheel=0 buttons=1
//
// rune is the key's unmodified rune (03 §5): what it types with no
// modifier, in the US layout until 7d2's keymaps. Until winsrv takes the
// keyboard (7d), inputd also types the keyboards' keys into the console,
// through its kbdin (its namespace is the console alone), with the modifiers applied: a machine with no
// serial line can type into rc.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-9p/ring_server.c"
#include "../../lib/vx-ns/nsapi.c"
#include "../../lib/vx-input/keymap.h"

static constexpr uint32_t MAX_DEVICES = 8, LOG = 1024, MAX_OPENS = 64;
static constexpr uint64_t KEY_CONNECT = P9_KEY_USER | 0x100, KEY_SESSION = P9_KEY_USER | 0x200;

typedef struct device {
  vx_handle connector, session;
  bool known; // its DEVICE has come
  uint32_t number;
  vx_input_device info;
} device;
static device devices[MAX_DEVICES];
static uint32_t ndevices;

// The log: the last LOG records of every device, by sequence number.
typedef struct entry {
  uint32_t dev;
  uint8_t kind;
  union {
    vx_input_key key;
    vx_input_pointer pointer;
  };
} entry;
static entry log_[LOG];
static uint64_t next_seq; // the next record's; the oldest held is next_seq - LOG, at least 0

static vx_fd kbdin = -1; // the console's, to type into
static p9_ring_server server;

// --- The tree ---

enum : uint64_t {
  ROOT = 1,
  INPUT = 2,
  KEYBOARD = 3,
  POINTER = 4,
  DIR = 16,
  INFO = 32,
  EVENTS = 48,
  OPENED = 1024
};

static device *device_of(uint64_t n) {
  for (uint32_t i = 0; i < ndevices; i++)
    if (devices[i].known && devices[i].number == n) return &devices[i];
  return nullptr;
}

// An open events file: which it is, and the next record it reads.
typedef struct open_file {
  bool used;
  uint64_t file, seq;
} open_file;
static open_file opens[MAX_OPENS];

static vx_status fs_attach(void *ctx, vx_str aname, uint64_t *root) {
  (void)ctx;
  if (aname.len) return VX_ERR_NOT_FOUND;
  *root = ROOT;
  return VX_OK;
}

static uint64_t number_of(vx_str name) {
  uint64_t n = 0;
  if (!name.len || name.len > 2) return UINT64_MAX;
  for (size_t i = 0; i < name.len; i++) {
    if (name.ptr[i] < '0' || name.ptr[i] > '9') return UINT64_MAX;
    n = n * 10 + (uint64_t)(name.ptr[i] - '0');
  }
  return n;
}

static vx_status fs_walk(void *ctx, uint64_t dir, vx_str name, uint64_t *child) {
  (void)ctx;
  if (dir == ROOT && vx_str_eq(name, VX_STR("input")))
    *child = INPUT;
  else if (dir == INPUT && vx_str_eq(name, VX_STR("keyboard")))
    *child = KEYBOARD;
  else if (dir == INPUT && vx_str_eq(name, VX_STR("pointer")))
    *child = POINTER;
  else if (dir == INPUT && number_of(name) < 16 && device_of(number_of(name)))
    *child = DIR + number_of(name);
  else if (dir >= DIR && dir < DIR + 16 && vx_str_eq(name, VX_STR("info")))
    *child = INFO + dir - DIR;
  else if (dir >= DIR && dir < DIR + 16 && vx_str_eq(name, VX_STR("events")))
    *child = EVENTS + dir - DIR;
  else
    return VX_ERR_NOT_FOUND;
  return VX_OK;
}

static vx_status fs_parent(void *ctx, uint64_t n, uint64_t *parent) {
  (void)ctx;
  if (n == INPUT || n == ROOT)
    *parent = ROOT;
  else if (n >= INFO && n < EVENTS + 16)
    *parent = DIR + (n - INFO) % 16;
  else
    *parent = INPUT;
  return VX_OK;
}

static bool is_dir(uint64_t n) { return n == ROOT || n == INPUT || (n >= DIR && n < DIR + 16); }

// A node's name; buf holds a device directory's.
static vx_str name_of(uint64_t n, char buf[4]) {
  if (n == ROOT) return VX_STR("/");
  if (n == INPUT) return VX_STR("input");
  if (n == KEYBOARD) return VX_STR("keyboard");
  if (n == POINTER) return VX_STR("pointer");
  if (n >= INFO && n < INFO + 16) return VX_STR("info");
  if (n >= EVENTS && n < EVENTS + 16) return VX_STR("events");
  if (n < DIR || n >= DIR + 16) return (vx_str){};
  uint64_t k = n - DIR;
  size_t len = 0;
  if (k >= 10) buf[len++] = (char)('0' + k / 10);
  buf[len++] = (char)('0' + k % 10);
  return (vx_str){buf, len};
}

static vx_status fs_stat(void *ctx, uint64_t n, p9_stat *st) {
  (void)ctx;
  if (n >= OPENED && n < OPENED + MAX_OPENS) n = opens[n - OPENED].file;
  static char buf[4];
  vx_str s = name_of(n, buf);
  if (!s.len) return VX_ERR_NOT_FOUND;
  *st = (p9_stat){.qid = {is_dir(n) ? P9_QTDIR : P9_QTFILE, 0, n},
                  .mode = is_dir(n) ? P9_DMDIR | 0555 : 0444,
                  .name = s,
                  .uid = VX_STR("sys"),
                  .gid = VX_STR("sys"),
                  .muid = VX_STR("sys")};
  return VX_OK;
}

static vx_status fs_open(void *ctx, uint64_t n, uint8_t mode) {
  (void)ctx, (void)n;
  return (mode & 3) == P9_OREAD ? VX_OK : VX_ERR_ACCESS;
}

static bool is_stream(uint64_t n) {
  return n == KEYBOARD || n == POINTER || (n >= EVENTS && n < EVENTS + 16);
}

// An events file opened: a node of its own, at the oldest record held.
static vx_status fs_clone(void *ctx, uint64_t n, uint8_t mode, uint64_t *opened) {
  (void)ctx, (void)mode;
  if (!is_stream(n)) return VX_ERR_NOT_FOUND;
  for (uint32_t i = 0; i < MAX_OPENS; i++)
    if (!opens[i].used) {
      opens[i] = (open_file){.used = true, .file = n, .seq = next_seq > LOG ? next_seq - LOG : 0};
      *opened = OPENED + i;
      return VX_OK;
    }
  return VX_ERR_NO_MEMORY;
}

static void fs_clunk(void *ctx, uint64_t n, bool opened) {
  (void)ctx, (void)opened;
  if (n >= OPENED && n < OPENED + MAX_OPENS) opens[n - OPENED] = (open_file){};
}

static void put_usage(vx_ndb_writer *w, const char *key, const uint32_t *u, uint32_t n) {
  char text[VX_INPUT_HELD * 12];
  size_t len = 0;
  for (uint32_t i = 0; i < n; i++) {
    static const char HEX[] = "0123456789abcdef";
    if (i) text[len++] = ',';
    uint32_t page = u[i] >> 16, id = u[i] & 0xffff;
    if (page >= 16) text[len++] = HEX[page >> 4 & 15];
    text[len++] = HEX[page & 15];
    text[len++] = ':';
    for (int s = 12; s >= 0; s -= 4)
      if (id >> s || !s) text[len++] = HEX[id >> s & 15];
  }
  if (n) vx_ndb_put(w, key, (vx_str){text, len});
}

static const char *const ACTIONS[] = {"up", "down", "repeat"};

// One record as a line.
static void format(vx_ndb_writer *w, const entry *e) {
  vx_ndb_flag(w, e->kind == VX_INPUT_KEYBOARD ? "key" : "pointer");
  vx_ndb_put_u64(w, "dev", devices[e->dev].number);
  if (e->kind == VX_INPUT_KEYBOARD) {
    const vx_input_key *k = &e->key;
    vx_ndb_put_u64(w, "t", k->time);
    put_usage(w, "usage", &k->usage, 1);
    vx_ndb_flag(w, ACTIONS[k->action <= VX_KEY_REPEAT ? k->action : 0]);
    uint32_t r = vx_keymap_rune(k->usage, 0);
    char rune[8];
    if (r > 0x20 && r < 0x7f) rune[0] = (char)r, vx_ndb_put(w, "rune", (vx_str){rune, 1});
    static const char *const MODS[] = {"shift", "ctrl", "alt", "meta", "altgr", "caps"};
    char mods[48];
    size_t len = 0;
    for (uint32_t i = 0; i < 6; i++) {
      if (!(k->mods >> i & 1)) continue;
      if (len) mods[len++] = ',';
      vx_str m = vx_cstr(MODS[i]);
      memcpy(mods + len, m.ptr, m.len), len += m.len;
    }
    if (len) vx_ndb_put(w, "mods", (vx_str){mods, len});
    put_usage(w, "held", k->held, k->nheld < VX_INPUT_HELD ? k->nheld : VX_INPUT_HELD);
  } else {
    const vx_input_pointer *p = &e->pointer;
    vx_ndb_put_u64(w, "t", p->time);
    vx_ndb_put_i64(w, "x", p->x);
    vx_ndb_put_i64(w, "y", p->y);
    vx_ndb_put_i64(w, "dx", p->dx);
    vx_ndb_put_i64(w, "dy", p->dy);
    vx_ndb_put_i64(w, "wheel", p->wheel);
    vx_ndb_put_i64(w, "hwheel", p->hwheel);
    vx_ndb_put_u64(w, "buttons", p->buttons);
  }
  vx_ndb_end(w);
}

static bool wanted(uint64_t file, const entry *e) {
  if (file == KEYBOARD) return e->kind == VX_INPUT_KEYBOARD;
  if (file == POINTER) return e->kind == VX_INPUT_POINTER;
  return devices[e->dev].number == file - EVENTS;
}

static vx_status read_stream(open_file *o, uint8_t *buf, uint32_t *count) {
  uint64_t oldest = next_seq > LOG ? next_seq - LOG : 0;
  if (o->seq < oldest) o->seq = oldest; // fell behind: what was lost is lost
  uint32_t n = 0;
  for (; o->seq < next_seq; o->seq++) {
    const entry *e = &log_[o->seq % LOG];
    if (!wanted(o->file, e)) continue;
    char line[512];
    vx_ndb_writer w = {.buf = line, .cap = sizeof line};
    format(&w, e);
    if (w.failed || n + w.len > *count) break;
    memcpy(buf + n, line, w.len), n += (uint32_t)w.len;
  }
  if (!n) return VX_ERR_SHOULD_WAIT; // nothing new: held until there is
  *count = n;
  return VX_OK;
}

static vx_status fs_read(void *ctx, uint64_t n, uint64_t offset, uint8_t *buf, uint32_t *count) {
  (void)ctx;
  if (n >= OPENED && n < OPENED + MAX_OPENS) return read_stream(&opens[n - OPENED], buf, count);
  device *d = n >= INFO && n < INFO + 16 ? device_of(n - INFO) : nullptr;
  if (!d) return VX_ERR_INVALID;
  char text[256];
  vx_ndb_writer w = {.buf = text, .cap = sizeof text};
  vx_ndb_put(&w, "name", vx_cstr(d->info.name));
  vx_ndb_put(&w, "kind", d->info.kind == VX_INPUT_KEYBOARD ? VX_STR("keyboard") : VX_STR("pointer"));
  if (d->info.kind == VX_INPUT_POINTER) {
    if (d->info.axes & VX_INPUT_ABSOLUTE) vx_ndb_flag(&w, "absolute");
    if (d->info.axes & VX_INPUT_RELATIVE) vx_ndb_flag(&w, "relative");
    if (d->info.axes & VX_INPUT_WHEEL) vx_ndb_flag(&w, "wheel");
    if (d->info.axes & VX_INPUT_ABSOLUTE) {
      vx_ndb_put_u64(&w, "x_max", d->info.x_max);
      vx_ndb_put_u64(&w, "y_max", d->info.y_max);
    }
  }
  vx_ndb_end(&w);
  size_t have = w.failed ? 0 : w.len;
  uint64_t left = offset < have ? have - offset : 0;
  if (*count > left) *count = (uint32_t)left;
  memcpy(buf, text + offset * (*count != 0), *count);
  return VX_OK;
}

static vx_status fs_readdir(void *ctx, uint64_t dir, uint32_t index, uint64_t *child) {
  (void)ctx;
  if (dir == ROOT) {
    if (index) return VX_ERR_NOT_FOUND;
    *child = INPUT;
    return VX_OK;
  }
  if (dir >= DIR && dir < DIR + 16) {
    if (index > 1) return VX_ERR_NOT_FOUND;
    *child = (index ? EVENTS : INFO) + dir - DIR;
    return VX_OK;
  }
  if (index < 2) {
    *child = index ? POINTER : KEYBOARD;
    return VX_OK;
  }
  for (uint32_t i = 0, seen = 2; i < ndevices; i++)
    if (devices[i].known && seen++ == index) {
      *child = DIR + devices[i].number;
      return VX_OK;
    }
  return VX_ERR_NOT_FOUND;
}

// --- The devices ---

// A key typed into the console: its rune with the modifiers, as UTF-8.
static void type_key(const vx_input_key *k) {
  if (kbdin < 0 || k->action == VX_KEY_UP) return;
  uint32_t r = vx_keymap_rune(k->usage, k->mods);
  if (!r) return;
  char b = (char)r; // the US layout's runes are all ASCII
  vx_write(kbdin, (vx_str){&b, 1});
}

static void record(uint32_t dev, const vx_input_events *m, uint32_t len) {
  uint8_t kind = devices[dev].info.kind;
  if (len < offsetof(vx_input_events, key) || m->count > VX_INPUT_BATCH ||
      len != vx_input_events_len(kind, m->count))
    return; // a driver's word, checked
  for (uint32_t i = 0; i < m->count; i++) {
    entry *e = &log_[next_seq++ % LOG];
    e->dev = dev, e->kind = kind;
    if (kind == VX_INPUT_KEYBOARD) {
      e->key = m->key[i];
      if (e->key.nheld > VX_INPUT_HELD) e->key.nheld = VX_INPUT_HELD;
      type_key(&e->key);
    } else {
      e->pointer = m->pointer[i];
    }
  }
  server.again = true; // held reads may go on
}

static void session_drain(uint32_t i) {
  device *d = &devices[i];
  for (;;) {
    static vx_input_events m;
    vx_msg_size size;
    vx_handle h[VX_CHANNEL_MAX_HANDLES];
    vx_status st = vx_channel_read(d->session, &m, sizeof m, h, VX_CHANNEL_MAX_HANDLES, &size);
    if (st == VX_ERR_PEER_CLOSED) { // the driver has gone; its records stay in the log
      vx_handle_close(d->session);
      d->session = VX_HANDLE_NONE, d->known = false;
      return;
    }
    if (st != VX_OK) break;
    for (uint32_t k = 0; k < size.handles; k++) vx_handle_close(h[k]);
    if (m.h.ordinal == VX_INPUT_DEVICE && size.bytes == sizeof(vx_input_device)) {
      memcpy(&d->info, &m, sizeof d->info);
      d->info.name[sizeof d->info.name - 1] = 0;
      d->known = d->info.version == VX_INPUT_VERSION &&
                 (d->info.kind == VX_INPUT_KEYBOARD || d->info.kind == VX_INPUT_POINTER);
      if (d->known)
        vx_printf("inputd: input%u, %s, a %s\n", d->number, d->info.name,
                  d->info.kind == VX_INPUT_KEYBOARD ? "keyboard" : "pointer");
    } else if (m.h.ordinal == VX_INPUT_EVENTS && d->known) {
      record(i, &m, size.bytes);
    }
  }
  vx_port_bind(server.port, d->session, VX_TRIGGER_READABLE, KEY_SESSION | i, 0);
}

// A driver's answer to CONNECT: the session's channel.
static void connected(uint32_t i) {
  device *d = &devices[i];
  vx_msg_header rep;
  vx_handle h = VX_HANDLE_NONE;
  vx_msg_size size;
  if (vx_channel_read(d->connector, &rep, sizeof rep, &h, 1, &size) != VX_OK) {
    vx_port_bind(server.port, d->connector, VX_TRIGGER_READABLE, KEY_CONNECT | i, 0);
    return;
  }
  if (rep.flags || !h) return; // refused
  d->session = h;
  session_drain(i);
}

static void event(void *ctx, const vx_packet *pk) {
  (void)ctx;
  uint32_t i = (uint32_t)(pk->key & 0xff);
  if (i >= ndevices) return;
  if ((pk->key & ~0xffull) == KEY_CONNECT) connected(i);
  if ((pk->key & ~0xffull) == KEY_SESSION && devices[i].session) session_drain(i);
}

// Its connectors: srv:input0 and on. A CONNECT sent on each, answered when
// the driver is there; a post with no driver never answers, which costs
// nothing.
static void connect_all(void) {
  for (uint32_t k = 0; k < vx_spawn.handle_count && ndevices < MAX_DEVICES; k++) {
    vx_str n = vx_spawn.handle_names[k];
    if (n.len < 10 || memcmp(n.ptr, "srv:input", 9) != 0 || !vx_spawn.handles[k]) continue;
    device *d = &devices[ndevices];
    d->connector = vx_spawn.handles[k], vx_spawn.handles[k] = VX_HANDLE_NONE;
    d->number = (uint32_t)number_of((vx_str){n.ptr + 9, n.len - 9});
    vx_msg_header req = {.txid = ndevices + 1, .ordinal = VX_INPUT_CONNECT};
    vx_channel_write(d->connector, &req, sizeof req, nullptr, 0);
    vx_port_bind(server.port, d->connector, VX_TRIGGER_READABLE, KEY_CONNECT | ndevices, 0);
    ndevices++;
  }
}

const char *vx_main(void) {
  server.fs = (p9_fs){.attach = fs_attach,
                      .walk = fs_walk,
                      .parent = fs_parent,
                      .stat = fs_stat,
                      .open = fs_open,
                      .clone = fs_clone,
                      .clunk = fs_clunk,
                      .read = fs_read,
                      .readdir = fs_readdir};
  server.name = VX_STR("inputd");
  server.supported = P9_EXT_XATTR;
  server.event = event;
  server.listen = vx_spawn_take("listen");
  if (!server.listen || vx_port_create(0, &server.port) != VX_OK) {
    vx_print(VX_STR("inputd: no listen channel\n"));
    return "no listen channel";
  }
  kbdin = vx_open(VX_STR("/kbdin"), VX_OWRITE); // none: no console to type into
  connect_all();
  vx_printf("inputd: serving /srv/input, %u posts%s\n", ndevices,
            kbdin >= 0 ? ", typing into the console" : "");
  return p9_ring_serve(&server) == VX_OK ? nullptr : "cannot serve";
}
