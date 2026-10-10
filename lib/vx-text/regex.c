// vx-text's regular expressions: sam's (9front sam/regexp.c, regexp(7)),
// over the piece tree. Parsed into a tree, then compiled twice: forward, and
// with every concatenation reversed for ?re?, which searches backward. Run
// as sam runs them, a Thompson machine a rune at a time with its threads in
// priority order, one thread an instruction: a match starting earlier wins,
// then a longer one (backward: ending later, then longer). Sub-matches \1-\9
// are the forward machine's. Everything a run needs is allocated when the
// expression is compiled, so a run cannot fail.
//
// ^ and $ test the text itself, so they hold at its ends and beside a
// newline wherever a search is bounded. Unlike sam's, $ also holds at the end
// of text with no final newline.

#pragma once

// Included by text.c, before sam.c.

enum : uint8_t {
  VT_RX_CHAR,
  VT_RX_ANY,
  VT_RX_CLASS,
  VT_RX_NCLASS,
  VT_RX_BOL,
  VT_RX_EOL,
  VT_RX_SPLIT,
  VT_RX_JMP,
  VT_RX_SAVE,
  VT_RX_MATCH,
  // the tree's alone
  VT_RX_CAT,
  VT_RX_ALT,
  VT_RX_STAR,
  VT_RX_PLUS,
  VT_RX_QUEST,
  VT_RX_GROUP,
};

enum : uint32_t {
  VT_RX_MAXPROG = 8192, // instructions in one direction's program
  VT_RX_DEPTH = 100,    // nested parentheses and repetitions
  VT_RX_SUBS = 10,      // \0 (the match) to \9
};

typedef struct vt_rx_node {
  uint8_t kind;
  uint32_t a, b; // children; a class's first range and count
  int32_t c;     // a rune; a group's sub-match (-1 none)
} vt_rx_node;

typedef struct vt_inst {
  uint8_t op;
  uint32_t x, y;
  int32_t c;
} vt_inst;

typedef struct vt_thread {
  uint32_t pc;
  uint64_t cap[VT_RX_SUBS * 2];
} vt_thread;

typedef struct vt_rx_frame {
  uint32_t pc, slot; // slot: a capture to restore to old, or VT_RX_EXPLORE
  uint64_t old;
} vt_rx_frame;

enum : uint32_t { VT_RX_EXPLORE = UINT32_MAX };

typedef struct vt_rx {
  vt_inst *prog[2]; // forward, backward
  size_t nprog[2], capprog[2];
  int32_t *ranges; // pairs: low, high
  size_t nranges, capranges;
  vt_rx_node *nodes;
  size_t nnodes, capnodes;
  uint32_t root;
  uint32_t *tmp; // the compiler's stack of chains' members
  size_t ntmp;
  // the machine's
  vt_thread *list[2];
  uint32_t *mark;
  vt_rx_frame *stack;
  uint32_t gen;
  const char *error;
} vt_rx;

// --- Reading the text a rune at a time ---

typedef struct vt_reader {
  const vx_text *t;
  uint32_t x; // the visible node in hand, or 0
  uint64_t cs, n;
  const char *p;
} vt_reader;

static void vt_rd_set(vt_reader *rd, uint32_t x, uint64_t cs) {
  rd->x = x, rd->cs = cs, rd->n = rd->t->nodes[x].len, rd->p = vt_bytes(rd->t, &rd->t->nodes[x]);
}

static int vt_rd_byte(vt_reader *rd, uint64_t pos) {
  if (rd->x && pos >= rd->cs && pos - rd->cs < rd->n) return (unsigned char)rd->p[pos - rd->cs];
  if (pos >= vx_text_len(rd->t)) return -1;
  uint32_t y = 0;
  if (rd->x && pos == rd->cs + rd->n && (y = vt_next(rd->t, rd->x))) {
    vt_rd_set(rd, y, pos);
  } else if (rd->x && pos + 1 == rd->cs && (y = vt_prev(rd->t, rd->x))) {
    vt_rd_set(rd, y, rd->cs - rd->t->nodes[y].len);
  } else {
    uint64_t in = 0;
    y = vt_find(rd->t, pos, &in);
    vt_rd_set(rd, y, pos - in);
  }
  return (unsigned char)rd->p[pos - rd->cs];
}

