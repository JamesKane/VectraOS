// SPDX-License-Identifier: BSD-3-Clause

// A process's descriptors on the one ring (D46), the child's side: each
// descriptor a parent gave as CROI_PA_STDIO parts (td_stdio.h) is one
// byte-stream ring, attached at start. A write goes into its ring,
// sleeping while it is full; a read takes what its ring holds, sleeping
// until some comes; end marks go out at exit (or td_stdio_end_fd). The
// parent's closing a descriptor's channel end is that descriptor's end.
// In C because it is ring.h's, the ring's C implementation (lib/ring),
// under the floor, which runs beneath any Swift runtime; the floor's Swift
// calls it.
//
// Each descriptor sleeps on a port of its own (stdin's reader and stdout's
// writer may be different threads), bound to its doorbell (CHANGE: each
// add a packet) and to its channel's PEER_CLOSED.

#include <croi/syscall.h>
#include <processargs.h>
#include <ring.h>

#include "td_floor.h"
#include "td_native.h"
#include "td_stdio.h"

typedef struct {
  int32_t fd;
  bool reads;  // the process reads it (else writes it)
  bool gone;   // the parent has closed its end
  bool ended;  // its end mark is written
  croi_ring_t ring;
  uint32_t child_bell, parent_bell, channel, port;
} descriptor_t;

static struct {
  descriptor_t d[TD_STDIO_FDS];
  unsigned count;
} stdio;

enum : uint64_t { BELL_KEY = 1, GONE_KEY = 2 };

static uint32_t take(uint32_t fd, uint32_t part) {
  return td_startup_take(croi_pa_hnd(CROI_PA_STDIO, td_stdio_arg(fd, part)));
}

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

// Attaches `fd` if the parent gave it; a descriptor that doesn't hold
// together is none.
static void attach(uint32_t fd) {
  uint32_t in = take(fd, TD_STDIO_VMO_IN), out = take(fd, TD_STDIO_VMO_OUT);
  if (!in && !out) return;
  uint32_t vmo = in ? in : out, child = take(fd, TD_STDIO_CHILD_BELL), parent = take(fd, TD_STDIO_PARENT_BELL),
           channel = take(fd, TD_STDIO_CHANNEL);
  if (in && out) croi_handle_close(out);
  descriptor_t *d = &stdio.d[stdio.count];
  uint64_t base = 0;
  bool ok = stdio.count < TD_STDIO_FDS && child && parent && channel &&
            croi_vmar_map(td_runtime_vmar_root, CROI_VM_PERM_READ | CROI_VM_PERM_WRITE, 0, vmo, 0,
                          TD_STDIO_RING_SIZE, &base) == 0;
  croi_handle_close(vmo);  // the mapping keeps it
  ok = ok && croi_ring_attach(&d->ring, (uint8_t *)(uintptr_t)base, TD_STDIO_RING_SIZE, !in, TD_STDIO_SLOT_SIZE,
                              TD_STDIO_FORMAT, CROI_RING_BYTE_STREAM);
  uint32_t port = ok ? port_for(child, channel) : 0;
  if (!port) {
    uint32_t handles[] = {child, parent, channel};
    for (unsigned i = 0; i < sizeof handles / sizeof handles[0]; i++)
      if (handles[i]) croi_handle_close(handles[i]);
    return;
  }
  d->fd = (int32_t)fd;
  d->reads = in != 0;
  d->gone = d->ended = false;
  d->child_bell = child;
  d->parent_bell = parent;
  d->channel = channel;
  d->port = port;
  stdio.count++;
}

void td_stdio_start(void) {
  for (uint32_t fd = 0; fd < TD_STDIO_FD_LIMIT; fd++) attach(fd);
}

static descriptor_t *find(int32_t fd) {
  for (unsigned i = 0; i < stdio.count; i++)
    if (stdio.d[i].fd == fd) return &stdio.d[i];
  return 0;
}

bool td_stdio_has(int32_t fd, bool *reads) {
  descriptor_t *d = find(fd);
  if (d && reads) *reads = d->reads;
  return d != 0;
}

// Sleeps on d's port as its ring says to; false once the parent has gone.
static bool sleep_on(descriptor_t *d) {
  if (!d->gone && croi_ring_prepare_sleep(&d->ring)) {
    croi_port_packet_t packet;
    if (croi_port_wait(d->port, INT64_MAX, &packet, 0) == 0 && packet.key == GONE_KEY) d->gone = true;
  }
  croi_ring_end_sleep(&d->ring);
  return !d->gone;
}

static void ring_parent(descriptor_t *d, bool wake) {
  if (wake) croi_counter_add(d->parent_bell, 1);
}

bool td_stdio_write_fd(int32_t fd, const void *bytes, uint64_t n) {
  descriptor_t *d = find(fd);
  if (!d || d->reads) return false;
  uint64_t done = 0;
  while (done < n && !d->gone && !d->ring.broken && !d->ended) {
    bool wake;
    uint64_t written = croi_ring_write_bytes(&d->ring, (const uint8_t *)bytes + done, n - done, &wake);
    ring_parent(d, wake);
    done += written;
    if (written == 0) sleep_on(d);
  }
  return true;
}

int64_t td_stdio_read_fd(int32_t fd, void *buffer, uint64_t n) {
  descriptor_t *d = find(fd);
  if (!d || !d->reads) return -1;
  for (;;) {
    bool ended, wake;
    uint64_t got = croi_ring_read_bytes(&d->ring, buffer, n, &ended, &wake);
    ring_parent(d, wake);
    if (got || ended || d->ring.broken || n == 0) return (int64_t)got;
    if (!sleep_on(d)) {
      // Gone: what it wrote before going is still there.
      got = croi_ring_read_bytes(&d->ring, buffer, n, &ended, &wake);
      return (int64_t)got;
    }
  }
}

void td_stdio_end_fd(int32_t fd) {
  descriptor_t *d = find(fd);
  if (!d || d->reads || d->ended) return;
  for (;;) {
    bool wake;
    bool done = croi_ring_write_end(&d->ring, &wake);
    ring_parent(d, wake);
    if (done || d->ring.broken || !sleep_on(d)) break;
  }
  d->ended = true;
}

bool td_stdio_write(const void *bytes, uint64_t n) { return td_stdio_write_fd(1, bytes, n); }

int64_t td_stdio_read(void *buffer, uint64_t n) { return td_stdio_read_fd(0, buffer, n); }

void td_stdio_end(void) {
  for (unsigned i = 0; i < stdio.count; i++) td_stdio_end_fd(stdio.d[i].fd);
}
