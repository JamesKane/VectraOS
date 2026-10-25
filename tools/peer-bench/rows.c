// D127's rows, the same program on VectraOS, Linux and FreeBSD: one
// portable C source built by our bundled clang for each (on the peers
// against a sysroot copied from the board, host-only, D4). C because the
// program must be the same on all three OSes, and the peers run no Swift.
//
//   peer-bench [-c CPU,CPU] [-d DIR] [ROW ...]
//
// Each row prints `budget name=peer.<row> value=<v> unit=<u>` lines.
// -c pins the main thread to the first CPU and a partner to the second
// (the OS's numbers for the same two cores, chosen by MPIDR by the
// caller); -d is where the file rows make their files (cached rows: any
// file system). With no ROW, every row here runs. Rows not here (the
// bench drive's, the network's, the loaded latency rows, footprint) are
// run by each OS's harness (README.md).

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <ftw.h>
#include <pthread.h>
#include <sched.h>
#include <spawn.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#if defined(__FreeBSD__)
#include <sys/cpuset.h>
#include <sys/param.h>
#include <pthread_np.h>
#include <sys/syscall.h>
#elif defined(__linux__)
#include <sys/syscall.h>
#endif

extern char **environ;

static int cpu_main = -1, cpu_partner = -1;
static const char *dir = ".";
static char self_dir[1024] = ".";

static uint64_t now_ns(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
}

static void budget(const char *row, const char *suffix, double value, const char *unit) {
  printf("budget name=peer.%s%s value=%.0f unit=%s\n", row, suffix, value, unit);
  fflush(stdout);
}

static void pin(int cpu) {
  if (cpu < 0) return;
#if defined(__FreeBSD__)
  cpuset_t set;
  CPU_ZERO(&set);
  CPU_SET(cpu, &set);
  if (pthread_setaffinity_np(pthread_self(), sizeof set, &set) != 0) fprintf(stderr, "peer-bench: can't pin to %d\n", cpu);
#elif defined(__linux__)
  cpu_set_t set;
  CPU_ZERO(&set);
  CPU_SET(cpu, &set);
  if (pthread_setaffinity_np(pthread_self(), sizeof set, &set) != 0) fprintf(stderr, "peer-bench: can't pin to %d\n", cpu);
#else
  (void)cpu;  // VectraOS: the harness pins (to come with its column)
#endif
}

static int compare_u64(const void *a, const void *b) {
  uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
  return x < y ? -1 : x > y;
}

static uint64_t percentile(uint64_t *v, size_t n, double p) {
  qsort(v, n, sizeof *v, compare_u64);
  size_t i = (size_t)(p * (double)(n - 1) + 0.5);
  return v[i < n ? i : n - 1];
}

// syscall_null (best column): the cheapest real kernel entry.
static void row_syscall_null(void) {
  enum { N = 10000 };
  for (int i = 0; i < 1000; i++) (void)getppid();
  uint64_t t0 = now_ns();
  for (int i = 0; i < N; i++) {
#if defined(SYS_getppid)
    (void)syscall(SYS_getppid);
#else
    (void)getppid();
#endif
  }
  budget("syscall_null", "", (double)(now_ns() - t0) / N, "ns");
}

// ipc_rtt_same, ipc_rtt_cross (same column): a byte each way over two
// pipes between two threads, on one core and across two; median of 10k.
struct pingpong {
  int to[2], from[2];
  int cpu;
};

static void *pong(void *arg) {
  struct pingpong *p = arg;
  pin(p->cpu);
  char c;
  while (read(p->to[0], &c, 1) == 1) {
    if (c == 'q') break;
    if (write(p->from[1], &c, 1) != 1) break;
  }
  return NULL;
}

