// vx-debug index: questions answered from a vxdi index (debug.h, ADR-0017):
// what function and line an address is in, where a function or a line is,
// what variables a function has at a pc, and what their types are. An index
// read from a file is checked whole when it is opened, so the queries trust
// its offsets.

#pragma once

#include "dwarf.c"

// Opens an index (built, or read from a file): false if it is not one, of
// this version, or a table lies outside it.
[[maybe_unused]] static bool vxdi_open(vxdi *ix, const void *buf, size_t size) {
  const uint8_t *b = buf;
  *ix = (vxdi){};
  if (size < sizeof(vxdi_header) || ((uintptr_t)b & 7)) return false;
  const vxdi_header *h = buf;
  if (memcmp(h->magic, "VXDI", 4) != 0 || h->version != VXDI_VERSION || h->size > size) return false;
  const vxdi_table *t[] = {&h->funcs, &h->lines, &h->vars,    &h->types, &h->members,
                           &h->syms,  &h->files, &h->strings, &h->exprs};
  const uint64_t sizes[] = {sizeof(vxdi_func),
                            sizeof(vxdi_line),
                            sizeof(vxdi_var),
                            sizeof(vxdi_type),
                            sizeof(vxdi_member),
                            sizeof(vxdi_sym),
                            sizeof(uint32_t),
                            1,
                            1};
  for (size_t i = 0; i < sizeof sizes / sizeof sizes[0]; i++)
    if (t[i]->off & 7 || t[i]->off > h->size || t[i]->count > (h->size - t[i]->off) / sizes[i]) return false;
  if (!h->types.count || !h->strings.count || b[h->strings.off + h->strings.count - 1] != 0) return false;
  *ix = (vxdi){.base = b,
               .h = h,
               .funcs = (const vxdi_func *)(b + h->funcs.off),
               .lines = (const vxdi_line *)(b + h->lines.off),
               .vars = (const vxdi_var *)(b + h->vars.off),
               .types = (const vxdi_type *)(b + h->types.off),
               .members = (const vxdi_member *)(b + h->members.off),
               .syms = (const vxdi_sym *)(b + h->syms.off),
               .files = (const uint32_t *)(b + h->files.off),
               .strings = (const char *)(b + h->strings.off),
               .exprs = b + h->exprs.off};
  return true;
}

// A string of the index ("" for one out of range).
[[maybe_unused]] static const char *vxdi_str(const vxdi *ix, uint32_t off) {
  return off < ix->h->strings.count ? ix->strings + off : "";
}

[[maybe_unused]] static const char *vxdi_file(const vxdi *ix, uint32_t file) {
  return file < ix->h->files.count ? vxdi_str(ix, ix->files[file]) : "";
}

[[maybe_unused]] static const vxdi_type *vxdi_type_of(const vxdi *ix, uint32_t type) {
  return type < ix->h->types.count ? &ix->types[type] : &ix->types[0];
}

// The function pc is in, or null.
[[maybe_unused]] static const vxdi_func *vxdi_func_at(const vxdi *ix, uint64_t pc) {
  uint64_t lo = 0, hi = ix->h->funcs.count;
  while (lo < hi) { // the last that starts at or before pc
    uint64_t mid = (lo + hi) / 2;
    if (ix->funcs[mid].low <= pc)
      lo = mid + 1;
    else
      hi = mid;
  }
  return lo && pc < ix->funcs[lo - 1].high ? &ix->funcs[lo - 1] : nullptr;
}

// The ELF symbol pc is in (for code with no DWARF, such as musl), or null.
[[maybe_unused]] static const vxdi_sym *vxdi_sym_at(const vxdi *ix, uint64_t pc) {
  uint64_t lo = 0, hi = ix->h->syms.count;
  while (lo < hi) {
    uint64_t mid = (lo + hi) / 2;
    if (ix->syms[mid].addr <= pc)
      lo = mid + 1;
    else
      hi = mid;
  }
  if (!lo) return nullptr;
  const vxdi_sym *s = &ix->syms[lo - 1];
  return pc < s->addr + (s->size ? s->size : 1) ? s : nullptr;
}

// The line row pc is in: the last row at or before it, unless that ends a sequence.
[[maybe_unused]] static const vxdi_line *vxdi_line_at(const vxdi *ix, uint64_t pc) {
  uint64_t lo = 0, hi = ix->h->lines.count;
  while (lo < hi) {
    uint64_t mid = (lo + hi) / 2;
    if (ix->lines[mid].addr <= pc)
      lo = mid + 1;
    else
      hi = mid;
  }
  if (!lo) return nullptr;
  const vxdi_line *l = &ix->lines[lo - 1];
  return l->flags & VXDI_END ? nullptr : l;
}

static bool vxdi_eq(const char *a, const char *b) {
  while (*a && *a == *b) a++, b++;
  return *a == *b;
}

