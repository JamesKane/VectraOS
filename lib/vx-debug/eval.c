// vx-debug eval: what dbg asks of a stopped program (docs/05 §6.2), from a
// vxdi index and the program's memory and registers, which the caller
// supplies (a live process's /proc files, or a crash directory):
//
//   vxd_unwind      the call stack, by the frame-pointer chain (05 §4: frame
//                   pointers are always on)
//   vxd_location    where a variable is at a frame's pc: its DWARF location
//                   expression evaluated
//   vxd_eval        a C expression: literals, variables, $registers, the
//                   arithmetic, comparison and logical operators, unary - ! ~
//                   * &, casts, sizeof, . -> and []; never a call into the
//                   program, which would change what is being debugged
//   vxd_format      a value as text, by its type
//
// The parser keeps its own stacks and never recurses (the house rules), and
// nothing reads the program but through the target's read callback.

#pragma once

#include "index.c"

// --- The target ---

typedef struct vxd_target {
  void *ctx;
  uint16_t machine; // EM_X86_64 (62) or EM_AARCH64 (183)
  // n bytes at addr in the program; false if they cannot be read.
  bool (*read)(void *ctx, uint64_t addr, void *buf, size_t n);
  // The innermost frame's register `dwarf` (DWARF numbering); false if unknown.
  bool (*reg)(void *ctx, uint32_t dwarf, uint64_t *value);
} vxd_target;

typedef struct vxd_frame {
  uint64_t pc, sp, fp;
  bool inner; // the innermost: every register is known, not only these
} vxd_frame;

// DWARF's numbers for the frame pointer, stack pointer and return address.
static uint32_t vxd_fp_reg(const vxd_target *t) { return t->machine == 183 ? 29 : 6; }
static uint32_t vxd_sp_reg(const vxd_target *t) { return t->machine == 183 ? 31 : 7; }
static constexpr uint32_t VXD_PC = 0xffff; // not a DWARF register: the pc

static bool vxd_frame_reg(const vxd_target *t, const vxd_frame *f, uint32_t reg, uint64_t *v) {
  if (reg == VXD_PC) return *v = f->pc, true;
  if (reg == vxd_fp_reg(t)) return *v = f->fp, true;
  if (reg == vxd_sp_reg(t)) return *v = f->sp, true;
  return f->inner && t->reg && t->reg(t->ctx, reg, v);
}

static bool vxd_read64(const vxd_target *t, uint64_t addr, uint64_t *v) {
  return t->read(t->ctx, addr, v, 8);
}

// --- The call stack ---

// Frames from the innermost (pc, sp and fp as it stopped) outwards, by the
// frame-pointer chain: a frame record is the caller's fp, then the return
// address. A pc still in its function's prologue has not made its record
// yet: its caller's is found from sp (x86_64) or the link register
// (aarch64). The walk stops where the chain does not go up the stack, or
// cannot be read. Returns how many frames it found, at most max.
[[maybe_unused]] static uint32_t vxd_unwind(const vxdi *ix, const vxd_target *t, uint64_t pc, uint64_t sp,
                                            uint64_t fp, vxd_frame *frames, uint32_t max) {
  uint32_t n = 0;
  if (!max) return 0;
  frames[n++] = (vxd_frame){.pc = pc, .sp = sp, .fp = fp, .inner = true};
  const vxdi_func *f = vxdi_func_at(ix, pc);
  if (f && pc < f->body && n < max) { // in the prologue: its frame record is not there yet
    uint64_t ret = 0, caller_fp = fp, caller_sp = sp;
    bool ok;
    if (t->machine == 183) {
      ok = t->reg && t->reg(t->ctx, 30, &ret); // x30, the link register; sp as the caller left it at low
    } else if (pc == f->low) {
      ok = vxd_read64(t, sp, &ret); // before push %rbp
      caller_sp = sp + 8;           // the caller's, before its call pushed the return address
    } else {
      ok = vxd_read64(t, sp + 8, &ret) && vxd_read64(t, sp, &caller_fp); // after it, before mov %rsp, %rbp
      caller_sp = sp + 16;
    }
    if (!ok || !ret) return n;
    frames[n++] = (vxd_frame){.pc = ret, .sp = caller_sp, .fp = caller_fp};
    fp = caller_fp;
  }
  while (n < max && fp && !(fp & 7)) {
    uint64_t next_fp, ret;
    if (!vxd_read64(t, fp, &next_fp) || !vxd_read64(t, fp + 8, &ret) || !ret) break;
    frames[n++] = (vxd_frame){.pc = ret, .sp = fp + 16, .fp = next_fp};
    if (next_fp <= fp) break; // the chain must go up the stack
    fp = next_fp;
  }
  return n;
}

// The pc to look up a frame's function and line by: a return address is the
// instruction after the call, which may be the next function's or line's.
[[maybe_unused]] static uint64_t vxd_frame_lookup_pc(const vxd_frame *f) {
  return f->inner ? f->pc : f->pc - 1;
}

// --- Locations ---

enum vxd_where : uint8_t { VXD_NOWHERE, VXD_MEM, VXD_REG, VXD_VALUE };

typedef struct vxd_loc {
  uint8_t where;  // enum vxd_where
  uint32_t reg;   // VXD_REG
  uint64_t value; // VXD_MEM: the address; VXD_VALUE: the value
} vxd_loc;

static uint64_t vxd_leb(const uint8_t **p, const uint8_t *end, bool sign) {
  uint64_t v = 0;
  uint32_t shift = 0;
  uint8_t b = 0;
  while (*p < end) {
    b = *(*p)++;
    if (shift < 64) v |= (uint64_t)(b & 0x7f) << shift;
    shift += 7;
    if (!(b & 0x80)) break;
  }
  if (sign && shift < 64 && (b & 0x40)) v |= ~0ull << shift;
  return v;
}

static uint64_t vxd_fixed(const uint8_t **p, const uint8_t *end, size_t n) {
  uint64_t v = 0;
  for (size_t i = 0; i < n && *p < end; i++) v |= (uint64_t)*(*p)++ << (8 * i);
  return v;
}

// The DWARF expression stack.
typedef struct vxd_stack {
  uint64_t v[64];
  uint32_t n;
  bool bad; // overflowed, or popped empty: the expression is not evaluated
} vxd_stack;

