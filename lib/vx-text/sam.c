// vx-text's command language: sam's, after 9front's sam/cmd.c (the parser),
// address.c (addresses) and xec.c (the commands), with dot as many
// selections (text.h). A command line is parsed whole, then run once for
// each selection. Every run reads the text as it was; changes are collected
// with where they came from, sorted, checked for overlap ("changes not in
// sequence"), and made from the last to the first, so no offset moves under
// another. The new dot is each run's result mapped through the changes:
// either an old position with a side to stick to, or the start or end of
// one change's new text.

#pragma once

// Included by text.c, after regex.c.

enum : uint32_t {
  VT_NEST = 64,         // commands within commands, braces and loops
  VT_SELECT = 1,        // the command x, y, g and v run when given none
  VT_NONE = UINT32_MAX, // no regular expression
};

typedef struct vt_mem {
  struct vt_mem *next;
  size_t used, cap;
  char bytes[];
} vt_mem;

typedef struct vt_addr {
  int32_t type; // '#', 'l', '/', '?', '.', '$', '+', '-', ',', ';'
  uint64_t num;
  uint32_t re;
  struct vt_addr *left, *next;
} vt_addr;

typedef struct vt_cmd {
  int32_t c;
  vt_addr *addr, *dest;
  uint32_t re;
  struct vt_cmd *sub, *next;
  vx_str text;
  int64_t num;
  bool global;
} vt_cmd;

typedef struct vt_change {
  uint64_t p0, p1;
  const char *s;
  uint64_t n;
  uint32_t seq;
} vt_change;

enum : uint8_t { VT_POS, VT_CSTART, VT_CEND };

typedef struct vt_end {
  uint8_t kind;
  uint32_t bias; // a position's
  uint64_t q;    // a position, or a change's seq
} vt_end;

typedef struct vt_result {
  vt_end a, b;
} vt_result;

typedef struct vt_run {
  vx_text *t;
  const vx_text_io *io;
  vt_mem *mem;
  vt_rx *rx;
  size_t nrx, caprx;
  vt_change *ch;
  size_t nch, capch;
  vt_result *res;
  size_t nres, capres;
  vx_text_range dot; // the selection a run has; '.'
  uint32_t nest;
  char *error;
  size_t errlen;
  bool failed;
  // the parser's
  const char *in;
  size_t inlen, at, last;
  uint32_t depth;
  bool closed;
} vt_run;

// --- Errors and memory ---

static void vt_put(char *buf, size_t cap, size_t *len, const char *s, size_t n) {
  for (size_t i = 0; i < n && *len + 1 < cap; i++) buf[(*len)++] = s[i];
  if (cap) buf[*len] = 0;
}

static size_t vt_cstrlen(const char *s) {
  size_t n = 0;
  while (s[n]) n++;
  return n;
}

// Sets the error, sam's words and what they name, once; always false.
static bool vt_fail2(vt_run *r, const char *what, const char *detail, size_t n) {
  if (r->failed) return false;
  r->failed = true;
  size_t len = 0;
  vt_put(r->error, r->errlen, &len, what, vt_cstrlen(what));
  if (detail) {
    vt_put(r->error, r->errlen, &len, " `", 2);
    vt_put(r->error, r->errlen, &len, detail, n);
    vt_put(r->error, r->errlen, &len, "'", 1);
  }
  return false;
}

static bool vt_fail(vt_run *r, const char *what) { return vt_fail2(r, what, nullptr, 0); }

static void *vt_mem_alloc(vt_run *r, size_t n) {
  n = (n + 7) & ~(size_t)7;
  vt_mem *m = r->mem;
  if (!m || m->cap - m->used < n) {
    size_t cap = n > 16384 ? n : 16384;
    m = vt_alloc(sizeof *m + cap);
    if (!m) return vt_fail(r, "out of memory"), nullptr;
    *m = (vt_mem){.next = r->mem, .cap = cap};
    r->mem = m;
  }
  void *p = m->bytes + m->used;
  m->used += n;
  __builtin_memset(p, 0, n);
  return p;
}

// The text of range a, in the run's memory.
static vx_str vt_text_of(vt_run *r, vx_text_range a) {
  char *p = vt_mem_alloc(r, a.p1 - a.p0);
  if (!p) return (vx_str){};
  return (vx_str){p, vx_text_read(r->t, a.p0, p, a.p1 - a.p0)};
}

// --- Parsing: sam's cmd.c, a rune at a time over the input ---

static int32_t vt_getc(vt_run *r) {
  r->last = r->at;
  if (r->at >= r->inlen) return -1;
  vx_rune c;
  r->at += vx_chartorune(&c, r->in + r->at, r->inlen - r->at);
  return (int32_t)c;
}

static void vt_ungetc(vt_run *r) { r->at = r->last; }

static int32_t vt_peek(vt_run *r) {
  if (r->at >= r->inlen) return -1;
  vx_rune c;
  vx_chartorune(&c, r->in + r->at, r->inlen - r->at);
  return (int32_t)c;
}

static int32_t vt_skipbl(vt_run *r) {
  int32_t c = 0;
  do c = vt_getc(r);
  while (c == ' ' || c == '\t');
  if (c >= 0) vt_ungetc(r);
  return c;
}

static bool vt_atnl(vt_run *r) {
  vt_skipbl(r);
  return vt_getc(r) == '\n' || vt_fail(r, "newline expected");
}

// A string being built: at most what is left of the input.
typedef struct vt_sbuf {
  char *p;
  size_t n;
} vt_sbuf;

static bool vt_sbuf_new(vt_run *r, vt_sbuf *s) {
  s->n = 0;
  s->p = vt_mem_alloc(r, r->inlen - r->at + 1);
  return s->p != nullptr;
}

