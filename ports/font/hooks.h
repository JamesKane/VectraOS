// ports/font/hooks.h: what the vendored text libraries call instead of a C
// library, defined by lib/vx-font (font.c): its heap, and the math
// stb_truetype uses (sqrt, floor and ceil to rasterize; pow, fmod, cos and
// acos only in its signed-distance-field functions, which nothing calls).

#pragma once

#include <stddef.h>

void *vx_font_alloc(size_t n);
void vx_font_free(void *p);
double vx_font_floor(double x);
double vx_font_ceil(double x);
double vx_font_sqrt(double x);
double vx_font_pow(double x, double y);
double vx_font_fmod(double x, double y);
double vx_font_cos(double x);
double vx_font_acos(double x);
double vx_font_fabs(double x);
size_t vx_font_strlen(const char *s);