static void vxd_push(vxd_stack *s, uint64_t v) {
  if (s->n == 64)
    s->bad = true;
  else
    s->v[s->n++] = v;
}
static uint64_t vxd_pop(vxd_stack *s) {
  if (!s->n) return s->bad = true, 0;
  return s->v[--s->n];
}
static uint64_t *vxd_top(vxd_stack *s) {
  static uint64_t none;
  if (!s->n) return s->bad = true, &none;
  return &s->v[s->n - 1];
}

// A binary DWARF operation (minus, mul, and, or, plus, xor, shl, shr) on the
// two values on top.
static void vxd_arith(vxd_stack *s, uint8_t op) {
  uint64_t b = vxd_pop(s), a = vxd_pop(s), r = 0;
  switch (op) {
  case 0x1c: r = a - b; break;
  case 0x1e: r = a * b; break;
  case 0x1a: r = a & b; break;
  case 0x21: r = a | b; break;
  case 0x22: r = a + b; break;
  case 0x27: r = a ^ b; break;
  case 0x24: r = b < 64 ? a << b : 0; break;
  case 0x25: r = b < 64 ? a >> b : 0; break;
  default: s->bad = true; break;
  }
  vxd_push(s, r);
}

// A DWARF expression at a frame: where its value is. frame_base is the
// function's (for DW_OP_fbreg), already evaluated; 0 if it has none.
static bool vxd_expr(const vxd_target *t, const vxd_frame *f, uint64_t frame_base, const uint8_t *p,
                     uint32_t len, vxd_loc *out) {
  const uint8_t *end = p + len;
  vxd_stack st = {};
  uint64_t a, b;
  *out = (vxd_loc){};
  while (p < end && !st.bad) {
    uint8_t op = *p++;
    if (op >= 0x30 && op <= 0x4f) { // lit0-31
      vxd_push(&st, op - 0x30u);
    } else if (op >= 0x50 && op <= 0x6f) { // reg0-31: the value is in the register
      *out = (vxd_loc){.where = VXD_REG, .reg = op - 0x50u};
      return p == end || *p == 0x93;       // alone, or as the first piece
    } else if (op >= 0x70 && op <= 0x8f) { // breg0-31
      int64_t off = (int64_t)vxd_leb(&p, end, true);
      if (!vxd_frame_reg(t, f, op - 0x70u, &a)) return false;
      vxd_push(&st, a + (uint64_t)off);
    } else if (op == 0x1c || op == 0x1e || op == 0x1a || op == 0x21 || op == 0x22 || op == 0x27 ||
               op == 0x24 || op == 0x25) {
      vxd_arith(&st, op);
    } else {
      switch (op) {
      case 0x03: vxd_push(&st, vxd_fixed(&p, end, 8)); break; // addr
      case 0x06:                                              // deref
        if (!vxd_read64(t, *vxd_top(&st), vxd_top(&st))) return false;
        break;
      case 0x94: { // deref_size
        uint8_t n = (uint8_t)vxd_fixed(&p, end, 1);
        uint64_t v = 0;
        if (n > 8 || !t->read(t->ctx, *vxd_top(&st), &v, n)) return false;
        *vxd_top(&st) = v;
        break;
      }
      case 0x08: vxd_push(&st, vxd_fixed(&p, end, 1)); break;
      case 0x09: vxd_push(&st, (uint64_t)(int8_t)vxd_fixed(&p, end, 1)); break;
      case 0x0a: vxd_push(&st, vxd_fixed(&p, end, 2)); break;
      case 0x0b: vxd_push(&st, (uint64_t)(int16_t)vxd_fixed(&p, end, 2)); break;
      case 0x0c: vxd_push(&st, vxd_fixed(&p, end, 4)); break;
      case 0x0d: vxd_push(&st, (uint64_t)(int32_t)vxd_fixed(&p, end, 4)); break;
      case 0x0e:
      case 0x0f: vxd_push(&st, vxd_fixed(&p, end, 8)); break;
      case 0x10: vxd_push(&st, vxd_leb(&p, end, false)); break; // constu
      case 0x11: vxd_push(&st, vxd_leb(&p, end, true)); break;  // consts
      case 0x12: vxd_push(&st, *vxd_top(&st)); break;           // dup
      case 0x13: vxd_pop(&st); break;                           // drop
      case 0x14:                                                // over
        b = vxd_pop(&st), a = vxd_pop(&st);
        vxd_push(&st, a), vxd_push(&st, b), vxd_push(&st, a);
        break;
      case 0x16: // swap
        b = vxd_pop(&st), a = vxd_pop(&st);
        vxd_push(&st, b), vxd_push(&st, a);
        break;
      case 0x1f: *vxd_top(&st) = -*vxd_top(&st); break;           // neg
      case 0x20: *vxd_top(&st) = ~*vxd_top(&st); break;           // not
      case 0x23: *vxd_top(&st) += vxd_leb(&p, end, false); break; // plus_uconst
      case 0x90:                                                  // regx
        *out = (vxd_loc){.where = VXD_REG, .reg = (uint32_t)vxd_leb(&p, end, false)};
        return p == end || *p == 0x93;
      case 0x91: { // fbreg
        int64_t off = (int64_t)vxd_leb(&p, end, true);
        if (!frame_base) return false;
        vxd_push(&st, frame_base + (uint64_t)off);
        break;
      }
      case 0x92: { // bregx
        uint32_t r = (uint32_t)vxd_leb(&p, end, false);
        int64_t off = (int64_t)vxd_leb(&p, end, true);
        if (!vxd_frame_reg(t, f, r, &a)) return false;
        vxd_push(&st, a + (uint64_t)off);
        break;
      }
      case 0x9c:
        vxd_push(&st, f->fp + 16);
        break;   // call_frame_cfa: with frame pointers, past the frame record
      case 0x9f: // stack_value: the value itself
        *out = (vxd_loc){.where = VXD_VALUE, .value = *vxd_top(&st)};
        return !st.bad;
      case 0x93: // piece: the first only (the value starts there)
        *out = (vxd_loc){.where = VXD_MEM, .value = *vxd_top(&st)};
        return !st.bad;
      case 0x96: break;                          // nop
      case 0xa8:                                 // convert: types are not tracked
      case 0xa9: vxd_leb(&p, end, false); break; // reinterpret
      case 0xa5: {                               // regval_type
        uint32_t r = (uint32_t)vxd_leb(&p, end, false);
        vxd_leb(&p, end, false);
        if (!vxd_frame_reg(t, f, r, &a)) return false;
        vxd_push(&st, a);
        break;
      }
      default: return false; // entry_value and the rest: not known here
      }
    }
  }
  if (st.bad || !st.n) return false;
  *out = (vxd_loc){.where = VXD_MEM, .value = st.v[st.n - 1]};
  return true;
}

