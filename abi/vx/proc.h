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
// The arguments (09 §5.1): 0 is the program's name, as C's argv has it.
VX_API vx_strs vx_args(void);
VX_API vx_str vx_arg(size_t i);
VX_API vx_handle vx_task_self(void); // the program's own task, for the calls that take one
VX_API uint64_t vx_pid(void);
VX_API vx_str vx_exe_path(void);
VX_API vx_str vx_user_name(void);
VX_API uint32_t vx_abi_level(void);

// The environment (09 §5.1, ADR-0044): /env/NAME, an rc list's words joined
// by spaces, copied into a; the zero slice if it is not set.
typedef struct vx_arena vx_arena;
VX_API vx_str vx_env_get(vx_str name, vx_arena *a);
// Sets it, for every process of the environment group (Plan 9's putenv).
VX_API vx_status vx_env_set(vx_str name, vx_str value);

// Processes (09 §5.8). A child is its task and its pid, /proc's name for it.
typedef struct vx_proc {
  vx_handle task;
  uint64_t pid;
} vx_proc;

enum : uint32_t {
  VX_PROC_NEWGROUP = 1, // a note group of its own, as Plan 9's RFNOTEG
};

// What to run. args.ptr[0] is the name the program sees for itself (none:
// the path's last element). The handles move to the child, under their
// names, whatever happens; it is also given the caller's stdout, stderr and
// console unless handles name them. ns must be empty in level 0: the child
// shares the caller's namespace group (ADR-0009).
typedef struct vx_spawn_req {
  vx_str path;
  vx_strs args;
  vx_str ns;
  const vx_handle *handles;
  const vx_str *handle_names;
  size_t nhandles;
  uint32_t intent; // its first thread's (enum vx_intent); 0: interactive
  uint32_t flags;  // VX_PROC_NEWGROUP
} vx_spawn_req;

VX_API vx_status vx_proc_spawn(const vx_spawn_req *r, vx_proc *out);
// The program in the caller's place (ADR-0012); returns only on failure.
VX_API vx_status vx_proc_exec(const vx_spawn_req *r);
// Waits until p ends, or deadline; its exit string, "" for success, into
// *exit, copied into a (exit may be nullptr).
VX_API vx_status vx_proc_wait(vx_proc p, vx_instant deadline, vx_arena *a, vx_str *exit);
VX_API void vx_proc_close(vx_proc p);
// Sends p a note (ADR-0010) through /proc/N/note.
VX_API vx_status vx_postnote(vx_proc p, vx_str note);
