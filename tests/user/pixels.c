// pixels: 03 §6's CPU pixel program (M7's exit, step 7e2; tests/qemu/
// pixels.ndb): a window drawn by the CPU straight into its buffer
// (vx_pixels), animated for 30 frames and then still, its last frame a
// pattern of its frame count, so the screen can be matched. It checks the
// buffers' ages as it goes: 0 for a new one, else 2, the two in turn.

#include <vxui.h>

static void draw(vx_pixels *px, uint32_t t) {
  for (uint32_t y = 0; y < px->h; y++) {
    uint32_t *row = (uint32_t *)(px->data + (size_t)y * px->stride);
    for (uint32_t x = 0; x < px->w; x++) {
      uint32_t r = (x * 255) / px->w, g = (y * 255) / px->h, b = ((x ^ y) + t * 4) & 0xff;
      row[x] = r << 16 | g << 8 | b;
    }
  }
}

const char *vx_main(void) {
  vx_app *app = vx_app_open("org.example.pixels");
  vx_window *win = vx_window_open(app, "Pixels", 320, 240);
  vx_window_animate(win, true);
  uint32_t frames = 0, bad_ages = 0;
  vx_event ev;
  while (vx_wait(app, &ev, VX_INFINITE)) {
    if (ev.kind == VX_CLOSE) return nullptr;
    if (ev.kind != VX_FRAME) continue;
    vx_pixels px = vx_pixels_begin(win, &ev.frame);
    if (px.age != 0 && px.age != 2) bad_ages++; // a new buffer's 0, then the two in turn
    draw(&px, ++frames);
    vx_pixels_present(win, &px);
    if (frames == 30) {
      vx_window_animate(win, false);
      vx_printf("pixels: 30 frames, %u wrong ages\n", bad_ages);
    }
  }
  vx_printf("pixels: %s\n", vx_app_error(app) ? vx_app_error(app) : "the wait ended");
  return "error";
}
