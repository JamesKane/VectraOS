// The one ring (architecture §3, D43): its format, and its C23
// implementation for C-side drivers. Ring.swift (lib/ring/Ring) is the
// Swift one; both are model-checked by RingCheck (lib/ring/check) through
// the same hooks, and a host test pins the two formats equal. C because
// C-side drivers need it; everything here is a static inline function over
// shared memory, with no syscalls: the caller rings doorbells (counter_add
// on the other side's counter) and sleeps (port_wait) when it says to.
//
// Layout, in a VMO both sides map:
//   0    the producer's line: cursor (u64), waiting (u32)
//   128  the consumer's line: cursor (u64), waiting (u32)
//   256  the header (croi_ring_header_t)
//   384  slots[count], each slot_size bytes
// Cursors are free-running counts: a slot's index is cursor & (count - 1).
// Each line is 128 bytes, so neither side's writes share a cache line with
// the other's on 64- or 128-byte line machines.
//
// One producer and one consumer. The producer fills slots, then publishes
// them with a release store of its cursor; the consumer acquires the
// producer's cursor, copies each slot out exactly once, and releases them
// with a release store of its own cursor. Shared memory is hostile: the
// header is validated once and used from a private copy, and a cursor that
// runs past the other marks the ring broken for good.
//
// Waking (NeoVectra's vx-ring protocol, both ways). A side about to sleep
// sets its waiting word, fences (seq_cst), and looks once more; it sleeps
// only if there is still nothing to do. The other side, after moving its
// cursor, fences (seq_cst) and rings the sleeper's doorbell only if its
// waiting word is set. One of the two fences always sees the other side's
// store, so no wake is lost; while both sides are busy, neither enters the
// kernel (the ring_kicks budget).
//
// OVERWRITE (D38): a producer that never waits, and any number of readers
// that keep their cursors to themselves (the consumer's line stays zero).
// Each slot begins with its u64 sequence: the writer sets it to all ones,
// writes the rest, sets it to the slot's cursor, then publishes. A reader
// keeps a copy only if the sequence read its cursor before and after.
//
// BYTE_STREAM (D46): a byte stream, one writer and one reader. Each slot
// is a length (u32), flags (u32) and that many bytes, so the writer puts
// any amount (as many slots as it fills) and the reader takes any amount
// (a slot in more than one read, its header kept privately so each byte is
// copied out once). The end of input is a slot flagged END, after the
// stream's last bytes. The cursors and the wakes are the ring's.
#pragma once
#include <stdint.h>

enum : uint32_t {
  CROI_RING_MAGIC = 0x474e5256,  // "VRNG"
  CROI_RING_VERSION = 1,
  CROI_RING_PRODUCER_LINE = 0,
  CROI_RING_CONSUMER_LINE = 128,
  CROI_RING_HEADER = 256,
  CROI_RING_SLOTS = 384,
  CROI_RING_WAITING_OFFSET = 8,  // in each line: the side sleeps until its doorbell rings
  // croi_ring_header_t.flags.
  CROI_RING_OVERWRITE = 1u << 0,
  CROI_RING_BYTE_STREAM = 1u << 1,
  CROI_RING_FLAGS = CROI_RING_OVERWRITE | CROI_RING_BYTE_STREAM,
  // A byte-stream slot: its length (u32) and flags (u32), then its bytes.
  CROI_RING_STREAM_HEADER = 8,
  CROI_RING_STREAM_END = 1u << 0,
  // Slots: a multiple of 8 bytes, up to 64 KiB; a power of two of them, up to 2^20.
  CROI_RING_MAX_SLOT_SIZE = 65536,
  CROI_RING_MAX_SLOTS = 1u << 20,
};

typedef struct {
  uint32_t magic;
  uint16_t version;
  uint16_t flags;
  uint32_t slot_size;
  uint32_t slot_count;
  uint64_t format;  // what a slot holds: a descriptor both sides agree on
  uint64_t reserved[13];
} croi_ring_header_t;

static_assert(sizeof(croi_ring_header_t) == 128);

