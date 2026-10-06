// cdtest: the native current directory from C (M6 step 6d7a, ADR-0039), run
// by rctest (tests/qemu/rcscript.ndb) from / in its namespace: vx_getwd, vx_chdir and a
// relative name opened after each change; .. against the path; a file, a
// missing name and a name too long refused, the directory left as it was; a
// relative create, bind and walk; another thread sees the change. rc's cd,
// and a child's inheriting it, are rctest's. Each check prints a line only
// when it fails; the last line counts them.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-ns/spawn.c"

static uint32_t checks, failures;

static void check_at(bool ok, const char *what, int line) {
  checks++;
  if (ok) return;
  failures++;
  vx_print(VX_STR("cdtest: FAILED line "));
  vx_print_u64((uint64_t)line);
  vx_print(VX_STR(": "));
  vx_print(vx_cstr(what));
  vx_print(VX_STR("\n"));
}

#define CHECK(cond) check_at((cond), #cond, __LINE__)

static vx_ns ns;

static bool wd_is(const char *want) {
  char wd[VX_WD_MAX];
  size_t n = vx_getwd(wd, sizeof wd);
  return n == vx_cstr(want).len && !memcmp(wd, want, n);
}

static bool opens(const char *path) {
  vx_ns_file f;
  if (vx_ns_open(&ns, vx_cstr(path), P9_OREAD, &f) != VX_OK) return false;
  vx_ns_close(&f);
  return true;
}

static _Atomic bool seen;
static void other(void *arg) {
  (void)arg;
  atomic_store(&seen, wd_is("/boot/bin"));
}

const char *vx_main(void) {
  if (vx_ns_from_spawn(&ns) != VX_OK) return "no namespace";
  CHECK(wd_is("/")); // rc's, inherited
  CHECK(!opens("echo"));

  CHECK(vx_chdir(&ns, VX_STR("/boot/bin")) == VX_OK && wd_is("/boot/bin"));
  CHECK(opens("echo") && opens("./echo") && opens("../bin/echo"));
  vx_thread t;
  CHECK(vx_thread_spawn(&t, other, nullptr, 0) == VX_OK);
  vx_thread_join(&t);
  CHECK(atomic_load(&seen)); // one directory for the process

  CHECK(vx_chdir(&ns, VX_STR("..")) == VX_OK && wd_is("/boot"));
  CHECK(opens("bin/echo") && !opens("echo"));
  CHECK(vx_chdir(&ns, VX_STR("bin/./../bin//")) == VX_OK && wd_is("/boot/bin"));
  CHECK(vx_chdir(&ns, VX_STR("../../../..")) == VX_OK && wd_is("/")); // .. above the root is the root

  // Refused, and left as it was.
  CHECK(vx_chdir(&ns, VX_STR("/boot")) == VX_OK);
  CHECK(vx_chdir(&ns, VX_STR("bin/echo")) == VX_ERR_INVALID && wd_is("/boot")); // not a directory
  CHECK(vx_chdir(&ns, VX_STR("no-such-dir")) == VX_ERR_NOT_FOUND && wd_is("/boot"));
  CHECK(vx_chdir(&ns, VX_STR("")) == VX_ERR_INVALID && wd_is("/boot"));
  static char longname[300];
  memset(longname, 'a', sizeof longname);
  CHECK(vx_chdir(&ns, (vx_str){longname, sizeof longname}) != VX_OK && wd_is("/boot"));

  // A relative create, walk and bind, in /tmp.
  CHECK(vx_chdir(&ns, VX_STR("/tmp")) == VX_OK);
  vx_ns_file f;
  CHECK(vx_ns_create(&ns, VX_STR("cdtest.d"), P9_DMDIR | 0755, P9_OREAD, &f) == VX_OK);
  vx_ns_close(&f);
  CHECK(vx_chdir(&ns, VX_STR("cdtest.d")) == VX_OK && wd_is("/tmp/cdtest.d"));
  CHECK(vx_ns_create(&ns, VX_STR("f"), 0644, P9_OWRITE, &f) == VX_OK);
  vx_ns_close(&f);
  CHECK(opens("/tmp/cdtest.d/f") && opens("f") && opens("../cdtest.d/f"));
  p9_client *c = nullptr;
  uint32_t fid = 0;
  CHECK(vx_ns_walk(&ns, VX_STR("f"), &c, &fid) == VX_OK);
  if (c) p9c_clunk(c, fid);
  CHECK(vx_ns_bind(&ns, VX_STR("/boot/bin"), VX_STR("."), 0) == VX_OK); // bind ... .: here
  CHECK(opens("echo") && opens("/tmp/cdtest.d/echo"));
  CHECK(vx_ns_unmount(&ns, (vx_str){}, VX_STR(".")) == VX_OK && opens("f"));

  vx_print(VX_STR("cdtest: "));
  vx_print_u64(checks);
  vx_print(VX_STR(" checks, "));
  vx_print_u64(failures);
  vx_print(VX_STR(" failed\n"));
  return nullptr;
}
