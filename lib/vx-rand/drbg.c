// vx-rand: a deterministic random bit generator over SHA-256, in the manner
// of NIST SP 800-90A's Hash_DRBG, simplified. Its state is a 32-byte key and
// a counter. Output block i is SHA-256("out" || key || counter + i); after
// each request the key is replaced by SHA-256("key" || key || counter), so
// state taken later says nothing of output already given. Seeding and mixing
// replace the key by SHA-256("mix" || key || data).
//
// It is only as good as its seed: VectraOS's comes from the bootloader's
// entropy (Limine's, from the firmware and the CPU), which the kernel gives
// svcd, and svcd and every POSIX parent give each child a seed of its own
// from theirs (`entropy=` in the spawn message). No external symbol.

#pragma once

#include "../vx-sha256/sha256.c"

typedef struct vx_drbg {
  uint8_t key[32];
  uint64_t counter;
  bool seeded;
} vx_drbg;

static void vx_drbg_hash(const vx_drbg *d, const char tag[3], const void *data, size_t n, uint8_t out[32]) {
  vx_sha256 h = vx_sha256_begin();
  vx_sha256_add(&h, tag, 3);
  vx_sha256_add(&h, d->key, sizeof d->key);
  vx_sha256_add(&h, data, n);
  vx_sha256_end(&h, out);
}

// Adds data to the state. A generator is seeded once it has been given a
// seed (`seed` true), not by mixing alone.
[[maybe_unused]] static void vx_drbg_mix(vx_drbg *d, const void *data, size_t n, bool seed) {
  uint8_t key[32];
  vx_drbg_hash(d, "mix", data, n, key);
  memcpy(d->key, key, sizeof key);
  if (seed) d->seeded = true;
}

[[maybe_unused]] static void vx_drbg_read(vx_drbg *d, void *out, size_t n) {
  uint8_t *p = out, block[32];
  while (n) {
    uint64_t c = d->counter++;
    vx_drbg_hash(d, "out", &c, sizeof c, block);
    size_t k = n < sizeof block ? n : sizeof block;
    memcpy(p, block, k);
    p += k;
    n -= k;
  }
  uint64_t c = d->counter++;
  vx_drbg_hash(d, "key", &c, sizeof c, block);
  memcpy(d->key, block, sizeof block);
}
