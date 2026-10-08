// dltest.h: what libdltesta.so and libdltestb.so export, and dltest uses
// (M6 step 6f1a, ADR-0047).

#pragma once

// libdltestb.so
extern thread_local int b_tls;
extern int b_value;
extern int b_inits;
int b_add(int x);
int b_tls_bump(void);

// libdltesta.so
extern thread_local int a_tls;
extern int a_counter;
extern int (*a_fn)(int);
extern int a_inits_seen;
extern const char *a_greeting; // a pointer the library relocates, which the program copies
int a_compute(int x);
int a_tls_bump(void);
int a_b_tls(void);
const char *a_name(int i);
