// vx-debug dwarf: a vxdi index from an ELF image's DWARF 5 and symbol table
// (debug.h, ADR-0017).
//
// Two passes over the compilation units: the first counts what each table
// will hold and the bytes of its strings and expressions, then the index is
// allocated whole, and the second fills it. Type references are kept as DIE
// offsets while filling and become type numbers at the end, as a type may be
// referred to before it is defined. DIEs are walked with an explicit stack,
// never recursively. Every read is bounded by its section: a bad offset ends
// that unit's DIEs, not the program.

#pragma once

#include "elf.c"

// --- Reading ---

typedef struct dw_cur {
  const uint8_t *p, *end;
  bool bad;
} dw_cur;

static const uint8_t *dw_take(dw_cur *c, size_t n) {
  if (c->bad || (size_t)(c->end - c->p) < n) {
    c->bad = true;
    c->p = c->end;
    return nullptr;
  }
  const uint8_t *at = c->p;
  c->p += n;
  return at;
}

static uint64_t dw_fixed(dw_cur *c, size_t n) {
  const uint8_t *p = dw_take(c, n);
  uint64_t v = 0;
  for (size_t i = 0; p && i < n && i < 8; i++)
    v |= (uint64_t)p[i] << (8 * i); // a wider field (a bad header's): its low 8
  return v;
}

static uint64_t dw_uleb(dw_cur *c) {
  uint64_t v = 0;
  for (uint32_t shift = 0;; shift += 7) {
    const uint8_t *b = dw_take(c, 1);
    if (!b) return 0;
    if (shift < 64) v |= (uint64_t)(*b & 0x7f) << shift;
    if (!(*b & 0x80)) return v;
  }
}

static int64_t dw_sleb(dw_cur *c) {
  uint64_t v = 0;
  uint32_t shift = 0;
  const uint8_t *b;
  do {
    b = dw_take(c, 1);
    if (!b) return 0;
    if (shift < 64) v |= (uint64_t)(*b & 0x7f) << shift;
    shift += 7;
  } while (*b & 0x80);
  if (shift < 64 && (*b & 0x40)) v |= ~0ull << shift;
  return (int64_t)v;
}

// A NUL-terminated string at off in sec, or null if it runs past its end.
static const char *dw_cstr(vxd_bytes sec, uint64_t off) {
  if (off >= sec.n) return nullptr;
  for (size_t i = off; i < sec.n; i++)
    if (!sec.p[i]) return (const char *)sec.p + off;
  return nullptr;
}

// --- The DWARF constants it uses ---

enum : uint16_t {
  DW_TAG_array_type = 0x01,
  DW_TAG_enumeration_type = 0x04,
  DW_TAG_formal_parameter = 0x05,
  DW_TAG_lexical_block = 0x0b,
  DW_TAG_member = 0x0d,
  DW_TAG_pointer_type = 0x0f,
  DW_TAG_compile_unit = 0x11,
  DW_TAG_structure_type = 0x13,
  DW_TAG_subroutine_type = 0x15,
  DW_TAG_typedef = 0x16,
  DW_TAG_union_type = 0x17,
  DW_TAG_inlined_subroutine = 0x1d,
  DW_TAG_subrange_type = 0x21,
  DW_TAG_base_type = 0x24,
  DW_TAG_const_type = 0x26,
  DW_TAG_enumerator = 0x28,
  DW_TAG_subprogram = 0x2e,
  DW_TAG_variable = 0x34,
  DW_TAG_volatile_type = 0x35,
  DW_TAG_restrict_type = 0x37,
  DW_TAG_atomic_type = 0x47,
};

enum : uint16_t {
  DW_AT_location = 0x02,
  DW_AT_name = 0x03,
  DW_AT_byte_size = 0x0b,
  DW_AT_stmt_list = 0x10,
  DW_AT_low_pc = 0x11,
  DW_AT_high_pc = 0x12,
  DW_AT_comp_dir = 0x1b,
  DW_AT_const_value = 0x1c,
  DW_AT_upper_bound = 0x2f,
  DW_AT_count = 0x37,
  DW_AT_data_member_location = 0x38,
  DW_AT_decl_file = 0x3a,
  DW_AT_decl_line = 0x3b,
  DW_AT_declaration = 0x3c,
  DW_AT_encoding = 0x3e,
  DW_AT_frame_base = 0x40,
  DW_AT_type = 0x49,
  DW_AT_ranges = 0x55,
  DW_AT_str_offsets_base = 0x72,
  DW_AT_addr_base = 0x73,
  DW_AT_rnglists_base = 0x74,
  DW_AT_loclists_base = 0x8c,
};

enum : uint16_t {
  DW_FORM_addr = 0x01,
  DW_FORM_block2 = 0x03,
  DW_FORM_block4 = 0x04,
  DW_FORM_data2 = 0x05,
  DW_FORM_data4 = 0x06,
  DW_FORM_data8 = 0x07,
  DW_FORM_string = 0x08,
  DW_FORM_block = 0x09,
  DW_FORM_block1 = 0x0a,
  DW_FORM_data1 = 0x0b,
  DW_FORM_flag = 0x0c,
  DW_FORM_sdata = 0x0d,
  DW_FORM_strp = 0x0e,
  DW_FORM_udata = 0x0f,
  DW_FORM_ref_addr = 0x10,
  DW_FORM_ref1 = 0x11,
  DW_FORM_ref2 = 0x12,
  DW_FORM_ref4 = 0x13,
  DW_FORM_ref8 = 0x14,
  DW_FORM_ref_udata = 0x15,
  DW_FORM_indirect = 0x16,
  DW_FORM_sec_offset = 0x17,
  DW_FORM_exprloc = 0x18,
  DW_FORM_flag_present = 0x19,
  DW_FORM_strx = 0x1a,
  DW_FORM_addrx = 0x1b,
  DW_FORM_ref_sup4 = 0x1c,
  DW_FORM_strp_sup = 0x1d,
  DW_FORM_data16 = 0x1e,
  DW_FORM_line_strp = 0x1f,
  DW_FORM_ref_sig8 = 0x20,
  DW_FORM_implicit_const = 0x21,
  DW_FORM_loclistx = 0x22,
  DW_FORM_rnglistx = 0x23,
  DW_FORM_ref_sup8 = 0x24,
  DW_FORM_strx1 = 0x25,
  DW_FORM_strx2 = 0x26,
  DW_FORM_strx3 = 0x27,
  DW_FORM_strx4 = 0x28,
  DW_FORM_addrx1 = 0x29,
  DW_FORM_addrx2 = 0x2a,
  DW_FORM_addrx3 = 0x2b,
  DW_FORM_addrx4 = 0x2c,
};

// --- One unit ---

static constexpr uint32_t DW_MAX_ABBREVS = 4096, DW_MAX_SPECS = 32768, DW_MAX_DEPTH = 64, DW_MAX_FILES = 512;

