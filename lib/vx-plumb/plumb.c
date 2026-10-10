// vx-plumb: messages and rules (plumb.h), after 9front's libplumb/mesg.c and
// cmd/plumb/rules.c and match.c. Regular expressions are vx-text's, sam's
// (regexp(7), leftmost-longest), as 9front's plumber's are libregexp's.
//
// Where it differs from 9front: a parse error says file:line for each file
// of the include stack, at reading and writing both; the text of a rules
// write that failed is dropped, not parsed again at the next; "rules" is no
// port's name, as "send" is not; a click is counted in runes throughout;
// ^ holds only at the data's start or after a newline, even when a click's
// match is tried from further in; and a regular expression's error gives
// vx-text's reason, not "parsing error".

#pragma once

#include "plumb.h"
#include "../vx-text/text.c"

static constexpr uint32_t VP_INCLUDES = 10, VP_EXPAND = 4096;

void *vx_plumb_alloc(size_t n) { return vt_alloc(n); }
void vx_plumb_dealloc(void *p) { vt_free(p); }

// The C library's string calls, which vx-rt has not (vx_str is its kind).
static size_t vp_len(const char *s) {
  size_t n = 0;
  while (s && s[n]) n++;
  return n;
}

static bool vp_eq(const char *a, const char *b) {
  a = a ? a : "", b = b ? b : "";
  while (*a && *a == *b) a++, b++;
  return *a == *b;
}

// Whether s starts with prefix.
static bool vp_prefix(const char *s, const char *prefix) {
  while (*prefix && *s == *prefix) s++, prefix++;
  return !*prefix;
}

[[maybe_unused]] static bool vp_has(const char *s, char c) { // the plumber's and plumb's
  for (; *s; s++)
    if (*s == c) return true;
  return false;
}

static char *vp_dup_n(const char *s, size_t n) {
  char *p = vt_alloc(n + 1);
  if (!p) return nullptr;
  if (n) __builtin_memcpy(p, s, n);
  p[n] = 0;
  return p;
}

static char *vp_dup(const char *s) { return vp_dup_n(s ? s : "", vp_len(s)); }

static bool vp_blank(char c) { return c == ' ' || c == '\t'; }
static bool vp_alpha(char c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }
static bool vp_alnum(char c) { return vp_alpha(c) || (c >= '0' && c <= '9'); }

// --- Messages (libplumb/mesg.c) ---

void vx_plumb_free_attr(vx_plumb_attr *a) {
  while (a) {
    vx_plumb_attr *next = a->next;
    vt_free(a->name), vt_free(a->value), vt_free(a);
    a = next;
  }
}

void vx_plumb_free(vx_plumb_msg *m) {
  if (!m) return;
  vt_free(m->src), vt_free(m->dst), vt_free(m->wdir), vt_free(m->type), vt_free(m->data);
  vx_plumb_free_attr(m->attr);
  vt_free(m);
}

vx_plumb_msg *vx_plumb_msg_new(const char *src, const char *dst, const char *wdir, const char *type,
                               const char *data, size_t ndata) {
  vx_plumb_msg *m = vt_alloc(sizeof *m);
  if (!m) return nullptr;
  *m = (vx_plumb_msg){.src = vp_dup(src),
                      .dst = vp_dup(dst),
                      .wdir = vp_dup(wdir),
                      .type = vp_dup(type),
                      .ndata = ndata,
                      .data = vp_dup_n(data ? data : "", data ? ndata : 0)};
  if (!data) m->ndata = 0;
  if (!m->src || !m->dst || !m->wdir || !m->type || !m->data) return vx_plumb_free(m), nullptr;
  return m;
}

// A value as it is packed: quoted when it holds a blank, a quote or an =.
static size_t vp_quote(const char *s, char *out) {
  size_t n = vp_len(s), k = 0;
  bool q = false;
  for (size_t i = 0; i < n && !q; i++) q = s[i] == ' ' || s[i] == '\t' || s[i] == '\'' || s[i] == '=';
  if (!q) {
    if (out) __builtin_memcpy(out, s, n);
    return n;
  }
  if (out) out[k] = '\'';
  k++;
  for (size_t i = 0; i < n; i++) {
    if (out) out[k] = s[i];
    k++;
    if (s[i] == '\'') {
      if (out) out[k] = '\'';
      k++;
    }
  }
  if (out) out[k] = '\'';
  return k + 1;
}

static size_t vp_pack_attr(const vx_plumb_attr *attr, char *out) {
  size_t k = 0;
  for (const vx_plumb_attr *a = attr; a; a = a->next) {
    if (a != attr) {
      if (out) out[k] = ' ';
      k++;
    }
    size_t n = vp_len(a->name);
    if (out) __builtin_memcpy(out + k, a->name, n), out[k + n] = '=';
    k += n + 1;
    k += vp_quote(a->value, out ? out + k : nullptr);
  }
  return k;
}

char *vx_plumb_pack_attr(const vx_plumb_attr *a) {
  if (!a) return nullptr;
  size_t n = vp_pack_attr(a, nullptr);
  char *s = vt_alloc(n + 1);
  if (!s) return nullptr;
  vp_pack_attr(a, s);
  s[n] = 0;
  return s;
}

const char *vx_plumb_lookup(const vx_plumb_attr *a, const char *name) {
  for (; a; a = a->next)
    if (vp_eq(a->name, name)) return a->value;
  return nullptr;
}

vx_plumb_attr *vx_plumb_add_attr(vx_plumb_attr *a, vx_plumb_attr *more) {
  if (!a) return more;
  vx_plumb_attr *l = a;
  while (l->next) l = l->next;
  l->next = more;
  return a;
}

