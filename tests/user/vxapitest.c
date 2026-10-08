// vxapitest: libvx v0's public API from a native program (M6 step 6e4b,
// ADR-0004), the vxapi scenario's (tests/qemu/vxapi.ndb). Built only with
// the target, against <vx.h> in the sysroot, and linked dynamically: each
// call is answered by libvx.so. Each check prints a line only when it fails;
// the last line counts them.

#include <stdio.h>
#include <string.h>
#include <vx.h>

static int checks, failures;

static void check_at(bool ok, const char *what, int line) {
  checks++;
  if (ok) return;
  failures++;
  printf("vxapitest: FAILED line %d: %s\n", line, what);
}

#define CHECK(cond) check_at((cond), #cond, __LINE__)

static vx_lock_t lock;
static uint64_t total;

static void adder(void *arg) {
  (void)arg;
  for (int i = 0; i < 10000; i++) {
    vx_lock(&lock);
    total++;
    vx_unlock(&lock);
  }
}

int main(void) {
  printf("vxapitest: hello from <vx.h>\n");
  CHECK(vx_abi_level() == VX_ABI_LEVEL && VX_TARGET_ABI == VX_ABI_LEVEL);

  // Time.
  vx_instant t0 = vx_now();
  CHECK(vx_sleep_until(t0 + 2'000'000, 0) == VX_OK && vx_now() >= t0 + 2'000'000);
  CHECK(vx_clock_resolution() > 0);

  // The heap.
  vx_heap *h = vx_heap_new(1 << 20);
  CHECK(!vx_heap_failed(h));
  char *p = vx_heap_alloc(h, 100);
  CHECK(p && vx_heap_usable(h, p) >= 100);
  if (p) memset(p, 'x', 100);
  vx_heap_free(h, p);

  // Threads and a lock between them.
  vx_thread a, b;
  CHECK(vx_thread_spawn(&a, adder, nullptr, 0) == VX_OK && vx_thread_spawn(&b, adder, nullptr, 0) == VX_OK);
  vx_thread_join(&a);
  vx_thread_join(&b);
  CHECK(total == 20000);
  CHECK(vx_cpu_count() >= 1);

  // A VMO, mapped and written.
  vx_handle v = VX_HANDLE_NONE;
  uint64_t at = 0;
  CHECK(vx_vmo_create(4096, 0, &v) == VX_OK &&
        vx_as_map(vx_task_self(), v, 0, 4096, VX_MAP_WRITE, &at) == VX_OK);
  if (at) ((volatile char *)at)[10] = 42;
  char back = 0;
  CHECK(vx_vmo_rw(v, VX_VMO_READ, 10, &back, 1) == VX_OK && back == 42);
  CHECK(vx_as_unmap(vx_task_self(), at, 4096) == VX_OK && vx_handle_close(v) == VX_OK);

  // Text: ndb and runes.
  static const char text[] = "name=vxapi level=0 flag\n";
  char scratch[256];
  vx_ndb_reader r = {.src = VX_STR(text), .scratch = scratch, .scratch_cap = sizeof scratch};
  vx_ndb_record rec;
  uint64_t level = 99;
  CHECK(vx_ndb_next(&r, &rec) == VX_NDB_RECORD && vx_ndb_has(&rec, "flag") &&
        vx_ndb_get_u64(&rec, "level", &level) && level == 0);
  vx_rune rune = 0;
  CHECK(vx_chartorune(&rune, "\xc3\xa9", 2) == 2 && rune == 0xe9);

  // The process.
  CHECK(vx_pid() != 0 && vx_user_name().len > 0);

  printf("vxapitest: %d checks, %d failed\n", checks, failures);
  return failures ? 1 : 0;
}
