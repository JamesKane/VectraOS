// vx-rc: the interpreter (rc.h). Its parts, in order: the heap, words and
// variables; the lexer (lex.c in rc); the parser (syn.y); the compiler
// (code.c); the machine (exec.c), with globbing (glob.c) and the builtins.

#pragma once

#include "rc.h"
#include "../vx-utf/utf.h"
#include "../vx-posix/posix.h"

// --- The heap: first fit, coalescing, in the caller's buffer ---

typedef struct rc_block {
  size_t size;           // the block's, header included
  struct rc_block *next; // free blocks only, in address order
} rc_block;

static constexpr size_t RC_ALIGN = 16;

static void *rc_alloc(rc *r, size_t n);
static void rc_free(rc *r, void *p);

// --- The interpreter ---

typedef struct rc_code rc_code;

typedef struct rc_var {
  struct rc_var *next;
  rc_word *val;
  rc_code *fn; // a function: its code, from fn_pc
  uint32_t fn_pc;
  char *fnsrc; // and its body's text, { to }, for whatis and export
  char name[]; // NUL-terminated
} rc_var;

enum : uint32_t { RC_VARS = 64, RC_STACK = 512, RC_FRAMES = 64, RC_REDIRS = 64, RC_ERR = 128 };

typedef struct rc_list { // a list on the argument stack
  rc_word *head, *tail;
  uint32_t n;
} rc_list;

typedef struct rc_redir {
  uint8_t fd;
  rc_fd to;
  rc_word *path; // owned
} rc_redir;

typedef struct rc_reader rc_reader;

typedef struct rc_frame { // a thread of rc's: what runs, and where it goes back to
  rc_code *code;
  uint32_t pc;
  rc_var *locals;
  uint32_t redirs;        // the redirection stack's height when it started
  rc_reader *rd;          // a frame that reads its commands as it goes (rc's Xrdcmds): where from
  uint32_t sp, ncaptures; // the stacks' heights when it started, for an error's unwinding to it
} rc_frame;

typedef struct rc_capture { // `{...}'s output, gathered
  char *buf;
  size_t len, cap;
} rc_capture;

struct rc {
  rc_host host;
  uint8_t *heap;
  size_t heap_size;
  rc_block *free;
  rc_var *vars[RC_VARS];
  rc_list stack[RC_STACK];
  uint32_t sp;
  rc_frame frames[RC_FRAMES];
  uint32_t nframes;
  rc_redir redirs[RC_REDIRS];
  uint32_t nredirs;
  rc_capture captures[8];
  uint32_t ncaptures;
  bool ifnot;   // the last if's condition was false: what `if not` runs on
  bool iflast;  // the last command compiled was an if, so `if not` may follow (rc's lex->iflast)
  bool failed;  // a run-time error ended the script
  bool failset; // and rc_fail set $status for it
  bool exiting;
  bool syntax, incomplete; // a run's reader met a syntax error, or the text's end inside a construct
  char src[64];            // where the code being compiled comes from, for errors: a file's name, or rc
  bool flag[128];          // rc's flags, -e -x -s -v -r and the rest, as flag in rc(1) sets them
  rc_code *rdcode;         // the code a reading frame runs: one X_RDCMDS
  volatile uint32_t trap[8], ntrap; // notes waiting for their functions, by rc_sig's numbers (rc's trap)
  bool trapped;                     // sigexit has run, as rc's
  uint64_t budget;  // instructions a run may take (0: as many as it needs): fuzzing's guard against loops
  char err[RC_ERR]; // the last error, for the host to show
};

[[maybe_unused]] static void rc_error(rc *r, const char *a, const char *b) {
  size_t n = 0;
  for (const char *s = a; s && *s && n + 1 < RC_ERR; s++) r->err[n++] = *s;
  for (const char *s = b; s && *s && n + 1 < RC_ERR; s++) r->err[n++] = *s;
  r->err[n] = 0;
}

static void *rc_alloc(rc *r, size_t n) {
  size_t need = (n + sizeof(rc_block) + RC_ALIGN - 1) & ~(RC_ALIGN - 1);
  for (rc_block **p = &r->free; *p; p = &(*p)->next) {
    rc_block *b = *p;
    if (b->size < need) continue;
    if (b->size - need >= 2 * RC_ALIGN + sizeof(rc_block)) { // split: the rest stays free
      rc_block *rest = (rc_block *)((uint8_t *)b + need);
      rest->size = b->size - need;
      rest->next = b->next;
      *p = rest;
      b->size = need;
    } else {
      *p = b->next;
    }
    b->next = nullptr;
    void *m = (uint8_t *)b + sizeof(rc_block);
    memset(m, 0, b->size - sizeof(rc_block));
    return m;
  }
  rc_error(r, "out of memory", nullptr);
  r->failed = true; // the script stops: a word or output left out would change what it does
  return nullptr;
}

static void rc_free(rc *r, void *p) {
  if (!p) return;
  rc_block *b = (rc_block *)((uint8_t *)p - sizeof(rc_block));
  rc_block **at = &r->free;
  while (*at && *at < b) at = &(*at)->next;
  b->next = *at;
  *at = b;
  if (b->next && (uint8_t *)b + b->size == (uint8_t *)b->next) { // into the next
    b->size += b->next->size;
    b->next = b->next->next;
  }
  rc_block *prev = r->free == b ? nullptr : r->free;
  while (prev && prev->next != b) prev = prev->next;
  if (prev && (uint8_t *)prev + prev->size == (uint8_t *)b) { // the previous into it
    prev->size += b->size;
    prev->next = b->next;
  }
}

// --- Words ---

static rc_word *rc_newword(rc *r, const char *s, size_t len) {
  rc_word *w = rc_alloc(r, sizeof *w + len + 1);
  if (!w) return nullptr;
  w->len = len;
  if (len) memcpy(w->s, s, len); // s may be null when len is 0
  w->s[len] = 0;
  return w;
}

static void rc_freewords(rc *r, rc_word *w) {
  while (w) {
    rc_word *next = w->next;
    rc_free(r, w);
    w = next;
  }
}

static rc_word *rc_copywords(rc *r, const rc_word *w) {
  rc_word *head = nullptr, **tail = &head;
  for (; w; w = w->next) {
    *tail = rc_newword(r, w->s, w->len);
    if (!*tail) break;
    tail = &(*tail)->next;
  }
  return head;
}

static uint32_t rc_count(const rc_word *w) {
  uint32_t n = 0;
  for (; w; w = w->next) n++;
  return n;
}

static bool rc_streq(const char *a, size_t al, const char *b, size_t bl) {
  return al == bl && memcmp(a, b, al) == 0;
}

static size_t rc_strlen(const char *s) {
  size_t n = 0;
  while (s[n]) n++;
  return n;
}

// --- Variables ---

static uint32_t rc_hash(const char *s, size_t n) {
  uint32_t h = 2166136261u;
  for (size_t i = 0; i < n; i++) h = (h ^ (uint8_t)s[i]) * 16777619u;
  return h % RC_VARS;
}

// The variable named (n bytes): a local of the running frames, innermost
// first, then a global; made a global if make and there is none.
static rc_var *rc_var_find(rc *r, const char *name, size_t n, bool make) {
  for (uint32_t f = r->nframes; f-- > 0;)
    for (rc_var *v = r->frames[f].locals; v; v = v->next)
      if (rc_streq(v->name, rc_strlen(v->name), name, n)) return v;
  rc_var **bucket = &r->vars[rc_hash(name, n)];
  for (rc_var *v = *bucket; v; v = v->next)
    if (rc_streq(v->name, rc_strlen(v->name), name, n)) return v;
  if (!make) return nullptr;
  rc_var *v = rc_alloc(r, sizeof *v + n + 1);
  if (!v) return nullptr;
  memcpy(v->name, name, n);
  v->next = *bucket;
  *bucket = v;
  return v;
}

// A global variable, which is where functions live (rc's gvlook): a local of
// the same name does not hide one.
static rc_var *rc_gvar_find(rc *r, const char *name, size_t n, bool make) {
  rc_var **bucket = &r->vars[rc_hash(name, n)];
  for (rc_var *v = *bucket; v; v = v->next)
    if (rc_streq(v->name, rc_strlen(v->name), name, n)) return v;
  if (!make) return nullptr;
  rc_var *v = rc_alloc(r, sizeof *v + n + 1);
  if (!v) return nullptr;
  memcpy(v->name, name, n);
  v->next = *bucket;
  *bucket = v;
  return v;
}

static void rc_code_release(rc *r, rc_code *c);

// Sets a variable to w (which it takes): an empty list unsets it, in effect.
static void rc_setvar(rc *r, const char *name, size_t n, rc_word *w) {
  rc_var *v = rc_var_find(r, name, n, true);
  if (!v) return rc_freewords(r, w);
  rc_freewords(r, v->val);
  v->val = w;
}

[[maybe_unused]] static const rc_word *rc_getvar(rc *r, const char *name) {
  const rc_var *v = rc_var_find(r, name, rc_strlen(name), false);
  return v ? v->val : nullptr;
}

// $status, from one status string.
[[maybe_unused]] static void rc_set_status(rc *r, const char *s, size_t n) {
  rc_setvar(r, "status", 6, rc_newword(r, s, n));
}

static bool rc_truestatus(rc *r) { // as rc's: nothing in $status's first word but 0s and a pipeline's |s
  const rc_word *w = rc_getvar(r, "status");
  for (size_t i = 0; w && i < w->len; i++)
    if (w->s[i] != '0' && w->s[i] != '|') return false;
  return true;
}

// --- The lexer ---

typedef enum rc_tok : uint8_t {
  TK_EOF,
  TK_NL,
  TK_WORD,
  TK_DOLLAR, // $
  TK_COUNT,  // $#
  TK_JOIN,   // $"
  TK_SUBLP,  // ( right after $name: a subscript
  TK_CARET,
  TK_BACKQ,
  TK_LP,
  TK_RP,
  TK_LBRACE,
  TK_RBRACE,
  TK_SEMI,
  TK_AMP,
  TK_ANDAND,
  TK_OROR,
  TK_PIPE, // fd0, fd1
  TK_EQ,
  TK_REDIR, // kind (enum rc_fd_kind), fd0
  TK_DUP,   // fd0 = fd1, or (fd1 255) a close
} rc_tok;

typedef enum rc_kw : uint8_t {
  KW_NONE,
  KW_FOR,
  KW_IN,
  KW_WHILE,
  KW_IF,
  KW_NOT,
  KW_SWITCH,
  KW_FN,
  KW_TWIDDLE,
  KW_BANG,
  KW_SUBSHELL
} rc_kw;

typedef struct rc_token {
  rc_tok kind;
  rc_kw kw;    // a bare word that is a keyword, where one may be
  bool quoted; // a word written in quotes
  bool adj;    // nothing between it and the token before
  uint8_t fd0, fd1, rkind;
  uint8_t here; // a here document's tag: its place in the lexer's heres, plus 1
  char *s;      // a word's text, unquoted, its glob characters marked (RC_GLOB before them)
  size_t len;
  uint32_t line;
  const char *at, *end; // where it is in the source
} rc_token;

typedef struct rc_here { // a here document: its tag, then (once its line has ended) its text
  const char *tag;
  size_t tlen;
  bool quoted; // <<'tag': no substitution
  bool read;
  const char *body;
  size_t blen;
} rc_here;

enum : uint32_t { RC_HERES = 32 };

static constexpr char RC_GLOB = '\x01'; // before a * ? or [ written bare: they glob

typedef struct rc_lexer {
  rc *r;
  const char *p, *end;
  const char *base; // the text's start
  uint32_t line;
  rc_token prev;
  rc_token pending; // a token held back behind a free caret
  bool has_pending, after_dollar;
  char *scratch; // where word texts are kept for the parse
  size_t used, cap;
  bool failed;
  bool incomplete; // it failed only for the text ending: in a quote, or after a \ that ends a line
  const char *why;
  bool want_tag; // the word next is a here document's tag
  rc_here heres[RC_HERES];
  uint32_t nheres;
} rc_lexer;

static bool rc_wordchr(char c) {
  static const char special[] = "\n \t#;&|^$=`'{}()<>";
  for (size_t i = 0; i < sizeof special - 1; i++)
    if (c == special[i]) return false;
  return c != 0;
}

static bool rc_idchr(char c) { // a variable name's characters
  static const char special[] = "!\"#$%&'()+,-./:;<=>?@[\\]^`{|}~";
  if ((unsigned char)c <= ' ') return false;
  for (size_t i = 0; i < sizeof special - 1; i++)
    if (c == special[i]) return false;
  return true;
}

static char *rc_lex_keep(rc_lexer *lx, size_t n) {
  if (lx->cap - lx->used < n + 1) {
    lx->failed = true, lx->why = "script too long";
    return nullptr;
  }
  char *s = lx->scratch + lx->used;
  lx->used += n + 1;
  return s;
}

static rc_kw rc_keyword(const char *s, size_t n) {
  static const struct {
    const char *w;
    rc_kw k;
  } K[] = {{"for", KW_FOR},       {"in", KW_IN}, {"while", KW_WHILE}, {"if", KW_IF},  {"not", KW_NOT},
           {"switch", KW_SWITCH}, {"fn", KW_FN}, {"~", KW_TWIDDLE},   {"!", KW_BANG}, {"@", KW_SUBSHELL}};
  for (size_t i = 0; i < sizeof K / sizeof K[0]; i++)
    if (rc_streq(s, n, K[i].w, rc_strlen(K[i].w))) return K[i].k;
  return KW_NONE;
}

// A [n] or [n=m] or [n=] after a redirection or pipe: false if malformed.
static bool rc_lex_fds(rc_lexer *lx, uint8_t *fd0, uint8_t *fd1, bool *eq) {
  *eq = false;
  if (lx->p >= lx->end || *lx->p != '[') return true;
  lx->p++;
  // Numbers of any length, as rc's lexer reads them; past the descriptors there are, refused.
  uint32_t n = 0;
  if (lx->p >= lx->end || *lx->p < '0' || *lx->p > '9') return false;
  while (lx->p < lx->end && *lx->p >= '0' && *lx->p <= '9' && n < 1000)
    n = n * 10 + (uint32_t)(*lx->p++ - '0');
  if (n >= RC_FDS) return false;
  *fd0 = (uint8_t)n;
  if (lx->p < lx->end && *lx->p == '=') {
    lx->p++;
    *eq = true;
    *fd1 = 255; // [n=]: close
    if (lx->p < lx->end && *lx->p >= '0' && *lx->p <= '9') {
      n = 0;
      while (lx->p < lx->end && *lx->p >= '0' && *lx->p <= '9' && n < 1000)
        n = n * 10 + (uint32_t)(*lx->p++ - '0');
      if (n >= RC_FDS) return false;
      *fd1 = (uint8_t)n;
    }
  }
  if (lx->p >= lx->end || *lx->p != ']') return false;
  lx->p++;
  return true;
}

// A \ that ends a line, which is white space wherever it is: it ends a word.
static bool rc_continues(const char *q, const char *end) {
  return q < end && q[0] == '\\' && (q + 1 == end || q[1] == '\n');
}

// At a line's end, the bodies of the here documents begun on it: each the
// lines up to one that is its tag alone (rc's readhere).
static void rc_lex_heres(rc_lexer *lx) {
  for (uint32_t i = 0; i < lx->nheres; i++) {
    rc_here *h = &lx->heres[i];
    if (h->read) continue;
    const char *start = lx->p;
    for (;;) {
      if (lx->p >= lx->end) {
        lx->failed = lx->incomplete = true, lx->why = "here document never ended";
        return;
      }
      const char *ln = lx->p;
      while (lx->p < lx->end && *lx->p != '\n') lx->p++;
      bool full = lx->p < lx->end;
      size_t n = (size_t)(lx->p - ln);
      if (full) lx->p++, lx->line++;
      if (n == h->tlen && memcmp(ln, h->tag, n) == 0 && full) {
        h->body = start, h->blen = (size_t)(ln - start), h->read = true;
        break;
      }
      if (!full) {
        lx->failed = lx->incomplete = true, lx->why = "here document never ended";
        return;
      }
    }
  }
}

static rc_token rc_lex_raw(rc_lexer *lx) {
  rc_token t = {.line = lx->line};
  const char *start = lx->p;
  for (;;) { // white space, line continuations, comments
    while (lx->p < lx->end && (*lx->p == ' ' || *lx->p == '\t')) lx->p++;
    if (lx->p + 2 < lx->end && lx->p[0] == '\\' && lx->p[1] == '\n') {
      lx->p += 2, lx->line++;
      continue;
    }
    if (rc_continues(lx->p, lx->end)) { // a \ that ends the text: the line goes on, in more text
      lx->failed = lx->incomplete = true, lx->why = "unexpected end";
      return t.kind = TK_EOF, t;
    }
    if (lx->p < lx->end && *lx->p == '#') {
      while (lx->p < lx->end && *lx->p != '\n') lx->p++;
    }
    break;
  }
  t.adj = lx->p == start;
  t.line = lx->line;
  t.at = lx->p;
  if (lx->p >= lx->end) return t.kind = TK_EOF, t;
  char c = *lx->p;
  if (lx->after_dollar && c != '\'' && c != '(' && c != '`' && c != '$' && c != '{') { // a variable's name
    lx->after_dollar = false;
    const char *s = lx->p;
    while (lx->p < lx->end && rc_idchr(*lx->p)) lx->p++;
    if (lx->p == s) { // $ alone, or before something no name starts with
      lx->failed = true, lx->why = "bad $ name";
      return t.kind = TK_EOF, t;
    }
    t.kind = TK_WORD, t.len = (size_t)(lx->p - s);
    t.s = rc_lex_keep(lx, t.len);
    if (t.s) memcpy(t.s, s, t.len), t.s[t.len] = 0;
    return t;
  }
  lx->after_dollar = false;
  lx->p++;
  switch (c) {
  case '\n':
    lx->line++;
    rc_lex_heres(lx);
    return t.kind = TK_NL, t;
  case ';': return t.kind = TK_SEMI, t;
  case '^': return t.kind = TK_CARET, t;
  case '`': return t.kind = TK_BACKQ, t;
  case '(': // right after a word (not a keyword): a subscript, which rc's grammar allows only after $name
    t.kind =
        t.adj && lx->prev.kind == TK_WORD && (lx->prev.kw == KW_NONE || lx->prev.quoted) ? TK_SUBLP : TK_LP;
    return t;
  case ')': return t.kind = TK_RP, t;
  case '{': return t.kind = TK_LBRACE, t;
  case '}': return t.kind = TK_RBRACE, t;
  case '=': return t.kind = TK_EQ, t;
  case '$':
    lx->after_dollar = true;
    if (lx->p < lx->end && *lx->p == '#') return lx->p++, t.kind = TK_COUNT, t;
    if (lx->p < lx->end && *lx->p == '"') return lx->p++, t.kind = TK_JOIN, t;
    return t.kind = TK_DOLLAR, t;
  case '&':
    if (lx->p < lx->end && *lx->p == '&') return lx->p++, t.kind = TK_ANDAND, t;
    return t.kind = TK_AMP, t;
  case '|': {
    if (lx->p < lx->end && *lx->p == '|') return lx->p++, t.kind = TK_OROR, t;
    bool eq;
    t.fd0 = 1, t.fd1 = 0;
    if (!rc_lex_fds(lx, &t.fd0, &t.fd1, &eq) || t.fd1 == 255) lx->failed = true, lx->why = "bad |[n=m]";
    return t.kind = TK_PIPE, t;
  }
  case '<':
  case '>': {
    bool eq;
    t.kind = TK_REDIR;
    t.fd0 = c == '<' ? 0 : 1;
    t.rkind = c == '<' ? RC_FD_READ : RC_FD_WRITE;
    if (lx->p < lx->end && *lx->p == c && c == '>')
      lx->p++, t.rkind = RC_FD_APPEND;
    else if (lx->p < lx->end && *lx->p == '>' && c == '<')
      lx->p++, t.rkind = RC_FD_RDWR;
    else if (lx->p < lx->end && *lx->p == '<' && c == '<') // <<tag: a here document, read once its line ends
      lx->p++, t.rkind = RC_FD_HERE, lx->want_tag = true;
    if (!rc_lex_fds(lx, &t.fd0, &t.fd1, &eq)) lx->failed = true, lx->why = "bad >[n=m]";
    if (eq) t.kind = TK_DUP;
    return t;
  }
  case '\'': { // a quoted word: '' is a quote
    size_t n = 0;
    const char *s = lx->p;
    for (const char *q = s;; q++) {
      if (q >= lx->end) {
        lx->failed = lx->incomplete = true, lx->why = "unterminated quote";
        return t.kind = TK_EOF, t;
      }
      if (*q == '\n') lx->line++;
      if (*q == '\'' && (q + 1 >= lx->end || q[1] != '\'')) break;
      if (*q == '\'') q++;
      n++;
    }
    t.s = rc_lex_keep(lx, n);
    if (!t.s) return t.kind = TK_EOF, t;
    size_t k = 0;
    for (; *lx->p != '\'' || (lx->p + 1 < lx->end && lx->p[1] == '\''); lx->p++) {
      if (*lx->p == '\'') lx->p++;
      t.s[k++] = *lx->p;
    }
    lx->p++;
    t.s[k] = 0;
    t.kind = TK_WORD, t.len = k, t.quoted = true;
    return t;
  }
  default: break;
  }
  // A bare word: its glob characters marked.
  lx->p--;
  const char *s = lx->p;
  size_t n = 0;
  for (const char *q = s; q < lx->end && rc_wordchr(*q) && !rc_continues(q, lx->end); q++)
    n += (*q == '*' || *q == '?' || *q == '[' || *q == RC_GLOB) ? 2 : 1;
  t.s = rc_lex_keep(lx, n);
  if (!t.s) return t.kind = TK_EOF, t;
  size_t k = 0;
  for (; lx->p < lx->end && rc_wordchr(*lx->p) && !rc_continues(lx->p, lx->end); lx->p++) {
    if (*lx->p == '*' || *lx->p == '?' || *lx->p == '[' || *lx->p == RC_GLOB)
      t.s[k++] = RC_GLOB; // a mark doubled: itself
    t.s[k++] = *lx->p;
  }
  t.s[k] = 0;
  t.kind = TK_WORD, t.len = k;
  t.kw = rc_keyword(s, (size_t)(lx->p - s));
  return t;
}