static void vt_sbuf_byte(vt_sbuf *s, char c) { s->p[s->n++] = c; }
static void vt_sbuf_raw(vt_run *r, vt_sbuf *s) { // the rune just read, as its bytes
  for (size_t i = r->last; i < r->at; i++) s->p[s->n++] = r->in[i];
}

static int64_t vt_getnum(vt_run *r, int signok) {
  int64_t n = 0, sign = 1;
  if (signok > 1 && vt_peek(r) == '-') {
    sign = -1;
    vt_getc(r);
  }
  int32_t c = vt_peek(r);
  if (c < '0' || c > '9') return sign; // no number is 1
  while ((c = vt_getc(r)) >= '0' && c <= '9')
    if (n < INT64_MAX / 10 - 10) n = n * 10 + (c - '0');
  vt_ungetc(r);
  return sign * n;
}

static bool vt_okdelim(vt_run *r, int32_t c) {
  if (c == '\\' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) {
    char b = (char)c;
    return vt_fail2(r, "bad delimiter", &b, 1);
  }
  return true;
}

// Compiles a pattern into the run's list, or the last one if it is empty.
static uint32_t vt_compile(vt_run *r, const char *p, size_t n) {
  vx_text *t = r->t;
  if (n) {
    char *keep = vt_alloc(n);
    if (!keep) return vt_fail(r, "out of memory"), VT_NONE;
    __builtin_memcpy(keep, p, n);
    vt_free(t->lastpat);
    t->lastpat = keep, t->lastpatlen = n;
  } else if (!t->lastpat) {
    return vt_fail(r, "pattern"), VT_NONE;
  }
  if (!vt_grow((void **)&r->rx, &r->caprx, r->nrx + 1, sizeof *r->rx))
    return vt_fail(r, "out of memory"), VT_NONE;
  const char *err = vt_rx_compile(&r->rx[r->nrx], t->lastpat, t->lastpatlen);
  r->nrx++;
  if (err) return vt_fail(r, err), VT_NONE;
  return (uint32_t)r->nrx - 1;
}

static uint32_t vt_getregexp(vt_run *r, int32_t delim) {
  vt_sbuf s;
  if (!vt_sbuf_new(r, &s)) return VT_NONE;
  int32_t c = 0;
  for (;;) {
    c = vt_getc(r);
    if (c == '\\') { // the escaped rune is kept, read raw below
      if (vt_peek(r) == delim) {
        vt_getc(r);
      } else if (vt_peek(r) == '\\') {
        vt_sbuf_byte(&s, '\\');
        vt_getc(r);
      }
    } else if (c == delim || c == '\n' || c < 0) {
      break;
    }
    vt_sbuf_raw(r, &s);
  }
  if (c != delim && c >= 0) vt_ungetc(r);
  return vt_compile(r, s.p, s.n);
}

// The rest of a delimited text: s's replacement (backslashes kept but for
// the delimiter's and a newline's, for the command to read) or a, c and i's.
static void vt_getrhs(vt_run *r, vt_sbuf *s, int32_t delim, int32_t cmd) {
  int32_t c = 0;
  while ((c = vt_getc(r)) > 0 && c != delim && c != '\n') {
    if (c != '\\') {
      vt_sbuf_raw(r, s);
      continue;
    }
    if ((c = vt_getc(r)) <= 0) {
      vt_fail(r, "bad \\ in rhs");
      return;
    }
    if (c == '\n') {
      vt_ungetc(r);
      vt_sbuf_byte(s, '\\');
    } else if (c == 'n') {
      vt_sbuf_byte(s, '\n');
    } else {
      if (c != delim && (cmd == 's' || c != '\\')) vt_sbuf_byte(s, '\\');
      vt_sbuf_raw(r, s);
    }
  }
  if (c >= 0) vt_ungetc(r);
}

static bool vt_collecttext(vt_run *r, vx_str *out) {
  vt_sbuf s;
  if (!vt_sbuf_new(r, &s)) return false;
  if (vt_skipbl(r) == '\n') { // lines up to one of only "."
    vt_getc(r);
    for (;;) {
      size_t begin = s.n;
      int32_t c = 0;
      while ((c = vt_getc(r)) >= 0 && c != '\n') vt_sbuf_raw(r, &s);
      if (s.n - begin == 1 && s.p[begin] == '.' && c == '\n') {
        s.n = begin;
        break;
      }
      if (c < 0) break;
      vt_sbuf_byte(&s, '\n');
    }
  } else {
    int32_t delim = vt_getc(r);
    if (delim < 0 || delim == '\n') return vt_fail(r, "bad delimiter");
    if (!vt_okdelim(r, delim)) return false;
    vt_getrhs(r, &s, delim, 'a');
    if (vt_peek(r) == delim) vt_getc(r);
    if (r->failed || !vt_atnl(r)) return false;
  }
  *out = (vx_str){s.p, s.n};
  return true;
}

// The rest of the line, leading blanks dropped (|, <, > and =).
static bool vt_collectline(vt_run *r, vx_str *out) {
  vt_sbuf s;
  if (!vt_sbuf_new(r, &s)) return false;
  vt_skipbl(r);
  int32_t c = 0;
  while ((c = vt_getc(r)) >= 0 && c != '\n') vt_sbuf_raw(r, &s);
  *out = (vx_str){s.p, s.n};
  return true;
}

static vt_addr *vt_newaddr(vt_run *r, vt_addr a) {
  vt_addr *p = vt_mem_alloc(r, sizeof *p);
  if (p) *p = a;
  return p;
}

