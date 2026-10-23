// SPDX-License-Identifier: BSD-3-Clause

// The end of link-test's chain of libraries (D124), C because C is what
// has thread-local variables: a TLS block with an initial image, data, a
// constructor that tells the program it ran, and a call into the program.

extern void link_note(int who);
extern int link_host_value(void);

_Thread_local long linkb_tls[2] = {7, 8};
_Thread_local int linkb_zero;
int linkb_value = 30;

__attribute__((constructor)) static void initialize(void) { link_note(2); }

long *linkb_tls_address(void) { return linkb_tls; }
int *linkb_zero_address(void) { return &linkb_zero; }
int linkb_add(int a) { return a + linkb_value + link_host_value(); }

#ifdef LINKB_STALE
// Another build of the library, which link-stale is linked against and
// bootfs doesn't have.
int linkb_stale(void) { return 1; }
#endif
