// drv-nvme: an NVMe controller (NVM Express base specification 1.4; docs/11
// §10), serving the block class protocol (docs/proto/block.md,
// lib/vx-driver/blockproto.h) on its post, /srv/diskN, for its first namespace.
//
// devmgr starts it, as any PCI driver, with the function's configuration
// space, its memory BARs, a DMA domain, MSI-X interrupts and the post's
// listen end. It serves up to MAX_CLIENTS sessions at once, each reaching its
// own window of the namespace.
//
// Queues. The admin queue is polled. The I/O queues are made at start, as
// many pairs as the controller grants (MAX_QUEUES at most), each with its own
// MSI-X vector while vectors last; a session submits to queue pair
// 1 + (its slot mod their number), so sessions share pairs when there are
// fewer. A queue must be physically contiguous (CAP.CQR), so its depth is
// what the controller allows (CAP.MQES) and what its memory gives the device
// in one run: a page, through today's pass-through DMA domain; more, once an
// IOMMU gives contiguous device addresses (M5 steps 6c, 6d).
//
// Commands. Each command in flight has an id, its index in its queue's
// table, apart from where it sits in the submission queue, and its own PRP
// list (in memory of the driver's that the device can reach). Zero copy: a
// session's client arena is given to the device when the session opens, and
// a transfer names the arena's own pages.
//
// Recovery. A command past its deadline is aborted; one still not done a
// while after that, or a controller that reports a fatal status (CSTS.CFS),
// is a reset: the controller disabled and enabled again, its queues made
// again, and every command that was in flight submitted again, under its
// old id. Reads, writes of the same data, flushes and discards may each be
// done twice, so a client sees a delay, not an error. The command line's
// drv-nvme.reset=N resets the controller after every N completions: how the
// fsdnvme scenario tests that path.
//
// Everything the controller writes (completions, identify data) is read as
// untrusted: ids and indices bounded, sizes checked.
//
// One thread, one port: the interrupts, the listen channel, each session's
// doorbell and going away, and the next deadline.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-pci/pci.c"
#include "../../lib/vx-ring/session.c"
#include "../../lib/vx-driver/blockproto.h"

static constexpr uint32_t MAX_CLIENTS = 8, MAX_QUEUES = 8, MAX_VECTORS = 8;
static constexpr uint16_t MAX_DEPTH = 256, ADMIN_DEPTH = 32;
static constexpr uint32_t MAX_TRANSFER = 128u << 10;      // bytes one request moves, at most
static constexpr uint32_t PRP_SLOT = 512;                 // a command's PRP list (33 entries) and DSM range
static constexpr uint32_t DSM_AT = 384;                   // in its slot: a Dataset Management range
static constexpr vx_duration IO_TIMEOUT = 10'000'000'000; // a command's, before it is aborted
static constexpr vx_duration ABORT_GRACE = 5'000'000'000; // after the abort, before a reset
static constexpr uint32_t ARENA_PAGES = VX_BLOCK_ARENA / 4096;
static_assert((MAX_TRANSFER / 4096 + 1) * 8 <= DSM_AT);

// Registers (§3.1), and what is in them.
enum : uint32_t { CAP = 0x00, VS = 0x08, CC = 0x14, CSTS = 0x1c, AQA = 0x24, ASQ = 0x28, ACQ = 0x30 };
enum : uint32_t { CC_EN = 1, CC_IOSQES = 6u << 16, CC_IOCQES = 4u << 20, CSTS_RDY = 1, CSTS_CFS = 2 };
// Admin (§5) and NVM (NVM command set §3) opcodes.
enum : uint8_t {
  A_DELETE_SQ = 0x00,
  A_CREATE_SQ = 0x01,
  A_DELETE_CQ = 0x04,
  A_CREATE_CQ = 0x05,
  A_IDENTIFY = 0x06,
  A_ABORT = 0x08,
  A_SET_FEATURES = 0x09,
  N_FLUSH = 0x00,
  N_WRITE = 0x01,
  N_READ = 0x02,
  N_DSM = 0x09,
};
static constexpr uint32_t FUA = 1u << 30; // a read's or write's cdw12

// Port keys: below 256 the driver's own; a session's carry its slot and
// generation, so a packet about a session that has gone is never taken for
// the next one in its slot.
enum : uint64_t { KEY_LISTEN = 1, KEY_IRQ = 16, KEY_BELL = 1, KEY_CLOSED = 2 };

