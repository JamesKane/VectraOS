// vx-utf: UTF-8, a rune at a time (ADR-0013), as Plan 9's libc has it, with
// lengths: nothing here reads past the n bytes it is given. Header-only, and
// defines no external symbol: the kernel, vx-rt, ndb, the servers and cmd/
// all include it.
//
// Decoding is strict and never fails. An overlong form, a surrogate
// (U+D800-U+DFFF), anything above U+10FFFF, a stray continuation byte and a
// truncated sequence each decode to VX_RUNEERROR, using up exactly one byte,
// as Plan 9's chartorune does: a decoder always moves on, and valid text after
// a bad byte still decodes. Code that must refuse bad text asks vx_utf_valid.

#pragma once

#include <stddef.h>
#include <stdint.h>

typedef __CHAR32_TYPE__ vx_rune; // C23's char32_t, which a freestanding build may have no <uchar.h> for

enum : uint32_t {
  VX_UTFMAX = 4,         // bytes in a rune, at most
  VX_RUNESELF = 0x80,    // a byte below this is a rune by itself
  VX_RUNEERROR = 0xfffd, // what a bad byte decodes to
  VX_RUNEMAX = 0x10ffff,
};

// Decodes the rune at s (n bytes there) into *r. Returns the bytes it used:
// 1 to 4, or 0 if n is 0. A bad byte is VX_RUNEERROR, and 1.
[[maybe_unused]] static size_t vx_chartorune(vx_rune *r, const char *s, size_t n) {
  if (n == 0) {
    *r = VX_RUNEERROR;
    return 0;
  }
  const unsigned char *u = (const unsigned char *)s;
  unsigned c = u[0];
  *r = VX_RUNEERROR;
  if (c < VX_RUNESELF) {
    *r = c;
    return 1;
  }
  size_t len;
  vx_rune v, min;
  if (c >= 0xc2 && c <= 0xdf)
    len = 2, v = c & 0x1f, min = 0x80;
  else if ((c & 0xf0) == 0xe0)
    len = 3, v = c & 0x0f, min = 0x800;
  else if (c >= 0xf0 && c <= 0xf4)
    len = 4, v = c & 0x07, min = 0x10000;
  else
    return 1; // a continuation byte, 0xc0, 0xc1 or 0xf5 and up: never a rune's start
  if (n < len) return 1;
  for (size_t k = 1; k < len; k++) {
    if ((u[k] & 0xc0) != 0x80) return 1;
    v = v << 6 | (u[k] & 0x3f);
  }
  if (v < min || v > VX_RUNEMAX || (v >= 0xd800 && v <= 0xdfff)) return 1; // overlong, too big, a surrogate
  *r = v;
  return len;
}

// The bytes rune r takes; a rune that cannot be encoded takes VX_RUNEERROR's 3.
[[maybe_unused]] static size_t vx_runelen(vx_rune r) {
  if (r < 0x80) return 1;
  if (r < 0x800) return 2;
  if (r > VX_RUNEMAX || (r >= 0xd800 && r <= 0xdfff)) return 3;
  return r < 0x10000 ? 3 : 4;
}

// Encodes r at s (VX_UTFMAX bytes of room). Returns the bytes it wrote. A rune
// that cannot be encoded (a surrogate, or above VX_RUNEMAX) is VX_RUNEERROR.
[[maybe_unused]] static size_t vx_runetochar(char *s, vx_rune r) {
  if (r > VX_RUNEMAX || (r >= 0xd800 && r <= 0xdfff)) r = VX_RUNEERROR;
  if (r < 0x80) {
    s[0] = (char)r;
    return 1;
  }
  if (r < 0x800) {
    s[0] = (char)(0xc0 | r >> 6);
    s[1] = (char)(0x80 | (r & 0x3f));
    return 2;
  }
  if (r < 0x10000) {
    s[0] = (char)(0xe0 | r >> 12);
    s[1] = (char)(0x80 | (r >> 6 & 0x3f));
    s[2] = (char)(0x80 | (r & 0x3f));
    return 3;
  }
  s[0] = (char)(0xf0 | r >> 18);
  s[1] = (char)(0x80 | (r >> 12 & 0x3f));
  s[2] = (char)(0x80 | (r >> 6 & 0x3f));
  s[3] = (char)(0x80 | (r & 0x3f));
  return 4;
}

