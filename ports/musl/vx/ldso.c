// ldso.c: libc.so as the interpreter of a dynamic POSIX program (M6 step
// 6f1b2: musl's own dynamic linker, decided 2026-10-07). Part of backend.c,
// in libc.so alone (SHARED).
//
// A spawn maps libc.so in the program's place (its PT_INTERP,
// /lib/ld-musl-ARCH.so.1) and enters _vx_dlstart with the bootstrap channel,
// and nothing on the stack. Before libc.so is relocated nothing here may
// reach a global but through PC-relative addresses: _vx_dlstart keeps the
// channel, and gives musl's _dlstart_c a first stack of its own with
// AT_BASE, libc.so's load address; musl relocates libc.so (_dlstart_c, then
// __dls2). Then, at the start of __dls2b, which a line ./build adds to its
// copy of dynlink.c calls, __vx_dls2b_hook starts the back end from the
// spawn message, maps the program from the VMO dl.exe the spawn gave, and
// gives musl the stack Linux would have: the program's headers, entry and
// libc.so's base in the auxiliary vector. musl's stage 3 loads and binds
// the program and enters it through musl's own crt1.

// The linker's: libc.so's own ELF header (its load address) and dynamic
// section, hidden, so reached PC-relative before relocation.
extern const char vx_ld_ehdr[] __asm__("__ehdr_start") __attribute__((visibility("hidden")));
extern size_t _DYNAMIC[] __attribute__((visibility("hidden")));
void _dlstart_c(size_t *sp, size_t *dynv) __attribute__((visibility("hidden"))); // musl's ldso/dlstart.c

static vx_handle ld_bootstrap;
static size_t ld_first[10]; // argc 0, no argv, no environment, AT_BASE, AT_PAGESZ, AT_NULL

[[gnu::no_stack_protector, gnu::used, gnu::visibility("hidden")]] void __vx_dlstart_c(vx_handle bootstrap);
void __vx_dlstart_c(vx_handle bootstrap) {
  ld_bootstrap = bootstrap;
  ld_first[3] = AT_BASE, ld_first[4] = (size_t)vx_ld_ehdr;
  ld_first[5] = AT_PAGESZ, ld_first[6] = 4096;
  _dlstart_c(ld_first, _DYNAMIC);
}

#ifdef __x86_64__
__asm__(".text\n"
        ".global _vx_dlstart\n"
        ".type _vx_dlstart, @function\n"
        "_vx_dlstart:\n\t"
        "endbr64\n\t"
        "xorl %ebp, %ebp\n\t"
        "andq $-16, %rsp\n\t"
        "call __vx_dlstart_c\n\t" // the bootstrap channel is in rdi
        "ud2\n");
#else
__asm__(".text\n"
        ".global _vx_dlstart\n"
        ".type _vx_dlstart, %function\n"
        "_vx_dlstart:\n\t"
        "bti c\n\t"
        "mov x29, xzr\n\t"
        "mov x30, xzr\n\t"
        "bl __vx_dlstart_c\n\t" // the bootstrap channel is in x0
        "brk #0\n");
#endif

[[noreturn]] static void ld_fail(const char *why) {
  vx_print(VX_STR("ld-musl: "));
  vx_print(vx_cstr(why));
  vx_print(VX_STR("\n"));
  vx_task_kill(vx_self, vx_cstr(why));
  __builtin_trap();
}

// The program, from dl.exe, at its link address; its program headers' address,
// their number and its entry.
static void ld_map_program(vx_handle exe, uintptr_t *phdr, size_t *phnum, uintptr_t *entry) {
  uint8_t head[4096];
  Elf64_Ehdr eh;
  if (vx_vmo_rw(exe, VX_VMO_READ, 0, head, sizeof head) != VX_OK) ld_fail("cannot read the program");
  memcpy(&eh, head, sizeof eh);
  uint64_t end = eh.e_phoff + (uint64_t)eh.e_phnum * sizeof(Elf64_Phdr);
  if (eh.e_phentsize != sizeof(Elf64_Phdr) || end > sizeof head) ld_fail("the program's headers");
  *phdr = 0;
  for (uint16_t i = 0; i < eh.e_phnum; i++) {
    Elf64_Phdr ph;
    memcpy(&ph, head + eh.e_phoff + (uint64_t)i * sizeof ph, sizeof ph);
    if (ph.p_type != PT_LOAD) continue;
    if (ph.p_offset + ph.p_filesz > end) end = ph.p_offset + ph.p_filesz;
    if (eh.e_phoff >= ph.p_offset && eh.e_phoff < ph.p_offset + ph.p_filesz)
      *phdr = ph.p_vaddr + (eh.e_phoff - ph.p_offset);
  }
  uint64_t len = (end + 4095) & ~4095ull, at = 0;
  if (!*phdr || vx_as_map(vx_self, exe, 0, len, 0, &at) != VX_OK) ld_fail("cannot map the program's image");
  uint64_t e = 0;
  vx_status st = vx_elf_load(vx_self, (const uint8_t *)at, end, &e);
  vx_as_unmap(vx_self, at, len);
  if (st != VX_OK) ld_fail("cannot map the program");
  *phnum = eh.e_phnum, *entry = e;
}

// The program's stack, as large as a spawn's, a block of n words at its top:
// musl's stage 3 enters the program with its stack pointer at the block
// (CRTJMP), so the block may not be static storage, which the stack would
// grow down over. The spawn's stack, which the linker ran on, is left.
static size_t *ld_stack(const uintptr_t *block, size_t n) {
  constexpr uint64_t size = 256ull * 1024; // spawn.c's VX_STACK_SIZE
  vx_handle vmo = VX_HANDLE_NONE;
  uint64_t at = 0;
  if (vx_vmo_create(size, VX_VMO_LAZY, &vmo) != VX_OK ||
      vx_as_map(vx_self, vmo, 0, size, VX_MAP_WRITE, &at) != VX_OK)
    ld_fail("no room for the program's stack");
  vx_handle_close(vmo);
  size_t *top = (size_t *)((at + size - n * sizeof *top) & ~(uint64_t)15);
  memcpy(top, block, n * sizeof *top);
  return top;
}

// At the start of __dls2b, libc.so relocated: the back end, the program, and
// the stack musl's stage 3 starts it with.
void __vx_dls2b_hook(size_t **sp, size_t **auxv) __attribute__((visibility("hidden")));
void __vx_dls2b_hook(size_t **sp, size_t **auxv) {
  vx_read_spawn(ld_bootstrap);
  vx_handle exe = vx_spawn_take("dl.exe");
  if (!exe) ld_fail("no program to load (dl.exe)");
  uintptr_t phdr, entry;
  size_t phnum;
  ld_map_program(exe, &phdr, &phnum, &entry);
  vx_handle_close(exe);
  uintptr_t *aux;
  uintptr_t *w = proc_start_block(VX_HANDLE_NONE, phdr, phnum, entry, (uintptr_t)vx_ld_ehdr, &aux);
  size_t at_aux = (size_t)(aux - w);
  *sp = ld_stack(w, at_aux + 2 * PROC_AUX);
  *auxv = *sp + at_aux;
}
