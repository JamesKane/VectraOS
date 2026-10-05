// slots_test.c: lib/vx-slots (docs/06 §7): a table printed and read back the
// same, and one with a key slots(6) does not name, or no boot slot, refused;
// and the slot apply writes, which is never the one that booted, however
// many applies come before a boot.

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

  // Applies with no boot between them: a, running, is never written.
  vx_slots t = {.boot = 0, .previous = -1};
  t.slot[0].used = true;
  CHECK(vx_slots_target(&t, -1) == -1); // not booted from a slot: none
  int first = vx_slots_target(&t, 0);
  CHECK(first == 1);
  t.slot[first].used = true, t.previous = 0, t.boot = first;
  int second = vx_slots_target(&t, 0);
  CHECK(second == 2); // not in use yet
  t.slot[second].used = true, t.previous = 0, t.boot = second;
  int third = vx_slots_target(&t, 0);
  CHECK(third == 2); // the staged slot again, never a
  // Booted from b, a the previous, c staged and not booted: c; then, c
  // booted, the one neither booting nor previous.
  t = (vx_slots){.boot = 2, .previous = 1};
  for (int i = 0; i < VX_SLOTS; i++) t.slot[i].used = true;
  CHECK(vx_slots_target(&t, 1) == 2);
  t.boot = 1, t.previous = 0;
  CHECK(vx_slots_target(&t, 1) == 2);
  return check_result();
}
