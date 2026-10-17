// SPDX-License-Identifier: BSD-3-Clause

// What 9gate's codec tests call in 9front's fcall(2): its own reading
// and writing of a message and a stat, in C because the files are
// 9front's, unchanged. Host only (D4).

#pragma once
#include <stdint.h>

// convM2S on exactly `n` bytes, then convS2M of what it read into `out`:
// the bytes written, or 0 if convM2S refused them (or `cap` is short).
uint32_t fcall_oracle_reencode(const uint8_t *in, uint32_t n, uint8_t *out, uint32_t cap);

// The same of a stat, through convM2D and convD2M, after statcheck.
uint32_t fcall_oracle_reencode_stat(const uint8_t *in, uint32_t n, uint8_t *out, uint32_t cap);
