// vx/abi.h: types shared by the kernel and user space (docs/04 §2).
// Every list here expands from a .def table, so nothing is kept in sync by hand.
#pragma once

#include <stddef.h>
#include <stdint.h>

typedef uint32_t vx_handle;  // table index plus a generation count (docs/01 §3)
typedef int64_t vx_instant;  // the one monotonic clock, in nanoseconds (docs/01 §4.4)
typedef int64_t vx_duration; // nanoseconds

static constexpr vx_handle VX_HANDLE_NONE = 0;

typedef struct vx_str { // length-carrying slice; never NUL-terminated
  const char *ptr;
  size_t len;
} vx_str;

#define VX_STR(lit) ((vx_str){.ptr = (lit), .len = sizeof(lit) - 1})

static constexpr vx_instant VX_INFINITE = INT64_MAX; // a deadline that never comes

// A port packet (docs/01 §4.4): 32 bytes.
typedef struct vx_packet {
  uint64_t key;   // chosen by whoever bound or posted it
  uint64_t value; // counter value, IRQ count, exit status; free for user posts
  vx_instant timestamp;
  uint32_t source;  // the handle it came from, or 0 for port_post
  uint32_t trigger; // enum vx_trigger
} vx_packet;
static_assert(sizeof(vx_packet) == 32);

// What a port binding waits for (port_bind). A binding is one-shot: it fires
// once, at once if its condition already holds, and is gone.
enum vx_trigger : uint32_t {
  VX_TRIGGER_USER = 1,    // port_post
  VX_TRIGGER_READABLE,    // a channel end has a message to read
  VX_TRIGGER_PEER_CLOSED, // a channel end's peer is gone
  VX_TRIGGER_COUNTER_GE,  // a counter has reached the binding's threshold; value: the counter
  VX_TRIGGER_EXIT,        // a task has ended; value: its exit status
  VX_TRIGGER_IRQ,         // an Irq has fired since it was last bound; value: how many times in all
};

// The intents a thread declares (01 §8). Until scheduling contexts land, every
// thread is VX_INTENT_INTERACTIVE.
enum vx_intent : uint32_t {
  VX_INTENT_REALTIME = 1,
  VX_INTENT_INTERACTIVE_FRAME,
  VX_INTENT_INTERACTIVE,
  VX_INTENT_THROUGHPUT,
  VX_INTENT_BACKGROUND,
};

// Every channel message starts with this header (01 §4.2). The kernel writes
// sender_intent; the rest is the protocol's.
typedef struct vx_msg_header {
  uint32_t txid;    // matches a reply to its call; 0 for a message that wants none
  uint32_t ordinal; // the protocol's operation
  uint32_t flags;
  uint32_t sender_intent; // enum vx_intent of the sending thread
} vx_msg_header;
static_assert(sizeof(vx_msg_header) == 16);

static constexpr uint32_t VX_CHANNEL_MAX_BYTES = 64 * 1024;
static constexpr uint32_t VX_CHANNEL_MAX_HANDLES = 64;

typedef struct vx_msg_size { // what channel_read and channel_call report
  uint32_t bytes;
  uint32_t handles;
} vx_msg_size;

// The spawn message (01 §9). A new task's first thread starts with one handle,
// its bootstrap channel, and the first message there comes from its parent
// (for the root task, from the kernel): this header with ordinal VX_SPAWN,
// then ndb records (02 §4.1) saying what the message's handles are and what
// the program is given:
//
//   spawn=NAME                       the program
//   handle=NAME index=N              the message's handle N; "self" is the task
//   arg=VALUE                        an argument; repeated, in order
//   cmdline=VALUE                    the kernel command line (the root task's)
//   bootimage size=N                 the boot image's length (the bootimage handle)
//   mount=OLD handle=NAME [aname=A] [flags=F] [src=S]    the namespace, as
//   bind=OLD new=NEW [flags=F]                           vx-ns replays it
static constexpr uint32_t VX_SPAWN = 0x6e77'7073; // "spwn"

// channel_call's buffers: what to send, and where the reply goes.
typedef struct vx_call {
  const void *wr_bytes;
  const vx_handle *wr_handles;
  void *rd_bytes;
  vx_handle *rd_handles;
  uint32_t wr_len, wr_count;
  uint32_t rd_cap, rd_count_cap;
  vx_msg_size actual;
} vx_call;

// --- Rings (01 §4.3) ---
//
// A ring is one VMO both sides map: this header, four index lines, the
// submission and completion queues, and an arena for each side. The kernel
// writes the header when it creates the ring and never reads the ring again;
// lib/vx-ring is the protocol. Every offset is from the start of the VMO.

static constexpr uint32_t VX_RING_MAGIC = 0x4252'5856; // "VXRB", little-endian
static constexpr uint32_t VX_RING_VERSION = 1;
static constexpr uint32_t VX_RING_NEED_WAKEUP = 1; // in a consumer line's flags: it sleeps, ring the doorbell