// The value of a register a location names, at a frame.
static bool vxd_loc_reg(const vxd_target *t, const vxd_frame *f, uint32_t reg, uint64_t *v) {
  return vxd_frame_reg(t, f, reg, v);
}

// A function's frame base at a frame: its DW_AT_frame_base evaluated.
static uint64_t vxd_frame_base(const vxdi *ix, const vxd_target *t, const vxd_frame *f, const vxdi_func *fn) {
  if (!fn || !fn->frame_base_len || fn->frame_base > ix->h->exprs.count ||
      fn->frame_base_len > ix->h->exprs.count - fn->frame_base)
    return 0;
  vxd_loc l;
  if (!vxd_expr(t, f, 0, ix->exprs + fn->frame_base, fn->frame_base_len, &l)) return 0;
  uint64_t v = 0;
  if (l.where == VXD_REG) return vxd_loc_reg(t, f, l.reg, &v) ? v : 0;
  return l.value;
}

// Where variable v is at frame f (whose function is fn, for a local).
[[maybe_unused]] static bool vxd_location(const vxdi *ix, const vxd_target *t, const vxd_frame *f,
                                          const vxdi_func *fn, const vxdi_var *v, vxd_loc *out) {
  if (v->flags & VXDI_CONST) {
    *out = (vxd_loc){.where = VXD_VALUE, .value = (uint64_t)v->value};
    return true;
  }
  const uint8_t *expr;
  uint32_t len;
  if (!vxdi_var_location(ix, v, vxd_frame_lookup_pc(f), &expr, &len)) return false;
  return vxd_expr(t, f, v->kind == VXDI_GLOBAL ? 0 : vxd_frame_base(ix, t, f, fn), expr, len, out);
}

// --- Values ---

// Types the evaluator makes (literals' and results'), numbered from here, as
// the index's are below it.
static constexpr uint32_t VXD_SYN = 1u << 30;
enum : uint32_t {
  VXD_SYN_LONG = VXD_SYN,
  VXD_SYN_ULONG,
  VXD_SYN_DOUBLE,
  VXD_SYN_PTR
}; // PTR + n: pointers made

typedef struct vxd_value {
  uint32_t type;
  uint8_t where; // VXD_MEM (an lvalue in the program), VXD_REG, or VXD_VALUE (in value)
  uint32_t reg;
  uint64_t addr;
  uint64_t value; // VXD_VALUE: up to 8 bytes; a scalar read is loaded here too
} vxd_value;

// What one or more evaluations at a frame share: the pointer types they
// made, so a value's type can be printed after; and why the last failed.
typedef struct vxd_session {
  const vxdi *ix;
  const vxd_target *t;
  const vxd_frame *frame;
  const vxdi_func *func;   // the frame's
  uint32_t ptr_target[32]; // VXD_SYN_PTR + i points at ptr_target[i]
  uint32_t nptr;
  const char *err;
} vxd_session;

[[maybe_unused]] static void vxd_begin(vxd_session *s, const vxdi *ix, const vxd_target *t,
                                       const vxd_frame *f) {
  *s = (vxd_session){.ix = ix, .t = t, .frame = f, .func = vxdi_func_at(ix, vxd_frame_lookup_pc(f))};
}

typedef struct vxd_tinfo { // a type as the evaluator needs it, with typedefs and qualifiers looked through
  uint32_t kind, encoding, target, count, first;
  uint64_t size;
} vxd_tinfo;

static vxd_tinfo vxd_info(vxd_session *c, uint32_t type) {
  if (type == VXD_SYN_LONG) return (vxd_tinfo){.kind = VXDI_BASE, .encoding = 5, .size = 8}; // DW_ATE_signed
  if (type == VXD_SYN_ULONG)
    return (vxd_tinfo){.kind = VXDI_BASE, .encoding = 7, .size = 8}; // DW_ATE_unsigned
  if (type == VXD_SYN_DOUBLE) return (vxd_tinfo){.kind = VXDI_BASE, .encoding = 4, .size = 8}; // DW_ATE_float
  if (type >= VXD_SYN_PTR && type - VXD_SYN_PTR < c->nptr)
    return (vxd_tinfo){.kind = VXDI_POINTER, .target = c->ptr_target[type - VXD_SYN_PTR], .size = 8};
  const vxdi_type *t = vxdi_resolve(c->ix, type, nullptr);
  vxd_tinfo i = {.kind = t->kind,
                 .encoding = t->encoding,
                 .target = t->target,
                 .count = t->count,
                 .first = t->first,
                 .size = t->size};
  if (i.kind == VXDI_POINTER && !i.size) i.size = 8;
  if (i.kind == VXDI_ENUM && !i.size) i.size = 4;
  if (i.kind == VXDI_ARRAY) { // its elements' size, through arrays of arrays, times its count
    uint64_t n = i.count;
    const vxdi_type *e = vxdi_resolve(c->ix, i.target, nullptr);
    for (int guard = 0; e->kind == VXDI_ARRAY && guard < 8; guard++)
      n *= e->count, e = vxdi_resolve(c->ix, e->target, nullptr);
    i.size = n * (e->kind == VXDI_POINTER && !e->size ? 8 : e->size);
  }
  return i;
}

static uint32_t vxd_pointer_to(vxd_session *c, uint32_t target) {
  for (uint32_t i = 0; i < c->nptr; i++)
    if (c->ptr_target[i] == target) return VXD_SYN_PTR + i;
  if (c->nptr == 32) return VXD_SYN_ULONG;
  c->ptr_target[c->nptr] = target;
  return VXD_SYN_PTR + c->nptr++;
}

static bool vxd_signed(const vxd_tinfo *i) {
  return i->kind == VXDI_BASE &&
         (i->encoding == 5 || i->encoding == 6 || i->encoding == 0xd); // signed, signed_char
}
static bool vxd_float(const vxd_tinfo *i) { return i->kind == VXDI_BASE && i->encoding == 4; }
static bool vxd_scalar(const vxd_tinfo *i) {
  return i->kind == VXDI_BASE || i->kind == VXDI_POINTER || i->kind == VXDI_ENUM;
}

