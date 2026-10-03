// partd: partitions as windows (docs/proto/block.md §6, docs/11 §10). It
// holds a connector to a whole disk (its manifest's connect=, as
// "srv:DISK"), reads the disk's GPT through a read-only session of its own
// (lib/vx-gpt), and serves each partition its manifest names on a post of
// its own, claimed from svcd:
//
//   service=partd program=/boot/bin/partd console
//   connect=disk0
//   claim=disk0.esp
//   part=disk0.esp type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
//   claim=disk0.system
//   part=disk0.system type=7C6D3E1A-2B4F-4E0A-9C1D-56F2A8B90E35
//
// A part= record matches the first GPT entry with that type GUID, or with
// that name (name=NAME). A CONNECT on a partition's post is answered with a
// session the driver opens on the window narrowed to the partition: partd
// passes the driver's reply on as it is and keeps nothing of it, so the
// session is between the client and the driver, and reaches only the
// partition. A post whose partition is not on the disk refuses every CONNECT
// (NOT_FOUND). The table is read once; a disk repartitioned under a running
// partd is not seen until it starts again.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-ring/session.c"
#include "../../lib/vx-driver/blockproto.h"
#include "../../lib/vx-gpt/gpt.c"

static constexpr uint32_t MAX_PARTS = 8;

typedef struct served {
  vx_str post;      // in the spawn message
  vx_handle listen; // the claimed post's server end
  bool found;
  uint64_t first, count; // the partition's window, in the disk's sectors
  bool armed;
} served;

static served parts[MAX_PARTS];
static uint32_t nparts;
static vx_handle disk, port;
static vx_str disk_name;

[[noreturn]] static void fail(const char *what) {
  vx_print(VX_STR("partd: FAILED: "));
  vx_print(vx_cstr(what));
  vx_print(VX_STR("\n"));
  vx_exits(what);
}

// --- Reading the table, through a session of partd's own ---

typedef struct reader {
  vx_ring ring;
  vx_handle end, port;
  uint8_t *arena;
  uint32_t max; // bytes a transfer moves, at most
} reader;

static bool wait_one(reader *r, vx_cqe *c) {
  vx_instant deadline = vx_clock_read() + 5'000'000'000;
  for (;;) {
    if (vx_ring_consume(&r->ring, c) == VX_OK) return true;
    int64_t seen = vx_counter_read(r->end);
    if (vx_ring_prepare_sleep(&r->ring)) {
      vx_packet pk = {};
      vx_port_bind(r->port, r->end, VX_TRIGGER_COUNTER_GE, 1, (uint64_t)seen + 1);
      int64_t n = vx_port_wait(r->port, deadline, 0, &pk, 1);
      vx_ring_end_sleep(&r->ring);
      if (n != 1) return false;
    } else {
      vx_ring_end_sleep(&r->ring);
    }
  }
}

static bool call(reader *r, vx_sqe e, vx_cqe *c) {
  vx_sqe *slot = vx_ring_produce_slot(&r->ring);
  if (!slot) return false;
  *slot = e;
  if (vx_ring_produce(&r->ring)) vx_ring_notify(r->end);
  return wait_one(r, c);
}

static bool read_sectors(void *ctx, uint64_t lba, uint32_t count, uint8_t *buf) {
  reader *r = ctx;
  static constexpr uint32_t sector = 512; // read_table takes no other size yet
  for (uint32_t done = 0; done < count;) {
    uint32_t n = count - done, room = r->max / sector;
    if (n > room) n = room;
    vx_cqe c;
    if (!call(
            r,
            (vx_sqe){.opcode = VX_BLOCK_READ, .flags = VX_SQE_DREF, .target = lba + done, .len = n * sector},
            &c) ||
        c.result != (int64_t)n * sector)
      return false;
    memcpy(buf + (size_t)done * sector, r->arena, (size_t)n * sector);
    done += n;
  }
  return true;
}

