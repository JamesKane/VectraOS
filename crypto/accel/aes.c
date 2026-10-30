// SPDX-License-Identifier: BSD-3-Clause

// AES-256-XTS in the CPU's instructions (td_aes.h, D153): AES-NI on
// amd64, the Armv8 cryptography extension (AESE, AESMC, AESD, AESIMC) on
// arm64, four blocks at a time so the rounds of one overlap the next's.
// The tweak goes from block to block as two 64-bit words, its carry made a
// mask, as the software does (crypto/lib/AES.swift). In C because Swift
// has no form of these instructions and no per-function target attribute
// (D128): a function here names the instructions it uses.

#include "td_aes.h"

/// The tweak of a block, little-endian in two words.
typedef struct {
  uint64_t lo, hi;
} tweak_t;

/// The next block's: multiplied by x in GF(2^128) (IEEE 1619 §5.2).
static inline tweak_t next_tweak(tweak_t t) {
  uint64_t carry = t.hi >> 63;
  t.hi = t.hi << 1 | t.lo >> 63;
  t.lo = t.lo << 1 ^ (0x87 & (0 - carry));
  return t;
}

// Whether the instructions are there: on the device, the topology page's
// record (D128), which counts a feature every CPU has; on the host, where
// the tests run, the CPU asked.
#if !__STDC_HOSTED__ && (defined(__x86_64__) || defined(__aarch64__))
#include "shared.h"  // CROI_FEATURE_AES

uint64_t td_cpu_features(void);  // the floor's

int td_aes_hardware(void) { return (td_cpu_features() & CROI_FEATURE_AES) != 0; }
#elif defined(__x86_64__)
#include <cpuid.h>

int td_aes_hardware(void) {
  unsigned a, b, c, d;
  return __get_cpuid(1, &a, &b, &c, &d) && (c >> 25 & 1);
}
#else
int td_aes_hardware(void) { return 0; }
#endif

#if defined(__x86_64__)
#include <immintrin.h>

#define TD_AES __attribute__((target("aes")))

static inline __m128i tweak_vector(tweak_t t) { return _mm_set_epi64x((long long)t.hi, (long long)t.lo); }

TD_AES static void load_keys(const uint8_t *keys, __m128i k[15]) {
  for (int i = 0; i < 15; i++) k[i] = _mm_loadu_si128((const __m128i *)(keys + 16 * i));
}

TD_AES static tweak_t first_tweak(const uint8_t *tweak_keys, uint64_t unit) {
  __m128i k[15];
  load_keys(tweak_keys, k);
  __m128i s = _mm_xor_si128(_mm_set_epi64x(0, (long long)unit), k[0]);
  for (int i = 1; i < 14; i++) s = _mm_aesenc_si128(s, k[i]);
  s = _mm_aesenclast_si128(s, k[14]);
  uint64_t w[2];
  _mm_storeu_si128((__m128i *)w, s);
  return (tweak_t){w[0], w[1]};
}

TD_AES void td_aes_xts_encrypt(const uint8_t *data_keys, const uint8_t *tweak_keys, uint64_t unit, uint8_t *data,
                               size_t blocks) {
  __m128i k[15];
  load_keys(data_keys, k);
  tweak_t t = first_tweak(tweak_keys, unit);
  size_t i = 0;
  for (; i + 4 <= blocks; i += 4) {
    tweak_t t1 = next_tweak(t), t2 = next_tweak(t1), t3 = next_tweak(t2);
    __m128i w0 = tweak_vector(t), w1 = tweak_vector(t1), w2 = tweak_vector(t2), w3 = tweak_vector(t3);
    __m128i *p = (__m128i *)(data + 16 * i);
    __m128i s0 = _mm_xor_si128(_mm_xor_si128(_mm_loadu_si128(p), w0), k[0]);
    __m128i s1 = _mm_xor_si128(_mm_xor_si128(_mm_loadu_si128(p + 1), w1), k[0]);
    __m128i s2 = _mm_xor_si128(_mm_xor_si128(_mm_loadu_si128(p + 2), w2), k[0]);
    __m128i s3 = _mm_xor_si128(_mm_xor_si128(_mm_loadu_si128(p + 3), w3), k[0]);
    for (int r = 1; r < 14; r++) {
      s0 = _mm_aesenc_si128(s0, k[r]);
      s1 = _mm_aesenc_si128(s1, k[r]);
      s2 = _mm_aesenc_si128(s2, k[r]);
      s3 = _mm_aesenc_si128(s3, k[r]);
    }
    _mm_storeu_si128(p, _mm_xor_si128(_mm_aesenclast_si128(s0, k[14]), w0));
    _mm_storeu_si128(p + 1, _mm_xor_si128(_mm_aesenclast_si128(s1, k[14]), w1));
    _mm_storeu_si128(p + 2, _mm_xor_si128(_mm_aesenclast_si128(s2, k[14]), w2));
    _mm_storeu_si128(p + 3, _mm_xor_si128(_mm_aesenclast_si128(s3, k[14]), w3));
    t = next_tweak(t3);
  }
  for (; i < blocks; i++) {
    __m128i w = tweak_vector(t), *p = (__m128i *)(data + 16 * i);
    __m128i s = _mm_xor_si128(_mm_xor_si128(_mm_loadu_si128(p), w), k[0]);
    for (int r = 1; r < 14; r++) s = _mm_aesenc_si128(s, k[r]);
    _mm_storeu_si128(p, _mm_xor_si128(_mm_aesenclast_si128(s, k[14]), w));
    t = next_tweak(t);
  }
}