static void ipc_rtt(const char *row, int partner) {
  enum { N = 10000, WARM = 1000 };
  struct pingpong p = {.cpu = partner};
  if (pipe(p.to) != 0 || pipe(p.from) != 0) return;
  pthread_t t;
  pthread_create(&t, NULL, pong, &p);
  static uint64_t lat[N];
  char c = 'x';
  for (int i = 0; i < N + WARM; i++) {
    uint64_t t0 = now_ns();
    if (write(p.to[1], &c, 1) != 1 || read(p.from[0], &c, 1) != 1) break;
    if (i >= WARM) lat[i - WARM] = now_ns() - t0;
  }
  c = 'q';
  (void)write(p.to[1], &c, 1);
  pthread_join(t, NULL);
  close(p.to[0]), close(p.to[1]), close(p.from[0]), close(p.from[1]);
  budget(row, "", (double)percentile(lat, N, 0.5), "ns");
}

static void row_ipc_rtt_same(void) { ipc_rtt("ipc_rtt_same", cpu_main); }
static void row_ipc_rtt_cross(void) { ipc_rtt("ipc_rtt_cross", cpu_partner); }

// wake_cross: a waiter on the partner core woken through a condition
// variable; from the signal to the waiter running; median and p99 of 2k.
static pthread_mutex_t wake_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t wake_cond = PTHREAD_COND_INITIALIZER;
static uint64_t wake_sent;
static int wake_round = 0, wake_seen = 0, wake_stop = 0;
static _Atomic int waiter_ready = 0;
enum { WAKES = 2000 };
static uint64_t wake_lat[WAKES];

static void *waiter(void *arg) {
  (void)arg;
  pin(cpu_partner);
  pthread_mutex_lock(&wake_lock);
  for (;;) {
    atomic_store(&waiter_ready, 1);
    while (wake_round == wake_seen && !wake_stop) pthread_cond_wait(&wake_cond, &wake_lock);
    if (wake_stop) break;
    uint64_t t = now_ns();
    if (wake_seen < WAKES) wake_lat[wake_seen] = t - wake_sent;
    wake_seen = wake_round;
  }
  pthread_mutex_unlock(&wake_lock);
  return NULL;
}

static void row_wake_cross(void) {
  pthread_t t;
  pthread_create(&t, NULL, waiter, NULL);
  for (int i = 0; i < WAKES; i++) {
    // The waiter asleep in its wait before the next signal.
    while (!atomic_load(&waiter_ready)) sched_yield();
    struct timespec pause = {0, 200000};
    nanosleep(&pause, NULL);
    pthread_mutex_lock(&wake_lock);
    atomic_store(&waiter_ready, 0);
    wake_sent = now_ns();
    wake_round = i + 1;
    pthread_cond_signal(&wake_cond);
    pthread_mutex_unlock(&wake_lock);
  }
  while (!atomic_load(&waiter_ready)) sched_yield();
  pthread_mutex_lock(&wake_lock);
  wake_stop = 1;
  pthread_cond_signal(&wake_cond);
  pthread_mutex_unlock(&wake_lock);
  pthread_join(t, NULL);
  budget("wake_cross", ".p50", (double)percentile(wake_lat, WAKES, 0.5), "ns");
  budget("wake_cross", ".p99", (double)percentile(wake_lat, WAKES, 0.99), "ns");
}

// fault_anon: touch a fresh 64 MiB anonymous mapping; ns per page.
static void row_fault_anon(void) {
  size_t size = 64u << 20, page = (size_t)sysconf(_SC_PAGESIZE);
  char *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
  if (p == MAP_FAILED) return;
  uint64_t t0 = now_ns();
  for (size_t i = 0; i < size; i += page) p[i] = 1;
  uint64_t t = now_ns() - t0;
  munmap(p, size);
  budget("fault_anon", "", (double)t / (double)(size / page), "ns");
}

// map_unmap: map and unmap 4 KiB and 2 MiB, 10k each; mean.
static void map_unmap(const char *suffix, size_t size) {
  enum { N = 10000 };
  uint64_t t0 = now_ns();
  for (int i = 0; i < N; i++) {
    void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (p == MAP_FAILED) return;
    munmap(p, size);
  }
  budget("map_unmap", suffix, (double)(now_ns() - t0) / N, "ns");
}

static void row_map_unmap(void) {
  map_unmap(".4k", 4096);
  map_unmap(".2m", 2u << 20);
}

