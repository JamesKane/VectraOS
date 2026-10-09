// drv-virtio-input: a virtio input device (virtio 1.2 §5.8; M7 step 7c1),
// keyboard or pointer, serving the input class protocol
// (docs/proto/input.md) on /srv/input0, input1, ... to inputd.
//
// The device speaks Linux's evdev: each event a type, a code and a value,
// a report ended by SYN_REPORT. A keyboard's EV_KEY codes become HID usages
// (the table below: Linux's hid-input.c, read backwards), each key record
// carrying the held set after it; a pointer's report becomes one pointer
// record, its absolute position, relative motion, wheel and buttons. Records
// are sent a batch per wake, never merged (21 §2 item 6). virtio-input gives
// no timestamps: a record's time is when the driver saw its report.
//
// What it is comes from its configuration: absolute axes make a tablet,
// relative ones a mouse, and anything else with keys a keyboard.
//
// One thread, one port: the interrupt, the listen channel, the session.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-driver/virtio.c"
#include "../../lib/vx-driver/inputproto.h"

static constexpr uint16_t QSIZE = 64; // event buffers the device fills
enum : uint64_t { KEY_IRQ = 1, KEY_LISTEN, KEY_SESSION };

// The device's configuration (§5.8.4): select and subsel pick what u holds.
enum : uint8_t { CFG_ID_NAME = 0x01, CFG_EV_BITS = 0x11, CFG_ABS_INFO = 0x12 };
enum : uint16_t { EV_SYN = 0, EV_KEY = 1, EV_REL = 2, EV_ABS = 3 };
enum : uint16_t { REL_X = 0, REL_Y = 1, REL_HWHEEL = 6, REL_WHEEL = 8, ABS_X = 0, ABS_Y = 1 };
enum : uint16_t {
  BTN_LEFT = 0x110,
  BTN_TASK = 0x117
}; // mouse buttons: left, right, middle, side, extra, ...

typedef struct virtio_input_event {
  uint16_t type, code;
  uint32_t value;
} virtio_input_event;

// Linux's KEY_ codes, 0 to 127, as HID keyboard usages (0: none).
static const uint8_t EVDEV_TO_HID[128] = {
    0,    0x29, 0x1e, 0x1f, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2d, 0x2e, 0x2a, 0x2b, // 0
    0x14, 0x1a, 0x08, 0x15, 0x17, 0x1c, 0x18, 0x0c, 0x12, 0x13, 0x2f, 0x30, 0x28, 0xe0, 0x04, 0x16, // 16
    0x07, 0x09, 0x0a, 0x0b, 0x0d, 0x0e, 0x0f, 0x33, 0x34, 0x35, 0xe1, 0x31, 0x1d, 0x1b, 0x06, 0x19, // 32
    0x05, 0x11, 0x10, 0x36, 0x37, 0x38, 0xe5, 0x55, 0xe2, 0x2c, 0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e, // 48
    0x3f, 0x40, 0x41, 0x42, 0x43, 0x53, 0x47, 0x5f, 0x60, 0x61, 0x56, 0x5c, 0x5d, 0x5e, 0x57, 0x59, // 64
    0x5a, 0x5b, 0x62, 0x63, 0,    0x94, 0x64, 0x44, 0x45, 0x87, 0x92, 0x93, 0x8a, 0x88, 0x8b, 0x8c, // 80
    0x58, 0xe4, 0x54, 0x46, 0xe6, 0,    0x4a, 0x52, 0x4b, 0x50, 0x4f, 0x4d, 0x51, 0x4e, 0x49, 0x4c, // 96
    0,    0x7f, 0x81, 0x80, 0x66, 0x67, 0,    0x48, 0,    0x85, 0x90, 0x91, 0x89, 0xe3, 0xe7, 0x65, // 112
};

// A key code as a HID usage: the keyboard page, F13 to F24 beyond the
// table, and mouse buttons the button page. 0 for one it does not know.
static uint32_t usage_of(uint16_t code) {
  if (code < 128 && EVDEV_TO_HID[code]) return VX_HID_KEYBOARD | EVDEV_TO_HID[code];
  if (code >= 183 && code <= 194) return VX_HID_KEYBOARD | (0x68 + (code - 183)); // KEY_F13..KEY_F24
  if (code >= BTN_LEFT && code <= BTN_TASK) return VX_HID_BUTTON | (code - BTN_LEFT + 1);
  return 0;
}

