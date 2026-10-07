// plugintest: a host and its plugins sharing structures in place (01 §6.6,
// M6 step 6e1b3, ADR-0043), run in the plugin scenario
// (tests/qemu/plugin.ndb). The host spawns a copy of itself as a plugin
// for each case, joined by a channel, and checks:
//   - a plugin killed while it builds publishes nothing;
//   - a sealed result cannot change under the host, nor be written by it;
//   - a result's links are followed with <vx/shared.h>, and one out of
//     bounds is refused;
//   - a lease revoked while the plugin reads reaches it as REVOKED;
//   - a lease lent for one call is gone after the reply, and after a
//     plugin that hangs past the call's deadline.
// Each check prints a line only when it fails; the last line counts them.
//
// Run as a plugin (its first argument "plugin"), it takes its channel end
// ("plugin") and answers one request on it.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-rt/spawn.c"
#include "../../lib/vx-ns/spawn.c"
#include "../../lib/vx-shared/shared.h"

enum op : uint32_t {
  OP_BUILD_DIE = 1, // build, say so, and wait to be killed
  OP_BUILDING,      // its answer
  OP_BUILD,         // build a list (value 1) or a list with a link out of bounds (0), seal it, send it
  OP_READ,          // read a leased VMO until it is revoked
  OP_READING,       // its first answer
  OP_CALL,          // a call with a lent VMO: read it, keep it, answer its value
  OP_CHECK,         // what the kept lease answers now
  OP_HANG,          // a call with a lent VMO: never answered; the lease's status after
  OP_REPORT,        // an answer with a status
};

typedef struct msg {
  vx_msg_header h;
  uint32_t op;
  int32_t status;
  uint64_t value;
} msg;

typedef struct node { // the shared list: links are offsets from the VMO's start
  uint64_t next;
  uint64_t value;
} node;

static constexpr uint64_t LIST_SIZE = 4ull * 4096;

static uint32_t checks, failures;

static void check_at(bool ok, const char *what, int line) {
  checks++;
  if (ok) return;
  failures++;
  vx_print(VX_STR("plugintest: FAILED line "));
  vx_print_u64((uint64_t)line);
  vx_print(VX_STR(": "));
  vx_print(vx_cstr(what));
  vx_print(VX_STR("\n"));
}

#define CHECK(cond) check_at((cond), #cond, __LINE__)

static vx_instant after_ms(uint64_t ms) { return vx_clock_read() + (vx_instant)(ms * 1'000'000); }

// The next message on ch, waiting until deadline; its handle, if it has one,
// in *h. VX_OK, TIMED_OUT, or PEER_CLOSED.
static vx_status receive(vx_handle ch, msg *m, vx_handle *h, vx_instant deadline) {
  vx_handle port;
  vx_status st = vx_port_create(0, &port);
  vx_msg_size size;
  for (; st == VX_OK;) {
    vx_handle got = 0;
    st = vx_channel_read(ch, m, sizeof *m, &got, 1, &size);
    if (st != VX_ERR_SHOULD_WAIT) {
      if (h) *h = size.handles ? got : 0;
      break;
    }
    vx_packet pk;
    vx_port_bind(port, ch, VX_TRIGGER_READABLE, 1, 0);
    vx_port_bind(port, ch, VX_TRIGGER_PEER_CLOSED, 2, 0);
    st = vx_port_wait(port, deadline, 0, &pk, 1) == 1 ? VX_OK : VX_ERR_TIMED_OUT;
  }
  vx_handle_close(port);
  return st;
}

static vx_status send(vx_handle ch, uint32_t op, int32_t status, uint64_t value, vx_handle h) {
  msg m = {.op = op, .status = status, .value = value};
  return vx_channel_write(ch, &m, sizeof m, h ? &h : nullptr, h ? 1 : 0);
}

// --- The plugin ---

static _Atomic uint32_t revoked; // a touch of a revoked lease, seen by the handler
static vx_handle spare;          // what the handler maps in its place

