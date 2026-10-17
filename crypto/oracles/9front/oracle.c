// SPDX-License-Identifier: BSD-3-Clause

// libsec_oracle.h over 9front's libsec, beside it unchanged (D89). In C
// because libsec is; linked only into the crypto tests (D4).

#include "os.h"
#include <libsec.h>
#include <stdarg.h>
#include <stdio.h>
#include <sys/random.h>

#include "include/libsec_oracle.h"

// libsec calls it for a bad key or IV length, which the oracle never passes.
void sysfatal(char *format, ...) {
  va_list args;
  va_start(args, format);
  fputs("libsec: ", stderr);
  vfprintf(stderr, format, args);
  fputc('\n', stderr);
  va_end(args);
  abort();
}

// curve25519_dh_new's randomness, which the oracle never asks for.
void genrandom(uchar *p, int n) {
  while (n > 0) {
    ssize_t got = getrandom(p, n, 0);
    if (got <= 0) sysfatal("getrandom");
    p += got;
    n -= got;
  }
}

int libsec_sha256(const uint8_t *in, size_t n, uint8_t *out) {
  sha2_256((uchar *)in, n, out, nil);
  return 0;
}

int libsec_sha512(const uint8_t *in, size_t n, uint8_t *out) {
  sha2_512((uchar *)in, n, out, nil);
  return 0;
}

int libsec_md5(const uint8_t *in, size_t n, uint8_t out[16]) {
  md5((uchar *)in, n, out, nil);
  return 0;
}

int libsec_hmac_sha256(const uint8_t *key, size_t keyLength, const uint8_t *in, size_t n, uint8_t *out) {
  hmac_sha2_256((uchar *)in, n, (uchar *)key, keyLength, out, nil);
  return 0;
}

int libsec_pbkdf2_sha256(const uint8_t *password, size_t passwordLength, const uint8_t *salt, size_t saltLength,
                         int iterations, uint8_t *out, size_t length) {
  pbkdf2_x((uchar *)password, passwordLength, (uchar *)salt, saltLength, iterations, out, length, hmac_sha2_256,
           SHA2_256dlen);
  return 0;
}

int libsec_hkdf_sha256(const uint8_t *salt, size_t saltLength, const uint8_t *info, size_t infoLength,
                       const uint8_t *key, size_t keyLength, uint8_t *out, size_t length) {
  hkdf_x((uchar *)salt, saltLength, (uchar *)info, infoLength, (uchar *)key, keyLength, out, length, hmac_sha2_256,
         SHA2_256dlen);
  return 0;
}

int libsec_chacha20(const uint8_t key[32], const uint8_t iv[16], size_t nonceLength, const uint8_t *in, size_t n,
                    uint8_t *out) {
  if (nonceLength != 12 && nonceLength != 8) return -1;
  Chachastate s;
  // The counter is the IV's first 16 - nonceLength bytes, little-endian.
  u64int counter = 0;
  for (size_t i = 0; i < 16 - nonceLength; i++) counter |= (u64int)iv[i] << (8 * i);
  setupChachastate(&s, (uchar *)key, 32, (uchar *)iv + 16 - nonceLength, nonceLength, 20);
  chacha_setblock(&s, counter);
  memmove(out, in, n);
  chacha_encrypt(out, n, &s);
  return 0;
}

int libsec_poly1305(const uint8_t key[32], const uint8_t *in, size_t n, uint8_t out[16]) {
  poly1305((uchar *)in, n, (uchar *)key, 32, out, nil);
  return 0;
}

int libsec_chacha20_poly1305_seal(const uint8_t key[32], const uint8_t nonce[12], const uint8_t *aad, size_t aadLength,
                                  const uint8_t *in, size_t n, uint8_t *out) {
  Chachastate s;
  setupChachastate(&s, (uchar *)key, 32, (uchar *)nonce, 12, 20);
  memmove(out, in, n);
  ccpoly_encrypt(out, n, (uchar *)aad, aadLength, out + n, &s);
  return 0;
}

int libsec_x25519(const uint8_t privateKey[32], const uint8_t peer[32], uint8_t out[32]) {
  // x25519 clamps its arguments in place, then puts them back.
  uchar s[32], u[32];
  memcpy(s, privateKey, 32);
  memcpy(u, peer, 32);
  return x25519(out, s, u) ? 0 : -1;
}
