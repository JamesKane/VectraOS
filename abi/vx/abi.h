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

// clock_read(): the time on the monotonic clock. clock_read(&info): the same,
// and the cycle counter it is made from, for /sys/clock/info (02 §5.1): its
// frequency (the clock is counter * 10^9 / counter_hz, exactly), and flags;
// and the wall clock, as UTC's offset from the monotonic clock (UTC in ns
// since 1970 = monotonic + utc_offset), with VX_CLOCK_UTC once something has
// set it (ADR-0031). User code may always read the counter: rdtsc, or mrs
// cntvct_el0.
//
// clock_set(resource, utc): the wall clock set to utc (ns since 1970, now),
// with the root Resource's MANAGE (ADR-0031): devmgr, from a clock driver.
enum vx_clock_flags : uint32_t {
  VX_CLOCK_INVARIANT = 1, // one rate in every power state
  VX_CLOCK_USER = 2,      // readable in user mode
  VX_CLOCK_TSC = 4,       // x86_64's TSC
  VX_CLOCK_CNTVCT = 8,    // aarch64's virtual counter
  VX_CLOCK_UTC = 16,      // utc_offset has been set: there is a wall clock
};
typedef struct vx_clock_info {
  uint64_t counter_hz;
  uint32_t flags, reserved;
  int64_t utc_offset; // 0 until VX_CLOCK_UTC
} vx_clock_info;

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
  VX_TRIGGER_PAGER,       // a page request (pager_create): source the VMO's key, value its range
  VX_TRIGGER_DMA_FAULT,   // a DmaDomain's device faulted (more than threshold in all); value: the count
};

// The intents a thread declares (01 §8), each a band of the scheduler,
// highest first (ADR-0038). A thread starts as VX_INTENT_INTERACTIVE.
enum vx_intent : uint32_t {
  VX_INTENT_REALTIME = 1,
  VX_INTENT_INTERACTIVE_FRAME,
  VX_INTENT_INTERACTIVE,
  VX_INTENT_THROUGHPUT,
  VX_INTENT_BACKGROUND,
};

// Scheduling contexts (ADR-0038). sched_ctx_create(&params, &handle) makes
// one, a realtime one admitted or REFUSED; sched_ctx_bind(ctx, thread, core)
// binds a thread to it (ctx none: unbinds; thread none: the caller; core -1,
// or a CPU of its reservation); sched_ctx_configure(ctx, &params) changes it
// (ctx none: the caller's own intent, never realtime); and
// sched_reserve(ctx, count, cls, domain, flags, &set) reserves whole CPUs
// for it, all or REFUSED, or with 0 gives them back.
typedef struct vx_sched_params {
  uint32_t intent;            // enum vx_intent
  uint32_t flags;             // 0
  vx_duration period, budget; // realtime's: budget in each period (1 ms to 10 s; 100 µs to the period)
} vx_sched_params;

typedef struct vx_core_set { // sched_reserve's grant
  uint64_t mask;             // CPU indices
  uint32_t count, reserved;
} vx_core_set;

static constexpr uint32_t VX_CORE_ANY = 0;
static inline uint32_t VX_CORE_TIER(uint32_t n) { return 0x100 | n; } // tier 0 the fastest (ADR-0024)
static inline uint32_t VX_CORE_MIN_CAPACITY(uint32_t c) { return 0x2000 | c; } // not yet: REFUSED
static constexpr uint32_t VX_DOMAIN_ANY = 0;
enum vx_reserve_flags : uint32_t { VX_RESERVE_NO_SMT_SIBLINGS = 1, VX_RESERVE_SAME_LLC = 2 };

