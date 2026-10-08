// vx/ns.h: the process's namespace (09 §5.9, ADR-0009; ADR-0004 libvx v0).
// What a process binds, mounts or unmounts is seen by the processes it
// shares a namespace group with; vx_newns gives it a namespace of its own.

#pragma once

#include "api.h"

// bind's and mount's flags: replace old (0), or join its union after or
// before what is there, and take creates there (Plan 9's -a, -b, -c).
enum : uint32_t { VX_MREPL = 0, VX_MAFTER = 1, VX_MBEFORE = 2, VX_MCREATE = 4 };

VX_API vx_status vx_bind(vx_str new_path, vx_str old, uint32_t flags);
// srv is a post (/srv/NAME) or a 9P server's address (tcp!HOST!PORT,
// 9p://HOST:PORT); spec is the attach name ("" for the default).
VX_API vx_status vx_mount(vx_str srv, vx_str spec, vx_str at, uint32_t flags);
// Unmounts what is at at; with from, only that one of its union.
VX_API vx_status vx_unmount(vx_str from, vx_str at);
// A namespace of the process's own from a namespace(6) template: a path, or
// a name under /lib/ns. The process leaves its group, and its table is built
// from the template alone.
VX_API vx_status vx_newns(vx_str tmpl);
