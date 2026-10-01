// vx/abi.h: types shared by the kernel and user space (docs/04 §2).
// Every list here expands from a .def table, so nothing is kept in sync by hand.
#pragma once

#include <stddef.h>
#include <stdint.h>

typedef uint32_t vx_handle;     // table index plus a generation count (docs/01 §3)
typedef int64_t  vx_instant;    // the one monotonic clock, in nanoseconds (docs/01 §4.4)
typedef int64_t  vx_duration;   // nanoseconds

constexpr vx_handle VX_HANDLE_NONE = 0;

typedef struct vx_str {         // length-carrying slice; never NUL-terminated
    const char *ptr;
    size_t      len;
} vx_str;

#define VX_STR(lit) ((vx_str){ .ptr = (lit), .len = sizeof(lit) - 1 })

constexpr vx_instant VX_INFINITE = INT64_MAX;   // a deadline that never comes

// A port packet (docs/01 §4.4): 32 bytes.
typedef struct vx_packet {
    uint64_t   key;        // chosen by whoever bound or posted it
    uint64_t   value;      // counter value, IRQ count, exit status; free for user posts
    vx_instant timestamp;
    uint32_t   source;     // the handle it came from, or 0 for port_post
    uint32_t   trigger;    // enum vx_trigger
} vx_packet;
static_assert(sizeof(vx_packet) == 32);

enum vx_trigger : uint32_t {
    VX_TRIGGER_USER = 1,   // port_post
};

typedef struct vx_task_summary {   // what task_info returns
    uint64_t id;
    char     name[24];          // NUL-padded
} vx_task_summary;

enum vx_map_flags : uint32_t {   // as_map; a mapping is always readable
    VX_MAP_WRITE = 1,
    VX_MAP_EXEC  = 2,
};

enum vx_syscall : uint32_t {
#define VX_SYSCALL(name) VX_SYS_##name,
#include "syscalls.def"
#undef VX_SYSCALL
    VX_SYS_COUNT
};

enum vx_right_bit : uint32_t {
#define VX_RIGHT(name) VX_RIGHT_BIT_##name,
#include "rights.def"
#undef VX_RIGHT
    VX_RIGHT_BIT_COUNT
};

enum vx_rights : uint32_t {
#define VX_RIGHT(name) VX_RIGHT_##name = 1u << VX_RIGHT_BIT_##name,
#include "rights.def"
#undef VX_RIGHT
};

typedef enum vx_status : int32_t {
#define VX_STATUS(name, value) VX_##name = (value),
#include "status.def"
#undef VX_STATUS
} vx_status;

static_assert(VX_OK == 0);
static_assert(VX_RIGHT_BIT_COUNT <= 32);
