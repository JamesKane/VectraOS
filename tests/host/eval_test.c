// eval_test.c: lib/vx-debug's unwinder, locations, expression evaluator and
// printer (05 §6.2), on this test's own process: from inside a chain of
// calls it unwinds its own stack by the frame pointers, reads each frame's
// parameters and locals through their DWARF locations, and evaluates C
// expressions over its globals, comparing with what it knows. The calls are
// optnone, so their variables live in their frames; host tests are not PIE,
// so the index's addresses are the process's.

#include <stdlib.h>
#include <string.h>

#include "check.h"
#include "../../lib/vx-debug/eval.c"

struct node {
  int value;
  struct node *next;
  const char *label;
};
static struct node second = {2, nullptr, "two"};
static struct node first = {1, &second, "one"};
static int table[5] = {10, 20, 30, 40, 50};
static double ratio = 1.5;
static bool flag = true;
static char letter = 'x';
enum mode { OFF = 0, ON = 1 };
static enum mode mode = ON;

static vxdi ix;

// The target is this process: its memory read a byte at a time, outside
// ASan's view (a debugger reads what the program's own checks forbid it).
[[gnu::no_sanitize("address")]] static bool read_self(void *ctx, uint64_t addr, void *buf, size_t n) {
  (void)ctx;
  if (addr < 4096) return false;
  const volatile uint8_t *p = (const volatile uint8_t *)(uintptr_t)addr;
  for (size_t i = 0; i < n; i++) ((uint8_t *)buf)[i] = p[i];
  return true;
}

static vxd_target self = {.machine = 62, .read = read_self};

// Evaluates and prints text at frame f, compared with want.
static void expect(const vxd_frame *f, const char *text, const char *want) {
  vxd_session s;
  vxd_begin(&s, &ix, &self, f);
  vxd_value v;
  char out[256] = {};
  bool ok = vxd_eval(&s, text, &v);
  if (ok) vxd_format(&s, &v, out, sizeof out);
  bool same = ok ? strcmp(out, want) == 0 : strcmp(s.err ? s.err : "", want) == 0;
  if (!same) fprintf(stderr, "eval %s: got %s (wanted %s)\n", text, ok ? out : s.err, want);
  CHECK(same);
}

// "0x" and a hex number: what a pointer prints as.
static const char *hex(const void *p) {
  static char buf[32];
  snprintf(buf, sizeof buf, "0x%llx", (unsigned long long)(uintptr_t)p);
  return buf;
}

