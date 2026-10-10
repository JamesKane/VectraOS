// vx/trace.h: a program's spans in the system's trace (20 §5; ADR-0056,
// libvx level 2). A span is a stretch of the calling thread's time, from
// vx_span_begin to vx_span_end, written into the process's profiling ring
// with what it was (a message type: 9Px's, or one of the frames' kinds,
// VX_SPAN_FRAME_*) and its flow, which spans of one request or frame in
// other processes share; /proc/trace merges them with the kernel's records.
// While the trace has spans off, vx_span_begin is one predictable branch
// and returns 0, and vx_span_end of 0 does nothing.

#pragma once

#include "api.h"

#if VX_TARGET_ABI >= 2
VX_API uint64_t vx_span_begin(void);
VX_API void vx_span_end(uint64_t start, uint32_t what, uint64_t flow);
#endif
