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

// The longest exit string or note, in bytes: Plan 9's ERRMAX (ADR-0010).
static constexpr uint32_t VX_ERRMAX = 128;

// A port packet (docs/01 §4.4): 32 bytes.
typedef struct vx_packet {
  uint64_t key;   // chosen by whoever bound or posted it
  uint64_t value; // counter value, IRQ count, exit string's length; free for user posts
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
  VX_TRIGGER_EXIT,        // a task has ended; value: its exit string's length (0: success)
  VX_TRIGGER_IRQ,         // an Irq has fired since it was last bound; value: how many times in all
  VX_TRIGGER_EXCEPTION,   // a thread stopped at an exception (exception_bind); value: its thread id
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
//   argv0=VALUE                      the POSIX argv[0], when it is not the
//                                    program's name (posix_spawn)
//   env=NAME=VALUE                   an environment variable (the POSIX
//                                    personality's); repeated
//   cmdline=VALUE                    the kernel command line (the root task's)
//   entropy=BYTES                    32 bytes to seed a random generator: the
//                                    bootloader's (the root task's), or one its
//                                    parent made for it (lib/vx-rand)
//   bootimage size=N                 the boot image's length (the bootimage handle)
//   mount=OLD handle=NAME [aname=A] [flags=F] [src=S]    the namespace, as
//   bind=OLD new=NEW [flags=F]                           vx-ns replays it
static constexpr uint32_t VX_SPAWN = 0x6e77'7073; // "spwn"

// channel_call's buffers: what to send, and where the reply goes. A call that
// ends without its reply (interrupted, or past its deadline) takes back its
// request if the server has not read it yet: it is never answered, and its
// handles are closed. An interrupted call whose request the server has read
// waits on for the reply, so no answer is lost; the interrupt comes when the
// call returns. A server that holds calls answers one before interrupting
// its caller.
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
//   irq_create(resource, source, VX_IRQ_MSI, &out, &msi)
//       an MSI or MSI-X interrupt for the PCI function whose requester ID
//       (bus << 8 | device << 3 | function) is `source`: the kernel picks
//       it, and vx_msi says what the device must write, and where. Always
//       edge-triggered. (x86_64: an APIC vector; arm64: an LPI, through the
//       GIC's ITS, which knows the device by its requester ID.)
//   dma_domain_create(resource, 0, &out)
//       a DmaDomain: what a device may reach by DMA. In pass-through mode,
//       the only one so far (QEMU; the IOMMU comes with M5), a device
//       address is the physical address.
//   dma_map(domain, vmo, offset, size, addresses)
//       the device address of each page of [offset, offset + size), into
//       addresses[size / 4096]; the domain holds the VMO until dma_unmap
//   dma_unmap(domain, vmo)
//   iorange_create(resource, base, count, &out)
//       x86_64 only: I/O ports, which a task may use once as_map has been
//       called with the IoRange in place of a VMO (offset, size and flags 0)
enum vx_vmo_options : uint32_t { VX_VMO_PHYSICAL = 1 };
enum vx_irq_options : uint32_t { VX_IRQ_MSI = 1 };

typedef struct vx_msi { // what a device writes to raise an MSI
  uint64_t address;
  uint32_t data;
  uint32_t reserved;
} vx_msi;

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
  uint32_t threads; // live threads
  uint64_t mapped;  // bytes mapped into its address space
  uint32_t blocked; // live threads that are waiting
  uint32_t exit_len;
  char exit[VX_ERRMAX]; // once EXITED, its exit string: exit_len bytes, empty for success
} vx_task_summary;

// A task ends with an exit string (ADR-0010): empty for success, else why, in
// at most VX_ERRMAX bytes of UTF-8. task_kill(task, msg, len, id) ends it with
// msg; a task whose last thread exits (thread_exit) ends with the empty
// string; a fault no one handles ends it with Plan 9's words for the trap
// ("sys: trap: fault read addr=0x0 pc=0x401000").
//
// task_info(task, &summary, id, flags) and task_kill(task, msg, len, id) act on
// the task itself, or with an id, on that task if it is the task or one of
// its descendants (the tasks it created, theirs, and so on; a task whose
// creator has gone passes to its creator's creator). With VX_TASK_NEXT,
// task_info finds the one with the next id after `id` instead, so a holder of
// a task handle can list its tree (procfs). There is no other way to reach a
// task: no global lookup (01 §3).
enum vx_task_info_flags : uint32_t { VX_TASK_NEXT = 1 };

// as_map(task, vmo, offset, size, flags, &address): maps part of a VMO, at
// *address, or where the kernel picks with *address 0.
// as_unmap(task, address, size): unmaps the pages of [address, address + size),
// whole mappings or parts of them; a mapping cut in the middle becomes two.
// Pages nothing maps there are left alone. Once it returns, no CPU can reach
// the pages through those addresses any more.
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

