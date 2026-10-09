// boot.c: the Limine boot protocol (docs/01 §10, ADR-0002). The kernel asks for
// what it needs with request structures in its image. Limine finds them between
// the start and end markers and fills in their responses before entering _start.

#include <limine.h>

#define LIMINE_REQUEST [[gnu::used, gnu::section(".limine_requests")]] static volatile

[[gnu::used, gnu::section(".limine_requests_start")]]
static volatile uint64_t limine_requests_start[] = LIMINE_REQUESTS_START_MARKER;

LIMINE_REQUEST uint64_t limine_base_revision[] = LIMINE_BASE_REVISION(6);
LIMINE_REQUEST struct limine_hhdm_request hhdm_request = {.id = LIMINE_HHDM_REQUEST_ID};
LIMINE_REQUEST struct limine_memmap_request memmap_request = {.id = LIMINE_MEMMAP_REQUEST_ID};
#ifdef __x86_64__
LIMINE_REQUEST struct limine_mp_request mp_request = {.id = LIMINE_MP_REQUEST_ID,
                                                      .flags = LIMINE_MP_REQUEST_X86_64_X2APIC};
LIMINE_REQUEST struct limine_tsc_frequency_request tsc_request = {.id = LIMINE_TSC_FREQUENCY_REQUEST_ID};
#else
LIMINE_REQUEST struct limine_mp_request mp_request = {.id = LIMINE_MP_REQUEST_ID};
#endif
LIMINE_REQUEST struct limine_rsdp_request rsdp_request = {.id = LIMINE_RSDP_REQUEST_ID}; // ACPI (acpi.c)
LIMINE_REQUEST struct limine_framebuffer_request framebuffer_request = {
    .id = LIMINE_FRAMEBUFFER_REQUEST_ID}; // the boot framebuffer, for user space (root.c, 7b1c)
// Five values: the stack guard's, and 32 bytes for user space (root.c).
LIMINE_REQUEST struct limine_entropy_request entropy_request = {.id = LIMINE_ENTROPY_REQUEST_ID,
                                                                .value_count = 5};
LIMINE_REQUEST struct limine_executable_cmdline_request cmdline_request = {
    .id = LIMINE_EXECUTABLE_CMDLINE_REQUEST_ID};
LIMINE_REQUEST struct limine_executable_address_request address_request = {
    .id = LIMINE_EXECUTABLE_ADDRESS_REQUEST_ID};

[[gnu::used, gnu::section(".limine_requests_end")]]
static volatile uint64_t limine_requests_end[] = LIMINE_REQUESTS_END_MARKER;

typedef struct phys_range {
  uint64_t base, end;
} phys_range;

static constexpr uint32_t MAX_RAM_RANGES = 128;

typedef struct boot_info {
  uint64_t hhdm; // virtual address = physical address + hhdm
  uint64_t usable_bytes;
  uint64_t cpu_count;
  vx_str cmdline;   // from limine.conf; empty if there is none
  uint64_t seed[4]; // the bootloader's entropy, for user space (root.c)
  bool seeded;
  uint64_t kernel_phys; // where the kernel image is loaded, physically contiguous
  uint64_t kernel_virt;
  // Every range of RAM and firmware memory, whatever it is used for: a
  // physical VMO (MMIO) may not overlap one (device.c). Kept because the
  // memory map itself is in memory reclaim_boot_memory frees.
  phys_range ram[MAX_RAM_RANGES];
  uint32_t ram_count;
  bool ram_incomplete;
  uint64_t rsdp; // the ACPI RSDP's physical address, or 0 (acpi.c)
  // The framebuffer the firmware left, which the kernel never draws on: its
  // physical address (0: none), its geometry, its pixels' channels.
  struct {
    uint64_t pa, width, height, pitch;
    uint16_t bpp;
    uint8_t red_size, red_shift, green_size, green_shift, blue_size, blue_shift;
  } fb;
} boot_info;

static boot_info boot;
static char boot_cmdline[256];

static void *phys_to_virt(uint64_t pa) { return (void *)(pa + boot.hhdm); }

