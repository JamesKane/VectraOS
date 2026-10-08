// vx-text: slices and formatting (09 §5.3, ADR-0004 libvx v0, M6 step
// 6e4c2). Pure: no kernel entry and no memory of its own, so it is
// unity-built through base.c, exported by libvx, and host-tested against the
// C library's printf (tests/host/text_test.c). What needs an arena or an
// output, vx_fmt, vx_str_cat and vx_printf, is vx-rt's (lib/vx-rt/arena.c).
//
// Formatting takes printf's verbs, so clang checks each format string:
// flags "-+ #0", width and precision (either may be *), lengths hh h l ll j z
// t L, and d i u o x X b B c s p f F e E g G a A %. Floating point is exact:
// a double's value is expanded to all its decimal digits, then rounded half
// to even, as glibc does. %Lf and the like take a long double and print it
// as a double. %lc and %ls write runes as UTF-8. %n writes nothing. A width
// counts bytes, as C's does.

#pragma once

#include <stdarg.h>
#include <stdckdint.h>

// Unity-built (static) everywhere but libvx itself (VX_RT_LIBC), which
// exports these (ADR-0004).
#ifndef VX_RT_LIBC
#ifndef VX_UNITY
#define VX_UNITY
#endif
#endif
#include "../../abi/vx/fmt.h"
#include "../../abi/vx/str.h"
#include "../../abi/vx/utf.h"

// --- Slices ---

VX_API vx_str vx_cstr(const char *s) {
  size_t n = 0;
  while (s[n]) n++;
  return (vx_str){s, n};
}

VX_API bool vx_str_eq(vx_str a, vx_str b) {
  return a.len == b.len && (a.len == 0 || __builtin_memcmp(a.ptr, b.ptr, a.len) == 0);
}

VX_API bool vx_str_prefix(vx_str s, vx_str prefix) {
  return s.len >= prefix.len && vx_str_eq((vx_str){s.ptr, prefix.len}, prefix);
}

VX_API bool vx_str_suffix(vx_str s, vx_str suffix) {
  return s.len >= suffix.len && vx_str_eq((vx_str){s.ptr + s.len - suffix.len, suffix.len}, suffix);
}

VX_API vx_str vx_str_cut(vx_str s, size_t from, size_t to) {
  if (to > s.len) to = s.len;
  if (from > to) from = to;
  return (vx_str){s.ptr ? s.ptr + from : nullptr, to - from};
}

VX_API int64_t vx_str_find(vx_str s, vx_str needle) {
  if (needle.len == 0) return 0;
  for (size_t i = 0; i + needle.len <= s.len; i++)
    if (s.ptr[i] == needle.ptr[0] && __builtin_memcmp(s.ptr + i, needle.ptr, needle.len) == 0)
      return (int64_t)i;
  return -1;
}

VX_API bool vx_str_split(vx_str *s, vx_str sep, vx_str *field) {
  if (!s->ptr) return false;
  int64_t at = sep.len ? vx_str_find(*s, sep) : -1;
  if (at < 0) {
    *field = *s;
    *s = (vx_str){};
  } else {
    *field = (vx_str){s->ptr, (size_t)at};
    *s = (vx_str){s->ptr + at + sep.len, s->len - (size_t)at - sep.len};
  }
  return true;
}

VX_API bool vx_str_u64(vx_str s, uint64_t *out) {
  uint64_t v = 0, base = 10;
  size_t i = 0;
  if (s.len > 2 && s.ptr[0] == '0' && (s.ptr[1] == 'x' || s.ptr[1] == 'X')) base = 16, i = 2;
  if (i == s.len) return false;
  for (; i < s.len; i++) {
    char c = s.ptr[i];
    uint64_t d = 16; // not a digit
    if (c >= '0' && c <= '9')
      d = (uint64_t)c - '0';
    else if (c >= 'a' && c <= 'f')
      d = (uint64_t)c - 'a' + 10;
    else if (c >= 'A' && c <= 'F')
      d = (uint64_t)c - 'A' + 10;
    if (d >= base || ckd_mul(&v, v, base) || ckd_add(&v, v, d)) return false;
  }
  *out = v;
  return true;
}

