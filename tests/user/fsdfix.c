// fsdfix: fsd's review findings fixed in M6 step 6d5c, in the fsdfix
// scenario (tests/qemu/fsdfix.ndb), as vectra (one of adm), on fsd
// connections of its own:
//   - each open of status reads a copy of its own: a reader part way through
//     does not see a label made since;
//   - a rename or a symlink to ctl or status in adm's root is refused;
//   - the dump view lists more than 256 dated labels;
//   - 40 snapshots opened one after another, more than the 32 slots; with
//     32 held, a 33rd waits for one to be let go;
//   - a snapshot deleted under a fid: the fid finds nothing, and never the
//     next snapshot that takes a slot;
//   - /adm/users rewritten with a user before vectra: a fid attached as
//     vectra is vectra's still;
//   - an orphan let go after halt is not reaped: nothing is committed.
// Each check prints a line only when it fails; the last line counts them.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-ns/spawn.c"

static uint32_t checks, failures;

static void check_at(bool ok, const char *what, int line) {
  checks++;
  if (ok) return;
  failures++;
  vx_print(VX_STR("fsdfix: FAILED line "));
  vx_print_u64((uint64_t)line);
  vx_print(VX_STR(": "));
  vx_print(vx_cstr(what));
  vx_print(VX_STR("\n"));
}

#define CHECK(cond) check_at((cond), #cond, __LINE__)

static vx_ns ns;
static vx_handle fsd;
static p9_conn adm, home;
static uint32_t aroot, hroot;

static bool attach(p9_conn *c, const char *aname, uint32_t *root) {
  if (p9_ring_connect(fsd, c) != VX_OK) return false;
  c->timeout = 60'000'000'000;
  return p9c_attach(&c->c, vx_cstr(aname), root) == VX_OK;
}

static bool has(const char *buf, size_t n, const char *s) {
  size_t k = vx_cstr(s).len;
  for (size_t i = 0; i + k <= n; i++)
    if (!memcmp(buf + i, s, k)) return true;
  return false;
}

// A decimal, at p (cap bytes): its length.
static size_t put_num(char *p, uint32_t v) {
  char t[12];
  size_t n = 0;
  do t[n++] = (char)('0' + v % 10), v /= 10;
  while (v);
  for (size_t i = 0; i < n; i++) p[i] = t[n - 1 - i];
  return n;
}

// One ctl command; its status.
static vx_status ctl(const char *cmd) {
  uint32_t fid;
  vx_status st = p9c_walk(&adm.c, aroot, VX_STR("ctl"), &fid);
  if (st != VX_OK) return st;
  st = p9c_open(&adm.c, fid, P9_OWRITE);
  size_t n = vx_cstr(cmd).len;
  int64_t w = st == VX_OK ? p9c_write(&adm.c, fid, 0, cmd, (uint32_t)n) : st;
  p9c_clunk(&adm.c, fid);
  return w < 0 ? (vx_status)w : VX_OK;
}

// The whole of a file at path from root on c, into buf: its length, or a negative status.
static int64_t read_all(p9_client *c, uint32_t root, const char *path, char *buf, uint32_t cap) {
  uint32_t fid;
  vx_status st = p9c_walk(c, root, vx_cstr(path), &fid);
  if (st != VX_OK) return st;
  st = p9c_open(c, fid, P9_OREAD);
  int64_t got = 0;
  for (int64_t n; st == VX_OK && got < cap &&
                  (n = p9c_read(c, fid, (uint64_t)got, buf + got, (uint32_t)(cap - got))) > 0;)
    got += n;
  p9c_clunk(c, fid);
  return st != VX_OK ? st : got;
}

static char big[64 * 1024];

static uint32_t commit_of(void) { // status's commit=
  int64_t n = read_all(&adm.c, aroot, "status", big, sizeof big);
  for (int64_t i = 0; i + 7 <= n; i++)
    if (!memcmp(big + i, "commit=", 7)) {
      uint32_t v = 0;
      for (int64_t j = i + 7; j < n && big[j] >= '0' && big[j] <= '9'; j++)
        v = v * 10 + (uint32_t)(big[j] - '0');
      return v;
    }
  return 0;
}

static void pause_ms(int64_t ms) {
  static _Atomic uint32_t never;
  vx_instant until = vx_clock_read() + ms * 1'000'000;
  while (vx_clock_read() < until) vx_futex_wait(&never, 0, until);
}

