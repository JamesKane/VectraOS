// vxctest: the native target's C library (M6 step 6e2b, ADR-0033), the vxc
// scenario's (tests/qemu/vxc.ndb). Built with only the target: Fedora's
// clang with the sysroot's configuration file, ld.lld with its response
// files, and nothing but ISO C's headers. Its first part (6e2b): strtod and
// printf round trips, math, qsort, the heap through malloc and the rest,
// getenv, remove and rename refused, the clocks, and writes to standard
// output. Its second (6e2c1): setlocale, and atexit's handlers in order.
// Its third (6e2c2): FILE streams on files and the standard streams. Its
// fourth (6e2c3, 6e2d1): <threads.h>, malloc from several threads, and
// timed waits.
// Each check prints a line only when it fails; the last line counts them.

#include <errno.h>
#include <locale.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <threads.h>
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

// One locale, "C": asked for by name or as the environment's, and given to a query.
static void locales(void) {
  const char *c = setlocale(LC_ALL, nullptr);
  CHECK(c != nullptr && strcmp(c, "C") == 0);
  CHECK(setlocale(LC_ALL, "") != nullptr && setlocale(LC_NUMERIC, "C") != nullptr);
  CHECK(setlocale(LC_ALL, "fr_FR.UTF-8") == nullptr);
}

// atexit's handlers run after main returns, last registered first: the
// scenario expects their lines in that order.
static void second(void) { printf("vxctest: atexit second\n"); }
static void first(void) { printf("vxctest: atexit first\n"); }

static void handlers(void) {
  CHECK(atexit(first) == 0 && atexit(second) == 0);
  CHECK(at_quick_exit(first) == 0); // not run: the program ends by returning
}

// FILE streams on /tmp (6e2c2): written, read back by line and by block,
// sought and told, appended to, changed in place, renamed and removed.
static bool slurp(const char *path, char *buf, size_t cap) {
  FILE *f = fopen(path, "r");
  if (!f) return false;
  size_t n = fread(buf, 1, cap - 1, f);
  buf[n] = 0;
  bool ok = feof(f) && !ferror(f);
  fclose(f);
  return ok;
}

// Whether path cannot be opened to read (the stream closed if it could).
static bool absent(const char *path, const char *mode) {
  FILE *f = fopen(path, mode);
  if (f) fclose(f);
  return f == nullptr;
}

// A file read from the start: the first line, the length by seeking to the
// end, a character pushed back, the second line. Each step only after the
// last succeeded.
static void reading(FILE *f) {
  char buf[256];
  bool ok = fgets(buf, sizeof buf, f) && strcmp(buf, "line 1\n") == 0;
  CHECK(ok);
  ok = ok && fseek(f, 0, SEEK_END) == 0 && ftell(f) == 21;
  CHECK(ok);
  ok = ok && fseek(f, 7, SEEK_SET) == 0 && getc(f) == 'l' && ungetc('L', f) == 'L' && getc(f) == 'L';
  CHECK(ok);
  ok = ok && fgets(buf, sizeof buf, f) && strcmp(buf, "ine 2\n") == 0;
  CHECK(ok);
}

static void files(void) {
  const char *p = "/tmp/vxctest.txt", *q = "/tmp/vxctest-renamed.txt";
  FILE *f = fopen(p, "w");
  CHECK(f != nullptr);
  if (!f) return;
  for (int i = 1; i <= 3; i++) fprintf(f, "line %d\n", i);
  CHECK(fclose(f) == 0);
  char buf[256];
  f = fopen(p, "r");
  CHECK(f != nullptr);
  if (f) {
    reading(f);
    fclose(f);
  }
  f = fopen(p, "a");
  CHECK(f != nullptr);
  if (f) CHECK(fputs("tail\n", f) >= 0), CHECK(fclose(f) == 0);
  CHECK(slurp(p, buf, sizeof buf) && strcmp(buf, "line 1\nline 2\nline 3\ntail\n") == 0);
  f = fopen(p, "r+");
  CHECK(f != nullptr);
  if (f) CHECK(fputc('L', f) == 'L'), CHECK(fclose(f) == 0); // fputc gives the character back
  CHECK(slurp(p, buf, sizeof buf) && strncmp(buf, "Line 1\n", 7) == 0);
  CHECK(rename(p, q) == 0 && absent(p, "r") && slurp(q, buf, sizeof buf));
  CHECK(remove(q) == 0 && absent(q, "r"));
  errno = 0;
  CHECK(absent("/tmp/vxctest-none", "r") && errno == ENOENT);
  CHECK(absent(p, "bogus"));
  CHECK(fprintf(stdout, "vxctest: fprintf to stdout\n") > 0 && fflush(stdout) == 0);
  CHECK(fputs("vxctest: fputs to stderr\n", stderr) >= 0);
}

// <threads.h> (6e2c3): four threads sharing a counter under a mutex while
// they use the heap; a condition variable; call_once; thread-specific
// storage and its destructors; thrd_exit from below a thread's function; a
// detached thread; a recursive mutex.
static mtx_t lock;
static cnd_t changed;
static int counter, ready, once_calls, destroyed;
static once_flag once = ONCE_FLAG_INIT;
static tss_t key;

static void count_once(void) { once_calls++; }
static void destroy(void *p) {
  mtx_lock(&lock);
  destroyed++;
  mtx_unlock(&lock);
  free(p);
}

static int worker(void *arg) {
  int id = (int)(size_t)arg;
  call_once(&once, count_once);
  tss_set(key, malloc(16));
  for (int i = 0; i < 2000; i++) {
    char *p = malloc((size_t)(16 + (i * 37 + id) % 3000)); // the heap from every thread at once
    if (p) p[0] = (char)id;
    mtx_lock(&lock);
    counter++;
    mtx_unlock(&lock);
    free(p);
  }
  return id * 10;
}

