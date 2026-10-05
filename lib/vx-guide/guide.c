// vx-guide: the parser and the terminal renderer (docs/12-manual.md §4,
// §6.1). See guide.h.

#pragma once

#include "guide.h"
#include "../vx-ndb/ndb.c"
#include "../vx-utf/utf.h"

// --- Characters and lines ---

static bool guide_alpha(char c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }
static bool guide_digit(char c) { return c >= '0' && c <= '9'; }
static bool guide_alnum(char c) { return guide_alpha(c) || guide_digit(c); }
static char guide_upper(char c) { return c >= 'a' && c <= 'z' ? (char)(c - ('a' - 'A')) : c; }
static bool guide_space(char c) { return c == ' ' || c == '\t' || c == '\n'; }
// A name a reference can carry: a page's or an indexed function's.
static bool guide_name_start(char c) { return guide_alnum(c) || c == '_'; }
static bool guide_name_char(char c) { return guide_alnum(c) || c == '_' || c == '.' || c == '+' || c == '-'; }

static bool guide_eq(vx_str a, const char *b) {
  size_t i = 0;
  for (; i < a.len && b[i]; i++)
    if (a.ptr[i] != b[i]) return false;
  return i == a.len && !b[i];
}

static bool guide_starts(vx_str a, const char *p) {
  for (size_t i = 0; p[i]; i++)
    if (i >= a.len || a.ptr[i] != p[i]) return false;
  return true;
}

static bool guide_same(vx_str a, vx_str b) {
  if (a.len != b.len) return false;
  for (size_t i = 0; i < a.len; i++)
    if (a.ptr[i] != b.ptr[i]) return false;
  return true;
}

static bool guide_blank(vx_str l) {
  for (size_t i = 0; i < l.len; i++)
    if (l.ptr[i] != ' ' && l.ptr[i] != '\t') return false;
  return true;
}

static vx_str guide_trim(vx_str s) {
  while (s.len && guide_space(s.ptr[0])) s.ptr++, s.len--;
  while (s.len && guide_space(s.ptr[s.len - 1])) s.len--;
  return s;
}

static bool guide_fail(vx_guide *g, const char *msg, size_t line) {
  g->error = msg;
  g->error_line = line;
  return false;
}

// The line at g->pos, without its newline; *next is where the following one starts.
static vx_str guide_line(const vx_guide *g, size_t *next) {
  size_t e = g->pos;
  while (e < g->src.len && g->src.ptr[e] != '\n') e++;
  *next = e < g->src.len ? e + 1 : e;
  return (vx_str){g->src.ptr + g->pos, e - g->pos};
}

static void guide_advance(vx_guide *g, size_t next) {
  g->pos = next;
  g->line++;
}

// Lowercase letters, digits and the punctuation 12 §4.2 allows: a page's name.
static bool guide_page_name(vx_str s) {
  if (!s.len || !(guide_digit(s.ptr[0]) || (s.ptr[0] >= 'a' && s.ptr[0] <= 'z'))) return false;
  for (size_t i = 1; i < s.len; i++) {
    char c = s.ptr[i];
    if (!(guide_digit(c) || (c >= 'a' && c <= 'z') || c == '.' || c == '_' || c == '+' || c == '-'))
      return false;
  }
  return true;
}

static bool guide_node_id(vx_str s) {
  if (!s.len) return false;
  for (size_t i = 0; i < s.len; i++)
    if (!(guide_digit(s.ptr[i]) || (s.ptr[i] >= 'a' && s.ptr[i] <= 'z') || s.ptr[i] == '-')) return false;
  return true;
}

[[maybe_unused]] static bool vx_guide_item_next(vx_str *list, vx_str *item) {
  if (!list->len) return false;
  size_t i = 0;
  while (i < list->len && list->ptr[i] != ',') i++;
  *item = guide_trim((vx_str){list->ptr, i});
  bool more = i < list->len;
  list->ptr += i + more, list->len -= i + more;
  return true;
}

// Each item of a list: a name (or, with `path`, any text without spaces), never empty.
static bool guide_list_ok(vx_str list, bool path) {
  vx_str item;
  if (!list.len) return false;
  while (vx_guide_item_next(&list, &item)) {
    if (!item.len || (!path && !guide_name_start(item.ptr[0]))) return false;
    for (size_t i = 0; i < item.len; i++)
      if (guide_space(item.ptr[i]) || (!path && !guide_name_char(item.ptr[i]))) return false;
  }
  return true;
}

// --- The header ---

