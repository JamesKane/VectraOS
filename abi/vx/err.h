// vx/err.h: the calling thread's last error, in words (09 §4.2, ADR-0004
// libvx v0). Calls return a vx_status; the detail, a server's Rerror
// unchanged among them, is here, up to VX_ERRMAX bytes.

#pragma once

#include "api.h"

VX_API vx_str vx_errstr(void);
