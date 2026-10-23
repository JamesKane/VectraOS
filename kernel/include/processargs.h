// Process bootstrap messages (K8; Zircon's processargs, zircon/processargs.h):
// the ABI shared by the kernel (which starts userboot) and user space. A new
// process's first thread gets a channel handle in its first argument
// register; the first message on it is a croi_proc_args_t header followed
// by a uint32_t handle-info word per handle (CROI_PA_HND), then the
// argument and environment strings, each NUL-terminated.
#pragma once
#include <stdint.h>

enum : uint32_t {
  CROI_PROCARGS_PROTOCOL = 0x4150585d,  // "MXPA"
  CROI_PROCARGS_VERSION = 0x0001000,

  // Handle types (the low byte of an info word; the argument is bits 16-31).
  CROI_PA_PROC_SELF = 0x01,
  CROI_PA_THREAD_SELF = 0x02,
  CROI_PA_JOB_DEFAULT = 0x03,
  CROI_PA_VMAR_ROOT = 0x04,
  CROI_PA_VMAR_LOADED = 0x05,
  CROI_PA_VMO_VDSO = 0x11,
  CROI_PA_VMO_STACK = 0x13,
  CROI_PA_VMO_EXECUTABLE = 0x14,
  CROI_PA_VMO_BOOTDATA = 0x1A,  // read-only ZBI container of firmware items (zbi.h)
  CROI_PA_VMO_BOOTFS = 0x1B,
  // A Node channel in the process's namespace (Fuchsia's PA_NS_DIR, D65); the
  // argument's bits 0-11 index the names table for its path, 12-13 its union
  // placement (0 replace, 1 before, 2 after), bit 14 marks it for creating, and
  // bit 15 seals the namespace (Plan 9's RFNOMNT; on any entry, for them all).
  CROI_PA_NS_DIR = 0x20,
  // The launcher's forwarder for a PA_NS_DIR entry that is a service's mount,
  // with the same argument: a new channel to the service's current instance
  // once the entry's closes (it restarted).
  CROI_PA_NS_RECONNECT = 0x21,
  CROI_PA_FD = 0x30,              // argument: the fd (1: stdout, a debuglog)
  // The server end of the process's own Node tree, its export (Fuchsia's
  // PA_DIRECTORY_REQUEST, D65).
  CROI_PA_DIRECTORY_REQUEST = 0x3B,
  // The UTC page (D48), a VMO the time service writes: argument 0 read only,
  // which the floor maps for clock_gettime; argument 1 writable, the time
  // service's. Fuchsia's PA_CLOCK_UTC was this type.
  CROI_PA_VMO_UTC = 0x40,
  CROI_PA_RESOURCE = 0x3F,        // argument 0: the root resource
  // Each kind's ranged root (Zircon's; userboot gets them all).
  CROI_PA_MMIO_RESOURCE = 0x50,
  CROI_PA_IRQ_RESOURCE = 0x51,
  CROI_PA_IOPORT_RESOURCE = 0x52,  // amd64
  CROI_PA_SMC_RESOURCE = 0x53,     // arm64
  CROI_PA_SYSTEM_RESOURCE = 0x54,
  CROI_PA_MEMORY_ACCOUNT = 0x41,   // croi's (K15a): the process's own account
  CROI_PA_ROOT_ACCOUNT = 0x42,     // croi's (D31): the system's memory levels
  CROI_PA_VMO_DEBUGLOG = 0x43,     // croi's (D38): the debuglog ring, read only (log.h)
  CROI_PA_DEBUGLOG_COUNTER = 0x44, // croi's (D38): its doorbell, the ring's producer cursor
  CROI_PA_USER0 = 0xF0,
  // The userland's, above USER0 (the kernel gives none of them):
  CROI_PA_TRACE_REGION = 0xF1,  // a process's trace region, a VMO (system/trace)
  CROI_PA_DEVICE = 0xF2,        // a driver host's device resources; the argument says which
  CROI_PA_SRV_BOARD = 0xF3,     // the session board, to post to /srv (system/node, D65)
  CROI_PA_STDIO = 0xF4,         // descriptors on rings (D46): the argument says which fd and part (td_stdio.h)
  CROI_PA_VMO_STATUS = 0xF6,    // a page the process writes its exit string to (Plan 9's exits, D72)
};

// Zircon's PA_HND(type, arg).
static inline uint32_t croi_pa_hnd(uint32_t type, uint32_t arg) {
  return (type & 0xFF) | ((arg & 0xFFFF) << 16);
}

// zx_proc_args_t.
typedef struct {
  uint32_t protocol;
  uint32_t version;
  uint32_t handle_info_off;  // uint32_t per handle, in the message's order
  uint32_t args_off;         // args_num NUL-terminated strings
  uint32_t args_num;
  uint32_t environ_off;      // environ_num NUL-terminated strings
  uint32_t environ_num;
  uint32_t names_off;        // names_num NUL-terminated strings: the namespace, a
                             // PA_NS_DIR handle's argument indexing it (D65)
  uint32_t names_num;
} croi_proc_args_t;

// The objects a spawner linked a program with (D124): a dynamically linked
// program's first thread gets this record's address in its second argument
// register (0 for a static program), on the top of its stack. The program
// comes first, then its libraries in load order. A runtime refuses a
// version it doesn't know.
enum : uint64_t {
  CROI_LINK_MAP_MAGIC = 0x50414d4b4e494cULL,  // "LINKMAP"
  CROI_LINK_MAP_VERSION = 1,
};

typedef struct {
  uint64_t magic;
  uint64_t version;
  uint64_t count;      // croi_link_object_t entries, which follow
  uint64_t tls_align;  // the thread pointer's alignment
  uint64_t tls_below;  // bytes of TLS below the thread pointer (amd64)
  uint64_t tls_above;  // and above it (arm64, rv64), the gap included
} croi_link_map_t;

typedef struct {
  uint64_t base;      // where the object's address 0 runs (0 for an ET_EXEC)
  uint64_t phdr;      // its program headers, where they run
  uint64_t phnum;
  uint64_t dynamic;   // its dynamic section, where it runs
  uint64_t name;      // a NUL-terminated name, in the record
  uint64_t tls_image; // its PT_TLS image, where it runs, or 0
  uint64_t tls_file_size;
  uint64_t tls_size;  // 0: no TLS
  int64_t tls_offset; // its TLS block's start, from the thread pointer
  uint64_t init;      // DT_INIT, or 0
  uint64_t init_array;
  uint64_t init_array_count;
  uint64_t init_rank; // its turn to be initialized, from 0: a library after
                      // those it needs, the program last
} croi_link_object_t;
