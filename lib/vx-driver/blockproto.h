// The block class protocol (docs/proto/block.md): a session per client on a
// block driver's post (/srv/disk0, ...) or on a partition's (partd), a ring
// (lib/vx-ring/session.c) that reaches one window of the disk.

#pragma once

#include "../../abi/vx/abi.h"

enum : uint32_t { VX_BLOCK_CONNECT = 0x6b6c'6263 }; // "cblk": the connector's one request
enum : uint32_t { VX_BLOCK_READONLY = 1 };          // CONNECT's flags

// CONNECT's body, after its vx_msg_header: the window, in the connector's sectors.
typedef struct vx_block_connect {
  vx_msg_header h;
  uint64_t first, count; // count 0: from first to the connector's end
  uint32_t flags;
  uint32_t reserved;
} vx_block_connect;

enum : uint16_t {
  VX_BLOCK_INFO = 1,
  VX_BLOCK_READ = 2,
  VX_BLOCK_WRITE = 3,
  VX_BLOCK_WRITE_FUA = 4,
  VX_BLOCK_FLUSH = 5,
  VX_BLOCK_DISCARD = 6,
};

// INFO's completion flags.
enum : uint32_t { VX_BLOCK_INFO_READONLY = 1, VX_BLOCK_INFO_CACHE = 2, VX_BLOCK_INFO_DISCARD = 4 };

static constexpr uint32_t VX_BLOCK_ENTRIES = 128;
static constexpr uint64_t VX_BLOCK_ARENA = 1ull << 20; // the client's buffers

static const vx_ring_params VX_BLOCK_PARAMS = {
    .sq_entries = VX_BLOCK_ENTRIES,
    .cq_entries = VX_BLOCK_ENTRIES,
    .sqe_size = sizeof(vx_sqe),
    .cqe_size = sizeof(vx_cqe),
    .client_arena = VX_BLOCK_ARENA,
    .server_arena = 0,
};
