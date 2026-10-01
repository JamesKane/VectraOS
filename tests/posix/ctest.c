// ctest: a C program against vectra-musl (M4 step 2d, tests/qemu/posix.ndb).
// It uses the C library as any port would, and checks what comes back: its
// arguments and environment, memory, floating point (aarch64's long double
// is compiler-rt's), stdio on files in its namespace, directories, stat, the
// working directory, errno, time, thread-local storage, setjmp, atexit, and
// its exit status.

#define _XOPEN_SOURCE 700 // POSIX, under -std=c23

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <pthread.h>
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>

static int checks, failed;

#define CHECK(cond)                                                                                          \
  do {                                                                                                       \
    checks++;                                                                                                \
    if (!(cond)) {                                                                                           \
      failed++;                                                                                              \
      printf("ctest: FAILED line %d: %s\n", __LINE__, #cond);                                                \
    }                                                                                                        \
  } while (0)

static _Thread_local int tls_counter = 41;
static jmp_buf jump;

static void at_exit(void) { printf("ctest: atexit ran\n"); }

static void jump_back(int value) { longjmp(jump, value); }

static int by_int(const void *a, const void *b) { return *(const int *)a - *(const int *)b; }

static void *never_runs(void *arg) { return arg; }

static double seconds(const struct timespec *t) { return (double)t->tv_sec + (double)t->tv_nsec / 1e9; }

int main(int argc, char **argv) {
  printf("ctest: hello from musl\n");
  // The spawn message's arguments, after the program's name, and environment.
  bool args = argc == 3 && argv[0] && argv[1] && argv[2];
  CHECK(args && strcmp(argv[0], "ctest") == 0);
  if (args) printf("ctest: argv %s|%s\n", argv[1], argv[2]);
  CHECK(args && strcmp(argv[2], "two words") == 0);
  const char *greeting = getenv("GREETING");
  CHECK(greeting && strcmp(greeting, "hello") == 0);
  CHECK(getenv("NOT_SET") == nullptr);

  // Memory: small allocations from musl's heap, a large one mapped alone.
  char *small = malloc(100);
  CHECK(small != nullptr);
  strcpy(small, "small");
  char *big = calloc(1, 4u << 20);
  CHECK(big != nullptr && big[0] == 0 && big[(4u << 20) - 1] == 0);
  if (big) {
    big[123456] = 7;
    char *bigger = realloc(big, 8u << 20);
    CHECK(bigger != nullptr && bigger[123456] == 7);
    free(bigger ? bigger : big);
  }
  CHECK(strcmp(small, "small") == 0);
  free(small);

  // Floating point, formatted and parsed; long double too.
  char buf[128];
  snprintf(buf, sizeof buf, "%.6f %g %.3e", sqrt(2.0), 1.0 / 3.0, 6.02214076e23);
  CHECK(strcmp(buf, "1.414214 0.333333 6.022e+23") == 0);
  long double third = 1.0L / 3.0L;
  snprintf(buf, sizeof buf, "%.12Lf", third);
  CHECK(strcmp(buf, "0.333333333333") == 0);
  CHECK(strtod("2.5e3", nullptr) == 2500.0 && strtold("0.25", nullptr) == 0.25L);
  CHECK(fabs(sin(M_PI / 6) - 0.5) < 1e-12 && pow(2.0, 10.0) == 1024.0);

  // Text: integers, sorting, the C locale's classes.
  CHECK(strtol("-0x7f", nullptr, 16) == -127 && strtol("  42", nullptr, 10) == 42);
  int numbers[] = {5, 3, 9, 1, 7};
  qsort(numbers, 5, sizeof numbers[0], by_int);
  CHECK(numbers[0] == 1 && numbers[4] == 9);

  // Files in the namespace: its own manifest, by absolute and relative paths.
  FILE *f = fopen("/boot/svc/ctest.ndb", "r");
  CHECK(f != nullptr);
  if (f) {
    CHECK(fgets(buf, sizeof buf, f) && strncmp(buf, "# tests/user/ctest.ndb", 22) == 0);
    CHECK(fseek(f, 0, SEEK_END) == 0);
    CHECK(fseek(f, 0, SEEK_SET) == 0 && fgetc(f) == '#');
    fclose(f);
  }
  struct stat st;
  CHECK(stat("/boot/svc/ctest.ndb", &st) == 0 && S_ISREG(st.st_mode) && st.st_size > 100);
  CHECK(stat("/boot/bin", &st) == 0 && S_ISDIR(st.st_mode));
  CHECK(getcwd(buf, sizeof buf) && strcmp(buf, "/") == 0);
  CHECK(chdir("/boot") == 0 && getcwd(buf, sizeof buf) && strcmp(buf, "/boot") == 0);
  f = fopen("svc/../svc/ctest.ndb", "r");
  CHECK(f != nullptr);
  if (f) fclose(f);
  CHECK(chdir("/boot/svc/ctest.ndb") == -1 && errno == ENOTDIR);

  // A directory, read whole.
  DIR *d = opendir("/boot/bin");
  CHECK(d != nullptr);
  int entries = 0;
  bool found = false;
  for (struct dirent *e; d && (e = readdir(d));) {
    entries++;
    if (strcmp(e->d_name, "ctest") == 0) found = e->d_type == DT_REG;
  }
  if (d) closedir(d);
  CHECK(found && entries > 5);

  // Errors come back as errno, and are worded.
  errno = 0;
  FILE *none = fopen("/no/such/file", "r");
  CHECK(none == nullptr && errno == ENOENT);
  if (none) fclose(none);
  CHECK(strcmp(strerror(ENOENT), "No such file or directory") == 0);
  CHECK(open("/boot/bin", O_WRONLY) == -1);

  // Time: the clock moves, and a sleep lasts as long as asked.
  struct timespec t0, t1;
  CHECK(clock_gettime(CLOCK_MONOTONIC, &t0) == 0);
  CHECK(nanosleep(&(struct timespec){.tv_nsec = 20'000'000}, nullptr) == 0);
  CHECK(clock_gettime(CLOCK_MONOTONIC, &t1) == 0 && seconds(&t1) - seconds(&t0) >= 0.02);

  // Thread-local storage (errno is too), setjmp, and the system's name.
  CHECK(++tls_counter == 42);
  int jumped = setjmp(jump);
  if (!jumped) jump_back(5);
  CHECK(jumped == 5);
  struct utsname u;
  CHECK(uname(&u) == 0 && strcmp(u.sysname, "VectraOS") == 0);

  // No threads yet: pthread_create fails, and says so (docs/milestones.md).
  pthread_t thread;
  CHECK(pthread_create(&thread, nullptr, never_runs, nullptr) != 0);

  atexit(at_exit);
  fprintf(stderr, "ctest: to stderr\n");
  printf("ctest: %d checks, %d failed\n", checks, failed);
  return failed ? 1 : 0;
}
