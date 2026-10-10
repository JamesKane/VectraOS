// ports/font/kbts.c: kb_text_shape's implementation (ADR-0053), with no C
// library, its allocator lib/vx-font's (hooks.h); the header unchanged.

#include "hooks.h"

#define KB_TEXT_SHAPE_NO_CRT
#define KBTS_MEMSET __builtin_memset
#define KBTS_MEMCPY __builtin_memcpy
#define KBTS_MALLOC(Data, Size) ((void)(Data), vx_font_alloc(Size))
#define KBTS_FREE(Data, Pointer) ((void)(Data), vx_font_free(Pointer))
#define KB_TEXT_SHAPE_IMPLEMENTATION
#include "kb_text_shape.h"
