// vx-buffer: the one currency for pixels and every other bulk image (01
// §6.1, rule 7; M7 step 7b2). A buffer is three things: a VMO holding its
// bytes, a descriptor saying how they are laid out, and a Counter, its
// timeline, which orders who may touch them. It is passed as its descriptor
// in a message's bytes (after the message's vx_msg_header, as every channel
// message starts) with its two handles beside it (vx_buffer_put,
// vx_buffer_take), and a receiver trusts nothing it is sent: the descriptor is
// checked against the VMO it came with (vx_buffer_check) before any byte is
// read.
//
// The timeline is a count that only rises. Whoever hands a buffer on names
// an acquire point, the value after which the receiver may read it, and
// the receiver signals a release point once it is done with it; a producer
// waits for the release before it draws into the buffer again. With a CPU
// compositor a buffer is released when it has been copied (21 §2 item 3).
//
// Version 1 carries fields M7 cannot drive yet (21 §2 item 9, rule 9): the
// colour's transfer function, primaries and mastering metadata, so HDR needs
// no version 2.

#pragma once

#include "../../abi/vx/abi.h"
#if !__STDC_HOSTED__
#include "../vx-rt/base.c"
#endif

// --- The descriptor ---

// DRM's fourcc codes (drm_fourcc.h), the four letters little-endian, and
// so the pixel's bytes in memory: XRGB8888 is B, G, R, X. Those a CPU
// renderer and the M7 back ends use.
enum : uint32_t {
  VX_FORMAT_XRGB8888 = 0x3432'5258, // 'XR24'
  VX_FORMAT_ARGB8888 = 0x3432'5241, // 'AR24'
  VX_FORMAT_XBGR8888 = 0x3432'4258, // 'XB24'
  VX_FORMAT_ABGR8888 = 0x3432'4241, // 'AB24'
  VX_FORMAT_RGB565 = 0x3631'4752,   // 'RG16'
};
static constexpr uint64_t VX_MODIFIER_LINEAR = 0; // DRM_FORMAT_MOD_LINEAR: rows one after another

enum : uint8_t { // how values map to light (03 §4)
  VX_TRANSFER_SRGB = 0,
  VX_TRANSFER_LINEAR = 1,
  VX_TRANSFER_PQ = 2,  // SMPTE ST 2084
  VX_TRANSFER_HLG = 3, // ARIB STD-B67
};
enum : uint8_t { VX_PRIMARIES_BT709 = 0, VX_PRIMARIES_BT2020 = 1, VX_PRIMARIES_P3 = 2 }; // BT709: sRGB's
enum : uint8_t { VX_RANGE_FULL = 0, VX_RANGE_LIMITED = 1 };
enum : uint8_t { VX_ALPHA_OPAQUE = 0, VX_ALPHA_PREMULTIPLIED = 1, VX_ALPHA_STRAIGHT = 2 };

typedef struct vx_buffer_plane {
  uint64_t offset; // into the VMO
  uint32_t stride; // bytes from a row to the next
  uint32_t reserved;
} vx_buffer_plane;

// SMPTE ST 2086's mastering display and CTA-861.3's light levels: chromaticity
// in units of 0.00002, luminance in units of 0.0001 cd/m², as HDMI sends them.
typedef struct vx_buffer_mastering {
  uint16_t red[2], green[2], blue[2], white[2]; // x, y
  uint32_t max_luminance, min_luminance;
  uint16_t max_content, max_frame_average; // MaxCLL and MaxFALL, in cd/m²
} vx_buffer_mastering;

typedef struct vx_buffer_desc {
  uint32_t version; // 1
  uint32_t format;  // a VX_FORMAT (DRM fourcc)
  uint64_t modifier;
  uint32_t width, height; // in pixels
  uint32_t planes;        // 1 to 4; the formats above have one
  uint32_t reserved;
  vx_buffer_plane plane[4];
  uint64_t size; // the bytes it reaches, every plane's last row included: at most its VMO's
  uint8_t transfer, primaries, range, alpha;
  uint32_t reserved2;
  vx_buffer_mastering mastering; // all zero: none given
} vx_buffer_desc;
static_assert(sizeof(vx_buffer_desc) == 144);

// A buffer as one process holds it.
typedef struct vx_buffer {
  vx_handle memory; // the VMO
  vx_buffer_desc desc;
  vx_handle timeline; // the Counter
} vx_buffer;

