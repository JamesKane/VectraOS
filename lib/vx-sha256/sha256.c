// vx-sha256: SHA-256 (FIPS 180-4). Used by `build vendor-check` to verify vendored
// trees against VENDOR.ndb, and anywhere else a published hash must be checked.
// Builds for the host and the target; no allocation, no library calls.

#include "../../abi/vx/abi.h"

typedef struct vx_sha256 {
  uint32_t state[8];
  uint64_t length; // bytes hashed so far
  uint8_t block[64];
  uint32_t used; // bytes waiting in block
} vx_sha256;

static const uint32_t SHA256_K[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

static inline uint32_t sha256_ror(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }

static void sha256_block(vx_sha256 *h, const uint8_t *p) {
  uint32_t w[64];
  for (size_t i = 0; i < 16; i++)
    w[i] =
        (uint32_t)p[4 * i] << 24 | (uint32_t)p[4 * i + 1] << 16 | (uint32_t)p[4 * i + 2] << 8 | p[4 * i + 3];
  for (int i = 16; i < 64; i++) {
    uint32_t s0 = sha256_ror(w[i - 15], 7) ^ sha256_ror(w[i - 15], 18) ^ (w[i - 15] >> 3);
    uint32_t s1 = sha256_ror(w[i - 2], 17) ^ sha256_ror(w[i - 2], 19) ^ (w[i - 2] >> 10);
    w[i] = w[i - 16] + s0 + w[i - 7] + s1;
  }
  uint32_t a = h->state[0], b = h->state[1], c = h->state[2], d = h->state[3];
  uint32_t e = h->state[4], f = h->state[5], g = h->state[6], k = h->state[7];
  for (int i = 0; i < 64; i++) {
    uint32_t t1 = k + (sha256_ror(e, 6) ^ sha256_ror(e, 11) ^ sha256_ror(e, 25)) + ((e & f) ^ (~e & g)) +
                  SHA256_K[i] + w[i];
    uint32_t t2 = (sha256_ror(a, 2) ^ sha256_ror(a, 13) ^ sha256_ror(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
    k = g;
    g = f;
    f = e;
    e = d + t1;
    d = c;
    c = b;
    b = a;
    a = t1 + t2;
  }
  h->state[0] += a;
  h->state[1] += b;
  h->state[2] += c;
  h->state[3] += d;
  h->state[4] += e;
  h->state[5] += f;
  h->state[6] += g;
  h->state[7] += k;
}

[[maybe_unused]] static vx_sha256 vx_sha256_begin(void) {
  return (vx_sha256){.state = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c,
                               0x1f83d9ab, 0x5be0cd19}};
}

[[maybe_unused]] static void vx_sha256_add(vx_sha256 *h, const void *data, size_t n) {
  const uint8_t *p = data;
  h->length += n;
  while (n) {
    uint32_t take = 64 - h->used;
    if (take > n) take = (uint32_t)n;
    for (uint32_t i = 0; i < take; i++) h->block[h->used + i] = p[i];
    h->used += take;
    p += take;
    n -= take;
    if (h->used == 64) {
      sha256_block(h, h->block);
      h->used = 0;
    }
  }
}

[[maybe_unused]] static void vx_sha256_end(vx_sha256 *h, uint8_t out[32]) {
  uint64_t bits = h->length * 8;
  uint8_t pad = 0x80;
  vx_sha256_add(h, &pad, 1);
  pad = 0;
  while (h->used != 56) vx_sha256_add(h, &pad, 1);
  uint8_t len[8];
  for (int i = 0; i < 8; i++) len[i] = (uint8_t)(bits >> (56 - 8 * i));
  vx_sha256_add(h, len, 8);
  for (size_t i = 0; i < 8; i++) {
    out[4 * i] = (uint8_t)(h->state[i] >> 24);
    out[4 * i + 1] = (uint8_t)(h->state[i] >> 16);
    out[4 * i + 2] = (uint8_t)(h->state[i] >> 8);
    out[4 * i + 3] = (uint8_t)h->state[i];
  }
}
