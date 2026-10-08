// vx-rt threads (M6 step 6d1): a native program's threads, each with its own
// stack and its own copy of the program's thread-local storage (C's
// thread_local), as the ELF ABI lays it out, and its stack's bounds known.
//
// The TLS image is the program's PT_TLS segment, found through __ehdr_start:
// p_filesz bytes copied, the rest of p_memsz zeroed, at p_align; in a
// dynamic program, each loaded object's, at the offset the loader gave it
// (ADR-0047). The thread pointer (x86_64's FS base, aarch64's TPIDR_EL0)
// points at it as each ABI has it:
//   - x86_64, variant II: the block ends at the thread pointer, rounded to its
//     alignment, and the word there points to itself (%fs:0, which compilers
//     read for the thread pointer). vx-rt's record of the thread (vx_tcb)
//     begins there, that word first.
//   - aarch64, variant I: two words at the thread pointer, then the block, at
//     its alignment past them. The first of the two points to vx_tcb, which
//     sits just below.
// A thread's stack, TLS and record are one VMO, mapped with the unmapped page
// as_map leaves below each mapping as its guard. vx_thread_join waits on a
// word the thread clears as it ends, then unmaps it all; the thread's last
// steps after that word use registers alone, so the unmapping cannot pull
// its stack from under it.
//
// The 9P client is not yet safe between threads: a connection is one
// thread's at a time until 6d4's pipelined client.

#pragma once

#include "../../abi/vx/dl.h"
#include "base.c"
#include "elf.h"

typedef struct vx_tcb {
  struct vx_tcb *self; // x86_64: %fs:0, the thread pointer itself
  void (*fn)(void *);
  void *arg;
  uint64_t stack_lo, stack_hi;
  _Atomic uint32_t running; // 1 until fn returns: vx_thread_join waits on it
  uint32_t id;              // the kernel's id for the thread (thread_create's; the first thread's 1)
} vx_tcb;

// A thread vx_thread_spawn made, for vx_thread_join.
typedef struct vx_thread {
  vx_handle handle;
  uint64_t base, size; // its mapping
  vx_tcb *tcb;
} vx_thread;

// The TLS blocks every thread copies: the program's, and in a dynamic
// program each library's, at its offset from the thread pointer. size is
// what they take on their side of it, align their largest alignment.
static constexpr uint32_t VX_TLS_MODULES = 32;
static struct {
  struct {
    const uint8_t *init;
    uint64_t filesz, memsz;
    int64_t offset;
  } mod[VX_TLS_MODULES];
  uint32_t count;
  uint64_t size, align;
} vx_tls;

extern const vx_elf_header __ehdr_start; // the program's own headers, mapped with its first segment (lld)

static uint64_t vx_round_up(uint64_t v, uint64_t a) { return (v + a - 1) & ~(a - 1); }

// A static program's one block, where its linker put it: on x86_64 ending
// at the thread pointer, on aarch64 past the two words there.
static void vx_tls_find(void) {
  const vx_elf_phdr *ph = (const vx_elf_phdr *)((const uint8_t *)&__ehdr_start + __ehdr_start.phoff);
  vx_tls.align = 16;
  for (uint16_t i = 0; i < __ehdr_start.phnum; i++) {
    if (ph[i].type != VX_PT_TLS) continue;
    uint64_t a = ph[i].align ? ph[i].align : 1; // the block's offset is rounded by it, as lld does
    vx_tls.align = a > 16 ? a : 16;             // the thread pointer's, at least 16
#ifdef __x86_64__
    int64_t offset = -(int64_t)vx_round_up(ph[i].memsz, a);
    vx_tls.size = (uint64_t)-offset;
#else
    int64_t offset = (int64_t)vx_round_up(16, a);
    vx_tls.size = (uint64_t)offset + ph[i].memsz;
#endif
    vx_tls.mod[0].init = (const uint8_t *)ph[i].vaddr;
    vx_tls.mod[0].filesz = ph[i].filesz, vx_tls.mod[0].memsz = ph[i].memsz, vx_tls.mod[0].offset = offset;
    vx_tls.count = 1;
  }
}

static bool vx_tls_given; // the loader's layout, not the program's own PT_TLS

// A dynamic program's blocks, as the loader laid them out (ADR-0047).
[[maybe_unused]] static void vx_tls_from(const vx_dl_handover *dl) {
  vx_tls_given = true;
  vx_tls.count = 0;
  vx_tls.size = dl->tls_size;
  vx_tls.align = dl->tls_align > 16 ? dl->tls_align : 16;
  for (uint32_t i = 0; i < dl->object_count && vx_tls.count < VX_TLS_MODULES; i++) {
    const vx_dl_object *o = &dl->objects[i];
    if (!o->tls_memsz) continue;
    vx_tls.mod[vx_tls.count].init = (const uint8_t *)o->tls_init;
    vx_tls.mod[vx_tls.count].filesz = o->tls_filesz, vx_tls.mod[vx_tls.count].memsz = o->tls_memsz;
    vx_tls.mod[vx_tls.count].offset = o->tls_offset;
    vx_tls.count++;
  }
}

// The bytes a thread's TLS and record need, at most: alignment slack included.
static uint64_t vx_tls_extent(void) {
  uint64_t a = vx_tls.align;
  return vx_round_up(vx_tls.size, a) + 2 * a + sizeof(vx_tcb) + 16;
}

