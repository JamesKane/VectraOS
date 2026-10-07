// libvxtest: libvx v0's memory, threads and time (M6 step 6e1e, 09 §5,
// swift-on-vectra's os-requirements R6 and R11-R15), the libvx scenario's
// (tests/qemu/libvx.ndb). A section for each: the CPUs the process may use,
// the clock and sleeping, futexes with deadlines, and random bytes. Each
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
  vx_thread t;
  CHECK(vx_thread_spawn(&t, waker, nullptr, 0) == VX_OK);
  vx_instant end = vx_now() + 5'000'000'000;
  vx_status st = VX_OK;
  while (!atomic_load(&word) && vx_now() < end) st = vx_futex_wait(&word, 0, end);
  CHECK(atomic_load(&word) == 1 && st != VX_ERR_TIMED_OUT);
  vx_thread_join(&t);
}

// R15: random bytes from start-up, different each time.
static void randomness(void) {
  uint8_t a[32] = {}, b[32] = {}, zero[32] = {};
  vx_random_bytes(a, sizeof a);
  vx_random_bytes(b, sizeof b);
  CHECK(memcmp(a, zero, sizeof a) != 0);
  CHECK(memcmp(a, b, sizeof a) != 0);
}

const char *vx_main(void) {
  cpus();
  timing();
  futexes();
  randomness();
  vx_print(VX_STR("libvxtest: "));
  vx_print_u64(checks);
  vx_print(VX_STR(" checks, "));
  vx_print_u64(failures);
  vx_print(VX_STR(" failed\n"));
  return failures ? "FAILED" : nullptr;
}