// The memory operations, which the model checker's build replaces
// (CROI_RING_CHECKED: lib/ring/check). Orders are C's __ATOMIC_*.
#ifdef CROI_RING_CHECKED
uint64_t croi_ring_check_load(const void *address, uint32_t size, int order);
void croi_ring_check_store(void *address, uint32_t size, uint64_t value, int order);
void croi_ring_check_fence(int order);
void croi_ring_check_copy(void *to, const void *from, uint64_t count);
#define CROI_RING_LOAD64(p, o) croi_ring_check_load((p), 8, (o))
#define CROI_RING_LOAD32(p, o) ((uint32_t)croi_ring_check_load((p), 4, (o)))
#define CROI_RING_STORE64(p, v, o) croi_ring_check_store((p), 8, (v), (o))
#define CROI_RING_STORE32(p, v, o) croi_ring_check_store((p), 4, (v), (o))
#define CROI_RING_FENCE(o) croi_ring_check_fence(o)
#define CROI_RING_COPY(to, from, n) croi_ring_check_copy((to), (from), (n))
#else
#define CROI_RING_LOAD64(p, o) __atomic_load_n((const uint64_t *)(p), (o))
#define CROI_RING_LOAD32(p, o) __atomic_load_n((const uint32_t *)(p), (o))
#define CROI_RING_STORE64(p, v, o) __atomic_store_n((uint64_t *)(p), (v), (o))
#define CROI_RING_STORE32(p, v, o) __atomic_store_n((uint32_t *)(p), (v), (o))
#define CROI_RING_FENCE(o) __atomic_thread_fence(o)
#define CROI_RING_COPY(to, from, n) __builtin_memcpy((to), (from), (n))
#endif

// One side's private view of a ring.
typedef struct {
  uint8_t *base;
  croi_ring_header_t header;  // the validated copy; the shared one is never read again
  uint64_t mask;
  uint64_t cursor;     // this side's: the producer's tail, the consumer's head, a reader's own
  uint64_t other;      // the other side's cursor, as last seen
  uint8_t *own_line;   // this side's line (a reader's: none)
  uint8_t *other_line;
  bool producer;
  bool broken;         // the other side broke the protocol: every call fails from here on
  // BYTE_STREAM's reader: the head slot's length (-1: not read yet) and
  // flags, the bytes taken from it, and whether the end mark has come.
  int64_t stream_length;
  uint32_t stream_flags;
  uint32_t stream_taken;
  bool ended;
} croi_ring_t;

// The bytes a ring of `count` slots of `slot_size` takes; 0 if the
// parameters aren't valid.
static inline uint64_t croi_ring_size(uint32_t slot_size, uint32_t count) {
  if (slot_size == 0 || slot_size % 8 || slot_size > CROI_RING_MAX_SLOT_SIZE) return 0;
  if (count == 0 || count > CROI_RING_MAX_SLOTS || (count & (count - 1))) return 0;
  return CROI_RING_SLOTS + (uint64_t)slot_size * count;
}

// Makes a ring in `size` bytes of zeroed memory at `base`: whoever creates
// the VMO does this once, before either side attaches. False if the
// parameters aren't valid or don't fit.
static inline bool croi_ring_create(void *base, uint64_t size, uint32_t slot_size, uint32_t count,
                                    uint64_t format, uint16_t flags) {
  uint64_t need = croi_ring_size(slot_size, count);
  if (need == 0 || need > size || (flags & ~CROI_RING_FLAGS)) return false;
  if (flags == (CROI_RING_OVERWRITE | CROI_RING_BYTE_STREAM)) return false;
  if ((flags & CROI_RING_BYTE_STREAM) && slot_size <= CROI_RING_STREAM_HEADER) return false;
  croi_ring_header_t header = {.magic = CROI_RING_MAGIC, .version = CROI_RING_VERSION, .flags = flags,
                               .slot_size = slot_size, .slot_count = count, .format = format};
  CROI_RING_COPY((uint8_t *)base + CROI_RING_HEADER, &header, sizeof header);
  return true;
}

