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

static const char *scratcher(void *arg) {
  (void)arg;
  other_scratch = vx_scratch(nullptr, 0); // its own thread's
  return nullptr;
}

static const char *adder(void *arg) {
  (void)arg;
  for (int i = 0; i < 10000; i++) {
    vx_lock(&lock);
    total++;
    vx_unlock(&lock);
  }
  return "";
}

static const char *refuser(void *arg) { return arg; }

// A rendezvous: the consumer sleeps until each item is there.
static vx_lock_t rlock;
static vx_rendez rz;
static int items, taken;

static const char *consumer(void *arg) {
  (void)arg;
  vx_lock(&rlock);
  while (taken < 10) {
    while (items == 0) vx_rendez_sleep(&rz, &rlock);
    items--, taken++;
  }
  vx_unlock(&rlock);
  return nullptr;
}

static const char *poster(void *arg) {
  for (uint64_t i = 1; i <= 3; i++) vx_post(arg, 100 + i, i * i);
  return nullptr;
}

// The loop: posts from another thread, a timer once and one every 2 ms, a
// child's end, a thread's end and a note, all through one wait.
static void loop_checks(vx_arena *ex) {
  vx_loop *l = vx_loop_new();
  CHECK(l != nullptr);
  if (!l) return;
  vx_event ev[8];
  CHECK(vx_loop_wait(l, 0, 0, ev, 8) == 0); // a poll: nothing yet
  vx_instant start = vx_now();
  vx_timer once = vx_timer_at(l, start + 5'000'000, 0, 0, 1);
  vx_timer tick = vx_timer_at(l, start + 2'000'000, 0, 2'000'000, 2);
  CHECK(once && tick && once != tick);
  vx_thread *p = vx_thread_spawn(poster, l, 0, 0);
  vx_thread *bye = vx_thread_spawn(refuser, "bye", 0, 0);
  CHECK(p && bye && vx_thread_watch(l, bye, 3) == VX_OK);
  vx_str args[] = {VX_STR("kid"), VX_STR("child"), VX_STR("two words")};
  vx_spawn_req req = {.path = vx_exe_path(), .args = {args, 3}};
  vx_proc kid = {};
  CHECK(vx_proc_spawn(&req, &kid) == VX_OK && vx_proc_watch(l, kid, 4) == VX_OK);
  CHECK(vx_notes_to_loop(l) == VX_OK);
  CHECK(vx_postnote((vx_proc){.pid = vx_pid()}, VX_STR("hello note")) == VX_OK);
  uint64_t posts = 0, sum = 0, ticks = 0;
  bool fired = false, thread_end = false, kid_end = false, noted = false, waits_ok = true;
  vx_instant until = vx_now() + 10'000'000'000;
  while ((posts < 3 || !fired || ticks < 3 || !thread_end || !kid_end || !noted) && vx_now() < until) {
    int64_t n = vx_loop_wait(l, until, 0, ev, 8);
    waits_ok = waits_ok && n >= 0; // one check below: how many waits it takes varies
    for (int64_t i = 0; i < n; i++) {
      switch (ev[i].kind) {
      case VX_EV_POST: posts++, sum += ev[i].post.a + ev[i].post.b; break;
      case VX_EV_TIMER:
        if (ev[i].key == 1) fired = ev[i].timer.id == once && vx_now() >= start + 5'000'000;
        if (ev[i].key == 2 && ++ticks == 3) vx_timer_stop(l, tick);
        break;
      case VX_EV_EXIT:
        if (ev[i].key == 3) thread_end = vx_str_eq(ev[i].exit.msg, VX_STR("bye"));
        if (ev[i].key == 4) kid_end = vx_str_eq(ev[i].exit.msg, VX_STR("7")) && ev[i].source == kid.pid;
        break;
      case VX_EV_NOTE: noted = vx_str_eq(ev[i].note.text, VX_STR("hello note")); break;
      default: break;
      }
    }
  }
  CHECK(waits_ok);
  CHECK(posts == 3 && sum == 101 + 102 + 103 + 1 + 4 + 9);
  CHECK(fired && ticks == 3);
  CHECK(thread_end && kid_end && noted);
  CHECK(vx_thread_join(p, nullptr, nullptr) == VX_OK && vx_thread_join(bye, nullptr, nullptr) == VX_OK);
  CHECK(vx_loop_wait(l, vx_now() + 10'000'000, 0, ev, 8) == 0); // the stopped timer does not come back
  vx_proc_close(kid);
  vx_notify(nullptr);
  vx_loop_free(l);
  (void)ex;
}