static vx_noted on_note(vx_exception *e, vx_str note, void *fp) {
  (void)note, (void)fp;
  if (e->kind != VX_EXCEPTION_REVOKED) return VX_NDFLT;
  atomic_store(&revoked, 1);
  uint64_t at = e->address & ~4095ull;
  vx_as_unmap(vx_self, at, 4096);
  vx_as_map(vx_self, spare, 0, 4096, 0, &at); // the load made again sees zero
  return VX_NCONT;
}

// A list of `count` nodes in a VMO of its own, sealed; with bad, the last
// link points past the VMO.
static vx_handle build(bool bad, vx_status *after_seal) {
  vx_handle v;
  uint64_t at = 0;
  if (vx_vmo_create(LIST_SIZE, 0, &v) != VX_OK ||
      vx_as_map(vx_self, v, 0, LIST_SIZE, VX_MAP_WRITE, &at) != VX_OK)
    return 0;
  node *n = (node *)at;
  for (uint64_t i = 0; i < 8; i++)
    n[i * 64] = (node){.next = i < 7 ? (i + 1) * 64 * sizeof(node) : 0, .value = i + 1};
  if (bad) n[(size_t)6 * 64].next = 1ull << 40;
  vx_as_unmap(vx_self, at, LIST_SIZE); // a seal wants no writable mapping
  vx_status st = vx_vmo_seal(v);
  uint64_t one = 1;
  *after_seal = st == VX_OK ? vx_vmo_rw(v, VX_VMO_WRITE, 0, &one, 8) : st; // its own write refused too
  return v;
}

static const char *plugin(void) {
  vx_handle ch = vx_spawn_take("plugin");
  if (!ch || vx_vmo_create(4096, 0, &spare) != VX_OK) return "no channel";
  vx_notify(on_note);
  msg m;
  vx_handle got = 0;
  if (receive(ch, &m, &got, after_ms(5000)) != VX_OK) return "no request";
  uint64_t at = 0, value = 0;
  vx_status st = VX_OK;
  switch (m.op) {
  case OP_BUILD_DIE: {
    vx_handle v;
    vx_vmo_create(LIST_SIZE, 0, &v); // half built, never sent
    send(ch, OP_BUILDING, 0, 0, 0);
    static const _Atomic uint32_t never;
    vx_futex_wait(&never, 0, VX_INFINITE); // until the host kills it
    break;
  }
  case OP_BUILD: {
    vx_handle v = build(m.value == 0, &st);
    send(ch, OP_REPORT, st, 0, v);
    break;
  }
  case OP_READ:
    if (vx_as_map(vx_self, got, 0, 4096, 0, &at) != VX_OK) return "cannot map the lease";
    send(ch, OP_READING, 0, *(volatile uint64_t *)at, 0);
    for (vx_instant end = after_ms(5000); !atomic_load(&revoked) && vx_clock_read() < end;)
      value += *(volatile uint64_t *)at; // reading, until the host takes it back
    send(ch, OP_REPORT, atomic_load(&revoked) ? VX_ERR_REVOKED : VX_OK, value, 0);
    break;
  case OP_CALL: // m.h.txid is the call's: the reply goes back with it
    if (vx_as_map(vx_self, got, 0, 4096, 0, &at) == VX_OK) value = *(volatile uint64_t *)at;
    m = (msg){.h = {.txid = m.h.txid}, .op = OP_REPORT, .value = value};
    vx_channel_write(ch, &m, sizeof m, nullptr, 0);
    if (receive(ch, &m, nullptr, after_ms(5000)) == VX_OK && m.op == OP_CHECK)
      send(ch, OP_REPORT, vx_vmo_rw(got, VX_VMO_READ, 0, &value, 8), value, 0); // the call is over
    break;
  case OP_HANG: {
    vx_vmo_rw(got, VX_VMO_READ, 0, &value, 8);
    static const _Atomic uint32_t never;
    vx_futex_wait(&never, 0, after_ms(2500)); // past the call's deadline: no answer
    send(ch, OP_REPORT, vx_vmo_rw(got, VX_VMO_READ, 0, &value, 8), value, 0);
    break;
  }
  default: return "unknown request";
  }
  return nullptr;
}

// --- The host ---

static uint8_t image[1 << 20];
static size_t image_size;
static vx_ns ns;

