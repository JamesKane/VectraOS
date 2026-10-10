// text_fuzz.c: lib/vx-text (M7 step 7g1a). Two kinds of input, by the first
// byte. Even: sam. The bytes up to a NUL are the text, the rest commands, run
// against a dot of every selection the next bytes make; whatever they do, a
// failure leaves sam's words, dot stays sorted inside the text, the summaries
// count what reading finds, and undoing every group gives back the
// original byte for byte. Odd: edits, undos and redos, two bytes a step,
// against a plain array and the states saved at each group.

#include <stdlib.h>
#include <string.h>

#include "../../lib/vx-text/text.c"

// libFuzzer calls it by name, so it cannot be static.
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size); // NOLINT(misc-use-internal-linkage)

static void print(void *arg, const char *p, size_t n) { (void)arg, (void)p, (void)n; }

static bool shell(void *arg, char kind, vx_str command, vx_str in, vx_str *out) {
  (void)arg, (void)kind;
  *out = command.len % 2 ? in : command; // something of either
  return command.len % 3 != 0;
}

static const vx_text_io io = {.print = print, .shell = shell};

static char *read_all(vx_text *t) {
  uint64_t len = vx_text_len(t);
  char *p = malloc(len + 1);
  if (vx_text_read(t, 0, p, len) != len) abort();
  p[len] = 0;
  uint64_t lines = 0, runes = 0;
  for (uint64_t i = 0; i < len; i++) lines += p[i] == '\n', runes += ((unsigned char)p[i] & 0xc0) != 0x80;
  if (lines != vx_text_lines(t) || runes != vx_text_runes(t)) abort();
  return p;
}

static void fuzz_sam(const uint8_t *data, size_t size) {
  const uint8_t *nul = memchr(data, 0, size);
  size_t tlen = nul ? (size_t)(nul - data) : size / 2;
  const char *text = (const char *)data;
  const uint8_t *rest = data + tlen + (nul != nullptr);
  size_t rlen = size - (size_t)(rest - data);
  vx_text *t = vx_text_new(text, tlen);
  if (!t) abort();
  vx_text_dot dot = {};
  vx_text_dot_set(&dot, 0, 0);
  if (rlen >= 2) { // the first two bytes: a selection
    vx_text_dot_set(&dot, rest[0] % (tlen + 1), rest[1] % (tlen + 1));
    rest += 2, rlen -= 2;
  }
  // At most 6 lines: each line can insert text in every selection, and the
  // next runs in every one again, so lines grow the text exponentially.
  for (size_t i = 0, lines = 0; i < rlen; i++)
    if (rest[i] == '\n' && ++lines == 6) rlen = i + 1;
  char err[64];
  bool ok = vx_text_run(t, (vx_str){(const char *)rest, rlen}, &dot, &io, VX_STR("fuzz"), err, sizeof err);
  if (!ok && err[0] == 0) abort();
  uint64_t len = vx_text_len(t);
  if (dot.n == 0) abort();
  for (size_t i = 0; i < dot.n; i++) {
    if (dot.r[i].p0 > dot.r[i].p1 || dot.r[i].p1 > len) abort();
    if (i && dot.r[i].p0 < dot.r[i - 1].p0) abort();
  }
  free(read_all(t));
  while (vx_text_undo(t));
  char *back = read_all(t);
  if (vx_text_len(t) != tlen || memcmp(back, text, tlen) != 0) abort();
  free(back);
  vx_text_dot_free(&dot);
  vx_text_free(t);
}

static void fuzz_edits(const uint8_t *data, size_t size) {
  enum { MAXG = 2048 };
  static char *state[MAXG];
  static uint32_t parent[MAXG], last[MAXG];
  vx_text *t = vx_text_new("seed\ntext\n", 10);
  state[0] = read_all(t);
  last[0] = 0;
  uint32_t head = 0, ngroups = 1;
  char ins[16];
  for (size_t i = 0; i + 1 < size && ngroups < MAXG; i += 2) {
    uint8_t op = data[i], arg = data[i + 1];
    uint64_t len = vx_text_len(t);
    if (op % 8 == 0) {
      if (vx_text_undo(t) != (head != 0)) abort();
      if (head) last[parent[head]] = head, head = parent[head];
    } else if (op % 8 == 1) {
      if (vx_text_redo(t) != (last[head] != 0)) abort();
      if (last[head]) head = last[head];
    } else {
      uint64_t p0 = arg % (len + 1), p1 = p0 + (op >> 3) % (len - p0 + 1) % 9;
      uint64_t n = (op >> 5) % 5;
      for (uint64_t k = 0; k < n; k++) ins[k] = "a\n\xc3\xa9"[(arg + k) % 4];
      vx_text_replace(t, p0, p1, ins, n);
      if (vx_text_head(t) != head) {
        uint32_t g = vx_text_head(t);
        if (g != ngroups) abort();
        parent[g] = head, last[head] = g, last[g] = 0;
        state[g] = read_all(t);
        head = g, ngroups++;
      }
    }
    char *now = read_all(t);
    if (strlen(state[head]) != vx_text_len(t) || memcmp(now, state[head], vx_text_len(t)) != 0) abort();
    free(now);
  }
  for (uint32_t i = 0; i < ngroups; i++) free(state[i]);
  vx_text_free(t);
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  if (size == 0) return 0;
  if (data[0] % 2 == 0)
    fuzz_sam(data + 1, size - 1);
  else
    fuzz_edits(data + 1, size - 1);
  return 0;
}