// NOLINTNEXTLINE(misc-no-recursion): as deep as the address is long, VT_NEST at most
static vt_addr *vt_simpleaddr(vt_run *r) {
  vt_addr a = {};
  int32_t c = vt_skipbl(r);
  switch (c) {
  case '#':
    a.type = vt_getc(r);
    a.num = (uint64_t)vt_getnum(r, 1);
    break;
  case '0':
  case '1':
  case '2':
  case '3':
  case '4':
  case '5':
  case '6':
  case '7':
  case '8':
  case '9':
    a.num = (uint64_t)vt_getnum(r, 1);
    a.type = 'l';
    break;
  case '/':
  case '?':
    a.type = vt_getc(r);
    a.re = vt_getregexp(r, a.type);
    if (r->failed) return nullptr;
    break;
  case '.':
  case '$':
  case '+':
  case '-': a.type = vt_getc(r); break;
  default: return nullptr;
  }
  if (++r->depth > VT_NEST) return vt_fail(r, "address too long"), nullptr;
  a.next = vt_simpleaddr(r);
  r->depth--;
  if (r->failed) return nullptr;
  if (a.next) switch (a.next->type) {
    case '.':
    case '$': return vt_fail(r, "address"), nullptr;
    case 'l':
    case '#':
    case '/':
    case '?':
      if (a.type != '+' && a.type != '-') // the missing '+'
        a.next = vt_newaddr(r, (vt_addr){.type = '+', .next = a.next});
      break;
    default: break;
    }
  return r->failed ? nullptr : vt_newaddr(r, a);
}

// NOLINTNEXTLINE(misc-no-recursion): VT_NEST deep at most
static vt_addr *vt_compoundaddr(vt_run *r) {
  vt_addr a = {};
  a.left = vt_simpleaddr(r);
  if (r->failed) return nullptr;
  int32_t c = vt_skipbl(r);
  if (c != ',' && c != ';') return a.left;
  a.type = c;
  vt_getc(r);
  if (++r->depth > VT_NEST) return vt_fail(r, "address too long"), nullptr;
  vt_addr *next = a.next = vt_compoundaddr(r);
  r->depth--;
  if (r->failed) return nullptr;
  if (next && (next->type == ',' || next->type == ';') && !next->left) return vt_fail(r, "address"), nullptr;
  return vt_newaddr(r, a);
}

enum : uint8_t { VT_ANO, VT_ADOT };

typedef struct vt_cmdtab {
  bool text, regexp, addr, defcmd;
  uint8_t defaddr;
  int count; // 1 a count, 2 a signed one
  bool line; // takes the rest of the line
} vt_cmdtab;

static bool vt_lookup(int32_t c, vt_cmdtab *ct) {
  switch (c) {
  case '\n':
  case 'd':
  case 'p': *ct = (vt_cmdtab){.defaddr = VT_ADOT}; return true;
  case 'a':
  case 'c':
  case 'i': *ct = (vt_cmdtab){.text = true, .defaddr = VT_ADOT}; return true;
  case 'g':
  case 'v':
  case 'x':
  case 'y': *ct = (vt_cmdtab){.regexp = true, .defcmd = true, .defaddr = VT_ADOT}; return true;
  case 'm':
  case 't': *ct = (vt_cmdtab){.addr = true, .defaddr = VT_ADOT}; return true;
  case 's': *ct = (vt_cmdtab){.regexp = true, .defaddr = VT_ADOT, .count = 1}; return true;
  case 'u': *ct = (vt_cmdtab){.defaddr = VT_ANO, .count = 2}; return true;
  case '|':
  case '<':
  case '>':
  case '=': *ct = (vt_cmdtab){.defaddr = VT_ADOT, .line = true}; return true;
  default: return false;
  }
}

static vt_cmd *vt_newcmd(vt_run *r, vt_cmd c) {
  vt_cmd *p = vt_mem_alloc(r, sizeof *p);
  if (p) *p = c;
  return p;
}

// One command, or nullptr at the end of the input or a block (or failed).
// NOLINTNEXTLINE(misc-no-recursion): VT_NEST deep at most
static vt_cmd *vt_parsecmd(vt_run *r, uint32_t nest) {
  if (++r->depth > VT_NEST) return vt_fail(r, "commands nested too deeply"), nullptr;
  vt_cmd cmd = {.re = VT_NONE, .num = 0};
  cmd.addr = vt_compoundaddr(r);
  if (r->failed || vt_skipbl(r) < 0) return nullptr;
  int32_t c = vt_getc(r);
  cmd.c = c;
  vt_cmdtab ct;
  if (vt_lookup(c, &ct)) {
    if (c == '\n') goto done;
    if (ct.defaddr == VT_ANO && cmd.addr) return vt_fail(r, "command takes no address"), nullptr;
    if (ct.count) cmd.num = vt_getnum(r, ct.count);
    if (ct.regexp) {
      int32_t p = vt_peek(r);
      if (c != 'x' || (p != ' ' && p != '\t' && p != '\n' && p >= 0)) { // x alone loops over lines
        vt_skipbl(r);
        int32_t delim = vt_getc(r);
        if (delim == '\n' || delim < 0) return vt_fail(r, "pattern expected"), nullptr;
        if (!vt_okdelim(r, delim)) return nullptr;
        cmd.re = vt_getregexp(r, delim);
        if (r->failed) return nullptr;
        if (c == 's') {
          vt_sbuf s;
          if (!vt_sbuf_new(r, &s)) return nullptr;
          vt_getrhs(r, &s, delim, 's');
          cmd.text = (vx_str){s.p, s.n};
          if (vt_peek(r) == delim) {
            vt_getc(r);
            if (vt_peek(r) == 'g') cmd.global = vt_getc(r);
          }
        }
      }
    }
    if (ct.addr && !(cmd.dest = vt_simpleaddr(r)))
      return r->failed ? nullptr : (vt_fail(r, "address"), nullptr);
    if (ct.defcmd) {
      if (vt_skipbl(r) == '\n' || vt_peek(r) < 0) {
        vt_getc(r);
        cmd.sub = vt_newcmd(r, (vt_cmd){.c = VT_SELECT, .re = VT_NONE});
      } else if (!(cmd.sub = vt_parsecmd(r, nest))) {
        return r->failed ? nullptr : (vt_fail(r, "command expected"), nullptr);
      }
    } else if (ct.text) {
      if (!vt_collecttext(r, &cmd.text)) return nullptr;
    } else if (ct.line) {
      if (!vt_collectline(r, &cmd.text)) return nullptr;
    } else if (!vt_atnl(r)) {
      return nullptr;
    }
  } else if (c == '{') {
    vt_cmd *last = nullptr;
    r->closed = false;
    for (;;) {
      if (vt_skipbl(r) == '\n') vt_getc(r);
      vt_cmd *n = vt_parsecmd(r, nest + 1);
      if (r->failed) return nullptr;
      if (!n) break;
      if (last)
        last->next = n;
      else
        cmd.sub = n;
      last = n;
    }
    if (!r->closed) return vt_fail(r, "unmatched `{'"), nullptr;
    r->closed = false;
  } else if (c == '}') {
    if (!vt_atnl(r)) return nullptr;
    if (nest == 0) return vt_fail(r, "unmatched `}'"), nullptr;
    r->closed = true;
    r->depth--;
    return nullptr;
  } else {
    return vt_fail2(r, "unknown command", r->in + r->last, r->at - r->last), nullptr;
  }
done:
  r->depth--;
  return r->failed ? nullptr : vt_newcmd(r, cmd);
}