// The rune at pos and its length, or -1 at the end.
static int32_t vt_rd_rune(vt_reader *rd, uint64_t pos, uint64_t *len) {
  int c = vt_rd_byte(rd, pos);
  if (c < 0x80) return *len = c >= 0, c;
  char b[VX_UTFMAX];
  size_t n = 0;
  if (pos + VX_UTFMAX <= rd->cs + rd->n)
    __builtin_memcpy(b, rd->p + (pos - rd->cs), n = VX_UTFMAX);
  else
    for (int d = c; n < VX_UTFMAX && d >= 0;) {
      b[n++] = (char)d;
      if (n < VX_UTFMAX) d = vt_rd_byte(rd, pos + n);
    }
  vx_rune r;
  *len = vx_chartorune(&r, b, n);
  return (int32_t)r;
}

// The rune before pos and its length, or -1 at the start.
static int32_t vt_rd_back(vt_reader *rd, uint64_t pos, uint64_t *len) {
  if (pos == 0) return *len = 0, -1;
  char b[VX_UTFMAX];
  size_t n = pos < VX_UTFMAX ? (size_t)pos : VX_UTFMAX;
  for (size_t i = 0; i < n; i++) b[n - 1 - i] = (char)vt_rd_byte(rd, pos - 1 - i);
  size_t start = vx_utf_back(b, n);
  vx_rune r;
  vx_chartorune(&r, b + start, n - start);
  *len = n - start;
  return (int32_t)r;
}

static bool vt_bol(vt_reader *rd, uint64_t pos) { return pos == 0 || vt_rd_byte(rd, pos - 1) == '\n'; }
static bool vt_eol(vt_reader *rd, uint64_t pos) {
  int c = vt_rd_byte(rd, pos);
  return c < 0 || c == '\n';
}

// --- Parsing, into rx->nodes ---

typedef struct vt_rx_parse {
  vt_rx *rx;
  const char *s;
  size_t n, at;
  int32_t nsub;
  uint32_t depth;
} vt_rx_parse;

static uint32_t vt_rx_new(vt_rx *rx, uint8_t kind, uint32_t a, uint32_t b, int32_t c) {
  if (rx->error) return 0;
  if (!vt_grow((void **)&rx->nodes, &rx->capnodes, rx->nnodes + 1, sizeof *rx->nodes)) {
    rx->error = "out of memory";
    return 0;
  }
  rx->nodes[rx->nnodes] = (vt_rx_node){kind, a, b, c};
  return (uint32_t)rx->nnodes++;
}

static int32_t vt_rx_peek(const vt_rx_parse *ps, size_t *len) {
  if (ps->at >= ps->n) return *len = 0, -1;
  vx_rune r;
  *len = vx_chartorune(&r, ps->s + ps->at, ps->n - ps->at);
  return (int32_t)r;
}

static int32_t vt_rx_take(vt_rx_parse *ps) {
  size_t len = 0;
  int32_t r = vt_rx_peek(ps, &len);
  ps->at += len;
  return r;
}

// A class's member, after [: an escaped rune is literal ('\n' a newline);
// sets *lit for one, which cannot end the class or make a range.
static int32_t vt_rx_class_rune(vt_rx_parse *ps, bool *lit) {
  int32_t r = vt_rx_take(ps);
  *lit = false;
  if (r != '\\') return r;
  r = vt_rx_take(ps);
  *lit = true;
  return r == 'n' ? '\n' : r;
}

