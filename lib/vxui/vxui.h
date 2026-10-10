// vxui.h: the app tier's C API (03 §6; M7 step 7e2), v0: an app, its
// windows, one wait for everything, a canvas, CPU pixels, and voices.
//
// One loop, one wait, owned by the app: vx_wait returns the next event of
// any of its windows (libvx's vx_event, its vxui kinds: VX_FRAME, VX_KEY,
// VX_POINTER, VX_TEXT, VX_CONFIGURE, VX_CLOSE, the window as its source);
// the toolkit never calls back. A window draws only when asked
// (vx_window_redraw, or every frame with vx_window_animate), and only with
// a credit of the frame protocol in hand (docs/proto/wsys.md), so an idle
// window costs nothing. Errors are sticky: a failed open makes the next
// vx_wait return false, and vx_app_error says why; the minimal program
// needs no error checks.
//
// v0 is a header library: a program includes this and has vxui compiled
// in, against vx-rt, as 03's programs are written (vx_main). It becomes
// libvxui.so, its ABI this header, when libvx exports what it uses (the
// srv extension's open, the process's task). Voices are numbered now and
// sound with audiod (M13).

#pragma once

#include "../vx-rt/rt.c"
#include "../vx-ns/nsapi.c"
#include "../vx-wsys/wsysproto.h"
#include "../vx-input/keymap.h"

typedef struct vx_app vx_app;
typedef struct vx_window vx_window;
typedef struct vx_canvas vx_canvas;
typedef struct vx_voice vx_voice;

// A colour: XRGB, or one of the theme's (resolved by vxui from the theme
// the window is drawn in).
typedef uint32_t vx_color;
enum : vx_color {
  VX_THEME_BG = 0x0100'0001, // a window's background
  VX_THEME_FG,               // text on it
  VX_THEME_ACCENT,           // the theme's accent
  VX_THEME_FACE,             // the chrome's face
};

static constexpr uint32_t VX_KEY_SPACE = VX_HID_KEYBOARD | 0x2c, VX_KEY_ESCAPE = VX_HID_KEYBOARD | 0x29,
                          VX_KEY_ENTER = VX_HID_KEYBOARD | 0x28;

// A sound a voice plays: v0 has tones.
typedef struct vx_sound {
  uint32_t kind; // 1: a tone
  float hz;
  uint32_t ms;
} vx_sound;
#define VX_TONE(hz_, ms_) ((vx_sound){.kind = 1, .hz = (hz_), .ms = (ms_)})

// A CPU surface (03 §6): the window's buffer to draw into, XRGB8888, rows
// stride bytes apart; age is how many presents ago its contents were last
// shown (0: never), so a program that redraws damage repaints only what
// changed since then.
typedef struct vx_pixels {
  uint8_t *data;
  uint32_t w, h, stride, age;
  uint32_t buffer; // vxui's
} vx_pixels;

[[maybe_unused]] static vx_app *vx_app_open(const char *id);
[[maybe_unused]] static const char *vx_app_error(const vx_app *app);
[[maybe_unused]] static bool vx_wait(vx_app *app, vx_event *ev, vx_instant deadline);

[[maybe_unused]] static vx_window *vx_window_open(vx_app *app, const char *title, uint32_t width,
                                                  uint32_t height);
[[maybe_unused]] static void vx_window_redraw(vx_window *win);
[[maybe_unused]] static void vx_window_animate(vx_window *win, bool on);
[[maybe_unused]] static void vx_window_title(vx_window *win, const char *title);

[[maybe_unused]] static vx_canvas *vx_canvas_begin(vx_window *win, const vx_frame_event *frame);
[[maybe_unused]] static void vx_clear(vx_canvas *c, vx_color colour);
[[maybe_unused]] static void vx_fill_rect(vx_canvas *c, float x, float y, float w, float h, vx_color colour);
[[maybe_unused]] static void vx_circle(vx_canvas *c, float x, float y, float r, vx_color colour);
[[maybe_unused]] static void vx_canvas_present(vx_canvas *c);

[[maybe_unused]] static vx_pixels vx_pixels_begin(vx_window *win, const vx_frame_event *frame);
[[maybe_unused]] static void vx_pixels_present(vx_window *win, vx_pixels *px);

[[maybe_unused]] static vx_voice *vx_voice_open(vx_app *app, vx_sound sound);
[[maybe_unused]] static void vx_voice_play(vx_voice *voice);

#include "vxui.c"
