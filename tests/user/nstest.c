// nstest: M2's namespace test, run as a service in the ns scenario
// (tests/qemu/ns.ndb). svcd spawns it from tests/user/nstest.ndb with a
// namespace: bootfs at /, /boot/bin after /bin, and bootfs attached at
// boot/svc after /dev. It checks what it sees through vx-ns, then plays a
// hostile client on its own connection. Each check prints a line only when it
// fails; the last line counts them.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-ns/spawn.c"

static uint32_t checks, failures;

static void check_at(bool ok, const char *what, int line) {
  checks++;
  if (ok) return;
  failures++;
  vx_print(VX_STR("nstest: FAILED line "));
  vx_print_u64((uint64_t)line);
  vx_print(VX_STR(": "));
  vx_print(vx_cstr(what));
  vx_print(VX_STR("\n"));
}

#define CHECK(cond) check_at((cond), #cond, __LINE__)

static bool str_is(vx_str s, const char *want);

// A string comparison that shows what it got when it fails.
static void check_str_at(vx_str got, const char *want, const char *what, int line) {
  check_at(str_is(got, want), what, line);
  if (str_is(got, want)) return;
  vx_print(VX_STR("nstest:   got \""));
  vx_print(got);
  vx_print(VX_STR("\"\n"));
}

#define CHECK_STR(got, want) check_str_at((got), (want), #got " is " #want, __LINE__)

static vx_ns ns;

static bool str_is(vx_str s, const char *want) {
  vx_str w = vx_cstr(want);
  return s.len == w.len && memcmp(s.ptr, w.ptr, w.len) == 0;
}

// The names in a directory, space-separated.
static vx_str list(const char *path) {
  static char out[512];
  size_t len = 0;
  vx_ns_file f;
  if (vx_ns_open(&ns, vx_cstr(path), P9_OREAD, &f) != VX_OK) return VX_STR("(cannot open)");
  static uint8_t buf[4096];
  int64_t n;
  while ((n = vx_ns_read(&f, buf, sizeof buf)) > 0) {
    p9_stat st;
    size_t off = 0;
    while (p9_dir_next(buf, (size_t)n, &off, &st)) {
      if (len + st.name.len + 1 >= sizeof out) return VX_STR("(too long)"); // room for the caller's NUL too
      if (len) out[len++] = ' ';
      memcpy(out + len, st.name.ptr, st.name.len);
      len += st.name.len;
    }
    if (off != (size_t)n) return VX_STR("(bad entry)");
  }
  vx_ns_close(&f);
  return n < 0 ? VX_STR("(read failed)") : (vx_str){out, len};
}

static void test_spawn(void) {
  CHECK(str_is(vx_spawn.name, "nstest"));
  CHECK(vx_spawn.argc == 2 && str_is(vx_spawn.args[0], "first") && str_is(vx_spawn.args[1], "second arg"));
  CHECK(vx_spawn_take("bootimage") == VX_HANDLE_NONE); // not granted
  CHECK(vx_spawn_take("listen") == VX_HANDLE_NONE);
}