// Whether [pa, pa + len) is RAM or firmware memory, which the direct map
// covers (and device memory, such as a physical VMO's, is not).
static bool in_direct_map(uint64_t pa, uint64_t len) {
  for (uint32_t i = 0; i < boot.ram_count; i++)
    if (pa >= boot.ram[i].base && pa < boot.ram[i].end && len <= boot.ram[i].end - pa) return true;
  return false;
}

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
  boot.hhdm = hhdm_request.response->offset;
  boot.kernel_phys = address_request.response->physical_base;
  boot.kernel_virt = address_request.response->virtual_base;

  struct limine_memmap_response *mm = memmap_request.response;
  uint64_t largest = 0;
  for (uint64_t i = 0; i < mm->entry_count; i++) {
    struct limine_memmap_entry *e = mm->entries[i];
    bool ram = e->type == LIMINE_MEMMAP_USABLE || e->type == LIMINE_MEMMAP_BOOTLOADER_RECLAIMABLE ||
               e->type == LIMINE_MEMMAP_EXECUTABLE_AND_MODULES || e->type == LIMINE_MEMMAP_ACPI_RECLAIMABLE ||
               e->type == LIMINE_MEMMAP_ACPI_NVS ||
               e->type == LIMINE_MEMMAP_RESERVED_MAPPED; // firmware's: ACPI tables, EFI runtime; mapped too
    if (ram && boot.ram_count < MAX_RAM_RANGES)
      boot.ram[boot.ram_count++] = (phys_range){e->base, e->base + e->length};
    else if (ram)
      boot.ram_incomplete = true; // then no physical VMO can be shown to be safe
    if (e->type != LIMINE_MEMMAP_USABLE) continue;
    boot.usable_bytes += e->length;
    if (e->length > largest) {
      largest = e->length;
      early_limit = e->base;
      early_next = e->base + e->length;
      early_top = early_next;
    }
  }

  boot.cpu_count = mp_request.response ? mp_request.response->cpu_count : 1;

  if (cmdline_request.response && cmdline_request.response->cmdline) {
    const char *c = cmdline_request.response->cmdline;
    size_t n = 0;
    while (c[n] && n < sizeof boot_cmdline) n++;
    memcpy(boot_cmdline, c, n); // the original is in memory reclaim_boot_memory frees
    boot.cmdline = (vx_str){boot_cmdline, n};
  }

  // Limine's responses are in memory reclaim_boot_memory frees, so what is
  // needed later is copied now. The RSDP's address is in the HHDM (it is
  // physical only under base revision 3).
  if (rsdp_request.response && rsdp_request.response->address)
    boot.rsdp = (uint64_t)rsdp_request.response->address - boot.hhdm;
  struct limine_framebuffer_response *fbs = framebuffer_request.response;
  if (fbs && fbs->framebuffer_count >= 1) { // the first, in the HHDM; RGB only
    const struct limine_framebuffer *f = fbs->framebuffers[0];
    if (f->memory_model == LIMINE_FRAMEBUFFER_RGB && f->bpp == 32)
      boot.fb.pa = (uint64_t)f->address - boot.hhdm, boot.fb.width = f->width, boot.fb.height = f->height,
      boot.fb.pitch = f->pitch, boot.fb.bpp = f->bpp, boot.fb.red_size = f->red_mask_size,
      boot.fb.red_shift = f->red_mask_shift, boot.fb.green_size = f->green_mask_size,
      boot.fb.green_shift = f->green_mask_shift, boot.fb.blue_size = f->blue_mask_size,
      boot.fb.blue_shift = f->blue_mask_shift;
  }

  struct limine_entropy_response *entropy = entropy_request.response;
  if (entropy && entropy->value_count >= 1) __stack_chk_guard = entropy->values[0];
  if (entropy && entropy->value_count >= 5) {
    for (int i = 0; i < 4; i++) boot.seed[i] = entropy->values[i + 1];
    boot.seeded = true;
  }
  return true;
}

// True if the kernel command line holds this word.
static bool cmdline_has(vx_str word) {
  vx_str c = boot.cmdline;
  for (size_t i = 0; i < c.len;) {
    while (i < c.len && c.ptr[i] == ' ') i++;
    size_t start = i;
    while (i < c.len && c.ptr[i] != ' ') i++;
    if (i - start == word.len && memcmp(c.ptr + start, word.ptr, word.len) == 0) return true;
  }
  return false;
}

// The value of `key=value` on the kernel command line, or an empty string.
static vx_str cmdline_value(vx_str key) {
  vx_str c = boot.cmdline;
  for (size_t i = 0; i < c.len;) {
    while (i < c.len && c.ptr[i] == ' ') i++;
    size_t start = i;
    while (i < c.len && c.ptr[i] != ' ') i++;
    if (i - start > key.len && c.ptr[start + key.len] == '=' && memcmp(c.ptr + start, key.ptr, key.len) == 0)
      return (vx_str){c.ptr + start + key.len + 1, i - start - key.len - 1};
  }
  return (vx_str){};
}
