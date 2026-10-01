// ndb_test.c: lib/vx-ndb's strict parser (docs/02 §4.1).

#include <string.h>

#include "check.h"
#include "../../lib/vx-ndb/ndb.c"

static char scratch[4096];

typedef struct parsed {
  int records;
  vx_ndb_record last;
  const char *error; // nullptr if it parsed
  size_t error_line;
} parsed;

static parsed parse(const char *src) {
  vx_ndb_reader r = {.src = {src, strlen(src)}, .scratch = scratch, .scratch_cap = sizeof scratch};
  parsed p = {};
  for (;;) {
    vx_ndb_record rec; // the end of input clears the record it is given, so keep the last one apart
    vx_ndb_result res = vx_ndb_next(&r, &rec);
    if (res == VX_NDB_END) return p;
    if (res == VX_NDB_ERROR) {
      p.error = r.error;
      p.error_line = r.error_line;
      return p;
    }
    p.last = rec;
    p.records++;
  }
}

static bool value_is(const vx_ndb_record *rec, const char *key, const char *want) {
  vx_str v = vx_ndb_get(rec, key);
  return v.ptr && v.len == strlen(want) && memcmp(v.ptr, want, v.len) == 0;
}

// Writes key=value and reads it back: the value must come back exactly.
static bool round_trip(vx_str value) {
  char buf[512];
  vx_ndb_writer w = {.buf = buf, .cap = sizeof buf - 1};
  vx_ndb_put(&w, "k", value);
  vx_ndb_flag(&w, "f");
  if (!vx_ndb_end(&w)) return false;
  buf[w.len] = 0;
  parsed p = parse(buf);
  vx_str got = vx_ndb_get(&p.last, "k");
  return !p.error && p.records == 1 && vx_ndb_has(&p.last, "f") && got.len == value.len &&
         memcmp(got.ptr, value.ptr, value.len) == 0;
}

static void test_writer(void) {
  CHECK(round_trip(VX_STR("plain")));
  CHECK(round_trip(VX_STR("")));
  CHECK(round_trip(VX_STR("two words")));
  CHECK(round_trip(VX_STR("say \"hi\"")));
  CHECK(round_trip(VX_STR("#not-a-comment")));
  CHECK(round_trip(VX_STR("line\nbreak k=forged"))); // a forged tuple stays inside the value
  CHECK(round_trip(VX_STR("\xff\xfe")));             // not UTF-8
  CHECK(round_trip(VX_STR("tab\there")));
  CHECK(round_trip(VX_STR("caf\xc3\xa9 au lait")));
  CHECK(round_trip(VX_STR("x\"41\""))); // looks like hex, is not

  char buf[128];
  vx_ndb_writer w = {.buf = buf, .cap = sizeof buf - 1};
  vx_ndb_put_i64(&w, "min", INT64_MIN);
  vx_ndb_put_u64(&w, "max", UINT64_MAX);
  CHECK(vx_ndb_end(&w));
  buf[w.len] = 0;
  parsed p = parse(buf);
  CHECK(value_is(&p.last, "min", "-9223372036854775808") && value_is(&p.last, "max", "18446744073709551615"));

  // A key that could not be read back fails the record; so does running out of room.
  static const char *const BAD_KEYS[] = {"", "a b", "a=b", "q\"", "#k", "nl\n"};
  for (size_t i = 0; i < sizeof BAD_KEYS / sizeof BAD_KEYS[0]; i++) {
    w = (vx_ndb_writer){.buf = buf, .cap = sizeof buf};
    vx_ndb_flag(&w, BAD_KEYS[i]);
    CHECK(!vx_ndb_end(&w));
  }
  w = (vx_ndb_writer){.buf = buf, .cap = 8};
  vx_ndb_put(&w, "key", VX_STR("longer than eight"));
  CHECK(!vx_ndb_end(&w));
}

