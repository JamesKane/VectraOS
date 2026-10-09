// buffer_test.c: lib/vx-buffer's descriptor (M7 step 7b2): the layouts it
// makes, and what vx_buffer_check refuses of a descriptor a sender wrote:
// every field out of range, and the arithmetic that would wrap.

#include <stdint.h>
#include <string.h>

#include "check.h"
#include "../../lib/vx-driver/displayproto.h"

int main(void) {
  // A layout: rows a multiple of 64 bytes, its size theirs, and it checks.
  vx_buffer_desc d = vx_buffer_layout(1000, 600, VX_FORMAT_XRGB8888);
  CHECK(d.version == 1 && d.planes == 1 && d.plane[0].stride == 4032 && d.size == 4032ull * 600);
  CHECK(d.alpha == VX_ALPHA_OPAQUE && d.transfer == VX_TRANSFER_SRGB && d.primaries == VX_PRIMARIES_BT709);
  CHECK(vx_buffer_check(&d, d.size) == VX_OK);
  CHECK(vx_buffer_check(&d, d.size - 1) == VX_ERR_RANGE); // a VMO too small for it
  CHECK(vx_buffer_layout(7, 3, VX_FORMAT_ARGB8888).alpha == VX_ALPHA_PREMULTIPLIED);
  CHECK(vx_buffer_layout(31, 2, VX_FORMAT_RGB565).plane[0].stride == 64);

  // Each field of a sent descriptor, out of range.
  vx_buffer_desc b;
  b = d, b.version = 2;
  CHECK(vx_buffer_check(&b, b.size) == VX_ERR_INVALID);
  b = d, b.format = 0x1234'5678;
  CHECK(vx_buffer_check(&b, b.size) == VX_ERR_INVALID);
  b = d, b.modifier = 1;
  CHECK(vx_buffer_check(&b, b.size) == VX_ERR_INVALID);
  b = d, b.planes = 2;
  CHECK(vx_buffer_check(&b, b.size) == VX_ERR_INVALID);
  b = d, b.width = 0;
  CHECK(vx_buffer_check(&b, b.size) == VX_ERR_INVALID);
  b = d, b.height = 1u << 16;
  CHECK(vx_buffer_check(&b, UINT64_MAX) == VX_ERR_INVALID);
  b = d, b.plane[0].stride = 3999; // narrower than a row
  CHECK(vx_buffer_check(&b, b.size) == VX_ERR_INVALID);
  b = d, b.plane[0].stride = 4034; // not a whole number of pixels
  CHECK(vx_buffer_check(&b, UINT64_MAX) == VX_ERR_INVALID);
  b = d, b.transfer = 9;
  CHECK(vx_buffer_check(&b, b.size) == VX_ERR_INVALID);
  b = d, b.alpha = 3;
  CHECK(vx_buffer_check(&b, b.size) == VX_ERR_INVALID);

  // What would wrap, or reach past the VMO.
  b = d, b.plane[0].offset = UINT64_MAX - 100; // offset + rows would wrap
  b.size = UINT64_MAX;
  CHECK(vx_buffer_check(&b, UINT64_MAX) == VX_ERR_RANGE);
  b = d, b.plane[0].offset = 4096; // its rows end past size
  CHECK(vx_buffer_check(&b, b.size) == VX_ERR_RANGE);
  b = d, b.size = d.size + 4096; // a size past its VMO's
  CHECK(vx_buffer_check(&b, d.size) == VX_ERR_RANGE);
  b = d, b.plane[0].offset = 4096, b.size = d.size + 4096; // an offset that fits
  CHECK(vx_buffer_check(&b, b.size) == VX_OK);
  b = vx_buffer_layout(1u << 15, 1u << 15, VX_FORMAT_XRGB8888); // the largest: no overflow in its size
  CHECK(b.size == (1ull << 17) * (1ull << 15) && vx_buffer_check(&b, b.size) == VX_OK);

  // The engine protocol's records fit a channel message (64 KiB) with room.
  CHECK(sizeof(vx_display_apply) < 1024 && sizeof(vx_display_info) < 256 && sizeof(vx_display_import) < 256);
  return check_result();
}