static bool guide_header_tuple(vx_guide *g, const vx_ndb_tuple *t, const vx_ndb_record *rec, size_t line) {
  vx_guide_header *h = &g->h;
  bool flag = t->value.ptr == nullptr;
  if (guide_eq(t->key, "host")) {
    if (!flag) return guide_fail(g, "host is a flag", line);
    h->host = true;
    return true;
  }
  if (flag) return guide_fail(g, "a header key with no value", line);
  if (guide_eq(t->key, "page")) {
    h->page = t->value;
  } else if (guide_eq(t->key, "sect")) {
    if (t->value.len != 1 || t->value.ptr[0] < '1' || t->value.ptr[0] > '8')
      return guide_fail(g, "sect= is 1 to 8", line);
    h->sect = t->value.ptr[0] - '0';
  } else if (guide_eq(t->key, "summary")) {
    h->summary = t->value;
  } else if (guide_eq(t->key, "names")) {
    h->names = t->value;
  } else if (guide_eq(t->key, "src")) {
    h->src = t->value;
  } else if (guide_eq(t->key, "keys")) {
    h->keys = t->value;
  } else if (guide_eq(t->key, "lang")) {
    if (!guide_eq(t->value, "c") && !guide_eq(t->value, "lua") && !guide_eq(t->value, "rc"))
      return guide_fail(g, "lang= is c, lua or rc", line);
    h->lang = t->value;
  } else if (guide_eq(t->key, "level")) {
    if (!vx_ndb_get_u64(rec, "level", &h->level) || !h->level)
      return guide_fail(g, "level= is an ABI level", line);
  } else {
    return guide_fail(g, "a header key guide does not know", line);
  }
  return true;
}

[[maybe_unused]] static bool vx_guide_open(vx_guide *g, vx_str page) {
  *g = (vx_guide){.src = page};
  size_t line = 1;
  for (size_t i = 0; i < page.len; i++) {
    unsigned char c = (unsigned char)page.ptr[i];
    if ((c < 0x20 && c != '\n' && c != '\t') || c == 0x7f) return guide_fail(g, "a control character", line);
    if (c == '\n') line++;
  }
  if (!vx_utf_valid(page.ptr, page.len)) return guide_fail(g, "not UTF-8", 1);
  size_t next;
  vx_str l = guide_line(g, &next);
  if (guide_starts(l, "@guide=")) { // 12 §4.7: version 1 is the only one there is
    if (!guide_eq(l, "@guide=1")) return guide_fail(g, "a version of guide this parser does not know", 1);
    guide_advance(g, next);
  }
  size_t start = g->pos, first = g->line + 1;
  while (g->pos < page.len && !guide_blank(guide_line(g, &next))) guide_advance(g, next);
  vx_str hdr = {page.ptr + start, g->pos - start};
  if (g->pos < page.len) guide_advance(g, next); // the blank line ending it
  vx_ndb_reader r = {.src = hdr, .scratch = g->hscratch, .scratch_cap = sizeof g->hscratch};
  static vx_ndb_record rec; // 4 KiB: kept off the stack (no reader runs two pages at once)
  vx_ndb_result res = vx_ndb_next(&r, &rec);
  if (res == VX_NDB_ERROR) return guide_fail(g, r.error, first + r.error_line - 1);
  if (res == VX_NDB_END || !guide_eq(rec.tuples[0].key, "page"))
    return guide_fail(g, "a page starts with a header whose first tuple is page=", first);
  for (int i = 0; i < rec.count; i++)
    if (!guide_header_tuple(g, &rec.tuples[i], &rec, first)) return false;
  vx_ndb_record more;
  if (vx_ndb_next(&r, &more) != VX_NDB_END) return guide_fail(g, "the header is one record", first);
  vx_guide_header *h = &g->h;
  if (!guide_page_name(h->page)) return guide_fail(g, "page= is lower case: [a-z0-9][a-z0-9._+-]*", first);
  if (!h->sect || !h->summary.len) return guide_fail(g, "a header needs sect= and summary=", first);
  if (!h->names.len) h->names = h->page;
  if (!guide_list_ok(h->names, false) || (h->keys.len && !guide_list_ok(h->keys, false)) ||
      (h->src.len && !guide_list_ok(h->src, true)))
    return guide_fail(g, "a list in the header has an empty or malformed item", first);
  return true;
}

// --- The body ---

static vx_guide_kind guide_error(vx_guide *g, vx_guide_block *b, const char *msg, size_t line) {
  guide_fail(g, msg, line);
  b->kind = VX_GUIDE_ERROR;
  return VX_GUIDE_ERROR;
}