typedef struct dw_spec {
  uint16_t name, form;
  int64_t implicit;
} dw_spec;

typedef struct dw_abbrev {
  uint64_t code;
  uint16_t tag;
  bool children;
  uint32_t first, count; // its specs
} dw_abbrev;

typedef struct dw_cu {
  uint64_t start;   // the unit's offset in .debug_info
  uint64_t die_end; // and its end
  uint8_t addr_size;
  uint64_t str_offsets_base, addr_base, rnglists_base, loclists_base;
  uint64_t low_pc;
  uint32_t file_base, file_count; // its line table's files, from file_base in the index's files
} dw_cu;

typedef struct dw_val {
  uint16_t form;
  uint64_t u;
  int64_t s;
  const uint8_t *block; // exprloc, a block, or an inline string
  size_t len;
} dw_val;

typedef struct vxd_builder {
  const vxd_elf *e;
  bool fill; // the second pass
  // What each table holds (counted in the first pass, filled in the second).
  uint64_t nfuncs, nlines, nvars, ntypes, nmembers, nsyms, nfiles, nstr, nexpr;
  vxdi_header *h;
  vxdi_func *funcs;
  vxdi_line *lines;
  vxdi_var *vars;
  vxdi_type *types;
  vxdi_member *members;
  vxdi_sym *syms;
  uint32_t *files;
  char *strings;
  uint8_t *exprs;
  uint64_t *type_dies; // each type's DIE offset, in order: what type references become
  dw_abbrev *abbrevs;
  dw_spec *specs;
  uint32_t nabbrevs, nspecs;
  dw_cu cu;
} vxd_builder;

// A string into the table: its offset (0, the empty string, for none).
static uint32_t emit_str2(vxd_builder *b, const char *dir, const char *s) {
  if (!s) return 0;
  size_t dl = 0, sl = 0;
  while (dir && dir[dl]) dl++;
  while (s[sl]) sl++;
  if (!dl && !sl) return 0;
  bool join = dl && s[0] != '/';
  uint64_t at = b->nstr, len = (join ? dl + 1 : 0) + sl;
  b->nstr += len + 1;
  if (!b->fill || at > UINT32_MAX) return b->fill ? 0 : (uint32_t)0;
  char *out = b->strings + at;
  if (join) memcpy(out, dir, dl), out[dl] = '/', out += dl + 1;
  memcpy(out, s, sl);
  out[sl] = 0;
  return (uint32_t)at;
}

static uint32_t emit_str(vxd_builder *b, const char *s) { return emit_str2(b, nullptr, s); }

static bool dw_abbrevs(vxd_builder *b, uint64_t off) {
  vxd_bytes sec = b->e->sec[VXD_ABBREV];
  if (off >= sec.n) return false;
  dw_cur c = {.p = sec.p + off, .end = sec.p + sec.n};
  b->nabbrevs = b->nspecs = 0;
  for (;;) {
    uint64_t code = dw_uleb(&c);
    if (!code || c.bad) return !c.bad;
    if (b->nabbrevs == DW_MAX_ABBREVS) return false;
    dw_abbrev *a = &b->abbrevs[b->nabbrevs++];
    *a = (dw_abbrev){.code = code, .tag = (uint16_t)dw_uleb(&c), .first = b->nspecs};
    a->children = dw_fixed(&c, 1) != 0;
    for (;;) {
      uint64_t name = dw_uleb(&c), form = dw_uleb(&c);
      if (c.bad) return false;
      if (!name && !form) break;
      if (b->nspecs == DW_MAX_SPECS) return false;
      dw_spec *s = &b->specs[b->nspecs++];
      *s = (dw_spec){.name = (uint16_t)name, .form = (uint16_t)form};
      if (form == DW_FORM_implicit_const) s->implicit = dw_sleb(&c);
      a->count++;
    }
  }
}

static const dw_abbrev *dw_abbrev_of(const vxd_builder *b, uint64_t code) {
  if (code && code <= b->nabbrevs && b->abbrevs[code - 1].code == code) return &b->abbrevs[code - 1];
  for (uint32_t i = 0; i < b->nabbrevs; i++)
    if (b->abbrevs[i].code == code) return &b->abbrevs[i];
  return nullptr;
}

// An attribute's value, as its form has it; strings and indexed addresses are
// resolved later (dw_string, dw_addrx), once the unit's bases are known.
static void dw_read(dw_cur *c, const dw_cu *cu, uint16_t form, int64_t implicit, dw_val *v) {
  if (form == DW_FORM_indirect)
    form = (uint16_t)dw_uleb(c); // the form is in the data; never another indirect
  *v = (dw_val){.form = form};
  switch (form) {
  case DW_FORM_addr: v->u = dw_fixed(c, cu->addr_size); break;
  case DW_FORM_data1:
  case DW_FORM_ref1:
  case DW_FORM_flag:
  case DW_FORM_strx1:
  case DW_FORM_addrx1: v->u = dw_fixed(c, 1); break;
  case DW_FORM_data2:
  case DW_FORM_ref2:
  case DW_FORM_strx2:
  case DW_FORM_addrx2: v->u = dw_fixed(c, 2); break;
  case DW_FORM_strx3:
  case DW_FORM_addrx3: v->u = dw_fixed(c, 3); break;
  case DW_FORM_data4:
  case DW_FORM_ref4:
  case DW_FORM_ref_addr:
  case DW_FORM_sec_offset:
  case DW_FORM_strp:
  case DW_FORM_line_strp:
  case DW_FORM_strx4:
  case DW_FORM_addrx4:
  case DW_FORM_ref_sup4:
  case DW_FORM_strp_sup: v->u = dw_fixed(c, 4); break;
  case DW_FORM_data8:
  case DW_FORM_ref8:
  case DW_FORM_ref_sig8:
  case DW_FORM_ref_sup8: v->u = dw_fixed(c, 8); break;
  case DW_FORM_data16: v->block = dw_take(c, 16), v->len = 16; break;
  case DW_FORM_sdata: v->s = dw_sleb(c), v->u = (uint64_t)v->s; break;
  case DW_FORM_udata:
  case DW_FORM_ref_udata:
  case DW_FORM_strx:
  case DW_FORM_addrx:
  case DW_FORM_loclistx:
  case DW_FORM_rnglistx: v->u = dw_uleb(c); break;
  case DW_FORM_implicit_const: v->s = implicit, v->u = (uint64_t)implicit; break;
  case DW_FORM_flag_present: v->u = 1; break;
  case DW_FORM_exprloc:
  case DW_FORM_block: v->len = (size_t)dw_uleb(c), v->block = dw_take(c, v->len); break;
  case DW_FORM_block1: v->len = (size_t)dw_fixed(c, 1), v->block = dw_take(c, v->len); break;
  case DW_FORM_block2: v->len = (size_t)dw_fixed(c, 2), v->block = dw_take(c, v->len); break;
  case DW_FORM_block4: v->len = (size_t)dw_fixed(c, 4), v->block = dw_take(c, v->len); break;
  case DW_FORM_string: {
    v->block = c->p;
    while (c->p < c->end && *c->p) c->p++;
    if (c->p == c->end) c->bad = true;
    v->len = (size_t)(c->p - v->block);
    dw_take(c, 1);
    break;
  }
  default: c->bad = true; break; // a form DWARF 5 does not have
  }
  if (c->bad) v->block = nullptr;
}