static bool rc_wordish(rc_tok k) {
  return k == TK_WORD || k == TK_DOLLAR || k == TK_COUNT || k == TK_JOIN || k == TK_BACKQ;
}

// The next token, with rc's free carets: a word written right after a word
// (or a variable's name) is joined to it, as if by ^.
static rc_token rc_lex(rc_lexer *lx) {
  if (lx->has_pending) {
    lx->has_pending = false;
    lx->prev = lx->pending;
    return lx->pending;
  }
  bool name = lx->after_dollar, tag = lx->want_tag;
  rc_token t = rc_lex_raw(lx);
  t.end = lx->p;
  if (tag && t.kind == TK_WORD) { // a here document's tag: its body is read when the line ends, as rc's
    lx->want_tag = false;
    if (lx->nheres == RC_HERES) {
      lx->failed = true, lx->why = "too many here documents";
    } else {
      size_t k = 0; // the tag's text without its glob marks
      for (size_t i = 0; i < t.len; i++)
        if (t.s[i] != RC_GLOB || i + 1 == t.len || t.s[i + 1] == RC_GLOB) t.s[k++] = t.s[i];
      t.len = k;
      lx->heres[lx->nheres] = (rc_here){.tag = t.s, .tlen = t.len, .quoted = t.quoted};
      t.here = (uint8_t)++lx->nheres;
    }
  }
  if (name)
    t.fd1 = 1, t.kw = KW_NONE; // a variable's name: a subscript may follow, and it is never a keyword
  else if (t.kind == TK_WORD)
    t.fd1 = 0;
  // No caret after a keyword, as rc's lexer (echo for$x is two words).
  if (t.adj && lx->prev.kind == TK_WORD && (lx->prev.kw == KW_NONE || lx->prev.quoted) &&
      rc_wordish(t.kind) && !name) {
    lx->pending = t;
    lx->has_pending = true;
    rc_token caret = {.kind = TK_CARET, .line = t.line, .adj = true};
    lx->prev = caret;
    return caret;
  }
  lx->prev = t;
  return t;
}

// --- The parser (rc's syn.y, without recursion) ---
//
// A shunting-yard over commands, with nested contexts: one stack holds what
// is pending, a frame each, and a value stack the trees made so far. A
// prefix construct (if (...), while (...), for (...), !, @, a redirection or
// an assignment before a command) waits for the command after it; a binary
// one (|, &&, ||) for its right side; a list (the script, { ... }, ( ... ),
// `{ ... }) gathers commands until its terminator. rc's precedences, lowest
// first: the bodies of if, while, for and if not; && and ||; ! and @ (and a
// redirection or assignment before a command); |. Words nest too ($ $# $"
// ^ subscripts, ( ... ) lists, `{ ... }) and have frames of their own.

typedef enum rc_nk : uint8_t {
  N_WORD,
  N_DOL,
  N_COUNT,
  N_JOIN,
  N_SUB,
  N_CONC,
  N_BACKQ,
  N_PAREN,
  N_SIMPLE,
  N_SEQ,
  N_ASYNC,
  N_AND,
  N_OR,
  N_PIPE,
  N_BANG,
  N_SUBSHELL,
  N_BRACE,
  N_IF,
  N_IFNOT,
  N_FOR,
  N_WHILE,
  N_SWITCH,
  N_TWIDDLE,
  N_FN,
  N_ASSIGN,
  N_REDIR,
  N_DUP,
} rc_nk;

typedef struct rc_node {
  rc_nk kind;
  uint8_t fd0, fd1, rkind;
  uint32_t line;
  int32_t a, b, c; // children (-1: none)
  int32_t next;    // the next in a list of words or redirections
  const char *s;   // N_WORD
  size_t len;
} rc_node;

static constexpr int32_t RC_NONE = -1, RC_ALLARGS = -2; // RC_ALLARGS: for(i) loops over $*

typedef enum rc_fk : uint8_t {
  F_LIST,       // term: what ends it; a: what it has gathered (a N_SEQ chain)
  F_BRACE,      // { ... }
  F_IFCOND,     // if ( ... )
  F_WHILECOND,  // while ( ... )
  F_SWITCHWAIT, // switch word: its { next; a: the word
  F_SWITCHBODY, // a: the subject
  F_FNBODY,     // a: the names
  F_BACKQBODY,  // `{ ... }; b: the ifs words, or none
  F_BACKQWAIT,  // `word: its { next; a: the word
  F_PREFIX,     // op, prec; a, b, fd0, fd1, rkind: what it holds
  F_BIN,        // op, prec, fd0, fd1
  F_SIMPLE,     // a: its words' head, b: its redirections' head; c, d: their tails
  F_WORDS,      // purpose; term; a: head, c: tail; b: what it is for (a name, a variable)
  F_WANT,       // a word for purpose; a, fd0, rkind: what it belongs to
  F_DOL,        // op: N_DOL, N_COUNT or N_JOIN
  F_CONC,       // a: the left side
  F_FORWAIT,    // for(word: `in` or `)` next; a: the variable
} rc_fk;

typedef enum rc_purpose : uint8_t {
  P_PAREN,   // ( words ): a word
  P_SUB,     // $x( words ): a subscript; b: the name
  P_FORIN,   // for(i in words); b: the variable
  P_FNNAMES, // fn names { ... }
  P_TWIDDLE, // ~ subject patterns; b: the subject
  W_SWITCH,
  W_ASSIGN, // a: the name
  W_REDIR_PREFIX,
  W_REDIR_EPILOG,
  W_REDIR_SIMPLE,
  W_FORVAR,
  W_TWIDDLE,
  W_BACKQ, // `word { ... }: the ifs
} rc_purpose;

typedef struct rc_pframe {
  rc_fk kind;
  uint8_t op, prec, purpose, term;
  uint8_t fd0, fd1, rkind;
  int32_t a, b, c, d;
} rc_pframe;

enum : uint32_t { RC_PFRAMES = 256, RC_PVALS = 256 };

typedef struct rc_parser {
  rc_lexer lx;
  const char *last_end; // where the last token taken ends: a function body's text ends there
  rc_token look[2];
  uint32_t nlook;
  rc_node *nodes;
  uint32_t nnodes, cap;
  rc_pframe frames[RC_PFRAMES];
  uint32_t nframes;
  int32_t vals[RC_PVALS];
  uint32_t nvals;
  const char *why; // a syntax error, if any
  bool incomplete; // the text ended inside a construct: more may finish it
  uint32_t line;
} rc_parser;

static rc_token *rc_peek(rc_parser *p) {
  if (!p->nlook) p->look[p->nlook++] = rc_lex(&p->lx);
  return &p->look[0];
}

static rc_token *rc_peek2(rc_parser *p) {
  rc_peek(p);
  if (p->nlook < 2) p->look[p->nlook++] = rc_lex(&p->lx);
  return &p->look[1];
}

static rc_token rc_take(rc_parser *p) {
  rc_peek(p);
  rc_token t = p->look[0];
  p->look[0] = p->look[1];
  p->nlook--;
  p->line = t.line;
  p->last_end = t.end;
  return t;
}

static int32_t rc_node_new(rc_parser *p, rc_nk kind, int32_t a, int32_t b, int32_t c) {
  if (p->nnodes == p->cap) {
    p->why = "script too long";
    return RC_NONE;
  }
  p->nodes[p->nnodes] = (rc_node){.kind = kind, .a = a, .b = b, .c = c, .next = RC_NONE, .line = p->line};
  return (int32_t)p->nnodes++;
}

static bool rc_push(rc_parser *p, rc_pframe f) {
  if (p->nframes == RC_PFRAMES) return p->why = "nested too deeply", false;
  p->frames[p->nframes++] = f;
  return true;
}

static bool rc_pushval(rc_parser *p, int32_t v) {
  if (p->nvals == RC_PVALS) return p->why = "nested too deeply", false;
  p->vals[p->nvals++] = v;
  return true;
}

static int32_t rc_popval(rc_parser *p) { return p->nvals ? p->vals[--p->nvals] : RC_NONE; }

static rc_pframe *rc_top(rc_parser *p) { return p->nframes ? &p->frames[p->nframes - 1] : nullptr; }

static void rc_skipnl(rc_parser *p) {
  while (rc_peek(p)->kind == TK_NL) rc_take(p);
}

// Appends node n to a list whose head and tail are *head and *tail.
static void rc_append(rc_parser *p, int32_t *head, int32_t *tail, int32_t n) {
  if (n == RC_NONE) return;
  if (*head == RC_NONE)
    *head = n;
  else
    p->nodes[*tail].next = n;
  *tail = n;
}

// Builds what the frame on top makes of the value(s) it was waiting for.
static void rc_reduce_one(rc_parser *p) {
  rc_pframe f = p->frames[--p->nframes];
  int32_t n;
  if (f.kind == F_BIN) {
    int32_t b = rc_popval(p), a = rc_popval(p);
    n = rc_node_new(p, (rc_nk)f.op, a, b, RC_NONE);
    if (n != RC_NONE) p->nodes[n].fd0 = f.fd0, p->nodes[n].fd1 = f.fd1; // |[fd0=fd1]
  } else {                                                              // F_PREFIX
    int32_t cmd = rc_popval(p);
    if (f.op == N_FOR)
      n = rc_node_new(p, N_FOR, f.a, f.b, cmd);
    else if (f.op == N_ASSIGN)
      n = rc_node_new(p, N_ASSIGN, f.a, f.b, cmd);
    else if (f.op == N_REDIR)
      n = rc_node_new(p, N_REDIR, f.a, cmd, RC_NONE);
    else if (f.op == N_DUP)
      n = rc_node_new(p, N_DUP, RC_NONE, cmd, RC_NONE);
    else if (f.op == N_IF || f.op == N_WHILE)
      n = rc_node_new(p, (rc_nk)f.op, f.a, cmd, RC_NONE);
    else
      n = rc_node_new(p, (rc_nk)f.op, RC_NONE, cmd, RC_NONE); // N_IFNOT, N_BANG, N_SUBSHELL: b is the command
    if (n != RC_NONE) p->nodes[n].fd0 = f.fd0, p->nodes[n].fd1 = f.fd1, p->nodes[n].rkind = f.rkind;
  }
  rc_pushval(p, n);
}

// Reduces what binds at least as tightly as prec (-1: everything, to the list).
static void rc_reduce(rc_parser *p, int prec) {
  for (rc_pframe *f = rc_top(p); f && (f->kind == F_BIN || f->kind == F_PREFIX) && (int)f->prec >= prec;
       f = rc_top(p))
    rc_reduce_one(p);
}

static bool rc_is_terminator(rc_tok k) { return k == TK_EOF || k == TK_RBRACE || k == TK_RP; }

typedef enum rc_pstate : uint8_t { S_CMD, S_AFTERCMD, S_COLLECT, S_WORD, S_AFTERATOM, S_DONE } rc_pstate;

// A word is complete: to whatever wanted it. The next state.
static rc_pstate rc_word_done(rc_parser *p, int32_t w) {
  rc_pframe *f = rc_top(p);
  if (!f) return p->why = "unexpected word", S_DONE;
  switch (f->kind) {
  case F_SIMPLE:
  case F_WORDS: rc_append(p, &f->a, &f->c, w); return S_COLLECT;
  case F_WANT: {
    rc_pframe want = *f;
    p->nframes--;
    switch (want.purpose) {
    case W_SWITCH:
      rc_skipnl(p);
      if (rc_peek(p)->kind != TK_LBRACE) return p->why = "switch needs { after its word", S_DONE;
      rc_take(p);
      rc_push(p, (rc_pframe){.kind = F_SWITCHBODY, .a = w});
      rc_push(p, (rc_pframe){.kind = F_LIST, .term = TK_RBRACE, .a = RC_NONE});
      return S_CMD;
    case W_ASSIGN:
      rc_push(p, (rc_pframe){.kind = F_PREFIX, .op = N_ASSIGN, .prec = 2, .a = want.a, .b = w});
      return S_CMD;
    case W_REDIR_PREFIX:
      rc_push(p,
              (rc_pframe){
                  .kind = F_PREFIX, .op = N_REDIR, .prec = 2, .a = w, .fd0 = want.fd0, .rkind = want.rkind});
      return S_CMD;
    case W_REDIR_EPILOG: {
      int32_t cmd = rc_popval(p), n = rc_node_new(p, N_REDIR, w, cmd, RC_NONE);
      if (n != RC_NONE) p->nodes[n].fd0 = want.fd0, p->nodes[n].rkind = want.rkind;
      rc_pushval(p, n);
      return S_AFTERCMD;
    }
    case W_REDIR_SIMPLE: {
      rc_pframe *s = rc_top(p); // the F_SIMPLE it is in
      int32_t n = rc_node_new(p, N_REDIR, w, RC_NONE, RC_NONE);
      if (n != RC_NONE) p->nodes[n].fd0 = want.fd0, p->nodes[n].rkind = want.rkind;
      rc_append(p, &s->b, &s->d, n);
      return S_COLLECT;
    }
    case W_FORVAR: rc_push(p, (rc_pframe){.kind = F_FORWAIT, .a = w}); return S_CMD;
    case W_TWIDDLE:
      rc_push(p,
              (rc_pframe){
                  .kind = F_WORDS, .purpose = P_TWIDDLE, .term = TK_EOF, .a = RC_NONE, .b = w, .c = RC_NONE});
      return S_COLLECT;
    case W_BACKQ:
      if (rc_peek(p)->kind != TK_LBRACE) return p->why = "` needs { after its separators", S_DONE;
      rc_take(p);
      rc_push(p, (rc_pframe){.kind = F_BACKQBODY, .b = w});
      rc_push(p, (rc_pframe){.kind = F_LIST, .term = TK_RBRACE, .a = RC_NONE});
      return S_CMD;
    default: return p->why = "unexpected word", S_DONE;
    }
  }
  default: return p->why = "unexpected word", S_DONE;
  }
}

// The list on top has ended at its terminator: what it was part of goes on.
static rc_pstate rc_list_done(rc_parser *p) {
  rc_pframe list = p->frames[--p->nframes];
  rc_pframe *f = rc_top(p);
  if (!f) {
    rc_pushval(p, list.a);
    return S_DONE;
  }
  rc_pframe up = *f;
  p->nframes--;
  switch (up.kind) {
  case F_BRACE: rc_pushval(p, rc_node_new(p, N_BRACE, list.a, RC_NONE, RC_NONE)); return S_AFTERCMD;
  case F_IFCOND:
  case F_WHILECOND:
    rc_push(
        p, (rc_pframe){.kind = F_PREFIX, .op = up.kind == F_IFCOND ? N_IF : N_WHILE, .prec = 0, .a = list.a});
    rc_skipnl(p);
    return S_CMD;
  case F_SWITCHBODY: rc_pushval(p, rc_node_new(p, N_SWITCH, up.a, list.a, RC_NONE)); return S_AFTERCMD;
  case F_FNBODY: { // its body's text kept, { to }, for whatis and export (rc's fnstr)
    int32_t n = rc_node_new(p, N_FN, up.a, list.a, RC_NONE);
    if (n != RC_NONE) {
      const char *from = p->lx.base + up.c;
      p->nodes[n].s = from, p->nodes[n].len = (size_t)(p->last_end - from);
    }
    rc_pushval(p, n);
    return S_AFTERCMD;
  }
  case F_BACKQBODY: rc_pushval(p, rc_node_new(p, N_BACKQ, list.a, up.b, RC_NONE)); return S_AFTERATOM;
  default: return p->why = "misplaced list", S_DONE;
  }
}

