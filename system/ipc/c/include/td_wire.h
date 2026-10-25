// SPDX-License-Identifier: BSD-3-Clause
//
// The IPC wire format (docs/wire-format.md) in C: message encoding and
// decoding, and a call helper over V1's calls (croi/syscall.h). Headers
// that idlc generates for each protocol are built on this one. Everything
// is static inline, so a C program needs only these headers and the kernel
// calls.
//
// Written from docs/wire-format.md, like system/ipc/wire (IPCWire), and kept
// byte-for-byte compatible with it by system/ipc/tests/c.

#ifndef TD_WIRE_H
#define TD_WIRE_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <croi/syscall.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TD_WIRE_VERSION 1u
#define TD_WIRE_HEADER_SIZE 16u
#define TD_WIRE_ERROR_INLINE_SIZE 8u
// A handle field that carries none (handle 0 is never a handle).
#define TD_WIRE_NO_HANDLE 0u

// Message kinds.
#define TD_WIRE_REQUEST 1u
#define TD_WIRE_REPLY 2u
#define TD_WIRE_EVENT 3u
// 4 and 5 are reserved (a cancel and an epitaph, which nothing sent: D137).

// Header flags (replies only); bit 0 is reserved (it was canceled: D137).
#define TD_WIRE_FLAG_ERROR (1u << 1)
#define TD_WIRE_FLAGS_KNOWN TD_WIRE_FLAG_ERROR

// Statuses beyond the kernel's: the peer broke the protocol, or the method
// failed with its own error (whose code is returned separately).
#define TD_ERR_PROTOCOL (-50)
#define TD_ERR_REMOTE (-51)

// A message: its bytes and handles. 64 KiB, so callers usually keep one
// rather than putting it on a small stack.
typedef struct td_wire_msg {
  _Alignas(8) uint8_t bytes[CROI_CHANNEL_MAX_BYTES];
  uint32_t byte_count;
  uint32_t handles[CROI_CHANNEL_MAX_HANDLES];
  uint32_t handle_count;
} td_wire_msg_t;

// A string or byte string: a pointer and a length. Decoded ones point into
// the message; strings are UTF-8 and not NUL-terminated.
typedef struct td_wire_str {
  const char *data;
  uint32_t len;
} td_wire_str_t;

typedef struct td_wire_bytes {
  const uint8_t *data;
  uint32_t len;
} td_wire_bytes_t;

// Where decoders put what doesn't fit in the message: vectors' elements and
// optional values. The caller provides the memory; decoding fails with
// CROI_ERR_BUFFER_TOO_SMALL when it runs out.
typedef struct td_wire_arena {
  uint8_t *base;
  uint32_t size;
  uint32_t used;
} td_wire_arena_t;

static inline void *td_wire_alloc(td_wire_arena_t *a, uint32_t size, uint32_t align) {
  if (!a) return NULL;
  uint32_t start = (a->used + align - 1) & ~(align - 1);
  if (start > a->size || size > a->size - start) return NULL;
  a->used = start + size;
  return a->base + start;
}

typedef struct td_wire_header {
  uint32_t txid;
  uint8_t kind;
  uint16_t flags;
  uint64_t ordinal;
} td_wire_header_t;

// Little-endian access, whatever the host's byte order.
static inline void td_wire_put(uint8_t *p, uint64_t v, unsigned size) {
  for (unsigned i = 0; i < size; i++) p[i] = (uint8_t)(v >> (8 * i));
}
static inline uint64_t td_wire_get(const uint8_t *p, unsigned size) {
  uint64_t v = 0;
  for (unsigned i = 0; i < size; i++) v |= (uint64_t)p[i] << (8 * i);
  return v;
}
static inline uint32_t td_wire_aligned(uint32_t n) { return (n + 7u) & ~7u; }

// ---- Encoding ------------------------------------------------------------

