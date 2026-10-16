// SPDX-License-Identifier: BSD-3-Clause

// Tier 1's floor from C (M6c): a program built by the *-vectraos toolchain
// against tier 1's sysroot, on croi. Its start (the floor's _start), argv
// and the environment, the heap, TLS, an initializer and an exit handler;
// printf's family and strtod; libm; pthreads; and what M6d added for
// C++: long double (strtold, %Lf), qsort, ctype, strerror, errno's ERANGE,
// the clocks, sysconf and dl_iterate_phdr. Exits 0 if all held.

#include <ctype.h>
#include <errno.h>
#include <float.h>
#include <link.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static void say(const char *s) {
  while (*s) putchar(*s++);
  putchar('\n');
}

static int failures;
static void check(int ok, const char *what) {
  if (!ok) {
    putchar('!');
    putchar(' ');
    say(what);
    failures++;
  }
}

static int initialized;
__attribute__((constructor)) static void initialize(void) { initialized = 7; }

static _Thread_local int tls = 5;

static void at_exit(void) { say("floor-hello: exit handler"); }

static int by_value(const void *a, const void *b) { return *(const int *)a - *(const int *)b; }

static int found_eh_frame;
static int each_object(struct dl_phdr_info *info, size_t size, void *data) {
  (void)size;
  (void)data;
  for (int i = 0; i < info->dlpi_phnum; i++)
    if (info->dlpi_phdr[i].p_type == PT_GNU_EH_FRAME || info->dlpi_phdr[i].p_type == PT_LOAD) found_eh_frame++;
  return 0;
}

static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static long counter;
static void *count(void *arg) {
  for (int i = 0; i < 10000; i++) {
    pthread_mutex_lock(&mutex);
    counter++;
    pthread_mutex_unlock(&mutex);
  }
  tls += 1;  // each thread's own
  return (char *)arg + tls;
}