const char *vx_main(void) {
  if (vx_ns_from_spawn(&ns) != VX_OK) return "no namespace";
  fsd = vx_ns_connector(&ns, VX_STR("/tmp"));
  CHECK(fsd != VX_HANDLE_NONE);
  CHECK(attach(&adm, "%adm", &aroot) && attach(&home, "home", &hroot)); // %: as adm, permissively
  char buf[512];
  uint32_t fid = 0, fid2 = 0;

  // status: an open's copy. A reads 64 bytes; a label is made; B sees it; A's rest does not.
  CHECK(p9c_walk(&adm.c, aroot, VX_STR("status"), &fid) == VX_OK && p9c_open(&adm.c, fid, P9_OREAD) == VX_OK);
  int64_t first = p9c_read(&adm.c, fid, 0, buf, 64);
  CHECK(first == 64);
  CHECK(ctl("snap home home@copy") == VX_OK);
  int64_t nb = read_all(&adm.c, aroot, "status", big, sizeof big);
  CHECK(nb > 0 && has(big, (size_t)nb, "label=home@copy "));
  int64_t rest = 0, n;
  static char a_text[16 * 1024];
  while ((n = p9c_read(&adm.c, fid, 64 + (uint64_t)rest, a_text + rest, 4096)) > 0) rest += n;
  CHECK(rest > 0 && !has(a_text, (size_t)rest, "label=home@copy "));
  p9c_clunk(&adm.c, fid);

  // ctl and status are never made real in adm's root.
  CHECK(p9c_walk(&adm.c, aroot, VX_STR(""), &fid) == VX_OK &&
        p9c_create(&adm.c, fid, VX_STR("spare"), 0644, P9_OWRITE) == VX_OK);
  p9c_clunk(&adm.c, fid);
  CHECK(p9c_renameat(&adm.c, aroot, VX_STR("spare"), aroot, VX_STR("ctl")) == VX_ERR_EXISTS);
  CHECK(p9c_renameat(&adm.c, aroot, VX_STR("spare"), aroot, VX_STR("status")) == VX_ERR_EXISTS);
  uint32_t lnk;
  CHECK(p9c_symlink(&adm.c, aroot, VX_STR("status"), VX_STR("spare")) == VX_ERR_EXISTS);
  CHECK(p9c_walk(&adm.c, aroot, VX_STR("spare"), &lnk) == VX_OK && p9c_remove(&adm.c, lnk) == VX_OK);

  // The dump view: 260 dated labels, every one listed.
  bool snapped = true;
  for (uint32_t i = 0; i < 260 && snapped; i++) {
    char cmd[64] = "snap home home@2001-01-01";
    // home@YYYY-MM-DD: years 2001.., months, days: all distinct dates
    uint32_t y = 2001 + i / 28, d = 1 + i % 28;
    cmd[15] = (char)('0' + y / 1000), cmd[16] = (char)('0' + y / 100 % 10),
    cmd[17] = (char)('0' + y / 10 % 10), cmd[18] = (char)('0' + y % 10);
    cmd[23] = (char)('0' + d / 10), cmd[24] = (char)('0' + d % 10);
    snapped = ctl(cmd) == VX_OK;
  }
  CHECK(snapped);
  static p9_conn dump;
  uint32_t droot, days = 0;
  CHECK(attach(&dump, "dump", &droot));
  for (uint32_t y = 2001; y <= 2010; y++) { // each year's days
    char path[8];
    size_t k = put_num(path, y);
    path[k] = 0;
    if (p9c_walk(&dump.c, droot, vx_cstr(path), &fid) != VX_OK) continue;
    if (p9c_open(&dump.c, fid, P9_OREAD) == VX_OK) {
      for (uint64_t off = 0; (n = p9c_read(&dump.c, fid, off, big, sizeof big)) > 0; off += (uint64_t)n) {
        p9_stat st;
        for (size_t at = 0; p9_dir_next((uint8_t *)big, (size_t)n, &at, &st);) days++;
      }
    }
    p9c_clunk(&dump.c, fid);
  }
  CHECK(days == 260);

  // 40 snapshots opened one after another: more than the 32 slots.
  bool opened = true;
  for (uint32_t i = 0; i < 40 && opened; i++) {
    char cmd[32] = "snap home home@s", label[24] = "home@s";
    size_t k = put_num(cmd + 16, i), l = put_num(label + 6, i);
    cmd[16 + k] = 0, label[6 + l] = 0;
    static p9_conn s;
    uint32_t sroot;
    opened = ctl(cmd) == VX_OK && attach(&s, label, &sroot);
    if (opened) p9c_clunk(&s.c, sroot);
    p9_ring_disconnect(&s);
  }
  CHECK(opened);
  // 32 held: the 33rd waits for one to go.
  static uint32_t sroots[33];
  bool all = true;
  for (uint32_t i = 0; i < 32 && all; i++) {
    char label[24] = "home@s";
    label[6 + put_num(label + 6, i)] = 0;
    all = p9c_attach(&home.c, vx_cstr(label), &sroots[i]) == VX_OK;
  }
  CHECK(all);
  CHECK(p9c_attach(&home.c, VX_STR("home@s39"), &sroots[32]) == VX_ERR_NO_MEMORY);
  p9c_clunk(&home.c, sroots[0]);
  CHECK(p9c_attach(&home.c, VX_STR("home@s39"), &sroots[32]) == VX_OK);
  for (uint32_t i = 1; i <= 32; i++) p9c_clunk(&home.c, sroots[i]);

  // A snapshot deleted under a fid: nothing found by it, before and after
  // another snapshot opens.
  uint32_t sroot = 0, hello = 0;
  CHECK(p9c_attach(&home.c, VX_STR("home@s1"), &sroot) == VX_OK &&
        p9c_walk(&home.c, sroot, VX_STR("hello.txt"), &hello) == VX_OK);
  p9_stat st;
  p9_stat_text keep;
  CHECK(p9c_stat(&home.c, hello, &st, &keep) == VX_OK);
  CHECK(ctl("del home@s1") == VX_OK);
  CHECK(p9c_stat(&home.c, hello, &st, &keep) == VX_ERR_NOT_FOUND);
  CHECK(ctl("snap home home@after") == VX_OK && p9c_attach(&home.c, VX_STR("home@after"), &fid2) == VX_OK);
  CHECK(p9c_stat(&home.c, hello, &st, &keep) == VX_ERR_NOT_FOUND);
  p9c_clunk(&home.c, fid2);
  p9c_clunk(&home.c, hello);
  p9c_clunk(&home.c, sroot);

  // /adm/users rewritten, a user put before vectra: a fid attached as
  // vectra stays vectra's, and the new user attaches as itself.
  int64_t un = read_all(&adm.c, aroot, "users", big, sizeof big - 64);
  CHECK(un > 0);
  static char users[64 * 1024];
  size_t ul = 0;
  for (const char *q = "4242:alice::\n"; *q; q++) users[ul++] = *q;
  memcpy(users + ul, big, (size_t)(un > 0 ? un : 0)), ul += (size_t)(un > 0 ? un : 0);
  CHECK(p9c_walk(&adm.c, aroot, VX_STR("users"), &fid) == VX_OK &&
        p9c_open(&adm.c, fid, P9_OWRITE | P9_OTRUNC) == VX_OK &&
        p9c_write(&adm.c, fid, 0, users, (uint32_t)ul) == (int64_t)ul);
  p9c_clunk(&adm.c, fid); // read again
  CHECK(p9c_walk(&home.c, hroot, VX_STR(""), &fid) == VX_OK &&
        p9c_create(&home.c, fid, VX_STR("mine"), 0644, P9_OWRITE) == VX_OK);
  p9c_clunk(&home.c, fid);
  CHECK(p9c_walk(&home.c, hroot, VX_STR("mine"), &fid) == VX_OK &&
        p9c_stat(&home.c, fid, &st, &keep) == VX_OK && st.uid.len == 6 && !memcmp(st.uid.ptr, "vectra", 6));
  p9c_clunk(&home.c, fid);

  // halt, then the last of an orphan let go: nothing reaped, nothing committed.
  uint32_t orphan;
  CHECK(p9c_walk(&home.c, hroot, VX_STR(""), &orphan) == VX_OK &&
        p9c_create(&home.c, orphan, VX_STR("orphan"), 0644, P9_OWRITE) == VX_OK &&
        p9c_write(&home.c, orphan, 0, "gone", 4) == 4);
  CHECK(p9c_walk(&home.c, hroot, VX_STR("orphan"), &fid) == VX_OK && p9c_remove(&home.c, fid) == VX_OK);
  CHECK(ctl("halt") == VX_OK);
  uint32_t before = commit_of();
  p9c_clunk(&home.c, orphan);
  pause_ms(6000); // past fsd's 5-second commit
  CHECK(commit_of() == before);
  int64_t sn = read_all(&adm.c, aroot, "status", big, sizeof big);
  CHECK(sn > 0 && has(big, (size_t)sn, " halted"));

  vx_print(VX_STR("fsdfix: "));
  vx_print_u64(checks);
  vx_print(VX_STR(" checks, "));
  vx_print_u64(failures);
  vx_print(VX_STR(" failed\n"));
  return nullptr;
}
