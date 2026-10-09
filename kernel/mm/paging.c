// paging.c: the kernel's page tables (docs/01 §5). Both architectures use a
// 4 KiB granule and four levels for 48-bit virtual addresses: level 0 is the
// top, level 3 holds 4 KiB pages, and levels 1 and 2 may hold 1 GiB and 2 MiB
// leaves. The entry format is the architecture's (arch_pte_*).

enum map_flags : uint32_t { // a mapping is always readable
  MAP_WRITE = 1,
  MAP_EXEC = 2,
  MAP_USER = 4,
  MAP_DEVICE = 8,       // uncached device memory
  MAP_WC = 16,          // write-combining device memory (ADR-0051): a framebuffer
  MAP_KEY_MASK = 0xf00, // the page's protection key, as VX_MAP_KEY puts it (ADR-0035; x86's PKU)
};

static uint64_t kernel_root; // physical address of the kernel's top-level table

static uint64_t *table_at(uint64_t pa) { return phys_to_virt(pa); }

// Pages for new tables: from the early allocator until phys_init has run.
static uint64_t table_page(void) { return phys.frame_state ? phys_alloc_zeroed(0) : early_alloc(1); }

// Maps [va, va + size) to [pa, pa + size), with the largest leaves that
// alignment allows. Fails without undoing anything if a table cannot be
// allocated or the range is already mapped; callers treat that as fatal.
static bool map_range(uint64_t root, uint64_t va, uint64_t pa, uint64_t size, uint32_t flags) {
  while (size) {
    int level = 3;
    uint64_t step = 4096;
    if (!((va | pa) & ((1ull << 30) - 1)) && size >= 1ull << 30) {
      level = 1;
      step = 1ull << 30;
    } else if (!((va | pa) & ((1ull << 21) - 1)) && size >= 1ull << 21) {
      level = 2;
      step = 1ull << 21;
    }

    uint64_t *t = table_at(root);
    for (int l = 0; l < level; l++) {
      unsigned idx = (va >> (39 - 9 * l)) & 511;
      if (!arch_pte_valid(t[idx])) {
        uint64_t page = table_page();
        if (!page) return false;
        arch_pte_publish(); // the new table's zeroes, before the entry that leads to it
        t[idx] = arch_pte_table(page);
      } else if (!arch_pte_is_table(t[idx], l)) {
        return false;
      }
      t = table_at(arch_pte_addr(t[idx]));
    }
    unsigned idx = (va >> (39 - 9 * level)) & 511;
    if (arch_pte_valid(t[idx])) return false;
    t[idx] = arch_pte_leaf(pa, flags, level);
    va += step;
    pa += step;
    size -= step;
  }
  arch_pte_publish();
  return true;
}

// The leaf entry mapping va in root, or nullptr if there is none.
static uint64_t *leaf_entry(uint64_t root, uint64_t va, int *level_out) {
  uint64_t *t = table_at(root);
  for (int level = 0; level <= 3; level++) {
    uint64_t *e = &t[(va >> (39 - 9 * level)) & 511];
    if (!arch_pte_valid(*e)) return nullptr;
    if (!arch_pte_is_table(*e, level)) {
      *level_out = level;
      return e;
    }
    t = table_at(arch_pte_addr(*e));
  }
  return nullptr;
}

// The physical address behind user address va in root, or 0 if it is not
// mapped for user access. Futexes are keyed on it.
static uint64_t user_page_pa(uint64_t root, uint64_t va) {
  int level;
  uint64_t *e = leaf_entry(root, va, &level);
  if (!e || !arch_pte_user_ok(*e, false)) return 0;
  uint64_t page = 1ull << (39 - 9 * level);
  return arch_pte_addr(*e) + (va & (page - 1));
}

// Removes the 4 KiB mapping at va, if there is one, and drops it from this
// CPU's TLB. (Other CPUs need a shootdown once as_unmap exists; until then this
// only undoes mappings no thread has used yet, or tears down a dead task.)
// Clears a page's entry. Its translation may still be cached on any CPU that
// has the tables loaded: the caller shoots it down (arch_tlb_shootdown), with
// no lock held, before the page can be freed.
static void unmap_page(uint64_t root, uint64_t va) {
  int level;
  uint64_t *e = leaf_entry(root, va, &level);
  if (!e || level != 3) return;
  *e = 0;
}