static rc_pstate rc_cmd(rc_parser *p) {
  rc_token *t = rc_peek(p);
  rc_pframe *top = rc_top(p);
  if (t->kind == TK_NL || t->kind == TK_SEMI) {
    if (top && top->kind != F_LIST) { // an empty command: for a prefix waiting (a=b alone, if() alone)
      rc_pushval(p, RC_NONE);
      return S_AFTERCMD;
    }
    rc_take(p);
    return S_CMD;
  }
  if (rc_is_terminator(t->kind)) {
    if (top && top->kind != F_LIST) {
      rc_pushval(p, RC_NONE);
      return S_AFTERCMD;
    }
    if (!top || t->kind != top->term) {
      if (t->kind == TK_EOF) p->incomplete = true;
      return p->why = t->kind == TK_EOF ? "unexpected end" : "unbalanced brackets", S_DONE;
    }
    if (t->kind != TK_EOF) rc_take(p);
    return rc_list_done(p);
  }
  if (t->kind == TK_LBRACE) {
    rc_take(p);
    rc_push(p, (rc_pframe){.kind = F_BRACE});
    rc_push(p, (rc_pframe){.kind = F_LIST, .term = TK_RBRACE, .a = RC_NONE});
    return S_CMD;
  }
  if (t->kind == TK_REDIR) {
    rc_token r = rc_take(p);
    rc_push(p, (rc_pframe){.kind = F_WANT, .purpose = W_REDIR_PREFIX, .fd0 = r.fd0, .rkind = r.rkind});
    return S_WORD;
  }
  if (t->kind == TK_DUP) {
    rc_token r = rc_take(p);
    rc_push(p, (rc_pframe){.kind = F_PREFIX, .op = N_DUP, .prec = 2, .fd0 = r.fd0, .fd1 = r.fd1});
    return S_CMD;
  }
  if (t->kind == TK_WORD && !t->quoted && (t->kw == KW_IN || t->kw == KW_NOT))
    return p->why = "syntax error",
           S_DONE; // in and not begin no command: rc's grammar has them only after for( and if
  if (t->kind == TK_WORD && !t->quoted && t->kw != KW_NONE) {
    rc_token k = rc_take(p);
    switch (k.kw) {
    case KW_IF:
      if (rc_peek(p)->kind == TK_WORD && rc_peek(p)->kw == KW_NOT) {
        rc_take(p);
        rc_skipnl(p);
        rc_push(p, (rc_pframe){.kind = F_PREFIX, .op = N_IFNOT, .prec = 0});
        return S_CMD;
      }
      [[fallthrough]];
    case KW_WHILE:
      if (rc_peek(p)->kind != TK_LP) return p->why = "if and while need ( after them", S_DONE;
      rc_take(p);
      rc_push(p, (rc_pframe){.kind = k.kw == KW_IF ? F_IFCOND : F_WHILECOND});
      rc_push(p, (rc_pframe){.kind = F_LIST, .term = TK_RP, .a = RC_NONE});
      return S_CMD;
    case KW_FOR:
      if (rc_peek(p)->kind != TK_LP) return p->why = "for needs ( after it", S_DONE;
      rc_take(p);
      rc_push(p, (rc_pframe){.kind = F_WANT, .purpose = W_FORVAR});
      return S_WORD;
    case KW_SWITCH: rc_push(p, (rc_pframe){.kind = F_WANT, .purpose = W_SWITCH}); return S_WORD;
    case KW_FN:
      rc_push(p, (rc_pframe){
                     .kind = F_WORDS, .purpose = P_FNNAMES, .term = TK_LBRACE, .a = RC_NONE, .c = RC_NONE});
      return S_COLLECT;
    case KW_BANG: rc_push(p, (rc_pframe){.kind = F_PREFIX, .op = N_BANG, .prec = 2}); return S_CMD;
    case KW_SUBSHELL: rc_push(p, (rc_pframe){.kind = F_PREFIX, .op = N_SUBSHELL, .prec = 2}); return S_CMD;
    case KW_TWIDDLE: rc_push(p, (rc_pframe){.kind = F_WANT, .purpose = W_TWIDDLE}); return S_WORD;
    default: break;
    }
  }
  if (t->kind == TK_WORD && rc_peek2(p)->kind == TK_EQ) { // name=value [command]
    rc_token name = rc_take(p);
    rc_take(p);
    int32_t n = rc_node_new(p, N_WORD, RC_NONE, RC_NONE, RC_NONE);
    if (n != RC_NONE) p->nodes[n].s = name.s, p->nodes[n].len = name.len;
    rc_push(p, (rc_pframe){.kind = F_WANT, .purpose = W_ASSIGN, .a = n});
    return S_WORD;
  }
  rc_push(p, (rc_pframe){.kind = F_SIMPLE, .a = RC_NONE, .b = RC_NONE, .c = RC_NONE, .d = RC_NONE});
  return S_COLLECT;
}

static uint8_t rc_binop(rc_tok k) {
  if (k == TK_PIPE) return N_PIPE;
  return k == TK_ANDAND ? N_AND : N_OR;
}

static uint8_t rc_dolop(rc_tok k) {
  if (k == TK_DOLLAR) return N_DOL;
  return k == TK_COUNT ? N_COUNT : N_JOIN;
}

static rc_pstate rc_aftercmd(rc_parser *p) {
  rc_token *t = rc_peek(p);
  if (t->kind == TK_REDIR) {
    rc_token r = rc_take(p);
    rc_push(p, (rc_pframe){.kind = F_WANT, .purpose = W_REDIR_EPILOG, .fd0 = r.fd0, .rkind = r.rkind});
    return S_WORD;
  }
  if (t->kind == TK_DUP) {
    rc_token r = rc_take(p);
    int32_t cmd = rc_popval(p), n = rc_node_new(p, N_DUP, RC_NONE, cmd, RC_NONE);
    if (n != RC_NONE) p->nodes[n].fd0 = r.fd0, p->nodes[n].fd1 = r.fd1;
    rc_pushval(p, n);
    return S_AFTERCMD;
  }
  if (t->kind == TK_PIPE || t->kind == TK_ANDAND || t->kind == TK_OROR) {
    rc_token op = rc_take(p);
    int prec = op.kind == TK_PIPE ? 3 : 1;
    rc_reduce(p, prec);
    rc_push(p,
            (rc_pframe){
                .kind = F_BIN, .op = rc_binop(op.kind), .prec = (uint8_t)prec, .fd0 = op.fd0, .fd1 = op.fd1});
    rc_skipnl(p);
    return S_CMD;
  }
  rc_reduce(p, -1);
  rc_pframe *list = rc_top(p);
  if (!list || list->kind != F_LIST) return p->why = "syntax error", S_DONE;
  int32_t cmd = rc_popval(p);
  if (t->kind == TK_AMP) {
    rc_take(p);
    cmd = rc_node_new(p, N_ASYNC, cmd, RC_NONE, RC_NONE);
  } else if (t->kind == TK_SEMI || t->kind == TK_NL) {
    rc_take(p);
  } else if (!rc_is_terminator(t->kind)) {
    return p->why = "syntax error", S_DONE;
  }
  // The chain grows to the right, SEQ(first, SEQ(second, ...)), through its
  // last link (c: its node + 1), so it compiles in a stack of fixed depth.
  if (cmd == RC_NONE) return S_CMD;
  if (list->a == RC_NONE) {
    list->a = cmd;
  } else if (!list->c) {
    int32_t seq = rc_node_new(p, N_SEQ, list->a, cmd, RC_NONE);
    list->a = seq, list->c = seq + 1;
  } else {
    int32_t last = list->c - 1, seq = rc_node_new(p, N_SEQ, p->nodes[last].b, cmd, RC_NONE);
    if (seq != RC_NONE) p->nodes[last].b = seq, list->c = seq + 1;
  }
  return S_CMD;
}

// Words being gathered: for a simple command, a ( ) list, fn's names, ~'s patterns.
static rc_pstate rc_collect(rc_parser *p) {
  rc_pframe *f = rc_top(p);
  rc_token *t = rc_peek(p);
  bool list = f->kind == F_WORDS && f->term == TK_RP;
  if (list && t->kind == TK_NL) {
    rc_take(p);
    return S_COLLECT;
  }
  if (t->kind == TK_EQ && f->kind == F_SIMPLE && f->a != RC_NONE && p->nodes[f->a].next == RC_NONE &&
      f->b == RC_NONE) { // first=value: an assignment, its name any word ($x=1 too), as rc's grammar
    rc_take(p);
    int32_t name = f->a;
    p->nframes--;
    rc_push(p, (rc_pframe){.kind = F_WANT, .purpose = W_ASSIGN, .a = name});
    return S_WORD;
  }
  if (t->kind == TK_WORD || t->kind == TK_DOLLAR || t->kind == TK_COUNT || t->kind == TK_JOIN ||
      t->kind == TK_BACKQ || t->kind == TK_LP)
    return S_WORD;
  if (f->kind == F_SIMPLE && t->kind == TK_REDIR) {
    rc_token r = rc_take(p);
    rc_push(p, (rc_pframe){.kind = F_WANT, .purpose = W_REDIR_SIMPLE, .fd0 = r.fd0, .rkind = r.rkind});
    return S_WORD;
  }
  if (f->kind == F_SIMPLE && t->kind == TK_DUP) {
    rc_token r = rc_take(p);
    int32_t n = rc_node_new(p, N_DUP, RC_NONE, RC_NONE, RC_NONE);
    if (n != RC_NONE) p->nodes[n].fd0 = r.fd0, p->nodes[n].fd1 = r.fd1;
    rc_append(p, &f->b, &f->d, n);
    return S_COLLECT;
  }
  rc_pframe done = *f;
  if (done.kind == F_SIMPLE) {
    p->nframes--;
    if (done.a == RC_NONE && done.b == RC_NONE) return p->why = "syntax error", S_DONE;
    rc_pushval(p, rc_node_new(p, N_SIMPLE, done.a, done.b, RC_NONE));
    return S_AFTERCMD;
  }
  switch (done.purpose) {
  case P_PAREN:
  case P_SUB:
  case P_FORIN:
    if (t->kind != TK_RP) {
      if (t->kind == TK_EOF) p->incomplete = true;
      return p->why = "( without )", S_DONE;
    }
    rc_take(p);
    p->nframes--;
    if (done.purpose == P_PAREN) {
      rc_pushval(p, rc_node_new(p, N_PAREN, done.a, RC_NONE, RC_NONE));
      return S_AFTERATOM;
    }
    if (done.purpose == P_SUB) {
      rc_pushval(p, rc_node_new(p, N_SUB, done.b, done.a, RC_NONE));
      return S_AFTERATOM;
    }
    rc_skipnl(p); // for(i in words)
    rc_push(p, (rc_pframe){.kind = F_PREFIX, .op = N_FOR, .prec = 0, .a = done.b, .b = done.a});
    return S_CMD;
  case P_FNNAMES:
    p->nframes--;
    if (t->kind == TK_LBRACE) {
      rc_token lb = rc_take(p);
      rc_push(p, (rc_pframe){.kind = F_FNBODY, .a = done.a, .c = (int32_t)(lb.at - p->lx.base)});
      rc_push(p, (rc_pframe){.kind = F_LIST, .term = TK_RBRACE, .a = RC_NONE});
      return S_CMD;
    }
    rc_pushval(p, rc_node_new(p, N_FN, done.a, RC_NONE, RC_NONE)); // fn names: deletes them
    return S_AFTERCMD;
  case P_TWIDDLE:
    p->nframes--;
    rc_pushval(p, rc_node_new(p, N_TWIDDLE, done.b, done.a, RC_NONE));
    return S_AFTERCMD;
  default: return p->why = "syntax error", S_DONE;
  }
}

static rc_pstate rc_atom(rc_parser *p) {
  rc_token t = rc_take(p);
  switch (t.kind) {
  case TK_WORD: { // = is not one: rc's grammar has it only in an assignment
    int32_t n = rc_node_new(p, N_WORD, RC_NONE, RC_NONE, RC_NONE);
    if (n == RC_NONE) return S_DONE;
    p->nodes[n].s = t.s;
    p->nodes[n].len = t.len;
    p->nodes[n].fd1 = t.fd1;    // a variable's name
    p->nodes[n].fd0 = t.quoted; // a quoted word: never a switch's case
    p->nodes[n].rkind = t.here; // a here document's tag
    rc_pushval(p, n);
    return S_AFTERATOM;
  }
  case TK_DOLLAR:
  case TK_COUNT:
  case TK_JOIN: rc_push(p, (rc_pframe){.kind = F_DOL, .op = rc_dolop(t.kind)}); return S_WORD;
  case TK_BACKQ:
    if (rc_peek(p)->kind == TK_LBRACE) {
      rc_take(p);
      rc_push(p, (rc_pframe){.kind = F_BACKQBODY, .b = RC_NONE});
      rc_push(p, (rc_pframe){.kind = F_LIST, .term = TK_RBRACE, .a = RC_NONE});
      return S_CMD;
    }
    rc_push(p, (rc_pframe){.kind = F_WANT, .purpose = W_BACKQ});
    return S_WORD;
  case TK_LP:
    rc_push(p, (rc_pframe){.kind = F_WORDS, .purpose = P_PAREN, .term = TK_RP, .a = RC_NONE, .c = RC_NONE});
    return S_COLLECT;
  case TK_EOF: p->incomplete = true; return p->why = "unexpected end", S_DONE;
  default: return p->why = "expected a word", S_DONE;
  }
}

static rc_pstate rc_afteratom(rc_parser *p) {
  int32_t atom = rc_popval(p);
  for (rc_pframe *f = rc_top(p); f && f->kind == F_DOL; f = rc_top(p)) { // $ binds to the atom after it
    uint8_t op = f->op;
    p->nframes--;
    if (op == N_DOL && rc_peek(p)->kind == TK_SUBLP) { // $x( subscripts )
      rc_take(p);
      rc_push(p,
              (rc_pframe){
                  .kind = F_WORDS, .purpose = P_SUB, .term = TK_RP, .a = RC_NONE, .b = atom, .c = RC_NONE});
      return S_COLLECT;
    }
    atom = rc_node_new(p, (rc_nk)op, atom, RC_NONE, RC_NONE);
  }
  rc_pframe *f = rc_top(p);
  if (f && f->kind == F_CONC) {
    atom = rc_node_new(p, N_CONC, f->a, atom, RC_NONE);
    p->nframes--;
  }
  rc_token *next = rc_peek(p);
  if (next->kind == TK_CARET) {
    rc_take(p);
    rc_push(p, (rc_pframe){.kind = F_CONC, .a = atom});
    return S_WORD;
  }
  return rc_word_done(p, atom);
}

// for(var: then `in words)` or `)`.
static rc_pstate rc_forwait(rc_parser *p) {
  rc_pframe f = p->frames[--p->nframes];
  rc_token *t = rc_peek(p);
  if (t->kind == TK_WORD && t->kw == KW_IN && !t->quoted) {
    rc_take(p);
    rc_push(p, (rc_pframe){
                   .kind = F_WORDS, .purpose = P_FORIN, .term = TK_RP, .a = RC_NONE, .b = f.a, .c = RC_NONE});
    return S_COLLECT;
  }
  if (t->kind != TK_RP) return p->why = "for( needs in or )", S_DONE;
  rc_take(p);
  rc_skipnl(p);
  rc_push(p, (rc_pframe){.kind = F_PREFIX, .op = N_FOR, .prec = 0, .a = f.a, .b = RC_ALLARGS});
  return S_CMD;
}

// Parses text: the tree's root (RC_NONE for nothing), or RC_NONE with why set.
static int32_t rc_parse(rc_parser *p) {
  rc_push(p, (rc_pframe){.kind = F_LIST, .term = TK_EOF, .a = RC_NONE});
  rc_pstate s = S_CMD;
  for (uint64_t steps = 0; s != S_DONE && !p->why && steps < 10'000'000; steps++) {
    if (p->lx.failed) {
      p->why = p->lx.why;
      break;
    }
    rc_pframe *top = rc_top(p);
    if (s == S_CMD && top && top->kind == F_FORWAIT) {
      s = rc_forwait(p);
      continue;
    }
    switch (s) {
    case S_CMD: s = rc_cmd(p); break;
    case S_AFTERCMD: s = rc_aftercmd(p); break;
    case S_COLLECT: s = rc_collect(p); break;
    case S_WORD: s = rc_atom(p); break;
    case S_AFTERATOM: s = rc_afteratom(p); break;
    default: break;
    }
  }
  if (p->lx.failed && !p->why) p->why = p->lx.why;
  return p->why ? RC_NONE : rc_popval(p);
}

// --- The compiler (rc's code.c, without recursion) ---
//
// The tree becomes instructions for the machine, as rc's outcode makes them:
// words go onto lists on the machine's stack (Xmark starts one, Xword adds
// to it), and $ # " ^ and subscripts work on the lists on top. Each node is
// compiled in phases, an explicit stack of (node, phase) items holding what
// is pending: children are pushed after their parent's next phase, so they
// are compiled first.

typedef enum rc_op : uint8_t {
  X_MARK,   // a new list on the stack
  X_WORD,   // a: the string, b: its length: added to the top list
  X_DOL,    // the top list's names: their values onto the list below
  X_COUNT,  // their count
  X_JOIN,   // their values joined by spaces, one word
  X_SUB,    // the top list subscripts the name in the one below: onto the list below that
  X_CONC,   // the top two lists concatenated, onto the one below
  X_SIMPLE, // f0: async. The top list is a command: run it
  X_STAGE,  // f0/f1: the fds it pipes to the next/from the last; a: its redirections. The top list is a stage
  X_PIPELINE, // a: stages, f0: async
  X_ASSIGN,   // the top list names a variable, the one below its value
  X_LOCAL,    // as X_ASSIGN, a local of the frame, until X_UNLOCAL
  X_UNLOCAL,
  X_IF,       // a: where to go if $status is false (ifnot = it was)
  X_IFNOT,    // a: where to go unless the last if was false
  X_WASTRUE,  // ifnot = false
  X_TRUE,     // a: where to go if $status is false
  X_FALSE,    // a: where to go if $status is true
  X_JUMP,     // a
  X_BANG,     // $status negated
  X_FOR,      // a: where to go when the list on top is used up; the next word into the frame's newest local
  X_POPM,     // drops the top list
  X_FN,       // a: where its body ends; the top list names it (them); the body follows
  X_DELFN,    // the top list's functions removed
  X_RETURN,   // the frame ends
  X_QW,       // the top list joined by spaces into one word ("" for none): a subject of ~ or switch
  X_SETTRUE,  // $status true: while()'s empty condition
  X_MATCH,    // the top list (a subject) against the patterns below: $status
  X_CASE,     // a: where to go unless the subject (two lists down) matches the patterns on top
  X_BACKQ,    // fd 1 into a capture, until X_BACKQEND
  X_BACKQEND, // the capture split by the separators on top (or $ifs) into words, onto the list below
  X_REDIR,    // f0: fd, f1: kind; the top list is the file
  X_DUP,      // f0 = f1 (f1 255: closed)
  X_POPREDIR, // a: how many
  X_RDCMDS,   // the frame's reader: the next command read, compiled and run, then this again (rc's Xrdcmds)
  X_EFLAG,    // -e: exit unless $status is true
} rc_op;

typedef struct rc_inst {
  rc_op op;
  uint8_t f0, f1;
  uint32_t a, b;
  uint32_t line; // the source line it came from, for errors
} rc_inst;

struct rc_code {
  uint32_t refs; // the running frames and the functions that use it
  uint32_t n;
  rc_inst *inst;
  char *strings;
  char src[64]; // the file it came from, for errors at file:line
};

// Where an error is, as rc's pfln: file:line, or the file alone, into buf.
static size_t rc_where(const char *src, uint32_t line, char *buf, size_t cap) {
  size_t n = 0;
  for (const char *s = src; *s && n + 1 < cap; s++) buf[n++] = *s;
  if (line && n + 12 < cap) {
    char d[12];
    size_t k = sizeof d;
    do d[--k] = (char)('0' + line % 10);
    while (line /= 10);
    buf[n++] = ':';
    while (k < sizeof d) buf[n++] = d[k++];
  }
  buf[n] = 0;
  return n;
}

// A run-time error, as rc's Xerror1 and Xerror2: `where: a[: b]` for the host
// to show, $status `status` (nullptr: "error"), and the run ends.
// rc's own standard error, whatever a command's redirections are: rc's
// messages go there, as rc's err.
static void rc_errout(rc *r, const char *s, size_t n) {
  rc_fd fd = {.kind = RC_FD_INHERIT, .dup = 2};
  if (r->host.write) r->host.write(r->host.ctx, &fd, 2, s, n);
}

