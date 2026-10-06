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
      .name2 = VX_STR("target"),
      .gid = 13,
      .mask = P9_GETATTR_BASIC,
      .datasync = 1,
      .attr = {.valid = P9_GETATTR_BASIC,
               .qid = {P9_QTFILE, 5, 55},
               .mode = P9_S_IFREG | 0644,
               .uid = 1,
               .gid = 2,
               .nlink = 3,
               .size = 4,
               .blksize = 4096,
               .blocks = 8,
               .atime_sec = 10,
               .atime_nsec = 11,
               .mtime_sec = 12,
               .mtime_nsec = 13,
               .ctime_sec = 14,
               .ctime_nsec = 15,
               .btime_sec = 16,
               .btime_nsec = 17,
               .gen = 18,
               .data_version = 19},
      .lock_type = P9_LOCK_WRITE,
      .lock_flags = 1,
      .start = 100,
      .length = 50,
      .proc_id = 42,
      .client_id = VX_STR("c"),
      .status = P9_LOCK_BLOCKED,
      .holds = 2,
      .token = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16},
      .whence = 2,
      .desc_flags = 1,
      .setattr = {.valid = P9_SETATTR_MODE | P9_SETATTR_SIZE | P9_SETATTR_MTIME_SET,
                  .mode = 0600,
                  .uid = 3,
                  .gid = 4,
                  .size = 5,
                  .atime_sec = 6,
                  .atime_nsec = 7,
                  .mtime_sec = 8,
                  .mtime_nsec = 9},
  };
  return m;
}

// The fields 9P2000.L's messages add come back as they went.
static void test_posix_fields(void) {
  uint8_t buf[512];
  p9_msg m = full_message(P9_Rgetattr), d;
  size_t n = p9_encode(&m, buf, sizeof buf);
  CHECK(n == 7 + 8 + 13 + 12 + 15 * 8); // Rgetattr's fixed size
  CHECK(p9_decode(buf, n, &d) == VX_OK && d.attr.valid == P9_GETATTR_BASIC && d.attr.qid.path == 55);
  CHECK(d.attr.mode == (P9_S_IFREG | 0644) && d.attr.mtime_nsec == 13 && d.attr.data_version == 19);
  m = full_message(P9_Tsetattr);
  n = p9_encode(&m, buf, sizeof buf);
  CHECK(n == 7 + 4 + 4 + 12 + 5 * 8);
  CHECK(p9_decode(buf, n, &d) == VX_OK && d.setattr.valid == m.setattr.valid && d.setattr.size == 5);
  CHECK(d.setattr.mode == 0600 && d.setattr.mtime_sec == 8 && d.setattr.mtime_nsec == 9);
  m = full_message(P9_Tjoin);
  n = p9_encode(&m, buf, sizeof buf);
  CHECK(n == 7 + 4 + 16 && p9_decode(buf, n, &d) == VX_OK && d.newfid == 12 && d.token[15] == 16);
  m = full_message(P9_Tlock);
  n = p9_encode(&m, buf, sizeof buf);
  CHECK(p9_decode(buf, n, &d) == VX_OK && d.lock_type == P9_LOCK_WRITE && d.start == 100 && d.length == 50);
  CHECK(d.proc_id == 42 && d.client_id.len == 1);
  m = full_message(P9_Trenameat);
  n = p9_encode(&m, buf, sizeof buf);
  CHECK(p9_decode(buf, n, &d) == VX_OK && d.fid == 11 && d.newfid == 12 && d.name.len == 7 &&
        d.name2.len == 6);
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
  CHECK(types == 74); // 9P2000's 27, 33 of 9P2000.L's (6d4c2: all it has but xattrs and mknod), 9Px's 14
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
  CHECK(p9_version_parse(VX_STR("9P2000.L"), &ext) == P9_2000L); // Linux's dialect (6d4c2)
  CHECK(p9_version_parse(VX_STR("9P2000.u"), &ext) == P9_2000);
  CHECK(p9_version_parse(VX_STR("9P1999"), &ext) == P9_UNKNOWN);
  CHECK(p9_version_parse(VX_STR(""), &ext) == P9_UNKNOWN);
  char buf[96];
  size_t n = p9_version_format(P9_2000X, P9_EXT_DREF | P9_EXT_NOTIFY, buf, sizeof buf);
  CHECK(n == 24 && memcmp(buf, "9P2000.x/1 +dref +notify", 24) == 0);
  CHECK(p9_version_format(P9_2000, 0, buf, sizeof buf) == 6);

  CHECK(p9_error_status(p9_error_text(VX_ERR_NOT_FOUND)) == VX_ERR_NOT_FOUND);
  CHECK(p9_error_status(p9_error_text(VX_ERR_ACCESS)) == VX_ERR_ACCESS);
  CHECK(p9_error_status(VX_STR("something only plan 9 says")) == VX_ERR_INVALID);
  // Other servers' wordings: Unix's strerror() as u9fs passes it on, and u9fs's own.
  CHECK(p9_error_status(VX_STR("No such file or directory")) == VX_ERR_NOT_FOUND);
  CHECK(p9_error_status(VX_STR("Permission denied")) == VX_ERR_ACCESS);
  CHECK(p9_error_status(VX_STR("file or directory already exists")) == VX_ERR_EXISTS);
  CHECK(p9_error_status(VX_STR("No such file or directory!")) == VX_ERR_INVALID); // whole text only
  CHECK(p9_error_status(VX_STR("No such file")) == VX_ERR_INVALID);
}

// Directory reads: each entry is bounded by what was read, not by its own size.
static void test_dir_next(void) {
  p9_stat s = {.name = VX_STR("a"), .uid = VX_STR("u"), .gid = VX_STR("g"), .muid = VX_STR("m")}, d;
  uint8_t b[256];
  size_t one = p9_stat_encode(&s, b, sizeof b), two = one + p9_stat_encode(&s, b + one, sizeof b - one),
         at = 0;
  CHECK(p9_dir_next(b, two, &at, &d) && at == one && p9_dir_next(b, two, &at, &d) && at == two);
  CHECK(!p9_dir_next(b, two, &at, &d)); // the end
  at = 0;
  CHECK(!p9_dir_next(b, one - 1, &at, &d) && at == 0); // cut short
  b[one] = 0xff, b[one + 1] = 0xff;                    // the second claims 64 KiB
  at = one;
  CHECK(!p9_dir_next(b, two, &at, &d) && at == one);
}

int main(void) {
  test_dir_next();
  test_round_trips();
  test_posix_fields();
  test_traps();
  test_stat();
  test_versions();
  return check_result();
}