// A scalar value's bits, read from where it is and widened to 64.
static bool vxd_load(vxd_session *c, const vxd_value *v, uint64_t *out) {
  vxd_tinfo i = vxd_info(c, v->type);
  uint64_t raw = 0;
  size_t n = i.size > 8 ? 8 : (size_t)i.size;
  if (v->where == VXD_VALUE)
    raw = v->value;
  else if (v->where == VXD_REG && !vxd_loc_reg(c->t, c->frame, v->reg, &raw))
    return c->err = "register not available", false;
  else if (v->where == VXD_MEM && !c->t->read(c->t->ctx, v->addr, &raw, n))
    return c->err = "cannot read memory", false;
  if (vxd_float(&i) && n == 4) { // a float: as a double
    float fl;
    uint32_t bits = (uint32_t)raw;
    memcpy(&fl, &bits, 4);
    double d = fl;
    memcpy(&raw, &d, 8);
  } else if (n && n < 8) {
    uint64_t mask = (1ull << (8 * n)) - 1;
    raw &= mask;
    if (vxd_signed(&i) && (raw >> (8 * n - 1) & 1)) raw |= ~mask; // sign-extended
  }
  *out = raw;
  return true;
}

static vxd_value vxd_imm(uint32_t type, uint64_t v) {
  return (vxd_value){.type = type, .where = VXD_VALUE, .value = v};
}

// --- Parsing ---

typedef enum vxd_tok_kind : uint8_t { T_END, T_NUM, T_FLOAT, T_IDENT, T_REG, T_CHAR, T_OP } vxd_tok_kind;

typedef struct vxd_tok {
  vxd_tok_kind kind;
  char op[3]; // T_OP: the operator's text
  const char *s;
  size_t len;
  uint64_t num;
} vxd_tok;

static bool vxd_ident_char(char ch, bool first) {
  return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch == '_' ||
         (!first && ch >= '0' && ch <= '9');
}

static uint64_t hex_digit_value(char ch) {
  if (ch >= '0' && ch <= '9') return (uint64_t)(ch - '0');
  if (ch >= 'a' && ch <= 'f') return (uint64_t)(ch - 'a') + 10;
  if (ch >= 'A' && ch <= 'F') return (uint64_t)(ch - 'A') + 10;
  return 16;
}

static const char *vxd_lex(const char *p, vxd_tok *t) {
  while (*p == ' ' || *p == '\t') p++;
  *t = (vxd_tok){.s = p};
  if (!*p) return p;
  if (*p >= '0' && *p <= '9') {
    uint64_t v = 0;
    if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) {
      for (p += 2; vxd_ident_char(*p, false); p++) {
        uint64_t d = hex_digit_value(*p);
        if (d > 15) return t->kind = T_END, t->s = nullptr, p;
        v = v << 4 | d;
      }
    } else {
      while (*p >= '0' && *p <= '9') v = v * 10 + (uint64_t)(*p++ - '0');
    }
    while (*p == 'u' || *p == 'U' || *p == 'l' || *p == 'L') p++; // suffixes
    t->kind = T_NUM, t->num = v, t->len = (size_t)(p - t->s);
    return p;
  }
  if (*p == '\'' && p[1] && p[2] == '\'') {
    t->kind = T_CHAR, t->num = (uint8_t)p[1], t->len = 3;
    return p + 3;
  }
  if (*p == '$' || vxd_ident_char(*p, true)) {
    bool reg = *p == '$';
    const char *s = p + reg;
    while (vxd_ident_char(*s, false)) s++;
    t->kind = reg ? T_REG : T_IDENT, t->s = p + reg, t->len = (size_t)(s - p - reg);
    return s;
  }
  static const char *const OPS[] = {"->", "<<", ">>", "<=", ">=", "==", "!=", "&&", "||",
                                    "+",  "-",  "*",  "/",  "%",  "&",  "|",  "^",  "~",
                                    "!",  "<",  ">",  "(",  ")",  "[",  "]",  ".",  ","};
  for (size_t i = 0; i < sizeof OPS / sizeof OPS[0]; i++) {
    size_t n = OPS[i][1] ? 2 : 1;
    if (p[0] == OPS[i][0] && (n == 1 || p[1] == OPS[i][1])) {
      t->kind = T_OP, t->op[0] = OPS[i][0], t->op[1] = n == 2 ? OPS[i][1] : 0, t->len = n;
      return p + n;
    }
  }
  t->kind = T_END, t->s = nullptr; // a character the language does not have
  return p;
}

static bool vxd_tok_is(const vxd_tok *t, const char *op) {
  return t->kind == T_OP && t->op[0] == op[0] && t->op[1] == op[1];
}

static bool vxd_tok_word(const vxd_tok *t, const char *w) {
  size_t n = 0;
  while (w[n]) n++;
  return t->kind == T_IDENT && t->len == n && memcmp(t->s, w, n) == 0;
}

// A type name at p ("int", "unsigned long", "struct point", "char *", ...):
// the type, and where it ends; 0 if p is not one.
static uint32_t vxd_type_name(vxd_session *c, const char *p, const char **end) {
  char name[64];
  size_t n = 0;
  vxd_tok t;
  const char *q = vxd_lex(p, &t);
  if (t.kind != T_IDENT) return 0;
  bool tagged = vxd_tok_word(&t, "struct") || vxd_tok_word(&t, "union") || vxd_tok_word(&t, "enum");
  if (tagged) q = vxd_lex(q, &t);
  for (;;) { // words: "unsigned long int"
    if (t.kind != T_IDENT || n + t.len + 1 >= sizeof name) break;
    if (n) name[n++] = ' ';
    memcpy(name + n, t.s, t.len), n += t.len;
    vxd_tok next;
    const char *r = vxd_lex(q, &next);
    if (tagged || next.kind != T_IDENT) break;
    t = next, q = r;
  }
  name[n] = 0;
  uint32_t type = vxdi_type_named(c->ix, name);
  if (!type && !tagged && vxd_tok_word(&t, "long") && n > 0)
    type = vxdi_type_named(c->ix, "long"); // "long long"
  if (!type) return 0;
  for (;;) { // and its pointers
    vxd_tok s;
    const char *r = vxd_lex(q, &s);
    if (!vxd_tok_is(&s, "*")) break;
    type = vxd_pointer_to(c, type);
    q = r;
  }
  *end = q;
  return type;
}

// Operators on the operator stack: binary ones by their text, and these.
enum : uint8_t {
  OP_NEG = 1,
  OP_NOT,
  OP_BNOT,
  OP_DEREF,
  OP_ADDR,
  OP_CAST,
  OP_SIZEOF,
  OP_PAREN,
  OP_INDEX,
  OP_BINARY
};

