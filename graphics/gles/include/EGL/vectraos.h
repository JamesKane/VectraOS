// SPDX-License-Identifier: BSD-3-Clause

// VectraOS's native window for EGL (egl(2)): what a program passes to eglCreateWindowSurface as its
// EGLNativeWindowType (a pointer to one). EGL opens a window of Radharc's of this size and title itself.
// eglplatform.h includes it.

#ifndef VECTRAOS_EGL_H
#define VECTRAOS_EGL_H

#include <stdint.h>

struct vectra_egl_window {
  uint32_t width, height;  // in points
  const char *title;
};

#endif