static bool vt_rx_range(vt_rx *rx, int32_t lo, int32_t hi) {
  if (!vt_grow((void **)&rx->ranges, &rx->capranges, rx->nranges + 2, sizeof *rx->ranges)) {
    rx->error = "out of memory";
    return false;
  }
  rx->ranges[rx->nranges++] = lo, rx->ranges[rx->nranges++] = hi;
  return true;
}

static uint32_t vt_rx_class(vt_rx_parse *ps) {
  vt_rx *rx = ps->rx;
  size_t len = 0;
  bool negate = vt_rx_peek(ps, &len) == '^';
  if (negate) ps->at += len;
  uint32_t first = (uint32_t)rx->nranges;
  for (;;) {
    bool lit = false, lit2 = false;
    int32_t lo = vt_rx_class_rune(ps, &lit);
    if (lo < 0) return rx->error = "malformed `[]'", 0;
    if (lo == ']' && !lit) break;
    if (lo == '-' && !lit) return rx->error = "malformed `[]'", 0;
    int32_t hi = lo;
    if (vt_rx_peek(ps, &len) == '-') {
      ps->at += len;
      hi = vt_rx_class_rune(ps, &lit2);
      if (hi < 0 || (hi == ']' && !lit2)) return rx->error = "malformed `[]'", 0;
    }
    if (!vt_rx_range(rx, lo, hi)) return 0;
  }
  uint32_t count = (uint32_t)(rx->nranges - first) / 2;
  return vt_rx_new(rx, negate ? VT_RX_NCLASS : VT_RX_CLASS, first, count, 0);
}

static uint32_t vt_rx_alt(vt_rx_parse *ps);

// NOLINTNEXTLINE(misc-no-recursion): VT_RX_DEPTH parentheses deep at most
static uint32_t vt_rx_atom(vt_rx_parse *ps) {
  vt_rx *rx = ps->rx;
  int32_t r = vt_rx_take(ps);
  switch (r) {
  case '(': {
    if (++ps->depth > VT_RX_DEPTH) return rx->error = "malformed regexp", 0;
    int32_t sub = ps->nsub < (int32_t)VT_RX_SUBS - 1 ? ++ps->nsub : -1;
    uint32_t inner = vt_rx_alt(ps);
    size_t len = 0;
    if (!rx->error && vt_rx_peek(ps, &len) != ')') return rx->error = "unmatched `('", 0;
    ps->at += len, ps->depth--;
    return vt_rx_new(rx, VT_RX_GROUP, inner, 0, sub);
  }
  case '.': return vt_rx_new(rx, VT_RX_ANY, 0, 0, 0);
  case '^': return vt_rx_new(rx, VT_RX_BOL, 0, 0, 0);
  case '$': return vt_rx_new(rx, VT_RX_EOL, 0, 0, 0);
  case '[': return vt_rx_class(ps);
  case '\\':
    r = vt_rx_take(ps);
    if (r < 0) r = '\\'; // sam's: a final backslash is itself
    return vt_rx_new(rx, VT_RX_CHAR, 0, 0, r == 'n' ? '\n' : r);
  default: return vt_rx_new(rx, VT_RX_CHAR, 0, 0, r);
  }
}

static bool vt_rx_operator(int32_t r) { return r == '*' || r == '+' || r == '?'; }

static uint8_t vt_rx_repeat(int32_t r) {
  switch (r) {
  case '*': return VT_RX_STAR;
  case '+': return VT_RX_PLUS;
  default: return VT_RX_QUEST;
  }
}

static const char *vt_rx_no_operand(int32_t r) {
  switch (r) {
  case '*': return "no operand for `*'";
  case '+': return "no operand for `+'";
  default: return "no operand for `?'";
  }
}