static bool dw_is_ref(uint16_t form) {
  return form == DW_FORM_ref1 || form == DW_FORM_ref2 || form == DW_FORM_ref4 || form == DW_FORM_ref8 ||
         form == DW_FORM_ref_udata;
}

static const char *dw_string(const vxd_builder *b, const dw_val *v) {
  const vxd_elf *e = b->e;
  switch (v->form) {
  case DW_FORM_string: return v->block ? (const char *)v->block : nullptr;
  case DW_FORM_strp: return dw_cstr(e->sec[VXD_STR], v->u);
  case DW_FORM_line_strp: return dw_cstr(e->sec[VXD_LINE_STR], v->u);
  case DW_FORM_strx:
  case DW_FORM_strx1:
  case DW_FORM_strx2:
  case DW_FORM_strx3:
  case DW_FORM_strx4: {
    vxd_bytes so = e->sec[VXD_STR_OFFSETS];
    uint64_t at = b->cu.str_offsets_base + v->u * 4;
    if (at > so.n || so.n - at < 4) return nullptr;
    dw_cur c = {.p = so.p + at, .end = so.p + so.n};
    return dw_cstr(e->sec[VXD_STR], dw_fixed(&c, 4));
  }
  default: return nullptr;
  }
}

// The address an addrx form, or a DW_OP_addrx, names.
static uint64_t dw_addr_at(const vxd_builder *b, uint64_t index) {
  vxd_bytes sec = b->e->sec[VXD_ADDR];
  uint64_t at = b->cu.addr_base + index * b->cu.addr_size;
  if (at > sec.n || sec.n - at < b->cu.addr_size) return 0;
  dw_cur c = {.p = sec.p + at, .end = sec.p + sec.n};
  return dw_fixed(&c, b->cu.addr_size);
}

static uint64_t dw_address(const vxd_builder *b, const dw_val *v) {
  if (v->form == DW_FORM_addr) return v->u;
  return dw_addr_at(b, v->u); // addrx, addrx1-4
}

static bool dw_is_addrx(uint16_t form) {
  return form == DW_FORM_addrx || form == DW_FORM_addrx1 || form == DW_FORM_addrx2 ||
         form == DW_FORM_addrx3 || form == DW_FORM_addrx4;
}

// --- Expressions ---

// An operation's operands, skipped (and, for addrx and constx, rewritten as
// DW_OP_addr). Returns false for one it does not know: the copy stops there.
static bool dw_op(const vxd_builder *b, dw_cur *c, uint8_t op, uint8_t *out, size_t *n) {
  const uint8_t *start = c->p;
  bool addr_op = op == 0xa1 || op == 0xa2; // DW_OP_addrx, DW_OP_constx
  if (addr_op) {
    uint64_t a = dw_addr_at(b, dw_uleb(c));
    if (out && !c->bad) { // a bad one is not counted (emit_expr): nor written past what was
      out[*n] = 0x03;     // DW_OP_addr
      for (int i = 0; i < 8; i++) out[*n + 1 + i] = (uint8_t)(a >> (8 * i));
    }
    *n += 9;
    return !c->bad;
  }
  if (op == 0x03)
    dw_take(c, b->cu.addr_size);
  else if (op == 0x08 || op == 0x09 || op == 0x15 || op == 0x94 || op == 0x95)
    dw_take(c, 1);
  else if (op == 0x0a || op == 0x0b || op == 0x28 || op == 0x2f || op == 0x98)
    dw_take(c, 2);
  else if (op == 0x0c || op == 0x0d || op == 0x99 || op == 0x9a)
    dw_take(c, 4);
  else if (op == 0x0e || op == 0x0f)
    dw_take(c, 8);
  else if (op == 0x10 || op == 0x23 || op == 0x90 || op == 0x93 || op == 0xa8 || op == 0xa9)
    dw_uleb(c);
  else if (op == 0x11 || (op >= 0x70 && op <= 0x8f) || op == 0x91)
    dw_sleb(c);
  else if (op == 0x92)
    dw_uleb(c), dw_sleb(c);
  else if (op == 0x9d || op == 0xa5)
    dw_uleb(c), dw_uleb(c);
  else if (op == 0x9e || op == 0xa3 || op == 0xf3)
    dw_take(c, (size_t)dw_uleb(c)); // implicit_value, entry_value
  else if (op == 0xa0)
    dw_take(c, 4), dw_sleb(c); // implicit_pointer
  else if (op == 0xa4)
    dw_uleb(c), dw_take(c, (size_t)dw_fixed(c, 1)); // const_type
  else if (op == 0xa6 || op == 0xa7)
    dw_take(c, 1), dw_uleb(c); // deref_type
  else if (!(op >= 0x06 && op <= 0x9f && op != 0x9b))
    return false; // no operands: the rest of the range
  size_t len = (size_t)(c->p - start);
  if (out && !c->bad) {
    out[*n] = op;
    memcpy(out + *n + 1, start, len);
  }
  *n += 1 + len;
  return !c->bad;
}

// A DWARF expression into exprs, rewritten to stand alone: its offset; its
// length in *len.
static uint32_t emit_expr(vxd_builder *b, const uint8_t *p, size_t n, uint32_t *len) {
  if (!p) n = 0; // a block that ran past its section
  dw_cur c = {.p = p, .end = p ? p + n : p};
  size_t out = 0;
  uint8_t *dst = b->fill ? b->exprs + b->nexpr : nullptr;
  while (c.p < c.end) {
    uint8_t op = c.p[0];
    c.p++;
    size_t before = out;
    if (!dw_op(b, &c, op, dst, &out)) {
      out = before; // what it understood
      break;
    }
  }
  uint64_t at = b->nexpr;
  b->nexpr += out;
  *len = (uint32_t)out;
  return (uint32_t)at;
}

static void emit_u64(vxd_builder *b, uint64_t v, size_t bytes) {
  if (b->fill)
    for (size_t i = 0; i < bytes; i++) b->exprs[b->nexpr + i] = (uint8_t)(v >> (8 * i));
  b->nexpr += bytes;
}

