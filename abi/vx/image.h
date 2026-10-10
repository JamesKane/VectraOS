// vx/image.h: code images mapped into a running process (ADR-0056, libvx
// level 2), for hot reload (03 §6.1) as dlopen is for a C program.
//
// vx_image_open maps the shared library at path into the process and binds
// it against what is loaded: the executable first, then its libraries in
// load order (as /lib/ld-vx loaded them), then the image itself, never an
// image opened before it. Its initialisation array runs before it returns.
// An image is never unmapped: a reload's old images stay mapped, so a
// pointer into one (a string, a function, a table) stays good. Each open
// maps a fresh copy at a new address, even of a path already open.
//
// Refused: an image with TLS (dynamic TLS is not implemented, ADR-0047
// item 6), and one needing a library that is not loaded already.

#pragma once

#include "api.h"

#if VX_TARGET_ABI >= 2
typedef struct vx_image vx_image;

VX_API vx_status vx_image_open(vx_str path, vx_image **image);
// A function or object the image defines, by name, or null.
VX_API void *vx_image_symbol(const vx_image *image, const char *name);
#endif