typedef struct client {
  bool on, dying; // dying: gone, but with commands still in flight
  uint32_t gen;
  vx_ring ring;
  vx_handle end, memory, mapping; // mapping: the arena's, for the device
  uint64_t pages[ARENA_PAGES];    // the arena's device addresses, by page
  uint64_t first, count;          // the window, in sectors
  bool readonly, armed;
  uint32_t inflight;
} client;

// A command in flight, by its id: enough to submit it again after a reset.
typedef struct cmd {
  bool busy, aborted;
  uint8_t client, opcode;
  uint32_t gen;
  uint64_t user_data;
  int64_t result; // what completing it reports, if the controller says it worked
  uint64_t prp1, prp2;
  uint32_t cdw[6]; // cdw10 to cdw15
  vx_instant deadline;
} cmd;

typedef struct queue {
  uint16_t id, depth, vector;
  volatile uint8_t *sq, *cq;
  uint64_t sq_addr, cq_addr; // device addresses
  uint16_t sq_tail, cq_head;
  bool phase;
  uint32_t inflight;
  uint8_t *prp; // depth slots of PRP_SLOT bytes
  uint64_t prp_pages[MAX_DEPTH * PRP_SLOT / 4096];
  cmd cmds[MAX_DEPTH];
} queue;

static vx_pci_fn fn;
static volatile uint8_t *regs;
static uint64_t regs_size;
static uint32_t doorbell_stride; // bytes
static vx_duration ready_timeout;
static vx_handle dma, port, listen, irqs[MAX_VECTORS];
static uint32_t vectors;
static queue admin, ioq[MAX_QUEUES];
static uint32_t nqueues;
static volatile uint8_t *scratch; // a page for identify data
static uint64_t scratch_addr;
static client clients[MAX_CLIENTS];
static uint32_t nsid, sector_size, max_transfer;
static uint64_t sectors;
static bool has_cache, has_discard;
static uint64_t reset_every, completions, resets;
static bool fault_test;    // drv-nvme.fault=1: see fault_once
static uint64_t die_after; // drv-nvme.die=N: on its first start, exit after N completions (fsdnvmerestart)
static uint32_t next_client;

[[noreturn]] static void fail(const char *what) {
  vx_print(VX_STR("drv-nvme: FAILED: "));
  vx_print(vx_cstr(what));
  vx_print(VX_STR("\n"));
  vx_exits(what);
}

static uint32_t r32(uint32_t at) { return *(volatile uint32_t *)(regs + at); }
static uint64_t r64(uint32_t at) { return r32(at) | (uint64_t)r32(at + 4) << 32; }
static void w32(uint32_t at, uint32_t v) { *(volatile uint32_t *)(regs + at) = v; }
static void w64(uint32_t at, uint64_t v) { w32(at, (uint32_t)v), w32(at + 4, (uint32_t)(v >> 32)); }

static void ring_sq(const queue *q) {
  *(volatile uint32_t *)(regs + 0x1000 + (size_t)(2u * q->id) * doorbell_stride) = q->sq_tail;
}
static void ring_cq(const queue *q) {
  *(volatile uint32_t *)(regs + 0x1000 + (size_t)(2u * q->id + 1) * doorbell_stride) = q->cq_head;
}

static uint64_t key_of(uint32_t c, uint64_t kind) { return (uint64_t)clients[c].gen << 16 | c << 8 | kind; }

// Maps the handle the spawn message calls `name` (`size` bytes), or returns nullptr.
static volatile uint8_t *map_handle(const char *name, uint64_t size) {
  vx_handle h = vx_spawn_take(name);
  uint64_t at = 0;
  if (!h || vx_as_map(vx_self, h, 0, size, VX_MAP_WRITE, &at) != VX_OK) return nullptr;
  vx_handle_close(h);
  return (volatile uint8_t *)at;
}

// Memory the device reaches: `size` bytes, mapped here, its pages' device
// addresses in pages[]. The bytes it gives in one run from its start, in
// *run. It reads and writes it all (queues, PRP lists, identify data), for
// as long as the driver lives.
static uint8_t *dma_memory(uint64_t size, uint64_t *pages, uint64_t *run) {
  vx_handle vmo, mapping;
  uint64_t at = 0;
  if (vx_vmo_create(size, 0, &vmo) != VX_OK || vx_as_map(vx_self, vmo, 0, size, VX_MAP_WRITE, &at) != VX_OK ||
      vx_dma_map(dma, vmo, 0, size, VX_DMA_READ | VX_DMA_WRITE, pages, &mapping) != VX_OK)
    fail("no memory the device can reach");
  vx_handle_close(vmo);
  uint64_t n = 1;
  while (n < size / 4096 && pages[n] == pages[0] + n * 4096) n++;
  if (run) *run = n * 4096;
  return (uint8_t *)at;
}

