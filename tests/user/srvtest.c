// srvtest: /srv as a file tree (M6 step 6d4d2a), run in the srv scenario
// (tests/qemu/srv.ndb) with the POSIX template's /srv (srvfs): a manifest's
// post listed and opened for a connector that works; a post made, opened by
// its owner and refused to another user, written twice, removed; a name
// taken twice; an entry not posted yet; a post with ORCLOSE gone with its
// maker's fid. Each check prints a line only when it fails; the last line
// counts them.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-ns/spawn.c"

static uint32_t checks, failures;

static void check_at(bool ok, const char *what, int line) {
  checks++;
  if (ok) return;
  failures++;
  vx_print(VX_STR("srvtest: FAILED line "));
  vx_print_u64((uint64_t)line);
  vx_print(VX_STR(": "));
  vx_print(vx_cstr(what));
  vx_print(VX_STR("\n"));
}

#define CHECK(cond) check_at((cond), #cond, __LINE__)

static vx_ns ns;

static bool str_is(const char *a, const char *b) {
  return vx_cstr(a).len == vx_cstr(b).len && !memcmp(a, b, vx_cstr(a).len);
}

// Whether /srv lists name, and its owner and mode if so.
static bool listed(const char *name, uint32_t *mode, char *owner) {
  vx_ns_file d;
  if (vx_ns_open(&ns, VX_STR("/srv"), P9_OREAD, &d) != VX_OK) return false;
  static uint8_t buf[4096];
  bool found = false;
  for (int64_t n; !found && (n = vx_ns_read(&d, buf, sizeof buf)) > 0;) {
    p9_stat st;
    for (size_t off = 0; !found && p9_dir_next(buf, (size_t)n, &off, &st);)
      if (st.name.len == vx_cstr(name).len && !memcmp(st.name.ptr, name, st.name.len)) {
        found = true;
        *mode = st.mode;
        memcpy(owner, st.uid.ptr, st.uid.len < 31 ? st.uid.len : 31);
        owner[st.uid.len < 31 ? st.uid.len : 31] = 0;
      }
  }
  vx_ns_close(&d);
  return found;
}

// A connector from opening /srv/name on connection c, as the user it attached as.
static vx_status open_post(p9_client *c, uint32_t root, const char *name, vx_handle *out) {
  uint32_t fid;
  vx_status e = p9c_walk(c, root, vx_cstr(name), &fid);
  if (e != VX_OK) return e;
  e = p9c_open_handle(c, fid, P9_ORDWR, out);
  p9c_clunk(c, fid);
  return e;
}