// Attaches to the ring mapped at `base` (`size` bytes mapped) as its
// producer or its consumer (an OVERWRITE ring's writer or a reader). The
// header must say what this side expects: whoever made the ring may be
// hostile, and the slot size decides how much each copy writes. Takes the
// cursors as they stand. False (and every later call failing) otherwise.
static inline bool croi_ring_attach(croi_ring_t *r, void *base, uint64_t size, bool producer, uint32_t slot_size,
                                    uint64_t format, uint16_t flags) {
  *r = (croi_ring_t){.broken = true};
  croi_ring_header_t h;
  if (size < CROI_RING_SLOTS) return false;
  CROI_RING_COPY(&h, (uint8_t *)base + CROI_RING_HEADER, sizeof h);
  uint64_t need = croi_ring_size(h.slot_size, h.slot_count);
  if (h.magic != CROI_RING_MAGIC || h.version != CROI_RING_VERSION || h.flags != flags ||
      h.slot_size != slot_size || h.format != format || need == 0 || need > size)
    return false;
  if ((flags & CROI_RING_BYTE_STREAM) && slot_size <= CROI_RING_STREAM_HEADER) return false;
  uint8_t *b = (uint8_t *)base;
  uint8_t *producer_line = b + CROI_RING_PRODUCER_LINE, *consumer_line = b + CROI_RING_CONSUMER_LINE;
  *r = (croi_ring_t){.base = b, .header = h, .mask = h.slot_count - 1, .producer = producer, .stream_length = -1};
  if (flags & CROI_RING_OVERWRITE) {
    r->own_line = producer ? producer_line : nullptr;
    r->other_line = producer_line;
    // The writer goes on from its cursor; a reader starts at the oldest
    // record still there.
    uint64_t tail = CROI_RING_LOAD64(producer_line, __ATOMIC_ACQUIRE);
    if (producer) r->cursor = tail;
    else r->cursor = tail < h.slot_count ? 0 : tail - h.slot_count;
    return true;
  }
  r->own_line = producer ? producer_line : consumer_line;
  r->other_line = producer ? consumer_line : producer_line;
  r->cursor = CROI_RING_LOAD64(r->own_line, __ATOMIC_RELAXED);
  r->other = CROI_RING_LOAD64(r->other_line, __ATOMIC_ACQUIRE);
  return true;
}

static inline uint8_t *croi_ring_slot_at(const croi_ring_t *r, uint64_t cursor) {
  return r->base + CROI_RING_SLOTS + (cursor & r->mask) * r->header.slot_size;
}

// --- The producer ---

// How many slots are free to fill (0: full, or broken).
static inline uint64_t croi_ring_space(croi_ring_t *r) {
  if (r->broken) return 0;
  r->other = CROI_RING_LOAD64(r->other_line, __ATOMIC_ACQUIRE);
  uint64_t used = r->cursor - r->other;
  if (used > r->header.slot_count) {  // the consumer's head ran past our tail
    r->broken = true;
    return 0;
  }
  return r->header.slot_count - used;
}

// The `i`th free slot (i < croi_ring_space), to fill in place. Nothing is
// visible to the consumer until croi_ring_publish.
static inline void *croi_ring_slot(const croi_ring_t *r, uint64_t i) { return croi_ring_slot_at(r, r->cursor + i); }

// Copies a slot's worth of bytes from `from` into the `i`th free slot.
static inline void croi_ring_put(croi_ring_t *r, uint64_t i, const void *from) {
  CROI_RING_COPY(croi_ring_slot(r, i), from, r->header.slot_size);
}

// Publishes the next `count` slots. True if the consumer sleeps, and its
// doorbell must be rung.
static inline bool croi_ring_publish(croi_ring_t *r, uint64_t count) {
  r->cursor += count;
  CROI_RING_STORE64(r->own_line, r->cursor, __ATOMIC_RELEASE);
  CROI_RING_FENCE(__ATOMIC_SEQ_CST);
  return CROI_RING_LOAD32(r->other_line + CROI_RING_WAITING_OFFSET, __ATOMIC_RELAXED) != 0;
}

// --- The consumer ---

