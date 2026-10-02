// eval_fuzz.c: arbitrary text into lib/vx-debug's expression evaluator and
// printer (05 §6.2), over this program's own index, with a target whose
// memory cannot be read and whose registers are unknown: the parser never
// reads outside its input, overflows its stacks, or recurses, and every
// failure names why.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../../lib/vx-debug/eval.c"

struct node {
  int value;
  struct node *next;
};
static struct node chain = {1, nullptr}; // something for names to find
static int table[3] = {1, 2, 3};

static bool read_nothing(void *ctx, uint64_t addr, void *buf, size_t n) {
  (void)ctx, (void)addr, (void)buf, (void)n;
  return false;
}

static vxdi ix;
static bool ready;

static void load(void) {
  ready = true;
  FILE *f = fopen("/proc/self/exe", "rb");
  if (!f) return;
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  uint8_t *image = n > 0 ? malloc((size_t)n) : nullptr;
  size_t got = image ? fread(image, 1, (size_t)n, f) : 0;
  fclose(f);
  static uint8_t memory[256 << 20];
  vxd_arena arena = {.buf = memory, .cap = sizeof memory};
  vxd_elf elf;
  const vxdi_header *h = image && vxd_elf_open(&elf, image, got) ? vxd_index(&elf, &arena) : nullptr;
  if (!h || !vxdi_open(&ix, h, h->size)) ix = (vxdi){};
  // The image stays: the index's strings are copied, but keep it simple.
}

// libFuzzer calls it by name, so it cannot be static.
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size); // NOLINT(misc-use-internal-linkage)

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  if (!ready) load();
  if (!ix.h) return 0;
  char *text = malloc(size + 1);
  if (!text) return 0;
  memcpy(text, data, size);
  text[size] = 0;
  vxd_target t = {.machine = 62, .read = read_nothing};
  vxd_frame f = {.pc = (uint64_t)(uintptr_t)&LLVMFuzzerTestOneInput, .inner = true};
  vxd_session s;
  vxd_begin(&s, &ix, &t, &f);
  vxd_value v;
  char out[256];
  if (vxd_eval(&s, text, &v))
    vxd_format(&s, &v, out, sizeof out);
  else if (!s.err)
    abort(); // a failure always says why
  (void)chain, (void)table;
  free(text);
  return 0;
}
