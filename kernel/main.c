// main.c: the architecture-independent start of the kernel.

// Allocates a block of every order, checks alignment and the free count, frees
// them all and checks that the count, and the largest block, come back.
// Recurses until the kernel stack's guard page stops it (mm/kstack.c): a
// frame a level, which neither a tail call nor the optimizer can take away.
// NOLINTNEXTLINE(misc-no-recursion): the recursion is the test
[[gnu::noinline]] static uint64_t selftest_recurse(uint64_t depth) {
  volatile uint8_t frame[512];
  frame[0] = (uint8_t)depth;
  if (depth > 1u << 30) return depth; // never: the guard page is far nearer
  return selftest_recurse(depth + 1) + frame[0];
}

static void selftest_phys(void) {
  uint64_t before = phys.free_pages, taken = 0, pa[PHYS_MAX_ORDER + 1];
  for (unsigned o = 0; o <= PHYS_MAX_ORDER; o++) {
    pa[o] = phys_alloc(o);
    if (!pa[o] || (pa[o] & ((4096ull << o) - 1))) panic(VX_STR("selftest phys: bad block"));
    taken += 1ull << o;
  }
  if (phys.free_pages != before - taken) panic(VX_STR("selftest phys: free count after allocating"));
  for (unsigned o = 0; o <= PHYS_MAX_ORDER; o++) phys_free(pa[o], o);
  if (phys.free_pages != before) panic(VX_STR("selftest phys: free count after freeing"));
  uint64_t big = phys_alloc(PHYS_MAX_ORDER);
  if (!big) panic(VX_STR("selftest phys: no largest block after freeing"));
  phys_free(big, PHYS_MAX_ORDER);
  kput(VX_STR("vx: selftest phys ok\n"));
}

// Prints a duration in nanoseconds as milliseconds with three decimals.
static void kput_millis(uint64_t ns) {
  uint64_t us = ns / 1000;
  kput_u64(us / 1000);
  kput(VX_STR("."));
  kput_u64(us % 1000 / 100);
  kput_u64(us % 100 / 10);
  kput_u64(us % 10);
}

// Arms the timer 10 ms ahead and sleeps until it fires. The wake-up must never
// come early, and must come within 20 ms of the deadline even under emulation.
static void selftest_timer(void) {
  vx_instant start = clock_now(), deadline = start + 10'000'000;
  uint64_t fired = cpu_timer[0].fired;
  timer_arm(deadline);
  while (cpu_timer[0].fired == fired) arch_wait();
  vx_instant woke = clock_now();
  if (woke < deadline) panic(VX_STR("selftest timer: woke before the deadline"));
  if (woke - deadline > 20'000'000) panic(VX_STR("selftest timer: woke more than 20 ms late"));
  kput(VX_STR("vx: selftest timer ok: requested 10.000 ms, woke after "));
  kput_millis((uint64_t)(woke - start));
  kput(VX_STR(" ms\n"));
}

// Self-tests that tests/qemu scenarios ask for on the command line. The fault
// tests end in a panic, which the scenario checks.
static void selftests(void) {
  if (cmdline_has(VX_STR("vx.selftest=smp"))) selftest_smp();
  if (cmdline_has(VX_STR("vx.selftest=timer"))) selftest_timer();
  if (cmdline_has(VX_STR("vx.selftest=phys"))) selftest_phys();
  if (cmdline_has(VX_STR("vx.selftest=stack-overflow"))) selftest_recurse(0); // into the guard page
  if (cmdline_has(VX_STR("vx.selftest=fault"))) {
    // Nothing is mapped this far above the direct map's start.
    volatile const uint64_t *p = (volatile const uint64_t *)(boot.hhdm + (1ull << 46));
    (void)*p;
  }
  if (cmdline_has(VX_STR("vx.selftest=lower-half"))) {
    // The lower half is empty until there is a user address space. (Address 8,
    // not 0: a null load would stop at the debug kernel's UBSan check first.)
    volatile const uint64_t *p = (volatile const uint64_t *)(uintptr_t)8;
    (void)*p;
  }
  if (cmdline_has(VX_STR("vx.selftest=write-text"))) {
    // Kernel code is read-only (W^X).
    volatile uint8_t *p = (volatile uint8_t *)(uintptr_t)&kernel_main;
    *p = 0;
  }
  if (cmdline_has(VX_STR("vx.selftest=write-text-alias"))) {
    // And so is its other mapping, in the direct map.
    volatile uint8_t *p = phys_to_virt((uintptr_t)&kernel_main - boot.kernel_virt + boot.kernel_phys);
    *p = 0;
  }
}

[[noreturn]] static void kernel_main_on_kstack(void);

[[noreturn, clang::no_stack_protector]] void kernel_main(void) {
  uint64_t entry = arch_counter();
  bool ok = boot_read();
  arch_console_init();
  if (!ok) panic(VX_STR("the bootloader does not provide Limine base revision 6"));
  clock_init(arch_counter_hz(), entry);
  arch_cpu_init(0);
  phys_init();
  paging_init();
  kstack_init();
  // CPU 0 leaves the boot stack for a kernel stack like every other (mm/kstack.c),
  // which it keeps as its idle stack.
  uint64_t stack = kstack_alloc();
  if (!stack) panic(VX_STR("no memory for CPU 0's stack"));
  cpus[0].idle_stack = stack;
  arch_run_on_stack(stack + KSTACK_SIZE, kernel_main_on_kstack);
}

[[noreturn]] static void kernel_main_on_kstack(void) {
  arch_devices_init();
  arch_timer_init();
  sched_enter_cpu();
  smp_init();

  kput(VX_STR("vx: kernel 0.1.0 " VX_ARCH_NAME ", "));
  kput_u64(phys.free_pages >> 8);
  kput(VX_STR(" MiB free, "));
  kput_u64(atomic_load(&cpus_online));
  kput(atomic_load(&cpus_online) == 1 ? VX_STR(" cpu\n") : VX_STR(" cpus\n"));

  find_root_module();
  reclaim_boot_memory(); // every CPU is on the kernel's tables and stacks, and the responses are read
  selftests();           // after the reclaim, so the allocator tests cover that memory too, and before
                         // the root task, so nothing else allocates while they count
  start_root_task();
  sched_idle_loop();
}
