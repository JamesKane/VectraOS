// vx-ndb: the strict ndb record parser. See ndb.h for the format.

#include <stdckdint.h>

#include "ndb.h"

// The reader's line counts lines consumed, so a zeroed reader starts at line 1.
static size_t ndb_lineno(const vx_ndb_reader *r) { return r->line + 1; }

static vx_ndb_result ndb_fail(vx_ndb_reader *r, const char *msg) {
  r->error = msg;
  r->error_line = ndb_lineno(r);
  return VX_NDB_ERROR;
}

static int ndb_peek(const vx_ndb_reader *r) {
  return r->pos < r->src.len ? (unsigned char)r->src.ptr[r->pos] : -1;
}

static bool ndb_is_space(int c) { return c == ' ' || c == '\t'; }
static bool ndb_is_control(int c) { return (c >= 0 && c < 0x20) || c == 0x7f; }

static bool ndb_valid_utf8(const unsigned char *s, size_t n) {
  for (size_t i = 0; i < n;) {
    unsigned c = s[i];
    if (c < 0x80) {
      i++;
      continue;
    }
    size_t len;
    uint32_t cp, min;
    if ((c & 0xe0) == 0xc0) {
      len = 2;
      cp = c & 0x1f;
      min = 0x80;
    } else if ((c & 0xf0) == 0xe0) {
      len = 3;
      cp = c & 0x0f;
      min = 0x800;
    } else if ((c & 0xf8) == 0xf0) {
      len = 4;
      cp = c & 0x07;
      min = 0x10000;
    } else {
      return false;
    }
    if (n - i < len) return false;
    for (size_t k = 1; k < len; k++) {
      if ((s[i + k] & 0xc0) != 0x80) return false;
      cp = (cp << 6) | (s[i + k] & 0x3f);
    }
    if (cp < min || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff)) return false;
    i += len;
  }
  return true;
}

// Skips the rest of the line, including its newline.
static void ndb_skip_line(vx_ndb_reader *r) {
  while (r->pos < r->src.len && r->src.ptr[r->pos] != '\n') r->pos++;
  if (r->pos < r->src.len) r->pos++;
  r->line++;
}

// True if the line at pos holds nothing but blanks or a comment.
static bool ndb_line_is_empty(const vx_ndb_reader *r) {
  size_t p = r->pos;
  while (p < r->src.len && ndb_is_space((unsigned char)r->src.ptr[p])) p++;
  return p == r->src.len || r->src.ptr[p] == '\n' || r->src.ptr[p] == '#';
}

static char *ndb_scratch(vx_ndb_reader *r, size_t n) {
  if (r->scratch_cap - r->scratch_used < n) return nullptr;
  char *p = r->scratch + r->scratch_used;
  r->scratch_used += n;
  return p;
}

