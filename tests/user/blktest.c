// blktest: the block class's conformance test (docs/proto/block.md §7), run
// as a service in the block scenario (tests/qemu/block.ndb) against the
// scenario's second disk, /srv/disk1, which ./build makes fresh for each run:
// zeros, but for a signature in sector 0 and a GPT of two partitions, which
// partd serves on /srv/disk1.esp and /srv/disk1.vectra.
//
// It checks INFO; reads and writes across sector and page boundaries, and as
// large as the driver takes; FLUSH, WRITE_FUA and DISCARD; every refusal of
// §2 and of CONNECT; a second session on a read-only window; many requests
// in flight at once; partd's partitions as windows. Then it kills the disk drivers, through the task tree
// its manifest gives it, and reads back through a new session what it wrote
// before. Each check prints a line only when it fails; the last line counts
// them.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-ring/session.c"
#include "../../lib/vx-driver/blockproto.h"

static constexpr char SIGNATURE[] = "VectraOS block test disk";
static constexpr uint32_t SPAN = 3 * 512; // three sectors, across a page boundary in the arena
// Where the whole-disk checks write: past the test partitions, which end at
// sector 83967 (./build's test_disk), and before the backup GPT.
static constexpr uint64_t BASE = 100'000;

typedef struct session {
  vx_ring ring;
  vx_handle end, port; // a port of its own: nothing left from an earlier session wakes it
  uint8_t *arena;
} session;

static vx_handle connector;
static uint32_t checks, failures;

static void check_at(bool ok, const char *what, int line) {
  checks++;
  if (ok) return;
  failures++;
  vx_print(VX_STR("blktest: FAILED line "));
  vx_print_u64((uint64_t)line);
  vx_print(VX_STR(": "));
  vx_print(vx_cstr(what));
  vx_print(VX_STR("\n"));
}
#define CHECK(x) check_at((x), #x, __LINE__)

[[noreturn]] static void fail(const char *what) {
  vx_print(VX_STR("blktest: FAILED: "));
  vx_print(vx_cstr(what));
  vx_print(VX_STR("\n"));
  vx_exits(what);
}

// A session on the window [first, first + count), or why it was refused.
static vx_status open_window(session *s, uint64_t first, uint64_t count, uint32_t flags) {
  vx_block_connect req = {.h = {.ordinal = VX_BLOCK_CONNECT}, .first = first, .count = count, .flags = flags};
  *s = (session){};
  vx_status st = vx_session_dial_with(connector, &req, sizeof req, &VX_BLOCK_PARAMS, &s->ring, &s->end);
  if (st == VX_OK && vx_port_create(0, &s->port) != VX_OK) fail("port_create");
  if (st == VX_OK) {
    uint64_t size;
    s->arena = vx_ring_arena(&s->ring, &size);
  }
  return st;
}

static void close_session(session *s) {
  vx_handle_close(s->end);
  vx_handle_close(s->port);
  vx_session_unmap(&s->ring);
  *s = (session){};
}

static void submit(session *s, vx_sqe e) {
  vx_sqe *slot = vx_ring_produce_slot(&s->ring);
  if (!slot) fail("the submission queue is full");
  *slot = e;
  if (vx_ring_produce(&s->ring)) vx_ring_notify(s->end);
}

// The next completion, waiting up to 5 s for it. False if none came, or the
// session ended (*closed).
static bool next(session *s, vx_cqe *c, bool *closed) {
  vx_instant deadline = vx_clock_read() + 5'000'000'000;
  if (closed) *closed = false;
  for (;;) {
    if (vx_ring_consume(&s->ring, c) == VX_OK) return true;
    int64_t seen = vx_counter_read(s->end);
    if (vx_ring_prepare_sleep(&s->ring)) {
      vx_packet pk = {};
      vx_port_bind(s->port, s->end, VX_TRIGGER_COUNTER_GE, 1, (uint64_t)seen + 1);
      vx_port_bind(s->port, s->end, VX_TRIGGER_PEER_CLOSED, 2, 0);
      int64_t n = vx_port_wait(s->port, deadline, 0, &pk, 1);
      vx_ring_end_sleep(&s->ring);
      if (n != 1) return false;
      if (pk.key == 2) {
        if (vx_ring_consume(&s->ring, c) == VX_OK) return true;
        if (closed) *closed = true;
        return false;
      }
    } else {
      vx_ring_end_sleep(&s->ring);
    }
  }
}

