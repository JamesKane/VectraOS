// drv-virtio-blk: the virtio block device (virtio 1.x, §5.2; docs/11 §10),
// serving the block class protocol (docs/proto/block.md,
// lib/vx-driver/blockproto.h) on its post, /srv/diskN.
//
// devmgr starts it with only its device: the function's configuration space,
// its memory BARs, a DMA domain, one MSI-X interrupt for the request queue,
// and the post's listen end. It serves up to MAX_CLIENTS sessions at once,
// each reaching its own window of the disk.
//
// Zero copy: a session's client arena is given to the device through the DMA
// domain when the session opens, so a transfer is described to the device as
// the arena's own pages and nothing is copied. Each request in flight holds a
// slot: an indirect descriptor table (§2.7.5.3), the request's header and its
// status byte, in memory of the driver's own that the device can reach. The
// device's view of a request is one queue descriptor, pointing at its table.
//
// virtio-blk has no FUA: WRITE_FUA is a write, then a flush, on the same slot.
// A session that ends with requests in flight stays half-open until they
// complete, so the device never writes into memory that has been let go.
//
// One thread, one port: the interrupt, the listen channel, and each
// session's doorbell and going away.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-driver/virtio.c"
#include "../../lib/vx-ring/session.c"
#include "../../lib/vx-driver/blockproto.h"

static constexpr uint32_t MAX_CLIENTS = 8;
static constexpr uint16_t SLOTS = 64;                             // requests in flight, all sessions together
static constexpr uint32_t MAX_TRANSFER = 128u << 10;              // bytes one request moves, at most
static constexpr uint32_t MAX_SEGMENTS = MAX_TRANSFER / 4096 + 1; // pages one transfer may touch
static constexpr uint32_t SLOT_BYTES = 1024;                      // a slot's memory, four to a page
static constexpr uint32_t TABLE_AT = 0, HEADER_AT = 640, DISCARD_AT = 672, STATUS_AT = 704;
static constexpr uint32_t ARENA_PAGES = VX_BLOCK_ARENA / 4096;
static_assert((MAX_SEGMENTS + 2) * sizeof(vx_virtio_desc) <= HEADER_AT);

// Features (§5.2.3) and request types (§5.2.6).
static constexpr uint64_t F_SEG_MAX = 1ull << 2, F_RO = 1ull << 5, F_BLK_SIZE = 1ull << 6,
                          F_FLUSH = 1ull << 9, F_DISCARD = 1ull << 13;
enum : uint32_t { T_IN = 0, T_OUT = 1, T_FLUSH = 4, T_DISCARD = 11 };
enum : uint8_t { S_OK = 0, S_IOERR = 1, S_UNSUPP = 2 };

// Port keys: a session's carry its slot and generation, so a packet about a
// session that has gone is never taken for the next one in its slot.
enum : uint64_t { KEY_IRQ = 1, KEY_LISTEN, KEY_BELL, KEY_CLOSED };

typedef struct client {
  bool on, dying; // dying: gone, but with requests still in flight
  uint32_t gen;
  vx_ring ring;
  vx_handle end, memory, mapping; // mapping: the arena's, for the device
  uint64_t pages[ARENA_PAGES];    // the arena's device addresses, by page
  uint64_t first, count;          // the window, in sectors
  bool readonly;
  bool armed;
  uint32_t inflight;
} client;

typedef enum stage : uint8_t { FREE, BUSY, FUA_FLUSH } stage;

typedef struct slot {
  stage stage;
  uint8_t client;
  uint32_t gen;
  uint64_t user_data;
  int64_t result; // what completing it reports, if the device says OK
} slot;

static vx_virtio dev;
static vx_virtq q;
static vx_handle irq, port, listen;
static uint8_t *slot_mem;              // SLOTS slots, mapped here
static vx_handle slot_mapping;         // theirs, for the device: kept as long as the driver lives
static uint64_t slot_pages[SLOTS / 4]; // their device addresses, a page each
static slot slots[SLOTS];
static client clients[MAX_CLIENTS];
static uint64_t sectors;     // the disk's, in sector_size units
static uint32_t sector_size; // bytes
static uint32_t max_transfer, max_discard;
static bool has_flush, has_discard, device_ro;
static uint32_t next_client; // where the round robin over sessions starts