static void rc_fail(rc *r, const char *status, const char *a, const char *b) {
  uint32_t line = 0;
  const char *src = r->src;
  if (r->nframes) {
    const rc_frame *f = &r->frames[r->nframes - 1];
    if (f->pc && f->pc <= f->code->n) line = f->code->inst[f->pc - 1].line;
    if (f->code->src[0]) src = f->code->src;
  }
  char where[96];
  rc_where(src, line, where, sizeof where);
  rc_error(r, where, ": ");
  size_t n = 0;
  while (r->err[n]) n++;
  for (const char *x = a; x && *x && n + 1 < RC_ERR; x++) r->err[n++] = *x;
  if (b && n + 3 < RC_ERR) r->err[n++] = ':', r->err[n++] = ' ';
  for (const char *x = b; x && *x && n + 1 < RC_ERR; x++) r->err[n++] = *x;
  r->err[n] = 0;
  const char *st = status ? status : "error";
  rc_set_status(r, st, rc_strlen(st));
  r->failed = r->failset = true;
  rc_errout(r, r->err, n), rc_errout(r, "\n", 1);
}

typedef struct rc_compiler {
  rc *r;
  const rc_node *nodes;
  rc_inst *inst;
  uint32_t n, cap;
  char *str;
  size_t nstr, strcap;
  const char *why;
  uint32_t line;        // the line of the node being compiled
  const rc_here *heres; // the here documents' texts, by a tag word's rkind (plus 1)
  uint32_t nheres;
} rc_compiler;

static uint32_t rc_emit(rc_compiler *c, rc_op op, uint8_t f0, uint8_t f1, uint32_t a, uint32_t b) {
  if (c->n == c->cap) {
    c->why = "script too long";
    return 0;
  }
  c->inst[c->n] = (rc_inst){.op = op, .f0 = f0, .f1 = f1, .a = a, .b = b, .line = c->line};
  return c->n++;
}

static void rc_emit_word(rc_compiler *c, const char *s, size_t len) {
  if (c->strcap - c->nstr < len + 1) {
    c->why = "script too long";
    return;
  }
  memcpy(c->str + c->nstr, s, len);
  c->str[c->nstr + len] = 0;
  rc_emit(c, X_WORD, 0, 0, (uint32_t)c->nstr, (uint32_t)len);
  c->nstr += len + 1;
}

// A here document's redirection: its text as the word, then X_REDIR (b: quoted).
static void rc_emit_here(rc_compiler *c, const rc_node *rd) {
  uint32_t k = c->nodes[rd->a].rkind;
  if (!k || k > c->nheres || !c->heres[k - 1].read) {
    c->why = "here document never ended";
    return;
  }
  const rc_here *h = &c->heres[k - 1];
  rc_emit(c, X_MARK, 0, 0, 0, 0);
  rc_emit_word(c, h->body, h->blen);
  rc_emit(c, X_REDIR, rd->fd0, RC_FD_HERE, 0, h->quoted);
}

static void rc_patch(rc_compiler *c, uint32_t at) {
  if (at < c->n) c->inst[at].a = c->n;
}

typedef struct rc_citem {
  int32_t node;
  uint8_t phase;
  bool stage;            // a simple command that is a stage of a pipeline
  uint8_t out_fd, in_fd; // a stage's: what it pipes to the next stage, and from the one before (255: none)
  uint32_t at;           // a jump to patch, or where a loop starts
  int32_t cur;           // a list being walked
  uint32_t count;
  bool noe; // a condition's: -e does not apply in it (rc's outcode(c, 0))
} rc_citem;

enum : uint32_t { RC_CITEMS = 1024 };

// Is node n a case label: a simple command whose first word is `case`?
static bool rc_is_case(const rc_compiler *c, int32_t n) {
  if (n == RC_NONE || c->nodes[n].kind != N_SIMPLE || c->nodes[n].a == RC_NONE) return false;
  const rc_node *w = &c->nodes[c->nodes[n].a];
  return w->kind == N_WORD && !w->fd0 && rc_streq(w->s, w->len, "case", 4); // unquoted, as rc's iscase
}

// A switch's body as a list of its commands, in order (its N_SEQ chain
// flattened); a body longer than cap is an error, not cut short.
static uint32_t rc_flatten(rc_compiler *c, int32_t n, int32_t *out, uint32_t cap) {
  int32_t stack[64]; // the chain grows to the right (rc_aftercmd): it needs little
  uint32_t sp = 0, count = 0;
  if (n != RC_NONE) stack[sp++] = n;
  while (sp) {
    int32_t x = stack[--sp];
    if (c->nodes[x].kind == N_SEQ) {
      if (sp + 2 > sizeof stack / sizeof stack[0]) return c->why = "switch nested too deeply", 0;
      stack[sp++] = c->nodes[x].b; // right after left
      stack[sp++] = c->nodes[x].a;
    } else if (count == cap) {
      return c->why = "switch too long", 0;
    } else {
      out[count++] = x;
    }
  }
  return count;
}

static rc_op rc_dolinst(rc_nk k) {
  if (k == N_DOL) return X_DOL;
  return k == N_COUNT ? X_COUNT : X_JOIN;
}

enum : uint8_t { RC_ENDCMD = 200 }; // a compile item's phase: the command it names has been compiled

static bool rc_is_cmd(rc_nk k) { // a command, not a word
  return k != N_WORD && k != N_DOL && k != N_COUNT && k != N_JOIN && k != N_SUB && k != N_CONC &&
         k != N_PAREN && k != N_BACKQ;
}

// -e after a command, as rc's Xeflag, unless in a condition.
static void rc_eflag(rc_compiler *c, bool noe) {
  if (c->r->flag['e'] && !noe) rc_emit(c, X_EFLAG, 0, 0, 0, 0);
}

// As rc's outcode: a command other than if not and a sequence clears iflast
// as it starts, and sets it, once compiled, to whether it was an if; if not
// is refused unless it is set. 1: the item was the marker of a command's end;
// -1: refused (c->why); 0: go on with it.
static int rc_iflast(rc_compiler *c, const rc_citem *it, const rc_node *t, rc_citem *items, uint32_t *ni) {
  if (it->phase == RC_ENDCMD) {
    c->r->iflast = t->kind == N_IF;
    return 1;
  }
  if (it->phase == 0 && rc_is_cmd(t->kind) && t->kind != N_SEQ && t->kind != N_IFNOT) {
    c->r->iflast = false;
    if (*ni == RC_CITEMS) return c->why = "nested too deeply", -1;
    items[(*ni)++] = (rc_citem){.node = it->node, .phase = RC_ENDCMD};
  }
  if (it->phase == 0 && t->kind == N_IFNOT && !c->r->iflast)
    return c->why = "`if not' does not follow `if(...)'", -1;
  return 0;
}

static bool rc_compile_tree(rc_compiler *c, int32_t root) {
  static rc_citem items[RC_CITEMS];
  uint32_t ni = 0;
  bool noe = false; // the item being compiled is in a condition
#define RC_PUSH(nd, ph) RC_PUSHE(nd, ph, noe)
#define RC_PUSHE(nd, ph, cond)                                                                               \
  do {                                                                                                       \
    if (ni == RC_CITEMS) return c->why = "nested too deeply", false;                                         \
    items[ni++] = (rc_citem){.node = (nd), .phase = (ph), .noe = (cond)};                                    \
  } while (0)
#define RC_EFLAG() rc_eflag(c, noe)
  if (root != RC_NONE) RC_PUSH(root, 0);
  while (ni && !c->why) {
    rc_citem it = items[--ni];
    if (it.node == RC_NONE) continue;
    noe = it.noe;
    const rc_node *t = &c->nodes[it.node];
    if (t->line) c->line = t->line;
    int iflast = rc_iflast(c, &it, t, items, &ni);
    if (iflast < 0) return false;
    if (iflast > 0) continue;
    // Pushes the item back at its next phase, with what it keeps.
#define RC_AGAIN(ph)                                                                                         \
  do {                                                                                                       \
    it.phase = (ph);                                                                                         \
    items[ni++] = it;                                                                                        \
  } while (0)
    switch (t->kind) {
    case N_WORD: rc_emit_word(c, t->s, t->len); break;
    case N_DOL:
    case N_COUNT:
    case N_JOIN:
      if (it.phase == 0) {
        rc_emit(c, X_MARK, 0, 0, 0, 0);
        RC_AGAIN(1);
        RC_PUSH(t->a, 0);
      } else {
        rc_emit(c, rc_dolinst(t->kind), 0, 0, 0, 0);
      }
      break;
    case N_SUB: // $name(subscripts)
      if (it.phase == 0) {
        rc_emit(c, X_MARK, 0, 0, 0, 0);
        RC_AGAIN(1);
        RC_PUSH(t->a, 0);
      } else if (it.phase == 1) {
        rc_emit(c, X_MARK, 0, 0, 0, 0);
        it.cur = t->b;
        RC_AGAIN(2);
      } else if (it.cur == RC_NONE) { // each subscript word, then X_SUB
        rc_emit(c, X_SUB, 0, 0, 0, 0);
      } else {
        int32_t w = it.cur;
        it.cur = c->nodes[w].next;
        RC_AGAIN(2);
        RC_PUSH(w, 0);
      }
      break;
    case N_CONC:
      if (it.phase == 0) {
        rc_emit(c, X_MARK, 0, 0, 0, 0);
        RC_AGAIN(1);
        RC_PUSH(t->a, 0);
      } else if (it.phase == 1) {
        rc_emit(c, X_MARK, 0, 0, 0, 0);
        RC_AGAIN(2);
        RC_PUSH(t->b, 0);
      } else {
        rc_emit(c, X_CONC, 0, 0, 0, 0);
      }
      break;
    case N_PAREN: // its words, onto the list being made
      if (it.phase == 0) it.cur = t->a;
      if (it.cur != RC_NONE) {
        int32_t w = it.cur;
        it.cur = c->nodes[w].next;
        RC_AGAIN(1);
        RC_PUSH(w, 0);
      }
      break;
    case N_BACKQ: // `{body}: its separators, then the capture
      if (it.phase == 0) {
        rc_emit(c, X_MARK, 0, 0, 0, 0);
        if (t->b == RC_NONE) {
          rc_emit(c, X_MARK, 0, 0, 0, 0);
          rc_emit_word(c, "ifs", 3);
          rc_emit(c, X_DOL, 0, 0, 0, 0);
          RC_AGAIN(1);
        } else {
          RC_AGAIN(1);
          RC_PUSH(t->b, 0);
        }
      } else if (it.phase == 1) {
        rc_emit(c, X_BACKQ, 0, 0, 0, 0);
        RC_AGAIN(2);
        RC_PUSH(t->a, 0);
      } else {
        rc_emit(c, X_BACKQEND, 0, 0, 0, 0);
      }
      break;
    case N_SIMPLE: // its redirections, its words, the command, then the redirections undone
      if (it.phase == 0) {
        it.cur = t->b, it.count = 0;
        RC_AGAIN(1);
      } else if (it.phase == 1) { // the next redirection
        if (it.cur == RC_NONE) {
          rc_emit(c, X_MARK, 0, 0, 0, 0);
          it.cur = t->a;
          RC_AGAIN(2);
        } else {
          const rc_node *rd = &c->nodes[it.cur];
          int32_t r = it.cur;
          it.cur = rd->next;
          it.count++;
          if (rd->kind == N_DUP) {
            rc_emit(c, X_DUP, rd->fd0, rd->fd1, 0, 0);
            RC_AGAIN(1);
          } else if (rd->rkind == RC_FD_HERE) {
            rc_emit_here(c, rd);
            RC_AGAIN(1);
          } else {
            rc_emit(c, X_MARK, 0, 0, 0, 0);
            it.at = (uint32_t)r;
            RC_AGAIN(5); // then X_REDIR, then back to 1
            RC_PUSH(rd->a, 0);
          }
        }
      } else if (it.phase == 5) {
        const rc_node *rd = &c->nodes[it.at];
        rc_emit(c, X_REDIR, rd->fd0, rd->rkind, 0, 0);
        RC_AGAIN(1);
      } else if (it.phase == 2) { // the next word
        if (it.cur == RC_NONE) {
          if (it.stage) {
            rc_emit(c, X_STAGE, it.out_fd, it.in_fd, it.count, 0);
          } else {
            rc_emit(c, X_SIMPLE, 0, 0, 0, 0);
            RC_EFLAG();
          }
          if (it.count) rc_emit(c, X_POPREDIR, 0, 0, it.count, 0);
        } else {
          int32_t w = it.cur;
          it.cur = c->nodes[w].next;
          RC_AGAIN(2);
          RC_PUSH(w, 0);
        }
      }
      break;
    case N_SEQ:
      RC_PUSH(t->b, 0);
      RC_PUSH(t->a, 0);
      break;
    case N_BRACE:
    case N_SUBSHELL: RC_PUSH(t->kind == N_BRACE ? t->a : t->b, 0); break;
    case N_ASYNC:
    case N_PIPE: { // a pipeline of programs: each stage, leftmost first, then X_PIPELINE
      bool async = t->kind == N_ASYNC;
      int32_t chain = async ? t->a : it.node;
      if (async && chain != RC_NONE && c->nodes[chain].kind == N_SIMPLE) { // program &
        if (it.phase == 0) {
          RC_AGAIN(1);
          RC_PUSH(chain, 0);
        } else { // its X_SIMPLE, the last one emitted, made asynchronous
          for (uint32_t i = c->n; i-- > 0;)
            if (c->inst[i].op == X_SIMPLE) {
              c->inst[i].f0 = 1;
              break;
            }
        }
        break;
      }
      if (async && (chain == RC_NONE || c->nodes[chain].kind != N_PIPE))
        return c->why = "& runs programs only, not blocks or functions (for now)", false;
      if (it.phase == 1) {
        rc_emit(c, X_PIPELINE, (uint8_t)async, 0, it.count, 0);
        break;
      }
      int32_t right[32];        // the stages, right to left
      uint8_t fd0[32], fd1[32]; // the joints' descriptors, right to left
      uint32_t n = 0;
      int32_t x = chain;
      for (; x != RC_NONE && c->nodes[x].kind == N_PIPE; x = c->nodes[x].a) {
        if (n == 31) return c->why = "pipeline too long", false;
        right[n] = c->nodes[x].b, fd0[n] = c->nodes[x].fd0, fd1[n] = c->nodes[x].fd1, n++;
      }
      right[n++] = x; // the leftmost
      it.count = n;
      RC_AGAIN(1);
      for (uint32_t k = 0; k < n; k++) { // right to left onto the stack: the leftmost compiles first
        int32_t node = right[k];
        if (node == RC_NONE || c->nodes[node].kind != N_SIMPLE)
          return c->why = "a pipeline's stages must be programs, not blocks or functions (for now)", false;
        // Stage k from the right: it pipes out on joint k-1's fd0, in on joint k's fd1.
        RC_PUSH(node, 0);
        items[ni - 1].stage = true;
        items[ni - 1].out_fd = k > 0 ? fd0[k - 1] : 255;
        items[ni - 1].in_fd = k + 1 < n ? fd1[k] : 255;
      }
      break;
    }
    case N_AND:
    case N_OR:
      if (it.phase == 0) {
        RC_AGAIN(1);
        RC_PUSHE(t->a, 0, true);
      } else if (it.phase == 1) {
        it.at = rc_emit(c, t->kind == N_AND ? X_TRUE : X_FALSE, 0, 0, 0, 0);
        RC_AGAIN(2);
        RC_PUSH(t->b, 0);
      } else {
        rc_patch(c, it.at);
      }
      break;
    case N_BANG:
      if (it.phase == 0) {
        RC_AGAIN(1);
        RC_PUSH(t->b, 0);
      } else {
        rc_emit(c, X_BANG, 0, 0, 0, 0);
      }
      break;
    case N_IF:
      if (it.phase == 0) {
        RC_AGAIN(1);
        RC_PUSHE(t->a, 0, true);
      } else if (it.phase == 1) {
        it.at = rc_emit(c, X_IF, 0, 0, 0, 0);
        RC_AGAIN(2);
        RC_PUSH(t->b, 0);
      } else {
        rc_emit(c, X_WASTRUE, 0, 0, 0, 0);
        rc_patch(c, it.at);
      }
      break;
    case N_IFNOT:
      if (it.phase == 0) {
        it.at = rc_emit(c, X_IFNOT, 0, 0, 0, 0);
        RC_AGAIN(1);
        RC_PUSH(t->b, 0);
      } else {
        rc_patch(c, it.at);
      }
      break;
    case N_WHILE:
      if (it.phase == 0) {
        it.count = c->n; // where the condition starts
        RC_AGAIN(1);
        RC_PUSHE(t->a, 0, true);
      } else if (it.phase == 1) {
        if (c->n == it.count) rc_emit(c, X_SETTRUE, 0, 0, 0, 0); // while(): an empty condition is true
        it.at = rc_emit(c, X_TRUE, 0, 0, 0, 0);
        RC_AGAIN(2);
        RC_PUSH(t->b, 0);
      } else {
        rc_emit(c, X_JUMP, 0, 0, it.count, 0);
        rc_patch(c, it.at);
      }
      break;
    case N_FOR: // for(var in words) body: the words on the stack, the variable a local
      if (it.phase == 0) {
        rc_emit(c, X_MARK, 0, 0, 0, 0);
        if (t->b == RC_ALLARGS) {
          rc_emit(c, X_MARK, 0, 0, 0, 0);
          rc_emit_word(c, "*", 1);
          rc_emit(c, X_DOL, 0, 0, 0, 0);
          RC_AGAIN(2);
        } else {
          it.cur = t->b;
          RC_AGAIN(1);
        }
      } else if (it.phase == 1) { // each word
        if (it.cur == RC_NONE) {
          RC_AGAIN(2);
        } else {
          int32_t w = it.cur;
          it.cur = c->nodes[w].next;
          RC_AGAIN(1);
          RC_PUSH(w, 0);
        }
      } else if (it.phase == 2) {
        rc_emit(c, X_MARK, 0, 0, 0, 0); // the local's (empty) value
        rc_emit(c, X_MARK, 0, 0, 0, 0);
        RC_AGAIN(3);
        RC_PUSH(t->a, 0);
      } else if (it.phase == 3) {
        rc_emit(c, X_LOCAL, 0, 0, 0, 0);
        it.count = rc_emit(c, X_FOR, 0, 0, 0, 0);
        RC_AGAIN(4);
        RC_PUSH(t->c, 0);
      } else {
        rc_emit(c, X_JUMP, 0, 0, it.count, 0);
        rc_patch(c, it.count);
        rc_emit(c, X_UNLOCAL, 0, 0, 0, 0);
        rc_emit(c, X_POPM, 0, 0, 0, 0); // the used-up list
      }
      break;
    case N_ASSIGN: // name=value [command]
      if (it.phase == 0) {
        rc_emit(c, X_MARK, 0, 0, 0, 0);
        RC_AGAIN(1);
        RC_PUSH(t->b, 0);
      } else if (it.phase == 1) {
        rc_emit(c, X_MARK, 0, 0, 0, 0);
        RC_AGAIN(2);
        RC_PUSH(t->a, 0);
      } else if (it.phase == 2) {
        if (t->c == RC_NONE) {
          rc_emit(c, X_ASSIGN, 0, 0, 0, 0);
        } else {
          rc_emit(c, X_LOCAL, 0, 0, 0, 0);
          RC_AGAIN(3);
          RC_PUSH(t->c, 0);
        }
      } else {
        rc_emit(c, X_UNLOCAL, 0, 0, 0, 0);
      }
      break;
    case N_REDIR:
      if (it.phase == 0 && t->rkind == RC_FD_HERE) {
        rc_emit_here(c, t);
        RC_AGAIN(2);
        RC_PUSH(t->b, 0);
      } else if (it.phase == 0) {
        rc_emit(c, X_MARK, 0, 0, 0, 0);
        RC_AGAIN(1);
        RC_PUSH(t->a, 0);
      } else if (it.phase == 1) {
        rc_emit(c, X_REDIR, t->fd0, t->rkind, 0, 0);
        RC_AGAIN(2);
        RC_PUSH(t->b, 0);
      } else {
        rc_emit(c, X_POPREDIR, 0, 0, 1, 0);
      }
      break;
    case N_DUP:
      if (it.phase == 0) {
        rc_emit(c, X_DUP, t->fd0, t->fd1, 0, 0);
        RC_AGAIN(1);
        RC_PUSH(t->b, 0);
      } else {
        rc_emit(c, X_POPREDIR, 0, 0, 1, 0);
      }
      break;
    case N_TWIDDLE: // ~ subject patterns
      if (it.phase == 0) {
        rc_emit(c, X_MARK, 0, 0, 0, 0);
        it.cur = t->b;
        RC_AGAIN(1);
      } else if (it.phase == 1) {
        if (it.cur == RC_NONE) {
          rc_emit(c, X_MARK, 0, 0, 0, 0);
          RC_AGAIN(2);
          RC_PUSH(t->a, 0);
        } else {
          int32_t w = it.cur;
          it.cur = c->nodes[w].next;
          RC_AGAIN(1);
          RC_PUSH(w, 0);
        }
      } else {
        rc_emit(c, X_QW, 0, 0, 0, 0); // the subject one word, as rc's
        rc_emit(c, X_MATCH, 0, 0, 0, 0);
        RC_EFLAG();
      }
      break;
    case N_FN: // fn names { body }: the names, X_FN, the body inline, X_RETURN
      if (it.phase == 0) {
        rc_emit(c, X_MARK, 0, 0, 0, 0);
        it.cur = t->a;
        RC_AGAIN(1);
      } else if (it.phase == 1) {
        if (it.cur != RC_NONE) {
          int32_t w = it.cur;
          it.cur = c->nodes[w].next;
          RC_AGAIN(1);
          RC_PUSH(w, 0);
        } else if (t->b == RC_NONE) {
          rc_emit(c, X_DELFN, 0, 0, 0, 0);
        } else {
          uint32_t src = 0; // its text, in the strings, plus 1
          if (t->len && c->strcap - c->nstr >= t->len + 1) {
            memcpy(c->str + c->nstr, t->s, t->len), c->str[c->nstr + t->len] = 0;
            src = (uint32_t)c->nstr + 1, c->nstr += t->len + 1;
          }
          it.at = rc_emit(c, X_FN, 0, 0, 0, src);
          RC_AGAIN(2);
          RC_PUSH(t->b, 0);
        }
      } else {
        rc_emit(c, X_RETURN, 0, 0, 0, 0);
        rc_patch(c, it.at);
      }
      break;
    case N_SWITCH: { // the subject once; each case's patterns tested against it; X_POPM
      static int32_t body[4096];
      uint32_t n = rc_flatten(c, t->b, body, sizeof body / sizeof body[0]);
      if (it.phase == 0 && (!n || !rc_is_case(c, body[0]))) {
        c->why = "case missing in switch";
        break;
      }
      if (it.phase == 0) {
        rc_emit(c, X_MARK, 0, 0, 0, 0);
        it.cur = 0;   // the next command of the body
        it.at = 0;    // the pending X_CASE to patch (0: none)
        it.count = 0; // the X_JUMPs to the end, as a chain through their a's
        RC_AGAIN(6);
        RC_PUSH(t->a, 0);
        break;
      }
      if (it.phase == 6) { // the subject is on the stack: one word, as rc's
        rc_emit(c, X_QW, 0, 0, 0, 0);
        it.phase = 1;
      }
      if (it.phase == 3) {                          // a case's patterns are on the stack: its test
        it.at = rc_emit(c, X_CASE, 0, 0, 0, 0) + 1; // +1: 0 means none
        it.phase = 1;
      }
      if (it.phase == 4) { // after one of the body's commands
        it.phase = 1;
      }
      if ((uint32_t)it.cur >= n) { // the end: every jump to it, and the last case's miss, land here
        if (it.at) rc_patch(c, it.at - 1);
        for (uint32_t j = it.count; j;) {
          uint32_t next = c->inst[j - 1].a;
          c->inst[j - 1].a = c->n;
          j = next;
        }
        rc_emit(c, X_POPM, 0, 0, 0, 0);
        break;
      }
      int32_t cmd = body[it.cur++];
      if (rc_is_case(c, cmd)) {
        if (it.at) { // the case before: done, to the end; its miss, here
          uint32_t j = rc_emit(c, X_JUMP, 0, 0, it.count, 0);
          it.count = j + 1;
          rc_patch(c, it.at - 1);
        }
        rc_emit(c, X_MARK, 0, 0, 0, 0);
        int32_t w = c->nodes[c->nodes[cmd].a].next; // the patterns, after `case`
        it.phase = 3;
        items[ni++] = it;
        // Its pattern words, each pushed so they compile in order.
        int32_t ws[64];
        uint32_t nw = 0;
        for (; w != RC_NONE && nw < 64; w = c->nodes[w].next) ws[nw++] = w;
        if (w != RC_NONE) return c->why = "too many patterns in a case", false;
        for (uint32_t k = nw; k-- > 0;) RC_PUSH(ws[k], 0);
      } else {
        it.phase = 4;
        items[ni++] = it;
        RC_PUSH(cmd, 0);
      }
      break;
    }
    default: c->why = "cannot compile"; break;
    }
  }
#undef RC_PUSH
#undef RC_PUSHE
#undef RC_EFLAG
#undef RC_AGAIN
  return !c->why;
}