// Continuation lines (two spaces, not blank) after the current one; the end of the last.
static size_t guide_continue(vx_guide *g, size_t next) {
  size_t end = g->pos + guide_line(g, &next).len;
  guide_advance(g, next);
  while (g->pos < g->src.len) {
    vx_str l = guide_line(g, &next);
    if (!guide_starts(l, "  ") || guide_blank(l)) break;
    end = g->pos + l.len;
    guide_advance(g, next);
  }
  return end;
}

static vx_guide_kind guide_fence(vx_guide *g, vx_guide_block *b, vx_str l, size_t next) {
  vx_str kind = {l.ptr + 3, l.len - 3};
  static const char *const kinds[] = {"", "usage", "c", "rc", "ndb", "lua", "text"};
  bool known = false;
  for (size_t i = 0; i < sizeof kinds / sizeof kinds[0]; i++) known = known || guide_eq(kind, kinds[i]);
  if (!known) return guide_error(g, b, "a fence kind guide does not know", b->line);
  guide_advance(g, next);
  size_t start = g->pos;
  while (g->pos < g->src.len) {
    vx_str in = guide_line(g, &next);
    if (guide_eq(in, "```")) {
      b->kind = VX_GUIDE_FENCE, b->fence = kind;
      b->text = (vx_str){g->src.ptr + start, g->pos - start};
      guide_advance(g, next);
      return b->kind;
    }
    guide_advance(g, next);
  }
  return guide_error(g, b, "a fence that is never closed", b->line);
}

static vx_guide_kind guide_directive(vx_guide *g, vx_guide_block *b, vx_str l, size_t next) {
  vx_ndb_reader r = {
      .src = {l.ptr + 1, l.len - 1}, .scratch = g->lscratch, .scratch_cap = sizeof g->lscratch};
  static vx_ndb_record rec; // 4 KiB: off the stack
  vx_ndb_result res = vx_ndb_next(&r, &rec);
  if (res == VX_NDB_ERROR) return guide_error(g, b, r.error, b->line);
  if (res == VX_NDB_END || !guide_eq(rec.tuples[0].key, "node")) {
    bool version = res == VX_NDB_RECORD && guide_eq(rec.tuples[0].key, "guide");
    return guide_error(g, b,
                       version ? "@guide= comes first, before the header" : "a directive guide does not know",
                       b->line);
  }
  for (int i = 0; i < rec.count; i++) {
    vx_str k = rec.tuples[i].key, v = rec.tuples[i].value;
    if (!v.ptr) return guide_error(g, b, "a directive's key with no value", b->line);
    if (guide_eq(k, "node"))
      b->node = v;
    else if (guide_eq(k, "title"))
      b->title = v;
    else if (guide_eq(k, "keys"))
      b->keys = v;
    else
      return guide_error(g, b, "a node key guide does not know", b->line);
  }
  // A bare id points into the page, so it outlives this line's scratch.
  if (!guide_node_id(b->node) || b->node.ptr < l.ptr || b->node.ptr >= l.ptr + l.len)
    return guide_error(g, b, "a node's id is bare: [a-z0-9-]+", b->line);
  if (b->keys.len && !guide_list_ok(b->keys, false))
    return guide_error(g, b, "a malformed keys= list", b->line);
  for (int i = 0; i < g->nnodes; i++)
    if (guide_same(g->nodes[i], b->node)) return guide_error(g, b, "a node id used twice", b->line);
  if (g->nnodes == VX_GUIDE_MAX_NODES) return guide_error(g, b, "more than 64 nodes", b->line);
  g->nodes[g->nnodes++] = b->node;
  guide_advance(g, next);
  b->kind = VX_GUIDE_NODE;
  return b->kind;
}

// True if a line starts a block of its own rather than going on with a paragraph.
static bool guide_starts_block(vx_str l) {
  if (!l.len) return true;
  char c = l.ptr[0];
  return guide_blank(l) || c == '@' || c == '#' || c == '|' || guide_starts(l, "```") ||
         guide_starts(l, "- ") || guide_starts(l, ": ") || guide_starts(l, "  ");
}