// --- Addresses: sam's address.c, with the tree's summaries for lines ---

static int vt_byte(const vx_text *t, uint64_t off) {
  char c;
  return vx_text_read(t, off, &c, 1) ? (unsigned char)c : -1;
}

// Just after the k-th (k >= 1) newline at or after pos, or UINT64_MAX.
static uint64_t vt_nl_after(const vx_text *t, uint64_t pos, uint64_t k) {
  uint64_t nl = vx_text_line_of(t, pos) + k;
  return nl > vx_text_lines(t) ? UINT64_MAX : vx_text_line_start(t, nl);
}

static uint64_t vt_line_end(const vx_text *t, uint64_t pos) {
  uint64_t e = vt_nl_after(t, pos, 1);
  return e == UINT64_MAX ? vx_text_len(t) : e;
}

static bool vt_lineaddr(vt_run *r, uint64_t l, vx_text_range a, int sign, vx_text_range *out) {
  const vx_text *t = r->t;
  if (sign >= 0) {
    if (l == 0) {
      if (sign == 0 || a.p1 == 0) return *out = (vx_text_range){0, 0}, true;
      *out = (vx_text_range){a.p1, vt_line_end(t, a.p1 - 1)};
      return true;
    }
    uint64_t p = 0, n = 1;
    if (sign != 0 && a.p1 != 0) {
      p = a.p1 - 1;
      n = vt_byte(t, p) == '\n';
      p++;
    }
    if (l > n && (p = vt_nl_after(t, p, l - n)) == UINT64_MAX) return vt_fail(r, "address range");
    *out = (vx_text_range){p, vt_line_end(t, p)};
    return true;
  }
  uint64_t p = a.p0, p2 = a.p0;
  if (l > 0) {
    uint64_t nls = vx_text_line_of(t, p); // the newlines before p
    if (l <= nls)
      p = vx_text_line_start(t, nls - l + 1);
    else if (l == nls + 1)
      p = 0;
    else
      return vt_fail(r, "address range");
    p2 = p;
    if (p > 0) p--;
  }
  *out = (vx_text_range){vx_text_line_start(t, vx_text_line_of(t, p)), p2};
  return true;
}

static bool vt_charaddr(vt_run *r, uint64_t l, vx_text_range a, int sign, vx_text_range *out) {
  const vx_text *t = r->t;
  uint64_t k = 0, runes = vx_text_runes(t);
  if (sign == 0) {
    k = l;
  } else if (sign < 0) {
    k = vx_text_rune_of(t, a.p0);
    if (l > k) return vt_fail(r, "address range");
    k -= l;
  } else {
    k = vx_text_rune_of(t, a.p1);
    if (l > runes - k) return vt_fail(r, "address range");
    k += l;
  }
  if (k > runes) return vt_fail(r, "address range");
  uint64_t p = vx_text_rune_start(t, k);
  *out = (vx_text_range){p, p};
  return true;
}

// How far a search moves past an empty match at p: a rune, or 1 at the end.
static uint64_t vt_step(const vx_text *t, uint64_t p) {
  vt_reader rd = {.t = t};
  uint64_t len = 0;
  vt_rd_rune(&rd, p, &len);
  return len ? len : 1;
}

static bool vt_search(vt_run *r, uint32_t re, uint64_t p, int sign, uint64_t m[VT_RX_SUBS * 2]) {
  vt_rx *rx = &r->rx[re];
  uint64_t len = vx_text_len(r->t);
  if (sign >= 0)
    return vt_rx_run(rx, r->t, p, len, len, false, m) ||
           (p > 0 && vt_rx_run(rx, r->t, 0, len, p - 1, false, m));
  return vt_rx_run(rx, r->t, p, 0, 0, true, m) || (p < len && vt_rx_run(rx, r->t, len, 0, p + 1, true, m));
}

