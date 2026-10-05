// threadtest: vx-rt's threads (M6 step 6d1), run in the threads scenario
// (tests/qemu/threads.ndb). Each thread's thread_local storage starts as the
// image has it (initialised, zeroed, at its alignment) and stays its own over
// sleeps and switches; each knows its stack's bounds; a vx_mutex keeps a
// shared count whole; threads joined are unmapped, and more can be made.
// Each check prints a line only when it fails; the last line counts them.

#include "../../lib/vx-rt/rt.c"

static _Atomic uint32_t checks, failures;

static void check_at(bool ok, const char *what, int line) {
  atomic_fetch_add(&checks, 1);
  if (ok) return;
  atomic_fetch_add(&failures, 1);
  vx_print(VX_STR("threadtest: FAILED line "));
  vx_print_u64((uint64_t)line);
  vx_print(VX_STR(": "));
  vx_print(vx_cstr(what));
  vx_print(VX_STR("\n"));
}

#define CHECK(cond) check_at((cond), #cond, __LINE__)

static thread_local uint64_t tl_init = 0x1234'5678; // .tdata
static thread_local uint8_t tl_zero[100];           // .tbss
static thread_local alignas(64) uint64_t tl_aligned;

static constexpr uint32_t THREADS = 8, ROUNDS = 5000;
static vx_mutex lock;
static uint64_t count; // under lock

static bool tls_fresh(void) {
  bool zero = true;
  for (size_t i = 0; i < sizeof tl_zero; i++) zero = zero && !tl_zero[i];
  return tl_init == 0x1234'5678 && zero && ((uintptr_t)&tl_aligned & 63) == 0 && tl_aligned == 0;
}

static void worker(void *arg) {
  uint64_t me = (uint64_t)(uintptr_t)arg;
  CHECK(tls_fresh()); // its own copy, from the image
  tl_init = me, tl_zero[me] = (uint8_t)me, tl_aligned = me * 3;
  uint64_t lo = 0, hi = 0;
  int here;
  CHECK(vx_thread_stack(&lo, &hi) && (uint64_t)&here >= lo && (uint64_t)&here < hi &&
        hi - lo == 64ull * 1024);
  for (uint32_t i = 0; i < ROUNDS; i++) {
    vx_mutex_lock(&lock);
    count++;
    vx_mutex_unlock(&lock);
    if (i % 1000 == 0) {
      static _Atomic uint32_t never;
      vx_futex_wait(&never, 0, vx_clock_read() + 1'000'000); // a sleep: another thread runs, perhaps here
    }
  }
  CHECK(tl_init == me && tl_zero[me] == (uint8_t)me && tl_aligned == me * 3); // still its own
}

const char *vx_main(void) {
  CHECK(tls_fresh());
  tl_init = 0x5555;
  uint64_t lo = 0, hi = 0;
  int here;
  CHECK(vx_thread_stack(&lo, &hi) && (uint64_t)&here >= lo && (uint64_t)&here < hi); // the first thread's too
  static vx_thread t[THREADS];
  for (int round = 0; round < 2; round++) { // joined threads are let go of, and more can be made
    count = 0;
    for (uint32_t i = 0; i < THREADS; i++)
      CHECK(vx_thread_spawn(&t[i], worker, (void *)(uintptr_t)(i + 1), 64ull * 1024) == VX_OK);
    for (uint32_t i = 0; i < THREADS; i++) vx_thread_join(&t[i]);
    CHECK(count == (uint64_t)THREADS * ROUNDS);
  }
  CHECK(tl_init == 0x5555); // the first thread's own, untouched by the others
  vx_print(VX_STR("threadtest: "));
  vx_print_u64(atomic_load(&checks));
  vx_print(VX_STR(" checks, "));
  vx_print_u64(atomic_load(&failures));
  vx_print(VX_STR(" failed\n"));
  return atomic_load(&failures) ? "failed" : nullptr;
}