// The offset a rnglistx or loclistx index names, from the offsets table at base.
static uint64_t dw_list_offset(vxd_bytes sec, uint64_t base, uint64_t index) {
  uint64_t at = base + index * 4;
  if (at > sec.n || sec.n - at < 4) return UINT64_MAX;
  dw_cur c = {.p = sec.p + at, .end = sec.p + sec.n};
  return base + dw_fixed(&c, 4);
}

// A location list (DW_LLE_*) as the index's: {lo, hi, len, bytes}..., then 0, 0, 0.
static uint32_t emit_loclist(vxd_builder *b, const dw_val *v) {
  vxd_bytes sec = b->e->sec[VXD_LOCLISTS];
  uint64_t off = v->form == DW_FORM_loclistx ? dw_list_offset(sec, b->cu.loclists_base, v->u) : v->u;
  uint32_t at = (uint32_t)b->nexpr;
  if (off < sec.n) {
    dw_cur c = {.p = sec.p + off, .end = sec.p + sec.n};
    uint64_t base = b->cu.low_pc;
    for (uint32_t guard = 0; guard < 4096 && !c.bad; guard++) {
      uint8_t kind = (uint8_t)dw_fixed(&c, 1);
      uint64_t lo = 0, hi = 0;
      if (kind == 0) break; // end_of_list
      if (kind == 1) {      // base_addressx
        base = dw_addr_at(b, dw_uleb(&c));
        continue;
      }
      if (kind == 6) { // base_address
        base = dw_fixed(&c, b->cu.addr_size);
        continue;
      }
      if (kind == 2)
        lo = dw_addr_at(b, dw_uleb(&c)), hi = dw_addr_at(b, dw_uleb(&c));
      else if (kind == 3)
        lo = dw_addr_at(b, dw_uleb(&c)), hi = lo + dw_uleb(&c);
      else if (kind == 4)
        lo = base + dw_uleb(&c), hi = base + dw_uleb(&c);
      else if (kind == 5)
        lo = 0, hi = UINT64_MAX; // default_location
      else if (kind == 7)
        lo = dw_fixed(&c, b->cu.addr_size), hi = dw_fixed(&c, b->cu.addr_size);
      else if (kind == 8)
        lo = dw_fixed(&c, b->cu.addr_size), hi = lo + dw_uleb(&c);
      else
        break;
      size_t len = (size_t)dw_uleb(&c);
      const uint8_t *expr = dw_take(&c, len);
      if (!expr) break;
      emit_u64(b, lo, 8);
      emit_u64(b, hi, 8);
      uint64_t len_at = b->nexpr;
      emit_u64(b, 0, 4);
      uint32_t elen;
      emit_expr(b, expr, len, &elen);
      if (b->fill)
        for (int i = 0; i < 4; i++) b->exprs[len_at + (uint64_t)i] = (uint8_t)(elen >> (8 * i));
    }
  }
  emit_u64(b, 0, 8);
  emit_u64(b, 0, 8);
  emit_u64(b, 0, 4);
  return at;
}

// The lowest and highest address a range list (DW_RLE_*) covers.
static void dw_ranges(const vxd_builder *b, const dw_val *v, uint64_t *low, uint64_t *high) {
  vxd_bytes sec = b->e->sec[VXD_RNGLISTS];
  uint64_t off = v->form == DW_FORM_rnglistx ? dw_list_offset(sec, b->cu.rnglists_base, v->u) : v->u;
  *low = UINT64_MAX, *high = 0;
  if (off >= sec.n) return;
  dw_cur c = {.p = sec.p + off, .end = sec.p + sec.n};
  uint64_t base = b->cu.low_pc;
  for (uint32_t guard = 0; guard < 4096 && !c.bad; guard++) {
    uint8_t kind = (uint8_t)dw_fixed(&c, 1);
    uint64_t lo, hi;
    if (kind == 0) break;
    if (kind == 1) {
      base = dw_addr_at(b, dw_uleb(&c));
      continue;
    }
    if (kind == 5) {
      base = dw_fixed(&c, b->cu.addr_size);
      continue;
    }
    if (kind == 2)
      lo = dw_addr_at(b, dw_uleb(&c)), hi = dw_addr_at(b, dw_uleb(&c));
    else if (kind == 3)
      lo = dw_addr_at(b, dw_uleb(&c)), hi = lo + dw_uleb(&c);
    else if (kind == 4)
      lo = base + dw_uleb(&c), hi = base + dw_uleb(&c);
    else if (kind == 6)
      lo = dw_fixed(&c, b->cu.addr_size), hi = dw_fixed(&c, b->cu.addr_size);
    else if (kind == 7)
      lo = dw_fixed(&c, b->cu.addr_size), hi = lo + dw_uleb(&c);
    else
      break;
    if (lo < *low) *low = lo;
    if (hi > *high) *high = hi;
  }
  if (*low > *high) *low = *high = 0;
}

// --- The line table ---

// Reads a v5 line table header's directory or file entry formats, then the
// entries: each path joined to its directory, into the files table.
static void dw_line_files(vxd_builder *b, dw_cur *c, const char **dirs, uint32_t *ndirs, bool is_dirs) {
  uint8_t nformats = (uint8_t)dw_fixed(c, 1);
  uint64_t formats[16][2];
  if (nformats > 16) {
    c->bad = true;
    return;
  }
  for (uint8_t i = 0; i < nformats; i++) formats[i][0] = dw_uleb(c), formats[i][1] = dw_uleb(c);
  uint64_t count = dw_uleb(c);
  for (uint64_t k = 0; k < count && !c->bad; k++) {
    const char *path = nullptr;
    uint64_t dir = 0;
    const uint8_t *entry = c->p;
    for (uint8_t i = 0; i < nformats; i++) {
      dw_val v;
      dw_read(c, &b->cu, (uint16_t)formats[i][1], 0, &v);
      if (formats[i][0] == 1) path = dw_string(b, &v); // DW_LNCT_path
      if (formats[i][0] == 2) dir = v.u;               // DW_LNCT_directory_index
    }
    if (c->p == entry) { // an entry of no bytes: a count from a broken header would never end
      c->bad = true;
      break;
    }
    if (is_dirs) {
      if (*ndirs < DW_MAX_FILES) dirs[(*ndirs)++] = path;
      continue;
    }
    // A relative directory is relative to directory 0, the compilation's.
    const char *d = dir < *ndirs ? dirs[dir] : nullptr;
    static char joined[512];
    if (d && d[0] != '/' && dir > 0 && *ndirs && dirs[0]) {
      size_t n0 = 0, n1 = 0;
      while (dirs[0][n0]) n0++;
      while (d[n1]) n1++;
      if (n0 + 1 + n1 < sizeof joined) {
        memcpy(joined, dirs[0], n0), joined[n0] = '/', memcpy(joined + n0 + 1, d, n1 + 1);
        d = joined;
      }
    }
    uint32_t name = emit_str2(b, d, path);
    if (b->fill) b->files[b->nfiles] = name;
    b->nfiles++;
    b->cu.file_count++;
  }
}