// Writes the header and reserves a zeroed inline part of inline_size bytes
// (rounded up to 8). Stores then go at offsets within the inline part.
static inline int32_t td_wire_begin(td_wire_msg_t *m, uint32_t txid, uint8_t kind, uint16_t flags,
                                        uint64_t ordinal, uint32_t inline_size) {
  uint32_t size = TD_WIRE_HEADER_SIZE + td_wire_aligned(inline_size);
  if (size > sizeof m->bytes) return CROI_ERR_OUT_OF_RANGE;
  memset(m->bytes, 0, size);
  td_wire_put(m->bytes + 0, txid, 4);
  m->bytes[4] = kind;
  m->bytes[5] = TD_WIRE_VERSION;
  td_wire_put(m->bytes + 6, flags, 2);
  td_wire_put(m->bytes + 8, ordinal, 8);
  m->byte_count = size;
  m->handle_count = 0;
  return CROI_OK;
}

// An integer of `size` bytes at `offset` from the body's start, in space
// already reserved: the inline part, or an out-of-line object.
static inline void td_wire_store(td_wire_msg_t *m, uint32_t offset, uint64_t v, unsigned size) {
  td_wire_put(m->bytes + TD_WIRE_HEADER_SIZE + offset, v, size);
}

// Reserves an out-of-line object of `size` bytes (padded to 8, zeroed); *base
// is its offset from the body's start.
static inline int32_t td_wire_reserve(td_wire_msg_t *m, uint32_t size, uint32_t *base) {
  uint32_t padded = td_wire_aligned(size);
  if (size > sizeof m->bytes || m->byte_count + padded > sizeof m->bytes) return CROI_ERR_OUT_OF_RANGE;
  memset(m->bytes + m->byte_count, 0, padded);
  *base = m->byte_count - TD_WIRE_HEADER_SIZE;
  m->byte_count += padded;
  return CROI_OK;
}

// A vector: count and presence at `offset`, and its element block reserved;
// element i starts at *base + i * elem_size.
static inline int32_t td_wire_store_vector(td_wire_msg_t *m, uint32_t offset, uint32_t count,
                                               uint32_t elem_size, uint32_t *base) {
  if (count > sizeof m->bytes / elem_size) return CROI_ERR_OUT_OF_RANGE;
  td_wire_store(m, offset, count, 8);
  td_wire_store(m, offset + 8, UINT64_MAX, 8);
  return td_wire_reserve(m, count * elem_size, base);
}

// A box: its presence at `offset`, and `size` bytes reserved at *base. An
// absent box, vector or string is left zero.
static inline int32_t td_wire_store_box(td_wire_msg_t *m, uint32_t offset, uint32_t size, uint32_t *base) {
  td_wire_store(m, offset, UINT64_MAX, 8);
  return td_wire_reserve(m, size, base);
}

// A byte string: count and presence inline, the bytes out of line.
static inline int32_t td_wire_store_bytes(td_wire_msg_t *m, uint32_t offset, const void *data,
                                              uint32_t count) {
  uint32_t padded = td_wire_aligned(count);
  if (count > sizeof m->bytes || m->byte_count + padded > sizeof m->bytes) return CROI_ERR_OUT_OF_RANGE;
  td_wire_store(m, offset, count, 8);
  td_wire_store(m, offset + 8, UINT64_MAX, 8);
  memset(m->bytes + m->byte_count, 0, padded);
  if (count) memcpy(m->bytes + m->byte_count, data, count);
  m->byte_count += padded;
  return CROI_OK;
}

// A handle, moved into the message (or absent, as TD_WIRE_NO_HANDLE).
static inline int32_t td_wire_store_handle(td_wire_msg_t *m, uint32_t offset, uint32_t h) {
  if (h == TD_WIRE_NO_HANDLE) {
    td_wire_store(m, offset, 0, 4);
    return CROI_OK;
  }
  if (m->handle_count >= CROI_CHANNEL_MAX_HANDLES) return CROI_ERR_OUT_OF_RANGE;
  td_wire_store(m, offset, UINT32_MAX, 4);
  m->handles[m->handle_count++] = h;
  return CROI_OK;
}

