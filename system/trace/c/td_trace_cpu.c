// SPDX-License-Identifier: BSD-3-Clause

#include "td_trace_cpu.h"

// Initial-exec TLS: one segment-relative load, no call.
static _Thread_local __attribute__((tls_model("initial-exec"))) void *thread_ring;

void *td_trace_thread_ring(void) { return thread_ring; }
void td_trace_set_thread_ring(void *ring) { thread_ring = ring; }