// after: what came before, for sam's error: 0, '(' or '|'.
// NOLINTNEXTLINE(misc-no-recursion): VT_RX_DEPTH parentheses deep at most
static uint32_t vt_rx_cat(vt_rx_parse *ps, int32_t after) {
  vt_rx *rx = ps->rx;
  uint32_t left = 0;
  bool any = false;
  for (size_t len = 0;;) {
    int32_t r = vt_rx_peek(ps, &len);
    if (r < 0 || r == '|' || r == ')') break;
    if (vt_rx_operator(r)) return rx->error = vt_rx_no_operand(r), 0;
    uint32_t a = vt_rx_atom(ps);
    for (uint32_t reps = 0; !rx->error && vt_rx_operator(r = vt_rx_peek(ps, &len)); reps++) {
      if (ps->depth + reps >= VT_RX_DEPTH) return rx->error = "malformed regexp", 0;
      ps->at += len;
      a = vt_rx_new(rx, vt_rx_repeat(r), a, 0, 0);
    }
    if (rx->error) return 0;
    left = any ? vt_rx_new(rx, VT_RX_CAT, left, a, 0) : a;
    any = true;
  }
  if (!any) { // an empty operand
    size_t len = 0;
    int32_t r = vt_rx_peek(ps, &len);
    if (r == ')' && !ps->depth) return rx->error = "unmatched `)'", 0;
    return rx->error = r == '|' || after == '|' ? "no operand for `|'" : "no operand for `('", 0;
  }
  return left;
}

// NOLINTNEXTLINE(misc-no-recursion): VT_RX_DEPTH parentheses deep at most
static uint32_t vt_rx_alt(vt_rx_parse *ps) {
  uint32_t left = vt_rx_cat(ps, ps->depth ? '(' : 0);
  for (size_t len = 0; !ps->rx->error && vt_rx_peek(ps, &len) == '|';) {
    ps->at += len;
    uint32_t right = vt_rx_cat(ps, '|');
    left = vt_rx_new(ps->rx, VT_RX_ALT, left, right, 0);
  }
  return left;
}

// --- Compiling ---

static uint32_t vt_rx_emit(vt_rx *rx, int dir, uint8_t op, uint32_t x, uint32_t y, int32_t c) {
  if (rx->error) return 0;
  if (rx->nprog[dir] == VT_RX_MAXPROG) return rx->error = "regular expression too long", 0;
  if (!vt_grow((void **)&rx->prog[dir], &rx->capprog[dir], rx->nprog[dir] + 1, sizeof *rx->prog[dir]))
    return rx->error = "out of memory", 0;
  rx->prog[dir][rx->nprog[dir]] = (vt_inst){op, x, y, c};
  return (uint32_t)rx->nprog[dir]++;
}