// ---- Decoding ------------------------------------------------------------
// Messages are untrusted: every read is checked, padding must be zero, and
// everything must be consumed. Failures return TD_ERR_PROTOCOL.

typedef struct td_wire_reader {
  const td_wire_msg_t *m;
  uint32_t inline_size;
  uint32_t next;         // the next out-of-line byte
  uint32_t next_handle;  // the next handle in the side array
} td_wire_reader_t;

static inline int32_t td_wire_header(const td_wire_msg_t *m, td_wire_header_t *h) {
  if (m->byte_count < TD_WIRE_HEADER_SIZE || m->byte_count % 8 || m->byte_count > sizeof m->bytes)
    return TD_ERR_PROTOCOL;
  if (m->bytes[5] != TD_WIRE_VERSION || m->bytes[4] < TD_WIRE_REQUEST || m->bytes[4] > TD_WIRE_EVENT)
    return TD_ERR_PROTOCOL;
  h->txid = (uint32_t)td_wire_get(m->bytes, 4);
  h->kind = m->bytes[4];
  h->flags = (uint16_t)td_wire_get(m->bytes + 6, 2);
  h->ordinal = td_wire_get(m->bytes + 8, 8);
  return (h->flags & ~TD_WIRE_FLAGS_KNOWN) ? TD_ERR_PROTOCOL : CROI_OK;
}

static inline int32_t td_wire_read_begin(td_wire_reader_t *r, const td_wire_msg_t *m, uint32_t inline_size) {
  td_wire_header_t h;
  if (td_wire_header(m, &h) != CROI_OK) return TD_ERR_PROTOCOL;
  r->m = m;
  r->inline_size = td_wire_aligned(inline_size);
  r->next = TD_WIRE_HEADER_SIZE + r->inline_size;
  r->next_handle = 0;
  return r->next <= m->byte_count ? CROI_OK : TD_ERR_PROTOCOL;
}

// An integer at `offset` from the body's start, in the inline part or an
// out-of-line object already taken.
static inline int32_t td_wire_load(const td_wire_reader_t *r, uint32_t offset, unsigned size, uint64_t *v) {
  if ((uint64_t)TD_WIRE_HEADER_SIZE + offset + size > r->next) return TD_ERR_PROTOCOL;
  *v = td_wire_get(r->m->bytes + TD_WIRE_HEADER_SIZE + offset, size);
  return CROI_OK;
}

static inline int32_t td_wire_check_padding(const td_wire_reader_t *r, uint32_t offset, uint32_t count) {
  if ((uint64_t)TD_WIRE_HEADER_SIZE + offset + count > r->next) return TD_ERR_PROTOCOL;
  for (uint32_t i = 0; i < count; i++)
    if (r->m->bytes[TD_WIRE_HEADER_SIZE + offset + i]) return TD_ERR_PROTOCOL;
  return CROI_OK;
}

static inline int32_t td_wire_load_bool(const td_wire_reader_t *r, uint32_t offset, uint8_t *v) {
  uint64_t raw;
  if (td_wire_load(r, offset, 1, &raw) != CROI_OK || raw > 1) return TD_ERR_PROTOCOL;
  *v = (uint8_t)raw;
  return CROI_OK;
}

// Takes the next out-of-line object, `size` bytes padded to 8 with zeros;
// *base is its offset from the body's start.
static inline int32_t td_wire_claim(td_wire_reader_t *r, uint64_t size, uint32_t *base) {
  uint64_t padded = (size + 7u) & ~(uint64_t)7u;
  if (padded > r->m->byte_count - r->next) return TD_ERR_PROTOCOL;
  for (uint64_t i = size; i < padded; i++)
    if (r->m->bytes[r->next + i]) return TD_ERR_PROTOCOL;
  *base = r->next - TD_WIRE_HEADER_SIZE;
  r->next += (uint32_t)padded;
  return CROI_OK;
}

