// drv-virtio-net: the virtio network card (docs/01 §7, 04 §5 M3), serving the
// net class protocol (lib/vx-driver/netproto.h) on /srv/ether0.
//
// devmgr starts it with only its device: the function's configuration space,
// its memory BARs, a DMA domain, two MSI-X interrupts (receive, transmit) and
// the post's listen end. It serves one client at a time (netd).
//
// Receiving: the device always holds every receive buffer. A frame it fills
// goes to the client's oldest offered slot, or is dropped if there is none,
// and the buffer goes straight back to the device. Sending: a frame is copied
// from the client's arena into a free transmit buffer; with none free, the
// driver takes nothing more from the client until the device returns one.
//
// One thread, one port: the two interrupts, the listen channel, and the
// client's doorbell and going away.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-driver/virtio.c"
#include "../../lib/vx-ring/session.c"
#include "../../lib/vx-driver/netproto.h"

static constexpr uint16_t QSIZE = 64;   // buffers in each virtqueue
static constexpr uint32_t BUF = 2048;   // two to a page, so none crosses one
static constexpr uint32_t NET_HDR = 12; // struct virtio_net_hdr, with VERSION_1
static constexpr uint64_t VIRTIO_NET_F_MAC = 1ull << 5;

// Port keys. A client's carry its session number above bit 8, so a packet
// about a client that has gone is never taken for the next one's.
enum : uint64_t { KEY_RX = 1, KEY_TX, KEY_LISTEN, KEY_BELL, KEY_CLOSED };
static uint64_t session; // the current client's number

static uint64_t client_key(uint64_t kind) { return session << 8 | kind; }

static vx_virtio dev;
static vx_virtq rxq, txq;
static uint8_t *rx_buf, *tx_buf;                          // QSIZE buffers each, mapped here
static uint64_t rx_pages[QSIZE / 2], tx_pages[QSIZE / 2]; // their device addresses, a page each
static bool tx_busy[QSIZE];
static uint8_t mac[6];
static vx_handle irq_rx, irq_tx, port, listen;

typedef struct client_state {
  bool on;
  vx_ring ring;
  vx_handle end;
  bool armed;
  bool holding; // a TX that found no free buffer: taken again once one is free
  vx_sqe held;
  struct {
    uint32_t slot;
    uint64_t user_data;
  } offers[VX_NET_SLOTS]; // RX slots offered, oldest first
  uint32_t offer_head, offer_count;
} client_state;

static client_state client;

[[noreturn]] static void fail(const char *what) {
  vx_print(VX_STR("drv-virtio-net: FAILED: "));
  vx_print(vx_cstr(what));
  vx_print(VX_STR("\n"));
  vx_thread_exit(1);
}

static uint64_t buf_addr(const uint64_t *pages, uint16_t i) { return pages[i / 2] + (uint64_t)(i % 2) * BUF; }

// A VMO of QSIZE buffers, mapped here and given to the device.
static uint8_t *make_buffers(uint64_t *pages) {
  vx_handle vmo;
  uint64_t at = 0, size = (uint64_t)QSIZE * BUF;
  if (vx_vmo_create(size, 0, &vmo) != VX_OK || vx_as_map(vx_self, vmo, 0, size, VX_MAP_WRITE, &at) != VX_OK ||
      vx_dma_map(dev.dma, vmo, 0, size, pages) != VX_OK)
    fail("no memory for buffers");
  vx_handle_close(vmo);
  return (uint8_t *)at;
}

