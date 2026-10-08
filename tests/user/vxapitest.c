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

static vx_arena *other_scratch;

static void scratcher(void *arg) {
  (void)arg;
  other_scratch = vx_scratch(nullptr, 0); // its own thread's
}

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

  // Arenas: zeroed pushes, marks, a full arena's error in words, the nil arena.
  vx_arena *ar = vx_arena_new(1 << 16);
  CHECK(vx_arena_error(ar) == VX_OK);
  vx_mark m = vx_arena_mark(ar);
  char *q = vx_push(ar, 64, 16);
  CHECK(q && ((uintptr_t)q & 15) == 0);
  if (q) memset(q, 'y', 64);
  vx_arena_pop(ar, m);
  char *q2 = vx_push(ar, 64, 16);
  CHECK(q2 && q2 == q && q2[0] == 0 && q2[63] == 0);
  CHECK(vx_push(ar, 1 << 20, 16) == nullptr && vx_arena_error(ar) == VX_ERR_NO_MEMORY && vx_errstr().len > 0);
  vx_arena_free(ar);
  vx_arena *nil = vx_arena_new(0);
  CHECK(vx_arena_error(nil) == VX_ERR_NIL && vx_push(nil, 8, 8) == nullptr);
  // Scratch: one that is not the caller's, and another thread's its own.
  vx_arena *s1 = vx_scratch(nullptr, 0);
  vx_arena *s2 = vx_scratch(&s1, 1);
  CHECK(s1 && s2 && s1 != s2 && vx_arena_error(s1) == VX_OK);
  vx_thread st;
  CHECK(vx_thread_spawn(&st, scratcher, nullptr, 0) == VX_OK);
  vx_thread_join(&st);
  CHECK(other_scratch && other_scratch != s1 && other_scratch != s2);
  // Pools: ids with generations, so a put id is stale.
  vx_arena *pa = vx_arena_new(1 << 16);
  vx_pool *pool = vx_pool_new(pa, 24, 2);
  vx_id i1 = vx_pool_take(pool), i2 = vx_pool_take(pool);
  CHECK(i1 && i2 && i1 != i2 && vx_pool_get(pool, i1) && vx_pool_take(pool) == 0);
  vx_pool_put(pool, i1);
  vx_id i3 = vx_pool_take(pool);
  CHECK(vx_pool_get(pool, i1) == nullptr && i3 != i1 && vx_pool_get(pool, i3) != nullptr);
  vx_arena_free(pa);

  // Slices and formatting, through libvx.so: an arena, a buffer, the output.
  vx_arena *ta = vx_arena_new(1 << 16);
  vx_str msg = vx_fmt(ta, "%s %d %.3f %#x %.*s", "fmt", -42, 2.0 / 3, 255, 3, "abcdef");
  CHECK(vx_str_eq(msg, VX_STR("fmt -42 0.667 0xff abc")) && msg.ptr[msg.len] == 0);
  vx_str cat = VX_STR_CAT(ta, VX_STR("a"), msg, VX_STR("z"));
  CHECK(cat.len == msg.len + 2 && vx_str_suffix(cat, VX_STR("abcz")));
  char small[5];
  CHECK(vx_bfmt((vx_bytes){(uint8_t *)small, sizeof small}, "ab%s", "\u20ac\u20ac") == 5);
  vx_str rest = VX_STR("x=1,y=22"), field;
  int64_t sum = 0;
  while (vx_str_split(&rest, VX_STR(","), &field)) {
    int64_t v = 0;
    vx_str_i64(vx_str_cut(field, 2, field.len), &v);
    sum += v;
  }
  CHECK(sum == 23);
  CHECK(vx_printf("vxapitest: printed %s\n", "by vx_printf") == 32);
  vx_arena_free(ta);

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
