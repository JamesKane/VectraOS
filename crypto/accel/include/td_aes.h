// SPDX-License-Identifier: BSD-3-Clause

// AES in the CPU's instructions (D153): AES-NI on amd64, the Armv8
// cryptography extension on arm64. TDCrypto's AES (crypto/lib/AES.swift)
// expands the keys and calls these when td_aes_hardware says so, and
// runs its own constant-time software otherwise. In C because Swift has
// no form of the instructions and no per-function target (D128).

#pragma once
#include <stddef.h>
#include <stdint.h>

/// 1 if this CPU runs the functions below: on amd64 and arm64 when every
/// CPU has the instructions (the topology page's record, D128; clang's
/// ivybridge, amd64's floor, leaves AES-NI out, D52), never on rv64.
int td_aes_hardware(void);

/// XTS (IEEE 1619) over `blocks` 16-byte blocks of `data`, in place: the
/// data unit `unit`, whose tweak is `unit` little-endian encrypted under
/// `tweak_keys`. Key schedules are AES-256's 15 round keys, 240 bytes in
/// the state's byte order; `data_keys` for decrypting are the equivalent
/// inverse cipher's (FIPS 197 §5.3.5).
void td_aes_xts_encrypt(const uint8_t *data_keys, const uint8_t *tweak_keys, uint64_t unit, uint8_t *data,
                        size_t blocks);
void td_aes_xts_decrypt(const uint8_t *data_keys, const uint8_t *tweak_keys, uint64_t unit, uint8_t *data,
                        size_t blocks);