// spawn_exit_static, spawn_exit_linked: posix_spawn of hello until
// waitpid returns; median of 200.
static void spawn_exit(const char *row, const char *program) {
  enum { N = 200 };
  static uint64_t lat[N];
  char path[1100];
  snprintf(path, sizeof path, "%s/%s", self_dir, program);
  char *argv[] = {path, NULL};
  for (int i = 0; i < N + 10; i++) {
    uint64_t t0 = now_ns();
    pid_t pid;
    if (posix_spawn(&pid, path, NULL, NULL, argv, environ) != 0) {
      fprintf(stderr, "peer-bench: can't spawn %s\n", path);
      return;
    }
    int status;
    waitpid(pid, &status, 0);
    if (i >= 10) lat[i - 10] = now_ns() - t0;
  }
  budget(row, "", (double)percentile(lat, N, 0.5), "ns");
}

static void row_spawn_exit_static(void) { spawn_exit("spawn_exit_static", "hello-static"); }
static void row_spawn_exit_linked(void) { spawn_exit("spawn_exit_linked", "hello-linked"); }

// thread_create: create and join a thread, 1k; mean.
static void *nothing(void *arg) { return arg; }

static void row_thread_create(void) {
  enum { N = 1000 };
  uint64_t t0 = now_ns();
  for (int i = 0; i < N; i++) {
    pthread_t t;
    pthread_create(&t, NULL, nothing, NULL);
    pthread_join(t, NULL);
  }
  budget("thread_create", "", (double)(now_ns() - t0) / N, "ns");
}

// clock_mono: clock_gettime(CLOCK_MONOTONIC), 1M; mean.
static void row_clock_mono(void) {
  enum { N = 1000000 };
  struct timespec t;
  uint64_t t0 = now_ns();
  for (int i = 0; i < N; i++) clock_gettime(CLOCK_MONOTONIC, &t);
  budget("clock_mono", "", (double)(now_ns() - t0) / N, "ns");
}

// small_read: open, read and close a 64-byte file, 10k (cached); mean.
static void row_small_read(void) {
  enum { N = 10000 };
  char path[1100], buf[128];
  snprintf(path, sizeof path, "%s/peer-small", dir);
  int fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0644);
  if (fd < 0) return;
  memset(buf, 'a', 64);
  (void)write(fd, buf, 64);
  close(fd);
  for (int i = 0; i < 100; i++) {
    fd = open(path, O_RDONLY);
    (void)read(fd, buf, sizeof buf);
    close(fd);
  }
  uint64_t t0 = now_ns();
  for (int i = 0; i < N; i++) {
    fd = open(path, O_RDONLY);
    (void)read(fd, buf, sizeof buf);
    close(fd);
  }
  budget("small_read", "", (double)(now_ns() - t0) / N, "ns");
  unlink(path);
}

// read_4k: pread of 4 KiB from a cached 1 MiB file, 100k at offsets
// through it; mean.
static void row_read_4k(void) {
  enum { N = 100000, SIZE = 1 << 20 };
  char path[1100];
  static char buf[SIZE];
  snprintf(path, sizeof path, "%s/peer-4k", dir);
  int fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0644);
  if (fd < 0) return;
  memset(buf, 'b', SIZE);
  (void)write(fd, buf, SIZE);
  for (int i = 0; i < SIZE / 4096; i++) (void)pread(fd, buf, 4096, (off_t)i * 4096);
  uint64_t t0 = now_ns();
  for (int i = 0; i < N; i++) (void)pread(fd, buf, 4096, (off_t)(i % (SIZE / 4096)) * 4096);
  budget("read_4k", "", (double)(now_ns() - t0) / N, "ns");
  close(fd);
  unlink(path);
}

// tree_walk: nftw with stat over 100k entries (cached): 100 directories
// of 1000 empty files, made once and kept in DIR/peer-tree; ns per entry.
static long walked;
static int count_entry(const char *path, const struct stat *s, int type, struct FTW *f) {
  (void)path, (void)s, (void)type, (void)f;
  walked++;
  return 0;
}

