// reload_app: the code image reloadhost runs (M7 step 7g2b,
// tests/qemu/reload.ndb), built twice: libreloada.so, image A, blue, and
// libreloadb.so (-DRELOAD_B), image B, green. Its state is all in the
// host's memory: frames counted across reloads, and a greeting, a pointer
// to image A's string, kept by B. Its own static data is each image's, so
// the first frame of each image says which it is.

#include <vxui.h>

#ifdef RELOAD_B
#define IMAGE "B"
static constexpr vx_color COLOUR = 0x2f8f4f;
#else
#define IMAGE "A"
static constexpr vx_color COLOUR = 0x3f6fb0;
#endif

typedef struct state {
  uint32_t frames;
  const char *greeting; // the first image's
} state;

static bool shown; // this image's

void vx_app_update(vx_app_memory *mem, vx_event *ev) {
  state *s = (state *)mem->storage;
  if (!s->greeting) s->greeting = "a string of image " IMAGE;
  if (ev->kind != VX_FRAME) return;
  s->frames++;
  vx_canvas *c = vx_canvas_begin(mem->window, &ev->frame);
  vx_clear(c, COLOUR);
  vx_canvas_present(c);
  if (!shown) {
    shown = true;
    vx_printf("reload: image " IMAGE " at frame %u, reloads %u, greeting '%s', memory at %#llx\n", s->frames,
              mem->reloads, s->greeting, (unsigned long long)(uintptr_t)mem);
  }
}