vx_plumb_attr *vx_plumb_del_attr(vx_plumb_attr *a, const char *name) {
  vx_plumb_attr **at = &a;
  while (*at && !vp_eq((*at)->name, name)) at = &(*at)->next;
  if (*at) {
    vx_plumb_attr *gone = *at;
    *at = gone->next, gone->next = nullptr;
    vx_plumb_free_attr(gone);
  }
  return a;
}

vx_plumb_attr *vx_plumb_unpack_attr(const char *s) {
  const char *p = s;
  vx_plumb_attr *attr = nullptr, **tail = &attr;
  char *buf = vt_alloc(vp_len(p) + 1);
  if (!buf) return nullptr;
  while (*p && *p != '\n') {
    while (vp_blank(*p)) p++;
    if (!*p) break;
    const char *q = p;
    while (*q && *q != '\n' && !vp_blank(*q) && *q != '=') q++;
    if (*q != '=') break; // malformed: the list ends
    size_t v = 0;
    const char *name = p;
    size_t nname = (size_t)(q - p);
    q++;
    bool quoting = false;
    while (*q && *q != '\n') {
      char c = *q++;
      if (quoting && c == '\'') {
        if (*q != '\'') {
          quoting = false;
          continue;
        }
        q++;
      } else if (!quoting && vp_blank(c)) {
        break;
      } else if (!quoting && c == '\'') {
        quoting = true;
        continue;
      }
      buf[v++] = c;
    }
    vx_plumb_attr *a = vt_alloc(sizeof *a);
    if (!a) break;
    *a = (vx_plumb_attr){.name = vp_dup_n(name, nname), .value = vp_dup_n(buf, v)};
    if (!a->name || !a->value) {
      vx_plumb_free_attr(a);
      break;
    }
    *tail = a, tail = &a->next;
    p = q;
  }
  vt_free(buf);
  return attr;
}

static size_t vp_put(char *out, size_t k, const char *s, size_t n) {
  if (n) __builtin_memcpy(out + k, s, n);
  return k + n;
}

char *vx_plumb_pack(const vx_plumb_msg *m, size_t *np) {
  char *attr = vx_plumb_pack_attr(m->attr);
  size_t na = vp_len(attr),
         n = vp_len(m->src) + vp_len(m->dst) + vp_len(m->wdir) + vp_len(m->type) + na + 5 + 21 + m->ndata;
  char *buf = vt_alloc(n + 1);
  if (!buf) return vt_free(attr), nullptr;
  size_t k = 0;
  const char *fields[] = {m->src, m->dst, m->wdir, m->type, attr};
  for (size_t i = 0; i < 5; i++) {
    k = vp_put(buf, k, fields[i], vp_len(fields[i]));
    buf[k++] = '\n';
  }
  char num[24];
  size_t nn = 0;
  uint64_t v = m->ndata;
  do num[nn++] = (char)('0' + v % 10), v /= 10;
  while (v);
  while (nn) buf[k++] = num[--nn];
  buf[k++] = '\n';
  k = vp_put(buf, k, m->data, m->ndata);
  buf[k] = 0;
  vt_free(attr);
  *np = k;
  return buf;
}

// The line at *o in buf, copied, *o past its newline; nullptr if none ends.
static char *vp_line(const char *buf, size_t n, size_t *o) {
  for (size_t i = *o; i < n; i++)
    if (buf[i] == '\n') {
      char *s = vp_dup_n(buf + *o, i - *o);
      *o = i + 1;
      return s;
    }
  return nullptr;
}

vx_plumb_msg *vx_plumb_unpack(const char *buf, size_t n, size_t *more) {
  if (more) *more = 0;
  vx_plumb_msg *m = vt_alloc(sizeof *m);
  if (!m) return nullptr;
  *m = (vx_plumb_msg){};
  size_t o = 0;
  char *attr = nullptr, *count = nullptr;
  if (!(m->src = vp_line(buf, n, &o)) || !(m->dst = vp_line(buf, n, &o)) ||
      !(m->wdir = vp_line(buf, n, &o)) || !(m->type = vp_line(buf, n, &o)) || !(attr = vp_line(buf, n, &o)) ||
      !(count = vp_line(buf, n, &o)))
    goto bad;
  m->attr = vx_plumb_unpack_attr(attr);
  uint64_t nd = 0;
  bool digits = *count != 0;
  for (const char *c = count; *c && digits; c++) {
    digits = *c >= '0' && *c <= '9' && nd < (1ull << 40);
    nd = nd * 10 + (uint64_t)(*c - '0');
  }
  if (!digits) goto bad;
  if (n - o < nd) {
    if (more) *more = (size_t)nd - (n - o);
    goto bad;
  }
  m->ndata = (size_t)nd;
  if (!(m->data = vp_dup_n(buf + o, m->ndata))) goto bad;
  vt_free(attr), vt_free(count);
  return m;
bad:
  vt_free(attr), vt_free(count);
  vx_plumb_free(m);
  return nullptr;
}

char *vx_plumb_clean(char *name) {
  bool rooted = name[0] == '/';
  char *out = name + rooted, *dotdot = out; // dotdot: where a ".." may back up to
  const char *p = out;
  while (*p) {
    if (*p == '/' || (p[0] == '.' && (p[1] == '/' || !p[1]))) {
      p++;
    } else if (p[0] == '.' && p[1] == '.' && (p[2] == '/' || !p[2])) {
      p += 2;
      if (out > dotdot) {
        do out--;
        while (out > dotdot && *out != '/');
      } else if (!rooted) {
        if (out != name) *out++ = '/';
        *out++ = '.', *out++ = '.';
        dotdot = out;
      }
    } else {
      if ((rooted && out != name + 1) || (!rooted && out != name)) *out++ = '/';
      while (*p && *p != '/') *out++ = *p++;
    }
  }
  if (out == name) *out++ = '.';
  *out = 0;
  return name;
}

