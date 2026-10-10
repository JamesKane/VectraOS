// imagetest_lib: the code images imagetest opens (M7 step 7g2a, ADR-0056),
// one source built three ways: libimage.so, which calls libvx, keeps state
// its constructor sets and hands out a string; libimagetls.so, the same with
// thread-local storage, which vx_image_open refuses; and libimageneeds.so,
// which needs libimage.so, loaded by no one but as an image, so refused too.

#include "imagetest.h"

#ifdef IMAGE_TLS
static thread_local int image_tls = 1;
int image_tls_read(void) { return image_tls; }
#endif

#ifdef IMAGE_NEEDS
const char *image_twice(void) { return image_hello(); }
#else
int image_counter;
static int inits;
static const char *const hello = "a string in an image";

[[gnu::constructor]] static void image_init(void) { inits++, image_counter = 10; }

static int image_hidden(void) { return 7; }

int image_inits(void) { return inits; }
int image_bump(void) { return ++image_counter + image_hidden() * 0; }
const char *image_hello(void) { return hello; }
vx_instant image_now(void) { return vx_now(); } // bound to libvx.so's
#endif