TD_AES void td_aes_xts_decrypt(const uint8_t *data_keys, const uint8_t *tweak_keys, uint64_t unit, uint8_t *data,
                               size_t blocks) {
  __m128i k[15];
  load_keys(data_keys, k);
  tweak_t t = first_tweak(tweak_keys, unit);
  size_t i = 0;
  for (; i + 4 <= blocks; i += 4) {
    tweak_t t1 = next_tweak(t), t2 = next_tweak(t1), t3 = next_tweak(t2);
    __m128i w0 = tweak_vector(t), w1 = tweak_vector(t1), w2 = tweak_vector(t2), w3 = tweak_vector(t3);
    __m128i *p = (__m128i *)(data + 16 * i);
    __m128i s0 = _mm_xor_si128(_mm_xor_si128(_mm_loadu_si128(p), w0), k[0]);
    __m128i s1 = _mm_xor_si128(_mm_xor_si128(_mm_loadu_si128(p + 1), w1), k[0]);
    __m128i s2 = _mm_xor_si128(_mm_xor_si128(_mm_loadu_si128(p + 2), w2), k[0]);
    __m128i s3 = _mm_xor_si128(_mm_xor_si128(_mm_loadu_si128(p + 3), w3), k[0]);
    for (int r = 1; r < 14; r++) {
      s0 = _mm_aesdec_si128(s0, k[r]);
      s1 = _mm_aesdec_si128(s1, k[r]);
      s2 = _mm_aesdec_si128(s2, k[r]);
      s3 = _mm_aesdec_si128(s3, k[r]);
    }
    _mm_storeu_si128(p, _mm_xor_si128(_mm_aesdeclast_si128(s0, k[14]), w0));
    _mm_storeu_si128(p + 1, _mm_xor_si128(_mm_aesdeclast_si128(s1, k[14]), w1));
    _mm_storeu_si128(p + 2, _mm_xor_si128(_mm_aesdeclast_si128(s2, k[14]), w2));
    _mm_storeu_si128(p + 3, _mm_xor_si128(_mm_aesdeclast_si128(s3, k[14]), w3));
    t = next_tweak(t3);
  }
  for (; i < blocks; i++) {
    __m128i w = tweak_vector(t), *p = (__m128i *)(data + 16 * i);
    __m128i s = _mm_xor_si128(_mm_xor_si128(_mm_loadu_si128(p), w), k[0]);
    for (int r = 1; r < 14; r++) s = _mm_aesdec_si128(s, k[r]);
    _mm_storeu_si128(p, _mm_xor_si128(_mm_aesdeclast_si128(s, k[14]), w));
    t = next_tweak(t);
  }
}

#elif defined(__aarch64__)
#include <arm_neon.h>

#define TD_AES __attribute__((target("aes")))

static inline uint8x16_t tweak_vector(tweak_t t) {
  return vreinterpretq_u8_u64(vcombine_u64(vcreate_u64(t.lo), vcreate_u64(t.hi)));
}

static void load_keys(const uint8_t *keys, uint8x16_t k[15]) {
  for (int i = 0; i < 15; i++) k[i] = vld1q_u8(keys + 16 * i);
}

// AESE is AddRoundKey, ShiftRows and SubBytes; AESMC MixColumns.
TD_AES static tweak_t first_tweak(const uint8_t *tweak_keys, uint64_t unit) {
  uint8x16_t k[15];
  load_keys(tweak_keys, k);
  uint8x16_t s = tweak_vector((tweak_t){unit, 0});
  for (int i = 0; i < 13; i++) s = vaesmcq_u8(vaeseq_u8(s, k[i]));
  s = veorq_u8(vaeseq_u8(s, k[13]), k[14]);
  uint64x2_t w = vreinterpretq_u64_u8(s);
  return (tweak_t){vgetq_lane_u64(w, 0), vgetq_lane_u64(w, 1)};
}