// A queue pair's memory: as deep as the controller and one contiguous run
// of each queue allow, at most `want`.
static void queue_memory(queue *q, uint16_t id, uint16_t want, uint16_t mqes) {
  static uint64_t pages[MAX_DEPTH * 64 / 4096];
  uint64_t sq_run, cq_run;
  q->id = id;
  q->sq = dma_memory((uint64_t)MAX_DEPTH * 64, pages, &sq_run);
  q->sq_addr = pages[0];
  q->cq = dma_memory((uint64_t)MAX_DEPTH * 16 < 4096 ? 4096 : (uint64_t)MAX_DEPTH * 16, pages, &cq_run);
  q->cq_addr = pages[0];
  uint64_t depth = want;
  if (depth > (uint64_t)mqes + 1) depth = (uint64_t)mqes + 1;
  if (depth > sq_run / 64) depth = sq_run / 64;
  if (depth > cq_run / 16) depth = cq_run / 16;
  if (depth < 2) fail("a queue of fewer than two entries");
  q->depth = (uint16_t)depth;
  q->prp = dma_memory((uint64_t)q->depth * PRP_SLOT < 4096 ? 4096 : (uint64_t)q->depth * PRP_SLOT,
                      q->prp_pages, nullptr);
}

static void queue_reset(queue *q) {
  memset((void *)q->cq, 0, (size_t)q->depth * 16);
  q->sq_tail = q->cq_head = 0;
  q->phase = true;
}

static uint64_t prp_addr(const queue *q, uint16_t cid, uint32_t at) {
  uint32_t off = (uint32_t)cid * PRP_SLOT + at;
  return q->prp_pages[off / 4096] + off % 4096;
}

// Puts command c (its id cid) at the queue's tail; the caller rings.
static void put_sqe(queue *q, uint16_t cid) {
  const cmd *c = &q->cmds[cid];
  volatile uint32_t *e = (volatile uint32_t *)(q->sq + (size_t)q->sq_tail * 64);
  e[0] = c->opcode | (uint32_t)cid << 16;
  e[1] = q->id ? nsid : 0;
  e[2] = e[3] = e[4] = e[5] = 0;
  e[6] = (uint32_t)c->prp1, e[7] = (uint32_t)(c->prp1 >> 32);
  e[8] = (uint32_t)c->prp2, e[9] = (uint32_t)(c->prp2 >> 32);
  for (int i = 0; i < 6; i++) e[10 + i] = c->cdw[i];
  q->sq_tail = (uint16_t)((q->sq_tail + 1) % q->depth);
}

// The next completion on q, if one has come: its id and status.
static bool take_cqe(queue *q, uint16_t *cid, uint16_t *status, uint32_t *result) {
  volatile uint32_t *e = (volatile uint32_t *)(q->cq + (size_t)q->cq_head * 16);
  uint32_t dw3 = e[3];
  if (((dw3 >> 16) & 1) != q->phase) return false;
  *result = e[0];
  *cid = (uint16_t)dw3;
  *status = (uint16_t)(dw3 >> 17 & 0x7fff);
  if (++q->cq_head == q->depth) q->cq_head = 0, q->phase = !q->phase;
  return true;
}

// --- The admin queue: one command at a time, polled ---