// --- Patterns and globbing (rc's glob.c) ---

// The length of the UTF-8 sequence at s[i] (n bytes), 1 when it is not one;
// its rune in *c (-1 if it is not one): vx-utf's strict decoding, the one rune
// library (ADR-0013).
static size_t rc_utf(const char *s, size_t i, size_t n, int32_t *c) {
  vx_rune r;
  size_t len = vx_chartorune(&r, s + i, n - i);
  bool bad = len == 1 && r == VX_RUNEERROR && (unsigned char)s[i] >= VX_RUNESELF;
  *c = bad ? -1 : (int32_t)r;
  return len ? len : 1;
}

// Whether s (n bytes) matches pattern p (m bytes), as rc's match: * ? and [
// are special only where RC_GLOB marks them (a doubled mark is the byte
// itself), ? and a class match one rune, and a class's range may be written
// either way round. No recursion: a * is retried from where it last matched,
// which is exact for patterns of *, ? and classes.
static bool rc_match(const char *s, size_t n, const char *p, size_t m) {
  size_t si = 0, pi = 0, star_p = SIZE_MAX, star_s = 0;
  while (si < n || pi < m) {
    if (pi + 1 < m && p[pi] == RC_GLOB && p[pi + 1] == '*') {
      star_p = pi += 2, star_s = si;
      continue;
    }
    if (si < n && pi < m) {
      int32_t c, pc;
      size_t sl = rc_utf(s, si, n, &c);
      if (p[pi] == RC_GLOB && pi + 1 < m && p[pi + 1] == '?') {
        pi += 2, si += sl;
        continue;
      }
      if (p[pi] == RC_GLOB && pi + 1 < m && p[pi + 1] == '[') { // [abc], [a-z], [~abc]
        size_t q = pi + 2;
        bool neg = q < m && p[q] == '~', hit = false, closed = false;
        if (neg) q++;
        while (q < m) {
          if (p[q] == ']') {
            closed = true;
            break;
          }
          int32_t lo, hi;
          q += rc_utf(p, q, m, &lo);
          hi = lo;
          if (q < m && p[q] == '-') {
            if (++q >= m) break;
            q += rc_utf(p, q, m, &hi);
            if (hi < lo) {
              int32_t t = lo;
              lo = hi, hi = t;
            }
          }
          if (lo <= c && c <= hi) hit = true;
        }
        if (closed && hit != neg) {
          pi = q + 1, si += sl;
          continue;
        }
      } else if (p[pi] == RC_GLOB && pi + 1 < m && p[pi + 1] == RC_GLOB) { // the byte itself
        if (s[si] == RC_GLOB) {
          pi += 2, si++;
          continue;
        }
      } else if (p[pi] != RC_GLOB) {
        size_t pl = rc_utf(p, pi, m, &pc);
        if (pl == sl && memcmp(p + pi, s + si, pl) == 0) {
          pi += pl, si += sl;
          continue;
        }
      }
    }
    if (star_p == SIZE_MAX || star_s >= n) return false; // no * to stretch, or nothing left to give it
    int32_t c;
    star_s += rc_utf(s, star_s, n, &c);
    pi = star_p, si = star_s;
  }
  return true;
}

static bool rc_globby(const char *s, size_t n) {
  for (size_t i = 0; i + 1 < n; i++)
    if (s[i] == RC_GLOB) return true;
  return false;
}

// A word with its glob marks taken out, in place.
static void rc_deglob(rc_word *w) { // as rc's: each mark goes, and the byte after it stays (a mark too)
  size_t k = 0;
  for (size_t i = 0; i < w->len; i++) {
    if (w->s[i] == RC_GLOB && i + 1 < w->len) i++;
    w->s[k++] = w->s[i];
  }
  w->len = k;
  w->s[k] = 0;
}

typedef struct rc_globber {
  rc *r;
  const char *pat; // this component's pattern
  size_t plen;
  const char *dir; // the directory being read, with its / (or empty)
  size_t dlen;
  rc_word *found, **tail;
  uint32_t n;
} rc_globber;

static void rc_glob_each(void *arg, const char *name, size_t n) {
  rc_globber *g = arg;
  bool dots =
      n && name[0] == '.' && (n == 1 || (n == 2 && name[1] == '.')); // . and .. only when asked for, as rc's
  if (dots && !(g->plen && g->pat[0] == '.')) return;
  if (!rc_match(name, n, g->pat, g->plen) || g->n >= 4096) return;
  rc_word *w = rc_alloc(g->r, sizeof *w + g->dlen + n + 2); // room for the '/' rc_glob may add
  if (!w) return;
  memcpy(w->s, g->dir, g->dlen);
  memcpy(w->s + g->dlen, name, n);
  w->len = g->dlen + n;
  *g->tail = w, g->tail = &w->next, g->n++;
}

// Sorts words in place (insertion sort, by bytes: globs give few).
static rc_word *rc_sortwords(rc_word *list) {
  rc_word *sorted = nullptr;
  while (list) {
    rc_word *w = list, **at = &sorted;
    list = list->next;
    while (*at) {
      size_t n = (*at)->len < w->len ? (*at)->len : w->len;
      int c = memcmp((*at)->s, w->s, n);
      if (c > 0 || (c == 0 && (*at)->len > w->len)) break;
      at = &(*at)->next;
    }
    w->next = *at, *at = w;
  }
  return sorted;
}

// A word expanded by globbing: the names it matches, sorted; itself, its
// marks taken out, if none (as rc does). Each /-separated component is
// matched in turn against the directories the one before matched.
static rc_word *rc_glob(rc *r, rc_word *w) {
  if (!rc_globby(w->s, w->len) || !r->host.readdir) {
    rc_deglob(w);
    return w;
  }
  rc_word *paths = rc_newword(r, w->s[0] == '/' ? "/" : "", w->s[0] == '/');
  size_t at = w->s[0] == '/';
  bool globbed = false, plain_after = false; // a pattern matched, and a plain component came after it
  while (at < w->len && paths) {
    size_t end = at;
    while (end < w->len && w->s[end] != '/') end++;
    bool glob = rc_globby(w->s + at, end - at);
    plain_after = globbed && !glob;
    globbed = globbed || glob;
    rc_word *next = nullptr, **tail = &next;
    for (rc_word *pth = paths; pth; pth = pth->next) {
      if (!rc_globby(w->s + at, end - at)) { // a plain component: just joined on
        rc_word *x = rc_alloc(r, sizeof *x + pth->len + (end - at) + 2);
        if (!x) break;
        memcpy(x->s, pth->s, pth->len);
        memcpy(x->s + pth->len, w->s + at, end - at);
        x->len = pth->len + (end - at);
        *tail = x, tail = &x->next;
        continue;
      }
      rc_globber g = {
          .r = r, .pat = w->s + at, .plen = end - at, .dir = pth->s, .dlen = pth->len, .tail = tail};
      r->host.readdir(r->host.ctx, pth->len ? pth->s : ".", pth->len ? pth->len : 1, rc_glob_each, &g);
      tail = g.tail;
    }
    rc_freewords(r, paths);
    paths = next;
    for (rc_word *x = paths; x && end < w->len; x = x->next) { // a / after each, for the next component
      x->s[x->len++] = '/';
      x->s[x->len] = 0;
    }
    at = end + 1;
  }
  if (plain_after && r->host.exists) { // as rc's globdir: what follows the last pattern must exist
    rc_word *kept = nullptr, **tail = &kept;
    while (paths) {
      rc_word *x = paths;
      paths = x->next, x->next = nullptr;
      if (r->host.exists(r->host.ctx, x->s, x->len))
        *tail = x, tail = &x->next;
      else
        rc_free(r, x);
    }
    paths = kept;
  }
  if (!paths) {
    rc_deglob(w);
    return w;
  }
  rc_freewords(r, w);
  return rc_sortwords(paths);
}

// --- The machine (rc's exec.c) ---

static rc_list *rc_toplist(rc *r) { return r->sp ? &r->stack[r->sp - 1] : nullptr; }

static void rc_listadd(rc_list *l, rc_word *w) {
  if (!w) return;
  while (w) {
    rc_word *next = w->next;
    w->next = nullptr;
    if (l->tail)
      l->tail->next = w;
    else
      l->head = w;
    l->tail = w;
    l->n++;
    w = next;
  }
}

static bool rc_mark(rc *r) {
  if (r->sp == RC_STACK) return rc_fail(r, nullptr, "stack overflow", nullptr), false;
  r->stack[r->sp++] = (rc_list){};
  return true;
}

static rc_word *rc_poplist(rc *r) { // the top list's words (the caller's), the list gone
  if (!r->sp) return nullptr;
  return r->stack[--r->sp].head;
}

// Every word of a list globbed, in place.
static rc_word *rc_globlist(rc *r, rc_word *w) {
  rc_word *out = nullptr;
  rc_list l = {};
  (void)out;
  while (w) {
    rc_word *next = w->next;
    w->next = nullptr;
    rc_listadd(&l, rc_glob(r, w));
    w = next;
  }
  return l.head;
}

static bool rc_has(const char *s, size_t n, char c) {
  for (size_t i = 0; i < n; i++)
    if (s[i] == c) return true;
  return false;
}

static void rc_degloblist(rc_word *w) {
  for (; w; w = w->next) rc_deglob(w);
}

// Redirections from..to of the stack applied to fds, in order.
static void rc_apply_redirs(const rc *r, rc_fd *fds, uint32_t from, uint32_t to) {
  for (uint32_t i = from; i < to && i < r->nredirs; i++) {
    const rc_redir *d = &r->redirs[i];
    if (d->fd >= RC_FDS) continue;
    if (d->to.kind == RC_FD_DUP && d->to.dup < RC_FDS)
      fds[d->fd] = fds[d->to.dup]; // a copy of what it is now
    else
      fds[d->fd] = d->to;
  }
}

// The descriptors a command gets: the redirection stack applied, in order.
static void rc_fds(const rc *r, rc_fd *fds) {
  for (uint32_t i = 0; i < RC_FDS; i++) fds[i] = (rc_fd){.kind = RC_FD_INHERIT, .dup = (uint8_t)i};
  rc_apply_redirs(r, fds, 0, r->nredirs);
}

// Output of the shell's own (a builtin's): to a capture, or the host.
static void rc_write(rc *r, uint32_t which, const char *s, size_t n) {
  rc_fd fds[RC_FDS];
  rc_fds(r, fds);
  const rc_fd *fd = &fds[which < RC_FDS ? which : 1];
  if (fd->kind == RC_FD_CAPTURE && fd->dup < r->ncaptures) {
    rc_capture *cap = &r->captures[fd->dup];
    if (cap->len + n > cap->cap) {
      size_t ncap = (cap->len + n) * 2 + 256;
      char *more = rc_alloc(r, ncap);
      if (!more) return;
      if (cap->buf) memcpy(more, cap->buf, cap->len), rc_free(r, cap->buf);
      cap->buf = more, cap->cap = ncap;
    }
    memcpy(cap->buf + cap->len, s, n);
    cap->len += n;
    return;
  }
  if (r->host.write) r->host.write(r->host.ctx, fd, which, s, n);
}

[[maybe_unused]] static void rc_print(rc *r, uint32_t fd, const char *s) { rc_write(r, fd, s, rc_strlen(s)); }

// Captured output from a program run into a capture: the host calls this (rc.h).
[[maybe_unused]] static void rc_capture_write(rc *r, const rc_fd *fd, const char *s, size_t n) {
  if (fd->kind != RC_FD_CAPTURE || fd->dup >= r->ncaptures) return;
  rc_capture *cap = &r->captures[fd->dup];
  if (cap->len + n > cap->cap) {
    size_t ncap = (cap->len + n) * 2 + 256;
    char *more = rc_alloc(r, ncap);
    if (!more) return;
    if (cap->buf) memcpy(more, cap->buf, cap->len), rc_free(r, cap->buf);
    cap->buf = more, cap->cap = ncap;
  }
  memcpy(cap->buf + cap->len, s, n);
  cap->len += n;
}

static void rc_code_release(rc *r, rc_code *c) {
  if (!c || --c->refs) return;
  rc_free(r, c->inst);
  rc_free(r, c->strings);
  rc_free(r, c);
}

static void rc_freelocals(rc *r, rc_var *v) {
  while (v) {
    rc_var *next = v->next;
    rc_freewords(r, v->val);
    rc_code_release(r, v->fn);
    rc_free(r, v);
    v = next;
  }
}

// A pipeline's stages, gathered by X_STAGE until X_PIPELINE runs them: its
// own, the last it says, so a pipeline in a stage's `{} runs alone. A file
// a gathered stage was given stays open until its pipeline has run, though
// the redirection that opened it is undone at once (rc_pop_redirs): each
// such close waits here, with how many stages were gathered then.
typedef struct rc_stage {
  rc_command cmd;
} rc_stage;

static constexpr uint32_t RC_STAGES = 64;
static rc_stage rc_stages[RC_STAGES];
static uint32_t rc_nstages;
static struct {
  uint32_t handle, level;
} rc_closes[2 * RC_STAGES];
static uint32_t rc_ncloses;

// The stages from base on let go, and the files only they used closed.
static void rc_free_stages(rc *r, uint32_t base) {
  for (uint32_t i = base; i < rc_nstages; i++) rc_freewords(r, (rc_word *)rc_stages[i].cmd.argv);
  if (base < rc_nstages) rc_nstages = base;
  uint32_t kept = 0;
  for (uint32_t i = 0; i < rc_ncloses; i++) {
    if (rc_closes[i].level > base)
      r->host.close(r->host.ctx, rc_closes[i].handle);
    else
      rc_closes[kept++] = rc_closes[i];
  }
  rc_ncloses = kept;
}