static vx_virtio dev;
static vx_virtq eventq;
static virtio_input_event *events; // QSIZE of them, mapped here
static uint64_t events_pa;
static vx_handle irq, port, listen, session;
static vx_input_device info;

// The report being gathered, and the batch being built.
static vx_input_events batch;
static uint32_t held[VX_INPUT_HELD], nheld;
static bool caps;
static vx_input_pointer report;
static bool report_moved;

[[noreturn]] static void fail(const char *what) {
  vx_printf("drv-virtio-input: FAILED: %s\n", what);
  vx_exits(what);
}

// --- Configuration ---

typedef struct input_config {
  uint8_t select, subsel, size, reserved[5];
  uint8_t u[128];
} input_config;

// What select and subsel give: its size, and its bytes at out (at most cap;
// the rest of out zero, so no earlier answer shows through a shorter one).
static uint8_t config(uint8_t select, uint8_t subsel, void *out, uint32_t cap) {
  memset(out, 0, cap);
  volatile input_config *c = (volatile input_config *)dev.device;
  c->select = select, c->subsel = subsel;
  uint8_t size = c->size;
  if (size > sizeof c->u) size = sizeof c->u; // the device's word, bounded
  for (uint32_t i = 0; i < size && i < cap; i++) ((uint8_t *)out)[i] = c->u[i];
  return size;
}

static void identify(void) {
  info = (vx_input_device){.h = {.ordinal = VX_INPUT_DEVICE}, .version = VX_INPUT_VERSION};
  config(CFG_ID_NAME, 0, info.name, sizeof info.name - 1);
  uint8_t bits[16];
  if (config(CFG_EV_BITS, EV_ABS, bits, sizeof bits) && bits[0] & 3) {
    info.kind = VX_INPUT_POINTER, info.axes = VX_INPUT_ABSOLUTE;
    uint32_t abs[5] = {}; // min, max, fuzz, flat, res
    config(CFG_ABS_INFO, ABS_X, abs, sizeof abs);
    info.x_max = abs[1];
    config(CFG_ABS_INFO, ABS_Y, abs, sizeof abs);
    info.y_max = abs[1];
  } else if (config(CFG_EV_BITS, EV_REL, bits, sizeof bits) && bits[0] & 3) {
    info.kind = VX_INPUT_POINTER, info.axes = VX_INPUT_RELATIVE;
  } else {
    info.kind = VX_INPUT_KEYBOARD;
  }
  if (info.kind == VX_INPUT_POINTER && config(CFG_EV_BITS, EV_REL, bits, sizeof bits) && bits[1] & 1)
    info.axes |= VX_INPUT_WHEEL; // REL_WHEEL is bit 8
}

// --- Events ---

static void send_batch(void) {
  if (!batch.count) return;
  if (session) {
    batch.h = (vx_msg_header){.ordinal = VX_INPUT_EVENTS};
    vx_channel_write(session, &batch, vx_input_events_len(info.kind, batch.count), nullptr, 0);
  }
  batch.count = 0;
}

static void key(uint16_t code, uint32_t value, vx_instant now) {
  uint32_t u = usage_of(code);
  if (!u || value > VX_KEY_REPEAT) return;
  if (value == VX_KEY_DOWN && u == (VX_HID_KEYBOARD | 0x39)) caps = !caps;
  if (value == VX_KEY_UP) {
    uint32_t j = 0;
    for (uint32_t i = 0; i < nheld; i++)
      if (held[i] != u) held[j++] = held[i];
    nheld = j;
  } else if (value == VX_KEY_DOWN) {
    bool there = false;
    for (uint32_t i = 0; i < nheld; i++) there |= held[i] == u;
    if (!there && nheld < VX_INPUT_HELD) held[nheld++] = u;
  }
  if (info.kind == VX_INPUT_POINTER) { // a button: the next report carries it
    uint32_t b = u & 0xffff;
    if (b >= 1 && b <= 32)
      report.buttons = value ? report.buttons | 1u << (b - 1) : report.buttons & ~(1u << (b - 1));
    report_moved = true;
    return;
  }
  if (batch.count == VX_INPUT_BATCH) send_batch();
  vx_input_key *k = &batch.key[batch.count++];
  *k = (vx_input_key){.time = (uint64_t)now, .usage = u, .action = (uint8_t)value, .nheld = (uint8_t)nheld};
  memcpy(k->held, held, nheld * sizeof held[0]);
  k->mods = vx_input_mods(held, nheld) | (caps ? VX_MOD_CAPS : 0);
}