static vx_status admin_cmd(uint8_t opcode, uint32_t ns, uint64_t prp1, const uint32_t cdw[6],
                           uint32_t *result) {
  cmd *c = &admin.cmds[0];
  *c = (cmd){.busy = true, .opcode = opcode, .prp1 = prp1};
  for (int i = 0; i < 6; i++) c->cdw[i] = cdw ? cdw[i] : 0;
  volatile uint32_t *e = (volatile uint32_t *)(admin.sq + (size_t)admin.sq_tail * 64);
  put_sqe(&admin, 0);
  e[1] = ns;
  ring_sq(&admin);
  vx_instant deadline = vx_clock_read() + ready_timeout;
  static _Atomic uint32_t never;
  for (;;) {
    uint16_t cid, status;
    uint32_t res;
    if (take_cqe(&admin, &cid, &status, &res)) {
      ring_cq(&admin);
      if (cid != 0) continue; // not ours: a stale completion
      c->busy = false;
      if (result) *result = res;
      return status ? VX_ERR_IO : VX_OK;
    }
    if (r32(CSTS) & CSTS_CFS || vx_clock_read() > deadline) {
      c->busy = false;
      return VX_ERR_TIMED_OUT;
    }
    vx_futex_wait(&never, 0, vx_clock_read() + 100'000); // 0.1 ms
  }
}

// --- Bringing the controller up (§7.6.1), at start and at each reset ---

static bool wait_ready(bool want) {
  vx_instant deadline = vx_clock_read() + ready_timeout;
  static _Atomic uint32_t never;
  while (((r32(CSTS) & CSTS_RDY) != 0) != want) {
    if (vx_clock_read() > deadline || (want && r32(CSTS) & CSTS_CFS)) return false;
    vx_futex_wait(&never, 0, vx_clock_read() + 1'000'000);
  }
  return true;
}

static bool create_io_queue(queue *q) {
  uint32_t cq[6] = {(uint32_t)(q->depth - 1) << 16 | q->id, (uint32_t)q->vector << 16 | 3}; // IEN, PC
  uint32_t sq[6] = {(uint32_t)(q->depth - 1) << 16 | q->id, (uint32_t)q->id << 16 | 1};     // its CQ, PC
  queue_reset(q);
  return admin_cmd(A_CREATE_CQ, 0, q->cq_addr, cq, nullptr) == VX_OK &&
         admin_cmd(A_CREATE_SQ, 0, q->sq_addr, sq, nullptr) == VX_OK;
}

// Disabled, then enabled with the admin queue; the I/O queues made again if
// they were (a reset). False if the controller will not come up.
static bool controller_up(bool again) {
  if (r32(CC) & CC_EN || r32(CSTS) & CSTS_RDY) {
    w32(CC, r32(CC) & ~CC_EN);
    if (!wait_ready(false)) return false;
  }
  queue_reset(&admin);
  w32(AQA, (uint32_t)(admin.depth - 1) << 16 | (uint32_t)(admin.depth - 1));
  w64(ASQ, admin.sq_addr);
  w64(ACQ, admin.cq_addr);
  w32(CC, CC_IOCQES | CC_IOSQES | CC_EN); // NVM command set, 4 KiB pages, round robin
  if (!wait_ready(true)) return false;
  if (!again) return true;
  uint32_t want[6] = {0x07, (nqueues - 1) << 16 | (nqueues - 1)}; // Number of Queues
  if (admin_cmd(A_SET_FEATURES, 0, 0, want, nullptr) != VX_OK) return false;
  for (uint32_t i = 0; i < nqueues; i++)
    if (!create_io_queue(&ioq[i])) return false;
  return true;
}

static void fault_once(void);

static void setup(void) {
  fn.cfg = map_handle("config", 4096);
  dma = vx_spawn_take("dma");
  if (!fn.cfg || !dma) fail("no configuration space or DMA domain");
  static char text[VX_CHANNEL_MAX_BYTES];
  vx_ndb_reader r = {.src = vx_spawn.text, .scratch = text, .scratch_cap = sizeof text};
  vx_ndb_record rec;
  volatile uint8_t *bar[6] = {};
  uint64_t bar_size[6] = {};
  vx_msi msi[MAX_VECTORS] = {};
  while (vx_ndb_next(&r, &rec) == VX_NDB_RECORD) {
    uint64_t n, v;
    if (vx_ndb_get_u64(&rec, "bar", &n) && n < 6 && vx_ndb_get_u64(&rec, "size", &v)) {
      char name[5] = {'b', 'a', 'r', (char)('0' + n), 0};
      bar[n] = map_handle(name, v);
      bar_size[n] = bar[n] ? v : 0;
    } else if (vx_ndb_get_u64(&rec, "msi", &n) && n < MAX_VECTORS && vx_ndb_get_u64(&rec, "address", &v)) {
      uint64_t data = 0;
      vx_ndb_get_u64(&rec, "data", &data);
      msi[n] = (vx_msi){.address = v, .data = (uint32_t)data};
    }
  }
  regs = bar[0], regs_size = bar_size[0];
  if (!regs || regs_size < 0x2000) fail("no register BAR");
  uint32_t table_entries = 0;
  volatile uint32_t *table = vx_pci_msix_table(&fn, bar, bar_size, &table_entries);
  if (!table) fail("no MSI-X");
  for (vectors = 0; vectors < MAX_VECTORS && vectors < table_entries && msi[vectors].address; vectors++) {
    char name[5] = {'m', 's', 'i', (char)('0' + vectors), 0};
    if (!(irqs[vectors] = vx_spawn_take(name))) break;
    vx_pci_msix_set(&fn, table, vectors, msi[vectors]);
  }
  if (!vectors) fail("no MSI");
  vx_pci_enable(&fn);

  // The controller's limits (§3.1.1), read as untrusted.
  uint64_t cap = r64(CAP);
  uint16_t mqes = (uint16_t)cap;
  doorbell_stride = 4u << ((cap >> 32) & 0xf);
  ready_timeout = (vx_duration)(((cap >> 24) & 0xff) + 1) * 500'000'000;
  if (!(cap >> 37 & 1)) fail("no NVM command set");
  if (((cap >> 48) & 0xf) != 0) fail("4 KiB pages are not supported");
  if (0x1000 + (2ull * MAX_QUEUES + 2) * doorbell_stride > regs_size) fail("doorbells outside the BAR");
  queue_memory(&admin, 0, ADMIN_DEPTH, mqes);
  if (!controller_up(false)) fail("the controller does not come up");
  uint64_t one[1];
  scratch = dma_memory(4096, one, nullptr);
  scratch_addr = one[0];

  // Identify the controller (CNS 1), the namespaces it has (CNS 2), the first's size and format (CNS 0).
  uint32_t cns[6] = {1};
  if (admin_cmd(A_IDENTIFY, 0, scratch_addr, cns, nullptr) != VX_OK) fail("identify controller");
  uint8_t mdts = scratch[77];
  has_cache = scratch[525] & 1;
  uint16_t oncs = (uint16_t)(scratch[520] | scratch[521] << 8);
  has_discard = oncs & 4;
  cns[0] = 2;
  if (admin_cmd(A_IDENTIFY, 0, scratch_addr, cns, nullptr) != VX_OK) fail("identify namespaces");
  nsid = *(volatile uint32_t *)scratch;
  if (!nsid || nsid == 0xffff'ffff) fail("no namespace");
  cns[0] = 0;
  if (admin_cmd(A_IDENTIFY, nsid, scratch_addr, cns, nullptr) != VX_OK) fail("identify namespace");
  sectors = *(volatile uint64_t *)scratch;
  uint8_t format = scratch[26] & 0xf;
  uint32_t lbaf = *(volatile uint32_t *)(scratch + 128 + (size_t)4 * format);
  uint32_t lbads = (lbaf >> 16) & 0xff;
  if ((lbaf & 0xffff) != 0) fail("a format with metadata");
  if (lbads < 9 || lbads > 12) fail("a sector size outside 512 to 4096");
  sector_size = 1u << lbads;
  max_transfer = MAX_TRANSFER;
  if (mdts && mdts < 16 && (4096u << mdts) < max_transfer) max_transfer = 4096u << mdts;
  max_transfer -= max_transfer % sector_size;
  if (fault_test) fault_once();

  // The I/O queues: as many pairs as granted, each with its own vector while
  // they last (vector 0 is the admin queue's).
  uint32_t want[6] = {0x07, (MAX_QUEUES - 1) << 16 | (MAX_QUEUES - 1)}, granted = 0;
  if (admin_cmd(A_SET_FEATURES, 0, 0, want, &granted) != VX_OK) fail("set the number of queues");
  nqueues = MAX_QUEUES;
  if ((granted & 0xffff) + 1 < nqueues) nqueues = (granted & 0xffff) + 1;
  if ((granted >> 16) + 1 < nqueues) nqueues = (granted >> 16) + 1;
  for (uint32_t i = 0; i < nqueues; i++) {
    queue_memory(&ioq[i], (uint16_t)(i + 1), MAX_DEPTH, mqes);
    ioq[i].vector = (uint16_t)(vectors > 1 ? 1 + i % (vectors - 1) : 0);
    if (!create_io_queue(&ioq[i])) fail("create the I/O queues");
  }
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

static queue *queue_of(uint32_t c) { return &ioq[c % nqueues]; }

static int32_t free_cid(const queue *q) {
  if (q->inflight + 1 >= q->depth) return -1; // a full queue: the tail would meet the head
  for (uint16_t i = 0; i < q->depth; i++)
    if (!q->cmds[i].busy) return i;
  return -1;
}

// A transfer's PRPs (§4.3): the first page's address with its offset, then
// the second page, or a list of the rest in the command's slot.
static void build_prps(queue *q, uint16_t cid, const client *k, uint32_t arena_off, uint32_t len, cmd *c) {
  uint32_t in_page = arena_off % 4096, page = arena_off / 4096;
  c->prp1 = k->pages[page] + in_page;
  uint32_t first = 4096 - in_page;
  if (len <= first) return;
  uint32_t rest = (len - first + 4095) / 4096;
  if (rest == 1) {
    c->prp2 = k->pages[page + 1];
    return;
  }
  uint64_t *list = (uint64_t *)(q->prp + (size_t)cid * PRP_SLOT);
  for (uint32_t i = 0; i < rest; i++) list[i] = k->pages[page + 1 + i];
  c->prp2 = prp_addr(q, cid, 0);
}

static void issue(queue *q, uint16_t cid, uint32_t c, const cmd *proto) {
  cmd *m = &q->cmds[cid];
  *m = *proto;
  m->busy = true, m->client = (uint8_t)c, m->gen = clients[c].gen;
  m->deadline = vx_clock_read() + IO_TIMEOUT;
  q->inflight++;
  clients[c].inflight++;
  put_sqe(q, cid);
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

// Takes what session c has submitted, as long as its queue has room. False
// if it broke the protocol. *rang: the queues to ring, by bit.
static bool serve_client(uint32_t c, uint32_t *rang) {
  client *k = &clients[c];
  queue *q = queue_of(c);
  while (k->on) {
    int32_t cid = free_cid(q);
    if (cid < 0) return true; // taken again when a command completes
    vx_sqe e;
    vx_status st = vx_ring_consume(&k->ring, &e);
    if (st == VX_ERR_SHOULD_WAIT) return true;
    if (st != VX_OK) return false;
    vx_cqe done = {.user_data = e.user_data};
    cmd m = {.user_data = e.user_data};
    bool now = true; // completed here, without the controller
    switch (e.opcode) {
    case VX_BLOCK_INFO:
      done.result = max_transfer;
      done.aux = sector_size;
      done.aux2 = k->count;
      done.flags = (k->readonly ? VX_BLOCK_INFO_READONLY : 0) | (has_cache ? VX_BLOCK_INFO_CACHE : 0) |
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
      uint64_t lba = k->first + e.target;
      m.opcode = write ? N_WRITE : N_READ;
      m.result = e.len;
      m.cdw[0] = (uint32_t)lba, m.cdw[1] = (uint32_t)(lba >> 32);
      m.cdw[2] = (e.len / sector_size - 1) | (e.opcode == VX_BLOCK_WRITE_FUA ? FUA : 0);
      build_prps(q, (uint16_t)cid, k, e.arena_off, e.len, &m);
      issue(q, (uint16_t)cid, c, &m);
      now = false;
      break;
    }
    case VX_BLOCK_FLUSH:
      if (k->readonly || !has_cache) break; // nothing of this session's to make durable
      m.opcode = N_FLUSH;
      issue(q, (uint16_t)cid, c, &m);
      now = false;
      break;
    case VX_BLOCK_DISCARD: {
      if (k->readonly) {
        done.result = VX_ERR_ACCESS;
        break;
      }
      if (e.target >= k->count || e.offset > k->count - e.target) {
        done.result = VX_ERR_RANGE;
        break;
      }
      if (!has_discard || !e.offset) break; // a hint the controller cannot take: done
      // At most one range's worth (2^32 - 1 sectors); a discard is a hint, so the rest may go undone.
      uint64_t count = e.offset < 0xffff'ffffu ? e.offset : 0xffff'ffffu, lba = k->first + e.target;
      volatile uint32_t *range = (volatile uint32_t *)(q->prp + (size_t)cid * PRP_SLOT + DSM_AT);
      range[0] = 0, range[1] = (uint32_t)count, range[2] = (uint32_t)lba, range[3] = (uint32_t)(lba >> 32);
      m.opcode = N_DSM;
      m.prp1 = prp_addr(q, (uint16_t)cid, DSM_AT);
      m.cdw[0] = 0, m.cdw[1] = 4; // one range; deallocate
      issue(q, (uint16_t)cid, c, &m);
      now = false;
      break;
    }
    default: done.result = VX_ERR_INVALID; break;
    }
    if (!now) {
      *rang |= 1u << (q->id - 1);
      continue;
    }
    if (!complete(c, done)) return false;
  }
  return true;
}

// Commands the controller has finished, on queue q: each completed to its session.
static void service_queue(queue *q) {
  uint16_t cid, status;
  uint32_t res;
  bool took = false;
  while (take_cqe(q, &cid, &status, &res)) {
    took = true;
    if (cid >= q->depth || !q->cmds[cid].busy) continue; // not one we submitted
    cmd *m = &q->cmds[cid];
    uint32_t c = m->client;
    client *k = &clients[c];
    int64_t result = status ? VX_ERR_IO : m->result;
    uint64_t user_data = m->user_data;
    bool same = k->gen == m->gen;
    *m = (cmd){};
    q->inflight--;
    completions++;
    if (!same) continue;
    k->inflight--;
    if (k->on && !complete(c, (vx_cqe){.user_data = user_data, .result = result})) drop_client(c);
    if (k->dying && !k->inflight) release_client(c);
  }
  if (took) ring_cq(q);
}

// The controller reset (§7.3.2), and every command that was in flight
// submitted again: a client sees a delay, not an error.
static void reset_controller(const char *why) {
  resets++;
  vx_print(VX_STR("drv-nvme: reset: "));
  vx_print(vx_cstr(why));
  vx_print(VX_STR("\n"));
  for (int tries = 0;; tries++) {
    if (controller_up(true)) break;
    if (tries == 3) fail("the controller does not come back after a reset");
  }
  vx_instant now = vx_clock_read();
  for (uint32_t i = 0; i < nqueues; i++) {
    queue *q = &ioq[i];
    for (uint16_t cid = 0; cid < q->depth; cid++)
      if (q->cmds[cid].busy) {
        q->cmds[cid].aborted = false;
        q->cmds[cid].deadline = now + IO_TIMEOUT;
        put_sqe(q, cid);
      }
    ring_sq(q);
  }
}

// Commands past their deadlines: aborted (§5.1), and if that does not settle
// them, the controller reset. Returns when to look again.
static vx_instant check_deadlines(void) {
  vx_instant now = vx_clock_read(), next = VX_INFINITE;
  if (r32(CSTS) & CSTS_CFS) {
    reset_controller("the controller reports a fatal status");
    now = vx_clock_read();
  }
  for (uint32_t i = 0; i < nqueues; i++) {
    queue *q = &ioq[i];
    for (uint16_t cid = 0; cid < q->depth; cid++) {
      cmd *m = &q->cmds[cid];
      if (!m->busy) continue;
      if (m->deadline <= now && !m->aborted) {
        uint32_t which[6] = {(uint32_t)cid << 16 | q->id};
        admin_cmd(A_ABORT, 0, 0, which, nullptr); // its completion, if it comes, says how it ended
        m->aborted = true;
        m->deadline = now + ABORT_GRACE;
      } else if (m->deadline <= now) {
        reset_controller("a command not done after it was aborted");
        return vx_clock_read();
      }
      if (m->deadline < next) next = m->deadline;
    }
  }
  return next;
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
    *k = (client){.gen = gen, .first = req.first, .count = count, .readonly = req.flags & VX_BLOCK_READONLY};
    if (vx_session_accept_keep(listen, &req.h, &VX_BLOCK_PARAMS, &k->ring, &k->end, &k->memory) != VX_OK) {
      *k = (client){.gen = gen};
      continue;
    }
    // The client arena, to the device.
    if (vx_dma_map(dma, k->memory, k->ring.h.client_arena_offset, VX_BLOCK_ARENA, VX_DMA_READ | VX_DMA_WRITE,
                   k->pages, &k->mapping) != VX_OK) {
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

// drv-nvme.fault=1: an Identify aimed where the domain maps nothing, to see
// the IOMMU stop the controller's write, count it, and say so (nvmefault).
static void fault_once(void) {
  vx_handle p;
  if (vx_port_create(0, &p) != VX_OK) fail("port_create");
  bool bound = vx_port_bind(p, dma, VX_TRIGGER_DMA_FAULT, 1, 0) == VX_OK;
  uint32_t cns[6] = {1};
  vx_status st = admin_cmd(A_IDENTIFY, 0, 1ull << 38, cns, nullptr);
  vx_packet pk = {};
  bool told = bound && vx_port_wait(p, vx_clock_read() + 2'000'000'000, 0, &pk, 1) == 1;
  vx_handle_close(p);
  vx_print(VX_STR("drv-nvme: a DMA fault, as asked: the command "));
  vx_print(st == VX_OK ? VX_STR("completed") : VX_STR("failed"));
  vx_print(told ? VX_STR(", the fault reported, ") : VX_STR(", no fault reported, "));
  vx_print_u64((uint64_t)vx_dma_domain_op(dma, VX_DMA_FAULTS));
  vx_print(VX_STR(" counted\n"));
}

// drv-nvme.reset=N on the kernel command line: a reset after every N completions.
static void read_options(void) {
  vx_str c = vx_spawn.cmdline;
  static const char die[] = "drv-nvme.die=";
  vx_ndb_record rec;
  uint64_t start = 1;
  if (vx_spawn_record("start", &rec)) vx_ndb_get_u64(&rec, "start", &start);
  for (size_t i = 0; start == 1 && i + sizeof die - 1 <= c.len; i++) {
    if ((i && c.ptr[i - 1] != ' ') || memcmp(c.ptr + i, die, sizeof die - 1) != 0) continue;
    for (size_t at = i + sizeof die - 1; at < c.len && c.ptr[at] >= '0' && c.ptr[at] <= '9'; at++)
      die_after = die_after * 10 + (uint64_t)(c.ptr[at] - '0');
  }
  static const char fault[] = "drv-nvme.fault=1";
  for (size_t i = 0; i + sizeof fault - 1 <= c.len; i++)
    if ((!i || c.ptr[i - 1] == ' ') && memcmp(c.ptr + i, fault, sizeof fault - 1) == 0) fault_test = true;
  static const char key[] = "drv-nvme.reset=";
  for (size_t i = 0; i + sizeof key - 1 <= c.len; i++) {
    if ((i && c.ptr[i - 1] != ' ') || memcmp(c.ptr + i, key, sizeof key - 1) != 0) continue;
    uint64_t n = 0;
    for (size_t at = i + sizeof key - 1; at < c.len && c.ptr[at] >= '0' && c.ptr[at] <= '9'; at++)
      n = n * 10 + (uint64_t)(c.ptr[at] - '0');
    reset_every = n;
  }
}

static void print_size(void) {
  vx_print_u64(sectors * sector_size >> 20);
  vx_print(VX_STR(" MiB, "));
  vx_print_u64(sector_size);
  vx_print(VX_STR("-byte sectors, "));
  vx_print_u64(nqueues);
  vx_print(VX_STR(" queues of "));
  vx_print_u64(ioq[0].depth);
  vx_print(VX_STR(", "));
  vx_print_u64(vectors);
  vx_print(VX_STR(" vectors"));
  if (has_cache) vx_print(VX_STR(", write cache"));
  if (has_discard) vx_print(VX_STR(", discard"));
  if (reset_every) {
    vx_print(VX_STR(", a reset every "));
    vx_print_u64(reset_every);
  }
}

const char *vx_main(void) {
  listen = vx_spawn_take("listen");
  if (!listen) fail("no listen channel");
  read_options();
  setup();
  if (vx_port_create(0, &port) != VX_OK) fail("port_create");
  for (uint32_t v = 0; v < vectors; v++) vx_port_bind(port, irqs[v], VX_TRIGGER_IRQ, KEY_IRQ + v, 0);
  vx_print(VX_STR("drv-nvme: "));
  print_size();
  vx_print(VX_STR("\n"));

  bool listen_armed = false;
  uint64_t next_reset = reset_every;
  for (;;) {
    for (uint32_t i = 0; i < nqueues; i++) service_queue(&ioq[i]);
    if (die_after && completions >= die_after) { // as a crash would: with commands in flight
      vx_print(VX_STR("drv-nvme: exiting, as asked (drv-nvme.die)\n"));
      vx_exits("drv-nvme.die");
    }
    if (reset_every && completions >= next_reset) {
      next_reset = completions + reset_every;
      reset_controller("drv-nvme.reset");
    }
    vx_instant deadline = check_deadlines();
    accept_client();
    uint32_t rang = 0;
    for (uint32_t i = 0; i < MAX_CLIENTS; i++) { // round robin: each session in turn takes ids first
      uint32_t c = (next_client + i) % MAX_CLIENTS;
      if (clients[c].on && !serve_client(c, &rang)) drop_client(c);
    }
    next_client = (next_client + 1) % MAX_CLIENTS;
    for (uint32_t i = 0; i < nqueues; i++)
      if (rang & 1u << i) ring_sq(&ioq[i]);

    // Arm what is idle; sleep unless a ring filled meanwhile. A session
    // whose queue is full is not armed: a completion frees an id, and that
    // comes as an interrupt.
    bool idle = true;
    for (uint32_t c = 0; c < MAX_CLIENTS; c++) {
      client *k = &clients[c];
      if (!k->on || free_cid(queue_of(c)) < 0) continue;
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
      int64_t n = vx_port_wait(port, deadline, 0, pk, 16);
      for (int64_t i = 0; i < n; i++) {
        uint64_t kind = pk[i].key & 0xff;
        uint32_t c = (uint32_t)(pk[i].key >> 8 & 0xff);
        if (pk[i].key >= KEY_IRQ && pk[i].key < KEY_IRQ + vectors)
          vx_port_bind(port, irqs[pk[i].key - KEY_IRQ], VX_TRIGGER_IRQ, pk[i].key, 0);
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
