// kstack.c: kernel stacks, with a guard page below each (docs/01 §11).
//
// Every kernel stack (a thread's, a CPU's idle stack, and CPU 0's once it
// leaves the boot stack) is 16 KiB at the top of a 32 KiB slot in a region of
// its own, with the slot's lower half never mapped. An overflow faults instead
// of writing over the next object. On aarch64 the slot layout is also what
// lets the exception vectors notice an overflow before they push a frame: a
// valid stack pointer has bit 14 set, and one that has run into the guard has
// it clear (vectors.S).
//
// A slot's pages stay mapped when its stack is freed, for the next stack to
// use: unmapping kernel pages would need every CPU to drop their cached
// translations. So the region's memory is the most stacks ever live at once.

static constexpr uint64_t KSTACK_BASE = 0xffff'ff00'0000'0000; // top-level slot 510 on both architectures
static constexpr uint64_t KSTACK_SIZE = 16ull * 1024, KSTACK_SLOT = 32ull * 1024;
static constexpr uint32_t KSTACK_SLOTS = 8192; // 256 MiB of address space
static_assert(KSTACK_SIZE == 1u << 14 && KSTACK_SLOT == 2 * KSTACK_SIZE);

static struct {
  spinlock lock;
  uint64_t free[KSTACK_SLOTS / 64];   // bit i: slot i holds a stack nobody uses
  uint64_t mapped[KSTACK_SLOTS / 64]; // bit i: slot i's pages are mapped
  uint32_t next;                      // slots below this have been used
} kstacks;

static bool kstack_bit(const uint64_t *bits, uint32_t i) { return bits[i / 64] >> (i % 64) & 1; }
static void kstack_set(uint64_t *bits, uint32_t i, bool on) {
  bits[i / 64] = on ? bits[i / 64] | 1ull << (i % 64) : bits[i / 64] & ~(1ull << (i % 64));
}

// Whether addr is in some slot's guard: below a stack, never mapped.
static bool kstack_in_guard(uint64_t addr) {
  return addr >= KSTACK_BASE && addr < KSTACK_BASE + (uint64_t)KSTACK_SLOTS * KSTACK_SLOT &&
         (addr - KSTACK_BASE) % KSTACK_SLOT < KSTACK_SLOT - KSTACK_SIZE;
}

// A stack: the address of its lowest byte (its top is that plus KSTACK_SIZE),
// or 0 when there is no memory or no slot left.
static uint64_t kstack_alloc(void) {
  spin_lock(&kstacks.lock);
  uint32_t slot = KSTACK_SLOTS;
  for (uint32_t w = 0; w < KSTACK_SLOTS / 64 && slot == KSTACK_SLOTS; w++)
    if (kstacks.free[w]) slot = w * 64 + (uint32_t)__builtin_ctzll(kstacks.free[w]);
  if (slot == KSTACK_SLOTS && kstacks.next < KSTACK_SLOTS) slot = kstacks.next++;
  if (slot == KSTACK_SLOTS) {
    spin_unlock(&kstacks.lock);
    return 0;
  }
  kstack_set(kstacks.free, slot, false);
  uint64_t base = KSTACK_BASE + (uint64_t)slot * KSTACK_SLOT + (KSTACK_SLOT - KSTACK_SIZE);
  if (!kstack_bit(kstacks.mapped, slot)) {
    uint64_t pa = phys_alloc_zeroed(2); // 16 KiB
    if (!pa || !map_range(kernel_root, base, pa, KSTACK_SIZE, MAP_WRITE)) {
      if (pa) phys_free(pa, 2);
      kstack_set(kstacks.free, slot, true);
      spin_unlock(&kstacks.lock);
      return 0;
    }
    kstack_set(kstacks.mapped, slot, true);
  }
  spin_unlock(&kstacks.lock);
  return base;
}

static void kstack_free(uint64_t base) {
  uint32_t slot = (uint32_t)((base - KSTACK_BASE) / KSTACK_SLOT);
  spin_lock(&kstacks.lock);
  kstack_set(kstacks.free, slot, true);
  spin_unlock(&kstacks.lock);
}

// Makes the region's top-level entry before any user address space copies the
// kernel half (x86_64 does, at task creation): a stack mapped later is then
// in every address space.
static void kstack_init(void) {
  uint64_t first = kstack_alloc();
  if (!first) panic(VX_STR("no memory for the first kernel stack"));
  kstack_free(first);
}