static void emit_row(vxd_builder *b, uint64_t addr, uint64_t file, uint64_t line, uint32_t flags) {
  if (b->fill)
    b->lines[b->nlines] = (vxdi_line){.addr = addr,
                                      .file = file < b->cu.file_count ? b->cu.file_base + (uint32_t)file : 0,
                                      .line = (uint32_t)line,
                                      .flags = flags};
  b->nlines++;
}

// The unit's line program: its files, then its rows.
static void dw_lines(vxd_builder *b, uint64_t off) {
  vxd_bytes sec = b->e->sec[VXD_LINE];
  b->cu.file_base = (uint32_t)b->nfiles;
  b->cu.file_count = 0;
  if (off >= sec.n) return;
  dw_cur c = {.p = sec.p + off, .end = sec.p + sec.n};
  uint64_t unit_len = dw_fixed(&c, 4);
  if (unit_len >= 0xffff'fff0 || unit_len > (uint64_t)(c.end - c.p)) return; // DWARF64 is not read
  const uint8_t *end = c.p + unit_len;
  c.end = end;
  if (dw_fixed(&c, 2) != 5) return;
  uint8_t addr_size = (uint8_t)dw_fixed(&c, 1);
  dw_fixed(&c, 1); // segment selector size
  uint64_t header_len = dw_fixed(&c, 4);
  if (c.bad || header_len > (uint64_t)(c.end - c.p)) return; // checked before the pointer is made
  const uint8_t *program = c.p + header_len;
  uint8_t min_inst = (uint8_t)dw_fixed(&c, 1);
  dw_fixed(&c, 1); // maximum operations per instruction: 1 on our machines
  bool default_stmt = dw_fixed(&c, 1) != 0;
  int8_t line_base = (int8_t)dw_fixed(&c, 1);
  uint8_t line_range = (uint8_t)dw_fixed(&c, 1), opcode_base = (uint8_t)dw_fixed(&c, 1);
  uint8_t std_lens[256] = {};
  for (uint32_t i = 1; i < opcode_base; i++) std_lens[i] = (uint8_t)dw_fixed(&c, 1);
  static const char *dirs[DW_MAX_FILES];
  uint32_t ndirs = 0;
  dw_line_files(b, &c, dirs, &ndirs, true);
  dw_line_files(b, &c, dirs, &ndirs, false);
  if (c.bad || program > end || !line_range) return;
  c.p = program;
  uint64_t addr = 0, file = 1, line = 1;
  bool stmt = default_stmt, prologue_end = false;
  while (c.p < c.end && !c.bad) {
    uint8_t op = (uint8_t)dw_fixed(&c, 1);
    uint32_t flags = (stmt ? VXDI_STMT : 0) | (prologue_end ? VXDI_PROLOGUE_END : 0);
    if (op >= opcode_base) { // special: advance, then a row
      uint32_t adj = op - opcode_base;
      addr += (uint64_t)(adj / line_range) * min_inst;
      line += (uint64_t)(int64_t)(line_base + (int32_t)(adj % line_range));
      emit_row(b, addr, file, line, flags);
      prologue_end = false;
      continue;
    }
    switch (op) {
    case 0: { // extended
      uint64_t len = dw_uleb(&c);
      if (len == 0 || len > (uint64_t)(c.end - c.p)) {
        c.bad = true;
        break;
      }
      const uint8_t *next = c.p + len;
      uint8_t sub = (uint8_t)dw_fixed(&c, 1);
      if (sub == 1) { // end_sequence
        emit_row(b, addr, file, line, flags | VXDI_END);
        addr = 0, file = 1, line = 1, stmt = default_stmt, prologue_end = false;
      } else if (sub == 2) { // set_address
        addr = dw_fixed(&c, addr_size);
      }
      c.p = next;
      break;
    }
    case 1: emit_row(b, addr, file, line, flags), prologue_end = false; break;      // copy
    case 2: addr += dw_uleb(&c) * min_inst; break;                                  // advance_pc
    case 3: line += (uint64_t)dw_sleb(&c); break;                                   // advance_line
    case 4: file = dw_uleb(&c); break;                                              // set_file
    case 5: dw_uleb(&c); break;                                                     // set_column
    case 6: stmt = !stmt; break;                                                    // negate_stmt
    case 7: break;                                                                  // set_basic_block
    case 8: addr += (uint64_t)((255 - opcode_base) / line_range) * min_inst; break; // const_add_pc
    case 9: addr += dw_fixed(&c, 2); break;                                         // fixed_advance_pc
    case 10: prologue_end = true; break;                                            // set_prologue_end
    case 11: break;                                                                 // set_epilogue_begin
    case 12: dw_uleb(&c); break;                                                    // set_isa
    default:
      for (uint32_t i = 0; i < std_lens[op]; i++) dw_uleb(&c); // one the header describes
      break;
    }
  }
}

// --- DIEs ---

typedef struct dw_die {
  const char *name;
  bool has_low, high_is_len, declaration, has_location, has_const, has_frame_base, has_ranges;
  uint64_t low, high, type_die, byte_size, encoding, count, decl_file, decl_line, member_offset, stmt_list;
  int64_t const_value;
  dw_val location, frame_base, ranges, name_val, low_val, high_val;
} dw_die;

// Where a member is, from its DW_AT_data_member_location: a constant, or
// (older producers) DW_OP_plus_uconst N.
static uint64_t dw_member_offset(const dw_val *v) {
  if (!v->block) return v->u;
  dw_cur c = {.p = v->block, .end = v->block + v->len};
  if (dw_fixed(&c, 1) == 0x23) return dw_uleb(&c);
  return 0;
}

static void dw_attrs(vxd_builder *b, dw_cur *c, const dw_abbrev *a, dw_die *d) {
  *d = (dw_die){};
  for (uint32_t i = 0; i < a->count && !c->bad; i++) {
    const dw_spec *s = &b->specs[a->first + i];
    dw_val v;
    dw_read(c, &b->cu, s->form, s->implicit, &v);
    switch (s->name) {
    case DW_AT_name: d->name_val = v; break;
    case DW_AT_low_pc: d->has_low = true, d->low_val = v; break; // resolved below, once the bases are known
    case DW_AT_high_pc:
      d->high_val = v;
      d->high_is_len = v.form != DW_FORM_addr && !dw_is_addrx(v.form); // a length, from low_pc
      break;
    case DW_AT_type: d->type_die = dw_is_ref(v.form) ? b->cu.start + v.u : v.u; break;
    case DW_AT_byte_size: d->byte_size = v.u; break;
    case DW_AT_encoding: d->encoding = v.u; break;
    case DW_AT_count: d->count = v.u; break;
    case DW_AT_upper_bound:
      if (!d->count) d->count = v.u + 1;
      break;
    case DW_AT_decl_file: d->decl_file = v.u; break;
    case DW_AT_decl_line: d->decl_line = v.u; break;
    case DW_AT_declaration: d->declaration = v.u != 0; break;
    case DW_AT_data_member_location: d->member_offset = dw_member_offset(&v); break;
    case DW_AT_const_value: d->has_const = true, d->const_value = v.s ? v.s : (int64_t)v.u; break;
    case DW_AT_location: d->has_location = true, d->location = v; break;
    case DW_AT_frame_base: d->has_frame_base = true, d->frame_base = v; break;
    case DW_AT_ranges: d->has_ranges = true, d->ranges = v; break;
    case DW_AT_stmt_list: d->stmt_list = v.u; break;
    case DW_AT_str_offsets_base: b->cu.str_offsets_base = v.u; break;
    case DW_AT_addr_base: b->cu.addr_base = v.u; break;
    case DW_AT_rnglists_base: b->cu.rnglists_base = v.u; break;
    case DW_AT_loclists_base: b->cu.loclists_base = v.u; break;
    default: break;
    }
  }
  // Now the unit's bases are known: low_pc as an address, high_pc after it.
  if (d->has_low) d->low = dw_address(b, &d->low_val);
  if (d->high_val.form) d->high = d->high_is_len ? d->low + d->high_val.u : dw_address(b, &d->high_val);
  d->name = dw_string(b, &d->name_val);
}

typedef enum dw_ctx : uint8_t { CTX_NONE, CTX_FUNC, CTX_BLOCK, CTX_TYPE, CTX_SKIP } dw_ctx;

typedef struct dw_frame {
  dw_ctx ctx;
  uint64_t type; // CTX_TYPE: its index
  uint64_t scope_low, scope_high;
} dw_frame;

static uint32_t type_kind_of(uint16_t tag) {
  switch (tag) {
  case DW_TAG_base_type: return VXDI_BASE;
  case DW_TAG_pointer_type: return VXDI_POINTER;
  case DW_TAG_const_type: return VXDI_CONST_T;
  case DW_TAG_volatile_type: return VXDI_VOLATILE;
  case DW_TAG_restrict_type: return VXDI_RESTRICT;
  case DW_TAG_atomic_type: return VXDI_ATOMIC;
  case DW_TAG_typedef: return VXDI_TYPEDEF;
  case DW_TAG_structure_type: return VXDI_STRUCT;
  case DW_TAG_union_type: return VXDI_UNION;
  case DW_TAG_array_type: return VXDI_ARRAY;
  case DW_TAG_enumeration_type: return VXDI_ENUM;
  case DW_TAG_subroutine_type: return VXDI_FUNC;
  default: return VXDI_VOID;
  }
}

// A variable or parameter: in a function (its scope the innermost block), or
// at the unit's top, a global.
static void emit_var(vxd_builder *b, const dw_die *d, uint32_t kind, const dw_frame *scope) {
  if (!d->has_location && !d->has_const) return;
  vxdi_var v = {.name = emit_str(b, d->name), .type = (uint32_t)(d->type_die + 1), .kind = kind};
  if (scope && scope->ctx == CTX_BLOCK) v.scope_low = scope->scope_low, v.scope_high = scope->scope_high;
  if (d->has_const) {
    v.flags = VXDI_CONST;
    v.value = d->const_value;
  } else if (d->location.form == DW_FORM_exprloc || d->location.block) {
    v.loc = emit_expr(b, d->location.block, d->location.len, &v.loc_len);
  } else { // a location list
    v.flags = VXDI_LOCLIST;
    v.loc = emit_loclist(b, &d->location);
  }
  if (b->fill) b->vars[b->nvars] = v;
  b->nvars++;
}

static void dw_die_tree(vxd_builder *b, dw_cur *c) {
  dw_frame stack[DW_MAX_DEPTH];
  uint32_t depth = 0;
  int64_t func = -1; // the function whose variables are being listed
  while (c->p < c->end && !c->bad) {
    uint64_t die_off = (uint64_t)(c->p - b->e->sec[VXD_INFO].p);
    uint64_t code = dw_uleb(c);
    if (!code) { // the end of a list of children
      if (!depth) break;
      depth--;
      if (stack[depth].ctx == CTX_FUNC && func >= 0) {
        if (b->fill) b->funcs[func].var_count = (uint32_t)(b->nvars - b->funcs[func].first_var);
        func = -1;
      }
      continue;
    }
    const dw_abbrev *a = dw_abbrev_of(b, code);
    if (!a) {
      c->bad = true;
      break;
    }
    dw_die d;
    dw_attrs(b, c, a, &d);
    const dw_frame *parent = depth ? &stack[depth - 1] : nullptr;
    dw_frame me = {.ctx = parent && parent->ctx == CTX_SKIP ? CTX_SKIP : CTX_NONE};
    bool in_func = func >= 0 && parent && (parent->ctx == CTX_FUNC || parent->ctx == CTX_BLOCK);
    uint32_t tk = type_kind_of(a->tag);
    if (me.ctx == CTX_SKIP) {
      // inside something whose children are not listed
    } else if (a->tag == DW_TAG_compile_unit) {
      b->cu.low_pc = d.low;
      dw_lines(b, d.stmt_list);
    } else if (a->tag == DW_TAG_subprogram) {
      if (d.has_ranges && !d.has_low) dw_ranges(b, &d.ranges, &d.low, &d.high), d.has_low = d.low < d.high;
      if (d.has_low && !d.declaration && d.low < d.high && func < 0) {
        func = (int64_t)b->nfuncs;
        if (b->fill) {
          vxdi_func *f = &b->funcs[b->nfuncs];
          *f = (vxdi_func){.low = d.low,
                           .high = d.high,
                           .body = d.low,
                           .name = emit_str(b, d.name),
                           .file =
                               d.decl_file < b->cu.file_count ? b->cu.file_base + (uint32_t)d.decl_file : 0,
                           .line = (uint32_t)d.decl_line,
                           .type = (uint32_t)(d.type_die + 1),
                           .first_var = (uint32_t)b->nvars};
          if (d.has_frame_base && d.frame_base.block)
            f->frame_base = emit_expr(b, d.frame_base.block, d.frame_base.len, &f->frame_base_len);
        } else {
          emit_str(b, d.name);
          uint32_t fl;
          if (d.has_frame_base && d.frame_base.block) emit_expr(b, d.frame_base.block, d.frame_base.len, &fl);
        }
        b->nfuncs++;
        me.ctx = CTX_FUNC;
      } else {
        me.ctx = CTX_SKIP; // a declaration, or nested: its parameters are not variables of a function
      }
    } else if (a->tag == DW_TAG_lexical_block && in_func) {
      me.ctx = CTX_BLOCK;
      if (d.has_ranges) dw_ranges(b, &d.ranges, &d.low, &d.high);
      me.scope_low = d.low, me.scope_high = d.high;
    } else if (a->tag == DW_TAG_inlined_subroutine) {
      me.ctx = CTX_SKIP; // its variables are the inlined function's (not yet listed)
    } else if ((a->tag == DW_TAG_formal_parameter || a->tag == DW_TAG_variable) && in_func) {
      emit_var(b, &d, a->tag == DW_TAG_formal_parameter ? VXDI_PARAM : VXDI_LOCAL, parent);
    } else if (a->tag == DW_TAG_variable && depth == 1 && !d.declaration) {
      emit_var(b, &d, VXDI_GLOBAL, nullptr);
    } else if (tk != VXDI_VOID || a->tag == DW_TAG_subroutine_type) {
      if (b->fill) {
        b->type_dies[b->ntypes] = die_off;
        b->types[b->ntypes] = (vxdi_type){.kind = tk,
                                          .name = emit_str(b, d.name),
                                          .size = d.byte_size,
                                          .target = (uint32_t)(d.type_die + 1),
                                          .first = (uint32_t)b->nmembers,
                                          .encoding = (uint32_t)d.encoding};
      } else {
        emit_str(b, d.name);
      }
      me.ctx = CTX_TYPE;
      me.type = b->ntypes++;
    } else if ((a->tag == DW_TAG_member || a->tag == DW_TAG_enumerator) && parent &&
               parent->ctx == CTX_TYPE) {
      if (b->fill) {
        b->members[b->nmembers] =
            (vxdi_member){.name = emit_str(b, d.name),
                          .type = (uint32_t)(d.type_die + 1),
                          .offset = a->tag == DW_TAG_member ? (int64_t)d.member_offset : d.const_value};
        b->types[parent->type].count++;
      } else {
        emit_str(b, d.name);
      }
      b->nmembers++;
    } else if (a->tag == DW_TAG_subrange_type && parent && parent->ctx == CTX_TYPE && b->fill) {
      vxdi_type *t = &b->types[parent->type];
      if (t->kind == VXDI_ARRAY && !t->count) t->count = (uint32_t)d.count; // the first dimension
    }
    if (a->children) {
      if (depth == DW_MAX_DEPTH) {
        c->bad = true;
        break;
      }
      if (me.ctx == CTX_NONE && parent && (parent->ctx == CTX_FUNC || parent->ctx == CTX_BLOCK))
        me = *parent,
        me.ctx = CTX_SKIP; // a type or the like inside a function: its children are not variables
      stack[depth++] = me;
    } else if (me.ctx == CTX_FUNC) { // a function with no children: no variables
      if (b->fill) b->funcs[func].var_count = 0;
      func = -1;
    }
  }
}

static void dw_units(vxd_builder *b) {
  vxd_bytes info = b->e->sec[VXD_INFO];
  dw_cur c = {.p = info.p, .end = info.p + info.n};
  while (c.p < c.end && !c.bad) {
    uint64_t start = (uint64_t)(c.p - info.p);
    uint64_t len = dw_fixed(&c, 4);
    if (len >= 0xffff'fff0 || len > (uint64_t)(c.end - c.p)) break; // DWARF64 is not read
    const uint8_t *next = c.p + len;
    dw_cur u = {.p = c.p, .end = next};
    uint16_t version = (uint16_t)dw_fixed(&u, 2);
    uint8_t unit_type = (uint8_t)dw_fixed(&u, 1), addr_size = (uint8_t)dw_fixed(&u, 1);
    uint64_t abbrev_off = dw_fixed(&u, 4);
    c.p = next;
    if (version != 5 || (unit_type != 1 && unit_type != 3) || (addr_size != 8 && addr_size != 4) || u.bad)
      continue; // DW_UT_compile and DW_UT_partial only
    b->cu = (dw_cu){.start = start, .die_end = (uint64_t)(next - info.p), .addr_size = addr_size};
    if (!dw_abbrevs(b, abbrev_off)) continue;
    dw_die_tree(b, &u);
  }
}

static void dw_symbols(vxd_builder *b) {
  vxd_bytes sym = b->e->sec[VXD_SYMTAB], str = b->e->sec[VXD_STRTAB];
  for (size_t at = 0; at + 24 <= sym.n; at += 24) {
    const uint8_t *s = sym.p + at;
    uint8_t type = s[4] & 15;
    uint16_t shndx = elf_u16(s + 6);
    uint64_t value = elf_u64(s + 8), size = elf_u64(s + 16);
    if ((type != 1 && type != 2) || !value || !shndx) continue; // STT_OBJECT, STT_FUNC, defined
    const char *name = dw_cstr(str, elf_u32(s));
    if (b->fill)
      b->syms[b->nsyms] =
          (vxdi_sym){.addr = value, .size = size, .name = emit_str(b, name), .func = type == 2};
    else
      emit_str(b, name);
    b->nsyms++;
  }
}

// --- Sorting (a heap sort: in place, no recursion) ---

static void vxd_swap(uint8_t *a, uint8_t *b, size_t size) {
  for (size_t i = 0; i < size; i++) {
    uint8_t t = a[i];
    a[i] = b[i], b[i] = t;
  }
}

static void vxd_sort(void *base, size_t n, size_t size, int (*cmp)(const void *, const void *)) {
  uint8_t *p = base;
  for (size_t start = n / 2; n > 1;) {
    size_t root;
    if (start > 0) {
      root = --start;
    } else {
      n--;
      vxd_swap(p, p + n * size, size);
      root = 0;
    }
    for (size_t child; (child = 2 * root + 1) < n; root = child) {
      if (child + 1 < n && cmp(p + child * size, p + (child + 1) * size) < 0) child++;
      if (cmp(p + root * size, p + child * size) >= 0) break;
      vxd_swap(p + root * size, p + child * size, size);
    }
  }
}

static int by_func_low(const void *a, const void *b) {
  uint64_t x = ((const vxdi_func *)a)->low, y = ((const vxdi_func *)b)->low;
  return (x > y) - (x < y);
}

static int by_line_addr(const void *a, const void *b) { // a sequence's end before the next one starting there
  const vxdi_line *x = a, *y = b;
  if (x->addr != y->addr) return (x->addr > y->addr) - (x->addr < y->addr);
  return (int)(y->flags & VXDI_END) - (int)(x->flags & VXDI_END);
}

static int by_sym_addr(const void *a, const void *b) {
  uint64_t x = ((const vxdi_sym *)a)->addr, y = ((const vxdi_sym *)b)->addr;
  return (x > y) - (x < y);
}

// A type reference (a DIE offset + 1, or 0) as a type number (0: void, or unknown).
static uint32_t type_index(const vxd_builder *b, uint32_t ref) {
  if (!ref) return 0;
  uint64_t die = ref - 1, lo = 0, hi = b->ntypes;
  while (lo < hi) {
    uint64_t mid = (lo + hi) / 2;
    if (b->type_dies[mid] < die)
      lo = mid + 1;
    else
      hi = mid;
  }
  return lo < b->ntypes && b->type_dies[lo] == die ? (uint32_t)lo + 1 : 0; // +1: type 0 is void
}

// Where a function's body starts: its first row marked prologue_end, else its
// second statement row, else its start.
static void func_bodies(vxd_builder *b) {
  for (uint64_t i = 0; i < b->nfuncs; i++) {
    vxdi_func *f = &b->funcs[i];
    uint64_t lo = 0, hi = b->nlines;
    while (lo < hi) {
      uint64_t mid = (lo + hi) / 2;
      if (b->lines[mid].addr < f->low)
        lo = mid + 1;
      else
        hi = mid;
    }
    uint64_t second = 0;
    uint32_t stmts = 0;
    for (uint64_t k = lo; k < b->nlines && b->lines[k].addr < f->high; k++) {
      const vxdi_line *l = &b->lines[k];
      // An END at the function's first address ends the sequence before it,
      // which the sort puts first: not this one's (the Rust port's finding,
      // its DWARF 5 on aarch64).
      if ((l->flags & VXDI_END) && l->addr == f->low) continue;
      if (l->flags & VXDI_END) break;
      if (l->flags & VXDI_PROLOGUE_END) {
        f->body = l->addr;
        second = 0;
        break;
      }
      if ((l->flags & VXDI_STMT) && l->addr > f->low && ++stmts == 1) second = l->addr;
    }
    if (second) f->body = second;
  }
}

static uint64_t align8(uint64_t v) { return (v + 7) & ~7ull; }

// Builds the index of elf in arena: its header, or null if the arena is too
// small (it needs a few times the DWARF's size).
[[maybe_unused]] static const vxdi_header *vxd_index(const vxd_elf *elf, vxd_arena *arena) {
  vxd_builder b = {.e = elf};
  b.abbrevs = vxd_alloc(arena, DW_MAX_ABBREVS * sizeof *b.abbrevs);
  b.specs = vxd_alloc(arena, DW_MAX_SPECS * sizeof *b.specs);
  if (!b.abbrevs || !b.specs) return nullptr;
  b.nstr = 1; // offset 0: the empty string
  dw_units(&b);
  dw_symbols(&b);
  uint64_t nfuncs = b.nfuncs, nlines = b.nlines, nvars = b.nvars, ntypes = b.ntypes, nmembers = b.nmembers,
           nsyms = b.nsyms, nfiles = b.nfiles, nstr = b.nstr, nexpr = b.nexpr;
  b.type_dies = vxd_alloc(arena, ntypes * sizeof *b.type_dies + 8);
  // The index, whole: its tables one after another, each 8-aligned.
  uint64_t at = align8(sizeof(vxdi_header));
  vxdi_header layout = {.version = VXDI_VERSION, .machine = elf->machine, .build_id_len = elf->build_id_len};
  vxdi_table *t[] = {&layout.funcs, &layout.lines, &layout.vars,    &layout.types, &layout.members,
                     &layout.syms,  &layout.files, &layout.strings, &layout.exprs};
  uint64_t counts[] = {nfuncs, nlines, nvars, ntypes + 1, nmembers, nsyms, nfiles, nstr, nexpr};
  uint64_t sizes[] = {sizeof(vxdi_func),
                      sizeof(vxdi_line),
                      sizeof(vxdi_var),
                      sizeof(vxdi_type),
                      sizeof(vxdi_member),
                      sizeof(vxdi_sym),
                      sizeof(uint32_t),
                      1,
                      1};
  for (size_t i = 0; i < sizeof counts / sizeof counts[0]; i++) {
    *t[i] = (vxdi_table){.off = at, .count = counts[i]};
    at = align8(at + counts[i] * sizes[i]);
  }
  layout.size = at;
  uint8_t *out = b.type_dies ? vxd_alloc(arena, at) : nullptr;
  if (!out) return nullptr;
  memcpy(out, &layout, sizeof layout);
  b.h = (vxdi_header *)out;
  memcpy(b.h->magic, "VXDI", 4);
  memcpy(b.h->build_id, elf->build_id, elf->build_id_len);
  b.funcs = (vxdi_func *)(out + layout.funcs.off);
  b.lines = (vxdi_line *)(out + layout.lines.off);
  b.vars = (vxdi_var *)(out + layout.vars.off);
  b.types = (vxdi_type *)(out + layout.types.off) + 1; // type 0, void, stays zero
  b.members = (vxdi_member *)(out + layout.members.off);
  b.syms = (vxdi_sym *)(out + layout.syms.off);
  b.files = (uint32_t *)(out + layout.files.off);
  b.strings = (char *)(out + layout.strings.off);
  b.exprs = out + layout.exprs.off;
  // The second pass, filling it.
  b.fill = true;
  b.nfuncs = b.nlines = b.nvars = b.ntypes = b.nmembers = b.nsyms = b.nfiles = b.nexpr = 0;
  b.nstr = 1;
  dw_units(&b);
  dw_symbols(&b);
  if (b.nfuncs != nfuncs || b.nlines != nlines || b.nvars != nvars || b.ntypes != ntypes ||
      b.nmembers != nmembers || b.nsyms != nsyms || b.nfiles != nfiles || b.nstr != nstr || b.nexpr != nexpr)
    return nullptr; // the passes disagree: a bug, not bad input
  // Type references, from DIE offsets to type numbers.
  for (uint64_t i = 0; i < ntypes; i++) b.types[i].target = type_index(&b, b.types[i].target);
  for (uint64_t i = 0; i < nmembers; i++) b.members[i].type = type_index(&b, b.members[i].type);
  for (uint64_t i = 0; i < nvars; i++) b.vars[i].type = type_index(&b, b.vars[i].type);
  for (uint64_t i = 0; i < nfuncs; i++) b.funcs[i].type = type_index(&b, b.funcs[i].type);
  for (uint64_t i = 0; i < ntypes; i++) // members' and enumerators' numbers start at 1 in the index too
    if (b.types[i].kind != VXDI_STRUCT && b.types[i].kind != VXDI_UNION && b.types[i].kind != VXDI_ENUM)
      b.types[i].first = 0;
  vxd_sort(b.funcs, nfuncs, sizeof *b.funcs, by_func_low);
  vxd_sort(b.lines, nlines, sizeof *b.lines, by_line_addr);
  vxd_sort(b.syms, nsyms, sizeof *b.syms, by_sym_addr);
  func_bodies(&b);
  return b.h;
}
