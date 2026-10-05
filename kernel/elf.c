// elf.c: loads the root task's ELF image from its boot module (docs/04 §5, M1).
// Static, non-PIE executables only; every other program is loaded from user
// space by libvxrt (01 §9).

typedef struct elf64_header {
  uint8_t ident[16];
  uint16_t type, machine;
  uint32_t version;
  uint64_t entry, phoff, shoff;
  uint32_t flags;
  uint16_t ehsize, phentsize, phnum, shentsize, shnum, shstrndx;
} elf64_header;

typedef struct elf64_phdr {
  uint32_t type, flags;
  uint64_t offset, vaddr, paddr, filesz, memsz, align;
} elf64_phdr;

static constexpr uint32_t PT_LOAD = 1, PF_X = 1, PF_W = 2;

#ifdef __x86_64__
static constexpr uint16_t ELF_MACHINE = 62; // EM_X86_64
#else
static constexpr uint16_t ELF_MACHINE = 183; // EM_AARCH64
#endif

static vx_status elf_load(task *t, const uint8_t *image, uint64_t size, uint64_t *entry) {
  const elf64_header *eh = (const elf64_header *)image;
  uint64_t table_end;
  if (size < sizeof *eh ||
      memcmp(eh->ident,
             "\x7f"
             "ELF",
             4) != 0 ||
      eh->ident[4] != 2 || eh->ident[5] != 1 || eh->type != 2 || eh->machine != ELF_MACHINE ||
      eh->phentsize != sizeof(elf64_phdr) || ckd_mul(&table_end, (uint64_t)eh->phnum, sizeof(elf64_phdr)) ||
      ckd_add(&table_end, table_end, eh->phoff) || table_end > size)
    return VX_ERR_INVALID;

  const elf64_phdr *ph = (const elf64_phdr *)(image + eh->phoff);
  for (uint16_t i = 0; i < eh->phnum; i++) {
    if (ph[i].type != PT_LOAD || ph[i].memsz == 0) continue;
    uint64_t file_end, mem_end;
    if (ph[i].filesz > ph[i].memsz || ckd_add(&file_end, ph[i].offset, ph[i].filesz) || file_end > size ||
        ckd_add(&mem_end, ph[i].vaddr, ph[i].memsz) || mem_end > USER_TOP ||
        (ph[i].flags & PF_W && ph[i].flags & PF_X))
      return VX_ERR_INVALID;
    uint64_t base = ph[i].vaddr & ~4095ull;
    vmo *v;
    vx_status st = vmo_create(mem_end - base, &v);
    if (st != VX_OK) return st;
    vmo_write(v, ph[i].vaddr - base, image + ph[i].offset, ph[i].filesz);
    uint64_t va = base;
    uint32_t mf = (ph[i].flags & PF_W ? VX_MAP_WRITE : 0) | (ph[i].flags & PF_X ? VX_MAP_EXEC : 0);
    st = task_map(t, v, 0, v->size, mf, mf, &va); // the kernel's own mapping: what the image asks, no more
    object_release(&v->obj);                      // the mapping keeps it
    if (st != VX_OK) return st;
  }
  *entry = eh->entry;
  return VX_OK;
}