[[noreturn]] static void fail(const char *what) {
  vx_print(VX_STR("drv-virtio-blk: FAILED: "));
  vx_print(vx_cstr(what));
  vx_print(VX_STR("\n"));
  vx_exits(what);
}

static uint64_t key_of(uint32_t c, uint64_t kind) { return (uint64_t)clients[c].gen << 16 | c << 8 | kind; }
static uint8_t *slot_at(uint16_t s) { return slot_mem + (size_t)s * SLOT_BYTES; }
static uint64_t slot_addr(uint16_t s, uint32_t at) {
  return slot_pages[s / 4] + (uint64_t)(s % 4) * SLOT_BYTES + at;
}

// Maps the handle the spawn message calls `name` (`size` bytes), or returns nullptr.
static volatile uint8_t *map_handle(const char *name, uint64_t size) {
  vx_handle h = vx_spawn_take(name);
  uint64_t at = 0;
  if (!h || vx_as_map(vx_self, h, 0, size, VX_MAP_WRITE, &at) != VX_OK) return nullptr;
  vx_handle_close(h);
  return (volatile uint8_t *)at;
}

static uint32_t cfg32(uint32_t at) { return *(volatile uint32_t *)(dev.device + at); }

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
  if (vx_virtio_start(&dev, VIRTIO_RING_F_INDIRECT_DESC | F_SEG_MAX | F_RO | F_BLK_SIZE | F_FLUSH | F_DISCARD,
                      &features) != VX_OK)
    fail("feature negotiation");
  if (!(features & VIRTIO_RING_F_INDIRECT_DESC)) fail("no indirect descriptors");
  vx_virtio_msix(&dev, 0, msi);
  if (vx_virtq_init(&dev, &q, 0, SLOTS, 0) != VX_OK || q.size < SLOTS) fail("the request queue");

  // The device's configuration (§5.2.4), read as untrusted: sizes bounded.
  uint64_t capacity = cfg32(0) | (uint64_t)cfg32(4) << 32; // in 512-byte sectors, always
  sector_size = features & F_BLK_SIZE ? cfg32(20) : 512;
  if (sector_size < 512 || sector_size > 4096 || sector_size & (sector_size - 1)) sector_size = 512;
  sectors = capacity / (sector_size / 512);
  uint32_t seg_max = features & F_SEG_MAX ? cfg32(12) : MAX_SEGMENTS;
  if (seg_max < 2) fail("the device takes too few segments");
  max_transfer =
      seg_max >= MAX_SEGMENTS ? MAX_TRANSFER : (seg_max - 1) * 4096; // the worst case: an unaligned start
  max_transfer -= max_transfer % sector_size;
  has_flush = features & F_FLUSH;
  device_ro = features & F_RO;
  has_discard = features & F_DISCARD;
  max_discard = has_discard ? cfg32(36) : 0;
  if (!max_discard) has_discard = false;

  vx_handle vmo;
  uint64_t at = 0, size = (uint64_t)SLOTS * SLOT_BYTES;
  if (vx_vmo_create(size, 0, &vmo) != VX_OK || vx_as_map(vx_self, vmo, 0, size, VX_MAP_WRITE, &at) != VX_OK ||
      vx_dma_map(dev.dma, vmo, 0, size, VX_DMA_READ | VX_DMA_WRITE, slot_pages, &slot_mapping) != VX_OK)
    fail("no memory for request slots");
  vx_handle_close(vmo);
  slot_mem = (uint8_t *)at;
  vx_virtio_ready(&dev);
}

// --- Sessions ---

static bool complete(uint32_t c, vx_cqe e) {
  client *k = &clients[c];
  vx_cqe *at = vx_ring_produce_slot(&k->ring);
  if (!at) return false; // a client that does not drain its completions
  *at = e;
  if (vx_ring_produce(&k->ring)) vx_ring_notify(k->end);
  return true;
}

