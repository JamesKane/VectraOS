// libvxui.c: libvxui.so (ADR-0056, M7 step 7g2a), vxui as the SDK's shared
// object: vxui.c built against libvx's public calls (libvx.so) with its
// calls exported, and its own copies of what holds no state of its own: the
// text stack (lib/vx-font, the font port built position-independent),
// lib/vx-buffer, and the window and input protocols' headers. An app links
// it and libvx.so, and includes vxui.h.

#define VXUI_LIB
#include "vxui.h"