typedef struct vxd_op {
  uint8_t kind;
  char text[3];  // OP_BINARY
  uint32_t type; // OP_CAST
} vxd_op;

static int vxd_prec(const vxd_op *o) {
  if (o->kind != OP_BINARY)
    return o->kind == OP_PAREN || o->kind == OP_INDEX ? 0 : 14; // unary binds above binary
  static const struct {
    const char *op;
    int prec;
  } P[] = {{"*", 13},  {"/", 13}, {"%", 13},  {"+", 12}, {"-", 12},  {"<<", 11},
           {">>", 11}, {"<", 10}, {"<=", 10}, {">", 10}, {">=", 10}, {"==", 9},
           {"!=", 9},  {"&", 8},  {"^", 7},   {"|", 6},  {"&&", 5},  {"||", 4}};
  for (size_t i = 0; i < sizeof P / sizeof P[0]; i++)
    if (o->text[0] == P[i].op[0] && o->text[1] == P[i].op[1]) return P[i].prec;
  return 1;
}

static bool vxd_binary_op(const vxd_tok *t) {
  static const char *const B[] = {
      "*", "/", "%", "+", "-", "<<", ">>", "<", "<=", ">", ">=", "==", "!=", "&", "^", "|", "&&", "||"};
  for (size_t i = 0; i < sizeof B / sizeof B[0]; i++)
    if (vxd_tok_is(t, B[i])) return true;
  return false;
}

// A variable or $register, by name, at the frame.
static bool vxd_name(vxd_session *c, const vxd_tok *t, vxd_value *out) {
  char name[64];
  if (t->len >= sizeof name) return c->err = "name too long", false;
  memcpy(name, t->s, t->len), name[t->len] = 0;
  if (t->kind == T_REG) {
    static const char *const X86[] = {"rax", "rdx", "rcx", "rbx", "rsi", "rdi", "rbp", "rsp",
                                      "r8",  "r9",  "r10", "r11", "r12", "r13", "r14", "r15"};
    uint32_t reg = UINT32_MAX;
    if (vxdi_eq(name, "pc") || vxdi_eq(name, "rip"))
      reg = VXD_PC;
    else if (vxdi_eq(name, "sp"))
      reg = vxd_sp_reg(c->t);
    else if (vxdi_eq(name, "fp"))
      reg = vxd_fp_reg(c->t);
    for (uint32_t i = 0; c->t->machine == 62 && i < 16 && reg == UINT32_MAX; i++)
      if (vxdi_eq(name, X86[i])) reg = i;
    if (c->t->machine == 183 && name[0] == 'x' && reg == UINT32_MAX) {
      uint32_t r = 0;
      size_t i = 1;
      for (; name[i] >= '0' && name[i] <= '9'; i++) r = r * 10 + (uint32_t)(name[i] - '0');
      if (i > 1 && !name[i] && r <= 30) reg = r;
    }
    if (reg == UINT32_MAX) return c->err = "no such register", false;
    *out = (vxd_value){.type = VXD_SYN_ULONG, .where = VXD_REG, .reg = reg};
    return true;
  }
  const vxdi_var *v = vxdi_local_named(c->ix, c->func, vxd_frame_lookup_pc(c->frame), name);
  if (!v) v = vxdi_global_named(c->ix, name);
  if (v) {
    vxd_loc l;
    if (!vxd_location(c->ix, c->t, c->frame, c->func, v, &l))
      return c->err = "variable not available here", false;
    *out = (vxd_value){.type = v->type, .where = l.where, .reg = l.reg, .addr = l.value, .value = l.value};
    return true;
  }
  for (uint64_t i = 1; i < c->ix->h->types.count; i++) { // an enumerator
    const vxdi_type *ty = &c->ix->types[i];
    for (uint32_t k = 0; ty->kind == VXDI_ENUM && k < ty->count && ty->first + k < c->ix->h->members.count;
         k++) {
      const vxdi_member *m = &c->ix->members[ty->first + k];
      if (vxdi_eq(vxdi_str(c->ix, m->name), name))
        return *out = vxd_imm((uint32_t)i, (uint64_t)m->offset), true;
    }
  }
  return c->err = "no such variable", false;
}

// A value as an rvalue scalar: arrays decay to pointers to their first element.
static bool vxd_rvalue(vxd_session *c, vxd_value *v) {
  vxd_tinfo i = vxd_info(c, v->type);
  if (i.kind == VXDI_ARRAY) {
    if (v->where != VXD_MEM) return c->err = "array not in memory", false;
    *v = vxd_imm(vxd_pointer_to(c, i.target), v->addr);
    return true;
  }
  if (i.kind == VXDI_FUNC) return *v = vxd_imm(vxd_pointer_to(c, v->type), v->addr), true;
  if (!vxd_scalar(&i)) return c->err = "not a number or pointer", false;
  uint64_t bits;
  if (!vxd_load(c, v, &bits)) return false;
  *v = vxd_imm(v->type, bits);
  return true;
}

static vxd_value vxd_deref(vxd_session *c, const vxd_value *ptr, bool *ok) {
  vxd_tinfo i = vxd_info(c, ptr->type);
  *ok = i.kind == VXDI_POINTER && i.target != 0;
  if (!*ok) c->err = i.kind == VXDI_POINTER ? "cannot dereference void *" : "not a pointer";
  return (vxd_value){.type = i.target, .where = VXD_MEM, .addr = ptr->value};
}

static bool vxd_apply_unary(vxd_session *c, const vxd_op *o, vxd_value *v) {
  if (o->kind == OP_ADDR) {
    if (v->where != VXD_MEM) return c->err = "not in memory: no address", false;
    *v = vxd_imm(vxd_pointer_to(c, v->type), v->addr);
    return true;
  }
  if (o->kind == OP_SIZEOF) {
    *v = vxd_imm(VXD_SYN_ULONG, vxd_info(c, v->type).size);
    return true;
  }
  if (!vxd_rvalue(c, v)) return false;
  vxd_tinfo i = vxd_info(c, v->type);
  bool ok = true;
  switch (o->kind) {
  case OP_DEREF: *v = vxd_deref(c, v, &ok); break;
  case OP_NEG: *v = vxd_imm(vxd_signed(&i) ? v->type : VXD_SYN_LONG, -v->value); break;
  case OP_NOT: *v = vxd_imm(VXD_SYN_LONG, v->value == 0); break;
  case OP_BNOT: *v = vxd_imm(v->type, ~v->value); break;
  case OP_CAST: {
    vxd_tinfo to = vxd_info(c, o->type);
    uint64_t x = v->value;
    if (to.size && to.size < 8) {
      x &= (1ull << (8 * to.size)) - 1;
      if (vxd_signed(&to) && (x >> (8 * to.size - 1) & 1)) x |= ~((1ull << (8 * to.size)) - 1);
    }
    *v = vxd_imm(o->type, x);
    break;
  }
  default: return c->err = "bad operator", false;
  }
  return ok;
}