typedef struct vx_sched_info { // thread_state(GET_SCHED): /proc/N/threads/T/sched
  uint32_t intent;             // the thread's: its context's, or its own
  int32_t core;                // the reserved CPU it is bound to, or -1
  uint32_t bound, reserved_count;
  vx_duration period, budget, left; // its context's; left, of the budget this period
  uint64_t exhausted;               // periods its context ran out of budget in
  uint64_t reserved;                // the CPUs its context reserved
  uint64_t lent_task, lent_thread;  // the channel_call caller it runs for, on its scheduling; or 0
} vx_sched_info;

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
//   cwd=PATH                         the current directory, absolute and
//                                    clean (ADR-0039); without it, /
//   fd=N pipe=read|write end=NAME    descriptor N, 3 to 9 (ADR-0040): the
//                                    message's handle NAME, a pipe end;
//   fd=N file=PATH flags=F offset=O [token=T]   or an open file, joined by
//                                    its token; 0 to 2 are the handles
//                                    stdin, stdout and stderr
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
//
// lent (ADR-0043): bit i lends wr_handles[i], a VMO handle the caller keeps:
// the server is sent a lease of it, with that handle's rights but MANAGE,
// which the kernel revokes when the call returns, however it ends (a reply,
// the deadline, an interrupt, the server's end closed, the caller killed).
// A lent handle that is not a VMO, or a lease, fails the call before it is
// sent (BAD_HANDLE, INVALID).
typedef struct vx_call {
  const void *wr_bytes;
  const vx_handle *wr_handles;
  void *rd_bytes;
  vx_handle *rd_handles;
  uint32_t wr_len, wr_count;
  uint32_t rd_cap, rd_count_cap;
  vx_msg_size actual;
  uint64_t lent;
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
//   dma_domain_create(resource, source, 0, &out)
//       a DmaDomain: what the PCI function whose requester ID is `source`
//       may reach by DMA. devmgr makes and keeps it, and gives its driver a
//       duplicate with MAP (and WAIT, INSPECT). In pass-through mode, the
//       only one so far (QEMU; the IOMMU comes with M5 steps 6c, 6d), a
//       device address is the physical address.
//   dma_map(domain, vmo, offset, size, options, &mapped)
//       the device address of each page of [offset, offset + size), into
//       mapped.addresses[size / 4096], and a DmaMapping for the range in
//       mapped.mapping. options: VX_DMA_READ (the device reads the memory:
//       the VMO handle needs READ), VX_DMA_WRITE (it writes it: WRITE),
//       or both. The mapping holds the VMO's pages for the device
//   dma_unmap(mapping)
//       the device is done with the range: its pages let go at once. A
//       mapping whose handles go without it keeps them until QUIESCED
//   dma_domain_op(domain, op, 0)
//       VX_DMA_REVOKE (MANAGE): every mapping's pages kept for the device
//       until QUIESCED, whatever its driver does; VX_DMA_QUIESCED (MANAGE):
//       the device has been stopped (bus mastering off, reset), so what was
//       kept is let go; VX_DMA_FAULTS (INSPECT): returns how many faults
//       the IOMMU has reported for the device (VX_TRIGGER_DMA_FAULT)
//   iorange_create(resource, base, count, &out)
//       x86_64 only: I/O ports, which a task may use once as_map has been
//       called with the IoRange in place of a VMO (offset, size and flags 0)
//
// Pagers (01 §5, docs/11 §8): a trusted task's supply of pages for VMOs, as
// fsd backs mmap of files. Only a task svcd marked a pager has a Resource
// handle with VX_RIGHT_PAGER (or the root one), which pager_create needs.
//
//   pager_create(resource, port, key, deadline_ns, &out)
//       a Pager: page requests go to port as packets (key, trigger
//       VX_TRIGGER_PAGER, source the VMO's key, value VX_PAGER_RANGE's), and
//       a fault waits deadline_ns for its page before the thread takes a
//       VX_EXCEPTION_PAGER_TIMEOUT
//   vmo_create(size, VX_VMO_PAGER, &out, pager, key)
//       a VMO whose pages the pager supplies, none yet; key (32 bits) names
//       it in requests. A fault on a page it has not supplied asks for it
//       (once, however many fault) and waits. vmo_rw on one is SHOULD_WAIT;
//       vmo_clone and dma_map refuse such a VMO (UNSUPPORTED). A forked task
//       shares its mappings of it, rather than copying them.
//   pager_supply(pager, vmo, offset, size, source, source_offset)
//       the VMO's pages [offset, offset + size) from an anonymous VMO's:
//       copied in where the VMO has none (a supplied page stays as it is),
//       and the threads that wait on them woken
//   pager_op(pager, vmo, op, offset, size, ranges)
//       VX_PAGER_DIRTY: the range's written pages, as at most VX_PAGER_RANGES
//       vx_pager_range into ranges; returns how many. A page is mapped
//       read-only until it is written, and dirty from then on.
//       VX_PAGER_CLEAN: the range's pages clean, and write-protected in every
//       mapping. Clean, then read, then write back: a write before the
//       clean is in what is read, one after it is dirty again.
//       VX_PAGER_EVICT: the range's clean pages freed; a touch asks again.
//       VX_PAGER_IDLE: 1 if the caller's handle is the VMO's only reference
//       (no other handle, no mapping), else 0: the pager may let it go.
//       VX_PAGER_RESIZE (offset 0, size the new size): the VMO's new size;
//       pages past it leave every mapping and are freed (a touch there is an
//       ordinary fault), pages added absent. The pager's alone.
//   vmo_op(vmo, VX_VMO_RESIZE, size)
//       a resizable anonymous VMO's new size (ADR-0042): pages added are
//       zero, pages past the end leave every mapping and are freed (a touch
//       there faults). One made without VX_VMO_RESIZABLE: UNSUPPORTED. A
//       pager-backed one is its pager's to resize (pager_op RESIZE): ACCESS
//       A lazy one's added pages are absent, made at a touch.
//   vmo_op(vmo, VX_VMO_DECOMMIT, offset, size) (ADR-0046)
//       a lazy VMO's pages in the page-aligned range freed, out of every
//       mapping first; a touch reads zeros again. Not lazy: UNSUPPORTED.
// VX_VMO_LAZY (ADR-0046): anonymous memory with no pages at first; a touch
// makes one, zero, and a touch with no memory left is an ordinary page fault.
// Alone or with VX_VMO_RESIZABLE. Not leased, not given to dma_map.
enum vx_vmo_options : uint32_t {
  VX_VMO_PHYSICAL = 1,
  VX_VMO_PAGER = 2,
  VX_VMO_RESIZABLE = 4,
  VX_VMO_LAZY = 8
};
// vmo_seal(vmo) (ADR-0043, 01 §6.6), with WRITE: no one writes the VMO again,
//     through any handle, mapping or lease (vmo_rw, as_map and as_protect
//     with WRITE, a resize: ACCESS). BAD_STATE while any writable mapping
//     of it exists, as memfd's F_SEAL_WRITE; UNSUPPORTED for a physical or
//     pager-backed VMO. Sealing again is VX_OK.
// vmo_lease(vmo, &lease): a lease, a VMO handle on the same pages with the
//     caller's rights and MANAGE, to give away (duplicated without MANAGE);
//     vmo_revoke(lease), with MANAGE: from then on no one reaches the pages
//     through it. Its mappings, in every task, lose their pages, and a touch
//     raises VX_EXCEPTION_REVOKED; vmo_rw, as_map and vmo_clone through it
//     answer REVOKED. A forked task maps a lease's mapping as it is, never a
//     copy, so a revoke reaches it too. Only a plain anonymous VMO is leased
//     (UNSUPPORTED otherwise), and a lease is not leased again (INVALID).
enum vx_dma_options : uint32_t { VX_DMA_READ = 1, VX_DMA_WRITE = 2 }; // what the device may do: dma_map
// system_power(resource, op): the whole machine (the root Resource, MANAGE).
// VX_POWER_OFF: through PSCI where the firmware has it (aarch64); returns,
// UNSUPPORTED, where powering off is ACPI's (x86_64: bus-acpi enters S5).
enum vx_power_op : uint32_t { VX_POWER_OFF = 1 };
enum vx_dma_op : uint32_t { VX_DMA_REVOKE = 1, VX_DMA_QUIESCED = 2, VX_DMA_FAULTS = 3 };
typedef struct vx_dma_mapped { // dma_map's answer
  uint64_t *addresses;         // in: where the pages' device addresses go
  vx_handle mapping;           // out: the DmaMapping
  uint32_t reserved;
} vx_dma_mapped;
enum vx_pager_op : uint32_t {
  VX_PAGER_DIRTY = 1,
  VX_PAGER_CLEAN = 2,
  VX_PAGER_EVICT = 3,
  VX_PAGER_IDLE = 4,
  VX_PAGER_RESIZE = 5,
};
enum vx_vmo_resize_op : uint32_t { VX_VMO_RESIZE = 1, VX_VMO_DECOMMIT = 2 };
static constexpr uint32_t VX_PAGER_RANGES = 64;
typedef struct vx_pager_range {
  uint64_t offset, size;
} vx_pager_range;

// A page request's range, in its packet's value: the first byte's offset
// (page-aligned) and how many pages, less one, in the low 12 bits.
static inline uint64_t vx_pager_offset(uint64_t value) { return value & ~4095ull; }
static inline uint64_t vx_pager_pages(uint64_t value) { return (value & 4095) + 1; }
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
// as_protect(task, address, size, flags): changes the rights and key of the
// pages of [address, address + size), every one mapped, within the rights
// each mapping's VMO handle gave when it was mapped (ACCESS past them); a
// mapping cut by the range becomes two or three (ADR-0035).
// as_reserve(task, size, align, flags, &address) (ADR-0042, 01 §5): a
// reservation, address space no mapping the kernel places lands in, for the
// task's own as_map at addresses inside it; as_unmap there leaves it reserved.
// align: 0 (a page), or a power of two up to 2^39. Without VX_AS_FIXED, at a
// random aligned base; with it, at *address, or EXISTS with *address set to
// the start of the first mapping or reservation in the way. VX_AS_RELEASE:
// the reservation starting at *address of size bytes given back, what is
// mapped in it unmapped (NOT_FOUND if there is none). A mapping placed at an
// address must lie wholly inside one reservation or outside every one (RANGE).
// At most 32 reservations a task (NO_SPACE).
enum vx_as_flags : uint32_t { VX_AS_FIXED = 1, VX_AS_RELEASE = 2 };
// as_key_alloc(task, &key) and as_key_free(task, key): a protection key of
// the task's, 1 to vx_cpu_info.keys (key 0 is every mapping's default),
// with the task handle's MANAGE as as_map takes it; NO_SPACE when none is
// free, UNSUPPORTED where the CPU has none; a key a mapping still uses is not
// freed (BAD_STATE). A thread's rights to each key are its own (PKRU,
// POR_EL0), set with the unprivileged instruction (vx-rt's vx_keys_set).
enum vx_map_flags : uint32_t { // as_map, as_protect; a mapping is readable unless NOACCESS
  VX_MAP_WRITE = 1,
  VX_MAP_EXEC = 2,
  VX_MAP_NOACCESS = 4,     // ADR-0042: no access at all, a touch faults (PROT_NONE, guard pages); alone
  VX_MAP_SHARED = 8,       // ADR-0042, as_map only: a forked task maps the same VMO here, not a copy
  VX_MAP_KEY_MASK = 0xf00, // the mapping's protection key: VX_MAP_KEY(k)
};
#define VX_MAP_KEY(k) ((uint32_t)(k) << 8)
enum vx_key_rights : uint32_t { VX_KEY_READ = 1, VX_KEY_WRITE = 2 }; // vx_keys_set's

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
//     own, at any time (musl's __set_thread_area). GET_FPREGS and SET_FPREGS
//     its FP/SIMD registers, a vx_fpregs, on the same terms (a debugger's
//     fpregs, 05 §3): the legacy part alone, x86_64's FXSAVE image. GET_XSTATE
//     and SET_XSTATE the whole of it, on the same terms (ADR-0035): x86_64's
//     XSAVE standard image of every component XCR0 enables, aarch64's
//     vx_fpregs; vx_cpu_info.xstate_size bytes. A SET_XSTATE with a header bit
//     XCR0 lacks, reserved header bytes set, or an MXCSR bit mxcsr_mask lacks is
//     INVALID. GET_CPU, with thread 0, a vx_cpu_info: what the kernel saves and
//     lets user code use. GET_WATCH and SET_WATCH (DEBUG), with thread 0, the
//     task's watchpoints, a vx_watches, which every thread of it has, from
//     when each next runs; GET says how many the hardware has in count.
//     NEXT_THREAD, at any time, describes the live thread
//     with the next id after `thread` (0: the first) in a vx_thread_info:
//     how procfs lists /proc/N/threads; NOT_FOUND after the last.
//     GET_NOTE_STACK and SET_NOTE_STACK, with thread 0, the caller's note
//     stack, a vx_note_stack (ADR-0036): the kernel diverts the thread to its
//     in-task handler there unless its stack pointer is on it already; size 0
//     for none, else at least VX_NOTE_STACK_MIN bytes inside user memory
//     (RANGE). A new thread has none; fork's thread and exec's have none.
// thread_suspend(task, thread), thread_resume(task, thread): counted, with the
//     DEBUG right; with thread 0, every thread of the task (a process stopped
//     as a whole). A suspended thread stops before it next returns to user
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
  VX_EXCEPTION_FP_DISABLED,    // FP/SIMD while the kernel does not save it (01 §11)
  VX_EXCEPTION_GENERAL,        // any other fault (x86 #GP, say); code: the architecture's
  VX_EXCEPTION_INTERRUPT,      // thread_interrupt; code: the note's length, note: its text
  VX_EXCEPTION_STEP,           // one instruction done, after exception_resume(STEP)
  VX_EXCEPTION_WATCHPOINT,     // a watched address touched; code: the watchpoint's slot, address: what it
                               // watches. x86_64 stops after the access, aarch64 before it (resuming
                               // touches it again: step it with the watchpoint off)
  VX_EXCEPTION_PAGER_TIMEOUT,  // a pager-backed page not supplied by its pager's deadline; address: the
                               // page, code: read 0, write 1, execute 2 (POSIX's SIGBUS)
  VX_EXCEPTION_PROTECTION_KEY, // a page whose key the thread's rights deny; address: what was touched,
                               // code: read 0, write 1, key: the mapping's (ADR-0035; SIGSEGV, SEGV_PKUERR)
  VX_EXCEPTION_REVOKED,        // a page of a lease that was revoked (ADR-0043); address: what was touched,
                               // code: read 0, write 1, execute 2 (POSIX's SIGBUS)
};