static int ndb_hex_digit(int c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

static bool ndb_key_eq(vx_str a, vx_str b) {
  if (a.len != b.len) return false;
  for (size_t i = 0; i < a.len; i++)
    if (a.ptr[i] != b.ptr[i]) return false;
  return true;
}

// Parses a "quoted" value. pos is on the opening quote.
static vx_ndb_result ndb_quoted(vx_ndb_reader *r, vx_str *out) {
  r->pos++;
  size_t start = r->pos, n = 0;
  // First pass: find the end and the decoded length, checking each byte.
  for (size_t p = start;; p++) {
    if (p >= r->src.len || r->src.ptr[p] == '\n') return ndb_fail(r, "unterminated quoted value");
    int c = (unsigned char)r->src.ptr[p];
    if (ndb_is_control(c)) return ndb_fail(r, "control character in a quoted value; use x\"…\"");
    if (c == '"') {
      if (p + 1 < r->src.len && r->src.ptr[p + 1] == '"') {
        p++;
        n++;
        continue;
      }
      break;
    }
    n++;
  }
  char *dst = ndb_scratch(r, n ? n : 1);
  if (!dst) return ndb_fail(r, "scratch space exhausted");
  size_t k = 0;
  for (;;) {
    char c = r->src.ptr[r->pos++];
    if (c == '"') {
      if (ndb_peek(r) == '"') {
        r->pos++;
        dst[k++] = '"';
        continue;
      }
      break;
    }
    dst[k++] = c;
  }
  if (!ndb_valid_utf8((const unsigned char *)dst, n)) return ndb_fail(r, "invalid UTF-8 in a quoted value");
  *out = (vx_str){.ptr = dst, .len = n};
  return VX_NDB_RECORD;
}

// Parses an x"hex" value. pos is on the x.
static vx_ndb_result ndb_hex(vx_ndb_reader *r, vx_str *out) {
  r->pos += 2;
  size_t start = r->pos;
  while (r->pos < r->src.len && ndb_hex_digit((unsigned char)r->src.ptr[r->pos]) >= 0) r->pos++;
  if (ndb_peek(r) != '"') return ndb_fail(r, "bad hex value");
  size_t digits = r->pos - start;
  r->pos++;
  if (digits % 2) return ndb_fail(r, "odd number of digits in a hex value");
  char *dst = ndb_scratch(r, digits / 2 ? digits / 2 : 1);
  if (!dst) return ndb_fail(r, "scratch space exhausted");
  for (size_t i = 0; i < digits / 2; i++)
    dst[i] = (char)(ndb_hex_digit((unsigned char)r->src.ptr[start + 2 * i]) << 4 |
                    ndb_hex_digit((unsigned char)r->src.ptr[start + 2 * i + 1]));
  *out = (vx_str){.ptr = dst, .len = digits / 2};
  return VX_NDB_RECORD;
}

// Parses the tuples on one line, up to and including its newline.
static vx_ndb_result ndb_tuples(vx_ndb_reader *r, vx_ndb_record *rec) {
  for (;;) {
    while (ndb_is_space(ndb_peek(r))) r->pos++;
    int c = ndb_peek(r);
    if (c == -1) return VX_NDB_RECORD;
    if (c == '\n' || c == '#') {
      ndb_skip_line(r);
      return VX_NDB_RECORD;
    }

    size_t start = r->pos;
    while ((c = ndb_peek(r)) != -1 && !ndb_is_space(c) && c != '\n' && c != '=' && c != '"') {
      if (ndb_is_control(c)) return ndb_fail(r, "control character in a key");
      r->pos++;
    }
    vx_ndb_tuple t = {.key = {r->src.ptr + start, r->pos - start}};
    if (t.key.len == 0) return ndb_fail(r, "empty key");
    if (!ndb_valid_utf8((const unsigned char *)t.key.ptr, t.key.len))
      return ndb_fail(r, "invalid UTF-8 in a key");

    if (ndb_peek(r) == '=') {
      r->pos++;
      c = ndb_peek(r);
      vx_ndb_result res = VX_NDB_RECORD;
      if (c == '"') {
        res = ndb_quoted(r, &t.value);
      } else if (c == 'x' && r->pos + 1 < r->src.len && r->src.ptr[r->pos + 1] == '"') {
        res = ndb_hex(r, &t.value);
      } else {
        size_t vstart = r->pos;
        while ((c = ndb_peek(r)) != -1 && !ndb_is_space(c) && c != '\n') {
          if (c == '"') return ndb_fail(r, "quote inside a bare value");
          if (ndb_is_control(c)) return ndb_fail(r, "control character in a value; use x\"…\"");
          r->pos++;
        }
        t.value = (vx_str){r->src.ptr + vstart, r->pos - vstart};
        if (t.value.len == 0) return ndb_fail(r, "empty bare value; write \"\"");
        if (!ndb_valid_utf8((const unsigned char *)t.value.ptr, t.value.len))
          return ndb_fail(r, "invalid UTF-8 in a value; use x\"…\"");
      }
      if (res != VX_NDB_RECORD) return res;
    } else if (ndb_peek(r) == '"') {
      return ndb_fail(r, "quote inside a key");
    }

    c = ndb_peek(r);
    if (c != -1 && !ndb_is_space(c) && c != '\n') return ndb_fail(r, "junk after a value");

    for (int i = 0; i < rec->count; i++)
      if (ndb_key_eq(rec->tuples[i].key, t.key)) return ndb_fail(r, "duplicate key");
    if (rec->count == VX_NDB_MAX_TUPLES) return ndb_fail(r, "too many tuples in one record");
    rec->tuples[rec->count++] = t;
  }
}

static vx_ndb_result vx_ndb_next(vx_ndb_reader *r, vx_ndb_record *rec) {
  rec->count = 0;
  while (r->pos < r->src.len && ndb_line_is_empty(r)) ndb_skip_line(r);
  if (r->pos >= r->src.len) return VX_NDB_END;
  if (ndb_is_space(ndb_peek(r))) return ndb_fail(r, "indented line with no record above it");

  size_t start = r->pos;
  rec->line = ndb_lineno(r);
  for (;;) {
    vx_ndb_result res = ndb_tuples(r, rec);
    if (res != VX_NDB_RECORD) return res;
    while (r->pos < r->src.len && ndb_line_is_empty(r)) ndb_skip_line(r);
    if (r->pos - start > VX_NDB_MAX_RECORD) return ndb_fail(r, "record longer than 64 KiB");
    if (!ndb_is_space(ndb_peek(r))) return VX_NDB_RECORD; // next record, or the end
  }
}

static vx_str vx_ndb_get(const vx_ndb_record *rec, const char *key) {
  size_t len = 0;
  while (key[len]) len++;
  for (int i = 0; i < rec->count; i++)
    if (ndb_key_eq(rec->tuples[i].key, (vx_str){key, len})) return rec->tuples[i].value;
  return (vx_str){};
}

static bool vx_ndb_has(const vx_ndb_record *rec, const char *key) {
  size_t len = 0;
  while (key[len]) len++;
  for (int i = 0; i < rec->count; i++)
    if (ndb_key_eq(rec->tuples[i].key, (vx_str){key, len})) return true;
  return false;
}

static bool vx_ndb_get_u64(const vx_ndb_record *rec, const char *key, uint64_t *out) {
  vx_str v = vx_ndb_get(rec, key);
  uint64_t n = 0;
  if (!v.len || v.len > 20 || (v.len > 1 && v.ptr[0] == '0')) return false; // no leading zeros
  for (size_t i = 0; i < v.len; i++) {
    if (v.ptr[i] < '0' || v.ptr[i] > '9' || ckd_mul(&n, n, 10u) || ckd_add(&n, n, (uint64_t)(v.ptr[i] - '0')))
      return false;
  }
  *out = n;
  return true;
}

// --- Writer ---

static void ndb_out(vx_ndb_writer *w, const char *p, size_t n) {
  if (w->failed || w->cap - w->len < n) {
    w->failed = true;
    return;
  }
  for (size_t i = 0; i < n; i++) w->buf[w->len + i] = p[i];
  w->len += n;
}

static void ndb_key(vx_ndb_writer *w, const char *key) {
  size_t n = 0;
  for (; key[n]; n++) {
    int c = (unsigned char)key[n];
    if (ndb_is_space(c) || c == '\n' || c == '=' || c == '"' || ndb_is_control(c)) w->failed = true;
  }
  if (n == 0 || key[0] == '#' || !ndb_valid_utf8((const unsigned char *)key, n)) w->failed = true;
  if (w->len && w->buf[w->len - 1] != '\n') ndb_out(w, " ", 1);
  ndb_out(w, key, n);
}

static void vx_ndb_put(vx_ndb_writer *w, const char *key, vx_str v) {
  ndb_key(w, key);
  ndb_out(w, "=", 1);
  bool printable = ndb_valid_utf8((const unsigned char *)v.ptr, v.len);
  bool bare = v.len > 0 && printable;
  for (size_t i = 0; i < v.len && printable; i++) {
    int c = (unsigned char)v.ptr[i];
    if (ndb_is_control(c)) printable = bare = false;
    if (c == ' ' || c == '"') bare = false;
  }
  if (bare) {
    ndb_out(w, v.ptr, v.len);
  } else if (printable) {
    ndb_out(w, "\"", 1);
    for (size_t i = 0; i < v.len; i++)
      ndb_out(w, v.ptr[i] == '"' ? "\"\"" : &v.ptr[i], v.ptr[i] == '"' ? 2 : 1);
    ndb_out(w, "\"", 1);
  } else {
    ndb_out(w, "x\"", 2);
    for (size_t i = 0; i < v.len; i++) {
      char hex[2] = {"0123456789abcdef"[(unsigned char)v.ptr[i] >> 4], "0123456789abcdef"[v.ptr[i] & 0xf]};
      ndb_out(w, hex, 2);
    }
    ndb_out(w, "\"", 1);
  }
}

static void vx_ndb_put_u64(vx_ndb_writer *w, const char *key, uint64_t value) {
  char buf[20];
  size_t i = sizeof buf;
  do {
    buf[--i] = (char)('0' + value % 10);
    value /= 10;
  } while (value);
  vx_ndb_put(w, key, (vx_str){buf + i, sizeof buf - i});
}

static void vx_ndb_put_i64(vx_ndb_writer *w, const char *key, int64_t value) {
  if (value >= 0) {
    vx_ndb_put_u64(w, key, (uint64_t)value);
    return;
  }
  char buf[21];
  uint64_t mag = (uint64_t)0 - (uint64_t)value;
  size_t i = sizeof buf;
  do {
    buf[--i] = (char)('0' + mag % 10);
    mag /= 10;
  } while (mag);
  buf[--i] = '-';
  vx_ndb_put(w, key, (vx_str){buf + i, sizeof buf - i});
}

static void vx_ndb_flag(vx_ndb_writer *w, const char *key) { ndb_key(w, key); }

static bool vx_ndb_end(vx_ndb_writer *w) {
  ndb_out(w, "\n", 1);
  return !w->failed;
}