// Bytes a pixel takes in a one-plane format; 0 for one it does not know.
[[maybe_unused]] static uint32_t vx_buffer_bpp(uint32_t format) {
  switch (format) {
  case VX_FORMAT_XRGB8888:
  case VX_FORMAT_ARGB8888:
  case VX_FORMAT_XBGR8888:
  case VX_FORMAT_ABGR8888: return 4;
  case VX_FORMAT_RGB565: return 2;
  default: return 0;
  }
}

// Whether d is a descriptor a receiver may read by: version 1, a format it
// knows, linear, its rows wide enough and every byte it reaches inside the
// VMO's vmo_size bytes. INVALID, or RANGE for one that reaches past it.
// Everything a sender wrote is checked, with no arithmetic that can wrap.
[[maybe_unused]] static vx_status vx_buffer_check(const vx_buffer_desc *d, uint64_t vmo_size) {
  uint32_t bpp = vx_buffer_bpp(d->format);
  if (d->version != 1 || !bpp || d->modifier != VX_MODIFIER_LINEAR || d->planes != 1 || !d->width ||
      !d->height || d->width > 1u << 15 || d->height > 1u << 15)
    return VX_ERR_INVALID;
  if (d->transfer > VX_TRANSFER_HLG || d->primaries > VX_PRIMARIES_P3 || d->range > VX_RANGE_LIMITED ||
      d->alpha > VX_ALPHA_STRAIGHT)
    return VX_ERR_INVALID;
  const vx_buffer_plane *p = &d->plane[0];
  if ((uint64_t)p->stride < (uint64_t)d->width * bpp || p->stride % bpp) return VX_ERR_INVALID;
  // Its last row ends at offset + stride * (height - 1) + width * bpp, at most 2^63 here.
  uint64_t end = p->offset + (uint64_t)p->stride * (d->height - 1) + (uint64_t)d->width * bpp;
  if (p->offset > (1ull << 48) || end > d->size || d->size > vmo_size) return VX_ERR_RANGE;
  return VX_OK;
}

// The descriptor of a one-plane linear buffer: rows of stride bytes, a
// multiple of 64 (a cache line, and what scan-out engines want), sRGB, opaque
// unless the format has alpha (then premultiplied).
[[maybe_unused]] static vx_buffer_desc vx_buffer_layout(uint32_t width, uint32_t height, uint32_t format) {
  uint32_t bpp = vx_buffer_bpp(format), stride = (width * bpp + 63) & ~63u;
  bool alpha = format == VX_FORMAT_ARGB8888 || format == VX_FORMAT_ABGR8888;
  return (vx_buffer_desc){.version = 1,
                          .format = format,
                          .width = width,
                          .height = height,
                          .planes = 1,
                          .plane = {{.offset = 0, .stride = stride}},
                          .size = (uint64_t)stride * height,
                          .alpha = alpha ? VX_ALPHA_PREMULTIPLIED : VX_ALPHA_OPAQUE};
}

#if !__STDC_HOSTED__

// --- Buffers in a process ---

// A new buffer: a VMO of its layout's size, and a timeline at 0. Its pages
// are made at once, not as they are drawn: a buffer may be scanned out, and
// no device may hold a lazy VMO's pages (dma_map refuses them).
[[maybe_unused]] static vx_status vx_buffer_alloc(vx_buffer *b, uint32_t width, uint32_t height,
                                                  uint32_t format) {
  *b = (vx_buffer){.desc = vx_buffer_layout(width, height, format)};
  if (vx_buffer_check(&b->desc, b->desc.size) != VX_OK) return VX_ERR_INVALID;
  vx_status st = vx_vmo_create((b->desc.size + 4095) & ~4095ull, 0, &b->memory);
  if (st == VX_OK) st = vx_counter_create(0, &b->timeline);
  if (st != VX_OK) {
    if (b->memory) vx_handle_close(b->memory);
    *b = (vx_buffer){};
  }
  return st;
}

// Its bytes mapped here, writable if write: *at their first byte.
[[maybe_unused]] static vx_status vx_buffer_map(const vx_buffer *b, bool write, uint8_t **at) {
  uint64_t va = 0;
  vx_status st =
      vx_as_map(vx_self, b->memory, 0, (b->desc.size + 4095) & ~4095ull, write ? VX_MAP_WRITE : 0, &va);
  *at = st == VX_OK ? (uint8_t *)va : nullptr;
  return st;
}