// One request, and its completion's result (or what went wrong).
static vx_cqe call(session *s, vx_sqe e) {
  static uint64_t tag;
  e.user_data = ++tag;
  submit(s, e);
  vx_cqe c = {};
  if (!next(s, &c, nullptr)) return (vx_cqe){.result = VX_ERR_TIMED_OUT};
  if (c.user_data != e.user_data) return (vx_cqe){.result = VX_ERR_BAD_STATE};
  return c;
}

static int64_t xfer(session *s, uint16_t op, uint64_t sector, uint32_t arena_off, uint32_t len) {
  return call(s,
              (vx_sqe){
                  .opcode = op, .flags = VX_SQE_DREF, .target = sector, .arena_off = arena_off, .len = len})
      .result;
}

static void fill(uint8_t *p, uint32_t len, uint8_t seed) {
  for (uint32_t i = 0; i < len; i++) p[i] = (uint8_t)(seed + i * 7 + (i >> 9));
}

static bool same(const uint8_t *a, const uint8_t *b, uint32_t len) {
  for (uint32_t i = 0; i < len; i++)
    if (a[i] != b[i]) return false;
  return true;
}

// The partition partd serves on /srv/POST: `sectors` long, at `first` on the
// disk, beginning with `marker`. `whole` is a session on the whole disk.
static void check_partition(const char *post, uint64_t first, uint64_t sectors, const char *marker,
                            session *whole) {
  char name[32] = "srv:";
  memcpy(name + 4, post, vx_cstr(post).len + 1);
  vx_handle keep = connector;
  connector = vx_spawn_take(name);
  CHECK(connector != VX_HANDLE_NONE);
  session p = {};
  CHECK(connector && open_window(&p, 0, 0, 0) == VX_OK);
  if (!p.end) {
    connector = keep;
    return;
  }
  vx_cqe info = call(&p, (vx_sqe){.opcode = VX_BLOCK_INFO});
  CHECK(info.aux2 == sectors);
  size_t m = vx_cstr(marker).len;
  CHECK(xfer(&p, VX_BLOCK_READ, 0, 0, 512) == 512 && same(p.arena, (const uint8_t *)marker, (uint32_t)m));
  fill(p.arena, 1024, 77);
  CHECK(xfer(&p, VX_BLOCK_WRITE, sectors - 2, 0, 1024) == 1024); // the partition's last two sectors
  CHECK(xfer(whole, VX_BLOCK_READ, first + sectors - 2, 0, 1024) == 1024 &&
        same(whole->arena, p.arena, 1024));
  CHECK(xfer(&p, VX_BLOCK_READ, sectors - 1, 0, 1024) == VX_ERR_RANGE); // past the partition's end
  close_session(&p);
  // A window inside it, counted from its start; one past its end refused.
  CHECK(open_window(&p, 1, 4, VX_BLOCK_READONLY) == VX_OK);
  vx_cqe winfo = call(&p, (vx_sqe){.opcode = VX_BLOCK_INFO});
  CHECK(winfo.aux2 == 4 && (winfo.flags & VX_BLOCK_INFO_READONLY));
  CHECK(xfer(&p, VX_BLOCK_WRITE, 0, 0, 512) == VX_ERR_ACCESS);
  close_session(&p);
  CHECK(open_window(&p, sectors, 0, 0) == VX_ERR_RANGE);
  CHECK(open_window(&p, sectors - 1, 2, 0) == VX_ERR_RANGE);
  vx_handle_close(connector);
  connector = keep;
}

// Kills every disk driver (the boot disk's too: nothing here uses it), and
// waits for this session to end.
static void kill_drivers(session *s) {
  vx_handle tasks = vx_spawn_take("tasks");
  if (!tasks) fail("no task tree");
  vx_task_summary info = {};
  uint64_t id = 0;
  int killed = 0;
  while (vx_task_info_of(tasks, id, VX_TASK_NEXT, &info) == VX_OK) {
    id = info.id;
    if (memcmp(info.name, "drv-virtio-blk", 15) == 0 && vx_task_kill_id(tasks, id, VX_STR("killed")) == VX_OK)
      killed++;
  }
  if (!killed) fail("no drv-virtio-blk task");
  vx_cqe c;
  bool closed = false;
  for (int i = 0; i < 4 && !closed; i++) next(s, &c, &closed);
  CHECK(closed);
  close_session(s);
}

