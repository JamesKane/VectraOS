// minimal: 03 §6's minimal program, as written there: a window, frames,
// input and sound in 10 calls (M7's exit, step 7e2; tests/qemu/minimal.ndb).
// Its sound is silent until audiod (M13).

#include <vxui.h>

const char *vx_main(void) {
  vx_app *app = vx_app_open("org.example.beep");             // 1
  vx_window *win = vx_window_open(app, "Beep", 640, 360);    // 2
  vx_voice *beep = vx_voice_open(app, VX_TONE(440.0f, 120)); // 3
  float x = 320.0f;
  vx_event ev;
  while (vx_wait(app, &ev, VX_INFINITE)) { // 4
    switch (ev.kind) {
    case VX_FRAME: {
      vx_canvas *c = vx_canvas_begin(win, &ev.frame);  // 5
      vx_clear(c, VX_THEME_BG);                        // 6
      vx_circle(c, x, 180.0f, 20.0f, VX_THEME_ACCENT); // 7
      vx_canvas_present(c);                            // 8
    } break;
    case VX_KEY:
      if (ev.keyboard.down && ev.keyboard.usage == VX_KEY_SPACE) vx_voice_play(beep); // 9
      break;
    case VX_POINTER:
      x = ev.pointer.x;
      vx_window_redraw(win); // 10
      break;
    case VX_CLOSE: return nullptr;
    default: break;
    }
  }
  return nullptr;
}
