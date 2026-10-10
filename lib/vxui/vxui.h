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
#include "../vx-font/font.c"

typedef struct vx_app vx_app;
typedef struct vx_window vx_window;
typedef struct vx_canvas vx_canvas;
typedef struct vx_voice vx_voice;
typedef struct vx_ui vx_ui;

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
// From any thread: the app's vx_wait returns a VX_WAKE (one for any number
// of wakes since the last), so a thread of the app's own (a reader) can hand
// it work.
[[maybe_unused]] static void vx_app_wake(vx_app *app);

[[maybe_unused]] static vx_window *vx_window_open(vx_app *app, const char *title, uint32_t width,
                                                  uint32_t height);
[[maybe_unused]] static void vx_window_redraw(vx_window *win);
[[maybe_unused]] static void vx_window_animate(vx_window *win, bool on);
[[maybe_unused]] static void vx_window_title(vx_window *win, const char *title);
// Text input (docs/proto/wsys.md, the window's ime file): on, its text
// resolved by the server (dead keys, compose, an input method) and given as
// VX_TEXT, commands still VX_KEY; purpose is text, password, number, url,
// email or terminal. Off (nullptr), as a window starts: keys alone.
[[maybe_unused]] static void vx_window_text_input(vx_window *win, const char *purpose);

[[maybe_unused]] static vx_canvas *vx_canvas_begin(vx_window *win, const vx_frame_event *frame);
[[maybe_unused]] static void vx_clear(vx_canvas *c, vx_color colour);
[[maybe_unused]] static void vx_fill_rect(vx_canvas *c, float x, float y, float w, float h, vx_color colour);
[[maybe_unused]] static void vx_circle(vx_canvas *c, float x, float y, float r, vx_color colour);
[[maybe_unused]] static void vx_canvas_present(vx_canvas *c);

[[maybe_unused]] static vx_pixels vx_pixels_begin(vx_window *win, const vx_frame_event *frame);
[[maybe_unused]] static void vx_pixels_present(vx_window *win, vx_pixels *px);

// Immediate-mode UI (03 §6 item 2; M7 step 7e2b): the app describes its UI
// each frame it draws, between vx_ui_begin and vx_ui_end, and holds no
// widget objects. A widget's id is its key's hash seeded with its parent's:
// the key is its label, or the whole string when the label has "##" in it
// ("Delete##row17" shows "Delete"); vx_push_id seeds the widgets inside it
// (rows built in a loop). Input uses the previous frame's rectangles:
// vx_button is true on the frame after a press and a release both on the
// button where it was drawn.
[[maybe_unused]] static vx_ui *vx_ui_begin(vx_window *win, const vx_frame_event *frame);
[[maybe_unused]] static void vx_ui_end(vx_ui *ui);
[[maybe_unused]] static void vx_label(vx_ui *ui, const char *text);
[[maybe_unused]] static bool vx_button(vx_ui *ui, const char *label);
[[maybe_unused]] static void vx_push_id(vx_ui *ui, uint64_t key);
[[maybe_unused]] static void vx_pop_id(vx_ui *ui);

[[maybe_unused]] static vx_voice *vx_voice_open(vx_app *app, vx_sound sound);
[[maybe_unused]] static void vx_voice_play(vx_voice *voice);

#include "vxui.c"