// Lays out a thread's TLS and record at address mem, vx_tls_extent() bytes of zeroed
// memory: the block initialised, the record placed. Returns the thread pointer.
static uint64_t vx_tls_layout(uint64_t mem, vx_tcb **tcb) {
  uint64_t a = vx_tls.align, tp;
#ifdef __x86_64__
  tp = vx_round_up(mem + vx_tls.size, a); // the blocks below it
  *tcb = (vx_tcb *)tp;
  (*tcb)->self = *tcb;
#else
  tp = vx_round_up(mem + sizeof(vx_tcb), a); // the record below it, the blocks past its two words
  *tcb = (vx_tcb *)(tp - sizeof(vx_tcb));
  (*tcb)->self = *tcb;
  *(vx_tcb **)tp = *tcb;
#endif
  for (uint32_t i = 0; i < vx_tls.count; i++)
    if (vx_tls.mod[i].filesz)
      memcpy((void *)(tp + (uint64_t)vx_tls.mod[i].offset), vx_tls.mod[i].init, vx_tls.mod[i].filesz);
  return tp;
}

static void vx_tp_set(uint64_t tp) {
#ifdef __x86_64__
  vx_thread_state(vx_self, 0, VX_STATE_SET_TLS, &tp, sizeof tp);
#else
  __asm__ volatile("msr tpidr_el0, %0" : : "r"(tp));
#endif
}

// The calling thread's record; nullptr on a thread vx-rt did not set up.
[[maybe_unused]] static vx_tcb *vx_tcb_get(void) {
#ifdef __x86_64__
  uint64_t tp;
  vx_thread_state(vx_self, 0, VX_STATE_GET_TLS, &tp, sizeof tp);
  return tp ? *(vx_tcb **)tp : nullptr;
#else
  uint64_t tp;
  __asm__ volatile("mrs %0, tpidr_el0" : "=r"(tp));
  return tp ? *(vx_tcb **)tp : nullptr;
#endif
}

// The calling thread's id, as the kernel gives it (/proc/N/threads/ID).
[[maybe_unused]] static uint32_t vx_thread_self_id(void) {
  const vx_tcb *t = vx_tcb_get();
  return t && t->id ? t->id : 1;
}

// The first thread's TLS and record, at start-up: a VMO of its own; its stack
// is the mapping its stack pointer is in.
static void vx_thread_main_init(void) {
  if (!vx_tls_given) vx_tls_find();
  uint64_t size = vx_round_up(vx_tls_extent(), 4096), at = 0;
  vx_handle v;
  if (vx_vmo_create(size, 0, &v) != VX_OK) return;
  vx_status st = vx_as_map(vx_self, v, 0, size, VX_MAP_WRITE, &at);
  vx_handle_close(v);
  if (st != VX_OK) return;
  vx_tcb *tcb;
  uint64_t tp = vx_tls_layout(at, &tcb);
  vx_map_info mi;
  uint64_t sp = (uint64_t)__builtin_frame_address(0);
  if (vx_as_query(vx_self, sp, &mi) == VX_OK && mi.base <= sp)
    tcb->stack_lo = mi.base, tcb->stack_hi = mi.base + mi.size;
  atomic_store(&tcb->running, 1);
  tcb->id = 1; // a task's first thread
  vx_tp_set(tp);
}

[[noreturn]] static void vx_thread_entry(vx_handle unused, uint64_t tp) {
  (void)unused;
  vx_tp_set(tp); // first: nothing before it may touch thread_local
  vx_tcb *t = vx_tcb_get();
  t->fn(t->arg);
  vx_thread_finish(&t->running);
}

// Starts fn(arg) on a new thread of the program's own task, with a stack of
// stack_size bytes (0: 256 KiB) and its own TLS; *t is for vx_thread_join.
[[maybe_unused]] static vx_status vx_thread_spawn(vx_thread *t, void (*fn)(void *), void *arg,
                                                  uint64_t stack_size) {
  *t = (vx_thread){};
  uint64_t stack = vx_round_up(stack_size ? stack_size : 256ull * 1024, 4096);
  uint64_t size = stack + vx_round_up(vx_tls_extent(), 4096), at = 0;
  vx_handle v, th = VX_HANDLE_NONE;
  vx_status st = vx_vmo_create(size, 0, &v);
  if (st != VX_OK) return st;
  st = vx_as_map(vx_self, v, 0, size, VX_MAP_WRITE, &at);
  vx_handle_close(v);
  if (st != VX_OK) return st;
  vx_tcb *tcb;
  uint64_t tp = vx_tls_layout(at + stack, &tcb);
  tcb->fn = fn, tcb->arg = arg, tcb->stack_lo = at, tcb->stack_hi = at + stack;
  atomic_store(&tcb->running, 1);
  st = vx_thread_create_id(vx_self, &th, &tcb->id);
  if (st == VX_OK) st = vx_thread_start(th, (uint64_t)vx_thread_entry, at + stack, VX_HANDLE_NONE, tp);
  if (st != VX_OK) {
    vx_handle_close(th);
    vx_as_unmap(vx_self, at, size);
    return st;
  }
  *t = (vx_thread){.handle = th, .base = at, .size = size, .tcb = tcb};
  return VX_OK;
}

// Waits for t's function to return, then lets go of its stack and TLS.
[[maybe_unused]] static void vx_thread_join(vx_thread *t) {
  if (!t->tcb) return;
  while (atomic_load(&t->tcb->running)) vx_futex_wait(&t->tcb->running, 1, VX_INFINITE);
  vx_handle_close(t->handle);
  vx_as_unmap(vx_self, t->base, t->size);
  *t = (vx_thread){};
}

// The calling thread's stack: [*lo, *hi). False on a thread vx-rt did not set up.
[[maybe_unused]] static bool vx_thread_stack(uint64_t *lo, uint64_t *hi) {
  const vx_tcb *t = vx_tcb_get();
  if (!t || !t->stack_hi) return false;
  *lo = t->stack_lo, *hi = t->stack_hi;
  return true;
}
