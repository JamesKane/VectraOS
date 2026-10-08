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

// Files, in /tmp: everything 09 §5.5 has but vx_io_submit and vx_watch.
// Files through a loop: requests submitted at once, a watched directory, and
// a child that waits for its standard input to be ready.
static void async_checks(void) {
  vx_loop *l = vx_loop_new();
  vx_arena *a = vx_arena_new(1 << 16);
  vx_remove(VX_STR("/tmp/vxio/new"));
  vx_remove(VX_STR("/tmp/vxio/data"));
  vx_remove(VX_STR("/tmp/vxio"));
  vx_close(vx_create(VX_STR("/tmp/vxio"), VX_OREAD, VX_DMDIR | 0755));
  vx_fd f = vx_create(VX_STR("/tmp/vxio/data"), VX_ORDWR, 0644);
  CHECK(l && f >= 0 && vx_write(f, VX_STR("abcdefgh")) == 8);
  char b1[4], b2[4];
  vx_io ops[] = {
      {.fd = f, .op = VX_IO_READ, .off = 0, .buf = {(uint8_t *)b1, 4}, .key = 1},
      {.fd = f, .op = VX_IO_READ, .off = 4, .buf = {(uint8_t *)b2, 4}, .key = 2},
      {.fd = f, .op = VX_IO_WRITE, .off = 8, .buf = {(uint8_t *)"XY", 2}, .key = 3},
      {.fd = f, .op = VX_IO_SYNC, .key = 4},
  };
  CHECK(vx_io_submit(l, ops, 4) == VX_OK);
  vx_io bad = {.fd = f, .op = 99};
  CHECK(vx_io_submit(l, &bad, 1) == VX_ERR_INVALID);
  // A watch on the directory: a file made there is a change, by name.
  vx_fd d = vx_open(VX_STR("/tmp/vxio"), VX_OREAD);
  vx_status ws = vx_watch(l, d, 9);
  CHECK(d >= 0 && ws == VX_OK);
  uint32_t done = 0;
  bool reads = true, created = false, made = false;
  vx_event ev[8];
  vx_instant until = vx_now() + 10'000'000'000;
  while ((done != 0xf || !created) && vx_now() < until) {
    int64_t n = vx_loop_wait(l, vx_now() + 100'000'000, 0, ev, 8);
    for (int64_t i = 0; i < n; i++) {
      if (ev[i].kind == VX_EV_IO && ev[i].key >= 1 && ev[i].key <= 4) {
        done |= 1u << (ev[i].key - 1);
        if (ev[i].key == 1) reads = reads && ev[i].io.count == 4 && memcmp(b1, "abcd", 4) == 0;
        if (ev[i].key == 2) reads = reads && ev[i].io.count == 4 && memcmp(b2, "efgh", 4) == 0;
        if (ev[i].key == 3) reads = reads && ev[i].io.count == 2 && ev[i].io.op == VX_IO_WRITE;
        if (ev[i].key == 4) reads = reads && ev[i].io.count == VX_OK;
      }
      if (ev[i].kind == VX_EV_CHANGED && ev[i].key == 9 && (ev[i].changed.what & VX_CHANGED_CREATE))
        created = created || vx_str_eq(ev[i].changed.name, VX_STR("new"));
    }
    if (!made) { // after the first wait, so the watch's Tnotify is surely there
      vx_close(vx_create(VX_STR("/tmp/vxio/new"), VX_OWRITE, 0644));
      made = true;
    }
  }
  CHECK(done == 0xf && reads);
  CHECK(created);
  char all[16];
  CHECK(vx_pread(f, (vx_bytes){(uint8_t *)all, sizeof all}, 0) == 10 && memcmp(all, "abcdefghXY", 10) == 0);
  vx_close(f);
  vx_close(d);
  // Standard input ready, in a child given a channel as its stdin.
  vx_handle ends[2];
  CHECK(vx_channel_create(0, ends) == VX_OK);
  vx_str rargs[] = {VX_STR("vxapitest"), VX_STR("reader")};
  vx_str names[] = {VX_STR("stdin")};
  vx_spawn_req rreq = {
      .path = vx_exe_path(), .args = {rargs, 2}, .handles = &ends[1], .handle_names = names, .nhandles = 1};
  vx_proc reader = {};
  CHECK(vx_proc_spawn(&rreq, &reader) == VX_OK);
  vx_sleep_until(vx_now() + 50'000'000, 0); // let it wait first, so READY comes from the binding
  struct {
    vx_msg_header h;
    char text[4];
  } msg = {.text = {'p', 'i', 'n', 'g'}};
  CHECK(vx_channel_write(ends[0], &msg, sizeof msg, nullptr, 0) == VX_OK);
  vx_str rex = VX_STR("unset");
  CHECK(vx_proc_wait(reader, VX_INFINITE, a, &rex) == VX_OK && rex.len == 0);
  vx_proc_close(reader);
  vx_handle_close(ends[0]);
  vx_remove(VX_STR("/tmp/vxio/new"));
  vx_remove(VX_STR("/tmp/vxio/data"));
  vx_remove(VX_STR("/tmp/vxio"));
  vx_loop_free(l); // its watch ended, its I/O threads joined
  vx_arena_free(a);
}