static bool vt_nextmatch(vt_run *r, uint32_t re, uint64_t p, int sign, vx_text_range *out) {
  uint64_t m[VT_RX_SUBS * 2];
  uint64_t len = vx_text_len(r->t);
  if (!vt_search(r, re, p, sign, m)) return vt_fail(r, "search");
  if (sign >= 0 && m[0] == m[1] && m[0] == p) {
    p += vt_step(r->t, p);
    if (p > len) p = 0;
    if (!vt_search(r, re, p, sign, m)) return vt_fail(r, "search");
  } else if (sign < 0 && m[0] == m[1] && m[1] == p) {
    if (p == 0) {
      p = len;
    } else {
      vt_reader rd = {.t = r->t};
      uint64_t back = 0;
      vt_rd_back(&rd, p, &back);
      p -= back;
    }
    if (!vt_search(r, re, p, sign, m)) return vt_fail(r, "search");
  }
  *out = (vx_text_range){m[0], m[1]};
  return true;
}

// NOLINTNEXTLINE(misc-no-recursion): as deep as the parsed address, VT_NEST at most
static bool vt_address(vt_run *r, const vt_addr *ap, vx_text_range a, int sign, vx_text_range *out) {
  uint64_t len = vx_text_len(r->t);
  do {
    switch (ap->type) {
    case 'l':
      if (!vt_lineaddr(r, ap->num, a, sign, &a)) return false;
      break;
    case '#':
      if (!vt_charaddr(r, ap->num, a, sign, &a)) return false;
      break;
    case '.': a = r->dot; break;
    case '$': a = (vx_text_range){len, len}; break;
    case '?':
      sign = -sign;
      if (sign == 0) sign = -1;
      [[fallthrough]];
    case '/':
      if (!vt_nextmatch(r, ap->re, sign >= 0 ? a.p1 : a.p0, sign, &a)) return false;
      break;
    case ',':
    case ';': {
      vx_text_range a1 = {0, 0}, a2 = {len, len};
      if (ap->left && !vt_address(r, ap->left, a, 0, &a1)) return false;
      if (ap->type == ';') a = a1, r->dot = a1;
      if (ap->next && !vt_address(r, ap->next, a, 0, &a2)) return false;
      if (a2.p1 < a1.p0) return vt_fail(r, "addresses out of order");
      *out = (vx_text_range){a1.p0, a2.p1};
      return true;
    }
    case '+':
    case '-':
      sign = ap->type == '-' ? -1 : 1;
      if (!ap->next || ap->next->type == '+' || ap->next->type == '-')
        if (!vt_lineaddr(r, 1, a, sign, &a)) return false;
      break;
    default: return vt_fail(r, "address");
    }
  } while ((ap = ap->next));
  *out = a;
  return true;
}

// --- Commands: sam's xec.c, collecting changes and results ---

static bool vt_change_add(vt_run *r, uint64_t p0, uint64_t p1, vx_str s, uint32_t *seq) {
  if (!vt_grow((void **)&r->ch, &r->capch, r->nch + 1, sizeof *r->ch)) return vt_fail(r, "out of memory");
  *seq = (uint32_t)r->nch;
  r->ch[r->nch] = (vt_change){p0, p1, s.ptr, s.len, *seq};
  r->nch++;
  return true;
}

static bool vt_result_add(vt_run *r, vt_end a, vt_end b) {
  if (!vt_grow((void **)&r->res, &r->capres, r->nres + 1, sizeof *r->res)) return vt_fail(r, "out of memory");
  r->res[r->nres++] = (vt_result){a, b};
  return true;
}

// A selection of range a: sticking to its text, not to text put beside it.
static bool vt_select(vt_run *r, vx_text_range a) {
  return vt_result_add(r, (vt_end){VT_POS, VX_TEXT_RIGHT, a.p0}, (vt_end){VT_POS, VX_TEXT_LEFT, a.p1});
}

// Replaces range a with s; dot becomes the new text.
static bool vt_replace(vt_run *r, vx_text_range a, vx_str s) {
  uint32_t seq = 0;
  return vt_change_add(r, a.p0, a.p1, s, &seq) &&
         vt_result_add(r, (vt_end){VT_CSTART, 0, seq}, (vt_end){VT_CEND, 0, seq});
}

static bool vt_print(vt_run *r, const char *p, size_t n) {
  if (r->io && r->io->print) r->io->print(r->io->arg, p, n);
  return true;
}

static bool vt_print_text(vt_run *r, vx_text_range a) {
  char buf[4096];
  for (uint64_t at = a.p0; at < a.p1;) {
    uint64_t n = a.p1 - at < sizeof buf ? a.p1 - at : sizeof buf;
    n = vx_text_read(r->t, at, buf, n);
    if (!n) break;
    vt_print(r, buf, n);
    at += n;
  }
  return true;
}

static size_t vt_dec(char *buf, uint64_t v) {
  char d[20];
  size_t n = 0, k = 0;
  do d[n++] = (char)('0' + v % 10);
  while (v /= 10);
  while (n) buf[k++] = d[--n];
  return k;
}

static bool vt_eq(vt_run *r, const vt_cmd *cp, vx_text_range a) {
  bool chars = cp->text.len == 1 && cp->text.ptr[0] == '#';
  if (cp->text.len && !chars) return vt_fail(r, "newline expected");
  char buf[64];
  size_t n = 0;
  uint64_t v1 = 0, v2 = 0;
  if (chars) {
    v1 = vx_text_rune_of(r->t, a.p0), v2 = vx_text_rune_of(r->t, a.p1);
  } else {
    v1 = 1 + vx_text_line_of(r->t, a.p0);
    v2 = v1 + vx_text_line_of(r->t, a.p1) - vx_text_line_of(r->t, a.p0);
    if (a.p1 > a.p0 && vt_byte(r->t, a.p1 - 1) == '\n') v2--;
  }
  if (chars) buf[n++] = '#';
  n += vt_dec(buf + n, v1);
  if (v2 != v1) {
    buf[n++] = ',';
    if (chars) buf[n++] = '#';
    n += vt_dec(buf + n, v2);
  }
  buf[n++] = '\n';
  return vt_print(r, buf, n);
}

