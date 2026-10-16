// SPDX-License-Identifier: BSD-3-Clause

// stdio on the one ring (D46): what a parent gives a child as CROI_PA_STDIO
// (processargs.h), whose argument says which part:
//   0  a VMO holding two byte-stream rings (ring.h's BYTE_STREAM): stdin
//      at TD_STDIO_IN, which the parent writes and the child reads, and
//      stdout at TD_STDIO_OUT, the other way (stderr is stdout's);
//   1  the child's doorbell, a counter the parent adds to when the child
//      sleeps (on an empty stdin or a full stdout);
//   2  the parent's doorbell, the other way;
//   3  a channel whose other end the parent holds: either end's closing
//      is the other side's end (its PEER_CLOSED).
// The floor attaches them at start (stdio.c); Sys's ChildStdio is the
// parent's side. A process given none writes stdout to the debuglog.

#pragma once
#include <stdint.h>

enum : uint64_t {
  TD_STDIO_SLOT_SIZE = 256,
  TD_STDIO_SLOTS = 16,
  TD_STDIO_IN = 0,
  TD_STDIO_OUT = 8192,
  TD_STDIO_SIZE = 16384,
  TD_STDIO_FORMAT = 0x4f494453,  // "SDIO"
};

enum : uint32_t {
  TD_STDIO_VMO = 0,
  TD_STDIO_CHILD_BELL = 1,
  TD_STDIO_PARENT_BELL = 2,
  TD_STDIO_CHANNEL = 3,
};

// The floor's side (stdio.c). td_stdio_start takes the handles at start;
// the rest return false (or -1) in a process given no stdio.
void td_stdio_start(void);
// Writes all of `bytes` to stdout, sleeping while the ring is full;
// dropped once the parent has gone.
bool td_stdio_write(const void *bytes, uint64_t n);
// Up to `n` bytes of stdin, sleeping until some come; 0 at its end (or
// once the parent has gone), -1 without stdio.
int64_t td_stdio_read(void *buffer, uint64_t n);
// stdout's end mark, at exit.
void td_stdio_end(void);
