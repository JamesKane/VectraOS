// fsdconc: fsd's readers with the server let go (M6 step 6d5b), in the
// fsdconc scenario (tests/qemu/fsdconc.ndb). Four reader threads, each on a
// connection of its own, walk, stat, list and read files whose every byte
// they check, one of them larger than fsd's block cache, while a writer
// makes, writes and removes files and commits: every byte read is right,
// fsd has more than one thread when they are done, and the volume's check
// is clean after, nothing given back early and nothing leaked. Each check
// prints a line only when it fails; the last line counts them.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-ns/spawn.c"

static uint32_t checks, failures;
static vx_mutex count_lock;

static void check_at(bool ok, const char *what, int line) {
  vx_mutex_lock(&count_lock);
  checks++;
  if (!ok) {
    failures++;
    vx_print(VX_STR("fsdconc: FAILED line "));
    vx_print_u64((uint64_t)line);
    vx_print(VX_STR(": "));
    vx_print(vx_cstr(what));
    vx_print(VX_STR("\n"));
  }
  vx_mutex_unlock(&count_lock);
}

#define CHECK(cond) check_at((cond), #cond, __LINE__)

static constexpr uint32_t FILES = 4, FILE_SIZE = 1 << 20, BIG_SIZE = 20 << 20, CHUNK = 8192;
static constexpr int READERS = 4, ROUNDS = 12, WRITES = 40;

static vx_ns ns;
static vx_handle fsd;

static uint8_t pattern(uint32_t k, uint64_t off) {
  return (uint8_t)(off * 31 + (uint64_t)k * 7 + (off >> 12));
}

static void fill(uint8_t *buf, uint32_t k, uint64_t off, uint32_t n) {
  for (uint32_t i = 0; i < n; i++) buf[i] = pattern(k, off + i);
}

static bool connect(p9_conn *c, const char *aname, uint32_t *root) {
  if (p9_ring_connect(fsd, c) != VX_OK) return false;
  c->timeout = 60'000'000'000;
  return p9c_attach(&c->c, vx_cstr(aname), root) == VX_OK;
}

static char name_buf[READERS + 2][16];
static vx_str file_name(int slot, const char *base, uint32_t k) {
  char *p = name_buf[slot];
  size_t n = vx_cstr(base).len;
  memcpy(p, base, n);
  if (k >= 10) p[n++] = (char)('0' + k / 10);
  p[n++] = (char)('0' + k % 10);
  return (vx_str){p, n};
}

// Writes the file of `size` bytes of pattern k at name in dir.
static bool make_file(p9_client *c, uint32_t dir, vx_str name, uint32_t k, uint32_t size) {
  static uint8_t buf[CHUNK];
  uint32_t fid;
  if (p9c_walk(c, dir, VX_STR(""), &fid) != VX_OK || p9c_create(c, fid, name, 0644, P9_OWRITE) != VX_OK)
    return false;
  bool ok = true;
  for (uint32_t off = 0; ok && off < size; off += CHUNK) {
    fill(buf, k, off, CHUNK);
    ok = p9c_write(c, fid, off, buf, CHUNK) == CHUNK;
  }
  p9c_clunk(c, fid);
  return ok;
}

// Reads the whole of name in dir, checking every byte against pattern k.
static bool read_file(p9_client *c, uint32_t dir, vx_str name, uint32_t k, uint32_t size) {
  uint8_t buf[CHUNK] = {};
  uint32_t fid;
  if (p9c_walk(c, dir, name, &fid) != VX_OK) return false;
  bool ok = p9c_open(c, fid, P9_OREAD) == VX_OK;
  uint64_t off = 0;
  for (int64_t n; ok && (n = p9c_read(c, fid, off, buf, CHUNK)) > 0; off += (uint64_t)n)
    for (int64_t i = 0; ok && i < n; i++) ok = buf[i] == pattern(k, off + (uint64_t)i);
  p9c_clunk(c, fid);
  return ok && off == size;
}

typedef struct reader {
  int id;
  p9_conn conn;
  uint32_t root, conc;
  uint32_t good, listed;
} reader;

static reader readers[READERS];

static void read_loop(void *arg) {
  reader *r = arg;
  p9_client *c = &r->conn.c;
  for (int round = 0; round < ROUNDS; round++) {
    uint32_t k = (uint32_t)(r->id + round) % FILES;
    if (read_file(c, r->conc, file_name(r->id, "f", k), k, FILE_SIZE)) r->good++;
    uint32_t fid; // a stat, and a listing that has the four
    if (p9c_walk(c, r->conc, file_name(r->id, "f", k), &fid) == VX_OK) {
      p9_stat st;
      p9_stat_text keep;
      if (p9c_stat(c, fid, &st, &keep) == VX_OK && st.length == FILE_SIZE) r->good++;
      p9c_clunk(c, fid);
    }
    if (p9c_walk(c, r->conc, VX_STR(""), &fid) == VX_OK && p9c_open(c, fid, P9_OREAD) == VX_OK) {
      static thread_local uint8_t dbuf[4096];
      uint32_t found = 0;
      int64_t n;
      for (uint64_t off = 0; (n = p9c_read(c, fid, off, dbuf, sizeof dbuf)) > 0; off += (uint64_t)n) {
        p9_stat st;
        for (size_t at = 0; p9_dir_next(dbuf, (size_t)n, &at, &st);)
          if (st.name.len == 2 && st.name.ptr[0] == 'f') found++;
      }
      if (found == FILES) r->listed++;
      p9c_clunk(c, fid);
    }
    if (round == 0 && r->id < 2 && read_file(c, r->conc, VX_STR("big"), 9, BIG_SIZE)) r->good++;
  }
}

