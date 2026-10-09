// buftest: a vx-buffer between two processes (M7 step 7b2, the buffer
// scenario): the parent draws into one and hands it to a child with its
// acquire point; the child takes it (checked against its VMO), waits for the
// point, reads every pixel, and signals the release point the parent waits
// for. A descriptor that claims more than its VMO is refused.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-ns/nsapi.c"
#include "../../lib/vx-buffer/buffer.h"

static uint32_t checks, failures;

static void check_at(bool ok, const char *what, int line) {
  checks++;
  if (ok) return;
  failures++;
  vx_printf("buftest: FAILED line %d: %s\n", line, what);
}

#define CHECK(cond) check_at((cond), #cond, __LINE__)

static uint32_t pixel(uint32_t x, uint32_t y) { return 0xff00'0000u | x << 16 | y << 8 | ((x + y) & 0xff); }

// A message, as every one on a channel is, a header first: then the buffer's
// descriptor, its two handles beside it.
typedef struct buffer_msg {
  vx_msg_header h;
  vx_buffer_desc d;
} buffer_msg;

// One message: a descriptor and its two handles; false at the channel's end.
static bool receive(vx_handle ch, vx_buffer_desc *d, vx_handle h[2]) {
  for (;;) {
    vx_msg_size size;
    buffer_msg m;
    vx_status st = vx_channel_read(ch, &m, sizeof m, h, 2, &size);
    *d = m.d;
    if (st == VX_OK) return size.bytes == sizeof m && size.handles == 2;
    if (st != VX_ERR_SHOULD_WAIT) return false;
    vx_handle port;
    vx_packet pk;
    vx_port_create(0, &port);
    vx_port_bind(port, ch, VX_TRIGGER_READABLE, 1, 0);
    vx_port_wait(port, vx_now() + 10'000'000'000, 0, &pk, 1);
    vx_handle_close(port);
  }
}

static const char *child(void) {
  vx_handle ch = vx_spawn_take("buffer");
  vx_buffer_desc d;
  vx_handle h[2];
  CHECK(receive(ch, &d, h));
  vx_buffer b;
  CHECK(vx_buffer_take(&b, &d, sizeof d, h) == VX_OK);
  CHECK(vx_buffer_wait(&b, 1, vx_now() + 5'000'000'000) == VX_OK); // its acquire point
  uint8_t *px = nullptr;
  CHECK(vx_buffer_map(&b, false, &px) == VX_OK);
  uint32_t wrong = 0;
  for (uint32_t y = 0; px && y < b.desc.height; y++)
    for (uint32_t x = 0; x < b.desc.width; x++)
      wrong +=
          ((uint32_t *)(px + b.desc.plane[0].offset + (size_t)y * b.desc.plane[0].stride))[x] != pixel(x, y);
  CHECK(wrong == 0);
  vx_buffer_unmap(&b, px);
  CHECK(vx_buffer_signal(&b, 2) == VX_OK); // released
  // A second: its descriptor claims more than its VMO holds.
  CHECK(receive(ch, &d, h));
  vx_buffer liar;
  CHECK(vx_buffer_take(&liar, &d, sizeof d, h) == VX_ERR_RANGE && !liar.memory);
  vx_buffer_close(&b);
  vx_printf("buftest: child %u checks, %u failed\n", checks, failures);
  return failures ? "failed" : nullptr;
}

const char *vx_main(void) {
  if (vx_str_eq(vx_arg(1), VX_STR("child"))) return child();
  vx_buffer b;
  CHECK(vx_buffer_alloc(&b, 320, 200, VX_FORMAT_XRGB8888) == VX_OK);
  CHECK(b.desc.plane[0].stride == 1280 && b.desc.size == 1280ull * 200);
  uint8_t *px = nullptr;
  CHECK(vx_buffer_map(&b, true, &px) == VX_OK);
  for (uint32_t y = 0; px && y < 200; y++)
    for (uint32_t x = 0; x < 320; x++) ((uint32_t *)(px + (size_t)y * 1280))[x] = pixel(x, y);
  vx_buffer_unmap(&b, px);

  vx_handle ch[2];
  CHECK(vx_channel_create(0, ch) == VX_OK);
  vx_str args[] = {VX_STR("buftest"), VX_STR("child")}, names[] = {VX_STR("buffer")};
  vx_spawn_req req = {
      .path = vx_exe_path(), .args = {args, 2}, .handles = &ch[1], .handle_names = names, .nhandles = 1};
  vx_proc kid = {};
  CHECK(vx_proc_spawn(&req, &kid) == VX_OK);
  vx_handle h[2];
  buffer_msg m = {};
  CHECK(vx_buffer_put(&b, false, &m.d, h) == VX_OK);
  CHECK(vx_channel_write(ch[0], &m, sizeof m, h, 2) == VX_OK);
  CHECK(vx_buffer_signal(&b, 1) == VX_OK);                          // drawn: the child may read from 1
  CHECK(vx_buffer_wait(&b, 2, vx_now() + 10'000'000'000) == VX_OK); // the child's release
  // The liar: the same buffer's handles, its descriptor a page larger than its VMO.
  CHECK(vx_buffer_put(&b, false, &m.d, h) == VX_OK);
  m.d.size += 4096ull * 100, m.d.height += 400;
  CHECK(vx_channel_write(ch[0], &m, sizeof m, h, 2) == VX_OK);
  vx_arena *a = vx_arena_new(1 << 16);
  vx_str why = VX_STR("unset");
  CHECK(vx_proc_wait(kid, VX_INFINITE, a, &why) == VX_OK && why.len == 0);
  uint64_t size = 0;
  CHECK(vx_vmo_size(b.memory, &size) == VX_OK && size == (1280ull * 200 + 4095) / 4096 * 4096); // whole pages
  vx_buffer_close(&b);
  vx_printf("buftest: %u checks, %u failed\n", checks, failures);
  return failures ? "failed" : nullptr;
}
