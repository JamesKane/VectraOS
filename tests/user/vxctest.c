// vxctest: the native target's C library (M6 step 6e2b, ADR-0033), the vxc
// scenario's (tests/qemu/vxc.ndb). Built with only the target: Fedora's
// clang with the sysroot's configuration file, ld.lld with its response
// files, and nothing but ISO C's headers. Its first part: strtod and printf
// round trips, math, qsort, the heap through malloc and the rest, getenv,
// remove and rename refused, the clocks, and writes to standard output.
// Each check prints a line only when it fails; the last line counts them.

#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int checks, failures;

static void check(int ok, const char *what, int line) {
  checks++;
  if (ok) return;
  failures++;
  printf("vxctest: FAILED line %d: %s\n", line, what);
}

#define CHECK(cond) check((cond) != 0, #cond, __LINE__)

static int by_value(const void *a, const void *b) {
  int x = *(const int *)a, y = *(const int *)b;
  return (x > y) - (x < y);
}

// Doubles printed with 17 digits read back as themselves: both correctly rounded.
static void numbers(void) {
  char buf[64];
  CHECK(strtod("0.1", nullptr) == 0.1);
  snprintf(buf, sizeof buf, "%.17g", 0.1);
  CHECK(strcmp(buf, "0.10000000000000001") == 0);
  static const double VALUES[] = {1e-300, 3.141592653589793,     1.0 / 3, 6.02214076e23,
                                  5e-324, 1.7976931348623157e308};
  for (size_t i = 0; i < sizeof VALUES / sizeof VALUES[0]; i++) {
    snprintf(buf, sizeof buf, "%.17g", VALUES[i]);
    CHECK(strtod(buf, nullptr) == VALUES[i]);
  }
  snprintf(buf, sizeof buf, "%d %u %x %s %c %5.2f %%", -7, 7u, 255u, "s", 'c', 2.5);
  CHECK(strcmp(buf, "-7 7 ff s c  2.50 %") == 0);
  CHECK(strtol("-1234", nullptr, 10) == -1234 && strtoul("ff", nullptr, 16) == 255);
}

static void maths(void) {
  CHECK(sqrt(2.0) == 1.4142135623730951);
  CHECK(exp(0.0) == 1.0 && log(1.0) == 0.0 && pow(2.0, 10.0) == 1024.0);
  CHECK(fabs(sin(3.141592653589793)) < 1e-15 && cos(0.0) == 1.0);
  CHECK(cbrtf(27.0f) == 3.0f && fma(2.0, 3.0, 1.0) == 7.0);
  CHECK(floor(-1.5) == -2.0 && round(2.5) == 3.0 && trunc(-2.7) == -2.0);
}

static void sorting(void) {
  int a[200];
  unsigned r = 1;
  for (int i = 0; i < 200; i++) a[i] = (int)((r = r * 1103515245u + 12345u) >> 8) % 1000;
  qsort(a, 200, sizeof a[0], by_value);
  int sorted = 1;
  for (int i = 1; i < 200; i++) sorted = sorted && a[i - 1] <= a[i];
  CHECK(sorted);
}

// malloc and the rest, over the process heap (vx_heap).
static void heap(void) {
  char *p = malloc(100);
  CHECK(p != nullptr && ((size_t)p & 15) == 0);
  if (p) strcpy(p, "kept");
  char *q = realloc(p, 100000);
  CHECK(q != nullptr && strcmp(q, "kept") == 0);
  free(q ? q : p);
  int *z = calloc(1000, sizeof(int));
  int zero = z != nullptr;
  for (int i = 0; z && i < 1000; i++) zero = zero && z[i] == 0;
  CHECK(zero);
  free(z);
  void *a = aligned_alloc(4096, 4096);
  CHECK(a != nullptr && ((size_t)a & 4095) == 0);
  free(a);
  char *big = malloc(64u << 20);
  CHECK(big != nullptr);
  if (big) memset(big, 1, 64u << 20), free(big);
  void *huge = calloc((size_t)-1 / 2, 4);
  CHECK(huge == nullptr); // overflow: refused
  free(huge);
}

// getenv through /env; remove and rename of what is not there refused.
static void environment(void) {
  const char *v = getenv("VXCTEST");
  CHECK(v != nullptr && strcmp(v, "hello world") == 0);
  CHECK(getenv("VXCTEST_NONE") == nullptr);
  errno = 0;
  CHECK(remove("/tmp/vxctest-none") != 0 && errno == ENOENT);
  errno = 0;
  CHECK(rename("/tmp/vxctest-none", "/tmp/vxctest-other") != 0 && errno == ENOENT);
}

static void clocks(void) {
  struct timespec ts;
  CHECK(timespec_get(&ts, TIME_UTC) == TIME_UTC && ts.tv_nsec >= 0 && ts.tv_nsec < 1000000000);
  volatile double x = 0;
  for (int i = 0; i < 2000000; i++) x += i; // some CPU time to count
  CHECK(clock() != (clock_t)-1);
}

int main(int argc, char **argv) {
  printf("vxctest: hello from llvm-libc\n");
  CHECK(argc == 3 && strcmp(argv[1], "one") == 0 && strcmp(argv[2], "two words") == 0);
  numbers();
  maths();
  sorting();
  heap();
  environment();
  clocks();
  puts("vxctest: through puts");
  printf("vxctest: %d checks, %d failed\n", checks, failures);
  return failures ? 1 : 0;
}