static void rc_pop_redirs(rc *r, uint32_t to) {
  while (r->nredirs > to) {
    rc_redir *d = &r->redirs[--r->nredirs];
    if (d->path && r->host.close) { // a file the host opened: closed, or once a stage given it has run
      if (rc_nstages && rc_ncloses < sizeof rc_closes / sizeof rc_closes[0])
        rc_closes[rc_ncloses++] = (typeof(rc_closes[0])){d->to.handle, rc_nstages};
      else
        r->host.close(r->host.ctx, d->to.handle);
    }
    rc_freewords(r, d->path);
    d->path = nullptr;
  }
}

static bool rc_push_frame(rc *r, rc_code *code, uint32_t pc, rc_var *locals) {
  if (r->nframes == RC_FRAMES) {
    rc_fail(r, nullptr, "functions nested too deeply", nullptr);
    rc_freelocals(r, locals);
    return false;
  }
  code->refs++;
  r->frames[r->nframes++] = (rc_frame){
      .code = code, .pc = pc, .locals = locals, .redirs = r->nredirs, .sp = r->sp, .ncaptures = r->ncaptures};
  return true;
}

static void rc_reader_free(rc *r, rc_reader *rd);

static void rc_pop_frame(rc *r) {
  rc_frame *f = &r->frames[--r->nframes];
  rc_freelocals(r, f->locals);
  rc_pop_redirs(r, f->redirs);
  rc_code_release(r, f->code);
  rc_reader_free(r, f->rd);
}

static rc_var *rc_newlocal(rc *r, const char *name, size_t n, rc_word *val) {
  rc_var *v = rc_alloc(r, sizeof *v + n + 1);
  if (!v) return rc_freewords(r, val), nullptr;
  memcpy(v->name, name, n);
  v->val = val;
  return v;
}

// --- Reading commands as they come (rc's Xrdcmds) ---

static rc_code *rc_compile_text(rc *r, const char *text, size_t len, uint32_t line, bool *incomplete);

struct rc_reader {
  char *text;           // a file's whole text, or what has been read of standard input
  size_t len, cap, pos; // its length, its buffer's size, and what has been read of it
  uint32_t line;        // the lines read so far
  bool interactive;     // -i: prompts, and an error goes back to it rather than ending everything
  bool tty;             // its text comes a line at a time from rc's standard input
  bool whole;           // -b: the whole text compiled at once
  bool quiet;           // -q: -e does not apply to it
  bool eof;
  char name[64]; // for errors: file:line
};

static rc_reader *rc_reader_new(rc *r, const char *name, size_t n) {
  rc_reader *rd = rc_alloc(r, sizeof *rd);
  if (!rd) return nullptr;
  for (size_t k = 0; k < n && k + 1 < sizeof rd->name; k++) rd->name[k] = name[k];
  return rd;
}

static void rc_reader_free(rc *r, rc_reader *rd) {
  if (!rd) return;
  rc_free(r, rd->text);
  rc_free(r, rd);
}

// A frame that reads from rd (which it takes), with locals (which it takes).
static bool rc_push_reader(rc *r, rc_reader *rd, rc_var *locals) {
  if (!rd) return rc_freelocals(r, locals), false;
  if (!rc_push_frame(r, r->rdcode, 0, locals)) return rc_reader_free(r, rd), false;
  r->frames[r->nframes - 1].rd = rd;
  return true;
}

// Writes w as rc quotes a word (%q): bare when it can be, else in '' with '' for a quote.
static void rc_errword(rc *r, const char *s, size_t n) {
  bool bare = n > 0;
  for (size_t i = 0; i < n && bare; i++) bare = rc_wordchr(s[i]) && s[i] != RC_GLOB;
  if (bare) return rc_errout(r, s, n);
  rc_errout(r, "'", 1);
  for (size_t i = 0; i < n; i++) {
    if (s[i] == '\'') rc_errout(r, "'", 1);
    rc_errout(r, s + i, 1);
  }
  rc_errout(r, "'", 1);
}

static void rc_errwords(rc *r, const rc_word *w) { // rc's %v
  for (; w; w = w->next) {
    rc_errword(r, w->s, w->len);
    rc_errout(r, w->next ? " " : "", w->next ? 1 : 0);
  }
}

// One more line of rd's standard input onto its text: false at the end.
static bool rc_reader_more(rc *r, rc_reader *rd, bool first) {
  if (rd->eof || !r->host.read_line) return rd->eof = true, false;
  if (rd->interactive) { // the prompt: $prompt's first word for a command, its second for a line that goes on
    const rc_word *pr = rc_getvar(r, "prompt");
    const rc_word *use = pr;
    if (!first) use = pr ? pr->next : nullptr;
    const char *def = first ? "% " : "\t";
    if (use)
      rc_errout(r, use->s, use->len);
    else
      rc_errout(r, def, rc_strlen(def));
  }
  if (rd->cap - rd->len < 4096) { // room for a line
    size_t cap = rd->cap ? rd->cap * 2 : 8192;
    if (cap > 1024ul * 1024) return rc_errout(r, "rc: line too long\n", 18), rd->eof = true, false;
    char *more = rc_alloc(r, cap);
    if (!more) return rd->eof = true, false;
    if (rd->len) memcpy(more, rd->text, rd->len);
    rc_free(r, rd->text);
    rd->text = more, rd->cap = cap;
  }
  int64_t n = r->host.read_line(r->host.ctx, rd->text + rd->len, rd->cap - rd->len);
  if (n <= 0) return rd->eof = true, false;
  rd->len += (size_t)n;
  return true;
}

static void rc_rdcmds(rc *r, rc_frame *f) {
  rc_reader *rd = f->rd;
  if (r->flag['s'] && !rc_truestatus(r)) { // -s: a status that is not true, before the next command
    rc_errout(r, "status=", 7);
    rc_errwords(r, rc_getvar(r, "status"));
    rc_errout(r, "\n", 1);
  }
  if (rd->tty && rd->pos == rd->len) rd->pos = rd->len = 0; // what was run, let go
  size_t start = rd->pos;
  uint32_t line0 = rd->line + 1;
  rc_code *code = nullptr;
  bool incomplete = false;
  for (;;) {
    if (rd->pos == rd->len && (!rd->tty || !rc_reader_more(r, rd, rd->pos == start))) break;
    size_t from = rd->pos;
    if (rd->whole) {
      rd->pos = rd->len;
    } else {
      while (rd->pos < rd->len && rd->text[rd->pos] != '\n') rd->pos++;
      if (rd->pos < rd->len) rd->pos++;
    }
    for (size_t k = from; k < rd->pos; k++) rd->line += rd->text[k] == '\n';
    if (r->flag['v'] || r->flag['V']) rc_errout(r, rd->text + from, rd->pos - from); // -v: input as read
    char was[sizeof r->src];
    memcpy(was, r->src, sizeof was);
    memcpy(r->src, rd->name, sizeof r->src); // what it compiles names its file
    bool e = r->flag['e'];
    if (rd->quiet) r->flag['e'] = false; // . -q: no -e in it, as rc's
    code = rc_compile_text(r, rd->text + start, rd->pos - start, line0, &incomplete);
    r->flag['e'] = e;
    memcpy(r->src, was, sizeof was);
    if (code || !incomplete) break;
  }
  if (!code && start == rd->pos) return; // the end: the frame returns
  if (!code) { // a syntax error, or the end inside a construct: said, and in $status
    if (incomplete && rd->pos == rd->len) {
      char where[96];
      size_t n = rc_where(rd->name, rd->line, where, sizeof where);
      rc_errout(r, where, n), rc_errout(r, ": unexpected end of file\n", 25);
      rc_set_status(r, "unexpected end of file", 22);
      r->incomplete = true;
    } else {
      rc_errout(r, r->err, rc_strlen(r->err)), rc_errout(r, "\n", 1);
      r->syntax = true;
    }
    if (rd->interactive && !rd->eof) f->pc--; // the next command, as rc's
    return;
  }
  f->pc--; // back for the next command once this one has run
  rc_push_frame(r, code, 0, nullptr);
  rc_code_release(r, code);
}

// rc's own builtins, by name (rc's Builtin[]: cd and the namespace's are the host's).
static const char *const RC_BUILTINS[] = {".",    "builtin", "eval", "exec",   "exit",
                                          "flag", "shift",   "wait", "whatis", nullptr};

static bool rc_is_builtin(const rc *r, const char *s, size_t n) {
  for (const char *const *b = RC_BUILTINS; *b; b++)
    if (rc_streq(s, n, *b, rc_strlen(*b))) return true;
  for (const char *const *b = r->host.builtin_names; b && *b; b++)
    if (rc_streq(s, n, *b, rc_strlen(*b))) return true;
  return false;
}

// A word written on fd 1 as rc's %q quotes it.
static void rc_outword(rc *r, const char *s, size_t n) {
  bool bare = n > 0;
  for (size_t i = 0; i < n && bare; i++) bare = rc_wordchr(s[i]) && s[i] != RC_GLOB;
  if (bare) return rc_write(r, 1, s, n);
  rc_write(r, 1, "'", 1);
  for (size_t i = 0; i < n; i++) {
    if (s[i] == '\'') rc_write(r, 1, "'", 1);
    rc_write(r, 1, s + i, 1);
  }
  rc_write(r, 1, "'", 1);
}

// whatis name ..., as rc's execwhatis: each name's value (x=val, or
// x=(a 'b c')), then its function (fn name {body}), or builtin name, or
// the program $path finds; $status "not found" for a name that is none.
static void rc_whatis(rc *r, rc_word *argv) {
  if (!argv->next) return rc_fail(r, nullptr, "Usage: whatis name ...", nullptr);
  rc_set_status(r, "", 0);
  for (rc_word *a = argv->next; a; a = a->next) {
    rc_var *v = rc_var_find(r, a->s, a->len, false);
    bool found = v && v->val;
    if (found) {
      rc_write(r, 1, a->s, a->len), rc_write(r, 1, "=", 1);
      if (!v->val->next) {
        rc_outword(r, v->val->s, v->val->len);
      } else {
        for (rc_word *w = v->val; w; w = w->next)
          rc_write(r, 1, w == v->val ? "(" : " ", 1), rc_outword(r, w->s, w->len);
        rc_write(r, 1, ")", 1);
      }
      rc_write(r, 1, "\n", 1);
    }
    rc_var *g = rc_gvar_find(r, a->s, a->len, false);
    if (g && g->fn) {
      rc_write(r, 1, "fn ", 3), rc_outword(r, a->s, a->len), rc_write(r, 1, " ", 1);
      const char *src = g->fnsrc ? g->fnsrc : "{}";
      rc_write(r, 1, src, rc_strlen(src)), rc_write(r, 1, "\n", 1);
      continue;
    }
    if (rc_is_builtin(r, a->s, a->len)) {
      rc_write(r, 1, "builtin ", 8), rc_write(r, 1, a->s, a->len), rc_write(r, 1, "\n", 1);
      continue;
    }
    bool here = a->s[0] == '/' || (a->len > 1 && a->s[0] == '.' && a->s[1] == '/');
    const rc_word *dirs = here ? nullptr : rc_getvar(r, "path");
    rc_word as_is = {.len = 0};
    if (!dirs) dirs = &as_is;
    bool hit = false;
    for (const rc_word *d = dirs; d && !hit && r->host.exists; d = d->next) {
      char path[512];
      size_t pn = 0;
      if (d->len && !(d->len == 1 && d->s[0] == '.') && d->len + 1 < sizeof path) {
        memcpy(path, d->s, d->len), pn = d->len;
        if (path[pn - 1] != '/') path[pn++] = '/';
      }
      if (pn + a->len >= sizeof path) continue;
      memcpy(path + pn, a->s, a->len), pn += a->len;
      if ((hit = r->host.exists(r->host.ctx, path, pn))) rc_write(r, 1, path, pn), rc_write(r, 1, "\n", 1);
    }
    if (!hit && !found) rc_set_status(r, "not found", 9);
  }
}

// rc's builtins: the ones the language needs. True if argv[0] is one.
static bool rc_builtin(rc *r, rc_word *argv, uint32_t argc) {
  const char *name = argv->s;
  size_t n = argv->len;
  if (rc_streq(name, n, "exit", 4)) { // exit [status]: with no status, $status as it is (rc's execexit)
    if (argc > 2) rc_errout(r, "Usage: exit [status]\nExiting anyway\n", 34);
    if (argc > 1) rc_set_status(r, argv->next->s, argv->next->len);
    r->exiting = true;
    return true;
  }
  if (rc_streq(name, n, "shift", 5)) { // shift [n]: from $*, n as atoi reads it (rc's execshift)
    if (argc > 2) {
      rc_errout(r, "Usage: shift [n]\n", 17);
      rc_set_status(r, "shift usage", 11);
      return true;
    }
    int64_t k = 1;
    if (argc > 1) {
      const rc_word *a = argv->next;
      size_t i = 0;
      bool neg = i < a->len && a->s[i] == '-';
      if (neg || (i < a->len && a->s[i] == '+')) i++;
      for (k = 0; i < a->len && a->s[i] >= '0' && a->s[i] <= '9' && k < 1'000'000; i++)
        k = k * 10 + (a->s[i] - '0');
      if (neg) k = -k;
    }
    rc_var *star = rc_var_find(r, "*", 1, true);
    for (; k > 0 && star && star->val; k--) {
      rc_word *first = star->val;
      star->val = first->next;
      rc_free(r, first);
    }
    rc_set_status(r, "", 0);
    return true;
  }
  if (rc_streq(name, n, "whatis", 6)) return rc_whatis(r, argv), true;
  if (rc_streq(name, n, "flag", 4)) { // flag f [+-], as rc's execflag
    unsigned char f = argc > 1 && argv->next->len == 1 ? (unsigned char)argv->next->s[0] : 0;
    if (argc == 2 && argv->next->len) {
      f = (unsigned char)argv->next->s[0];
      bool set = f < 128 && r->flag[f];
      rc_set_status(r, set ? "" : "flag not set", set ? 0 : 12);
      return true;
    }
    const rc_word *v = argc == 3 ? argv->next->next : nullptr;
    if (f && f < 128 && v && v->len == 1 && (v->s[0] == '+' || v->s[0] == '-')) {
      r->flag[f] = v->s[0] == '+';
      rc_set_status(r, "", 0);
      return true;
    }
    rc_fail(r, nullptr, "Usage: flag [letter] [+-]", nullptr);
    return true;
  }
  if (rc_streq(name, n, "whatis", 6)) {
    for (rc_word *a = argv->next; a; a = a->next) {
      rc_var *v = rc_var_find(r, a->s, a->len, false);
      rc_print(r, 1, a->s);
      if (v && v->fn) rc_print(r, 1, " is a function");
      if (v && v->val) {
        rc_print(r, 1, "=");
        for (rc_word *w = v->val; w; w = w->next)
          rc_write(r, 1, w->s, w->len), rc_print(r, 1, w->next ? " " : "");
      }
      rc_print(r, 1, "\n");
    }
    rc_set_status(r, "", 0);
    return true;
  }
  return false;
}

// `.` [-biq] file [arg ...], as rc's execdot: the file, found through $path
// unless its name says where it is, read and run a command at a time in a
// frame of its own, $* its arguments and $0 its name. '#d/0' is rc's own
// standard input. -b: compiled whole; -i: interactive; -q: no error if it is
// not there, and no -e in it.
static void rc_dot(rc *r, rc_word *argv) {
  bool bflag = false, iflag = false, qflag = false;
  rc_word *a = argv->next;
  for (; a && a->len && a->s[0] == '-'; a = a->next) {
    if (a->len == 2 && a->s[1] == '-') {
      a = a->next;
      break;
    }
    for (size_t k = 1; k < a->len; k++) {
      if (a->s[k] == 'b')
        bflag = true;
      else if (a->s[k] == 'i')
        iflag = true;
      else if (a->s[k] == 'q')
        qflag = true;
      else
        return rc_fail(r, nullptr, "Usage: . [-biq] file [arg ...]", nullptr);
    }
  }
  if (!a) return rc_fail(r, nullptr, "Usage: . [-biq] file [arg ...]", nullptr);
  rc_reader *rd = nullptr;
  bool tty = rc_streq(a->s, a->len, "#d/0", 4);
  if (tty) {
    rd = rc_reader_new(r, a->s, a->len);
    if (rd) rd->tty = true;
  } else { // through $path, as rc's searchpath, unless it starts / ./ or ../
    bool here = a->s[0] == '/' || (a->len > 1 && a->s[0] == '.' && a->s[1] == '/') ||
                (a->len > 2 && a->s[0] == '.' && a->s[1] == '.' && a->s[2] == '/');
    const rc_word *dirs = here ? nullptr : rc_getvar(r, "path");
    rc_word dot = {.len = 0};
    if (!dirs) dirs = &dot;
    char *buf = rc_alloc(r, 256ul * 1024);
    for (const rc_word *d = dirs; buf && d && !rd; d = d->next) {
      char path[512];
      size_t n = 0;
      bool cur = d->len == 0 || (d->len == 1 && d->s[0] == '.');
      if (!cur && d->len + 1 < sizeof path) {
        memcpy(path, d->s, d->len), n = d->len;
        if (path[n - 1] != '/') path[n++] = '/';
      }
      if (n + a->len >= sizeof path) continue;
      memcpy(path + n, a->s, a->len), n += a->len;
      int64_t got = r->host.read_file ? r->host.read_file(r->host.ctx, path, n, buf, 256ul * 1024) : -1;
      if (got < 0) continue;
      rd = rc_reader_new(r, path, n);
      if (rd) rd->text = buf, rd->len = (size_t)got, rd->cap = 256ul * 1024, buf = nullptr;
    }
    rc_free(r, buf);
    if (!rd) {
      if (!qflag) { // rc's Xerror3: . can't open: file: why, why its status
        char msg[RC_ERR];
        size_t k = 0;
        for (const char *x = ". can't open: "; *x; x++) msg[k++] = *x;
        for (size_t q = 0; q < a->len && k + 1 < sizeof msg; q++) msg[k++] = a->s[q];
        msg[k] = 0;
        rc_fail(r, "file does not exist", msg, "file does not exist");
      }
      return;
    }
  }
  if (!rd) return rc_fail(r, nullptr, "out of memory", nullptr);
  rd->interactive = iflag, rd->whole = bflag && !iflag, rd->quiet = qflag;
  rc_var *star = rc_newlocal(r, "*", 1, rc_copywords(r, a->next));
  rc_var *zero = rc_newlocal(r, "0", 1, rc_newword(r, a->s, a->len));
  if (star && zero) zero->next = star;
  rc_push_reader(r, rd, zero ? zero : star);
}

// eval cmd ...: the words, joined by spaces, run as a command line (rc's execeval).
static void rc_eval(rc *r, rc_word *argv) {
  if (!argv->next) return rc_fail(r, nullptr, "Usage: eval cmd ...", nullptr);
  size_t total = 1;
  for (rc_word *w = argv->next; w; w = w->next) total += w->len + 1;
  char *buf = rc_alloc(r, total);
  if (!buf) return;
  size_t at = 0;
  for (rc_word *w = argv->next; w; w = w->next) {
    memcpy(buf + at, w->s, w->len), at += w->len;
    buf[at++] = w->next ? ' ' : '\n';
  }
  char name[64];
  uint32_t line = 0;
  const char *src = r->src;
  if (r->nframes) {
    const rc_frame *f = &r->frames[r->nframes - 1];
    if (f->pc && f->pc <= f->code->n) line = f->code->inst[f->pc - 1].line;
    if (f->code->src[0]) src = f->code->src;
  }
  size_t n = rc_where(src, line, name, sizeof name - 8);
  for (const char *x = " *eval*"; *x && n + 1 < sizeof name; x++) name[n++] = *x;
  rc_reader *rd = rc_reader_new(r, name, n);
  if (!rd) return rc_free(r, buf);
  rd->text = buf, rd->len = at, rd->cap = total;
  rc_push_reader(r, rd, nullptr);
}

