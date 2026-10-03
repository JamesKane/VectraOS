// XXH64, the block hash (docs/11 §12), written from its specification
// (Yann Collet's xxHash, doc/xxhash_spec.md) and checked against vectors from
// the reference implementation (tests/host/vxfs_test.c). A 64-bit
// non-cryptographic hash: it catches failing media and bugs, not tampering.

#pragma once

#include "fs.h"

static constexpr uint64_t XXH_P1 = 0x9E3779B185EBCA87ull, XXH_P2 = 0xC2B2AE3D27D4EB4Full,
                          XXH_P3 = 0x165667B19E3779F9ull, XXH_P4 = 0x85EBCA77C2B2AE63ull,
                          XXH_P5 = 0x27D4EB2F165667C5ull;

static inline uint64_t xxh_rotl(uint64_t x, int r) { return x << r | x >> (64 - r); }

static inline uint64_t xxh_round(uint64_t acc, uint64_t lane) {
  acc += lane * XXH_P2;
  acc = xxh_rotl(acc, 31);
  return acc * XXH_P1;
}

static inline uint64_t xxh_merge(uint64_t acc, uint64_t v) {
  acc ^= xxh_round(0, v);
  return acc * XXH_P1 + XXH_P4;
}

[[maybe_unused]] static uint64_t vxfs_xxh64(const void *data, size_t len, uint64_t seed) {
  const uint8_t *p = data, *end = p + len;
  uint64_t h;
  if (len >= 32) {
    uint64_t v1 = seed + XXH_P1 + XXH_P2, v2 = seed + XXH_P2, v3 = seed, v4 = seed - XXH_P1;
    for (; end - p >= 32; p += 32) {
      v1 = xxh_round(v1, vxfs_get64(p));
      v2 = xxh_round(v2, vxfs_get64(p + 8));
      v3 = xxh_round(v3, vxfs_get64(p + 16));
      v4 = xxh_round(v4, vxfs_get64(p + 24));
    }
    h = xxh_rotl(v1, 1) + xxh_rotl(v2, 7) + xxh_rotl(v3, 12) + xxh_rotl(v4, 18);
    h = xxh_merge(h, v1);
    h = xxh_merge(h, v2);
    h = xxh_merge(h, v3);
    h = xxh_merge(h, v4);
  } else {
    h = seed + XXH_P5;
  }
  h += len;
  for (; end - p >= 8; p += 8) {
    h ^= xxh_round(0, vxfs_get64(p));
    h = xxh_rotl(h, 27) * XXH_P1 + XXH_P4;
  }
  if (end - p >= 4) {
    h ^= (uint64_t)vxfs_get32(p) * XXH_P1;
    h = xxh_rotl(h, 23) * XXH_P2 + XXH_P3;
    p += 4;
  }
  for (; p < end; p++) {
    h ^= *p * XXH_P5;
    h = xxh_rotl(h, 11) * XXH_P1;
  }
  h ^= h >> 33;
  h *= XXH_P2;
  h ^= h >> 29;
  h *= XXH_P3;
  h ^= h >> 32;
  return h;
}