// --- Rules (cmd/plumb/rules.c) ---

enum : uint8_t { O_ARG, O_ATTR, O_DATA, O_DST, O_PLUMB, O_SRC, O_TYPE, O_WDIR };
enum : uint8_t { V_ADD, V_CLIENT, V_DELETE, V_IS, V_ISDIR, V_ISFILE, V_MATCHES, V_SET, V_START, V_TO };

static const char *const vp_objects[] = {"arg", "attr", "data", "dst",  "plumb",
                                         "src", "type", "wdir", nullptr};
static const char *const vp_verbs[] = {"add",     "client", "delete", "is", "isdir", "isfile",
                                       "matches", "set",    "start",  "to", nullptr};
static const char *const vp_bad_ports[] = {".", "..", "send", "rules", nullptr};

typedef struct vp_rule {
  uint8_t obj, verb;
  char *arg;  // as written
  char *qarg; // its quotes and variables expanded at parsing
  vt_rx *rx;  // matches'
} vp_rule;

typedef struct vp_ruleset {
  vp_rule **pat, **act;
  uint32_t npat, nact;
  size_t cappat, capact;
  char *port;
} vp_ruleset;

typedef struct vp_var {
  char *name, *value, *qvalue;
} vp_var;

typedef struct vp_input {
  char *name;
  char *text; // owned, the whole file (or the base's text, not)
  size_t len, at;
  uint32_t line;
  bool owned;
} vp_input;

struct vx_plumb_rules {
  vx_plumb_fs fs;
  vp_ruleset **sets;
  size_t nsets, capsets;
  vp_var *vars;
  size_t nvars, capvars;
  char **ports;
  size_t nports, capports;
  vp_input in[VP_INCLUDES + 1];
  uint32_t depth; // inputs on the stack
  char *pending;  // written to the rules file, not yet parsed
  size_t npending;
  char *line;
  size_t capline;
  bool failed;
  char error[512];
  char ebuf[VP_EXPAND]; // expand's
  char *fbuf;           // filename's, $file and $dir
  char *abuf;           // $attr's
};

struct vx_plumb_exec {
  const vp_ruleset *rs;
  vx_plumb_msg *msg;
  char *match[VT_RX_SUBS];
  int64_t p0, p1; // the click's match in data
  bool clearclick, setdata, hold;
  char *file, *dir; // isfile's and isdir's
};

static void vp_fail(vx_plumb_rules *r, const char *a, const char *b) {
  if (r->failed) return;
  r->failed = true;
  size_t k = 0, cap = sizeof r->error - 1;
  for (uint32_t i = 0; i < r->depth; i++) { // the include stack, outermost first: file:line:
    const vp_input *in = &r->in[i];
    char num[12];
    size_t nn = 0;
    uint32_t v = in->line;
    do num[nn++] = (char)('0' + v % 10), v /= 10;
    while (v);
    for (const char *s = in->name; *s && k < cap; s++) r->error[k++] = *s;
    if (k < cap) r->error[k++] = ':';
    while (nn && k < cap) r->error[k++] = num[--nn];
    if (k < cap) r->error[k++] = ':';
    if (k < cap) r->error[k++] = ' ';
  }
  for (const char *s = a; s && *s && k < cap; s++) r->error[k++] = *s;
  for (const char *s = b; s && *s && k < cap; s++) r->error[k++] = *s;
  r->error[k] = 0;
}

const char *vx_plumb_rules_error(const vx_plumb_rules *r) { return r->failed ? r->error : nullptr; }

static bool vp_push(vx_plumb_rules *r, const char *name, char *text, size_t len, bool owned) {
  if (r->depth > VP_INCLUDES) {
    if (owned) vt_free(text);
    return vp_fail(r, "include stack too deep; max 10", nullptr), false;
  }
  char *n = vp_dup(name);
  if (!n) {
    if (owned) vt_free(text);
    return vp_fail(r, "out of memory", nullptr), false;
  }
  r->in[r->depth++] = (vp_input){.name = n, .text = text, .len = len, .owned = owned};
  return true;
}

static void vp_pop(vx_plumb_rules *r) {
  vp_input *in = &r->in[--r->depth];
  vt_free(in->name);
  if (in->owned) vt_free(in->text);
  *in = (vp_input){};
}

// The top input's next line, in r->line; false at its end.
static bool vp_getline(vx_plumb_rules *r) {
  vp_input *in = &r->in[r->depth - 1];
  if (in->at >= in->len) return false;
  size_t i = in->at;
  while (i < in->len && in->text[i] != '\n' && in->text[i]) i++;
  size_t n = i - in->at;
  if (!vt_grow((void **)&r->line, &r->capline, n + 1, 1)) return vp_fail(r, "out of memory", nullptr), false;
  __builtin_memcpy(r->line, in->text + in->at, n);
  r->line[n] = 0;
  in->at = i < in->len ? i + 1 : i;
  in->line++;
  return true;
}

static int vp_lookup(const char *s, const char *const tab[]) {
  for (int i = 0; tab[i]; i++)
    if (vp_eq(s, tab[i])) return i;
  return -1;
}

static vp_var *vp_variable(vx_plumb_rules *r, const char *s, size_t n) {
  for (size_t i = 0; i < r->nvars; i++)
    if (vp_len(r->vars[i].name) == n && __builtin_memcmp(r->vars[i].name, s, n) == 0) return &r->vars[i];
  return nullptr;
}