// Runs a command whose words are argv: a function, a builtin (rc's, then the
// host's), or a program. Returns false to stop (an error).
static void rc_simple(rc *r, rc_word *argv, bool async) {
  argv = rc_globlist(r, argv);
  uint32_t argc = rc_count(argv);
  if (!argc) return rc_fail(r, nullptr, "empty argument list", nullptr);
  if (r->flag['x'])
    rc_errwords(r, argv), rc_errout(r, "\n", 1); // -x: each command, as rc's (before its redirections)
  bool forced = rc_streq(argv->s, argv->len, "builtin", 7); // builtin cmd: no function, as rc's
  if (forced) {
    if (argc == 1) return rc_freewords(r, argv), rc_fail(r, nullptr, "builtin: empty argument list", nullptr);
    rc_word *b = argv;
    argv = argv->next, argc--;
    b->next = nullptr;
    rc_freewords(r, b);
  }
  if (argc == 1 && rc_streq(argv->s, argv->len, "exec", 4))
    return rc_freewords(r, argv), rc_fail(r, nullptr, "exec: empty argument list", nullptr);
  rc_var *v = forced ? nullptr : rc_gvar_find(r, argv->s, argv->len, false);
  if (v && v->fn && async) { // rc runs it in a child, which needs M6's 6d: refused, not run in the foreground
    rc_print(r, 2, "rc: a function run with & needs a child (for now)\n");
    rc_set_status(r, "async", 5);
    return rc_freewords(r, argv);
  }
  if (v && v->fn) { // a function: $* the rest, in a frame of its own
    rc_var *star = rc_newlocal(r, "*", 1, argv->next);
    argv->next = nullptr;
    rc_freewords(r, argv);
    rc_push_frame(r, v->fn, v->fn_pc, star);
    return;
  }
  if (rc_builtin(r, argv, argc)) return rc_freewords(r, argv);
  if (rc_streq(argv->s, argv->len, ".", 1)) return rc_dot(r, argv), rc_freewords(r, argv);
  if (rc_streq(argv->s, argv->len, "eval", 4)) return rc_eval(r, argv), rc_freewords(r, argv);
  rc_fd fds[RC_FDS];
  rc_fds(r, fds);
  if (r->host.builtin && r->host.builtin(r->host.ctx, r, argv, argc, fds)) return rc_freewords(r, argv);
  rc_command cmd = {.argv = argv, .argc = argc};
  memcpy(cmd.fds, fds, sizeof fds);
  uint64_t pid = 0;
  if (!r->host.run || !r->host.run(r->host.ctx, r, &cmd, 1, async, &pid)) {
    if (!r->host.run) rc_set_status(r, "no way to run programs", 22);
  }
  if (async) {
    char digits[24];
    size_t k = sizeof digits;
    do digits[--k] = (char)('0' + pid % 10);
    while (pid /= 10);
    rc_setvar(r, "apid", 4, rc_newword(r, digits + k, sizeof digits - k));
  }
  rc_freewords(r, argv);
}

// Concatenation (rc's ^): one word with each of a list, or pairwise.
static rc_word *rc_conc(rc *r, const rc_word *a, const rc_word *b, const char **bad) {
  uint32_t na = rc_count(a), nb = rc_count(b);
  rc_list out = {};
  if (!na && !nb) return nullptr; // both empty: empty, as rc's Xconc
  if (!na || !nb) {
    *bad = "null list in concatenation";
    return nullptr;
  }
  if (na != nb && na != 1 && nb != 1) {
    *bad = "mismatched list lengths in concatenation";
    return nullptr;
  }
  uint32_t n = na > nb ? na : nb;
  for (uint32_t i = 0; i < n; i++) {
    rc_word *w = rc_alloc(r, sizeof *w + a->len + b->len + 1);
    if (!w) break;
    memcpy(w->s, a->s, a->len), memcpy(w->s + a->len, b->s, b->len);
    w->len = a->len + b->len;
    rc_listadd(&out, w);
    if (na > 1) a = a->next;
    if (nb > 1) b = b->next;
  }
  return out.head;
}

static uint32_t rc_parse_index(const char *s, size_t n, bool *ok) {
  uint32_t v = 0;
  *ok = n > 0;
  for (size_t i = 0; i < n; i++) {
    if (s[i] < '0' || s[i] > '9' || v > 100'000'000) return *ok = false, 0;
    v = v * 10 + (uint32_t)(s[i] - '0');
  }
  return v;
}

// The value of the variable named in names, which must be one word (rc's
// Xdol and Xcount): $1 and the like are $*'s. False, with the run failed, if
// names is not one word.
static bool rc_value(rc *r, const rc_word *names, const char *what, rc_word **out, uint32_t *count) {
  *out = nullptr, *count = 0;
  if (!names || names->next) return rc_fail(r, nullptr, what, nullptr), false;
  bool num;
  uint32_t k = rc_parse_index(names->s, names->len, &num);
  if (num && k) { // $n: the n'th of $*; $0 is a variable of its own, the script's name
    const rc_word *w = rc_getvar(r, "*");
    for (uint32_t i = 1; w && i < k; i++) w = w->next;
    if (w) *out = rc_newword(r, w->s, w->len), *count = 1;
    return true;
  }
  rc_var *v = rc_var_find(r, names->s, names->len, false);
  if (v) *out = rc_copywords(r, v->val), *count = rc_count(v->val);
  return true;
}

// A list joined by spaces into one word, "" for none (rc's Xqw).
static rc_word *rc_qw(rc *r, rc_word *list) {
  size_t total = 0;
  for (rc_word *w = list; w; w = w->next) total += w->len + 1;
  rc_word *j = rc_alloc(r, sizeof *j + total + 1);
  for (rc_word *w = list; j && w; w = w->next) {
    memcpy(j->s + j->len, w->s, w->len), j->len += w->len;
    if (w->next) j->s[j->len++] = ' ';
  }
  rc_freewords(r, list);
  return j;
}

// A here document's text with $name, $n and $$ replaced, as rc's psubst: a
// list's words joined by spaces, and a ^ right after a name dropped. It takes
// body, and gives one word.
static rc_word *rc_hsubst(rc *r, rc_word *body) {
  size_t cap = body->len + 64, n = 0;
  char *out = rc_alloc(r, cap);
  for (size_t i = 0; out && i < body->len;) {
    char piece[2] = {body->s[i], 0};
    const char *add = piece;
    size_t alen = 1;
    rc_word *vals = nullptr;
    if (body->s[i] != '$') {
      i++;
    } else if (i + 1 < body->len && body->s[i + 1] == '$') {
      add = "$", i += 2;
    } else {
      size_t s0 = ++i;
      while (i < body->len && rc_idchr(body->s[i])) i++;
      rc_word *nm = rc_newword(r, body->s + s0, i - s0);
      uint32_t count = 0;
      if (nm && nm->len) rc_value(r, nm, "", &vals, &count);
      rc_freewords(r, nm);
      if (i < body->len && body->s[i] == '^') i++;
      add = nullptr, alen = 0;
    }
    size_t need = alen;
    for (rc_word *w = vals; w; w = w->next) need += w->len + 1;
    if (n + need + 1 > cap) {
      size_t ncap = (n + need + 1) * 2;
      char *more = rc_alloc(r, ncap);
      if (more) memcpy(more, out, n);
      rc_free(r, out);
      out = more, cap = ncap;
      if (!out) break;
    }
    if (add) memcpy(out + n, add, alen), n += alen;
    for (rc_word *w = vals; w; w = w->next) {
      memcpy(out + n, w->s, w->len), n += w->len;
      if (w->next) out[n++] = ' ';
    }
    rc_freewords(r, vals);
  }
  rc_freewords(r, body);
  rc_word *w = out ? rc_newword(r, out, n) : nullptr;
  rc_free(r, out);
  return w;
}

// Runs code from the frame on top until the frames it started with have all
// returned, or an error or exit stops it.
// Back to the nearest interactive reader above base, as rc's
// while(!runq->iflag) Xreturn(): false if there is none.
static bool rc_unwind(rc *r, uint32_t base) {
  uint32_t i = r->nframes;
  while (i > base && !(r->frames[i - 1].rd && r->frames[i - 1].rd->interactive)) i--;
  if (i == base) return false;
  while (r->nframes > i) rc_pop_frame(r);
  rc_frame *rf = &r->frames[i - 1];
  while (r->sp > rf->sp) rc_freewords(r, rc_poplist(r));
  while (r->ncaptures > rf->ncaptures) rc_free(r, r->captures[--r->ncaptures].buf);
  rc_pop_redirs(r, rf->redirs);
  return true;
}

// rc's signal functions, by the numbers rc_trap takes (rc's Signame).
static const char *const RC_SIGNAMES[8] = {"sigexit", "sighup",  "sigint", "sigquit",
                                           "sigalrm", "sigkill", "sigfpe", "sigterm"};

// The notes waiting, each to its function, as rc's dotrap: with none, an
// interrupt or quit goes back to the interactive reader (or exits, if none),
// and anything else exits.
static void rc_dotrap(rc *r, uint32_t base) {
  for (uint32_t i = 0; r->ntrap && i < 8; i++) {
    while (r->trap[i]) {
      r->trap[i]--, r->ntrap--;
      rc_var *v = rc_gvar_find(r, RC_SIGNAMES[i], rc_strlen(RC_SIGNAMES[i]), false);
      if (v && v->fn) {
        rc_var *star = rc_newlocal(r, "*", 1, rc_copywords(r, rc_getvar(r, "*")));
        rc_push_frame(r, v->fn, v->fn_pc, star);
      } else if (i == 2 || i == 3) {
        if (!rc_unwind(r, base)) r->exiting = true;
      } else {
        r->exiting = true;
      }
    }
  }
}

static void rc_execute(rc *r, uint32_t base) {
  uint64_t steps = 0;
  for (;;) {
    if (r->failed && !r->exiting) { // as rc's Xerror: back to the nearest interactive reader, if one
      if (!rc_unwind(r, base)) break;
      r->failed = r->failset = false;
    }
    if (r->ntrap && !r->exiting) rc_dotrap(r, base);
    if (r->nframes <= base || r->failed || r->exiting) break;
    if (r->budget && ++steps > r->budget) {
      rc_fail(r, nullptr, "too many steps", nullptr);
      break;
    }
    rc_frame *f = &r->frames[r->nframes - 1];
    if (f->pc >= f->code->n) {
      rc_pop_frame(r);
      continue;
    }
    const rc_inst *in = &f->code->inst[f->pc++];
    if (r->flag['r']) { // -r: each instruction as it runs, as rc's pfnc
      static const char *const names[] = {
          "Xmark",  "Xword",   "Xdol",   "Xcount",    "Xjoin",  "Xsub",   "Xconc",     "Xsimple", "Xstage",
          "Xpipe",  "Xassign", "Xlocal", "Xunlocal",  "Xif",    "Xifnot", "Xwastrue",  "Xtrue",   "Xfalse",
          "Xjump",  "Xbang",   "Xfor",   "Xpopm",     "Xfn",    "Xdelfn", "Xreturn",   "Xqw",     "Xsettrue",
          "Xmatch", "Xcase",   "Xbackq", "Xbackqend", "Xredir", "Xdup",   "Xpopredir", "Xrdcmds", "Xeflag"};
      const char *nm = in->op < sizeof names / sizeof names[0] ? names[in->op] : "X?";
      char where[96];
      size_t wn = rc_where(f->code->src, in->line, where, sizeof where);
      rc_errout(r, where, wn), rc_errout(r, ": ", 2), rc_errout(r, nm, rc_strlen(nm)), rc_errout(r, "\n", 1);
    }
    switch (in->op) {
    case X_MARK: rc_mark(r); break;
    case X_WORD:
      if (r->sp) rc_listadd(rc_toplist(r), rc_newword(r, f->code->strings + in->a, in->b));
      break;
    case X_DOL:
    case X_COUNT:
    case X_JOIN: {
      rc_word *names = rc_poplist(r), *vals;
      rc_degloblist(names);
      uint32_t k;
      bool ok = rc_value(
          r, names, in->op == X_COUNT ? "$# variable name not singleton!" : "$ variable name not singleton!",
          &vals, &k);
      rc_freewords(r, names);
      if (!ok || !r->sp) {
        rc_freewords(r, vals);
        break;
      }
      if (in->op == X_DOL) {
        rc_listadd(rc_toplist(r), vals);
      } else if (in->op == X_COUNT) {
        char digits[16];
        uint32_t d = sizeof digits;
        do digits[--d] = (char)('0' + k % 10);
        while (k /= 10);
        rc_listadd(rc_toplist(r), rc_newword(r, digits + d, sizeof digits - d));
        rc_freewords(r, vals);
      } else { // $": one word, joined by spaces
        rc_listadd(rc_toplist(r), rc_qw(r, vals));
      }
      break;
    }
    case X_SUB: { // $x(subscripts) as rc's subwords: 1-based, ranges n-m and n-
      rc_word *subs = rc_poplist(r), *names = rc_poplist(r);
      rc_degloblist(subs), rc_degloblist(names);
      if (!names || names->next) {
        rc_fail(r, nullptr, "$() variable name not singleton!", nullptr);
        rc_freewords(r, subs), rc_freewords(r, names);
        break;
      }
      rc_var *v = rc_var_find(r, names->s, names->len, false); // $1(2) is a variable named 1's, as rc's
      const rc_word *vals = v ? v->val : nullptr;
      uint32_t len = rc_count(vals);
      for (rc_word *sw = subs; sw && r->sp; sw = sw->next) {
        size_t i = 0;
        uint32_t n = 0, m = 0;
        while (i < sw->len && sw->s[i] >= '0' && sw->s[i] <= '9' && n < 100'000'000)
          n = n * 10 + (uint32_t)(sw->s[i++] - '0');
        bool neg = false;
        if (i < sw->len && sw->s[i] == '-') {
          if (++i == sw->len) {
            neg = n > len, m = neg ? 0 : len - n;
          } else {
            uint32_t to = 0;
            while (i < sw->len && sw->s[i] >= '0' && sw->s[i] <= '9' && to < 100'000'000)
              to = to * 10 + (uint32_t)(sw->s[i++] - '0');
            neg = to < n, m = neg ? 0 : to - n;
          }
        }
        if (n < 1 || n > len || neg) continue;
        if (n + m > len) m = len - n;
        const rc_word *w = vals;
        for (uint32_t k = 1; k < n; k++) w = w->next;
        for (uint32_t k = 0; k <= m && w; k++, w = w->next)
          rc_listadd(rc_toplist(r), rc_newword(r, w->s, w->len));
      }
      rc_freewords(r, subs), rc_freewords(r, names);
      break;
    }
    case X_CONC: {
      rc_word *b = rc_poplist(r), *a = rc_poplist(r);
      const char *bad = nullptr;
      rc_word *c = rc_conc(r, a, b, &bad);
      rc_freewords(r, a), rc_freewords(r, b);
      if (bad) {
        rc_fail(r, nullptr, bad, nullptr);
        break;
      }
      if (r->sp)
        rc_listadd(rc_toplist(r), c);
      else
        rc_freewords(r, c);
      break;
    }
    case X_SIMPLE: rc_simple(r, rc_poplist(r), in->f0); break;
    case X_STAGE: { // a: its own redirections, the top of the stack
      rc_word *argv = rc_globlist(r, rc_poplist(r));
      if (rc_nstages == RC_STAGES) {
        rc_freewords(r, argv);
        rc_fail(r, nullptr, "pipelines nested too deeply", nullptr);
        break;
      }
      rc_stage *st = &rc_stages[rc_nstages++];
      *st = (rc_stage){.cmd = {.argv = argv, .argc = rc_count(argv)}};
      // As rc does in the child: what encloses the pipeline, then the pipe
      // ends, then the stage's own redirections, which may move them.
      uint32_t own = r->nredirs >= in->a ? r->nredirs - in->a : 0;
      rc_fd *fds = st->cmd.fds;
      for (uint32_t i = 0; i < RC_FDS; i++) fds[i] = (rc_fd){.kind = RC_FD_INHERIT, .dup = (uint8_t)i};
      rc_apply_redirs(r, fds, 0, own);
      if (in->f0 < RC_FDS) fds[in->f0] = (rc_fd){.kind = RC_FD_PIPE_OUT};
      if (in->f1 < RC_FDS) fds[in->f1] = (rc_fd){.kind = RC_FD_PIPE_IN};
      rc_apply_redirs(r, fds, own, r->nredirs);
      break;
    }
    case X_PIPELINE: { // a: how many stages, the last gathered
      rc_command cmds[RC_STAGES];
      uint32_t first = rc_nstages >= in->a ? rc_nstages - in->a : 0, stages = rc_nstages - first;
      bool ok = stages > 0 && stages == in->a;
      for (uint32_t i = 0; i < stages; i++) {
        cmds[i] = rc_stages[first + i].cmd;
        if (!cmds[i].argc) ok = false;
        rc_var *v = cmds[i].argc ? rc_gvar_find(r, cmds[i].argv->s, cmds[i].argv->len, false) : nullptr;
        if (v && v->fn) ok = false;
      }
      uint64_t pid = 0;
      if (!ok)
        rc_print(r, 2, "rc: a pipeline's stages must be programs (for now)\n"),
            rc_set_status(r, "pipeline", 8);
      else if (r->host.run)
        r->host.run(r->host.ctx, r, cmds, stages, in->f0, &pid);
      rc_free_stages(r, first);
      break;
    }
    case X_ASSIGN:
    case X_LOCAL: {
      rc_word *name = rc_poplist(r), *val = rc_globlist(r, rc_poplist(r));
      rc_degloblist(name);
      if (!name || name->next) {
        rc_fail(r, nullptr,
                in->op == X_ASSIGN ? "= variable name not singleton!"
                                   : "local variable name must be singleton",
                nullptr);
        rc_freewords(r, name), rc_freewords(r, val);
        break;
      }
      if (in->op == X_ASSIGN) {
        rc_setvar(r, name->s, name->len, val);
      } else {
        rc_var *v = rc_newlocal(r, name->s, name->len, val);
        if (v) v->next = f->locals, f->locals = v;
      }
      rc_freewords(r, name);
      break;
    }
    case X_UNLOCAL:
      if (f->locals) {
        rc_var *v = f->locals;
        f->locals = v->next;
        v->next = nullptr;
        rc_freelocals(r, v);
      }
      break;
    case X_IF:
      r->ifnot = !rc_truestatus(r);
      if (r->ifnot) f->pc = in->a;
      break;
    case X_IFNOT:
      if (!r->ifnot) f->pc = in->a;
      break;
    case X_WASTRUE: r->ifnot = false; break;
    case X_TRUE:
      if (!rc_truestatus(r)) f->pc = in->a;
      break;
    case X_FALSE:
      if (rc_truestatus(r)) f->pc = in->a;
      break;
    case X_JUMP: f->pc = in->a; break;
    case X_BANG: rc_set_status(r, rc_truestatus(r) ? "false" : "", rc_truestatus(r) ? 5 : 0); break;
    case X_FOR: { // the next word of the list on top into the newest local
      rc_list *l = rc_toplist(r);
      if (!l || !l->head) {
        f->pc = in->a;
        break;
      }
      rc_word *w = l->head;
      l->head = w->next;
      if (!l->head) l->tail = nullptr;
      l->n--;
      w->next = nullptr;
      // Globbed as it is taken: the names it matches go back on the front of
      // the list, the first of them taken now (they have no marks to match again).
      w = rc_glob(r, w);
      if (w->next) {
        rc_word *rest = w->next, *last = rest;
        uint32_t k = 1;
        for (; last->next; last = last->next) k++;
        last->next = l->head;
        if (!l->head) l->tail = last;
        l->head = rest;
        l->n += k;
        w->next = nullptr;
      }
      if (f->locals)
        rc_freewords(r, f->locals->val), f->locals->val = w;
      else
        rc_free(r, w);
      break;
    }
    case X_POPM: rc_freewords(r, rc_poplist(r)); break;
    case X_FN: { // the names on top: each the function whose body follows
      rc_word *names = rc_poplist(r);
      rc_degloblist(names);
      for (rc_word *n = names; n; n = n->next) {
        rc_var *v = rc_gvar_find(r, n->s, n->len, true);
        if (!v) continue;
        rc_code_release(r, v->fn);
        v->fn = f->code, v->fn_pc = f->pc;
        f->code->refs++;
        rc_free(r, v->fnsrc), v->fnsrc = nullptr;
        if (in->b) {
          const char *t = f->code->strings + in->b - 1;
          size_t tl = rc_strlen(t);
          v->fnsrc = rc_alloc(r, tl + 1);
          if (v->fnsrc) memcpy(v->fnsrc, t, tl + 1);
        }
      }
      rc_freewords(r, names);
      f->pc = in->a;
      break;
    }
    case X_DELFN: {
      rc_word *names = rc_poplist(r);
      rc_degloblist(names);
      for (rc_word *n = names; n; n = n->next) {
        rc_var *v = rc_gvar_find(r, n->s, n->len, false);
        if (v) rc_code_release(r, v->fn), v->fn = nullptr, rc_free(r, v->fnsrc), v->fnsrc = nullptr;
      }
      rc_freewords(r, names);
      break;
    }
    case X_RETURN: rc_pop_frame(r); break;
    case X_QW: { // the list on top as one word, its marks gone: a subject is never a pattern
      rc_word *l = rc_poplist(r);
      rc_degloblist(l);
      if (rc_mark(r)) rc_listadd(rc_toplist(r), rc_qw(r, l));
      break;
    }
    case X_SETTRUE: rc_set_status(r, "", 0); break;
    case X_MATCH: { // ~ subject patterns: the subject (one word, X_QW's) against each
      rc_word *subj = rc_poplist(r), *pats = rc_poplist(r);
      bool hit = false;
      for (rc_word *p = pats; subj && p && !hit; p = p->next)
        hit = rc_match(subj->s, subj->len, p->s, p->len);
      rc_set_status(r, hit ? "" : "no match", hit ? 0 : 8);
      rc_freewords(r, subj), rc_freewords(r, pats);
      break;
    }
    case X_CASE: { // the patterns on top against the subject below them (one word, X_QW's)
      rc_word *pats = rc_poplist(r);
      rc_list *subj = rc_toplist(r);
      const rc_word *sw = subj ? subj->head : nullptr;
      bool hit = false;
      for (rc_word *p = pats; sw && p && !hit; p = p->next) hit = rc_match(sw->s, sw->len, p->s, p->len);
      rc_freewords(r, pats);
      if (!hit) f->pc = in->a;
      break;
    }
    case X_BACKQ: { // fd 1 into a new capture
      if (r->ncaptures == 8 || r->nredirs == RC_REDIRS) {
        rc_fail(r, nullptr, "` nested too deeply", nullptr);
        break;
      }
      r->captures[r->ncaptures] = (rc_capture){};
      r->redirs[r->nredirs++] =
          (rc_redir){.fd = 1, .to = {.kind = RC_FD_CAPTURE, .dup = (uint8_t)r->ncaptures}};
      r->ncaptures++;
      break;
    }
    case X_BACKQEND: { // the capture split at the separators on top
      rc_capture cap = r->captures[--r->ncaptures];
      rc_pop_redirs(r, r->nredirs - 1);
      // Every byte of $ifs separates, its words joined by spaces as rc's (so a
      // space too when it has several); none (ifs=()) makes the output one word.
      rc_word *ifs = rc_poplist(r);
      char seps[64];
      size_t nseps = 0;
      for (const rc_word *w = ifs; w; w = w->next) {
        for (size_t k = 0; k < w->len && nseps < sizeof seps; k++) seps[nseps++] = w->s[k];
        if (w->next && nseps < sizeof seps) seps[nseps++] = ' ';
      }
      for (size_t i = 0; i < cap.len && r->sp;) {
        while (i < cap.len && rc_has(seps, nseps, cap.buf[i])) i++;
        size_t start = i;
        while (i < cap.len && !rc_has(seps, nseps, cap.buf[i])) i++;
        if (i > start) rc_listadd(rc_toplist(r), rc_newword(r, cap.buf + start, i - start));
      }
      rc_freewords(r, ifs);
      rc_free(r, cap.buf);
      break;
    }
    case X_REDIR: {
      if (in->f1 == RC_FD_HERE) { // a here document: its text, substituted unless its tag was quoted
        rc_word *body = rc_poplist(r);
        if (body && !in->b) body = rc_hsubst(r, body);
        if (!body || r->nredirs == RC_REDIRS) {
          rc_freewords(r, body);
          rc_fail(r, nullptr, "<< nested too deeply", nullptr);
          break;
        }
        r->redirs[r->nredirs++] = (rc_redir){
            .fd = in->f0, .to = {.kind = RC_FD_HERE, .path = body->s, .path_len = body->len}, .path = body};
        break;
      }
      rc_word *path = rc_globlist(r, rc_poplist(r));
      const char *op = ">";
      if (in->f1 == RC_FD_READ) op = "<";
      if (in->f1 == RC_FD_APPEND) op = ">>";
      if (in->f1 == RC_FD_RDWR) op = "<>";
      if (!path || path->next || r->nredirs == RC_REDIRS) { // as rc's: > requires file, > requires singleton
        char msg[32];
        size_t n = 0;
        for (const char *x = op; *x; x++) msg[n++] = *x;
        const char *tail = " requires singleton";
        if (!path) tail = " requires file";
        if (path && r->nredirs == RC_REDIRS) tail = " nested too deeply";
        for (const char *x = tail; *x; x++) msg[n++] = *x;
        msg[n] = 0;
        rc_fail(r, nullptr, msg, nullptr);
        rc_freewords(r, path);
        break;
      }
      uint32_t handle = 0;
      if (r->host.open && !r->host.open(r->host.ctx, r, path->s, path->len, in->f1, &handle)) {
        // rc's Xerror3: `< can't open: file: why`, why (the host's, in $status) the status.
        char msg[RC_ERR], why[RC_ERR];
        size_t n = 0, w = 0;
        for (const char *x = op; *x; x++) msg[n++] = *x;
        for (const char *x = " can't open: "; *x; x++) msg[n++] = *x;
        for (size_t k = 0; k < path->len && n + 1 < sizeof msg; k++) msg[n++] = path->s[k];
        msg[n] = 0;
        const rc_word *st = rc_getvar(r, "status");
        for (size_t k = 0; st && k < st->len && w + 1 < sizeof why; k++) why[w++] = st->s[k];
        if (!w)
          for (const char *x = "cannot open"; *x; x++) why[w++] = *x;
        why[w] = 0;
        rc_freewords(r, path);
        rc_fail(r, why, msg, why);
        break;
      }
      r->redirs[r->nredirs++] =
          (rc_redir){.fd = in->f0,
                     .to = {.kind = in->f1, .handle = handle, .path = path->s, .path_len = path->len},
                     .path = path};
      break;
    }
    case X_DUP:
      if (r->nredirs == RC_REDIRS) break;
      r->redirs[r->nredirs++] =
          (rc_redir){.fd = in->f0, .to = {.kind = in->f1 == 255 ? RC_FD_CLOSED : RC_FD_DUP, .dup = in->f1}};
      break;
    case X_POPREDIR: rc_pop_redirs(r, r->nredirs >= in->a ? r->nredirs - in->a : 0); break;
    case X_RDCMDS: rc_rdcmds(r, f); break;
    case X_EFLAG:
      if (!rc_truestatus(r)) r->exiting = true; // -e, as rc's Xeflag: exit with the status
      break;
    default: rc_fail(r, nullptr, "bad instruction", nullptr); break;
    }
  }
}

