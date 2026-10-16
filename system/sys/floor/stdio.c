// SPDX-License-Identifier: BSD-3-Clause

// stdio on the one ring (D46), the child's side: the two byte-stream rings
// a parent gave as CROI_PA_STDIO (td_stdio.h), attached at start. stdout's
// writes (Stdout.swift's lines) go into its ring, sleeping while it is
// full; stdin's reads take what its ring holds, sleeping until some comes;
// the end mark goes out at exit. The parent's closing its channel end is
// the end of both. In C because it is ring.h's, the ring's C
// implementation (lib/ring), under the floor, which runs beneath any
// Swift runtime; the floor's Swift calls it.
//
// Each direction sleeps on a port of its own (stdin's reader and stdout's
// writer may be different threads), both bound to the child's doorbell
// (CHANGE: each add a packet) and to the channel's PEER_CLOSED.

#include <croi/syscall.h>
#include <processargs.h>
#include <ring.h>

#include "td_floor.h"
#include "td_native.h"
#include "td_stdio.h"

static struct {
  bool given;
  bool gone;  // the parent has closed its end
  croi_ring_t in, out;
  uint32_t child_bell, parent_bell, channel;
  uint32_t in_port, out_port;
} stdio;

enum : uint64_t { BELL_KEY = 1, GONE_KEY = 2 };

static uint32_t take(uint32_t part) { return td_startup_take(croi_pa_hnd(CROI_PA_STDIO, part)); }

static uint32_t port_for(uint32_t bell, uint32_t channel) {
  uint32_t port = 0;
  if (croi_syscall(CROI_SYS_PORT_CREATE, 0, (uint64_t)&port, 0, 0, 0) != 0) return 0;
  croi_bind_item_t items[2] = {
      {.handle = bell, .options = CROI_BIND_CHANGE | CROI_BIND_PERSISTENT, .key = BELL_KEY, .status = 1},
      {.handle = channel, .options = CROI_BIND_SIGNALS, .key = GONE_KEY, .trigger = CROI_SIGNAL_PEER_CLOSED,
       .status = 1},
  };
  if (croi_syscall(CROI_SYS_OBJECT_BIND, port, (uint64_t)items, 2, 0, 0) != 2) {
    croi_handle_close(port);
    return 0;
  }
  return port;
}

void td_stdio_start(void) {
  uint32_t vmo = take(TD_STDIO_VMO), child = take(TD_STDIO_CHILD_BELL), parent = take(TD_STDIO_PARENT_BELL),
           channel = take(TD_STDIO_CHANNEL);
  uint64_t base = 0;
  bool ok = vmo && child && parent && channel &&
            croi_vmar_map(td_runtime_vmar_root, CROI_VM_PERM_READ | CROI_VM_PERM_WRITE, 0, vmo, 0, TD_STDIO_SIZE,
                          &base) == 0;
  if (vmo) croi_handle_close(vmo);  // the mapping keeps it
  uint8_t *b = (uint8_t *)(uintptr_t)base;
  ok = ok &&
       croi_ring_attach(&stdio.in, b + TD_STDIO_IN, TD_STDIO_OUT - TD_STDIO_IN, false, TD_STDIO_SLOT_SIZE,
                        TD_STDIO_FORMAT, CROI_RING_BYTE_STREAM) &&
       croi_ring_attach(&stdio.out, b + TD_STDIO_OUT, TD_STDIO_SIZE - TD_STDIO_OUT, true, TD_STDIO_SLOT_SIZE,
                        TD_STDIO_FORMAT, CROI_RING_BYTE_STREAM);
  if (ok) {
    stdio.in_port = port_for(child, channel);
    stdio.out_port = port_for(child, channel);
    ok = stdio.in_port && stdio.out_port;
  }
  if (!ok) {  // a stdio that doesn't hold together is none: stdout stays the debuglog
    uint32_t handles[] = {child, parent, channel, stdio.in_port, stdio.out_port};
    for (unsigned i = 0; i < sizeof handles / sizeof handles[0]; i++)
      if (handles[i]) croi_handle_close(handles[i]);
    stdio.in_port = stdio.out_port = 0;
    return;
  }
  stdio.child_bell = child;
  stdio.parent_bell = parent;
  stdio.channel = channel;
  stdio.given = true;
}

// Sleeps on `port` for `ring` as the ring says to; false once the parent
// has gone.
static bool sleep_on(uint32_t port, croi_ring_t *ring) {
  if (!stdio.gone && croi_ring_prepare_sleep(ring)) {
    croi_port_packet_t packet;
    if (croi_port_wait(port, INT64_MAX, &packet, 0) == 0 && packet.key == GONE_KEY) stdio.gone = true;
  }
  croi_ring_end_sleep(ring);
  return !stdio.gone;
}

static void ring_parent(bool wake) {
  if (wake) croi_counter_add(stdio.parent_bell, 1);
}

bool td_stdio_write(const void *bytes, uint64_t n) {
  if (!stdio.given) return false;
  uint64_t done = 0;
  while (done < n && !stdio.gone && !stdio.out.broken) {
    bool wake;
    uint64_t written = croi_ring_write_bytes(&stdio.out, (const uint8_t *)bytes + done, n - done, &wake);
    ring_parent(wake);
    done += written;
    if (written == 0) sleep_on(stdio.out_port, &stdio.out);
  }
  return true;
}

int64_t td_stdio_read(void *buffer, uint64_t n) {
  if (!stdio.given) return -1;
  for (;;) {
    bool ended, wake;
    uint64_t got = croi_ring_read_bytes(&stdio.in, buffer, n, &ended, &wake);
    ring_parent(wake);
    if (got || ended || stdio.in.broken || n == 0) return (int64_t)got;
    if (!sleep_on(stdio.in_port, &stdio.in)) {
      // Gone: what it wrote before going is still there.
      got = croi_ring_read_bytes(&stdio.in, buffer, n, &ended, &wake);
      return (int64_t)got;
    }
  }
}

void td_stdio_end(void) {
  if (!stdio.given) return;
  for (;;) {
    bool wake;
    bool done = croi_ring_write_end(&stdio.out, &wake);
    ring_parent(wake);
    if (done || stdio.out.broken || !sleep_on(stdio.out_port, &stdio.out)) return;
  }
}