// How many slots are ready to read (0: empty, or broken).
static inline uint64_t croi_ring_ready(croi_ring_t *r) {
  if (r->broken) return 0;
  r->other = CROI_RING_LOAD64(r->other_line, __ATOMIC_ACQUIRE);
  uint64_t ready = r->other - r->cursor;
  if (ready > r->header.slot_count) {  // the producer's tail ran ahead of what fits
    r->broken = true;
    return 0;
  }
  return ready;
}

// Copies the `i`th ready slot (i < croi_ring_ready) out to `to`.
static inline void croi_ring_get(croi_ring_t *r, uint64_t i, void *to) {
  CROI_RING_COPY(to, croi_ring_slot_at(r, r->cursor + i), r->header.slot_size);
}

// Frees the next `count` slots. True if the producer sleeps waiting for
// space, and its doorbell must be rung.
static inline bool croi_ring_release(croi_ring_t *r, uint64_t count) {
  r->cursor += count;
  CROI_RING_STORE64(r->own_line, r->cursor, __ATOMIC_RELEASE);
  CROI_RING_FENCE(__ATOMIC_SEQ_CST);
  return CROI_RING_LOAD32(r->other_line + CROI_RING_WAITING_OFFSET, __ATOMIC_RELAXED) != 0;
}

// --- Sleeping, either side ---

// About to sleep (the consumer on an empty ring, the producer on a full
// one): says so, then looks once more. True if there is still nothing to
// do, and the caller may wait for its doorbell; false if the other side
// moved meanwhile (and the announcement is withdrawn).
static inline bool croi_ring_prepare_sleep(croi_ring_t *r) {
  if (r->broken) return false;
  CROI_RING_STORE32(r->own_line + CROI_RING_WAITING_OFFSET, 1, __ATOMIC_RELAXED);
  CROI_RING_FENCE(__ATOMIC_SEQ_CST);
  uint64_t other = CROI_RING_LOAD64(r->other_line, __ATOMIC_ACQUIRE);
  bool idle = r->producer ? r->cursor - other == r->header.slot_count : other == r->cursor;
  if (!idle) CROI_RING_STORE32(r->own_line + CROI_RING_WAITING_OFFSET, 0, __ATOMIC_RELAXED);
  return idle;
}

// Awake: the other side need not ring until the next croi_ring_prepare_sleep.
static inline void croi_ring_end_sleep(croi_ring_t *r) {
  CROI_RING_STORE32(r->own_line + CROI_RING_WAITING_OFFSET, 0, __ATOMIC_RELAXED);
}

// --- OVERWRITE ---

// Writes a slot's worth of bytes from `from` (its first 8, the sequence,
// are the ring's) as the next record, overwriting the oldest. Never waits.
static inline void croi_ring_write(croi_ring_t *r, const void *from) {
  uint8_t *slot = croi_ring_slot_at(r, r->cursor);
  CROI_RING_STORE64(slot, ~0ull, __ATOMIC_RELAXED);
  CROI_RING_FENCE(__ATOMIC_RELEASE);  // the mark before the bytes
  CROI_RING_COPY(slot + 8, (const uint8_t *)from + 8, r->header.slot_size - 8);
  CROI_RING_STORE64(slot, r->cursor, __ATOMIC_RELEASE);
  r->cursor++;
  CROI_RING_STORE64(r->own_line, r->cursor, __ATOMIC_RELEASE);
}

// Copies the next record out to `to`. True if there was one; `dropped`
// grows by the records the writer overwrote before this reader got to
// them. A record whose sequence isn't its cursor, before or after the copy,
// has been overwritten (or is being): it is dropped, and the reader goes on
// to the next, so a writer stopped halfway never holds a reader up.
static inline bool croi_ring_read(croi_ring_t *r, void *to, uint64_t *dropped) {
  if (r->broken) return false;
  for (;;) {
    uint64_t tail = CROI_RING_LOAD64(r->other_line, __ATOMIC_ACQUIRE);
    if (tail == r->cursor) return false;
    if (tail - r->cursor > r->header.slot_count) {  // lapped: skip to the oldest still there
      *dropped += tail - r->header.slot_count - r->cursor;
      r->cursor = tail - r->header.slot_count;
    }
    uint8_t *slot = croi_ring_slot_at(r, r->cursor);
    if (CROI_RING_LOAD64(slot, __ATOMIC_ACQUIRE) == r->cursor) {
      CROI_RING_COPY(to, slot, r->header.slot_size);
      CROI_RING_FENCE(__ATOMIC_ACQUIRE);  // the bytes before the second look
      if (CROI_RING_LOAD64(slot, __ATOMIC_RELAXED) == r->cursor) {
        r->cursor++;
        return true;
      }
    }
    *dropped += 1;
    r->cursor++;
  }
}


