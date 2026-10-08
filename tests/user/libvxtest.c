// libvxtest: libvx v0's memory, threads and time (M6 step 6e1e, 09 §5,
// swift-on-vectra's os-requirements R6 and R11-R15), the libvx scenario's
// (tests/qemu/libvx.ndb). A section for each: the CPUs the process may use,
// the clock and sleeping, futexes with deadlines, random bytes, and the
// heap (6e1e2b). Each
// check prints a line only when it fails; the last line counts them.

#include "../../lib/vx-rt/rt.c"

static uint32_t checks, failures;

static void check_at(bool ok, const char *what, int line) {
  checks++;
  if (ok) return;
  failures++;
  vx_print(VX_STR("libvxtest: FAILED line "));
  vx_print_u64((uint64_t)line);
  vx_print(VX_STR(": "));
  vx_print(vx_cstr(what));
  vx_print(VX_STR("\n"));
}

#define CHECK(cond) check_at((cond), #cond, __LINE__)

static void say(const char *what, uint64_t n) {
  vx_print(VX_STR("libvxtest: "));
  vx_print(vx_cstr(what));
  vx_print(VX_STR(" "));
  vx_print_u64(n);
  vx_print(VX_STR("\n"));
}

// R12: as many as are online, none being reserved here (ADR-0045).
static void cpus(void) {
  vx_cpu_info info = {};
  CHECK(vx_thread_state(VX_HANDLE_NONE, 0, VX_STATE_GET_CPU, &info, sizeof info) == VX_OK);
  uint32_t n = vx_cpu_count();
  say("cpus", n);
  CHECK(info.cpus_online >= 1 && info.cpus_online <= 64);
  CHECK(!info.cpus_reserved);
  CHECK(n == info.cpus_online && info.cpus_usable == n);
}

