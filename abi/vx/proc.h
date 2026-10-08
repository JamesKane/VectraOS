// vx/proc.h: the process: exit, notes, identity (09 §5.1, 5.8, ADR-0004 libvx v0).
// libvx's public declarations: a native program's, and the system's own
// programs' through lib/vx-rt (VX_API, api.h).

#pragma once

#include "api.h"
// A note's handler (ADR-0010): it returns VX_NCONT to go on, VX_NDFLT for
// the default, which ends the process.
typedef enum vx_noted : uint32_t { VX_NCONT = 0, VX_NDFLT = 1 } vx_noted;
typedef vx_noted vx_note_handler(vx_exception *e, vx_str note, void *fp);

[[noreturn]] VX_API void vx_exits(const char *msg);
[[noreturn]] VX_API void vx_exit(int n);
[[noreturn]] VX_API void vx_abort(void);
VX_API vx_status vx_notify(vx_note_handler *handler);
VX_API vx_handle vx_task_self(void); // the program's own task, for the calls that take one
VX_API uint64_t vx_pid(void);
VX_API vx_str vx_exe_path(void);
VX_API vx_str vx_user_name(void);
VX_API uint32_t vx_abi_level(void);