// The presence of a vector or byte string at `offset`, without taking it: 1
// present, 0 absent (count zero), -1 malformed.
static inline int td_wire_presence(const td_wire_reader_t *r, uint32_t offset) {
  uint64_t n, presence;
  if (td_wire_load(r, offset, 8, &n) || td_wire_load(r, offset + 8, 8, &presence)) return -1;
  if (presence == UINT64_MAX) return 1;
  return presence == 0 && n == 0 ? 0 : -1;
}

// A vector at `offset`: its count, and its element block taken (element i at
// *base + i * elem_size). 1 present, 0 absent, -1 malformed.
static inline int td_wire_load_vector(td_wire_reader_t *r, uint32_t offset, uint32_t elem_size, uint32_t *count,
                                      uint32_t *base) {
  uint64_t n;
  int present = td_wire_presence(r, offset);
  if (present <= 0) return present;
  if (td_wire_load(r, offset, 8, &n) || n > (r->m->byte_count - r->next) / elem_size) return -1;
  *count = (uint32_t)n;
  return td_wire_claim(r, n * elem_size, base) == CROI_OK ? 1 : -1;
}

// A box at `offset`: its value's `size` bytes taken at *base. 1 present, 0
// absent, -1 malformed.
static inline int td_wire_load_box(td_wire_reader_t *r, uint32_t offset, uint32_t size, uint32_t *base) {
  uint64_t presence;
  if (td_wire_load(r, offset, 8, &presence)) return -1;
  if (presence == 0) return 0;
  if (presence != UINT64_MAX) return -1;
  return td_wire_claim(r, size, base) == CROI_OK ? 1 : -1;
}

// A byte string, as a pointer into the message (no copy).
static inline int32_t td_wire_load_bytes(td_wire_reader_t *r, uint32_t offset, const uint8_t **data,
                                             uint32_t *count) {
  uint32_t base;
  if (td_wire_load_vector(r, offset, 1, count, &base) != 1) return TD_ERR_PROTOCOL;
  *data = r->m->bytes + TD_WIRE_HEADER_SIZE + base;
  return CROI_OK;
}

// Whether data[0..count) is valid UTF-8 (Unicode §3.9, table 3-7): no
// overlong forms, no surrogates, nothing above U+10FFFF.
static inline int td_wire_utf8_valid(const uint8_t *s, uint32_t count) {
  uint32_t i = 0;
  while (i < count) {
    uint8_t c = s[i];
    uint32_t need;
    uint8_t lo = 0x80, hi = 0xbf;
    if (c < 0x80) { i++; continue; }
    else if (c >= 0xc2 && c <= 0xdf) need = 1;
    else if (c == 0xe0) { need = 2; lo = 0xa0; }
    else if (c >= 0xe1 && c <= 0xec) need = 2;
    else if (c == 0xed) { need = 2; hi = 0x9f; }
    else if (c >= 0xee && c <= 0xef) need = 2;
    else if (c == 0xf0) { need = 3; lo = 0x90; }
    else if (c >= 0xf1 && c <= 0xf3) need = 3;
    else if (c == 0xf4) { need = 3; hi = 0x8f; }
    else return 0;
    if (count - i <= need) return 0;
    if (s[i + 1] < lo || s[i + 1] > hi) return 0;
    for (uint32_t k = 2; k <= need; k++)
      if (s[i + k] < 0x80 || s[i + k] > 0xbf) return 0;
    i += need + 1;
  }
  return 1;
}

// A string: a byte string that must be valid UTF-8. Not NUL-terminated.
static inline int32_t td_wire_load_string(td_wire_reader_t *r, uint32_t offset, const char **text,
                                              uint32_t *len) {
  const uint8_t *data;
  if (td_wire_load_bytes(r, offset, &data, len) != CROI_OK || !td_wire_utf8_valid(data, *len))
    return TD_ERR_PROTOCOL;
  *text = (const char *)data;
  return CROI_OK;
}