// $file and $dir: the name isfile or isdir found, else the data, made
// absolute by the working directory.
static const char *vp_filename(vx_plumb_rules *r, const vx_plumb_exec *e, const char *name) {
  vt_free(r->fbuf);
  const vx_plumb_msg *m = e->msg;
  if (name && *name) {
    r->fbuf = vp_dup(name);
  } else if (m->data[0] == '/' || !m->wdir[0]) {
    r->fbuf = vp_dup(m->data);
  } else {
    size_t nw = vp_len(m->wdir), nd = vp_len(m->data);
    if ((r->fbuf = vt_alloc(nw + nd + 2))) {
      __builtin_memcpy(r->fbuf, m->wdir, nw), r->fbuf[nw] = '/';
      __builtin_memcpy(r->fbuf + nw + 1, m->data, nd + 1);
    }
  }
  return r->fbuf ? vx_plumb_clean(r->fbuf) : "";
}

static const char *vp_nonnil(const char *s) { return s ? s : ""; }

static bool vp_word(const char *s, size_t n, const char *w) {
  return vp_len(w) == n && __builtin_memcmp(s, w, n) == 0;
}

static const char *vp_dollar(vx_plumb_rules *r, const vx_plumb_exec *e, const char *s, size_t *namelen) {
  *namelen = 1;
  if (e && s[0] >= '0' && s[0] <= '9') return vp_nonnil(e->match[s[0] - '0']);
  size_t n = 0;
  while (vp_alnum(s[n])) n++;
  *namelen = n;
  if (e) {
    const vx_plumb_msg *m = e->msg;
    if (vp_word(s, n, "src")) return m->src;
    if (vp_word(s, n, "dst")) return m->dst;
    if (vp_word(s, n, "dir")) return vp_filename(r, e, e->dir);
    if (vp_word(s, n, "attr")) {
      vt_free(r->abuf);
      r->abuf = vx_plumb_pack_attr(m->attr);
      return vp_nonnil(r->abuf);
    }
    if (vp_word(s, n, "data")) return m->data;
    if (vp_word(s, n, "file")) return vp_filename(r, e, e->file);
    if (vp_word(s, n, "type")) return m->type;
    if (vp_word(s, n, "wdir")) return m->wdir;
  }
  vp_var *v = vp_variable(r, s, n);
  return v ? v->qvalue : nullptr;
}

// One blank-ended word of s expanded, its quotes taken off and its $names
// put in, in r->ebuf; *ends, if asked, where it ended.
static const char *vp_expand(vx_plumb_rules *r, const vx_plumb_exec *e, const char *s, const char **ends) {
  char *p = r->ebuf, *ep = r->ebuf + sizeof r->ebuf - 1;
  bool quoting = false;
  while (p < ep && *s && (quoting || !vp_blank(*s))) {
    if (*s == '\'') {
      s++;
      if (!quoting) {
        quoting = true;
      } else if (*s == '\'') {
        *p++ = '\'', s++;
      } else {
        quoting = false;
      }
      continue;
    }
    if (quoting || *s != '$') {
      *p++ = *s++;
      continue;
    }
    s++;
    size_t namelen;
    const char *val = vp_dollar(r, e, s, &namelen);
    if (!val) {
      *p++ = '$';
      continue;
    }
    size_t n = vp_len(val);
    if ((size_t)(ep - p) < n) return "string-too-long";
    __builtin_memcpy(p, val, n);
    p += n, s += namelen;
  }
  if (ends) *ends = s;
  *p = 0;
  return r->ebuf;
}

static void vp_free_rule(vp_rule *rule) {
  if (!rule) return;
  vt_free(rule->arg), vt_free(rule->qarg);
  if (rule->rx) vt_rx_free(rule->rx), vt_free(rule->rx);
  vt_free(rule);
}

static void vp_free_ruleset(vp_ruleset *rs) {
  for (uint32_t i = 0; i < rs->npat; i++) vp_free_rule(rs->pat[i]);
  for (uint32_t i = 0; i < rs->nact; i++) vp_free_rule(rs->act[i]);
  vt_free(rs->pat), vt_free(rs->act), vt_free(rs->port), vt_free(rs);
}

static bool vp_parse_rule(vx_plumb_rules *r, vp_rule *rule) {
  if (!(rule->qarg = vp_dup(vp_expand(r, nullptr, rule->arg, nullptr))))
    return vp_fail(r, "out of memory", nullptr), false;
  bool plumb = rule->obj == O_PLUMB,
       action = rule->verb == V_CLIENT || rule->verb == V_START || rule->verb == V_TO;
  if (plumb != action || (!plumb && rule->obj != O_ATTR && (rule->verb == V_ADD || rule->verb == V_DELETE))) {
    char what[64];
    size_t k = 0;
    for (const char *s = vp_verbs[rule->verb]; *s; s++) what[k++] = *s;
    for (const char *s = " not valid verb for object "; *s; s++) what[k++] = *s;
    what[k] = 0;
    return vp_fail(r, what, vp_objects[rule->obj]), false;
  }
  if (rule->verb != V_MATCHES) return true;
  if (!(rule->rx = vt_alloc(sizeof *rule->rx))) return vp_fail(r, "out of memory", nullptr), false;
  const char *err = vt_rx_compile(rule->rx, rule->qarg, vp_len(rule->qarg));
  if (err) { // 9front's words, "regexp RE: parsing error", with vx-text's reason
    char what[128] = "regexp ";
    size_t k = 7;
    for (const char *c = rule->qarg; *c && k < sizeof what - 3; c++) what[k++] = *c;
    what[k++] = ':', what[k++] = ' ', what[k] = 0;
    return vp_fail(r, what, err), false;
  }
  return true;
}