[[noreturn]] static void leave(int code) { thrd_exit(code); }
static int leaver(void *arg) {
  (void)arg;
  leave(7); // ends the thread from below its function
}

static int waiter(void *arg) {
  (void)arg;
  mtx_lock(&lock);
  while (!ready) cnd_wait(&changed, &lock);
  ready = 2;
  cnd_signal(&changed);
  mtx_unlock(&lock);
  return 0;
}

static int detached(void *arg) {
  (void)arg;
  mtx_lock(&lock);
  ready = 3;
  cnd_broadcast(&changed);
  mtx_unlock(&lock);
  return 0;
}

static int recurse(void *arg) {
  mtx_t *r = arg;
  mtx_lock(r); // waits until main has unlocked it twice
  mtx_unlock(r);
  return 1;
}

// Waits with deadlines: TIME_UTC's, ms milliseconds from now.
static struct timespec after_ms(long ms) {
  struct timespec ts;
  timespec_get(&ts, TIME_UTC);
  ts.tv_nsec += ms * 1000000;
  ts.tv_sec += ts.tv_nsec / 1000000000;
  ts.tv_nsec %= 1000000000;
  return ts;
}

static long since_ms(const struct timespec *start) {
  struct timespec now;
  timespec_get(&now, TIME_UTC);
  return (long)((now.tv_sec - start->tv_sec) * 1000 + (now.tv_nsec - start->tv_nsec) / 1000000);
}

static mtx_t held;

static int try_held(void *arg) {
  (void)arg;
  struct timespec start, until = after_ms(50);
  timespec_get(&start, TIME_UTC);
  int busy = mtx_trylock(&held);
  int timed = mtx_timedlock(&held, &until);
  return busy == thrd_busy && timed == thrd_timedout && since_ms(&start) >= 49;
}

// The rest of C11's threads (6e2d1): a lock tried and timed out while
// another thread holds it, a condition waited on to a deadline, a sleep and
// a yield.
static void timed(void) {
  CHECK(mtx_init(&held, mtx_timed) == thrd_success && mtx_lock(&held) == thrd_success);
  thrd_t t;
  int ok = 0;
  CHECK(thrd_create(&t, try_held, nullptr) == thrd_success && thrd_join(t, &ok) == thrd_success && ok);
  CHECK(mtx_unlock(&held) == thrd_success && mtx_trylock(&held) == thrd_success &&
        mtx_unlock(&held) == thrd_success);
  cnd_t never;
  CHECK(cnd_init(&never) == thrd_success && mtx_lock(&held) == thrd_success);
  struct timespec start, until = after_ms(30);
  timespec_get(&start, TIME_UTC);
  CHECK(cnd_timedwait(&never, &held, &until) == thrd_timedout && since_ms(&start) >= 29);
  CHECK(mtx_unlock(&held) == thrd_success); // held again after the timeout
  struct timespec nap = {.tv_sec = 0, .tv_nsec = 20000000}, left = {.tv_sec = 1, .tv_nsec = 1};
  timespec_get(&start, TIME_UTC);
  CHECK(thrd_sleep(&nap, &left) == 0 && since_ms(&start) >= 19 && left.tv_sec == 0 && left.tv_nsec == 0);
  thrd_yield();
  cnd_destroy(&never);
  mtx_destroy(&held);
}

static void threads(void) {
  CHECK(mtx_init(&lock, mtx_plain) == thrd_success && cnd_init(&changed) == thrd_success);
  CHECK(tss_create(&key, destroy) == thrd_success);
  thrd_t t[4];
  for (int i = 0; i < 4; i++) CHECK(thrd_create(&t[i], worker, (void *)(size_t)(i + 1)) == thrd_success);
  int sum = 0, res = 0;
  for (int i = 0; i < 4; i++) CHECK(thrd_join(t[i], &res) == thrd_success), sum += res;
  CHECK(counter == 8000 && sum == 100 && once_calls == 1 && destroyed == 4);
  thrd_t l;
  CHECK(thrd_create(&l, leaver, nullptr) == thrd_success && thrd_join(l, &res) == thrd_success && res == 7);
  thrd_t w;
  CHECK(thrd_create(&w, waiter, nullptr) == thrd_success);
  mtx_lock(&lock);
  ready = 1;
  cnd_signal(&changed);
  while (ready != 2) cnd_wait(&changed, &lock);
  mtx_unlock(&lock);
  CHECK(thrd_join(w, nullptr) == thrd_success && ready == 2);
  thrd_t d;
  CHECK(thrd_create(&d, detached, nullptr) == thrd_success && thrd_detach(d) == thrd_success);
  mtx_lock(&lock);
  while (ready != 3) cnd_wait(&changed, &lock);
  mtx_unlock(&lock);
  mtx_t r;
  CHECK(mtx_init(&r, mtx_plain | mtx_recursive) == thrd_success);
  CHECK(mtx_lock(&r) == thrd_success && mtx_lock(&r) == thrd_success); // held twice by one thread
  thrd_t o;
  CHECK(thrd_create(&o, recurse, &r) == thrd_success);
  CHECK(mtx_unlock(&r) == thrd_success && mtx_unlock(&r) == thrd_success);
  CHECK(thrd_join(o, &res) == thrd_success && res == 1);
  CHECK(thrd_equal(thrd_current(), thrd_current()) && !thrd_equal(thrd_current(), o));
  mtx_destroy(&r);
  tss_delete(key);
  cnd_destroy(&changed);
  mtx_destroy(&lock);
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
  locales();
  files();
  threads();
  timed();
  handlers();
  puts("vxctest: through puts");
  printf("vxctest: %d checks, %d failed\n", checks, failures);
  return failures ? 1 : 0;
}