[[maybe_unused]] static vx_guide_kind vx_guide_next(vx_guide *g, vx_guide_block *b) {
  *b = (vx_guide_block){};
  if (g->error) return b->kind = VX_GUIDE_ERROR;
  size_t next = 0;
  vx_str l = {};
  for (;;) {
    if (g->pos >= g->src.len) return b->kind = VX_GUIDE_END;
    l = guide_line(g, &next);
    if (!guide_blank(l)) break;
    guide_advance(g, next);
  }
  b->line = g->line + 1;
  size_t start = g->pos;
  if (guide_starts(l, "```")) return guide_fence(g, b, l, next);
  if (l.ptr[0] == '@') return guide_directive(g, b, l, next);
  if (l.ptr[0] == '#') {
    bool sub = guide_starts(l, "## ");
    if (!sub && !guide_starts(l, "# "))
      return guide_error(g, b, "a heading is # or ##, then a space", b->line);
    b->text = guide_trim((vx_str){l.ptr + 2 + sub, l.len - 2 - sub});
    if (!b->text.len) return guide_error(g, b, "an empty heading", b->line);
    if (!sub && (guide_eq(b->text, "NAME") || guide_eq(b->text, "SOURCE")))
      return guide_error(g, b, "NAME and SOURCE are made from the header", b->line);
    guide_advance(g, next);
    return b->kind = sub ? VX_GUIDE_SUBHEADING : VX_GUIDE_HEADING;
  }
  if (guide_starts(l, "  "))
    return guide_error(g, b, "a continuation line with nothing to continue", b->line);
  if (l.ptr[0] == '|') {
    b->text = (vx_str){l.ptr + 1, l.len - 1};
    guide_advance(g, next);
    return b->kind = VX_GUIDE_ROW;
  }
  if (guide_starts(l, "- ")) {
    size_t end = guide_continue(g, next);
    b->text = (vx_str){g->src.ptr + start + 2, end - start - 2};
    return b->kind = VX_GUIDE_ITEM;
  }
  if (guide_starts(l, ": ")) {
    b->text = guide_trim((vx_str){l.ptr + 2, l.len - 2});
    if (!b->text.len) return guide_error(g, b, "a definition with no term", b->line);
    size_t body = next, end = guide_continue(g, next);
    b->body = end > body ? (vx_str){g->src.ptr + body, end - body} : (vx_str){};
    return b->kind = VX_GUIDE_DEF;
  }
  size_t end = start + l.len; // a paragraph: lines up to a blank one or another block's
  guide_advance(g, next);
  while (g->pos < g->src.len) {
    vx_str more = guide_line(g, &next);
    if (guide_starts_block(more)) break;
    end = g->pos + more.len;
    guide_advance(g, next);
  }
  b->text = (vx_str){g->src.ptr + start, end - start};
  return b->kind = VX_GUIDE_PARA;
}

// --- Inline spans ---

// The length of a reference name(N) at s[i], or 0; its section in *sect.
static size_t guide_ref_at(vx_str s, size_t i, int *sect) {
  if (!guide_name_start(s.ptr[i]) || (i && guide_name_char(s.ptr[i - 1]))) return 0;
  size_t j = i;
  while (j < s.len && guide_name_char(s.ptr[j])) j++;
  if (j + 3 > s.len || s.ptr[j] != '(' || s.ptr[j + 1] < '1' || s.ptr[j + 1] > '8' || s.ptr[j + 2] != ')')
    return 0;
  *sect = s.ptr[j + 1] - '0';
  return j + 3 - i;
}

// The length of a parameter <name> at s[i], or 0.
static size_t guide_param_at(vx_str s, size_t i) {
  if (s.ptr[i] != '<' || i + 1 >= s.len || !guide_alpha(s.ptr[i + 1])) return 0;
  size_t j = i + 2;
  while (j < s.len && (guide_alnum(s.ptr[j]) || s.ptr[j] == '.' || s.ptr[j] == '_' || s.ptr[j] == '-')) j++;
  return j < s.len && s.ptr[j] == '>' ? j + 1 - i : 0;
}

static bool guide_target_ok(vx_str t) {
  if (!t.len) return false;
  if (t.ptr[0] == '#') return guide_node_id((vx_str){t.ptr + 1, t.len - 1});
  static const char *const schemes[] = {"https:", "gemini:", "gopher:"};
  for (size_t i = 0; i < sizeof schemes / sizeof schemes[0]; i++)
    if (guide_starts(t, schemes[i])) {
      for (size_t k = 0; k < t.len; k++)
        if (guide_space(t.ptr[k])) return false;
      return t.len > 7;
    }
  int sect;
  size_t n = guide_ref_at(t, 0, &sect);
  if (!n) return false;
  return n == t.len || (t.ptr[n] == '#' && guide_node_id((vx_str){t.ptr + n + 1, t.len - n - 1}));
}

static vx_guide_span_kind guide_span_error(vx_guide_inline *it, vx_guide_span *sp, const char *msg) {
  it->error = msg;
  sp->kind = VX_SPAN_ERROR;
  return sp->kind;
}

// Backticks from s[i]: how many in the run.
static size_t guide_ticks(vx_str s, size_t i) {
  size_t n = 0;
  while (i + n < s.len && s.ptr[i + n] == '`') n++;
  return n;
}

