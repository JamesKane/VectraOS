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
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <sys/wait.h>
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

// ctest run by ctest: argv[1] says what to check, argv[2] is the parent's
// pid, and the exit status says what it found.
extern char **environ; // POSIX's, which <unistd.h> declares only for _GNU_SOURCE

static int child_main(char **argv) {
  pid_t parent = (pid_t)strtol(argv[2], nullptr, 10);
  if (getppid() != parent || getpid() == parent || getsid(0) != getsid(parent)) return 1;
  if (strcmp(argv[1], "exit") == 0) return (int)strtol(argv[3], nullptr, 10);
  if (strcmp(argv[1], "group") == 0) return getpgrp() == getpid() ? 9 : 2; // POSIX_SPAWN_SETPGROUP, 0
  if (strcmp(argv[1], "sleep") == 0) {
    nanosleep(&(struct timespec){.tv_nsec = 100'000'000}, nullptr);
    return 3;
  }
  if (strcmp(argv[1], "echo") == 0) { // its standard output, a pipe the parent reads
    printf("echo from child\n");
    return 8;
  }
  if (strcmp(argv[1], "fds") == 0) { // descriptors and the working directory, as the parent left them
    char b[3] = {}, cwd[64];
    bool ok = read(3, b, 2) == 2 && memcmp(b, "te", 2) == 0; // inherited at offset 2
    ok = ok && fcntl(4, F_GETFD) == -1 && errno == EBADF;    // FD_CLOEXEC: not inherited
    ok = ok && read(5, b, 1) == 1 && b[0] == '#';            // posix_spawn_file_actions_addopen
    ok = ok && getcwd(cwd, sizeof cwd) && strcmp(cwd, "/boot") == 0;
    return ok ? 10 : 2;
  }
  if (strcmp(argv[1], "env") == 0) {
    const char *greeting = getenv("GREETING");
    return greeting && strcmp(greeting, "hello") == 0 ? 4 : 2;
  }
  return 2;
}

static int spawn_wait(const char *path, bool search, const char *what, const posix_spawnattr_t *attr) {
  char parent[24];
  snprintf(parent, sizeof parent, "%d", (int)getpid());
  char *args[] = {"ctest", (char *)what, parent, "7", nullptr};
  pid_t child = 0;
  int err = search ? posix_spawnp(&child, path, nullptr, attr, args, environ)
                   : posix_spawn(&child, path, nullptr, attr, args, environ);
  if (err != 0) return -err;
  int status = 0;
  if (waitpid(child, &status, 0) != child || !WIFEXITED(status)) return -1000;
  return WEXITSTATUS(status);
}