static bool vt_exec(vt_run *r, const vt_cmd *cp, vx_text_range dot);

static bool vt_s(vt_run *r, const vt_cmd *cp, vx_text_range a) {
  vt_rx *rx = &r->rx[cp->re];
  int64_t n = cp->num;
  uint64_t op = UINT64_MAX, m[VT_RX_SUBS * 2];
  bool didsub = false;
  for (uint64_t p1 = a.p0; p1 <= a.p1 && vt_rx_run(rx, r->t, p1, a.p1, a.p1, false, m);) {
    if (m[0] == m[1]) { // empty match
      if (m[0] == op) {
        p1 += vt_step(r->t, p1);
        continue;
      }
      p1 = m[1] + vt_step(r->t, m[1]);
    } else {
      p1 = m[1];
    }
    op = m[1];
    if (--n > 0) continue;
    // the replacement: \1-\9 the sub-matches, & the match, \c the rune c
    uint64_t size = 0;
    for (size_t i = 0; i < cp->text.len; i++) {
      char c = cp->text.ptr[i];
      if (c == '\\' && i + 1 < cp->text.len) {
        c = cp->text.ptr[++i];
        size_t sub = (size_t)(c - '0');
        size += c >= '1' && c <= '9' ? m[sub * 2 + 1] - m[sub * 2] : 1;
      } else {
        size += c == '&' ? m[1] - m[0] : 1;
      }
    }
    char *out = vt_mem_alloc(r, size);
    if (!out) return false;
    size_t k = 0;
    for (size_t i = 0; i < cp->text.len; i++) {
      char c = cp->text.ptr[i];
      size_t sub = SIZE_MAX;
      if (c == '\\' && i + 1 < cp->text.len) {
        c = cp->text.ptr[++i];
        if (c >= '1' && c <= '9') sub = (size_t)(c - '0');
      } else if (c == '&') {
        sub = 0;
      }
      if (sub == SIZE_MAX)
        out[k++] = c;
      else
        k += vx_text_read(r->t, m[sub * 2], out + k, m[sub * 2 + 1] - m[sub * 2]);
    }
    uint32_t seq = 0;
    if (!vt_change_add(r, m[0], m[1], (vx_str){out, k}, &seq)) return false;
    didsub = true;
    if (!cp->global) break;
  }
  if (!didsub && r->nest == 0) return vt_fail(r, "substitution");
  return vt_result_add(r, (vt_end){VT_POS, VX_TEXT_LEFT, a.p0}, (vt_end){VT_POS, VX_TEXT_RIGHT, a.p1});
}

// NOLINTNEXTLINE(misc-no-recursion): as deep as the parsed command, VT_NEST at most
static bool vt_looper(vt_run *r, const vt_cmd *cp, vx_text_range a, bool xy) {
  vt_rx *rx = &r->rx[cp->re];
  uint64_t op = xy ? UINT64_MAX : a.p0, m[VT_RX_SUBS * 2];
  r->nest++;
  for (uint64_t p = a.p0; p <= a.p1;) {
    vx_text_range d;
    if (!vt_rx_run(rx, r->t, p, a.p1, a.p1, false, m)) { // no match, but y still runs
      if (xy || op > a.p1) break;
      d = (vx_text_range){op, a.p1};
      p = a.p1 + 1;
      m[1] = UINT64_MAX;
    } else {
      if (m[0] == m[1]) {
        if (m[0] == op) {
          p += vt_step(r->t, p);
          continue;
        }
        p = m[1] + vt_step(r->t, m[1]);
      } else {
        p = m[1];
      }
      d = xy ? (vx_text_range){m[0], m[1]} : (vx_text_range){op, m[0]};
    }
    op = m[1];
    if (!vt_exec(r, cp->sub, d)) return false;
  }
  r->nest--;
  return true;
}

// NOLINTNEXTLINE(misc-no-recursion): as deep as the parsed command, VT_NEST at most
static bool vt_linelooper(vt_run *r, const vt_cmd *cp, vx_text_range a) {
  vx_text_range a3 = {a.p0, a.p0}, line;
  r->nest++;
  for (uint64_t p = a.p0; p < a.p1; p = a3.p1) {
    a3.p0 = a3.p1;
    if (p != a.p0 || (vt_lineaddr(r, 0, a3, 1, &line) && line.p1 == p))
      if (!vt_lineaddr(r, 1, a3, 1, &line)) return false;
    if (line.p0 >= a.p1) break;
    if (line.p1 >= a.p1) line.p1 = a.p1;
    if (!(line.p1 > line.p0 && line.p0 >= a3.p1 && line.p1 > a3.p1)) break;
    if (!vt_exec(r, cp->sub, line)) return false;
    a3 = line;
  }
  r->nest--;
  return true;
}

static bool vt_shell(vt_run *r, const vt_cmd *cp, vx_text_range a) {
  if (!r->io || !r->io->shell) return vt_fail(r, "no shell");
  vx_str in = cp->c == '<' ? (vx_str){} : vt_text_of(r, a), out = {};
  if (r->failed) return false;
  if (!r->io->shell(r->io->arg, (char)cp->c, cp->text, in, &out)) return vt_fail(r, "exit status");
  if (cp->c == '>') return vt_select(r, a);
  char *keep = vt_mem_alloc(r, out.len);
  if (!keep) return false;
  if (out.len) __builtin_memcpy(keep, out.ptr, out.len);
  return vt_replace(r, a, (vx_str){keep, out.len});
}

