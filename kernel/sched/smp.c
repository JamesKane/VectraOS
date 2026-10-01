// smp.c: bringing up the other CPUs, and the memory the bootloader used for
// itself (docs/01 §10).
//
// Limine parks every application processor (AP) and starts one when its
// goto_address is written. Each AP gets an idle stack from the page allocator,
// with its CPU index stored at the top; ap_start (the architecture's entry)
// moves onto that stack and calls ap_main, which loads the kernel's page
// tables and vectors, starts the CPU's timer and enters its idle loop.

static _Atomic bool smp_test_go;
static _Atomic uint32_t smp_test_done;
static constexpr uint32_t SMP_TEST_ROUNDS = 4000;

// Every CPU allocates and frees blocks of orders 0 to 3, stamping each one with
// its CPU and round and checking the stamp before freeing it: a block handed to
// two CPUs at once would show up as a wrong stamp.
static void smp_stress(uint32_t index) {
  uint64_t held[8] = {}, tags[8] = {};
  unsigned orders[8] = {};
  for (uint32_t r = 0; r < SMP_TEST_ROUNDS; r++) {
    unsigned slot = r % 8, order = r % 4;
    if (held[slot]) {
      volatile uint64_t *p = phys_to_virt(held[slot]);
      volatile uint64_t *last =
          (volatile uint64_t *)((uint8_t *)phys_to_virt(held[slot]) + (4096ull << orders[slot]) - 8);
      if (*p != tags[slot] || *last != tags[slot])
        panic(VX_STR("selftest smp: a block was handed out twice"));
      phys_free(held[slot], orders[slot]);
    }
    held[slot] = phys_alloc(order);
    if (!held[slot]) panic(VX_STR("selftest smp: out of memory"));
    orders[slot] = order;
    tags[slot] = (uint64_t)index << 32 | r;
    volatile uint64_t *p = phys_to_virt(held[slot]);
    volatile uint64_t *last =
        (volatile uint64_t *)((uint8_t *)phys_to_virt(held[slot]) + (4096ull << order) - 8);
    *p = tags[slot];
    *last = tags[slot];
  }
  for (unsigned slot = 0; slot < 8; slot++)
    if (held[slot]) phys_free(held[slot], orders[slot]);
}

static bool selftest_smp_enabled(void) { return cmdline_has(VX_STR("vx.selftest=smp")); }

[[noreturn]] void ap_main(uint32_t index) {
  arch_switch_tables(kernel_root);
  arch_cpu_init(index);
  arch_timer_init();
  sched_enter_cpu();
  atomic_fetch_add_explicit(&cpus_online, 1, memory_order_release);
  if (selftest_smp_enabled()) {
    while (!atomic_load_explicit(&smp_test_go, memory_order_acquire)) arch_pause();
    smp_stress(index);
    atomic_fetch_add_explicit(&smp_test_done, 1, memory_order_release);
  }
  sched_idle_loop();
}

static constexpr unsigned AP_STACK_ORDER = 2; // 16 KiB idle stacks

// Starts every AP and waits up to a second for all of them to reach their idle loop.
static void smp_init(void) {
  struct limine_mp_response *mp = mp_request.response;
  cpu_total = 1;
  atomic_store(&cpus_online, 1);
  if (!mp) return;
#ifdef __x86_64__
  uint64_t bsp_id = mp->bsp_lapic_id;
#else
  uint64_t bsp_id = mp->bsp_mpidr;
#endif
  cpus[0].arch_id = bsp_id;
  uint32_t parked = 0;
  for (uint64_t i = 0; i < mp->cpu_count; i++) {
    struct limine_mp_info *info = mp->cpus[i];
#ifdef __x86_64__
    uint64_t id = info->lapic_id;
#else
    uint64_t id = info->mpidr;
#endif
    if (id == bsp_id) continue;
    if (cpu_total == MAX_CPUS) { // the rest halt for good, on the kernel's tables (ap_park)
      if (!parked++) kput(VX_STR("vx: more CPUs than MAX_CPUS; the rest are halted\n"));
      __atomic_store_n(&info->goto_address, ap_park, __ATOMIC_RELEASE);
      continue;
    }
    uint32_t index = cpu_total++;
    uint64_t stack = phys_alloc_zeroed(AP_STACK_ORDER);
    if (!stack) panic(VX_STR("no memory for an idle stack"));
    cpus[index].index = index;
    cpus[index].arch_id = id;
    cpus[index].idle_stack = (uint64_t)phys_to_virt(stack);
    uint64_t *top = (uint64_t *)(cpus[index].idle_stack + (4096ull << AP_STACK_ORDER));
    top[-1] = index;
    info->extra_argument = (uint64_t)(top - 2); // ap_start: sp = this, and its index just above
    __atomic_store_n(&info->goto_address, ap_start, __ATOMIC_RELEASE);
  }
  vx_instant give_up = clock_now() + 1'000'000'000;
  while (atomic_load_explicit(&cpus_online, memory_order_acquire) < cpu_total && clock_now() < give_up)
    arch_pause();
  if (atomic_load(&cpus_online) < cpu_total) panic(VX_STR("a CPU did not come online"));
}

// Runs the CPUs' allocator stress together (vx.selftest=smp), then checks that
// the free count is what it was.
static void selftest_smp(void) {
  uint64_t before = phys.free_pages;
  atomic_store_explicit(&smp_test_go, true, memory_order_release);
  smp_stress(0);
  while (atomic_load_explicit(&smp_test_done, memory_order_acquire) < cpu_total - 1) arch_pause();
  if (phys.free_pages != before) panic(VX_STR("selftest smp: the free count does not balance"));
  kput(VX_STR("vx: selftest smp ok: "));
  kput_u64(cpu_total);
  kput(VX_STR(" cpus, "));
  kput_u64((uint64_t)cpu_total * SMP_TEST_ROUNDS);
  kput(VX_STR(" allocations\n"));
}

// Hands the memory Limine used for itself to the page allocator: its page
// tables, the APs' first stacks, and the responses to the kernel's requests.
// Call it only when every CPU runs on the kernel's own tables and stacks, and
// nothing reads a response any more. The ranges are copied out first, because
// the memory map itself lives in that memory.
static void reclaim_boot_memory(void) {
  struct limine_memmap_response *mm = memmap_request.response;
  uint64_t ranges[64][2];
  uint32_t n = 0;
  for (uint64_t i = 0; i < mm->entry_count && n < 64; i++) {
    if (mm->entries[i]->type != LIMINE_MEMMAP_BOOTLOADER_RECLAIMABLE) continue;
    ranges[n][0] = mm->entries[i]->base;
    ranges[n][1] = mm->entries[i]->base + mm->entries[i]->length;
    n++;
  }
  for (uint32_t i = 0; i < n; i++) phys_add_range(ranges[i][0], ranges[i][1]);
}