// Maps the handle the spawn message calls `name` (`size` bytes), or returns nullptr.
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
  // The BARs devmgr mapped for it: records `bar=N size=S`.
  static char scratch[VX_CHANNEL_MAX_BYTES];
  vx_ndb_reader r = {.src = vx_spawn.text, .scratch = scratch, .scratch_cap = sizeof scratch};
  vx_ndb_record rec;
  vx_msi msi[2] = {};
  while (vx_ndb_next(&r, &rec) == VX_NDB_RECORD) {
    uint64_t n, v;
    if (vx_ndb_get_u64(&rec, "bar", &n) && n < 6 && vx_ndb_get_u64(&rec, "size", &v)) {
      char name[5] = {'b', 'a', 'r', (char)('0' + n), 0};
      dev.bar[n] = map_handle(name, v);
      dev.bar_size[n] = dev.bar[n] ? v : 0;
    } else if (vx_ndb_get_u64(&rec, "msi", &n) && n < 2 && vx_ndb_get_u64(&rec, "address", &v)) {
      uint64_t data = 0;
      vx_ndb_get_u64(&rec, "data", &data);
      msi[n] = (vx_msi){.address = v, .data = (uint32_t)data};
    }
  }
  irq_rx = vx_spawn_take("msi0");
  irq_tx = vx_spawn_take("msi1");
  if (!irq_rx || !irq_tx || !msi[0].address || !msi[1].address) fail("no MSIs");
  if (vx_virtio_find(&dev) != VX_OK || dev.msix_count < 2) fail("not a modern virtio device with MSI-X");

  uint64_t features;
  if (vx_virtio_start(&dev, VIRTIO_NET_F_MAC, &features) != VX_OK) fail("feature negotiation");
  vx_virtio_msix(&dev, 0, msi[0]);
  vx_virtio_msix(&dev, 1, msi[1]);
  if (vx_virtq_init(&dev, &rxq, 0, QSIZE, 0) != VX_OK || vx_virtq_init(&dev, &txq, 1, QSIZE, 1) != VX_OK)
    fail("the queues");
  bool has_mac = features & VIRTIO_NET_F_MAC;
  for (int i = 0; i < 6; i++) mac[i] = has_mac ? dev.device[i] : 0;
  if (!has_mac) mac[0] = 2, mac[5] = 1; // a locally administered address
  rx_buf = make_buffers(rx_pages);
  tx_buf = make_buffers(tx_pages);
  for (uint16_t i = 0; i < QSIZE; i++) vx_virtq_offer(&rxq, i, buf_addr(rx_pages, i), BUF, true);
  vx_virtio_ready(&dev);
  vx_virtq_kick(&rxq);
}

// --- The client ---

static void drop_client(void) {
  vx_handle_close(client.end);
  vx_session_unmap(&client.ring);
  client = (client_state){};
}

static bool complete(vx_cqe c) {
  vx_cqe *slot = vx_ring_produce_slot(&client.ring);
  if (!slot) return false; // a client that does not drain its completions
  *slot = c;
  if (vx_ring_produce(&client.ring)) vx_ring_notify(client.end);
  return true;
}

// Sends one frame from the client's arena. False if no transmit buffer is free.
static bool transmit(const vx_sqe *e, int64_t *result) {
  const uint8_t *frame = e->flags & VX_SQE_DREF && e->len >= 14 && e->len <= VX_NET_MAX_FRAME
                             ? vx_ring_peer_bytes(&client.ring, e->arena_off, e->len)
                             : nullptr;
  if (!frame) {
    *result = VX_ERR_INVALID;
    return true;
  }
  uint16_t d = 0;
  while (d < QSIZE && tx_busy[d]) d++;
  if (d == QSIZE) return false;
  uint8_t *b = tx_buf + (size_t)d * BUF;
  memset(b, 0, NET_HDR);              // no offloads
  memcpy(b + NET_HDR, frame, e->len); // copied once, then the device reads our copy
  tx_busy[d] = true;
  vx_virtq_offer(&txq, d, buf_addr(tx_pages, d), NET_HDR + e->len, false);
  vx_virtq_kick(&txq);
  *result = e->len;
  return true;
}

// Serves what the client has submitted. False if it broke the protocol.
static bool serve_client(void) {
  while (client.on) {
    vx_sqe e;
    if (client.holding) {
      e = client.held;
    } else {
      vx_status st = vx_ring_consume(&client.ring, &e);
      if (st == VX_ERR_SHOULD_WAIT) return true;
      if (st != VX_OK) return false;
    }
    vx_cqe c = {.user_data = e.user_data};
    if (e.opcode == VX_NET_INFO) {
      for (int i = 0; i < 6; i++) c.aux2 |= (uint64_t)mac[i] << (8 * i);
      c.aux = 1500;
    } else if (e.opcode == VX_NET_TX) {
      client.holding = !transmit(&e, &c.result);
      if (client.holding) {
        client.held = e;
        return true; // until the device gives a buffer back
      }
    } else if (e.opcode == VX_NET_RX && e.target < VX_NET_SLOTS && client.offer_count < VX_NET_SLOTS) {
      uint32_t at = (client.offer_head + client.offer_count++) % VX_NET_SLOTS;
      client.offers[at].slot = (uint32_t)e.target;
      client.offers[at].user_data = e.user_data;
      continue; // completed when a frame comes
    } else {
      c.result = VX_ERR_INVALID;
    }
    if (!complete(c)) return false;
  }
  return true;
}