typedef struct vx_exception {
  uint32_t kind; // enum vx_exception_kind
  uint32_t code;
  uint64_t address;
  uint32_t thread; // the id of the thread it happened to
  uint32_t key;    // PROTECTION_KEY: the mapping's protection key
  uint64_t rights; // its protection-key rights (PKRU, POR_EL0) when it was diverted to its in-task
                   // handler, which runs with key 0 opened; the handler writes them back as it leaves
  vx_regs regs;
  char note[VX_ERRMAX]; // INTERRUPT: the note, `code` bytes of it
} vx_exception;

enum vx_exception_options : uint32_t { VX_EXCEPTION_IN_TASK = 1, VX_EXCEPTION_FIRST_CHANCE = 2 };
enum vx_resume_action : uint32_t { VX_RESUME_CONTINUE = 1, VX_RESUME_KILL, VX_RESUME_PASS, VX_RESUME_STEP };

#ifdef __x86_64__
typedef struct vx_fpregs { // FXSAVE's 512-byte image: x87, MXCSR, XMM0-15
  uint8_t fxsave[512];
} vx_fpregs;
#elifdef __aarch64__
typedef struct vx_fpregs {
  uint8_t v[32][16]; // V0-V31
  uint64_t fpcr, fpsr;
} vx_fpregs;
#endif