static bool vp_assignment(vx_plumb_rules *r, const char *p) {
  if (!vp_alpha(p[0])) return false;
  const char *var = p;
  while (vp_alnum(*p)) p++;
  size_t n = (size_t)(p - var);
  while (vp_blank(*p)) p++;
  if (*p++ != '=') return false;
  while (vp_blank(*p)) p++;
  const char *q = vp_expand(r, nullptr, p, nullptr);
  vp_var *v = vp_variable(r, var, n);
  if (!v) {
    if (!vt_grow((void **)&r->vars, &r->capvars, r->nvars + 1, sizeof *r->vars))
      return vp_fail(r, "out of memory", nullptr), true;
    v = &r->vars[r->nvars++];
    *v = (vp_var){.name = vp_dup_n(var, n)};
  }
  vt_free(v->value), vt_free(v->qvalue);
  v->value = vp_dup(p), v->qvalue = vp_dup(q);
  if (!v->name || !v->value || !v->qvalue) vp_fail(r, "out of memory", nullptr);
  return true;
}

// "include FILE [#...]": FILE pushed, from /lib/plumb when it is not there
// and its name is neither rooted nor ./ or ../.
static bool vp_include(vx_plumb_rules *r, const char *s) {
  if (!vp_prefix(s, "include")) return false;
  const char *p = s + 7;
  if (*p && !vp_blank(*p)) return vp_fail(r, "malformed include statement", nullptr), true;
  while (vp_blank(*p)) p++;
  const char *name = p;
  while (*p && !vp_blank(*p)) p++;
  size_t n = (size_t)(p - name);
  while (vp_blank(*p)) p++;
  if (!n || name[0] == '#' || (*p && *p != '#') || n > 200)
    return vp_fail(r, "malformed include statement", nullptr), true;
  char path[256];
  __builtin_memcpy(path, name, n), path[n] = 0;
  size_t len = 0;
  char *text = r->fs.read ? r->fs.read(r->fs.ctx, path, &len) : nullptr;
  if (!text && path[0] != '/' && !vp_prefix(path, "./") && !vp_prefix(path, "../")) {
    char lib[256 + 10] = "/lib/plumb/";
    __builtin_memcpy(lib + 11, path, n + 1);
    __builtin_memcpy(path, lib, n + 12 <= sizeof path ? n + 12 : sizeof path);
    path[sizeof path - 1] = 0;
    text = r->fs.read ? r->fs.read(r->fs.ctx, path, &len) : nullptr;
  }
  if (!text) {
    char what[300] = "can't open ";
    size_t k = 11;
    for (const char *c = path; *c && k < sizeof what - 20; c++) what[k++] = *c;
    what[k] = 0;
    return vp_fail(r, what, " for inclusion"), true;
  }
  vp_push(r, path, text, len, true);
  return true;
}

// The next rule; nullptr at a blank line, a comment or an assignment, or
// with *eof at the end of the input (an include's end goes on).
static vp_rule *vp_read_rule(vx_plumb_rules *r, bool *eof) {
  for (;;) {
    if (r->failed) return *eof = true, nullptr;
    if (!vp_getline(r)) {
      if (r->failed) return *eof = true, nullptr;
      if (r->depth > 1) {
        vp_pop(r);
        continue;
      }
      return *eof = true, nullptr;
    }
    char *p = r->line;
    while (vp_blank(*p)) p++;
    if (!*p || *p == '#') return nullptr;
    if (vp_include(r, p)) continue;
    if (vp_assignment(r, p)) return nullptr;
    char *word = p;
    while (*p && !vp_blank(*p)) p++;
    if (!*p) return vp_fail(r, "malformed rule", nullptr), nullptr;
    *p++ = 0;
    int obj = vp_lookup(word, vp_objects);
    if (obj < 0 && vp_eq(word, "kind")) obj = O_TYPE; // the old name
    if (obj < 0) return vp_fail(r, "unknown object ", word), nullptr;
    while (vp_blank(*p)) p++;
    word = p;
    while (*p && !vp_blank(*p)) p++;
    if (!*p) return vp_fail(r, "malformed rule", nullptr), nullptr;
    *p++ = 0;
    int verb = vp_lookup(word, vp_verbs);
    if (verb < 0) return vp_fail(r, "unknown verb ", word), nullptr;
    while (vp_blank(*p)) p++;
    if (!*p) return vp_fail(r, "malformed rule", nullptr), nullptr;
    vp_rule *rule = vt_alloc(sizeof *rule);
    if (!rule) return vp_fail(r, "out of memory", nullptr), nullptr;
    *rule = (vp_rule){.obj = (uint8_t)obj, .verb = (uint8_t)verb, .arg = vp_dup(p)};
    if (!rule->arg || !vp_parse_rule(r, rule)) {
      vp_free_rule(rule);
      if (!r->failed) vp_fail(r, "out of memory", nullptr);
      return nullptr;
    }
    return rule;
  }
}

static void vp_add_port(vx_plumb_rules *r, const char *port) {
  if (!port || !*port) return;
  for (size_t i = 0; i < r->nports; i++)
    if (vp_eq(r->ports[i], port)) return;
  char *p = vp_dup(port);
  if (!p || !vt_grow((void **)&r->ports, &r->capports, r->nports + 1, sizeof *r->ports)) {
    vt_free(p);
    return;
  }
  r->ports[r->nports++] = p;
}

static bool vp_append(vp_rule ***list, uint32_t *n, size_t *cap, vp_rule *rule) {
  if (!vt_grow((void **)list, cap, *n + 1, sizeof **list)) return false;
  (*list)[(*n)++] = rule;
  return true;
}