// --- BYTE_STREAM ---

// The producer's: writes up to `count` bytes from `from`, up to a slot's
// payload a slot, in as many slots as are free. How many bytes went (0:
// full); *wake says whether the reader sleeps, and its doorbell must ring.
static inline uint64_t croi_ring_write_bytes(croi_ring_t *r, const void *from, uint64_t count, bool *wake) {
  uint64_t payload = r->header.slot_size - CROI_RING_STREAM_HEADER;
  uint64_t free = croi_ring_space(r), used = 0, written = 0;
  *wake = false;
  while (used < free && written < count) {
    uint64_t take = count - written < payload ? count - written : payload;
    uint8_t *slot = (uint8_t *)croi_ring_slot(r, used);
    uint64_t head = take;  // little-endian: the length, then no flags
    CROI_RING_COPY(slot, &head, CROI_RING_STREAM_HEADER);
    CROI_RING_COPY(slot + CROI_RING_STREAM_HEADER, (const uint8_t *)from + written, take);
    written += take;
    used++;
  }
  if (used) *wake = croi_ring_publish(r, used);
  return written;
}

// The producer's: the end mark, a slot of no bytes after all the others.
// False if the ring is full (try again when it has room).
static inline bool croi_ring_write_end(croi_ring_t *r, bool *wake) {
  *wake = false;
  if (croi_ring_space(r) == 0) return false;
  uint64_t head = (uint64_t)CROI_RING_STREAM_END << 32;
  CROI_RING_COPY(croi_ring_slot(r, 0), &head, CROI_RING_STREAM_HEADER);
  *wake = croi_ring_publish(r, 1);
  return true;
}

// The consumer's: copies up to `max` bytes to `to`, from as many slots as
// are ready, taking a slot's bytes in more than one read if `max` falls
// inside it. How many bytes came; *ended says the end mark followed them
// (and stays set), *wake that the writer sleeps waiting for room. A slot
// whose header is nonsense breaks the ring.
static inline uint64_t croi_ring_read_bytes(croi_ring_t *r, void *to, uint64_t max, bool *ended, bool *wake) {
  *wake = false;
  *ended = r->ended;
  if (r->ended) return 0;
  uint64_t available = croi_ring_ready(r), got = 0, freed = 0;
  while (freed < available && !r->ended) {
    uint8_t *slot = croi_ring_slot_at(r, r->cursor + freed);
    if (r->stream_length < 0) {
      uint64_t head;
      CROI_RING_COPY(&head, slot, CROI_RING_STREAM_HEADER);
      uint32_t length = (uint32_t)head, flags = (uint32_t)(head >> 32);
      if (length > r->header.slot_size - CROI_RING_STREAM_HEADER || (flags & ~CROI_RING_STREAM_END)) {
        r->broken = true;
        break;
      }
      r->stream_length = length;
      r->stream_flags = flags;
    }
    uint64_t left = (uint64_t)r->stream_length - r->stream_taken;
    uint64_t take = left < max - got ? left : max - got;
    if (take) {
      CROI_RING_COPY((uint8_t *)to + got, slot + CROI_RING_STREAM_HEADER + r->stream_taken, take);
      got += take;
      r->stream_taken += (uint32_t)take;
    }
    if (r->stream_taken != (uint64_t)r->stream_length) break;  // `max` fell inside this slot
    freed++;
    r->ended = (r->stream_flags & CROI_RING_STREAM_END) != 0;
    r->stream_length = -1;
    r->stream_taken = 0;
  }
  if (freed) *wake = croi_ring_release(r, freed);
  *ended = r->ended;
  return got;
}