// The table, or why not.
static vx_status read_table(vx_gpt *g) {
  reader r = {};
  vx_block_connect req = {.h = {.ordinal = VX_BLOCK_CONNECT}, .flags = VX_BLOCK_READONLY};
  vx_status st = vx_session_dial_with(disk, &req, sizeof req, &VX_BLOCK_PARAMS, &r.ring, &r.end);
  if (st != VX_OK) return st;
  if (vx_port_create(0, &r.port) != VX_OK) fail("port_create");
  uint64_t size;
  r.arena = vx_ring_arena(&r.ring, &size);
  vx_cqe info;
  st = call(&r, (vx_sqe){.opcode = VX_BLOCK_INFO}, &info) ? VX_OK : VX_ERR_TIMED_OUT;
  if (st == VX_OK && (info.aux != 512 || info.result < 512))
    st = VX_ERR_UNSUPPORTED; // 4 KiB sectors: when a disk has them
  if (st == VX_OK) {
    r.max = (uint32_t)(info.result > (int64_t)VX_BLOCK_ARENA ? VX_BLOCK_ARENA : info.result);
    st = vx_gpt_read(g, info.aux, info.aux2, read_sectors, &r);
  }
  vx_handle_close(r.port);
  vx_handle_close(r.end);
  vx_session_unmap(&r.ring);
  return st;
}

// --- The manifest ---

static vx_handle take_prefixed(const char *prefix, vx_str name) {
  char want[64];
  size_t p = vx_cstr(prefix).len;
  if (p + name.len >= sizeof want) return VX_HANDLE_NONE;
  memcpy(want, prefix, p);
  memcpy(want + p, name.ptr, name.len);
  want[p + name.len] = 0;
  return vx_spawn_take(want);
}

// The disk's connector: the one handle named srv:NAME.
static void find_disk(void) {
  for (uint32_t i = 0; i < vx_spawn.handle_count; i++) {
    vx_str n = vx_spawn.handle_names[i];
    if (n.len > 4 && memcmp(n.ptr, "srv:", 4) == 0 && vx_spawn.handles[i]) {
      disk_name = (vx_str){n.ptr + 4, n.len - 4};
      disk = vx_spawn.handles[i];
      vx_spawn.handles[i] = VX_HANDLE_NONE;
      return;
    }
  }
  fail("no connector to a disk (connect=)");
}

static bool matches(const vx_gpt_part *p, const vx_ndb_record *rec) {
  vx_str type = vx_ndb_get(rec, "type"), name = vx_ndb_get(rec, "name");
  if (type.len) {
    uint8_t guid[16];
    return vx_gpt_guid(type.ptr, type.len, guid) && memcmp(guid, p->type, 16) == 0;
  }
  return name.len && vx_cstr(p->name).len == name.len && memcmp(p->name, name.ptr, name.len) == 0;
}

static void say_part(const served *s, const vx_gpt_part *p) {
  vx_print(VX_STR("partd: /srv/"));
  vx_print(s->post);
  if (!p) {
    vx_print(VX_STR(": no such partition on the disk\n"));
    return;
  }
  vx_print(VX_STR(" is sectors "));
  vx_print_u64(p->first);
  vx_print(VX_STR("-"));
  vx_print_u64(p->last);
  vx_print(VX_STR(" ("));
  vx_print(vx_cstr(p->name));
  vx_print(VX_STR(")\n"));
}

static void load_manifest(const vx_gpt *g) {
  static char scratch[VX_CHANNEL_MAX_BYTES];
  vx_ndb_reader r = {.src = vx_spawn.text, .scratch = scratch, .scratch_cap = sizeof scratch};
  vx_ndb_record rec;
  while (vx_ndb_next(&r, &rec) == VX_NDB_RECORD) {
    if (!vx_ndb_has(&rec, "part")) continue;
    if (nparts == MAX_PARTS) fail("more part= records than partd serves");
    served *s = &parts[nparts];
    *s = (served){.post = vx_ndb_get(&rec, "part")};
    s->listen = take_prefixed("claim:", s->post);
    if (!s->listen) fail("a part= record with no claim= for its post");
    const vx_gpt_part *found = nullptr;
    for (uint32_t i = 0; g && i < g->count && !found; i++)
      if (matches(&g->parts[i], &rec)) found = &g->parts[i];
    if (found)
      *s = (served){.post = s->post,
                    .listen = s->listen,
                    .found = true,
                    .first = found->first,
                    .count = found->last - found->first + 1};
    say_part(s, found);
    nparts++;
  }
}

