// SPDX-License-Identifier: BSD-3-Clause

// A process's descriptors on the one ring (D46): each descriptor a parent
// gives a child is one byte-stream ring (ring.h's BYTE_STREAM), one way,
// given as CROI_PA_STDIO (processargs.h) parts whose argument is
// td_stdio_arg(fd, part):
//   0  a VMO holding the ring, which the child reads (the parent writes);
//   1  or one the child writes (the parent reads): one of 0 and 1;
//   2  the child's doorbell, a counter the parent adds to when the child
//      sleeps (on an empty ring it reads, or a full one it writes);
//   3  the parent's doorbell, the other way;
//   4  a channel whose other end the parent holds: either end's closing
//      is the other side's end of this descriptor (its PEER_CLOSED).
// stdin is fd 0 and stdout fd 1; stderr is fd 2, or stdout's when a
// parent gives no fd 2. The floor attaches what it's given at start
// (stdio.c), up to TD_STDIO_FDS descriptors below TD_STDIO_FD_LIMIT; Sys's
// ChildStdio is the parent's side. A process given no fd 1 writes stdout
// to the debuglog.

#pragma once
#include <stdint.h>

enum : uint64_t {
  TD_STDIO_SLOT_SIZE = 256,
  TD_STDIO_SLOTS = 16,
  TD_STDIO_RING_SIZE = 8192,  // a descriptor's VMO: its ring alone
  TD_STDIO_FORMAT = 0x4f494453,  // "SDIO"
};

enum : uint32_t {
  TD_STDIO_VMO_IN = 0,
  TD_STDIO_VMO_OUT = 1,
  TD_STDIO_CHILD_BELL = 2,
  TD_STDIO_PARENT_BELL = 3,
  TD_STDIO_CHANNEL = 4,
  TD_STDIO_PARTS = 8,  // an argument's low 3 bits are the part, the rest the fd
  TD_STDIO_FDS = 16,
  TD_STDIO_FD_LIMIT = 64,
};

static inline uint32_t td_stdio_arg(uint32_t fd, uint32_t part) { return fd * TD_STDIO_PARTS + part; }

// The floor's side (stdio.c). td_stdio_start takes the handles at start;
// the rest return false (or -1) for a descriptor the process wasn't given.
void td_stdio_start(void);
// Whether the process was given `fd`, and if so whether it reads it.
bool td_stdio_has(int32_t fd, bool *reads);
// Writes all of `bytes` to `fd`, sleeping while its ring is full; false if
// fd isn't one the process writes (dropped once the parent has gone).
bool td_stdio_write_fd(int32_t fd, const void *bytes, uint64_t n);
// Up to `n` bytes of `fd`, sleeping until some come; 0 at its end (or once
// the parent has gone), -1 if fd isn't one the process reads.
int64_t td_stdio_read_fd(int32_t fd, void *buffer, uint64_t n);
// `fd`'s end mark (a descriptor the process writes), once.
void td_stdio_end_fd(int32_t fd);
// A pipe: one ring, read as `read_fd` and written as `write_fd`, both this
// process's; false if it couldn't be made (no memory, or no free entry).
bool td_stdio_pipe(int32_t read_fd, int32_t write_fd);
// Closes `fd`: its end mark if it is written; a pipe's end is let go, so
// the other end sees its end, and the number is free again.
void td_stdio_close_fd(int32_t fd);
// stdout (fd 1) and stdin (fd 0).
bool td_stdio_write(const void *bytes, uint64_t n);
int64_t td_stdio_read(void *buffer, uint64_t n);
// Every written descriptor's end mark, at exit.
void td_stdio_end(void);