// Watchpoints: the debug registers, x86_64's four, aarch64's two to sixteen.
// An address aligned to its length (1, 2, 4 or 8 bytes), in user space.
static constexpr uint32_t VX_WATCH_MAX = 16;
enum vx_watch_kind : uint32_t { VX_WATCH_OFF, VX_WATCH_WRITE, VX_WATCH_RW };
typedef struct vx_watch {
  uint64_t address;
  uint32_t len;
  uint32_t kind; // enum vx_watch_kind
} vx_watch;
typedef struct vx_watches {
  uint32_t count; // GET_WATCH: how many the hardware has; slots from there on are OFF
  uint32_t reserved;
  vx_watch slot[VX_WATCH_MAX];
} vx_watches;

enum vx_thread_run_state : uint32_t {
  VX_THREAD_RUNNING = 1, // running or ready
  VX_THREAD_BLOCKED,     // waiting in a call
  VX_THREAD_STOPPED,     // at an exception port, until exception_resume
  VX_THREAD_SUSPENDED,   // parked by thread_suspend
};

typedef struct vx_thread_info { // thread_state(NEXT_THREAD)
  uint32_t id;
  uint32_t state;         // enum vx_thread_run_state
  uint32_t suspend_count; // thread_suspend's, less thread_resume's
  uint32_t first_chance;  // STOPPED at a debugger's port (exception_bind FIRST_CHANCE)
} vx_thread_info;

