// vx/random.h: random bytes (ADR-0004 libvx v0; swift-on-vectra's R15).
// The process's own generator, seeded at start-up from its spawn message's
// entropy (svcd's or its parent's), so it never waits and never fails.

#pragma once

#include "api.h"

VX_API void vx_random_bytes(void *out, size_t n);
