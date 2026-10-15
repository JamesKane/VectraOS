// Channels and object info: the ABI shared by the kernel and
// user space (user/include/croi/syscall.h includes it). Zircon's layouts.
#pragma once
#include <stdint.h>

enum : uint32_t {
  CROI_CHANNEL_MAX_BYTES = 65536,
  CROI_CHANNEL_MAX_HANDLES = 64,
  // Signals (Zircon's ZX_CHANNEL_*).
  CROI_SIGNAL_READABLE = 1u << 0,
  CROI_SIGNAL_WRITABLE = 1u << 1,
  CROI_SIGNAL_PEER_CLOSED = 1u << 2,
  CROI_SIGNAL_SIGNALED = 1u << 3,  // ZX_EVENT_SIGNALED; nothing asserts it since D31
  // object_get_info topics.
  CROI_INFO_HANDLE_BASIC = 2,
  CROI_INFO_VMAR = 7,  // croi_info_vmar_t (needs INSPECT)
  // croi_info_handle_count_t (needs INSPECT, K13a): handles to the object
  // in every handle table and in channel messages in flight. A mapping
  // keeps a VMO alive without a handle: see vmo.h's ZERO_CHILDREN.
  CROI_INFO_HANDLE_COUNT = 19,
  // handle_duplicate's options (D34): CONSUME closes the handle, even on
  // failure, and needs no DUPLICATE right (handle_replace until D34).
  CROI_HANDLE_DUPLICATE_CONSUME = 1u << 0,
  // handle_duplicate takes up to this many items at once (D39).
  CROI_HANDLE_DUPLICATE_MAX_ITEMS = 64,
};

// handle_duplicate(croi_handle_duplicate_item_t *items, count) (D39):
// duplicates (or, with CONSUME, replaces) each item's handle with the
// rights asked for, in order. It stops at the first item that fails and
// returns how many succeeded; each item it processed has its status
// written back. A bad pointer or count fails the whole call (a negative
// status) before any item is done. croi_handle_duplicate in syscall.h is
// the one-handle form.
typedef struct {
  uint32_t handle;    // the handle to duplicate
  uint32_t rights;    // a subset of its rights, or 1u << 31: the same
  uint32_t options;   // 0 or CROI_HANDLE_DUPLICATE_CONSUME
  uint32_t out;       // out: the new handle
  int32_t status;     // out: 0, or why this item failed
  uint32_t reserved;  // 0
} croi_handle_duplicate_item_t;

static_assert(sizeof(croi_handle_duplicate_item_t) == 24);

// zx_info_handle_count_t.
typedef struct {
  uint32_t handle_count;
} croi_info_handle_count_t;

// zx_info_vmar_t.
typedef struct {
  uint64_t base;
  uint64_t len;
} croi_info_vmar_t;

// zx_channel_call_args_t.
typedef struct {
  uint64_t wr_bytes;    // const void *
  uint64_t wr_handles;  // const uint32_t *
  uint64_t rd_bytes;    // void *
  uint64_t rd_handles;  // uint32_t *
  uint32_t wr_num_bytes;
  uint32_t wr_num_handles;
  uint32_t rd_num_bytes;
  uint32_t rd_num_handles;
} croi_channel_call_args_t;

// channel_read's MAY_DISCARD (K13e; V1 cut the *_etc forms, D22: rights
// are narrowed with handle_duplicate before sending).
enum : uint32_t {
  CROI_CHANNEL_READ_MAY_DISCARD = 1,
};

// zx_info_handle_basic_t.
typedef struct {
  uint64_t koid;
  uint32_t rights;
  uint32_t type;
  uint64_t related_koid;  // the peer's, for channels
  uint32_t reserved[2];
} croi_info_handle_basic_t;

// The flow id of a channel message (trace records, K7b): both ends compute
// it from what they share, the channel's id (the smaller of its two
// endpoints' koids, from CROI_INFO_HANDLE_BASIC) and the message's txid
// (its first four bytes), so a call and its reply share one flow and
// nothing extra is sent. splitmix64's finalizer over channel * golden
// ratio + txid.
static inline uint64_t croi_flow_id(uint64_t channel, uint32_t txid) {
  uint64_t z = channel * 0x9E3779B97F4A7C15ull + txid;
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
  return z ^ (z >> 31);
}