// A plugin: its task, and the host's end of its channel.
static bool spawn_plugin(vx_handle *task, vx_handle *end) {
  vx_handle ch[2];
  if (vx_channel_create(0, ch) != VX_OK) return false;
  vx_handle handles[2] = {ch[1]};
  vx_str names[2] = {VX_STR("plugin")};
  uint32_t count = 1;
  if (vx_console.connector && vx_handle_dup(vx_console.connector, VX_RIGHTS_SAME, &handles[count]) == VX_OK)
    names[count++] = VX_STR("console");
  static const char records[] = "arg=plugin\n";
  vx_spawn_args a = {.name = VX_STR("plugin"),
                     .image = image,
                     .image_size = image_size,
                     .handles = handles,
                     .handle_names = names,
                     .handle_count = count,
                     .records = {records, sizeof records - 1}};
  if (vx_spawn_elf(&a, task) != VX_OK) {
    vx_handle_close(ch[0]);
    return false;
  }
  *end = ch[0];
  return true;
}

// A call to a plugin lending it mem: the call's status, and its reply in *r.
static vx_status lend(vx_handle end, uint32_t op, vx_handle mem, msg *r, vx_instant deadline) {
  msg rq = {.op = op};
  vx_call call = {.wr_bytes = &rq,
                  .wr_len = sizeof rq,
                  .wr_handles = &mem,
                  .wr_count = 1,
                  .rd_bytes = r,
                  .rd_cap = sizeof *r,
                  .lent = 1};
  return vx_channel_call(end, &call, deadline);
}

// The sum of a sealed list's values, following links checked by
// <vx/shared.h>; *refused counts the links it would not follow.
static uint64_t walk(vx_shared s, uint32_t *refused) {
  uint64_t sum = 0;
  *refused = 0;
  const node *n = VX_SHARED_AT(s, 0, node);
  for (uint32_t hops = 0; n && hops < 64; hops++) {
    sum += n->value;
    uint64_t next = n->next; // read once: the bytes are sealed, but the habit is the safe one
    n = next ? VX_SHARED_AT(s, next, node) : nullptr;
    if (next && !n) ++*refused;
  }
  return sum;
}

static void test_killed_while_building(void) {
  vx_handle task = 0, end = 0, got = 0;
  msg m;
  CHECK(spawn_plugin(&task, &end));
  CHECK(send(end, OP_BUILD_DIE, 0, 0, 0) == VX_OK);
  CHECK(receive(end, &m, &got, after_ms(5000)) == VX_OK && m.op == OP_BUILDING && !got);
  CHECK(vx_task_kill(task, VX_STR("replaced")) == VX_OK);
  CHECK(receive(end, &m, &got, after_ms(5000)) == VX_ERR_PEER_CLOSED && !got); // nothing was published
  vx_handle_close(end);
  vx_handle_close(task);
}

static void test_sealed_result(bool bad) {
  vx_handle task = 0, end = 0, v = 0;
  msg m;
  CHECK(spawn_plugin(&task, &end));
  CHECK(send(end, OP_BUILD, 0, bad ? 0 : 1, 0) == VX_OK);
  CHECK(receive(end, &m, &v, after_ms(5000)) == VX_OK && m.op == OP_REPORT && v);
  CHECK(m.status == VX_ERR_ACCESS); // the plugin's own write after its seal
  uint64_t at = 0, one = 1;
  CHECK(vx_as_map(vx_self, v, 0, LIST_SIZE, VX_MAP_WRITE, &at) == VX_ERR_ACCESS); // nor the host's
  CHECK(vx_vmo_rw(v, VX_VMO_WRITE, 0, &one, 8) == VX_ERR_ACCESS);
  CHECK(vx_as_map(vx_self, v, 0, LIST_SIZE, 0, &at) == VX_OK);
  uint32_t refused = 0;
  uint64_t sum = walk((vx_shared){(const uint8_t *)at, LIST_SIZE}, &refused);
  if (bad)
    CHECK(sum == 1 + 2 + 3 + 4 + 5 + 6 + 7 && refused == 1); // the seventh's link points out: not followed
  else
    CHECK(sum == 36 && refused == 0);
  vx_as_unmap(vx_self, at, LIST_SIZE);
  vx_handle_close(v);
  vx_handle_close(end);
  vx_handle_close(task);
}

