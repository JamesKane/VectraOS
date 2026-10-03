// A block class client (docs/proto/block.md): a session on a disk's or a
// partition's post, used one request at a time. A transfer goes through the
// session's client arena, so each request moves at most the arena's size or
// the driver's limit, whichever is less; longer reads and writes are split.
// Synchronous: fsd in M5 is one event loop, and waits for its disk.

#pragma once

#include "../vx-ring/session.c"
#include "blockproto.h"

typedef struct vx_blk {
  vx_ring ring;
  vx_handle end, port;
  uint8_t *arena;
  uint32_t max;     // bytes one request may move
  uint32_t sector;  // bytes
  uint64_t sectors; // the window's
  uint32_t flags;   // INFO's: VX_BLOCK_INFO_READONLY, _CACHE, _DISCARD
  vx_duration timeout;
} vx_blk;

static bool blk_wait(vx_blk *b, vx_cqe *c) {
  vx_instant deadline = vx_clock_read() + b->timeout;
  for (;;) {
    if (vx_ring_consume(&b->ring, c) == VX_OK) return true;
    int64_t seen = vx_counter_read(b->end);
    if (vx_ring_prepare_sleep(&b->ring)) {
      vx_packet pk = {};
      vx_port_bind(b->port, b->end, VX_TRIGGER_COUNTER_GE, 1, (uint64_t)seen + 1);
      int64_t n = vx_port_wait(b->port, deadline, 0, &pk, 1);
      vx_ring_end_sleep(&b->ring);
      if (n != 1) return false;
    } else {
      vx_ring_end_sleep(&b->ring);
    }
  }
}

static vx_status blk_call(vx_blk *b, vx_sqe e, vx_cqe *c) {
  vx_sqe *slot = vx_ring_produce_slot(&b->ring);
  if (!slot) return VX_ERR_SHOULD_WAIT;
  *slot = e;
  if (vx_ring_produce(&b->ring)) vx_ring_notify(b->end);
  if (!blk_wait(b, c)) return VX_ERR_TIMED_OUT;
  return c->result < 0 ? (vx_status)c->result : VX_OK;
}

// A session on the connector's whole window (flags: VX_BLOCK_READONLY).
[[maybe_unused]] static vx_status vx_blk_open(vx_blk *b, vx_handle connector, uint32_t flags) {
  *b = (vx_blk){.timeout = 30'000'000'000};
  vx_block_connect req = {.h = {.ordinal = VX_BLOCK_CONNECT}, .flags = flags};
  vx_status st = vx_session_dial_with(connector, &req, sizeof req, &VX_BLOCK_PARAMS, &b->ring, &b->end);
  if (st != VX_OK) return st;
  if ((st = vx_port_create(0, &b->port)) != VX_OK) return st;
  uint64_t size;
  b->arena = vx_ring_arena(&b->ring, &size);
  vx_cqe info;
  if ((st = blk_call(b, (vx_sqe){.opcode = VX_BLOCK_INFO}, &info)) != VX_OK) return st;
  if (!info.aux || info.result < (int64_t)info.aux) return VX_ERR_UNSUPPORTED;
  b->sector = info.aux, b->sectors = info.aux2, b->flags = info.flags;
  uint64_t max = (uint64_t)info.result < size ? (uint64_t)info.result : size;
  b->max = (uint32_t)(max / b->sector * b->sector);
  return VX_OK;
}

[[maybe_unused]] static void vx_blk_close(vx_blk *b) {
  if (b->port) vx_handle_close(b->port);
  if (b->end) vx_handle_close(b->end);
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
    vx_status st = blk_call(
        b,
        (vx_sqe){.opcode = VX_BLOCK_READ, .flags = VX_SQE_DREF, .target = (off + done) / b->sector, .len = n},
        &c);
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
    memcpy(b->arena, in + done, n);
    vx_cqe c;
    vx_status st = blk_call(
        b,
        (vx_sqe){
            .opcode = VX_BLOCK_WRITE, .flags = VX_SQE_DREF, .target = (off + done) / b->sector, .len = n},
        &c);
    if (st != VX_OK) return st;
    if (c.result != n) return VX_ERR_IO;
    done += n;
  }
  return VX_OK;
}

// Everything written before it durable.
[[maybe_unused]] static vx_status vx_blk_flush(vx_blk *b) {
  vx_cqe c;
  return blk_call(b, (vx_sqe){.opcode = VX_BLOCK_FLUSH}, &c);
}
