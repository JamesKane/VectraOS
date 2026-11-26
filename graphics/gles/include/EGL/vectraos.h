// SPDX-License-Identifier: BSD-3-Clause

// VectraOS's native window for EGL (egl(2)): what a program passes to eglCreateWindowSurface as its
// EGLNativeWindowType (a pointer to one). EGL opens a window of Radharc's of this size and title itself, or, headless, makes its image alone.
// eglplatform.h includes it.

#ifndef VECTRAOS_EGL_H
#define VECTRAOS_EGL_H

#include <stdint.h>

struct vectra_egl_window {
  uint32_t width, height;  // in points
  const char *title;
  uint32_t flags;  // VECTRA_EGL_WINDOW_*
};

// A window no compositor shows: EGL makes its image itself, and a swap only ends the frame (as a GBM surface with
// no display does elsewhere). glmark2 asks for one off-screen.
#define VECTRA_EGL_WINDOW_HEADLESS 1u

#endif