// The session's memory, given back once nothing in flight can write to it.
static void release_client(uint32_t c) {
  client *k = &clients[c];
  vx_dma_unmap(k->mapping);
  vx_handle_close(k->memory);
  vx_session_unmap(&k->ring);
  uint32_t gen = k->gen;
  *k = (client){.gen = gen};
}

static void drop_client(uint32_t c) {
  client *k = &clients[c];
  if (!k->on) return;
  vx_handle_close(k->end);
  k->on = false;
  k->dying = true;
  if (!k->inflight) release_client(c);
}

// Describes a transfer to the device: the header, the arena's pages, the
// status byte, chained in slot s's table. Returns the table's length.
static uint16_t build_transfer(uint16_t s, const client *k, uint32_t type, uint64_t sector,
                               uint32_t arena_off, uint32_t len) {
  uint8_t *m = slot_at(s);
  volatile vx_virtio_desc *t = (volatile vx_virtio_desc *)(m + TABLE_AT);
  uint32_t *h = (uint32_t *)(m + HEADER_AT);
  h[0] = type, h[1] = 0;
  *(uint64_t *)(m + HEADER_AT + 8) = sector * (sector_size / 512);
  m[STATUS_AT] = 0xff;
  uint16_t n = 0;
  t[n++] =
      (vx_virtio_desc){.addr = slot_addr(s, HEADER_AT), .len = 16, .flags = VIRTQ_DESC_F_NEXT, .next = 1};
  bool device_writes = type == T_IN;
  for (uint32_t done = 0; done < len;) {
    uint32_t off = arena_off + done, in_page = off % 4096, take = 4096 - in_page;
    if (take > len - done) take = len - done;
    uint64_t pa = k->pages[off / 4096] + in_page;
    volatile vx_virtio_desc *prev = &t[n - 1];
    if (n > 1 && prev->addr + prev->len == pa) { // physically contiguous: one segment
      prev->len += take;
    } else {
      t[n] =
          (vx_virtio_desc){.addr = pa,
                           .len = take,
                           .flags = (uint16_t)(VIRTQ_DESC_F_NEXT | (device_writes ? VIRTQ_DESC_F_WRITE : 0)),
                           .next = (uint16_t)(n + 1)};
      n++;
    }
    done += take;
  }
  t[n] = (vx_virtio_desc){.addr = slot_addr(s, STATUS_AT), .len = 1, .flags = VIRTQ_DESC_F_WRITE};
  return (uint16_t)(n + 1);
}

static uint16_t build_flush(uint16_t s) {
  uint8_t *m = slot_at(s);
  volatile vx_virtio_desc *t = (volatile vx_virtio_desc *)(m + TABLE_AT);
  uint32_t *h = (uint32_t *)(m + HEADER_AT);
  h[0] = T_FLUSH, h[1] = 0;
  *(uint64_t *)(m + HEADER_AT + 8) = 0;
  m[STATUS_AT] = 0xff;
  t[0] = (vx_virtio_desc){.addr = slot_addr(s, HEADER_AT), .len = 16, .flags = VIRTQ_DESC_F_NEXT, .next = 1};
  t[1] = (vx_virtio_desc){.addr = slot_addr(s, STATUS_AT), .len = 1, .flags = VIRTQ_DESC_F_WRITE};
  return 2;
}

static uint16_t build_discard(uint16_t s, uint64_t sector, uint32_t count) {
  uint8_t *m = slot_at(s);
  volatile vx_virtio_desc *t = (volatile vx_virtio_desc *)(m + TABLE_AT);
  uint32_t *h = (uint32_t *)(m + HEADER_AT);
  h[0] = T_DISCARD, h[1] = 0;
  *(uint64_t *)(m + HEADER_AT + 8) = 0;
  *(uint64_t *)(m + DISCARD_AT) = sector * (sector_size / 512); // struct virtio_blk_discard_write_zeroes
  *(uint32_t *)(m + DISCARD_AT + 8) = count * (sector_size / 512);
  *(uint32_t *)(m + DISCARD_AT + 12) = 0;
  m[STATUS_AT] = 0xff;
  t[0] = (vx_virtio_desc){.addr = slot_addr(s, HEADER_AT), .len = 16, .flags = VIRTQ_DESC_F_NEXT, .next = 1};
  t[1] = (vx_virtio_desc){.addr = slot_addr(s, DISCARD_AT), .len = 16, .flags = VIRTQ_DESC_F_NEXT, .next = 2};
  t[2] = (vx_virtio_desc){.addr = slot_addr(s, STATUS_AT), .len = 1, .flags = VIRTQ_DESC_F_WRITE};
  return 3;
}

