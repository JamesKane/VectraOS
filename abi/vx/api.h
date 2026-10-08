// vx/api.h: how libvx's public declarations are made (ADR-0004).
//
// VX_API marks each call libvx exports. A native program sees plain
// declarations, which libvx.so (or libvx.a) answers. libvx itself is built
// with VX_RT_LIBC: its definitions have default visibility, so libvx.so
// exports exactly these. The system's own programs compile libvx in, as a
// unity build (VX_UNITY, lib/vx-rt/rt.c): the same declarations, static.
//
// VX_TARGET_ABI is the level a program targets, the SDK's own unless the
// program says otherwise: a declaration made after level 1 is inside
// #if VX_TARGET_ABI >= n, so a newer call is a compile error for an older
// target. vx_abi_level() is the running system's.

#pragma once

#include "abi.h"

#ifndef VX_TARGET_ABI
#define VX_TARGET_ABI VX_ABI_LEVEL
#endif

#ifdef VX_UNITY
#define VX_API [[maybe_unused]] static
#elifdef VX_RT_LIBC
#define VX_API [[gnu::visibility("default")]]
#else
#define VX_API
#endif