static void event(const virtio_input_event *e, vx_instant now) {
  if (e->type == EV_KEY) {
    key(e->code, e->value, now);
  } else if (e->type == EV_ABS) {
    if (e->code == ABS_X) report.x = (int32_t)e->value;
    if (e->code == ABS_Y) report.y = (int32_t)e->value;
    report_moved = true;
  } else if (e->type == EV_REL) {
    int32_t v = (int32_t)e->value;
    if (e->code == REL_X) report.dx += v;
    if (e->code == REL_Y) report.dy += v;
    if (e->code == REL_WHEEL) report.wheel += v;
    if (e->code == REL_HWHEEL) report.hwheel += v;
    report_moved = true;
  } else if (e->type == EV_SYN && e->code == 0 && info.kind == VX_INPUT_POINTER && report_moved) {
    if (batch.count == VX_INPUT_BATCH) send_batch();
    report.time = (uint64_t)now;
    batch.pointer[batch.count++] = report;
    report.dx = report.dy = report.wheel = report.hwheel = 0, report_moved = false; // absolute stays
  }
}

// Every event the device has written, its buffers given back.
static void drain(void) {
  vx_instant now = vx_now();
  uint16_t d;
  uint32_t len;
  bool any = false;
  while (vx_virtq_used(&eventq, &d, &len)) {
    if (len >= sizeof(virtio_input_event)) event(&events[d], now);
    vx_virtq_offer(&eventq, d, events_pa + (uint64_t)d * sizeof(virtio_input_event),
                   sizeof(virtio_input_event), true);
    any = true;
  }
  if (any) vx_virtq_kick(&eventq);
  send_batch();
}

// --- The post ---

static void refuse(const vx_msg_header *req, vx_status why) {
  vx_msg_header rep = {.txid = req->txid, .ordinal = req->ordinal, .flags = (uint32_t)(int32_t)why};
  vx_channel_write(listen, &rep, sizeof rep, nullptr, 0);
}

static void accept(void) {
  for (;;) {
    vx_msg_header req;
    vx_msg_size size;
    vx_handle junk[VX_CHANNEL_MAX_HANDLES];
    vx_status st = vx_channel_read(listen, &req, sizeof req, junk, VX_CHANNEL_MAX_HANDLES, &size);
    if (st == VX_ERR_SHOULD_WAIT) return;
    if (st == VX_ERR_PEER_CLOSED) fail("the listen channel is gone");
    if (st != VX_OK) continue;
    for (uint32_t i = 0; i < size.handles; i++) vx_handle_close(junk[i]);
    if (size.bytes != sizeof req || req.ordinal != VX_INPUT_CONNECT) {
      refuse(&req, VX_ERR_INVALID);
      continue;
    }
    if (session) {
      refuse(&req, VX_ERR_BAD_STATE);
      continue;
    }
    vx_handle ends[2];
    if (vx_channel_create(0, ends) != VX_OK) {
      refuse(&req, VX_ERR_NO_MEMORY);
      continue;
    }
    vx_msg_header rep = {.txid = req.txid, .ordinal = req.ordinal};
    if (vx_channel_write(listen, &rep, sizeof rep, &ends[1], 1) != VX_OK) {
      vx_handle_close(ends[0]), vx_handle_close(ends[1]);
      continue;
    }
    session = ends[0];
    vx_channel_write(session, &info, sizeof info, nullptr, 0);
    vx_port_bind(port, session, VX_TRIGGER_PEER_CLOSED, KEY_SESSION, 0);
  }
}

// --- Starting ---

static volatile uint8_t *map_handle(const char *name, uint64_t size) {
  vx_handle h = vx_spawn_take(name);
  uint64_t at = 0;
  if (!h || vx_as_map(vx_self, h, 0, size, VX_MAP_WRITE, &at) != VX_OK) return nullptr;
  vx_handle_close(h);
  return (volatile uint8_t *)at;
}