// The next ruleset: patterns then actions, ended by a blank line. One of
// only `plumb to` declares ports and is not kept. nullptr at the end.
static vp_ruleset *vp_read_ruleset(vx_plumb_rules *r) {
  for (;;) {
    vp_ruleset *rs = vt_alloc(sizeof *rs);
    if (!rs) return vp_fail(r, "out of memory", nullptr), nullptr;
    *rs = (vp_ruleset){};
    bool eof = false, in_rule = false;
    uint32_t ncmd = 0;
    for (;;) {
      vp_rule *rule = vp_read_rule(r, &eof);
      if (eof) break;
      if (!rule) {
        if (in_rule) break;
        continue;
      }
      in_rule = true;
      bool ok;
      if (rule->obj != O_PLUMB) {
        ok = vp_append(&rs->pat, &rs->npat, &rs->cappat, rule);
      } else {
        ok = vp_append(&rs->act, &rs->nact, &rs->capact, rule);
        if (ok && rule->verb == V_TO) {
          if (rs->npat > 0 && rs->port) vp_fail(r, "too many ports", nullptr);
          if (vp_lookup(rule->qarg, vp_bad_ports) >= 0) vp_fail(r, "illegal port name ", rule->qarg);
          vt_free(rs->port);
          rs->port = vp_dup(rule->qarg);
        } else if (ok) {
          ncmd++; // start or client
        }
      }
      if (!ok) vp_free_rule(rule), vp_fail(r, "out of memory", nullptr);
      if (r->failed) break;
    }
    if (!r->failed && ncmd > 1) vp_fail(r, "ruleset has more than one client or start action", nullptr);
    if (r->failed) return vp_free_ruleset(rs), nullptr;
    if (rs->npat > 0 && rs->nact > 0) return rs;
    if (rs->npat == 0 && rs->nact == 0) return vp_free_ruleset(rs), nullptr;
    if (rs->nact == 0 || !rs->port) {
      vp_fail(r, "ruleset must have patterns and actions", nullptr);
      return vp_free_ruleset(rs), nullptr;
    }
    for (uint32_t i = 0; i < rs->nact; i++)
      if (rs->act[i]->verb != V_TO) {
        vp_fail(r, "ruleset must have actions", nullptr);
        return vp_free_ruleset(rs), nullptr;
      }
    for (uint32_t i = 0; i < rs->nact; i++) vp_add_port(r, rs->act[i]->qarg);
    vp_free_ruleset(rs);
    if (eof) return nullptr;
  }
}

// Every ruleset of the input on the stack's base, added; its ports made.
static bool vp_parse(vx_plumb_rules *r) {
  vp_ruleset *rs;
  while ((rs = vp_read_ruleset(r))) {
    if (!vt_grow((void **)&r->sets, &r->capsets, r->nsets + 1, sizeof *r->sets)) {
      vp_free_ruleset(rs);
      vp_fail(r, "out of memory", nullptr);
      break;
    }
    r->sets[r->nsets++] = rs;
    vp_add_port(r, rs->port);
  }
  while (r->depth) vp_pop(r);
  return !r->failed;
}

vx_plumb_rules *vx_plumb_rules_new(const vx_plumb_fs *fs) {
  vx_plumb_rules *r = vt_alloc(sizeof *r);
  if (!r) return nullptr;
  *r = (vx_plumb_rules){};
  if (fs) r->fs = *fs;
  return r;
}

void vx_plumb_rules_clear(vx_plumb_rules *r) {
  for (size_t i = 0; i < r->nsets; i++) vp_free_ruleset(r->sets[i]);
  r->nsets = 0;
}

void vx_plumb_rules_free(vx_plumb_rules *r) {
  if (!r) return;
  vx_plumb_rules_clear(r);
  for (size_t i = 0; i < r->nvars; i++)
    vt_free(r->vars[i].name), vt_free(r->vars[i].value), vt_free(r->vars[i].qvalue);
  for (size_t i = 0; i < r->nports; i++) vt_free(r->ports[i]);
  vt_free(r->sets), vt_free(r->vars), vt_free(r->ports), vt_free(r->pending), vt_free(r->line);
  vt_free(r->fbuf), vt_free(r->abuf), vt_free(r);
}

bool vx_plumb_rules_read(vx_plumb_rules *r, const char *name, const char *text, size_t n) {
  r->failed = false;
  if (!vp_push(r, name, (char *)(uintptr_t)text, n, false)) return false;
  return vp_parse(r);
}

bool vx_plumb_rules_write(vx_plumb_rules *r, const char *text, size_t n, bool done) {
  r->failed = false;
  if (n) {
    char *p = vt_alloc(r->npending + n + 1);
    if (!p) return vp_fail(r, "out of memory", nullptr), false;
    if (r->npending) __builtin_memcpy(p, r->pending, r->npending);
    __builtin_memcpy(p + r->npending, text, n);
    vt_free(r->pending);
    r->pending = p, r->npending += n;
    p[r->npending] = 0;
  }
  if (!r->npending) return true;
  // Whole rulesets as they come, so an error is the write's, not the
  // close's: up to the last blank line, or all of it at the close.
  size_t cut = 0;
  if (done) {
    cut = r->npending;
  } else {
    for (size_t i = 0; i + 1 < r->npending; i++)
      if (r->pending[i] == '\n' && r->pending[i + 1] == '\n') cut = i + 2;
    if (!cut) return true;
  }
  if (!vp_push(r, "<rules input>", r->pending, cut, false)) return false;
  bool ok = vp_parse(r);
  size_t rest = ok ? r->npending - cut : 0; // the text of a failed write is dropped
  if (rest) __builtin_memmove(r->pending, r->pending + cut, rest);
  r->npending = rest;
  if (!rest) vt_free(r->pending), r->pending = nullptr;
  return ok;
}

uint32_t vx_plumb_port_count(const vx_plumb_rules *r) { return (uint32_t)r->nports; }
const char *vx_plumb_port(const vx_plumb_rules *r, uint32_t i) {
  return i < r->nports ? r->ports[i] : nullptr;
}

typedef struct vp_out {
  char *p;
  size_t n, cap;
  bool failed;
} vp_out;

