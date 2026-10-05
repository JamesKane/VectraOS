// phys.c: the physical page allocator (docs/01 §5). A buddy allocator over the
// memory map, in blocks of 2^order pages, order 0 (4 KiB) to PHYS_MAX_ORDER
// (4 MiB). One zone, one lock and no per-CPU caches yet: the dma32 and
// contiguous zones, NUMA nodes and per-CPU caches come when measurements ask.

static constexpr unsigned PHYS_MAX_ORDER = 10;
// frame_state: the first frame of a free block has this bit, and its order in the low bits.
static constexpr uint8_t FRAME_FREE_HEAD = 0x80;

typedef struct free_block { // lives in the free memory itself, through the direct map
  struct free_block *next, *prev;
} free_block;

static struct {
  spinlock lock;
  free_block *lists[PHYS_MAX_ORDER + 1];
  uint8_t *frame_state; // one byte per 4 KiB frame below `frames`
  uint64_t frames;
  uint64_t free_pages;
} phys;

static void list_push(unsigned order, uint64_t pa) {
  free_block *b = phys_to_virt(pa);
  *b = (free_block){.next = phys.lists[order]};
  if (b->next) b->next->prev = b;
  phys.lists[order] = b;
}

static void list_remove(unsigned order, uint64_t pa) {
  free_block *b = phys_to_virt(pa);
  if (b->prev)
    b->prev->next = b->next;
  else
    phys.lists[order] = b->next;
  if (b->next) b->next->prev = b->prev;
}

static void phys_free(uint64_t pa, unsigned order) {
  spin_lock(&phys.lock);
  phys.free_pages += 1ull << order;
  uint64_t frame = pa >> 12;
  while (order < PHYS_MAX_ORDER) {
    uint64_t buddy = frame ^ (1ull << order);
    if (buddy + (1ull << order) > phys.frames || phys.frame_state[buddy] != (FRAME_FREE_HEAD | order)) break;
    list_remove(order, buddy << 12);
    phys.frame_state[buddy] = 0;
    frame &= ~(1ull << order);
    order++;
  }
  phys.frame_state[frame] = FRAME_FREE_HEAD | (uint8_t)order;
  list_push(order, frame << 12);
  spin_unlock(&phys.lock);
}

// Returns the physical address of 2^order free pages, or 0 if there are none.
static uint64_t phys_alloc(unsigned order) {
  spin_lock(&phys.lock);
  unsigned k = order;
  while (k <= PHYS_MAX_ORDER && !phys.lists[k]) k++;
  if (k > PHYS_MAX_ORDER) {
    spin_unlock(&phys.lock);
    return 0;
  }
  uint64_t pa = (uint64_t)phys.lists[k] - boot.hhdm;
  list_remove(k, pa);
  phys.frame_state[pa >> 12] = 0;
  while (k > order) { // return the upper halves
    k--;
    uint64_t upper = pa + (4096ull << k);
    phys.frame_state[upper >> 12] = FRAME_FREE_HEAD | (uint8_t)k;
    list_push(k, upper);
  }
  phys.free_pages -= 1ull << order;
  spin_unlock(&phys.lock);
  return pa;
}

static uint64_t phys_alloc_zeroed(unsigned order) {
  uint64_t pa = phys_alloc(order);
  if (pa) arch_page_zero(phys_to_virt(pa), 4096ull << order);
  return pa;
}

// Frees [start, end) in the largest aligned blocks that fit. Frame 0 is never
// added: 0 is phys_alloc's "no memory", and Limine may report page 0 as usable.
static void phys_add_range(uint64_t start, uint64_t end) {
  if (start == 0) start = 4096;
  while (start < end) {
    unsigned order = PHYS_MAX_ORDER;
    while (order && (((start >> 12) & ((1ull << order) - 1)) || start + (4096ull << order) > end)) order--;
    phys_free(start, order);
    start += 4096ull << order;
  }
}

// Builds the allocator from the usable memory map entries, minus what the early
// allocator has handed out (the top of the largest usable region), and closes
// the early allocator. Memory Limine itself used (bootloader-reclaimable) is
// added only after SMP bring-up: the parked CPUs wait on structures inside it.
static void phys_init(void) {
  struct limine_memmap_response *mm = memmap_request.response;
  uint64_t top = 0;
  for (uint64_t i = 0; i < mm->entry_count; i++) {
    struct limine_memmap_entry *e = mm->entries[i];
    if (e->type == LIMINE_MEMMAP_USABLE || e->type == LIMINE_MEMMAP_BOOTLOADER_RECLAIMABLE)
      if (e->base + e->length > top) top = e->base + e->length;
  }
  phys.frames = top >> 12;
  uint64_t state_pa = early_alloc((phys.frames + 4095) / 4096);
  if (!state_pa) panic(VX_STR("no memory for the page allocator"));
  phys.frame_state = phys_to_virt(state_pa);

  uint64_t taken_lo = early_next, taken_hi = early_top;
  early_limit = early_next; // the early allocator is closed from here on
  for (uint64_t i = 0; i < mm->entry_count; i++) {
    struct limine_memmap_entry *e = mm->entries[i];
    if (e->type != LIMINE_MEMMAP_USABLE) continue;
    uint64_t lo = e->base, hi = e->base + e->length;
    if (taken_lo >= lo && taken_hi <= hi) {
      phys_add_range(lo, taken_lo);
      phys_add_range(taken_hi, hi);
    } else {
      phys_add_range(lo, hi);
    }
  }
}
