// p9_codec_test.c: lib/vx-9p's codec. Every message type round-trips with
// every field set; every truncation of each, and a trailing byte, is refused;
// and the specific traps (long walks, NUL in names, counts past the end,
// unknown types) are refused too.

#include <string.h>

#include "check.h"
#include "../../lib/vx-9p/codec.c"

// A message of the given type with every field it carries set to something
// distinctive.
static p9_msg full_message(p9_type type) {
  static const uint8_t data[5] = {1, 2, 3, 4, 5};
  static uint8_t stat[64];
  p9_stat st = {.type = 1,
                .dev = 2,
                .qid = {P9_QTDIR, 3, 4},
                .mode = P9_DMDIR | 0755,
                .length = 9,
                .name = VX_STR("dir"),
                .uid = VX_STR("jk"),
                .gid = VX_STR("jk"),
                .muid = VX_STR("")};
  size_t stat_len = p9_stat_encode(&st, stat, sizeof stat);
  p9_msg m = {
      .type = type,
      .tag = 7,
      .fid = 11,
      .newfid = 12,
      .afid = P9_NOFID,
      .msize = 8192,
      .iounit = 8168,
      .perm = 0644,
      .count = 5,
      .offset = 0x1234'5678'9abc,
      .mode = P9_ORDWR,
      .oldtag = 3,
      .version = VX_STR("9P2000.x/1 +dref"),
      .uname = VX_STR("jk"),
      .aname = VX_STR("/srv"),
      .ename = VX_STR("file does not exist"),
      .name = VX_STR("new.txt"),
      .qid = {P9_QTFILE, 9, 99},
      .nwname = 3,
      .wname = {VX_STR("a"), VX_STR(".."), VX_STR("c")},
      .nwqid = 2,
      .wqid = {{P9_QTDIR, 1, 2}, {P9_QTFILE, 3, 4}},
      .data = {data, sizeof data},
      .stat = {stat, stat_len},
  };
  return m;
}

static void test_round_trips(void) {
  uint8_t buf[512], again[512];
  int types = 0;
  for (int t = 0; t < 256; t++) {
    if (!P9_FIELDS[t]) continue;
    types++;
    p9_msg m = full_message((p9_type)t), d;
    size_t n = p9_encode(&m, buf, sizeof buf);
    CHECK(n >= 7);
    CHECK(p9_decode(buf, n, &d) == VX_OK && d.type == t && d.tag == 7);
    CHECK(p9_encode(&d, again, sizeof again) == n && memcmp(buf, again, n) == 0);

    // Every shorter length, with the size field saying so, is malformed.
    for (size_t len = 0; len < n; len++) {
      uint8_t cut[512];
      memcpy(cut, buf, len);
      if (len >= 4) cut[0] = (uint8_t)len, cut[1] = cut[2] = cut[3] = 0;
      if (p9_decode(cut, len, &d) == VX_OK && len != n) {
        CHECK(!"a truncated message decoded");
        break;
      }
    }
    // So is one byte too many.
    buf[n] = 0;
    buf[0] = (uint8_t)(n + 1);
    CHECK(p9_decode(buf, n + 1, &d) == VX_ERR_INVALID);
    // So is a size field that disagrees with the length.
    buf[0] = (uint8_t)(n - 1);
    CHECK(p9_decode(buf, n, &d) == VX_ERR_INVALID);
  }
  CHECK(types == 27);
  CHECK(P9_FIELDS[106] == nullptr); // there is no Terror
  CHECK(p9_encode(&(p9_msg){.type = (p9_type)106}, buf, sizeof buf) == 0);
  CHECK(p9_encode(&(p9_msg){.type = P9_Tclunk}, buf, 6) == 0); // does not fit
}

// A hand-built Twalk with `n` names, and optionally a NUL in the last.
static size_t raw_walk(uint8_t *b, uint16_t n, bool nul) {
  size_t len = 4;
  b[len++] = P9_Twalk;
  b[len++] = 1, b[len++] = 0;               // tag
  for (int i = 0; i < 8; i++) b[len++] = 0; // fid, newfid
  b[len++] = (uint8_t)n, b[len++] = (uint8_t)(n >> 8);
  for (uint16_t i = 0; i < n; i++) b[len++] = 1, b[len++] = 0, b[len++] = (nul && i == n - 1) ? 0 : 'a';
  b[0] = (uint8_t)len, b[1] = (uint8_t)(len >> 8), b[2] = b[3] = 0;
  return len;
}