static void test_revoked_while_reading(void) {
  vx_handle task = 0, end = 0, input = 0, lease = 0, given = 0;
  msg m;
  uint64_t value = 77;
  CHECK(vx_vmo_create(4096, 0, &input) == VX_OK && vx_vmo_rw(input, VX_VMO_WRITE, 0, &value, 8) == VX_OK);
  CHECK(vx_vmo_lease(input, &lease) == VX_OK &&
        vx_handle_dup(lease, VX_RIGHT_READ | VX_RIGHT_MAP | VX_RIGHT_TRANSFER, &given) == VX_OK);
  CHECK(spawn_plugin(&task, &end));
  CHECK(send(end, OP_READ, 0, 0, given) == VX_OK);
  CHECK(receive(end, &m, nullptr, after_ms(5000)) == VX_OK && m.op == OP_READING && m.value == 77);
  CHECK(vx_vmo_revoke(lease) == VX_OK); // while it reads
  CHECK(receive(end, &m, nullptr, after_ms(5000)) == VX_OK && m.op == OP_REPORT &&
        m.status == VX_ERR_REVOKED);
  CHECK(vx_vmo_rw(input, VX_VMO_READ, 0, &value, 8) == VX_OK && value == 77); // the host's own stays
  vx_handle_close(lease);
  vx_handle_close(input);
  vx_handle_close(end);
  vx_handle_close(task);
}

static void test_lent(void) {
  vx_handle task = 0, end = 0, input = 0;
  msg m;
  uint64_t value = 5150;
  CHECK(vx_vmo_create(4096, 0, &input) == VX_OK && vx_vmo_rw(input, VX_VMO_WRITE, 0, &value, 8) == VX_OK);
  // Answered: read through the lent memory, which is gone once the call is.
  CHECK(spawn_plugin(&task, &end));
  CHECK(lend(end, OP_CALL, input, &m, after_ms(5000)) == VX_OK && m.value == 5150);
  CHECK(send(end, OP_CHECK, 0, 0, 0) == VX_OK);
  CHECK(receive(end, &m, nullptr, after_ms(5000)) == VX_OK && m.status == VX_ERR_REVOKED);
  vx_handle_close(end);
  vx_handle_close(task);
  // Never answered: the deadline ends the call and the lease with it.
  CHECK(spawn_plugin(&task, &end));
  CHECK(lend(end, OP_HANG, input, &m, after_ms(1500)) == VX_ERR_TIMED_OUT); // read by then, even under TCG
  CHECK(receive(end, &m, nullptr, after_ms(5000)) == VX_OK && m.op == OP_REPORT &&
        m.status == VX_ERR_REVOKED);
  CHECK(vx_vmo_rw(input, VX_VMO_READ, 0, &value, 8) == VX_OK && value == 5150);
  vx_handle_close(end);
  vx_handle_close(task);
  vx_handle_close(input);
}

const char *vx_main(void) {
  if (vx_spawn.argc && vx_spawn.args[0].len == 6 && !memcmp(vx_spawn.args[0].ptr, "plugin", 6))
    return plugin();
  if (vx_ns_from_spawn(&ns) != VX_OK) return "no namespace";
  vx_ns_file f;
  if (vx_ns_open(&ns, VX_STR("/boot/bin/plugintest"), P9_OREAD, &f) == VX_OK) {
    int64_t n;
    while (image_size < sizeof image &&
           (n = vx_ns_read(&f, image + image_size, (uint32_t)(sizeof image - image_size))) > 0)
      image_size += (size_t)n;
    vx_ns_close(&f);
  }
  CHECK(image_size > 0);
  test_killed_while_building();
  test_sealed_result(false);
  test_sealed_result(true);
  test_revoked_while_reading();
  test_lent();
  vx_print(VX_STR("plugintest: "));
  vx_print_u64(checks);
  vx_print(VX_STR(" checks, "));
  vx_print_u64(failures);
  vx_print(VX_STR(" failed\n"));
  return failures ? "FAILED" : nullptr;
}
