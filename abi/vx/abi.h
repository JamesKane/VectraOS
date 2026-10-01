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