static void vp_out_put(vp_out *o, const char *s) {
  size_t n = vp_len(s);
  if (o->failed || !vt_grow((void **)&o->p, &o->cap, o->n + n + 1, 1) || !o->p) {
    o->failed = true;
    return;
  }
  __builtin_memcpy(o->p + o->n, s, n);
  o->n += n, o->p[o->n] = 0;
}

static void vp_print_rule(vp_out *o, const vp_rule *rule) {
  vp_out_put(o, vp_objects[rule->obj]), vp_out_put(o, "\t");
  vp_out_put(o, vp_verbs[rule->verb]), vp_out_put(o, "\t");
  vp_out_put(o, rule->arg), vp_out_put(o, "\n");
}

char *vx_plumb_rules_print(vx_plumb_rules *r, size_t *n) {
  vp_out o = {};
  for (size_t i = 0; i < r->nvars; i++)
    vp_out_put(&o, r->vars[i].name), vp_out_put(&o, "="), vp_out_put(&o, r->vars[i].value),
        vp_out_put(&o, "\n\n");
  for (size_t i = 0; i < r->nports; i++)
    vp_out_put(&o, "plumb to "), vp_out_put(&o, r->ports[i]), vp_out_put(&o, "\n");
  vp_out_put(&o, "\n");
  for (size_t i = 0; i < r->nsets; i++) {
    const vp_ruleset *rs = r->sets[i];
    for (uint32_t k = 0; k < rs->npat; k++) vp_print_rule(&o, rs->pat[k]);
    for (uint32_t k = 0; k < rs->nact; k++) vp_print_rule(&o, rs->act[k]);
    vp_out_put(&o, "\n");
  }
  if (o.failed) return vt_free(o.p), nullptr;
  *n = o.n;
  return o.p;
}

// --- Matching (cmd/plumb/match.c) ---

static void vp_set_matches(vx_plumb_exec *e, const char *text, const uint64_t m[VT_RX_SUBS * 2]) {
  for (size_t i = 0; i < VT_RX_SUBS; i++) {
    vt_free(e->match[i]);
    e->match[i] = vp_dup_n(text + m[2 * i], m[2 * i + 1] - m[2 * i]);
  }
}

// The leftmost-longest match of rx in text starting at from or later.
static bool vp_search(vt_rx *rx, const char *text, size_t n, size_t from, uint64_t m[VT_RX_SUBS * 2]) {
  vx_text *t = vx_text_new(text, n);
  if (!t) return false;
  bool found = vt_rx_run(rx, t, from, n, n, false, m);
  vx_text_free(t);
  return found;
}

static bool vp_matches(vx_plumb_exec *e, const vp_rule *rule) {
  vx_plumb_msg *m = e->msg;
  uint64_t sub[VT_RX_SUBS * 2] = {};
  const char *text;
  size_t n;
  switch (rule->obj) {
  case O_DATA: {
    const char *click = vx_plumb_lookup(m->attr, "click");
    text = m->data, n = m->ndata;
    if (!click) break;
    // The match that holds the click, a rune offset, from the earliest start.
    uint64_t runes = 0;
    for (const char *c = click; *c >= '0' && *c <= '9' && runes < (1ull << 32); c++)
      runes = runes * 10 + (uint64_t)(*c - '0');
    size_t at = 0;
    for (uint64_t i = 0; i < runes && at < n; i++) {
      at++;
      while (at < n && ((uint8_t)text[at] & 0xc0) == 0x80) at++;
    }
    bool found = false;
    for (size_t from = 0; from <= at && !found;) {
      found = vp_search(rule->rx, text, n, from, sub) && sub[0] <= at && at <= sub[1];
      if (found) break;
      from++;
      while (from < n && ((uint8_t)text[from] & 0xc0) == 0x80) from++;
    }
    if (!found) return false;
    if (e->p0 >= 0 && !(e->p0 == (int64_t)sub[0] && e->p1 == (int64_t)sub[1])) return false;
    e->clearclick = e->setdata = true;
    e->p0 = (int64_t)sub[0], e->p1 = (int64_t)sub[1];
    vp_set_matches(e, text, sub);
    return true;
  }
  case O_DST: text = m->dst, n = vp_len(text); break;
  case O_TYPE: text = m->type, n = vp_len(text); break;
  case O_WDIR: text = m->wdir, n = vp_len(text); break;
  case O_SRC: text = m->src, n = vp_len(text); break;
  default: return false;
  }
  // The whole text.
  if (!vp_search(rule->rx, text, n, 0, sub) || sub[0] != 0 || sub[1] != n) return false;
  vp_set_matches(e, text, sub);
  return true;
}

// dir/file, cleaned: file itself when it is rooted.
static char *vp_absolute(const char *dir, const char *file) {
  if (file[0] == '/') return vp_dup(file);
  size_t nd = vp_len(dir), nf = vp_len(file);
  char *p = vt_alloc(nd + nf + 2);
  if (!p) return nullptr;
  __builtin_memcpy(p, dir, nd), p[nd] = '/';
  __builtin_memcpy(p + nd + 1, file, nf + 1);
  return vx_plumb_clean(p);
}

static bool vp_isfile(vx_plumb_rules *r, vx_plumb_exec *e, const vp_rule *rule, int want, char **var) {
  vx_plumb_msg *m = e->msg;
  char *file;
  if (rule->obj == O_ARG)
    file = vp_absolute(m->wdir, vp_expand(r, e, rule->arg, nullptr));
  else if (rule->obj == O_DATA || rule->obj == O_WDIR)
    file = vp_absolute(m->wdir, rule->obj == O_DATA ? m->data : m->wdir);
  else
    return false;
  if (!file) return false;
  if (!r->fs.kind || r->fs.kind(r->fs.ctx, file) != want) return vt_free(file), false;
  vt_free(*var);
  *var = file;
  return true;
}