// A handle that must be present. It becomes the caller's.
static inline int32_t td_wire_load_handle(td_wire_reader_t *r, uint32_t offset, uint32_t *h) {
  uint64_t marker;
  if (td_wire_load(r, offset, 4, &marker) != CROI_OK || marker != UINT32_MAX) return TD_ERR_PROTOCOL;
  if (r->next_handle >= r->m->handle_count) return TD_ERR_PROTOCOL;
  *h = r->m->handles[r->next_handle++];
  return CROI_OK;
}

// A handle that may be absent (TD_WIRE_NO_HANDLE).
static inline int32_t td_wire_load_handle_opt(td_wire_reader_t *r, uint32_t offset, uint32_t *h) {
  uint64_t marker;
  if (td_wire_load(r, offset, 4, &marker) != CROI_OK) return TD_ERR_PROTOCOL;
  if (marker == 0) {
    *h = TD_WIRE_NO_HANDLE;
    return CROI_OK;
  }
  return td_wire_load_handle(r, offset, h);
}

// Every byte and handle must have been consumed.
static inline int32_t td_wire_read_end(const td_wire_reader_t *r) {
  return r->next == r->m->byte_count && r->next_handle == r->m->handle_count ? CROI_OK : TD_ERR_PROTOCOL;
}

// Closes every handle a message carries: for a message that is dropped.
static inline void td_wire_close_handles(const td_wire_msg_t *m) {
  for (uint32_t i = 0; i < m->handle_count; i++) croi_handle_close(m->handles[i]);
}

// ---- Calls ---------------------------------------------------------------

// Calls: sends `request` (whose handles move) with channel_call, which
// writes a txid of the kernel's own into it and hands this caller the
// reply that echoes it, into `reply` (which may be `request`). Events that
// arrive meanwhile stay queued for the client's own reads. An error reply
// returns TD_ERR_REMOTE with *error_code set (positive: the method's own;
// negative: a framework status); a closed channel, CROI_ERR_PEER_CLOSED.
static inline int32_t td_wire_call(uint32_t channel, td_wire_msg_t *request, td_wire_msg_t *reply,
                                   int32_t *error_code) {
  croi_channel_call_args_t args = {
      (uint64_t)(uintptr_t)request->bytes, (uint64_t)(uintptr_t)request->handles,
      (uint64_t)(uintptr_t)reply->bytes,   (uint64_t)(uintptr_t)reply->handles,
      request->byte_count,                 request->handle_count,
      sizeof reply->bytes,                 CROI_CHANNEL_MAX_HANDLES,
  };
  uint32_t actual_bytes = 0, actual_handles = 0;
  int64_t s = croi_syscall6(CROI_SYS_CHANNEL_CALL, channel, 0, (uint64_t)INT64_MAX, (uint64_t)(uintptr_t)&args,
                            (uint64_t)(uintptr_t)&actual_bytes, (uint64_t)(uintptr_t)&actual_handles);
  if (s != CROI_OK) return (int32_t)s;
  reply->byte_count = actual_bytes;
  reply->handle_count = actual_handles;
  td_wire_header_t h;
  if (td_wire_header(reply, &h) != CROI_OK || h.kind != TD_WIRE_REPLY) {
    td_wire_close_handles(reply);
    return TD_ERR_PROTOCOL;
  }
  if (h.flags & TD_WIRE_FLAG_ERROR) {
    td_wire_reader_t r;
    uint64_t code;
    if (td_wire_read_begin(&r, reply, TD_WIRE_ERROR_INLINE_SIZE) || td_wire_load(&r, 0, 4, &code) ||
        td_wire_check_padding(&r, 4, 4) || td_wire_read_end(&r))
      return TD_ERR_PROTOCOL;
    *error_code = (int32_t)(uint32_t)code;
    return TD_ERR_REMOTE;
  }
  return CROI_OK;
}

#ifdef __cplusplus
}
#endif

#endif