// pids, groups and sessions through posixd; posix_spawn and wait.
static void test_processes(void) {
  pid_t me = getpid();
  CHECK(me >= 2 && getppid() == 1); // connected through /srv/posixd: a session of its own
  CHECK(getsid(0) == me && getpgrp() == me);
  errno = 0;
  CHECK(setsid() == -1 && errno == EPERM); // a group leader already
  int status;
  errno = 0;
  CHECK(waitpid(-1, &status, 0) == -1 && errno == ECHILD);

  CHECK(spawn_wait("/boot/bin/ctest", false, "exit", nullptr) == 7);
  CHECK(spawn_wait("/boot/bin/ctest", false, "env", nullptr) == 4);
  CHECK(spawn_wait("ctest", true, "exit", nullptr) == 7); // posix_spawnp, through PATH
  posix_spawnattr_t attr;
  posix_spawnattr_init(&attr);
  posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
  posix_spawnattr_setpgroup(&attr, 0);
  CHECK(spawn_wait("/boot/bin/ctest", false, "group", &attr) == 9);
  posix_spawnattr_destroy(&attr);
  CHECK(spawn_wait("/boot/bin/no-such-program", false, "exit", nullptr) == -ENOENT);

  // A child still running: WNOHANG finds nothing, then a wait finds it.
  char parent[24];
  snprintf(parent, sizeof parent, "%d", (int)me);
  char *args[] = {"ctest", "sleep", parent, nullptr};
  pid_t child = 0;
  CHECK(posix_spawn(&child, "/boot/bin/ctest", nullptr, nullptr, args, environ) == 0 && child > me);
  CHECK(getpgid(child) == me && getsid(child) == me);
  CHECK(waitpid(child, &status, WNOHANG) == 0);
  CHECK(waitpid(-1, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 3);
  errno = 0;
  CHECK(getpgid(child) == -1 && errno == ESRCH); // reaped
}

// Reads a pipe to its end.
static size_t read_all(int fd, char *buf, size_t cap) {
  size_t n = 0;
  for (ssize_t r; n < cap && (r = read(fd, buf + n, cap - n)) > 0;) n += (size_t)r;
  return n;
}

// fork, execve and pipes; descriptors given to children.
static void test_fork_exec_pipes(void) {
  static const char manifest[] = "/boot/svc/ctest.ndb"; // it starts "# tests/user/ctest.ndb"
  char buf[64] = {}, parent[24];
  pid_t me = getpid();
  snprintf(parent, sizeof parent, "%d", (int)me);
  int p[2], status = 0;
  CHECK(pipe(p) == 0);
  CHECK(write(p[1], "hello", 5) == 5 && read(p[0], buf, sizeof buf) == 5 && memcmp(buf, "hello", 5) == 0);
  int q[2];
  CHECK(pipe2(q, O_NONBLOCK) == 0);
  errno = 0;
  CHECK(read(q[0], buf, 1) == -1 && errno == EAGAIN);
  close(q[0]);
  close(q[1]);

  // fork: the child has memory and descriptors as they were, and its own
  // from then on; it reports through the pipe and its status.
  static int marker = 1;
  int file = open(manifest, O_RDONLY);
  CHECK(file >= 0 && lseek(file, 2, SEEK_SET) == 2);
  if (file < 0) return; // the rest needs it
  pid_t child = fork();
  if (child == 0) {
    char b[3] = {};
    bool ok = marker == 1 && getppid() == me && getpid() != me;
    ok = ok && read(file, b, 2) == 2 && memcmp(b, "te", 2) == 0;
    marker = 2;
    const char *say = ok ? "child ok" : "child bad";
    ok = write(p[1], say, strlen(say)) == (ssize_t)strlen(say) && ok;
    _exit(ok ? 5 : 1);
  }
  CHECK(child > me);
  close(p[1]); // the child's end is the last writer: the read ends when it exits
  memset(buf, 0, sizeof buf);
  CHECK(read_all(p[0], buf, sizeof buf - 1) == 8 && strcmp(buf, "child ok") == 0);
  close(p[0]);
  CHECK(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 5);
  CHECK(marker == 1);
  char b[3] = {};
  CHECK(read(file, b, 2) == 2 && memcmp(b, "te", 2) == 0); // the offset is not shared yet (M4 step 4)

  // fork, then execve: the program goes on as the same process.
  child = fork();
  if (child == 0) {
    char *args[] = {"ctest", "exit", parent, "6", nullptr};
    execv("/boot/bin/ctest", args);
    _exit(1);
  }
  CHECK(child > me && waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 6);
  child = fork();
  if (child == 0) {
    char *args[] = {"none", nullptr};
    _exit(execv("/boot/bin/no-such-program", args) == -1 && errno == ENOENT ? 11 : 1);
  }
  CHECK(waitpid(child, &status, 0) == child && WEXITSTATUS(status) == 11);

  // posix_spawn's file actions: the child's standard output into a pipe.
  CHECK(pipe(p) == 0);
  posix_spawn_file_actions_t fa;
  posix_spawn_file_actions_init(&fa);
  posix_spawn_file_actions_adddup2(&fa, p[1], 1);
  posix_spawn_file_actions_addclose(&fa, p[0]);
  posix_spawn_file_actions_addclose(&fa, p[1]);
  char *echo[] = {"ctest", "echo", parent, nullptr};
  CHECK(posix_spawn(&child, "/boot/bin/ctest", &fa, nullptr, echo, environ) == 0);
  posix_spawn_file_actions_destroy(&fa);
  close(p[1]);
  memset(buf, 0, sizeof buf);
  CHECK(read_all(p[0], buf, sizeof buf - 1) == 16 && strcmp(buf, "echo from child\n") == 0);
  close(p[0]);
  CHECK(waitpid(child, &status, 0) == child && WEXITSTATUS(status) == 8);

  // Inherited: a file at its offset, not one marked FD_CLOEXEC, one opened
  // by a file action, and the working directory.
  int keep = open(manifest, O_RDONLY | O_CLOEXEC);
  CHECK(keep >= 0 && dup3(keep, 4, O_CLOEXEC) == 4);
  posix_spawn_file_actions_init(&fa);
  posix_spawn_file_actions_adddup2(&fa, file, 3);
  posix_spawn_file_actions_addopen(&fa, 5, manifest, O_RDONLY, 0);
  CHECK(lseek(file, 2, SEEK_SET) == 2 && chdir("/boot") == 0);
  char *fds[] = {"ctest", "fds", parent, nullptr};
  CHECK(posix_spawn(&child, "/boot/bin/ctest", &fa, nullptr, fds, environ) == 0);
  CHECK(chdir("/") == 0);
  posix_spawn_file_actions_destroy(&fa);
  CHECK(waitpid(child, &status, 0) == child && WEXITSTATUS(status) == 10);
  close(4);
  close(keep);
  close(file);
}

int main(int argc, char **argv) {
  if (argc >= 3 && strcmp(argv[1], "one") != 0) return child_main(argv);
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

  test_processes();
  test_fork_exec_pipes();

  // No threads yet: pthread_create fails, and says so (docs/milestones.md).
  pthread_t thread;
  CHECK(pthread_create(&thread, nullptr, never_runs, nullptr) != 0);

  atexit(at_exit);
  fprintf(stderr, "ctest: to stderr\n");
  printf("ctest: %d checks, %d failed\n", checks, failed);
  return failed ? 1 : 0;
}