// Frames the device has received: each to the oldest offered slot, or dropped.
static void service_rx(void) {
  uint16_t d;
  uint32_t len;
  bool any = false;
  while (vx_virtq_used(&rxq, &d, &len)) {
    any = true;
    if (len > NET_HDR && len <= BUF && client.on && client.offer_count) {
      uint32_t flen = len - NET_HDR;
      uint64_t arena_size;
      uint8_t *arena = vx_ring_arena(&client.ring, &arena_size);
      uint32_t slot = client.offers[client.offer_head].slot;
      uint64_t user_data = client.offers[client.offer_head].user_data;
      client.offer_head = (client.offer_head + 1) % VX_NET_SLOTS;
      client.offer_count--;
      memcpy(arena + (size_t)slot * VX_NET_SLOT, rx_buf + (size_t)d * BUF + NET_HDR, flen);
      if (!complete((vx_cqe){.user_data = user_data, .result = flen, .aux2 = (uint64_t)slot * VX_NET_SLOT}))
        drop_client();
    }
    vx_virtq_offer(&rxq, d, buf_addr(rx_pages, d), BUF, true); // straight back to the device
  }
  if (any) vx_virtq_kick(&rxq);
}

static void service_tx(void) {
  uint16_t d;
  uint32_t len;
  while (vx_virtq_used(&txq, &d, &len)) tx_busy[d] = false;
}

static void accept_client(void) {
  for (;;) {
    vx_msg_header req;
    vx_msg_size size;
    vx_status st = vx_channel_read(listen, &req, sizeof req, nullptr, 0, &size);
    if (st == VX_ERR_SHOULD_WAIT) return;
    if (st == VX_ERR_PEER_CLOSED) fail("the listen channel is gone");
    if (st != VX_OK || size.bytes != sizeof req || req.ordinal != VX_NET_CONNECT) continue;
    if (client.on) { // one client at a time: refuse
      vx_msg_header no = {.txid = req.txid, .ordinal = req.ordinal, .flags = 1};
      vx_channel_write(listen, &no, sizeof no, nullptr, 0);
      continue;
    }
    if (vx_session_accept(listen, &req, &VX_NET_PARAMS, &client.ring, &client.end) != VX_OK) continue;
    client.on = true;
    session++;
    vx_port_bind(port, client.end, VX_TRIGGER_PEER_CLOSED, client_key(KEY_CLOSED), 0);
  }
}

int vx_main(void) {
  listen = vx_spawn_take("listen");
  if (!listen) fail("no listen channel");
  setup_device();
  if (vx_port_create(0, &port) != VX_OK) fail("port_create");
  vx_port_bind(port, irq_rx, VX_TRIGGER_IRQ, KEY_RX, 0);
  vx_port_bind(port, irq_tx, VX_TRIGGER_IRQ, KEY_TX, 0);
  vx_print(VX_STR("drv-virtio-net: "));
  static const char hex[] = "0123456789abcdef";
  char text[18];
  for (int i = 0; i < 6; i++) {
    char *at = text + (ptrdiff_t)3 * i;
    at[0] = hex[mac[i] >> 4], at[1] = hex[mac[i] & 15];
    if (i < 5) at[2] = ':';
  }
  vx_print((vx_str){text, 17});
  vx_print(VX_STR(", serving /srv/ether0\n"));

  bool listen_armed = false;
  for (;;) {
    service_rx();
    service_tx();
    accept_client();
    if (client.on && !serve_client()) drop_client();

    // Arm what is idle; sleep unless the client's queue filled meanwhile.
    bool idle = true;
    if (client.on && !client.holding) {
      int64_t seen = vx_counter_read(client.end);
      if (!vx_ring_prepare_sleep(&client.ring))
        idle = false;
      else if (!client.armed)
        client.armed = vx_port_bind(port, client.end, VX_TRIGGER_COUNTER_GE, client_key(KEY_BELL),
                                    (uint64_t)seen + 1) == VX_OK;
    }
    if (!listen_armed) listen_armed = vx_port_bind(port, listen, VX_TRIGGER_READABLE, KEY_LISTEN, 0) == VX_OK;
    if (idle) {
      vx_packet pk[8];
      int64_t n = vx_port_wait(port, VX_INFINITE, 0, pk, 8);
      for (int64_t i = 0; i < n; i++) {
        if (pk[i].key == KEY_RX) vx_port_bind(port, irq_rx, VX_TRIGGER_IRQ, KEY_RX, 0);
        if (pk[i].key == KEY_TX) vx_port_bind(port, irq_tx, VX_TRIGGER_IRQ, KEY_TX, 0);
        if (pk[i].key == KEY_LISTEN) listen_armed = false;
        if (pk[i].key == client_key(KEY_BELL)) client.armed = false;
        if (pk[i].key == client_key(KEY_CLOSED) && client.on) drop_client();
      }
    }
    if (client.on) vx_ring_end_sleep(&client.ring);
  }
}