static p9_conn writer_conn;
static uint32_t writer_root, writer_conc, written;

static void write_loop(void *arg) {
  (void)arg;
  p9_client *c = &writer_conn.c;
  for (uint32_t i = 0; i < WRITES; i++) {
    if (make_file(c, writer_conc, file_name(READERS, "t", i % 100), 20 + i, 64 * 1024)) written++;
    uint32_t fid;
    if (i && p9c_walk(c, writer_conc, file_name(READERS + 1, "t", (i - 1) % 100), &fid) == VX_OK)
      p9c_remove(c, fid);
    if (i % 5 == 4 && p9c_walk(c, writer_root, VX_STR(""), &fid) == VX_OK) { // a commit, readers or not
      p9c_fsync(c, fid);
      p9c_clunk(c, fid);
    }
  }
}

// fsd's threads, from its /proc status line.
static uint32_t fsd_threads(void) {
  for (uint32_t pid = 1; pid < 64; pid++) {
    char path[32] = "/proc/", buf[256];
    size_t n = 6, got = 0;
    if (pid >= 10) path[n++] = (char)('0' + pid / 10);
    path[n++] = (char)('0' + pid % 10);
    memcpy(path + n, "/status", 8);
    if (vx_ns_read_all(&ns, vx_cstr(path), buf, sizeof buf - 1, &got) != VX_OK) continue;
    buf[got] = 0;
    const char *name = "name=fsd ";
    bool is = false;
    for (size_t i = 0; i + 9 <= got && !is; i++) is = !memcmp(buf + i, name, 9);
    if (!is) continue;
    for (size_t i = 0; i + 8 <= got; i++)
      if (!memcmp(buf + i, "threads=", 8)) {
        uint32_t t = 0;
        for (size_t j = i + 8; j < got && buf[j] >= '0' && buf[j] <= '9'; j++)
          t = t * 10 + (uint32_t)(buf[j] - '0');
        return t;
      }
  }
  return 0;
}

const char *vx_main(void) {
  if (vx_ns_from_spawn(&ns) != VX_OK) return "no namespace";
  fsd = vx_ns_connector(&ns, VX_STR("/tmp"));
  CHECK(fsd != VX_HANDLE_NONE);
  CHECK(connect(&writer_conn, "home", &writer_root));
  p9_client *w = &writer_conn.c;

  // The files: four of a mebibyte, and one larger than the cache (16 MiB).
  uint32_t fid;
  CHECK(p9c_walk(w, writer_root, VX_STR(""), &fid) == VX_OK &&
        p9c_create(w, fid, VX_STR("conc"), P9_DMDIR | 0755, P9_OREAD) == VX_OK);
  p9c_clunk(w, fid);
  CHECK(p9c_walk(w, writer_root, VX_STR("conc"), &writer_conc) == VX_OK);
  bool made = true;
  for (uint32_t k = 0; k < FILES; k++)
    made = made && make_file(w, writer_conc, file_name(0, "f", k), k, FILE_SIZE);
  made = made && make_file(w, writer_conc, VX_STR("big"), 9, BIG_SIZE);
  CHECK(made);
  CHECK(p9c_walk(w, writer_root, VX_STR(""), &fid) == VX_OK && p9c_fsync(w, fid) == VX_OK);
  p9c_clunk(w, fid);

  // The readers and the writer, all at once.
  vx_thread t[READERS + 1];
  for (int i = 0; i < READERS; i++) {
    readers[i].id = i;
    CHECK(connect(&readers[i].conn, "home", &readers[i].root) &&
          p9c_walk(&readers[i].conn.c, readers[i].root, VX_STR("conc"), &readers[i].conc) == VX_OK);
  }
  for (int i = 0; i < READERS; i++) CHECK(vx_thread_spawn(&t[i], read_loop, &readers[i], 0) == VX_OK);
  CHECK(vx_thread_spawn(&t[READERS], write_loop, nullptr, 0) == VX_OK);
  for (int i = 0; i <= READERS; i++) vx_thread_join(&t[i]);
  for (int i = 0; i < READERS; i++) {
    CHECK(readers[i].good == 2 * ROUNDS + (i < 2 ? 1 : 0));
    CHECK(readers[i].listed == ROUNDS);
  }
  CHECK(written == WRITES);
  CHECK(fsd_threads() > 1); // readers let it go: it made threads to serve the rest

  // The volume's check, through adm: nothing given back early, nothing leaked.
  static p9_conn adm;
  uint32_t aroot;
  CHECK(connect(&adm, "adm", &aroot));
  CHECK(p9c_walk(&adm.c, aroot, VX_STR("ctl"), &fid) == VX_OK && p9c_open(&adm.c, fid, P9_OWRITE) == VX_OK &&
        p9c_write(&adm.c, fid, 0, "check", 5) == 5);
  p9c_clunk(&adm.c, fid);
  char status[512] = {};
  int64_t n = 0;
  if (p9c_walk(&adm.c, aroot, VX_STR("status"), &fid) == VX_OK && p9c_open(&adm.c, fid, P9_OREAD) == VX_OK)
    n = p9c_read(&adm.c, fid, 0, status, sizeof status - 1);
  p9c_clunk(&adm.c, fid);
  bool clean = false;
  for (int64_t i = 0; i + 11 <= n && !clean; i++) clean = !memcmp(status + i, "check=clean", 11);
  CHECK(clean);
  if (!clean) vx_print((vx_str){status, n > 0 ? (size_t)n : 0});

  vx_print(VX_STR("fsdconc: "));
  vx_print_u64(checks);
  vx_print(VX_STR(" checks, "));
  vx_print_u64(failures);
  vx_print(VX_STR(" failed\n"));
  return nullptr;
}
