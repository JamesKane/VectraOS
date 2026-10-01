// boot.c: the Limine boot protocol (docs/01 §10, ADR-0002). The kernel asks for
// what it needs with request structures in its image. Limine finds them between
// the start and end markers and fills in their responses before entering _start.

#include <limine.h>

#define LIMINE_REQUEST [[gnu::used, gnu::section(".limine_requests")]] static volatile

[[gnu::used, gnu::section(".limine_requests_start")]]
static volatile uint64_t limine_requests_start[] = LIMINE_REQUESTS_START_MARKER;

LIMINE_REQUEST uint64_t limine_base_revision[] = LIMINE_BASE_REVISION(6);
LIMINE_REQUEST struct limine_hhdm_request    hhdm_request    = { .id = LIMINE_HHDM_REQUEST_ID };
LIMINE_REQUEST struct limine_memmap_request  memmap_request  = { .id = LIMINE_MEMMAP_REQUEST_ID };
#if defined(__x86_64__)
LIMINE_REQUEST struct limine_mp_request      mp_request      = { .id = LIMINE_MP_REQUEST_ID, .flags = LIMINE_MP_REQUEST_X86_64_X2APIC };
LIMINE_REQUEST struct limine_tsc_frequency_request tsc_request = { .id = LIMINE_TSC_FREQUENCY_REQUEST_ID };
#else
LIMINE_REQUEST struct limine_mp_request      mp_request      = { .id = LIMINE_MP_REQUEST_ID };
#endif
LIMINE_REQUEST struct limine_entropy_request entropy_request = { .id = LIMINE_ENTROPY_REQUEST_ID, .value_count = 1 };
LIMINE_REQUEST struct limine_executable_cmdline_request cmdline_request = { .id = LIMINE_EXECUTABLE_CMDLINE_REQUEST_ID };
LIMINE_REQUEST struct limine_executable_address_request address_request = { .id = LIMINE_EXECUTABLE_ADDRESS_REQUEST_ID };

[[gnu::used, gnu::section(".limine_requests_end")]]
static volatile uint64_t limine_requests_end[] = LIMINE_REQUESTS_END_MARKER;

typedef struct boot_info {
    uint64_t hhdm;           // virtual address = physical address + hhdm
    uint64_t usable_bytes;
    uint64_t cpu_count;
    vx_str   cmdline;        // from limine.conf; empty if there is none
    uint64_t kernel_phys;    // where the kernel image is loaded, physically contiguous
    uint64_t kernel_virt;
} boot_info;

static boot_info boot;

static void *phys_to_virt(uint64_t pa) { return (void *)(pa + boot.hhdm); }

// Early pages, before the physical allocator exists: taken from the top of the
// largest usable region, downwards, and never returned. phys_init hands the
// allocator that region minus [early_next, early_top), then closes this one by
// setting early_limit to early_next.
static uint64_t early_next, early_limit, early_top;

// Returns the physical address of `pages` zeroed, contiguous 4 KiB pages, or 0.
static uint64_t early_alloc(uint64_t pages) {
    if (early_next == 0 || early_next - early_limit < pages * 4096) return 0;
    early_next -= pages * 4096;
    uint64_t *p = phys_to_virt(early_next);
    for (uint64_t i = 0; i < pages * 512; i++) p[i] = 0;
    return early_next;
}

// Reads the responses. Returns false if Limine does not speak base revision 6.
// It changes the stack-protector guard, so neither it nor its caller may have a
// canary of their own.
[[clang::no_stack_protector]] static bool boot_read(void) {
    if (!LIMINE_BASE_REVISION_SUPPORTED(limine_base_revision)) return false;
    if (!hhdm_request.response || !memmap_request.response || !address_request.response) return false;
    boot.hhdm        = hhdm_request.response->offset;
    boot.kernel_phys = address_request.response->physical_base;
    boot.kernel_virt = address_request.response->virtual_base;

    struct limine_memmap_response *mm = memmap_request.response;
    uint64_t largest = 0;
    for (uint64_t i = 0; i < mm->entry_count; i++) {
        struct limine_memmap_entry *e = mm->entries[i];
        if (e->type != LIMINE_MEMMAP_USABLE) continue;
        boot.usable_bytes += e->length;
        if (e->length > largest) {
            largest     = e->length;
            early_limit = e->base;
            early_next  = e->base + e->length;
            early_top   = early_next;
        }
    }

    boot.cpu_count = mp_request.response ? mp_request.response->cpu_count : 1;

    if (cmdline_request.response && cmdline_request.response->cmdline) {
        const char *c = cmdline_request.response->cmdline;
        size_t n = 0;
        while (c[n]) n++;
        boot.cmdline = (vx_str){ c, n };
    }

    struct limine_entropy_response *entropy = entropy_request.response;
    if (entropy && entropy->value_count >= 1) __stack_chk_guard = entropy->values[0];
    return true;
}
