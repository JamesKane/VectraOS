// rc_fuzz.c: arbitrary text into lib/vx-rc as a script: its lexer, parser,
// compiler and machine never read outside the text or the heap, never
// recurse, and stop (a step budget for loops); its heap gives back all it
// lends, so a long run of inputs never runs it out.

#include <stdlib.h>
#include <string.h>

#include "../../lib/vx-rc/rc.c"

static bool run(void *ctx, rc *r, const rc_command *stages, uint32_t n, bool async, uint64_t *pid) {
  (void)ctx, (void)stages, (void)n, (void)async;
  *pid = 1;
  rc_set_status(r, "", 0);
  return true;
}

static void write_nothing(void *ctx, const rc_fd *fd, uint32_t which, const char *s, size_t n) {
  (void)ctx, (void)fd, (void)which, (void)s, (void)n;
}

static bool readdir_some(void *ctx, const char *path, size_t len, void (*each)(void *, const char *, size_t),
                         void *arg) {
  (void)ctx, (void)path, (void)len;
  each(arg, "a.c", 3);
  each(arg, "b", 1);
  return true;
}

static alignas(16) uint8_t heap[8 << 20];

// libFuzzer calls it by name, so it cannot be static.
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size); // NOLINT(misc-use-internal-linkage)

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  rc_host host = {.run = run, .write = write_nothing, .readdir = readdir_some};
  rc *r = rc_new(heap, sizeof heap, &host); // a fresh interpreter each time
  if (!r) abort();
  r->budget = 20000;
  char *text = malloc(size ? size : 1);
  if (!text) return 0;
  memcpy(text, data, size);
  rc_run(r, text, size);
  rc_run(r, text, size); // twice: what the first left (functions, variables) does not break the second
  free(text);
  return 0;
}