static void file_checks(void) {
  vx_arena *a = vx_arena_new(1 << 20);
  vx_remove(VX_STR("/tmp/vxapi/sub/c.txt"));
  vx_remove(VX_STR("/tmp/vxapi/sub"));
  vx_remove(VX_STR("/tmp/vxapi/b.txt"));
  vx_remove(VX_STR("/tmp/vxapi/link"));
  vx_remove(VX_STR("/tmp/vxapi"));
  vx_fd dir = vx_create(VX_STR("/tmp/vxapi"), VX_OREAD, VX_DMDIR | 0755);
  CHECK(dir >= 0);
  vx_close(dir);
  vx_fd f = vx_create(VX_STR("/tmp/vxapi/a.txt"), VX_ORDWR, 0644);
  CHECK(f >= 256 && vx_write(f, VX_STR("hello world")) == 11);
  char buf[64];
  vx_bytes b = {(uint8_t *)buf, sizeof buf};
  CHECK(vx_pread(f, b, 6) == 5 && memcmp(buf, "world", 5) == 0);
  CHECK(vx_seek(f, 0, VX_SEEK_SET) == 0 && vx_read(f, (vx_bytes){(uint8_t *)buf, 5}) == 5 &&
        memcmp(buf, "hello", 5) == 0);
  CHECK(vx_seek(f, -5, VX_SEEK_END) == 6 && vx_seek(f, 2, VX_SEEK_CUR) == 8);
  CHECK(vx_pwrite(f, VX_STR("W"), 6) == 1);
  vx_dir d;
  CHECK(vx_fstat(f, a, &d) == VX_OK && d.length == 11 && !(d.mode & VX_DMDIR) && (d.mode & 0777) == 0644);
  CHECK(vx_sync(f) == VX_OK);
  CHECK(vx_close(f) == VX_OK);
  vx_status again = vx_close(f); // a closed fd finds nothing
  CHECK(again == VX_ERR_BAD_HANDLE && vx_read(f, b) < 0);
  CHECK(vx_stat(VX_STR("/tmp/vxapi/a.txt"), a, &d) == VX_OK && vx_str_eq(d.name, VX_STR("a.txt")) &&
        d.length == 11);
  vx_fd ex = vx_create(VX_STR("/tmp/vxapi/a.txt"), VX_OWRITE | VX_OEXCL, 0644);
  CHECK(ex == VX_ERR_EXISTS && vx_errstr().len > 0);
  f = vx_create(VX_STR("/tmp/vxapi/a.txt"), VX_OWRITE, 0644); // there: emptied
  CHECK(f >= 0 && vx_fstat(f, a, &d) == VX_OK && d.length == 0);
  vx_close(f);
  f = vx_open(VX_STR("/tmp/vxapi/a.txt"), VX_OWRITE | VX_OAPPEND);
  CHECK(f >= 0 && vx_write(f, VX_STR("one ")) == 4 && vx_seek(f, 0, VX_SEEK_SET) == 0 &&
        vx_write(f, VX_STR("two")) == 3);
  vx_close(f);
  f = vx_open(VX_STR("/tmp/vxapi/a.txt"), VX_OREAD);
  int64_t n = vx_read(f, b);
  CHECK(n == 7 && memcmp(buf, "one two", 7) == 0);
  vx_close(f);
  vx_dir keep = vx_dir_keep();
  keep.mtime = 1'234'567'890LL * 1'000'000'000 + 5;
  CHECK(vx_wstat(VX_STR("/tmp/vxapi/a.txt"), &keep) == VX_OK);
  CHECK(vx_stat(VX_STR("/tmp/vxapi/a.txt"), a, &d) == VX_OK && d.mtime / 1'000'000'000 == 1'234'567'890);
  CHECK(vx_rename(VX_STR("/tmp/vxapi/a.txt"), VX_STR("/tmp/vxapi/b.txt")) == VX_OK);
  CHECK(vx_stat(VX_STR("/tmp/vxapi/a.txt"), a, &d) != VX_OK &&
        vx_stat(VX_STR("/tmp/vxapi/b.txt"), a, &d) == VX_OK);
  vx_fd sub = vx_create(VX_STR("/tmp/vxapi/sub"), VX_OREAD, VX_DMDIR | 0755);
  vx_close(sub);
  CHECK(vx_rename(VX_STR("/tmp/vxapi/b.txt"), VX_STR("/tmp/vxapi/sub/c.txt")) == VX_OK); // across directories
  CHECK(vx_stat(VX_STR("/tmp/vxapi/sub/c.txt"), a, &d) == VX_OK);
  CHECK(vx_rename(VX_STR("/tmp/vxapi/sub/c.txt"), VX_STR("/tmp/vxapi/b.txt")) == VX_OK);
  vx_str target = {};
  CHECK(vx_symlink(VX_STR("b.txt"), VX_STR("/tmp/vxapi/link")) == VX_OK);
  CHECK(vx_readlink(VX_STR("/tmp/vxapi/link"), a, &target) == VX_OK && vx_str_eq(target, VX_STR("b.txt")));
  CHECK(vx_stat(VX_STR("/tmp/vxapi/link"), a, &d) == VX_OK && vx_str_eq(d.name, VX_STR("b.txt"))); // followed
  CHECK(vx_lstat(VX_STR("/tmp/vxapi/link"), a, &d) == VX_OK && (d.mode & VX_DMSYMLINK));
  vx_fd df = vx_open(VX_STR("/tmp/vxapi"), VX_OREAD);
  vx_dir *ents = nullptr;
  int64_t ne = vx_dirread(df, a, &ents);
  bool names = ne == 3;
  for (int64_t i = 0; names && i < ne; i++)
    names = vx_str_eq(ents[i].name, VX_STR("sub")) || vx_str_eq(ents[i].name, VX_STR("b.txt")) ||
            vx_str_eq(ents[i].name, VX_STR("link"));
  CHECK(names && vx_dirread(df, a, &ents) == 0); // all of it the first time
  vx_close(df);
  // Mapped: tmpfs has no Tmap (VX_ERR_UNSUPPORTED); bootfs, where this
  // program is, does.
  f = vx_open(VX_STR("/tmp/vxapi/b.txt"), VX_ORDWR);
  void *m = nullptr;
  CHECK(vx_map(f, 0, 4096, VX_MAP_WRITE, &m) == VX_ERR_UNSUPPORTED && m == nullptr);
  vx_close(f);
  f = vx_open(vx_exe_path(), VX_OREAD);
  CHECK(vx_map(f, 0, 4096, VX_MAP_WRITE | VX_MAP_EXEC, &m) == VX_ERR_INVALID); // W^X
  CHECK(vx_map(f, 0, 4096, 0, &m) == VX_OK && m &&
        memcmp(m,
               "\x7f"
               "ELF",
               4) == 0);
  if (m) CHECK(vx_unmap(m, 4096) == VX_OK);
  vx_close(f);
  CHECK(vx_ctl(VX_STR("/tmp/vxapi/b.txt"), "ctl %d", 42) == VX_OK);
  f = vx_open(VX_STR("/tmp/vxapi/b.txt"), VX_OREAD);
  n = vx_read(f, b);
  CHECK(n == 7 && memcmp(buf, "ctl 42", 6) == 0); // written at offset 0, over "one two"
  vx_close(f);
  CHECK(vx_write(VX_STDOUT, VX_STR("vxapitest: written to VX_STDOUT\n")) == 32);
  vx_remove(VX_STR("/tmp/vxapi/link"));
  CHECK(vx_remove(VX_STR("/tmp/vxapi/b.txt")) == VX_OK && vx_remove(VX_STR("/tmp/vxapi/b.txt")) != VX_OK);
  vx_remove(VX_STR("/tmp/vxapi/sub/c.txt"));
  vx_remove(VX_STR("/tmp/vxapi/sub"));
  CHECK(vx_remove(VX_STR("/tmp/vxapi")) == VX_OK);
  vx_arena_free(a);
}

