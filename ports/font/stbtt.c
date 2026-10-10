// ports/font/stbtt.c: stb_truetype's implementation (ADR-0052), its hooks
// lib/vx-font's (hooks.h); the header unchanged.

#include "hooks.h"

#define STBTT_ifloor(x) ((int)vx_font_floor(x))
#define STBTT_iceil(x) ((int)vx_font_ceil(x))
#define STBTT_sqrt(x) vx_font_sqrt(x)
#define STBTT_pow(x, y) vx_font_pow(x, y)
#define STBTT_fmod(x, y) vx_font_fmod(x, y)
#define STBTT_cos(x) vx_font_cos(x)
#define STBTT_acos(x) vx_font_acos(x)
#define STBTT_fabs(x) vx_font_fabs(x)
#define STBTT_malloc(x, u) ((void)(u), vx_font_alloc(x))
#define STBTT_free(x, u) ((void)(u), vx_font_free(x))
#define STBTT_assert(x) ((void)0)
#define STBTT_strlen(x) vx_font_strlen(x)
#define STBTT_memcpy __builtin_memcpy
#define STBTT_memset __builtin_memset
#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"
