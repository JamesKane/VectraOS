// vx-rt spawn: starts a program from an ELF image in memory (docs/01 §9). The
// ELF loader lives here, in user space; the kernel loads only the root task.
//
// The parent builds the child: a task, a VMO per loadable segment mapped at
// its address, a stack, and a bootstrap channel holding the spawn message
// (abi.h), which names the handles the child is given. Then it starts the
// first thread. The child gets nothing else: no ambient authority (01 §2).
//
// To exec, a program builds the new image the same way, in a scratch task,
// and task_exec moves it into the program's own task (ADR-0012): the task, so
// the pid, carries on, with only the handles the spawn message names.
//
// The image is the parent's to trust or not, but it is checked like any other
// input: an image that would map outside the lower half, map a page both
// writable and executable, or reach past its own end is refused.
//
#include "base.c"

typedef struct vx_elf_header {
  uint8_t ident[16];
  uint16_t type, machine;
  uint32_t version;
  uint64_t entry, phoff, shoff;
  uint32_t flags;
  uint16_t ehsize, phentsize, phnum, shentsize, shnum, shstrndx;
} vx_elf_header;

typedef struct vx_elf_phdr {
  uint32_t type, flags;
  uint64_t offset, vaddr, paddr, filesz, memsz, align;
} vx_elf_phdr;

enum : uint32_t { VX_PT_LOAD = 1, VX_PF_X = 1, VX_PF_W = 2 };

#ifdef __x86_64__
static constexpr uint16_t VX_ELF_MACHINE = 62; // EM_X86_64
#else
static constexpr uint16_t VX_ELF_MACHINE = 183; // EM_AARCH64
#endif

static constexpr uint64_t VX_USER_TOP = 0x0000'8000'0000'0000;
// The stack goes just below the top, with an unmapped page above it and
// nothing mapped below it but what the program asks for (a guard reservation
// comes with as_reserve).
static constexpr uint64_t VX_STACK_TOP = 0x0000'7fff'ffff'0000;
static constexpr uint64_t VX_STACK_SIZE = 256ull * 1024; // as the root task's (kernel/obj/task.c)
static constexpr uint32_t VX_ALL_RIGHTS = (1u << VX_RIGHT_BIT_COUNT) - 1;

// Maps each loadable segment of the image into the task. Returns the entry point in *entry.
static vx_status vx_elf_load(vx_handle task, const uint8_t *image, size_t size, uint64_t *entry) {
  vx_elf_header eh;
  if (size < sizeof eh) return VX_ERR_INVALID;
  memcpy(&eh, image, sizeof eh);
  uint64_t table_end;
  if (memcmp(eh.ident,
             "\x7f"
             "ELF",
             4) != 0 ||
      eh.ident[4] != 2 || eh.ident[5] != 1 || eh.type != 2 || eh.machine != VX_ELF_MACHINE ||
      eh.phentsize != sizeof(vx_elf_phdr) || ckd_mul(&table_end, (uint64_t)eh.phnum, sizeof(vx_elf_phdr)) ||
      ckd_add(&table_end, table_end, eh.phoff) || table_end > size || eh.entry >= VX_USER_TOP)
    return VX_ERR_INVALID;

  bool entry_found = false; // the entry point must be in an executable segment
  for (uint16_t i = 0; i < eh.phnum; i++) {
    vx_elf_phdr ph;
    memcpy(&ph, image + eh.phoff + (uint64_t)i * sizeof ph, sizeof ph);
    if (ph.type != VX_PT_LOAD || ph.memsz == 0) continue;
    uint64_t file_end, mem_end;
    // Not in the first page either: there, an address of 0 asks as_map to pick one.
    if (ph.vaddr < 4096 || ph.filesz > ph.memsz || ckd_add(&file_end, ph.offset, ph.filesz) ||
        file_end > size || ckd_add(&mem_end, ph.vaddr, ph.memsz) ||
        mem_end > VX_STACK_TOP - VX_STACK_SIZE - 4096 || ((ph.flags & VX_PF_W) && (ph.flags & VX_PF_X)))
      return VX_ERR_INVALID;
    uint64_t base = ph.vaddr & ~4095ull, map_size = ((mem_end + 4095) & ~4095ull) - base;
    vx_handle vmo;
    vx_status st = vx_vmo_create(map_size, 0, &vmo);
    if (st != VX_OK) return st;
    if (ph.filesz) st = vx_vmo_rw(vmo, VX_VMO_WRITE, ph.vaddr - base, (void *)(image + ph.offset), ph.filesz);
    uint64_t va = base;
    if (st == VX_OK)
      st = vx_as_map(task, vmo, 0, map_size,
                     (ph.flags & VX_PF_W ? VX_MAP_WRITE : 0) | (ph.flags & VX_PF_X ? VX_MAP_EXEC : 0), &va);
    vx_handle_close(vmo); // the mapping keeps it
    if (st != VX_OK) return st;
    if (va != base) return VX_ERR_INVALID; // mapped, but not where the program was linked to run
    if ((ph.flags & VX_PF_X) && eh.entry >= ph.vaddr && eh.entry < mem_end) entry_found = true;
  }
  if (!entry_found) return VX_ERR_INVALID;
  *entry = eh.entry;
  return VX_OK;
}