// Text compiled into code: null on a syntax error (in r->err), or if more
// text could finish it (*incomplete).
static rc_code *rc_compile_text(rc *r, const char *text, size_t len, uint32_t line, bool *incomplete) {
  rc_parser *p = rc_alloc(r, sizeof *p);
  if (!p) return nullptr;
  size_t scratch = 2 * len + 64, nodes = len + 32;
  p->lx = (rc_lexer){.r = r,
                     .p = text,
                     .end = text + len,
                     .base = text,
                     .line = line,
                     .scratch = rc_alloc(r, scratch),
                     .cap = scratch};
  p->nodes = rc_alloc(r, nodes * sizeof *p->nodes);
  p->cap = (uint32_t)nodes;
  p->line = line;
  rc_code *code = nullptr;
  if (p->lx.scratch && p->nodes) {
    int32_t root = rc_parse(p);
    *incomplete = p->incomplete || p->lx.incomplete;
    if (p->why) { // as rc's yyerror: file:line: message, which is $status too
      char where[96];
      rc_where(r->src, p->line, where, sizeof where);
      rc_error(r, where, ": ");
      size_t n = 0;
      while (r->err[n]) n++;
      for (const char *x = p->why; *x && n + 1 < RC_ERR; x++) r->err[n++] = *x;
      r->err[n] = 0;
      if (!*incomplete) rc_set_status(r, p->why, rc_strlen(p->why));
    } else {
      rc_compiler c = {.r = r,
                       .nodes = p->nodes,
                       .cap = (uint32_t)(nodes * 4 + 16),
                       .strcap = scratch + 64,
                       .heres = p->lx.heres,
                       .nheres = p->lx.nheres};
      c.inst = rc_alloc(r, c.cap * sizeof *c.inst);
      c.str = rc_alloc(r, c.strcap);
      if (c.inst && c.str && rc_compile_tree(&c, root)) {
        code = rc_alloc(r, sizeof *code);
        if (code) {
          *code = (rc_code){.refs = 1, .n = c.n, .inst = c.inst, .strings = c.str};
          for (size_t k = 0; r->src[k] && k + 1 < sizeof code->src; k++) code->src[k] = r->src[k];
        } else {
          rc_free(r, c.inst), rc_free(r, c.str);
        }
      } else {
        char where[96];
        rc_where(r->src, c.line, where, sizeof where);
        rc_error(r, where, ": ");
        const char *why = c.why ? c.why : "out of memory";
        size_t n = 0;
        while (r->err[n]) n++;
        for (const char *x = why; *x && n + 1 < RC_ERR; x++) r->err[n++] = *x;
        r->err[n] = 0;
        rc_set_status(r, why, rc_strlen(why));
        rc_free(r, c.inst), rc_free(r, c.str);
      }
    }
  }
  rc_free(r, p->lx.scratch);
  rc_free(r, p->nodes);
  rc_free(r, p);
  return code;
}

// --- The interface ---

typedef enum rc_result : uint8_t { RC_OK, RC_INCOMPLETE, RC_SYNTAX, RC_FAILED, RC_EXIT } rc_result;

// A new interpreter in heap (size bytes, 16-aligned), with host's callbacks.
[[maybe_unused]] static rc *rc_new(void *heap, size_t size, const rc_host *host) {
  if (size < 64ul * 1024 || ((uintptr_t)heap & (RC_ALIGN - 1))) return nullptr;
  rc *r = heap;
  memset(r, 0, sizeof *r);
  r->host = *host;
  size_t used = (sizeof *r + RC_ALIGN - 1) & ~(RC_ALIGN - 1);
  r->heap = (uint8_t *)heap + used;
  r->heap_size = size - used;
  r->free = (rc_block *)r->heap;
  r->free->size = r->heap_size & ~(RC_ALIGN - 1);
  r->free->next = nullptr;
  rc_setvar(r, "ifs", 3, rc_newword(r, " \t\n", 3));
  rc_set_status(r, "", 0);
  r->src[0] = 'r', r->src[1] = 'c';
  r->rdcode = rc_alloc(r, sizeof *r->rdcode);
  rc_inst *one = rc_alloc(r, sizeof *one);
  if (!r->rdcode || !one) return nullptr;
  *one = (rc_inst){.op = X_RDCMDS};
  *r->rdcode = (rc_code){.refs = 1, .n = 1, .inst = one}; // its own reference: never freed
  return r;
}

// Sets a variable to n words.
[[maybe_unused]] static void rc_set(rc *r, const char *name, const char *const *words, const size_t *lens,
                                    uint32_t n) {
  rc_list l = {};
  for (uint32_t i = 0; i < n; i++) rc_listadd(&l, rc_newword(r, words[i], lens[i]));
  rc_setvar(r, name, rc_strlen(name), l.head);
}

// Runs sigexit, once, as rc does when it exits: the host calls it at its end
// too (the end of its input, or an error that ends it).
[[maybe_unused]] static void rc_sigexit(rc *r) {
  rc_var *v = rc_gvar_find(r, "sigexit", 7, false);
  if (r->trapped || !v || !v->fn) return;
  r->trapped = true;
  bool exiting = r->exiting;
  r->exiting = r->failed = false;
  uint32_t base = r->nframes;
  rc_var *star = rc_newlocal(r, "*", 1, rc_copywords(r, rc_getvar(r, "*")));
  if (rc_push_frame(r, v->fn, v->fn_pc, star)) rc_execute(r, base);
  while (r->nframes > base) rc_pop_frame(r);
  r->exiting = r->exiting || exiting;
}

// Runs text (a line, or a whole script): RC_INCOMPLETE if it ends inside a
// construct (the caller adds the next line and tries again), RC_SYNTAX with
// the message in rc_err, RC_FAILED after a run-time error, RC_EXIT once
// `exit` ran (its status is $status).
[[maybe_unused]] static rc_result rc_run(rc *r, const char *text, size_t len) {
  r->err[0] = 0;
  r->failed = r->failset = r->exiting = r->syntax = r->incomplete = false;
  rc_reader *rd = rc_reader_new(r, r->src, rc_strlen(r->src));
  char *copy = rd ? rc_alloc(r, len + 1) : nullptr;
  if (!copy) return rc_reader_free(r, rd), RC_FAILED;
  memcpy(copy, text, len);
  rd->text = copy, rd->len = len, rd->cap = len + 1;
  uint32_t base = r->nframes;
  if (!rc_push_reader(r, rd, nullptr)) return RC_FAILED;
  rc_execute(r, base);
  if (r->exiting) rc_sigexit(r);             // as rc's Xexit: sigexit first, once
  while (r->nframes > base) rc_pop_frame(r); // after an error or exit: what was running
  while (r->sp) rc_freewords(r, rc_poplist(r));
  rc_free_stages(r, 0);
  while (r->ncaptures) rc_free(r, r->captures[--r->ncaptures].buf); // an error inside `{}
  if (r->exiting) return RC_EXIT;
  if (r->failed) {
    if (!r->failset) rc_set_status(r, "error", 5); // out of memory, which rc_fail cannot report
    return RC_FAILED;
  }
  if (r->incomplete) return RC_INCOMPLETE;
  return r->syntax ? RC_SYNTAX : RC_OK;
}

[[maybe_unused]] static const char *rc_err(const rc *r) { return r->err; }

// A note for rc (by RC_SIGNAMES's numbers: 1 hangup, 2 interrupt, 3 quit, 4
// alarm, 5 kill, 6 floating point, 7 term), from the host's note handler: its
// function runs before the next instruction (rc's notifyf). An interrupt is
// counted once until it has run.
[[maybe_unused]] static void rc_trap(rc *r, uint32_t sig) {
  if (sig == 0 || sig >= 8 || (sig == 2 && r->trap[2])) return;
  r->trap[sig]++;
  r->ntrap++;
}

// The number rc_trap takes for a note, 0 if rc has no function for it:
// 9front's words first ("interrupt", "sys: fp: ", "term"), then VectraOS's
// notes as the signals they stand for (lib/vx-posix): "sys: trap: arithmetic"
// is sigfpe's, "posix: SIGTERM pid=12" sigterm's, "posix: SIGQUIT" (^\ at a
// terminal) sigquit's.
[[maybe_unused]] static uint32_t rc_note_trap(vx_str note) {
  static const char *const names[8] = {"exit",  "hangup", "interrupt", "quit",
                                       "alarm", "kill",   "sys: fp: ", "term"};
  static const int64_t signals[8] = {0,
                                     POSIX_SIGHUP,
                                     POSIX_SIGINT,
                                     POSIX_SIGQUIT,
                                     POSIX_SIGALRM,
                                     POSIX_SIGKILL,
                                     POSIX_SIGFPE,
                                     POSIX_SIGTERM};
  int64_t sender, sig = posix_note_signal(note, &sender);
  for (uint32_t i = 1; i < 8; i++) {
    size_t n = rc_strlen(names[i]);
    if ((note.len >= n && memcmp(note.ptr, names[i], n) == 0) || (sig && sig == signals[i])) return i;
  }
  return 0;
}

// Each function, for the host to export: each(name, its body's text).
[[maybe_unused]] static void rc_each_fn(rc *r, void (*each)(void *arg, const char *name, const char *src),
                                        void *arg) {
  for (uint32_t b = 0; b < RC_VARS; b++)
    for (const rc_var *v = r->vars[b]; v; v = v->next)
      if (v->fn) each(arg, v->name, v->fnsrc ? v->fnsrc : "{}");
}

// Where the code run next comes from, for errors (file:line): a script's
// name; "rc" until set.
[[maybe_unused]] static void rc_source(rc *r, const char *name, size_t n) {
  size_t k = 0;
  for (; k < n && k + 1 < sizeof r->src; k++) r->src[k] = name[k];
  r->src[k] = 0;
}

// Adds one stage's status to a pipeline's (buf, *len of cap bytes), as rc's
// concstatus: joined by |, which is left out while what came before is empty.
[[maybe_unused]] static void rc_concstatus(char *buf, size_t *len, size_t cap, const char *s, size_t n) {
  if (*len && *len < cap) buf[(*len)++] = '|';
  for (size_t i = 0; i < n && *len < cap; i++) buf[(*len)++] = s[i];
}

// Each variable with a value as a command would see it now (a local hiding a
// global of its name), for the host to export as rc does: each(name, words).
[[maybe_unused]] static void rc_each_var(rc *r, void (*each)(void *arg, const char *name, const rc_word *val),
                                         void *arg) {
  for (uint32_t f = r->nframes + 1; f-- > 0;) {
    for (uint32_t b = 0; b < (f == r->nframes ? RC_VARS : 1); b++) {
      rc_var *v = f == r->nframes ? r->vars[b] : r->frames[f].locals;
      for (; v; v = v->next)
        if (v->val && rc_var_find(r, v->name, rc_strlen(v->name), false) == v) each(arg, v->name, v->val);
    }
  }
}