// Whether the n bytes at s hold the whole of the rune that starts there (or
// enough to know it is a bad byte), as a reader of a stream must know before
// it decodes.
[[maybe_unused]] static bool vx_fullrune(const char *s, size_t n) {
  if (n == 0) return false;
  unsigned c = (unsigned char)s[0];
  size_t len = 1;
  if (c >= 0xc2 && c <= 0xdf)
    len = 2;
  else if ((c & 0xf0) == 0xe0)
    len = 3;
  else if (c >= 0xf0 && c <= 0xf4)
    len = 4;
  for (size_t k = 1; k < len && k < n; k++)
    if (((unsigned char)s[k] & 0xc0) != 0x80) return true; // bad already: one byte
  return n >= len;
}

// The runes in s (n bytes); each bad byte counts as one.
[[maybe_unused]] static size_t vx_utflen(const char *s, size_t n) {
  size_t runes = 0;
  vx_rune r;
  for (size_t at = 0; at < n; runes++) at += vx_chartorune(&r, s + at, n - at);
  return runes;
}

// The first rune r in s (n bytes), or null; vx_utfrrune, the last.
[[maybe_unused]] static const char *vx_utfrune(const char *s, size_t n, vx_rune r) {
  vx_rune c;
  for (size_t at = 0, len; at < n; at += len) {
    len = vx_chartorune(&c, s + at, n - at);
    if (c == r && (r != VX_RUNEERROR || len == 3)) return s + at;
  }
  return nullptr;
}

[[maybe_unused]] static const char *vx_utfrrune(const char *s, size_t n, vx_rune r) {
  const char *last = nullptr;
  vx_rune c;
  for (size_t at = 0, len; at < n; at += len) {
    len = vx_chartorune(&c, s + at, n - at);
    if (c == r && (r != VX_RUNEERROR || len == 3)) last = s + at;
  }
  return last;
}

// Whether s (n bytes) is all valid UTF-8.
[[maybe_unused]] static bool vx_utf_valid(const char *s, size_t n) {
  vx_rune r;
  for (size_t at = 0, len; at < n; at += len) {
    len = vx_chartorune(&r, s + at, n - at);
    if (r == VX_RUNEERROR && len != 3) return false; // a bad byte (U+FFFD itself takes 3)
  }
  return true;
}

// The longest prefix of s (n bytes) of at most max bytes that ends at a rune
// boundary: where a bounded copy of text is cut. A bad byte is a rune of its own.
[[maybe_unused]] static size_t vx_utf_cut(const char *s, size_t n, size_t max) {
  if (n <= max) return n;
  size_t at = 0;
  vx_rune r;
  for (size_t len; at < max; at += len) {
    len = vx_chartorune(&r, s + at, n - at);
    if (at + len > max) break;
  }
  return at;
}

// Where the rune before offset at in s starts: at - 1 for a bad byte, or at
// 0 for at 0. What a line editor's erase takes back.
[[maybe_unused]] static size_t vx_utf_back(const char *s, size_t at) {
  if (at == 0) return 0;
  vx_rune r;
  for (size_t back = 1; back <= VX_UTFMAX && back <= at; back++) {
    size_t start = at - back;
    if (((unsigned char)s[start] & 0xc0) == 0x80) continue; // a continuation byte: further back
    size_t len = vx_chartorune(&r, s + start, back);
    return start + len == at && (r != VX_RUNEERROR || len == 3) ? start : at - 1;
  }
  return at - 1;
}

// Whether s (n bytes) may be a name, a path component (ADR-0013, as Plan 9's
// validname, made strict about UTF-8): valid UTF-8, with no control character
// (0x00-0x1f, 0x7f). The rest (".", "..", '/') is the caller's to refuse.
[[maybe_unused]] static bool vx_utf_name(const char *s, size_t n) {
  for (size_t i = 0; i < n; i++)
    if ((unsigned char)s[i] < 0x20 || s[i] == 0x7f) return false;
  return vx_utf_valid(s, n);
}