static bool vxd_apply_binary(vxd_session *c, const char *op, vxd_value *a, vxd_value b) {
  if (!vxd_rvalue(c, a) || !vxd_rvalue(c, &b)) return false;
  vxd_tinfo ia = vxd_info(c, a->type), ib = vxd_info(c, b.type);
  if (vxd_float(&ia) || vxd_float(&ib)) return c->err = "floating-point arithmetic is not supported", false;
  bool pa = ia.kind == VXDI_POINTER, pb = ib.kind == VXDI_POINTER;
  uint64_t x = a->value, y = b.value, r = 0;
  bool sgn = (vxd_signed(&ia) || a->type == VXD_SYN_LONG) && (vxd_signed(&ib) || b.type == VXD_SYN_LONG);
  uint32_t type = sgn ? VXD_SYN_LONG : VXD_SYN_ULONG;
  if (pa || pb) type = pa ? a->type : b.type;
  uint64_t scale_a = pa ? vxd_info(c, ia.target).size : 1, scale_b = pb ? vxd_info(c, ib.target).size : 1;
  if (op[0] == '+' && !op[1]) {
    if (pa && pb) return c->err = "cannot add two pointers", false;
    if (pa)
      r = x + y * scale_a;
    else if (pb)
      r = y + x * scale_b;
    else
      r = x + y;
  } else if (op[0] == '-' && !op[1]) {
    if (pa && pb)
      r = scale_a ? (uint64_t)((int64_t)(x - y) / (int64_t)scale_a) : 0,
      type = VXD_SYN_LONG; // signed: &a[0] - &a[1] is -1
    else if (pb)
      return c->err = "cannot subtract a pointer from a number", false;
    else
      r = pa ? x - y * scale_a : x - y;
  } else if (op[0] == '*' && !op[1]) {
    r = x * y;
  } else if ((op[0] == '/' || op[0] == '%') && !op[1]) {
    if (!y) return c->err = "division by zero", false;
    if (sgn && (int64_t)x == INT64_MIN &&
        (int64_t)y == -1) // the one quotient that does not fit: it wraps, as C's would
      r = op[0] == '/' ? x : 0;
    else if (sgn)
      r = op[0] == '/' ? (uint64_t)((int64_t)x / (int64_t)y) : (uint64_t)((int64_t)x % (int64_t)y);
    else
      r = op[0] == '/' ? x / y : x % y;
  } else if (op[0] == '<' && op[1] == '<') {
    r = y < 64 ? x << y : 0;
  } else if (op[0] == '>' && op[1] == '>') {
    if (y >= 64)
      r = 0;
    else
      r = sgn ? (uint64_t)((int64_t)x >> y) : x >> y;
  } else if (op[0] == '&' && !op[1]) {
    r = x & y;
  } else if (op[0] == '|' && !op[1]) {
    r = x | y;
  } else if (op[0] == '^') {
    r = x ^ y;
  } else {
    type = VXD_SYN_LONG; // comparisons and logic: 0 or 1
    bool lt = sgn ? (int64_t)x < (int64_t)y : x < y, gt = sgn ? (int64_t)x > (int64_t)y : x > y;
    if (op[0] == '&' && op[1] == '&')
      r = x && y;
    else if (op[0] == '|' && op[1] == '|')
      r = x || y;
    else if (op[0] == '=' && op[1] == '=')
      r = x == y;
    else if (op[0] == '!' && op[1] == '=')
      r = x != y;
    else if (op[0] == '<' && op[1] == '=')
      r = !gt;
    else if (op[0] == '>' && op[1] == '=')
      r = !lt;
    else if (op[0] == '<')
      r = lt;
    else if (op[0] == '>')
      r = gt;
    else
      return c->err = "bad operator", false;
  }
  *a = vxd_imm(type, r);
  return true;
}

// .member or ->member of v.
static bool vxd_member(vxd_session *c, vxd_value *v, const vxd_tok *name, bool arrow) {
  if (arrow) {
    if (!vxd_rvalue(c, v)) return false;
    bool ok;
    *v = vxd_deref(c, v, &ok);
    if (!ok) return false;
  }
  vxd_tinfo i = vxd_info(c, v->type);
  if (i.kind != VXDI_STRUCT && i.kind != VXDI_UNION) return c->err = "not a struct or union", false;
  for (uint32_t k = 0; k < i.count && i.first + k < c->ix->h->members.count; k++) {
    const vxdi_member *m = &c->ix->members[i.first + k];
    const char *mn = vxdi_str(c->ix, m->name);
    size_t same = 0; // compared to mn's NUL at most: no byte past its end is read
    while (same < name->len && mn[same] && mn[same] == name->s[same]) same++;
    if (same == name->len && !mn[same]) {
      if (v->where != VXD_MEM) return c->err = "member of a value not in memory", false;
      *v = (vxd_value){.type = m->type, .where = VXD_MEM, .addr = v->addr + (uint64_t)m->offset};
      return true;
    }
  }
  return c->err = "no such member", false;
}

// Applies the operator on top of the stacks to the values under it.
static bool vxd_reduce(vxd_session *c, vxd_value *vals, uint32_t *nv, vxd_op *ops, uint32_t *no) {
  vxd_op o = ops[--*no];
  if (o.kind == OP_BINARY) {
    if (*nv < 2) return c->err = "missing operand", false;
    vxd_value b = vals[--*nv];
    return vxd_apply_binary(c, o.text, &vals[*nv - 1], b);
  }
  if (*nv < 1) return c->err = "missing operand", false;
  return vxd_apply_unary(c, &o, &vals[*nv - 1]);
}