TD_AES void td_aes_xts_encrypt(const uint8_t *data_keys, const uint8_t *tweak_keys, uint64_t unit, uint8_t *data,
                               size_t blocks) {
  uint8x16_t k[15];
  load_keys(data_keys, k);
  tweak_t t = first_tweak(tweak_keys, unit);
  size_t i = 0;
  for (; i + 4 <= blocks; i += 4) {
    tweak_t t1 = next_tweak(t), t2 = next_tweak(t1), t3 = next_tweak(t2);
    uint8x16_t w0 = tweak_vector(t), w1 = tweak_vector(t1), w2 = tweak_vector(t2), w3 = tweak_vector(t3);
    uint8_t *p = data + 16 * i;
    uint8x16_t s0 = veorq_u8(vld1q_u8(p), w0), s1 = veorq_u8(vld1q_u8(p + 16), w1);
    uint8x16_t s2 = veorq_u8(vld1q_u8(p + 32), w2), s3 = veorq_u8(vld1q_u8(p + 48), w3);
    for (int r = 0; r < 13; r++) {
      s0 = vaesmcq_u8(vaeseq_u8(s0, k[r]));
      s1 = vaesmcq_u8(vaeseq_u8(s1, k[r]));
      s2 = vaesmcq_u8(vaeseq_u8(s2, k[r]));
      s3 = vaesmcq_u8(vaeseq_u8(s3, k[r]));
    }
    vst1q_u8(p, veorq_u8(veorq_u8(vaeseq_u8(s0, k[13]), k[14]), w0));
    vst1q_u8(p + 16, veorq_u8(veorq_u8(vaeseq_u8(s1, k[13]), k[14]), w1));
    vst1q_u8(p + 32, veorq_u8(veorq_u8(vaeseq_u8(s2, k[13]), k[14]), w2));
    vst1q_u8(p + 48, veorq_u8(veorq_u8(vaeseq_u8(s3, k[13]), k[14]), w3));
    t = next_tweak(t3);
  }
  for (; i < blocks; i++) {
    uint8x16_t w = tweak_vector(t);
    uint8_t *p = data + 16 * i;
    uint8x16_t s = veorq_u8(vld1q_u8(p), w);
    for (int r = 0; r < 13; r++) s = vaesmcq_u8(vaeseq_u8(s, k[r]));
    vst1q_u8(p, veorq_u8(veorq_u8(vaeseq_u8(s, k[13]), k[14]), w));
    t = next_tweak(t);
  }
}

// AESD is AddRoundKey, InvShiftRows and InvSubBytes; AESIMC
// InvMixColumns: the equivalent inverse cipher's schedule.
TD_AES void td_aes_xts_decrypt(const uint8_t *data_keys, const uint8_t *tweak_keys, uint64_t unit, uint8_t *data,
                               size_t blocks) {
  uint8x16_t k[15];
  load_keys(data_keys, k);
  tweak_t t = first_tweak(tweak_keys, unit);
  size_t i = 0;
  for (; i + 4 <= blocks; i += 4) {
    tweak_t t1 = next_tweak(t), t2 = next_tweak(t1), t3 = next_tweak(t2);
    uint8x16_t w0 = tweak_vector(t), w1 = tweak_vector(t1), w2 = tweak_vector(t2), w3 = tweak_vector(t3);
    uint8_t *p = data + 16 * i;
    uint8x16_t s0 = veorq_u8(vld1q_u8(p), w0), s1 = veorq_u8(vld1q_u8(p + 16), w1);
    uint8x16_t s2 = veorq_u8(vld1q_u8(p + 32), w2), s3 = veorq_u8(vld1q_u8(p + 48), w3);
    for (int r = 0; r < 13; r++) {
      s0 = vaesimcq_u8(vaesdq_u8(s0, k[r]));
      s1 = vaesimcq_u8(vaesdq_u8(s1, k[r]));
      s2 = vaesimcq_u8(vaesdq_u8(s2, k[r]));
      s3 = vaesimcq_u8(vaesdq_u8(s3, k[r]));
    }
    vst1q_u8(p, veorq_u8(veorq_u8(vaesdq_u8(s0, k[13]), k[14]), w0));
    vst1q_u8(p + 16, veorq_u8(veorq_u8(vaesdq_u8(s1, k[13]), k[14]), w1));
    vst1q_u8(p + 32, veorq_u8(veorq_u8(vaesdq_u8(s2, k[13]), k[14]), w2));
    vst1q_u8(p + 48, veorq_u8(veorq_u8(vaesdq_u8(s3, k[13]), k[14]), w3));
    t = next_tweak(t3);
  }
  for (; i < blocks; i++) {
    uint8x16_t w = tweak_vector(t);
    uint8_t *p = data + 16 * i;
    uint8x16_t s = veorq_u8(vld1q_u8(p), w);
    for (int r = 0; r < 13; r++) s = vaesimcq_u8(vaesdq_u8(s, k[r]));
    vst1q_u8(p, veorq_u8(veorq_u8(vaesdq_u8(s, k[13]), k[14]), w));
    t = next_tweak(t);
  }
}

#else
// No AES instructions (rv64: neither Zkn nor Zvkn is in its tiers, D128):
// the software is AES.swift's.
void td_aes_xts_encrypt(const uint8_t *data_keys, const uint8_t *tweak_keys, uint64_t unit, uint8_t *data,
                        size_t blocks) {
  (void)data_keys, (void)tweak_keys, (void)unit, (void)data, (void)blocks;
  __builtin_trap();
}

void td_aes_xts_decrypt(const uint8_t *data_keys, const uint8_t *tweak_keys, uint64_t unit, uint8_t *data,
                        size_t blocks) {
  (void)data_keys, (void)tweak_keys, (void)unit, (void)data, (void)blocks;
  __builtin_trap();
}
#endif
