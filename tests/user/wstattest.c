// wstattest: what vx-9p's server does for every file server (M6 step
// 6d4c1), run in the fsdwstat scenario (tests/qemu/fsdwstat.ndb) against fsd
// (its home branch on /tmp) and tmpfs (/n/mem): Twstat's rename, truncate,
// chmod and mtime, all of a wstat or none of it, and what it may not
// change; ORCLOSE at create and at open; DMAPPEND's writes at the end; and
// DMEXCL's one open at a time. Each check prints a line only when it fails;
// the last line counts them.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-ns/spawn.c"

static uint32_t checks, failures;

static void check_at(bool ok, const char *what, int line) {
  checks++;
  if (ok) return;
  failures++;
  vx_print(VX_STR("wstattest: FAILED line "));
  vx_print_u64((uint64_t)line);
  vx_print(VX_STR(": "));
  vx_print(vx_cstr(what));
  vx_print(VX_STR("\n"));
}

#define CHECK(cond) check_at((cond), #cond, __LINE__)

static vx_ns ns;
static char path[64];

// dir/name, in path.
static vx_str at(const char *dir, const char *name) {
  size_t n = 0;
  for (const char *p = dir; *p; p++) path[n++] = *p;
  path[n++] = '/';
  for (const char *p = name; *p; p++) path[n++] = *p;
  return (vx_str){path, n};
}

static bool exists(const char *dir, const char *name) {
  p9_client *c;
  uint32_t fid;
  if (vx_ns_walk(&ns, at(dir, name), &c, &fid) != VX_OK) return false;
  p9c_clunk(c, fid);
  return true;
}

static void rm(const char *dir, const char *name) {
  p9_client *c;
  uint32_t fid;
  if (vx_ns_walk(&ns, at(dir, name), &c, &fid) == VX_OK) p9c_remove(c, fid);
}

static p9_stat stat_of(const vx_ns_file *f) {
  p9_stat st = {};
  p9c_stat(f->c, f->fid, &st, nullptr);
  return st;
}

static void on(const char *dir) {
  vx_ns_file f, g;
  // Rename, truncate, chmod, mtime.
  bool made = vx_ns_create(&ns, at(dir, "a"), 0644, P9_ORDWR, &f) == VX_OK;
  CHECK(made);
  if (!made) return;
  CHECK(p9c_write(f.c, f.fid, 0, "hello", 5) == 5);
  p9_stat w = p9_stat_untouched();
  w.name = VX_STR("b");
  CHECK(p9c_wstat(f.c, f.fid, &w) == VX_OK && exists(dir, "b") && !exists(dir, "a"));
  w = p9_stat_untouched();
  w.length = 2, w.mode = (stat_of(&f).mode & ~0777u) | 0600, w.mtime = 1000;
  CHECK(p9c_wstat(f.c, f.fid, &w) == VX_OK);
  p9_stat st = stat_of(&f);
  CHECK(st.length == 2 && (st.mode & 0777) == 0600 && st.mtime == 1000);
  w = p9_stat_untouched();
  CHECK(p9c_wstat(f.c, f.fid, &w) == VX_OK); // nothing: a sync
  // What may not change.
  w = p9_stat_untouched();
  w.uid = VX_STR("someone-else");
  CHECK(p9c_wstat(f.c, f.fid, &w) == VX_ERR_ACCESS);
  w = p9_stat_untouched();
  w.qid.path = 12345;
  CHECK(p9c_wstat(f.c, f.fid, &w) == VX_ERR_INVALID);
  w = p9_stat_untouched();
  w.mode = stat_of(&f).mode | P9_DMAPPEND;
  CHECK(p9c_wstat(f.c, f.fid, &w) == VX_ERR_UNSUPPORTED); // only at create
  // All of it or none: a rename onto a name that is there, with a length.
  CHECK(vx_ns_create(&ns, at(dir, "c"), 0644, P9_OWRITE, &g) == VX_OK);
  vx_ns_close(&g);
  w = p9_stat_untouched();
  w.name = VX_STR("c"), w.length = 0;
  CHECK(p9c_wstat(f.c, f.fid, &w) != VX_OK && stat_of(&f).length == 2 && exists(dir, "b"));
  vx_ns_close(&f);
  rm(dir, "b");
  rm(dir, "c");

  // ORCLOSE: made with it, gone at the clunk; opened with it, the same.
  CHECK(vx_ns_create(&ns, at(dir, "r"), 0644, P9_OWRITE | P9_ORCLOSE, &f) == VX_OK && exists(dir, "r"));
  vx_ns_close(&f);
  CHECK(!exists(dir, "r"));
  CHECK(vx_ns_create(&ns, at(dir, "r2"), 0644, P9_OWRITE, &f) == VX_OK);
  vx_ns_close(&f);
  CHECK(vx_ns_open(&ns, at(dir, "r2"), P9_OREAD | P9_ORCLOSE, &f) == VX_OK);
  vx_ns_close(&f);
  CHECK(!exists(dir, "r2"));

  // DMAPPEND: every write at the end.
  made = vx_ns_create(&ns, at(dir, "app"), P9_DMAPPEND | 0644, P9_ORDWR, &f) == VX_OK;
  CHECK(made);
  if (!made) return;
  CHECK((stat_of(&f).qid.type & P9_QTAPPEND) && (stat_of(&f).mode & P9_DMAPPEND));
  CHECK(p9c_write(f.c, f.fid, 0, "ab", 2) == 2 && p9c_write(f.c, f.fid, 0, "cd", 2) == 2);
  char buf[8] = {};
  CHECK(p9c_read(f.c, f.fid, 0, buf, sizeof buf) == 4 && memcmp(buf, "abcd", 4) == 0);
  vx_ns_close(&f);
  rm(dir, "app");

  // DMEXCL: one open at a time.
  made = vx_ns_create(&ns, at(dir, "ex"), P9_DMEXCL | 0644, P9_ORDWR, &f) == VX_OK;
  CHECK(made);
  if (!made) return;
  CHECK(stat_of(&f).qid.type & P9_QTEXCL);
  CHECK(vx_ns_open(&ns, at(dir, "ex"), P9_OREAD, &g) == VX_ERR_ACCESS);
  vx_ns_close(&f);
  CHECK(vx_ns_open(&ns, at(dir, "ex"), P9_OREAD, &g) == VX_OK);
  vx_ns_close(&g);
  rm(dir, "ex");
}

const char *vx_main(void) {
  if (vx_ns_from_spawn(&ns) != VX_OK) return "no namespace";
  on("/tmp");   // fsd
  on("/n/mem"); // tmpfs
  vx_print(VX_STR("wstattest: "));
  vx_print_u64(checks);
  vx_print(VX_STR(" checks, "));
  vx_print_u64(failures);
  vx_print(VX_STR(" failed\n"));
  return nullptr;
}
