// nettest: the network driver's test, run as a service in the net scenario
// (tests/qemu/net.ndb). It opens a session on /srv/ether0, as netd will,
// asks for the MAC address, offers receive slots, and sends an ARP request
// for QEMU's host (10.0.2.2) from the guest's address (10.0.2.15). QEMU's user
// network answers, so a reply means frames went out and came back in, through
// both virtqueues and both MSI-X interrupts. A second session is refused
// while the first is open.
//
// Then it kills the driver, through the task tree its manifest gives it
// (`tasks`), and does it all again: devmgr restarts the driver on the same
// post, so a new session works as the first did.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-ring/session.c"
#include "../../lib/vx-driver/netproto.h"

static const uint8_t GUEST_IP[4] = {10, 0, 2, 15}, HOST_IP[4] = {10, 0, 2, 2};

static vx_ring ring;
static vx_handle end, port;

[[noreturn]] static void fail(const char *what) {
  vx_print(VX_STR("nettest: FAILED: "));
  vx_print(vx_cstr(what));
  vx_print(VX_STR("\n"));
  vx_thread_exit(1);
}

static void submit(vx_sqe e) {
  vx_sqe *slot = vx_ring_produce_slot(&ring);
  if (!slot) fail("the submission queue is full");
  *slot = e;
  if (vx_ring_produce(&ring)) vx_ring_notify(end);
}

// The next completion, waiting up to `seconds` for it.
static bool next(vx_cqe *c, int64_t seconds) {
  vx_instant deadline = vx_clock_read() + seconds * 1'000'000'000;
  for (;;) {
    if (vx_ring_consume(&ring, c) == VX_OK) return true;
    int64_t seen = vx_counter_read(end);
    if (vx_ring_prepare_sleep(&ring)) {
      vx_packet pk = {};
      if (vx_port_bind(port, end, VX_TRIGGER_COUNTER_GE, 1, (uint64_t)seen + 1) != VX_OK) fail("port_bind");
      int64_t n = vx_port_wait(port, deadline, 0, &pk, 1);
      vx_ring_end_sleep(&ring);
      if (n == VX_ERR_TIMED_OUT) return false;
      if (n != 1) fail("waiting for the driver");
    } else {
      vx_ring_end_sleep(&ring);
    }
  }
}

static void hex(const uint8_t *b, int n, char sep) {
  static const char digits[] = "0123456789abcdef";
  char text[3];
  for (int i = 0; i < n; i++) {
    text[0] = digits[b[i] >> 4], text[1] = digits[b[i] & 15], text[2] = sep;
    vx_print((vx_str){text, i + 1 < n ? 3u : 2u});
  }
}

// Opens a session (waiting for the driver to serve), and checks a second
// is refused while it is open.
static void open_session(vx_handle connector) {
  vx_status st = VX_ERR_PEER_CLOSED;
  for (int tries = 0; tries < 50 && st != VX_OK; tries++) { // the driver may not be serving yet
    st = vx_session_dial(connector, VX_NET_CONNECT, &VX_NET_PARAMS, &ring, &end);
    if (st != VX_OK) vx_port_wait(port, vx_clock_read() + 100'000'000, 0, &(vx_packet){}, 1); // a nap
  }
  if (st != VX_OK) fail("cannot open a session");

  vx_ring other;
  vx_handle other_end;
  if (vx_session_dial(connector, VX_NET_CONNECT, &VX_NET_PARAMS, &other, &other_end) == VX_OK)
    fail("a second session was opened while the first is open");
  vx_print(VX_STR("nettest: a second session is refused\n"));
}