VX_API bool vx_str_i64(vx_str s, int64_t *out) {
  bool neg = s.len && s.ptr[0] == '-';
  if (s.len && (s.ptr[0] == '-' || s.ptr[0] == '+')) s = vx_str_cut(s, 1, s.len);
  uint64_t v;
  if (!vx_str_u64(s, &v) || v > (uint64_t)INT64_MAX + neg) return false;
  *out = neg ? (int64_t)(0 - v) : (int64_t)v;
  return true;
}

// --- Formatting: the output ---

// Where formatted bytes go: the first cap into buf, and the VX_UTFMAX after
// those into over, where a cut at a rune's boundary looks. len counts all.
typedef struct text_out {
  char *buf;
  size_t cap, len;
  char over[VX_UTFMAX];
} text_out;

static void text_put(text_out *o, const char *s, size_t n) {
  for (size_t i = 0; i < n; i++, o->len++) {
    if (o->len < o->cap) {
      o->buf[o->len] = s[i];
    } else if (o->len - o->cap < VX_UTFMAX) {
      o->over[o->len - o->cap] = s[i];
    } else {
      o->len += n - i;
      return;
    }
  }
}

static void text_pad(text_out *o, char c, size_t n) {
  for (size_t i = 0; i < n; i++) text_put(o, &c, 1);
}

// --- Formatting: a conversion ---

typedef struct text_spec {
  bool left, plus, space, alt, zero, has_prec;
  size_t width, prec;
  char conv;
} text_spec;

// A conversion's sign or prefix, zeros, body and trailing zeros, padded to
// its width: what every numeric conversion comes to.
static void text_emit(text_out *o, const text_spec *sp, const char *pre, size_t pre_n, size_t zeros,
                      const char *body, size_t body_n, size_t tail_zeros, bool zero_pad) {
  size_t n = pre_n + zeros + body_n + tail_zeros;
  size_t pad = sp->width > n ? sp->width - n : 0;
  if (!sp->left && !zero_pad) text_pad(o, ' ', pad);
  text_put(o, pre, pre_n);
  if (!sp->left && zero_pad) text_pad(o, '0', pad);
  text_pad(o, '0', zeros);
  text_put(o, body, body_n);
  text_pad(o, '0', tail_zeros);
  if (sp->left) text_pad(o, ' ', pad);
}

static void text_int(text_out *o, const text_spec *sp, uint64_t v, bool neg) {
  char c = sp->conv;
  unsigned base = 10;
  if (c == 'o') base = 8;
  if (c == 'x' || c == 'X' || c == 'p') base = 16;
  if (c == 'b' || c == 'B') base = 2;
  const char *digits = c == 'X' ? "0123456789ABCDEF" : "0123456789abcdef";
  char body[64];
  size_t n = 0;
  for (uint64_t u = v; u; u /= base) body[sizeof body - ++n] = digits[u % base];
  size_t prec = sp->has_prec ? sp->prec : 1;
  if (c == 'p') prec = 1;
  size_t zeros = prec > n ? prec - n : 0;
  if (c == 'o' && sp->alt && zeros == 0) zeros = 1; // its first digit a 0
  char pre[2];
  size_t pre_n = 0;
  if (c == 'd' || c == 'i') {
    if (neg)
      pre[pre_n++] = '-';
    else if (sp->plus)
      pre[pre_n++] = '+';
    else if (sp->space)
      pre[pre_n++] = ' ';
  } else if ((sp->alt && v && (c == 'x' || c == 'X' || c == 'b' || c == 'B')) || c == 'p') {
    pre[pre_n++] = '0';
    pre[pre_n++] = c == 'p' ? 'x' : c;
  }
  text_emit(o, sp, pre, pre_n, zeros, body + sizeof body - n, n, 0, sp->zero && !sp->left && !sp->has_prec);
}

// --- Formatting: floating point ---
//
// A double is m * 2^e. Its exact decimal digits are those of m * 2^e when e
// >= 0, and of m * 5^-e, with the point -e places from the right, when e <
// 0: at most 767 digits, made in base 10^9 limbs. A number is held as digits
// d (no leading or trailing zeros; none for zero) and point: the value is
// 0.d * 10^point.

typedef struct text_dec {
  char d[800];
  int n, point;
} text_dec;

