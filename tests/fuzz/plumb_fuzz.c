// plumb_fuzz.c: lib/vx-plumb (M7 step 7g3a), what the plumber parses from
// any program: messages written to send, and rules written to the rules
// file. By the first byte. Even: the rest is a message; one that unpacks
// packs to what unpacks to the same again. Odd: the bytes to a NUL are
// rules, written in pieces the next bytes size, the rest a message's data
// matched against them with a click, its action expanded; the listing read
// back as rules too. Nothing may crash or leak.

#include <stdlib.h>
#include <string.h>

#include "../../lib/vx-plumb/plumb.c"

// libFuzzer calls it by name, so it cannot be static.
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size); // NOLINT(misc-use-internal-linkage)

static int kind(void *ctx, const char *path) {
  (void)ctx;
  static const int kinds[] = {VX_PLUMB_FILE, VX_PLUMB_DIR, VX_PLUMB_NONE}; // by the name's length
  return kinds[strlen(path) % 3];
}

static char *read_file(void *ctx, const char *path, size_t *n) {
  (void)ctx;
  if (strcmp(path, "/lib/plumb/inc") != 0) return nullptr; // and "inc" includes itself, deep
  static const char text[] = "x=1\ninclude inc\n";
  *n = sizeof text - 1;
  char *p = vx_plumb_alloc(*n + 1);
  memcpy(p, text, *n + 1);
  return p;
}

static const vx_plumb_fs FS = {.kind = kind, .read = read_file};

static bool same(const vx_plumb_msg *a, const vx_plumb_msg *b) {
  if (strcmp(a->src, b->src) != 0 || strcmp(a->dst, b->dst) != 0 || strcmp(a->wdir, b->wdir) != 0 ||
      strcmp(a->type, b->type) != 0)
    return false;
  return a->ndata == b->ndata && memcmp(a->data, b->data, a->ndata) == 0;
}

static void fuzz_message(const uint8_t *data, size_t size) {
  size_t more = 0;
  vx_plumb_msg *m = vx_plumb_unpack((const char *)data, size, &more);
  if (!m) return;
  size_t n = 0;
  char *packed = vx_plumb_pack(m, &n);
  vx_plumb_msg *again = packed ? vx_plumb_unpack(packed, n, nullptr) : nullptr;
  if (!again || !same(m, again)) abort();
  char *a = vx_plumb_pack_attr(m->attr), *b = vx_plumb_pack_attr(again->attr);
  if ((a == nullptr) != (b == nullptr) || (a && strcmp(a, b) != 0)) abort();
  vx_plumb_dealloc(a), vx_plumb_dealloc(b), vx_plumb_dealloc(packed);
  vx_plumb_free(again), vx_plumb_free(m);
}

static void fuzz_rules(const uint8_t *data, size_t size) {
  const uint8_t *nul = memchr(data, 0, size);
  size_t rlen = nul ? (size_t)(nul - data) : size;
  const uint8_t *rest = nul ? nul + 1 : data + size;
  size_t nrest = (size_t)(data + size - rest);
  vx_plumb_rules *r = vx_plumb_rules_new(&FS);
  // Written in pieces, as writes to the rules file come.
  size_t at = 0, k = 0;
  while (at < rlen) {
    size_t piece = 1 + (nrest ? rest[k++ % nrest] : rlen) % 64;
    if (piece > rlen - at) piece = rlen - at;
    vx_plumb_rules_write(r, (const char *)data + at, piece, false);
    at += piece;
  }
  vx_plumb_rules_write(r, nullptr, 0, true);
  // The rest as a message's data, a click into it.
  vx_plumb_msg *m = vx_plumb_msg_new("fuzz", "", "/usr/glenda", "text", (const char *)rest, nrest);
  if (m && nrest) {
    char click[32] = "click=";
    size_t c = 6, v = rest[0] % (nrest + 2);
    char digits[24];
    size_t nd = 0;
    do digits[nd++] = (char)('0' + v % 10), v /= 10;
    while (v);
    while (nd) click[c++] = digits[--nd];
    click[c] = 0;
    m->attr = vx_plumb_unpack_attr(click);
  }
  vx_plumb_exec *e = m ? vx_plumb_match(r, m) : nullptr;
  char **argv = nullptr;
  bool hold = false;
  vx_plumb_startup(r, e, &argv, &hold);
  vx_plumb_argv_free(argv);
  vx_plumb_exec_free(e);
  vx_plumb_free(m);
  // The listing, read as rules.
  size_t n = 0;
  char *text = vx_plumb_rules_print(r, &n);
  vx_plumb_rules *again = vx_plumb_rules_new(&FS);
  if (text) vx_plumb_rules_read(again, "listing", text, n);
  vx_plumb_dealloc(text);
  vx_plumb_rules_free(again);
  vx_plumb_rules_free(r);
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  if (size < 1) return 0;
  if (data[0] % 2)
    fuzz_rules(data + 1, size - 1);
  else
    fuzz_message(data + 1, size - 1);
  return 0;
}