typedef struct vx_spawn_args {
  vx_str name; // the task's name and the spawn= record
  const uint8_t *image;
  size_t image_size;
  const vx_handle *handles; // given to the child: they leave the caller, whatever happens
  const vx_str *handle_names;
  uint32_t handle_count; // at most VX_CHANNEL_MAX_HANDLES - 1; "self" is added
  vx_str records;        // more ndb records for the spawn message: arg=, mount=, bind=
  // If set, called once the task exists and its image is loaded, before its
  // message is written or its thread started: it may give the child one more
  // handle, named (a POSIX parent registers the child with posixd here).
  vx_status (*prepare)(void *ctx, vx_handle task, vx_handle *handle, vx_str *name);
  void *ctx;
  // Exec instead of spawn: the caller becomes the program, and vx_spawn_elf
  // returns only on a failure. "self" names the caller's own task.
  bool exec;
} vx_spawn_args;

alignas(vx_msg_header) static uint8_t vx_spawn_out[VX_CHANNEL_MAX_BYTES]; // written as a header first

static void vx_close_all(const vx_handle *h, uint32_t n) {
  for (uint32_t i = 0; i < n; i++)
    if (h[i]) vx_handle_close(h[i]);
}

// Builds and starts the child. On success *task is the parent's handle to it,
// to watch (VX_TRIGGER_EXIT) or kill.
[[maybe_unused]] static vx_status vx_spawn_elf(const vx_spawn_args *a, vx_handle *task) {
  *task = VX_HANDLE_NONE;
  vx_handle given[VX_CHANNEL_MAX_HANDLES] = {}; // "self", the caller's, and prepare's
  vx_str names[VX_CHANNEL_MAX_HANDLES] = {VX_STR("self")};
  uint32_t count = 1 + a->handle_count;
  if (count > VX_CHANNEL_MAX_HANDLES - (a->prepare ? 1 : 0)) {
    vx_close_all(a->handles, a->handle_count);
    return VX_ERR_RANGE;
  }
  for (uint32_t i = 0; i < a->handle_count; i++)
    given[i + 1] = a->handles[i], names[i + 1] = a->handle_names[i];

  vx_handle t = VX_HANDLE_NONE, stack = VX_HANDLE_NONE, thread = VX_HANDLE_NONE, ch[2] = {};
  uint64_t entry = 0, stack_at = VX_STACK_TOP - VX_STACK_SIZE;
  vx_status st = vx_task_create(a->name, &t);
  if (st == VX_OK) st = vx_elf_load(t, a->image, a->image_size, &entry);
  if (st == VX_OK) st = vx_vmo_create(VX_STACK_SIZE, 0, &stack);
  if (st == VX_OK) st = vx_as_map(t, stack, 0, VX_STACK_SIZE, VX_MAP_WRITE, &stack_at);
  if (st == VX_OK)
    st = a->exec ? vx_handle_dup(vx_self, VX_RIGHTS_SAME, &given[0])
                 : vx_handle_dup(t, VX_ALL_RIGHTS, &given[0]);
  if (st == VX_OK && a->prepare) {
    st = a->prepare(a->ctx, t, &given[count], &names[count]);
    if (st == VX_OK && given[count]) count++;
  }

  // The spawn message: the header, then its records.
  vx_ndb_writer w = {.buf = (char *)vx_spawn_out + sizeof(vx_msg_header),
                     .cap = sizeof vx_spawn_out - sizeof(vx_msg_header)};
  vx_ndb_put(&w, "spawn", a->name);
  vx_ndb_end(&w);
  for (uint32_t i = 0; i < count; i++) {
    vx_ndb_put(&w, "handle", names[i]);
    vx_ndb_put_u64(&w, "index", i);
    vx_ndb_end(&w);
  }
  if (!w.failed && a->records.len <= w.cap - w.len) {
    memcpy(w.buf + w.len, a->records.ptr, a->records.len);
    w.len += a->records.len;
  } else {
    w.failed = true;
  }
  if (st == VX_OK && w.failed) st = VX_ERR_RANGE;
  *(vx_msg_header *)vx_spawn_out = (vx_msg_header){.ordinal = VX_SPAWN};

  if (st == VX_OK) st = vx_channel_create(0, ch);
  if (st == VX_OK)
    st = vx_channel_write(ch[0], vx_spawn_out, (uint32_t)(sizeof(vx_msg_header) + w.len), given, count);
  else
    vx_close_all(given, count);
  // Moved, whatever happened. Only the caller's own were not given: a failure
  // before the write closed them above.
  for (uint32_t i = 0; i < count; i++) given[i] = VX_HANDLE_NONE;
  if (st == VX_OK && a->exec) st = vx_task_exec(t, ch[1], entry, VX_STACK_TOP); // returns only on a failure
  if (st == VX_OK) st = vx_thread_create(t, &thread);
  if (st == VX_OK) st = vx_thread_start(thread, entry, VX_STACK_TOP, ch[1], 0);
  if (st == VX_OK) ch[1] = VX_HANDLE_NONE; // moved into the child

  if (stack) vx_handle_close(stack); // the mapping keeps it
  if (thread) vx_handle_close(thread);
  vx_close_all(ch, 2); // the child reads its message after our end is gone
  if (st != VX_OK) {
    if (t) {
      vx_task_kill(t, VX_STR("spawn failed"));
      vx_handle_close(t);
    }
    return st;
  }
  *task = t;
  return VX_OK;
}