// Frees the user half's page tables and the top table itself. The leaves are
// VMO pages, which their VMOs free. No CPU may be using the address space.
// Three nested loops rather than recursion (04 §1.1).
static void free_user_tables(uint64_t root) {
  uint64_t *top = table_at(root);
  for (uint32_t i = 0; i < arch_user_top_slots(); i++) {
    if (!arch_pte_valid(top[i]) || !arch_pte_is_table(top[i], 0)) continue;
    uint64_t *l1 = table_at(arch_pte_addr(top[i]));
    for (uint32_t j = 0; j < 512; j++) {
      if (!arch_pte_valid(l1[j]) || !arch_pte_is_table(l1[j], 1)) continue;
      uint64_t *l2 = table_at(arch_pte_addr(l1[j]));
      for (uint32_t k = 0; k < 512; k++)
        if (arch_pte_valid(l2[k]) && arch_pte_is_table(l2[k], 2)) phys_free(arch_pte_addr(l2[k]), 0);
      phys_free(arch_pte_addr(l1[j]), 0);
    }
    phys_free(arch_pte_addr(top[i]), 0);
  }
  phys_free(root, 0);
}

// True if va is mapped in root for user access, and writable if asked.
static bool user_page_ok(uint64_t root, uint64_t va, bool write) {
  uint64_t *t = table_at(root);
  for (int level = 0; level <= 3; level++) {
    uint64_t e = t[(va >> (39 - 9 * level)) & 511];
    if (!arch_pte_valid(e)) return false;
    if (!arch_pte_is_table(e, level)) return arch_pte_user_ok(e, write);
    t = table_at(arch_pte_addr(e));
  }
  return false;
}

// Section bounds from the linker script.
extern const uint8_t vx_text_start[], vx_text_end[], vx_rodata_start[], vx_rodata_end[];
extern const uint8_t vx_data_start[], vx_data_end[], vx_boot_stack_bottom[], vx_boot_stack_top[];

static uint64_t page_up(uint64_t v) { return (v + 4095) & ~4095ull; }

static void map_image_part(const uint8_t *start, const uint8_t *end, uint32_t flags) {
  uint64_t va = (uint64_t)start, size = page_up((uint64_t)end) - va;
  if (!map_range(kernel_root, va, va - boot.kernel_virt + boot.kernel_phys, size, flags))
    panic(VX_STR("cannot map the kernel image"));
}

// Builds the kernel's own page tables and switches to them:
//  - the kernel image, each part with its own permissions (W^X);
//  - the direct map: RAM, firmware tables and runtime services, never
//    executable, read-write but for the kernel image and the modules;
//  - the architecture's device pages (arch_kernel_mappings);
//  - nothing in the lower half, so null pointers fault.
static void paging_init(void) {
  kernel_root = phys_alloc_zeroed(0);
  if (!kernel_root) panic(VX_STR("no memory for page tables"));

  map_image_part(vx_text_start, vx_text_end, MAP_EXEC);
  map_image_part(vx_rodata_start, vx_rodata_end, 0);
  map_image_part(vx_data_start, vx_data_end, MAP_WRITE);
  map_image_part(vx_boot_stack_bottom, vx_boot_stack_top, MAP_WRITE); // the page below stays unmapped

  // Runs of adjacent regions with the same permissions merge, so large leaves
  // fit. The kernel image and the boot modules are read-only here: the image
  // is written only through its own mapping, and only where it may be (W^X).
  struct limine_memmap_response *mm = memmap_request.response;
  uint64_t run_lo = 0, run_hi = 0;
  uint32_t run_flags = 0;
  for (uint64_t i = 0; i <= mm->entry_count; i++) {
    uint64_t lo = 0, hi = 0;
    uint32_t flags = MAP_WRITE;
    if (i < mm->entry_count) {
      struct limine_memmap_entry *e = mm->entries[i];
      switch (e->type) {
      case LIMINE_MEMMAP_EXECUTABLE_AND_MODULES: flags = 0; [[fallthrough]];
      case LIMINE_MEMMAP_USABLE:
      case LIMINE_MEMMAP_BOOTLOADER_RECLAIMABLE:
      case LIMINE_MEMMAP_ACPI_RECLAIMABLE:
      case LIMINE_MEMMAP_ACPI_NVS:
      case LIMINE_MEMMAP_RESERVED_MAPPED:
        lo = e->base & ~4095ull;
        hi = page_up(e->base + e->length);
        break;
      default: continue;
      }
      if (run_hi && lo <= run_hi && flags == run_flags) { // the map is sorted: extend the run
        if (hi > run_hi) run_hi = hi;
        continue;
      }
      if (run_hi && lo < run_hi) lo = run_hi; // a page shared with the run before: that run has it
    }
    if (run_hi && !map_range(kernel_root, boot.hhdm + run_lo, run_lo, run_hi - run_lo, run_flags))
      panic(VX_STR("cannot build the direct map"));
    run_lo = lo;
    run_hi = hi;
    run_flags = flags;
  }

  arch_kernel_mappings(kernel_root);
  arch_switch_tables(kernel_root);
}
