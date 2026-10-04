// vx-driver clockproto: what a clock driver tells devmgr (M5 step 7d,
// ADR-0031). devmgr starts a driver whose record says clock with a channel
// ("devmgr"); the driver writes one message, the time its hardware keeps, and
// devmgr sets the kernel's wall clock from it with the root Resource, which
// the driver does not hold. No reply.

#pragma once

#include "../../abi/vx/abi.h"

enum : uint32_t { VX_CLOCK_REPORT = 0x6b63'6c63 }; // "clck"

typedef struct vx_clock_report {
  vx_msg_header h;
  int64_t utc;       // ns since 1970, read now
  int64_t monotonic; // clock_read() when it was read: devmgr allows for the time since
} vx_clock_report;