// as_query(task, address, &info): with INSPECT on the task, the first of its
// mappings that ends after address, in a vx_map_info; NOT_FOUND if none. A
// caller lists an address space by asking again from each one's end (procfs's
// /proc/N/maps, 05 §3).
typedef struct vx_map_info {
  uint64_t base, size;
  uint64_t offset; // into the VMO mapped
  uint32_t flags;  // VX_MAP_WRITE, VX_MAP_EXEC; always readable
  uint32_t reserved;
} vx_map_info;

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
  VX_STATE_GET_FPREGS,
  VX_STATE_SET_FPREGS,
  VX_STATE_NEXT_THREAD,
  VX_STATE_GET_WATCH,
  VX_STATE_SET_WATCH,
  VX_STATE_GET_XSTATE, // ADR-0035
  VX_STATE_SET_XSTATE,
  VX_STATE_GET_CPU,
  VX_STATE_GET_NOTE_STACK, // ADR-0036
  VX_STATE_SET_NOTE_STACK,
  VX_STATE_GET_SCHED, // ADR-0038: a vx_sched_info, at any time
  VX_STATE_GET_TIMES, // ADR-0041: a vx_cpu_times, at any time
};

// thread_state's GET_TIMES (ADR-0041): the CPU time a thread, or with thread
// 0 its whole task (threads that have ended too), has had, in nanoseconds,
// sampled as 9front does: each 10 ms tick of a CPU running it is charged to
// user or system time by where the tick found it.
typedef struct vx_cpu_times {
  vx_duration user, sys;
} vx_cpu_times;

