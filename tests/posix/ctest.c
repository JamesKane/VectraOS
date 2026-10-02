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
#include <sched.h>
#include <setjmp.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/auxv.h>
#include <sys/ioctl.h>
#include <sys/random.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <termios.h>
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

static volatile sig_atomic_t signals[65]; // how many of each signal a handler saw
static volatile pid_t last_sender;
static sigjmp_buf fault_jump;
static void *volatile fault_address;

// An address nothing is mapped at, for the faults the tests make on purpose:
// made at run time, which keeps the static analyzer from flagging them.
static volatile int *nowhere_at(void) { return (volatile int *)(uintptr_t)strtoul("16", nullptr, 10); }

static void on_signal(int sig) { signals[sig]++; }

static void on_signal_info(int sig, siginfo_t *info, void *uc) {
  (void)uc;
  signals[sig]++;
  last_sender = info->si_pid;
}

static void on_fault(int sig, siginfo_t *info, void *uc) {
  (void)uc;
  signals[sig]++;
  fault_address = info->si_addr;
  siglongjmp(fault_jump, 1);
}

static int child_main(char **argv) {
  pid_t parent = (pid_t)strtol(argv[2], nullptr, 10);
  if (getppid() != parent || getpid() == parent || getsid(0) != getsid(parent)) return 1;
  if (strcmp(argv[1], "exit") == 0) return argv[3] ? (int)strtol(argv[3], nullptr, 10) : 7;
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
  if (strcmp(argv[1], "signal") == 0) return kill(parent, SIGUSR1) == 0 ? 12 : 2;
  if (strcmp(argv[1], "late") == 0) { // a signal to the parent while it sleeps
    nanosleep(&(struct timespec){.tv_nsec = 50'000'000}, nullptr);
    return kill(parent, SIGUSR1) == 0 ? 14 : 2;
  }
  if (strcmp(argv[1], "pause") == 0) { // ready (on its standard output), then waits for SIGUSR2
    struct sigaction sa = {.sa_handler = on_signal};
    sigset_t usr2, none;
    sigemptyset(&usr2);
    sigaddset(&usr2, SIGUSR2);
    sigemptyset(&none);
    sigprocmask(SIG_BLOCK, &usr2, nullptr); // so it cannot come between "ready" and the wait
    sigaction(SIGUSR2, &sa, nullptr);
    write(1, "ready", 5);
    bool interrupted = sigsuspend(&none) == -1 && errno == EINTR;
    return interrupted && signals[SIGUSR2] == 1 ? 13 : 2;
  }
  if (strcmp(argv[1], "segv") == 0) return *nowhere_at(); // default: the end, as SIGSEGV
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

static int spawn_child(const char *what, posix_spawn_file_actions_t *fa, pid_t *child) {
  char parent[24];
  snprintf(parent, sizeof parent, "%d", (int)getpid());
  char *args[] = {"ctest", (char *)what, parent, nullptr};
  return posix_spawn(child, "/boot/bin/ctest", fa, nullptr, args, environ);
}

static double now_seconds(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return seconds(&t);
}

// Signals: to itself, blocked and pending, ignored, between processes;
// faults; default actions; SIGCHLD; interrupted and restarted calls.
static void test_signals(void) {
  struct sigaction sa = {.sa_handler = on_signal},
                   info = {.sa_sigaction = on_signal_info, .sa_flags = SA_SIGINFO};
  CHECK(sigaction(SIGUSR1, &sa, nullptr) == 0);
  CHECK(raise(SIGUSR1) == 0 && signals[SIGUSR1] == 1); // delivered before raise returns
  sigset_t usr1, pending;
  sigemptyset(&usr1);
  sigaddset(&usr1, SIGUSR1);
  CHECK(sigprocmask(SIG_BLOCK, &usr1, nullptr) == 0);
  CHECK(raise(SIGUSR1) == 0 && signals[SIGUSR1] == 1); // blocked: pending
  CHECK(sigpending(&pending) == 0 && sigismember(&pending, SIGUSR1));
  CHECK(sigprocmask(SIG_UNBLOCK, &usr1, nullptr) == 0 && signals[SIGUSR1] == 2);
  CHECK(signal(SIGUSR2, SIG_IGN) != SIG_ERR && raise(SIGUSR2) == 0 && signals[SIGUSR2] == 0);
  signal(SIGUSR2, SIG_DFL);
  errno = 0;
  CHECK(sigaction(SIGKILL, &sa, nullptr) == -1 && errno == EINVAL);

  // From another process, with its pid; the wait it interrupts goes on (SA_RESTART).
  info.sa_flags |= SA_RESTART;
  CHECK(sigaction(SIGUSR1, &info, nullptr) == 0);
  pid_t child = 0;
  int status = 0;
  CHECK(spawn_child("signal", nullptr, &child) == 0);
  CHECK(waitpid(child, &status, 0) == child && WEXITSTATUS(status) == 12);
  for (double end = now_seconds() + 1; signals[SIGUSR1] < 3 && now_seconds() < end;) sched_yield();
  CHECK(signals[SIGUSR1] == 3 && last_sender == child);

  // To a child that waits for it.
  int p[2];
  CHECK(pipe(p) == 0);
  posix_spawn_file_actions_t fa;
  posix_spawn_file_actions_init(&fa);
  posix_spawn_file_actions_adddup2(&fa, p[1], 1);
  posix_spawn_file_actions_addclose(&fa, p[0]);
  CHECK(spawn_child("pause", &fa, &child) == 0);
  posix_spawn_file_actions_destroy(&fa);
  close(p[1]);
  char ready[8] = {};
  CHECK(read(p[0], ready, 5) == 5 && strcmp(ready, "ready") == 0);
  close(p[0]);
  CHECK(kill(child, SIGUSR2) == 0);
  CHECK(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 13);

  // Default actions: the end, with the signal in the wait status.
  CHECK(spawn_child("sleep", nullptr, &child) == 0 && kill(child, SIGTERM) == 0);
  CHECK(waitpid(child, &status, 0) == child && WIFSIGNALED(status) && WTERMSIG(status) == SIGTERM);
  CHECK(spawn_child("sleep", nullptr, &child) == 0 && kill(child, SIGKILL) == 0);
  CHECK(waitpid(child, &status, 0) == child && WIFSIGNALED(status) && WTERMSIG(status) == SIGKILL);
  CHECK(spawn_child("segv", nullptr, &child) == 0);
  CHECK(waitpid(child, &status, 0) == child && WIFSIGNALED(status) && WTERMSIG(status) == SIGSEGV);
  errno = 0;
  CHECK(kill(99999, SIGTERM) == -1 && errno == ESRCH);

  // A fault caught, and left by siglongjmp.
  struct sigaction fault = {.sa_sigaction = on_fault, .sa_flags = SA_SIGINFO};
  CHECK(sigaction(SIGSEGV, &fault, nullptr) == 0);
  if (sigsetjmp(fault_jump, 1) == 0) (void)*nowhere_at();
  CHECK(signals[SIGSEGV] == 1 && fault_address == (void *)nowhere_at());
  signal(SIGSEGV, SIG_DFL);

  // SIGCHLD, after the wait's answer.
  CHECK(sigaction(SIGCHLD, &(struct sigaction){.sa_handler = on_signal, .sa_flags = SA_RESTART}, nullptr) ==
        0);
  // An earlier child's may still be on its way: this one's adds at least one.
  int before = signals[SIGCHLD];
  CHECK(spawn_child("exit", nullptr, &child) == 0);
  CHECK(waitpid(child, &status, 0) == child);
  for (double end = now_seconds() + 1; signals[SIGCHLD] <= before && now_seconds() < end;) sched_yield();
  CHECK(signals[SIGCHLD] > before);
  signal(SIGCHLD, SIG_DFL);

  // A sleep a handler interrupts ends with EINTR and what was left; one that
  // an ignored signal (SIGCHLD by default) interrupts goes on to its end.
  CHECK(sigaction(SIGUSR1, &sa, nullptr) == 0); // not SA_RESTART
  CHECK(spawn_child("late", nullptr, &child) == 0);
  struct timespec rem = {};
  double t0 = now_seconds();
  CHECK(nanosleep(&(struct timespec){.tv_sec = 2}, &rem) == -1 && errno == EINTR && rem.tv_sec >= 1);
  CHECK(now_seconds() - t0 < 1.5);
  CHECK(waitpid(child, &status, 0) == child && WEXITSTATUS(status) == 14);
  CHECK(spawn_child("exit", nullptr, &child) == 0); // its SIGCHLD comes during the sleep
  t0 = now_seconds();
  CHECK(nanosleep(&(struct timespec){.tv_nsec = 300'000'000}, nullptr) == 0 && now_seconds() - t0 >= 0.3);
  CHECK(waitpid(child, &status, 0) == child);
  signal(SIGUSR1, SIG_DFL);
}

static bool all_zero(const unsigned char *p, size_t n) {
  for (size_t i = 0; i < n; i++)
    if (p[i]) return false;
  return true;
}

// /tmp (tmpfs), /dev's null, zero and urandom (nullfs), getrandom.
static void test_tmp_and_devices(void) {
  char buf[64] = {};
  errno = 0;
  CHECK(mkdir("/tmp/d", 0755) == 0);
  CHECK(mkdir("/tmp/d", 0755) == -1 && errno == EEXIST); // made already
  FILE *f = fopen("/tmp/d/a.txt", "w");
  CHECK(f && fputs("hello tmp\n", f) >= 0 && fclose(f) == 0);
  struct stat st;
  CHECK(stat("/tmp/d/a.txt", &st) == 0 && S_ISREG(st.st_mode) && st.st_size == 10);
  f = fopen("/tmp/d/a.txt", "a");
  CHECK(f && fputs("more\n", f) >= 0 && fclose(f) == 0);
  f = fopen("/tmp/d/a.txt", "r");
  CHECK(f && fread(buf, 1, sizeof buf - 1, f) == 15 && strcmp(buf, "hello tmp\nmore\n") == 0);
  if (f) fclose(f);
  DIR *d = opendir("/tmp/d");
  struct dirent *e = d ? readdir(d) : nullptr;
  CHECK(e && strcmp(e->d_name, "a.txt") == 0 && !readdir(d));
  if (d) closedir(d);

  // Removed while open: gone from its directory, still readable.
  int fd = open("/tmp/d/a.txt", O_RDONLY);
  CHECK(fd >= 0 && unlink("/tmp/d/a.txt") == 0);
  errno = 0;
  CHECK(stat("/tmp/d/a.txt", &st) == -1 && errno == ENOENT);
  memset(buf, 0, sizeof buf);
  CHECK(read(fd, buf, 5) == 5 && memcmp(buf, "hello", 5) == 0);
  close(fd);

  // A hole reads as zeros; truncation; a directory goes only when empty.
  fd = open("/tmp/d/hole", O_RDWR | O_CREAT, 0644);
  CHECK(fd >= 0 && pwrite(fd, "x", 1, 100) == 1);
  if (fd < 0) return; // the rest needs it
  unsigned char c = 0xff;
  CHECK(pread(fd, &c, 1, 50) == 1 && c == 0 && fstat(fd, &st) == 0 && st.st_size == 101);
  close(fd);
  CHECK(rmdir("/tmp/d") == -1); // not empty
  fd = open("/tmp/d/hole", O_WRONLY | O_TRUNC);
  CHECK(fd >= 0 && fstat(fd, &st) == 0 && st.st_size == 0);
  close(fd);
  CHECK(unlink("/tmp/d/hole") == 0 && rmdir("/tmp/d") == 0);
  errno = 0;
  CHECK(opendir("/tmp/d") == nullptr && errno == ENOENT);

  // /dev.
  fd = open("/dev/null", O_RDWR);
  CHECK(fd >= 0 && write(fd, "gone", 4) == 4 && read(fd, buf, sizeof buf) == 0);
  close(fd);
  unsigned char zeros[16], r1[32] = {}, r2[32] = {};
  memset(zeros, 0xff, sizeof zeros);
  fd = open("/dev/zero", O_RDONLY);
  CHECK(fd >= 0 && read(fd, zeros, sizeof zeros) == 16 && all_zero(zeros, sizeof zeros));
  close(fd);
  fd = open("/dev/urandom", O_RDONLY);
  CHECK(fd >= 0 && read(fd, r1, sizeof r1) == 32 && read(fd, r2, sizeof r2) == 32);
  CHECK(!all_zero(r1, sizeof r1) && memcmp(r1, r2, sizeof r1) != 0);
  close(fd);
  CHECK(getrandom(r1, sizeof r1, 0) == 32 && memcmp(r1, r2, sizeof r1) != 0 && !all_zero(r1, sizeof r1));
  CHECK(getauxval(AT_RANDOM) != 0);
}

static bool write_file(const char *path, const char *text) {
  FILE *f = fopen(path, "w");
  bool ok = f && fputs(text, f) >= 0;
  return f && fclose(f) == 0 && ok;
}

static bool file_is(const char *path, const char *text) {
  char buf[64] = {};
  FILE *f = fopen(path, "r");
  size_t n = f ? fread(buf, 1, sizeof buf - 1, f) : 0;
  if (f) fclose(f);
  return f && n == strlen(text) && memcmp(buf, text, n) == 0;
}

// The posix and xattr extensions, through tmpfs: rename, symbolic links,
// chmod, truncate, utimensat, fsync.
static void test_names_and_attributes(void) {
  struct stat st;
  char buf[64] = {};
  CHECK(write_file("/tmp/r1", "renamed") && mkdir("/tmp/rd", 0755) == 0);
  CHECK(rename("/tmp/r1", "/tmp/r2") == 0 && stat("/tmp/r1", &st) == -1 && file_is("/tmp/r2", "renamed"));
  CHECK(rename("/tmp/r2", "/tmp/rd/r3") == 0 && file_is("/tmp/rd/r3", "renamed")); // across directories
  CHECK(write_file("/tmp/other", "replaced") && rename("/tmp/other", "/tmp/rd/r3") == 0);
  CHECK(file_is("/tmp/rd/r3", "replaced") && stat("/tmp/other", &st) == -1);
  errno = 0;
  CHECK(rename("/tmp/rd", "/tmp/rd/inside") == -1 && errno == EINVAL);
  errno = 0;
  CHECK(rename("/tmp/rd/r3", "/boot/r3") == -1 && errno == EXDEV); // another server

  // Symbolic links: read, followed (at the end and on the way), or not.
  CHECK(symlink("rd/r3", "/tmp/ln") == 0);
  ssize_t n = readlink("/tmp/ln", buf, sizeof buf);
  CHECK(n == 5 && memcmp(buf, "rd/r3", 5) == 0);
  CHECK(lstat("/tmp/ln", &st) == 0 && S_ISLNK(st.st_mode));
  CHECK(stat("/tmp/ln", &st) == 0 && S_ISREG(st.st_mode) && st.st_size == 8 &&
        file_is("/tmp/ln", "replaced"));
  CHECK(symlink("/tmp/rd", "/tmp/dl") == 0 && file_is("/tmp/dl/r3", "replaced"));
  bool saw_link = false;
  DIR *d = opendir("/tmp");
  for (struct dirent *e; d && (e = readdir(d));)
    if (strcmp(e->d_name, "ln") == 0) saw_link = e->d_type == DT_LNK;
  if (d) closedir(d);
  CHECK(saw_link);
  CHECK(symlink("/tmp/nothing", "/tmp/dangling") == 0 && lstat("/tmp/dangling", &st) == 0);
  errno = 0;
  CHECK(stat("/tmp/dangling", &st) == -1 && errno == ENOENT);
  CHECK(symlink("/tmp/loop", "/tmp/loop") == 0);
  errno = 0;
  CHECK(open("/tmp/loop", O_RDONLY) == -1 && errno == ELOOP);
  errno = 0;
  CHECK(open("/tmp/ln", O_RDONLY | O_NOFOLLOW) == -1 && errno == ELOOP);
  CHECK(unlink("/tmp/ln") == 0 && lstat("/tmp/ln", &st) == -1 &&
        stat("/tmp/rd/r3", &st) == 0); // the link only
  errno = 0;
  CHECK(readlink("/tmp/rd/r3", buf, sizeof buf) == -1 && errno == EINVAL); // not a link

  // Attributes.
  CHECK(chmod("/tmp/rd/r3", 0600) == 0 && stat("/tmp/rd/r3", &st) == 0 && (st.st_mode & 0777) == 0600);
  int fd = open("/tmp/rd/r3", O_RDWR);
  CHECK(fd >= 0);
  if (fd < 0) return; // the rest needs it
  CHECK(fchmod(fd, 0640) == 0 && fstat(fd, &st) == 0 && (st.st_mode & 0777) == 0640);
  CHECK(truncate("/tmp/rd/r3", 3) == 0 && stat("/tmp/rd/r3", &st) == 0 && st.st_size == 3);
  CHECK(ftruncate(fd, 10) == 0 && fstat(fd, &st) == 0 && st.st_size == 10);
  unsigned char tail[7];
  memset(tail, 0xff, sizeof tail);
  CHECK(pread(fd, tail, sizeof tail, 3) == 7 && all_zero(tail, sizeof tail)); // grown with zeros
  CHECK(fsync(fd) == 0 && fdatasync(fd) == 0);
  CHECK(utimensat(AT_FDCWD, "/tmp/rd/r3", (struct timespec[]){{.tv_nsec = UTIME_OMIT}, {.tv_sec = 1000}},
                  0) == 0);
  CHECK(stat("/tmp/rd/r3", &st) == 0 && st.st_mtime == 1000);
  CHECK(futimens(fd, nullptr) == 0 && fstat(fd, &st) == 0 && st.st_mtime != 1000); // now
  CHECK(chown("/tmp/rd/r3", 0, 0) == 0); // owners are not kept, and no one may not
  errno = 0;
  CHECK(link("/tmp/rd/r3", "/tmp/hard") == -1 && errno == EPERM);
  close(fd);
  CHECK(unlink("/tmp/dl") == 0 && unlink("/tmp/dangling") == 0 && unlink("/tmp/loop") == 0);
  CHECK(unlink("/tmp/rd/r3") == 0 && rmdir("/tmp/rd") == 0);
}

// The posix extension's open files, kept by the server: a child's writes
// move its parent's offset; O_APPEND is the server's; locks between
// processes.
static void test_shared_offsets_and_locks(void) {
  struct stat st;
  int status = 0;
  int fd = open("/tmp/shared", O_RDWR | O_CREAT | O_TRUNC, 0644);
  CHECK(fd >= 0);
  if (fd < 0) return;
  CHECK(write(fd, "ab", 2) == 2);
  pid_t child = fork();
  if (child == 0) _exit(write(fd, "cd", 2) == 2 ? 0 : 1); // at the offset it shares
  CHECK(child > 0 && waitpid(child, &status, 0) == child && WEXITSTATUS(status) == 0);
  CHECK(lseek(fd, 0, SEEK_CUR) == 4 && write(fd, "ef", 2) == 2 && file_is("/tmp/shared", "abcdef"));
  CHECK(lseek(fd, -1, SEEK_END) == 5);

  // A child's standard output, twice, then the parent's: in that order.
  int out = open("/tmp/sequence", O_WRONLY | O_CREAT | O_TRUNC, 0644);
  CHECK(out >= 0);
  posix_spawn_file_actions_t fa;
  posix_spawn_file_actions_init(&fa);
  posix_spawn_file_actions_adddup2(&fa, out, 1);
  for (int i = 0; i < 2; i++) {
    CHECK(spawn_child("echo", &fa, &child) == 0);
    CHECK(waitpid(child, &status, 0) == child && WEXITSTATUS(status) == 8);
  }
  posix_spawn_file_actions_destroy(&fa);
  CHECK(write(out, "parent\n", 7) == 7);
  close(out);
  CHECK(file_is("/tmp/sequence", "echo from child\necho from child\nparent\n"));

  // O_APPEND through two opens of one file: each write at the end.
  int a = open("/tmp/shared", O_WRONLY | O_APPEND), b = open("/tmp/shared", O_WRONLY | O_APPEND);
  CHECK(a >= 0 && b >= 0 && write(a, "1", 1) == 1 && write(b, "2", 1) == 1 && write(a, "3", 1) == 1);
  CHECK(file_is("/tmp/shared", "abcdef123"));
  close(a);
  close(b);

  // Locks: a child cannot take what the parent holds, and sees who holds it.
  struct flock whole = {.l_type = F_WRLCK, .l_whence = SEEK_SET}, first = {.l_type = F_WRLCK, .l_len = 4};
  CHECK(fcntl(fd, F_SETLK, &first) == 0);
  pid_t me = getpid();
  child = fork();
  if (child == 0) {
    struct flock probe = whole, other = {.l_type = F_WRLCK, .l_start = 4, .l_len = 4};
    bool ok = fcntl(fd, F_SETLK, &(struct flock){.l_type = F_WRLCK}) == -1 && errno == EAGAIN;
    ok = ok && fcntl(fd, F_GETLK, &probe) == 0 && probe.l_type == F_WRLCK && probe.l_pid == me;
    ok = ok && probe.l_start == 0 && probe.l_len == 4;
    ok = ok && fcntl(fd, F_SETLK, &other) == 0; // the bytes after: free
    ok = ok && fcntl(fd, F_SETLKW, &(struct flock){.l_type = F_RDLCK, .l_len = 4}) == 0; // once let go
    _exit(ok ? 0 : 1);
  }
  nanosleep(&(struct timespec){.tv_nsec = 100'000'000}, nullptr);
  CHECK(fcntl(fd, F_SETLK, &(struct flock){.l_type = F_UNLCK, .l_len = 4}) == 0); // the child's wait ends
  CHECK(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
  CHECK(fcntl(fd, F_SETLK, &whole) == 0); // the child's went with it
  close(fd);
  CHECK(stat("/tmp/shared", &st) == 0 && unlink("/tmp/shared") == 0 && unlink("/tmp/sequence") == 0);
}

// Reads what the master has now: the slave's output and echo.
static size_t master_read(int m, char *buf, size_t cap) {
  ssize_t n = read(m, buf, cap - 1);
  buf[n > 0 ? n : 0] = 0;
  return n > 0 ? (size_t)n : 0;
}

// ptyd's terminals and job control.
static void test_terminals(void) {
  char buf[64];
  int m = posix_openpt(O_RDWR | O_NOCTTY);
  CHECK(m >= 0 && grantpt(m) == 0 && unlockpt(m) == 0);
  if (m < 0) return;
  const char *name = ptsname(m);
  CHECK(name && strcmp(name, "/dev/pts/0") == 0);
  int s = open(name ? name : "/dev/pts/0", O_RDWR | O_NOCTTY);
  CHECK(s >= 0);
  if (s < 0) return;
  struct stat st;
  CHECK(isatty(s) && isatty(m) && fstat(s, &st) == 0 && S_ISCHR(st.st_mode));
  int plain = open("/boot/svc/ctest.ndb", O_RDONLY);
  CHECK(plain >= 0);
  if (plain >= 0) {
    CHECK(!isatty(plain));
    close(plain);
  }
  struct termios t;
  CHECK(tcgetattr(s, &t) == 0 && (t.c_lflag & ICANON) && (t.c_lflag & ECHO) && cfgetospeed(&t) == B38400);

  // Cooked input: CR made NL, echoed (as CR NL), one line a read; erase.
  CHECK(write(m, "hello\r", 6) == 6 && read(s, buf, sizeof buf) == 6 && memcmp(buf, "hello\n", 6) == 0);
  CHECK(master_read(m, buf, sizeof buf) == 7 && strcmp(buf, "hello\r\n") == 0);
  CHECK(write(m,
              "ab\x7f"
              "c\n",
              5) == 5 &&
        read(s, buf, sizeof buf) == 3 && memcmp(buf, "ac\n", 3) == 0);
  master_read(m, buf, sizeof buf);
  CHECK(write(s, "out\n", 4) == 4 && master_read(m, buf, sizeof buf) == 5 && strcmp(buf, "out\r\n") == 0);
  CHECK(write(m, "\x04", 1) == 1 && read(s, buf, sizeof buf) == 0); // ^D on an empty line

  // Raw input, a byte at a time and not echoed; then cooked again.
  struct termios raw = t;
  raw.c_lflag &= ~(tcflag_t)(ICANON | ECHO);
  CHECK(tcsetattr(s, TCSANOW, &raw) == 0 && tcgetattr(s, &raw) == 0 && !(raw.c_lflag & ICANON));
  CHECK(write(m, "xy", 2) == 2 && read(s, buf, 1) == 1 && buf[0] == 'x' && read(s, buf, 8) == 1 &&
        buf[0] == 'y');
  CHECK(tcsetattr(s, TCSAFLUSH, &t) == 0);

  // The window's size, set at the master, read at the slave.
  CHECK(ioctl(m, TIOCSWINSZ, &(struct winsize){.ws_row = 30, .ws_col = 100}) == 0);
  struct winsize w = {};
  CHECK(ioctl(s, TIOCGWINSZ, &w) == 0 && w.ws_row == 30 && w.ws_col == 100);

  // ^C: SIGINT to the foreground group, which ends a read waiting for input.
  CHECK(tcsetpgrp(s, getpgrp()) == 0 && tcgetpgrp(s) == getpgrp());
  CHECK(sigaction(SIGINT, &(struct sigaction){.sa_handler = on_signal}, nullptr) == 0); // not SA_RESTART
  int before = signals[SIGINT], status = 0;
  pid_t child = fork();
  if (child == 0) _exit(read(s, buf, sizeof buf) == -1 && errno == EINTR ? 21 : 1);
  nanosleep(&(struct timespec){.tv_nsec = 100'000'000}, nullptr);
  CHECK(write(m, "\x03", 1) == 1);
  CHECK(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 21);
  for (double end = now_seconds() + 1; signals[SIGINT] <= before && now_seconds() < end;) sched_yield();
  CHECK(signals[SIGINT] > before); // the parent is in the group too
  signal(SIGINT, SIG_DFL);
  master_read(m, buf, sizeof buf); // the ^C's echo

  // Job control: SIGSTOP, then SIGCONT, as waitpid reports them; a stopping
  // signal's default stops.
  child = fork();
  if (child == 0)
    for (;;) pause();
  CHECK(kill(child, SIGSTOP) == 0);
  CHECK(waitpid(child, &status, WUNTRACED) == child && WIFSTOPPED(status) && WSTOPSIG(status) == SIGSTOP);
  CHECK(kill(child, SIGCONT) == 0);
  CHECK(waitpid(child, &status, WCONTINUED) == child && WIFCONTINUED(status));
  CHECK(kill(child, SIGTERM) == 0);
  CHECK(waitpid(child, &status, 0) == child && WIFSIGNALED(status) && WTERMSIG(status) == SIGTERM);
  child = fork();
  if (child == 0) _exit(raise(SIGTSTP) == 0 ? 22 : 1);
  CHECK(waitpid(child, &status, WUNTRACED) == child && WIFSTOPPED(status) && WSTOPSIG(status) == SIGTSTP);
  CHECK(kill(child, SIGCONT) == 0);
  CHECK(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 22);

  // The master gone, the slave reads the end of its file.
  close(m);
  CHECK(read(s, buf, sizeof buf) == 0);
  close(s);
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
  test_signals();
  test_tmp_and_devices();
  test_names_and_attributes();
  test_shared_offsets_and_locks();
  test_terminals();

  // No threads yet: pthread_create fails, and says so (docs/milestones.md).
  pthread_t thread;
  CHECK(pthread_create(&thread, nullptr, never_runs, nullptr) != 0);

  atexit(at_exit);
  fprintf(stderr, "ctest: to stderr\n");
  printf("ctest: %d checks, %d failed\n", checks, failed);
  return failed ? 1 : 0;
}
