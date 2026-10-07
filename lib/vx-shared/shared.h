// <vx/shared.h> (01 §6.6, M6 step 6e1b3): a structure shared in a VMO and
// read in place, its links offsets from the VMO's start, every one checked
// against the VMO's bounds before it is followed, once per link. libvx's,
// in lib/ until libvx exists (6e2); it needs only abi.h.
//
// A reader that trusts its writer (a host's input to a plugin) may follow
// links unchecked; one that does not (a plugin's result) has the writer
// seal the VMO (vmo_seal) before it is sent, so the bytes cannot change
// after these checks, and checks each link with vx_shared_at or
// vx_shared_follow, as §4.3 asks of any shared memory.
//
// Links between VMOs are (slot, offset) pairs: the slot indexes a table at
// the head of the VMO, whose entries name the handles sent with the message
// by their position (Twizzler's foreign object table, positions in place of
// global ids): the reader maps each of those handles once, in order, and
// vx_shared_follow checks the slot against the table as it checks the
// offset against the VMO it names.

#pragma once

#include "../../abi/vx/abi.h"

// One VMO as the reader mapped it.
typedef struct vx_shared {
  const uint8_t *base;
  uint64_t size;
} vx_shared;

// The len bytes at off, if they lie wholly inside s and off is a multiple of
// align (a power of two); else null. No sum can wrap.
static inline const void *vx_shared_at(vx_shared s, uint64_t off, uint64_t len, uint64_t align) {
  if (!s.base || off > s.size || len > s.size - off || (align && (off & (align - 1)))) return nullptr;
  return s.base + off;
}

// A T at off in s, checked as vx_shared_at checks it; null if it is not there.
#define VX_SHARED_AT(s, off, T) ((const T *)vx_shared_at((s), (off), sizeof(T), alignof(T)))

// The n Ts of an array at off, checked whole; null if they are not all there.
static inline const void *vx_shared_array(vx_shared s, uint64_t off, uint64_t n, uint64_t each,
                                          uint64_t align) {
  if (each && n > UINT64_MAX / each) return nullptr;
  return vx_shared_at(s, off, n * each, align);
}

// A link into another VMO of the message: its slot in the table at the head
// of the VMO holding the link, and the offset in the VMO the slot names.
typedef struct vx_shared_link {
  uint32_t slot;
  uint32_t reserved; // 0
  uint64_t offset;
} vx_shared_link;

// The table at the head of a VMO with links: count entries, each the
// position of a handle in the message.
typedef struct vx_shared_table {
  uint32_t count;
  uint32_t position[];
} vx_shared_table;

// The len bytes link names, from the VMO from holds it in: the slot checked
// against from's table, the position against the n views the reader mapped
// (the message's handles, in order), and the offset against that view.
static inline const void *vx_shared_follow(vx_shared from, const vx_shared *views, uint32_t n,
                                           vx_shared_link link, uint64_t len, uint64_t align) {
  const vx_shared_table *t = VX_SHARED_AT(from, 0, vx_shared_table);
  if (!t || link.reserved) return nullptr;
  uint32_t count = *(const volatile uint32_t *)&t->count; // read once: an unsealed writer may change it
  if (link.slot >= count) return nullptr;
  const uint32_t *pos = vx_shared_array(from, sizeof *t, count, sizeof(uint32_t), alignof(uint32_t));
  uint32_t at = pos ? *(const volatile uint32_t *)&pos[link.slot] : n;
  if (at >= n) return nullptr;
  return vx_shared_at(views[at], link.offset, len, align);
}