// Emits node i for direction dir: backward reverses every concatenation and
// captures nothing. Chains of concatenation and alternation are walked, not
// recursed along, so the recursion is the nesting the parser bounds.
// NOLINTNEXTLINE(misc-no-recursion): as deep as the parser's nesting, VT_RX_DEPTH bounds it
static void vt_rx_compile_node(vt_rx *rx, int dir, uint32_t i) {
  if (rx->error) return;
  vt_rx_node n = rx->nodes[i];
  switch (n.kind) {
  case VT_RX_CAT: { // a chain, left-nested, emitted without recursing along it
    size_t base = rx->ntmp;
    uint32_t x = i;
    for (; rx->nodes[x].kind == VT_RX_CAT; x = rx->nodes[x].a) rx->tmp[rx->ntmp++] = rx->nodes[x].b;
    rx->tmp[rx->ntmp++] = x; // tmp[base..top): the chain's members, last first
    size_t top = rx->ntmp;
    for (size_t k = 0; k < top - base; k++)
      vt_rx_compile_node(rx, dir, rx->tmp[dir ? base + k : top - 1 - k]);
    rx->ntmp = base;
    return;
  }
  case VT_RX_ALT: { // SPLIT to each alternative in turn, each jumping to the end
    size_t base = rx->ntmp;
    uint32_t x = i;
    for (; rx->nodes[x].kind == VT_RX_ALT; x = rx->nodes[x].a) rx->tmp[rx->ntmp++] = rx->nodes[x].b;
    rx->tmp[rx->ntmp++] = x;
    size_t top = rx->ntmp, njmp = 0;
    for (size_t k = 0; k < top - base && !rx->error; k++) {
      uint32_t alt = rx->tmp[top - 1 - k];
      if (k == top - base - 1) {
        vt_rx_compile_node(rx, dir, alt);
        break;
      }
      uint32_t split = vt_rx_emit(rx, dir, VT_RX_SPLIT, 0, 0, 0);
      vt_rx_compile_node(rx, dir, alt);
      uint32_t jmp = vt_rx_emit(rx, dir, VT_RX_JMP, 0, 0, 0);
      if (rx->error) break;
      rx->prog[dir][split].x = split + 1, rx->prog[dir][split].y = (uint32_t)rx->nprog[dir];
      rx->tmp[top + njmp++] = jmp;
      rx->ntmp = top + njmp;
    }
    for (size_t k = 0; k < njmp && !rx->error; k++)
      rx->prog[dir][rx->tmp[top + k]].x = (uint32_t)rx->nprog[dir];
    rx->ntmp = base;
    return;
  }
  case VT_RX_STAR: {
    uint32_t split = vt_rx_emit(rx, dir, VT_RX_SPLIT, 0, 0, 0);
    vt_rx_compile_node(rx, dir, n.a);
    vt_rx_emit(rx, dir, VT_RX_JMP, split, 0, 0);
    if (rx->error) return;
    rx->prog[dir][split].x = split + 1, rx->prog[dir][split].y = (uint32_t)rx->nprog[dir];
    return;
  }
  case VT_RX_PLUS: {
    uint32_t top = (uint32_t)rx->nprog[dir];
    vt_rx_compile_node(rx, dir, n.a);
    uint32_t split = vt_rx_emit(rx, dir, VT_RX_SPLIT, top, 0, 0);
    if (!rx->error) rx->prog[dir][split].y = split + 1;
    return;
  }
  case VT_RX_QUEST: {
    uint32_t split = vt_rx_emit(rx, dir, VT_RX_SPLIT, 0, 0, 0);
    vt_rx_compile_node(rx, dir, n.a);
    if (rx->error) return;
    rx->prog[dir][split].x = split + 1, rx->prog[dir][split].y = (uint32_t)rx->nprog[dir];
    return;
  }
  case VT_RX_GROUP:
    if (dir == 0 && n.c > 0) vt_rx_emit(rx, dir, VT_RX_SAVE, (uint32_t)n.c * 2, 0, 0);
    vt_rx_compile_node(rx, dir, n.a);
    if (dir == 0 && n.c > 0) vt_rx_emit(rx, dir, VT_RX_SAVE, (uint32_t)n.c * 2 + 1, 0, 0);
    return;
  default: vt_rx_emit(rx, dir, n.kind, n.a, n.b, n.c); return;
  }
}

static void vt_rx_free(vt_rx *rx) {
  vt_free(rx->prog[0]), vt_free(rx->prog[1]), vt_free(rx->ranges), vt_free(rx->nodes);
  vt_free(rx->list[0]), vt_free(rx->list[1]), vt_free(rx->mark), vt_free(rx->stack), vt_free(rx->tmp);
  *rx = (vt_rx){};
}