typedef struct vx_ring_header {
  uint32_t magic, version;
  uint32_t sq_entries, cq_entries; // powers of two
  uint32_t sqe_size, cqe_size;     // bytes per entry
  uint32_t features;
  uint32_t reserved;
  uint64_t sq_offset, cq_offset; // the entries
  uint64_t client_arena_offset, client_arena_size;
  uint64_t server_arena_offset, server_arena_size;
  uint64_t size; // of the whole VMO
} vx_ring_header;

// The four index lines start at 4096, 64 bytes apart, so no two sides write
// one cache line: SQ tail (client), SQ head and flags (server), CQ tail
// (server), CQ head and flags (client). Indices run free and wrap at 2^32.
typedef struct vx_ring_index {
  uint32_t index;
  uint32_t flags; // the consumer lines only: VX_RING_NEED_WAKEUP
  uint8_t pad[56];
} vx_ring_index;
static_assert(sizeof(vx_ring_index) == 64);

static constexpr uint64_t VX_RING_INDEX_OFFSET = 4096;
enum vx_ring_line : uint32_t { VX_RING_SQ_TAIL, VX_RING_SQ_HEAD, VX_RING_CQ_TAIL, VX_RING_CQ_HEAD };

typedef struct vx_ring_params { // ring_create's request
  uint32_t sq_entries, cq_entries;
  uint32_t sqe_size, cqe_size;         // multiples of 16, at most 256
  uint64_t client_arena, server_arena; // bytes, rounded up to pages
} vx_ring_params;

typedef struct vx_ring_handles { // ring_create's answer
  vx_handle client, server;      // the two ends
  vx_handle memory;              // the VMO; each side maps it
} vx_ring_handles;

enum vx_ring_xfer : uint32_t { // ring_xfer_handles
  VX_RING_PUT = 0,             // handles -> a slot for the peer; returns the slot
  VX_RING_TAKE = 1,            // a slot from the peer -> handles; returns their count
};

static constexpr uint32_t VX_RING_SLOTS = 16;       // per direction
static constexpr uint32_t VX_RING_SLOT_HANDLES = 4; // per slot

enum vx_sqe_flags : uint16_t { VX_SQE_LINK = 1, VX_SQE_DREF = 2, VX_SQE_HANDLES = 4, VX_SQE_FENCE = 8 };

typedef struct vx_sqe { // the generic submission entry, 64 bytes (01 §4.3)
  alignas(64) uint16_t opcode;
  uint16_t flags;      // enum vx_sqe_flags
  uint8_t reserved[4]; // no per-entry priority: the service class belongs to the ring
  uint64_t user_data;  // echoed in the vx_cqe
  uint64_t target;     // fid, block, socket, surface: the protocol's
  uint64_t offset;
  uint32_t arena_off; // valid with DREF
  uint32_t len;
  uint32_t handle_slot; // valid with HANDLES
  uint32_t pad;
  uint8_t inline_data[16];
} vx_sqe;
static_assert(sizeof(vx_sqe) == 64);

typedef struct vx_cqe { // the generic completion entry, 32 bytes
  alignas(32) uint64_t user_data;
  int64_t result;
  uint32_t flags, aux;
  uint64_t aux2;
} vx_cqe;
static_assert(sizeof(vx_cqe) == 32);

// Devices (01 §7.1). A Resource is root authority over physical memory that
// is not RAM, interrupt lines and I/O ports; svcd gets it, and makes narrower
// objects from it for each driver:
//
//   vmo_create(size, VX_VMO_PHYSICAL, &out, resource, physical_address)
//       MMIO: uncached device memory, never RAM; mapped like any VMO
//   irq_create(resource, line, 0, &out)
//       x86_64: an ISA IRQ below 16 (through the firmware's overrides), or a
//       GSI; aarch64: a GIC SPI's INTID. Bound to a port with
//       VX_TRIGGER_IRQ. A level-triggered line is masked when it fires until
//       irq_ack; an edge-triggered one is never masked, and a binding made
//       after it fired fires at once.
//   iorange_create(resource, base, count, &out)
//       x86_64 only: I/O ports, which a task may use once as_map has been
//       called with the IoRange in place of a VMO (offset, size and flags 0)
enum vx_vmo_options : uint32_t { VX_VMO_PHYSICAL = 1 };

enum vx_vmo_op : uint32_t { // vmo_rw
  VX_VMO_READ = 0,
  VX_VMO_WRITE = 1,
};

typedef enum vx_task_state : uint32_t {
  VX_TASK_NEW = 0, // no thread has started
  VX_TASK_RUNNING,
  VX_TASK_EXITED, // every thread has exited, or it was killed
} vx_task_state;

typedef struct vx_task_summary { // what task_info returns
  uint64_t id;
  char name[24]; // NUL-padded
  vx_task_state state;
  uint32_t threads;    // live threads
  int64_t exit_status; // once EXITED
  uint64_t mapped;     // bytes mapped into its address space
} vx_task_summary;

enum vx_map_flags : uint32_t { // as_map; a mapping is always readable
  VX_MAP_WRITE = 1,
  VX_MAP_EXEC = 2,
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
static_assert(VX_RIGHT_BIT_COUNT <= 31);
static constexpr uint32_t VX_RIGHTS_SAME = 1u << 31; // handle_dup: the rights the handle has