static int16_t free_slot(void) {
  for (uint16_t s = 0; s < SLOTS; s++)
    if (slots[s].stage == FREE) return (int16_t)s;
  return -1;
}

static void issue(uint16_t s, uint32_t c, uint64_t user_data, int64_t result, stage st, uint16_t n) {
  slots[s] = (slot){
      .stage = st, .client = (uint8_t)c, .gen = clients[c].gen, .user_data = user_data, .result = result};
  clients[c].inflight++;
  vx_virtq_offer_indirect(&q, s, slot_addr(s, TABLE_AT), n);
}

// Checks a transfer against the session's window and arena: 0, or why not.
static vx_status check_transfer(const client *k, const vx_sqe *e) {
  if (!(e->flags & VX_SQE_DREF) || !e->len || e->len % sector_size || e->arena_off % sector_size ||
      e->len > max_transfer)
    return VX_ERR_INVALID;
  if ((uint64_t)e->arena_off + e->len > VX_BLOCK_ARENA) return VX_ERR_RANGE;
  uint64_t n = e->len / sector_size;
  if (e->target >= k->count || n > k->count - e->target) return VX_ERR_RANGE;
  return VX_OK;
}

// Takes what session c has submitted, as long as slots are free. False if it
// broke the protocol. *kicked says whether anything went to the device.
static bool serve_client(uint32_t c, bool *kicked) {
  client *k = &clients[c];
  while (k->on) {
    int16_t s = free_slot();
    if (s < 0) return true; // taken again when a slot comes back
    vx_sqe e;
    vx_status st = vx_ring_consume(&k->ring, &e);
    if (st == VX_ERR_SHOULD_WAIT) return true;
    if (st != VX_OK) return false;
    vx_cqe done = {.user_data = e.user_data};
    bool now = true; // completed here, without the device
    switch (e.opcode) {
    case VX_BLOCK_INFO:
      done.result = max_transfer;
      done.aux = sector_size;
      done.aux2 = k->count;
      done.flags = (k->readonly ? VX_BLOCK_INFO_READONLY : 0) | (has_flush ? VX_BLOCK_INFO_CACHE : 0) |
                   (has_discard ? VX_BLOCK_INFO_DISCARD : 0);
      break;
    case VX_BLOCK_READ:
    case VX_BLOCK_WRITE:
    case VX_BLOCK_WRITE_FUA: {
      bool write = e.opcode != VX_BLOCK_READ;
      vx_status why = check_transfer(k, &e);
      if (why == VX_OK && write && k->readonly) why = VX_ERR_ACCESS;
      if (why != VX_OK) {
        done.result = why;
        break;
      }
      uint16_t n =
          build_transfer((uint16_t)s, k, write ? T_OUT : T_IN, k->first + e.target, e.arena_off, e.len);
      issue((uint16_t)s, c, e.user_data, e.len,
            e.opcode == VX_BLOCK_WRITE_FUA && has_flush ? FUA_FLUSH : BUSY, n);
      now = false;
      break;
    }
    case VX_BLOCK_FLUSH:
      if (k->readonly || !has_flush) break; // nothing of this session's to make durable
      issue((uint16_t)s, c, e.user_data, 0, BUSY, build_flush((uint16_t)s));
      now = false;
      break;
    case VX_BLOCK_DISCARD:
      if (k->readonly) {
        done.result = VX_ERR_ACCESS;
        break;
      }
      if (e.target >= k->count || e.offset > k->count - e.target) {
        done.result = VX_ERR_RANGE;
        break;
      }
      if (!has_discard || !e.offset) break; // a hint the device cannot take: done
      // At most what the device takes at once; a discard is a hint, so the rest may go undone.
      uint64_t count = e.offset < max_discard ? e.offset : max_discard;
      issue((uint16_t)s, c, e.user_data, 0, BUSY,
            build_discard((uint16_t)s, k->first + e.target, (uint32_t)count));
      now = false;
      break;
    default: done.result = VX_ERR_INVALID; break;
    }
    if (!now) {
      *kicked = true;
      continue;
    }
    if (!complete(c, done)) return false;
  }
  return true;
}

