// A block class client (docs/proto/block.md): a session on a disk's or a
// partition's post, used one request at a time. A transfer goes through the
// session's client arena, so each request moves at most the arena's size or
// the driver's limit, whichever is less; longer reads and writes are split.
// Synchronous: fsd in M5 is one event loop, and waits for its disk.
//
// A driver that dies takes its sessions with it (docs/01 §7.4). The client
// keeps its connector, and when its session goes it dials again, until the
// driver has been restarted (RECONNECT_FOR), and does the request it was
// waiting for again: a read is read again, a write's bytes copied into the
// new arena and written again, a flush flushed again. Each may then have been
// done twice, which the protocol allows. The new session must reach a window
// of the same size, or the disk is not the one it was.

#pragma once

#include "../vx-ring/session.c"
#include "blockproto.h"

static constexpr vx_duration RECONNECT_FOR = 30'000'000'000;

typedef struct vx_blk {
  vx_ring ring;
  vx_handle end, port, connector;
  uint8_t *arena;
  uint32_t max;       // bytes one request may move
  uint32_t sector;    // bytes
  uint64_t sectors;   // the window's
  uint32_t flags;     // INFO's: VX_BLOCK_INFO_READONLY, _CACHE, _DISCARD
  uint32_t open_with; // CONNECT's flags
  uint32_t reconnects;
  vx_duration timeout;
} vx_blk;

enum : uint64_t { BLK_KEY_BELL = 1, BLK_KEY_CLOSED = 2 };

// The completion, if it comes: false if the session went (its driver died)
// or nothing came in time; *gone says which.
static bool blk_wait(vx_blk *b, vx_cqe *c, bool *gone) {
  vx_instant deadline = vx_clock_read() + b->timeout;
  *gone = false;
  for (;;) {
    if (vx_ring_consume(&b->ring, c) == VX_OK) return true;
    int64_t seen = vx_counter_read(b->end);
    if (vx_ring_prepare_sleep(&b->ring)) {
      vx_packet pk = {};
      vx_port_bind(b->port, b->end, VX_TRIGGER_COUNTER_GE, BLK_KEY_BELL, (uint64_t)seen + 1);
      int64_t n = vx_port_wait(b->port, deadline, 0, &pk, 1);
      vx_ring_end_sleep(&b->ring);
      if (n == 1 && pk.key == BLK_KEY_CLOSED) {
        *gone = vx_ring_consume(&b->ring, c) != VX_OK; // it may have answered as it went
        return !*gone;
      }
      if (n != 1) return false;
    } else {
      vx_ring_end_sleep(&b->ring);
    }
  }
}

static vx_status blk_info(vx_blk *b);

// A session on the connector, and what it reaches.
static vx_status blk_dial(vx_blk *b) {
  vx_block_connect req = {.h = {.ordinal = VX_BLOCK_CONNECT}, .flags = b->open_with};
  vx_status st = vx_session_dial_with(b->connector, &req, sizeof req, &VX_BLOCK_PARAMS, &b->ring, &b->end);
  if (st != VX_OK) return st;
  if (!b->port && (st = vx_port_create(0, &b->port)) != VX_OK) return st;
  if ((st = vx_port_bind(b->port, b->end, VX_TRIGGER_PEER_CLOSED, BLK_KEY_CLOSED, 0)) != VX_OK) return st;
  uint64_t size;
  b->arena = vx_ring_arena(&b->ring, &size);
  return blk_info(b);
}

// The session gone: dialled again until the driver is back. False if it is not.
static bool blk_reconnect(vx_blk *b) {
  uint64_t had = b->sectors;
  uint32_t sector = b->sector;
  vx_handle_close(b->end);
  vx_session_unmap(&b->ring);
  b->end = VX_HANDLE_NONE;
  vx_instant until = vx_clock_read() + RECONNECT_FOR;
  static _Atomic uint32_t never;
  while (vx_clock_read() < until) {
    if (blk_dial(b) == VX_OK) {
      if (b->sectors != had || b->sector != sector) return false; // another disk now
      b->reconnects++;
      vx_print(VX_STR("vx-blk: the disk's session went; dialled again, and the request done again\n"));
      return true;
    }
    if (b->end) vx_handle_close(b->end), b->end = VX_HANDLE_NONE;
    vx_session_unmap(&b->ring);
    vx_futex_wait(&never, 0, vx_clock_read() + 100'000'000); // the driver restarting: 0.1 s
  }
  return false;
}

