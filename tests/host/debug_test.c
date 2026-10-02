// debug_test.c: lib/vx-debug (ADR-0017), on this test's own executable: its
// DWARF 5 and symbol table become an index, and the index says where its
// functions, lines, variables and types are, which the test knows from the
// inside (&fixture_add, __LINE__, offsetof). The executable is PIE: its
// addresses are the index's plus the bias it was loaded at. A damaged index
// is refused.

#include <stddef.h>
#include <stdlib.h>

#include "check.h"
#include "../../lib/vx-debug/index.c"

struct point {
  int x;
  long y;
  char name[8];
};
enum color { RED = 0, GREEN = 5 };

static struct point origin = {1, 2, "o"};
static enum color hue = GREEN;
static int marker_line;
enum { FIXTURE_LINE = __LINE__ + 2 }; // fixture_add's

[[gnu::noinline]] static int fixture_add(int a, int b) {
  int sum = a + b;
  marker_line = __LINE__;
  return sum + (int)hue;
}

static void *read_all(const char *path, size_t *size) {
  FILE *f = fopen(path, "rb");
  if (!f) return nullptr;
  size_t cap = 1 << 20, len = 0;
  uint8_t *buf = malloc(cap);
  size_t n;
  while (buf && (n = fread(buf + len, 1, cap - len, f)) > 0) {
    len += n;
    if (len < cap) continue;
    uint8_t *more = realloc(buf, cap *= 2);
    if (!more) free(buf);
    buf = more;
  }
  fclose(f);
  *size = len;
  return buf;
}

int main(void) {
  CHECK(fixture_add(2, 3) == 10);
  size_t size = 0;
  void *image = read_all("/proc/self/exe", &size);
  CHECK(image != nullptr);
  if (!image) return check_result();
  vxd_elf elf;
  CHECK(vxd_elf_open(&elf, image, size) && elf.machine == 62 && elf.sec[VXD_INFO].n &&
        elf.build_id_len == 20);
  static uint8_t memory[256 << 20];
  vxd_arena arena = {.buf = memory, .cap = sizeof memory};
  const vxdi_header *h = vxd_index(&elf, &arena);
  CHECK(h != nullptr);
  if (!h) return check_result();
  vxdi ix;
  CHECK(vxdi_open(&ix, h, h->size) && memcmp(h->build_id, elf.build_id, 20) == 0);

  // The function, and the bias the executable was loaded at.
  const vxdi_func *f = vxdi_func_named(&ix, "fixture_add");
  CHECK(f != nullptr);
  if (!f) return check_result();
  uint64_t bias = (uint64_t)(uintptr_t)&fixture_add - f->low;
  CHECK(vxdi_func_at(&ix, f->low) == f && vxdi_func_at(&ix, f->high - 1) == f &&
        vxdi_func_at(&ix, f->high) != f);
  CHECK(f->body > f->low && f->body < f->high); // past the prologue
  CHECK(vxdi_path_ends(vxdi_file(&ix, f->file), "tests/host/debug_test.c") && f->line == FIXTURE_LINE);
  const vxdi_line *l = vxdi_line_at(&ix, f->body);
  CHECK(l && l->line >= FIXTURE_LINE && l->line <= FIXTURE_LINE + 2 &&
        vxdi_path_ends(vxdi_file(&ix, l->file), "debug_test.c"));
  uint64_t at = vxdi_line_addr(&ix, "host/debug_test.c", (uint32_t)marker_line);
  CHECK(at >= f->low && at < f->high);
  CHECK(vxdi_line_addr(&ix, "no_such_file.c", 1) == 0);

  // Its parameters and local, and their type.
  const vxdi_var *a = vxdi_local_named(&ix, f, f->body, "a"), *sum = vxdi_local_named(&ix, f, f->body, "sum");
  CHECK(a && a->kind == VXDI_PARAM && sum && sum->kind == VXDI_LOCAL &&
        !vxdi_local_named(&ix, f, f->body, "zz"));
  const vxdi_type *int_t = a ? vxdi_resolve(&ix, a->type, nullptr) : nullptr;
  CHECK(int_t && int_t->kind == VXDI_BASE && int_t->size == 4 && vxdi_eq(vxdi_str(&ix, int_t->name), "int"));

  // A global struct: its members, and one an array.
  const vxdi_var *g = vxdi_global_named(&ix, "origin");
  CHECK(g && g->kind == VXDI_GLOBAL);
  const uint8_t *expr = nullptr;
  uint32_t len = 0;
  uint64_t addr = 0;
  CHECK(g && vxdi_var_location(&ix, g, 0, &expr, &len) && len == 9 && expr[0] == 0x03); // DW_OP_addr
  if (len == 9) memcpy(&addr, expr + 1, 8);
  CHECK(addr + bias == (uint64_t)(uintptr_t)&origin);
  uint32_t pt = 0;
  const vxdi_type *st = g ? vxdi_resolve(&ix, g->type, &pt) : nullptr;
  CHECK(st && st->kind == VXDI_STRUCT && st->size == sizeof(struct point) && st->count == 3);
  if (st && st->count == 3) {
    const vxdi_member *m = &ix.members[st->first];
    CHECK(vxdi_eq(vxdi_str(&ix, m[0].name), "x") && m[0].offset == offsetof(struct point, x));
    CHECK(vxdi_eq(vxdi_str(&ix, m[1].name), "y") && m[1].offset == offsetof(struct point, y));
    CHECK(vxdi_eq(vxdi_str(&ix, m[2].name), "name") && m[2].offset == offsetof(struct point, name));
    const vxdi_type *arr = vxdi_resolve(&ix, m[2].type, nullptr);
    CHECK(arr->kind == VXDI_ARRAY && arr->count == 8 && vxdi_resolve(&ix, arr->target, nullptr)->size == 1);
  }
  CHECK(vxdi_type_named(&ix, "point") == pt);

  // An enum, its enumerators and their values.
  const vxdi_type *en = vxdi_type_of(&ix, vxdi_type_named(&ix, "color"));
  CHECK(en->kind == VXDI_ENUM && en->count == 2);
  if (en->count == 2) {
    CHECK(vxdi_eq(vxdi_str(&ix, ix.members[en->first].name), "RED") && ix.members[en->first].offset == 0);
    CHECK(vxdi_eq(vxdi_str(&ix, ix.members[en->first + 1].name), "GREEN") &&
          ix.members[en->first + 1].offset == 5);
  }

  // The symbol table, for code with no DWARF.
  const vxdi_sym *s = vxdi_sym_at(&ix, (uint64_t)(uintptr_t)&main - bias);
  CHECK(s && s->func && vxdi_eq(vxdi_str(&ix, s->name), "main"));

  // An index from a file that is not one, or is cut short, is refused.
  vxdi bad;
  CHECK(!vxdi_open(&bad, h, sizeof(vxdi_header) - 1) && !vxdi_open(&bad, h, h->size - 8));
  static uint8_t junk[4096];
  CHECK(!vxdi_open(&bad, junk, sizeof junk));
  // An ELF that is not one, or is cut short, gives an empty index, never a crash.
  CHECK(!vxd_elf_open(&elf, junk, sizeof junk));
  CHECK(vxd_elf_open(&elf, image, 4096) ? vxd_index(&elf, &arena) != nullptr : true);
  free(image);
  return check_result();
}
