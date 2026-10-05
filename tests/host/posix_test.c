// posix_test.c: lib/vx-posix's signals as notes (ADR-0010): each note and
// exit string to the signal it stands for and its sender, and the wait
// status a parent sees, a pager's timeout among them (SIGBUS).

#include <string.h>

#include "check.h"
#include "../../lib/vx-posix/posix.h"

int main(void) {
  int64_t sender;
  CHECK(posix_note_signal(VX_STR("posix: SIGTERM pid=12"), &sender) == POSIX_SIGTERM && sender == 12);
  CHECK(posix_note_signal(VX_STR("interrupt"), &sender) == POSIX_SIGINT && sender == 0);
  CHECK(posix_note_signal(VX_STR("sys: trap: arithmetic pc=0x401000"), &sender) == POSIX_SIGFPE);
  CHECK(posix_note_signal(VX_STR("sys: trap: page not supplied addr=0x7000 pc=0x401000"), &sender) ==
        POSIX_SIGBUS);
  CHECK(posix_note_signal(VX_STR("no such thing"), &sender) == 0);

  CHECK(posix_wait_status(VX_STR("")) == 0);
  CHECK(posix_wait_status(VX_STR("3")) == 3 << 8);
  CHECK(posix_wait_status(VX_STR("sys: trap: page not supplied addr=0x7000 pc=0x401000")) == POSIX_SIGBUS);
  CHECK(posix_wait_status(VX_STR("killed")) == POSIX_SIGKILL);
  CHECK(posix_wait_status(VX_STR("cannot open")) == 1 << 8);

  char note[VX_ERRMAX];
  size_t n = posix_note(POSIX_SIGQUIT, 0, note); // ^\ at a terminal: no Plan 9 words
  CHECK(n == 14 && memcmp(note, "posix: SIGQUIT", 14) == 0);
  return check_result();
}