static void test_numbers(void) {
  static const char numbers[] = "a=0 b=18446744073709551615 c=18446744073709551616 d=007 e=-1 f=1x g\n";
  vx_ndb_reader r = {.src = {numbers, sizeof numbers - 1}, .scratch = scratch, .scratch_cap = sizeof scratch};
  vx_ndb_record rec;
  CHECK(vx_ndb_next(&r, &rec) == VX_NDB_RECORD);
  uint64_t v = 99;
  CHECK(vx_ndb_get_u64(&rec, "a", &v) && v == 0);
  CHECK(vx_ndb_get_u64(&rec, "b", &v) && v == UINT64_MAX);
  v = 5;
  CHECK(!vx_ndb_get_u64(&rec, "c", &v) && !vx_ndb_get_u64(&rec, "d", &v) && !vx_ndb_get_u64(&rec, "e", &v));
  CHECK(!vx_ndb_get_u64(&rec, "f", &v) && !vx_ndb_get_u64(&rec, "g", &v) && !vx_ndb_get_u64(&rec, "h", &v));
  CHECK(v == 5);
}

int main(void) {
  test_numbers();
  test_writer();
  // Records, continuation lines, comments and blank lines.
  parsed p = parse("a=1 b=2 flag\n  c=3\nd=4");
  CHECK(!p.error && p.records == 2 && value_is(&p.last, "d", "4"));
  p = parse("a=1 b=2 flag\n  c=3\n");
  CHECK(!p.error && p.records == 1 && p.last.count == 4 && value_is(&p.last, "c", "3"));
  CHECK(vx_ndb_has(&p.last, "flag") && vx_ndb_get(&p.last, "flag").ptr == nullptr);
  p = parse("a=1\n\n  # comment\n  b=2\nc=3");
  CHECK(!p.error && p.records == 2);
  p = parse("# only a comment\n\n");
  CHECK(!p.error && p.records == 0);

  // Values: quoted with doubled quotes, '#' inside a bare value, hex bytes.
  p = parse("k=\"say \"\"hi\"\"\" color=#1b1d23 # tail\n");
  CHECK(!p.error && value_is(&p.last, "k", "say \"hi\"") && value_is(&p.last, "color", "#1b1d23"));
  p = parse("name=x\"610a62\"");
  CHECK(!p.error && value_is(&p.last, "name", "a\nb"));
  p = parse("empty=\"\"");
  CHECK(!p.error && vx_ndb_get(&p.last, "empty").len == 0 && vx_ndb_get(&p.last, "empty").ptr != nullptr);
  p = parse("u=\"caf\xc3\xa9\"");
  CHECK(!p.error && value_is(&p.last, "u", "caf\xc3\xa9"));

  // Rejected whole, never repaired.
  CHECK(parse("a=1 a=2").error);
  CHECK(parse("a=1\n  a=2").error); // a duplicate on a continuation line
  CHECK(parse("a=\"open").error);
  CHECK(parse("a=\"line\nbreak\"").error);
  CHECK(parse("a=b\"c").error);
  CHECK(parse("a\"b=1").error);
  CHECK(parse("a=").error);
  CHECK(parse("a=\"x\"y").error);
  CHECK(parse("a=x\"6\"").error); // odd number of hex digits
  CHECK(parse("a=x\"zz\"").error);
  CHECK(parse("a=\"\xff\"").error);         // invalid UTF-8
  CHECK(parse("a=\xc0\xaf").error);         // an overlong encoding
  CHECK(parse("a=\"\xed\xa0\x80\"").error); // a surrogate
  CHECK(parse("a=\"tab\there\"").error);    // a control character
  CHECK(parse("=1").error);
  p = parse("ok=1\n  indented=1\nb=1 b=2");
  CHECK(p.error && p.error_line == 3);
  CHECK(parse("  indented=1").error);

  // A record over 64 KiB is rejected.
  static char big[70000];
  memcpy(big, "k=1\n", 4);
  for (size_t i = 4; i + 8 < sizeof big; i += 8) memcpy(big + i, "  x=1  \n", 8);
  big[sizeof big - 1] = 0;
  CHECK(parse(big).error);

  // Every key at most once, and at most VX_NDB_MAX_TUPLES of them.
  static char many[4096];
  size_t n = 0;
  for (int i = 0; i <= VX_NDB_MAX_TUPLES; i++) n += (size_t)snprintf(many + n, sizeof many - n, "k%d=1 ", i);
  CHECK(parse(many).error);

  return check_result();
}