// Evaluates text, a C expression, at the session's frame: its value in *out;
// false, with why in s->err, if it cannot be.
[[maybe_unused]] static bool vxd_eval(vxd_session *s, const char *text, vxd_value *out) {
  vxd_session c = *s;
  c.err = nullptr;
  vxd_value vals[32];
  vxd_op ops[64];
  uint32_t nv = 0, no = 0;
  bool want_operand = true;
  const char *p = text;
  bool ok = true;
  while (ok) {
    vxd_tok tk;
    const char *next = vxd_lex(p, &tk);
    if (!tk.s) {
      c.err = "unexpected character";
      ok = false;
      break;
    }
    if (tk.kind == T_END) break;
    if (want_operand) {
      if (tk.kind == T_NUM || tk.kind == T_CHAR) {
        if (nv == 32) return s->err = "too complex", false;
        vals[nv++] = vxd_imm(VXD_SYN_LONG, tk.num);
        want_operand = false;
      } else if (tk.kind == T_IDENT && vxd_tok_word(&tk, "sizeof")) {
        vxd_tok paren;
        const char *q = vxd_lex(next, &paren), *end;
        uint32_t ty = vxd_tok_is(&paren, "(") ? vxd_type_name(&c, q, &end) : 0;
        vxd_tok close;
        if (ty && (vxd_lex(end, &close), vxd_tok_is(&close, ")"))) { // sizeof(type)
          if (nv == 32) return s->err = "too complex", false;
          vals[nv++] = vxd_imm(VXD_SYN_ULONG, vxd_info(&c, ty).size);
          next = vxd_lex(end, &close);
          want_operand = false;
        } else {
          if (no == 64) return s->err = "too complex", false;
          ops[no++] = (vxd_op){.kind = OP_SIZEOF};
        }
      } else if (tk.kind == T_IDENT || tk.kind == T_REG) {
        if (nv == 32) return s->err = "too complex", false;
        ok = vxd_name(&c, &tk, &vals[nv++]);
        want_operand = false;
      } else if (vxd_tok_is(&tk, "(")) {
        const char *end;
        uint32_t ty = vxd_type_name(&c, next, &end);
        vxd_tok close;
        if (no == 64) return s->err = "too complex", false;
        if (ty && (vxd_lex(end, &close), vxd_tok_is(&close, ")"))) { // a cast
          ops[no++] = (vxd_op){.kind = OP_CAST, .type = ty};
          next = vxd_lex(end, &close);
        } else {
          ops[no++] = (vxd_op){.kind = OP_PAREN};
        }
      } else if (tk.kind == T_OP &&
                 (tk.op[0] == '-' || tk.op[0] == '!' || tk.op[0] == '~' || tk.op[0] == '*' ||
                  tk.op[0] == '&' || tk.op[0] == '+') &&
                 !tk.op[1]) {
        if (no == 64) return s->err = "too complex", false;
        uint8_t k = 0; // unary +: nothing to do
        switch (tk.op[0]) {
        case '-': k = OP_NEG; break;
        case '!': k = OP_NOT; break;
        case '~': k = OP_BNOT; break;
        case '*': k = OP_DEREF; break;
        case '&': k = OP_ADDR; break;
        default: break;
        }
        if (k) ops[no++] = (vxd_op){.kind = k};
      } else {
        c.err = "expected a value";
        ok = false;
      }
    } else if (vxd_tok_is(&tk, ".") || vxd_tok_is(&tk, "->")) { // postfix: at once, on the operand
      vxd_tok name;
      next = vxd_lex(next, &name);
      ok = name.kind == T_IDENT ? vxd_member(&c, &vals[nv - 1], &name, tk.op[0] == '-')
                                : (c.err = "expected a member", false);
    } else if (vxd_tok_is(&tk, "[")) {
      if (no == 64) return s->err = "too complex", false;
      ops[no++] = (vxd_op){.kind = OP_INDEX};
      want_operand = true;
    } else if (vxd_tok_is(&tk, ")") || vxd_tok_is(&tk, "]")) {
      uint8_t open = tk.op[0] == ')' ? OP_PAREN : OP_INDEX;
      while (ok && no && ops[no - 1].kind != open) ok = vxd_reduce(&c, vals, &nv, ops, &no);
      if (!ok) break;
      if (!no) {
        c.err = "unbalanced brackets";
        ok = false;
        break;
      }
      no--;
      if (open == OP_INDEX) { // a[i]: *(a + i)
        if (nv < 2) {
          c.err = "missing index";
          ok = false;
          break;
        }
        vxd_value idx = vals[--nv];
        ok = vxd_apply_binary(&c, "+", &vals[nv - 1], idx);
        bool deref_ok = ok;
        if (ok) vals[nv - 1] = vxd_deref(&c, &vals[nv - 1], &deref_ok);
        ok = deref_ok;
      }
    } else if (vxd_binary_op(&tk)) {
      vxd_op o = {.kind = OP_BINARY, .text = {tk.op[0], tk.op[1], 0}};
      while (ok && no && ops[no - 1].kind != OP_PAREN && ops[no - 1].kind != OP_INDEX &&
             vxd_prec(&ops[no - 1]) >= vxd_prec(&o))
        ok = vxd_reduce(&c, vals, &nv, ops, &no);
      if (no == 64) return s->err = "too complex", false;
      ops[no++] = o;
      want_operand = true;
    } else {
      c.err = "expected an operator";
      ok = false;
    }
    p = next;
  }
  if (ok && want_operand) c.err = "expected a value", ok = false;
  while (ok && no) {
    if (ops[no - 1].kind == OP_PAREN || ops[no - 1].kind == OP_INDEX) {
      c.err = "unbalanced brackets";
      ok = false;
      break;
    }
    ok = vxd_reduce(&c, vals, &nv, ops, &no);
  }
  if (ok && nv != 1) c.err = "not one expression", ok = false;
  if (ok) *out = vals[0];
  *s = c; // its pointer types, and why it failed
  return ok;
}

// --- Printing ---

typedef struct vxd_out {
  char *buf;
  size_t cap, len;
} vxd_out;

static void vxd_put(vxd_out *o, const char *s, size_t n) {
  for (size_t i = 0; i < n && o->len + 1 < o->cap; i++) o->buf[o->len++] = s[i];
  if (o->cap) o->buf[o->len] = 0;
}
static void vxd_puts(vxd_out *o, const char *s) {
  size_t n = 0;
  while (s[n]) n++;
  vxd_put(o, s, n);
}
static void vxd_put_u(vxd_out *o, uint64_t v, bool hex) {
  char d[24];
  size_t n = 0;
  do d[n++] = "0123456789abcdef"[hex ? v & 15 : v % 10];
  while (hex ? (v >>= 4) : (v /= 10));
  if (hex) vxd_puts(o, "0x");
  while (n) vxd_put(o, &d[--n], 1);
}
static void vxd_put_i(vxd_out *o, int64_t v) {
  if (v < 0) vxd_puts(o, "-");
  vxd_put_u(o, v < 0 ? (uint64_t)0 - (uint64_t)v : (uint64_t)v, false);
}