// Compiles pattern s (n bytes); nullptr, or the error in sam's words.
static const char *vt_rx_compile(vt_rx *rx, const char *s, size_t n) {
  *rx = (vt_rx){};
  vt_rx_parse ps = {.rx = rx, .s = s, .n = n};
  rx->root = vt_rx_alt(&ps);
  if (!rx->error && ps.at < ps.n) rx->error = "unmatched `)'";
  if (!rx->error && !(rx->tmp = vt_alloc((3 * rx->nnodes + 1) * sizeof *rx->tmp)))
    rx->error = "out of memory";
  for (int dir = 0; dir < 2 && !rx->error; dir++) {
    vt_rx_emit(rx, dir, VT_RX_SAVE, 0, 0, 0);
    vt_rx_compile_node(rx, dir, rx->root);
    vt_rx_emit(rx, dir, VT_RX_MATCH, 0, 0, 0);
  }
  if (rx->error) return rx->error;
  size_t most = rx->nprog[0] > rx->nprog[1] ? rx->nprog[0] : rx->nprog[1];
  rx->list[0] = vt_alloc(most * sizeof(vt_thread));
  rx->list[1] = vt_alloc(most * sizeof(vt_thread));
  rx->mark = vt_alloc(most * sizeof(uint32_t));
  rx->stack = vt_alloc((3 * most + 1) * sizeof(vt_rx_frame));
  if (!rx->list[0] || !rx->list[1] || !rx->mark || !rx->stack) return rx->error = "out of memory";
  for (size_t i = 0; i < most; i++) rx->mark[i] = 0;
  return nullptr;
}

// --- Running ---

// A new step's mark; at the counter's wrap every mark is cleared.
static void vt_rx_step(vt_rx *rx) {
  if (++rx->gen) return;
  size_t most = rx->nprog[0] > rx->nprog[1] ? rx->nprog[0] : rx->nprog[1];
  for (size_t i = 0; i < most; i++) rx->mark[i] = 0;
  rx->gen = 1;
}

static bool vt_rx_in_class(const vt_rx *rx, const vt_inst *in, int32_t c) {
  for (uint32_t i = 0; i < in->y; i++)
    if (c >= rx->ranges[in->x + i * 2] && c <= rx->ranges[in->x + i * 2 + 1]) return true;
  return false;
}

// Adds the thread at pc, with captures cap, to list (n so far), following
// what needs no rune; each instruction once a step.
static void vt_rx_add(vt_rx *rx, int dir, vt_thread *list, uint32_t *n, uint32_t pc, uint64_t *cap,
                      vt_reader *rd, uint64_t pos) {
  const vt_inst *prog = rx->prog[dir];
  uint32_t sp = 0;
  rx->stack[sp++] = (vt_rx_frame){.pc = pc, .slot = VT_RX_EXPLORE};
  while (sp) {
    vt_rx_frame f = rx->stack[--sp];
    if (f.slot != VT_RX_EXPLORE) {
      cap[f.slot] = f.old;
      continue;
    }
    if (rx->mark[f.pc] == rx->gen) continue;
    rx->mark[f.pc] = rx->gen;
    const vt_inst *in = &prog[f.pc];
    switch (in->op) {
    case VT_RX_JMP: rx->stack[sp++] = (vt_rx_frame){.pc = in->x, .slot = VT_RX_EXPLORE}; break;
    case VT_RX_SPLIT:
      rx->stack[sp++] = (vt_rx_frame){.pc = in->y, .slot = VT_RX_EXPLORE};
      rx->stack[sp++] = (vt_rx_frame){.pc = in->x, .slot = VT_RX_EXPLORE};
      break;
    case VT_RX_SAVE:
      rx->stack[sp++] = (vt_rx_frame){.slot = in->x, .old = cap[in->x]};
      cap[in->x] = pos;
      rx->stack[sp++] = (vt_rx_frame){.pc = f.pc + 1, .slot = VT_RX_EXPLORE};
      break;
    case VT_RX_BOL:
      if (vt_bol(rd, pos)) rx->stack[sp++] = (vt_rx_frame){.pc = f.pc + 1, .slot = VT_RX_EXPLORE};
      break;
    case VT_RX_EOL:
      if (vt_eol(rd, pos)) rx->stack[sp++] = (vt_rx_frame){.pc = f.pc + 1, .slot = VT_RX_EXPLORE};
      break;
    default:
      list[*n].pc = f.pc;
      __builtin_memcpy(list[*n].cap, cap, sizeof list[*n].cap);
      (*n)++;
    }
  }
}

