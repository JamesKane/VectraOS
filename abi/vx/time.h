// vx/time.h: the one clock, sleeping, the wall clock (09 §5.6, ADR-0004 libvx v0).
// libvx's public declarations: a native program's, and the system's own
// programs' through lib/vx-rt (VX_API, api.h).

#pragma once

#include "api.h"
VX_API vx_instant vx_now(void);
VX_API vx_duration vx_clock_resolution(void);
VX_API vx_status vx_sleep_until(vx_instant at, vx_duration leeway);
VX_API int64_t vx_wallclock(void);