// thread_state's GET_NOTE_STACK and SET_NOTE_STACK (ADR-0036): the stack a
// thread's in-task handler runs on, [base, base + size); size 0: none.
typedef struct vx_note_stack {
  uint64_t base, size;
} vx_note_stack;
static constexpr uint64_t VX_NOTE_STACK_MIN = 2048; // as POSIX's MINSIGSTKSZ on x86_64

// thread_set_robust(head, size, owner) (ADR-0037): the calling thread's robust
// list, Linux's: head is three words (the first entry of a ring that ends at
// head, the offset from an entry to its lock word, the entry being added or
// taken off, or 0), size 24, owner the value its lock words hold (1 to
// VX_FUTEX_OWNER_MASK); head 0 unregisters. As the thread ends (exit, kill,
// task_exec) the kernel walks at most 2048 entries and sets each word the
// thread still owns to OWNER_DIED, WAITERS kept, waking one waiter if it was set.
static constexpr uint32_t VX_FUTEX_WAITERS = 0x8000'0000;
static constexpr uint32_t VX_FUTEX_OWNER_DIED = 0x4000'0000;
static constexpr uint32_t VX_FUTEX_OWNER_MASK = 0x3fff'ffff;

// thread_state's GET_CPU (ADR-0035): what the kernel saves of a thread's
// FP/SIMD state, and what user code may use. x86_64 user code asks CPUID for
// instruction sets; aarch64's ID registers trap at EL0, so they are here, as
// the kernel read them, with the fields of what it does not save (SVE, SME)
// zeroed.
typedef struct vx_cpu_info {
  uint32_t xstate_size;   // GET_XSTATE's bytes
  uint32_t keys;          // protection keys a task may allocate; 0: none
  uint32_t cpus_online;   // CPUs that reached the scheduler, numbered from 0 (ADR-0045)
  uint32_t cpus_usable;   // of them, the caller's: unreserved ones and its context's own
  uint64_t cpus_reserved; // bit i: CPU i reserved by a scheduling context
#ifdef __x86_64__
  uint64_t xfeatures; // XCR0: the components saved
  uint32_t mxcsr_mask;
  uint32_t reserved;
#elifdef __aarch64__
  uint64_t isar0, isar1, isar2, pfr0, pfr1, zfr0, smfr0, mmfr3; // ID_AA64*_EL1
#endif
} vx_cpu_info;