static void vxd_put_double(vxd_out *o, double d) {
  if (d != d) return vxd_puts(o, "nan");
  if (d < 0) vxd_puts(o, "-"), d = -d;
  if (d > 1e18) return vxd_puts(o, "inf-or-large");
  uint64_t whole = (uint64_t)d;
  vxd_put_u(o, whole, false);
  uint64_t frac = (uint64_t)((d - (double)whole) * 1e6 + 0.5);
  if (frac >= 1000000) frac = 999999;
  char digits[7] = "000000";
  for (int i = 5; i >= 0; i--) digits[i] = (char)('0' + frac % 10), frac /= 10;
  int last = 5;
  while (last > 0 && digits[last] == '0') last--;
  vxd_puts(o, ".");
  vxd_put(o, digits, (size_t)last + 1);
}

// A string in the program at addr, quoted: at most max bytes, until a NUL.
static void vxd_put_string(vxd_session *c, vxd_out *o, uint64_t addr, size_t max) {
  vxd_puts(o, "\"");
  for (size_t i = 0; i < max; i++) {
    if (o->len + 8 >= o->cap) break; // the output is full: no more of the target read for nothing
    char ch;
    if (!c->t->read(c->t->ctx, addr + i, &ch, 1)) return vxd_puts(o, "<unreadable>");
    if (!ch) return vxd_puts(o, "\"");
    if (ch == '"' || ch == '\\') vxd_put(o, "\\", 1);
    if ((unsigned char)ch < 0x20) {
      char esc[2] = {'\\', '?'};
      if (ch == '\n') esc[1] = 'n';
      if (ch == '\t') esc[1] = 't';
      vxd_put(o, esc, 2);
    } else {
      vxd_put(o, &ch, 1);
    }
  }
  vxd_puts(o, "...\"");
}

static bool vxd_char_type(vxd_session *c, uint32_t type) {
  vxd_tinfo i = vxd_info(c, type);
  return i.kind == VXDI_BASE && i.size == 1 &&
         (i.encoding == 6 || i.encoding == 8); // signed_char, unsigned_char
}

// A scalar (base, enum or pointer) value as text.
static void vxd_put_scalar(vxd_session *c, vxd_out *o, uint32_t type, uint64_t bits) {
  vxd_tinfo i = vxd_info(c, type);
  if (i.kind == VXDI_POINTER) {
    vxd_put_u(o, bits, true);
    if (bits && vxd_char_type(c, i.target)) vxd_puts(o, " "), vxd_put_string(c, o, bits, 64);
    return;
  }
  if (i.kind == VXDI_ENUM) {
    for (uint32_t k = 0; k < i.count && i.first + k < c->ix->h->members.count; k++) {
      const vxdi_member *m = &c->ix->members[i.first + k];
      if ((uint64_t)m->offset == bits) return vxd_puts(o, vxdi_str(c->ix, m->name));
    }
    return vxd_put_i(o, (int64_t)bits);
  }
  if (vxd_float(&i)) {
    double d;
    memcpy(&d, &bits, 8);
    return vxd_put_double(o, d);
  }
  if (i.encoding == 2) return vxd_puts(o, bits ? "true" : "false"); // DW_ATE_boolean
  if (vxd_signed(&i))
    vxd_put_i(o, (int64_t)bits);
  else
    vxd_put_u(o, bits, false);
  if (vxd_char_type(c, type) && bits >= 0x20 && bits < 0x7f) {
    char q[4] = {' ', '\'', (char)bits, '\''};
    vxd_put(o, q, 4);
  }
}

// v as text, into buf (cap bytes): a struct's members one level deep, an
// array's first elements, a char array or char * as a string.
[[maybe_unused]] static size_t vxd_format(vxd_session *s, const vxd_value *v, char *buf, size_t cap) {
  vxd_session c = *s;
  const vxdi *ix = c.ix;
  vxd_out o = {.buf = buf, .cap = cap};
  if (cap) buf[0] = 0;
  vxd_tinfo i = vxd_info(&c, v->type);
  uint64_t bits;
  if (vxd_scalar(&i)) {
    if (vxd_load(&c, v, &bits))
      vxd_put_scalar(&c, &o, v->type, bits);
    else
      vxd_puts(&o, c.err);
  } else if (v->where != VXD_MEM) {
    vxd_puts(&o, "<not in memory>");
  } else if (i.kind == VXDI_ARRAY && vxd_char_type(&c, i.target)) {
    vxd_put_string(&c, &o, v->addr, i.count ? i.count : 64);
  } else if (i.kind == VXDI_ARRAY) {
    uint64_t esize = vxd_info(&c, i.target).size;
    vxd_puts(&o, "[");
    for (uint32_t k = 0; k < i.count && k < 8; k++) {
      vxd_value e = {.type = i.target, .where = VXD_MEM, .addr = v->addr + k * esize};
      if (k) vxd_puts(&o, ", ");
      vxd_tinfo ei = vxd_info(&c, i.target);
      if (vxd_scalar(&ei) && vxd_load(&c, &e, &bits))
        vxd_put_scalar(&c, &o, i.target, bits);
      else
        vxd_puts(&o, "{...}");
    }
    vxd_puts(&o, i.count > 8 ? ", ...]" : "]");
  } else if (i.kind == VXDI_STRUCT || i.kind == VXDI_UNION) {
    vxd_puts(&o, "{");
    for (uint32_t k = 0; k < i.count && i.first + k < ix->h->members.count; k++) {
      const vxdi_member *m = &ix->members[i.first + k];
      vxd_value mv = {.type = m->type, .where = VXD_MEM, .addr = v->addr + (uint64_t)m->offset};
      vxd_tinfo mi = vxd_info(&c, m->type);
      if (k) vxd_puts(&o, ", ");
      vxd_puts(&o, vxdi_str(ix, m->name));
      vxd_puts(&o, " = ");
      if (vxd_scalar(&mi) && vxd_load(&c, &mv, &bits))
        vxd_put_scalar(&c, &o, m->type, bits);
      else if (mi.kind == VXDI_ARRAY && vxd_char_type(&c, mi.target))
        vxd_put_string(&c, &o, mv.addr, mi.count ? mi.count : 64);
      else
        vxd_puts(&o, "{...}");
    }
    vxd_puts(&o, "}");
  } else {
    vxd_puts(&o, "<no value>");
  }
  return o.len;
}