// The function named name, or null.
[[maybe_unused]] static const vxdi_func *vxdi_func_named(const vxdi *ix, const char *name) {
  for (uint64_t i = 0; i < ix->h->funcs.count; i++)
    if (vxdi_eq(vxdi_str(ix, ix->funcs[i].name), name)) return &ix->funcs[i];
  return nullptr;
}

// Whether path ends with the path suffix, at a component boundary.
static bool vxdi_path_ends(const char *path, const char *suffix) {
  size_t pl = 0, sl = 0;
  while (path[pl]) pl++;
  while (suffix[sl]) sl++;
  if (sl > pl) return false;
  for (size_t i = 0; i < sl; i++)
    if (path[pl - sl + i] != suffix[i]) return false;
  return sl == pl || path[pl - sl - 1] == '/';
}

// The lowest address of a statement on line `line` of a file whose path ends
// with `file`; 0 if there is none.
[[maybe_unused]] static uint64_t vxdi_line_addr(const vxdi *ix, const char *file, uint32_t line) {
  uint64_t best = 0;
  for (uint64_t i = 0; i < ix->h->lines.count; i++) {
    const vxdi_line *l = &ix->lines[i];
    if (l->line != line || !(l->flags & VXDI_STMT) || (l->flags & VXDI_END)) continue;
    if ((!best || l->addr < best) && vxdi_path_ends(vxdi_file(ix, l->file), file)) best = l->addr;
  }
  return best;
}

// The global (or constant) named name, or null.
[[maybe_unused]] static const vxdi_var *vxdi_global_named(const vxdi *ix, const char *name) {
  for (uint64_t i = 0; i < ix->h->vars.count; i++)
    if (ix->vars[i].kind == VXDI_GLOBAL && vxdi_eq(vxdi_str(ix, ix->vars[i].name), name)) return &ix->vars[i];
  return nullptr;
}

// The variable of f named name in scope at pc: the innermost block's first.
[[maybe_unused]] static const vxdi_var *vxdi_local_named(const vxdi *ix, const vxdi_func *f, uint64_t pc,
                                                         const char *name) {
  const vxdi_var *best = nullptr;
  for (uint32_t i = 0; f && i < f->var_count && f->first_var + i < ix->h->vars.count; i++) {
    const vxdi_var *v = &ix->vars[f->first_var + i];
    bool in_scope = !v->scope_high || (pc >= v->scope_low && pc < v->scope_high);
    if (!in_scope || !vxdi_eq(vxdi_str(ix, v->name), name)) continue;
    if (!best || (v->scope_high &&
                  (!best->scope_high || v->scope_high - v->scope_low < best->scope_high - best->scope_low)))
      best = v;
  }
  return best;
}

// A type with its typedefs and qualifiers looked through.
[[maybe_unused]] static const vxdi_type *vxdi_resolve(const vxdi *ix, uint32_t type, uint32_t *out) {
  for (int guard = 0; guard < 32; guard++) {
    const vxdi_type *t = vxdi_type_of(ix, type);
    if (t->kind != VXDI_TYPEDEF && t->kind != VXDI_CONST_T && t->kind != VXDI_VOLATILE &&
        t->kind != VXDI_RESTRICT && t->kind != VXDI_ATOMIC) {
      if (out) *out = type;
      return t;
    }
    type = t->target;
  }
  if (out) *out = 0;
  return &ix->types[0];
}

// The named type (a typedef, a base type, or a struct, union or enum tag), or 0.
[[maybe_unused]] static uint32_t vxdi_type_named(const vxdi *ix, const char *name) {
  for (uint64_t i = 1; i < ix->h->types.count; i++)
    if (ix->types[i].name && vxdi_eq(vxdi_str(ix, ix->types[i].name), name)) return (uint32_t)i;
  return 0;
}

// A variable's location at pc: its expression (from its list, if it has one); false if none applies.
[[maybe_unused]] static bool vxdi_var_location(const vxdi *ix, const vxdi_var *v, uint64_t pc,
                                               const uint8_t **expr, uint32_t *len) {
  if (v->flags & VXDI_CONST) return false;
  if (!(v->flags & VXDI_LOCLIST)) {
    if (v->loc > ix->h->exprs.count || v->loc_len > ix->h->exprs.count - v->loc) return false;
    *expr = ix->exprs + v->loc, *len = v->loc_len;
    return v->loc_len > 0;
  }
  for (uint64_t at = v->loc; at + 20 <= ix->h->exprs.count;) {
    uint64_t lo, hi;
    uint32_t n;
    memcpy(&lo, ix->exprs + at, 8), memcpy(&hi, ix->exprs + at + 8, 8), memcpy(&n, ix->exprs + at + 16, 4);
    if (!lo && !hi && !n) return false;
    if (n > ix->h->exprs.count - at - 20) return false;
    if (pc >= lo && pc < hi) {
      *expr = ix->exprs + at + 20, *len = n;
      return n > 0;
    }
    at += 20 + n;
  }
  return false;
}