const char *vx_main(void) {
  if (vx_ns_from_spawn(&ns) != VX_OK) return "no namespace";
  uint32_t mode = 0;
  char owner[32] = {};
  CHECK(listed("null", &mode, owner) && (mode & 0777) == 0666 && str_is(owner, "sys")); // svcd's, srvmode=

  // This program's own connection to srvfs, as vectra, and another as someone else.
  vx_handle srv = vx_ns_connector(&ns, VX_STR("/srv"));
  CHECK(srv != VX_HANDLE_NONE);
  static p9_conn me, other;
  uint32_t mroot = 0, oroot = 0;
  CHECK(p9_ring_connect(srv, &me) == VX_OK && (me.c.extensions & P9_EXT_SRV));
  me.c.uname = VX_STR("vectra");
  CHECK(p9c_attach(&me.c, VX_STR(""), &mroot) == VX_OK);
  CHECK(p9_ring_connect(srv, &other) == VX_OK);
  other.c.uname = VX_STR("glenda");
  CHECK(p9c_attach(&other.c, VX_STR(""), &oroot) == VX_OK);

  // /srv/null's connector works: its zero reads as zeros.
  vx_handle null = VX_HANDLE_NONE;
  CHECK(open_post(&me.c, mroot, "null", &null) == VX_OK && null);
  static p9_conn nc;
  uint32_t nroot = 0, zero = 0;
  uint8_t z[8] = {1, 1, 1, 1, 1, 1, 1, 1};
  CHECK(p9_ring_connect(null, &nc) == VX_OK && p9c_attach(&nc.c, VX_STR(""), &nroot) == VX_OK &&
        p9c_walk(&nc.c, nroot, VX_STR("zero"), &zero) == VX_OK && p9c_open(&nc.c, zero, P9_OREAD) == VX_OK &&
        p9c_read(&nc.c, zero, 0, z, sizeof z) == 8 && z[0] == 0 && z[7] == 0);
  p9_ring_disconnect(&nc);

  // A post of one's own: made, written with a connector, listed as one's own.
  uint32_t fid = 0;
  vx_handle dup;
  CHECK(p9c_walk(&me.c, mroot, VX_STR(""), &fid) == VX_OK &&
        p9c_create(&me.c, fid, VX_STR("mine"), 0600, P9_OWRITE) == VX_OK);
  CHECK(vx_handle_dup(null, VX_RIGHTS_SAME, &dup) == VX_OK && p9c_write_handle(&me.c, fid, dup) == VX_OK);
  CHECK(vx_handle_dup(null, VX_RIGHTS_SAME, &dup) == VX_OK &&
        p9c_write_handle(&me.c, fid, dup) == VX_ERR_BAD_STATE); // posted already
  p9c_clunk(&me.c, fid);
  CHECK(listed("mine", &mode, owner) && (mode & 0777) == 0600 && str_is(owner, "vectra"));
  vx_handle got = VX_HANDLE_NONE;
  CHECK(open_post(&me.c, mroot, "mine", &got) == VX_OK && got);
  vx_handle_close(got);
  CHECK(open_post(&other.c, oroot, "mine", &got) == VX_ERR_ACCESS); // 0600: the owner's
  CHECK(p9c_walk(&me.c, mroot, VX_STR(""), &fid) == VX_OK &&
        p9c_create(&me.c, fid, VX_STR("mine"), 0600, P9_OWRITE) == VX_ERR_EXISTS);
  p9c_clunk(&me.c, fid);
  uint32_t m = 0;
  CHECK(p9c_walk(&other.c, oroot, VX_STR("mine"), &m) == VX_OK && p9c_remove(&other.c, m) == VX_ERR_ACCESS);
  CHECK(p9c_walk(&me.c, mroot, VX_STR("mine"), &m) == VX_OK && p9c_remove(&me.c, m) == VX_OK);
  CHECK(!listed("mine", &mode, owner));

  // Made and not posted: there, but no connector to give.
  CHECK(p9c_walk(&me.c, mroot, VX_STR(""), &fid) == VX_OK &&
        p9c_create(&me.c, fid, VX_STR("empty"), 0666, P9_OWRITE) == VX_OK);
  CHECK(open_post(&other.c, oroot, "empty", &got) == VX_ERR_BAD_STATE);
  p9c_remove(&me.c, fid);

  // ORCLOSE: the post goes with its maker's fid.
  CHECK(p9c_walk(&me.c, mroot, VX_STR(""), &fid) == VX_OK &&
        p9c_create(&me.c, fid, VX_STR("brief"), 0666, P9_OWRITE | P9_ORCLOSE) == VX_OK);
  CHECK(vx_handle_dup(null, VX_RIGHTS_SAME, &dup) == VX_OK && p9c_write_handle(&me.c, fid, dup) == VX_OK);
  CHECK(listed("brief", &mode, owner));
  p9c_clunk(&me.c, fid);
  CHECK(!listed("brief", &mode, owner));

  vx_handle_close(null);
  p9_ring_disconnect(&me);
  p9_ring_disconnect(&other);
  vx_print(VX_STR("srvtest: "));
  vx_print_u64(checks);
  vx_print(VX_STR(" checks, "));
  vx_print_u64(failures);
  vx_print(VX_STR(" failed\n"));
  return nullptr;
}