// Where a literal opened at s[i] by n backticks closes (the closing run's
// start), or 0 if it never does.
static size_t guide_literal_end(vx_str s, size_t i, size_t n) {
  for (size_t k = i + n; k < s.len;) {
    size_t run = guide_ticks(s, k);
    if (run == n) return k;
    k += run ? run : 1;
  }
  return 0;
}

[[maybe_unused]] static vx_guide_span_kind vx_guide_span_next(vx_guide_inline *it, vx_guide_span *sp) {
  *sp = (vx_guide_span){};
  vx_str s = it->s;
  size_t i = it->pos;
  if (i >= s.len) return sp->kind = VX_SPAN_END;
  char c = s.ptr[i];
  if (guide_space(c)) {
    size_t j = i;
    while (j < s.len && guide_space(s.ptr[j])) j++;
    it->pos = j;
    sp->text = (vx_str){s.ptr + i, j - i};
    return sp->kind = VX_SPAN_SPACE;
  }
  if (c == '`') {
    size_t n = guide_ticks(s, i), end = guide_literal_end(s, i, n);
    if (!end) return guide_span_error(it, sp, "a literal that is never closed");
    vx_str in = {s.ptr + i + n, end - i - n};
    if (in.len >= 2 && in.ptr[0] == ' ' && in.ptr[in.len - 1] == ' ' && !guide_blank(in))
      in.ptr++, in.len -= 2;
    it->pos = end + n;
    sp->text = in;
    return sp->kind = VX_SPAN_LITERAL;
  }
  size_t n = guide_param_at(s, i);
  if (n) {
    it->pos = i + n;
    sp->text = (vx_str){s.ptr + i, n};
    return sp->kind = VX_SPAN_PARAM;
  }
  if (c == '{') {
    size_t j = i + 1;
    while (j < s.len && s.ptr[j] != '}' && s.ptr[j] != '{') j++;
    if (j >= s.len || s.ptr[j] == '{') return guide_span_error(it, sp, "a { link } that is never closed");
    vx_str in = {s.ptr + i + 1, j - i - 1};
    size_t bar = 0;
    while (bar < in.len && in.ptr[bar] != '|') bar++;
    sp->target = bar < in.len ? (vx_str){in.ptr + bar + 1, in.len - bar - 1} : in;
    sp->label = bar < in.len ? guide_trim((vx_str){in.ptr, bar}) : sp->target;
    if (!sp->label.len || !guide_target_ok(sp->target))
      return guide_span_error(it, sp, "a link to no target guide knows");
    it->pos = j + 1;
    sp->text = (vx_str){s.ptr + i, j + 1 - i};
    return sp->kind = VX_SPAN_LINK;
  }
  int sect = 0;
  if ((n = guide_ref_at(s, i, &sect))) {
    it->pos = i + n;
    sp->text = (vx_str){s.ptr + i, n};
    sp->name = (vx_str){s.ptr + i, n - 3};
    sp->sect = sect;
    return sp->kind = VX_SPAN_REF;
  }
  size_t j = i + 1; // plain text: up to a space or the next span's start
  while (j < s.len && !guide_space(s.ptr[j]) && s.ptr[j] != '`' && s.ptr[j] != '{' && !guide_param_at(s, j) &&
         !guide_ref_at(s, j, &sect))
    j++;
  it->pos = j;
  sp->text = (vx_str){s.ptr + i, j - i};
  return sp->kind = VX_SPAN_TEXT;
}

[[maybe_unused]] static bool vx_guide_cell_next(vx_str *row, vx_str *cell) {
  if (guide_blank(*row)) return false;
  size_t i = 0;
  while (i < row->len && row->ptr[i] != '|') {
    size_t n = guide_ticks(*row, i);
    size_t end = n ? guide_literal_end(*row, i, n) : 0;
    i = end ? end + n : i + (n ? n : 1);
  }
  *cell = guide_trim((vx_str){row->ptr, i});
  bool bar = i < row->len;
  row->ptr += i + bar, row->len -= i + bar;
  return true;
}

// --- Rendering for a terminal ---

static constexpr uint32_t GUIDE_INDENT = 5, GUIDE_SUB = 3, GUIDE_HANG = 10, GUIDE_MAXCOLS = 16;

typedef struct guide_fill {
  const vx_guide_out *out;
  uint32_t width, lead, col; // lead: where a new line's first word starts
  bool bol;                  // nothing written on this line since its start (or its marker)
  char word[256 + 4];        // a word is written once it holds 256 bytes, at a rune's start
  size_t nword;
  uint32_t wcols;
} guide_fill;