[[maybe_unused]] static void vx_buffer_unmap(const vx_buffer *b, uint8_t *at) {
  if (at) vx_as_unmap(vx_self, (uint64_t)at, (b->desc.size + 4095) & ~4095ull);
}

[[maybe_unused]] static void vx_buffer_close(vx_buffer *b) {
  if (b->memory) vx_handle_close(b->memory);
  if (b->timeline) vx_handle_close(b->timeline);
  *b = (vx_buffer){};
}

// --- On a channel ---

// b written into a message: its descriptor at bytes, its handles (duplicates,
// so the sender keeps its own) at handles[0] and [1]. The rights given: READ
// and MAP on the memory (WRITE too if writable), WAIT and SIGNAL on the timeline.
[[maybe_unused]] static vx_status vx_buffer_put(const vx_buffer *b, bool writable, vx_buffer_desc *bytes,
                                                vx_handle handles[2]) {
  *bytes = b->desc;
  handles[0] = handles[1] = VX_HANDLE_NONE;
  uint32_t mem =
      VX_RIGHT_READ | VX_RIGHT_MAP | VX_RIGHT_TRANSFER | VX_RIGHT_DUPLICATE | (writable ? VX_RIGHT_WRITE : 0);
  vx_status st = vx_handle_dup(b->memory, mem, &handles[0]);
  if (st == VX_OK)
    st = vx_handle_dup(b->timeline, VX_RIGHT_WAIT | VX_RIGHT_SIGNAL | VX_RIGHT_READ | VX_RIGHT_TRANSFER,
                       &handles[1]);
  if (st != VX_OK && handles[0]) vx_handle_close(handles[0]), handles[0] = VX_HANDLE_NONE;
  return st;
}

// A buffer taken from a message: its descriptor (len bytes at bytes) and its
// two handles, which it owns from here whatever happens. Checked against the
// VMO's own size, and the timeline is a Counter; INVALID or RANGE, the
// handles closed, if not.
[[maybe_unused]] static vx_status vx_buffer_take(vx_buffer *b, const void *bytes, uint32_t len,
                                                 const vx_handle handles[2]) {
  *b = (vx_buffer){.memory = handles[0], .timeline = handles[1]};
  vx_status st = len == sizeof b->desc && handles[0] && handles[1] ? VX_OK : VX_ERR_INVALID;
  if (st == VX_OK) memcpy(&b->desc, bytes, sizeof b->desc);
  uint64_t size = 0;
  if (st == VX_OK) st = vx_vmo_size(b->memory, &size);
  if (st == VX_OK) st = vx_buffer_check(&b->desc, size);
  if (st == VX_OK && vx_counter_read(b->timeline) < 0) st = VX_ERR_INVALID; // no Counter
  if (st != VX_OK) {
    if (handles[0]) vx_handle_close(handles[0]);
    if (handles[1]) vx_handle_close(handles[1]);
    *b = (vx_buffer){};
  }
  return st;
}

// --- The timeline ---

// The timeline raised to point: an acquire (readers may start) or a release
// (the readers are done), whichever the protocol says it is.
[[maybe_unused]] static vx_status vx_buffer_signal(const vx_buffer *b, uint64_t point) {
  return vx_counter_signal(b->timeline, point);
}

// Waits until the timeline reaches point, or deadline: OK or TIMED_OUT.
[[maybe_unused]] static vx_status vx_buffer_wait(const vx_buffer *b, uint64_t point, vx_instant deadline) {
  int64_t now = vx_counter_read(b->timeline);
  if (now < 0) return (vx_status)now;
  if ((uint64_t)now >= point) return VX_OK;
  vx_handle port;
  vx_status st = vx_port_create(0, &port);
  if (st != VX_OK) return st;
  st = vx_port_bind(port, b->timeline, VX_TRIGGER_COUNTER_GE, 1, point);
  vx_packet pk;
  int64_t got = st == VX_OK ? vx_port_wait(port, deadline, 0, &pk, 1) : st;
  vx_handle_close(port);
  if (got == 1) return VX_OK;
  return got < 0 ? (vx_status)got : VX_ERR_TIMED_OUT;
}

#endif