// One request, and its completion. PEER_CLOSED: the session went before it
// was answered (blk_retry redoes it).
static vx_status blk_once(vx_blk *b, vx_sqe e, vx_cqe *c) {
  vx_sqe *slot = vx_ring_produce_slot(&b->ring);
  if (!slot) return VX_ERR_SHOULD_WAIT;
  *slot = e;
  if (vx_ring_produce(&b->ring)) vx_ring_notify(b->end);
  bool gone;
  if (!blk_wait(b, c, &gone)) return gone ? VX_ERR_PEER_CLOSED : VX_ERR_TIMED_OUT;
  return c->result < 0 ? (vx_status)c->result : VX_OK;
}

static vx_status blk_info(vx_blk *b) {
  vx_cqe info;
  vx_status st = blk_once(b, (vx_sqe){.opcode = VX_BLOCK_INFO}, &info);
  if (st != VX_OK) return st;
  uint64_t size;
  vx_ring_arena(&b->ring, &size);
  if (!info.aux || info.result < (int64_t)info.aux) return VX_ERR_UNSUPPORTED;
  b->sector = info.aux, b->sectors = info.aux2, b->flags = info.flags;
  uint64_t max = (uint64_t)info.result < size ? (uint64_t)info.result : size;
  b->max = (uint32_t)(max / b->sector * b->sector);
  return b->max ? VX_OK : VX_ERR_UNSUPPORTED; // a sector larger than the arena: no request could move one
}

// A session on the connector's whole window (flags: VX_BLOCK_READONLY). The
// connector becomes the session's: it dials again with it when it must.
[[maybe_unused]] static vx_status vx_blk_open(vx_blk *b, vx_handle connector, uint32_t flags) {
  *b = (vx_blk){.timeout = 30'000'000'000, .connector = connector, .open_with = flags};
  return blk_dial(b);
}

[[maybe_unused]] static void vx_blk_close(vx_blk *b) {
  if (b->port) vx_handle_close(b->port);
  if (b->end) vx_handle_close(b->end);
  if (b->connector) vx_handle_close(b->connector);
  vx_session_unmap(&b->ring);
  *b = (vx_blk){};
}

// Bytes [off, off + len), both multiples of the sector size, into buf.
[[maybe_unused]] static vx_status vx_blk_read(vx_blk *b, uint64_t off, void *buf, uint64_t len) {
  if (off % b->sector || len % b->sector || off / b->sector > b->sectors ||
      len / b->sector > b->sectors - off / b->sector)
    return VX_ERR_RANGE;
  uint8_t *out = buf;
  for (uint64_t done = 0; done < len;) {
    uint32_t n = len - done < b->max ? (uint32_t)(len - done) : b->max;
    vx_cqe c;
    vx_status st;
    do
      st = blk_once(
          b,
          (vx_sqe){
              .opcode = VX_BLOCK_READ, .flags = VX_SQE_DREF, .target = (off + done) / b->sector, .len = n},
          &c);
    while (st == VX_ERR_PEER_CLOSED && blk_reconnect(b));
    if (st != VX_OK) return st;
    if (c.result != n) return VX_ERR_IO;
    memcpy(out + done, b->arena, n);
    done += n;
  }
  return VX_OK;
}

// buf to bytes [off, off + len), both multiples of the sector size.
[[maybe_unused]] static vx_status vx_blk_write(vx_blk *b, uint64_t off, const void *buf, uint64_t len) {
  if (off % b->sector || len % b->sector || off / b->sector > b->sectors ||
      len / b->sector > b->sectors - off / b->sector)
    return VX_ERR_RANGE;
  const uint8_t *in = buf;
  for (uint64_t done = 0; done < len;) {
    uint32_t n = len - done < b->max ? (uint32_t)(len - done) : b->max;
    vx_cqe c;
    vx_status st;
    do {
      memcpy(b->arena, in + done, n); // again into a new session's arena, after a reconnect
      st = blk_once(
          b,
          (vx_sqe){
              .opcode = VX_BLOCK_WRITE, .flags = VX_SQE_DREF, .target = (off + done) / b->sector, .len = n},
          &c);
    } while (st == VX_ERR_PEER_CLOSED && blk_reconnect(b));
    if (st != VX_OK) return st;
    if (c.result != n) return VX_ERR_IO;
    done += n;
  }
  return VX_OK;
}

// Everything written before it durable.
[[maybe_unused]] static vx_status vx_blk_flush(vx_blk *b) {
  vx_cqe c;
  vx_status st;
  do st = blk_once(b, (vx_sqe){.opcode = VX_BLOCK_FLUSH}, &c);
  while (st == VX_ERR_PEER_CLOSED && blk_reconnect(b));
  return st;
}