static uint32_t guide_cols(const char *s, size_t n) {
  uint32_t c = 0;
  for (size_t i = 0; i < n; i++) c += ((unsigned char)s[i] & 0xc0) != 0x80;
  return c;
}

static void guide_put(guide_fill *f, const char *s, size_t n) {
  if (n) f->out->write(f->out->ctx, s, n);
  f->col += guide_cols(s, n);
}

static void guide_spaces(guide_fill *f, uint32_t n) {
  static const char sp[] = "                ";
  for (; n > 16; n -= 16) guide_put(f, sp, 16);
  guide_put(f, sp, n);
}

static void guide_newline(guide_fill *f) {
  f->out->write(f->out->ctx, "\n", 1);
  f->col = 0, f->bol = true;
}

static void guide_flush(guide_fill *f) {
  if (!f->nword) return;
  if (!f->bol && f->col + 1 + f->wcols > f->width) guide_newline(f);
  if (f->bol && f->col < f->lead) guide_spaces(f, f->lead - f->col);
  if (!f->bol) guide_put(f, " ", 1);
  guide_put(f, f->word, f->nword);
  f->bol = false, f->nword = 0, f->wcols = 0;
}

// Bytes added to the word being built; a word too long to hold is written as it stands.
static void guide_add(guide_fill *f, const char *s, size_t n) {
  for (size_t i = 0; i < n; i++) {
    bool starts = ((unsigned char)s[i] & 0xc0) != 0x80;
    if (f->nword >= 256 && starts) guide_flush(f);
    if (f->nword == sizeof f->word) continue; // a malformed rune's tail (pages are checked UTF-8)
    f->word[f->nword++] = s[i];
    f->wcols += starts;
  }
}

// Text with its whitespace runs as single spaces, each a place to break.
static void guide_words(guide_fill *f, vx_str s, bool join_first) {
  for (size_t i = 0; i < s.len;) {
    if (guide_space(s.ptr[i])) {
      while (i < s.len && guide_space(s.ptr[i])) i++;
      if (i < s.len) guide_flush(f);
      continue;
    }
    if (!join_first) guide_flush(f);
    join_first = true;
    size_t j = i;
    while (j < s.len && !guide_space(s.ptr[j])) j++;
    guide_add(f, s.ptr + i, j - i);
    i = j;
  }
}

// A block's inline text, filled. False, with *error, on a bad span.
static bool guide_text(guide_fill *f, vx_str s, const char **error) {
  vx_guide_inline it = {.s = s};
  vx_guide_span sp;
  for (;;) {
    switch (vx_guide_span_next(&it, &sp)) {
    case VX_SPAN_END: return true;
    case VX_SPAN_ERROR: *error = it.error; return false;
    case VX_SPAN_SPACE: guide_flush(f); break;
    case VX_SPAN_LITERAL: // one unbreakable word, its whitespace runs single spaces
      for (size_t i = 0; i < sp.text.len; i++) {
        bool sp_run = guide_space(sp.text.ptr[i]);
        if (sp_run && i && guide_space(sp.text.ptr[i - 1])) continue;
        guide_add(f, sp_run ? " " : sp.text.ptr + i, 1);
      }
      break;
    case VX_SPAN_LINK:
      guide_words(f, sp.label, true);
      if (sp.label.ptr != sp.target.ptr) {
        guide_flush(f);
        guide_add(f, "(", 1), guide_add(f, sp.target.ptr, sp.target.len), guide_add(f, ")", 1);
      }
      break;
    default: guide_add(f, sp.text.ptr, sp.text.len); break;
    }
  }
}

static bool guide_para(guide_fill *f, uint32_t lead, vx_str s, const char **error) {
  f->lead = lead;
  bool ok = guide_text(f, s, error);
  guide_flush(f);
  if (f->col) guide_newline(f);
  return ok;
}

// Writes into a buffer: a table cell rendered on one line.
typedef struct guide_buf {
  char *p;
  size_t cap, n;
} guide_buf;

static void guide_buf_write(void *ctx, const char *s, size_t n) {
  guide_buf *b = ctx;
  for (size_t i = 0; i < n && b->n < b->cap; i++) b->p[b->n++] = s[i];
}

static bool guide_cell(vx_str cell, guide_buf *b, uint32_t *cols, const char **error) {
  b->n = 0;
  vx_guide_out o = {.write = guide_buf_write, .ctx = b};
  guide_fill f = {.out = &o, .width = UINT32_MAX, .bol = true};
  bool ok = guide_text(&f, cell, error);
  guide_flush(&f);
  if (b->n == b->cap) { // cut at the buffer's end: back to the last rune's start, dropped if it is not whole
    size_t lead = b->n;
    while (lead > 0 && b->n - lead < VX_UTFMAX && ((unsigned char)b->p[lead - 1] & 0xc0) == 0x80) lead--;
    if (lead > 0 && !vx_fullrune(b->p + lead - 1, b->n - lead + 1)) b->n = lead - 1;
  }
  *cols = guide_cols(b->p, b->n);
  return ok;
}