// Called from level3, with its frame address: the innermost frame is level3's.
[[gnu::noinline, clang::optnone]] static void inspect(uint64_t fp) {
  vxd_frame frames[16];
  const vxdi_func *l3 = vxdi_func_named(&ix, "level3");
  CHECK(l3 != nullptr);
  if (!l3) return;
  uint32_t n = vxd_unwind(&ix, &self, l3->body, 0, fp, frames, 16);
  const char *names[] = {"level3", "level2", "level1", "main"};
  CHECK(n >= 4);
  for (uint32_t i = 0; i < 4 && i < n; i++) {
    const vxdi_func *fn = vxdi_func_at(&ix, vxd_frame_lookup_pc(&frames[i]));
    bool named = fn && strcmp(vxdi_str(&ix, fn->name), names[i]) == 0;
    if (!named)
      fprintf(stderr, "frame %u: %s (wanted %s)\n", i, fn ? vxdi_str(&ix, fn->name) : "?", names[i]);
    CHECK(named);
    const vxdi_line *l = vxdi_line_at(&ix, vxd_frame_lookup_pc(&frames[i]));
    CHECK(l && vxdi_path_ends(vxdi_file(&ix, l->file), "eval_test.c"));
  }
  if (n < 4) return;
  // Each frame's variables, through its frame base.
  expect(&frames[0], "c", "11");
  expect(&frames[1], "b", "10");
  expect(&frames[1], "local", "11");
  expect(&frames[1], "msg[1]", "101 'e'");
  expect(&frames[1], "*msg", "104 'h'");
  expect(&frames[2], "a", "5");
  expect(&frames[2], "doubled * 2 + a", "25");
  expect(&frames[2], "local", "no such variable"); // level2's, not level1's
  // Globals, from any frame.
  const vxd_frame *f = &frames[0];
  expect(f, "first.value", "1");
  expect(f, "first.next->value", "2");
  expect(f, "first.next->next", "0x0");
  char want[128];
  snprintf(want, sizeof want, "%s \"two\"", hex(second.label));
  expect(f, "first.next->label", want);
  char next[32];
  snprintf(next, sizeof next, "%s", hex(&second)); // hex's buffer is reused
  snprintf(want, sizeof want, "{value = 1, next = %s, label = %s \"one\"}", next, hex(first.label));
  expect(f, "first", want);
  expect(f, "(*first.next).value + 40", "42");
  expect(f, "table[2]", "30");
  expect(f, "table", "[10, 20, 30, 40, 50]");
  expect(f, "*(&table[1])", "20");
  expect(f, "&table[3] - &table[1]", "2");
  expect(f, "*(table + 4)", "50");
  expect(f, "sizeof(table)", "20");
  expect(f, "sizeof table[0]", "4");
  expect(f, "sizeof(struct node)", "24");
  snprintf(want, sizeof want, "%s", hex(&table[0]));
  expect(f, "&table[0]", want);
  expect(f, "letter", "120 'x'");
  expect(f, "(char)65", "65 'A'");
  expect(f, "flag", "true");
  expect(f, "ratio", "1.5");
  expect(f, "mode", "ON");
  expect(f, "ON + 1", "2");
  expect(f, "-3 * 4 + 20 / (2 + 3)", "-8");
  expect(f, "7 % 4 == 3", "1");
  expect(f, "1 << 4 | 1", "17");
  expect(f, "!0 && 5 > 3", "1");
  expect(f, "0x10 + 'a'", "113");
  expect(f, "~0 & 0xff", "255");
  expect(f, "(unsigned char)300", "44 ','");
  snprintf(want, sizeof want, "%llu", (unsigned long long)fp);
  expect(f, "$fp", want);
  // And what it refuses.
  expect(f, "nosuch", "no such variable");
  expect(f, "1 +", "expected a value");
  expect(f, "first.nope", "no such member");
  expect(f, "(1 + 2", "unbalanced brackets");
  expect(f, "1 / 0", "division by zero");
  expect(f, "9223372036854775808 / -1", "-9223372036854775808"); // wraps, as C's would; not a trap
  expect(f, "9223372036854775808 % -1", "0");
  expect(f, "*table[0]", "not a pointer");
  expect(f, "ratio + 1", "floating-point arithmetic is not supported");
  expect(f, "first + 1", "not a number or pointer");
  expect(f, "$nope", "no such register");
}

[[gnu::noinline, clang::optnone]] static int level3(int c) {
  inspect((uint64_t)(uintptr_t)__builtin_frame_address(0));
  return c;
}

[[gnu::noinline, clang::optnone]] static int level2(int b, const char *msg) {
  int local = b + 1;
  return level3(local) + (int)msg[0];
}

[[gnu::noinline, clang::optnone]] static int level1(int a) {
  int doubled = a * 2;
  return level2(doubled, "hello");
}

static void *read_all(const char *path, size_t *size) {
  FILE *f = fopen(path, "rb");
  if (!f) return nullptr;
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  uint8_t *buf = n > 0 ? malloc((size_t)n) : nullptr;
  *size = buf ? fread(buf, 1, (size_t)n, f) : 0;
  fclose(f);
  return buf;
}

int main(void) {
  size_t size = 0;
  void *image = read_all("/proc/self/exe", &size);
  vxd_elf elf;
  static uint8_t memory[256 << 20];
  vxd_arena arena = {.buf = memory, .cap = sizeof memory};
  const vxdi_header *h = image && vxd_elf_open(&elf, image, size) ? vxd_index(&elf, &arena) : nullptr;
  CHECK(h && vxdi_open(&ix, h, h->size));
  if (!h) return check_result();
  const vxdi_func *m = vxdi_func_named(&ix, "main");
  CHECK(m && (uint64_t)(uintptr_t)&main == m->low); // not PIE: the index's addresses are the process's
  CHECK(level1(5) == 11 + 'h');
  (void)ratio, (void)flag, (void)letter, (void)mode, (void)table, (void)first;
  free(image);
  return check_result();
}
