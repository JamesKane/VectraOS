// The display engine protocol (docs/proto/display.md, ADR-0026; M7 step
// 7b2): between displayd and a display back end (simplefb, virtio-gpu, and
// later a SoC's), on a channel the back end hands displayd from its post.
// Requests go by channel_call; APPLY is one message with no reply, so a flip
// costs one write; events come unasked, with txid 0.

#pragma once

#include "../../abi/vx/abi.h"
#include "../vx-buffer/buffer.h"

enum : uint32_t {
  VX_DISPLAY_CONNECT = 0x7073'6964
}; // "disp": the post's one request; the reply carries the channel
static constexpr uint32_t VX_DISPLAY_VERSION = 1;

enum : uint32_t { // a request's ordinal, and an event's
  VX_DISPLAY_INFO = 1,
  VX_DISPLAY_IMPORT = 2,
  VX_DISPLAY_RELEASE = 3,
  VX_DISPLAY_CHECK = 4,
  VX_DISPLAY_APPLY = 5, // no reply
  VX_DISPLAY_POWER = 6,
  VX_DISPLAY_ADDED = 0x101,
  VX_DISPLAY_REMOVED = 0x102,
  VX_DISPLAY_VBLANK = 0x103,
};

static constexpr uint32_t VX_DISPLAY_FORMATS = 8, VX_DISPLAY_LAYERS = 4, VX_DISPLAY_DAMAGE = 8;

// What a back end can do (INFO's reply).
enum : uint32_t {
  VX_DISPLAY_CONTIGUOUS = 1, // a scan-out image must be physically contiguous
  VX_DISPLAY_WC = 2,         // and mapped write-combining by whoever draws into it directly
};
typedef struct vx_display_info {
  vx_msg_header h;
  uint32_t version; // VX_DISPLAY_VERSION
  uint32_t outputs; // at most; version 1 has 1
  uint32_t layers;  // per output
  uint32_t nformats;
  uint32_t formats[VX_DISPLAY_FORMATS]; // VX_FORMAT_*, linear
  uint32_t constraints;                 // VX_DISPLAY_CONTIGUOUS, VX_DISPLAY_WC
  uint32_t align;                       // a scan-out image's start, in bytes
  uint64_t address_limit;               // its last byte's physical address, at most; 0: any
} vx_display_info;

// IMPORT: a vx-buffer (its descriptor, its memory and timeline as the
// message's two handles), as a scan-out image; the reply's arg is its id.
typedef struct vx_display_import {
  vx_msg_header h;
  vx_buffer_desc desc;
} vx_display_import;

typedef struct vx_display_rect {
  int32_t x, y;
  uint32_t width, height;
} vx_display_rect;

typedef struct vx_display_mode {
  uint32_t width, height;
  uint32_t refresh_mhz; // millihertz: 60000 is 60 Hz
  uint32_t flags;       // VX_DISPLAY_FIRMWARE: the mode the firmware left
} vx_display_mode;
enum : uint32_t { VX_DISPLAY_FIRMWARE = 1 };

enum : uint32_t { VX_DISPLAY_LAYER_IMAGE = 1, VX_DISPLAY_LAYER_COLOR = 2 };
typedef struct vx_display_layer {
  uint32_t kind;  // IMAGE or COLOR
  uint32_t color; // COLOR's, XRGB8888
  uint64_t image; // IMAGE's id, from IMPORT
  vx_display_rect src, dst;
  uint8_t alpha;    // 255: opaque
  uint8_t rotation; // 0, 1, 2, 3: quarter turns clockwise
  uint8_t reserved[6];
} vx_display_layer;

// A configuration of one output: CHECK's and APPLY's body.
typedef struct vx_display_cfg {
  uint32_t output;
  uint32_t nlayers;
  vx_display_mode mode;
  vx_display_layer layer[VX_DISPLAY_LAYERS];
} vx_display_cfg;

typedef struct vx_display_check {
  vx_msg_header h;
  vx_display_cfg cfg;
} vx_display_check; // the reply: flags 0, or a status and arg[0] the first layer that failed (-1: the mode)

// APPLY: a checked configuration (or one differing from it only in its
// images), shown from the next vblank, which reports stamp. damage: the
// rectangles that changed since the stamp before (none: all of it), which a
// back end that copies or flushes need only cover.
typedef struct vx_display_apply {
  vx_msg_header h;
  uint64_t stamp; // strictly increasing
  vx_display_cfg cfg;
  uint32_t ndamage;
  uint32_t reserved;
  vx_display_rect damage[VX_DISPLAY_DAMAGE];
} vx_display_apply;

typedef struct vx_display_power {
  vx_msg_header h;
  uint32_t output;
  uint32_t on;
} vx_display_power;

// Events.
typedef struct vx_display_added {
  vx_msg_header h;
  uint32_t output;
  uint32_t edid_len; // the EDID's bytes that follow in the message (0: none, the firmware's framebuffer)
  vx_display_mode preferred, current;
} vx_display_added;

typedef struct vx_display_vblank {
  vx_msg_header h;
  uint32_t output;
  uint32_t reserved;
  uint64_t time;  // vx_clock's nanoseconds
  uint64_t stamp; // the newest APPLY on screen
} vx_display_vblank;

// A small request whose reply is a header and up to three words (RELEASE,
// POWER's, IMPORT's id, CHECK's failure).
typedef struct vx_display_msg {
  vx_msg_header h;
  int64_t arg[3];
} vx_display_msg;
