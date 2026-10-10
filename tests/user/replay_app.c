// replay_app: the code image looped playback runs (M7 step 7g2c,
// tests/qemu/replay.ndb) in reloadhost, built twice: libreplaya.so, image A,
// and libreplayb.so (-DREPLAY_B), image B. Its state is in the host's
// memory: the frames drawn and the spaces pressed, each press a frame drawn
// with a bar as long as the presses. Each frame and each space says which
// image had it, and whether it was replayed. Each press also marks a page a
// MiB further in, made after the snapshot, so a restore that kept one is
// seen. An A key says so: pressed while the host
// plays, it must not reach the image.

#include <vxui.h>

#ifdef REPLAY_B
#define IMAGE "B"
static constexpr vx_color COLOUR = 0x2f8f4f;
#else
#define IMAGE "A"
static constexpr vx_color COLOUR = 0x3f6fb0;
#endif

static constexpr uint32_t KEY_A = 0x07u << 16 | 0x04;

typedef struct state {
  uint32_t frames, presses;
} state;

void vx_app_update(vx_app_memory *mem, vx_event *ev) {
  state *s = (state *)mem->storage;
  if (ev->kind == VX_KEY && ev->keyboard.down && !ev->keyboard.repeat) {
    if (ev->keyboard.usage == VX_KEY_SPACE) {
      s->presses++, vx_window_redraw(mem->window);
      if (s->presses < 8)
        mem->storage[s->presses << 20] = (uint8_t)s->presses; // a page made after the snapshot
      vx_printf("replay: image " IMAGE " was given a space, %s\n",
                ev->flags & VX_REPLAYED ? "replayed" : "live");
    }
    if (ev->keyboard.usage == KEY_A) vx_printf("replay: image " IMAGE " was given a live key\n");
  }
  if (ev->kind != VX_FRAME) return;
  s->frames++;
  for (uint32_t k = 1; k < 8; k++) // restored: none of the pages made since
    if (mem->storage[k << 20] != (k <= s->presses ? k : 0))
      vx_printf("replay: image " IMAGE " found page %u stale\n", k);
  vx_canvas *c = vx_canvas_begin(mem->window, &ev->frame);
  vx_clear(c, COLOUR);
  vx_fill_rect(c, 16, 16, (float)(24 * s->presses), 24, VX_THEME_FG);
  vx_canvas_present(c);
  vx_printf("replay: image " IMAGE " drew frame %u, presses %u, %s\n", s->frames, s->presses,
            ev->flags & VX_REPLAYED ? "replayed" : "live");
}
