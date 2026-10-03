// dreftest: 9Px's dref extension on fsd (docs/proto/dref.md), run in the
// fsddref scenario (tests/qemu/fsddref.ndb) with fsd's home branch on /tmp.
// Reads and writes whose data is in a VMO of its own, far past the msize in
// one message; what fsd refuses; and that fsd, handed its own page cache's
// VMO as a region, refuses it rather than waiting on itself. Each check
// prints a line only when it fails; the last line counts them.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-ns/spawn.c"

static uint32_t checks, failures;

static void check_at(bool ok, const char *what, int line) {
  checks++;
  if (ok) return;
  failures++;
  vx_print(VX_STR("dreftest: FAILED line "));
  vx_print_u64((uint64_t)line);
  vx_print(VX_STR(": "));
  vx_print(vx_cstr(what));
  vx_print(VX_STR("\n"));
}

#define CHECK(cond) check_at((cond), #cond, __LINE__)

static constexpr uint32_t SIZE = 200 * 1024; // more than ten of the ring's 16 KiB messages
static uint8_t data[SIZE], back[SIZE];

static vx_ns ns;

const char *vx_main(void) {
  if (vx_ns_from_spawn(&ns) != VX_OK) return "no namespace";
  for (uint32_t i = 0; i < SIZE; i++) data[i] = (uint8_t)(i * 7 + i / 4096);
  vx_handle out = VX_HANDLE_NONE, in = VX_HANDLE_NONE;
  CHECK(vx_vmo_create(SIZE, 0, &out) == VX_OK && vx_vmo_create(SIZE + 4096, 0, &in) == VX_OK);
  CHECK(vx_vmo_rw(out, VX_VMO_WRITE, 0, data, SIZE) == VX_OK);

  // Written in one Twriteref, read back in one Treadref, at an offset in the VMO.
  vx_ns_file f;
  CHECK(vx_ns_create(&ns, VX_STR("/tmp/dref"), 0644, P9_ORDWR, &f) == VX_OK);
  CHECK(f.c->extensions & P9_EXT_DREF);
  uint32_t done = 0;
  CHECK(p9c_writeref(f.c, f.fid, 0, out, 0, SIZE, &done) == VX_OK && done == SIZE);
  CHECK(p9c_readref(f.c, f.fid, 0, in, 4096, SIZE, &done) == VX_OK && done == SIZE);
  CHECK(vx_vmo_rw(in, VX_VMO_READ, 4096, back, SIZE) == VX_OK && memcmp(back, data, SIZE) == 0);
  // Past the end: a short read; at it, none.
  CHECK(p9c_readref(f.c, f.fid, SIZE - 100, in, 0, 4096, &done) == VX_OK && done == 100);
  CHECK(p9c_readref(f.c, f.fid, SIZE, in, 0, 4096, &done) == VX_OK && done == 0);
  // What Tread sees is the same file.
  uint8_t some[64];
  CHECK(p9c_read(f.c, f.fid, 70'000, some, sizeof some) == (int64_t)sizeof some &&
        memcmp(some, data + 70'000, sizeof some) == 0);
  // A region past the VMO's end is refused, having read nothing into it.
  CHECK(p9c_readref(f.c, f.fid, 0, out, SIZE - 10, 4096, &done) != VX_OK);
  vx_ns_close(&f);

  // The fid's mode is Tread's and Twrite's rule.
  CHECK(vx_ns_open(&ns, VX_STR("/tmp/dref"), P9_OREAD, &f) == VX_OK);
  CHECK(p9c_writeref(f.c, f.fid, 0, out, 0, 4096, &done) == VX_ERR_ACCESS);
  CHECK(p9c_readref(f.c, f.fid, 0, in, 0, 4096, &done) == VX_OK && done == 4096);
  // fsd's own page cache as the region: refused, not waited on (its pages
  // were never asked for), and fsd still answers.
  vx_handle cache = VX_HANDLE_NONE;
  uint64_t at = 0, avail = 0;
  CHECK(p9c_map(f.c, f.fid, 0, 8192, P9_PROT_READ, &cache, &at, &avail) == VX_OK && avail >= 8192);
  CHECK(p9c_readref(f.c, f.fid, 0, cache, 0, 4096, &done) != VX_OK);
  if (cache) vx_handle_close(cache);
  CHECK(p9c_readref(f.c, f.fid, 0, in, 0, 4096, &done) == VX_OK && done == 4096);
  vx_ns_close(&f);
  CHECK(vx_ns_open(&ns, VX_STR("/tmp/dref"), P9_OWRITE, &f) == VX_OK);
  CHECK(p9c_readref(f.c, f.fid, 0, in, 0, 4096, &done) == VX_ERR_ACCESS);
  vx_ns_close(&f);

  vx_print(VX_STR("dreftest: "));
  vx_print_u64(checks);
  vx_print(VX_STR(" checks, "));
  vx_print_u64(failures);
  vx_print(failures ? VX_STR(" FAILED\n") : VX_STR(" failed\n"));
  return nullptr;
}