static void row_tree_walk(void) {
  char root[1100], path[1200];
  snprintf(root, sizeof root, "%s/peer-tree", dir);
  struct stat s;
  if (stat(root, &s) != 0) {
    mkdir(root, 0755);
    for (int d = 0; d < 100; d++) {
      snprintf(path, sizeof path, "%s/d%03d", root, d);
      mkdir(path, 0755);
      for (int f = 0; f < 1000; f++) {
        snprintf(path, sizeof path, "%s/d%03d/f%04d", root, d, f);
        int fd = open(path, O_CREAT | O_WRONLY, 0644);
        if (fd >= 0) close(fd);
      }
    }
  }
  walked = 0;
  nftw(root, count_entry, 64, FTW_PHYS);  // warms the caches
  walked = 0;
  uint64_t t0 = now_ns();
  nftw(root, count_entry, 64, FTW_PHYS);
  uint64_t t = now_ns() - t0;
  if (walked > 0) budget("tree_walk", "", (double)t / (double)walked, "ns");
}

// timer_wake_idle: a thread woken every 1 ms for 60 s by an absolute
// sleep; wake error p50, p99 and p99.9 (cyclictest's shape).
static void row_timer_wake_idle(void) {
  enum { N = 60000 };
  static uint64_t err[N];
  struct timespec next;
  clock_gettime(CLOCK_MONOTONIC, &next);
  for (int i = 0; i < N; i++) {
    next.tv_nsec += 1000000;
    if (next.tv_nsec >= 1000000000) next.tv_nsec -= 1000000000, next.tv_sec++;
    while (clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &next, NULL) == EINTR) {}
    uint64_t woke = now_ns(), due = (uint64_t)next.tv_sec * 1000000000u + (uint64_t)next.tv_nsec;
    err[i] = woke > due ? woke - due : 0;
  }
  budget("timer_wake_idle", ".p50", (double)percentile(err, N, 0.5), "ns");
  budget("timer_wake_idle", ".p99", (double)percentile(err, N, 0.99), "ns");
  budget("timer_wake_idle", ".p999", (double)percentile(err, N, 0.999), "ns");
}

static const struct {
  const char *name;
  void (*run)(void);
} rows[] = {
    {"syscall_null", row_syscall_null},
    {"ipc_rtt_same", row_ipc_rtt_same},
    {"ipc_rtt_cross", row_ipc_rtt_cross},
    {"wake_cross", row_wake_cross},
    {"fault_anon", row_fault_anon},
    {"map_unmap", row_map_unmap},
    {"spawn_exit_static", row_spawn_exit_static},
    {"spawn_exit_linked", row_spawn_exit_linked},
    {"thread_create", row_thread_create},
    {"clock_mono", row_clock_mono},
    {"small_read", row_small_read},
    {"read_4k", row_read_4k},
    {"tree_walk", row_tree_walk},
    {"timer_wake_idle", row_timer_wake_idle},
};

int main(int argc, char **argv) {
  int i = 1;
  for (; i < argc && argv[i][0] == '-'; i++) {
    if (strcmp(argv[i], "-c") == 0 && i + 1 < argc) {
      if (sscanf(argv[++i], "%d,%d", &cpu_main, &cpu_partner) != 2) return 2;
    } else if (strcmp(argv[i], "-d") == 0 && i + 1 < argc) {
      dir = argv[++i];
    } else {
      fprintf(stderr, "usage: peer-bench [-c CPU,CPU] [-d DIR] [ROW ...]\n");
      return 2;
    }
  }
  // hello-static and hello-linked sit beside this program.
  snprintf(self_dir, sizeof self_dir, "%s", argv[0]);
  char *slash = strrchr(self_dir, '/');
  if (slash) *slash = 0; else strcpy(self_dir, ".");
  pin(cpu_main);
  int ran = 0;
  for (size_t r = 0; r < sizeof rows / sizeof rows[0]; r++) {
    int wanted = i == argc;
    for (int a = i; a < argc; a++) wanted |= strcmp(argv[a], rows[r].name) == 0;
    if (wanted) rows[r].run(), ran++;
  }
  return ran > 0 ? 0 : 2;
}