static void text_big_mul(uint32_t *limb, int *n, uint32_t by) {
  uint64_t carry = 0;
  for (int i = 0; i < *n; i++) {
    uint64_t t = (uint64_t)limb[i] * by + carry;
    limb[i] = (uint32_t)(t % 1'000'000'000);
    carry = t / 1'000'000'000;
  }
  while (carry) {
    limb[(*n)++] = (uint32_t)(carry % 1'000'000'000);
    carry /= 1'000'000'000;
  }
}

static void text_decimal(double x, text_dec *r) {
  uint64_t bits;
  __builtin_memcpy(&bits, &x, sizeof bits);
  uint64_t m = bits & ((1ull << 52) - 1);
  int exp = (int)(bits >> 52 & 0x7ff);
  if (exp)
    m |= 1ull << 52, exp -= 1075;
  else
    exp = -1074;
  r->n = r->point = 0;
  if (!m) return;
  uint32_t limb[90];
  int nl = 0;
  for (uint64_t u = m; u; u /= 1'000'000'000) limb[nl++] = (uint32_t)(u % 1'000'000'000);
  for (int k = exp; k > 0; k -= 29) text_big_mul(limb, &nl, 1u << (k < 29 ? k : 29));
  for (int k = -exp; k > 0; k -= 13) {
    uint32_t p = 1;
    for (int i = 0; i < (k < 13 ? k : 13); i++) p *= 5;
    text_big_mul(limb, &nl, p);
  }
  // The limbs as digits, the top one without its leading zeros.
  char top[10];
  int tn = 0;
  for (uint32_t u = limb[nl - 1]; u; u /= 10) top[tn++] = (char)('0' + u % 10);
  for (int i = 0; i < tn; i++) r->d[r->n++] = top[tn - 1 - i];
  for (int i = nl - 2; i >= 0; i--)
    for (int k = 8; k >= 0; k--) {
      uint32_t p = 1;
      for (int j = 0; j < k; j++) p *= 10;
      r->d[r->n++] = (char)('0' + limb[i] / p % 10);
    }
  r->point = r->n + (exp < 0 ? exp : 0);
  while (r->n && r->d[r->n - 1] == '0') r->n--;
}

// Rounds r to its first keep digits, half to even.
static void text_round(text_dec *r, int keep) {
  if (keep >= r->n) return;
  bool up;
  if (keep < 0)
    up = false;
  else if (keep == 0)
    up = r->d[0] > '5' || (r->d[0] == '5' && r->n > 1);
  else
    up = r->d[keep] > '5' || (r->d[keep] == '5' && (r->n > keep + 1 || (r->d[keep - 1] - '0') % 2));
  r->n = keep < 0 ? 0 : keep;
  if (up) {
    int i = r->n - 1;
    while (i >= 0 && r->d[i] == '9') i--;
    if (i < 0) {
      r->d[0] = '1';
      r->n = 1;
      r->point++;
    } else {
      r->d[i]++;
      r->n = i + 1;
    }
  }
  while (r->n && r->d[r->n - 1] == '0') r->n--;
  if (!r->n) r->point = 0;
}

static char text_digit(const text_dec *r, int i) { return i >= 0 && i < r->n ? r->d[i] : '0'; }

// The digits of r from position from, count of them, into o: written a piece
// at a time, since %.500f is allowed.
static void text_digits(text_out *o, const text_dec *r, int from, size_t count) {
  for (size_t i = 0; i < count; i++) {
    char c = text_digit(r, from + (int)i);
    text_put(o, &c, 1);
  }
}

// An exponent: letter, its sign, and at least min digits.
static size_t text_exp(char *buf, int e, char letter, size_t min) {
  size_t n = 0;
  buf[n++] = letter;
  buf[n++] = e < 0 ? '-' : '+';
  unsigned u = (unsigned)(e < 0 ? -e : e);
  char tmp[8];
  size_t t = 0;
  do tmp[t++] = (char)('0' + u % 10);
  while (u /= 10);
  while (t < min) tmp[t++] = '0';
  while (t) buf[n++] = tmp[--t];
  return n;
}

static void text_float(text_out *o, const text_spec *sp, double x) {
  char c = sp->conv;
  bool upper = c == 'F' || c == 'E' || c == 'G' || c == 'A';
  char pre[4]; // the sign, and %a's 0x
  size_t pre_n = 0;
  if (__builtin_signbit(x))
    pre[pre_n++] = '-';
  else if (sp->plus)
    pre[pre_n++] = '+';
  else if (sp->space)
    pre[pre_n++] = ' ';
  if (__builtin_isnan(x) || __builtin_isinf(x)) {
    static const char *const words[2][2] = {{"inf", "INF"}, {"nan", "NAN"}};
    const char *w = words[__builtin_isnan(x) ? 1 : 0][upper ? 1 : 0];
    text_emit(o, sp, pre, pre_n, 0, w, 3, 0, false);
    return;
  }
  if (x < 0) x = -x;
  bool zero_pad = sp->zero && !sp->left;

  if (c == 'a' || c == 'A') {
    uint64_t bits;
    __builtin_memcpy(&bits, &x, sizeof bits);
    uint64_t frac = bits & ((1ull << 52) - 1);
    int be = (int)(bits >> 52 & 0x7ff);
    unsigned lead = be ? 1 : 0;
    int e = be - 1023; // a subnormal's is -1022, and zero's 0
    if (!be) e = frac ? -1022 : 0;
    int nd = 13;                         // hex digits after the point
    if (sp->has_prec && sp->prec < 13) { // rounded half to even, the lead digit included
      int shift = (13 - (int)sp->prec) * 4;
      uint64_t all = (uint64_t)lead << 52 | frac;
      uint64_t rem = all & ((1ull << shift) - 1), half = 1ull << (shift - 1);
      all >>= shift;
      if (rem > half || (rem == half && (all & 1))) all++;
      nd = (int)sp->prec;
      lead = (unsigned)(all >> (nd * 4)); // 2 when it carries: 0x2p+0, as glibc
      frac = all & ((1ull << (nd * 4)) - 1);
    } else if (!sp->has_prec) {
      while (nd && !(frac & 15)) frac >>= 4, nd--;
    }
    const char *hex = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    pre[pre_n++] = '0';
    pre[pre_n++] = upper ? 'X' : 'x';
    char body[16];
    size_t n = 0;
    body[n++] = hex[lead];
    size_t extra = sp->has_prec && sp->prec > 13 ? sp->prec - 13 : 0;
    if (nd || extra || sp->alt) body[n++] = '.';
    for (int i = nd - 1; i >= 0; i--) body[n++] = hex[frac >> (i * 4) & 15];
    char ex[16];
    size_t en = text_exp(ex, e, upper ? 'P' : 'p', 1);
    size_t sz = pre_n + n + extra + en;
    size_t pad = sp->width > sz ? sp->width - sz : 0;
    if (!sp->left && !zero_pad) text_pad(o, ' ', pad);
    text_put(o, pre, pre_n);
    if (!sp->left && zero_pad) text_pad(o, '0', pad);
    text_put(o, body, n);
    text_pad(o, '0', extra);
    text_put(o, ex, en);
    if (sp->left) text_pad(o, ' ', pad);
    return;
  }

  text_dec r;
  text_decimal(x, &r);
  int prec = 6;
  if (sp->has_prec) prec = sp->prec > 100'000 ? 100'000 : (int)sp->prec;
  bool fixed = c == 'f' || c == 'F';
  bool strip = false;
  if (c == 'g' || c == 'G') {
    if (prec == 0) prec = 1;
    text_round(&r, prec);
    int xe = r.n ? r.point - 1 : 0;
    fixed = prec > xe && xe >= -4;
    prec = fixed ? prec - 1 - xe : prec - 1;
    strip = !sp->alt;
  }
  if (fixed) {
    text_round(&r, r.point + prec);
    if (strip && prec > r.n - r.point) prec = r.n - r.point > 0 ? r.n - r.point : 0;
    size_t int_n = r.point > 0 ? (size_t)r.point : 1;
    bool dot = prec > 0 || sp->alt;
    size_t sz = pre_n + int_n + dot + (size_t)prec;
    size_t pad = sp->width > sz ? sp->width - sz : 0;
    if (!sp->left && !zero_pad) text_pad(o, ' ', pad);
    text_put(o, pre, pre_n);
    if (!sp->left && zero_pad) text_pad(o, '0', pad);
    if (r.point > 0)
      text_digits(o, &r, 0, int_n);
    else
      text_put(o, "0", 1);
    if (dot) text_put(o, ".", 1);
    text_digits(o, &r, r.point, (size_t)prec);
    if (sp->left) text_pad(o, ' ', pad);
  } else {
    text_round(&r, prec + 1);
    if (strip && prec > r.n - 1) prec = r.n > 1 ? r.n - 1 : 0;
    char ex[16];
    size_t en = text_exp(ex, r.n ? r.point - 1 : 0, upper ? 'E' : 'e', 2);
    bool dot = prec > 0 || sp->alt;
    size_t sz = pre_n + 1 + dot + (size_t)prec + en;
    size_t pad = sp->width > sz ? sp->width - sz : 0;
    if (!sp->left && !zero_pad) text_pad(o, ' ', pad);
    text_put(o, pre, pre_n);
    if (!sp->left && zero_pad) text_pad(o, '0', pad);
    text_digits(o, &r, 0, 1);
    if (dot) text_put(o, ".", 1);
    text_digits(o, &r, 1, (size_t)prec);
    text_put(o, ex, en);
    if (sp->left) text_pad(o, ' ', pad);
  }
}

// --- Formatting: strings ---

static void text_string(text_out *o, const text_spec *sp, const char *s) {
  size_t n = 0;
  if (s)
    while ((!sp->has_prec || n < sp->prec) && s[n]) n++;
  text_emit(o, sp, "", 0, 0, s ? s : "", n, 0, false);
}

// Runes as UTF-8, no more than the precision's bytes and no rune cut.
static void text_runes(text_out *o, const text_spec *sp, const uint32_t *w, size_t count) {
  size_t n = 0;
  char tmp[VX_UTFMAX];
  for (size_t i = 0; i < count; i++) {
    size_t k = vx_runetochar(tmp, (vx_rune)w[i]);
    if (sp->has_prec && n + k > sp->prec) break;
    n += k;
  }
  size_t pad = sp->width > n ? sp->width - n : 0;
  if (!sp->left) text_pad(o, ' ', pad);
  for (size_t i = 0, done = 0; done < n; i++) {
    size_t k = vx_runetochar(tmp, (vx_rune)w[i]);
    text_put(o, tmp, k);
    done += k;
  }
  if (sp->left) text_pad(o, ' ', pad);
}

// --- Formatting: the engine ---

// An integer argument of the length len ('H' hh, 'q' ll), as C promotes it.
static int64_t text_signed(va_list *ap, char len) {
  // long, long long and the rest are distinct types to va_arg, though the same size
  // NOLINTBEGIN(bugprone-branch-clone)
  switch (len) {
  case 'l': return va_arg(*ap, long);
  case 'q': return va_arg(*ap, long long);
  case 'j': return va_arg(*ap, intmax_t);
  case 'z':
  case 't': return va_arg(*ap, ptrdiff_t);
  case 'H': return (int8_t)(uint8_t)va_arg(*ap, int);
  case 'h': return (short)va_arg(*ap, int);
  default: return va_arg(*ap, int);
  }
  // NOLINTEND(bugprone-branch-clone)
}

static uint64_t text_unsigned(va_list *ap, char len) {
  // long, long long and the rest are distinct types to va_arg, though the same size
  // NOLINTBEGIN(bugprone-branch-clone)
  switch (len) {
  case 'l': return va_arg(*ap, unsigned long);
  case 'q': return va_arg(*ap, unsigned long long);
  case 'j': return va_arg(*ap, uintmax_t);
  case 'z':
  case 't': return va_arg(*ap, size_t);
  case 'H': return (unsigned char)va_arg(*ap, unsigned);
  case 'h': return (unsigned short)va_arg(*ap, unsigned);
  default: return va_arg(*ap, unsigned);
  }
  // NOLINTEND(bugprone-branch-clone)
}

// Formats into o; returns how many bytes the whole output is.
static size_t text_vformat(text_out *o, const char *fmt, va_list args) {
  va_list ap; // a local one, whose address the integer readers take
  va_copy(ap, args);
  for (const char *f = fmt; *f;) {
    if (*f != '%') {
      const char *start = f;
      while (*f && *f != '%') f++;
      text_put(o, start, (size_t)(f - start));
      continue;
    }
    f++;
    text_spec sp = {};
    for (;; f++) {
      if (*f == '-')
        sp.left = true;
      else if (*f == '+')
        sp.plus = true;
      else if (*f == ' ')
        sp.space = true;
      else if (*f == '#')
        sp.alt = true;
      else if (*f == '0')
        sp.zero = true;
      else
        break;
    }
    if (*f == '*') {
      int w = va_arg(ap, int);
      if (w < 0) sp.left = true, w = -w;
      sp.width = (size_t)w;
      f++;
    } else {
      while (*f >= '0' && *f <= '9') sp.width = sp.width * 10 + (size_t)(*f++ - '0');
    }
    if (*f == '.') {
      f++;
      sp.has_prec = true;
      if (*f == '*') {
        int p = va_arg(ap, int);
        sp.has_prec = p >= 0;
        sp.prec = p >= 0 ? (size_t)p : 0;
        f++;
      } else {
        while (*f >= '0' && *f <= '9') sp.prec = sp.prec * 10 + (size_t)(*f++ - '0');
      }
    }
    // The length: 'H' hh, 'h', 'l', 'q' ll, 'j', 'z', 't', 'L'.
    char len = 0;
    if (f[0] == 'h' && f[1] == 'h')
      len = 'H', f += 2;
    else if (f[0] == 'l' && f[1] == 'l')
      len = 'q', f += 2;
    else if (*f == 'h' || *f == 'l' || *f == 'j' || *f == 'z' || *f == 't' || *f == 'L')
      len = *f++;
    sp.conv = *f;
    if (!*f) break;
    f++;
    switch (sp.conv) {
    case 'd':
    case 'i': {
      int64_t v = text_signed(&ap, len);
      text_int(o, &sp, v < 0 ? 0 - (uint64_t)v : (uint64_t)v, v < 0);
      break;
    }
    case 'u':
    case 'o':
    case 'x':
    case 'X':
    case 'b':
    case 'B': {
      uint64_t v = text_unsigned(&ap, len);
      text_int(o, &sp, v, false);
      break;
    }
    case 'p': text_int(o, &sp, (uintptr_t)va_arg(ap, void *), false); break;
    case 'c':
      if (len == 'l') {
        uint32_t w = va_arg(ap, unsigned);
        text_runes(o, &sp, &w, 1);
      } else {
        char ch = (char)va_arg(ap, int);
        sp.has_prec = false;
        text_emit(o, &sp, "", 0, 0, &ch, 1, 0, false);
      }
      break;
    case 's':
      if (len == 'l') {
        const uint32_t *w = (const uint32_t *)va_arg(ap, const void *);
        size_t count = 0;
        while (w && w[count]) count++;
        text_runes(o, &sp, w, count);
      } else {
        text_string(o, &sp, va_arg(ap, const char *));
      }
      break;
    case 'f':
    case 'F':
    case 'e':
    case 'E':
    case 'g':
    case 'G':
    case 'a':
    case 'A': text_float(o, &sp, len == 'L' ? (double)va_arg(ap, long double) : va_arg(ap, double)); break;
    case 'n':
      (void)va_arg(ap, void *); // writes nothing
      break;
    case '%': text_put(o, "%", 1); break;
    default: // not a verb: written as it is
      text_put(o, "%", 1);
      text_put(o, &sp.conv, 1);
      break;
    }
  }
  va_end(ap);
  return o->len;
}

// The length of the output in o, cut at a rune's boundary to its buffer.
static size_t text_cut(const text_out *o) {
  if (o->len <= o->cap) return o->len;
  size_t at = 0;
  vx_rune r;
  while (at < o->cap) {
    char tmp[2 * VX_UTFMAX];
    const char *p = o->buf + at;
    size_t n = o->cap - at;
    if (n < VX_UTFMAX) { // the rune may run past the buffer: over has the rest
      size_t over = o->len - o->cap < VX_UTFMAX ? o->len - o->cap : VX_UTFMAX;
      __builtin_memcpy(tmp, p, n);
      __builtin_memcpy(tmp + n, o->over, over);
      p = tmp;
      n += over;
    }
    size_t len = vx_chartorune(&r, p, n);
    if (at + len > o->cap) break;
    at += len;
  }
  return at;
}

VX_API size_t vx_vbfmt(vx_bytes buf, const char *fmt, va_list ap) {
  text_out o = {.buf = (char *)buf.ptr, .cap = buf.ptr ? buf.len : 0};
  text_vformat(&o, fmt, ap);
  return text_cut(&o);
}

VX_API size_t vx_bfmt(vx_bytes buf, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  size_t n = vx_vbfmt(buf, fmt, ap);
  va_end(ap);
  return n;
}

// The whole output's length, nothing written: for vx_fmt and vx_printf.
[[maybe_unused]] static size_t vx_vfmt_len(const char *fmt, va_list ap) {
  text_out o = {};
  return text_vformat(&o, fmt, ap);
}
