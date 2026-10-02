// vx-proc: registering a process with procfs (ADR-0011), the user-space half
// of Plan 9's rfork. Everything else about processes is a file in /proc.
//
// A process's pid is its first task's kernel id, which is never reused. Whoever
// spawns a child registers it before it runs, with a channel call on procfs's
// listen channel (the post /srv/proc, or the connector a namespace mounted
// /proc from) carrying a handle to the child's task. procfs keeps the handle:
// it watches for the task's end, to queue a wait record for the parent, and
// it is what posts notes and stops. exec keeps the task (ADR-0012), so it
// needs no registering.

#pragma once

#include "../../abi/vx/abi.h"

enum : uint32_t { PROC_REGISTER = 0x636f'7270 }; // "proc", beside P9_CONNECT on the same channel

enum proc_flags : uint32_t {
  PROC_NOWAIT = 1, // the parent wants no wait record (Plan 9's RFNOWAIT): it watches the task itself
  PROC_NOTEG = 2,  // a note group of its own, rather than the parent's (RFNOTEG)
  PROC_SETSID = 4, // a session of its own too, and a note group (POSIX's setsid, posix_spawn's SETSID)
};

// The call: arg[0] the parent's pid, arg[1] enum proc_flags, arg[2] a note
// group in the parent's session for the child to join (0: none, as the flags
// say); handles [the child's task]. The reply: h.flags 0 or a vx_status,
// arg[0] the child's pid.
typedef struct proc_msg {
  vx_msg_header h;
  int64_t arg[3];
} proc_msg;