// The namespace: a bind seen through its new name, an unmount, and a new
// namespace from the posix template.
static void ns_checks(void) {
  vx_arena *a = vx_arena_new(1 << 16);
  vx_close(vx_create(VX_STR("/tmp/vxns"), VX_OREAD, VX_DMDIR | 0755));
  vx_close(vx_create(VX_STR("/tmp/vxns/marker"), VX_OWRITE, 0644));
  vx_close(vx_create(VX_STR("/tmp/vxns2"), VX_OREAD, VX_DMDIR | 0755));
  vx_dir d;
  CHECK(vx_bind(VX_STR("/tmp/vxns"), VX_STR("/tmp/vxns2"), VX_MREPL) == VX_OK);
  CHECK(vx_stat(VX_STR("/tmp/vxns2/marker"), a, &d) == VX_OK);
  CHECK(vx_unmount((vx_str){}, VX_STR("/tmp/vxns2")) == VX_OK);
  CHECK(vx_stat(VX_STR("/tmp/vxns2/marker"), a, &d) != VX_OK);
  CHECK(vx_bind(VX_STR("/nonexistent"), VX_STR("/tmp/vxns2"), VX_MREPL) != VX_OK && vx_errstr().len > 0);
  CHECK(vx_mount(VX_STR("/srv/no-such-post"), VX_STR(""), VX_STR("/tmp/vxns2"), VX_MREPL) != VX_OK);
  vx_remove(VX_STR("/tmp/vxns/marker"));
  vx_remove(VX_STR("/tmp/vxns"));
  vx_remove(VX_STR("/tmp/vxns2"));
  CHECK(vx_newns(VX_STR("posix")) == VX_OK);
  CHECK(vx_stat(VX_STR("/lib/libvx.so.1"), a, &d) == VX_OK); // the template's /lib
  vx_arena_free(a);
}

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
// "sleeper" waits for a note; "reader" waits in its loop for standard input
// (VX_EV_READY), reads it and ends with it.
static int child(void) {
  vx_arena *a = vx_arena_new(1 << 16);
  if (vx_str_eq(vx_arg(1), VX_STR("reader"))) {
    vx_loop *l = vx_loop_new();
    vx_event ev;
    bool ready = l && vx_watch(l, VX_STDIN, 5) == VX_OK &&
                 vx_loop_wait(l, vx_now() + 10'000'000'000, 0, &ev, 1) == 1 && ev.kind == VX_EV_READY &&
                 ev.key == 5;
    char got[16];
    int64_t n = ready ? vx_read(VX_STDIN, (vx_bytes){(uint8_t *)got, sizeof got}) : -1;
    printf("vxapitest: reader %s: %.*s\n", ready ? "ready" : "NOT READY", n > 0 ? (int)n : 0, got);
    return n == 4 && memcmp(got, "ping", 4) == 0 ? 0 : 1;
  }
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
  if (vx_str_eq(vx_arg(1), VX_STR("child")) || vx_str_eq(vx_arg(1), VX_STR("sleeper")) ||
      vx_str_eq(vx_arg(1), VX_STR("reader")))
    return child();
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
  file_checks();
  async_checks();
  ns_checks(); // last: vx_newns leaves the namespace the rest used
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
