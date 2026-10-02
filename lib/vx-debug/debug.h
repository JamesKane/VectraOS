// vx-debug: the debugger's symbols (docs/05 §4, ADR-0017). An ELF image's
// DWARF 5 and symbol table become a vxdi index, one flat buffer whose every
// reference is an offset from its start, so it can be written to a file and
// mapped as it is; queries answer from it alone.
//
// Freestanding: the builder works in an arena the caller gives it and makes
// no system call, so dbg, host tools and the tests share it. Every offset read
// from the image is checked against its section: a crash directory, and the
// binaries it names, may come from anywhere.

#pragma once

#include "../../abi/vx/abi.h"
#if __STDC_HOSTED__
#include <string.h> // host tests
#else
#include "../vx-mem/mem.h"
#endif

typedef struct vxd_bytes {
  const uint8_t *p;
  size_t n;
} vxd_bytes;

// --- The ELF image (elf.c) ---

enum vxd_section : uint32_t {
  VXD_INFO,
  VXD_ABBREV,
  VXD_LINE,
  VXD_STR,
  VXD_LINE_STR,
  VXD_STR_OFFSETS,
  VXD_ADDR,
  VXD_RNGLISTS,
  VXD_LOCLISTS,
  VXD_SYMTAB,
  VXD_STRTAB,
  VXD_SECTIONS
};

typedef struct vxd_elf {
  uint16_t machine; // EM_X86_64 (62), EM_AARCH64 (183)
  vxd_bytes sec[VXD_SECTIONS];
  uint8_t build_id[32];
  uint32_t build_id_len;
} vxd_elf;

// --- The index (ADR-0017) ---

static constexpr uint32_t VXDI_VERSION = 1;

typedef struct vxdi_table {
  uint64_t off, count;
} vxdi_table;

typedef struct vxdi_header {
  char magic[4]; // "VXDI"
  uint32_t version;
  uint32_t machine;
  uint32_t build_id_len;
  uint8_t build_id[32];
  uint64_t size; // the whole index, in bytes
  vxdi_table funcs, lines, vars, types, members, syms, files, strings, exprs;
} vxdi_header;

typedef struct vxdi_func { // sorted by low
  uint64_t low, high;
  uint64_t body;       // past the prologue: where a breakpoint on it goes
  uint32_t name, file; // strings; files
  uint32_t line, type; // its declaration's line; its return type
  uint32_t first_var, var_count;
  uint32_t frame_base, frame_base_len; // an expression, in exprs
} vxdi_func;

enum vxdi_line_flags : uint32_t { VXDI_STMT = 1, VXDI_PROLOGUE_END = 2, VXDI_END = 4 };

typedef struct vxdi_line { // sorted by addr; an END row ends a sequence there
  uint64_t addr;
  uint32_t file, line;
  uint32_t flags, reserved;
} vxdi_line;

enum vxdi_var_kind : uint32_t { VXDI_PARAM = 1, VXDI_LOCAL, VXDI_GLOBAL };
enum vxdi_var_flags : uint32_t {
  VXDI_LOCLIST = 1,
  VXDI_CONST = 2
}; // CONST: loc_len is unused, loc the value

typedef struct vxdi_var {
  uint32_t name, type;
  uint32_t loc,
      loc_len; // an expression in exprs, or (LOCLIST) a list: {lo, hi, len, bytes}..., ended by 0, 0, 0
  uint64_t scope_low, scope_high; // a local's lexical block; 0, 0 for the whole function
  uint32_t kind, flags;
  int64_t value; // CONST: the value (DW_AT_const_value)
} vxdi_var;

enum vxdi_type_kind : uint32_t {
  VXDI_VOID,
  VXDI_BASE,
  VXDI_POINTER,
  VXDI_CONST_T,
  VXDI_VOLATILE,
  VXDI_RESTRICT,
  VXDI_ATOMIC,
  VXDI_TYPEDEF,
  VXDI_STRUCT,
  VXDI_UNION,
  VXDI_ARRAY,
  VXDI_ENUM,
  VXDI_FUNC,
};

typedef struct vxdi_type { // type 0 is void
  uint32_t kind, name;
  uint64_t size;
  uint32_t target;       // what it points at, qualifies, names, or holds
  uint32_t first, count; // members or enumerators; an array's elements (count; 0 if unknown)
  uint32_t encoding;     // a base type's DW_ATE_*
} vxdi_type;

typedef struct vxdi_member { // a member (offset: its byte offset), or an enumerator (offset: its value)
  uint32_t name, type;
  int64_t offset;
} vxdi_member;

typedef struct vxdi_sym { // sorted by addr
  uint64_t addr, size;
  uint32_t name, func; // func: a function (STT_FUNC), else data
} vxdi_sym;

typedef struct vxdi {
  const uint8_t *base;
  const vxdi_header *h;
  const vxdi_func *funcs;
  const vxdi_line *lines;
  const vxdi_var *vars;
  const vxdi_type *types;
  const vxdi_member *members;
  const vxdi_sym *syms;
  const uint32_t *files; // strings
  const char *strings;
  const uint8_t *exprs;
} vxdi;

// An arena: the builder takes what it needs from it, from the front.
typedef struct vxd_arena {
  uint8_t *buf;
  size_t cap, used;
} vxd_arena;

[[maybe_unused]] static void *vxd_alloc(vxd_arena *a, size_t n) {
  size_t at = (a->used + 7) & ~(size_t)7;
  if (at > a->cap || n > a->cap - at) return nullptr;
  a->used = at + n;
  memset(a->buf + at, 0, n);
  return a->buf + at;
}