// NOLINTNEXTLINE(misc-no-recursion): as deep as the parsed command, VT_NEST at most
static bool vt_exec(vt_run *r, const vt_cmd *cp, vx_text_range dot) {
  vt_cmdtab ct = {};
  vx_text_range a = dot;
  r->dot = dot;
  bool table = vt_lookup(cp->c, &ct);
  if ((table && ct.defaddr == VT_ADOT) || cp->c == '{')
    if (cp->addr && !vt_address(r, cp->addr, dot, 0, &a)) return false;
  switch (cp->c) {
  case VT_SELECT:
  case '\n': return vt_select(r, a); // an address alone; or nothing, dot kept
  case '{':
    for (const vt_cmd *c = cp->sub; c; c = c->next) {
      r->nest++;
      bool ok = vt_exec(r, c, a);
      r->nest--;
      if (!ok) return false;
    }
    return true;
  case 'a': return vt_replace(r, (vx_text_range){a.p1, a.p1}, cp->text);
  case 'i': return vt_replace(r, (vx_text_range){a.p0, a.p0}, cp->text);
  case 'c': return vt_replace(r, a, cp->text);
  case 'd': return vt_replace(r, a, (vx_str){});
  case 'p': return vt_print_text(r, a) && vt_select(r, a);
  case '=': return vt_eq(r, cp, a) && vt_select(r, dot);
  case 's': return vt_s(r, cp, a);
  case 'g':
  case 'v': {
    uint64_t m[VT_RX_SUBS * 2];
    if (vt_rx_run(&r->rx[cp->re], r->t, a.p0, a.p1, a.p1, false, m) == (cp->c == 'v')) return true;
    r->nest++;
    bool ok = vt_exec(r, cp->sub, a);
    r->nest--;
    return ok;
  }
  case 'x':
  case 'y': return cp->re == VT_NONE ? vt_linelooper(r, cp, a) : vt_looper(r, cp, a, cp->c == 'x');
  case 'm':
  case 't': {
    vx_text_range d;
    r->dot = dot;
    if (!vt_address(r, cp->dest, dot, 0, &d)) return false;
    vx_str s = vt_text_of(r, a);
    if (r->failed) return false;
    if (cp->c == 'm') {
      if (!(a.p1 <= d.p1 || a.p0 >= d.p1)) return vt_fail(r, "addresses overlap");
      uint32_t seq = 0;
      if (!vt_change_add(r, a.p0, a.p1, (vx_str){}, &seq)) return false;
    }
    return vt_replace(r, (vx_text_range){d.p1, d.p1}, s);
  }
  case '|':
  case '<':
  case '>': return vt_shell(r, cp, a);
  case 'u': return vt_fail(r, "u in a loop");
  default: return vt_fail(r, "unknown command");
  }
}

// --- Making the changes, and the new dot ---

// A stable merge sort of n elements of size bytes.
static bool vt_sort(void *base, size_t n, size_t size, bool (*less)(const void *, const void *)) {
  if (n < 2) return true;
  char *a = base, *tmp = vt_alloc(n * size);
  if (!tmp) return false;
  for (size_t width = 1; width < n; width *= 2) {
    for (size_t lo = 0; lo < n; lo += 2 * width) {
      size_t mid = lo + width < n ? lo + width : n, hi = lo + 2 * width < n ? lo + 2 * width : n;
      size_t i = lo, j = mid, k = lo;
      while (i < mid && j < hi) {
        const char *take = less(a + j * size, a + i * size) ? a + j++ * size : a + i++ * size;
        __builtin_memcpy(tmp + k++ * size, take, size);
      }
      if (i < mid) __builtin_memcpy(tmp + k * size, a + i * size, (mid - i) * size), k += mid - i;
      if (j < hi) __builtin_memcpy(tmp + k * size, a + j * size, (hi - j) * size);
    }
    __builtin_memcpy(a, tmp, n * size);
  }
  vt_free(tmp);
  return true;
}

static bool vt_change_less(const void *x, const void *y) {
  const vt_change *a = x, *b = y;
  return a->p0 < b->p0 || (a->p0 == b->p0 && a->p1 < b->p1);
}

static bool vt_range_less(const void *x, const void *y) {
  const vx_text_range *a = x, *b = y;
  return a->p0 < b->p0 || (a->p0 == b->p0 && a->p1 < b->p1);
}

typedef struct vt_mapping {
  const vt_change *ch; // sorted
  size_t n;
  int64_t *before; // the change in length of the ones before each
  uint32_t *index; // a seq's place among them
} vt_mapping;

static uint64_t vt_map_pos(const vt_mapping *mp, uint64_t q, uint32_t bias) {
  size_t lo = 0, hi = mp->n; // the first change not wholly before q
  while (lo < hi) {
    size_t mid = (lo + hi) / 2;
    const vt_change *c = &mp->ch[mid];
    bool before = c->p1 < q || (c->p1 == q && (c->p0 < c->p1 || bias == VX_TEXT_RIGHT));
    if (before)
      lo = mid + 1;
    else
      hi = mid;
  }
  if (lo == mp->n) return (uint64_t)((int64_t)q + mp->before[lo]);
  const vt_change *c = &mp->ch[lo];
  if (c->p0 < c->p1 && c->p0 <= q) // inside a deletion, or at its start
    return (uint64_t)((int64_t)c->p0 + mp->before[lo]) + (bias == VX_TEXT_RIGHT ? c->n : 0);
  return (uint64_t)((int64_t)q + mp->before[lo]);
}

static uint64_t vt_map_end(const vt_mapping *mp, vt_end e) {
  if (e.kind == VT_POS) return vt_map_pos(mp, e.q, e.bias);
  size_t i = mp->index[e.q];
  uint64_t start = (uint64_t)((int64_t)mp->ch[i].p0 + mp->before[i]);
  return e.kind == VT_CSTART ? start : start + mp->ch[i].n;
}

