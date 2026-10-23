// SPDX-License-Identifier: BSD-3-Clause

// The first of link-test's libraries (D124), which needs liblinkb.so: its
// own TLS, aligned past the others', liblinkb's TLS and functions reached
// from here, and a constructor that runs after liblinkb's.

extern _Thread_local long linkb_tls[2];
extern int linkb_add(int a);
extern void link_note(int who);

_Thread_local int linka_tls __attribute__((aligned(64))) = 5;

__attribute__((constructor)) static void initialize(void) { link_note(1); }

int *linka_tls_address(void) { return &linka_tls; }
long linka_reads_b(void) { return linkb_tls[1]; }
int linka_add(int a) { return linkb_add(a) + 1; }