const char *vx_main(void) {
  connector = vx_spawn_take("srv:disk1");
  if (!connector) fail("no connector to /srv/disk1");

  // The whole disk.
  session s;
  if (open_window(&s, 0, 0, 0) != VX_OK) fail("no session on /srv/disk1");
  vx_cqe info = call(&s, (vx_sqe){.opcode = VX_BLOCK_INFO});
  uint32_t sector = info.aux, max = (uint32_t)info.result;
  uint64_t sectors = info.aux2;
  CHECK(sector == 512 && sectors == 64ull * 2048 && max >= 64u << 10 && max <= VX_BLOCK_ARENA);
  CHECK(!(info.flags & VX_BLOCK_INFO_READONLY));
  vx_print(VX_STR("blktest: "));
  vx_print_u64(sectors);
  vx_print(VX_STR(" sectors of "));
  vx_print_u64(sector);
  vx_print(VX_STR(" bytes, up to "));
  vx_print_u64(max >> 10);
  vx_print(VX_STR(" KiB a transfer\n"));

  CHECK(xfer(&s, VX_BLOCK_READ, 0, 0, 512) == 512 &&
        same(s.arena, (const uint8_t *)SIGNATURE, sizeof SIGNATURE - 1));

  // Across a page boundary in the arena, and three sectors on the disk.
  static uint8_t want[128 << 10];
  fill(want, SPAN, 1);
  memcpy(s.arena + 3584, want, SPAN);
  CHECK(xfer(&s, VX_BLOCK_WRITE, BASE + 8, 3584, SPAN) == SPAN);
  memset(s.arena + 65536, 0, SPAN);
  CHECK(xfer(&s, VX_BLOCK_READ, BASE + 8, 65536, SPAN) == SPAN && same(s.arena + 65536, want, SPAN));

  // As large as the driver takes, at the end of the arena.
  uint32_t big = max > sizeof want ? (uint32_t)sizeof want : max, at = (uint32_t)(VX_BLOCK_ARENA - big);
  fill(want, big, 9);
  memcpy(s.arena + at, want, big);
  CHECK(xfer(&s, VX_BLOCK_WRITE_FUA, BASE + 1000, at, big) == big);
  memset(s.arena, 0, big);
  CHECK(xfer(&s, VX_BLOCK_READ, BASE + 1000, 0, big) == big && same(s.arena, want, big));
  CHECK(call(&s, (vx_sqe){.opcode = VX_BLOCK_FLUSH}).result == 0);
  CHECK(call(&s, (vx_sqe){.opcode = VX_BLOCK_DISCARD, .target = BASE + 4096, .offset = 2048}).result == 0);
  // The last sector of the disk (the backup GPT's header), written back as it was.
  CHECK(xfer(&s, VX_BLOCK_READ, sectors - 1, 0, 512) == 512 &&
        xfer(&s, VX_BLOCK_WRITE, sectors - 1, 0, 512) == 512);

  // Refusals (§2), none of which reaches the device.
  CHECK(xfer(&s, VX_BLOCK_READ, 0, 0, 0) == VX_ERR_INVALID);            // no length
  CHECK(xfer(&s, VX_BLOCK_READ, 0, 0, 100) == VX_ERR_INVALID);          // part of a sector
  CHECK(xfer(&s, VX_BLOCK_READ, 0, 100, 512) == VX_ERR_INVALID);        // misaligned in the arena
  CHECK(xfer(&s, VX_BLOCK_READ, 0, 0, max + 512) == VX_ERR_INVALID);    // too large
  CHECK(xfer(&s, VX_BLOCK_READ, sectors, 0, 512) == VX_ERR_RANGE);      // past the disk
  CHECK(xfer(&s, VX_BLOCK_READ, sectors - 1, 0, 1024) == VX_ERR_RANGE); // running past it
  CHECK(xfer(&s, VX_BLOCK_READ, 0, (uint32_t)VX_BLOCK_ARENA - 512, 1024) == VX_ERR_RANGE); // past the arena
  CHECK(call(&s, (vx_sqe){.opcode = VX_BLOCK_READ, .target = 0, .len = 512}).result ==
        VX_ERR_INVALID); // no DREF
  CHECK(call(&s, (vx_sqe){.opcode = 99}).result == VX_ERR_INVALID);
  CHECK(call(&s, (vx_sqe){.opcode = VX_BLOCK_DISCARD, .target = sectors - 1, .offset = 2}).result ==
        VX_ERR_RANGE);

  // Many requests in flight at once: every one completes, once.
  static bool seen[100];
  for (uint32_t i = 0; i < 100; i++)
    submit(&s, (vx_sqe){.opcode = VX_BLOCK_READ,
                        .flags = VX_SQE_DREF,
                        .user_data = 10'000 + i,
                        .target = i,
                        .arena_off = i * 4096,
                        .len = 4096});
  uint32_t got = 0;
  vx_cqe c;
  while (got < 100 && next(&s, &c, nullptr))
    if (c.user_data >= 10'000 && c.user_data < 10'100 && !seen[c.user_data - 10'000] && c.result == 4096)
      seen[c.user_data - 10'000] = true, got++;
  CHECK(got == 100);

  // A read-only window: sectors 8 to 23, as a second session at once.
  session w;
  CHECK(open_window(&w, BASE + 8, 16, VX_BLOCK_READONLY) == VX_OK);
  vx_cqe winfo = call(&w, (vx_sqe){.opcode = VX_BLOCK_INFO});
  CHECK(winfo.aux2 == 16 && (winfo.flags & VX_BLOCK_INFO_READONLY));
  fill(want, SPAN, 1);
  CHECK(xfer(&w, VX_BLOCK_READ, 0, 0, SPAN) == SPAN && same(w.arena, want, SPAN)); // disk sector 8
  CHECK(xfer(&w, VX_BLOCK_WRITE, 0, 0, 512) == VX_ERR_ACCESS);
  CHECK(xfer(&w, VX_BLOCK_READ, 16, 0, 512) == VX_ERR_RANGE);
  CHECK(xfer(&w, VX_BLOCK_READ, 15, 0, 1024) == VX_ERR_RANGE);
  CHECK(call(&w, (vx_sqe){.opcode = VX_BLOCK_DISCARD, .target = 0, .offset = 1}).result == VX_ERR_ACCESS);
  close_session(&w);

  // Partitions, through partd: each a window, its first sector the line
  // ./build wrote there; writes land at the partition's offset on the disk.
  check_partition("disk1.esp", 2048, 16384, "partition esp\n", &s);
  check_partition("disk1.vectra", 18432, 65536, "partition vectra\n", &s);
  vx_handle none = vx_spawn_take("srv:disk1.none");
  session y;
  vx_handle keep = connector;
  connector = none;
  CHECK(none && open_window(&y, 0, 0, 0) == VX_ERR_NOT_FOUND); // a partition the disk does not have
  connector = keep;

  // CONNECT's refusals.
  session x;
  CHECK(open_window(&x, sectors, 0, 0) == VX_ERR_RANGE);
  CHECK(open_window(&x, sectors - 8, 16, 0) == VX_ERR_RANGE);
  CHECK(open_window(&x, 0, 0, 2) == VX_ERR_INVALID);
  vx_print(VX_STR("blktest: ok\n"));

  // The drivers killed, then restarted by devmgr: what was written is there.
  kill_drivers(&s);
  vx_print(VX_STR("blktest: stopped the drivers; the session ended\n"));
  vx_status st = VX_ERR_TIMED_OUT;
  for (int i = 0; i < 100 && st != VX_OK; i++) { // until the new driver serves the post
    st = open_window(&s, 0, 0, 0);
    if (st != VX_OK) {
      static const _Atomic uint32_t never;
      vx_futex_wait(&never, 0, vx_clock_read() + 50'000'000);
    }
  }
  CHECK(st == VX_OK);
  if (st == VX_OK) {
    fill(want, big, 9);
    CHECK(xfer(&s, VX_BLOCK_READ, BASE + 1000, 0, big) == big && same(s.arena, want, big));
    close_session(&s);
  }
  vx_print(VX_STR("blktest: "));
  vx_print_u64(checks);
  vx_print(VX_STR(" checks, "));
  vx_print_u64(failures);
  vx_print(VX_STR(" failed\n"));
  return failures ? "failed" : nullptr;
}
