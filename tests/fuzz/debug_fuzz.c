// debug_fuzz.c: arbitrary bytes as an ELF image into lib/vx-debug (ADR-0017):
// its reader and index builder never read outside the image or the arena,
// and an index it builds opens and answers queries. The seed is a small
// object with DWARF 5.

#include <stdlib.h>
#include <string.h>

#include "../../lib/vx-debug/index.c"

// libFuzzer calls it by name, so it cannot be static.
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size); // NOLINT(misc-use-internal-linkage)

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  uint8_t *image = malloc(size ? size : 1); // its own copy, so ASan sees any read past its end
  if (!image) return 0;
  memcpy(image, data, size);
  static uint8_t memory[8 << 20];
  vxd_arena arena = {.buf = memory, .cap = sizeof memory};
  vxd_elf elf;
  if (vxd_elf_open(&elf, image, size)) {
    const vxdi_header *h = vxd_index(&elf, &arena);
    vxdi ix;
    if (h && vxdi_open(&ix, h, h->size)) {
      for (uint64_t i = 0; i < ix.h->funcs.count; i++) {
        const vxdi_func *f = &ix.funcs[i];
        if (vxdi_func_at(&ix, f->low) == nullptr && f->low < f->high) abort(); // sorted, so found
        vxdi_line_at(&ix, f->body);
        for (uint32_t k = 0; k < f->var_count && f->first_var + k < ix.h->vars.count; k++) {
          const uint8_t *expr;
          uint32_t len;
          vxdi_var_location(&ix, &ix.vars[f->first_var + k], f->body, &expr, &len);
          vxdi_resolve(&ix, ix.vars[f->first_var + k].type, nullptr);
        }
      }
      vxdi_line_addr(&ix, "a.c", 1);
      vxdi_type_named(&ix, "p");
    }
  }
  free(image);
  return 0;
}