// Makes the collected changes and sets dot from the results.
static bool vt_commit(vt_run *r, vx_text_dot *dot) {
  size_t n = r->nch;
  if (!vt_sort(r->ch, n, sizeof *r->ch, vt_change_less)) return vt_fail(r, "out of memory");
  for (size_t i = 1; i < n; i++)
    if (r->ch[i].p0 < r->ch[i - 1].p1) return vt_fail(r, "changes not in sequence");
  vt_mapping mp = {.ch = r->ch, .n = n};
  mp.before = vt_alloc((n + 1) * sizeof *mp.before);
  mp.index = vt_alloc((n + 1) * sizeof *mp.index);
  if (!mp.before || !mp.index) {
    vt_free(mp.before), vt_free(mp.index);
    return vt_fail(r, "out of memory");
  }
  mp.before[0] = 0;
  for (size_t i = 0; i < n; i++) {
    mp.before[i + 1] = mp.before[i] + (int64_t)r->ch[i].n - (int64_t)(r->ch[i].p1 - r->ch[i].p0);
    mp.index[r->ch[i].seq] = (uint32_t)i;
  }
  bool ok = true;
  for (size_t i = n; i-- > 0 && ok;)
    ok = vx_text_replace(r->t, r->ch[i].p0, r->ch[i].p1, r->ch[i].s, r->ch[i].n);
  // the new dot: the results, or (none) the old dot, mapped, sorted, merged
  size_t want = r->nres ? r->nres : dot->n;
  if (ok && !vt_grow((void **)&dot->r, &dot->cap, want ? want : 1, sizeof *dot->r)) ok = false;
  if (ok) {
    for (size_t i = 0; i < want; i++) {
      vt_end a = r->nres ? r->res[i].a : (vt_end){VT_POS, VX_TEXT_RIGHT, dot->r[i].p0};
      vt_end b = r->nres ? r->res[i].b : (vt_end){VT_POS, VX_TEXT_LEFT, dot->r[i].p1};
      uint64_t p0 = vt_map_end(&mp, a), p1 = vt_map_end(&mp, b);
      dot->r[i] = (vx_text_range){p0, p1 < p0 ? p0 : p1};
    }
    dot->n = want;
    ok = vt_sort(dot->r, dot->n, sizeof *dot->r, vt_range_less);
  }
  vt_free(mp.before), vt_free(mp.index);
  if (!ok) return vt_fail(r, "out of memory");
  size_t k = 0;
  for (size_t i = 0; i < dot->n; i++) {
    vx_text_range x = dot->r[i];
    if (k && (x.p0 < dot->r[k - 1].p1 || (x.p0 == dot->r[k - 1].p0 && x.p1 == dot->r[k - 1].p1))) {
      if (x.p1 > dot->r[k - 1].p1) dot->r[k - 1].p1 = x.p1;
    } else {
      dot->r[k++] = x;
    }
  }
  dot->n = k ? k : 1;
  if (!k) dot->r[0] = (vx_text_range){};
  return true;
}

static void vt_run_free(vt_run *r) {
  for (size_t i = 0; i < r->nrx; i++) vt_rx_free(&r->rx[i]);
  vt_free(r->rx), vt_free(r->ch), vt_free(r->res);
  for (vt_mem *m = r->mem, *next; m; m = next) next = m->next, vt_free(m);
}

// One command over every selection, then its changes made.
static bool vt_run_cmd(vt_run *r, const vt_cmd *cp, vx_text_dot *dot, vx_str source) {
  uint64_t len = vx_text_len(r->t);
  if (dot->n == 0 && !vx_text_dot_set(dot, 0, 0)) return vt_fail(r, "out of memory");
  for (size_t i = 0; i < dot->n; i++) {
    if (dot->r[i].p1 > len) dot->r[i].p1 = len;
    if (dot->r[i].p0 > dot->r[i].p1) dot->r[i].p0 = dot->r[i].p1;
  }
  if (cp->c == 'u') { // sam's undo, outside the group; -n redoes
    vx_text_end(r->t);
    for (int64_t n = cp->num; n > 0 && vx_text_undo(r->t); n--);
    for (int64_t n = cp->num; n < 0 && vx_text_redo(r->t); n++);
    if (!vx_text_begin(r->t, source)) return vt_fail(r, "out of memory");
    len = vx_text_len(r->t);
    for (size_t i = 0; i < dot->n; i++) {
      if (dot->r[i].p1 > len) dot->r[i].p1 = len;
      if (dot->r[i].p0 > dot->r[i].p1) dot->r[i].p0 = dot->r[i].p1;
    }
    return true;
  }
  r->nch = r->nres = 0;
  for (size_t i = 0; i < dot->n; i++) {
    r->nest = 0;
    if (!vt_exec(r, cp, dot->r[i])) return false;
  }
  return vt_commit(r, dot);
}

bool vx_text_run(vx_text *t, vx_str cmd, vx_text_dot *dot, const vx_text_io *io, vx_str source, char *error,
                 size_t errlen) {
  vt_run r = {.t = t, .io = io, .error = error, .errlen = errlen};
  if (errlen) error[0] = 0;
  // the input, ending in a newline
  char *in = vt_mem_alloc(&r, cmd.len + 1);
  if (!in) return vt_run_free(&r), false;
  if (cmd.len) __builtin_memcpy(in, cmd.ptr, cmd.len);
  r.in = in, r.inlen = cmd.len;
  if (!cmd.len || cmd.ptr[cmd.len - 1] != '\n') in[r.inlen++] = '\n';
  if (!vx_text_begin(t, source)) {
    vt_fail(&r, "out of memory");
    vt_run_free(&r);
    return false;
  }
  for (;;) {
    r.depth = 0;
    vt_cmd *cp = vt_parsecmd(&r, 0);
    if (!cp) break;
    if (!vt_run_cmd(&r, cp, dot, source)) break;
  }
  vx_text_end(t);
  bool ok = !r.failed;
  vt_run_free(&r);
  return ok;
}
