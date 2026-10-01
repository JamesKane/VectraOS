// paging.c: the kernel's page tables (docs/01 §5). Both architectures use a
// 4 KiB granule and four levels for 48-bit virtual addresses: level 0 is the
// top, level 3 holds 4 KiB pages, and levels 1 and 2 may hold 1 GiB and 2 MiB
// leaves. The entry format is the architecture's (arch_pte_*).

enum map_flags : uint32_t {   // a mapping is always readable
    MAP_WRITE  = 1,
    MAP_EXEC   = 2,
    MAP_USER   = 4,
    MAP_DEVICE = 8,           // uncached device memory
};

static uint64_t kernel_root;   // physical address of the kernel's top-level table

static uint64_t *table_at(uint64_t pa) { return phys_to_virt(pa); }

// Pages for new tables: from the early allocator until phys_init has run.
static uint64_t table_page(void) {
    return phys.frame_state ? phys_alloc_zeroed(0) : early_alloc(1);
}

// Maps [va, va + size) to [pa, pa + size), with the largest leaves that
// alignment allows. Fails without undoing anything if a table cannot be
// allocated or the range is already mapped; callers treat that as fatal.
static bool map_range(uint64_t root, uint64_t va, uint64_t pa, uint64_t size, uint32_t flags) {
    while (size) {
        int level = 3;
        uint64_t step = 4096;
        if (!((va | pa) & ((1ull << 30) - 1)) && size >= 1ull << 30) { level = 1; step = 1ull << 30; }
        else if (!((va | pa) & ((1ull << 21) - 1)) && size >= 1ull << 21) { level = 2; step = 1ull << 21; }

        uint64_t *t = table_at(root);
        for (int l = 0; l < level; l++) {
            unsigned idx = (va >> (39 - 9 * l)) & 511;
            if (!arch_pte_valid(t[idx])) {
                uint64_t page = table_page();
                if (!page) return false;
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
    return true;
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
//  - the direct map: RAM, firmware tables and runtime services, read-write and
//    never executable, merged across adjacent regions so large leaves fit;
//  - the architecture's device pages (arch_kernel_mappings);
//  - nothing in the lower half, so null pointers fault.
static void paging_init(void) {
    kernel_root = phys_alloc_zeroed(0);
    if (!kernel_root) panic(VX_STR("no memory for page tables"));

    map_image_part(vx_text_start, vx_text_end, MAP_EXEC);
    map_image_part(vx_rodata_start, vx_rodata_end, 0);
    map_image_part(vx_data_start, vx_data_end, MAP_WRITE);
    map_image_part(vx_boot_stack_bottom, vx_boot_stack_top, MAP_WRITE);   // the page below stays unmapped

    struct limine_memmap_response *mm = memmap_request.response;
    uint64_t run_lo = 0, run_hi = 0;
    for (uint64_t i = 0; i <= mm->entry_count; i++) {
        uint64_t lo = 0, hi = 0;
        if (i < mm->entry_count) {
            struct limine_memmap_entry *e = mm->entries[i];
            switch (e->type) {
            case LIMINE_MEMMAP_USABLE:
            case LIMINE_MEMMAP_BOOTLOADER_RECLAIMABLE:
            case LIMINE_MEMMAP_EXECUTABLE_AND_MODULES:
            case LIMINE_MEMMAP_ACPI_RECLAIMABLE:
            case LIMINE_MEMMAP_ACPI_NVS:
            case LIMINE_MEMMAP_RESERVED_MAPPED:
                lo = e->base & ~4095ull;
                hi = page_up(e->base + e->length);
                break;
            default:
                continue;
            }
            if (run_hi && lo <= run_hi) {   // the map is sorted: extend the run
                if (hi > run_hi) run_hi = hi;
                continue;
            }
        }
        if (run_hi && !map_range(kernel_root, boot.hhdm + run_lo, run_lo, run_hi - run_lo, MAP_WRITE))
            panic(VX_STR("cannot build the direct map"));
        run_lo = lo;
        run_hi = hi;
    }

    arch_kernel_mappings(kernel_root);
    arch_switch_tables(kernel_root);
}