int main(int argc, char **argv) {
  check(argc >= 1 && argv[0] && strlen(argv[0]) > 0, "argv");
  check(initialized == 7, "an initializer");
  check(tls == 5, "TLS");
  char *p = malloc(100000);
  check(p != 0, "malloc");
  memset(p, 'x', 100000);
  free(p);
  check(getenv("NO_SUCH_VARIABLE_HERE") == 0, "getenv");
  check(atexit(at_exit) == 0, "atexit");

  // printf's family: the same strings glibc gives.
  char b[128];
  snprintf(b, sizeof b, "%d|%5s|%-4x|%#o|%+.3f|%e|%g|%a|%c|%%", -42, "ab", 255, 8, 2.0 / 3.0, 1234.5, 0.0001, 1.0, 'z');
  check(strcmp(b, "-42|   ab|ff  |010|+0.667|1.234500e+03|0.0001|0x1p+0|z|%") == 0, "snprintf");
  snprintf(b, sizeof b, "%.0f %.0f %.20f %.17g", 0.5, 2.5, 0.1, 0.1);
  check(strcmp(b, "0 2 0.10000000000000000555 0.10000000000000001") == 0, "snprintf's rounding");
  check(snprintf(b, 4, "%s", "truncated") == 9 && strcmp(b, "tru") == 0, "snprintf's truncation");
  printf("floor-hello: printf %s %d %.2f\n", "says", 3, 3.14159);
  fprintf(stderr, "floor-hello: and stderr\n");

  // strtod and strtof, correctly rounded.
  char *end;
  check(strtod("0.1", &end) == 0.1 && *end == 0, "strtod 0.1");
  check(strtod("  -1.5e3xyz", &end) == -1500.0 && strcmp(end, "xyz") == 0, "strtod's end");
  check(strtod("0x1.8p1", 0) == 3.0, "strtod's hex");
  check(strtod("4.9e-324", 0) > 0 && strtod("2e-324", 0) == 0, "strtod's subnormals");
  check(strtof("3.4028235e38", 0) == 3.4028235e38f, "strtof");
  check(atof("2.5") == 2.5, "atof");

  // libm: exact functions bit for bit, the rest within an ulp.
  volatile double h = 2.5, n = -2.5, big = 1e22;
  check(floor(h) == 2 && ceil(n) == -2 && round(h) == 3 && rint(h) == 2 && trunc(n) == -2, "rounding");
  check(fmod(10.5, 3) == 1.5 && remainder(10.5, 3) == -1.5 && fma(0.1, 10, -1) == 5.551115123125783e-17, "fmod, fma");
  check(sqrt(2.0) == 1.4142135623730951, "sqrt");
  check(fabs(exp(1.0) - M_E) <= 4.5e-16 && fabs(log(M_E) - 1) <= 2.3e-16, "exp, log");
  check(exp2(10) == 1024 && log2(1024) == 10 && log10(1000) == 3, "exp2, log2, log10");
  check(fabs(sin(M_PI / 6) - 0.5) <= 1.2e-16 && fabs(cos(M_PI / 3) - 0.5) <= 1.2e-16, "sin, cos");
  check(fabs(sin(big) - (-0.8522008497671888)) <= 1.2e-16, "sin of 1e22 (Payne-Hanek)");
  snprintf(b, sizeof b, "%.6f %.6f", sinf(1.0f), sqrtf(2.0f));
  check(strcmp(b, "0.841471 1.414214") == 0, "the float functions");

  // pthreads, runtime-free beneath tier 1: threads, a contended mutex, TLS.
  pthread_t t[4];
  for (int i = 0; i < 4; i++) check(pthread_create(&t[i], 0, count, (void *)(long)(i * 100)) == 0, "pthread_create");
  for (int i = 0; i < 4; i++) {
    void *r = 0;
    check(pthread_join(t[i], &r) == 0 && r == (void *)(long)(i * 100 + 6), "pthread_join's result");
  }
  check(counter == 40000 && tls == 5, "a mutex and TLS across threads");

  // M6d: long double, qsort, ctype, strerror, ERANGE, clocks, sysconf,
  // dl_iterate_phdr.
  long double ld = strtold("0.1", 0);
  snprintf(b, sizeof b, "%.25Lf %La", ld, 1.0L);
  // 0.1 to x87's 64 bits is 0.10000000000000000000135525…; to binary128's
  // 113, 0.1000000000000000000000000000000000055511…
  check(strcmp(b, LDBL_MANT_DIG == 64 ? "0.1000000000000000000013553 0x8p-3" : "0.1000000000000000000000000 0x1p+0") == 0,
        "strtold and %Lf");
  int v[] = {5, 3, 9, 1, 7};
  qsort(v, 5, sizeof v[0], by_value);
  check(v[0] == 1 && v[2] == 5 && v[4] == 9, "qsort");
  check(isdigit('7') && !isalpha('7') && toupper('q') == 'Q' && isspace('\t'), "ctype");
  check(strcmp(strerror(ENOENT), "No such file or directory") == 0, "strerror");
  errno = 0;
  check(strtol("99999999999999999999", 0, 10) == 9223372036854775807L && errno == ERANGE, "strtol's ERANGE");
  struct timespec t0, t1, nap = {0, 1000000};
  clock_gettime(CLOCK_MONOTONIC, &t0);
  nanosleep(&nap, 0);
  clock_gettime(CLOCK_MONOTONIC, &t1);
  check((t1.tv_sec - t0.tv_sec) * 1000000000L + (t1.tv_nsec - t0.tv_nsec) >= 1000000, "nanosleep and clock_gettime");
  check(sysconf(_SC_NPROCESSORS_ONLN) >= 1, "sysconf's processors");
  dl_iterate_phdr(each_object, 0);
  check(found_eh_frame >= 2, "dl_iterate_phdr");
  say(failures ? "floor-hello: FAILED" : "floor-hello: passed");
  return failures ? 1 : 0;
}