static void test_namespace(void) {
  CHECK_STR(list("/"), "bin boot dev n net proc srv tmp");
  vx_str boot_bin = list("/boot/bin");
  static char programs[512];
  memcpy(programs, boot_bin.ptr, boot_bin.len); // list's buffer is reused
  programs[boot_bin.len] = 0;
  CHECK_STR(list("/bin"), programs); // the empty /bin, then /boot/bin
  CHECK(boot_bin.len > 6 && memcmp(programs, "bootfs nstest ", 14) == 0);
  vx_str svc = list("/boot/svc");
  static char manifests[512];
  memcpy(manifests, svc.ptr, svc.len); // list's buffer is reused
  manifests[svc.len] = 0;
  CHECK_STR(list("/dev"), manifests); // /dev's own (nothing), then boot/svc attached at /dev
  CHECK(svc.len > 22 && memcmp(manifests, "bootfs.ndb cons.ndb ", 20) == 0);

  // A file, read through a bind and through a second attach.
  static const char want[] = "# boot/svc/bootfs.ndb";
  char got[sizeof want - 1];
  vx_ns_file f;
  CHECK(vx_ns_open(&ns, VX_STR("/dev/bootfs.ndb"), P9_OREAD, &f) == VX_OK);
  CHECK(vx_ns_read(&f, got, sizeof got) == sizeof got && memcmp(got, want, sizeof got) == 0);
  vx_ns_close(&f);
  CHECK(vx_ns_open(&ns, VX_STR("/bin/nstest"), P9_OREAD, &f) == VX_OK);
  CHECK(vx_ns_read(&f, got, 4) == 4 && memcmp(got,
                                              "\x7f"
                                              "ELF",
                                              4) == 0);
  vx_ns_close(&f);

  // bootfs is read-only.
  CHECK(vx_ns_open(&ns, VX_STR("/boot/svc/bootfs.ndb"), P9_OWRITE, &f) == VX_ERR_ACCESS);
  CHECK(vx_ns_open(&ns, VX_STR("/boot/svc/bootfs.ndb"), P9_OREAD | P9_OTRUNC, &f) == VX_ERR_ACCESS);
  CHECK(vx_ns_open(&ns, VX_STR("/nothing"), P9_OREAD, &f) == VX_ERR_NOT_FOUND);

  char out[512];
  size_t n = vx_ns_print(&ns, out, sizeof out);
  static const char script[] = "mount /srv/bootfs /\n"
                               "bind /bin /bin\n"
                               "bind -a /boot/bin /bin\n"
                               "bind /dev /dev\n"
                               "mount -a /srv/bootfs /dev boot/svc\n";
  CHECK(n == sizeof script - 1 && memcmp(out, script, n) == 0);
  if (n) vx_print((vx_str){out, n});
}

// A hostile client on a connection of its own: raw walks may not leave the
// attach root, and the server keeps working after nonsense.
static void test_confinement(void) {
  p9_client *c = &vx_ns_conns[0].c;
  uint32_t root = 0, fid = 0;
  CHECK(p9c_attach(c, VX_STR("boot/bin"), &root) == VX_OK);
  CHECK(p9c_walk(c, root, VX_STR("../../../.."), &fid) == VX_OK);
  p9_stat st;
  CHECK(p9c_stat(c, fid, &st) == VX_OK && str_is(st.name, "bin"));
  p9c_clunk(c, fid);
  CHECK(p9c_walk(c, root, VX_STR("../svc"), &fid) == VX_ERR_NOT_FOUND); // ../ is bin itself; no svc there
  CHECK(p9c_walk(c, root, VX_STR("nstest"), &fid) == VX_OK);
  CHECK(p9c_create(c, root, VX_STR("x"), 0644, P9_OWRITE) == VX_ERR_ACCESS);
  CHECK(p9c_remove(c, fid) == VX_ERR_ACCESS); // and the fid is gone
  CHECK(p9c_clunk(c, fid) == VX_ERR_BAD_HANDLE);
  CHECK(p9c_attach(c, VX_STR("../.."), &fid) == VX_ERR_NOT_FOUND);
  CHECK(p9c_attach(c, VX_STR("boot/svc/bootfs.ndb"), &fid) == VX_ERR_NOT_FOUND); // not a directory
  p9c_clunk(c, root);
  CHECK(list("/bin").len > 6); // still serving
}

// A ring connection that ends takes its mapping with it (as_unmap): twenty
// connections to bootfs, each ended, leave the address space as it was.
static void test_connections_unmap(void) {
  vx_handle connector = ns.conns[0].connector;
  vx_task_summary before, after;
  CHECK(connector && vx_task_info(vx_self, &before) == VX_OK);
  for (int i = 0; i < 20; i++) {
    static p9_conn k;
    CHECK(p9_ring_connect(connector, &k) == VX_OK && p9c_version(&k.c, P9_RING_MSIZE, 0) == VX_OK);
    p9_ring_disconnect(&k);
  }
  CHECK(vx_task_info(vx_self, &after) == VX_OK && after.mapped == before.mapped);
}

const char *vx_main(void) {
  test_spawn();
  vx_status st = vx_ns_from_spawn(&ns);
  CHECK(st == VX_OK);
  if (st == VX_OK) {
    test_namespace();
    test_confinement();
    test_connections_unmap();
  }
  vx_print(VX_STR("nstest: "));
  vx_print_u64(checks);
  vx_print(VX_STR(" checks, "));
  vx_print_u64(failures);
  vx_print(VX_STR(" failed\n"));
  return failures ? "failed" : nullptr;
}