// Runs the machine from start toward end (backward: down to it), starting
// threads at positions up to last (backward: down to it). A match is m[0],
// m[1], ordered, and forward the sub-matches after them (unset ones empty at
// 0). The fast path: a forward expression starting with an ASCII rune skips
// to where that byte is while no thread runs.
static bool vt_rx_run(vt_rx *rx, const vx_text *t, uint64_t start, uint64_t end, uint64_t last, bool back,
                      uint64_t m[VT_RX_SUBS * 2]) {
  int dir = back;
  vt_reader rd = {.t = t};
  const vt_inst *prog = rx->prog[dir];
  int32_t first = !back && prog[1].op == VT_RX_CHAR && prog[1].c < 0x80 ? prog[1].c : -1;
  uint32_t ncur = 0, nnext = 0;
  vt_thread *cur = rx->list[0], *next = rx->list[1];
  uint64_t cap[VT_RX_SUBS * 2] = {};
  bool found = false;
  uint64_t best0 = 0, best1 = 0; // forward: start, end; backward: end, start
  vt_rx_step(rx);
  for (uint64_t pos = start;;) {
    if (!found && (back ? pos >= last : pos <= last)) {
      if (first >= 0 && ncur == 0) {
        while (pos <= last && pos < end && vt_rd_byte(&rd, pos) != first) pos++;
        if (pos > last || pos >= end) break;
      }
      for (size_t i = 0; i < (size_t)VT_RX_SUBS * 2; i++) cap[i] = 0;
      vt_rx_add(rx, dir, cur, &ncur, 0, cap, &rd, pos);
    }
    if (ncur == 0 && (found || (back ? pos <= last : pos >= last))) break; // none running, none to start
    uint64_t len = 0;
    int32_t c = -1;
    if (back && pos > end)
      c = vt_rd_back(&rd, pos, &len);
    else if (!back && pos < end)
      c = vt_rd_rune(&rd, pos, &len);
    uint64_t to = back ? pos - len : pos + len;
    vt_rx_step(rx);
    nnext = 0;
    for (uint32_t i = 0; i < ncur; i++) {
      vt_thread *th = &cur[i];
      if (found && (back ? th->cap[0] < best0 : th->cap[0] > best0)) continue; // cannot win
      const vt_inst *in = &prog[th->pc];
      bool step = false;
      switch (in->op) {
      case VT_RX_CHAR: step = c == in->c; break;
      case VT_RX_ANY: step = c >= 0 && c != '\n'; break;
      case VT_RX_CLASS: step = c >= 0 && vt_rx_in_class(rx, in, c); break;
      case VT_RX_NCLASS: step = c >= 0 && c != '\n' && !vt_rx_in_class(rx, in, c); break;
      case VT_RX_MATCH: {
        uint64_t a = th->cap[0];
        bool better = back ? !found || a > best0 || (a == best0 && pos < best1)
                           : !found || a < best0 || (a == best0 && pos > best1);
        if (better) {
          found = true, best0 = a, best1 = pos;
          for (size_t k = 0; k < (size_t)VT_RX_SUBS * 2; k++) m[k] = th->cap[k];
        }
        break;
      }
      default: break;
      }
      if (step) {
        __builtin_memcpy(cap, th->cap, sizeof cap);
        vt_rx_add(rx, dir, next, &nnext, th->pc + 1, cap, &rd, to);
      }
    }
    if (c < 0) break;
    pos = to;
    vt_thread *swap = cur;
    cur = next, next = swap, ncur = nnext;
  }
  if (found) {
    m[0] = back ? best1 : best0;
    m[1] = back ? best0 : best1;
  }
  return found;
}