// The widths of a run of rows from g on (the block just read, b, its first).
static bool guide_widths(const vx_guide *g, const vx_guide_block *b, uint32_t *w, const char **error) {
  static vx_guide look; // a copy to read ahead with, 4 KiB: off the stack
  look = *g;
  vx_guide_block r = *b;
  char buf[512];
  guide_buf gb = {.p = buf, .cap = sizeof buf};
  for (uint32_t k = 0; k < GUIDE_MAXCOLS; k++) w[k] = 0;
  for (size_t line = r.line;;) {
    vx_str row = r.text, cell;
    for (uint32_t k = 0; vx_guide_cell_next(&row, &cell) && k < GUIDE_MAXCOLS; k++) {
      uint32_t c;
      if (!guide_cell(cell, &gb, &c, error)) return false;
      if (c > w[k]) w[k] = c;
    }
    if (vx_guide_next(&look, &r) != VX_GUIDE_ROW || r.line != line + 1) return true;
    line = r.line;
  }
}

static bool guide_row(guide_fill *f, vx_str row, const uint32_t *w, const char **error) {
  char buf[512];
  guide_buf gb = {.p = buf, .cap = sizeof buf};
  vx_str cell;
  guide_spaces(f, GUIDE_INDENT);
  uint32_t pad = 0;
  for (uint32_t k = 0; vx_guide_cell_next(&row, &cell); k++) {
    uint32_t c;
    if (!guide_cell(cell, &gb, &c, error)) return false;
    if (k) guide_spaces(f, pad + 2);
    guide_put(f, buf, gb.n);
    pad = k < GUIDE_MAXCOLS && w[k] > c ? w[k] - c : 0;
  }
  guide_newline(f);
  return true;
}

// A heading's words at `lead`, capitals as written (or, from a node's title, made so).
static bool guide_heading(guide_fill *f, uint32_t lead, vx_str s, bool upper, const char **error) {
  if (!upper) return guide_para(f, lead, s, error);
  char buf[256];
  size_t n = s.len < sizeof buf ? s.len : sizeof buf;
  n = vx_utf_cut(s.ptr, s.len, n);
  for (size_t i = 0; i < n; i++) {
    char c = s.ptr[i];
    buf[i] = guide_upper(c);
  }
  f->lead = lead;
  guide_words(f, (vx_str){buf, n}, false);
  guide_flush(f);
  guide_newline(f);
  return true;
}

static void guide_title(guide_fill *f, const vx_guide_header *h) {
  char t[96];
  size_t n = 0;
  for (size_t i = 0; i < h->page.len && n + 4 < sizeof t; i++) {
    char c = h->page.ptr[i];
    t[n++] = guide_upper(c);
  }
  t[n++] = '(', t[n++] = (char)('0' + h->sect), t[n++] = ')';
  guide_put(f, t, n);
  if (2 * n + 1 <= f->width) guide_spaces(f, f->width - 2 * (uint32_t)n), guide_put(f, t, n);
  guide_newline(f);
}

static void guide_name(guide_fill *f, const vx_guide_header *h) {
  f->lead = GUIDE_INDENT;
  vx_str list = h->names, item;
  bool first = true;
  while (vx_guide_item_next(&list, &item)) {
    if (!first) guide_add(f, ",", 1);
    guide_flush(f);
    guide_add(f, item.ptr, item.len);
    first = false;
  }
  guide_flush(f);
  guide_add(f, "—", sizeof "—" - 1);
  guide_words(f, h->summary, false);
  guide_flush(f);
  guide_newline(f);
}

static void guide_source(guide_fill *f, const vx_guide_header *h) {
  guide_put(f, "SOURCE", 6);
  guide_newline(f);
  vx_str list = h->src, item;
  while (vx_guide_item_next(&list, &item)) {
    guide_spaces(f, GUIDE_INDENT);
    guide_put(f, item.ptr, item.len);
    guide_newline(f);
  }
}

static void guide_fence_out(guide_fill *f, vx_str text) {
  for (size_t i = 0; i < text.len;) {
    size_t j = i;
    while (j < text.len && text.ptr[j] != '\n') j++;
    if (j > i) guide_spaces(f, GUIDE_INDENT), guide_put(f, text.ptr + i, j - i);
    guide_newline(f);
    i = j + 1;
  }
}