// Requests the device has finished: each completed, or its FUA's flush issued.
static bool service_queue(void) {
  uint16_t d;
  uint32_t len;
  bool kicked = false;
  while (vx_virtq_used(&q, &d, &len)) {
    if (d >= SLOTS || slots[d].stage == FREE) continue; // not one we offered
    slot *sl = &slots[d];
    client *k = &clients[sl->client];
    uint8_t status = slot_at(d)[STATUS_AT];
    if (sl->stage == FUA_FLUSH && status == S_OK && k->on && k->gen == sl->gen) { // the write: now its flush
      sl->stage = BUSY;
      vx_virtq_offer_indirect(&q, d, slot_addr(d, TABLE_AT), build_flush(d));
      kicked = true;
      continue;
    }
    int64_t result = VX_ERR_IO;
    if (status == S_OK) result = sl->result;
    if (status == S_UNSUPP) result = VX_ERR_UNSUPPORTED;
    uint32_t c = sl->client;
    uint64_t user_data = sl->user_data;
    bool same = k->gen == sl->gen;
    *sl = (slot){};
    if (!same) continue;
    k->inflight--;
    if (k->on && !complete(c, (vx_cqe){.user_data = user_data, .result = result})) drop_client(c);
    if (k->dying && !k->inflight) release_client(c);
  }
  return kicked;
}

static void accept_client(void) {
  for (;;) {
    vx_block_connect req;
    vx_msg_size size;
    vx_status st = vx_channel_read(listen, &req, sizeof req, nullptr, 0, &size);
    if (st == VX_ERR_SHOULD_WAIT) return;
    if (st == VX_ERR_PEER_CLOSED) fail("the listen channel is gone");
    if (st == VX_ERR_TOO_SMALL) { // not a request this protocol makes: read it, to be rid of it
      static uint8_t junk[VX_CHANNEL_MAX_BYTES];
      static vx_handle junk_handles[VX_CHANNEL_MAX_HANDLES];
      if (vx_channel_read(listen, junk, sizeof junk, junk_handles, VX_CHANNEL_MAX_HANDLES, &size) == VX_OK)
        for (uint32_t i = 0; i < size.handles; i++) vx_handle_close(junk_handles[i]);
      continue;
    }
    if (st != VX_OK || size.bytes < sizeof req.h) continue;
    if (size.bytes != sizeof req || req.h.ordinal != VX_BLOCK_CONNECT || req.flags & ~VX_BLOCK_READONLY) {
      vx_session_refuse(listen, &req.h, VX_ERR_INVALID);
      continue;
    }
    uint64_t count = req.count;
    if (!count && req.first < sectors) count = sectors - req.first;
    if (req.first >= sectors || !count || count > sectors - req.first) {
      vx_session_refuse(listen, &req.h, VX_ERR_RANGE);
      continue;
    }
    uint32_t c = 0;
    while (c < MAX_CLIENTS && (clients[c].on || clients[c].dying)) c++;
    if (c == MAX_CLIENTS) {
      vx_session_refuse(listen, &req.h, VX_ERR_NO_MEMORY);
      continue;
    }
    client *k = &clients[c];
    uint32_t gen = k->gen + 1;
    *k = (client){.gen = gen,
                  .first = req.first,
                  .count = count,
                  .readonly = device_ro || (req.flags & VX_BLOCK_READONLY)};
    if (vx_session_accept_keep(listen, &req.h, &VX_BLOCK_PARAMS, &k->ring, &k->end, &k->memory) != VX_OK) {
      *k = (client){.gen = gen};
      continue;
    }
    // The client arena, to the device.
    if (vx_dma_map(dev.dma, k->memory, k->ring.h.client_arena_offset, VX_BLOCK_ARENA,
                   VX_DMA_READ | VX_DMA_WRITE, k->pages, &k->mapping) != VX_OK) {
      vx_handle_close(k->end);
      vx_handle_close(k->memory);
      vx_session_unmap(&k->ring);
      *k = (client){.gen = gen};
      continue;
    }
    k->on = true;
    vx_port_bind(port, k->end, VX_TRIGGER_PEER_CLOSED, key_of(c, KEY_CLOSED), 0);
  }
}