// R13: the clock goes forward, has a resolution, and a sleep ends on time.
static void timing(void) {
  vx_duration res = vx_clock_resolution();
  say("clock resolution (ns)", (uint64_t)res);
  CHECK(res >= 1 && res <= 1'000);
  vx_instant a = vx_now(), b = vx_now();
  CHECK(a > 0 && b >= a);
  vx_instant at = vx_now() + 20'000'000;
  CHECK(vx_sleep_until(at, 0) == VX_OK);
  vx_instant woke = vx_now();
  CHECK(woke >= at);
  CHECK(woke - at < 1'000'000'000); // late only by the scheduler, under emulation
  vx_instant before = vx_now();
  CHECK(vx_sleep_until(before - 1, 0) == VX_OK); // a deadline passed: at once
  CHECK(vx_now() - before < 100'000'000);
}

static _Atomic uint32_t word;

static void waker(void *arg) {
  (void)arg;
  vx_sleep_until(vx_now() + 10'000'000, 0);
  atomic_store(&word, 1);
  vx_futex_wake(&word, 1);
}

// R11: a wait whose word has changed returns at once, one with a deadline
// times out after it, and a wake ends one before it.
static void futexes(void) {
  atomic_store(&word, 1);
  CHECK(vx_futex_wait(&word, 0, vx_now() + 1'000'000'000) == VX_ERR_BAD_STATE);
  atomic_store(&word, 0);
  vx_instant at = vx_now() + 10'000'000;
  CHECK(vx_futex_wait(&word, 0, at) == VX_ERR_TIMED_OUT);
  CHECK(vx_now() >= at);
  vx_worker t;
  CHECK(vx_worker_start(&t, waker, nullptr, 0) == VX_OK);
  vx_instant end = vx_now() + 5'000'000'000;
  vx_status st = VX_OK;
  while (!atomic_load(&word) && vx_now() < end) st = vx_futex_wait(&word, 0, end);
  CHECK(atomic_load(&word) == 1 && st != VX_ERR_TIMED_OUT);
  vx_worker_join(&t);
}

// R15: random bytes from start-up, different each time.
static void randomness(void) {
  uint8_t a[32] = {}, b[32] = {}, zero[32] = {};
  vx_random_bytes(a, sizeof a);
  vx_random_bytes(b, sizeof b);
  CHECK(memcmp(a, zero, sizeof a) != 0);
  CHECK(memcmp(a, b, sizeof a) != 0);
}

// R6: the heap. Blocks of every class and larger, each with room for what
// was asked, aligned, and apart from the others; aligned requests up to a
// span; a freed block taken again; what is not a block refused.
static void heap_blocks(void) {
  vx_heap *h = vx_heap_new(1ull << 30);
  CHECK(!vx_heap_failed(h));
  static const size_t SIZES[] = {1,     8,     16,    17,     100,     1000,    4096,     5000,
                                 30000, 32768, 32769, 100000, 1 << 20, 5 << 20, 300 << 20};
  static constexpr size_t N = sizeof SIZES / sizeof SIZES[0];
  uint8_t *p[N] = {};
  for (size_t i = 0; i < N; i++) {
    p[i] = vx_heap_alloc(h, SIZES[i]);
    CHECK(p[i] && !((uintptr_t)p[i] & 15) && vx_heap_usable(h, p[i]) >= SIZES[i]);
    if (p[i]) memset(p[i], (int)i + 1, SIZES[i]);
  }
  for (size_t i = 0; i < N; i++) {
    bool kept = p[i] != nullptr;
    for (size_t j = 0; kept && j < SIZES[i]; j += 97) kept = p[i][j] == (uint8_t)(i + 1);
    CHECK(kept && p[i][SIZES[i] - 1] == (uint8_t)(i + 1));
    vx_heap_free(h, p[i]);
  }
  for (size_t align = 16; align <= 65536; align *= 2) {
    uint8_t *a = vx_heap_alloc_aligned(h, 100, align);
    CHECK(a && !((uintptr_t)a & (align - 1)) && vx_heap_usable(h, a) >= 100);
    vx_heap_free(h, a);
  }
  CHECK(!vx_heap_alloc_aligned(h, 10, 3) && !vx_heap_alloc_aligned(h, 10, 1 << 17));
  void *b = vx_heap_alloc(h, 64);
  vx_heap_free(h, b);
  CHECK(vx_heap_alloc(h, 64) == b); // a slab's freed block is the next given
  vx_heap_free(h, b);
  int local = 0;
  CHECK(vx_heap_usable(h, &local) == 0);
  vx_heap_free(h, nullptr);
  // Many small ones: each its own, aligned.
  static uint8_t *many[10000];
  bool ok = true;
  for (size_t i = 0; i < 10000; i++) {
    many[i] = vx_heap_alloc(h, 48);
    ok = ok && many[i] && !((uintptr_t)many[i] & 15);
    if (many[i]) memset(many[i], (int)(i & 0xff), 48);
  }
  for (size_t i = 0; i < 10000; i++) ok = ok && many[i] && many[i][47] == (uint8_t)(i & 0xff);
  CHECK(ok);
  for (size_t i = 0; i < 10000; i++) vx_heap_free(h, many[i]);
}

// The process heap from several threads at once, each freeing what the
// others made: a slot table of blocks, each holding its size and a pattern.
static constexpr uint32_t SLOTS = 256;
static uint8_t *_Atomic slots[SLOTS];
static _Atomic uint32_t heap_errors;

static void heap_check_free(uint8_t *p) {
  if (!p) return;
  size_t n;
  memcpy(&n, p, sizeof n);
  bool ok = vx_heap_usable(vx_heap_process(), p) >= n;
  for (size_t j = sizeof n; ok && j < n && j < 256; j++) ok = p[j] == (uint8_t)n;
  if (!ok) atomic_fetch_add(&heap_errors, 1);
  vx_heap_free(vx_heap_process(), p);
}

static void heap_worker(void *arg) {
  uint64_t r = (uint64_t)(uintptr_t)arg * 0x9e3779b97f4a7c15ull + 1;
  for (int i = 0; i < 20000; i++) {
    r ^= r << 13, r ^= r >> 7, r ^= r << 17;
    size_t n = sizeof(size_t) + r % 3000;
    if (r % 64 == 0) n += 60000; // now and then a large one
    uint8_t *p = vx_heap_alloc(vx_heap_process(), n);
    if (!p) {
      atomic_fetch_add(&heap_errors, 1);
      continue;
    }
    memcpy(p, &n, sizeof n);
    memset(p + sizeof n, (uint8_t)n, (n < 256 ? n : 256) - sizeof n);
    heap_check_free(atomic_exchange(&slots[(r >> 32) % SLOTS], p));
  }
}

static void heap_threads(void) {
  vx_worker t[4];
  for (uintptr_t i = 0; i < 4; i++) CHECK(vx_worker_start(&t[i], heap_worker, (void *)(i + 1), 0) == VX_OK);
  for (int i = 0; i < 4; i++) vx_worker_join(&t[i]);
  for (uint32_t i = 0; i < SLOTS; i++) heap_check_free(atomic_exchange(&slots[i], nullptr));
  CHECK(atomic_load(&heap_errors) == 0);
}

// Memory given back: 160 MiB written through and freed, four times, on a
// machine of 512 MiB; it fits only if each block's pages go back.
static void heap_returns(void) {
  bool ok = true;
  for (int round = 0; round < 4 && ok; round++) {
    uint8_t *p = vx_heap_alloc(vx_heap_process(), 160ull << 20);
    ok = p != nullptr;
    for (size_t at = 0; p && at < 160ull << 20; at += 4096) p[at] = 1;
    vx_heap_free(vx_heap_process(), p);
  }
  CHECK(ok);
}

const char *vx_main(void) {
  cpus();
  timing();
  futexes();
  randomness();
  heap_blocks();
  heap_threads();
  heap_returns();
  vx_print(VX_STR("libvxtest: "));
  vx_print_u64(checks);
  vx_print(VX_STR(" checks, "));
  vx_print_u64(failures);
  vx_print(VX_STR(" failed\n"));
  return failures ? "FAILED" : nullptr;
}