static bool guide_def(guide_fill *f, const vx_guide_block *b, const char **error) {
  f->lead = GUIDE_INDENT;
  if (!guide_text(f, b->text, error)) return false;
  guide_flush(f);
  if (!b->body.len) {
    guide_newline(f);
    return true;
  }
  if (f->col + 2 <= GUIDE_HANG) { // a short term: its description on the same line, two spaces on
    guide_spaces(f, GUIDE_HANG - f->col);
    f->bol = true;
  } else {
    guide_newline(f);
  }
  return guide_para(f, GUIDE_HANG, b->body, error);
}

static bool guide_is_late(vx_str heading) { // what Plan 9's order puts after SOURCE
  return guide_eq(heading, "SEE ALSO") || guide_eq(heading, "DIAGNOSTICS") || guide_eq(heading, "BUGS");
}

static bool guide_block_out(guide_fill *f, const vx_guide *g, const vx_guide_block *b, uint32_t *w,
                            size_t *row_line, const char **error) {
  switch (b->kind) {
  case VX_GUIDE_NODE: return guide_heading(f, 0, b->title.len ? b->title : b->node, true, error);
  case VX_GUIDE_HEADING: return guide_heading(f, 0, b->text, false, error);
  case VX_GUIDE_SUBHEADING: return guide_heading(f, GUIDE_SUB, b->text, false, error);
  case VX_GUIDE_PARA: return guide_para(f, GUIDE_INDENT, b->text, error);
  case VX_GUIDE_ITEM:
    guide_spaces(f, GUIDE_INDENT), guide_put(f, "- ", 2);
    f->bol = true;
    return guide_para(f, GUIDE_INDENT + 2, b->text, error);
  case VX_GUIDE_DEF: return guide_def(f, b, error);
  case VX_GUIDE_ROW:
    if (*row_line + 1 != b->line && !guide_widths(g, b, w, error)) return false;
    *row_line = b->line;
    return guide_row(f, b->text, w, error);
  case VX_GUIDE_FENCE: guide_fence_out(f, b->text); return true;
  default: return true;
  }
}

[[maybe_unused]] static bool vx_guide_render(vx_str page, const char *node, const vx_guide_out *out,
                                             const char **error, size_t *line) {
  static vx_guide g; // 4 KiB: off the stack
  *error = nullptr, *line = 0;
  if (!vx_guide_open(&g, page)) {
    *error = g.error, *line = g.error_line;
    return false;
  }
  guide_fill f = {.out = out, .width = out->width ? out->width : 80, .bol = true};
  vx_str want = {node, 0};
  while (node && node[want.len]) want.len++;
  bool on = !node, source = !node && g.h.src.len, found = false;
  if (on) {
    guide_title(&f, &g.h);
    guide_newline(&f);
    guide_put(&f, "NAME", 4), guide_newline(&f);
    guide_name(&f, &g.h);
  }
  vx_guide_kind prev = VX_GUIDE_HEADING;
  size_t row_line = 0;
  uint32_t w[GUIDE_MAXCOLS] = {};
  vx_guide_block b;
  for (;;) {
    vx_guide_kind k = vx_guide_next(&g, &b);
    if (k == VX_GUIDE_ERROR) {
      *error = g.error, *line = g.error_line;
      return false;
    }
    if (k == VX_GUIDE_END) break;
    if (k == VX_GUIDE_NODE && node) {
      if (on) break; // the next node: the one asked for has ended
      on = found = guide_same(b.node, want);
      prev = VX_GUIDE_END;
    }
    if (!on) continue;
    if (k == VX_GUIDE_HEADING && source && guide_is_late(b.text)) {
      guide_newline(&f), guide_source(&f, &g.h);
      source = false;
    }
    bool heading = k == VX_GUIDE_NODE || k == VX_GUIDE_HEADING || k == VX_GUIDE_SUBHEADING;
    bool joined =
        (prev == VX_GUIDE_HEADING || prev == VX_GUIDE_SUBHEADING || prev == VX_GUIDE_NODE) && !heading;
    joined = joined || (k == VX_GUIDE_ITEM && prev == VX_GUIDE_ITEM) ||
             (k == VX_GUIDE_ROW && row_line + 1 == b.line);
    if (!joined && prev != VX_GUIDE_END) guide_newline(&f);
    if (!guide_block_out(&f, &g, &b, w, &row_line, error)) {
      *line = b.line;
      return false;
    }
    if (k != VX_GUIDE_ROW) row_line = 0;
    prev = k;
  }
  if (node && !found) {
    *error = "no such node";
    return false;
  }
  if (source) guide_newline(&f), guide_source(&f, &g.h);
  return true;
}
