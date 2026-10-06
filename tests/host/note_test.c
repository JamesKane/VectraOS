// note_test.c: lib/vx-note, a trap's note in Plan 9's words (ADR-0010), for
// the kinds whose words depend on the code: a protection key's read and
// write (ADR-0035), once cut to "sys: tr" (VX_STR of a conditional, the
// Odin port's finding), and a page fault's.

#include <string.h>

#include "check.h"
#include "../../lib/vx-note/note.c"

static bool note_is(uint32_t kind, uint32_t code, const char *want) {
  char out[VX_ERRMAX];
  size_t n = vx_trap_note(kind, code, 0x1000, 0x2000, out);
  return n >= strlen(want) && memcmp(out, want, strlen(want)) == 0;
}

int main(void) {
  CHECK(note_is(VX_EXCEPTION_PROTECTION_KEY, 1, "sys: trap: protection key write addr=0x1000"));
  CHECK(note_is(VX_EXCEPTION_PROTECTION_KEY, 0, "sys: trap: protection key read addr=0x1000"));
  CHECK(note_is(VX_EXCEPTION_PAGE_FAULT, 1, "sys: trap: fault write addr=0x1000"));
  return check_result();
}