// INFO, then an ARP request and its reply. False if no reply came.
static bool exchange(void) {
  submit((vx_sqe){.opcode = VX_NET_INFO, .user_data = 1});
  vx_cqe c;
  if (!next(&c, 5) || c.user_data != 1 || c.result != 0) fail("INFO");
  uint8_t mac[6];
  for (int i = 0; i < 6; i++) mac[i] = (uint8_t)(c.aux2 >> (8 * i));
  vx_print(VX_STR("nettest: MAC "));
  hex(mac, 6, ':');
  vx_print(VX_STR(", MTU "));
  vx_print_u64(c.aux);
  vx_print(VX_STR("\n"));

  for (uint32_t s = 0; s < 8; s++) submit((vx_sqe){.opcode = VX_NET_RX, .user_data = 100 + s, .target = s});

  // An ARP request (RFC 826), broadcast: who has 10.0.2.2? tell 10.0.2.15.
  uint64_t arena_size;
  uint8_t *f = vx_ring_arena(&ring, &arena_size);
  memset(f, 0xff, 6);
  memcpy(f + 6, mac, 6);
  f[12] = 0x08, f[13] = 0x06;                    // ARP
  f[14] = 0, f[15] = 1, f[16] = 0x08, f[17] = 0; // Ethernet, IPv4
  f[18] = 6, f[19] = 4, f[20] = 0, f[21] = 1;    // address sizes; a request
  memcpy(f + 22, mac, 6);
  memcpy(f + 28, GUEST_IP, 4);
  memset(f + 32, 0, 6);
  memcpy(f + 38, HOST_IP, 4);
  memset(f + 42, 0, 18); // padded to Ethernet's 60 bytes
  submit((vx_sqe){.opcode = VX_NET_TX, .flags = VX_SQE_DREF, .user_data = 2, .arena_off = 0, .len = 60});

  bool sent = false;
  while (next(&c, 10)) {
    if (c.user_data == 2) {
      if (c.result != 60) fail("TX");
      sent = true;
      vx_print(VX_STR("nettest: sent an ARP request for 10.0.2.2\n"));
      continue;
    }
    if (c.user_data < 100 || c.user_data >= 108 || c.result < 42) fail("an RX completion");
    const uint8_t *r = vx_ring_peer_bytes(&ring, c.aux2, (uint64_t)c.result);
    if (!r) fail("an RX frame outside the driver's arena");
    bool reply = r[12] == 0x08 && r[13] == 0x06 && r[20] == 0 && r[21] == 2 &&
                 memcmp(r + 28, HOST_IP, 4) == 0 && memcmp(r + 38, GUEST_IP, 4) == 0 &&
                 memcmp(r, mac, 6) == 0;
    submit((vx_sqe){
        .opcode = VX_NET_RX, .user_data = c.user_data, .target = c.user_data - 100}); // offered again
    if (!reply) continue; // something else on the wire
    vx_print(VX_STR("nettest: 10.0.2.2 is at "));
    hex(r + 22, 6, ':');
    vx_print(VX_STR("\n"));
    if (!sent) fail("a reply before the request completed");
    return true;
  }
  return false;
}

// Kills the driver, found by name in the task tree, and waits for its session to end.
static void kill_driver(vx_handle tasks) {
  vx_task_summary info = {};
  uint64_t id = 0;
  bool found = false;
  while (!found && vx_task_info_of(tasks, id, VX_TASK_NEXT, &info) == VX_OK) {
    id = info.id;
    found = memcmp(info.name, "drv-virtio-net", 15) == 0;
  }
  if (!found) fail("no drv-virtio-net task");
  if (vx_task_kill_id(tasks, id, -9) != VX_OK) fail("cannot kill the driver");
  if (vx_port_bind(port, end, VX_TRIGGER_PEER_CLOSED, 2, 0) != VX_OK) fail("port_bind");
  vx_packet pk = {};
  while (pk.key != 2)
    if (vx_port_wait(port, vx_clock_read() + 5'000'000'000, 0, &pk, 1) != 1)
      fail("the session outlived the driver");
  vx_handle_close(end);
  vx_print(VX_STR("nettest: stopped the driver; its session ended\n"));
}

int vx_main(void) {
  vx_handle connector = vx_spawn_take("srv:ether0"), tasks = vx_spawn_take("tasks");
  if (!connector || !tasks) fail("no connector to /srv/ether0, or no task tree");
  if (vx_port_create(0, &port) != VX_OK) fail("port_create");
  open_session(connector);
  if (!exchange()) fail("no ARP reply");
  vx_print(VX_STR("nettest: ok\n"));
  kill_driver(tasks);
  open_session(connector); // the restarted driver serves the same post
  if (!exchange()) fail("no ARP reply from the restarted driver");
  vx_print(VX_STR("nettest: ok after the restart\n"));
  return 0;
}