static void setup_device(void) {
  dev.fn.cfg = map_handle("config", 4096);
  dev.dma = vx_spawn_take("dma");
  if (!dev.fn.cfg || !dev.dma) fail("no configuration space or DMA domain");
  static char scratch[VX_CHANNEL_MAX_BYTES];
  vx_ndb_reader r = {.src = vx_spawn.text, .scratch = scratch, .scratch_cap = sizeof scratch};
  vx_ndb_record rec;
  vx_msi msi = {};
  while (vx_ndb_next(&r, &rec) == VX_NDB_RECORD) {
    uint64_t n, v;
    if (vx_ndb_get_u64(&rec, "bar", &n) && n < 6 && vx_ndb_get_u64(&rec, "size", &v)) {
      char name[5] = {'b', 'a', 'r', (char)('0' + n), 0};
      dev.bar[n] = map_handle(name, v);
      dev.bar_size[n] = dev.bar[n] ? v : 0;
    } else if (vx_ndb_get_u64(&rec, "msi", &n) && n == 0 && vx_ndb_get_u64(&rec, "address", &v)) {
      uint64_t data = 0;
      vx_ndb_get_u64(&rec, "data", &data);
      msi = (vx_msi){.address = v, .data = (uint32_t)data};
    }
  }
  irq = vx_spawn_take("msi0");
  if (!irq || !msi.address) fail("no MSI");
  if (vx_virtio_find(&dev) != VX_OK || dev.msix_count < 1) fail("not a modern virtio device with MSI-X");
  uint64_t features;
  if (vx_virtio_start(&dev, 0, &features) != VX_OK) fail("feature negotiation");
  vx_virtio_msix(&dev, 0, msi);
  if (vx_virtq_init(&dev, &eventq, 0, QSIZE, 0) != VX_OK) fail("the event queue");
  identify();
  vx_handle vmo, mapping; // kept as long as the driver lives
  uint64_t at = 0;
  if (vx_vmo_create(4096, 0, &vmo) != VX_OK || vx_as_map(vx_self, vmo, 0, 4096, VX_MAP_WRITE, &at) != VX_OK ||
      vx_dma_map(dev.dma, vmo, 0, 4096, VX_DMA_READ | VX_DMA_WRITE, &events_pa, &mapping) != VX_OK)
    fail("no memory for events");
  vx_handle_close(vmo);
  events = (virtio_input_event *)at;
  for (uint16_t i = 0; i < eventq.size; i++)
    vx_virtq_offer(&eventq, i, events_pa + (uint64_t)i * sizeof(virtio_input_event),
                   sizeof(virtio_input_event), true);
  vx_virtio_ready(&dev);
  vx_virtq_kick(&eventq);
}

const char *vx_main(void) {
  setup_device();
  listen = vx_spawn_take("listen");
  if (!listen || vx_port_create(0, &port) != VX_OK) fail("no listen channel");
  const char *kind = "mouse";
  if (info.kind == VX_INPUT_KEYBOARD)
    kind = "keyboard";
  else if (info.axes & VX_INPUT_ABSOLUTE)
    kind = "tablet";
  vx_printf("drv-virtio-input: %s, a %s\n", info.name, kind);
  vx_port_bind(port, irq, VX_TRIGGER_IRQ, KEY_IRQ, 0);
  vx_port_bind(port, listen, VX_TRIGGER_READABLE, KEY_LISTEN, 0);
  for (;;) {
    vx_packet pk[4];
    int64_t n = vx_port_wait(port, VX_INFINITE, 0, pk, 4);
    for (int64_t i = 0; i < n; i++) {
      if (pk[i].key == KEY_IRQ) {
        drain();
        vx_port_bind(port, irq, VX_TRIGGER_IRQ, KEY_IRQ, 0);
      } else if (pk[i].key == KEY_LISTEN) {
        accept();
        vx_port_bind(port, listen, VX_TRIGGER_READABLE, KEY_LISTEN, 0);
      } else if (pk[i].key == KEY_SESSION && session) {
        vx_handle_close(session);
        session = VX_HANDLE_NONE;
      }
    }
  }
}