// --- Exceptions and interrupts (docs/01 §9, 05 §2) ---
//
// A fault in user mode goes first to a debugger's port, if one is bound with
// FIRST_CHANCE, then to the task's in-task handler, if it has one, then to its
// exception port, then to the default: the task is killed (05 §2).
//
// task_create(name, len, &task, options): a new task, with nothing in it.
//     With FORK, it has a copy of the caller's memory, made now, and of its
//     handle table: the same values and rights, a handle to the caller
//     becoming one to the new task. Rings' memory and device memory are not
//     copied, and the copy has no threads: the caller starts one (01 §9).
enum vx_task_options : uint32_t { VX_TASK_FORK = 1 };
// thread_start(thread, entry, sp, handle, arg2): runs entry(handle, arg2) as
//     if called, sp being a 16-aligned stack top: on x86_64 with a zero
//     return address just below it, so any C function can be the entry.
// exception_bind(task, port, key, options): with options 0, faults stop the
//     thread and post a packet to port: trigger VX_TRIGGER_EXCEPTION, the
//     binding's key, and value the thread's id (from 1, in creation order). A
//     port of VX_HANDLE_NONE unbinds. With VX_EXCEPTION_IN_TASK, key is a
//     handler in the task (port ignored, 0 unbinds): the kernel puts a
//     vx_exception on the faulting thread's own stack, below the 128 bytes
//     under its stack pointer, and starts the thread at handler(exception).
//     A handler never returns: it resumes with exception_resume. With
//     VX_EXCEPTION_FIRST_CHANCE (and the DEBUG right), a debugger's port, as
//     with options 0 but before the rest; it also gets STEP exceptions.
// exception_resume(task, thread, action, regs): resumes a thread stopped at
//     its port: CONTINUE (with the registers at regs, if not null; else as it
//     stopped, retrying the instruction), KILL, or, from a debugger's port,
//     PASS (to whoever is next in line) or STEP (CONTINUE for one instruction,
//     then a STEP exception to the debugger). With thread 0, the caller
//     resumes itself from its handler: CONTINUE with the registers its
//     vx_exception holds, perhaps changed.
// thread_state(task, thread, op, buffer, size): for a thread stopped at a
//     port, GET_EXCEPTION reads its vx_exception; for one stopped or suspended,
//     GET_REGS and SET_REGS its registers (DEBUG for a suspended one).
//     GET_TLS and SET_TLS its thread pointer (x86_64's FS base, aarch64's
//     TPIDR_EL0), a uint64_t, on the same terms; with thread 0, the caller's
//     own, at any time (musl's __set_thread_area).
// thread_suspend(task, thread), thread_resume(task, thread): counted, with the
//     DEBUG right. A suspended thread stops before it next returns to user
//     mode; thread_suspend returns once it has (stopped there, or blocked in a
//     call), or TIMED_OUT after a second.
// task_mem_rw(task, ops, count): with the DEBUG right, copies between another
//     task's memory and the caller's, a vx_mem_op each; each op gets its own
//     status. A write to a mapping that is not writable (code, for a
//     breakpoint) first gives the task a private copy of that mapping, as
//     ptrace does: never a writable mapping of it.
// thread_interrupt(task, thread, note, len): posts a note (ADR-0010), a
//     string of 1 to VX_ERRMAX bytes, to the thread (any thread of the task,
//     with thread 0): a call it is blocked in returns ERR_INTERRUPTED, and on
//     its way back to user mode it is diverted to the in-task handler with an
//     exception of kind INTERRUPT carrying the note. A task with no in-task
//     handler ends instead, with the note as its exit string, as in Plan 9.
//     Up to eight notes wait for delivery, each its own exception; more is
//     SHOULD_WAIT.
// vmo_clone(vmo, offset, size, options, &out): a new VMO holding a copy of the
//     range, charged in full (01 §5: commit, not overcommit).
//
// Registers a handler or a debugger may change are checked: a thread can be
// given any user-mode state, and never a privileged one.

#ifdef __x86_64__
typedef struct vx_regs {
  uint64_t rax, rbx, rcx, rdx, rsi, rdi, rbp, rsp;
  uint64_t r8, r9, r10, r11, r12, r13, r14, r15;
  uint64_t rip, rflags;
} vx_regs;
#elifdef __aarch64__
typedef struct vx_regs {
  uint64_t x[31]; // x30 is the link register
  uint64_t sp, pc, pstate;
} vx_regs;
#endif

enum vx_exception_kind : uint32_t {
  VX_EXCEPTION_PAGE_FAULT = 1, // address: what was touched; code: read 0, write 1, execute 2
  VX_EXCEPTION_ILLEGAL,        // an undefined or privileged instruction
  VX_EXCEPTION_BREAKPOINT,     // int3, brk
  VX_EXCEPTION_ARITHMETIC,     // division by zero, an FP exception
  VX_EXCEPTION_ALIGNMENT,
  VX_EXCEPTION_FP_DISABLED, // FP/SIMD while the kernel does not save it (01 §11)
  VX_EXCEPTION_GENERAL,     // any other fault (x86 #GP, say); code: the architecture's
  VX_EXCEPTION_INTERRUPT,   // thread_interrupt; code: the note's length, note: its text
  VX_EXCEPTION_STEP,        // one instruction done, after exception_resume(STEP)
};

typedef struct vx_exception {
  uint32_t kind; // enum vx_exception_kind
  uint32_t code;
  uint64_t address;
  uint32_t thread; // the id of the thread it happened to
  uint32_t reserved;
  vx_regs regs;
  char note[VX_ERRMAX]; // INTERRUPT: the note, `code` bytes of it
} vx_exception;

enum vx_exception_options : uint32_t { VX_EXCEPTION_IN_TASK = 1, VX_EXCEPTION_FIRST_CHANCE = 2 };
enum vx_resume_action : uint32_t { VX_RESUME_CONTINUE = 1, VX_RESUME_KILL, VX_RESUME_PASS, VX_RESUME_STEP };

typedef struct vx_mem_op { // task_mem_rw
  uint64_t address;        // in the task
  uint64_t buffer;         // in the caller
  uint64_t size;
  uint32_t write; // 1: buffer to address; 0: address to buffer
  int32_t status; // set by the kernel: a vx_status
} vx_mem_op;
enum vx_thread_state_op : uint32_t {
  VX_STATE_GET_EXCEPTION = 1,
  VX_STATE_GET_REGS,
  VX_STATE_SET_REGS,
  VX_STATE_GET_TLS,
  VX_STATE_SET_TLS,
};