static void print_size(void) {
  uint64_t mib = sectors * sector_size >> 20;
  vx_print_u64(mib);
  vx_print(VX_STR(" MiB, "));
  vx_print_u64(sector_size);
  vx_print(VX_STR("-byte sectors"));
  if (device_ro) vx_print(VX_STR(", read-only"));
  if (has_flush) vx_print(VX_STR(", write cache"));
  if (has_discard) vx_print(VX_STR(", discard"));
}

const char *vx_main(void) {
  listen = vx_spawn_take("listen");
  if (!listen) fail("no listen channel");
  setup_device();
  if (vx_port_create(0, &port) != VX_OK) fail("port_create");
  vx_port_bind(port, irq, VX_TRIGGER_IRQ, KEY_IRQ, 0);
  vx_print(VX_STR("drv-virtio-blk: "));
  print_size();
  vx_print(VX_STR("\n"));

  bool listen_armed = false;
  for (;;) {
    bool kicked = service_queue();
    accept_client();
    for (uint32_t i = 0; i < MAX_CLIENTS; i++) { // round robin: each session in turn takes slots first
      uint32_t c = (next_client + i) % MAX_CLIENTS;
      if (clients[c].on && !serve_client(c, &kicked)) drop_client(c);
    }
    next_client = (next_client + 1) % MAX_CLIENTS;
    if (kicked) vx_virtq_kick(&q);

    // Arm what is idle; sleep unless a queue filled meanwhile. A session
    // waiting for a slot is not armed: a completion frees one, and that
    // comes as an interrupt.
    bool idle = true, slot_free = free_slot() >= 0;
    for (uint32_t c = 0; c < MAX_CLIENTS; c++) {
      client *k = &clients[c];
      if (!k->on || !slot_free) continue;
      int64_t seen = vx_counter_read(k->end);
      if (!vx_ring_prepare_sleep(&k->ring))
        idle = false;
      else if (!k->armed)
        k->armed = vx_port_bind(port, k->end, VX_TRIGGER_COUNTER_GE, key_of(c, KEY_BELL),
                                (uint64_t)seen + 1) == VX_OK;
    }
    if (!listen_armed) listen_armed = vx_port_bind(port, listen, VX_TRIGGER_READABLE, KEY_LISTEN, 0) == VX_OK;
    if (idle) {
      vx_packet pk[16];
      int64_t n = vx_port_wait(port, VX_INFINITE, 0, pk, 16);
      for (int64_t i = 0; i < n; i++) {
        uint64_t kind = pk[i].key & 0xff;
        uint32_t c = (uint32_t)(pk[i].key >> 8 & 0xff);
        if (pk[i].key == KEY_IRQ) vx_port_bind(port, irq, VX_TRIGGER_IRQ, KEY_IRQ, 0);
        if (pk[i].key == KEY_LISTEN) listen_armed = false;
        if (pk[i].key < 256 || c >= MAX_CLIENTS || pk[i].key != key_of(c, kind)) continue; // a gone session's
        if (kind == KEY_BELL) clients[c].armed = false;
        if (kind == KEY_CLOSED) drop_client(c);
      }
    }
    for (uint32_t c = 0; c < MAX_CLIENTS; c++)
      if (clients[c].on) vx_ring_end_sleep(&clients[c].ring);
  }
}