// As the spawned child: "child" checks what it was given and ends with 7;
// "sleeper" waits for a note.
static int child(void) {
  vx_arena *a = vx_arena_new(1 << 16);
  if (vx_str_eq(vx_arg(1), VX_STR("sleeper"))) {
    printf("vxapitest: sleeper waiting\n");
    for (;;) vx_sleep_until(vx_now() + 1'000'000'000, 0);
  }
  bool ok = vx_args().len == 3 && vx_str_eq(vx_arg(0), VX_STR("kid")) &&
            vx_str_eq(vx_arg(2), VX_STR("two words")) && vx_arg(3).ptr == nullptr &&
            vx_str_eq(vx_env_get(VX_STR("VXAPI"), a), VX_STR("hello")) &&
            vx_env_get(VX_STR("VXAPI_NONE"), a).ptr == nullptr;
  if (!ok)
    printf("vxapitest: child got %zu args, 0 \"%.*s\", 2 \"%.*s\", VXAPI \"%.*s\"\n", vx_args().len,
           VX_FMT(vx_arg(0)), VX_FMT(vx_arg(2)), VX_FMT(vx_env_get(VX_STR("VXAPI"), a)));
  printf("vxapitest: child %s\n", ok ? "ok" : "FAILED its checks");
  return 7;
}

int main(void) {
  if (vx_str_eq(vx_arg(1), VX_STR("child")) || vx_str_eq(vx_arg(1), VX_STR("sleeper"))) return child();
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
  vx_thread *st = vx_thread_spawn(scratcher, nullptr, 0, 0);
  CHECK(st && vx_thread_join(st, nullptr, nullptr) == VX_OK);
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
  vx_thread *a = vx_thread_spawn(adder, nullptr, VX_INTENT_THROUGHPUT, 0);
  vx_thread *b = vx_thread_spawn(adder, nullptr, VX_INTENT_BACKGROUND, 64 << 10);
  vx_arena *ex = vx_arena_new(1 << 16);
  vx_str ea = VX_STR("unset"), eb = VX_STR("unset"), ec = {};
  CHECK(a && b && vx_thread_join(a, ex, &ea) == VX_OK && vx_thread_join(b, ex, &eb) == VX_OK);
  CHECK(ea.len == 0 && eb.len == 0);
  vx_thread *c = vx_thread_spawn(refuser, "thread said no", 0, 0);
  CHECK(c && vx_thread_join(c, ex, &ec) == VX_OK && vx_str_eq(ec, VX_STR("thread said no")));

  // Processes: itself as a child, given arguments and the environment, then
  // one ended by a note.
  CHECK(vx_env_set(VX_STR("VXAPI"), VX_STR("hello")) == VX_OK);
  CHECK(vx_str_eq(vx_env_get(VX_STR("VXAPI"), ex), VX_STR("hello")));
  vx_str args[] = {VX_STR("kid"), VX_STR("child"), VX_STR("two words")};
  vx_spawn_req req = {.path = vx_exe_path(), .args = {args, 3}, .intent = VX_INTENT_BACKGROUND};
  vx_proc kid = {};
  vx_str kex = {};
  vx_status sst = vx_proc_spawn(&req, &kid);
  CHECK(sst == VX_OK && kid.pid != 0);
  CHECK(vx_proc_wait(kid, VX_INFINITE, ex, &kex) == VX_OK && vx_str_eq(kex, VX_STR("7")));
  vx_proc_close(kid);
  vx_str sargs[] = {VX_STR("vxapitest"), VX_STR("sleeper")};
  vx_spawn_req sreq = {.path = vx_exe_path(), .args = {sargs, 2}, .flags = VX_PROC_NEWGROUP};
  vx_proc sleeper = {};
  CHECK(vx_proc_spawn(&sreq, &sleeper) == VX_OK);
  CHECK(vx_proc_wait(sleeper, vx_now() + 300'000'000, ex, &kex) == VX_ERR_TIMED_OUT);
  CHECK(vx_postnote(sleeper, VX_STR("kill")) == VX_OK);
  CHECK(vx_proc_wait(sleeper, VX_INFINITE, ex, &kex) == VX_OK && kex.len > 0);
  printf("vxapitest: the sleeper ended with \"%.*s\"\n", VX_FMT(kex));
  vx_proc_close(sleeper);
  loop_checks(ex);
  vx_thread *cons = vx_thread_spawn(consumer, nullptr, 0, 0);
  for (int i = 0; i < 10; i++) {
    vx_lock(&rlock);
    items++;
    vx_rendez_wake(&rz);
    vx_unlock(&rlock);
    if (i % 3 == 0) vx_sleep_until(vx_now() + 1'000'000, 0);
  }
  CHECK(cons && vx_thread_join(cons, nullptr, nullptr) == VX_OK && taken == 10 && items == 0);
  vx_spawn_req bad = {.path = VX_STR("/nonexistent/program")};
  CHECK(vx_proc_spawn(&bad, &kid) != VX_OK);
  vx_arena_free(ex);
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