static bool vp_set(vx_plumb_rules *r, vx_plumb_exec *e, const vp_rule *rule) {
  vx_plumb_msg *m = e->msg;
  char *new = vp_dup(vp_expand(r, e, rule->arg, nullptr)), **field;
  if (!new) return false;
  switch (rule->obj) {
  case O_DATA:
    vt_free(m->data);
    m->data = new, m->ndata = vp_len(new);
    e->p0 = e->p1 = -1, e->setdata = false;
    return true;
  case O_DST: field = &m->dst; break;
  case O_TYPE: field = &m->type; break;
  case O_WDIR: field = &m->wdir; break;
  case O_SRC: field = &m->src; break;
  default: vt_free(new); return true;
  }
  vt_free(*field);
  *field = new;
  return true;
}

static bool vp_pattern(vx_plumb_rules *r, vx_plumb_exec *e, const vp_rule *rule) {
  vx_plumb_msg *m = e->msg;
  switch (rule->verb) {
  case V_ADD:
    if (rule->obj != O_ATTR) return false;
    m->attr = vx_plumb_add_attr(m->attr, vx_plumb_unpack_attr(vp_expand(r, e, rule->arg, nullptr)));
    return true;
  case V_DELETE: {
    if (rule->obj != O_ATTR) return false;
    const char *a = vp_expand(r, e, rule->arg, nullptr);
    if (!vx_plumb_lookup(m->attr, a)) return false;
    m->attr = vx_plumb_del_attr(m->attr, a);
    return true;
  }
  case V_IS:
    switch (rule->obj) {
    case O_DATA: return vp_eq(m->data, rule->qarg);
    case O_DST: return vp_eq(m->dst, rule->qarg);
    case O_TYPE: return vp_eq(m->type, rule->qarg);
    case O_WDIR: return vp_eq(m->wdir, rule->qarg);
    case O_SRC: return vp_eq(m->src, rule->qarg);
    default: return false;
    }
  case V_ISDIR: return vp_isfile(r, e, rule, VX_PLUMB_DIR, &e->dir);
  case V_ISFILE: return vp_isfile(r, e, rule, VX_PLUMB_FILE, &e->file);
  case V_MATCHES: return vp_matches(e, rule);
  case V_SET: vp_set(r, e, rule); return true;
  default: return false;
  }
}

void vx_plumb_exec_free(vx_plumb_exec *e) {
  if (!e) return;
  for (size_t i = 0; i < VT_RX_SUBS; i++) vt_free(e->match[i]);
  vt_free(e->file), vt_free(e->dir), vt_free(e);
}

// A match's rewriting: the click's attribute gone and the data what it
// selected.
static void vp_rewrite(vx_plumb_rules *r, vx_plumb_exec *e) {
  vx_plumb_msg *m = e->msg;
  if (!e->clearclick) return;
  m->attr = vx_plumb_del_attr(m->attr, "click");
  if (!e->setdata) return;
  char *data = vp_dup(vp_expand(r, e, "$0", nullptr));
  if (!data) return;
  vt_free(m->data);
  m->data = data, m->ndata = vp_len(data);
}

static vx_plumb_exec *vp_match_ruleset(vx_plumb_rules *r, vx_plumb_msg *m, const vp_ruleset *rs) {
  if (m->dst[0] && rs->port && !vp_eq(m->dst, rs->port)) return nullptr;
  vx_plumb_exec *e = vt_alloc(sizeof *e);
  if (!e) return nullptr;
  *e = (vx_plumb_exec){.rs = rs, .msg = m, .p0 = -1, .p1 = -1};
  for (uint32_t i = 0; i < rs->npat; i++)
    if (!vp_pattern(r, e, rs->pat[i])) return vx_plumb_exec_free(e), nullptr;
  if (rs->port && !m->dst[0]) {
    char *dst = vp_dup(rs->port);
    if (dst) vt_free(m->dst), m->dst = dst;
  }
  vp_rewrite(r, e);
  return e;
}

vx_plumb_exec *vx_plumb_match(vx_plumb_rules *r, vx_plumb_msg *m) {
  for (size_t i = 0; i < r->nsets; i++) {
    vx_plumb_exec *e = vp_match_ruleset(r, m, r->sets[i]);
    if (e) return e;
  }
  return nullptr;
}

void vx_plumb_argv_free(char **argv) {
  for (size_t i = 0; argv && argv[i]; i++) vt_free(argv[i]);
  vt_free(argv);
}

const char *vx_plumb_startup(vx_plumb_rules *r, vx_plumb_exec *e, char ***argv, bool *hold) {
  *argv = nullptr, *hold = false;
  const vp_rule *act = nullptr;
  for (uint32_t i = 0; e && i < e->rs->nact && !act; i++) {
    uint8_t v = e->rs->act[i]->verb;
    if (v == V_START || v == V_CLIENT) act = e->rs->act[i];
  }
  if (!act) return "no start action for plumb message";
  if (act->verb == V_CLIENT) {
    if (!e->msg->dst[0]) return "no port for \"client\" rule";
    e->hold = *hold = true;
  }
  char **av = nullptr;
  size_t ac = 0, cap = 0;
  const char *s = act->arg;
  for (;;) {
    if (!vt_grow((void **)&av, &cap, ac + 1, sizeof *av)) return vx_plumb_argv_free(av), "out of memory";
    av[ac] = nullptr;
    while (vp_blank(*s)) s++;
    if (!*s) break;
    if (!(av[ac] = vp_dup(vp_expand(r, e, s, &s)))) return vx_plumb_argv_free(av), "out of memory";
    ac++;
  }
  if (!ac) return vx_plumb_argv_free(av), "empty argument list";
  *argv = av;
  return nullptr;
}
