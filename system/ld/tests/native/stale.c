// SPDX-License-Identifier: BSD-3-Clause

// bin/link-stale (D124): a program linked against a build of liblinkb.so
// that bootfs doesn't have (its build ID differs), so the process that
// starts it must refuse it; dl-test checks that. Were it started, it would
// exit 1.

extern int linkb_add(int a);

void link_note(int who) { (void)who; }
int link_host_value(void) { return 0; }

int main(void) { return linkb_add(0) == 30 ? 1 : 2; }