// --- Serving ---

static void refuse(vx_handle listen, const vx_msg_header *req, vx_status why) {
  vx_session_refuse(listen, req, why);
}

// The requests waiting on partition s's post.
static void serve(served *s) {
  for (;;) {
    vx_block_connect req;
    vx_msg_size size;
    vx_status st = vx_channel_read(s->listen, &req, sizeof req, nullptr, 0, &size);
    if (st == VX_ERR_SHOULD_WAIT) return;
    if (st == VX_ERR_PEER_CLOSED) fail("a post is gone");
    if (st == VX_ERR_TOO_SMALL) { // not a request this protocol makes: read it, to be rid of it
      static uint8_t junk[VX_CHANNEL_MAX_BYTES];
      static vx_handle junk_handles[VX_CHANNEL_MAX_HANDLES];
      if (vx_channel_read(s->listen, junk, sizeof junk, junk_handles, VX_CHANNEL_MAX_HANDLES, &size) == VX_OK)
        for (uint32_t i = 0; i < size.handles; i++) vx_handle_close(junk_handles[i]);
      continue;
    }
    if (st != VX_OK || size.bytes < sizeof req.h) continue;
    if (size.bytes != sizeof req || req.h.ordinal != VX_BLOCK_CONNECT) {
      refuse(s->listen, &req.h, VX_ERR_INVALID);
      continue;
    }
    if (!s->found) {
      refuse(s->listen, &req.h, VX_ERR_NOT_FOUND);
      continue;
    }
    // The window, counted in the partition and kept inside it.
    uint64_t count = req.count;
    if (!count && req.first < s->count) count = s->count - req.first;
    if (req.first >= s->count || !count || count > s->count - req.first) {
      refuse(s->listen, &req.h, VX_ERR_RANGE);
      continue;
    }
    vx_block_connect to = {.h = {.ordinal = VX_BLOCK_CONNECT},
                           .first = s->first + req.first,
                           .count = count,
                           .flags = req.flags};
    vx_handle got[2];
    st = vx_session_ask_raw(disk, &to, sizeof to, vx_clock_read() + 5'000'000'000, got);
    if (st != VX_OK) {
      refuse(s->listen, &req.h, st);
      continue;
    }
    vx_msg_header rep = {.txid = req.h.txid, .ordinal = req.h.ordinal};
    if (vx_channel_write(s->listen, &rep, sizeof rep, got, 2) != VX_OK) // the client gave up: let it go
      vx_handle_close(got[0]), vx_handle_close(got[1]);
  }
}

const char *vx_main(void) {
  find_disk();
  if (vx_port_create(0, &port) != VX_OK) fail("port_create");
  static vx_gpt g;
  vx_status st = read_table(&g);
  vx_print(VX_STR("partd: /srv/"));
  vx_print(disk_name);
  if (st == VX_OK) {
    vx_print(VX_STR(": "));
    vx_print_u64(g.count);
    vx_print(g.backup ? VX_STR(" partitions, from the backup table: the primary is damaged\n")
                      : VX_STR(" partitions\n"));
  } else {
    vx_print(VX_STR(": no partition table it can trust: "));
    vx_print(p9_error_text(st));
    vx_print(VX_STR("\n"));
  }
  load_manifest(st == VX_OK ? &g : nullptr);
  for (;;) {
    for (uint32_t i = 0; i < nparts; i++) {
      serve(&parts[i]);
      if (!parts[i].armed)
        parts[i].armed = vx_port_bind(port, parts[i].listen, VX_TRIGGER_READABLE, i, 0) == VX_OK;
    }
    vx_packet pk[MAX_PARTS];
    int64_t n = vx_port_wait(port, VX_INFINITE, 0, pk, MAX_PARTS);
    for (int64_t i = 0; i < n; i++)
      if (pk[i].key < nparts) parts[pk[i].key].armed = false;
  }
}
