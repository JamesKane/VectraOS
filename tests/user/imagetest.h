// imagetest.h: what imagetest's code images export (tests/user/imagetest_lib.c),
// which imagetest finds by name (vx_image_symbol) and calls through these types.

#pragma once

#include <vx.h>

extern int image_counter; // each image's own
int image_inits(void);
int image_bump(void);
const char *image_hello(void);
vx_instant image_now(void);
int image_tls_read(void);
const char *image_twice(void);