static void test_traps(void) {
  uint8_t b[256];
  p9_msg d;
  CHECK(p9_decode(b, raw_walk(b, 16, false), &d) == VX_OK && d.nwname == 16);
  CHECK(p9_decode(b, raw_walk(b, 17, false), &d) == VX_ERR_INVALID); // more than MAXWELEM
  CHECK(p9_decode(b, raw_walk(b, 2, true), &d) == VX_ERR_INVALID);   // NUL in a name

  // A Twrite whose count runs past the message.
  p9_msg w = full_message(P9_Twrite);
  size_t n = p9_encode(&w, b, sizeof b);
  b[4 + 1 + 2 + 4 + 8] = 200; // count's low byte
  CHECK(p9_decode(b, n, &d) == VX_ERR_INVALID);

  // Unknown types.
  uint8_t tiny[7] = {7, 0, 0, 0, 99, 0, 0};
  CHECK(p9_decode(tiny, 7, &d) == VX_ERR_INVALID);
  tiny[4] = 106;
  CHECK(p9_decode(tiny, 7, &d) == VX_ERR_INVALID);
  tiny[4] = P9_Rflush;
  CHECK(p9_decode(tiny, 7, &d) == VX_OK);
  CHECK(p9_decode(tiny, 6, &d) == VX_ERR_INVALID);
}

static void test_stat(void) {
  p9_stat s = {.qid = {P9_QTFILE, 1, 2},
               .mode = 0644,
               .length = 10,
               .name = VX_STR("f"),
               .uid = VX_STR("u"),
               .gid = VX_STR("g"),
               .muid = VX_STR("m")};
  uint8_t b[128];
  size_t n = p9_stat_encode(&s, b, sizeof b);
  p9_stat d;
  CHECK(n == 2 + 39 + 4 * 3 && p9_stat_decode(b, n, &d) == VX_OK);
  CHECK(d.length == 10 && d.qid.path == 2 && d.name.len == 1 && d.muid.ptr[0] == 'm');
  CHECK(p9_stat_decode(b, n - 1, &d) == VX_ERR_INVALID);
  CHECK(p9_stat_encode(&s, b, 20) == 0);
}

static void test_versions(void) {
  uint32_t ext;
  CHECK(p9_version_parse(VX_STR("9P2000.x/1 +dref +map +future"), &ext) == P9_2000X);
  CHECK(ext == (P9_EXT_DREF | P9_EXT_MAP));
  CHECK(p9_version_parse(VX_STR("9P2000.x/1"), &ext) == P9_2000X && ext == 0);
  CHECK(p9_version_parse(VX_STR("9P2000"), &ext) == P9_2000);
  CHECK(p9_version_parse(VX_STR("9P2000.L"), &ext) == P9_2000);
  CHECK(p9_version_parse(VX_STR("9P1999"), &ext) == P9_UNKNOWN);
  CHECK(p9_version_parse(VX_STR(""), &ext) == P9_UNKNOWN);
  char buf[96];
  size_t n = p9_version_format(P9_2000X, P9_EXT_DREF | P9_EXT_NOTIFY, buf, sizeof buf);
  CHECK(n == 24 && memcmp(buf, "9P2000.x/1 +dref +notify", 24) == 0);
  CHECK(p9_version_format(P9_2000, 0, buf, sizeof buf) == 6);

  CHECK(p9_error_status(p9_error_text(VX_ERR_NOT_FOUND)) == VX_ERR_NOT_FOUND);
  CHECK(p9_error_status(p9_error_text(VX_ERR_ACCESS)) == VX_ERR_ACCESS);
  CHECK(p9_error_status(VX_STR("something only plan 9 says")) == VX_ERR_INVALID);
}

int main(void) {
  test_round_trips();
  test_traps();
  test_stat();
  test_versions();
  return check_result();
}
