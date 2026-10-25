// SPDX-License-Identifier: BSD-3-Clause

// 9front's libsec as a test oracle (D89): our crypto compared with it on
// random inputs. Only the crypto tests link it, never a build that ships
// (D4; crypto/README.md). In C because libsec is.

#pragma once
#include <stddef.h>
#include <stdint.h>

/// SHA-256 of `in` into `out` (32 bytes); 0 on success.
int libsec_sha256(const uint8_t *in, size_t n, uint8_t *out);

int libsec_sha512(const uint8_t *in, size_t n, uint8_t *out);

/// HMAC-SHA-256 of `in` under `key` into `out` (32 bytes); 0 on success.
int libsec_hmac_sha256(const uint8_t *key, size_t keyLength, const uint8_t *in, size_t n, uint8_t *out);

/// PBKDF2-HMAC-SHA-256 into `out` (`length` bytes); 0 on success.
int libsec_pbkdf2_sha256(const uint8_t *password, size_t passwordLength, const uint8_t *salt, size_t saltLength,
                         int iterations, uint8_t *out, size_t length);

/// HKDF-SHA-256 (RFC 5869) into `out` (`length` bytes); 0 on success.
int libsec_hkdf_sha256(const uint8_t *salt, size_t saltLength, const uint8_t *info, size_t infoLength,
                       const uint8_t *key, size_t keyLength, uint8_t *out, size_t length);

/// ChaCha20 under `key` with OpenSSL's 16-byte `iv`: a 32-bit counter
/// then a 96-bit nonce (RFC 8439), or a 64-bit counter then a 64-bit
/// nonce (the original), both little-endian; `nonceLength` says which (12
/// or 8). 0 on success.
int libsec_chacha20(const uint8_t key[32], const uint8_t iv[16], size_t nonceLength, const uint8_t *in, size_t n,
                    uint8_t *out);

int libsec_poly1305(const uint8_t key[32], const uint8_t *in, size_t n, uint8_t out[16]);

/// RFC 8439's AEAD: `out` is the ciphertext then the 16-byte tag.
int libsec_chacha20_poly1305_seal(const uint8_t key[32], const uint8_t nonce[12], const uint8_t *aad, size_t aadLength,
                                  const uint8_t *in, size_t n, uint8_t *out);

/// X25519 (RFC 7748); nonzero if the shared secret is all zeros.
int libsec_x25519(const uint8_t privateKey[32], const uint8_t peer[32], uint8_t out[32]);
