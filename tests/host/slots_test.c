// slots_test.c: lib/vx-slots (docs/06 §7): a table printed and read back the
// same, and one with a key slots(6) does not name, or no boot slot, refused.

#include <string.h>

#include "check.h"
#include "../../lib/vx-slots/slots.c"

static char scratch[4096];

int main(void) {
  vx_slots s = {.boot = 0, .previous = -1};
  s.slot[0].used = true;
  s.slot[0].release = 7;
  strcpy(s.slot[0].tree, "b2:ab");
  for (int f = 0; f < VX_SLOT_FILES; f++) memset(s.slot[0].hash[f], 'c', VX_SLOT_HASH);
  strcpy(s.cmdline, "vx.skip=rc");
  static char text[2048];
  vx_ndb_writer w = {.buf = text, .cap = sizeof text};
  CHECK(vx_slots_print(&s, &w) && !w.failed);

  vx_slots back;
  CHECK(vx_slots_parse(&back, (vx_str){text, w.len}, scratch, sizeof scratch) == VX_OK);
  CHECK(back.boot == 0 && back.previous == -1 && back.slot[0].used && back.slot[0].release == 7 &&
        !back.slot[1].used && strcmp(back.cmdline, "vx.skip=rc") == 0);

  static char bad[2100];
  snprintf(bad, sizeof bad, "%.*s booted=a\n", (int)w.len - 1, text); // on the table's record
  CHECK(vx_slots_parse(&back, (vx_str){bad, strlen(bad)}, scratch, sizeof scratch) == VX_ERR_INVALID);
  const char *noboot = "boot=b previous=-\n";
  CHECK(vx_slots_parse(&back, (vx_str){noboot, strlen(noboot)}, scratch, sizeof scratch) == VX_ERR_INVALID);
  return check_result();
}
